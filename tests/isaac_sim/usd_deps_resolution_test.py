"""tools/usd_deps.py and the launcher read USD's answer the same way.

A stub pxr.UsdUtils returns a chosen answer, so both programs can be given
cases usd-core does not produce on its own, and the same answer goes to each.
This target does not depend on usd-core, so no other pxr is importable.
"""

import json
import os
import subprocess
import sys
import textwrap
import unittest

from launcher_testing import LauncherTestCase

USD_DEPS = os.path.abspath(os.environ["USD_DEPS"])

# Stub of pxr.UsdUtils. It returns the answer in the file STUB_USD_ANSWER names.
STUB_USD_UTILS = textwrap.dedent(
    """\
    import json, os


    class _Layer:
        def __init__(self, real_path, identifier):
            self.realPath = real_path
            self.identifier = identifier


    def ComputeAllDependencies(scene):
        with open(os.environ["STUB_USD_ANSWER"]) as f:
            answer = json.load(f)
        layers = [_Layer(*pair) for pair in answer["layers"]]
        return layers, answer["assets"], answer["unresolved"]
    """
)


class ResolutionTestCase(LauncherTestCase):
    def setUp(self):
        super().setUp()
        self.package = os.path.join(self.root, "pkg")
        os.makedirs(self.package)
        self.scene = self.make_file("stage.usda")
        self.make_file("BUILD.bazel")
        self.stub = os.path.join(self.root, "stub")
        os.makedirs(os.path.join(self.stub, "pxr"))
        with open(os.path.join(self.stub, "pxr", "__init__.py"), "w") as f:
            f.write("")
        with open(os.path.join(self.stub, "pxr", "UsdUtils.py"), "w") as f:
            f.write(STUB_USD_UTILS)
        self.answer_file = os.path.join(self.root, "answer.json")
        self.write_script("import sys\nopen(sys.argv[0] + '.ran', 'w').close()\n")

    def make_file(self, relative):
        path = os.path.join(self.package, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("fixture\n")
        return path

    def environ(self):
        env = super().environ()
        env["PYTHONPATH"] = self.stub
        env["STUB_USD_ANSWER"] = self.answer_file
        env.pop("PYTHONSAFEPATH", None)
        return env

    def answer(self, layers=(), assets=(), unresolved=()):
        with open(self.answer_file, "w") as f:
            json.dump(
                {
                    "layers": [[self.scene, self.scene], *layers],
                    "assets": list(assets),
                    "unresolved": list(unresolved),
                },
                f,
            )

    def generated(self):
        namespace = {}
        with open(os.path.join(self.package, "stage_deps.bzl")) as f:
            exec(f.read(), namespace)
        return namespace["STAGE_DEPS"]


class SameResolutionTest(ResolutionTestCase):
    def assertBothAccept(self, listed, warned=()):
        """The tool lists exactly listed, and the launcher accepts that list, both warning about warned."""
        tool = self.run_python([USD_DEPS, self.scene])
        self.assertEqual(tool.returncode, 0, tool.stderr)
        self.assertEqual(self.generated(), listed)
        launcher = self.launch(self.scene, [os.path.join(self.package, path) for path in listed], [])
        self.assertEqual(launcher.returncode, 0, launcher.stderr)
        self.assertTrue(self.script_ran())
        for path in warned:
            self.assertIn(path, tool.stderr)
            self.assertIn(path, launcher.stderr)

    def assertBothReject(self, *names):
        tool = self.run_python([USD_DEPS, self.scene])
        self.assertNotEqual(tool.returncode, 0, tool.stderr)
        launcher = self.launch(self.scene, [], [])
        self.assertNotEqual(launcher.returncode, 0, launcher.stderr)
        self.assertFalse(self.script_ran())
        for name in names:
            self.assertIn(name, tool.stderr)
            self.assertIn(name, launcher.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.package, "stage_deps.bzl")))

    def test_every_scheme_counts_as_online(self):
        paths = ["https:/example.com/a.usd", "omniverse:/server/b.usd", "s3:/bucket/c.png", "file:/etc/d.usda"]
        self.answer(unresolved=paths)
        self.assertBothAccept([], warned=paths)

    def test_online_path_among_resolved_assets_is_not_listed(self):
        self.answer(assets=["omniverse:/server/wood.png"])
        self.assertBothAccept([], warned=["omniverse:/server/wood.png"])

    def test_online_layer_is_not_listed(self):
        self.answer(layers=[["", "omniverse:/server/layer.usd"]])
        self.assertBothAccept([], warned=["omniverse:/server/layer.usd"])

    def test_layer_without_a_real_path_uses_its_identifier(self):
        path = self.make_file("anchored.usda")
        self.answer(layers=[["", path]])
        self.assertBothAccept(["anchored.usda"])

    def test_real_path_wins_over_the_identifier(self):
        path = self.make_file("real.usda")
        self.answer(layers=[[path, "not/the/real/path.usda"]])
        self.assertBothAccept(["real.usda"])

    def test_resolved_asset_is_listed(self):
        path = self.make_file("textures/wood.png")
        self.answer(assets=[path])
        self.assertBothAccept(["textures/wood.png"])

    def test_one_letter_scheme_is_a_local_path(self):
        self.answer(unresolved=["C:/textures/wood.png"])
        self.assertBothReject("C:/textures/wood.png")

    def test_unresolved_local_path_fails(self):
        path = os.path.join(self.package, "missing.usda")
        self.answer(unresolved=[path])
        self.assertBothReject(path)


class RunsAsItsOwnProgramTest(ResolutionTestCase):
    """How `bazel run` starts the tool: as a program, with the python3 on PATH."""

    def run_program(self, *args, env):
        return subprocess.run([USD_DEPS, *args], capture_output=True, text=True, env=env, timeout=60)

    def without_pxr(self):
        env = dict(os.environ)
        env.pop("PYTHONPATH", None)
        env.pop("PYTHONSAFEPATH", None)
        return env

    def test_finds_python3_on_path(self):
        # A python3 that is this test's interpreter, so the stub pxr can be imported.
        bin_dir = os.path.join(self.root, "bin")
        os.makedirs(bin_dir)
        shim = os.path.join(bin_dir, "python3")
        with open(shim, "w") as f:
            f.write('#!/bin/sh\nexec "%s" "$@"\n' % os.path.realpath(sys.executable))
        os.chmod(shim, 0o755)
        self.answer()
        env = self.environ()
        env["PATH"] = bin_dir + os.pathsep + env["PATH"]
        result = self.run_program(self.scene, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated(), [])

    def test_help_needs_no_pxr(self):
        result = self.run_program("--help", env=self.without_pxr())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--check", result.stdout)

    def test_without_pxr_says_how_to_get_it(self):
        env = self.without_pxr()
        probe = subprocess.run(["python3", "-c", "import pxr"], capture_output=True, env=env)
        if probe.returncode == 0:
            self.skipTest("the python3 on PATH has pxr")
        result = self.run_program(self.scene, env=env)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("usd-core", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
