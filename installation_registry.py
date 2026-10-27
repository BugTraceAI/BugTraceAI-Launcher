"""Remember an explicitly registered installation without scanning unrelated paths."""
import argparse
import json
import os
from pathlib import Path
import sys


def registry_path() -> Path:
    return Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'bugtraceai-launcher/installation.json'


def selected_install_dir() -> Path:
    if os.environ.get('BUGTRACEAI_DIR'):
        return Path(os.environ['BUGTRACEAI_DIR']).expanduser().resolve()
    registry = registry_path()
    if registry.exists():
        from release_manager import read_json
        try:
            value = read_json(registry)
        except RuntimeError as error:
            raise ValueError(
                f'Invalid installation registry at {registry}: {error} '
                'Fix or delete this file, or set BUGTRACEAI_DIR.') from error
        directory = value.get('install_dir')
        if not isinstance(directory, str) or not Path(directory).is_absolute() or any(c in directory for c in '\n\r\0'):
            raise ValueError(
                f'Invalid installation registry at {registry}: install_dir must be an absolute path. '
                'Fix or delete this file, or set BUGTRACEAI_DIR.')
        return Path(directory).resolve()
    return Path.home() / 'bugtraceai'


def register_installation(directory: Path) -> None:
    from release_manager import normalize_state, read_json, write_json
    directory = directory.expanduser().resolve()
    normalize_state(read_json(directory / '.launcher-state'))
    path = registry_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    write_json(path, {'install_dir': str(directory)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('locate', 'register'))
    parser.add_argument('directory', nargs='?', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'register':
            if args.directory is None:
                parser.error('register requires an installation directory')
            register_installation(args.directory)
        print(selected_install_dir())
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
