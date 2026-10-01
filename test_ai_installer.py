"""Exercise the real AI installer effects without an LLM or Docker daemon.

The source-preparation tests invoke launcher.sh, rather than copying its patch
logic into mocks. Docker probes and the finish boundary are injected separately.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from unittest.mock import patch

import ai_installer as ai
import installer_core as core


TEST_DIR = Path(__file__).resolve().parent


class TestAIConfiguration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="btai-ai-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.web = self.root / "BugTraceAI-WEB"
        self.cli = self.root / "BugTraceAI-CLI"
        self.api = self.root / "BugTraceAI-API"
        self.recon = self.root / "reconftw-mcp"
        for folder in (self.web / "backend", self.cli, self.api, self.recon):
            folder.mkdir(parents=True, exist_ok=True)
        # Public WEB shape: recon has an image but no local build declaration.
        compose = (TEST_DIR / "testdata/public-recon-image-only.yml").read_text()
        compose = compose.replace("  kali-mcp:\n", "  kali-mcp:\n    container_name: kali-mcp-server\n")
        (self.web / "docker-compose.yml").write_text(compose)
        (self.web / "nginx.conf").write_text("""server {
    resolver 127.0.0.11;
    location ^~ /cli-api/ {
        proxy_pass http://bugtrace-cli-api:${CLI_API_PORT}/;
    }
}
""")
        (self.web / "backend/Dockerfile").write_text("""FROM node:22-alpine AS builder
RUN npm ci
FROM node:22-alpine AS production
RUN npm ci --omit=dev
""")
        (self.cli / "docker-compose.yml").write_text("""services:
  api:
    image: fixture-cli
    container_name: bugtrace_api
    ports:
      - "${CLI_PORT}:${CLI_PORT}"
  mcp:
    image: fixture-cli
    container_name: bugtrace_mcp
    ports:
      - "${MCP_PORT}:${MCP_PORT}"
""")
        (self.api / "docker-compose.yml").write_text("services:\n  api:\n    image: fixture-api\n")
        (self.recon / "requirements.txt").write_text("mcp[cli]>=1.0.0\nfastmcp>=0.1.0\n")
        (self.recon / "Dockerfile").write_text("""FROM six2dez/reconftw:main
RUN python3 -m venv /opt/mcp-venv
RUN pip install --no-cache-dir \\
    mcp[cli]>=1.0.0 \\
    fastmcp>=0.1.0
""")
        context = ai.DeploymentContext(
            install_dir=str(self.root), mode="full", provider="openrouter",
            ports=core.DeploymentPorts(web=39169, cli=39100, mcp=39101,
                                       btai=39105, btai_mcp=39104),
            mcp_cli_enabled=True, mcp_recon_enabled=True, mcp_kali_enabled=True,
        )
        for name, value in (("INSTALL_DIR", str(self.root)), ("deployment_context", context),
                            ("api_key", "fixture-secret"), ("PROVIDER", "openrouter")):
            mock = patch.object(ai, name, value, create=True)
            mock.start()
            self.addCleanup(mock.stop)

    def assert_configured(self, fn):
        success, detail = fn()
        self.assertTrue(success, detail)

    def test_full_prepare_uses_standard_fixes_and_is_repeatable(self):
        self.assert_configured(ai._configure_cli)
        self.assert_configured(ai._configure_api)
        self.assert_configured(ai._configure_web)
        env = ai._read_env_values(self.web / ".env.docker")
        self.assertEqual(env["BTAI_API_PORT"], "39105")
        self.assertEqual(env["CLI_API_PORT"], "39100")
        self.assertEqual(env["FRONTEND_PORT"], "39169")
        self.assertEqual(env["RECON_SSE_MODE"], "true")
        self.assertNotEqual(env["RECON_MCP_PORT"], env["POSTGRES_PORT"])
        self.assertFalse(env.get("COMPOSE_PROFILES"))
        backend = (self.web / "backend/Dockerfile").read_text()
        self.assertEqual(backend.count("fetch-retries 5"), 2)
        self.assertIn("npm ci --omit=dev --no-audit --no-fund", backend)
        self.assertIn('"mcp[cli]>=1.0.0,<2"', (self.recon / "Dockerfile").read_text())
        self.assertIn("python3 -m virtualenv", (self.recon / "Dockerfile").read_text())
        self.assertEqual((self.recon / "requirements.txt").read_text().splitlines()[0],
                         "mcp[cli]>=1.0.0,<2")
        compose = (self.web / "docker-compose.yml").read_text()
        self.assertIn("context: ../reconftw-mcp", compose)
        self.assertIn("Required Kali tools are unavailable.", compose)
        self.assertIn("exec tail -f /dev/null", compose)
        self.assertIn(f'"{env["RECON_MCP_PORT"]}:8002"', compose)
        files = (self.web / "docker-compose.yml", self.web / "backend/Dockerfile",
                 self.web / ".env.docker", self.recon / "Dockerfile")
        before = {path: path.read_text() for path in files}
        self.assert_configured(ai._configure_web)
        self.assert_configured(ai._configure_agents)
        self.assertEqual(before, {path: path.read_text() for path in files})
        for path in (self.cli / ".env", self.api / ".env", self.web / ".env.docker"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_repair_preserves_database_password_and_custom_settings(self):
        (self.web / ".env.docker").write_text("""# retained settings
