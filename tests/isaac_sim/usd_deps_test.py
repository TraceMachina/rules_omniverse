"""tools/usd_deps.py: what it lists, where it writes, and when it fails.

Each test builds a temporary workspace holding one package, pkg/, runs
//tools:usd_deps on it with this test's usd-core, and reads what it wrote. The
contract is docs/usd_deps.md.

The launcher is deliberately not in this test's data, so the tool has to find
everything it needs in the runfiles of //tools:usd_deps.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

from pxr import UsdUtils

USD_DEPS = os.path.abspath(os.environ["USD_DEPS"])

ROBOT_URL = "https://example.com/robots/robot.usd"
WALL_URL = "https://example.com/textures/wall.png"
# USD reports a URL with one slash after the scheme.
ROBOT_REPORTED = "example.com/robots/robot.usd"
WALL_REPORTED = "example.com/textures/wall.png"


def _prim_name(path):
    return "P_" + re.sub(r"\W", "_", path)


def reference(path):
    return 'def Xform "%s" (references = @%s@)\n{\n}\n' % (_prim_name(path), path)


def payload(path):
    return 'def Xform "%s" (payload = @%s@)\n{\n}\n' % (_prim_name(path), path)


def texture(path):
    return 'def Shader "%s"\n{\n    asset inputs:file = @%s@\n}\n' % (_prim_name(path), path)


def sublayers(*paths):
    return "(\n    subLayers = [%s]\n)\n" % ", ".join("@%s@" % path for path in paths)


def layer(*parts):
    return "#usda 1.0\n" + "".join(parts)


def tool_output(result):
    """What the tool printed, without USD's own diagnostics, which name the same files."""
    lines = (result.stdout + result.stderr).splitlines()
    return "\n".join(line for line in lines if not line.startswith("Warning: in "))


