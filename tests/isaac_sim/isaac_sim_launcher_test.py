"""isaac_sim_launcher.py's scene dependency check and exit codes.

The fixture in scene/ is a two-layer
stage (root.usda sublayers props.usda) with one texture (textures/checker.png).
"""

import os
import shutil
import sys
import textwrap
import unittest

from launcher_testing import LauncherTestCase
from pxr import UsdUtils

FIXTURE_DIR = os.path.dirname(os.path.abspath(os.environ["ISAAC_SIM_TEST_SCENE"]))

# User script: records the argv it received, then exits with the code given
# by --exit-code (default 0).
USER_SCRIPT = textwrap.dedent(
    """\
    import json, sys
    with open(sys.argv[0] + ".ran", "w") as f:
        json.dump(sys.argv[1:], f)
    code = 0
    if "--exit-code" in sys.argv:
        code = int(sys.argv[sys.argv.index("--exit-code") + 1])
    sys.exit(code)
    """
)


class LauncherTest(LauncherTestCase):
    def setUp(self):
        super().setUp()
        # A writable copy of the fixture so undeclared files really exist on
        # disk (the launcher must not accept a file just because it is there).
        self.scene_dir = os.path.join(self.root, "scene")
        shutil.copytree(FIXTURE_DIR, self.scene_dir)
        self.scene = os.path.join(self.scene_dir, "root.usda")
        self.props = os.path.join(self.scene_dir, "props.usda")
        self.texture = os.path.join(self.scene_dir, "textures", "checker.png")
        self.write_script(USER_SCRIPT)

    def environ(self):
        env = super().environ()
        # Let the launcher subprocess import pxr from this test's deps.
        env["PYTHONPATH"] = os.pathsep.join(p for p in sys.path if p)
        return env

    def launch(self, scene=None, assets=(), args=()):
        return super().launch(scene, assets, args)

    def write_layer(self, name, body):
        path = os.path.join(self.scene_dir, name)
        with open(path, "w") as f:
            f.write("#usda 1.0\n" + textwrap.dedent(body))
        return path

    def assertUsdReports(self, scene, name):
        # Precondition: usd-core itself reports this dependency, so a launcher
        # built on ComputeAllDependencies can see it.
        layers, assets, unresolved = UsdUtils.ComputeAllDependencies(scene)
        reported = [layer.identifier for layer in layers] + list(assets) + list(unresolved)
        self.assertTrue(any(name in path for path in reported), "usd-core does not report %s: %s" % (name, reported))

    def assertFailedNaming(self, result, *names):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        for name in names:
            self.assertIn(name, result.stderr)
        self.assertFalse(self.script_ran(), "script must not run when a dependency is undeclared")

    # Precondition: proves the fixture and usd-core work, independent of the
    # launcher. If this fails, the test setup is broken, not the launcher.
    def test_fixture_dependencies(self):
        layers, assets, unresolved = UsdUtils.ComputeAllDependencies(self.scene)
        self.assertEqual(
            sorted(os.path.basename(layer.realPath) for layer in layers),
            ["props.usda", "root.usda"],
        )
        self.assertEqual([os.path.basename(a) for a in assets], ["checker.png"])
        self.assertEqual(list(unresolved), [])

    def test_all_declared_runs_script_with_args_unchanged(self):
        args = ["--output_dir", "/tmp/out", "--scene", "x.usd", "--frames", "3"]
        result = self.launch(self.scene, [self.props, self.texture], args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded(), args)

    def test_undeclared_texture_fails_naming_it(self):
        result = self.launch(self.scene, [self.props])
        self.assertFailedNaming(result, "checker.png")

    def test_names_every_undeclared_file(self):
        result = self.launch(self.scene, [])
        self.assertFailedNaming(result, "props.usda", "checker.png")

    def test_missing_local_file_is_undeclared(self):
        scene = self.write_layer(
            "with_missing.usda",
            """\
            (
                subLayers = [@./props.usda@]
            )
            def Xform "Robot" (references = @./missing_robot.usda@)
            {
            }
            """,
        )
        self.assertUsdReports(scene, "missing_robot.usda")
        result = self.launch(scene, [self.props, self.texture])
        self.assertFailedNaming(result, "missing_robot.usda")

    def test_online_reference_only_warns(self):
        scene = self.write_layer(
            "with_online.usda",
            """\
            (
                subLayers = [@./props.usda@]
            )
            def Xform "Robot" (references = @https://example.com/robots/robot.usd@)
            {
            }
            """,
        )
        # usd-core reports it as "https:/example.com/..." (one slash).
        self.assertUsdReports(scene, "example.com/robots/robot.usd")
        result = self.launch(scene, [self.props, self.texture])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("example.com/robots/robot.usd", result.stderr)
        self.assertTrue(self.script_ran())

    def test_no_scene_skips_check(self):
        result = self.launch(args=["--headless"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded(), ["--headless"])

    def test_script_exit_code_passed_through(self):
        result = self.launch(self.scene, [self.props, self.texture], ["--exit-code", "7"])
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertTrue(self.script_ran())


if __name__ == "__main__":
    unittest.main()
