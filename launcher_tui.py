#!/usr/bin/env python3
"""Polished, dependency-isolated terminal front end for the universal installer."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
import subprocess
import sys
import json
import tempfile
from pathlib import Path

from textual.app import App, ComposeResult
from textual.screen import ModalScreen
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import Button, Checkbox, OptionList, Select, Static, Input
from textual.widgets.option_list import Option
from installer_core import InstallProfile, parse_install_profiles
from setup_form import SetupSelection
from embedded_installer import InstallerSession
from provider_validation import check_provider_key


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
    #provider-panel, #method-panel { height: 1fr; margin: 0 2; padding: 2 3; border: round #594477; background: #211338; }
    #provider-panel Input { height: 3; margin: 1 0; }
    #credential-status, #credential-note { height: auto; margin: 1 0; }
    .method-description { height: auto; margin-bottom: 2; color: #B9A9D3; }
    #method-panel Button { width: 32; margin-bottom: 1; }
    #modules-form { height: auto; }
    .wide #modules-form { layout: horizontal; height: 22; }
    .wide .module-card { width: 1fr; height: 20; margin: 1; }

    .module-card { height: auto; padding: 1 2; margin: 1 0; border: round #594477; background: #211338; }
    .module-title { height: 1; color: #FF7F50; text-style: bold; }
    #choice-panel .module-card Checkbox { height: 2; }

    .port-field { width: 1fr; height: 2; }
    .form-row { height: 2; }
    .form-row Input, .form-row Checkbox { width: 1fr; }
    #choice-panel Checkbox { height: 2; margin: 0; }
    #choice-panel Input { height: 1; }
    #form-provider { height: 3; }
    #form-note { height: auto; color: #B9A9D3; }
    #choice-panel { height: 1fr; margin: 0 2; padding: 1 2; border: round #594477; background: #211338; }
    #workspace-list { height: 10; border: none; background: #211338; }
    #server-toggle, #server-engine { height: 3; }
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
    Checkbox > .toggle--button { color: #3D2B5F; background: #3D2B5F; }
    Checkbox.-on > .toggle--button { color: #FF7F50; background: #3D2B5F; }
    Checkbox:focus > .toggle--label { background: #3D2B5F; color: #FF9B75; }
    Input { background: #302047; color: #F8F4FC; border: none; }
    Input:focus { background: #49345F; }

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
    .review #products-title, .review #products { display: block; }
    .compact #runtime-row { height: 1; }
    .compact #runtime-label { width: 10; height: 1; }
    .compact #global-toggle, .compact #recon-toggle, .compact #kali-toggle { height: 1; }
    .compact #runtime-note { margin-left: 10; }
    .compact #global-toggle, .compact #recon-toggle, .compact #kali-toggle { margin-top: 0; }
    .short #intro { display: none; }
    .short #requirements, .short .panel-title, .short #runtime-note { display: none; }
    .short #setup-actions, .short #result-actions { margin-top: 0; }
    .review #requirements { display: block; }
    #choice-panel #runtime-row { height: 3; }
    #choice-panel #runtime-label { height: 3; }
    .short #choice-panel .panel-title { display: block; }
    """

    BINDINGS = [("q", "quit_launcher", "Quit"), ("escape", "quit_launcher", "Quit")]

    def __init__(self, launcher: Path, profiles: tuple[InstallProfile, ...] | None = None,
                 initial_profile: str | None = None):
        super().__init__()
        self.launcher = launcher
        self.profiles = profiles or load_profiles()
        if initial_profile and initial_profile not in {profile.key for profile in self.profiles}:
            raise ValueError(f"Unknown suggested installation profile: {initial_profile}")
        self.selected = next((profile for profile in self.profiles if profile.key == initial_profile),
                             self.profiles[0])
        self.setup_step = -2
        self.install_method = "wizard"
        self._validated_credentials = None
        self._checking_key = False
        self.install_exit_code: int | None = None
        self._result_kind = "install"
        self.install_dir = Path(os.environ.get("BUGTRACEAI_DIR", Path.home() / "bugtraceai"))

    def compose(self) -> ComposeResult:
        with Horizontal(id="brand"):
            yield Static("◈  BugTraceAI", id="brand-name")
            yield Static("   LAUNCHER  /  UNIVERSAL SETUP", id="brand-caption")
        yield Static("Choose a workspace. Required engines are included and connected automatically.", id="intro")
        with VerticalScroll(id="provider-panel"):
            yield Static("PROVIDER", classes="panel-title")
            yield Select([("OpenRouter", "openrouter"), ("Anthropic", "anthropic"), ("Z.ai", "zai")],
                         value="openrouter", allow_blank=False, id="form-provider")
            yield Input(placeholder="API key · required", password=True, id="form-key")
            yield Static("OpenRouter/Anthropic: access check without a model call. Z.ai: a short test request; provider usage may apply.", id="credential-note")
            yield Static("Enter your provider key, then select Verify and continue.", id="credential-status")
        with VerticalScroll(id="method-panel"):
            yield Static("HOW WOULD YOU LIKE TO INSTALL?", classes="panel-title")
            yield Button("Install with Wizard", id="choose-wizard", variant="primary")
            yield Static("Guided setup. Choose modules, ports and runtime, then review the installation.", classes="method-description")
            yield Button("Talk to AI · install or repair", id="choose-ai")
            yield Static("Tell the assistant what you want to install or what went wrong. It asks questions, reviews your choices and stays in this TUI. Uses OpenRouter/Anthropic provider tokens.", classes="method-description")
        with VerticalScroll(id="choice-panel"):
            with Vertical(id="modules-form"):
                with Vertical(classes="module-card",id="web-card"):
                    yield Static("BugTraceAI-WEB", classes="module-title")
                    yield Static("Independent browser workspace · dashboard and analysis tools")
                    yield Checkbox("Install WEB", id="select-web")
                    with Horizontal(classes="form-row"):
                        yield Checkbox("reconFTW MCP", id="recon-toggle")
                        yield Checkbox("Kali toolbox", id="kali-toggle")
                    yield Static("Toolboxes require CLI selected.")
                    yield Static("WEB port")
                    yield Input(value="6869", placeholder="WEB port", type="integer", id="port-web")
                    yield Static("reconFTW MCP port", id="recon-port-label")
                    yield Input(value="8002", placeholder="reconFTW MCP port", type="integer", id="port-recon")
                with Vertical(classes="module-card",id="cli-card"):
                    yield Static("BugTraceAI-CLI", classes="module-title")
                    yield Static("Independent web-scanning engine · REST / MCP and optional terminal")
                    yield Checkbox("Install CLI", value=True, id="select-cli")
                    yield Checkbox("Enable terminal TUI", value=True, id="select-tui")
                    yield Checkbox("Register global btai", id="global-toggle")
                    with Horizontal(classes="form-row"):
                        with Vertical(classes="port-field"):
                            yield Static("REST port")
                            yield Input(value="8000", placeholder="CLI REST port", type="integer", id="port-cli")
                        with Vertical(classes="port-field"):
                            yield Static("MCP port")
                            yield Input(value="8001", placeholder="CLI MCP port", type="integer", id="port-cli_mcp")
                with Vertical(classes="module-card",id="api-card"):
                    yield Static("BugTraceAI-API", classes="module-title")
                    yield Static("Independent API-target scanner · REST / MCP, no WEB or CLI required")
                    yield Checkbox("Install API", id="select-api")
                    with Horizontal(classes="form-row"):
                        with Vertical(classes="port-field"):
                            yield Static("REST port")
                            yield Input(value="8005", placeholder="API REST port", type="integer", id="port-api")
                        with Vertical(classes="port-field"):
                            yield Static("MCP port")
                            yield Input(value="8004", placeholder="API MCP port", type="integer", id="port-api_mcp")
            yield Static("Advanced · CLI-only installations can use local Python.", classes="panel-title")
            with Horizontal(id="runtime-row"):
                yield Static("CLI runtime", id="runtime-label")
                yield Select([("Docker containers", "docker"), ("Local Python (.venv)", "local")],
                             value="docker", allow_blank=False, id="runtime")
            yield Static("", id="form-note")
        with Horizontal(id="workspace"):
            with VerticalScroll(id="details-panel"):
                yield Static("", id="profile-name")
                yield Static("", id="profile-description")
                yield Static("INSTALLED COMPONENTS", classes="panel-title", id="products-title")
                yield Static("", id="products")
                yield Static("", id="requirements")
        with Vertical(id="result-panel"):
            yield Static("", id="result-title")
            yield Static("", id="result-message")
            yield Static("", id="result-path")
        with Horizontal(id="setup-actions"):
            yield Button("Verify and continue", id="verify-button", variant="primary")
            yield Button("Update installation", id="update-button")
            yield Button("AI-assisted install", id="ai-button")
            yield Button("Repair / diagnose", id="repair-button")
            yield Button("Back", id="previous-button")
            yield Button("Review installation", id="next-button", variant="primary")
            yield Button("Quit", id="quit-button")
            yield Button("Install selection", id="install-button", variant="primary")
        with Horizontal(id="result-actions"):
            yield Button("Open terminal workspace", id="open-tui-button", variant="primary")
            yield Button("Ask AI", id="result-ai-button")
            yield Button("Back to profiles", id="back-button")
            yield Button("Quit", id="result-quit-button")
        yield Static("↑↓ profile  ·  Tab settings  ·  Enter focus Install  ·  q quit", id="footer")

    def on_mount(self) -> None:
        profile = self.selected
        self.query_one("#select-web", Checkbox).value = profile.install_web
        self.query_one("#select-cli", Checkbox).value = profile.install_cli and profile.key != "web"
        self.query_one("#select-api", Checkbox).value = profile.install_api and profile.key != "web"
        self.query_one("#select-tui", Checkbox).value = has_tui(profile)
        self.refresh_form()
        self.show_setup_step(-2)
        self.set_class(self.size.width < 104, "compact")
        self.set_class(self.size.height < 28, "short")
        self.set_class(self.size.width >= 120, "wide")

    def on_resize(self, event) -> None:
        self.set_class(event.size.width < 104, "compact")
        self.set_class(event.size.height < 28, "short")
        self.set_class(event.size.width >= 120, "wide")

    def form_selection(self) -> SetupSelection:
        def checked(name): return self.query_one(name, Checkbox).value
        ports = {}
        for key in ("web", "cli", "cli_mcp", "api", "api_mcp", "recon"):
            value = self.query_one("#port-"+key, Input).value
            ports[key] = int(value) if value.isdecimal() else None
        return SetupSelection(
            web=checked("#select-web"), cli=checked("#select-cli"), api=checked("#select-api"),
            tui=checked("#select-tui") and checked("#select-cli"),
            runtime=str(self.query_one("#runtime", Select).value),
            global_command=checked("#global-toggle"), recon=checked("#recon-toggle") and checked("#select-web"), kali=checked("#kali-toggle") and checked("#select-web"),
            provider=str(self.query_one("#form-provider", Select).value),
            api_key=self.query_one("#form-key", Input).value.strip(), ports=ports)

    def refresh_form(self):
        selection = self.form_selection()
        effective_cli = selection.cli
        effective_api = selection.api
        for name in ("#recon-toggle", "#kali-toggle", "#port-web"):
            self.query_one(name).disabled = not selection.web
        for name in ("#port-recon", "#recon-port-label"):
            self.query_one(name).display = selection.recon
        for name in ("#select-tui", "#port-cli", "#port-cli_mcp"):
            self.query_one(name).disabled = not effective_cli
        for name in ("#port-api", "#port-api_mcp"):
            self.query_one(name).disabled = not effective_api
        self.query_one("#runtime", Select).disabled = selection.web or selection.api
        if selection.web or selection.api: self.query_one("#runtime", Select).value = "docker"
        self.query_one("#global-toggle", Checkbox).disabled = not selection.tui
        self.query_one("#form-note", Static).update(
            "Each module is independent. Only checked modules are installed. WEB can connect to local or external scanning engines later.")

    def credential_fingerprint(self):
        provider = str(self.query_one("#form-provider", Select).value)
        key = self.query_one("#form-key", Input).value.strip()
        return hashlib.sha256((provider + "\0" + key).encode()).digest()

    def credentials_verified(self):
        return self._validated_credentials == self.credential_fingerprint()

    async def verify_provider(self):
        if self._checking_key:
            return
        provider = str(self.query_one("#form-provider", Select).value)
        key = self.query_one("#form-key", Input).value.strip()
        if not key:
            self.query_one("#credential-status", Static).update("API key is required.")
            return
        self._checking_key = True
        self._validated_credentials = None
        fingerprint = self.credential_fingerprint()
        self.query_one("#verify-button", Button).disabled = True
        self.query_one("#credential-status", Static).update("Checking provider access…")
        try:
            valid, message = await asyncio.to_thread(check_provider_key, provider, key)
            if fingerprint != self.credential_fingerprint():
                self.query_one("#credential-status", Static).update("Credentials changed. Verify the new key before continuing.")
                return
            self.query_one("#credential-status", Static).update(message)
            if valid:
                self._validated_credentials = fingerprint
                self.show_setup_step(-1)
        finally:
            self._checking_key = False
            self.query_one("#verify-button", Button).disabled = False

    def choose_install_method(self, method):
        if not self.credentials_verified():
            self.show_setup_step(-2)
            return
        if method == "ai" and self.query_one("#form-provider", Select).value == "zai":
            self.notify("AI installation supports OpenRouter/Anthropic. Use Wizard for Z.ai.", severity="error")
            return
        self.install_method = method
        if method == "ai":
            self.run_ai_assistant()
            return
        self.show_setup_step(0)

    def show_setup_step(self, step: int) -> None:
        if step >= -1 and not self.credentials_verified():
            self.notify("Verify your provider API key before continuing.", severity="error")
            step = -2
        if step == 1:
            try:
                selection = self.form_selection().validate()
                self.selected = next(p for p in self.profiles if p.key == selection.profile)
            except ValueError as error:
                self.notify(str(error), severity="error", title="Review your selection")
                return
        self.setup_step = step
        self.set_class(step == 1, "review")
        labels = {-2:"Provider credentials · verify access before installing", -1:"Choose Wizard or AI-assisted installation", 0:"Choose independent modules and ports", 1:"Review installation · " + self.install_method.upper()}
        self.query_one("#intro", Static).update(labels[step])
        for panel, visible in (("provider-panel", step == -2), ("method-panel", step == -1), ("choice-panel", step == 0), ("workspace", step == 1)):
            self.query_one("#" + panel).display = visible
        self.query_one("#previous-button").display = step > -2
        self.query_one("#verify-button").display = step == -2
        self.query_one("#next-button").display = step == 0
        self.query_one("#install-button").display = step == 1 and self.install_method == "wizard"
        self.query_one("#ai-button").display = step == 1 and self.install_method == "ai"
        self.query_one("#choose-ai", Button).disabled = self.query_one("#form-provider", Select).value == "zai"
        existing = (self.install_dir / ".launcher-state").is_file()
        self.query_one("#update-button").display = step == -2 and existing
        self.query_one("#repair-button").display = step == -2 and (existing or any((self.install_dir / n).is_dir() for n in ("BugTraceAI-CLI","BugTraceAI-WEB","BugTraceAI-API")))
        if step == 1:
            self.query_one("#profile-name", Static).update(self.selected.label)
            self.query_one("#profile-description", Static).update("Selected independent modules:")
            self.query_one("#products", Static).update("\n".join(included_products(self.selected)))
            self.query_one("#requirements", Static).update(
                f"Runtime: {selection.runtime} · Global btai: {'yes' if selection.global_command and selection.tui else 'no'}\n"
                f"Provider: {selection.provider} · Access verified · Key hidden\n"
                + "\n".join(f"{k}: {v}" for k,v in selection.active_ports().items())
                + f"\nExtras: {', '.join(n for n,v in [('reconFTW',selection.recon),('Kali',selection.kali)] if v) or 'none'}\n"
                + "Installation and AI conversation stay inside this TUI.")
        self.query_one("#footer", Static).update("Tab focus · Back preserves your choices · q quit")
        target = {-2:"form-key", -1:"choose-wizard", 0:"select-web", 1:"ai-button" if self.install_method == "ai" else "install-button"}[step]
        self.call_after_refresh(self.query_one("#" + target).focus)

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "form-key" and self._validated_credentials is not None and not self.credentials_verified():
            self._validated_credentials = None
            self.query_one("#credential-status", Static).update("Credentials changed. Verify again before continuing.")

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        if event.checkbox.id and event.checkbox.id.startswith(("select-", "recon-", "kali-", "global-")):
            self.refresh_form()

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id in ("runtime", "form-provider"):
            if event.select.id == "form-provider" and self._validated_credentials is not None and not self.credentials_verified():
                self._validated_credentials = None
                self.query_one("#credential-status", Static).update("Provider changed. Verify again before continuing.")
            self.refresh_form()

    def configuration_file(self, selection):
        handle, path = tempfile.mkstemp(prefix="btai-setup-", suffix=".json")
        with os.fdopen(handle, "w") as stream:
            json.dump(selection.payload(),stream)
        return Path(path)

    def run_install(self) -> None:
        if not self.credentials_verified():
            self.show_setup_step(-2); return
        try: selection = self.form_selection().validate(check_available=True)
        except ValueError as error:
            self.notify(str(error),severity="error"); return
        config=self.configuration_file(selection)
        env=os.environ.copy()
        env.update({"BTAI_SETUP_CONFIG":str(config),"BUGTRACEAI_LAUNCHER_TUI_CHILD":"1", "BUGTRACEAI_LAUNCHER_TUI_REVIEWED":"1", "BUGTRACEAI_LAUNCHER_SKIP_POST_INSTALL":"1", "BUGTRACEAI_MCP_SELECTION_PRESET":"1", "BUGTRACEAI_MCP_RECON":str(selection.recon).lower(),"BUGTRACEAI_MCP_KALI":str(selection.kali).lower()})
        self._run_child(install_command(self.selected,selection.runtime,selection.global_command and selection.tui),env,"install",config=config,secrets=[selection.api_key])

    def run_ai_assistant(self, repair: bool = False) -> None:
        env=os.environ.copy(); config=None; secrets=[]
        for key in ("BUGTRACEAI_PROFILE","BTAI_INSTALLER_MODE","BTAI_INSTALLER_RUNTIME","BTAI_INSTALLER_GLOBAL","BTAI_INSTALLER_MCP_RECON","BTAI_INSTALLER_MCP_KALI","BTAI_SETUP_CONFIG","BTAI_ASSISTANT_CREDENTIALS"):
            env.pop(key,None)
        env['BTAI_INSTALLER_ACTION']='repair' if repair else 'install'
        if not repair:
            if not self.credentials_verified():
                self.show_setup_step(-2); return
        provider=str(self.query_one('#form-provider',Select).value)
        if provider == 'zai':
            self.notify("Choose OpenRouter/Anthropic for AI conversation, or use Wizard for Z.ai.",severity="error"); return
        key=self.query_one('#form-key',Input).value.strip()
        # A reviewed Wizard selection is useful repair context. Occupied ports
        # are discussed by the assistant instead of preventing the chat opening.
        if self.setup_step == 1 and key:
            try:
                config=self.configuration_file(self.form_selection().validate())
                env['BTAI_SETUP_CONFIG']=str(config)
            except ValueError:
                pass
        if config is None:
            fd,path=tempfile.mkstemp(prefix='btai-assistant-',suffix='.json')
            with os.fdopen(fd,'w') as stream:
                json.dump({'provider':provider,'api_key':key},stream)
            config=Path(path)
        env.update({'BTAI_INSTALLER_CONVERSATION':'1','BTAI_ASSISTANT_CREDENTIALS':str(config),
                    'BUGTRACEAI_LAUNCHER_TUI_CHILD':'1','BUGTRACEAI_DIR':str(self.install_dir)})
        secrets=[key] if key else []
        self._run_child(['ai'],env,'assistant',config=config,secrets=secrets)

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

    def _run_child(self, arguments, env, kind, config=None, secrets=()) -> None:
        self._result_kind=kind
        state=self.install_dir/'.launcher-state'
        before=state.stat().st_mtime_ns if state.exists() else None
        command=[sys.executable,str(ROOT/'ai_installer.py')] if arguments == ['ai'] else ['bash',str(self.launcher),*arguments]
        def cleanup():
            if config: config.unlink(missing_ok=True)
        def completed(code):
            if kind == 'install' and code == 0:
                after=state.stat().st_mtime_ns if state.exists() else None
                if after is None or after == before: code=130
            self.install_exit_code=code
            self.show_result(kind,code)
        self.push_screen(InstallerSession(command,env,secrets=secrets,cleanup=cleanup,kind=kind),completed)

    def show_result(self, kind: str, exit_code: int) -> None:
        for name in ('provider-panel','method-panel','choice-panel','workspace','setup-actions'):
            self.query_one('#'+name).display=False
        panel = self.query_one("#result-panel", Vertical)
        panel.display = True
        if exit_code == 130:
            title = "SESSION STOPPED"
            message = "No verified installation success was recorded. Review the output; existing data was not removed by the UI."
            color = "#FF7F50"
        elif exit_code == 0:
            title = {"install": "SETUP COMPLETE", "update": "UPDATE VERIFIED"}.get(kind, "ASSISTANT SESSION COMPLETE")
            message = "The Launcher finished without an installation error. Review the service URLs shown above the terminal prompt."
            if kind == "update":
                message = "The selected release versions are active and all required runtime checks passed. Your existing settings and data were retained."
            elif kind == "assistant":
                message = "The assistant session ended. Read its report for the diagnosis and any verified installation checks."
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
        self.query_one("#result-ai-button", Button).display = exit_code not in (0,130) and kind in {"install","update"}
        self.query_one("#back-button", Button).display = kind in {"install", "update", "assistant"}
        self.query_one("#footer", Static).update("Review the report   ·   Ask AI for diagnosis   ·   Back to setup   ·   q quit")

    async def on_button_pressed(self, event: Button.Pressed) -> None:  # type: ignore[override]
        button = event.button.id
        if button == "open-tui-button":
            with self.suspend():
                subprocess.run(["bash", str(self.launcher), "tui"], check=False)
            return
        if button == "back-button":
            self.query_one("#result-panel", Vertical).display = False
            self.show_setup_step(0)
            self.query_one("#setup-actions", Horizontal).display = True
            self.query_one("#result-actions", Horizontal).display = False
            self.query_one("#footer", Static).update("↑↓ profile  ·  Tab settings  ·  Enter focus Install  ·  q quit")
            return
        if button in {"quit-button", "result-quit-button"}:
            self.exit(self.install_exit_code or 0)
        elif button == "verify-button":
            self.run_worker(self.verify_provider(), exclusive=True, group="credential-check")
        elif button in {"choose-wizard", "choose-ai"}:
            self.choose_install_method("ai" if button == "choose-ai" else "wizard")
        elif button == "previous-button":
            self.show_setup_step(max(-2, self.setup_step - 1))
        elif button == "next-button":
            self.show_setup_step(1)
        elif button == "repair-button":
            self.run_ai_assistant(repair=True)
        elif button == "result-ai-button":
            self.run_ai_assistant(repair=True)
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
