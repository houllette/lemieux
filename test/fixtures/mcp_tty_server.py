"""An offline SSH-like wrapper whose late helper tries the controlling tty."""
import json
import os
import stat
import subprocess
import sys

helper = r'''
import json, os, socket, stat
opened = False
try:
    fd = os.open('/dev/tty', os.O_WRONLY | os.O_NOCTTY)
except OSError:
    pass
else:
    opened = True
    os.write(fd, b'TTY_LEAK_MARKER\x1b[2Jclient_loop: timeout\r\n')
    os.close(fd)
captured = stat.S_ISSOCK(os.fstat(2).st_mode)
os.write(2, b'\x1b[31mSSH_DIAGNOSTIC_MARKER Operation timed out\x1b[0m\n')
diagnostic = socket.socket(fileno=2)
diagnostic.shutdown(socket.SHUT_WR)
diagnostic.recv(1)
diagnostic.detach()
print(json.dumps({'tty_opened': opened, 'stderr_socket': captured}), flush=True)
'''

for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "disconnect":
        child = subprocess.run([sys.executable, "-c", helper], stdout=subprocess.PIPE, check=True)
        result = json.loads(child.stdout)
    else:
        result = {"stderr_socket": stat.S_ISSOCK(os.fstat(2).st_mode)}
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
