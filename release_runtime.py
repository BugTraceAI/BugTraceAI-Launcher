"""Prepare dependencies and Docker images, switch, verify, and recover runtimes.

Compose projects and named-volume identities stay fixed throughout the update.
Each candidate uses unique image tags; running images are not overwritten.
Database backups are retained; schema rollback is never guessed automatically.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import urllib.parse

from release_manager import (CONFIG_FILES, NAMES, PATCH_FILES, ReleaseError, copy_file,
                             git, run, runtime_config_paths, selected_components, write_json)

LOCAL_READY_TIMEOUT_SECONDS = 120


TUI_PROBE = '''import asyncio
from bugtrace.core.ui.tui import BugTraceApp
async def check():
    app = BugTraceApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        app.exit()
asyncio.run(check())
'''


def parse_objects(text: str) -> list[dict]:
    if not text:
        return []
    try:
        value = json.loads(text)
        return value if isinstance(value, list) else [value]
    except ValueError:
        return [json.loads(line) for line in text.splitlines() if line.strip()]


def active_local_processes(path: Path) -> list[int]:
    """Detect the running CLI modules without killing user processes."""
    processes = []
    if Path("/proc").is_dir():
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit() or int(entry.name) == os.getpid():
                continue
            try:
                arguments = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
                cwd = (entry / "cwd").resolve()
            except OSError:
                continue
            if cwd == path and ("-m bugtrace" in arguments or "uvicorn bugtrace." in arguments):
                processes.append(int(entry.name))
    else:
        output = run(["ps", "-axo", "pid=,command="])
        for line in output.splitlines():
            values = line.strip().split(maxsplit=1)
            if len(values) != 2 or not any(part in values[1] for part in ("-m bugtrace", "uvicorn bugtrace.")):
                continue
            pid = int(values[0])
            if str(path) in values[1]:
                processes.append(pid)
                continue
            if shutil.which("lsof"):
                result = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True, text=True)
                if f"n{path}" in result.stdout.splitlines():
                    processes.append(pid)
    return processes


class Runtime:
    def __init__(self, launcher: Path):
        self.launcher = launcher.resolve()
        self.compose = shlex.split(os.environ.get("BUGTRACEAI_RELEASE_COMPOSE", "docker compose"))
        if not self.compose:
            raise ReleaseError("Docker Compose command is missing.")
        self.docker = self.compose[:-1] if self.compose[-1] == "compose" else (self.compose[:-1] + ["docker"])
        self.environment = dict(os.environ, COMPOSE_PROFILES="")
        self.local = False

    def command(self, arguments: list[str], *, capture=True, cwd=None, output=None, timeout=180) -> str:
        try:
            result = subprocess.run(arguments, cwd=cwd, env=self.environment, text=output is None,
                                    stdout=output if output is not None else (subprocess.PIPE if capture else None),
                                    stderr=subprocess.PIPE if capture else None, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReleaseError("Runtime command could not finish; inspect the saved update log.") from error
        if result.returncode:
            raise ReleaseError(f"Runtime command failed (exit {result.returncode}); previous runtime backups were kept.")
        return result.stdout.strip() if capture and output is None else ""

    def compose_args(self, entry: dict, state: dict, *, staged=False, overlay: str = "") -> list[str]:
        key = entry["key"]
        path = Path(entry["staged"] if staged else entry["original"])
        file = "docker-compose.tui.yml" if key == "cli" and state.get("cli_managed") and state.get("cli_interface") == "tui" else "docker-compose.yml"
        arguments = [*self.compose, "--project-directory", str(path)]
        if entry.get("project"):
            arguments += ["--project-name", entry["project"]]
        arguments += ["--env-file", str(path / (".env.docker" if key == "web" else ".env")), "-f", str(path / file)]
        if overlay:
            arguments += ["-f", overlay]
        # Only core services change with this cohort. Existing toolbox containers
        # remain at their installed versions; their health is still verified.
        # API bundles amd64 tools. CLI/WEB retain their own native platform.
        if key == "api":
            arguments = ["env", "DOCKER_DEFAULT_PLATFORM=linux/amd64", *arguments]
        return arguments

    def preflight(self, state: dict, paths: dict[str, Path]) -> None:
        self.local = bool(state.get("cli_managed")) and state.get("cli_runtime") == "local"
        if self.local:
            if active_local_processes(paths["cli"]):
                raise ReleaseError("Close this installation's local TUI/API/MCP processes before updating; they were not stopped.")
            return
        self.command([*self.docker, "info"])
        # An in-progress scan must not lose its worker during an update.
        for key, field in (("cli", "cli_port"), ("api", "btai_port")):
            port = state.get(field)
            if key not in selected_components(state) or not str(port).isdigit():
                continue
            page, cursor = 1, ""
            while True:
                query = urllib.parse.urlencode({"page": page, "per_page": 100} if key == "cli" else {"limit": 200, **({"cursor": cursor} if cursor else {})})
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/scans?{query}", timeout=3) as response:
                        value = json.load(response)
                except (OSError, ValueError):
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3):
                            pass
                    except OSError:
                        break  # An engine that is down has no running worker.
                    raise ReleaseError("An engine responds, but scan activity could not be checked. Update was not started.")
                scans = value if isinstance(value, list) else value.get("scans", []) if isinstance(value, dict) else []
                if isinstance(scans, dict):
                    scans = list(scans.values())
                if any(isinstance(item, dict) and str(item.get("status", "")).lower() in {"running", "pending", "paused", "scanning", "initializing", "queued"} for item in scans):
                    raise ReleaseError("A selected engine has an active scan. Finish or stop it before updating.")
                if not isinstance(value, dict):
                    break
                if key == "cli":
                    if page * 100 >= value.get("total", len(scans)):
                        break
                    page += 1
                else:
                    next_cursor = value.get("next_cursor")
                    if not next_cursor:
                        break
                    if next_cursor == cursor:
                        raise ReleaseError("Scan history pagination did not advance; update was stopped.")
                    cursor = next_cursor

    def shell_step(self, action: str, journal: dict, job: Path, *, key="", paths=None) -> None:
        state_path = job / "context-state.json"
        write_json(state_path, journal["state"])
        directories = {item["key"]: item["staged"] for item in journal.get("components", [])}
        directories.update(paths or {})
        arguments = ["bash", str(self.launcher.parent / "release_steps.sh"), str(self.launcher), action, str(state_path)]
        arguments += [directories.get(name, str(job / "sources" / NAMES[name])) for name in ("cli", "web", "api")]
        arguments.append(key)
        self.command(arguments, capture=False, timeout=1800)

    def validate_existing(self, key: str, staged: Path, state: dict) -> None:
        job = staged.parent.parent
        self.shell_step("validate", {"state": state}, job, key=key, paths={key: str(staged)})
        # Preference/configuration changes are preserved separately from source.
        tracked = set(git(staged, "ls-files").splitlines())
        for name in runtime_config_paths(key, staged):
            if name in tracked:
                git(staged, "checkout", "--", name)

    def current_containers(self, arguments: list[str]) -> list[dict]:
        ids = self.command([*arguments, "ps", "--all", "--quiet"]).splitlines()
        if not ids:
            return []
        values = json.loads(self.command([*self.docker, "inspect", *ids]))
        return [{"service": item["Config"]["Labels"]["com.docker.compose.service"],
                 "image": item["Image"], "running": item["State"]["Running"]} for item in values]

    @staticmethod
    def volume_identity(config: dict) -> dict:
        identities = {}
        for service, item in config.get("services", {}).items():
            for volume in item.get("volumes", []):
                if volume.get("type") == "volume":
                    source = volume.get("source")
                    actual = config.get("volumes", {}).get(source, {}).get("name", source)
                    identities[f"{service}:{volume['target']}"] = actual
        return identities

    def prepare(self, journal: dict, job: Path) -> None:
        self.local = bool(journal["state"].get("cli_managed")) and journal["state"].get("cli_runtime") == "local"
        if self.local:
            entry = journal["components"][0]
            path = Path(entry["staged"])
            installer = path / "scripts/install-runtime.sh"
            if not installer.is_file():
                installer = path / "install.sh"
            print("Preparing the local Python environment in the update directory...", flush=True)
            self.command(["bash", str(installer), "--interface", journal["state"]["cli_interface"],
                          "--runtime", "local", "--global", "no", "--launch", "no"], capture=False, cwd=path, timeout=None)
            journal["runtime"] = {"kind": "local", "venv": str(path / ".venv"), "venv_switched": False}
            return
        state = journal["state"]
        # Recon sources are only copied for context resolution; they are not updated.
        if state.get("mcp_recon_enabled"):
            source = job.parent.parent / "reconftw-mcp"
            if not source.is_dir():
                raise ReleaseError("The installed reconFTW context is missing; repair it before updating WEB.")
            destination = job / "sources/reconftw-mcp"
            shutil.copytree(source, destination, ignore=shutil.ignore_patterns(".git", ".env", "__pycache__", "node_modules", "reports", "logs"))
        self.shell_step("patch", journal, job)
        runtime = {"kind": "docker", "components": []}
        for entry in journal["components"]:
            arguments = self.compose_args(entry, state)
            old = json.loads(self.command([*arguments, "config", "--format", "json"]))
            entry["project"] = old["name"]
            new_arguments = self.compose_args(entry, state, staged=True)
            new = json.loads(self.command([*new_arguments, "config", "--format", "json"]))
            old_volumes, new_volumes = self.volume_identity(old), self.volume_identity(new)
            for target, volume in old_volumes.items():
                if new_volumes.get(target) != volume:
                    raise ReleaseError("The candidate would change a named data volume. Migration needs an explicit plan.")
            if entry["key"] == "web" and old["services"].get("postgres", {}).get("image") != new["services"].get("postgres", {}).get("image"):
                raise ReleaseError("Database image changes need a separate migration; this update was stopped.")
            services = [name for name, item in new["services"].items() if not item.get("profiles")]
            containers = self.current_containers(self.compose_args(entry, state))
            by_service = {item["service"]: item for item in containers}
            candidate_services, previous_services = {}, {}
            for name in services:
                item = new["services"][name]
                if item.get("build"):
                    image = f"bugtraceai-update-{job.name.lower()}:{entry['key']}-{name}"
                else:
                    # Keep the actual running database/toolbox image, not a floating tag.
                    image = by_service.get(name, {}).get("image", item.get("image"))
                if image:
                    if not item.get("build") and name not in by_service:
                        self.command([*self.docker, "pull", image], capture=False, timeout=None)
                    candidate_services[name] = {"image": image, "pull_policy": "never"}
                if name in by_service:
                    previous_services[name] = {"image": by_service[name]["image"], "pull_policy": "never"}
            candidate = job / f"{entry['key']}-candidate.compose.json"
            previous = job / f"{entry['key']}-previous.compose.json"
            write_json(candidate, {"services": candidate_services})
            write_json(previous, {"services": previous_services})
            item = {"key": entry["key"], "services": services, "containers": containers,
                    "candidate": str(candidate), "previous": str(previous)}
            runtime["components"].append(item)
            print(f"Building {NAMES[entry['key']]} {entry['version']} before activation...", flush=True)
            self.command([*new_arguments, "-f", str(candidate), "build", *services], capture=False, timeout=None)
        journal["runtime"] = runtime

    def quiesce(self, journal: dict, job: Path) -> None:
        if journal["runtime"]["kind"] == "local":
            if active_local_processes(Path(journal["components"][0]["original"])):
                raise ReleaseError("A local CLI process started while preparing; close it and retry.")
            return
        # Stop application writers before the DB dump; database and sidecars stay up.
        for item in reversed(journal["runtime"]["components"]):
            entry = next(value for value in journal["components"] if value["key"] == item["key"])
            applications = [name for name in item["services"] if name != "postgres"]
            if applications:
                self.command([*self.compose_args(entry, journal["state"]), "stop", *applications], capture=False, timeout=180)
        for item in journal["runtime"]["components"]:
            if item["key"] != "web" or not any(value["service"] == "postgres" and value["running"] for value in item["containers"]):
                continue
            entry = next(value for value in journal["components"] if value["key"] == "web")
            arguments = self.compose_args(entry, journal["state"])
            backup = job / "postgres.dump"
            with os.fdopen(os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as output:
                self.command([*arguments, "exec", "-T", "postgres", "sh", "-c",
                              'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc'], output=output, timeout=300)
            schema = self.command([*arguments, "exec", "-T", "postgres", "sh", "-c",
                                   'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --schema-only --no-owner --no-privileges'])
            # pg_dump 17+ adds a random \restrict token unrelated to the schema.
            stable_schema = "\n".join(line for line in schema.splitlines() if not line.startswith(("\\restrict", "\\unrestrict", "--")))
            journal["runtime"]["database_schema"] = hashlib.sha256(stable_schema.encode()).hexdigest()
            journal["runtime"]["database_backup"] = str(backup)
            write_json(job / "journal.json", journal)

    def activate(self, journal: dict, job: Path) -> None:
        if journal["runtime"]["kind"] == "local":
            entry = journal["components"][0]
            original = Path(entry["original"]) / ".venv"
            previous = job / "previous-venv"
            if original.exists() or original.is_symlink():
                original.rename(previous)
            original.symlink_to(journal["runtime"]["venv"], target_is_directory=True)
            journal["runtime"]["venv_switched"] = True
            return
        for entry in journal["components"]:
            original, staged = Path(entry["original"]), Path(entry["staged"])
            for name in PATCH_FILES[entry["key"]]:
                if (staged / name).is_file():
                    # Copy validated patch output, not secrets or obsolete env changes.
                    (original / name).write_bytes((staged / name).read_bytes())
            item = next(value for value in journal["runtime"]["components"] if value["key"] == entry["key"])
            arguments = self.compose_args(entry, journal["state"], overlay=item["candidate"])
            self.command([*arguments, "up", "-d", "--no-build", "--pull", "never", *item["services"]], capture=False, timeout=300)

    def verify(self, journal: dict, job: Path) -> None:
        state = journal["state"]
        if journal["runtime"]["kind"] == "local":
            self.verify_local(journal, job)
            return
        if state.get("cli_managed") and state.get("cli_interface") == "tui":
            entry = journal["components"][0]
            item = journal["runtime"]["components"][0]
            self.command([*self.compose_args(entry, state, overlay=item["candidate"]), "run", "--rm", "--no-deps", "-T",
                          "--entrypoint", "python3", "scanner", "-c", TUI_PROBE], capture=False, timeout=120)
            return
        paths = {item["key"]: item["original"] for item in journal["components"]}
        self.shell_step("verify", journal, job, paths=paths)
        if state.get("cli_interface") == "both":
            entry = next(item for item in journal["components"] if item["key"] == "cli")
            item = next(item for item in journal["runtime"]["components"] if item["key"] == "cli")
            self.command([*self.compose_args(entry, state, overlay=item["candidate"]), "exec", "-T", "api",
                          "python3", "-c", TUI_PROBE], capture=False, timeout=120)

    def verify_local(self, journal: dict, job: Path) -> None:
        entry = journal["components"][0]
        python = str(Path(journal["runtime"]["venv"]) / "bin/python")
        cwd = Path(entry["original"])
        interface = journal["state"].get("cli_interface")
        if interface in {"tui", "both"}:
            self.command([python, "-c", TUI_PROBE], capture=False, cwd=cwd, timeout=120)
        if interface in {"api", "both"}:
            for module, endpoint in (("api", "/health"), ("mcp", "/sse")):
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    port = listener.getsockname()[1]
                if module == "api":
                    command = [python, "-m", "uvicorn", "bugtrace.api.main:app", "--host", "127.0.0.1", "--port", str(port)]
                else:
                    command = [python, "-m", "bugtrace", "mcp", "--sse", "--host", "127.0.0.1", "--port", str(port)]
                with (job / f"local-{module}.log").open("w") as output:
                    process = subprocess.Popen(command, cwd=cwd, env=self.environment, stdout=output, stderr=output)
                    try:
                        ready = False
                        deadline = time.monotonic() + LOCAL_READY_TIMEOUT_SECONDS
                        while time.monotonic() < deadline:
                            if process.poll() is not None:
                                break
                            remaining = deadline - time.monotonic()
                            if remaining <= 0:
                                break
                            try:
                                with urllib.request.urlopen(f"http://127.0.0.1:{port}{endpoint}", timeout=min(1, remaining)) as response:
                                    ready = response.status == 200
                                if ready:
                                    break
                            except OSError:
                                time.sleep(min(0.5, max(0, deadline - time.monotonic())))
                        if not ready:
                            return_code = process.poll()
                            reason = (f"exited with code {return_code} before readiness" if return_code is not None
                                      else f"readiness timed out after {LOCAL_READY_TIMEOUT_SECONDS:g}s")
                            raise ReleaseError(f"Local {module} {reason}; inspect {job.name}/local-{module}.log.")
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()

    def stop_candidate(self, journal: dict, job: Path) -> None:
        if journal.get("runtime", {}).get("kind") != "docker":
            return
        for item in reversed(journal["runtime"]["components"]):
            entry = next(value for value in journal["components"] if value["key"] == item["key"])
            applications = [name for name in item["services"] if name != "postgres"]
            if applications:
                self.command([*self.compose_args(entry, journal["state"], overlay=item["candidate"]), "stop", *applications], capture=False, timeout=180)

    def rollback(self, journal: dict, job: Path) -> None:
        if journal.get("runtime", {}).get("kind") == "local":
            original = Path(journal["components"][0]["original"]) / ".venv"
            previous = job / "previous-venv"
            # A signal may interrupt between the rename and symlink operations.
            if previous.exists() or previous.is_symlink():
                if original.is_symlink():
                    original.unlink()
                elif original.exists():
                    raise ReleaseError("Local environment changed during recovery; previous environment was kept.")
                previous.rename(original)
            elif original.is_symlink() and os.readlink(original) == journal["runtime"].get("venv"):
                original.unlink()
            return
        state = journal["state"]
        if journal.get("runtime", {}).get("database_schema"):
            entry = next(value for value in journal["components"] if value["key"] == "web")
            schema = self.command([*self.compose_args(entry, state), "exec", "-T", "postgres", "sh", "-c",
                                   'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --schema-only --no-owner --no-privileges'])
            stable = "\n".join(line for line in schema.splitlines() if not line.startswith(("\\restrict", "\\unrestrict", "--")))
            if hashlib.sha256(stable.encode()).hexdigest() != journal["runtime"]["database_schema"]:
                raise ReleaseError(f"Database schema changed. Database backup: {journal['runtime']['database_backup']}; review the migration before restoring it.")
        # Do not run old application code against an incompatible new schema.
        all_running = True
        for item in journal.get("runtime", {}).get("components", []):
            entry = next(value for value in journal["components"] if value["key"] == item["key"])
            running = [value["service"] for value in item["containers"] if value["running"] and value["service"] in item["services"]]
            all_running = all_running and set(running) == set(item["services"])
            if running:
                self.command([*self.compose_args(entry, state, overlay=item["previous"]), "up", "-d", "--no-build", "--pull", "never", *running], capture=False, timeout=300)
        if all_running and journal.get("runtime", {}).get("components"):
            paths = {item["key"]: item["original"] for item in journal["components"]}
            if state.get("cli_managed") and state.get("cli_interface") == "tui":
                return  # The scanner service is interactive and normally stopped.
            self.shell_step("verify", journal, job, paths=paths)
