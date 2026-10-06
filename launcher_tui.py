#!/usr/bin/env python3
"""Polished, dependency-isolated terminal front end for the universal installer."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from textual.app import App, ComposeResult
from textual.screen import ModalScreen
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, Checkbox, OptionList, Select, Static
from textual.widgets.option_list import Option
from installer_core import InstallProfile, parse_install_profiles


ROOT = Path(__file__).resolve().parent
PROFILE_CATALOG = ROOT / "installation-profiles.tsv"


def has_tui(profile: InstallProfile) -> bool:
    return profile.cli_interface in {"tui", "both"}


def load_profiles(path: Path = PROFILE_CATALOG) -> tuple[InstallProfile, ...]:
    profiles = parse_install_profiles(path.read_text(encoding="utf-8"))
    if not profiles:
        raise ValueError("The installation profile catalog is empty")
    return profiles


def included_products(profile: InstallProfile) -> tuple[str, ...]:
    """Return user-facing component names derived from the shared profile data."""
    products: list[str] = []
    if profile.install_web:
        products.append("BugTraceAI-WEB · dashboard and database")
    if profile.install_cli:
        if has_tui(profile):
            products.append("BugTraceAI-CLI · terminal workspace")
        if profile.cli_interface in {"api", "both"}:
            products.append("BugTraceAI-CLI · web-scanning REST API + MCP")
    if profile.install_api:
        products.append("BugTraceAI-API · API-target REST API + MCP")
    return tuple(products)


def install_command(profile: InstallProfile, runtime: str, global_command: bool) -> list[str]:
    return ["install", "--profile", profile.key, "--runtime", runtime,
            "--global", "yes" if global_command else "no"]


class UpdateReview(ModalScreen[bool]):
    CSS = """
    UpdateReview { align: center middle; background: #1A0F2EDD; }
    #update-review { width: 76; height: auto; max-height: 90%; padding: 1 2;
        background: #211338; border: round #FF7F50; }
    #update-summary { height: auto; margin-bottom: 1; }
    #update-actions { height: 3; align-horizontal: right; }
    """
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, plan: dict):
        super().__init__()
        self.plan = plan

    def compose(self) -> ComposeResult:
        from release_manager import preview_text
        with Vertical(id="update-review"):
            yield Static("[bold #FF7F50]UPDATE INSTALLATION[/]", classes="panel-title")
            yield Static(preview_text(self.plan) + "\n\nYour saved profile, ports, provider settings and data are kept.\n"
                         "All builds finish before switching. Services must pass health checks.\n"
                         "Recovery backups stay in the installation's .updates directory.",
                         id="update-summary", markup=False)
            with Horizontal(id="update-actions"):
                yield Button("Cancel", id="cancel-update")
                yield Button("Apply update", id="apply-update", variant="primary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "apply-update")

    def action_cancel(self) -> None:
        self.dismiss(False)


class LauncherTUI(App[int]):
    """A single profile chooser prevents the repeated CLI-interface questions."""

    TITLE = "BugTraceAI Launcher"
    SUB_TITLE = "Universal installer"
    CSS = """
    Screen {
        background: #1A0F2E;
        color: #F8F4FC;
        layout: vertical;
    }
    #brand {
        height: 1;
        padding: 0 2;
        background: #24163B;
        border-bottom: solid #FF7F50;
        content-align: left middle;
    }
    #brand-name { width: auto; }
    #brand-caption {
        width: 1fr;
        height: 1;
        color: #A899C2;
        content-align: right middle;
        padding-right: 2;
    }
    #intro {
        height: 2;
        margin: 0 2;
        color: #B9A9D3;
        content-align: left middle;
    }
    #workspace {
        height: 1fr;
        min-height: 12;
        margin: 0 2;
    }
    #profile-panel {
        width: 38%;
        min-width: 31;
        border: round #594477;
        background: #1A0F2E;
        padding: 0 1;
    }
    #profile-panel-title, .panel-title {
        height: 1;
        color: #FF7F50;
        text-style: bold;
        margin-bottom: 1;
    }
    #profile-list {
        height: 1fr;
        border: none;
        background: #1A0F2E;
        scrollbar-size: 0 0;
    }
    OptionList > .option-list--option {
        height: 2;
        padding: 0 1;
        color: #D6CBE5;
    }
    OptionList > .option-list--option-highlighted {
        background: #3D2B5F;
        color: #FF9B75;
        text-style: bold;
    }
    #details-panel {
        width: 1fr;
        margin-left: 1;
        border: round #594477;
        background: #211338;
        padding: 1 2;
    }
    #profile-name {
        height: 2;
        color: #F8F4FC;
        text-style: bold;
        content-align: left middle;
    }
    #profile-description {
        height: auto;
        min-height: 2;
        color: #B9A9D3;
        margin-bottom: 1;
    }
    #products-title { margin-top: 0; }
    #products {
        height: auto;
        min-height: 3;
        color: #E9E0F5;
        margin-bottom: 1;
    }
    #runtime-row { height: 3; }
    #runtime-label {
        width: 14;
        height: 3;
        color: #B9A9D3;
        content-align: left middle;
    }
    #runtime { width: 1fr; }
    Select, SelectCurrent { background: #302047; border: none; }
    Select:focus, SelectCurrent:focus { background: #49345F; }
    #runtime-note {
        height: 1;
        color: #8A7FA8;
        margin-left: 14;
    }
    #global-toggle, #recon-toggle, #kali-toggle {
        height: 1;
        margin-top: 1;
        color: #D6CBE5;
    }
    Checkbox {
        border: none;
        padding: 0;
        background: transparent;
    }
    Checkbox > .toggle--button { color: #FF7F50; }
    #requirements {
        height: auto;
        color: #A899C2;
        margin-top: 1;
    }
    #setup-actions, #result-actions {
        height: 3;
        margin: 1 2 0 2;
        align-horizontal: right;
    }
    #result-actions { display: none; }
    Button {
        min-width: 15;
        margin-left: 1;
        border: none;
        background: #302047;
        color: #E9E0F5;
    }
    Button:focus { background: #49345F; text-style: bold; }
    Button.-primary {
        background: #FF7F50;
        color: #1A0F2E;
        text-style: bold;
    }
    #footer {
        height: 1;
        padding: 0 2;
        background: #24163B;
        color: #A899C2;
    }
    #result-panel {
        display: none;
        height: 1fr;
        margin: 1 2;
        padding: 2 3;
        border: round #594477;
        background: #211338;
    }
    #result-title { height: 2; color: #FF7F50; text-style: bold; }
    #result-message { height: auto; color: #E9E0F5; margin-bottom: 1; }
    #result-path { height: auto; color: #A899C2; }
    .compact #workspace { layout: vertical; }
    .compact #brand { height: 1; }
    .compact #brand-caption { display: none; }
    .compact #profile-panel { width: 1fr; height: 9; min-width: 0; }
    .compact #profile-panel-title { margin-bottom: 0; }
    .compact #profile-list { height: 6; padding: 0; margin: 0; }
    .compact OptionList > .option-list--option { height: 1; }
    .compact #details-panel { width: 1fr; height: 1fr; margin: 1 0 0 0; padding: 0 1; }
    .compact #profile-name { height: 1; }
    .compact #profile-description, .compact #products-title, .compact #products { display: none; }
    .compact #runtime-row { height: 1; }
    .compact #runtime-label { width: 10; height: 1; }
    .compact #global-toggle, .compact #recon-toggle, .compact #kali-toggle { height: 1; }
    .compact #runtime-note { margin-left: 10; }
    .compact #global-toggle, .compact #recon-toggle, .compact #kali-toggle { margin-top: 0; }
    .short #intro { display: none; }
    .short #requirements, .short .panel-title, .short #runtime-note { display: none; }
    .short #setup-actions, .short #result-actions { margin-top: 0; }
    """

    BINDINGS = [("q", "quit_launcher", "Quit"), ("escape", "quit_launcher", "Back")]

    def __init__(self, launcher: Path, profiles: tuple[InstallProfile, ...] | None = None,
                 initial_profile: str | None = None):
        super().__init__()
        self.launcher = launcher
        self.profiles = profiles or load_profiles()
        if initial_profile and initial_profile not in {profile.key for profile in self.profiles}:
            raise ValueError(f"Unknown suggested installation profile: {initial_profile}")
        self.selected = next((profile for profile in self.profiles if profile.key == initial_profile),
                             self.profiles[0])
        self.install_exit_code: int | None = None
        self._result_kind = "install"
        self.install_dir = Path(os.environ.get("BUGTRACEAI_DIR", Path.home() / "bugtraceai"))

    def compose(self) -> ComposeResult:
        with Horizontal(id="brand"):
            yield Static("◈  BugTraceAI", id="brand-name")
            yield Static("   LAUNCHER  /  UNIVERSAL SETUP", id="brand-caption")
        yield Static("Choose a workspace. Required engines are included and connected automatically.", id="intro")
        with Horizontal(id="workspace"):
            with Vertical(id="profile-panel"):
                yield Static("INSTALL PROFILE", id="profile-panel-title")
                yield OptionList(*(Option(profile.label, id=profile.key) for profile in self.profiles), id="profile-list")
            with Vertical(id="details-panel"):
                yield Static("", id="profile-name")
                yield Static("", id="profile-description")
                yield Static("INSTALLED COMPONENTS", classes="panel-title", id="products-title")
                yield Static("", id="products")
                with Horizontal(id="runtime-row"):
                    yield Static("RUNTIME", id="runtime-label")
                    yield Select([("Local Python (.venv)", "local"), ("Docker containers", "docker")],
                                 value="local", allow_blank=False, id="runtime")
                yield Static("Choose once here; the installer will use this runtime for the selected components.", id="runtime-note")
                yield Checkbox("Register the global `btai` command", id="global-toggle")
                yield Checkbox("Add reconFTW MCP (OSINT)", id="recon-toggle")
                yield Checkbox("Add Kali toolbox (>3 GB)", id="kali-toggle")
                yield Static("", id="requirements")
        with Vertical(id="result-panel"):
            yield Static("", id="result-title")
            yield Static("", id="result-message")
            yield Static("", id="result-path")
        with Horizontal(id="setup-actions"):
            yield Button("Update installation", id="update-button")
            yield Button("AI setup / repair", id="ai-button")
            yield Button("Quit", id="quit-button")
            yield Button("Install selection", id="install-button", variant="primary")
        with Horizontal(id="result-actions"):
            yield Button("Open terminal workspace", id="open-tui-button", variant="primary")
            yield Button("Back to profiles", id="back-button")
            yield Button("Quit", id="result-quit-button")
        yield Static("↑↓ profile  ·  Tab settings  ·  Enter focus Install  ·  q quit", id="footer")

    def on_mount(self) -> None:
        self.query_one("#update-button", Button).display = (self.install_dir / ".launcher-state").is_file()
        self.query_one(OptionList).highlighted = self.profiles.index(self.selected)
        self.refresh_profile(self.selected)
        self.query_one(OptionList).focus()
        self.set_class(self.size.width < 104, "compact")
        self.set_class(self.size.height < 28, "short")

    def on_resize(self, event) -> None:
        self.set_class(event.size.width < 104, "compact")
        self.set_class(event.size.height < 28, "short")

    def on_option_list_option_highlighted(self, event: OptionList.OptionHighlighted) -> None:
        if event.option and event.option.id:
            profile = next((item for item in self.profiles if item.key == event.option.id), None)
            if profile:
                self.selected = profile
                self.refresh_profile(profile)

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        if event.option and event.option.id:
            profile = next((item for item in self.profiles if item.key == event.option.id), None)
            if profile:
                self.selected = profile
                self.refresh_profile(profile)
                self.query_one("#install-button", Button).focus()
                self.query_one("#footer", Static).update(
                    "Review runtime/add-ons, then press Enter on Install  ·  q quit"
                )

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id == "runtime":
            self.query_one("#runtime-note", Static).update(
                "Docker required for WEB and API-target deployments." if self.selected.mode != "cli"
                else "Local keeps the CLI in a Python venv; Docker runs it in a container.")

    def refresh_profile(self, profile: InstallProfile) -> None:
        self.query_one("#profile-name", Static).update(profile.label)
        self.query_one("#profile-description", Static).update(profile.description)
        products = included_products(profile)
        self.query_one("#products", Static).update("\n".join(f"✓  {product}" for product in products))

        runtime = self.query_one("#runtime", Select)
        runtime.disabled = profile.mode != "cli"
        runtime.value = "local" if profile.mode == "cli" else "docker"
        self.query_one("#runtime-note", Static).update(
            "Local keeps the CLI in a Python venv; Docker runs it in a container."
            if profile.mode == "cli" else "Docker is required; the Launcher connects the selected services.")

        global_toggle = self.query_one("#global-toggle", Checkbox)
        global_toggle.display = has_tui(profile)
        if not has_tui(profile):
            global_toggle.value = False
        for widget_id in ("#recon-toggle", "#kali-toggle"):
            self.query_one(widget_id, Checkbox).display = profile.install_web
        if not profile.install_web:
            self.query_one("#recon-toggle", Checkbox).value = False
            self.query_one("#kali-toggle", Checkbox).value = False

        if profile.install_web:
            requirements = "WEB includes both scanning engines. Optional recon/Kali tools are separate; Kali downloads over 3 GB."
        elif profile.install_api:
            requirements = "Independent API-target scanner · REST + MCP. No WEB or CLI dependency."
        elif profile.cli_interface == "api":
            requirements = "Headless web-scanning engine · REST + MCP. No terminal UI."
        else:
            requirements = "A provider key can be added later in the TUI with F7. A real scan does not start during setup."
        self.query_one("#requirements", Static).update(requirements)

    def run_install(self) -> None:
        profile = self.selected
        runtime = str(self.query_one("#runtime", Select).value)
        if profile.mode != "cli":
            runtime = "docker"
        global_command = bool(self.query_one("#global-toggle", Checkbox).value) and has_tui(profile)
        recon = bool(self.query_one("#recon-toggle", Checkbox).value) and profile.install_web
        kali = bool(self.query_one("#kali-toggle", Checkbox).value) and profile.install_web
        env = os.environ.copy()
        env.update({
            "BUGTRACEAI_LAUNCHER_TUI_CHILD": "1",
            "BUGTRACEAI_LAUNCHER_SKIP_POST_INSTALL": "1",
            "BUGTRACEAI_MCP_SELECTION_PRESET": "1",
            "BUGTRACEAI_MCP_RECON": "true" if recon else "false",
            "BUGTRACEAI_MCP_KALI": "true" if kali else "false",
        })
        self._run_child(install_command(profile, runtime, global_command), env, "install")

    def run_ai_assistant(self) -> None:
        env = os.environ.copy()
        self._run_child(["ai"], env, "assistant")

    def review_update(self) -> None:
        from release_manager import Manifest, SourceTransaction, ReleaseError
        try:
            manifest = Manifest.load(Path(os.environ.get("BUGTRACEAI_RELEASE_MANIFEST", ROOT / "release-manifest.json")))
            version = (self.launcher.parent / "VERSION").read_text().strip()
            plan = SourceTransaction(manifest, self.install_dir, None, version).preview()
        except (ReleaseError, OSError, ValueError) as error:
            self.notify(str(error), title="Cannot preview update", severity="error")
            return
        self.push_screen(UpdateReview(plan), self._update_reviewed)

    def _update_reviewed(self, accepted: bool) -> None:
        if accepted:
            self._run_child(["update"], os.environ.copy(), "update")

    def _run_child(self, arguments: list[str], env: dict[str, str], kind: str) -> None:
        self._result_kind = kind
        self.query_one("#workspace", Horizontal).display = False
        self.query_one("#setup-actions", Horizontal).display = False
        self.query_one("#result-actions", Horizontal).display = False
        self.query_one("#footer", Static).update("Installer is running in the terminal. You can return here when it completes.")
        self.query_one("#result-panel", Vertical).display = False
        self.screen.refresh()
        with self.suspend():
            if arguments == ["ai"]:
                result = subprocess.run([sys.executable, str(ROOT / "ai_installer.py")], env=env, check=False)
            else:
                result = subprocess.run(["bash", str(self.launcher), *arguments], env=env, check=False)
        self.install_exit_code = result.returncode
        self.show_result(kind, result.returncode)

    def show_result(self, kind: str, exit_code: int) -> None:
        panel = self.query_one("#result-panel", Vertical)
        panel.display = True
        if exit_code == 0:
            title = {"install": "SETUP COMPLETE", "update": "UPDATE VERIFIED"}.get(kind, "ASSISTANT SESSION COMPLETE")
            message = "The Launcher finished without an installation error. Review the service URLs shown above the terminal prompt."
            if kind == "update":
                message = "The selected release versions are active and all required runtime checks passed. Your existing settings and data were retained."
            color = "#2ECC71"
        else:
            title = "SETUP NEEDS ATTENTION" if kind == "install" else "ASSISTANT SESSION ENDED WITH AN ERROR"
            message = f"The process exited with code {exit_code}. Check the installer output and install.log, then retry or run ./launcher.sh repair."
            if kind == "update":
                title = "UPDATE NEEDS ATTENTION"
                message = f"Update exited with code {exit_code}. Read the update output. If recovery is required, run ./launcher.sh update --recover. Backups are retained in .updates."
            color = "#FF7F50"
        self.query_one("#result-title", Static).update(title)
        self.query_one("#result-title", Static).styles.color = color
        self.query_one("#result-message", Static).update(message)
        self.query_one("#result-path", Static).update(f"Install directory: {os.environ.get('BUGTRACEAI_DIR', str(Path.home() / 'bugtraceai'))}")
        self.query_one("#result-actions", Horizontal).display = True
        self.query_one("#result-quit-button", Button).display = True
        self.query_one("#open-tui-button", Button).display = exit_code == 0 and kind == "install" and has_tui(self.selected)
        self.query_one("#back-button", Button).display = kind in {"install", "update"}
        self.query_one("#footer", Static).update("Enter on Install starts setup   ·   Tab edit options   ·   q quit")

    def on_button_pressed(self, event: Button.Pressed) -> None:  # type: ignore[override]
        button = event.button.id
        if button == "open-tui-button":
            with self.suspend():
                subprocess.run(["bash", str(self.launcher), "tui"], check=False)
            return
        if button == "back-button":
            self.query_one("#result-panel", Vertical).display = False
            self.query_one("#workspace", Horizontal).display = True
            self.query_one("#setup-actions", Horizontal).display = True
            self.query_one("#result-actions", Horizontal).display = False
            self.query_one("#footer", Static).update("↑↓ profile  ·  Tab settings  ·  Enter focus Install  ·  q quit")
            return
        if button in {"quit-button", "result-quit-button"}:
            self.exit(self.install_exit_code or 0)
        elif button == "install-button":
            self.run_install()
        elif button == "ai-button":
            self.run_ai_assistant()
        elif button == "update-button":
            self.review_update()

    def action_quit_launcher(self) -> None:
        self.exit(self.install_exit_code if self.install_exit_code is not None else 0)


def main() -> int:
    parser = argparse.ArgumentParser(description="BugTraceAI universal installation TUI")
    parser.add_argument("--launcher", type=Path, default=ROOT / "launcher.sh")
    args = parser.parse_args()
    try:
        app = LauncherTUI(args.launcher.resolve(),
                          initial_profile=os.environ.get("BUGTRACEAI_LAUNCHER_INITIAL_PROFILE"))
        return int(app.run() or 0)
    except (OSError, ValueError) as exc:
        print(f"BugTraceAI Launcher TUI could not start: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
