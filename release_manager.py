#!/usr/bin/env python3
"""Pinned releases and recoverable updates. Uses only the Python standard library.

All Git fetches, configuration validation and builds finish before activation.
Runtime operations are separated from the source transaction for offline tests.
The journal and configuration backups are private local files, never releases.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

from release_errors import ReleaseError


ROOT = Path(__file__).resolve().parent
DEFAULT_MANIFEST = ROOT / "release-manifest.json"
NAMES = {"cli": "BugTraceAI-CLI", "web": "BugTraceAI-WEB", "api": "BugTraceAI-API"}
_VERSION_PATTERN = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$")
CONFIG_FILES = {
    "cli": (".env", ".bugtrace-install.env", "bugtraceaicli.conf", "bugtrace/data/waf_strategy_learning.json"),
    "web": (".env.docker", "backend/.env"),
    "api": (".env",),
}


def compare_versions(left: str, right: str) -> int:
    """Compare launcher component versions using SemVer precedence."""
    def parse(value: str):
        match = _VERSION_PATTERN.fullmatch(value)
        if not match:
            raise ReleaseError(f"Cannot safely compare installed version {value!r}.")
        major, minor, patch, prerelease = match.groups()
        return (int(major), int(minor), int(patch)), prerelease.split(".") if prerelease else None

    left_core, left_pre = parse(left)
    right_core, right_pre = parse(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        if left_pre is right_pre:
            return 0
        return 1 if left_pre is None else -1
    for left_item, right_item in zip(left_pre, right_pre):
        if left_item == right_item:
            continue
        left_numeric, right_numeric = left_item.isdigit(), right_item.isdigit()
        if left_numeric and right_numeric:
            return (int(left_item) > int(right_item)) - (int(left_item) < int(right_item))
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return (left_item > right_item) - (left_item < right_item)
    return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))
PATCH_FILES = {
    "cli": {"docker-compose.yml"},
    "web": {"docker-compose.yml", "nginx.conf", "backend/Dockerfile"},
    "api": {"docker-compose.yml"},
}



def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise ReleaseError(f"Cannot read valid JSON from {path.name}.") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"{path.name} must contain a JSON object.")
    return value


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def run(command: list[str], *, cwd: Path | None = None, capture: bool = True,
        timeout: int | None = 180, output=None) -> str:
    try:
        result = subprocess.run(command, cwd=cwd, text=output is None,
                                stdout=output if output is not None else (subprocess.PIPE if capture else None),
                                stderr=subprocess.PIPE if capture else None, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseError(f"Could not finish {Path(command[0]).name}; check connectivity and dependencies.") from error
    if result.returncode:
        # Git/Compose output may include URL credentials or env substitutions.
        raise ReleaseError(f"{Path(command[0]).name} failed (exit {result.returncode}).")
    return result.stdout.strip() if capture and output is None else ""


def git(path: Path, *arguments: str) -> str:
    return run(["git", "-C", str(path), *arguments])


@dataclass(frozen=True)
class Component:
    key: str
    repository: str
    ref: str
    version: str
    commit: str = ""


@dataclass(frozen=True)
class Manifest:
    release: str
    channel: str
    launcher_version: str
    components: dict[str, Component]

    @classmethod
    def load(cls, path: Path = DEFAULT_MANIFEST) -> Manifest:
        data = read_json(path)
        if type(data.get("schema_version")) is not int or data["schema_version"] != 1 or data.get("channel") not in {"beta", "stable"}:
            raise ReleaseError("Unsupported release manifest schema or channel.")
        if not isinstance(data.get("components"), dict):
            raise ReleaseError("Release components must be an object.")
        components = {}
        for key in NAMES:
            item = data.get("components", {}).get(key, {})
            if not isinstance(item, dict):
                raise ReleaseError(f"Invalid release metadata for {key}.")
            repository, ref, version = (item.get(name, "") for name in ("repository", "ref", "version"))
            if not all(isinstance(value, str) and value for value in (repository, ref, version)):
                raise ReleaseError(f"Incomplete release metadata for {key}.")
            if not re.fullmatch(r"refs/tags/[A-Za-z0-9][A-Za-z0-9._-]*", ref):
                raise ReleaseError(f"{key} must use a fixed release tag, not a branch.")
            if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
                raise ReleaseError(f"Invalid {key} version in release manifest.")
            if ref != f"refs/tags/v{version}":
                raise ReleaseError(f"{key} tag and version disagree.")
            commit = item.get("commit", "")
            if not isinstance(commit, str) or (commit and not re.fullmatch(r"[0-9a-f]{40}", commit)):
                raise ReleaseError(f"Invalid {key} commit in release manifest.")
            components[key] = Component(key, repository, ref, version, commit)
        release, launcher = data.get("release", ""), data.get("launcher_version", "")
        if not isinstance(release, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", release) or not isinstance(launcher, str) or not re.fullmatch(r"\d+\.\d+\.\d+", launcher):
            raise ReleaseError("Release identifier and Launcher version are required.")
        return cls(release, data["channel"], launcher, components)


def selected_components(state: dict) -> list[str]:
    """Keep the installed inventory, including pre-profile state files."""
    mode = state.get("mode", "")
    def flag(name: str, fallback: bool = False) -> bool:
        value = state.get(name, fallback)
        if value in (True, "true"):
            return True
        if value in (False, "false"):
            return False
        raise ReleaseError(f"Invalid saved installation flag: {name}.")
    selected = []
    if flag("install_btai"):
        selected.append("api")
    if flag("install_cli", mode in {"cli", "full"}) or flag("mcp_cli_enabled"):
        selected.append("cli")
    if flag("install_web", mode in {"web", "full", "custom", "recon"}):
        selected.append("web")
    if not selected:
        raise ReleaseError("The saved installation has no selected components.")
    return selected


def ensure_release_tags_available(manifest: Manifest, components: list[str]) -> None:
    """Fail before planning or cloning and report every unavailable pinned tag."""
    unavailable = []
    for key in components:
        target = manifest.components[key]
        try:
            patterns = [target.ref]
            if target.commit:
                patterns.append(f"{target.ref}^{{}}")
            result = run(["git", "ls-remote", "--exit-code", target.repository, *patterns])
        except ReleaseError:
            unavailable.append(f"{NAMES[key]} {target.version}")
            continue
        refs = {ref: sha for sha, ref in (line.split("\t", 1) for line in result.splitlines() if "\t" in line)}
        actual = refs.get(f"{target.ref}^{{}}") or refs.get(target.ref)
        if not actual:
            unavailable.append(f"{NAMES[key]} {target.version}")
        elif target.commit and actual != target.commit:
            unavailable.append(f"{NAMES[key]} {target.version} (tag commit differs from manifest)")
    if unavailable:
        missing = "\n".join(f"  - {component}" for component in unavailable)
        raise ReleaseError(
            f"These pinned release tags are unavailable, unreachable, or changed:\n{missing}\n"
            "The release combination is not ready; no product checkout was created."
        )


def normalize_state(state: dict) -> dict:
    result = dict(state)
    for name in ("cli_managed", "install_cli", "install_web", "install_btai", "mcp_cli_enabled", "mcp_recon_enabled", "mcp_kali_enabled"):
        if name in result:
            if result[name] not in (True, False, "true", "false"):
                raise ReleaseError(f"Invalid saved installation flag: {name}.")
            result[name] = result[name] in (True, "true")
    selected = selected_components(result)
    for key, flag in (("cli", "install_cli"), ("web", "install_web"), ("api", "install_btai")):
        result.setdefault(flag, key in selected)
    result.setdefault("cli_runtime", "docker")
    result.setdefault("cli_interface", "api")
    result.setdefault("cli_managed", False)
    result.setdefault("mcp_cli_enabled", "cli" in selected and result["cli_interface"] != "tui")
    return result


def component_paths(state: dict, install_dir: Path) -> dict[str, Path]:
    paths = {key: install_dir / name for key, name in NAMES.items()}
    if state.get("cli_managed") in (True, "true") and state.get("cli_checkout"):
        paths["cli"] = Path(state["cli_checkout"]).expanduser().resolve()
    return paths


def runtime_config_paths(key: str, path: Path) -> list[str]:
    files = list(CONFIG_FILES[key])
    if key == "api" and (path / "config").is_dir():
        files.extend(str(item.relative_to(path)) for item in (path / "config").rglob("*") if item.is_file())
    return sorted(set(files))


def fingerprint(path: Path) -> str:
    if path.is_symlink():
        return "link:" + os.readlink(path)
    if not path.is_file():
        return "missing"
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        raise ReleaseError(f"Configuration symlink requires manual handling: {source.name}.")
    shutil.copy2(source, destination)


@contextmanager
def installation_lock(install_dir: Path):
    path = install_dir / ".release-update.lock"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as error:
        raise ReleaseError("Another update is running, or an interrupted update needs recovery. Run update --recover first.") from error
    with os.fdopen(descriptor, "w") as stream:
        json.dump({"pid": os.getpid(), "created_at": time.time()}, stream)
    try:
        yield
    finally:
        path.unlink(missing_ok=True)


class SourceTransaction:
    """Prepare a complete cohort; activate only after the runtime is ready."""

    def __init__(self, manifest: Manifest, install_dir: Path, runtime, launcher_version: str):
        self.manifest = manifest
        self.install_dir = install_dir.resolve()
        self.state_file = self.install_dir / ".launcher-state"
        self.state = normalize_state(read_json(self.state_file))
        self.selected = selected_components(self.state)
        self.paths = component_paths(self.state, self.install_dir)
        if self.state.get("cli_managed"):
            profile = self.paths["cli"] / ".bugtrace-install.env"
            if profile.is_file():
                values = dict(line.split("=", 1) for line in profile.read_text().splitlines() if "=" in line)
                interface, mode = values.get("INTERFACE"), values.get("RUNTIME")
                if interface not in {"tui", "api", "both"} or mode not in {"local", "docker"}:
                    raise ReleaseError("Invalid saved CLI runtime profile; repair it before updating.")
                self.state.update(cli_interface=interface, cli_runtime=mode, cli_global=values.get("GLOBAL", "no"),
                                  mcp_cli_enabled=interface != "tui")
        self.runtime = runtime
        self.launcher_version = launcher_version
        if tuple(map(int, launcher_version.split("."))) < tuple(map(int, manifest.launcher_version.split("."))):
            raise ReleaseError(f"This release requires Launcher {manifest.launcher_version} or newer.")
        self.journal: dict = {}
        self.job: Path | None = None

    def preview(self) -> dict:
        self._reject_downgrades()
        ensure_release_tags_available(self.manifest, self.selected)
        components = []
        for key in self.selected:
            path = self.paths[key]
            current = (path / "VERSION").read_text().strip() if (path / "VERSION").is_file() else "unknown"
            target = self.manifest.components[key]
            components.append({"component": key, "current": current, "target": target.version, "ref": target.ref})
        return {"release": self.manifest.release, "channel": self.manifest.channel,
                "installed_release": self.state.get("release") or "unrecorded",
                "launcher_minimum": self.manifest.launcher_version,
                "launcher_running": self.launcher_version,
                "install_profile": self.state.get("install_profile") or self.state.get("mode"),
                "runtime": self.state.get("cli_runtime", "docker"), "components": components}

    def _reject_downgrades(self) -> None:
        downgrades = []
        for key in self.selected:
            version_file = self.paths[key] / "VERSION"
            current = version_file.read_text().strip() if version_file.is_file() else "unknown"
            if current == "unknown":
                continue
            target = self.manifest.components[key].version
            if compare_versions(current, target) > 0:
                downgrades.append(f"{NAMES[key]} {current} -> {target}")
        if downgrades:
            details = "\n".join(f"  - {item}" for item in downgrades)
            raise ReleaseError(
                f"Installed release: {self.state.get('release') or 'unrecorded'}; selected release: "
                f"{self.manifest.release}. The selected release would downgrade installed components:\n"
                f"{details}\nNo files or services were changed. Use a matching or newer release "
                "manifest when it is available."
            )

    def checkpoint(self, phase: str) -> None:
        self.journal["phase"] = phase
        write_json(self.job / "journal.json", self.journal)
        marker = self.install_dir / ".updates" / "active.json"
        if phase in {"activating", "verifying", "recovering", "recovery_required"}:
            write_json(marker, {"journal": str(self.job / "journal.json")})
        elif phase in {"complete", "rolled_back"}:
            marker.unlink(missing_ok=True)

    def prepare(self) -> None:
        if (self.install_dir / ".updates" / "active.json").exists():
            raise ReleaseError("An earlier update needs recovery. Run update --recover before another update.")
        self._reject_downgrades()
        self.runtime.preflight(self.state, self.paths)
        self.job = self.install_dir / ".updates" / (time.strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8])
        self.job.mkdir(parents=True, mode=0o700)
        self.job.parent.chmod(0o700)
        state_snapshot = self.job / "previous-state.json"
        copy_file(self.state_file, state_snapshot)
        self.journal = {"schema_version": 1, "release": self.manifest.release, "state_sha": fingerprint(self.state_file),
                        "state_file": str(self.state_file), "components": [], "activated": [], "runtime": {},
                        "state": self.state, "launcher_version": self.launcher_version}
        self.checkpoint("preparing")
        for key in self.selected:
            original = self.paths[key]
            if not original.is_dir() or git(original, "rev-parse", "--show-toplevel") != str(original):
                raise ReleaseError(f"{NAMES[key]} is not a complete checkout; repair it before updating.")
            if git(original, "diff", "--name-only", "--cached"):
                raise ReleaseError(f"{NAMES[key]} has staged changes; they were preserved. Commit them before updating.")
            dirty = git(original, "diff", "--name-only").splitlines()
            config_files = runtime_config_paths(key, original)
            allowed = PATCH_FILES[key] | set(config_files)
            if set(dirty) - allowed:
                raise ReleaseError(f"{NAMES[key]} has local source edits; they were preserved. Commit or move them before updating.")
            old_head = git(original, "rev-parse", "HEAD")
            old_branch = git(original, "branch", "--show-current")
            target = self.manifest.components[key]
            origin = git(original, "remote", "get-url", "origin")
            if origin.rstrip("/").removesuffix(".git").lower() != target.repository.rstrip("/").removesuffix(".git").lower():
                raise ReleaseError(f"{NAMES[key]} uses a different development repository. Use its direct update workflow; this checkout was preserved.")
            staged = self.job / "sources" / NAMES[key]
            staged.parent.mkdir(exist_ok=True)
            run(["git", "clone", "--quiet", "--no-hardlinks", "--no-local", str(original), str(staged)])
            # Validate generated launcher patches on a copy, never on the live checkout.
            for name in dirty:
                copy_file(original / name, staged / name)
            self.runtime.validate_existing(key, staged, self.state)
            try:
                git(staged, "fetch", "--quiet", "--depth", "1", "--no-tags", target.repository, target.ref)
            except ReleaseError as error:
                raise ReleaseError(f"{NAMES[key]} {target.version} is unavailable. No installed component was changed.") from error
            new_head = git(staged, "rev-parse", "FETCH_HEAD^{commit}")
            if target.commit and new_head != target.commit:
                raise ReleaseError(f"{NAMES[key]} release commit does not match the manifest.")
            git(staged, "checkout", "--quiet", "--detach", new_head)
            if not (staged / "VERSION").is_file() or (staged / "VERSION").read_text().strip() != target.version:
                raise ReleaseError(f"{NAMES[key]} VERSION disagrees with its release tag.")
            candidate_files = set(git(staged, "ls-files").splitlines())
            # Git can overwrite ignored untracked files during checkout too.
            collisions = set(git(original, "ls-files", "--others").splitlines()) & candidate_files
            if collisions:
                raise ReleaseError(f"{NAMES[key]} contains untracked files that the release would replace. Preserve/merge them manually first.")
            saved = self.job / "configuration" / key
            digests = {}
            saved_files = sorted(set(config_files) | set(dirty))
            for name in saved_files:
                value = original / name
                digests[name] = fingerprint(value)
                if value.is_file():
                    copy_file(value, saved / name)
                    # Generated patches are recreated against the new source.
                    if name in config_files:
                        copy_file(value, staged / name)
            entry = {"key": key, "original": str(original), "staged": str(staged), "old_head": old_head,
                     "old_branch": old_branch, "new_head": new_head, "version": target.version, "ref": target.ref,
                     "config_files": config_files, "saved_files": saved_files, "dirty": dirty, "digests": digests}
            self.journal["components"].append(entry)
            self.checkpoint("preparing")
        self.runtime.prepare(self.journal, self.job)
        self.checkpoint("prepared")

    def assert_unchanged(self) -> None:
        if fingerprint(self.state_file) != self.journal["state_sha"]:
            raise ReleaseError("Installation preferences changed during preparation; update was cancelled.")
        for entry in self.journal["components"]:
            original = Path(entry["original"])
            if git(original, "rev-parse", "HEAD") != entry["old_head"]:
                raise ReleaseError("A checkout changed during preparation; update was cancelled.")
            if git(original, "branch", "--show-current") != entry["old_branch"] or git(original, "diff", "--name-only", "--cached"):
                raise ReleaseError("A branch or staged edit changed during preparation; update was cancelled.")
            if runtime_config_paths(entry["key"], original) != entry["config_files"]:
                raise ReleaseError("Configuration files changed during preparation; update was cancelled.")
            if set(git(original, "diff", "--name-only").splitlines()) != set(entry["dirty"]):
                raise ReleaseError("Local edits changed during preparation; update was cancelled.")
            for name, digest in entry["digests"].items():
                if fingerprint(original / name) != digest:
                    raise ReleaseError("Local configuration changed during preparation; update was cancelled.")

    def activate(self) -> None:
        self.assert_unchanged()
        # A fetch into the original object store does not change its files/branch.
        for entry in self.journal["components"]:
            git(Path(entry["original"]), "fetch", "--quiet", "--no-tags", entry["staged"], entry["new_head"])
        self.checkpoint("activating")
        self.runtime.quiesce(self.journal, self.job)
        self.checkpoint("activating")
        for entry in self.journal["components"]:
            original = Path(entry["original"])
            self.journal["activated"].append(entry["key"])
            self.checkpoint("activating")
            for name in entry["dirty"]:
                # All of these bytes were backed up and validated beforehand.
                head_files = set(git(original, "ls-files").splitlines())
                if name in head_files:
                    content = subprocess.run(["git", "-C", str(original), "show", f"HEAD:{name}"], capture_output=True)
                    if content.returncode:
                        raise ReleaseError("Could not restore a verified generated patch.")
                    (original / name).write_bytes(content.stdout)
            git(original, "checkout", "--quiet", "--detach", entry["new_head"])
            for name in entry["config_files"]:
                saved = self.job / "configuration" / entry["key"] / name
                if saved.is_file():
                    copy_file(saved, original / name)
        self.runtime.activate(self.journal, self.job)
        self.checkpoint("verifying")
        self.runtime.verify(self.journal, self.job)
        updated = dict(self.state)
        updated["version"] = self.launcher_version
        updated["release"] = self.manifest.release
        updated["release_components"] = {item["key"]: {"version": item["version"], "ref": item["ref"], "commit": item["new_head"]}
                                         for item in self.journal["components"]}
        updated["last_update"] = str(self.job)
        write_json(self.state_file, updated)
        self.checkpoint("complete")

    def rollback(self) -> None:
        self.checkpoint("recovering")
        self.runtime.stop_candidate(self.journal, self.job)
        for entry in reversed(self.journal["components"]):
            if entry["key"] not in self.journal["activated"]:
                continue
            original = Path(entry["original"])
            # Candidate generated patches are known; user files are never cleaned.
            dirty = git(original, "diff", "--name-only").splitlines()
            for name in dirty:
                if name not in PATCH_FILES[entry["key"]] | set(entry["config_files"]):
                    raise ReleaseError("Recovery found new user edits. Source backups were kept for manual recovery.")
                content = subprocess.run(["git", "-C", str(original), "show", f"HEAD:{name}"], capture_output=True)
                if content.returncode == 0:
                    (original / name).write_bytes(content.stdout)
            git(original, "checkout", "--quiet", "--detach", entry["old_head"])
            if entry["old_branch"]:
                git(original, "checkout", "--quiet", entry["old_branch"])
            for name in entry["saved_files"]:
                saved = self.job / "configuration" / entry["key"] / name
                if saved.is_file():
                    copy_file(saved, original / name)
        copy_file(self.job / "previous-state.json", self.state_file)
        self.runtime.rollback(self.journal, self.job)
        self.checkpoint("rolled_back")

    def execute(self) -> None:
        with installation_lock(self.install_dir):
            try:
                self.prepare()
                self.activate()
            except BaseException:
                if self.job and self.journal.get("phase") in {"activating", "verifying", "complete"}:
                    try:
                        self.rollback()
                    except BaseException as recovery_error:
                        self.checkpoint("recovery_required")
                        raise ReleaseError(f"Update needs recovery. Backups and journal: {self.job}") from recovery_error
                elif self.job:
                    self.checkpoint("preparation_failed")
                raise


def preview_text(value: dict) -> str:
    lines = [f"Installed release: {value['installed_release']}",
             f"Selected release: {value['release']} ({value['channel']})",
             f"Launcher: {value['launcher_running']} (minimum for selected release: {value['launcher_minimum']})",
             f"Installed selection: {value['install_profile']}"]
    lines.extend(f"  {NAMES[item['component']]}: {item['current']} -> {item['target']}" for item in value["components"])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["preview", "update", "recover", "ref", "record", "available", "checkout"])
    parser.add_argument("--manifest", type=Path, default=Path(os.environ.get("BUGTRACEAI_RELEASE_MANIFEST", DEFAULT_MANIFEST)))
    parser.add_argument("--install-dir", type=Path, default=Path(os.environ.get("BUGTRACEAI_DIR", Path.home() / "bugtraceai")))
    parser.add_argument("--launcher", type=Path, default=ROOT / "launcher.sh")
    parser.add_argument("--component", choices=list(NAMES))
    parser.add_argument("--components", nargs="+", choices=list(NAMES))
    parser.add_argument("--checkout", type=Path)
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        if arguments.action == "recover":
            from release_runtime import Runtime
            recover_installation(arguments.install_dir.resolve(), Runtime(arguments.launcher))
            return 0
        manifest = Manifest.load(arguments.manifest)
        if arguments.action == "available":
            ensure_release_tags_available(manifest, arguments.components or list(NAMES))
            print(f"All selected release tags are available for {manifest.release}.")
            return 0
        if arguments.action == "checkout":
            if not arguments.component or not arguments.checkout:
                raise ReleaseError("Component and checkout path are required.")
            checkout_release(manifest.components[arguments.component], arguments.checkout)
            return 0
        if arguments.action == "ref":
            if not arguments.component:
                raise ReleaseError("A component is required.")
            item = manifest.components[arguments.component]
            print(item.ref.removeprefix("refs/tags/"))
            return 0
        if arguments.action == "record":
            record_installed_release(manifest, arguments.install_dir)
            return 0
        from release_runtime import Runtime
        version = (arguments.launcher.parent / "VERSION").read_text().strip()
        runtime = Runtime(arguments.launcher)
        transaction = SourceTransaction(manifest, arguments.install_dir, runtime, version)
        if arguments.action == "preview":
            value = transaction.preview()
            print(json.dumps(value) if arguments.json else preview_text(value))
        else:
            print(preview_text(transaction.preview()), flush=True)
            transaction.execute()
            print(f"Update complete; all selected components verified. Recovery journal: {transaction.job}")
        return 0
    except (ReleaseError, OSError, ValueError) as error:
        print(f"Update stopped: {error}", file=sys.stderr)
        return 1


def record_installed_release(manifest: Manifest, install_dir: Path) -> None:
    state_file = install_dir / ".launcher-state"
    state = read_json(state_file)
    paths = component_paths(state, install_dir)
    components = {}
    for key in selected_components(state):
        path = paths[key]
        target = manifest.components[key]
        actual_version = (path / "VERSION").read_text().strip()
        components[key] = {"version": actual_version, "commit": git(path, "rev-parse", "HEAD"),
                           "ref": target.ref if actual_version == target.version else "development-checkout"}
    state["release"] = manifest.release if all(item["ref"] != "development-checkout" for item in components.values()) else "development-checkout"
    state["release_components"] = components
    write_json(state_file, state)


def verify_installed_release(manifest: Manifest, paths: dict[str, Path], selected: list[str]) -> None:
    for key in selected:
        item, path = manifest.components[key], paths[key]
        head = git(path, "rev-parse", "HEAD")
        if (path / "VERSION").read_text().strip() != item.version or head != git(path, "rev-parse", item.ref + "^{commit}"):
            raise ReleaseError(f"{NAMES[key]} does not match the selected release tag; verification was not passed.")
        if item.commit and head != item.commit:
            raise ReleaseError(f"{NAMES[key]} does not match the pinned release commit.")


def checkout_release(component: Component, destination: Path) -> None:
    """Fresh installation only. Existing checkouts require the update transaction."""
    if destination.exists():
        if not (destination / "VERSION").is_file() or (destination / "VERSION").read_text().strip() != component.version:
            raise ReleaseError(f"{NAMES[component.key]} already exists at another version. Use update; no files were replaced.")
        git(destination, "fetch", "--quiet", "--depth", "1", "--no-tags", component.repository, component.ref)
        if git(destination, "rev-parse", "HEAD") != git(destination, "rev-parse", "FETCH_HEAD^{commit}"):
            raise ReleaseError("An existing checkout differs from the release tag. Use update; local code was preserved.")
        if component.commit and git(destination, "rev-parse", "HEAD") != component.commit:
            raise ReleaseError("Existing release commit disagrees with the manifest.")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        run(["git", "clone", "--quiet", "--depth", "1", "--branch", component.ref.removeprefix("refs/tags/"),
             "--single-branch", component.repository, str(destination)])
        if (destination / "VERSION").read_text().strip() != component.version:
            raise ReleaseError(f"{NAMES[component.key]} tag and VERSION disagree.")
        if component.commit and git(destination, "rev-parse", "HEAD") != component.commit:
            raise ReleaseError("Release commit disagrees with the manifest.")
    except (ReleaseError, OSError):
        # Quarantine only the checkout this invocation just created; no deletion.
        if destination.exists():
            destination.rename(destination.with_name(destination.name + ".incomplete-" + uuid.uuid4().hex[:8]))
        raise


def recover_installation(install_dir: Path, runtime) -> None:
    """Recovery depends on the saved journal, even when current state is damaged."""
    lock = install_dir / ".release-update.lock"
    if lock.exists():
        pid = read_json(lock).get("pid")
        if isinstance(pid, int):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise ReleaseError("An update process is still running. Recovery was not started.")
        lock.unlink()
    with installation_lock(install_dir):
        marker = install_dir / ".updates" / "active.json"
        if marker.exists():
            selected = Path(read_json(marker).get("journal", "")).resolve()
            if selected.parent.parent != (install_dir / ".updates").resolve() or selected.name != "journal.json":
                raise ReleaseError("The recovery journal path is invalid.")
            candidates = [selected]
        else:
            candidates = sorted((install_dir / ".updates").glob("*/journal.json"), key=lambda path: path.stat().st_mtime_ns, reverse=True)
        if not candidates:
            raise ReleaseError("No update journal is available.")
        journal = read_json(candidates[0])
        if journal.get("phase") in {"complete", "rolled_back", "preparation_failed", "preparing", "prepared"}:
            print("No partially activated update needs recovery.")
            return
        transaction = object.__new__(SourceTransaction)
        transaction.install_dir = install_dir
        transaction.state_file = install_dir / ".launcher-state"
        transaction.runtime = runtime
        transaction.job = candidates[0].parent
        transaction.journal = journal
        transaction.rollback()
        print("Previous source versions and runtime restored. Configuration and database backups were kept.")


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Update interrupted; inspect update --recover if recovery did not complete.", file=sys.stderr)
        raise SystemExit(130)
