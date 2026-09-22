"""Unit tests for the autonomous, provider-agnostic agent runtime."""
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import installer_core as core
from assistant_runtime import (
    CONTINUE_NUDGE, AgentLoop, LoopOutcome, ToolOutcome,
    looks_like_user_question, rewrite_service_host_port, rewrite_web_cli_proxy,
    spawn_killable_process, sudo_ticket_unusable, wrap_readline_prompt,
)


def message(content=None, tool_calls=()):
    return core.AssistantMessage(content=content, tool_calls=tool_calls, raw={})


class TestAgentLoop(unittest.TestCase):
    def make_loop(self, results, dispatch):
        messages = [
            {"role": "system", "content": "system"},
            {"role": "user", "content": "start"},
        ]
        rendered, errors, turns = [], [], []

        def request():
            return results.pop(0)

        loop = AgentLoop(
            messages=messages,
            request=request,
            is_error=core.is_err,
            assistant_message=core.assistant_message_dict,
            dispatch_tool=dispatch,
            render_assistant=rendered.append,
            on_error=errors.append,
            on_turn=lambda turn, limit: turns.append((turn, limit)),
        )
        return loop, messages, rendered, errors, turns

    def test_tools_continue_automatically_until_text_needs_user(self):
        tool = core.ToolCall("call-1", "run_command", '{"command":"true"}')
        dispatched = []

        def dispatch(call):
            dispatched.append(call.name)
            return ToolOutcome({"role": "tool", "tool_call_id": call.id,
                                "name": call.name, "content": "Exit code: 0"})

        loop, messages, rendered, errors, turns = self.make_loop([
            core.Ok(message(tool_calls=(tool,))),
            core.Ok(message("The check is complete.")),
        ], dispatch)

        self.assertEqual(loop.advance(4), LoopOutcome.WAITING_FOR_USER)
        self.assertEqual(dispatched, ["run_command"])
        self.assertEqual(rendered, ["The check is complete."])
        self.assertEqual(errors, [])
        self.assertEqual(turns, [(1, 4), (2, 4)])
        self.assertEqual([item["role"] for item in messages],
                         ["system", "user", "assistant", "tool", "assistant"])

    def test_finished_tool_stops_later_calls_in_same_response(self):
        finish = core.ToolCall("finish", "finish", '{"summary":"done"}')
        unsafe_later_call = core.ToolCall("later", "run_command", '{"command":"false"}')
        dispatched = []

        def dispatch(call):
            dispatched.append(call.name)
            return ToolOutcome({"role": "tool", "tool_call_id": call.id,
                                "name": call.name, "content": "verified"},
                               finished=call.name == "finish")

        loop, messages, _, _, _ = self.make_loop([
            core.Ok(message(tool_calls=(finish, unsafe_later_call))),
        ], dispatch)

        self.assertEqual(loop.advance(2), LoopOutcome.FINISHED)
        self.assertEqual(dispatched, ["finish"])
        self.assertEqual([item["role"] for item in messages],
                         ["system", "user", "assistant", "tool"])

    def test_empty_response_is_nudged_without_waiting_for_user(self):
        def dispatch(_):
            self.fail("no tool should be dispatched")

        loop, messages, rendered, _, _ = self.make_loop([
            core.Ok(message()),
            core.Ok(message("Continuing now.")),
        ], dispatch)

        self.assertEqual(loop.advance(3), LoopOutcome.WAITING_FOR_USER)
        self.assertEqual(rendered, ["Continuing now."])
        self.assertIn(CONTINUE_NUDGE, [item.get("content") for item in messages])

    def test_installer_status_line_does_not_wait_for_enter(self):
        finish = core.ToolCall("finish", "finish", '{"summary":"done"}')
        dispatched = []

        def dispatch(call):
            dispatched.append(call.name)
            return ToolOutcome({"role": "tool", "tool_call_id": call.id,
                                "name": call.name, "content": "verified"},
                               finished=call.name == "finish")

        loop, messages, rendered, errors, turns = self.make_loop([
            core.Ok(message("Checking Docker next.")),
            core.Ok(message(tool_calls=(finish,))),
        ], dispatch)

        self.assertEqual(loop.advance(4, wait_on_text=False), LoopOutcome.FINISHED)
        self.assertEqual(dispatched, ["finish"])
        self.assertEqual(rendered, ["Checking Docker next."])
        self.assertEqual(errors, [])
        self.assertEqual(turns, [(1, 4), (2, 4)])
        self.assertIn(CONTINUE_NUDGE, [item.get("content") for item in messages])

    def test_installer_text_only_hits_turn_limit_instead_of_waiting(self):
        def dispatch(_):
            self.fail("no tool should be dispatched")

        loop, _, rendered, _, _ = self.make_loop([
            core.Ok(message("Working...")),
            core.Ok(message("Still working...")),
        ], dispatch)

        self.assertEqual(loop.advance(2, wait_on_text=False), LoopOutcome.TURN_LIMIT)
        self.assertEqual(rendered, ["Working...", "Still working..."])

    def test_installer_question_waits_even_when_status_does_not(self):
        def dispatch(_):
            self.fail("no tool should be dispatched")

        loop, messages, rendered, _, _ = self.make_loop([
            core.Ok(message("Should I reinstall the existing stack?")),
        ], dispatch)

        self.assertEqual(loop.advance(4, wait_on_text=False), LoopOutcome.WAITING_FOR_USER)
        self.assertEqual(rendered, ["Should I reinstall the existing stack?"])
        self.assertNotIn(CONTINUE_NUDGE, [item.get("content") for item in messages])

    def test_provider_error_returns_error_outcome(self):
        seen = []

        def dispatch(_):
            self.fail("no tool should be dispatched")

        loop, _, _, errors, _ = self.make_loop([
            core.Err(core.DomainError("network", "offline")),
        ], dispatch)
        self.assertEqual(loop.advance(1), LoopOutcome.ERROR)
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0].kind, "network")


