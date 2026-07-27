#!/usr/bin/env python3
"""
BugTraceAI — AI Setup & Repair Assistant v2.8.7
Runs on OpenRouter (DeepSeek V3 -> Claude Haiku 4.5) or Anthropic (Claude Haiku 4.5,
direct Messages API), selected at startup.

This is the IMPERATIVE SHELL of a Functional-Core / Imperative-Shell design.
All decision logic (timeouts, retries, response parsing, command safety,
verification plan, system prompt) lives in the pure module `installer_core`
and is unit-tested without effects (see test_installer_core.py). This file owns
the effects: HTTP, the persistent bash subprocess, stdin/stdout, sleeping.

Errors from the core arrive as values (Ok/Err) and are handled explicitly here,
so a malformed model response or a transient API failure degrades gracefully
instead of crashing with a traceback.
"""
import json
import urllib.request
import urllib.error
import subprocess
import sys
import os
import uuid
import textwrap
import threading
import time
import signal
import atexit
import getpass

import installer_core as core
from installer_core import Err, DomainError, PromptSpec, TerminalCaps

# ── Terminal capabilities → palette (pure core decides; we only read env) ─────
_CAPS = TerminalCaps(
    is_tty=sys.stdout.isatty(),
    term=os.environ.get("TERM", ""),
    no_color="NO_COLOR" in os.environ,
    encoding=(sys.stdout.encoding
              or os.environ.get("LC_ALL")
              or os.environ.get("LC_CTYPE")
              or os.environ.get("LANG")
              or ""),
)
_STDOUT_IS_TTY = _CAPS.is_tty
_UTF8_ENABLED = core.utf8_enabled(_CAPS)
_P = core.make_palette(_CAPS)

RESET, BOLD, DIM = _P.reset, _P.bold, _P.dim
RED, GREEN, YELLOW = _P.red, _P.green, _P.yellow
BLUE, CYAN, WHITE, GREY = _P.blue, _P.cyan, _P.white, _P.grey
CHECK, CROSS, WARN = _P.check, _P.cross, _P.warn
DOT, ELLIPSIS, ARROW = _P.dot, _P.ellipsis, _P.arrow
YOU = "You" if _UTF8_ENABLED else "You"
THINKING = "The AI is thinking" if _UTF8_ENABLED else "The AI is thinking"


# The persistent bash runs in its own session (start_new_session=True), so it
# does NOT receive the terminal's Ctrl-C. We therefore kill its process group
# explicitly on every exit/interrupt path, or a long `docker compose up --build`
# would be orphaned and keep running after the installer quits.
_bash = None


def _terminate_bash():
    b = _bash
    if b is None:
        return
    try:
        os.killpg(os.getpgid(b.pid), signal.SIGKILL)
    except Exception:
        pass


def _cleanup_terminal():
    """Reset terminal on exit to prevent a broken TTY after spinners."""
    if _STDOUT_IS_TTY:
        sys.stdout.write("\033[0m\033[?25h")  # reset attributes + show cursor
        sys.stdout.flush()
    try:
        os.system("stty sane 2>/dev/null")
    except Exception:
        pass


def _on_signal_exit(code):
    _terminate_bash()
    if _STDOUT_IS_TTY:
        sys.stdout.write("\n\033[0m  Interrupted.\n")
    sys.exit(code)


atexit.register(_terminate_bash)
atexit.register(_cleanup_terminal)
signal.signal(signal.SIGINT, lambda *_: _on_signal_exit(130))
signal.signal(signal.SIGTERM, lambda *_: _on_signal_exit(143))

# ── Constants ────────────────────────────────────────────────────────────────
MAX_TURNS = 40
CMD_TIMEOUT_DEFAULT = 60
CMD_TIMEOUT_DOCKER_BUILD = 600
API_MAX_ATTEMPTS = 4
INSTALL_DIR = os.path.expanduser("~/bugtraceai")
CLI_REPO = "https://github.com/BugTraceAI/BugTraceAI-CLI.git"
WEB_REPO = "https://github.com/BugTraceAI/BugTraceAI-WEB.git"
VERSION = "2.8.7"

