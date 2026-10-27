"""Run installer interaction inside a Textual screen, without suspending the TUI."""
import codecs
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import struct
import sys
import termios
import threading
from textual import work
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, RichLog, Static

ROOT=Path(__file__).resolve().parent
ANSI=re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)')

def session_text(chunk, decoder):
    """Decode one PTY chunk, keeping progress rewrites readable."""
    return ANSI.sub('', decoder.decode(chunk)).replace('\r\n','\n').replace('\r','\n')


class StreamingRedactor:
    """Hide secrets even when the PTY splits them across separate reads."""
    def __init__(self, secrets):
        self.secrets = secrets
        self.pending = ''

    def feed(self, text, final=False):
        data = self.pending + text
        self.pending = ''
        secrets = sorted((s for s in self.secrets if s), key=len, reverse=True)
        output = []
        while data:
            match = next((secret for secret in secrets if data.startswith(secret)), None)
            if match:
                output.append('[REDACTED]')
                data = data[len(match):]
            elif not final and any(secret.startswith(data) for secret in secrets):
                self.pending = data
                break
            else:
                output.append(data[0])
                data = data[1:]
        return ''.join(output)


class StopConfirmation(ModalScreen[bool]):
    BINDINGS=[('escape','cancel','')]
    CSS='''
    StopConfirmation { align: center middle; background: #1A0F2EDD; }
    #stop-confirm { width: 90%; max-width: 66; height: auto; padding: 1 2; background: #211338; border: round #FF7F50; }
    #stop-title { height: 1; color: #FF7F50; text-style: bold; margin-bottom: 1; }
    #stop-message { height: auto; margin-bottom: 1; }
    #stop-actions { height: 3; align-horizontal: right; }
    '''
    def compose(self):
        with Vertical(id='stop-confirm'):
            yield Static('STOP THIS SESSION?',id='stop-title')
            yield Static('The running installer will be terminated. Files already written are kept; a partial installation may need repair.',id='stop-message',markup=False)
            with Horizontal(id='stop-actions'):
                yield Button('Keep running',id='keep-session')
                yield Button('Stop install',id='confirm-stop',variant='error')

    def on_button_pressed(self,event):
        self.dismiss(event.button.id=='confirm-stop')

    def action_cancel(self):
        self.dismiss(False)


