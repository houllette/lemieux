"""Wait for an unrelated OS process to exit, including an unreaped zombie."""
import os
import select
import sys

pid = int(sys.argv[1])
try:
    if hasattr(os, "pidfd_open"):
        descriptor = os.pidfd_open(pid)
        try:
            ready, _, _ = select.select([descriptor], [], [], 2)
        finally:
            os.close(descriptor)
    else:
        queue = select.kqueue()
        try:
            event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  fflags=select.KQ_NOTE_EXIT)
            ready = queue.control([event], 1, 2)
        finally:
            queue.close()
except ProcessLookupError:
    ready = True

if not ready:
    sys.exit("process %s is still running" % pid)
