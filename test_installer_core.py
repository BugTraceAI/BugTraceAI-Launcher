#!/usr/bin/env python3
"""
Unit + property tests for installer_core (the pure functional core).

Run:  python3 -m unittest test_installer_core -v
      python3 test_installer_core.py

No external dependencies (stdlib unittest). Property tests use random with a
fixed seed *inside the test* — randomness at the test boundary is fine; the
functions under test remain pure and deterministic.
"""
import json
import random
import unittest

import installer_core as core
from installer_core import (
    Ok, Err, DomainError, TerminalCaps, PromptSpec, Check,
)


def caps(is_tty=True, term="xterm-256color", no_color=False, encoding="UTF-8"):
    return TerminalCaps(is_tty=is_tty, term=term, no_color=no_color, encoding=encoding)


class TestResult(unittest.TestCase):
    def test_ok_err_helpers(self):
        self.assertTrue(core.is_ok(Ok(1)))
        self.assertFalse(core.is_err(Ok(1)))
        self.assertTrue(core.is_err(Err(DomainError("k", "m"))))

    def test_frozen_immutability(self):
        e = DomainError("k", "m")
        with self.assertRaises(Exception):
            e.kind = "other"  # frozen dataclass


class TestPalette(unittest.TestCase):
    def test_no_ansi_when_color_disabled(self):
        for c in (caps(is_tty=False), caps(term="dumb"), caps(no_color=True)):
            p = core.make_palette(c)
            self.assertEqual(p.red, "")
            self.assertEqual(p.reset, "")
            self.assertEqual(p.bold, "")

    def test_ansi_present_when_color_enabled(self):
        p = core.make_palette(caps())
        self.assertEqual(p.red, "\033[31m")
        self.assertTrue(p.reset.startswith("\033["))

    def test_ascii_fallback_without_utf8(self):
        p = core.make_palette(caps(encoding="ANSI_X3.4-1968"))
        self.assertEqual(p.check, "OK")
        self.assertEqual(p.cross, "NO")
        self.assertEqual(p.arrow, ">")
        self.assertEqual(p.spinner_frames, "|/-\\")

    def test_utf8_glyphs_when_supported(self):
        p = core.make_palette(caps(encoding="UTF-8"))
        self.assertEqual(p.check, "✔")
        self.assertEqual(p.arrow, "›")

    def test_color_independent_of_utf8(self):
        # No-color but UTF-8 → glyphs unicode, codes empty
        p = core.make_palette(caps(no_color=True, encoding="UTF-8"))
        self.assertEqual(p.green, "")
        self.assertEqual(p.check, "✔")


class TestTimeouts(unittest.TestCase):
    def test_long_running_detection(self):
        self.assertTrue(core.is_long_running("docker compose up -d --build"))
        self.assertTrue(core.is_long_running("sudo apt-get install -y nmap"))
        self.assertTrue(core.is_long_running("docker pull alpine"))
        self.assertFalse(core.is_long_running("ls -la"))
        self.assertFalse(core.is_long_running("docker ps"))

    def test_select_timeout_consistency(self):
        self.assertEqual(core.select_timeout("docker compose build", 60, 600), 600)
        self.assertEqual(core.select_timeout("echo hi", 60, 600), 60)


class TestStreamingLogs(unittest.TestCase):
    def test_detect_follow(self):
        self.assertTrue(core.is_streaming_log("docker compose logs -f --tail=20"))
        self.assertTrue(core.is_streaming_log("docker logs --follow web"))
        self.assertFalse(core.is_streaming_log("docker compose logs --tail=30"))
        self.assertFalse(core.is_streaming_log("docker ps -f status=running"))  # -f not for logs

    def test_harden_strips_follow(self):
        safe, mod = core.harden_command("docker compose logs -f --tail=20")
        self.assertTrue(mod)
        self.assertNotIn("-f", safe.split())
        self.assertIn("--tail=20", safe)

    def test_harden_noop_on_normal(self):
        cmd = "docker compose up -d --build"
        self.assertEqual(core.harden_command(cmd), (cmd, False))

    def test_harden_idempotent_and_safe_property(self):
        rng = random.Random(1234)
        flags = ["-f", "--follow", "--tail=20", "web", "cli", "-t", "--timestamps"]
        for _ in range(500):
            n = rng.randint(0, 5)
            tail = " ".join(rng.choice(flags) for _ in range(n))
            cmd = f"docker compose logs {tail}".strip()
            safe1, _ = core.harden_command(cmd)
            safe2, mod2 = core.harden_command(safe1)
            # After hardening once, the result is already safe (idempotent) ...
            self.assertFalse(mod2, f"not idempotent for {cmd!r}")
            # ... and never contains a follow flag.
            self.assertNotIn("-f", safe1.split())
            self.assertNotIn("--follow", safe1.split())


