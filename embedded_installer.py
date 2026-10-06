"""Run installer interaction inside a Textual screen, without suspending the TUI."""
import codecs
import errno
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import threading
from textual import work
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, RichLog, Static

ROOT=Path(__file__).resolve().parent
ANSI=re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)')

class InstallerSession(ModalScreen[int]):
    CSS='''
    InstallerSession { background: #1A0F2E; padding: 1 2; }
    #session-title { height: 2; color: #FF7F50; text-style: bold; }
    #session-log { height: 1fr; background: #211338; border: round #594477; }
    #reply-label { height: 1; color: #B9A9D3; }
    #session-reply { height: 3; background: #302047; }
    #session-actions { height: 3; align-horizontal: right; }
    #session-actions Button { margin-left: 1; }
    '''
    def __init__(self, command, env, secrets=(), cleanup=None):
        super().__init__()
        self.command=command; self.env=env; self.secrets=list(filter(None,secrets)); self.cleanup=cleanup
        self.process=None; self.master=None; self.exit_code=None; self.cancelled=False
        self.stop_requested=threading.Event()

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

    @work(thread=True,exclusive=True)
    def start_session(self):
        decoder=codecs.getincrementaldecoder('utf-8')('replace')
        master,slave=pty.openpty()
        self.master=master
        try:
            # Children see an actual TTY; their native secret prompts remain native.
            self.process=subprocess.Popen([sys.executable,str(ROOT/'pty_child.py'),*self.command],
                stdin=slave,stdout=slave,stderr=slave,env=self.env,close_fds=True)
            os.close(slave); slave=None
            while self.process.poll() is None or select.select([master],[],[],0)[0]:
                if self.stop_requested.is_set():
                    try: os.killpg(self.process.pid,signal.SIGTERM)
                    except ProcessLookupError: self.process.terminate()
                    try: self.process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        try: os.killpg(self.process.pid,signal.SIGKILL)
                        except ProcessLookupError: self.process.kill()
                    break
                if not select.select([master],[],[],.15)[0]: continue
                try: chunk=os.read(master,8192)
                except OSError as exc:
                    if exc.errno == errno.EIO: break
                    raise
                if not chunk: break
                text=ANSI.sub('',decoder.decode(chunk)).replace('\r','')
                for secret in self.secrets: text=text.replace(secret,'[REDACTED]')
                hidden=not bool(termios.tcgetattr(master)[3]&termios.ECHO)
                self.dispatch(self.render_output,text,hidden)
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
        self.query_one('#session-log',RichLog).write(text)
        self.query_one('#session-reply',Input).password=hidden
        self.query_one('#reply-label',Static).update('Hidden input · credentials are not added to the conversation' if hidden else 'Reply to the installer or AI assistant below')

    def send_reply(self):
        field=self.query_one('#session-reply',Input)
        if self.master is None or self.exit_code is not None: return
        if field.password and field.value: self.secrets.append(field.value)
        try: os.write(self.master,(field.value+'\n').encode())
        except OSError: return
        field.value=''

    def on_input_submitted(self,event): self.send_reply()
    def on_button_pressed(self,event):
        if event.button.id=='send-reply': self.send_reply()
        elif event.button.id=='stop-session':
            self.cancelled=True; self.stop_requested.set()
        elif event.button.id=='close-session': self.dismiss(130 if self.cancelled else self.exit_code)

    def finished(self,code):
        self.exit_code=code
        self.query_one('#session-title',Static).update('Session stopped' if self.cancelled else f'Session ended · exit {code}')
        self.query_one('#close-session',Button).disabled=False
        self.query_one('#stop-session',Button).disabled=True
        self.query_one('#session-reply',Input).disabled=True
        self.query_one('#send-reply',Button).disabled=True
        self.query_one('#close-session',Button).focus()

    def on_unmount(self): self.stop_requested.set()