# LLM provider + model chain are chosen AFTER the boot banner (the user picks the
# provider from a menu), so these module globals are (re)assigned during boot.
# OpenRouter: DeepSeek V3 primary + sticky Claude Haiku 4.5 fallback. Anthropic
# (direct Messages API, x-api-key): a single Claude Haiku 4.5. Either primary/
# fallback can be overridden via env without touching code.
PROVIDER = core.PROVIDER_OPENROUTER
MODEL_CHAIN = ()
# Index into MODEL_CHAIN of the model currently in use. Advances (sticky) the
# first time we fall back, so we never thrash back to a dead/rate-limited model.
_active_model_idx = 0

# The boot banner is printed BEFORE the provider is known, so its subtitle is static.
_BANNER_SUBTITLE = "Autonomous install  ·  diagnose  ·  repair"
_BANNER_SUBTITLE_ASCII = "Autonomous install - diagnose - repair"


def _build_model_chain(provider):
    """Per-provider model chain, honouring the BTAI_INSTALLER_MODEL/_FALLBACK_MODEL
    env overrides. Anthropic runs a single Haiku 4.5 (its own direct-API slug);
    OpenRouter keeps the DeepSeek V3 -> Haiku 4.5 fallback pair."""
    if provider == core.PROVIDER_ANTHROPIC:
        primary = os.environ.get("BTAI_INSTALLER_MODEL", core.DEFAULT_ANTHROPIC_PRIMARY_MODEL)
        fallback = os.environ.get("BTAI_INSTALLER_FALLBACK_MODEL", "")
    else:
        primary = os.environ.get("BTAI_INSTALLER_MODEL", core.DEFAULT_PRIMARY_MODEL)
        fallback = os.environ.get("BTAI_INSTALLER_FALLBACK_MODEL", core.DEFAULT_FALLBACK_MODEL)
    return core.build_model_chain(primary, fallback)

try:
    COLS = min(os.get_terminal_size().columns, 100)
except Exception:
    COLS = 80


# ── UI helpers (effects only; formatting decisions come from the palette) ─────
def hr(char="─", color=GREY):
    if not _UTF8_ENABLED and char in ("─", "═"):
        char = "-" if char == "─" else "="
    sys.stdout.write(f"{color}{char * COLS}{RESET}\n")
    sys.stdout.flush()


def ok(msg):   print(f"{GREEN}  {CHECK}  {RESET}{msg}")
def err(msg):  print(f"{RED}  {CROSS}  {RESET}{msg}")
def info(msg): print(f"{CYAN}  {DOT}  {RESET}{DIM}{msg}{RESET}")


def _active_model_label():
    """Display name of the model currently answering; flags the fallback so the
    user can see when the cheap primary handed off to Haiku."""
    name = core.model_display_name(MODEL_CHAIN[_active_model_idx])
    return f"{name} · fallback" if _active_model_idx > 0 else name


def bubble_ai(text):
    print(f"\n{BLUE}{BOLD}  {_active_model_label()}{RESET}")
    for line in textwrap.wrap(text.strip(), width=COLS - 4) or [""]:
        print(f"  {BLUE}{line}{RESET}")


def bubble_user(text):
    print(f"\n{GREEN}{BOLD}  {YOU}{RESET}")
    for line in textwrap.wrap(text.strip(), width=COLS - 4) or [""]:
        print(f"  {GREEN}{line}{RESET}")


def cmd_block(cmd, output, rc):
    short = (cmd[:COLS - 12] + ELLIPSIS) if len(cmd) > COLS - 12 else cmd
    rc_col = GREEN if rc == 0 else RED
    top = "┌─" if _UTF8_ENABLED else "+-"
    side = "│" if _UTF8_ENABLED else "|"
    bottom = "└─" if _UTF8_ENABLED else "+-"
    print(f"\n{GREY}  {top} $ {short}{RESET}")
    if output.strip():
        lines = output.strip().splitlines()
        show = 40 if rc != 0 else 25
        for line in lines[:show]:
            disp = (line[:COLS - 9] + ELLIPSIS) if len(line) > COLS - 9 else line
            print(f"{DIM}  {side}  {disp}{RESET}")
        if len(lines) > show:
            print(f"{DIM}{GREY}  {side}  {ELLIPSIS} ({len(lines) - show} more lines){RESET}")
    print(f"{rc_col}{DIM}  {bottom} exit {rc}{RESET}")


def check_row(label, passed, note=""):
    icon = f"{GREEN}{CHECK}{RESET}" if passed else f"{RED}{CROSS}{RESET}"
    n = f"  {DIM}{GREY}{note}{RESET}" if note else ""
    print(f"  {icon}  {label:<38}{n}")