class TestDestructive(unittest.TestCase):
    def test_positive(self):
        for cmd in ("rm -rf /", "sudo rm -rf /  ", "mkfs.ext4 /dev/sda1",
                    "dd if=/dev/zero of=/dev/sda", "DROP DATABASE bugtraceai_web;",
                    "docker volume rm pgdata",
                    "docker compose down -v", "docker compose down --volumes",
                    "docker-compose down -v", "docker compose down -fv"):
            self.assertTrue(core.is_destructive(cmd), cmd)

    def test_negative(self):
        for cmd in ("rm -rf ./build", "docker compose up -d --build",
                    "rm -f /tmp/x", "git clone repo", "apt-get install -y curl",
                    "docker compose down", "docker compose down --remove-orphans"):
            self.assertFalse(core.is_destructive(cmd), cmd)


class TestPrivilegeRouting(unittest.TestCase):
    def test_detects_sudo_command_boundaries(self):
        for cmd in ("sudo apt-get update", "echo ok; sudo -v", "/usr/bin/sudo id"):
            self.assertTrue(core.requests_sudo(cmd), cmd)
        for cmd in ("echo sudoers", "printf '%s\\n' sudo", "sudoers-check"):
            self.assertFalse(core.requests_sudo(cmd), cmd)


class TestRetryPolicy(unittest.TestCase):
    def test_should_retry_table(self):
        self.assertTrue(core.should_retry(429, 1, 4))
        self.assertTrue(core.should_retry(503, 2, 4))
        self.assertTrue(core.should_retry(None, 1, 4))   # network error
        self.assertFalse(core.should_retry(400, 1, 4))   # client error: no retry
        self.assertFalse(core.should_retry(200, 1, 4))
        self.assertFalse(core.should_retry(429, 4, 4))   # attempts exhausted

    def test_never_exceeds_max_property(self):
        rng = random.Random(7)
        for _ in range(1000):
            status = rng.choice([None, 200, 400, 401, 429, 500, 502, 503])
            mx = rng.randint(1, 6)
            attempt = rng.randint(mx, mx + 3)  # at or beyond max
            self.assertFalse(core.should_retry(status, attempt, mx))

    def test_backoff_monotonic_and_capped(self):
        prev = -1.0
        for attempt in range(1, 10):
            d = core.backoff_delay(attempt, base=1.0, cap=30.0)
            self.assertGreaterEqual(d, prev)
            self.assertLessEqual(d, 30.0)
            prev = d
        self.assertEqual(core.backoff_delay(0), 0.0)
        self.assertEqual(core.backoff_delay(1, base=1.0), 1.0)
        self.assertEqual(core.backoff_delay(2, base=1.0), 2.0)


