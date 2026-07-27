#!/usr/bin/env python3
"""
installer_core.py — Pure functional core for the BugTraceAI AI Setup & Repair
Assistant.

This module is the *functional core* of the Functional-Core / Imperative-Shell
split. Every function here is referentially transparent:

  * NO I/O                (no print, no file, no socket, no subprocess)
  * NO clock              (never reads the time)
  * NO randomness
  * NO environment reads   (terminal capabilities are passed in as values)
  * NO global mutable state
  * NO argument mutation   (inputs are treated as immutable)

The imperative shell (ai_installer.py) performs all effects — HTTP, the bash
subprocess, stdin/stdout, sleeping for backoff — and feeds the *results* of
those effects into these pure functions. That makes the decision logic
(timeouts, retries, response parsing, command safety, verification spec)
unit-testable with plain values and no mocks: see test_installer_core.py.

Errors are returned as values (Ok/Err) instead of raised, so every caller must
handle success and failure explicitly. The only place exceptions are caught is
the boundary parsers (json.loads), which immediately become typed DomainErrors.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Optional, Tuple


HEALTHY_TOKENS = ("healthy", "ok", "ready", "up", "alive", "running", "pass")


# ── Errors as values ──────────────────────────────────────────────────────────
@dataclass(frozen=True)
class DomainError:
    """A typed, immutable error from the core. `kind` is a stable machine code,
    `message` is an English user-facing summary, `detail` is optional context."""
    kind: str
    message: str
    detail: str = ""


@dataclass(frozen=True)
class Ok:
    value: Any


@dataclass(frozen=True)
class Err:
    error: DomainError


# A Result is an Ok | Err. These helpers keep call sites declarative.
def is_ok(result) -> bool:
    return isinstance(result, Ok)


def is_err(result) -> bool:
    return isinstance(result, Err)


# ── Terminal capabilities (pure values, never read here) ──────────────────────
@dataclass(frozen=True)
class TerminalCaps:
    is_tty: bool
    term: str
    no_color: bool
    encoding: str


def color_enabled(caps: TerminalCaps) -> bool:
    return caps.is_tty and caps.term != "dumb" and not caps.no_color


def utf8_enabled(caps: TerminalCaps) -> bool:
    return "UTF" in caps.encoding.upper()


def spinner_enabled(caps: TerminalCaps) -> bool:
    return caps.is_tty and caps.term != "dumb"


@dataclass(frozen=True)
class Palette:
    reset: str
    bold: str
    dim: str
    red: str
    green: str
    yellow: str
    blue: str
    cyan: str
    white: str
    grey: str
    check: str
    cross: str
    warn: str
    dot: str
    ellipsis: str
    arrow: str
    spinner_frames: str


def make_palette(caps: TerminalCaps) -> Palette:
    """Build the full palette from terminal capabilities. Pure: same caps in →
    same palette out. Colour codes collapse to '' when colour is disabled, and
    every non-ASCII glyph falls back to ASCII when UTF-8 is unavailable."""
    color = color_enabled(caps)
    utf8 = utf8_enabled(caps)

    def ansi(code: str) -> str:
        return f"\033[{code}m" if color else ""

    return Palette(
        reset=ansi("0"), bold=ansi("1"), dim=ansi("2"),
        red=ansi("31"), green=ansi("32"), yellow=ansi("33"),
        blue=ansi("94"), cyan=ansi("36"), white=ansi("37"), grey=ansi("90"),
        check="✔" if utf8 else "OK",
        cross="✖" if utf8 else "NO",
        warn="⚠" if utf8 else "!",
        dot="·" if utf8 else "-",
        ellipsis="…" if utf8 else "...",
        arrow="›" if utf8 else ">",
        spinner_frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" if utf8 else "|/-\\",
    )


# ── Command classification (pure) ─────────────────────────────────────────────
_LONG_CMD_MARKERS: Tuple[str, ...] = (
    "docker compose up", "docker compose build",
    "docker-compose up", "docker-compose build",
    "docker build", "docker pull", "docker compose pull",
    "apt-get install", "apt install", "npm install", "npm ci",
    "get.docker.com",
)

# High-signal literal patterns (whitespace-normalized match). These never have
# a legitimate use during an install.
_DESTRUCTIVE_LITERALS: Tuple[str, ...] = (
    "rm -rf --no-preserve-root", "mkfs", "dd if=", "of=/dev/sd", "of=/dev/nvme",
    "of=/dev/hd", ">/dev/sd", "> /dev/sd", "drop database", "drop table",
    "truncate table", "chmod -r 777 /", "chown -r / ", ":(){", "userdel ",
    "deluser ", "docker system prune", "docker volume prune", "docker volume rm",
)

# Paths that make a recursive+force delete dangerous (the shell may have cd'd
# into the install dir, so cwd-relative targets like '.' and '*' matter).
_DANGEROUS_RM_TARGETS = frozenset({
    "/", ".", "..", "*", "~", "$home", "./", "./*", "~/", "~/*",
    "/home", "/etc", "/var", "/usr", "/boot", "/root", "/bin", "/sbin",
    "/lib", "/lib64", "/opt", "/srv",
})


def _has_flag(tokens, letter: str) -> bool:
    """True if a recursive ('r') or force ('f') flag is present, whether given
    as a long flag (--recursive/--force) or inside a short cluster (-rf, -fr)."""
    longs = {"r": "--recursive", "f": "--force"}
    for t in tokens:
        if not t.startswith("-"):
            continue
        if t.startswith("--"):
            if t == longs[letter]:
                return True
        elif letter in t[1:]:
            return True
    return False


def is_long_running(cmd: str) -> bool:
    """True for commands that legitimately take minutes (builds, image pulls,
    package installs) and therefore deserve the long timeout."""
    return any(marker in cmd for marker in _LONG_CMD_MARKERS)


def select_timeout(cmd: str, default_timeout: int, long_timeout: int) -> int:
    """Pick a timeout for a command. Single source of truth so the spinner
    decision and the kill deadline can never disagree (the old code had two
    separate, divergent docker-detection lists)."""
    return long_timeout if is_long_running(cmd) else default_timeout


def _tokens(cmd: str) -> Tuple[str, ...]:
    return tuple(cmd.split())


def is_streaming_log(cmd: str) -> bool:
    """True for `docker [compose] logs -f/--follow …`, which never terminates
    and would block the installer forever. Detected so the shell can refuse it."""
    toks = _tokens(cmd)
    if "logs" not in toks:
        return False
    return any(t == "-f" or t == "--follow" for t in toks)


def harden_command(cmd: str) -> Tuple[str, bool]:
    """Return (safe_cmd, was_modified). Strips -f/--follow from a streaming
    `logs` command so it returns immediately instead of hanging. Any other
    command is returned unchanged. Pure string transform."""
    if not is_streaming_log(cmd):
        return (cmd, False)
    safe = " ".join(t for t in _tokens(cmd) if t not in ("-f", "--follow"))
    return (safe, True)


def is_destructive(cmd: str) -> bool:
    """True if the command is likely destructive. The shell turns True into an
    explicit y/N confirmation; it never silently blocks. Tokenized + whitespace
    -normalized so split flags ('rm -r -f /'), double spaces and cwd-relative
    targets ('rm -rf .', 'rm -rf *') are caught, not just exact substrings."""
    low = " ".join(cmd.lower().split())
    if any(pattern in low for pattern in _DESTRUCTIVE_LITERALS):
        return True
    toks = low.split()
    # docker rmi / docker rm -f
    if "docker" in toks and ("rmi" in toks or ("rm" in toks and _has_flag(toks, "f"))):
        return True
    # `docker compose down -v` / `--volumes` destroys NAMED volumes (the Postgres
    # DB + CLI SQLite source-of-truth), so it must be confirmed like `volume rm`.
    # Matches `docker compose down` and the hyphenated `docker-compose down`, with
    # the volume flag given long (`--volumes`) or short, incl. clusters (`-v`,`-fv`).
    if "down" in toks and ("docker" in toks or "docker-compose" in toks):
        for t in toks:
            if t == "--volumes" or (
                t.startswith("-") and not t.startswith("--") and "v" in t[1:]
            ):
                return True
    # git clean -f...
    if "git" in toks and "clean" in toks and _has_flag(toks, "f"):
        return True
    # recursive+force rm targeting a dangerous path (or no explicit path)
    if "rm" in toks and _has_flag(toks, "r") and _has_flag(toks, "f"):
        targets = [t for t in toks if not t.startswith("-") and t not in ("rm", "sudo")]
        if not targets:
            return True
        for t in targets:
            if t in _DANGEROUS_RM_TARGETS or t.rstrip("/") in _DANGEROUS_RM_TARGETS \
                    or t.startswith("/home") or t.startswith("$home") or t.startswith("~"):
                return True
    return False


def command_spinner_label(cmd: str) -> str:
    """English progress label for a long-running command."""
    if "build" in cmd:
        return "Building Docker images"
    if "docker" in cmd:
        return "Running Docker"
    return "Running command"


def docker_progress_label(line: str) -> Optional[str]:
    """Map a single line of docker output to a short English spinner label, or
    None if the line is not an interesting progress marker. Pure."""
    s = line.strip()
    if not s:
        return None
    if s.startswith("#") or s.startswith("Step "):
        return f"Building: {s[:50]}"
    if "Pulling" in s or "Downloading" in s:
        return f"Downloading: {s[:50]}"
    for kw in ("Creating", "Created", "Starting", "Started", "Healthy", "Built"):
        if kw in s:
            return f"Docker: {s[:50]}"
    return None


# ── Retry policy (pure, deterministic) ────────────────────────────────────────
def should_retry(status_code: Optional[int], attempt: int, max_attempts: int) -> bool:
    """Decide whether to retry an API call. `status_code` is None for network /
    timeout errors. Retries on transient failures only (None, 429, 5xx) and
    never beyond max_attempts. attempt is 1-based."""
    if attempt >= max_attempts:
        return False
    if status_code is None:
        return True
    return status_code == 429 or 500 <= status_code < 600


def mask_secret(secret: str, visible: int = 5, mask_char: str = "*",
                mask_width: Optional[int] = None) -> str:
    """Mask a secret for display: keep only the last `visible` characters and
    replace the rest with `mask_char`. With `mask_width` set, the masked prefix
    is a FIXED number of chars (so the display length does not leak the real
    length). A secret no longer than `visible` is fully masked. Pure."""
    if not secret:
        return ""
    if visible <= 0 or len(secret) <= visible:
        return mask_char * (mask_width if mask_width is not None else len(secret))
    width = mask_width if mask_width is not None else (len(secret) - visible)
    return mask_char * width + secret[-visible:]


def backoff_delay(attempt: int, base: float = 1.0, cap: float = 30.0) -> float:
    """Deterministic exponential backoff: base * 2^(attempt-1), capped. No
    randomness so the function stays pure and testable; the shell may add jitter
    at the effect boundary if desired. attempt is 1-based."""
    if attempt < 1:
        return 0.0
    return min(cap, base * (2 ** (attempt - 1)))


# ── Model selection / fallback chain (pure) ───────────────────────────────────
# The installer drives an agentic tool-calling loop, so the model MUST be a
# reliable tool-caller. DeepSeek V3 is the cheap primary; Claude Haiku 4.5 is the
# proven fallback used only if the primary fails terminally. Both ids are
# OpenRouter slugs; the shell may override either via env vars.
DEFAULT_PRIMARY_MODEL = "deepseek/deepseek-chat"
DEFAULT_FALLBACK_MODEL = "anthropic/claude-haiku-4.5"

# Error kinds that mean "this model/provider could not give us a usable
# response", so trying the next model in the chain is worthwhile. These are
# exactly the kinds call_api() can surface after its own retries are exhausted
# (a bad request the next model would also reject is still worth one attempt,
# since the two providers validate payloads differently).
_FALLBACK_ELIGIBLE_KINDS = frozenset({
    "network", "api_error", "invalid_json", "bad_response_shape",
})

# Human-friendly names for the model ids we ship, so the UI never shows a raw
# slug. Anything not listed degrades to its last path segment.
_MODEL_DISPLAY_NAMES = {
    "deepseek/deepseek-chat": "DeepSeek V3",
    "anthropic/claude-haiku-4.5": "Haiku 4.5",
    "claude-haiku-4-5": "Haiku 4.5",
    "z-ai/glm-4.6": "GLM-4.6",
    "moonshotai/kimi-k2": "Kimi K2",
}


# ── Providers (pure) ──────────────────────────────────────────────────────────
# The assistant can run its own reasoning on either OpenRouter (OpenAI-compatible
# Chat Completions) or Anthropic (Messages API, x-api-key). ALL wire divergence
# is confined to build_request()/parse_anthropic_response() below; the accumulating
# `messages` list always stays in the canonical OpenAI shape so the chat loops and
# assistant_message_dict()/_tool_result() never change.
PROVIDER_OPENROUTER = "openrouter"
PROVIDER_ANTHROPIC = "anthropic"

# Anthropic direct-API default model for the assistant's own reasoning. NOTE the
# bare slug (no 'anthropic/' prefix) — the OpenRouter slug 'anthropic/claude-haiku-4.5'
# is NOT valid against api.anthropic.com.
DEFAULT_ANTHROPIC_PRIMARY_MODEL = "claude-haiku-4-5"
ANTHROPIC_VERSION = "2023-06-01"
ANTHROPIC_MAX_TOKENS = 4096

# How the DEPLOYED CLI is configured per provider: the .env key variable it reads,
# and the bugtraceaicli.conf [PROVIDER] ACTIVE value that selects the preset.
_CLI_PROVISION = {
    "openrouter": ("OPENROUTER_API_KEY", "openrouter-v2"),
    "zai":        ("GLM_API_KEY",        "zai"),
    "anthropic":  ("ANTHROPIC_API_KEY",  "anthropic"),
}


def cli_key_env(provider: str) -> str:
    """The .env variable the deployed CLI reads its API key from, for `provider`.
    Unknown providers degrade to OpenRouter. Pure."""
    return _CLI_PROVISION.get(provider, _CLI_PROVISION["openrouter"])[0]


def cli_conf_active(provider: str) -> str:
    """The bugtraceaicli.conf [PROVIDER] ACTIVE value that selects `provider`'s
    preset. Unknown providers degrade to the recommended OpenRouter preset. Pure."""
    return _CLI_PROVISION.get(provider, _CLI_PROVISION["openrouter"])[1]


def cli_conf_patch_command(provider: str, conf_file: str = "bugtraceaicli.conf") -> str:
    """The exact, idempotent, section-scoped shell command that sets the deployed
    CLI's active provider by rewriting the ACTIVE line *within* [PROVIDER] only
    (the CLI overrides .env PROVIDER with this conf value at load time, so writing
    the key to .env is not enough). Pure — returns a string; the shell runs it."""
    active = cli_conf_active(provider)
    return (r"sed -i '/^\[PROVIDER\]/,/^\[/ s/^ACTIVE *=.*/ACTIVE = "
            + active + r"/' " + conf_file)


def build_model_chain(primary: str, fallback: str) -> Tuple[str, ...]:
    """Build the ordered model fallback chain from a primary and a fallback id.
    Blanks are dropped and a fallback equal to the primary is omitted, so the
    chain never tries the same model twice and (given a non-blank primary) is
    always non-empty. Pure."""
    chain = []
    for m in (primary, fallback):
        m = (m or "").strip()
        if m and m not in chain:
            chain.append(m)
    return tuple(chain)


def is_fallback_eligible(error: "DomainError") -> bool:
    """True if a terminal error from one model call warrants handing off to the
    next model in the chain (rather than failing outright). Pure."""
    return error.kind in _FALLBACK_ELIGIBLE_KINDS


def model_display_name(model_id: str) -> str:
    """Short, human-friendly name for a model id. Unknown ids degrade to their
    last path segment (e.g. 'foo/bar-baz' -> 'bar-baz'). Pure."""
    if not model_id:
        return "model"
    return _MODEL_DISPLAY_NAMES.get(model_id) or model_id.split("/")[-1]


# ── API response parsing (errors as values) ───────────────────────────────────
@dataclass(frozen=True)
class ToolCall:
    id: str
    name: str
    arguments: str  # raw JSON string; parse with parse_tool_arguments


@dataclass(frozen=True)
class AssistantMessage:
    content: Optional[str]
    tool_calls: Tuple[ToolCall, ...]
    raw: Any  # original message dict, needed verbatim for the next API call


def parse_tool_arguments(arguments: str):
    """Parse a tool-call arguments JSON string into a dict. Returns Ok(dict) or
    Err(DomainError) — never raises on malformed input."""
    try:
        data = json.loads(arguments) if arguments else {}
    except (json.JSONDecodeError, ValueError) as exc:
        return Err(DomainError("invalid_tool_args",
                               "The model sent invalid arguments (broken JSON).",
                               str(exc)[:200]))
    if not isinstance(data, dict):
        return Err(DomainError("invalid_tool_args",
                               "The tool arguments are not an object.",
                               str(type(data))))
    return Ok(data)


def parse_api_response(raw_text: str):
    """Validate and parse a raw OpenRouter chat-completions response body.

    Returns Ok(AssistantMessage) or Err(DomainError). Guards every shape the
    real API can return: invalid JSON, an error-shaped HTTP 200, missing/empty
    choices, and a missing message object — none of which may crash the caller.
    """
    try:
        data = json.loads(raw_text)
    except (json.JSONDecodeError, ValueError) as exc:
        return Err(DomainError("invalid_json",
                               "The provider response is not valid JSON.",
                               str(exc)[:200]))
    if not isinstance(data, dict):
        return Err(DomainError("bad_response_shape",
                               "The provider response is not an object.",
                               str(type(data))))
    if data.get("error"):
        return Err(DomainError("api_error",
                               "The provider returned an error.",
                               str(data["error"])[:300]))
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices:
        return Err(DomainError("bad_response_shape",
                               "The response does not contain 'choices'.",
                               raw_text[:200]))
    first = choices[0]
    message = first.get("message") if isinstance(first, dict) else None
    if not isinstance(message, dict):
        return Err(DomainError("bad_response_shape",
                               "The response does not contain an assistant message.",
                               raw_text[:200]))

    content = _normalize_content(message.get("content"))
    tool_calls = _extract_tool_calls(message.get("tool_calls") or [])
    return Ok(AssistantMessage(content=content, tool_calls=tool_calls, raw=message))


def _normalize_content(content):
    """Coerce assistant content to Optional[str]. Anthropic-via-OpenRouter may
    return a list of content blocks; join their text so the shell's `.strip()`
    never receives a non-string (which would crash bubble_ai)."""
    if content is None or isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
            elif isinstance(block, str):
                parts.append(block)
        return "".join(parts) if parts else None
    return str(content)


def _extract_tool_calls(raw_calls):
    """Build sanitized ToolCalls. Coerces a null/non-dict `function` to {} (the
    chained .get() would otherwise raise AttributeError — the boundary parser
    must never crash) and synthesizes a stable id for id-less entries so the
    sent and answered tool_call ids always match."""
    out = []
    for i, tc in enumerate(raw_calls):
        if not isinstance(tc, dict):
            continue
        fn = tc.get("function")
        if not isinstance(fn, dict):
            fn = {}
        out.append(ToolCall(
            id=str(tc.get("id") or f"call_{i}"),
            name=str(fn.get("name", "")),
            arguments=str(fn.get("arguments", "")),
        ))
    return tuple(out)


def assistant_message_dict(msg: "AssistantMessage") -> dict:
    """Rebuild a spec-compliant assistant message from the PARSED (sanitized,
    id-normalized) data, so every tool_call id the shell sends is one it will
    answer. Append THIS to the conversation, not the raw provider message
    (whose tool_calls may contain unanswered/duplicate/null-id entries)."""
    d = {"role": "assistant", "content": msg.content}
    if msg.tool_calls:
        d["tool_calls"] = [
            {"id": tc.id, "type": "function",
             "function": {"name": tc.name, "arguments": tc.arguments}}
            for tc in msg.tool_calls
        ]
    return d


def classify_http_error(status: Optional[int], body: str) -> DomainError:
    """Map a non-retryable HTTP error to a typed DomainError. If the body is an
    error-shaped JSON ({"error": ...}), surface that; otherwise a generic HTTP
    error that keeps the status code (more useful than 'invalid JSON' for an
    HTML 5xx page). Pure."""
    parsed = parse_api_response(body or "")
    if is_err(parsed) and parsed.error.kind == "api_error":
        return parsed.error
    return DomainError("api_error", f"The provider returned HTTP {status}.", (body or "")[:300])


# ── Anthropic Messages API wire adapters (pure) ───────────────────────────────
# The conversation is kept in ONE canonical OpenAI shape everywhere; these pure
# converters translate to/from Anthropic's Messages API only at the request/parse
# boundary. The OpenRouter branch of build_request stays byte-identical to the
# historical payload, so the existing path cannot regress.
@dataclass(frozen=True)
class RequestSpec:
    """A ready-to-send HTTP request as pure data. The shell turns this into an
    actual urllib request; keeping it a value makes build_request unit-testable."""
    url: str
    headers: dict
    body: dict


def split_system(messages) -> Tuple[Optional[str], list]:
    """Split a canonical OpenAI message list into (system_text, other_messages).
    Anthropic takes the system prompt as a top-level `system` param, not a role.
    Multiple system messages join with blank lines. Pure; inputs not mutated."""
    system_parts = []
    rest = []
    for m in messages:
        if m.get("role") == "system":
            c = m.get("content")
            if isinstance(c, str) and c:
                system_parts.append(c)
        else:
            rest.append(m)
    return ("\n\n".join(system_parts) if system_parts else None), rest


def to_anthropic_tools(tools) -> list:
    """Convert OpenAI function-tools to Anthropic tool specs:
    {"type":"function","function":{name,description,parameters}} →
    {name,description,input_schema:parameters}. Pure."""
    out = []
    for t in tools or []:
        fn = t.get("function") if isinstance(t, dict) else None
        if not isinstance(fn, dict):
            continue
        spec = {"name": fn.get("name", ""),
                "input_schema": fn.get("parameters") or {"type": "object"}}
        if fn.get("description"):
            spec["description"] = fn["description"]
        out.append(spec)
    return out


def to_anthropic_messages(messages) -> list:
    """Convert canonical OpenAI (non-system) messages to Anthropic message blocks:
      * user      {content:str}                → {role:user, content:str}
      * assistant {content, tool_calls}        → {role:assistant, content:[text?, tool_use...]}
      * tool      {tool_call_id, content}      → folded into a {role:user,
        content:[tool_result...]} turn.
    CONSECUTIVE same-role turns are MERGED into one message: Anthropic requires
    strict user/assistant alternation, but an OpenAI-shaped history can carry two
    user turns in a row (e.g. a tool-result turn followed by a 'continue' nudge).
    Pure; inputs not mutated."""
    out = []
    pending = []  # accumulated tool_result blocks awaiting a flush

    def as_blocks(c):
        return list(c) if isinstance(c, list) else [
            {"type": "text", "text": c if isinstance(c, str) else str(c)}]

    def push(role, content):
        # Merge into the previous turn when the role repeats (keeps alternation).
        if out and out[-1]["role"] == role:
            out[-1] = {"role": role,
                       "content": as_blocks(out[-1]["content"]) + as_blocks(content)}
        else:
            out.append({"role": role, "content": content})

    def flush():
        if pending:
            push("user", list(pending))
            pending.clear()

    for m in messages:
        role = m.get("role")
        if role == "tool":
            pending.append({"type": "tool_result",
                            "tool_use_id": m.get("tool_call_id", ""),
                            "content": m.get("content", "") or ""})
            continue
        flush()  # any non-tool message closes an open group of tool_results
        if role == "assistant":
            blocks = []
            content = m.get("content")
            if isinstance(content, str) and content.strip():
                blocks.append({"type": "text", "text": content})
            for tc in m.get("tool_calls") or []:
                fn = tc.get("function") if isinstance(tc, dict) else None
                if not isinstance(fn, dict):
                    continue
                try:
                    tool_input = json.loads(fn.get("arguments") or "{}")
                except (json.JSONDecodeError, ValueError):
                    tool_input = {}
                if not isinstance(tool_input, dict):
                    tool_input = {}
                blocks.append({"type": "tool_use", "id": tc.get("id", ""),
                               "name": fn.get("name", ""), "input": tool_input})
            if not blocks:  # defensive: Anthropic rejects an empty assistant turn
                blocks.append({"type": "text", "text": content if isinstance(content, str) else " "})
            push("assistant", blocks)
        else:
            push("user", m.get("content"))
    flush()
    return out


def build_request(provider, model, api_key, messages, tools,
                  max_tokens=None, referer=None, title=None) -> RequestSpec:
    """Build the HTTP RequestSpec for one assistant completion. The OpenRouter
    branch is BYTE-IDENTICAL to the historical request; the Anthropic branch hoists
    the system prompt, converts tools/messages, and sets the required max_tokens +
    tool_choice. Pure: no I/O, returns a value. Localizes ALL wire divergence."""
    if provider == PROVIDER_ANTHROPIC:
        system_text, convo = split_system(messages)
        body = {
            "model": model,
            "max_tokens": max_tokens or ANTHROPIC_MAX_TOKENS,
            "messages": to_anthropic_messages(convo),
            "tools": to_anthropic_tools(tools),
            "tool_choice": {"type": "auto"},
        }
        if system_text:
            body["system"] = system_text
        headers = {"x-api-key": api_key,
                   "anthropic-version": ANTHROPIC_VERSION,
                   "content-type": "application/json"}
        return RequestSpec("https://api.anthropic.com/v1/messages", headers, body)
    # OpenRouter (default) — identical to the original _fetch_completion payload.
    headers = {"Authorization": f"Bearer {api_key}",
               "Content-Type": "application/json",
               "HTTP-Referer": referer or "https://bugtraceai.com",
               "X-Title": title or "BugTraceAI Setup & Repair Assistant"}
    body = {"model": model, "messages": messages, "tools": tools, "tool_choice": "auto"}
    return RequestSpec("https://openrouter.ai/api/v1/chat/completions", headers, body)


def parse_anthropic_response(raw_text: str):
    """Parse an Anthropic Messages API response body into the SAME
    Ok(AssistantMessage)/Err(DomainError) the OpenRouter parser returns. Anthropic
    shape: {content:[{type:text,text}|{type:tool_use,id,name,input:{...}}], ...} or
    an error {type:error, error:{...}}. Emits identical DomainError kinds so the
    retry/fallback policy stays provider-agnostic. Never raises."""
    try:
        data = json.loads(raw_text)
    except (json.JSONDecodeError, ValueError) as exc:
        return Err(DomainError("invalid_json",
                               "The provider response is not valid JSON.",
                               str(exc)[:200]))
    if not isinstance(data, dict):
        return Err(DomainError("bad_response_shape",
                               "The provider response is not an object.",
                               str(type(data))))
    if data.get("type") == "error" or data.get("error"):
        return Err(DomainError("api_error",
                               "The provider returned an error.",
                               str(data.get("error") or data)[:300]))
    blocks = data.get("content")
    if not isinstance(blocks, list):
        return Err(DomainError("bad_response_shape",
                               "The response does not contain 'content'.",
                               raw_text[:200]))
    text_parts, tool_calls = [], []
    for i, block in enumerate(blocks):
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text" and isinstance(block.get("text"), str):
            text_parts.append(block["text"])
        elif btype == "tool_use":
            tool_input = block.get("input")
            if not isinstance(tool_input, dict):
                tool_input = {}
            tool_calls.append(ToolCall(id=str(block.get("id") or f"call_{i}"),
                                       name=str(block.get("name", "")),
                                       arguments=json.dumps(tool_input)))
    content = "".join(text_parts) if text_parts else None
    return Ok(AssistantMessage(content=content, tool_calls=tuple(tool_calls), raw=data))


def validation_request(provider, api_key) -> Tuple[str, dict]:
    """The pure (url, headers) to cheaply validate a key for `provider` with a GET.
    OpenRouter: /api/v1/key (Bearer). Anthropic: /v1/models (x-api-key +
    anthropic-version) — auth-only, spends no tokens. The shell GETs it and treats
    HTTP 200 as valid. Pure."""
    if provider == PROVIDER_ANTHROPIC:
        return ("https://api.anthropic.com/v1/models",
                {"x-api-key": api_key, "anthropic-version": ANTHROPIC_VERSION})
    return ("https://openrouter.ai/api/v1/key",
            {"Authorization": f"Bearer {api_key}",
             "HTTP-Referer": "https://bugtraceai.com",
             "X-Title": "BugTraceAI Setup & Repair Assistant"})


def parse_response(provider, raw_text: str):
    """Dispatch to the provider's response parser. Keeps the shell's retry loop
    provider-agnostic — it calls parse_response(provider, body) and everything
    downstream (AssistantMessage, tool dispatch) is identical. Pure."""
    if provider == PROVIDER_ANTHROPIC:
        return parse_anthropic_response(raw_text)
    return parse_api_response(raw_text)


# ── Verification spec (pure data) ─────────────────────────────────────────────
@dataclass(frozen=True)
class Check:
    label: str
    command: str
    predicate: str  # one of: rc0_nonempty | nonempty | health | http200 | exists
    critical: bool = True


def evaluate_check(predicate: str, rc: int, out: str) -> bool:
    """Pure predicate evaluation for a verification Check. Separating *what* to
    check (the immutable Check list) from *running* it (the shell's run_fn) keeps
    this logic testable without Docker."""
    text = out.strip()
    if predicate == "rc0_nonempty":
        return rc == 0 and bool(text)
    if predicate == "nonempty":
        return bool(text)
    if predicate == "health":
        low = out.lower()
        return rc == 0 and (not text or any(token in low for token in HEALTHY_TOKENS))
    if predicate == "http200":
        return text == "200"
    if predicate == "exists":
        return text == "exists"
    return False


def verification_checks(mode: str, install_dir: str) -> Tuple[Check, ...]:
    """The verification plan as immutable data, derived purely from the install
    mode and directory. The shell iterates this, runs each command, and applies
    evaluate_check."""
    checks = [
        Check("Docker daemon",
              "docker info --format '{{.ServerVersion}}' 2>/dev/null",
              "rc0_nonempty"),
    ]
    if mode in ("full", "cli"):
        checks += [
            Check("CLI container (bugtrace_api)",
                  "docker ps --filter 'name=^bugtrace_api$' --format '{{.Names}} {{.Status}}'",
                  "nonempty"),
            Check("CLI health (localhost:8000)",
                  "curl -sf --max-time 5 http://localhost:8000/health 2>/dev/null",
                  "health"),
            Check("CLI configuration (.env)",
                  f"test -f {install_dir}/BugTraceAI-CLI/.env && echo exists",
                  "exists"),
        ]
    if mode in ("full", "web"):
        for cname, label in (
            ("bugtraceai-web-db", "PostgreSQL WEB"),
            ("bugtraceai-web-backend", "Backend WEB"),
            ("bugtraceai-web-frontend", "Frontend WEB"),
        ):
            checks.append(Check(
                f"{label} ({cname})",
                f"docker ps --filter 'name=^{cname}$' --format '{{{{.Names}}}} {{{{.Status}}}}'",
                "nonempty"))
        checks += [
            Check("WEB frontend (localhost:6869)",
                  "curl -sf --max-time 5 -o /dev/null -w '%{http_code}' http://localhost:6869 2>/dev/null",
                  "http200"),
            Check("WEB configuration (.env.docker)",
                  f"test -f {install_dir}/BugTraceAI-WEB/.env.docker && echo exists",
                  "exists"),
        ]
    return tuple(checks)


# ── System prompt (pure) ──────────────────────────────────────────────────────
@dataclass(frozen=True)
class PromptSpec:
    mode: str          # full | cli | web
    action: str        # install | repair
    install_dir: str
    api_key: str
    cli_repo: str
    web_repo: str
    max_turns: int
    provider: str = "openrouter"   # openrouter | anthropic — configures the deployed CLI


def build_system_prompt(spec: PromptSpec) -> str:
    """Build the agent system prompt. Pure: all dependencies (repos, key, dir,
    turn budget) are injected via PromptSpec, none read from globals."""
    install_dir = spec.install_dir
    cli_playbook = web_playbook = cli_verify = web_verify = ""

    # Provider-aware deployment: which .env key var the deployed CLI reads, and
    # (for a non-OpenRouter provider) the command that selects its preset in the
    # conf. Default 'openrouter' reproduces the historical prompt exactly.
    key_env = cli_key_env(spec.provider)
    provider_label = {"openrouter": "OPENROUTER", "anthropic": "ANTHROPIC",
                      "zai": "GLM/Z.AI"}.get(spec.provider, "OPENROUTER")
    provider_select_step = "" if spec.provider == "openrouter" else (
        f"4b. Point the deployed CLI at the {spec.provider} provider (it reads\n"
        f"    [PROVIDER] ACTIVE from bugtraceaicli.conf, which ships as openrouter):\n"
        f"     {cli_conf_patch_command(spec.provider)}\n"
    )

    if spec.mode in ("full", "cli"):
        cli_playbook = f"""
STEP 1: INSTALL CLI
1. mkdir -p {install_dir} && cd {install_dir}
2. git clone --depth 1 {spec.cli_repo} BugTraceAI-CLI
3. cd BugTraceAI-CLI
4. Create the .env file with this EXACT content (use cat << 'EOF' > .env):
     {key_env}={spec.api_key}
     BUGTRACE_CORS_ORIGINS=*
   Then harden it: chmod 600 .env   (the file holds a secret).
{provider_select_step}5. Build and start (this takes 5-15 min on first run):
     docker compose up -d --build
6. Inspect build/startup output WITHOUT following forever:
     docker compose logs --tail=30
   (Never use -f/--follow — it blocks indefinitely.)
   Wait until you see "Application startup complete" or similar.
7. Verify health:
     curl -sf http://localhost:8000/health
   Must return {{"status":"healthy"}}. Retry every 15 seconds, up to 5 minutes.

Expected containers after CLI install:
  - bugtrace_api (port 8000) — FastAPI scanner API
  - bugtrace_mcp (port 8001) — MCP SSE server (depends on bugtrace_api health)
"""
        cli_verify = """
CLI checks:
  - Container bugtrace_api is Up
  - curl http://localhost:8000/health returns {"status":"healthy"}
  - File {install_dir}/BugTraceAI-CLI/.env exists
""".replace("{install_dir}", install_dir)

    if spec.mode in ("full", "web"):
        step_num = "2" if spec.mode == "full" else "1"
        web_playbook = f"""
STEP {step_num}: INSTALL WEB
1. cd {install_dir}
2. git clone --depth 1 {spec.web_repo} BugTraceAI-WEB
3. cd BugTraceAI-WEB
4. Generate a random password and create .env.docker (use cat << EOF > .env.docker):
     POSTGRES_USER=bugtraceai
     POSTGRES_PASSWORD=<generate a random 24-char alphanumeric password>
     POSTGRES_DB=bugtraceai_web
     FRONTEND_PORT=6869
     VITE_CLI_API_URL=/cli-api
   Then harden it: chmod 600 .env.docker   (it holds the DB password).
5. Build and start (this takes 5-10 min on first run):
     docker compose --env-file .env.docker up -d --build
6. Inspect progress WITHOUT following forever:
     docker compose --env-file .env.docker logs --tail=30
   (Never use -f/--follow.)
7. Verify:
     curl -sf -o /dev/null -w '%{{http_code}}' http://localhost:6869
   Must return 200. Retry every 15 seconds, up to 5 minutes.

Expected containers after WEB install:
  - bugtraceai-web-db (PostgreSQL on port 5432)
  - bugtraceai-web-backend (Express on port 3001)
  - bugtraceai-web-frontend (nginx on port 6869)
"""
        web_verify = """
WEB checks:
  - Containers bugtraceai-web-db, bugtraceai-web-backend, bugtraceai-web-frontend are Up
  - curl http://localhost:6869 returns HTTP 200
  - File {install_dir}/BugTraceAI-WEB/.env.docker exists
""".replace("{install_dir}", install_dir)

    mode_label = {"full": "Full Platform (WEB + CLI)", "cli": "CLI Only", "web": "WEB Only"}[spec.mode]
    action_label = ("REPAIR / TROUBLESHOOT EXISTING INSTALLATION"
                    if spec.action == "repair" else "INSTALL NEW DEPLOYMENT")
    if spec.action == "repair":
        action_instructions = f"""ACTION: {action_label}

REPAIR MODE RULES:
- Do NOT reinstall immediately.
- First inspect containers, logs, ports, disk space, Docker status, and env files.
- Prefer small fixes: restart services, rebuild one stack, repair env/config, explain what failed.
- Ask the user before deleting containers, volumes, databases, or reinstalling from scratch.
"""
    else:
        action_instructions = f"""ACTION: {action_label}

INSTALL MODE RULES:
- Follow the installation playbook in order.
- If an existing deployment is detected, ask the user before replacing or reinstalling it.
"""

    bar = "=" * 60
    return f"""You are the BugTraceAI Autonomous Setup & Repair agent.
You have root shell access via the run_command tool. Beyond installing, you
also diagnose and fix problems with an existing deployment (failed services,
database connectivity, Docker, ports, env/config) when the user asks.

{action_instructions}
INSTALL MODE: {mode_label}
INSTALL DIRECTORY: {install_dir}
{provider_label} API KEY: {spec.api_key}

You ALREADY have the API key above. Do NOT ask the user for it again.

{bar}
INSTALLATION PLAYBOOK — Follow these steps IN ORDER
{bar}

STEP 0: SYSTEM ASSESSMENT (do this first, silently)
- Run: uname -a && cat /etc/os-release 2>/dev/null && free -h && df -h /
- Check Docker: docker --version && docker compose version
- If Docker is NOT installed:
  a. curl -fsSL https://get.docker.com | sudo sh
  b. sudo usermod -aG docker $USER
  c. sudo systemctl enable docker && sudo systemctl start docker
  d. newgrp docker  (or use sudo for docker commands)
- If docker compose is not available:
  a. Try: sudo apt-get install -y docker-compose-plugin
  b. Or download binary from GitHub
- Check if {install_dir} already exists. If BugTraceAI containers are running,
  use ask_user to confirm reinstall before proceeding.
{cli_playbook}{web_playbook}
{bar}
VERIFICATION — What the system checks when you call finish
{bar}
{cli_verify}{web_verify}
When you believe everything is running, call finish(summary).
The system runs automated verification. If any check fails, you get the results
and MUST fix the issues, then call finish again.

{bar}
RULES
{bar}
1. Shell is STATEFUL: cd and env vars persist between run_command calls.
2. Always use non-interactive flags: apt-get install -y, DEBIAN_FRONTEND=noninteractive.
3. NEVER run destructive commands (rm -rf /, database drops) without ask_user.
4. All messages to the user MUST be in English unless the user asks otherwise.
5. Use ask_user ONLY for genuine choices (e.g. reinstall confirmation).
6. Be efficient. You have {spec.max_turns} turns maximum.
7. When a command returns exit code 124, it was killed by timeout.
   Docker builds have a long timeout, other commands a short one.
8. NEVER use -f/--follow with `logs` — it blocks forever. Use --tail=N.
9. Any .env file you create MUST be chmod 600 (it holds secrets).
10. After verification passes, remain available for troubleshooting.
11. Keep messages brief and informative. No walls of text.
12. If a docker build fails, check disk space and RAM first.
"""
