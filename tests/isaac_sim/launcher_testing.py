"""Shared by the launcher tests.

Each test gets a temporary folder holding the script under test, its output
folder out/, and the stub Kit's event log, and runs the script directly or
under isaac_sim_launcher.py.
"""

import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

LAUNCHER = os.path.abspath(os.environ["ISAAC_SIM_LAUNCHER"])

NO_REPORT = "no completion report"

# Writes 5 of 10 frames to the output directory given as argv[1], so the
# output is not empty when the script then fails (the runner's empty-output
# check alone would pass it).
PARTIAL_OUTPUT = """\
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for frame in range(5):
    with open(os.path.join(out, "rgb_%04d.png" % frame), "w") as f:
        f.write("frame %d" % frame)
"""


def fake_isaacsim(init_variable):
    """PYTHONPATH for a stub isaacsim in tests/isaac_sim/fake_isaacsim and the stub Kit it uses.

    init_variable names the environment variable that holds the path of the
    layout's isaacsim/__init__.py; FAKE_KIT holds that of kit/fake_kit.py.
    """
    init = os.path.abspath(os.environ[init_variable])
    kit = os.path.abspath(os.environ["FAKE_KIT"])
    return os.pathsep.join([os.path.dirname(os.path.dirname(init)), os.path.dirname(kit)])


class LauncherTestCase(unittest.TestCase):
    def setUp(self):
        # realpath, so paths have one spelling on macOS too.
        self.root = os.path.realpath(tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR")))
        self.out = os.path.join(self.root, "out")
        self.script = os.path.join(self.root, "generate.py")
        self.events = os.path.join(self.root, "kit_events.jsonl")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def reset(self):
        """Removes what a run left: the output, Kit's events, and the script's records (SCRIPT.*)."""
        shutil.rmtree(self.out, ignore_errors=True)
        for path in glob.glob(glob.escape(self.script) + ".*") + [self.events]:
            if os.path.exists(path):
                os.remove(path)

    def write_script(self, *parts):
        self.reset()
        with open(self.script, "w") as f:
            f.write("".join(textwrap.dedent(part) for part in parts))

    def environ(self):
        """The environment of every process the test starts, unless it passes its own."""
        return dict(os.environ)

    def run_python(self, args, env=None, python=sys.executable):
        return subprocess.run(
            [python, *args], capture_output=True, text=True, env=env or self.environ(), timeout=60
        )

    def launch(self, scene=None, assets=(), args=None, env=None, python=sys.executable):
        """Runs the script under the launcher; its arguments are args, by default [out]."""
        command = [LAUNCHER]
        if scene:
            command += ["--scene", scene]
        for asset in assets:
            command += ["--asset", asset]
        command += ["--", self.script, *([self.out] if args is None else args)]
        return self.run_python(command, env, python)

    def run_directly(self, env=None):
        return self.run_python([self.script, self.out], env)

    def script_ran(self, suffix=".ran"):
        return os.path.exists(self.script + suffix)

    def recorded(self, suffix=".ran"):
        """What the script wrote, as JSON, to SCRIPT + suffix."""
        self.assertTrue(self.script_ran(suffix), "the script did not write %s" % (self.script + suffix))
        with open(self.script + suffix) as f:
            return json.load(f)

    def kit_events(self):
        """The stub Kit's events, if FAKE_KIT_EVENTS was set (see fake_isaacsim/kit/fake_kit.py)."""
        if not os.path.exists(self.events):
            return []
        with open(self.events) as f:
            return [json.loads(line) for line in f]

    def kit_event_names(self):
        return [event["event"] for event in self.kit_events()]

    def output_files(self):
        if not os.path.isdir(self.out):
            return []
        return sorted(os.listdir(self.out))

    def assertReported(self, result, status):
        """The launcher exits with status, taken from the script process's completion report."""
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertNotIn(NO_REPORT, result.stderr, "the launcher got no completion report")