class TestMaskSecret(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(core.mask_secret(""), "")

    def test_reveals_last_five(self):
        key = "sk-or-v1-EXAMPLE-FAKE-TEST-KEY-0-abcde"
        masked = core.mask_secret(key)
        self.assertTrue(masked.endswith(key[-5:]))         # last 5 chars visible
        self.assertEqual(masked[-5:], key[-5:])
        self.assertTrue(masked.startswith("*"))
        self.assertEqual(len(masked), len(key))            # length preserved by stars

    def test_short_secret_fully_masked(self):
        # Nothing should leak when the secret is <= visible.
        self.assertEqual(core.mask_secret("abc"), "***")
        self.assertEqual(core.mask_secret("12345"), "*****")

    def test_never_exposes_more_than_visible_property(self):
        rng = random.Random(5)
        alphabet = "abcdefABCDEF0123456789-_"
        for _ in range(1000):
            n = rng.randint(0, 40)
            key = "".join(rng.choice(alphabet) for _ in range(n))
            masked = core.mask_secret(key, visible=5)
            # The number of non-masked (revealed) chars never exceeds 5.
            revealed = sum(1 for a, b in zip(masked, key) if a == b and a != "*")
            self.assertLessEqual(revealed, 5)


class TestRedactSensitiveOutput(unittest.TestCase):
    def test_redacts_known_and_env_style_secrets(self):
        output = ("OPENROUTER_API_KEY=sk-or-secret\n"
                  "POSTGRES_PASSWORD=database-secret\n"
                  "provider saw sk-or-secret\n"
                  "ordinary=value\n")
        redacted = core.redact_sensitive_output(output, ("sk-or-secret",))
        self.assertNotIn("sk-or-secret", redacted)
        self.assertNotIn("database-secret", redacted)
        self.assertIn("OPENROUTER_API_KEY=[REDACTED]", redacted)
        self.assertIn("ordinary=value", redacted)

    def test_install_log_line_flattens_and_redacts(self):
        line = core.format_install_log_line(
            "2026-01-01T00:00:00+00:00", "info",
            "OPENROUTER_API_KEY=sk-or-secret\nnext",
            ("sk-or-secret",),
        )
        self.assertEqual(
            line,
            "2026-01-01T00:00:00+00:00 INFO OPENROUTER_API_KEY=[REDACTED] next\n",
        )
        self.assertTrue(line.endswith("\n"))


class TestParsing(unittest.TestCase):
    def test_parse_tool_arguments_valid(self):
        r = core.parse_tool_arguments('{"command": "ls"}')
        self.assertIsInstance(r, Ok)
        self.assertEqual(r.value["command"], "ls")

    def test_parse_tool_arguments_empty(self):
        r = core.parse_tool_arguments("")
        self.assertIsInstance(r, Ok)
        self.assertEqual(r.value, {})

    def test_parse_tool_arguments_broken(self):
        r = core.parse_tool_arguments('{"command": ')
        self.assertIsInstance(r, Err)
        self.assertEqual(r.error.kind, "invalid_tool_args")

    def test_parse_tool_arguments_non_dict(self):
        r = core.parse_tool_arguments('[1,2,3]')
        self.assertIsInstance(r, Err)

    def test_parse_api_response_with_tool_calls(self):
        body = json.dumps({"choices": [{"message": {
            "content": None,
            "tool_calls": [{"id": "c1", "function": {"name": "run_command",
                                                     "arguments": '{"command":"ls"}'}}],
        }}]})
        r = core.parse_api_response(body)
        self.assertIsInstance(r, Ok)
        msg = r.value
        self.assertEqual(len(msg.tool_calls), 1)
        self.assertEqual(msg.tool_calls[0].name, "run_command")
        self.assertIsNotNone(msg.raw)

    def test_parse_api_response_with_content(self):
        body = json.dumps({"choices": [{"message": {"content": "hola"}}]})
        r = core.parse_api_response(body)
        self.assertIsInstance(r, Ok)
        self.assertEqual(r.value.content, "hola")
        self.assertEqual(r.value.tool_calls, ())

    def test_parse_api_response_error_shaped(self):
        body = json.dumps({"error": {"message": "rate limited", "code": 429}})
        r = core.parse_api_response(body)
        self.assertIsInstance(r, Err)
        self.assertEqual(r.error.kind, "api_error")

    def test_parse_api_response_empty_choices(self):
        r = core.parse_api_response(json.dumps({"choices": []}))
        self.assertIsInstance(r, Err)
        self.assertEqual(r.error.kind, "bad_response_shape")

    def test_parse_api_response_invalid_json(self):
        r = core.parse_api_response("<html>502 Bad Gateway</html>")
        self.assertIsInstance(r, Err)
        self.assertEqual(r.error.kind, "invalid_json")

    def test_parse_api_response_missing_message(self):
        r = core.parse_api_response(json.dumps({"choices": [{"finish_reason": "stop"}]}))
        self.assertIsInstance(r, Err)

    def test_parse_never_raises_property(self):
        rng = random.Random(99)
        alphabet = '{}[]":,abc 012\\n'
        for _ in range(2000):
            s = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 30)))
            # Must return a Result, never raise.
            self.assertIn(type(core.parse_api_response(s)), (Ok, Err))
            self.assertIn(type(core.parse_tool_arguments(s)), (Ok, Err))


