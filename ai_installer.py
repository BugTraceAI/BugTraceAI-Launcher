#!/usr/bin/env python3
"""
BugTraceAI — AI Setup & Repair Assistant v2.9.2
Defaults to OpenRouter (DeepSeek V4.1 Flash -> Qwen 3.8 Max (0902)). Anthropic direct
(Claude Haiku 4.5 / Messages API) remains an explicit environment override.

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
import grp
import pwd
import secrets
import shlex
import shutil
import socket
from dataclasses import dataclass, replace
from datetime import datetime
from typing import Optional

import installer_core as core
from installer_core import Err, DomainError, PromptSpec, TerminalCaps
from assistant_runtime import (
    AgentLoop, CONTINUE_NUDGE, LoopOutcome, PrivilegeSession, ToolOutcome,
    rewrite_service_host_port, rewrite_web_cli_proxy,
    spawn_killable_process, sudo_ticket_unusable, wrap_readline_prompt,
)

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
_privilege_session: Optional[PrivilegeSession] = None


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
    if _privilege_session is not None:
        _privilege_session.close()
    if _STDOUT_IS_TTY:
        sys.stdout.write("\n\033[0m  Interrupted.\n")
    sys.exit(code)


atexit.register(_terminate_bash)
atexit.register(_cleanup_terminal)


def _close_privilege_session():
    if _privilege_session is not None:
        _privilege_session.close()


def _docker_info_ok():
    try:
        return subprocess.run(
            ["docker", "info"], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=20,
        ).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _docker_group_active():
    try:
        gid = grp.getgrnam("docker").gr_gid
    except KeyError:
        return False
    return gid in os.getgroups()


def _user_in_docker_group():
    try:
        docker = grp.getgrnam("docker")
        user = pwd.getpwuid(os.geteuid()).pw_name
    except (KeyError, OSError):
        return False
    if pwd.getpwuid(os.geteuid()).pw_gid == docker.gr_gid:
        return True
    return user in docker.gr_mem


def _maybe_reexec_with_docker_group():
    """Re-enter this process via ``sg docker`` so run_command can use the socket.

    ``usermod -aG docker`` does not change the groups of a running process.
    Without this, every docker call hits permission denied and the model
    retries ``run_privileged_command`` until sudo -n fails in a loop.
    """
    if sys.platform == "darwin" or os.geteuid() == 0:
        return
    if os.environ.get("BTAI_DOCKER_GROUP_REEXEC") == "1":
        return
    if _docker_group_active() or not _user_in_docker_group():
        return
    sg = shutil.which("sg")
    if not sg:
        return
    os.environ["BTAI_DOCKER_GROUP_REEXEC"] = "1"
    info("Activating the docker group for this session...")
    cmd = "exec " + shlex.join(
        [sys.executable, os.path.abspath(__file__), *sys.argv[1:]])
    try:
        os.execv(sg, [sg, "docker", "-c", cmd])
    except OSError as exc:
        os.environ.pop("BTAI_DOCKER_GROUP_REEXEC", None)
        info(f"Could not activate docker group ({exc}); privileged Docker commands will be used.")


def _ensure_linux_docker_engine():
    """Run the launcher's Linux Docker installer; output and sudo stay on the TTY."""
    launcher = os.path.join(os.path.dirname(os.path.abspath(__file__)), "launcher.sh")
    if not os.path.isfile(launcher):
        return False
    env = os.environ.copy()
    if _INSTALL_LOG_FILE:
        env["BUGTRACEAI_INSTALL_LOG"] = _INSTALL_LOG_FILE
    proc = subprocess.run(
        ["bash", "-c", 'source "$1" && ensure_linux_docker_engine yes',
         "bash", launcher],
        env=env,
    )
    return proc.returncode == 0


atexit.register(_close_privilege_session)
signal.signal(signal.SIGINT, lambda *_: _on_signal_exit(130))
signal.signal(signal.SIGTERM, lambda *_: _on_signal_exit(143))


def _positive_env_int(name, default):
    """Read an optional positive integer without making a bad env value fatal."""
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return max(1, value)


# ── Constants ────────────────────────────────────────────────────────────────
MAX_TURNS = _positive_env_int("BTAI_INSTALLER_MAX_TURNS", 80)
SUPPORT_TURNS = _positive_env_int("BTAI_INSTALLER_SUPPORT_TURNS", 32)
CMD_TIMEOUT_DEFAULT = 60
CMD_TIMEOUT_DOCKER_BUILD = 600
API_MAX_ATTEMPTS = 4
INSTALL_DIR = os.path.abspath(os.path.expanduser(
    os.environ.get("BUGTRACEAI_DIR", "~/bugtraceai")))
CLI_REPO = "https://github.com/BugTraceAI/BugTraceAI-CLI.git"
WEB_REPO = "https://github.com/BugTraceAI/BugTraceAI-WEB.git"
VERSION = "2.9.2"

# LLM provider + model chain are chosen AFTER the boot banner (the user picks
# the provider from a menu, unless BTAI_INSTALLER_PROVIDER is set).
# OpenRouter: DeepSeek V4.1 Flash primary + sticky Qwen 3.8 Max (0902) fallback. Anthropic
# (direct Messages API, x-api-key): a single Claude Haiku 4.5. Either primary/
# fallback can be overridden via env without touching code.
PROVIDER = core.PROVIDER_OPENROUTER
MODEL_CHAIN = ()
# Index into MODEL_CHAIN of the model currently in use. Advances (sticky) the
# first time we fall back, so we never thrash back to a dead/rate-limited model.
_active_model_idx = 0

# The boot banner is printed BEFORE the provider is known, so its subtitle is static.
_BANNER_SUBTITLE = "Interactive install  ·  diagnose  ·  repair"
_BANNER_SUBTITLE_ASCII = "Interactive install - diagnose - repair"


