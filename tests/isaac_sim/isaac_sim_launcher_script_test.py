"""The launcher runs the script and exits by how the script ended.

Kit ends its process with exit code 0 however the Python script ended, and in
the Isaac Sim image SimulationApp.close() never returns: it ends the process
with exit code 0. So a crash inside `try: ... finally: simulation_app.close()`
never reaches the code after the script, prints no traceback and exits 0.

The stub isaacsim package in fake_isaacsim/ does the same: close() calls
os._exit(0), and a started app that is never closed ends the process with
os._exit(0) at exit. With FAKE_KIT_REJECTS_MULTILINE_C=1 its start-up also
exits 1, with no Python error, when the process was started with a multi-line
`python -c`, as Kit's does in the image. It comes in two layouts: as in the
image (isaacsim.simulation_app is a placeholder without __spec__ and
SimulationApp is defined in a top-level simulation_app package), and with
isaacsim.simulation_app a regular subpackage. Every close() test runs with both.
"""

import json
import os
import unittest

from launcher_testing import NO_REPORT, PARTIAL_OUTPUT, LauncherTestCase, fake_isaacsim

IMAGE_LAYOUT = fake_isaacsim("FAKE_ISAACSIM")
PACKAGE_LAYOUT = fake_isaacsim("FAKE_ISAACSIM_PACKAGE")
FAKE_KIT = os.path.dirname(os.path.abspath(os.environ["FAKE_KIT"]))
WRAPPER = os.path.abspath(os.environ["EXAMPLE_WRAPPER"])


class KitTestCase(LauncherTestCase):
    # PYTHONPATH of the script's process, which finds the stub isaacsim.
    PYTHONPATH = IMAGE_LAYOUT

    def environ(self):
        env = super().environ()
        # rules_python sets PYTHONSAFEPATH for tests; the image does not, and
        # with it `python SCRIPT` would not put the script's folder on sys.path.
        env.pop("PYTHONSAFEPATH", None)
        env["PYTHONPATH"] = self.PYTHONPATH
        env["FAKE_KIT_EVENTS"] = self.events
        return env


# Like Kit: whatever happens below, the process ends with exit code 0.
# These tests run without isaacsim, so the launcher cannot patch close().
KIT_EXIT = """\
import atexit, json, os, sys
atexit.register(lambda: os._exit(0))
"""

CRASH = 'raise RuntimeError("deliberate crash at frame 5 of 10")\n'


class ExitStatusTest(LauncherTestCase):
    """A script that fails makes the launcher fail, even when its process exits 0."""

    def test_crash_after_partial_output_fails(self):
        tracebacks = {
            "printed traceback": "",
            # Kit sends Python errors to its own log. Here nothing is printed
            # at all, so a launcher that reads the output cannot see the failure.
            "no traceback": "sys.excepthook = lambda *exc_info: None\n",
        }
        for name, hide in tracebacks.items():
            with self.subTest(name):
                # Precondition: the simulated Kit really hides the crash. If
                # this fails, the simulation is broken, not the launcher.
                self.write_script(KIT_EXIT, hide, PARTIAL_OUTPUT, CRASH)
                direct = self.run_directly()
                self.assertEqual(direct.returncode, 0, direct.stderr)
                if hide:
                    self.assertEqual(direct.stderr, "", "precondition: the crash is silent")
                else:
                    self.assertIn("deliberate crash", direct.stderr)
                self.assertEqual(len(self.output_files()), 5)

                self.reset()
                result = self.launch()
                self.assertReported(result, 1)
                self.assertEqual(len(self.output_files()), 5, "precondition: the output is not empty")

    def test_system_exit_with_nonzero_code_fails(self):
        for code, expected in [("3", 3), ('"fatal: no camera"', 1)]:
            with self.subTest(code=code):
                self.write_script(KIT_EXIT, PARTIAL_OUTPUT, "sys.exit(%s)\n" % code)
                result = self.launch()
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_normal_finish_succeeds(self):
        record = """\
        with open(sys.argv[0] + ".ran", "w") as f:
            json.dump({"name": __name__, "argv": sys.argv}, f)
        """
        for ending in ["", "sys.exit(0)\n", "sys.exit(None)\n"]:
            with self.subTest(ending=ending):
                self.write_script(KIT_EXIT, PARTIAL_OUTPUT, record, ending)
                result = self.launch()
                self.assertEqual(result.returncode, 0, result.stderr)
                ran = self.recorded()
                # The script still runs as a program of its own.
                self.assertEqual(ran["name"], "__main__")
                self.assertEqual(ran["argv"], [self.script, self.out])

    def test_error_text_in_output_does_not_fail(self):
        # Detection must not parse logs: error-looking text from a script that
        # finishes normally is not a failure.
        self.write_script(
            KIT_EXIT,
            PARTIAL_OUTPUT,
            """\
            text = 'Traceback (most recent call last):\\nRuntimeError: boom\\n[Error] [omni.kit.app] failed\\n'
            sys.stdout.write(text)
            sys.stderr.write(text)
            sys.stdout.flush()
            sys.stderr.flush()
            """,
        )
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)