class UsdDepsTestCase(unittest.TestCase):
    def setUp(self):
        # realpath, so paths have one spelling on macOS too.
        self.workspace = os.path.realpath(tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR")))
        self.addCleanup(shutil.rmtree, self.workspace, ignore_errors=True)
        self.package = os.path.join(self.workspace, "pkg")
        self.write("BUILD.bazel", "")
        self.scene = self.path("stage.usda")

    def path(self, relative):
        return os.path.normpath(os.path.join(self.package, relative))

    def write(self, relative, content=""):
        path = self.path(relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        return path

    def write_layers(self, *relatives):
        return [self.write(relative, layer()) for relative in relatives]

    def read(self, relative):
        with open(self.path(relative)) as f:
            return f.read()

    def environ(self):
        env = dict(os.environ)
        # Let the tool import pxr from this test's deps. `bazel run` sets
        # neither PYTHONSAFEPATH nor BUILD_* for a test, so a test sets BUILD_* itself.
        env["PYTHONPATH"] = os.pathsep.join(p for p in sys.path if p)
        env.pop("PYTHONSAFEPATH", None)
        return env

    def run_tool(self, *args, cwd=None, env=None):
        return subprocess.run(
            [sys.executable, USD_DEPS, *args],
            capture_output=True,
            text=True,
            cwd=cwd or self.workspace,
            env=env or self.environ(),
            timeout=60,
        )

    def tree(self):
        """Every file in the workspace, with its bytes and modification time."""
        found = {}
        for directory, _, names in os.walk(self.workspace):
            for name in names:
                path = os.path.join(directory, name)
                with open(path, "rb") as f:
                    found[path] = (f.read(), os.stat(path).st_mtime_ns)
        return found

    def age(self, relative):
        """Backdates a file, so a rewrite shows up in its modification time."""
        os.utime(self.path(relative), ns=(1_000_000_000, 1_000_000_000))

    def generated(self, relative="stage_deps.bzl", name="STAGE_DEPS"):
        """The list a generated file defines; it must define nothing else."""
        namespace = {}
        exec(self.read(relative), namespace)
        self.assertEqual([key for key in namespace if not key.startswith("__")], [name])
        return namespace[name]

    def assertListed(self, expected, *args):
        result = self.run_tool(*(args or [self.scene]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated(), expected)

    def assertFailedNaming(self, result, *names):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        output = tool_output(result)
        for name in names:
            self.assertIn(name, output)


class WhatIsListedTest(UsdDepsTestCase):
    # Precondition: proves usd-core reports each kind of dependency, and where,
    # independent of the tool. If this fails, the setup is broken, not the tool.
    def test_precondition_usd_reports_each_kind(self):
        self.write_layers("sub.usda", "ref.usda", "pay.usda")
        self.write("wood.png")
        self.write("stage.usda", layer(
            sublayers("./sub.usda"),
            reference("./ref.usda"),
            payload("./pay.usda"),
            texture("./wood.png"),
            reference("./missing.usda"),
            reference(ROBOT_URL),
        ))
        layers, assets, unresolved = UsdUtils.ComputeAllDependencies(self.scene)
        self.assertEqual(
            sorted(os.path.basename(item.realPath) for item in layers),
            ["pay.usda", "ref.usda", "stage.usda", "sub.usda"],
        )
        self.assertEqual([os.path.basename(asset) for asset in assets], ["wood.png"])
        self.assertEqual(sorted(os.path.basename(path) for path in unresolved), ["missing.usda", "robot.usd"])
        self.assertTrue(any(ROBOT_REPORTED in path for path in unresolved), unresolved)

    def test_sublayers(self):
        self.write_layers("base.usda", "overrides.usda")
        self.write("stage.usda", layer(sublayers("./overrides.usda", "./base.usda")))
        self.assertListed(["base.usda", "overrides.usda"])

    def test_references(self):
        self.write_layers("robot.usda")
        self.write("stage.usda", layer(reference("./robot.usda")))
        self.assertListed(["robot.usda"])

    def test_payloads(self):
        self.write_layers("heavy.usda")
        self.write("stage.usda", layer(payload("./heavy.usda")))
        self.assertListed(["heavy.usda"])

    def test_texture_asset_paths(self):
        self.write("textures/wood.png")
        self.write("stage.usda", layer(texture("./textures/wood.png")))
        self.assertListed(["textures/wood.png"])

    def test_nested_relative_paths_are_anchored_at_their_own_layer(self):
        self.write("stage.usda", layer(reference("./refs/robot.usda")))
        self.write("refs/robot.usda", layer(reference("./parts/arm.usda")))
        self.write("refs/parts/arm.usda", layer(sublayers("./overlay.usda"), texture("../../textures/metal.png")))
        self.write("refs/parts/overlay.usda", layer())
        self.write("textures/metal.png")
        self.assertListed(["refs/parts/arm.usda", "refs/parts/overlay.usda", "refs/robot.usda", "textures/metal.png"])

    def test_paths_are_relative_to_the_package_not_the_scene(self):
        scene = self.write("scenes/stage.usda", layer(reference("./props/chair.usda")))
        self.write("scenes/props/chair.usda", layer())
        result = self.run_tool(scene)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated("scenes/stage_deps.bzl"), ["scenes/props/chair.usda"])

    def test_nearest_build_file_decides_the_package(self):
        self.write("scenes/BUILD.bazel")
        scene = self.write("scenes/stage.usda", layer(reference("./props/chair.usda")))
        self.write("scenes/props/chair.usda", layer())
        result = self.run_tool(scene)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated("scenes/stage_deps.bzl"), ["props/chair.usda"])

    def test_plain_build_file_makes_a_package(self):
        os.remove(self.path("BUILD.bazel"))
        self.write("BUILD")
        self.write("wood.png")
        self.write("stage.usda", layer(texture("./wood.png")))
        self.assertListed(["wood.png"])

    def test_scene_without_dependencies_gets_an_empty_list(self):
        self.write("stage.usda", layer())
        self.assertListed([])

    def test_sorted_without_duplicates(self):
        self.write_layers("Zebra.usda", "apple.usda", "middle/a.usda")
        self.write("wood.png")
        self.write("Zebra.usda", layer(texture("./wood.png")))
        self.write("apple.usda", layer(texture("./wood.png")))
        self.write("stage.usda", layer(reference("./middle/a.usda"), reference("./apple.usda"), reference("./Zebra.usda")))
        self.assertListed(["Zebra.usda", "apple.usda", "middle/a.usda", "wood.png"])

    def test_symlink_in_the_package_is_a_file_in_the_package(self):
        shared = os.path.join(self.workspace, "shared", "wall.png")
        os.makedirs(os.path.dirname(shared))
        with open(shared, "w") as f:
            f.write("wall\n")
        os.makedirs(self.path("textures"))
        os.symlink(shared, self.path("textures/link.png"))
        self.write("stage.usda", layer(texture("./textures/link.png")))
        self.assertListed(["textures/link.png"])


class OutputFileTest(UsdDepsTestCase):
    def test_exact_bytes(self):
        self.write("props/chair.usda", layer(texture("../textures/wood.png")))
        self.write("textures/wood.png")
        self.write("stage.usda", layer(reference("./props/chair.usda")))
        self.assertEqual(self.run_tool(self.scene).returncode, 0)
        self.assertEqual(
            self.read("stage_deps.bzl"),
            textwrap.dedent(
                '''\
                """Generated by usd_deps from stage.usda. Do not edit."""

                STAGE_DEPS = [
                    "props/chair.usda",
                    "textures/wood.png",
                ]
                '''
            ),
        )

    def test_exact_bytes_of_an_empty_list(self):
        self.write("stage.usda", layer())
        self.assertEqual(self.run_tool(self.scene).returncode, 0)
        self.assertEqual(
            self.read("stage_deps.bzl"),
            '"""Generated by usd_deps from stage.usda. Do not edit."""\n\nSTAGE_DEPS = []\n',
        )

    def test_writes_only_the_generated_file_and_never_edits_build_files(self):
        self.write("BUILD.bazel", 'exports_files(["stage.usda"])\n')
        self.write("stage.usda", layer())
        before = self.tree()
        self.assertEqual(self.run_tool(self.scene).returncode, 0)
        after = self.tree()
        generated = self.path("stage_deps.bzl")
        self.assertEqual(sorted(set(after) - set(before)), [generated])
        del after[generated]
        self.assertEqual(after, before)

    def test_name_comes_from_the_stem(self):
        for scene, bzl, name in [
            ("factory.v2.usda", "factory.v2_deps.bzl", "FACTORY_V2_DEPS"),
            ("my-scene.usd", "my-scene_deps.bzl", "MY_SCENE_DEPS"),
            ("Stage2.usda", "Stage2_deps.bzl", "STAGE2_DEPS"),
        ]:
            with self.subTest(scene):
                path = self.write(scene, layer())
                result = self.run_tool(path)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.generated(bzl, name), [])

    def test_stem_that_cannot_be_loaded_fails(self):
        for scene in ["1st.usda", "_stage.usda"]:
            with self.subTest(scene):
                path = self.write(scene, layer())
                before = self.tree()
                self.assertFailedNaming(self.run_tool(path), scene)
                self.assertEqual(self.tree(), before)

    def test_each_scene_gets_its_own_file(self):
        self.write_layers("a.usda", "b.usda")
        first = self.write("first.usda", layer(reference("./a.usda")))
        second = self.write("nested/second.usda", layer(reference("../b.usda")))
        result = self.run_tool(first, second)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated("first_deps.bzl", "FIRST_DEPS"), ["a.usda"])
        self.assertEqual(self.generated("nested/second_deps.bzl", "SECOND_DEPS"), ["b.usda"])

    def test_two_scenes_writing_the_same_file_fail(self):
        first = self.write("stage.usd", layer())
        second = self.write("stage.usda", layer())
        before = self.tree()
        self.assertFailedNaming(self.run_tool(first, second), "stage_deps.bzl")
        self.assertEqual(self.tree(), before)


