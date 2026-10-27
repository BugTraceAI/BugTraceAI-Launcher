"""Read-only discovery in the selected directory; never guess container ownership."""
from dataclasses import dataclass, field
from pathlib import Path

from release_manager import NAMES, ReleaseError, normalize_state, read_json, selected_components


@dataclass(frozen=True)
class Installation:
    path: Path
    status: str
    components: tuple[str, ...] = ()
    state: dict | None = field(default=None, repr=False)

    @property
    def can_update(self) -> bool:
        return self.status == "installed"

    @property
    def can_repair(self) -> bool:
        return self.status in {"installed", "incomplete"}

    @property
    def can_diagnose(self) -> bool:
        """Any non-empty directory can be opened in the AI diagnosis flow."""
        return self.status != "fresh"

    def summary(self) -> str:
        headings = {
            "installed": "Installation detected",
            "incomplete": "Incomplete installation detected",
            "unmanaged": "Components detected without valid Launcher state",
            "invalid": "Installation state needs attention",
            "occupied": "Directory is not empty",
            "fresh": "No previous installation detected",
        }
        lines = [headings[self.status], f"Directory: {self.path}"]
        if self.components:
            lines.append("Components: " + ", ".join(NAMES[key] for key in self.components))
        if self.state:
            # Only an allowlist, never raw state/configuration or credentials.
            runtime = self.state.get('cli_runtime', 'docker')
            lines.append("Runtime: " + (runtime if runtime in ('docker', 'local') else 'unknown'))
        if self.can_update:
            lines.append("Update keeps the saved components, ports, provider settings and data.")
        elif self.status != "fresh":
            lines.append("Update is unavailable without valid completed installation state. Existing files are kept.")
        return "\n".join(lines)


def inspect_installation(path: Path) -> Installation:
    path = path.expanduser().resolve()
    try:
        for filename, status in ((".launcher-state", "installed"),
                                 (".launcher-pending.json", "incomplete")):
            marker = path / filename
            if marker.exists():
                try:
                    state = normalize_state(read_json(marker))
                except (ReleaseError, TypeError, ValueError):
                    return Installation(path, "invalid")
                return Installation(path, status, tuple(selected_components(state)), state)
        components = tuple(key for key, name in NAMES.items() if (path / name).is_dir())
        if components:
            return Installation(path, "unmanaged", components)
        # Match the classic wizard's legacy cache-only directory handling,
        # without removing the cache or treating it as an installed product.
        if path.exists() and (not path.is_dir() or any(
                not entry.name.startswith('.version_cache') for entry in path.iterdir())):
            return Installation(path, "occupied")
    except OSError:
        return Installation(path, "invalid")
    return Installation(path, "fresh")
