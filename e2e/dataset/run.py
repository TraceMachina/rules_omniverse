#!/usr/bin/env python3
"""isaac_sim_dataset as seen by a module that loads rules_omniverse through bzlmod.

From the repository root, with bazelisk and no Docker or GPU; nothing is rendered:

    python3 e2e/dataset/run.py

It is run separately from `bazel test //...` because it starts Bazel itself,
and because raising chunks can only be compared by editing a BUILD file between
two analyses. It works on a copy of e2e/bzlmod with this checkout as
rules_omniverse: e2e/bzlmod itself uses the released rules_omniverse unless
overridden, so a BUILD file there that loads the macro would break a plain
`bazel test` for as long as the release does not have it.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PACKAGE = "//dataset_consumer"
DATASET = PACKAGE + ":ds"
EXAMPLE = "@rules_omniverse//examples/isaac_sim:scene_based_sdg_dataset"
ARGUMENTS = '["--output_dir", "{output}", "--headless"]'


def dataset(name="ds", chunks=3, frames_per_chunk=5, base_seed=100, arguments=ARGUMENTS, extra=""):
    return """
isaac_sim_dataset(
    name = "%s",
    arguments = %s,
    base_seed = %d,
    chunks = %d,
    data = ["config.yaml"],
    frames_per_chunk = %d,
    gpu_model = "E2E_GPU",
    image = "nvcr.io/nvidia/isaac-sim@sha256:4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c",
    script = "generate.py",
    %s
)
""" % (name, arguments, base_seed, chunks, frames_per_chunk, extra)


def chunk(index):
    return "%s_chunk_%d" % (DATASET, index)


def flag(arguments, name):
    return [arguments[i + 1] for i in range(len(arguments) - 1) if arguments[i] == name]


class DatasetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.mkdtemp(prefix="rules_omniverse_dataset.")
        cls.workspace = os.path.join(cls.scratch, "workspace")
        cls.bazelisk = ["bazelisk", "--output_base=" + os.path.join(cls.scratch, "output_base")]
        shutil.copytree(
            os.path.join(ROOT, "e2e", "bzlmod"),
            cls.workspace,
            ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock"),
        )
        # USE_BAZEL_VERSION, for the compatibility runs, takes precedence over this file.
        shutil.copy(os.path.join(ROOT, ".bazelversion"), cls.workspace)
        with open(os.path.join(cls.workspace, ".bazelrc"), "a") as f:
            f.write("common --override_module=rules_omniverse=%s\n" % ROOT)
        cls.package = os.path.join(cls.workspace, "dataset_consumer")
        os.makedirs(cls.package)
        for name in ("generate.py", "config.yaml"):
            open(os.path.join(cls.package, name), "w").close()

    @classmethod
    def tearDownClass(cls):
        subprocess.run(cls.bazelisk + ["shutdown"], cwd=cls.workspace, capture_output=True)
        # Bazel leaves read-only files in its output base.
        subprocess.run(["chmod", "-R", "u+w", cls.scratch])
        shutil.rmtree(cls.scratch, ignore_errors=True)

    def write_package(self, *blocks):
        with open(os.path.join(self.package, "BUILD.bazel"), "w") as f:
            f.write('load("@rules_omniverse//omniverse:defs.bzl", "isaac_sim_dataset")\n')
            f.write("".join(blocks))

    def run_bazel(self, *args):
        return subprocess.run(self.bazelisk + list(args), cwd=self.workspace, capture_output=True, text=True)

    def bazel(self, *args):
        result = self.run_bazel(*args)
        self.assertEqual(result.returncode, 0, "bazel %s failed:\n%s" % (" ".join(args), result.stderr[-3000:]))
        return result.stdout

    def actions(self, label):
        """Maps each target under label to what its one IsaacSimAction does."""
        query = 'mnemonic("IsaacSimAction", deps(%s))' % label
        graph = json.loads(self.bazel("aquery", "--output=jsonproto", query))
        labels = {t["id"]: t["label"] for t in graph.get("targets", [])}
        fragments = {f["id"]: f for f in graph.get("pathFragments", [])}
        depsets = {d["id"]: d for d in graph.get("depSetOfFiles", [])}

        def path(fragment_id):
            fragment = fragments[fragment_id]
            parent = fragment.get("parentId")
            return path(parent) + "/" + fragment["label"] if parent else fragment["label"]

        artifacts = {a["id"]: path(a["pathFragmentId"]) for a in graph.get("artifacts", [])}

        def files(depset_ids):
            found = set()
            for depset_id in depset_ids:
                found.update(artifacts[i] for i in depsets[depset_id].get("directArtifactIds", []))
                found.update(files(depsets[depset_id].get("transitiveDepSetIds", [])))
            return found

        return {
            labels[action["targetId"]]: {
                "key": action["actionKey"],
                "arguments": action["arguments"],
                "inputs": sorted(files(action.get("inputDepSetIds", []))),
                "outputs": [artifacts[i] for i in action["outputIds"]],
                "environment": action.get("environmentVariables", []),
                "execution_info": action.get("executionInfo", []),
                "platform": action.get("executionPlatform"),
            }
            for action in graph.get("actions", [])
        }

    def dataset_actions(self, **settings):
        self.write_package(dataset(**settings))
        return self.actions(DATASET)

    def assert_rejected(self, target, *messages):
        result = self.run_bazel("build", "--nobuild", "%s:%s" % (PACKAGE, target))
        self.assertNotEqual(result.returncode, 0, "%s was accepted" % target)
        for message in messages:
            self.assertIn(message, result.stderr)

    def test_one_block_declares_every_chunk_with_its_seed_and_frames(self):
        actions = self.dataset_actions()
        self.assertEqual(sorted(actions), [chunk(0), chunk(1), chunk(2)])
        for index in range(3):
            with self.subTest(chunk=index):
                action = actions[chunk(index)]
                self.assertEqual(flag(action["arguments"], "--seed"), [str(100 + index)])
                self.assertEqual(flag(action["arguments"], "--frames"), ["5"])
                self.assertEqual(flag(action["arguments"], "--output_dir"), action["outputs"])
                self.assertIn("--headless", action["arguments"])
                self.assertTrue(any(i.endswith("/config.yaml") for i in action["inputs"]), action["inputs"])

        built = self.bazel("cquery", "--output=files", DATASET).split()
        self.assertEqual(sorted(built), sorted(a["outputs"][0] for a in actions.values()))

    def test_raising_chunks_leaves_the_existing_chunks_as_they_were(self):
        before = self.dataset_actions(chunks=2)
        after = self.dataset_actions(chunks=4)
        self.assertEqual(sorted(after), [chunk(i) for i in range(4)])
        for index in range(2):
            self.assertEqual(before[chunk(index)], after[chunk(index)])

    def test_changing_frames_or_base_seed_changes_every_chunk(self):
        # base_seed 0 is valid, so the baseline also checks it is accepted.
        before = self.dataset_actions(base_seed=0)
        for change in ({"frames_per_chunk": 6}, {"base_seed": 1}):
            with self.subTest(change=change):
                after = self.dataset_actions(**{"base_seed": 0, **change})
                for index in range(3):
                    self.assertNotEqual(before[chunk(index)]["key"], after[chunk(index)]["key"])

    def test_chunks_differ_only_in_their_seed_and_output(self):
        def comparable(action):
            arguments = list(action["arguments"])
            arguments[arguments.index("--seed") + 1] = "SEED"
            text = json.dumps({**action, "key": "", "arguments": arguments}, sort_keys=True)
            return text.replace("ds_chunk_1", "ds_chunk_0")

        actions = self.dataset_actions(chunks=2)
        self.assertEqual(comparable(actions[chunk(0)]), comparable(actions[chunk(1)]))

    def test_invalid_settings_fail_only_when_built_and_are_reported_together(self):
        self.write_package(dataset(), dataset(name="bad", chunks=0, frames_per_chunk=0, base_seed=-1))
        self.bazel("build", "--nobuild", DATASET)
        self.assert_rejected(
            "bad",
            "isaac_sim_dataset bad:",
            "chunks must be a positive integer, got 0",
            "frames_per_chunk must be a positive integer, got 0",
            "base_seed must be zero or a positive integer, got -1",
        )

    def test_the_macro_owns_frames_and_the_seed(self):
        self.write_package(
            dataset(name="frames", extra="frames = 3,"),
            dataset(name="seed", arguments='["--headless", "--seed", "7"]'),
            dataset(name="seed_equals", arguments='["--seed=7"]'),
        )
        self.assert_rejected("frames", "do not set frames; frames_per_chunk sets it (got frames = 3)")
        self.assert_rejected("seed", 'do not set --seed in arguments; base_seed sets it (got "--seed")')
        self.assert_rejected("seed_equals", 'do not set --seed in arguments; base_seed sets it (got "--seed=7")')

    def test_an_outside_user_can_declare_and_analyse_a_dataset(self):
        self.write_package(dataset())
        self.bazel("build", "--nobuild", DATASET)

    def test_the_example_dataset_gives_each_chunk_the_wrappers_flags(self):
        # The label's spelling of an external repository depends on the Bazel version.
        actions = {label.split(":")[-1]: action for label, action in self.actions(EXAMPLE).items()}
        self.assertEqual(sorted(actions), ["scene_based_sdg_dataset_chunk_%d" % i for i in range(3)])
        with open(os.path.join(ROOT, "examples", "isaac_sim", "isaac_sim.pin")) as f:
            pin = f.read().strip()
        for index in range(3):
            with self.subTest(chunk=index):
                action = actions["scene_based_sdg_dataset_chunk_%d" % index]
                self.assertEqual(flag(action["arguments"], "--seed"), [str(42 + index)])
                self.assertEqual(flag(action["arguments"], "--frames"), ["10"])
                self.assertEqual(flag(action["arguments"], "--output_dir"), action["outputs"])
                self.assertEqual(flag(action["arguments"], "--image"), [pin])
                self.assertTrue(any(a.endswith("/run_scene_based_sdg.py") for a in action["arguments"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