def prompt_user():
    sys.stdout.write(f"\n{GREEN}{BOLD}  {YOU} {ARROW}{RESET} ")
    sys.stdout.flush()
    line = sys.stdin.readline()
    return line.strip() if line else ""


def confirm(question):
    """Ask a y/N question. Accepts English and Spanish affirmatives."""
    sys.stdout.write(f"{YELLOW}  {question} [y/N]: {RESET}")
    sys.stdout.flush()
    return sys.stdin.readline().strip().lower() in ("y", "yes", "s", "si", "sí")


def reconnect_tty_or_exit():
    """Reconnect stdin to the controlling terminal when launched from a pipe."""
    if sys.stdin.isatty():
        return
    try:
        tty = open("/dev/tty")
        os.dup2(tty.fileno(), sys.stdin.fileno())
    except OSError:
        print(f"{RED}{CROSS} No interactive terminal (TTY) available. Run from a real terminal.{RESET}")
        sys.exit(1)


# ── Spinner (effect; enablement decided by the pure core) ─────────────────────
class Spinner:
    def __init__(self, label="Working"):
        self.label = label
        self.enabled = core.spinner_enabled(_CAPS)
        self.frames = _P.spinner_frames
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        i = 0
        while not self._stop.is_set():
            elapsed_s = int(i * 0.08)
            time_str = f" {elapsed_s}s" if elapsed_s >= 3 else ""
            frame = self.frames[i % len(self.frames)]
            sys.stdout.write(f"\r{CYAN}  {frame}{RESET} {DIM}{self.label}{ELLIPSIS}{time_str}{RESET}   ")
            sys.stdout.flush()
            time.sleep(0.08)
            i += 1
        sys.stdout.write(f"\r{' ' * (len(self.label) + 30)}\r")
        sys.stdout.flush()

    def update(self, label):
        self.label = label

    def start(self):
        if self.enabled:
            self._t.start()
        return self

    def stop(self):
        if self.enabled and self._t.is_alive():
            self._stop.set()
            self._t.join()


class spinner_running:
    """Context manager that guarantees the spinner is stopped even if the body
    raises or calls sys.exit — fixes the leftover-frame-over-error-message bug."""
    def __init__(self, label):
        self.spinner = Spinner(label)

    def __enter__(self):
        return self.spinner.start()

    def __exit__(self, *exc):
        self.spinner.stop()
        return False


# ── Key validation (effect; returns a plain bool) ─────────────────────────────
def validate_key(provider, key):
    """Cheaply validate a key for `provider` with an auth-only GET (the URL +
    headers come from the pure core). HTTP 200 => valid. Anthropic uses
    /v1/models (x-api-key); OpenRouter uses /api/v1/key (Bearer)."""
    url, headers = core.validation_request(provider, key)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status == 200
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:200]
        err(f"The provider rejected the key ({e.code}): {body}")
        return False
    except Exception as ex:
        err(str(ex))
        return False


# ── Verification (runs the pure plan; the predicates are pure) ────────────────
def run_verification(run_fn, mode):
    print()
    hr("═", CYAN + BOLD)
    print(f"{CYAN}{BOLD}  Checking that everything responds{ELLIPSIS}{RESET}")
    hr("═", CYAN + BOLD)
    print()

    report = []
    all_ok = True
    for check in core.verification_checks(mode, INSTALL_DIR):
        rc, out = run_fn(check.command)
        passed = core.evaluate_check(check.predicate, rc, out)
        note = out.strip()[:50] if out.strip() else ""
        check_row(check.label, passed, note if passed else (note or "FAILED"))
        report.append(f"[{'PASS' if passed else 'FAIL'}] {check.label}: {out.strip()[:80] or 'no output'}")
        if not passed and check.critical:
            all_ok = False

    print()
    if all_ok:
        hr("═", GREEN + BOLD)
        print(f"{GREEN}{BOLD}  {CHECK}  All checks passed.{RESET}")
        hr("═", GREEN + BOLD)
    else:
        hr("═", RED + BOLD)
        print(f"{RED}{BOLD}  {CROSS}  Some checks are failing; the agent will try to fix them.{RESET}")
        hr("═", RED + BOLD)
    return all_ok, "\n".join(report)


