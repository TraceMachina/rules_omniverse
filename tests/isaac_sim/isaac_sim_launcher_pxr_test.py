"""The launcher finds pxr in the Isaac Sim image's extension cache.

In the image, python.sh runs /isaac-sim/kit/python/bin/python3 and pxr is only
in /isaac-sim/extscache/omni.usd.libs-<version>+<hash>.../, so a plain
`from pxr import UsdUtils` fails there with "No module named 'pxr'". These tests build
a fake image root with that layout: kit/python/bin/python3 is a link to this
test's interpreter, and extscache/omni.usd.libs-* folders hold a stub pxr.
This target does not depend on usd-core, so no other pxr is importable.
"""

import json
import os
import shutil
import sys
import textwrap
import unittest

from launcher_testing import LauncherTestCase

# Stub of pxr.UsdUtils. It reports the scene plus textures/checker.png next to
# it, and records the environment its process started with.
STUB_USD_UTILS = textwrap.dedent(
    """\
    import json, os

    _LIBS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


    def _startup_environ():
        # The loader reads LD_LIBRARY_PATH only when a process starts, so read
        # the environment the process started with where the OS shows it.
        try:
            with open("/proc/self/environ", "rb") as f:
                entries = f.read().split(b"\\0")
        except OSError:
            return dict(os.environ)
        return dict(entry.decode().split("=", 1) for entry in entries if b"=" in entry)


    class _Layer:
        def __init__(self, path):
            self.identifier = path
            self.realPath = path


    def ComputeAllDependencies(scene):
        env = _startup_environ()
        with open(os.path.join(_LIBS, "calls.jsonl"), "a") as f:
            f.write(json.dumps({"PYTHONPATH": env.get("PYTHONPATH"), "LD_LIBRARY_PATH": env.get("LD_LIBRARY_PATH")}) + "\\n")
        texture = os.path.join(os.path.dirname(scene), "textures", "checker.png")
        return [_Layer(scene)], [texture], []
    """
)

# User script: records what it can see of the launcher's pxr search.
USER_SCRIPT = textwrap.dedent(
    """\
    import json, os, sys
    with open(sys.argv[0] + ".ran", "w") as f:
        json.dump(
            {
                "PYTHONPATH": os.environ.get("PYTHONPATH"),
                "LD_LIBRARY_PATH": os.environ.get("LD_LIBRARY_PATH"),
                "environ": dict(os.environ),
                "sys_path": sys.path,
                "pxr_loaded": "pxr" in sys.modules,
            },
            f,
        )
    """
)