class TestVerification(unittest.TestCase):
    def test_evaluate_predicates(self):
        self.assertTrue(core.evaluate_check("rc0_nonempty", 0, "1.2.3"))
        self.assertFalse(core.evaluate_check("rc0_nonempty", 1, "1.2.3"))
        self.assertFalse(core.evaluate_check("rc0_nonempty", 0, "  "))
        self.assertTrue(core.evaluate_check("nonempty", 1, "x"))
        self.assertTrue(core.evaluate_check("health", 0, '{"status":"healthy"}'))
        self.assertTrue(core.evaluate_check("health", 0, '{"status":"ok"}'))
        self.assertTrue(core.evaluate_check("health", 0, '{"status":"degraded but up"}'))
        self.assertFalse(core.evaluate_check("health", 0, ""))
        self.assertFalse(core.evaluate_check("health", 7, '{"status":"healthy"}'))
        self.assertFalse(core.evaluate_check("health", 0, "down"))
        self.assertTrue(core.evaluate_check("http200", 0, "200\n"))
        self.assertFalse(core.evaluate_check("http200", 0, "500"))
        self.assertTrue(core.evaluate_check("sse", 0, ""))
        self.assertTrue(core.evaluate_check("sse", 28, ""))
        self.assertFalse(core.evaluate_check("sse", 7, ""))
        self.assertTrue(core.evaluate_check("exists", 0, "exists"))
        self.assertFalse(core.evaluate_check("unknown_predicate", 0, "x"))

    def test_checks_per_mode(self):
        ports = core.DeploymentPorts(web=41001, cli=41002)
        full = core.verification_checks("full", "/home/u/bugtraceai", ports)
        cli = core.verification_checks("cli", "/home/u/bugtraceai", ports)
        web = core.verification_checks("web", "/home/u/bugtraceai", ports)
        # full = docker + cli(3) + web(5) + WEB-to-CLI proxy(1)
        self.assertEqual(len(full), 1 + 3 + 5 + 1)
        self.assertEqual(len(cli), 1 + 3)
        self.assertEqual(len(web), 1 + 5)
        # all checks are immutable Check instances with a known predicate
        valid = {"rc0_nonempty", "rc0", "nonempty", "health", "http200", "exists", "sse"}
        for c in full:
            self.assertIsInstance(c, Check)
            self.assertIn(c.predicate, valid)
        commands = "\n".join(check.command for check in full)
        self.assertIn("localhost:41001", commands)
        self.assertIn("localhost:41002", commands)
        self.assertNotIn("localhost:8000", commands)

    def test_no_endpoint_check_is_invented_without_a_resolved_port(self):
        checks = core.verification_checks("full", "/opt/bt")
        commands = "\n".join(check.command for check in checks)
        self.assertNotIn("curl", commands)

    def test_endpoint_url_uses_only_valid_resolved_ports(self):
        self.assertEqual(core.endpoint_url(43210, "/health"), "http://localhost:43210/health")
        self.assertIsNone(core.endpoint_url(None))
        self.assertIsNone(core.endpoint_url(True))
        self.assertIsNone(core.endpoint_url(0))
        self.assertIsNone(core.endpoint_url(70000))

    def test_checks_reference_install_dir(self):
        checks = core.verification_checks("cli", "/opt/bt")
        env_check = [c for c in checks if c.predicate == "exists"][0]
        self.assertIn("/opt/bt/BugTraceAI-CLI/.env", env_check.command)


class TestSystemPrompt(unittest.TestCase):
    def spec(self, mode="full", action="install"):
        return PromptSpec(mode=mode, action=action, install_dir="/home/u/bugtraceai",
                          api_key="sk-or-TESTKEY", cli_repo="git://cli", web_repo="git://web",
                          max_turns=40)

    def test_keeps_key_out_of_prompt_and_contains_dir(self):
        p = core.build_system_prompt(self.spec())
        self.assertNotIn("sk-or-TESTKEY", p)
        self.assertIn("/home/u/bugtraceai", p)
        self.assertIn("configure_cli", p)

    def test_host_managed_secret_hardening_present(self):
        p = core.build_system_prompt(self.spec())
        self.assertIn("mode 600", p)
        self.assertIn("Never create or print the secret yourself", p)
        self.assertIn("installs Docker Engine before this agent starts", p)
        self.assertIn("Do not run get.docker.com yourself", p)
        self.assertIn("AUTH_REQUIRED", p)
        self.assertIn("do not retry it in a loop", p)
        self.assertIn("SELECTED COMPONENTS", p)
        self.assertIn("This installer is interactive", p)

    def test_prompt_uses_resolved_endpoint_without_fixed_fallback(self):
        spec = PromptSpec(mode="full", action="install", install_dir="/home/u/bugtraceai",
                          api_key="sk-or-TESTKEY", cli_repo="git://cli", web_repo="git://web",
                          max_turns=40, ports=core.DeploymentPorts(web=41001, cli=41002))
        p = core.build_system_prompt(spec)
        self.assertIn("http://localhost:41001", p)
        self.assertIn("http://localhost:41002", p)
        self.assertNotIn("localhost:6869", p)

    def test_no_follow_in_logs(self):
        # No actual `docker ... logs -f/--follow` *command* should remain (it
        # would hang). The RULE line that forbids follow is allowed — it has no
        # "docker" token, so we only inspect lines that look like a real command.
        p = core.build_system_prompt(self.spec())
        for line in p.splitlines():
            toks = line.split()
            if "docker" in toks and "logs" in toks and ("-f" in toks or "--follow" in toks):
                self.fail(f"system prompt still instructs follow-logs: {line!r}")

    def test_repair_vs_install_instructions(self):
        self.assertIn("REPAIR MODE RULES", core.build_system_prompt(self.spec(action="repair")))
        self.assertIn("INSTALL MODE RULES", core.build_system_prompt(self.spec(action="install")))

    def test_mode_label(self):
        self.assertIn("CLI Only", core.build_system_prompt(self.spec(mode="cli")))
        self.assertIn("WEB Only", core.build_system_prompt(self.spec(mode="web")))