POSTGRES_USER=existing_user
POSTGRES_PASSWORD=existing_password
POSTGRES_DB=existing_database
POSTGRES_PORT=39132
COMPOSE_PROFILES=recon,kali
CUSTOM_SETTING=keep-me
""")
        (self.cli / ".env").write_text("BUGTRACE_CORS_ORIGINS=https://example.test\nCUSTOM_SETTING=keep-me\n")
        (self.api / ".env").write_text("APEX_MIN_SEVERITY=high\nCUSTOM_SETTING=keep-me\n")
        self.assert_configured(ai._configure_cli)
        self.assert_configured(ai._configure_api)
        self.assert_configured(ai._configure_web)
        self.assert_configured(ai._configure_web)
        env = ai._read_env_values(self.web / ".env.docker")
        self.assertEqual(env["POSTGRES_PASSWORD"], "existing_password")
        self.assertEqual(env["POSTGRES_USER"], "existing_user")
        self.assertEqual(env["POSTGRES_DB"], "existing_database")
        self.assertEqual(env["POSTGRES_PORT"], "39132")
        self.assertEqual(env["CUSTOM_SETTING"], "keep-me")
        self.assertIn("# retained settings", (self.web / ".env.docker").read_text())
        self.assertFalse(env.get("COMPOSE_PROFILES"))
        self.assertEqual(ai._read_env_values(self.cli / ".env")["BUGTRACE_CORS_ORIGINS"],
                         "https://example.test")
        self.assertEqual(ai._read_env_values(self.api / ".env")["APEX_MIN_SEVERITY"], "high")

    def test_web_without_cli_uses_lazy_proxy_then_can_upgrade_to_full(self):
        ai.deployment_context = replace(ai.deployment_context, mode="web",
                                        ports=replace(ai.deployment_context.ports, cli=None, mcp=None),
                                        mcp_cli_enabled=False, mcp_recon_enabled=False,
                                        mcp_kali_enabled=False)
        self.assert_configured(ai._configure_api)
        self.assert_configured(ai._configure_web)
        self.assertIn("set $cli_api_host bugtrace-cli-api;", (self.web / "nginx.conf").read_text())
        ai.deployment_context = replace(ai.deployment_context, mode="full")
        self.assert_configured(ai._configure_cli)
        self.assert_configured(ai._configure_web)
        self.assertTrue(ai.deployment_context.mcp_cli_enabled)

    def test_arm_preparation_uses_amd64_recon_and_valid_yaml_boundary(self):
        bin_dir = self.root / "fake-bin"
        bin_dir.mkdir()
        uname = bin_dir / "uname"
        uname.write_text("#!/bin/sh\nprintf '%s\\n' aarch64\n")
        uname.chmod(0o755)
        with patch.dict(os.environ, {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}):
            self.assert_configured(ai._configure_web)
        self.assertIn("FROM --platform=linux/amd64 six2dez/reconftw:main",
                      (self.recon / "Dockerfile").read_text())
        compose = (self.web / "docker-compose.yml").read_text()
        self.assertIn("platform: linux/amd64", compose)
        self.assertEqual(compose.count("networks:\n  bugtraceai-network:"), 1)

    def test_rendered_optional_compose_is_valid_for_every_extras_selection(self):
        if not shutil.which("docker"):
            self.skipTest("Docker Compose is required for schema validation")
        if subprocess.run(["docker", "compose", "version"], capture_output=True).returncode:
            self.skipTest("Docker Compose is required for schema validation")
        for recon, kali in ((False, False), (True, False), (False, True), (True, True)):
            with self.subTest(recon=recon, kali=kali):
                ai.deployment_context = replace(ai.deployment_context, mcp_recon_enabled=recon,
                                                mcp_kali_enabled=kali)
                self.assert_configured(ai._configure_web)
                proc = subprocess.run(
                    ["docker", "compose", "--env-file", ".env.docker", "--profile", "recon",
                     "--profile", "kali", "config", "--format", "json"],
                    cwd=self.web, capture_output=True, text=True, timeout=15)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                services = json.loads(proc.stdout)["services"]
                if recon:
                    self.assertEqual(services["reconftw-mcp"]["environment"]["RECONFTW_AUTO_INSTALL"], "false")
                if kali:
                    self.assertIn("Required Kali tools are unavailable.", services["kali-mcp"]["command"][-1])

    def test_recon_environment_mapping_and_existing_auto_setting_are_preserved(self):
        compose = (self.web / "docker-compose.yml").read_text().replace(
            '    command: ["mcp", "--sse"]',
            '    environment:\n      MCP_PORT: "8002"\n      RECONFTW_AUTO_INSTALL: "true"\n'
            '    command: ["mcp", "--sse"]')
        (self.web / "docker-compose.yml").write_text(compose)
        self.assert_configured(ai._configure_web)
        self.assert_configured(ai._configure_web)
        compose = (self.web / "docker-compose.yml").read_text()
        self.assertEqual(compose.count("RECONFTW_AUTO_INSTALL"), 1)
        self.assertIn('RECONFTW_AUTO_INSTALL: "true"', compose)
        # Without an existing override the patch must use a mapping, not a list
        # item outside the environment block.
        compose = compose.replace('      RECONFTW_AUTO_INSTALL: "true"\n', '')
        (self.web / "docker-compose.yml").write_text(compose)
        self.assert_configured(ai._configure_web)
        self.assertIn('      RECONFTW_AUTO_INSTALL: "false"',
                      (self.web / "docker-compose.yml").read_text())

    def test_recon_list_environment_with_comments_remains_a_list(self):
        compose = (self.web / "docker-compose.yml").read_text().replace(
            '    command: ["mcp", "--sse"]',
            '    environment:\n      - MCP_PORT=8002\n      # API Keys\n'
            '      - GITHUB_TOKEN=${GITHUB_TOKEN:-}\n    command: ["mcp", "--sse"]')
        (self.web / "docker-compose.yml").write_text(compose)
        self.assert_configured(ai._configure_web)
        self.assert_configured(ai._configure_web)
        compose = (self.web / "docker-compose.yml").read_text()
        self.assertEqual(compose.count("RECONFTW_AUTO_INSTALL"), 1)
        self.assertIn("      - RECONFTW_AUTO_INSTALL=false", compose)
        self.assertNotIn('      RECONFTW_AUTO_INSTALL: "false"', compose)

    def test_missing_recon_source_is_cloned_and_pinned_before_build(self):
        local_repo = self.root / "local-recon-remote"
        self.recon.rename(local_repo)
        for args in (("init",), ("add", "Dockerfile", "requirements.txt"),
                     ("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                      "commit", "-m", "Fixture")):
            proc = subprocess.run(["git", "-C", str(local_repo), *args],
                                  capture_output=True, text=True, timeout=10)
            self.assertEqual(proc.returncode, 0, proc.stderr)
        # Scope URL rewriting to this child process; never modify user Git config.
        with patch.dict(os.environ, {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": f"url.{local_repo}.insteadOf",
            "GIT_CONFIG_VALUE_0": "https://github.com/BugTraceAI/reconftw-mcp.git",
        }):
            self.assert_configured(ai._configure_web)
        self.assertTrue((self.recon / ".git").is_dir())
        self.assertIn('"mcp[cli]>=1.0.0,<2"', (self.recon / "Dockerfile").read_text())

    def test_partial_recon_tree_is_reported_not_overwritten(self):
        (self.recon / "Dockerfile").unlink()
        (self.recon / "user-file").write_text("preserve me")
        success, detail = ai._configure_web()
        self.assertFalse(success)
        self.assertIn("incomplete", detail)
        self.assertEqual((self.recon / "user-file").read_text(), "preserve me")

    def test_recon_allocation_reserves_database_port(self):
        (self.web / ".env.docker").write_text("POSTGRES_PORT=39132\n")
        with patch.object(ai, "_allocate_host_port", return_value=39102) as allocator:
            self.assert_configured(ai._configure_agents)
        self.assertIn(39132, allocator.call_args.args[0])

    def test_api_only_saved_key_can_be_loaded_without_cli(self):
        (self.api / ".env").write_text("OPENROUTER_API_KEY=api-only-secret\n")
        self.assertEqual(ai._load_saved_api_key(str(self.root), "openrouter"), "api-only-secret")


class TestAIVerification(unittest.TestCase):
    def context(self, **flags):
        return ai.DeploymentContext(
            install_dir="/tmp/fixture with spaces", mode="full", provider="openrouter",
            ports=core.DeploymentPorts(web=39169, cli=39100, mcp=39101,
                                       recon=39102, btai=39105, btai_mcp=39104),
            mcp_cli_enabled=True, mcp_recon_enabled=True, mcp_kali_enabled=True,
            **flags,
        )

    def runner(self, fail_command=None):
        def run(cmd):
            if fail_command and fail_command in cmd:
                return 1, "restarting"
            if "docker info" in cmd:
                return 0, "29.0"
            if "docker inspect" in cmd:
                return 0, "running healthy"
            if "docker exec kali-mcp-server" in cmd:
                return 0, "ready"
            if "test -f" in cmd:
                return 0, "exists"
            if "/sse" in cmd:
                return 28, "200"
            if "39169/health" in cmd:
                return 0, '{"success":true,"data":{"status":"ok"}}'
            if "/health" in cmd:
                return 0, '{"status":"healthy"}'
            if "/mcp" in cmd:
                return 0, "406"
            return 0, "200"
        return run

    def test_every_selected_service_is_required_at_finish(self):
        for failed in (None, "reconftw-mcp", "kali-mcp-server", "/btai-api/health",
                       "/kr-api/health", "/cli-api/health", "/sse",
                       "docker exec kali-mcp-server"):
            with self.subTest(failed=failed), contextlib.redirect_stdout(io.StringIO()), \
                    patch.object(ai, "api_key", "fixture-secret", create=True):
                passed, report = ai.run_verification(self.runner(failed), self.context())
                self.assertEqual(passed, failed is None, report)

    def test_missing_selected_agent_port_cannot_pass(self):
        context = self.context()
        context = replace(context, ports=replace(context.ports, recon=None))
        with contextlib.redirect_stdout(io.StringIO()), \
                patch.object(ai, "api_key", "fixture-secret", create=True):
            passed, report = ai.run_verification(self.runner(), context)
        self.assertFalse(passed)
        self.assertIn("[FAIL] reconFTW MCP host port", report)

    def test_finish_failure_never_saves_state_or_exits_agent(self):
        context = self.context()
        with patch.object(ai, "deployment_context", context, create=True), \
                patch.object(ai, "api_key", "fixture-secret", create=True), \
                patch.object(ai, "_refresh_deployment_context", return_value=context), \
                patch.object(ai, "_verification_command", side_effect=self.runner("kali-mcp-server")), \
                patch.object(ai, "_save_ai_state") as save, \
                patch.object(ai, "bubble_ai") as summary, \
                contextlib.redirect_stdout(io.StringIO()):
            result = ai._finish_tool(core.ToolCall("finish", "finish", "{}"),
                                     {"summary": "Everything is installed"})
        self.assertFalse(result.finished)
        self.assertIn("VERIFICATION FAILED", result.message["content"])
        save.assert_not_called()
        summary.assert_not_called()

    def test_live_api_listener_roles_not_sorted_port_numbers(self):
        inspect = {"Config": {"Env": ["MCP_PORT=39144", "API_PORT=39105"]},
                   "NetworkSettings": {"Ports": {
                       "39144/tcp": [{"HostPort": "45144"}],
                       "39105/tcp": [{"HostPort": "45105"}],
                   }}}
        with patch.object(ai, "_capture_host_command", return_value=(0, json.dumps(inspect))):
            self.assertEqual(ai._api_published_ports(), {"btai": 45105, "btai_mcp": 45144})

    def test_standalone_api_does_not_count_as_cli(self):
        context = replace(self.context(), ports=replace(self.context().ports, cli=None))
        with patch.object(ai, "_published_port", return_value=None) as probe, \
                patch.object(ai, "_api_published_ports", return_value={"btai": 45105, "btai_mcp": 45144}):
            refreshed = ai._refresh_deployment_context(context)
        self.assertIsNone(refreshed.ports.cli)
        self.assertNotIn("bugtrace-api", [call.args[0] for call in probe.call_args_list])


class TestAIShell(unittest.TestCase):
    def test_import_does_not_boot_interactive_installer(self):
        proc = subprocess.run([sys.executable, "-c", "import ai_installer; print('import-safe')"],
                              cwd=TEST_DIR, capture_output=True, text=True, timeout=5)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "import-safe")

    def test_failed_build_pipeline_is_not_hidden_and_profiles_are_cleared(self):
        with patch.dict(os.environ, {"COMPOSE_PROFILES": "recon,kali"}), \
                patch.object(ai, "_bash", ai._spawn_bash()):
            try:
                rc, output = ai.run_cmd("false | tail -n 1", timeout=5)
                self.assertEqual(rc, 1, output)
                rc, output = ai.run_cmd('printf "profiles=<%s>\\n" "$COMPOSE_PROFILES"', timeout=5)
                self.assertEqual(rc, 0, output)
                self.assertIn("profiles=<>", output)
                self.assertEqual(ai.run_cmd("cd /tmp", timeout=5)[0], 0)
                self.assertEqual(ai.run_cmd("pwd", timeout=5)[1].strip(), "/tmp")
            finally:
                ai._kill_bash_group(ai._bash)
                ai._bash.stdin.close()
                ai._bash.stdout.close()


if __name__ == "__main__":
    unittest.main()