# Starts the stub Kit, as a Replicator script does.
START = """\
import json, os, sys
from isaacsim import SimulationApp

app = SimulationApp({"headless": True})
"""


class WrapperFileTest(KitTestCase):
    """The launcher runs the script's wrapper from a file, not with a multi-line -c."""

    def environ(self):
        env = super().environ()
        env["FAKE_KIT_REJECTS_MULTILINE_C"] = "1"
        return env

    # Precondition: the stub Kit fails like the image's Kit. If this fails,
    # the stub is broken, not the launcher.
    def test_precondition_fake_kit_rejects_multiline_c(self):
        start = "from isaacsim import SimulationApp; app = SimulationApp(); app.close()"
        result = self.run_python(["-c", start.replace("; ", "\n")])
        self.assertEqual((result.returncode, result.stderr), (1, ""), "multi-line -c must fail silently")
        self.assertEqual(self.kit_event_names(), ["startup_failed"])

        self.reset()
        result = self.run_python(["-c", start])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.kit_event_names(), ["start", "close"])

        self.write_script(START, PARTIAL_OUTPUT, "app.close()\n")
        result = self.run_directly()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.kit_event_names(), ["start", "close"])

    def test_kit_starts_under_launcher(self):
        self.write_script(START, PARTIAL_OUTPUT, "app.close()\n")
        result = self.launch()
        self.assertNotIn(
            "startup_failed",
            self.kit_event_names(),
            "Kit's start-up saw a -c argument with a line break:\n" + result.stderr,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.kit_event_names(), ["start", "close"])
        self.assertEqual(len(self.output_files()), 5)

    def test_script_sees_what_python_script_gives(self):
        # Running the wrapper from a file must not change what the script
        # sees: the same __name__, __file__, argv and sys.path[0] as
        # `python SCRIPT`, so it can import modules next to it.
        with open(os.path.join(self.root, "sibling.py"), "w") as f:
            f.write("VALUE = 'next to the script'\n")
        self.write_script(
            """\
            import json, sys
            import sibling

            with open(sys.argv[0] + ".ran", "w") as f:
                json.dump(
                    {
                        "name": __name__,
                        "file": __file__,
                        "argv": sys.argv,
                        "path0": sys.path[0],
                        "sibling": sibling.VALUE,
                    },
                    f,
                )
            """
        )
        direct = self.run_directly()
        self.assertEqual(direct.returncode, 0, direct.stderr)
        expected = self.recorded()

        self.reset()
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded(), expected)

    def test_same_sys_path_as_python_script_with_pythonsafepath(self):
        # With PYTHONSAFEPATH=1, `python SCRIPT` adds no script folder to
        # sys.path, so the PYTHONPATH entries come first, all of them. The
        # script must see exactly that import path under the launcher too.
        first = os.path.join(self.root, "first")
        second = os.path.join(self.root, "second")
        os.makedirs(first)
        os.makedirs(second)
        env = self.environ()
        env["PYTHONSAFEPATH"] = "1"
        env["PYTHONPATH"] = os.pathsep.join([first, second])
        self.write_script(
            """\
            import json, sys

            with open(sys.argv[0] + ".sys_path", "w") as f:
                json.dump(sys.path, f)
            """
        )
        direct = self.run_directly(env)
        self.assertEqual(direct.returncode, 0, direct.stderr)
        expected = self.recorded(".sys_path")
        # Precondition: this interpreter honours PYTHONSAFEPATH. If this
        # fails, the test setup is broken, not the launcher.
        self.assertEqual(expected[:2], [first, second])
        self.assertNotIn(self.root, expected)

        self.reset()
        result = self.launch(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded(".sys_path"), expected)