class TestParsingHardened(unittest.TestCase):
    """Regression tests for the boundary-parser never-crash contract (the HIGH
    finding) and content normalization."""
    def test_function_null_does_not_crash(self):
        body = json.dumps({"choices": [{"message": {"tool_calls": [
            {"id": "x", "function": None}]}}]})
        r = core.parse_api_response(body)
        self.assertIsInstance(r, Ok)
        self.assertEqual(r.value.tool_calls[0].name, "")

    def test_function_string_does_not_crash(self):
        body = json.dumps({"choices": [{"message": {"tool_calls": [
            {"id": "x", "function": "oops"}]}}]})
        r = core.parse_api_response(body)
        self.assertIsInstance(r, Ok)
        self.assertEqual(r.value.tool_calls[0].arguments, "")

    def test_idless_tool_call_gets_synthetic_id(self):
        body = json.dumps({"choices": [{"message": {"tool_calls": [
            {"function": {"name": "run_command", "arguments": "{}"}}]}}]})
        r = core.parse_api_response(body)
        self.assertTrue(r.value.tool_calls[0].id)  # non-empty synthesized id

    def test_content_list_normalized_to_str(self):
        body = json.dumps({"choices": [{"message": {"content": [
            {"type": "text", "text": "ho"}, {"type": "text", "text": "la"}]}}]})
        r = core.parse_api_response(body)
        self.assertEqual(r.value.content, "hola")

    def test_content_weird_type_coerced(self):
        body = json.dumps({"choices": [{"message": {"content": 123}}]})
        r = core.parse_api_response(body)
        self.assertIsInstance(r.value.content, str)

    def test_non_dict_tool_call_filtered(self):
        body = json.dumps({"choices": [{"message": {"tool_calls": ["nope", 5]}}]})
        r = core.parse_api_response(body)
        self.assertEqual(r.value.tool_calls, ())


class TestAssistantMessageDict(unittest.TestCase):
    def test_sent_ids_match_parsed(self):
        body = json.dumps({"choices": [{"message": {"content": None, "tool_calls": [
            {"id": "a", "function": {"name": "run_command", "arguments": "{}"}},
            {"function": {"name": "ask_user", "arguments": "{}"}},  # id-less
        ]}}]})
        msg = core.parse_api_response(body).value
        d = core.assistant_message_dict(msg)
        sent_ids = [tc["id"] for tc in d["tool_calls"]]
        answered_ids = [tc.id for tc in msg.tool_calls]
        self.assertEqual(sent_ids, answered_ids)          # every sent id is answerable
        self.assertTrue(all(sent_ids))                    # none empty
        self.assertEqual(d["role"], "assistant")

    def test_no_tool_calls_key_when_none(self):
        body = json.dumps({"choices": [{"message": {"content": "hi"}}]})
        d = core.assistant_message_dict(core.parse_api_response(body).value)
        self.assertNotIn("tool_calls", d)


class TestClassifyHttpError(unittest.TestCase):
    def test_error_shaped_body(self):
        e = core.classify_http_error(429, json.dumps({"error": {"message": "rate"}}))
        self.assertEqual(e.kind, "api_error")

    def test_html_body(self):
        e = core.classify_http_error(502, "<html>bad gateway</html>")
        self.assertIn("502", e.message)

    def test_empty_body(self):
        # No parseable error body → generic HTTP error that keeps the status.
        e = core.classify_http_error(500, "")
        self.assertEqual(e.kind, "api_error")
        self.assertIn("500", e.message)


class TestRetryBoundaries(unittest.TestCase):
    def test_5xx_boundaries(self):
        self.assertFalse(core.should_retry(499, 1, 4))
        self.assertTrue(core.should_retry(500, 1, 4))
        self.assertTrue(core.should_retry(599, 1, 4))
        self.assertFalse(core.should_retry(600, 1, 4))

    def test_backoff_cap_reached_and_custom_base(self):
        self.assertEqual(core.backoff_delay(10, base=1.0, cap=30.0), 30.0)
        self.assertEqual(core.backoff_delay(1, base=2.5), 2.5)


class TestDestructiveHardened(unittest.TestCase):
    def test_relative_and_split_and_tools(self):
        for cmd in ("rm -rf .", "rm -rf *", "rm -r -f /", "rm  -rf  /",
                    "git clean -fdx", "docker rm -f web", "docker rmi img",
                    "rm -rf ~", "sudo rm -rf /"):
            self.assertTrue(core.is_destructive(cmd), cmd)

    def test_legit_not_flagged(self):
        for cmd in ("rm -rf ./build", "rm -rf node_modules", "rm -rf dist",
                    "docker compose up -d --build", "git clone x", "rm -f /tmp/x.log"):
            self.assertFalse(core.is_destructive(cmd), cmd)


class TestEvaluateExistsExact(unittest.TestCase):
    def test_exact_match_only(self):
        self.assertTrue(core.evaluate_check("exists", 0, "exists\n"))
        self.assertFalse(core.evaluate_check("exists", 0, "directory already exists"))
        self.assertFalse(core.evaluate_check("exists", 0, "preexists"))


