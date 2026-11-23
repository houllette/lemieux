"""Run a bounded offline fixture on a controlling terminal and return its bytes.

Pass --respond with a JSON list of [prompt, reply] pairs before the command
to send each reply when its prompt appears in the terminal output.
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

command = sys.argv[1:]
replies = []
if command[0] == "--respond":
    replies = [(prompt.encode(), reply.encode()) for prompt, reply in json.loads(command[1])]
    command = command[2:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

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
            if replies and replies[0][0] in output:
                _, reply = replies.pop(0)
                os.write(fd, reply)
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
