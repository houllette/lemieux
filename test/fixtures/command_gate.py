"""An OS command whose progress and death are observable without sleeps."""
import pathlib
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5) as control:
    control.settimeout(10)
    print(sys.argv[2], end="", flush=True)
    control.sendall(b"ready\n")
    if control.recv(1) == b"x":
        pathlib.Path("late-marker").touch()
        print(sys.argv[3], end="", flush=True)