class TestDynamicEndpointWiring(unittest.TestCase):
    def test_rewrites_only_the_target_service_host_port(self):
        compose = """services:
  api:
    container_name: bugtrace_api
    ports:
      - \"8000:8000\"
  mcp:
    container_name: bugtrace_mcp
    ports:
      - \"8001:8001\"
"""
        with tempfile.TemporaryDirectory() as tmp:
            compose_path = os.path.join(tmp, "docker-compose.yml")
            with open(compose_path, "w", encoding="utf-8") as f:
                f.write(compose)
            self.assertTrue(rewrite_service_host_port(
                compose_path, "bugtrace_api", 41234))
            with open(compose_path, encoding="utf-8") as f:
                rewritten = f.read()

        self.assertIn('"41234:8000"', rewritten)
        self.assertIn('"8001:8001"', rewritten)

    def test_rewrites_web_proxy_and_declines_unknown_shape(self):
        nginx = """server {
    location ^~ /cli-api/ {
        proxy_pass http://host.docker.internal:8000/;
    }
}
"""
        with tempfile.TemporaryDirectory() as tmp:
            nginx_path = os.path.join(tmp, "nginx.conf")
            with open(nginx_path, "w", encoding="utf-8") as f:
                f.write(nginx)
            self.assertTrue(rewrite_web_cli_proxy(nginx_path, 41234))
            with open(nginx_path, encoding="utf-8") as f:
                rewritten = f.read()
            missing_path = os.path.join(tmp, "missing.conf")
            self.assertFalse(rewrite_web_cli_proxy(missing_path, 41234))

        self.assertIn("host.docker.internal:41234/", rewritten)


class TestWrapReadlinePrompt(unittest.TestCase):
    def test_ansi_sequences_are_marked_zero_width(self):
        wrapped = wrap_readline_prompt("\033[1;32mYou\033[0m > ")
        self.assertIn("\x01\033[1;32m\x02", wrapped)
        self.assertIn("\x01\033[0m\x02", wrapped)
        self.assertIn("You", wrapped)
        self.assertTrue(wrapped.endswith(" > "))

    def test_plain_prompt_unchanged(self):
        self.assertEqual(wrap_readline_prompt("You > "), "You > ")


class TestLooksLikeUserQuestion(unittest.TestCase):
    def test_status_line_is_not_a_question(self):
        self.assertFalse(looks_like_user_question("Checking Docker next."))
        self.assertFalse(looks_like_user_question("Checking which image to pull"))

    def test_question_mark_or_ask_phrase_is_a_question(self):
        self.assertTrue(looks_like_user_question("Should I reinstall?"))
        self.assertTrue(looks_like_user_question("Do you want the Kali toolbox as well"))


class TestSudoTicketHelpers(unittest.TestCase):
    def test_password_required_is_unusable_ticket(self):
        self.assertTrue(sudo_ticket_unusable("sudo: a password is required"))
        self.assertFalse(sudo_ticket_unusable("permission denied while trying to connect"))

    def test_killable_child_keeps_session_and_separate_pgrp(self):
        proc = spawn_killable_process(
            [sys.executable, "-c",
             "import os, time, sys; "
             "print(os.getsid(0), os.getpgrp(), flush=True); "
             "time.sleep(30)"],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            line = proc.stdout.readline()
            sid, pgrp = (int(part) for part in line.split())
            self.assertEqual(sid, os.getsid(0))
            self.assertNotEqual(pgrp, os.getpgrp())
            self.assertEqual(pgrp, proc.pid)
            self.assertIsNone(proc.stdin)
        finally:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            if proc.stdout is not None:
                proc.stdout.close()
            proc.wait(timeout=5)


class TestPrivilegeSession(unittest.TestCase):
    @patch("assistant_runtime.os.geteuid", return_value=1000)
    @patch("assistant_runtime.subprocess.run")
    def test_native_authentication_is_visible_and_ticket_revoked_once(self, run, _geteuid):
        run.return_value = type("Result", (), {"returncode": 0})()
        from assistant_runtime import PrivilegeSession

        session = PrivilegeSession(refresh_seconds=999)
        self.assertTrue(session.authenticate())
        first_call = run.call_args_list[0]
        self.assertEqual(first_call.args[0], ["sudo", "-v"])
        self.assertNotIn("stdin", first_call.kwargs)
        self.assertNotIn("stdout", first_call.kwargs)
        self.assertNotIn("stderr", first_call.kwargs)

        session.close()
        session.close()
        revoke_calls = [call for call in run.call_args_list if call.args[0] == ["sudo", "-k"]]
        self.assertEqual(len(revoke_calls), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