class InstallerSession(ModalScreen[int]):
    BINDINGS=[('escape','ignore_key',''),('q','ignore_key','')]
    CSS='''
    InstallerSession { background: #1A0F2E; padding: 1 2; }
    #session-title { height: 2; color: #FF7F50; text-style: bold; }
    #session-log { height: 1fr; background: #211338; border: round #594477; }
    #reply-label { height: 2; color: #B9A9D3; }
    #session-reply { height: 3; background: #302047; }
    #session-actions { height: 3; align-horizontal: right; }
    #session-actions Button { margin-left: 1; }
    '''
    def __init__(self, command, env, secrets=(), cleanup=None, kind=None):
        super().__init__()
        self.command=command; self.env=env; self.secrets=list(filter(None,secrets)); self.cleanup=cleanup
        self.kind=kind
        self.process=None; self.master=None; self.exit_code=None; self.cancelled=False
        self.stop_requested=threading.Event()
        self.last_output=''
        self.prompt_sensitive=False

    def compose(self):
        yield Static('BugTraceAI · Installer conversation',id='session-title')
        yield RichLog(wrap=True,markup=False,highlight=False,max_lines=2000,id='session-log')
        yield Static('Reply to the prompt shown above. Passwords are hidden.',id='reply-label')
        yield Input(placeholder='Reply…',password=True,id='session-reply')
        with Horizontal(id='session-actions'):
            yield Button('Send',id='send-reply')
            yield Button('Stop session',id='stop-session')
            yield Button('Back',id='close-session',disabled=True)

    def on_mount(self):
        self.host=self.app
        self.start_session()
        self.query_one('#session-reply',Input).focus()

    def set_terminal_size(self, fd):
        # openpty defaults to 0x0. Terminal formatters then compute negative
        # wrapping widths before the assistant can ask its first question.
        rows=max(10, min(65535, self.host.size.height-8))
        columns=max(20, min(65535, self.host.size.width-8))
        fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',rows,columns,0,0))

    def on_resize(self, event):
        if self.master is not None:
            try: self.set_terminal_size(self.master)
            except OSError: pass

    @work(thread=True,exclusive=True)
    def start_session(self):
        decoder=codecs.getincrementaldecoder('utf-8')('replace')
        redactor=StreamingRedactor(self.secrets)
        master,slave=pty.openpty()
        self.master=master
        try:
            self.set_terminal_size(slave)
            # Children see an actual TTY; their native secret prompts remain native.
            self.process=subprocess.Popen([sys.executable,str(ROOT/'pty_child.py'),*self.command],
                stdin=slave,stdout=slave,stderr=slave,env=self.env,close_fds=True)
            os.close(slave); slave=None
            last_hidden = None
            while self.process.poll() is None or select.select([master],[],[],0)[0]:
                if self.stop_requested.is_set():
                    try: os.killpg(self.process.pid,signal.SIGTERM)
                    except ProcessLookupError: self.process.terminate()
                    try: self.process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        try: os.killpg(self.process.pid,signal.SIGKILL)
                        except ProcessLookupError: self.process.kill()
                    break
                hidden=not bool(termios.tcgetattr(master)[3]&termios.ECHO)
                if hidden != last_hidden:
                    self.dispatch(self.set_hidden, hidden)
                    last_hidden=hidden
                if not select.select([master],[],[],.05)[0]: continue
                try: chunk=os.read(master,8192)
                except OSError as exc:
                    if exc.errno == errno.EIO: break
                    raise
                if not chunk: break
                text=redactor.feed(session_text(chunk,decoder))
                hidden=not bool(termios.tcgetattr(master)[3]&termios.ECHO)
                self.dispatch(self.render_output,text,hidden)
            remaining=redactor.feed(decoder.decode(b'',final=True), final=True)
            if remaining: self.dispatch(self.render_output,remaining,True)
            code=self.process.wait()
        except Exception as exc:
            self.dispatch(self.render_output,f'Session could not run: {type(exc).__name__}',True)
            code=1
        finally:
            if slave is not None: os.close(slave)
            os.close(master); self.master=None
            if self.cleanup: self.cleanup()
        self.dispatch(self.finished,code)

    def dispatch(self, function, *args):
        if not self.host.is_running or not self.is_mounted: return
        try: self.host.call_from_thread(function,*args)
        except RuntimeError: pass  # app shutdown; child cleanup still runs

    def render_output(self,text,hidden):
        if text:
            self.last_output=(self.last_output+text)[-512:]
            self.query_one('#session-log',RichLog).write(text)
            if re.search(r'(?:password|passphrase|api[ _-]?key|token|credential|secret)[^\n]{0,80}:[ \t]*\Z', self.last_output, re.I):
                self.prompt_sensitive=True
        self.set_hidden(hidden)

    def set_hidden(self,hidden):
        hidden = hidden or self.prompt_sensitive
        self.query_one('#session-reply',Input).password=hidden
        self.query_one('#reply-label',Static).update('Hidden input · credentials are not added to the conversation' if hidden else 'Reply to the installer or AI assistant below')

    def send_reply(self):
        field=self.query_one('#session-reply',Input)
        if self.master is None or self.exit_code is not None: return
        try:
            hidden=not bool(termios.tcgetattr(self.master)[3]&termios.ECHO)
        except OSError:
            return
        # Readline and confirmation prompts can temporarily disable echo too;
        # a yes/no response is not a password and must not redact every letter.
        approval = re.search(r'(?:\[[yYnN/ ]+\]|\(y/n\)|run this command\?)\s*:?\s*$', self.last_output, re.I)
        if (hidden or self.prompt_sensitive) and field.value and not approval: self.secrets.append(field.value)
        try: os.write(self.master,(field.value+'\n').encode())
        except OSError: return
        field.value=''
        self.prompt_sensitive=False

    def on_input_submitted(self,event): self.send_reply()
    def action_ignore_key(self): pass
    def _stop_confirmed(self,confirmed):
        if confirmed and self.exit_code is None:
            self.cancelled=True
            self.stop_requested.set()
    def on_button_pressed(self,event):
        if event.button.id=='send-reply': self.send_reply()
        elif event.button.id=='stop-session':
            if self.exit_code is None: self.app.push_screen(StopConfirmation(),self._stop_confirmed)
        elif event.button.id=='close-session': self.dismiss(130 if self.cancelled else self.exit_code)

    def finished(self,code):
        self.exit_code=code
        title=self.query_one('#session-title',Static)
        detail=self.query_one('#reply-label',Static)
        close_button=self.query_one('#close-session',Button)
        if self.cancelled:
            title.update('Session stopped · completion was not confirmed')
            detail.update('Review the output above, then choose Back to return.')
            title.styles.color='#FF7F50'
            close_button.label='Back'
        elif code == 0:
            success_titles={
                'install':'Installation completed successfully',
                'update':'Update completed successfully',
                'repair':'Repair completed successfully',
                'assistant':'Assistant session completed successfully',
            }
            operation=success_titles.get(self.kind,'Session completed successfully')
            title.update(f'{operation} · exit 0')
            if self.kind == 'install':
                detail.update('The installer finished successfully. Review the service URLs above, then choose Exit.')
            elif self.kind == 'update':
                detail.update('The update finished successfully. Review the output above, then choose Exit.')
            else:
                detail.update('The session finished successfully. Review the output above, then choose Exit.')
            title.styles.color='#2ECC71'
            close_button.label='Exit'
        else:
            title.update(f'Process ended with an error · exit {code}')
            detail.update('The operation did not complete successfully. Review the output above before choosing Back.')
            title.styles.color='#FF7F50'
            close_button.label='Back'
        close_button.disabled=False
        self.query_one('#stop-session',Button).disabled=True
        self.query_one('#session-reply',Input).disabled=True
        self.query_one('#send-reply',Button).disabled=True
        self.query_one('#close-session',Button).focus()

    def on_unmount(self): self.stop_requested.set()
