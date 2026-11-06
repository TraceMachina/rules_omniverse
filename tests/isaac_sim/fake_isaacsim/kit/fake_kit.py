"""Stub of Isaac Sim's SimulationApp that ends its process like Kit.

Shared by the two layouts of the stub isaacsim package, image/ and package/.
Each layout defines its own
SimulationApp, a subclass of this one with no methods of its own, in the
module where the layout says it is defined, so that reloading that module
creates a new class, as in the image.

It does what Kit does in the Isaac Sim image:

- Importing the package does not start Kit; SimulationApp() does. If
  FAKE_KIT_REJECTS_MULTILINE_C=1, start-up exits 1 with no Python error when
  any -c argument of the process (sys.orig_argv) contains a line break, as
  Kit's start-up does in the image. The other tests leave it off so that they
  do not depend on how the launcher starts the script.
- close() never returns: it ends the process with exit code 0.
- A started app that is never closed shuts down at exit and ends the process
  with exit code 0, whatever the script did.

If FAKE_KIT_EVENTS names a file, each step appends one JSON line to it.
"""

import atexit
import json
import os
import sys


def _record(event, **fields):
    path = os.environ.get("FAKE_KIT_EVENTS")
    if path:
        with open(path, "a") as f:
            f.write(json.dumps(dict(event=event, **fields)) + "\n")


def _rejects_command_line():
    argv = sys.orig_argv
    return any(arg == "-c" and i + 1 < len(argv) and "\n" in argv[i + 1] for i, arg in enumerate(argv))


def _shutdown():
    _record("shutdown")
    os._exit(0)


class SimulationApp:
    def __init__(self, launch_config=None, experience=""):
        if os.environ.get("FAKE_KIT_REJECTS_MULTILINE_C") == "1" and _rejects_command_line():
            _record("startup_failed")
            os._exit(1)
        _record("start", launch_config=launch_config)
        atexit.register(_shutdown)

    def update(self):
        pass

    def close(self, wait_for_replicator=True, skip_cleanup=False):
        _record("close", wait_for_replicator=wait_for_replicator, skip_cleanup=skip_cleanup)
        os._exit(0)