# Marks that code after close() ran; it must not, as in the image.
AFTER_CLOSE = """\
with open(sys.argv[0] + ".after_close", "w") as f:
    f.write("close() returned")
"""

# The two ways scripts import SimulationApp; the image's isaacsim re-exports it
# from isaacsim.simulation_app.
IMPORT_FORMS = {
    "from isaacsim import": START,
    "from isaacsim.simulation_app import": START.replace("from isaacsim import", "from isaacsim.simulation_app import"),
}

# Ways a crash meets close(). Each one, run directly, ends with exit code 0.
CRASH_THEN_CLOSE = {
    "try/finally": """\
        try:
            raise RuntimeError("deliberate crash at frame 5 of 10")
        finally:
            app.close()
        """,
    "with statement": """\
        class Closing:
            def __enter__(self):
                return app

            def __exit__(self, *exc_info):
                app.close()

        with Closing():
            raise RuntimeError("deliberate crash at frame 5 of 10")
        """,
    "function called from finally": """\
        def shut_down():
            app.close()

        try:
            raise RuntimeError("deliberate crash at frame 5 of 10")
        finally:
            shut_down()
        """,
}


class CloseTest(KitTestCase):
    """The script's ending is reported through SimulationApp.close(), and silence fails.

    The stub isaacsim laid out as in the image.
    """

    PYTHONPATH = IMAGE_LAYOUT
    # Where SimulationApp is defined, and whether isaacsim.simulation_app is
    # a placeholder module without __spec__.
    DEFINING_MODULE = "simulation_app.simulation_app"
    PLACEHOLDER = True

    def assertClosedLikeKit(self, result):
        """close() ran, with no automatic shutdown after it, and did not return."""
        self.assertEqual(self.kit_event_names(), ["start", "close"], result.stderr)
        self.assertFalse(self.script_ran(".after_close"), "close() returned to the script")

    # Precondition: the stub's layout is the one this class tests, and
    # importing isaacsim does not start Kit. If this fails, the stub is
    # broken, not the launcher.
    def test_precondition_layout(self):
        self.write_script(
            """\
            import json, sys
            import isaacsim
            from isaacsim import SimulationApp as package_form
            from isaacsim.simulation_app import SimulationApp as module_form

            with open(sys.argv[0] + ".layout", "w") as f:
                json.dump(
                    {
                        "defined in": package_form.__module__,
                        "same class": package_form is module_form,
                        "placeholder": sys.modules["isaacsim.simulation_app"].__spec__ is None,
                    },
                    f,
                )
            """
        )
        result = self.run_directly()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.recorded(".layout"),
            {"defined in": self.DEFINING_MODULE, "same class": True, "placeholder": self.PLACEHOLDER},
        )
        self.assertEqual(self.kit_events(), [], "importing isaacsim started Kit")

    # Precondition: the stub Kit hides a crash in try/finally like the image
    # did. If this fails, the stub is broken, not the launcher.
    def test_precondition_crash_then_close_exits_zero_silently(self):
        for name, crash in CRASH_THEN_CLOSE.items():
            with self.subTest(name):
                self.write_script(START, PARTIAL_OUTPUT, crash, AFTER_CLOSE)
                result = self.run_directly()
                self.assertEqual((result.returncode, result.stderr), (0, ""))
                self.assertClosedLikeKit(result)
                self.assertEqual(len(self.output_files()), 5)

    def test_crash_then_close_fails(self):
        for form, start in IMPORT_FORMS.items():
            for name, crash in CRASH_THEN_CLOSE.items():
                with self.subTest(form=form, crash=name):
                    self.write_script(start, PARTIAL_OUTPUT, crash, AFTER_CLOSE)
                    result = self.launch()
                    self.assertReported(result, 1)
                    self.assertClosedLikeKit(result)
                    self.assertEqual(len(self.output_files()), 5, "precondition: the output is not empty")

    def test_close_while_handling_an_error_fails(self):
        # Deliberate: a script that handles an error and closes from inside
        # the handler fails, even if it meant to recover.
        self.write_script(
            START,
            PARTIAL_OUTPUT,
            """\
            try:
                raise ValueError("camera not found")
            except ValueError:
                print("recovering")
                app.close()
            """,
            AFTER_CLOSE,
        )
        result = self.launch()
        self.assertReported(result, 1)
        self.assertClosedLikeKit(result)

    def test_system_exit_then_close_keeps_its_code(self):
        # The exit codes for sys.exit() still hold when close() runs in a
        # finally block while the SystemExit propagates.
        for code, expected in [("3", 3), ('"fatal: no camera"', 1), ("0", 0), ("None", 0)]:
            with self.subTest(code=code):
                self.write_script(
                    START,
                    PARTIAL_OUTPUT,
                    """\
                    try:
                        sys.exit(%s)
                    finally:
                        app.close()
                    """
                    % code,
                    AFTER_CLOSE,
                )
                result = self.launch()
                self.assertReported(result, expected)
                self.assertClosedLikeKit(result)

    def test_close_after_normal_finish_succeeds(self):
        endings = {
            "close()": "app.close()\n",
            "close() with arguments": "app.close(wait_for_replicator=False)\n",
            "close() after an error was handled": """\
                try:
                    raise ValueError("camera not found")
                except ValueError:
                    print("recovered")
                app.close()
                """,
            "close() in finally after a normal finish": """\
                try:
                    pass
                finally:
                    app.close()
                """,
        }
        for name, ending in endings.items():
            with self.subTest(name):
                self.write_script(START, PARTIAL_OUTPUT, ending, AFTER_CLOSE)
                direct = self.run_directly()
                self.assertEqual(direct.returncode, 0, direct.stderr)
                expected_events = self.kit_events()

                self.reset()
                result = self.launch()
                self.assertReported(result, 0)
                # The script's behaviour is unchanged: close() gets the same
                # arguments and still ends the process.
                self.assertEqual(self.kit_events(), expected_events)
                self.assertClosedLikeKit(result)
                self.assertEqual(len(self.output_files()), 5)

    def test_close_patched_before_script(self):
        # When the script's first line runs, the launcher has imported
        # isaacsim, without starting Kit, and patched close() on the class
        # that both import forms give.
        self.write_script(
            """\
            import json, os, sys
            seen = {
                "isaacsim imported": "isaacsim" in sys.modules,
                "Kit started": os.path.exists(os.environ["FAKE_KIT_EVENTS"]),
            }
            import fake_kit
            from isaacsim import SimulationApp as package_form
            from isaacsim.simulation_app import SimulationApp as module_form
            seen["same class"] = package_form is module_form
            seen["close patched"] = package_form.close is not fake_kit.SimulationApp.close
            seen["on the class"] = "close" in vars(package_form)
            with open(sys.argv[0] + ".seen", "w") as f:
                json.dump(seen, f)
            """,
            START,
            "app.close()\n",
        )
        result = self.launch()
        self.assertReported(result, 0)
        self.assertEqual(
            self.recorded(".seen"),
            {
                "isaacsim imported": True,
                "Kit started": False,
                "same class": True,
                "close patched": True,
                "on the class": True,
            },
        )

    def test_reloaded_class_is_not_patched_and_fails(self):
        # Known limit: reloading the module that defines SimulationApp creates
        # a new class, which the launcher did not patch. Its close() sends no
        # report, so the run fails with "no completion report", never passes.
        self.write_script(
            """\
            import importlib, sys
            import isaacsim

            importlib.reload(sys.modules[isaacsim.SimulationApp.__module__])
            from %s import SimulationApp

            assert SimulationApp is not isaacsim.SimulationApp, "the reload did not create a new class"
            app = SimulationApp({"headless": True})
            app.close()
            """
            % self.DEFINING_MODULE
        )
        direct = self.run_directly()
        self.assertEqual(direct.returncode, 0, direct.stderr)

        self.reset()
        result = self.launch()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(NO_REPORT, result.stderr)
        self.assertEqual(self.kit_event_names(), ["start", "close"], result.stderr)

    def test_no_report_fails(self):
        with open(os.path.join(self.root, "other.py"), "w") as f:
            f.write("print('another program')\n")
        endings = {
            "os._exit(0)": ("os._exit(0)\n", 1),
            "os._exit(7)": ("os._exit(7)\n", 7),
            "os.execv into another program": (
                "os.execv(sys.executable, [sys.executable, os.path.join(os.path.dirname(sys.argv[0]), 'other.py')])\n",
                1,
            ),
            "Kit exits on its own": (
                """\
                import threading, time
                threading.Thread(target=os._exit, args=(0,)).start()
                time.sleep(60)
                """,
                1,
            ),
        }
        for name, (ending, expected) in endings.items():
            with self.subTest(name):
                self.write_script(START, PARTIAL_OUTPUT, ending)
                result = self.launch()
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn(NO_REPORT, result.stderr)