def print_success_next_steps(mode, action):
    action_label = "Repair" if action == "repair" else "Installation"
    print()
    hr("═", GREEN + BOLD)
    print(f"{GREEN}{BOLD}  {CHECK}  Done: {action_label} completed and verified.{RESET}")
    hr("═", GREEN + BOLD)
    print()
    print(f"{WHITE}{BOLD}  Check it now on your machine:{RESET}")
    if mode in ("full", "web"):
        print(f"  {CYAN}- WEB:{RESET} http://localhost:6869")
    if mode in ("full", "cli"):
        print(f"  {CYAN}- CLI health:{RESET} http://localhost:8000/health")
    print(f"  {CYAN}- Status:{RESET} ./launcher.sh status")
    print(f"  {CYAN}- Logs:{RESET} ./launcher.sh logs")
    print()
    print(f"{DIM}  You can type a question now, or press ENTER to exit.{RESET}")


# ── Boot ──────────────────────────────────────────────────────────────────────
reconnect_tty_or_exit()
os.system("clear")
print()
bw = 56
if _UTF8_ENABLED:
    print(f"{CYAN}{BOLD}  ┌{'─' * bw}┐{RESET}")
    print(f"{CYAN}{BOLD}  │{'BugTraceAI  ·  AI Setup & Repair Assistant  v' + VERSION:^{bw}}│{RESET}")
    print(f"{CYAN}{BOLD}  │{_BANNER_SUBTITLE:^{bw}}│{RESET}")
    print(f"{CYAN}{BOLD}  └{'─' * bw}┘{RESET}")
else:
    print(f"{CYAN}{BOLD}  {'-' * bw}{RESET}")
    print(f"{CYAN}{BOLD}  {'BugTraceAI - AI Setup & Repair Assistant v' + VERSION:^{bw}}{RESET}")
    print(f"{CYAN}{BOLD}  {_BANNER_SUBTITLE_ASCII:^{bw}}{RESET}")
    print(f"{CYAN}{BOLD}  {'-' * bw}{RESET}")
print()
print(f"{GREY}  Assisted agent with shell access. It can install BugTraceAI,{RESET}")
print(f"{GREY}  diagnose services, Docker, ports, database and configuration,{RESET}")
print(f"{GREY}  and verify the result automatically.{RESET}")
print(f"{GREY}  Recommended for clean VMs, VPS or controlled environments.{RESET}")
print()
hr()