class LauncherPxrTest(LauncherTestCase):
    def setUp(self):
        super().setUp()
        self.image = os.path.join(self.root, "isaac-sim")
        self.extscache = os.path.join(self.image, "extscache")
        os.makedirs(self.extscache)
        bin_dir = os.path.join(self.image, "kit", "python", "bin")
        os.makedirs(bin_dir)
        self.python = os.path.join(bin_dir, "python3")
        os.symlink(os.path.realpath(sys.executable), self.python)

        self.scene_dir = os.path.join(self.root, "scene")
        os.makedirs(os.path.join(self.scene_dir, "textures"))
        self.scene = os.path.join(self.scene_dir, "scene.usda")
        self.texture = os.path.join(self.scene_dir, "textures", "checker.png")
        for path in [self.scene, self.texture]:
            with open(path, "w") as f:
                f.write("fixture\n")

        self.write_script(USER_SCRIPT)

    def add_usd_libs(self, name="omni.usd.libs-1.0.3+187cf21b.lx64.r.cp312"):
        libs = os.path.join(self.extscache, name)
        os.makedirs(os.path.join(libs, "pxr"))
        os.makedirs(os.path.join(libs, "bin"))
        os.makedirs(os.path.join(libs, "lib"))
        with open(os.path.join(libs, "pxr", "__init__.py"), "w") as f:
            f.write("")
        with open(os.path.join(libs, "pxr", "UsdUtils.py"), "w") as f:
            f.write(STUB_USD_UTILS)
        return libs

    def environ(self, pythonpath=None, ld_library_path=None):
        env = super().environ()
        env.pop("PYTHONPATH", None)
        env.pop("LD_LIBRARY_PATH", None)
        if pythonpath is not None:
            env["PYTHONPATH"] = pythonpath
        if ld_library_path is not None:
            env["LD_LIBRARY_PATH"] = ld_library_path
        return env

    def launch(self, scene=None, assets=(), env=None):
        return super().launch(scene, assets, [], env, self.python)

    def stub_calls(self, libs):
        path = os.path.join(libs, "calls.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(line) for line in f]

    def assertUsedStub(self, result, libs):
        self.assertEqual(
            len(self.stub_calls(libs)), 1, "the launcher did not use the pxr in %s:\n%s" % (libs, result.stderr)
        )

    def assertFailedNamingSearch(self, result):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(os.path.join(self.extscache, "omni.usd.libs-*"), result.stderr)
        self.assertFalse(self.script_ran(), "script must not run when pxr cannot be found")

    # Precondition: the fake image behaves like the real one. Its interpreter
    # reports the image path as sys.executable, and pxr is not importable
    # without help.
    # If this fails, the test setup is broken, not the launcher.
    def test_precondition_fake_image(self):
        self.add_usd_libs()
        result = self.run_python(["-c", "import sys; print(sys.executable)"], python=self.python)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), self.python)

        result = self.run_python(["-c", "from pxr import UsdUtils"], python=self.python)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No module named 'pxr'", result.stderr)

    def test_undeclared_texture_found_with_image_pxr(self):
        libs = self.add_usd_libs()
        result = self.launch(self.scene)
        self.assertUsedStub(result, libs)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("checker.png", result.stderr)
        self.assertFalse(self.script_ran(), "script must not run when a dependency is undeclared")

    def test_declared_scene_runs_script_with_unchanged_environment(self):
        for pythonpath, ld_library_path in [(None, None), ("/user/python", "/user/lib")]:
            with self.subTest(pythonpath=pythonpath, ld_library_path=ld_library_path):
                shutil.rmtree(self.extscache)
                os.makedirs(self.extscache)
                self.reset()
                libs = self.add_usd_libs()
                result = self.launch(self.scene, [self.texture], self.environ(pythonpath, ld_library_path))
                self.assertUsedStub(result, libs)
                self.assertEqual(result.returncode, 0, result.stderr)

                # The check's process starts with LIBS on both paths, before
                # what the launcher was given.
                [call] = self.stub_calls(libs)
                self.assertEqual(call["PYTHONPATH"].split(os.pathsep), [libs] + [p for p in [pythonpath] if p])
                self.assertEqual(
                    call["LD_LIBRARY_PATH"].split(os.pathsep),
                    [os.path.join(libs, "bin"), os.path.join(libs, "lib")] + [p for p in [ld_library_path] if p],
                )

                # The script's process starts with exactly what the launcher
                # was given.
                saw = self.recorded()
                self.assertEqual(saw["PYTHONPATH"], pythonpath)
                self.assertEqual(saw["LD_LIBRARY_PATH"], ld_library_path)
                self.assertFalse(saw["pxr_loaded"], "pxr must not be imported into the script's process")
                for name, value in saw["environ"].items():
                    self.assertNotIn("omni.usd.libs", value, "%s leaked into the script's environment" % name)
                for entry in saw["sys_path"]:
                    self.assertNotIn("omni.usd.libs", entry, "leaked into the script's sys.path")

    def test_no_usd_libs_folder_fails_naming_search(self):
        result = self.launch(self.scene, [self.texture])
        self.assertFailedNamingSearch(result)

    def test_several_usd_libs_folders_fail_naming_each(self):
        first = self.add_usd_libs("omni.usd.libs-1.0.3+187cf21b.lx64.r.cp312")
        second = self.add_usd_libs("omni.usd.libs-1.0.4+0a1b2c3d.lx64.r.cp312")
        result = self.launch(self.scene, [self.texture])
        self.assertFailedNamingSearch(result)
        self.assertIn(first, result.stderr)
        self.assertIn(second, result.stderr)
        self.assertEqual(self.stub_calls(first) + self.stub_calls(second), [])

    def test_without_scene_nothing_changes(self):
        for count in [0, 1, 2]:
            with self.subTest(usd_libs_folders=count):
                shutil.rmtree(self.extscache)
                os.makedirs(self.extscache)
                self.reset()
                folders = [self.add_usd_libs("omni.usd.libs-1.0.%d+abc" % i) for i in range(count)]
                result = self.launch(env=self.environ("/user/python", "/user/lib"))
                self.assertEqual(result.returncode, 0, result.stderr)
                saw = self.recorded()
                self.assertEqual(saw["PYTHONPATH"], "/user/python")
                self.assertEqual(saw["LD_LIBRARY_PATH"], "/user/lib")
                for libs in folders:
                    self.assertEqual(self.stub_calls(libs), [])


if __name__ == "__main__":
    unittest.main()
