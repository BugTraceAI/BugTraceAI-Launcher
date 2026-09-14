#!/usr/bin/env python3
"""Runtime helpers shared by the interactive BugTraceAI AI assistant.

This module deliberately has no terminal UI of its own.  It holds the two
stateful pieces that were previously duplicated or implicit in
``ai_installer.py``:

* ``AgentLoop`` advances a tool-calling conversation until the assistant has
  a normal reply for the user, instead of stopping after every shell command.
* ``PrivilegeSession`` owns the operating system's temporary sudo ticket
  without ever retaining the user's password.

Keeping these pieces separate makes their behaviour testable without calling a
real LLM, Docker daemon, or sudo binary.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import os
import re
import subprocess
import threading
from typing import Any, Callable, Optional


class LoopOutcome(str, Enum):
    """The point at which an agent-driving pass paused."""

    WAITING_FOR_USER = "waiting_for_user"
    FINISHED = "finished"
    TURN_LIMIT = "turn_limit"
    ERROR = "error"


@dataclass(frozen=True)
class ToolOutcome:
    """One tool result plus whether it completed the current workflow."""

    message: dict
    finished: bool = False


# Installer-phase nudge: a status sentence is not a reason to wait for Enter.
CONTINUE_NUDGE = "Continue with the next concrete tool call. Do not wait for a reply."

# Phrases that mean the model is asking the human, even with wait_on_text=False.
# Keep this conservative: a status line like "Checking which image to pull"
# must not pause the installer.
_QUESTION_PHRASES = (
    "would you",
    "do you want",
    "should i",
    "shall i",
    "please confirm",
    "is that ok",
    "what would you like",
    "how would you like",
)


def looks_like_user_question(text: str) -> bool:
    """True when assistant text is a real question, not a status line."""
    stripped = (text or "").strip()
    if not stripped:
        return False
    if "?" in stripped:
        return True
    lowered = stripped.lower()
    return any(phrase in lowered for phrase in _QUESTION_PHRASES)


def wrap_readline_prompt(prompt: str) -> str:
    """Mark ANSI CSI sequences as zero-width so GNU readline can backspace.

    Without this, colored prompts make Backspace reprint the line and leave
    ``^H`` on terminals whose erase character does not match the key.
    """
    out = []
    i = 0
    n = len(prompt or "")
    while i < n:
        if prompt[i] == "\x1b" and i + 1 < n and prompt[i + 1] == "[":
            j = i + 2
            while j < n and not ("A" <= prompt[j] <= "Z" or "a" <= prompt[j] <= "z"):
                j += 1
            if j < n:
                out.append("\x01" + prompt[i:j + 1] + "\x02")
                i = j + 1
                continue
        out.append(prompt[i])
        i += 1
    return "".join(out)

# sudo -n in a new session cannot reuse Ubuntu tty_tickets.  Match the strings
# sudo actually prints so the installer can re-prompt on the real TTY instead
# of feeding "password is required" back to the model in a loop.
_SUDO_TICKET_UNUSABLE = (
    "a password is required",
    "no tty present",
    "a terminal is required to read the password",
    "sudo: no askpass program specified",
)


def sudo_ticket_unusable(output: str) -> bool:
    """True when sudo -n failed because it could not see the cached ticket."""
    text = (output or "").lower()
    return any(marker in text for marker in _SUDO_TICKET_UNUSABLE)


def spawn_killable_process(argv, **popen_kwargs):
    """Spawn a child that timeout-kill can reap without dropping the TTY.

    ``start_new_session=True`` (setsid) creates a new session with no
    controlling terminal, so a later ``sudo -n`` cannot use the ticket
    obtained by ``sudo -v`` on the installer TTY.  A new process group in
    the same session stays on that TTY and is still ``killpg``-able.

    stdin defaults to DEVNULL so a background process group does not stop
    on SIGTTIN if the command tries to read the terminal.
    """
    kwargs = dict(popen_kwargs)
    kwargs.pop("start_new_session", None)
    kwargs.setdefault("stdin", subprocess.DEVNULL)
    kwargs["preexec_fn"] = os.setpgrp
    return subprocess.Popen(argv, **kwargs)


class AgentLoop:
    """Drive one assistant task until it needs actual user input.

    ``request`` returns the project's ``Ok(AssistantMessage)`` / ``Err``
    values.  The loop does not know about providers, terminal rendering, or
    concrete tools; those remain injected callbacks.  Real questions go through
    the ``ask_user`` tool (the dispatcher blocks), not through a text pause.
    """

    def __init__(
        self,
        messages: list,
        request: Callable[[], Any],
        is_error: Callable[[Any], bool],
        assistant_message: Callable[[Any], dict],
        dispatch_tool: Callable[[Any], ToolOutcome],
        render_assistant: Callable[[str], None],
        on_error: Callable[[Any], None],
        on_turn: Optional[Callable[[int, int], None]] = None,
    ):
        self.messages = messages
        self._request = request
        self._is_error = is_error
        self._assistant_message = assistant_message
        self._dispatch_tool = dispatch_tool
        self._render_assistant = render_assistant
        self._on_error = on_error
        self._on_turn = on_turn
        self.turns_used = 0

    def advance(self, max_turns: int, wait_on_text: bool = True) -> LoopOutcome:
        """Keep requesting the model after every tool result.

        ``wait_on_text=False`` is the installer: a status line is shown, then
        the model is nudged to call the next tool.  Enter is not a continue
        key.  ``wait_on_text=True`` is post-verify support, where a text reply
        is an answer and the human types next.
        """
        for turn in range(self.turns_used + 1, max_turns + 1):
            self.turns_used = turn
            if self._on_turn is not None:
                self._on_turn(turn, max_turns)

            result = self._request()
            if self._is_error(result):
                self._on_error(result.error)
                return LoopOutcome.ERROR

            msg = result.value
            if msg.content:
                self._render_assistant(msg.content)

            if msg.tool_calls:
                self.messages.append(self._assistant_message(msg))
                for tool_call in msg.tool_calls:
                    outcome = self._dispatch_tool(tool_call)
                    self.messages.append(outcome.message)
                    # Successful finish is terminal for this pass.  Later calls
                    # in the same response must not mutate a verified install.
                    if outcome.finished:
                        return LoopOutcome.FINISHED
                continue

            if msg.content:
                self.messages.append(self._assistant_message(msg))
                if wait_on_text or looks_like_user_question(msg.content):
                    return LoopOutcome.WAITING_FOR_USER
                self.messages.append({"role": "user", "content": CONTINUE_NUDGE})
                continue

            # Empty assistant payloads are invalid on the wire; nudge instead.
            self.messages.append({"role": "user", "content": CONTINUE_NUDGE})

        return LoopOutcome.TURN_LIMIT


class PrivilegeSession:
    """Maintain a temporary sudo ticket without ever storing a password.

    Authentication uses the native sudo prompt on the controlling terminal.
    Later commands use ``sudo -n`` and therefore return a normal error instead
    of blocking in a pipe when the ticket has expired.  A lightweight refresher
    keeps a valid ticket alive only while this launcher process is active.
    """

    def __init__(self, refresh_seconds: int = 120):
        self.refresh_seconds = max(30, refresh_seconds)
        self._active = os.geteuid() == 0
        self._owns_ticket = False
        self._needs_reauth = False
        self._closed = threading.Event()
        self._lock = threading.Lock()
        self._refresher: Optional[threading.Thread] = None

    @property
    def active(self) -> bool:
        return self._active and not self._needs_reauth

    @property
    def needs_reauth(self) -> bool:
        return self._needs_reauth

    def authenticate(self) -> bool:
        """Request sudo visibly on the real terminal, if needed."""
        if os.geteuid() == 0:
            self._active = True
            self._needs_reauth = False
            return True
        try:
            # Do not redirect stdin/stdout/stderr.  The user must see sudo's
            # native password prompt and sudo itself controls echo safely.
            result = subprocess.run(["sudo", "-v"])
        except OSError:
            self._active = False
            self._needs_reauth = True
            return False

        if result.returncode != 0:
            self._active = False
            self._needs_reauth = True
            return False

        with self._lock:
            self._active = True
            self._needs_reauth = False
            self._owns_ticket = True
            if self._refresher is None or not self._refresher.is_alive():
                self._refresher = threading.Thread(
                    target=self._refresh_loop,
                    name="bugtraceai-sudo-refresh",
                    daemon=True,
                )
                self._refresher.start()
        return True

    def ensure(self) -> bool:
        """Return a valid ticket, bringing up a visible prompt when required."""
        if os.geteuid() == 0:
            return True
        if self._needs_reauth or not self._active:
            return self.authenticate()
        if self._check_ticket():
            return True
        self._needs_reauth = True
        return self.authenticate()

    def _check_ticket(self) -> bool:
        try:
            result = subprocess.run(
                ["sudo", "-n", "-v"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return result.returncode == 0
        except OSError:
            return False

    def _refresh_loop(self) -> None:
        while not self._closed.wait(self.refresh_seconds):
            if not self._check_ticket():
                self._needs_reauth = True
                self._active = False
                return

    def close(self) -> None:
        """Stop refresh work and revoke the ticket created for this run."""
        with self._lock:
            if self._closed.is_set():
                return
            self._closed.set()
            owns_ticket = self._owns_ticket
            self._owns_ticket = False
        refresher = self._refresher
        if refresher is not None and refresher.is_alive():
            refresher.join(timeout=1)
        if owns_ticket and os.geteuid() != 0:
            try:
                subprocess.run(
                    ["sudo", "-k"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except OSError:
                pass
        self._active = False
        self._needs_reauth = True


def rewrite_service_host_port(compose_path: str, container_name: str, host_port: int) -> bool:
    """Assign a Compose service an available host port without assuming its
    container port.  The container side is read from the service's current
    mapping and only the host side is replaced.

    The parser is deliberately narrow: it handles the ordinary quoted/unquoted
    scalar port mappings emitted by BugTraceAI's Compose files and declines an
    unfamiliar structure instead of guessing or rewriting unrelated services.
    """
    try:
        with open(compose_path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return False

    def indent_of(line: str) -> int:
        return len(line) - len(line.lstrip(" \t"))

    service_starts = [
        i for i, line in enumerate(lines)
        if indent_of(line) == 2 and line.strip().endswith(":")
        and not line.lstrip().startswith("#")
    ]
    for position, start in enumerate(service_starts):
        end = service_starts[position + 1] if position + 1 < len(service_starts) else len(lines)
        block = "".join(lines[start:end])
        name_pattern = (r"(?m)^[ \t]+container_name:\s*[\"']?"
                        + re.escape(container_name) + r"[\"']?\s*(?:#.*)?$")
        if not re.search(name_pattern, block):
            continue

        for i in range(start, end):
            if lines[i].strip() != "ports:":
                continue
            ports_indent = indent_of(lines[i])
            for j in range(i + 1, end):
                stripped = lines[j].strip()
                if stripped and not stripped.startswith("#") and indent_of(lines[j]) <= ports_indent:
                    break
                match = re.match(
                    r"^(?P<prefix>\s*-\s*)(?P<quote>[\"']?)(?P<spec>[^\"'#\s]+)"
                    r"(?P=quote)(?P<suffix>\s*(?:#.*)?\n?)$", lines[j])
                if not match:
                    continue
                _, separator, container_port = match.group("spec").rpartition(":")
                if not separator or not container_port.isdigit():
                    continue
                lines[j] = (f"{match.group('prefix')}{match.group('quote')}"
                            f"{host_port}:{container_port}{match.group('quote')}"
                            f"{match.group('suffix')}")
                try:
                    with open(compose_path, "w", encoding="utf-8") as f:
                        f.writelines(lines)
                except OSError:
                    return False
                return True
    return False


def rewrite_web_cli_proxy(nginx_path: str, cli_port: int) -> bool:
    """Point the WEB nginx CLI proxy at a resolved local CLI host endpoint."""
    try:
        with open(nginx_path, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return False
    updated, changed = re.subn(
        r"(?m)^(?P<prefix>\s*proxy_pass\s+http://host\.docker\.internal:)\d+(?P<suffix>/;\s*)$",
        lambda match: f"{match.group('prefix')}{cli_port}{match.group('suffix')}",
        content,
        count=1,
    )
    if changed != 1:
        return False
    try:
        with open(nginx_path, "w", encoding="utf-8") as f:
            f.write(updated)
    except OSError:
        return False
    return True
