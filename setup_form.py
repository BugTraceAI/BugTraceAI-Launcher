"""Form selections resolve to the existing, validated installation profiles."""
from dataclasses import dataclass, field
import json
from pathlib import Path
import socket

PORT_KEYS = {'web': 'WEB_PORT', 'cli': 'CLI_PORT', 'cli_mcp': 'MCP_PORT',
             'api': 'BTAI_PORT', 'api_mcp': 'BTAI_MCP_PORT', 'recon': 'RECON_PORT'}

@dataclass
class SetupSelection:
    web: bool = False
    cli: bool = True
    api: bool = False
    tui: bool = True
    runtime: str = 'docker'
    global_command: bool = False
    recon: bool = False
    kali: bool = False
    provider: str = 'openrouter'
    api_key: str = field(default='', repr=False)
    ports: dict = field(default_factory=dict)

    @property
    def profile(self):
        if self.web:
            if self.cli and self.api: return 'full' if self.tui else 'web'
            if self.cli: return 'web-cli-tui' if self.tui else 'web-cli'
            if self.api: return 'web-api'
            return 'web-only'
        if self.cli and self.api:
            return 'engines-tui' if self.tui else 'engines'
        if self.cli:
            return 'terminal-server' if self.tui else 'server'
        if self.api:
            return 'api'
        raise ValueError('Select WEB, CLI or API before continuing.')

    def active_ports(self):
        keys = []
        if self.web: keys.append('web')
        if self.cli: keys.extend(('cli', 'cli_mcp'))
        if self.api: keys.extend(('api', 'api_mcp'))
        if self.recon: keys.append('recon')
        return {k: self.ports.get(k, 8002 if k == 'recon' else None) for k in keys}

    def validate(self, check_available=False):
        self.profile
        if not isinstance(self.api_key, str) or not self.api_key.strip():
            raise ValueError("Enter the selected provider's API key before continuing.")
        if any(c in self.api_key for c in ('\0','\r','\n')):
            raise ValueError('API key must be a single line.')
        if self.runtime == 'local' and (self.ports.get('cli') != 8000 or self.ports.get('cli_mcp') != 8001):
            raise ValueError('Local CLI uses ports 8000/8001. Choose Docker for custom ports.')
        if self.provider not in ('openrouter','anthropic','zai'):
            raise ValueError('Choose a supported provider.')
        if self.runtime not in ('docker','local') or (self.runtime == 'local' and (self.web or self.api)):
            raise ValueError('WEB and API require Docker. Local Python is available for CLI only.')
        if (self.recon or self.kali) and not (self.web and self.cli):
            raise ValueError('The current reconFTW/Kali integration requires both WEB and CLI. Select CLI explicitly to enable these extras.')
        seen=set()
        for key, value in self.active_ports().items():
            if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 65535:
                raise ValueError(f'{key} port must be between 1 and 65535.')
            if value in seen: raise ValueError('Selected service ports must be different.')
            seen.add(value)
            if check_available:
                with socket.socket() as sock:
                    try: sock.bind(('0.0.0.0', value))
                    except OSError: raise ValueError(f'Port {value} is occupied. Choose another port.') from None
        return self

    def payload(self):
        self.validate()
        return {'profile':self.profile,'runtime':self.runtime,'global':'yes' if self.tui and self.cli and self.global_command else 'no',
                'recon':self.recon,'kali':self.kali,'provider':self.provider,'api_key':self.api_key,
                'ports':{PORT_KEYS[k]:v for k,v in self.active_ports().items()}}