def _build_model_chain(provider):
    """Per-provider model chain, honouring the BTAI_INSTALLER_MODEL/_FALLBACK_MODEL
    env overrides. Anthropic runs a single Haiku 4.5 (its own direct-API slug);
    OpenRouter keeps the DeepSeek V4.1 Flash -> Qwen 3.8 Max (0902) fallback
    pair."""
    if provider == core.PROVIDER_ANTHROPIC:
        primary = os.environ.get("BTAI_INSTALLER_MODEL", core.DEFAULT_ANTHROPIC_PRIMARY_MODEL)
        fallback = os.environ.get("BTAI_INSTALLER_FALLBACK_MODEL", "")
    else:
        primary = os.environ.get("BTAI_INSTALLER_MODEL", core.DEFAULT_PRIMARY_MODEL)
        fallback = os.environ.get("BTAI_INSTALLER_FALLBACK_MODEL", core.DEFAULT_FALLBACK_MODEL)
    chain = core.build_model_chain(primary, fallback)
    if chain:
        return chain
    # A blank environment override must not leave the session with an empty
    # chain and crash before it can explain the configuration problem.
    return (core.DEFAULT_ANTHROPIC_PRIMARY_MODEL
            if provider == core.PROVIDER_ANTHROPIC
            else core.DEFAULT_PRIMARY_MODEL,)

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


_INSTALL_LOG_FILE = None


def _install_log_timestamp():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _known_log_secrets():
    key = globals().get("api_key")
    return (key,) if key else ()


def _log_event(level, msg):
    if not _INSTALL_LOG_FILE:
        return
    line = core.format_install_log_line(
        _install_log_timestamp(), level, msg, _known_log_secrets())
    try:
        with open(_INSTALL_LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(line)
    except OSError:
        pass


def _init_install_log():
    global _INSTALL_LOG_FILE
    path = os.environ.get("BUGTRACEAI_INSTALL_LOG") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "install.log")
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(
                f"\n===== BugTraceAI AI installer v{VERSION}  "
                f"{_install_log_timestamp()}  pid={os.getpid()} =====\n")
        _INSTALL_LOG_FILE = path
    except OSError:
        _INSTALL_LOG_FILE = None


def ok(msg):
    print(f"{GREEN}  {CHECK}  {RESET}{msg}")
    _log_event("OK", msg)


def err(msg):
    print(f"{RED}  {CROSS}  {RESET}{msg}")
    _log_event("ERROR", msg)


def info(msg):
    print(f"{CYAN}  {DOT}  {RESET}{DIM}{msg}{RESET}")
    _log_event("INFO", msg)


def _active_model_label():
    """Display name of the model currently answering; flags the fallback so the
    user can see when the primary handed off to the secondary model."""
    if not MODEL_CHAIN:
        return "Assistant"
    name = core.model_display_name(MODEL_CHAIN[_active_model_idx])
    return f"{name} · fallback" if _active_model_idx > 0 else name


def bubble_ai(text):
    print(f"\n{BLUE}{BOLD}  {_active_model_label()}{RESET}")
    for line in textwrap.wrap(text.strip(), width=COLS - 4) or [""]:
        print(f"  {BLUE}{line}{RESET}")
    if text and text.strip():
        _log_event("AI", text.strip())


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
    _log_event("CMD", f"rc={rc} {cmd}")
    if rc != 0 and output.strip():
        tail = "\n".join(output.strip().splitlines()[-20:])
        _log_event("CMD_OUT", tail)


def check_row(label, passed, note=""):
    icon = f"{GREEN}{CHECK}{RESET}" if passed else f"{RED}{CROSS}{RESET}"
    n = f"  {DIM}{GREY}{note}{RESET}" if note else ""
    print(f"  {icon}  {label:<38}{n}")


def _restore_cooked_tty():
    """Undo raw/cbreak leftovers so Backspace and arrows work in the chat.

    After sudo, Docker, and spinners the TTY can be left with ICANON off or
    with VERASE=DEL while the key sends ^H, which prints as ``^H^H^H``.
    """
    if not sys.stdin.isatty():
        return
    try:
        import termios
        fd = sys.stdin.fileno()
        iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)
        lflag |= (termios.ICANON | termios.ECHO | termios.ECHOE
                  | termios.ECHOK | termios.ISIG)
        echoctl = getattr(termios, "ECHOCTL", 0)
        if echoctl:
            lflag &= ~echoctl
        # Lubuntu/QTerminal Backspace is typically ^H, not DEL.
        cc[termios.VERASE] = "\x08"
        termios.tcsetattr(fd, termios.TCSADRAIN,
                          [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])
    except Exception:
        try:
            os.system("stty sane erase ^H -echoctl 2>/dev/null")
        except Exception:
            pass
    if _STDOUT_IS_TTY:
        sys.stdout.write("\033[0m\033[?25h")
        sys.stdout.flush()


_readline_ready = False


def _ensure_readline():
    """Load GNU readline so Backspace and arrows edit the chat line."""
    global _readline_ready
    if _readline_ready:
        return
    try:
        import readline
        readline.parse_and_bind(r'"\C-h": backward-delete-char')
        readline.parse_and_bind(r'"\C-?": backward-delete-char')
        readline.parse_and_bind("set horizontal-scroll-mode on")
        readline.parse_and_bind("set bell-style none")
        _readline_ready = True
    except ImportError:
        _readline_ready = False


def _read_line(prompt=""):
    _restore_cooked_tty()
    _ensure_readline()
    try:
        return input(wrap_readline_prompt(prompt) if prompt else "")
    except EOFError:
        return ""


def prompt_user():
    sys.stdout.write("\n")
    sys.stdout.flush()
    return _read_line(f"{GREEN}{BOLD}  {YOU} {ARROW}{RESET} ").strip()


def confirm(question):
    """Ask a y/N question. Accepts English and Spanish affirmatives."""
    return _read_line(f"{YELLOW}  {question} [y/N]: {RESET}").strip().lower() in (
        "y", "yes", "s", "si", "sí")


