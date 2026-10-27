"""Host-owned install plans for the conversational Launcher assistant.

The model asks questions and diagnoses. This boundary keeps installation on the
same validated runtime as the Wizard, with locally held credentials.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from datetime import datetime, timezone

from setup_form import SetupSelection

DEFAULT_PORTS = {'web': 6869, 'cli': 8000, 'cli_mcp': 8001,
                 'api': 8005, 'api_mcp': 8004, 'recon': 8002}
STATE_FIELDS = ('install_profile', 'mode', 'cli_interface', 'cli_runtime',
                'cli_global', 'install_web', 'install_cli', 'install_btai',
                'mcp_cli_enabled', 'mcp_recon_enabled', 'mcp_kali_enabled',
                'web_port', 'cli_port', 'mcp_port', 'btai_port',
                'btai_mcp_port', 'recon_port', 'provider')

# Keep model input to recognized, fixed descriptions: logs may contain secrets,
# user messages, or instructions from untrusted build output.
REPAIR_LOG_SIGNALS = (
    ('build_network_host', r'additional privileges requested:[^\n]*--allow(?:=|\s+)network\.host',
     'Buildx rejected the host-network permission requested by a build.'),
    ('disk_full', r'no space left on device', 'A build or installation ran out of disk space.'),
    ('port_in_use', r'port is already allocated|address already in use', 'A required network port was already in use.'),
    ('dns_failure', r'temporary failure in name resolution|could not resolve host|name or service not known',
     'A network name could not be resolved.'),
    ('docker_permission', r'permission denied[^\n]*docker daemon socket|permission denied while trying to connect to the docker daemon',
     'Access to the Docker daemon was denied.'),
    ('docker_unavailable', r'cannot connect to the docker daemon|is the docker daemon running',
     'The Docker daemon could not be reached.'),
    ('npm_failure', r'npm (?:err!|error)', 'An npm dependency installation reported an error.'),
    ('web_start_failed', r'failed to start web services', 'The Launcher reported that WEB services did not start.'),
    ('cli_start_failed', r'failed to start cli service', 'The Launcher reported that the CLI service did not start.'),
    ('api_start_failed', r'failed to start bugtraceai-api', 'The Launcher reported that BugTraceAI-API did not start.'),
)


class ConversationSetup:
    def __init__(self, root, install_dir, provider, api_key, *,
                 ask, emit, runner=subprocess.run, install_log=None):
        self.root = Path(root)
        self.install_dir = Path(install_dir)
        self.provider = provider
        self._api_key = api_key
        self.ask = ask
        self.emit = emit
        self.runner = runner
        self.install_log = Path(install_log) if install_log else self.root / 'install.log'
        self.plan = None
        self.verified = False

    def repair_log_evidence(self):
        """Extract bounded, non-secret signals without sending raw logs to the model."""
        logs, signals = [], []
        for source, path in (('build', self.install_dir / '.build.log'),
                             ('installer', self.install_log)):
            try:
                with path.open('rb') as stream:
                    size = os.fstat(stream.fileno()).st_size
                    stream.seek(max(0, size - 65536))
                    tail = stream.read(65536).decode('utf-8', 'replace')
                    modified = datetime.fromtimestamp(os.fstat(stream.fileno()).st_mtime, timezone.utc).isoformat()
            except FileNotFoundError:
                logs.append({'source': source, 'status': 'missing'})
                continue
            except OSError:
                logs.append({'source': source, 'status': 'unavailable'})
                continue
            if source == 'installer':
                # install.log is append-only; an old failure must not become
                # evidence about a later successful installation attempt.
                sessions = re.split(r'(?m)^===== BugTraceAI Launcher v[^\n]*=====$', tail)
                if len(sessions) > 1:
                    tail = sessions[-1]
            logs.append({'source': source, 'status': 'read', 'modified_utc': modified,
                         'tail_truncated': size > 65536})
            for code, pattern, description in REPAIR_LOG_SIGNALS:
                if re.search(pattern, tail, re.IGNORECASE):
                    signals.append({'source': source, 'code': code, 'description': description})
        return {'logs': logs, 'signals': signals}

    def read_skill(self, name):
        if name not in {'install', 'repair', 'ports'}:
            raise ValueError('Choose install, repair or ports.')
        return (self.root / 'assistant/skills' / (name + '.md')).read_text()

    def system_prompt(self):
        return (self.root / 'assistant/AGENT.md').read_text() + (
            '\n\nHost context:\n' + json.dumps({
                'installation_directory': str(self.install_dir),
                'provider': self.provider,
                'provider_key': 'held privately by the host',
                'available_skills': ['install', 'repair', 'ports'],
            }))

    def inspect(self):
        state, state_kind = {}, 'none'
        for name, kind in [('.launcher-state', 'verified'),
                           ('.launcher-pending.json', 'incomplete')]:
            path = self.install_dir / name
            if path.is_file():
                try:
                    data = json.loads(path.read_text())
                    if not isinstance(data, dict):
                        raise ValueError('state is not an object')
                except (OSError, ValueError):
                    state_kind = 'invalid'
                    break
                state = {k: data[k] for k in STATE_FIELDS if k in data}
                state_kind = kind
                break
        components = [name for name in ('BugTraceAI-WEB', 'BugTraceAI-CLI', 'BugTraceAI-API')
                      if (self.install_dir / name).is_dir()]
        try:
            result = self.runner(['docker', 'ps', '-a', '--format',
                                  '{{.Names}}\t{{.Status}}\t{{.Ports}}'],
                                 capture_output=True, text=True, timeout=15, check=False)
            docker = result.stdout if result.returncode == 0 else result.stderr
        except (OSError, subprocess.TimeoutExpired) as exc:
            docker = f'Docker status unavailable: {type(exc).__name__}'
        return {'install_dir': str(self.install_dir), 'state_kind': state_kind,
                'selection': state, 'component_directories': components,
                'docker_status': docker, 'health_verified_this_session': self.verified}

    def prepare(self, args):
        # Invalidate an old plan even if the replacement is invalid.
        self.plan = None
        modules = args.get('modules')
        if not isinstance(modules, list) or not modules or any(
                m not in ('web', 'cli', 'api') for m in modules) or len(set(modules)) != len(modules):
            raise ValueError('Select one or more distinct modules: web, cli, api.')
        ports = args.get('ports', {})
        if not isinstance(ports, dict) or set(ports) - set(DEFAULT_PORTS):
            raise ValueError('Invalid service port names.')
        for key in ('tui', 'global_command', 'recon', 'kali'):
            if key in args and not isinstance(args[key], bool):
                raise ValueError(f'{key} must be a boolean.')
        selection = SetupSelection(
            web='web' in modules, cli='cli' in modules, api='api' in modules,
            tui=args.get('tui', 'cli' in modules),
            runtime=args.get('runtime', 'docker'),
            global_command=args.get('global_command', False),
            recon=args.get('recon', False), kali=args.get('kali', False),
            provider=self.provider, api_key=self._api_key,
            ports={**DEFAULT_PORTS, **ports})
        selection.validate(check_available=True)
        self.plan = selection
        return self.public_plan()

    def public_plan(self):
        if self.plan is None:
            raise ValueError('Prepare and review a valid installation plan first.')
        data = self.plan.payload()
        data.pop('api_key', None)
        data['install_dir'] = str(self.install_dir)
        data['modules'] = [name for name in ('web', 'cli', 'api') if getattr(self.plan, name)]
        return data

    def _approve(self, question):
        answer = self.ask(question).strip().lower()
        return answer in {'y', 'yes', 'si', 'sí'}, answer

    def install(self):
        if self.plan is None:
            raise ValueError('Prepare and review a valid installation plan first.')
        self.plan.validate(check_available=True)
        if self.install_dir.exists() and any(self.install_dir.iterdir()):
            raise ValueError('An existing installation/directory must be diagnosed or repaired; fresh setup will not replace it.')
        plan = self.public_plan()
        self.emit('Review installation:\n' + json.dumps(plan, indent=2))
        approved, answer = self._approve('Install this reviewed selection? Type yes to install, or describe what you want to change.')
        if not approved:
            return {'verified': False, 'installed': False, 'user_reply': answer}
        # Recheck after the user answers; never replace the accepted port.
        self.plan.validate(check_available=True)
        fd, path = tempfile.mkstemp(prefix='btai-ai-plan-', suffix='.json')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(self.plan.payload(), stream)
            env = os.environ.copy()
            for key in ('BUGTRACEAI_PROFILE', 'BTAI_INSTALLER_ACTION', 'BTAI_INSTALLER_MODE'):
                env.pop(key, None)
            env.update({'BUGTRACEAI_DIR': str(self.install_dir),
                        'BTAI_SETUP_CONFIG': path, 'BUGTRACEAI_LAUNCHER_TUI_CHILD': '1',
                        'BUGTRACEAI_SKIP_AI_PROMPT': '1', 'BUGTRACEAI_LAUNCHER_SKIP_POST_INSTALL': '1'})
            result = self.runner(['bash', str(self.root / 'launcher.sh'), 'install',
                                  '--profile', self.plan.profile, '--runtime', self.plan.runtime,
                                  '--global', plan['global']], env=env, check=False)
        finally:
            Path(path).unlink(missing_ok=True)
        self.verified = result.returncode == 0 and (self.install_dir / '.launcher-state').is_file()
        return {'exit_code': result.returncode, 'verified': self.verified,
                'plan': plan, 'next_step': 'Report verified services.' if self.verified else
                'Stay in the conversation. Inspect the failure, explain it and ask how the user wants to proceed.'}

    def repair(self):
        if not any((self.install_dir / n).is_file() for n in ('.launcher-state', '.launcher-pending.json')):
            raise ValueError('No saved or pending selection exists. Inspect the current services and ask the user about the original selection; do not reinstall.')
        self.emit('Saved installation:\n' + json.dumps(self.inspect(), indent=2))
        approved, answer = self._approve('Repair this saved selection and restart its services while preserving data and source versions? Type yes to proceed.')
        if not approved:
            return {'verified': False, 'repaired': False, 'user_reply': answer}
        env = {**os.environ, 'BUGTRACEAI_DIR': str(self.install_dir),
               'BUGTRACEAI_LAUNCHER_TUI_CHILD': '1', 'BUGTRACEAI_SKIP_AI_PROMPT': '1'}
        env.pop('BTAI_SETUP_CONFIG', None)
        result = self.runner(['bash', str(self.root / 'launcher.sh'), 'repair'], env=env, check=False)
        self.verified = result.returncode == 0 and (self.install_dir / '.launcher-state').is_file()
        return {'exit_code': result.returncode, 'verified': self.verified,
                'next_step': 'Report health verification.' if self.verified else
                'Keep chatting. Inspect bounded service logs and ask about the next repair step.'}


def tool_definitions(existing):
    tools = [t for t in existing if t['function']['name'] in
             {'run_command', 'run_privileged_command', 'ask_user', 'finish'}]
    definitions = [
        ('read_skill', 'Read host-provided install, repair or ports guidance.',
         {'name': {'type': 'string', 'enum': ['install', 'repair', 'ports']}}, ['name']),
        ('inspect_installation', 'Read the real saved/pending inventory and Docker status without modifying services.', {}, []),
        ('inspect_repair_logs', 'Review bounded, sanitized installation and build log signals without exposing raw logs or credentials.', {}, []),
        ('prepare_installation', 'Validate the exact requested independent modules and ports. Occupied ports require a user decision. Nothing is installed.',
         {'modules': {'type': 'array', 'items': {'type': 'string', 'enum': ['web', 'cli', 'api']}},
          'runtime': {'type': 'string', 'enum': ['docker', 'local']},
          **{k: {'type': 'boolean'} for k in ('tui', 'global_command', 'recon', 'kali')},
          'ports': {'type': 'object', 'properties': {k: {'type': 'integer'} for k in DEFAULT_PORTS}, 'additionalProperties': False}}, ['modules']),
        ('install_selection', 'Show the prepared plan, ask the human for confirmation, then install through the validated Launcher. Failure returns to this conversation.', {}, []),
        ('repair_installation', 'Ask the human before repairing the saved/pending selection through the Launcher. Preserve versions and data; verify health.', {}, []),
    ]
    for name, description, properties, required in definitions:
        tools.append({'type': 'function', 'function': {
            'name': name, 'description': description,
            'parameters': {'type': 'object', 'properties': properties, 'required': required,
                           'additionalProperties': False}}})
    for index, tool in enumerate(tools):
        if tool['function']['name'] == 'finish':
            # Copy rather than mutate the legacy installer's tool definition.
            tool = {'type': 'function', 'function': {**tool['function'],
                    'description': 'End a diagnosis or a host-verified installation, then remain available for follow-up. It cannot declare an unverified install successful.'}}
            tools[index] = tool
            break
    return tools
