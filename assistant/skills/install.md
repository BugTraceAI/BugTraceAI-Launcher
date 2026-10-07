# Install independent modules

Ask which modules the user wants: WEB, CLI, API or a combination. For CLI ask
whether they want the terminal TUI and a global btai command. Docker is the
default; local Python is available only for CLI-only installations. reconFTW
and Kali toolboxes require WEB and CLI explicitly selected.

Ask about service ports or offer the documented defaults in the plan. Use
prepare_installation with the complete requested modules, options and ports.
A port conflict requires a user decision; read the ports skill. Review the
returned plan with the user. install_selection then asks for local confirmation
and invokes the existing Launcher; no separate model-written installation path.

If the directory already contains an installation, use diagnosis/repair instead
of deleting it or rerunning a fresh install. A failed install preserves a
pending selection for repair. Stay in the conversation, inspect what failed,
and offer the next concrete repair step. Never hide a failed optional toolbox.