class SceneArgumentTest(UsdDepsTestCase):
    def setUp(self):
        super().setUp()
        self.write("wood.png")
        self.write("stage.usda", layer(texture("./wood.png")))
        self.elsewhere = os.path.join(self.workspace, "elsewhere")
        os.makedirs(self.elsewhere)

    def test_relative_scene_is_found_from_where_bazel_run_started(self):
        env = self.environ()
        env["BUILD_WORKING_DIRECTORY"] = self.package
        result = self.run_tool("stage.usda", cwd=self.elsewhere, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated(), ["wood.png"])
        self.assertEqual(os.listdir(self.elsewhere), [])

    def test_relative_scene_is_found_from_the_current_directory_when_run_directly(self):
        result = self.run_tool("stage.usda", cwd=self.package)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated(), ["wood.png"])

    def test_missing_scene_fails_naming_it(self):
        self.assertFailedNaming(self.run_tool(self.path("nope.usda")), "nope.usda")

    def test_no_scene_is_a_usage_error(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("usage", result.stderr.lower())

    def test_scene_outside_any_package_fails(self):
        os.remove(self.path("BUILD.bazel"))
        env = self.environ()
        env["BUILD_WORKSPACE_DIRECTORY"] = self.workspace
        before = self.tree()
        self.assertFailedNaming(self.run_tool(self.scene, env=env), "stage.usda")
        self.assertEqual(self.tree(), before)


class OnlineReferencesTest(UsdDepsTestCase):
    def setUp(self):
        super().setUp()
        self.write_layers("robot.usda")
        self.write("stage.usda", layer(reference("./robot.usda"), reference(ROBOT_URL), texture(WALL_URL)))

    def assertWarned(self, result, *paths):
        warnings = [line for line in result.stderr.splitlines() if line.startswith("usd_deps: warning:")]
        for path in paths:
            self.assertTrue(any(path in line for line in warnings), "no warning for %s in:\n%s" % (path, result.stderr))

    def test_listed_only_as_warnings(self):
        result = self.run_tool(self.scene)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.generated(), ["robot.usda"])
        self.assertNotIn("example.com", self.read("stage_deps.bzl"))
        self.assertWarned(result, ROBOT_REPORTED, WALL_REPORTED)

    def test_check_still_only_warns(self):
        self.assertEqual(self.run_tool(self.scene).returncode, 0)
        result = self.run_tool("--check", self.scene)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertWarned(result, ROBOT_REPORTED, WALL_REPORTED)