class PackageLayoutCloseTest(CloseTest):
    """The same tests, with isaacsim.simulation_app a regular subpackage that defines SimulationApp."""

    PYTHONPATH = PACKAGE_LAYOUT
    DEFINING_MODULE = "isaacsim.simulation_app"
    PLACEHOLDER = False


class WithoutIsaacSimTest(KitTestCase):
    """If `import isaacsim` fails, the script runs without the close() patch.

    How the script returns or raises is still reported, and the launcher
    adds nothing to the script's output.
    """

    ENDINGS = {
        "returns": ("print('done')\n", 0),
        "raises": ("raise RuntimeError('deliberate crash')\n", 1),
        "sys.exit(3)": ("import sys; sys.exit(3)\n", 3),
    }

    def isaacsim_on_path(self, name, init_source):
        """A folder with an isaacsim package whose __init__.py is init_source."""
        folder = os.path.join(self.root, name)
        os.makedirs(os.path.join(folder, "isaacsim"))
        with open(os.path.join(folder, "isaacsim", "__init__.py"), "w") as f:
            f.write(init_source)
        return folder

    def test_runs_unpatched_when_import_isaacsim_fails(self):
        cases = {
            "isaacsim not installed": FAKE_KIT,
            "import isaacsim raises": self.isaacsim_on_path(
                "broken", "raise RuntimeError('isaacsim: no GPU driver found')\n"
            ),
            "isaacsim has no SimulationApp": self.isaacsim_on_path("empty", '"""Not Isaac Sim."""\n'),
        }
        for case, pythonpath in cases.items():
            self.PYTHONPATH = pythonpath
            for ending, (source, status) in self.ENDINGS.items():
                with self.subTest(case=case, ending=ending):
                    self.write_script(source)
                    result = self.launch()
                    self.assertReported(result, status)
                    if status == 0:
                        self.assertEqual(result.stderr, "", "the launcher printed something")