def _ask_menu(title, options, default=0):
    """Numbered menu on the TTY. Empty input keeps the default."""
    print()
    print(f"{WHITE}{BOLD}  {title}{RESET}")
    print()
    for i, option in enumerate(options, 1):
        marker = f"  {DIM}(default){RESET}" if i - 1 == default else ""
        print(f"  {CYAN}{i}){RESET} {option}{marker}")
    print()
    raw = _read_line(f"{YELLOW}  Option [1-{len(options)}]: {RESET}").strip()
    if not raw:
        return default
    if raw.isdigit() and 1 <= int(raw) <= len(options):
        return int(raw) - 1
    info(f"Invalid option; using default ({default + 1}).")
    return default


def _env_choice(name, allowed):
    value = os.environ.get(name, "").strip().lower()
    return value if value in allowed else None


def _has_existing_target():
    if os.path.isfile(os.path.join(INSTALL_DIR, ".launcher-state")):
        return True
    return any(
        os.path.isdir(os.path.join(INSTALL_DIR, name))
        for name in ("BugTraceAI-CLI", "BugTraceAI-WEB")
    )


def _choose_provider():
    env = _env_choice("BTAI_INSTALLER_PROVIDER",
                      (core.PROVIDER_OPENROUTER, core.PROVIDER_ANTHROPIC))
    if env:
        return env
    idx = _ask_menu(
        "Which LLM provider should power the assistant?",
        (
            "OpenRouter    (DeepSeek V4.1 Flash, Qwen 3.8 Max fallback)  — recommended",
            "Anthropic     (Claude Haiku 4.5, direct API, key starts with sk-ant-)",
        ),
        default=0,
    )
    return (core.PROVIDER_OPENROUTER, core.PROVIDER_ANTHROPIC)[idx]


def _choose_action(existing):
    env = _env_choice("BTAI_INSTALLER_ACTION", ("install", "repair"))
    if env:
        return env
    default = 1 if existing else 0
    idx = _ask_menu(
        "What would you like to do?",
        (
            "Install BugTraceAI",
            "Repair or diagnose an existing installation",
        ),
        default=default,
    )
    return ("install", "repair")[idx]


def _choose_mode(action):
    env = _env_choice("BTAI_INSTALLER_MODE", ("full", "cli", "web"))
    if env:
        return env
    title = ("Which part do you want to review?"
             if action == "repair" else "What do you want to install?")
    idx = _ask_menu(
        title,
        (
            "Full platform        (WEB + CLI — recommended)",
            "CLI only             (scanner API, no web interface)",
            "WEB only             (web interface — needs the CLI API elsewhere)",
        ),
        default=0,
    )
    return ("full", "cli", "web")[idx]


def _choose_mcp(mode):
    """Match the wizard extras: Full pack / Kali / recon / none. CLI-only skips this."""
    if mode == "cli":
        return False, False, False
    env_recon = os.environ.get("BTAI_INSTALLER_MCP_RECON", "").strip().lower()
    env_kali = os.environ.get("BTAI_INSTALLER_MCP_KALI", "").strip().lower()
    if env_recon in ("0", "1", "true", "false", "yes", "no") or env_kali in (
            "0", "1", "true", "false", "yes", "no"):
        recon = env_recon in ("1", "true", "yes")
        kali = env_kali in ("1", "true", "yes")
        return (mode == "full" or recon or kali), recon, kali
    idx = _ask_menu(
        "Would you like to add chat MCPs or the Kali toolbox?",
        (
            "Add Full Pack (reconFTW MCP + Kali toolbox)",
            "Add Kali Linux toolbox (full pentest toolkit — 3GB+)",
            "Add reconFTW MCP (OSINT & subdomains by @six2dez)",
            "NONE (only BugTraceAI core components)",
        ),
        default=0,
    )
    recon = idx in (0, 2)
    kali = idx in (0, 1)
    mcp_cli = mode == "full" or recon or kali
    return mcp_cli, recon, kali


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
        sys.stdout.write(f"\r{' ' * (len(self.label) + 30)}\r\033[?25h")
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
        _restore_cooked_tty()
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


@dataclass
class DeploymentContext:
    """Runtime configuration resolved from state, Docker, and local config.

    Host ports are values discovered at runtime.  They are never guessed from
    service defaults inside the AI assistant.
    """

    install_dir: str
    mode: str
    provider: str
    ports: core.DeploymentPorts
    mcp_cli_enabled: bool = False
    mcp_recon_enabled: bool = False
    mcp_kali_enabled: bool = False
    has_state: bool = False


def _as_port(value):
    try:
        port = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    return port if 1 <= port <= 65535 else None


def _read_env_values(path):
    values = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    except OSError:
        pass
    return values


def _load_saved_api_key(install_dir, provider):
    """Read an already-private deployed key locally without exposing it to the
    assistant transcript.  A missing key simply means we must ask once."""
    values = _read_env_values(os.path.join(install_dir, "BugTraceAI-CLI", ".env"))
    key = values.get(core.cli_key_env(provider), "").strip()
    return key or None