class TestMaskWidth(unittest.TestCase):
    def test_fixed_width_hides_length(self):
        short = core.mask_secret("sk-or-abcdefg", mask_width=8)
        long = core.mask_secret("sk-or-" + "x" * 60 + "abcde", mask_width=8)
        self.assertEqual(short, "********" + "cdefg")
        self.assertTrue(long.startswith("********"))
        self.assertEqual(long[-5:], "abcde")
        self.assertEqual(len(long.rstrip("abcde").rstrip()), 8)  # fixed prefix

    def test_custom_mask_char_and_visible_zero(self):
        self.assertTrue(core.mask_secret("abcdefgh", mask_char="#").endswith("defgh"))
        self.assertEqual(set(core.mask_secret("abcdef", visible=0)), {"*"})


class TestSpinnerLabels(unittest.TestCase):
    def test_command_spinner_label_precedence(self):
        self.assertEqual(core.command_spinner_label("docker compose build"), "Building Docker images")
        self.assertEqual(core.command_spinner_label("docker ps"), "Running Docker")
        self.assertEqual(core.command_spinner_label("ls -la"), "Running command")

    def test_docker_progress_label_branches(self):
        self.assertTrue(core.docker_progress_label("#5 building").startswith("Building:"))
        self.assertTrue(core.docker_progress_label("Step 3/16 : RUN").startswith("Building:"))
        self.assertTrue(core.docker_progress_label("Pulling fs layer").startswith("Downloading:"))
        self.assertTrue(core.docker_progress_label("Creating bugtrace_api").startswith("Docker:"))
        self.assertIsNone(core.docker_progress_label("   "))
        self.assertIsNone(core.docker_progress_label("random noise line"))


class TestHardenSurvival(unittest.TestCase):
    def test_non_follow_tokens_survive(self):
        # Over-stripping would be a bug: only -f/--follow must be removed.
        safe, mod = core.harden_command("docker compose logs -f --tail=20 web")
        self.assertTrue(mod)
        for tok in ("docker", "compose", "logs", "--tail=20", "web"):
            self.assertIn(tok, safe.split())


class TestResultGuards(unittest.TestCase):
    def test_is_ok_is_err_exclusive(self):
        self.assertFalse(core.is_ok(Err(DomainError("k", "m"))))
        self.assertFalse(core.is_err(Ok(1)))


class TestModelChain(unittest.TestCase):
    def test_default_chain_is_deepseek_then_qwen(self):
        chain = core.build_model_chain(core.DEFAULT_PRIMARY_MODEL, core.DEFAULT_FALLBACK_MODEL)
        self.assertEqual(chain, ("deepseek/deepseek-v4.1-flash", "qwen/qwen3.8-max-0902"))

    def test_chain_drops_blanks(self):
        # A blank fallback (env override unset) leaves a single-model chain.
        self.assertEqual(core.build_model_chain("deepseek/deepseek-v4.1-flash", ""),
                         ("deepseek/deepseek-v4.1-flash",))
        self.assertEqual(core.build_model_chain("  ", "qwen/qwen3.8-max-0902"),
                         ("qwen/qwen3.8-max-0902",))

    def test_chain_dedupes_identical_primary_and_fallback(self):
        # Never try the same model twice (no pointless self-fallback).
        self.assertEqual(core.build_model_chain("x/y", "x/y"), ("x/y",))
        self.assertEqual(core.build_model_chain(" x/y ", "x/y"), ("x/y",))

    def test_chain_strips_whitespace(self):
        self.assertEqual(core.build_model_chain("  a/b  ", " c/d "), ("a/b", "c/d"))

    def test_fallback_eligible_kinds(self):
        for kind in ("network", "api_error", "invalid_json", "bad_response_shape"):
            self.assertTrue(core.is_fallback_eligible(DomainError(kind, "m")), kind)

    def test_fallback_not_eligible_for_non_call_api_kinds(self):
        # Tool-arg parse errors are not generic API fallback triggers; the shell
        # applies its separate repeated-protocol-error threshold instead.
        for kind in ("invalid_tool_args", "whatever"):
            self.assertFalse(core.is_fallback_eligible(DomainError(kind, "m")), kind)

    def test_repeated_malformed_tools_trigger_a_failover(self):
        self.assertFalse(core.tool_error_requires_failover(1))
        self.assertTrue(core.tool_error_requires_failover(2))
        self.assertTrue(core.tool_error_requires_failover(3))
        self.assertTrue(core.tool_error_requires_failover(1, limit=1))

    def test_model_display_names_known(self):
        self.assertEqual(core.model_display_name("deepseek/deepseek-v4.1-flash"),
                         "DeepSeek V4.1 Flash")
        self.assertEqual(core.model_display_name("qwen/qwen3.8-max-0902"),
                         "Qwen 3.8 Max (0902)")
        self.assertEqual(core.model_display_name("z-ai/glm-4.6"), "GLM-4.6")

    def test_model_display_name_unknown_uses_last_segment(self):
        self.assertEqual(core.model_display_name("foo/bar-baz"), "bar-baz")
        self.assertEqual(core.model_display_name("noslug"), "noslug")
        self.assertEqual(core.model_display_name(""), "model")