# The image's sample, which the example wrapper names once.
IMAGE_SAMPLE = "/isaac-sim/standalone_examples/replicator/scene_based_sdg/scene_based_sdg.py"

# Stub of NVIDIA's sample: takes --config and --headless, records how it was
# run, writes 5 frames next to its config, then crashes or closes as the
# config's `mode` says.
STUB_SAMPLE = """\
import json, os, sys
from isaacsim import SimulationApp

config = sys.argv[sys.argv.index("--config") + 1]
with open(config) as f:
    mode = f.read().split(":", 1)[1].strip()
app = SimulationApp({"headless": "--headless" in sys.argv})
here = os.path.dirname(config)
with open(os.path.join(here, "sample.ran"), "w") as f:
    json.dump({"name": __name__, "file": __file__, "argv": sys.argv, "path0": sys.path[0]}, f)
out = os.path.join(here, "out")
os.makedirs(out, exist_ok=True)
for frame in range(5):
    with open(os.path.join(out, "rgb_%04d.png" % frame), "w") as f:
        f.write("frame %d" % frame)
if mode == "crash":
    raise RuntimeError("stub sample crashed at frame 5 of 10")
app.close()
"""


class ExampleWrapperTest(KitTestCase):
    """The example wrapper runs NVIDIA's sample in its own process.

    The launcher's completion report comes from the script's process. A
    wrapper that handed off to the sample with os.execv would replace that
    process, and a crashed sample would exit 0.
    These tests run a copy of the wrapper, as the script, whose sample path
    names a stub sample instead of the image's.
    """

    def setUp(self):
        super().setUp()
        self.sample = os.path.join(self.root, "isaac-sim", "standalone_examples", "scene_based_sdg.py")
        os.makedirs(os.path.dirname(self.sample))
        with open(self.sample, "w") as f:
            f.write(STUB_SAMPLE)

        # The wrapper names the image's sample path once; the copy names the stub.
        with open(WRAPPER) as f:
            source = f.read()
        self.assertEqual(source.count(IMAGE_SAMPLE), 1, "the wrapper must name %s exactly once" % IMAGE_SAMPLE)
        self.script = os.path.join(self.root, "run_scene_based_sdg.py")
        with open(self.script, "w") as f:
            f.write(source.replace(IMAGE_SAMPLE, self.sample))

        self.config = os.path.join(self.root, "scene_based_sdg.yaml")
        self.args = ["--config", self.config, "--headless"]
        self.ran = os.path.join(self.root, "sample.ran")

    def write_config(self, mode):
        with open(self.config, "w") as f:
            f.write("mode: %s\n" % mode)

    def sample_saw(self):
        self.assertTrue(os.path.exists(self.ran), "the wrapper did not run the stub sample")
        with open(self.ran) as f:
            return json.load(f)

    # Precondition: the stub sample's crash is hidden like Kit hides it. If
    # this fails, the stub is broken, not the wrapper.
    def test_precondition_stub_sample_crash_exits_zero(self):
        self.write_config("crash")
        result = self.run_python([self.sample, *self.args])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stub sample crashed", result.stderr)
        self.assertEqual(len(self.output_files()), 5)

    def test_sample_crash_fails_through_wrapper(self):
        self.write_config("crash")
        result = self.launch(args=self.args)
        self.sample_saw()
        # The crash itself is reported, not lost with the process.
        self.assertReported(result, 1)
        self.assertEqual(len(self.output_files()), 5, "precondition: the output is not empty")

    def test_sample_finish_succeeds_through_wrapper(self):
        self.write_config("ok")
        result = self.launch(args=self.args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.sample_saw(),
            {
                "name": "__main__",
                "file": self.sample,
                "argv": [self.sample, *self.args],
                "path0": os.path.dirname(self.sample),
            },
        )
        self.assertEqual(len(self.output_files()), 5)


if __name__ == "__main__":
    unittest.main()