# Sudo
with spinner_running("Requesting sudo"):
    _sudo = subprocess.run(["sudo", "-v"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if _sudo.returncode != 0:
    err("Sudo access is required to continue.")
    sys.exit(1)
ok("Sudo access confirmed.")

# Disclaimer
print()
print(f"{YELLOW}{BOLD}  {WARN}  RISKS BEFORE CONTINUING:{RESET}")
print(f"{YELLOW}  1. The AI can install packages and modify system configuration.{RESET}")
print(f"{YELLOW}  2. A mistake could affect other services on this machine.{RESET}")
print(f"{YELLOW}  3. This consumes credits from your LLM provider account.{RESET}")
print()
if not confirm("Continue?"):
    print("\n  Cancelled.\n")
    sys.exit(0)

# ── Provider selection (before the key, so the prompt + validation match) ─────
_env_provider = os.environ.get("BTAI_INSTALLER_PROVIDER", "").strip().lower()
if _env_provider in (core.PROVIDER_OPENROUTER, core.PROVIDER_ANTHROPIC):
    PROVIDER = _env_provider
    ok(f"Provider (from BTAI_INSTALLER_PROVIDER): {PROVIDER}")
else:
    print()
    print(f"{WHITE}{BOLD}  Which LLM provider should power the assistant?{RESET}")
    print()
    print(f"  {CYAN}1){RESET} OpenRouter   {DIM}(DeepSeek V3, key starts with sk-or-){RESET}")
    print(f"  {CYAN}2){RESET} Anthropic    {DIM}(Claude Haiku 4.5, direct API, key starts with sk-ant-){RESET}")
    print()
    sys.stdout.write(f"{YELLOW}  Option [1/2]: {RESET}")
    sys.stdout.flush()
    PROVIDER = core.PROVIDER_ANTHROPIC if sys.stdin.readline().strip() == "2" else core.PROVIDER_OPENROUTER

MODEL_CHAIN = _build_model_chain(PROVIDER)
_provider_name = "Anthropic" if PROVIDER == core.PROVIDER_ANTHROPIC else "OpenRouter"
_key_label = "Anthropic API key (sk-ant-...)" if PROVIDER == core.PROVIDER_ANTHROPIC else "OpenRouter API key"
ok(f"Provider: {_provider_name}  {DOT}  Model: {core.model_display_name(MODEL_CHAIN[0])}")

# API key — read WITHOUT echo so it never appears on screen; only a masked
# form (asterisks + last 5 chars) is ever displayed back to the user.
print()
try:
    api_key = getpass.getpass(f"  {_key_label} (hidden input): ").strip()
except Exception:
    # getpass could not disable echo (odd PTY / no controlling TTY). Warn loudly
    # rather than silently reading the key in cleartext.
    err("WARNING: input could not be hidden — the API key WILL be visible on screen.")
    sys.stdout.write(f"{WHITE}{BOLD}  {_key_label}:{RESET} ")
    sys.stdout.flush()
    api_key = sys.stdin.readline().strip()
if not api_key:
    err("The API key is required.")
    sys.exit(1)
# Fixed-width mask: asterisks + last 5 chars, so the display never leaks length.
ok(f"API key received: {core.mask_secret(api_key, mask_width=8)}")

hr()
with spinner_running("Validating API key"):
    _valid = validate_key(PROVIDER, api_key)
if not _valid:
    sys.exit(1)
ok(f"API key validated: {core.mask_secret(api_key, mask_width=8)}")
hr()

# Action selection
print()
print(f"{WHITE}{BOLD}  What would you like to do?{RESET}")
print()
print(f"  {CYAN}1){RESET} Install BugTraceAI")
print(f"  {CYAN}2){RESET} Repair or diagnose an existing installation")
print()
sys.stdout.write(f"{YELLOW}  Option [1/2]: {RESET}")
sys.stdout.flush()
_action_input = sys.stdin.readline().strip()
setup_action = "repair" if _action_input == "2" else "install"
ok("Mode: repair/diagnose" if setup_action == "repair" else "Mode: install")

# Scope selection
print()
print(f"{WHITE}{BOLD}  {'Which part do you want to review?' if setup_action == 'repair' else 'What do you want to install?'}{RESET}")
print()
_dash = "—" if _UTF8_ENABLED else "-"
print(f"  {CYAN}1){RESET} Full platform        {DIM}(WEB + CLI {_dash} recommended){RESET}")
print(f"  {CYAN}2){RESET} CLI only             {DIM}(scanner API, no web interface){RESET}")
print(f"  {CYAN}3){RESET} WEB only             {DIM}(web interface {_dash} needs the CLI API elsewhere){RESET}")
print()
sys.stdout.write(f"{YELLOW}  Option [1/2/3]: {RESET}")
sys.stdout.flush()
_mode_input = sys.stdin.readline().strip()
install_mode = {"1": "full", "2": "cli", "3": "web"}.get(_mode_input, "full")
ok(f"Selected mode: {install_mode}")
print()
hr()
print()
info(f"Starting AI agent — action: {setup_action}, mode: {install_mode}, target: {INSTALL_DIR}")
print()

# ── Build prompt & messages ──────────────────────────────────────────────────
SYSTEM = core.build_system_prompt(PromptSpec(
    mode=install_mode, action=setup_action, install_dir=INSTALL_DIR,
    api_key=api_key, cli_repo=CLI_REPO, web_repo=WEB_REPO, max_turns=MAX_TURNS,
    provider=PROVIDER))

messages = [
    {"role": "system", "content": SYSTEM},
    {"role": "user", "content": (
        f"Action: {setup_action}. Install mode: {install_mode}. "
        f"Install directory: {INSTALL_DIR}. "
        f"The API key is already in your system prompt — do NOT ask for it. "
        f"If action is repair, diagnose first and do not reinstall without asking. "
        f"If action is install, start by assessing the system (Step 0), then follow the playbook."
    )},
]

tools = [
    {"type": "function", "function": {
        "name": "run_command",
        "description": "Run a bash command in a persistent stateful shell. cd and env vars persist.",
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string", "description": "The bash command to execute."}},
                       "required": ["command"]}}},
    {"type": "function", "function": {
        "name": "ask_user",
        "description": "Ask the user a question when a real preference decision is needed.",
        "parameters": {"type": "object",
                       "properties": {"question": {"type": "string", "description": "The question to ask."}},
                       "required": ["question"]}}},
    {"type": "function", "function": {
        "name": "finish",
        "description": ("Call when you believe BugTraceAI is fully installed and running. "
                        "The system will automatically run verification checks. "
                        "If any critical check fails you will receive the results and must fix and call finish again."),
        "parameters": {"type": "object",
                       "properties": {"summary": {"type": "string", "description": "What was installed and how to access it."}},
                       "required": ["summary"]}}},
]


# ── API call (effect) with pure retry policy and typed result ─────────────────
def _fetch_completion(model):
    """Perform one HTTP request for `model` on the active PROVIDER. The endpoint,
    headers and body are built by the pure core (OpenRouter or Anthropic wire).
    Returns (status_code|None, body|None, neterr|None)."""
    spec = core.build_request(PROVIDER, model, api_key, messages, tools)
    req = urllib.request.Request(
        spec.url, data=json.dumps(spec.body).encode(), headers=spec.headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read().decode(), None
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode()
        except Exception:
            body = ""
        return e.code, body, None
    except Exception as ex:
        return None, None, str(ex)


def _call_one_model(model):
    """One model's full attempt: retries transient failures (network / 429 / 5xx)
    with backoff and returns Ok(AssistantMessage) or a terminal Err(DomainError).
    The retry decision and delay come from the pure core."""
    attempt = 0
    while True:
        attempt += 1
        status, body, neterr = _fetch_completion(model)

        if neterr is not None:
            if core.should_retry(None, attempt, API_MAX_ATTEMPTS):
                info(f"Network error ({neterr[:60]}); retry {attempt}/{API_MAX_ATTEMPTS}{ELLIPSIS}")
                time.sleep(core.backoff_delay(attempt))
                continue
            return Err(DomainError("network", "Could not reach the provider.", neterr))

        if status is not None and status >= 400:
            if core.should_retry(status, attempt, API_MAX_ATTEMPTS):
                info(f"HTTP {status}; retry {attempt}/{API_MAX_ATTEMPTS}{ELLIPSIS}")
                time.sleep(core.backoff_delay(attempt))
                continue
            return Err(core.classify_http_error(status, body or ""))

        return core.parse_response(PROVIDER, body or "")


def call_api():
    """Try each model in MODEL_CHAIN, starting from the active one. A model that
    fails terminally with a fallback-eligible error (network down, 4xx/5xx,
    corrupt body) hands off to the next model. The switch is STICKY — once we
    move to Haiku we stay there for the rest of the session instead of thrashing
    back to a dead/rate-limited primary. Returns Ok(AssistantMessage) or
    Err(DomainError) once the chain is exhausted."""
    global _active_model_idx
    idx = _active_model_idx
    while True:
        result = _call_one_model(MODEL_CHAIN[idx])
        if core.is_ok(result):
            _active_model_idx = idx  # remember the model that worked
            return result
        # Terminal failure for this model. Hand off only if there is a next model
        # AND the error is the kind a different provider could recover from.
        if idx + 1 < len(MODEL_CHAIN) and core.is_fallback_eligible(result.error):
            nxt = MODEL_CHAIN[idx + 1]
            err(f"{core.model_display_name(MODEL_CHAIN[idx])} failed "
                f"({result.error.kind}). Switching to {core.model_display_name(nxt)}{ELLIPSIS}")
            idx += 1
            _active_model_idx = idx  # sticky from here on
            continue
        return result


# ── Persistent bash shell with KERNEL-enforced timeout ────────────────────────
# The shell runs in its own session/process group (start_new_session=True) so a
# hung command can be killed for real: on timeout we SIGKILL the whole group
# (the old code wrote "\x03" to a pipe, which is NOT a SIGINT and never killed
# anything). After a timeout we respawn a fresh shell so no stale output can
# corrupt the next command. State (cd/env) is only lost on the rare timeout path.
def _spawn_bash():
    return subprocess.Popen(
        ["/bin/bash"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, start_new_session=True)


_bash = _spawn_bash()


def _kill_bash_group(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass


def _respawn_bash(old):
    _kill_bash_group(old)
    return _spawn_bash()


def run_cmd(cmd, timeout=CMD_TIMEOUT_DEFAULT, spinner=None):
    global _bash
    safe_cmd, was_followed = core.harden_command(cmd)
    sentinel = f"__DONE_{uuid.uuid4().hex}__"
    timed_out = threading.Event()
    completed = threading.Event()
    timeout_lock = threading.Lock()

    def _on_timeout():
        with timeout_lock:
            if completed.is_set():
                return
            timed_out.set()
            _kill_bash_group(_bash)  # SIGKILL the group → reader hits EOF immediately

    timer = threading.Timer(timeout, _on_timeout)
    timer.start()
    try:
        _bash.stdin.write(f"{safe_cmd}\necho \"\n{sentinel}$?\"\n")
        _bash.stdin.flush()
    except (BrokenPipeError, ValueError, OSError):
        with timeout_lock:
            completed.set()
            timer.cancel()
        _bash = _respawn_bash(_bash)
        return 1, "[shell] the persistent shell was restarted after a write failure."

    lines, rc, got_sentinel = [], 0, False
    try:
        while True:
            line = _bash.stdout.readline()
            if not line:
                break  # EOF (normal close, killed on timeout, or shell died)
            if sentinel in line:
                got_sentinel = True
                with timeout_lock:
                    completed.set()
                try:
                    rc = int(line.strip().replace(sentinel, ""))
                except ValueError:
                    rc = -1
                break
            lines.append(line)
            if spinner is not None and core.is_long_running(safe_cmd) and line.strip():
                label = core.docker_progress_label(line)
                if label:
                    spinner.update(label)
    finally:
        with timeout_lock:
            completed.set()
            timer.cancel()

    output = "".join(lines)
    if was_followed:
        output = "[note] removed -f/--follow so the command can terminate.\n" + output

    # Real timeout only if we did NOT already read the result (avoids a race
    # where the sentinel and the timer fire together → false rc=124).
    if timed_out.is_set() and not got_sentinel:
        _bash = _respawn_bash(_bash)  # fresh shell: no stale sentinel can corrupt the next command
        return 124, f"[TIMEOUT after {timeout}s — process killed]\n{output}"

    # EOF without a sentinel and no timeout → the shell died unexpectedly
    # (model ran `exit`, kill $$, or a crash). Report failure (not a false rc=0)
    # and respawn so the next command starts on a clean shell.
    if not got_sentinel:
        _bash = _respawn_bash(_bash)
        return 1, output + "\n[shell] the shell exited unexpectedly; it was restarted."

    return rc, output


# ── Tool dispatch helpers (shared by both loops) ──────────────────────────────
def _tool_result(tc_id, name, content):
    return {"role": "tool", "tool_call_id": tc_id, "name": name, "content": content}


def _run_command_tool(tc, args):
    cmd = args.get("command")
    if not cmd:
        return _tool_result(tc.id, tc.name, "ERROR: no 'command' was provided.")
    if core.is_destructive(cmd):
        bubble_ai(f"The command looks destructive:\n  {cmd}")
        if not confirm("Run it anyway?"):
            return _tool_result(tc.id, tc.name, "The user declined to run the command.")
    t = core.select_timeout(cmd, CMD_TIMEOUT_DEFAULT, CMD_TIMEOUT_DOCKER_BUILD)
    is_long = t > CMD_TIMEOUT_DEFAULT
    if is_long:
        with spinner_running(core.command_spinner_label(cmd)) as sp:
            rc, out = run_cmd(cmd, timeout=t, spinner=sp)
    else:
        rc, out = run_cmd(cmd, timeout=t)
    cmd_block(cmd, out, rc)
    return _tool_result(tc.id, tc.name, f"Exit code: {rc}\nOUTPUT:\n{out}")


def _ask_user_tool(tc, args):
    question = args.get("question", "How would you like to continue?")
    bubble_ai(question)
    answer = prompt_user()
    bubble_user(answer)
    return _tool_result(tc.id, tc.name, answer)


# ── Request the assistant; handle Err gracefully ──────────────────────────────
def request_assistant():
    with spinner_running(THINKING):
        result = call_api()
    return result


def _fail_and_exit(error: DomainError, code=1):
    err(error.message)
    if error.detail:
        info(error.detail)
    info("You can try again by running: ./launcher.sh")
    try:
        _bash.stdin.close()
    except Exception:
        pass
    sys.exit(code)


# ── Main chat loop (turn-limited) ─────────────────────────────────────────────
turn = 0
finished = False

while turn < MAX_TURNS:
    turn += 1
    sys.stdout.write(f"{DIM}  [{turn}/{MAX_TURNS}]{RESET}\n")
    sys.stdout.flush()

    result = request_assistant()
    if core.is_err(result):
        _fail_and_exit(result.error)
    msg = result.value

    if msg.content:
        bubble_ai(msg.content)

    if msg.tool_calls:
        messages.append(core.assistant_message_dict(msg))
        for tc in msg.tool_calls:
            parsed = core.parse_tool_arguments(tc.arguments)
            if core.is_err(parsed):
                # Feed the error back so the model can self-correct instead of crashing.
                messages.append(_tool_result(tc.id, tc.name,
                                             f"ERROR: {parsed.error.message} {parsed.error.detail}"))
                continue
            args = parsed.value

            if tc.name == "run_command":
                messages.append(_run_command_tool(tc, args))
            elif tc.name == "ask_user":
                messages.append(_ask_user_tool(tc, args))
            elif tc.name == "finish":
                bubble_ai(args.get("summary", ""))
                all_ok, report = run_verification(run_cmd, install_mode)
                if all_ok:
                    messages.append(_tool_result(tc.id, tc.name, f"VERIFICATION PASSED.\n{report}"))
                    finished = True
                    print_success_next_steps(install_mode, setup_action)
                else:
                    remaining = MAX_TURNS - turn
                    messages.append(_tool_result(
                        tc.id, tc.name,
                        f"VERIFICATION FAILED. Fix the issues and call finish again.\n"
                        f"You have {remaining} turns remaining.\n{report}"))
            else:
                messages.append(_tool_result(tc.id, tc.name, f"ERROR: unknown tool '{tc.name}'."))
        if finished:
            break
    elif msg.content:
        # The model spoke without a tool call → conversational turn.
        messages.append(core.assistant_message_dict(msg))
        answer = prompt_user()
        if answer.lower() in ("exit", "quit", "bye", "salir"):
            print(f"\n{CYAN}  Done. See you later.{RESET}\n")
            _bash.stdin.close()
            sys.exit(0)
        if answer:
            bubble_user(answer)
            messages.append({"role": "user", "content": answer})
    else:
        # Empty response (no content, no tool calls): don't append a null message
        # (the API would reject it) and don't block on input — nudge and continue.
        messages.append({"role": "user", "content": "Continue with the next step."})

# ── Exhausted ─────────────────────────────────────────────────────────────────
if not finished:
    print()
    hr("═", RED + BOLD)
    print(f"{RED}{BOLD}  Turn limit reached ({MAX_TURNS}). It did not finish.{RESET}")
    print(f"{RED}  Try the standard installer: ./launcher.sh{RESET}")
    hr("═", RED + BOLD)
    print()
    _bash.stdin.close()
    sys.exit(1)

# ── Post-finish support loop (unlimited) ──────────────────────────────────────
while True:
    answer = prompt_user()
    if not answer or answer.lower() in ("exit", "quit", "bye", "salir"):
        print(f"\n{CYAN}  Done. See you later.{RESET}\n")
        break
    bubble_user(answer)
    messages.append({"role": "user", "content": answer})

    result = request_assistant()
    if core.is_err(result):
        err(result.error.message)
        if result.error.detail:
            info(result.error.detail)
        continue
    msg = result.value

    if msg.content:
        bubble_ai(msg.content)

    if msg.tool_calls:
        messages.append(core.assistant_message_dict(msg))
        for tc in msg.tool_calls:
            parsed = core.parse_tool_arguments(tc.arguments)
            if core.is_err(parsed):
                messages.append(_tool_result(tc.id, tc.name,
                                             f"ERROR: {parsed.error.message} {parsed.error.detail}"))
                continue
            args = parsed.value
            if tc.name == "run_command":
                messages.append(_run_command_tool(tc, args))
            elif tc.name == "ask_user":
                messages.append(_ask_user_tool(tc, args))
            elif tc.name == "finish":
                # Re-verify on finish here too, so a repair done during Q&A is
                # actually re-checked instead of blindly acknowledged.
                bubble_ai(args.get("summary", ""))
                all_ok, report = run_verification(run_cmd, install_mode)
                tag = "VERIFICATION PASSED." if all_ok else "VERIFICATION FAILED. Fix and call finish again."
                messages.append(_tool_result(tc.id, tc.name, f"{tag}\n{report}"))
            else:
                messages.append(_tool_result(tc.id, tc.name, f"ERROR: unknown tool '{tc.name}'."))
    elif msg.content:
        messages.append(core.assistant_message_dict(msg))

try:
    _bash.stdin.close()
except Exception:
    pass
