"""Run a bounded offline fixture on a controlling terminal and return its bytes."""
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

pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
output = bytearray()
status = None
deadline = time.monotonic() + 60
terminal_open = True
try:
    while time.monotonic() < deadline:
        if terminal_open and select.select([fd], [], [], 0.05)[0]:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            terminal_open = bool(data)
            output.extend(data)
        if not terminal_open:
            time.sleep(0.01)
        done, code = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            status = os.waitstatus_to_exitcode(code)
            break
finally:
    if status is None:
        done, code = os.waitpid(pid, os.WNOHANG)
        if done != pid:
            os.kill(pid, signal.SIGKILL)
            _, code = os.waitpid(pid, 0)
        status = os.waitstatus_to_exitcode(code)
    os.close(fd)

print(json.dumps({"status": status, "output": base64.b64encode(output).decode("ascii")}))
