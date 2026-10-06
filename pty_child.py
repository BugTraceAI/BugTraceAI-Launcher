"""Give an embedded installer its own controlling terminal, including sudo/getpass."""
import fcntl
import os
import sys
import termios
os.setsid()
fcntl.ioctl(0, termios.TIOCSCTTY, 0)
os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