class FailuresTest(UsdDepsTestCase):
    def assertFailedWritingNothing(self, args, *names):
        before = self.tree()
        self.assertFailedNaming(self.run_tool(*args), *names)
        self.assertEqual(self.tree(), before)

    def write_outside(self, relative, content=""):
        path = os.path.join(self.workspace, "outside", relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)

    def test_missing_files_fail_listing_every_one(self):
        self.write("stage.usda", layer(reference("./gone_ref.usda"), reference("./refs/ok.usda"), texture("./gone.png")))
        self.write("refs/ok.usda", layer(sublayers("./gone_nested.usda")))
        self.assertFailedWritingNothing([self.scene], "gone_ref.usda", "gone.png", "gone_nested.usda")

    def test_files_outside_the_package_fail_listing_every_one(self):
        self.write_outside("far.usda", layer())
        self.write_outside("far.png")
        self.write("stage.usda", layer(reference("../outside/far.usda"), texture("../outside/far.png")))
        self.assertFailedWritingNothing([self.scene], "far.usda", "far.png")

    def test_a_file_in_a_subpackage_is_outside(self):
        self.write("sub/BUILD.bazel")
        self.write("sub/deep/chair.usda", layer())
        self.write("stage.usda", layer(reference("./sub/deep/chair.usda")))
        self.assertFailedWritingNothing([self.scene], "chair.usda")

    def test_missing_and_outside_files_are_listed_together(self):
        self.write_outside("far.usda", layer())
        self.write("stage.usda", layer(reference("../outside/far.usda"), reference("./gone.usda")))
        self.assertFailedWritingNothing([self.scene], "far.usda", "gone.usda")

    def test_every_scene_is_reported_and_no_scene_is_written(self):
        good = self.write("good.usda", layer())
        first = self.write("first.usda", layer(reference("./gone_first.usda")))
        second = self.write("second.usda", layer(reference("./gone_second.usda")))
        self.assertFailedWritingNothing([good, first, second], "gone_first.usda", "gone_second.usda")

    def test_failure_leaves_an_existing_file_alone(self):
        self.write("stage_deps.bzl", "previous\n")
        self.write("stage.usda", layer(reference("./gone.usda")))
        self.assertFailedWritingNothing([self.scene], "gone.usda")


