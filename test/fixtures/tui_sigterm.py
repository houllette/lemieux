"""Open a terminal UI on a pseudo-terminal, send its VM SIGTERM once it is up,
and report what the terminal received.

    python3 tui_sigterm.py OPEN_SECONDS MARKER COMMAND [ARG...]

COMMAND runs as the pseudo-terminal's session leader, in this process's
environment and working directory, and must become the VM itself (`mix`
execs `elixir`, which execs `erl`, which execs the emulator), so that the
signal goes to the VM and not to a wrapper that would forward it. Once
MARKER has been drawn and a second has passed, the VM is sent SIGTERM; it
then has twenty seconds to exit.

Prints one JSON object: `opened` (whether MARKER was drawn), `seconds` (from
the signal to the VM's exit; null if it did not exit), `status` (the exit
status, or minus the signal that ended it), `stopped_at` (where in `output`
the signal was sent, in bytes) and `output` (every byte the terminal
received, in Base64). A VM still running at the end is killed.
"""
import base64
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

open_seconds = float(sys.argv[1])
marker = sys.argv[2].encode()
command = sys.argv[3:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
output = bytearray()
status = None


def drain(seconds):
    """Reads what the terminal received for up to SECONDS; False once it is closed."""
    if not select.select([fd], [], [], seconds)[0]:
        return True
    try:
        data = os.read(fd, 65536)
    except OSError:
        return False
    output.extend(data)
    return bool(data)


def exited():
    global status
    if status is None:
        done, code = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            # os.waitstatus_to_exitcode/1, which Python 3.8 lacks.
            status = os.WEXITSTATUS(code) if os.WIFEXITED(code) else -os.WTERMSIG(code)
    return status is not None


def until(check, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return True
        if not drain(0.05):
            time.sleep(0.05)
    return check()


opened = until(lambda: marker in output or exited(), open_seconds) and marker in output
seconds = None
stopped_at = len(output)

try:
    if opened and not exited():
        # The host registers its trap right after the screen starts; the
        # marker is drawn later, once the session is up. A second more is
        # margin, not a guess about the order.
        until(lambda: False, 1)
        stopped_at = len(output)
        signalled = time.monotonic()
        os.kill(pid, signal.SIGTERM)
        if until(exited, 20):
            seconds = time.monotonic() - signalled
        # What was written last may still be waiting to be read.
        until(lambda: False, 0.5)
finally:
    if not exited():
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(fd)

print(json.dumps({
    "opened": opened,
    "seconds": seconds,
    "status": status,
    "stopped_at": stopped_at,
    "output": base64.b64encode(bytes(output)).decode("ascii"),
}))