class TestAnthropicProvider(unittest.TestCase):
    """Anthropic direct-API wire adapters + provider provisioning (all pure)."""

    def test_provision_maps(self):
        self.assertEqual(core.cli_key_env("anthropic"), "ANTHROPIC_API_KEY")
        self.assertEqual(core.cli_key_env("zai"), "GLM_API_KEY")
        self.assertEqual(core.cli_key_env("openrouter"), "OPENROUTER_API_KEY")
        self.assertEqual(core.cli_key_env("unknown"), "OPENROUTER_API_KEY")  # degrade
        self.assertEqual(core.cli_conf_active("anthropic"), "anthropic")
        self.assertEqual(core.cli_conf_active("openrouter"), "openrouter-v2")
        self.assertEqual(core.cli_conf_active("zai"), "zai")

    def test_conf_patch_command_section_scoped(self):
        cmd = core.cli_conf_patch_command("anthropic")
        self.assertIn("ACTIVE = anthropic", cmd)
        self.assertIn(r"/^\[PROVIDER\]/", cmd)   # section-scoped range
        self.assertIn("^ACTIVE *=", cmd)         # only the ACTIVE line
        self.assertIn("bugtraceaicli.conf", cmd)

    def test_split_system(self):
        msgs = [{"role": "system", "content": "SYS"},
                {"role": "user", "content": "hi"},
                {"role": "system", "content": "MORE"}]
        sys_text, rest = core.split_system(msgs)
        self.assertEqual(sys_text, "SYS\n\nMORE")
        self.assertEqual(rest, [{"role": "user", "content": "hi"}])

    def test_split_system_none(self):
        sys_text, rest = core.split_system([{"role": "user", "content": "hi"}])
        self.assertIsNone(sys_text)
        self.assertEqual(len(rest), 1)

    def test_to_anthropic_tools(self):
        tools = [{"type": "function", "function": {
            "name": "run_command", "description": "run", "parameters": {"type": "object"}}}]
        self.assertEqual(core.to_anthropic_tools(tools),
                         [{"name": "run_command", "input_schema": {"type": "object"},
                           "description": "run"}])

    def test_to_anthropic_messages_tool_use_and_result(self):
        msgs = [
            {"role": "user", "content": "install"},
            {"role": "assistant", "content": "running", "tool_calls": [
                {"id": "tc1", "type": "function",
                 "function": {"name": "run_command", "arguments": '{"command": "ls"}'}}]},
            {"role": "tool", "tool_call_id": "tc1", "name": "run_command", "content": "out"},
        ]
        out = core.to_anthropic_messages(msgs)
        self.assertEqual(out[0], {"role": "user", "content": "install"})
        self.assertEqual(out[1]["role"], "assistant")
        self.assertEqual(out[1]["content"][0], {"type": "text", "text": "running"})
        self.assertEqual(out[1]["content"][1],
                         {"type": "tool_use", "id": "tc1", "name": "run_command",
                          "input": {"command": "ls"}})  # input is a DICT, not a string
        self.assertEqual(out[2], {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "tc1", "content": "out"}]})

    def test_to_anthropic_messages_merges_consecutive_tool_results(self):
        out = core.to_anthropic_messages([
            {"role": "tool", "tool_call_id": "a", "content": "1"},
            {"role": "tool", "tool_call_id": "b", "content": "2"}])
        self.assertEqual(len(out), 1)  # merged into ONE user turn
        self.assertEqual([b["tool_use_id"] for b in out[0]["content"]], ["a", "b"])

    def test_to_anthropic_messages_coalesces_consecutive_user(self):
        # A tool-result user turn followed by a plain 'continue' user turn must
        # merge, or Anthropic rejects the two consecutive user roles.
        out = core.to_anthropic_messages([
            {"role": "tool", "tool_call_id": "a", "content": "out"},
            {"role": "user", "content": "continue"}])
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["role"], "user")
        self.assertEqual([b["type"] for b in out[0]["content"]], ["tool_result", "text"])

    def test_build_request_openrouter_byte_identical(self):
        msgs = [{"role": "user", "content": "hi"}]
        tools = [{"type": "function", "function": {"name": "t", "description": "d",
                                                   "parameters": {"type": "object"}}}]
        spec = core.build_request("openrouter", "deepseek/deepseek-v4.1-flash", "sk-or-x", msgs, tools)
        self.assertEqual(spec.url, "https://openrouter.ai/api/v1/chat/completions")
        self.assertEqual(spec.headers, {
            "Authorization": "Bearer sk-or-x",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://bugtraceai.com",
            "X-Title": "BugTraceAI Setup & Repair Assistant"})
        self.assertEqual(spec.body, {"model": "deepseek/deepseek-v4.1-flash", "messages": msgs,
                                     "tools": tools, "tool_choice": "auto"})

    def test_build_request_anthropic(self):
        msgs = [{"role": "system", "content": "SYS"}, {"role": "user", "content": "hi"}]
        tools = [{"type": "function", "function": {"name": "t", "description": "d",
                                                   "parameters": {"type": "object"}}}]
        spec = core.build_request("anthropic", "claude-haiku-4-5", "sk-ant-x", msgs, tools)
        self.assertEqual(spec.url, "https://api.anthropic.com/v1/messages")
        self.assertEqual(spec.headers["x-api-key"], "sk-ant-x")
        self.assertEqual(spec.headers["anthropic-version"], "2023-06-01")
        self.assertNotIn("Authorization", spec.headers)
        self.assertEqual(spec.body["system"], "SYS")
        self.assertEqual(spec.body["max_tokens"], core.ANTHROPIC_MAX_TOKENS)
        self.assertEqual(spec.body["tool_choice"], {"type": "auto"})
        self.assertEqual(spec.body["tools"][0]["input_schema"], {"type": "object"})
        self.assertEqual(spec.body["messages"], [{"role": "user", "content": "hi"}])

    def test_parse_anthropic_text_only(self):
        r = core.parse_anthropic_response('{"content":[{"type":"text","text":"hello"}]}')
        self.assertTrue(core.is_ok(r))
        self.assertEqual(r.value.content, "hello")
        self.assertEqual(r.value.tool_calls, ())

    def test_parse_anthropic_tool_use(self):
        r = core.parse_anthropic_response(
            '{"content":[{"type":"tool_use","id":"tu1","name":"run_command","input":{"command":"ls"}}]}')
        self.assertTrue(core.is_ok(r))
        tc = r.value.tool_calls[0]
        self.assertEqual((tc.id, tc.name), ("tu1", "run_command"))
        self.assertEqual(json.loads(tc.arguments), {"command": "ls"})  # arguments is a JSON string

    def test_parse_anthropic_error_body(self):
        r = core.parse_anthropic_response('{"type":"error","error":{"message":"bad"}}')
        self.assertTrue(core.is_err(r) and r.error.kind == "api_error")

    def test_parse_anthropic_malformed_json(self):
        r = core.parse_anthropic_response("{not json")
        self.assertTrue(core.is_err(r) and r.error.kind == "invalid_json")

    def test_parse_anthropic_missing_content(self):
        r = core.parse_anthropic_response('{"id":"x"}')
        self.assertTrue(core.is_err(r) and r.error.kind == "bad_response_shape")

    def test_parse_anthropic_error_kinds_are_fallback_eligible(self):
        for body in ("{not json", '{"type":"error","error":{}}', '{"id":"x"}'):
            self.assertTrue(core.is_fallback_eligible(core.parse_anthropic_response(body).error))

    def test_validation_request(self):
        url, headers = core.validation_request("anthropic", "sk-ant-x")
        self.assertEqual(url, "https://api.anthropic.com/v1/models")
        self.assertEqual(headers, {"x-api-key": "sk-ant-x", "anthropic-version": "2023-06-01"})
        url2, headers2 = core.validation_request("openrouter", "sk-or-x")
        self.assertEqual(url2, "https://openrouter.ai/api/v1/key")
        self.assertEqual(headers2["Authorization"], "Bearer sk-or-x")

    def test_parse_response_dispatch(self):
        r = core.parse_response("anthropic", '{"content":[{"type":"text","text":"x"}]}')
        self.assertTrue(core.is_ok(r) and r.value.content == "x")
        r2 = core.parse_response("openrouter", '{"choices":[{"message":{"content":"y"}}]}')
        self.assertTrue(core.is_ok(r2) and r2.value.content == "y")

    def test_system_prompt_openrouter_keeps_secret_out(self):
        p = core.build_system_prompt(PromptSpec(
            mode="cli", action="install", install_dir="/tmp/x", api_key="sk-or-KEY",
            cli_repo="R", web_repo="W", max_turns=10))  # default provider=openrouter
        self.assertNotIn("sk-or-KEY", p)
        self.assertIn("DEPLOYED CLI PROVIDER: OPENROUTER", p)
        self.assertIn("configure_cli", p)

    def test_system_prompt_anthropic(self):
        p = core.build_system_prompt(PromptSpec(
            mode="cli", action="install", install_dir="/tmp/x", api_key="sk-ant-KEY",
            cli_repo="R", web_repo="W", max_turns=10, provider="anthropic"))
        self.assertNotIn("sk-ant-KEY", p)
        self.assertNotIn("OPENROUTER_API_KEY=", p)
        self.assertIn("DEPLOYED CLI PROVIDER: ANTHROPIC", p)


if __name__ == "__main__":
    unittest.main(verbosity=2)