class RepeatRunsAndCheckTest(UsdDepsTestCase):
    def setUp(self):
        super().setUp()
        self.write_layers("chair.usda", "table.usda")
        self.write("stage.usda", layer(reference("./chair.usda"), reference("./table.usda")))
        result = self.run_tool(self.scene)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.age("stage_deps.bzl")

    def stale_file(self):
        """A file listing chair.usda and old.usda, where the scene needs chair.usda and table.usda."""
        self.write(
            "stage_deps.bzl",
            '"""Generated by usd_deps from stage.usda. Do not edit."""\n\n'
            'STAGE_DEPS = [\n    "chair.usda",\n    "old.usda",\n]\n',
        )

    def assertCheckFailsWritingNothing(self):
        before = self.tree()
        result = self.run_tool("--check", self.scene)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tree(), before)
        return tool_output(result)

    def test_running_twice_changes_nothing(self):
        before = self.tree()
        result = self.run_tool(self.scene)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tree(), before)

    def test_running_again_after_the_scene_changes_updates_the_file(self):
        self.write("stage.usda", layer(reference("./chair.usda")))
        self.assertEqual(self.run_tool(self.scene).returncode, 0)
        self.assertEqual(self.generated(), ["chair.usda"])

    def test_check_passes_on_fresh_output_and_writes_nothing(self):
        before = self.tree()
        result = self.run_tool("--check", self.scene)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tree(), before)

    def test_check_fails_on_stale_output_listing_the_differences(self):
        self.stale_file()
        output = self.assertCheckFailsWritingNothing()
        self.assertIn("stage_deps.bzl", output)
        self.assertIn("table.usda", output)
        self.assertIn("old.usda", output)
        self.assertNotIn("chair.usda", output)

    def test_check_fails_on_a_missing_file_without_creating_it(self):
        os.remove(self.path("stage_deps.bzl"))
        output = self.assertCheckFailsWritingNothing()
        self.assertIn("stage_deps.bzl", output)

    def test_check_fails_on_a_hand_edit_that_keeps_the_list(self):
        self.write("stage_deps.bzl", self.read("stage_deps.bzl") + "# a note\n")
        output = self.assertCheckFailsWritingNothing()
        self.assertIn("stage_deps.bzl", output)

    def test_check_reports_only_the_stale_scene(self):
        fresh = self.write("fresh.usda", layer())
        self.assertEqual(self.run_tool(fresh).returncode, 0)
        self.stale_file()
        result = self.run_tool("--check", fresh, self.scene)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        output = tool_output(result)
        self.assertIn("stage_deps.bzl", output)
        self.assertNotIn("fresh_deps.bzl", output)

    def test_check_fails_when_a_dependency_is_missing(self):
        self.write("stage.usda", layer(reference("./chair.usda"), reference("./gone.usda")))
        self.assertIn("gone.usda", self.assertCheckFailsWritingNothing())


if __name__ == "__main__":
    unittest.main()