def load_config(path):
    data=json.loads(Path(path).read_text())
    from installer_core import parse_install_profiles
    profiles={p.key:p for p in parse_install_profiles((Path(__file__).parent/'installation-profiles.tsv').read_text())}
    profile=profiles.get(data.get('profile'))
    if profile is None:
        raise ValueError('Invalid setup profile')
    if data.get('runtime') not in ('docker','local') or data.get('global') not in ('yes','no'):
        raise ValueError('Invalid runtime/global selection')
    if profile.mode != 'cli' and data['runtime'] != 'docker':
        raise ValueError('This profile requires Docker')
    if data.get('provider') not in ('openrouter','anthropic','zai'):
        raise ValueError('Invalid provider')
    key = data.get('api_key')
    if not isinstance(key, str) or not key.strip():
        raise ValueError('Provider API key is required')
    if any(c in key for c in ('\0','\r','\n')): raise ValueError('Invalid key')
    for field in ('recon','kali'):
        if not isinstance(data.get(field),bool): raise ValueError('Invalid extras')
        if data[field] and not (profile.install_web and profile.install_cli): raise ValueError('Extras require WEB')
    ports=data.get('ports',{})
    if not isinstance(ports,dict) or set(ports)-set(PORT_KEYS.values()): raise ValueError('Invalid port names')
    required=set()
    if profile.install_web: required.add('WEB_PORT')
    if profile.install_cli: required.update(('CLI_PORT','MCP_PORT'))
    if profile.install_api: required.update(('BTAI_PORT','BTAI_MCP_PORT'))
    if data['recon']:
        required.add('RECON_PORT')
        # Accept handoffs produced by older Launchers, which omitted this port.
        ports.setdefault('RECON_PORT', 8002)
    if set(ports) != required: raise ValueError('Missing or unrelated service ports')
    if data['global']=='yes' and (not profile.install_cli or profile.cli_interface=='api'): raise ValueError('Global btai needs the TUI')
    for port in ports.values():
        if isinstance(port,bool) or not isinstance(port,int) or not 1 <= port <= 65535: raise ValueError('Invalid port')
    if len(set(ports.values())) != len(ports): raise ValueError('Duplicate ports')
    return data


def shell_values(path):
    data=load_config(path)
    values={'INSTALL_PROFILE':data['profile'],'REQUESTED_RUNTIME':data['runtime'],
            'REQUESTED_GLOBAL':data['global'],'LLM_PROVIDER':data['provider'],
            'API_KEY':data.get('api_key',''),'API_KEY_ENV_VAR':{'openrouter':'OPENROUTER_API_KEY','anthropic':'ANTHROPIC_API_KEY','zai':'GLM_API_KEY'}[data['provider']],
            'BUGTRACEAI_MCP_SELECTION_PRESET':'1','BUGTRACEAI_MCP_RECON':str(data['recon']).lower(),
            'BUGTRACEAI_MCP_KALI':str(data['kali']).lower(),**data['ports']}
    return values

if __name__ == '__main__':
    import sys
    # NUL-delimited values, never evaluated as shell code.
    for key,value in shell_values(sys.argv[1]).items():
        sys.stdout.buffer.write(key.encode()+b'\0'+str(value).encode()+b'\0')


def apply_cli_config(config_path, directory):
    """Apply only explicit form values; leave unrelated settings intact."""
    data=load_config(config_path)
    env=Path(directory)/'.env'
    updates={k:str(v) for k,v in data['ports'].items() if k in ('CLI_PORT','MCP_PORT')}
    updates['PROVIDER']=data['provider']
    if data.get('api_key'):
        key={'openrouter':'OPENROUTER_API_KEY','anthropic':'ANTHROPIC_API_KEY','zai':'GLM_API_KEY'}[data['provider']]
        # dotenv cannot represent arbitrary newlines as an unquoted assignment.
        value=data['api_key']
        if '\n' in value or '\r' in value: raise ValueError('API key must be a single line')
        updates[key]=value
    lines=env.read_text().splitlines() if env.exists() else []
    if env.exists():
        backup=env.with_name('.env.before-launcher-form')
        if not backup.exists():
            import shutil,os
            shutil.copyfile(env,backup); os.chmod(backup,0o600)
    output=[]
    for line in lines:
        name=line.split('=',1)[0].strip()
        if name in updates:
            output.append(name+'='+updates.pop(name))
        else: output.append(line)
    output.extend(k+'='+v for k,v in updates.items())
    import os
    fd=os.open(env,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as stream: stream.write('\n'.join(output)+'\n')
    os.chmod(env,0o600)

    conf=Path(directory)/'bugtraceaicli.conf'
    if conf.exists():
        import re
        from installer_core import cli_conf_active
        content=conf.read_text(); active=cli_conf_active(data['provider'])
        match=re.search(r'(?ms)^\[PROVIDER\]\s*$.*?(?=^\[|\Z)',content)
        if match:
            block=match.group()
            if re.search(r'(?m)^ACTIVE\s*=',block):
                updated=re.sub(r'(?m)^ACTIVE\s*=.*$', 'ACTIVE = '+active,block)
            else: updated=block.rstrip()+'\nACTIVE = '+active+'\n'
            content=content[:match.start()]+updated+content[match.end():]
        else: content+='\n[PROVIDER]\nACTIVE = '+active+'\n'
        conf.write_text(content)