def _read_launcher_state(install_dir):
    try:
        with open(os.path.join(install_dir, ".launcher-state"), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def _allocate_host_port(reserved=()):
    """Ask the kernel for a currently free host port, without a fixed base."""
    reserved_ports = {port for port in reserved if _as_port(port) is not None}
    for _ in range(16):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            port = int(sock.getsockname()[1])
        if port not in reserved_ports:
            return port
    raise OSError("could not reserve a distinct ephemeral host port")


def _capture_host_command(argv, timeout=5):
    """Run a fixed host-side probe, retrying via the managed sudo ticket only
    when Docker socket permissions require it.  This never handles a password."""
    try:
        proc = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as ex:
        return 1, str(ex)

    output = proc.stdout or ""
    if proc.returncode == 0 or _privilege_session is None:
        return proc.returncode, output
    if "permission denied" not in output.lower() or not _privilege_session.ensure():
        return proc.returncode, output

    try:
        privileged = subprocess.run(
            ["sudo", "-n", *argv], stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=timeout,
        )
        return privileged.returncode, privileged.stdout or ""
    except (OSError, subprocess.TimeoutExpired) as ex:
        return 1, str(ex)


def _published_port(container):
    rc, output = _capture_host_command(["docker", "port", container])
    if rc != 0:
        return None
    for line in output.splitlines():
        candidate = line.split("->", 1)[-1].strip()
        _, sep, tail = candidate.rpartition(":")
        if sep:
            port = _as_port(tail)
            if port is not None:
                return port
    return None


def _first_published_port(*containers):
    for container in containers:
        port = _published_port(container)
        if port is not None:
            return port
    return None


def _bool_state(value):
    return value is True or str(value).strip().lower() == "true"


def _resolve_deployment_context():
    """Merge launcher state, local env files, and live Docker mappings."""
    state = _read_launcher_state(INSTALL_DIR)
    requested_mode = os.environ.get("BTAI_INSTALLER_MODE", "").strip().lower()
    state_mode = str(state.get("mode", "")).strip().lower()
    mode = requested_mode if requested_mode in ("full", "cli", "web") else state_mode
    if mode not in ("full", "cli", "web"):
        mode = "full"

    requested_provider = os.environ.get("BTAI_INSTALLER_PROVIDER", "").strip().lower()
    state_provider = str(state.get("provider", "")).strip().lower()
    provider = requested_provider if requested_provider in (
        core.PROVIDER_OPENROUTER, core.PROVIDER_ANTHROPIC,
    ) else state_provider
    if provider not in (core.PROVIDER_OPENROUTER, core.PROVIDER_ANTHROPIC):
        provider = core.PROVIDER_OPENROUTER

    web_env = _read_env_values(os.path.join(INSTALL_DIR, "BugTraceAI-WEB", ".env.docker"))
    ports = core.DeploymentPorts(
        web=_as_port(state.get("web_port")) or _as_port(web_env.get("FRONTEND_PORT")),
        cli=_as_port(state.get("cli_port")),
        mcp=_as_port(state.get("mcp_port")) or _as_port(web_env.get("CLI_MCP_PORT")),
        recon=_as_port(state.get("recon_port")) or _as_port(web_env.get("RECON_MCP_PORT")),
        kali=_as_port(state.get("kali_port")),
    )
    context = DeploymentContext(
        install_dir=INSTALL_DIR,
        mode=mode,
        provider=provider,
        ports=ports,
        mcp_cli_enabled=_bool_state(state.get("mcp_cli_enabled")),
        mcp_recon_enabled=_bool_state(state.get("mcp_recon_enabled")),
        mcp_kali_enabled=_bool_state(state.get("mcp_kali_enabled")),
        has_state=bool(state),
    )
    return _refresh_deployment_context(context, allocate_web=not context.has_state)


def _refresh_deployment_context(context, allocate_web=False):
    """Prefer actual published Docker ports over possibly stale saved state."""
    web = _published_port("bugtraceai-web-frontend") or context.ports.web
    cli = _first_published_port("bugtrace_api", "bugtrace-api") or context.ports.cli
    mcp = _first_published_port("bugtrace_mcp", "bugtrace-mcp", "bugtrace-cli-mcp") or context.ports.mcp
    recon = _published_port("reconftw-mcp") or context.ports.recon
    if allocate_web and context.mode in ("full", "web") and web is None:
        web = _allocate_host_port()
    return replace(context, ports=core.DeploymentPorts(
        web=web, cli=cli, mcp=mcp, recon=recon, kali=context.ports.kali,
    ))


def _write_private_file(path, content):
    """Write secret-bearing configuration with restrictive permissions from
    creation time, without rendering the secret in the terminal."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
    finally:
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass


def _set_cli_provider_active(conf_path, provider):
    """Set only [PROVIDER]/ACTIVE without shelling out or exposing secrets."""
    try:
        with open(conf_path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return

    active = core.cli_conf_active(provider)
    section_start = next((i for i, line in enumerate(lines)
                          if line.strip().upper() == "[PROVIDER]"), None)
    if section_start is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.extend(["\n", "[PROVIDER]\n", f"ACTIVE = {active}\n"])
    else:
        section_end = next((i for i in range(section_start + 1, len(lines))
                            if lines[i].lstrip().startswith("[")), len(lines))
        for i in range(section_start + 1, section_end):
            if lines[i].strip().upper().startswith("ACTIVE"):
                lines[i] = f"ACTIVE = {active}\n"
                break
        else:
            lines.insert(section_end, f"ACTIVE = {active}\n")
    with open(conf_path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def _configure_cli():
    global deployment_context
    cli_dir = os.path.join(INSTALL_DIR, "BugTraceAI-CLI")
    if not os.path.isdir(cli_dir):
        return False, "CLI directory is missing. Clone BugTraceAI-CLI first."

    if setup_action == "install":
        reserved = [port for port in (
            deployment_context.ports.web, deployment_context.ports.cli,
            deployment_context.ports.mcp, deployment_context.ports.recon,
            deployment_context.ports.kali,
        ) if port is not None]
        cli_port = deployment_context.ports.cli or _allocate_host_port(reserved)
        if not rewrite_service_host_port(
                os.path.join(cli_dir, "docker-compose.yml"), "bugtrace_api", cli_port):
            return False, "Could not assign a dynamic host port to the CLI Compose service."

        reserved.append(cli_port)
        mcp_port = deployment_context.ports.mcp or _allocate_host_port(reserved)
        mcp_patched = rewrite_service_host_port(
            os.path.join(cli_dir, "docker-compose.yml"), "bugtrace_mcp", mcp_port)
        deployment_context = replace(
            deployment_context,
            ports=replace(deployment_context.ports, cli=cli_port,
                          mcp=mcp_port if mcp_patched else deployment_context.ports.mcp),
            mcp_cli_enabled=mcp_patched or deployment_context.mcp_cli_enabled,
        )

    env_path = os.path.join(cli_dir, ".env")
    key_env = core.cli_key_env(PROVIDER)
    try:
        _write_private_file(env_path, (
            f"# Generated by BugTraceAI Launcher v{VERSION}\n"
            f"PROVIDER={PROVIDER}\n"
            f"{key_env}={api_key}\n"
            "BUGTRACE_CORS_ORIGINS=*\n"
        ))
        _set_cli_provider_active(os.path.join(cli_dir, "bugtraceaicli.conf"), PROVIDER)
    except OSError as exc:
        return False, f"Could not write CLI configuration: {exc}"
    return True, "CLI configuration was written with restricted permissions."


def _configure_web():
    global deployment_context
    web_dir = os.path.join(INSTALL_DIR, "BugTraceAI-WEB")
    if not os.path.isdir(web_dir):
        return False, "WEB directory is missing. Clone BugTraceAI-WEB first."
    if setup_action == "repair" and os.path.isfile(os.path.join(web_dir, ".env.docker")):
        return True, "Existing WEB configuration was preserved during repair."

    if deployment_context.mode == "full" and deployment_context.ports.cli is None:
        return False, "Full mode needs configure_cli before WEB configuration so its proxy has a resolved CLI endpoint."
    if deployment_context.ports.web is None:
        deployment_context = _refresh_deployment_context(deployment_context, allocate_web=True)
    web_port = deployment_context.ports.web
    if web_port is None:
        return False, "Could not allocate a WEB host port."
    reserved = [port for port in (
        deployment_context.ports.web, deployment_context.ports.cli,
        deployment_context.ports.mcp, deployment_context.ports.recon,
        deployment_context.ports.kali,
    ) if port is not None]
    database_port = _allocate_host_port(reserved)
    database_password = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                                for _ in range(24))
    try:
        _write_private_file(os.path.join(web_dir, ".env.docker"), (
            f"# Generated by BugTraceAI Launcher v{VERSION}\n"
            "POSTGRES_USER=bugtraceai\n"
            f"POSTGRES_PASSWORD={database_password}\n"
            "POSTGRES_DB=bugtraceai_web\n"
            f"POSTGRES_PORT={database_port}\n"
            f"FRONTEND_PORT={web_port}\n"
            "VITE_CLI_API_URL=/cli-api\n"
        ))
        if deployment_context.mode == "full" and not rewrite_web_cli_proxy(
                os.path.join(web_dir, "nginx.conf"), deployment_context.ports.cli):
            return False, "Could not point the WEB proxy at the resolved CLI endpoint."
    except OSError as exc:
        return False, f"Could not write WEB configuration: {exc}"
    return True, f"WEB configuration was written for the resolved host endpoint {core.endpoint_url(web_port)}."


def _save_ai_state(context):
    """Persist the same public state contract consumed by launcher.sh.

    The state deliberately excludes API and database secrets.
    """
    state_path = os.path.join(context.install_dir, ".launcher-state")
    data = {
        "version": VERSION,
        "mode": context.mode,
        "web_port": str(context.ports.web or ""),
        "cli_port": str(context.ports.cli or ""),
        "mcp_port": str(context.ports.mcp or ""),
        "recon_port": str(context.ports.recon or ""),
        "kali_port": str(context.ports.kali or ""),
        "provider": context.provider,
        "primary_model": MODEL_CHAIN[0] if MODEL_CHAIN else "",
        "fallback_model": MODEL_CHAIN[1] if len(MODEL_CHAIN) > 1 else "",
        "install_web": context.mode in ("full", "web"),
        "install_cli": context.mode in ("full", "cli"),
        "mcp_cli_enabled": context.mcp_cli_enabled,
        "mcp_recon_enabled": context.mcp_recon_enabled,
        "mcp_kali_enabled": context.mcp_kali_enabled,
        "install_dir": context.install_dir,
        "deployed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    _write_private_file(state_path, json.dumps(data, indent=2) + "\n")


# ── Verification (runs the pure plan; the predicates are pure) ────────────────
def run_verification(run_fn, context):
    print()
    hr("═", CYAN + BOLD)
    print(f"{CYAN}{BOLD}  Checking that everything responds{ELLIPSIS}{RESET}")
    hr("═", CYAN + BOLD)
    print()

    report = []
    all_ok = True

    # A running container without a resolved host endpoint is not enough to
    # claim that the user can reach the service.  Do not substitute a familiar
    # port number here; make the unresolved mapping visible to the agent.
    required_ports = []
    if context.mode in ("full", "cli"):
        required_ports.append(("CLI host port", context.ports.cli))
    if context.mode in ("full", "web"):
        required_ports.append(("WEB host port", context.ports.web))
    for label, port in required_ports:
        passed = port is not None
        check_row(label, passed, str(port) if passed else "not discovered")
        report.append(f"[{'PASS' if passed else 'FAIL'}] {label}: {port if passed else 'not discovered'}")
        all_ok = all_ok and passed

    for check in core.verification_checks(
            context.mode, context.install_dir, context.ports,
            mcp_enabled=context.mcp_cli_enabled,
            recon_enabled=context.mcp_recon_enabled):
        rc, out = run_fn(check.command)
        out = core.redact_sensitive_output(out, (api_key,))
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


def print_success_next_steps(context, action):
    action_label = "Repair" if action == "repair" else "Installation"
    print()
    hr("═", GREEN + BOLD)
    print(f"{GREEN}{BOLD}  {CHECK}  Done: {action_label} completed and verified.{RESET}")
    hr("═", GREEN + BOLD)
    print()
    print(f"{WHITE}{BOLD}  Check it now on your machine:{RESET}")
    if context.mode in ("full", "web") and context.ports.web is not None:
        print(f"  {CYAN}- WEB:{RESET} {core.endpoint_url(context.ports.web)}")
    if context.mode in ("full", "cli") and context.ports.cli is not None:
        print(f"  {CYAN}- CLI health:{RESET} {core.endpoint_url(context.ports.cli, '/health')}")
    print(f"  {CYAN}- Status:{RESET} ./launcher.sh status")
    print(f"  {CYAN}- Logs:{RESET} ./launcher.sh logs")
    if _INSTALL_LOG_FILE:
        print(f"  {CYAN}- Install log:{RESET} {_INSTALL_LOG_FILE}")
    print()
    print(f"{DIM}  You can type a question now, or press ENTER to exit.{RESET}")


# ── Boot ──────────────────────────────────────────────────────────────────────
reconnect_tty_or_exit()
_init_install_log()
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
if _INSTALL_LOG_FILE:
    print(f"{GREY}  Install log: {_INSTALL_LOG_FILE}{RESET}")
print()
hr()

# Privilege is intentionally acquired through the native terminal prompt.  We
# retain no password: sudo owns a temporary ticket, refreshed only while this
# process lives and explicitly invalidated on exit.
_privilege_session = PrivilegeSession()
info("Authenticate once with sudo if required; its native prompt will appear below.")
if not _privilege_session.authenticate():
    err("Sudo access is required to continue.")
    sys.exit(1)
ok("Temporary sudo session is active for this launcher only.")

_REEXECED_DOCKER_GROUP = os.environ.get("BTAI_DOCKER_GROUP_REEXEC") == "1"

# Disclaimer (skip on the sg docker re-exec — already confirmed).
if not _REEXECED_DOCKER_GROUP:
    print()
    print(f"{YELLOW}{BOLD}  {WARN}  RISKS BEFORE CONTINUING:{RESET}")
    print(f"{YELLOW}  1. The AI can install packages and modify system configuration.{RESET}")
    print(f"{YELLOW}  2. A mistake could affect other services on this machine.{RESET}")
    print(f"{YELLOW}  3. This consumes credits from your LLM provider account.{RESET}")
    print()
    if not confirm("Continue?"):
        print("\n  Cancelled.\n")
        sys.exit(0)
else:
    ok("Docker group is active in this session.")

if sys.platform != "darwin" and not _docker_info_ok():
    info("Docker Engine is not ready; installing or starting it...")
    if not _ensure_linux_docker_engine() and not _docker_info_ok():
        err("Docker Engine is required. Install it and rerun this installer.")
        sys.exit(1)
    if _docker_info_ok():
        ok("Docker Engine is ready.")
    else:
        info("Docker is installed; privileged commands will be used until this user is in the docker group.")

_maybe_reexec_with_docker_group()

# Interactive choices — same questions the AI installer asked before the
# autonomous pass. Environment overrides skip the matching menu.
PROVIDER = _choose_provider()
MODEL_CHAIN = _build_model_chain(PROVIDER)
_provider_name = "Anthropic" if PROVIDER == core.PROVIDER_ANTHROPIC else "OpenRouter"
_key_label = "Anthropic API key (sk-ant-...)" if PROVIDER == core.PROVIDER_ANTHROPIC else "OpenRouter API key"
_chain_label = " -> ".join(core.model_display_name(model) for model in MODEL_CHAIN)
ok(f"Provider: {_provider_name}  {DOT}  Models: {_chain_label}")

api_key = _load_saved_api_key(INSTALL_DIR, PROVIDER)
if api_key:
    ok(f"Using the locally saved API key: {core.mask_secret(api_key, mask_width=8)}")
else:
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
    ok(f"API key received: {core.mask_secret(api_key, mask_width=8)}")

hr()
with spinner_running("Validating API key"):
    _valid = validate_key(PROVIDER, api_key)
if not _valid:
    sys.exit(1)
ok(f"API key validated: {core.mask_secret(api_key, mask_width=8)}")
hr()

_existing_target = _has_existing_target()
setup_action = _choose_action(_existing_target)
install_mode = _choose_mode(setup_action)
mcp_cli_enabled, mcp_recon_enabled, mcp_kali_enabled = _choose_mcp(install_mode)
ok(f"Mode: {setup_action}  {DOT}  scope: {install_mode}")
if mcp_recon_enabled or mcp_kali_enabled:
    extras = []
    if mcp_recon_enabled:
        extras.append("reconFTW")
    if mcp_kali_enabled:
        extras.append("Kali")
    ok("Extras: " + " + ".join(extras))
elif install_mode != "cli":
    ok("Extras: none")

os.environ["BTAI_INSTALLER_MODE"] = install_mode
os.environ["BTAI_INSTALLER_PROVIDER"] = PROVIDER
os.environ["BTAI_INSTALLER_ACTION"] = setup_action
deployment_context = _resolve_deployment_context()
deployment_context = replace(
    deployment_context,
    mode=install_mode,
    provider=PROVIDER,
    mcp_cli_enabled=mcp_cli_enabled,
    mcp_recon_enabled=mcp_recon_enabled,
    mcp_kali_enabled=mcp_kali_enabled,
)
print()
hr()
print()
info(f"Starting AI agent — action: {setup_action}, mode: {install_mode}, target: {INSTALL_DIR}")
print()

# ── Build prompt & messages ──────────────────────────────────────────────────
SYSTEM = core.build_system_prompt(PromptSpec(
    mode=install_mode, action=setup_action, install_dir=INSTALL_DIR,
    api_key=api_key, cli_repo=CLI_REPO, web_repo=WEB_REPO, max_turns=MAX_TURNS,
    provider=PROVIDER, ports=deployment_context.ports,
    mcp_cli=mcp_cli_enabled, mcp_recon=mcp_recon_enabled, mcp_kali=mcp_kali_enabled))

messages = [
    {"role": "system", "content": SYSTEM},
    {"role": "user", "content": (
        f"Action: {setup_action}. Install mode: {install_mode}. "
        f"Install directory: {INSTALL_DIR}. "
        f"Components: WEB={'yes' if install_mode in ('full', 'web') else 'no'}, "
        f"CLI={'yes' if install_mode in ('full', 'cli') else 'no'}, "
        f"MCP={'yes' if mcp_cli_enabled else 'no'}, "
        f"reconFTW={'yes' if mcp_recon_enabled else 'no'}, "
        f"Kali={'yes' if mcp_kali_enabled else 'no'}. "
        f"The host holds the API key privately — do NOT ask for it. "
        f"If action is repair, diagnose first and do not reinstall without asking. "
        f"If action is install, start by assessing the system (Step 0), then follow the playbook. "
        f"Ask the user when a real choice appears."
    )},
]

tools = [
    {"type": "function", "function": {
        "name": "run_command",
        "description": ("Run a non-privileged bash command in a persistent stateful shell. "
                        "cd and env vars persist. Do not include sudo."),
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string", "description": "The bash command to execute."}},
                       "required": ["command"]}}},
    {"type": "function", "function": {
        "name": "run_privileged_command",
        "description": ("Run a root-required bash command through the temporary host-managed sudo ticket. "
                        "The command starts in a fresh shell, so include its working directory. Do not include sudo."),
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string", "description": "The root-required bash command to execute."}},
                       "required": ["command"]}}},
    {"type": "function", "function": {
        "name": "configure_cli",
        "description": ("Configure the cloned CLI locally. The host writes the API key securely and assigns dynamic "
                        "host port mappings; use this after cloning CLI and before building it."),
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "configure_web",
        "description": ("Configure the cloned WEB locally. The host chooses dynamic ports, creates the database secret, "
                        "and connects the WEB proxy to the resolved CLI endpoint in Full mode."),
        "parameters": {"type": "object", "properties": {}}}},
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
    move to the secondary model we stay there for the rest of the session instead
    of thrashing back to a dead/rate-limited primary. Returns Ok(AssistantMessage) or
    Err(DomainError) once the chain is exhausted."""
    global _active_model_idx
    if not MODEL_CHAIN:
        return Err(DomainError("configuration", "No assistant model is configured."))
    if _active_model_idx >= len(MODEL_CHAIN):
        _active_model_idx = 0
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


# ── Tool dispatch and autonomous agent loop ──────────────────────────────────
_AUTH_REQUIRED = (
    "[AUTH_REQUIRED] sudo authentication was cancelled or expired. "
    "Do not retry run_privileged_command in a loop. Use ask_user if a "
    "visible re-authentication is needed, or run_command when the docker "
    "group is already active."
)


def run_privileged_cmd(cmd, timeout=CMD_TIMEOUT_DEFAULT, spinner=None):
    """Run one root-required command through sudo's cached ticket.

    It deliberately uses a fresh process rather than the persistent user shell:
    a sudo expiry can then trigger the native terminal prompt in ``ensure()``
    rather than blocking invisibly behind the shell pipe.  No password enters
    Python memory or a command string.  The child stays in the installer TTY
    session so Ubuntu tty_tickets still apply.
    """
    safe_cmd, was_followed = core.harden_command(cmd)
    if _privilege_session is None or not _privilege_session.ensure():
        return 1, _AUTH_REQUIRED

    argv = (["/bin/bash", "-lc", safe_cmd] if os.geteuid() == 0
            else ["sudo", "-n", "/bin/bash", "-lc", safe_cmd])

    def _run_once():
        try:
            proc = spawn_killable_process(
                argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except OSError as exc:
            return 1, str(exc)
        try:
            output, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_bash_group(proc)
            try:
                output, _ = proc.communicate(timeout=5)
            except Exception:
                output = ""
            return 124, f"[TIMEOUT after {timeout}s — process killed]\n{output or ''}"
        return proc.returncode, output or ""

    rc, output = _run_once()
    if rc != 0 and sudo_ticket_unusable(output):
        info("Sudo needs a visible re-authentication on this terminal.")
        if _privilege_session.authenticate():
            rc, output = _run_once()
    if rc != 0 and sudo_ticket_unusable(output):
        return 1, _AUTH_REQUIRED + "\n" + output

    if was_followed:
        output = "[note] removed -f/--follow so the command can terminate.\n" + output
    return rc, output


def _tool_result(tc_id, name, content):
    return {"role": "tool", "tool_call_id": tc_id, "name": name, "content": content}


def _run_shell_tool(tc, args, privileged=False):
    cmd = args.get("command")
    if not isinstance(cmd, str) or not cmd.strip():
        return _tool_result(tc.id, tc.name, "ERROR: a non-empty string 'command' is required.")
    cmd = cmd.strip()
    if core.requests_sudo(cmd):
        return _tool_result(
            tc.id, tc.name,
            "ERROR: do not write sudo in commands. Use run_privileged_command without sudo.")
    if core.is_destructive(cmd):
        bubble_ai(f"The command looks destructive:\n  {cmd}")
        if not confirm("Run it anyway?"):
            return _tool_result(tc.id, tc.name, "The user declined to run the command.")

    timeout = core.select_timeout(cmd, CMD_TIMEOUT_DEFAULT, CMD_TIMEOUT_DOCKER_BUILD)
    runner = run_privileged_cmd if privileged else run_cmd
    if timeout > CMD_TIMEOUT_DEFAULT:
        with spinner_running(core.command_spinner_label(cmd)) as spinner:
            rc, output = runner(cmd, timeout=timeout, spinner=spinner)
    else:
        rc, output = runner(cmd, timeout=timeout)
    output = core.redact_sensitive_output(output, (api_key,))
    cmd_block(cmd, output, rc)
    return _tool_result(tc.id, tc.name, f"Exit code: {rc}\nOUTPUT:\n{output}")


def _ask_user_tool(tc, args):
    question = args.get("question", "How would you like to continue?")
    if not isinstance(question, str) or not question.strip():
        question = "How would you like to continue?"
    bubble_ai(question)
    answer = prompt_user()
    bubble_user(answer)
    return _tool_result(tc.id, tc.name, answer)


def _verification_command(cmd):
    """Run checks as the user first, escalating only for a Docker socket error."""
    rc, output = run_cmd(cmd)
    if (rc != 0 and "docker" in cmd and "permission denied" in output.lower()):
        return run_privileged_cmd(cmd)
    return rc, output


_consecutive_tool_protocol_errors = 0


def _protocol_error(tc, description):
    """Return a model-visible tool error and fail over after repeated malformed
    calls.  A second model can often recover when the primary got stuck emitting
    an incompatible tool schema.
    """
    global _active_model_idx, _consecutive_tool_protocol_errors
    _consecutive_tool_protocol_errors += 1
    suffix = ""
    if (core.tool_error_requires_failover(_consecutive_tool_protocol_errors)
            and _active_model_idx + 1 < len(MODEL_CHAIN)):
        previous = MODEL_CHAIN[_active_model_idx]
        _active_model_idx += 1
        _consecutive_tool_protocol_errors = 0
        suffix = (" The assistant was switched from "
                  f"{core.model_display_name(previous)} to "
                  f"{core.model_display_name(MODEL_CHAIN[_active_model_idx])}.")
        info(suffix.strip())
    return ToolOutcome(_tool_result(tc.id, tc.name, f"ERROR: {description}{suffix}"))


def _finish_tool(tc, args):
    global deployment_context
    summary = args.get("summary", "")
    if not isinstance(summary, str):
        return _protocol_error(tc, "'summary' must be a string.")
    if summary.strip():
        bubble_ai(summary)

    deployment_context = _refresh_deployment_context(deployment_context)
    all_ok, report = run_verification(_verification_command, deployment_context)
    if not all_ok:
        _log_event("ERROR", "verification failed")
        return ToolOutcome(_tool_result(
            tc.id, tc.name,
            "VERIFICATION FAILED. Fix the issues and call finish again.\n" + report))

    try:
        _save_ai_state(deployment_context)
    except OSError as exc:
        return ToolOutcome(_tool_result(
            tc.id, tc.name,
            f"VERIFICATION PASSED but state could not be saved: {exc}. Fix that and call finish again."))
    _log_event("OK", "verification passed")
    print_success_next_steps(deployment_context, setup_action)
    return ToolOutcome(_tool_result(tc.id, tc.name, "VERIFICATION PASSED.\n" + report), finished=True)


def _dispatch_tool(tc):
    """Validate a model call at the boundary and execute exactly one host tool."""
    global _consecutive_tool_protocol_errors
    _log_event("TOOL", tc.name)
    parsed = core.parse_tool_arguments(tc.arguments)
    if core.is_err(parsed):
        return _protocol_error(tc, f"{parsed.error.message} {parsed.error.detail}")
    _consecutive_tool_protocol_errors = 0
    args = parsed.value

    if tc.name == "run_command":
        return ToolOutcome(_run_shell_tool(tc, args, privileged=False))
    if tc.name == "run_privileged_command":
        return ToolOutcome(_run_shell_tool(tc, args, privileged=True))
    if tc.name == "configure_cli":
        try:
            success, detail = _configure_cli()
        except Exception as exc:
            success, detail = False, f"CLI configuration failed: {exc}"
        return ToolOutcome(_tool_result(tc.id, tc.name,
                                        ("OK: " if success else "ERROR: ") + detail))
    if tc.name == "configure_web":
        try:
            success, detail = _configure_web()
        except Exception as exc:
            success, detail = False, f"WEB configuration failed: {exc}"
        return ToolOutcome(_tool_result(tc.id, tc.name,
                                        ("OK: " if success else "ERROR: ") + detail))
    if tc.name == "ask_user":
        return ToolOutcome(_ask_user_tool(tc, args))
    if tc.name == "finish":
        return _finish_tool(tc, args)
    return _protocol_error(tc, f"unknown tool '{tc.name}'.")


# ── Request the assistant; handle provider errors as values ──────────────────
_last_agent_error = None


def request_assistant():
    with spinner_running(THINKING):
        return call_api()


def _report_agent_error(error):
    global _last_agent_error
    _last_agent_error = error
    err(error.message)
    if error.detail:
        info(error.detail)


def _render_turn(turn, limit):
    sys.stdout.write(f"{DIM}  [{turn}/{limit}]{RESET}\n")
    sys.stdout.flush()


def _close_persistent_shell():
    try:
        if _bash is not None and _bash.stdin is not None:
            _bash.stdin.close()
    except Exception:
        pass


def _report_turn_limit(limit):
    _log_event("ERROR", f"turn limit reached ({limit})")
    print()
    hr("═", RED + BOLD)
    print(f"{RED}{BOLD}  Turn limit reached ({limit}). The current task is not verified yet.{RESET}")
    print(f"{RED}  You can describe the next repair step, or press ENTER to exit.{RESET}")
    hr("═", RED + BOLD)
    print()


# Installer pass: status lines continue; a real question waits for an answer.
# Enter is not "continue" except as a reply to a question (then we nudge).
# ask_user also blocks inside the tool.
agent_loop = AgentLoop(
    messages=messages,
    request=request_assistant,
    is_error=core.is_err,
    assistant_message=core.assistant_message_dict,
    dispatch_tool=_dispatch_tool,
    render_assistant=bubble_ai,
    on_error=_report_agent_error,
    on_turn=_render_turn,
)

_EXIT_ANSWERS = ("exit", "quit", "bye", "salir")
outcome = agent_loop.advance(MAX_TURNS, wait_on_text=False)
while outcome == LoopOutcome.WAITING_FOR_USER:
    answer = prompt_user()
    if answer.lower() in _EXIT_ANSWERS:
        print(f"\n{CYAN}  Done. See you later.{RESET}\n")
        _close_persistent_shell()
        sys.exit(0)
    if answer:
        bubble_user(answer)
        messages.append({"role": "user", "content": answer})
    else:
        messages.append({"role": "user", "content": CONTINUE_NUDGE})
    outcome = agent_loop.advance(MAX_TURNS, wait_on_text=False)

if outcome == LoopOutcome.ERROR:
    info("The provider session stopped. You can run ./launcher.sh to start a new one.")
elif outcome == LoopOutcome.TURN_LIMIT:
    _report_turn_limit(MAX_TURNS)

# After verify (or turn limit), empty Enter exits; a typed question is support.
if outcome in (LoopOutcome.FINISHED, LoopOutcome.TURN_LIMIT):
    agent_loop.turns_used = 0
    while True:
        answer = prompt_user()
        if not answer or answer.lower() in _EXIT_ANSWERS:
            print(f"\n{CYAN}  Done. See you later.{RESET}\n")
            break
        bubble_user(answer)
        messages.append({"role": "user", "content": answer})
        outcome = agent_loop.advance(SUPPORT_TURNS, wait_on_text=True)
        if outcome == LoopOutcome.ERROR:
            break
        if outcome == LoopOutcome.TURN_LIMIT:
            _report_turn_limit(SUPPORT_TURNS)

_close_persistent_shell()
