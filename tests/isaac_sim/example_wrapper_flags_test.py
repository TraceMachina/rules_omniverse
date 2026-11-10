"""The example wrapper applies --seed, --frames and --output_dir to NVIDIA's sample.

The sample in the image hard-codes both of its seeds and reads its frame count
and output folder only from its config, which it opens only if the path ends in
.json or .yaml. The stub sample here does the same, with the same two seed lines
as scene_based_sdg.py in Isaac Sim 6.2.0.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

IMAGE_SAMPLE = "/isaac-sim/standalone_examples/replicator/scene_based_sdg/scene_based_sdg.py"
WRAPPER = os.path.abspath(os.environ["EXAMPLE_WRAPPER"])

REP_SEED_LINE = "rep.set_global_seed(42)\n"
NUMPY_SEED_LINE = "rng = np.random.default_rng(42)\n"

STUB_SAMPLE = """\
import argparse, json, os, sys
import yaml
import scene_based_sdg_utils

config = {"num_frames": 4, "backend_params": {"output_dir": "_out_scene_based_sdg"}}

parser = argparse.ArgumentParser()
parser.add_argument("--config", required=False)
parser.add_argument("--headless", action="store_true")
args, unknown = parser.parse_known_args()

if args.config and os.path.isfile(args.config):
    with open(args.config) as f:
        if args.config.endswith(".json"):
            config.update(json.load(f))
        elif args.config.endswith(".yaml"):
            config.update(yaml.safe_load(f))

seeds = {}


class rep:
    @staticmethod
    def set_global_seed(seed):
        seeds["rep"] = seed


class np:
    class random:
        @staticmethod
        def default_rng(seed):
            seeds["numpy"] = seed


%s
with open(@RECORD@, "w") as f:
    json.dump(
        {
            "argv": sys.argv,
            "backend_params": config["backend_params"],
            "num_frames": config["num_frames"],
            "seeds": seeds,
        },
        f,
    )
"""


class ExampleWrapperFlagsTest(unittest.TestCase):
    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR")))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.sample = self.root + IMAGE_SAMPLE
        os.makedirs(os.path.dirname(self.sample))
        open(os.path.join(os.path.dirname(self.sample), "scene_based_sdg_utils.py"), "w").close()
        self.record = os.path.join(self.root, "sample.ran")
        self.write_sample(REP_SEED_LINE, NUMPY_SEED_LINE)

        # The wrapper names the image's sample path once; the copy names the stub.
        with open(WRAPPER) as f:
            source = f.read()
        self.script = os.path.join(self.root, "run_scene_based_sdg.py")
        with open(self.script, "w") as f:
            f.write(source.replace(IMAGE_SAMPLE, self.sample))

        self.config = os.path.join(self.root, "scene_based_sdg.yaml")
        self.config_output = os.path.join(self.root, "config_out")
        with open(self.config, "w") as f:
            yaml.safe_dump({"num_frames": 6, "backend_params": {"output_dir": self.config_output, "overwrite": True}}, f)
        with open(self.config, "rb") as f:
            self.config_bytes = f.read()

    def write_sample(self, *seed_lines):
        with open(self.sample, "w") as f:
            f.write((STUB_SAMPLE % "".join(seed_lines)).replace("@RECORD@", repr(self.record)))

    def run_wrapper(self, *flags):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        # rules_python sets PYTHONSAFEPATH for tests; the image does not.
        env.pop("PYTHONSAFEPATH", None)
        env["PYTHONPATH"] = os.path.dirname(os.path.dirname(yaml.__file__))
        result = subprocess.run(
            [sys.executable, self.script, "--config", self.config, "--headless", *flags],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
        )
        with open(self.config, "rb") as f:
            self.assertEqual(f.read(), self.config_bytes, "the config file was modified")
        return result

    def sample_saw(self, *flags):
        result = self.run_wrapper(*flags)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.record) as f:
            return json.load(f)

    def test_seed_sets_both_of_the_samples_seeds(self):
        # 0 is a real seed, and must not read as "no seed given".
        for seed in (0, 7):
            with self.subTest(seed=seed):
                self.assertEqual(self.sample_saw("--seed", str(seed))["seeds"], {"rep": seed, "numpy": seed})

    def test_frames_sets_the_samples_frame_count(self):
        self.assertEqual(self.sample_saw("--frames", "9")["num_frames"], 9)

    def test_output_dir_sets_the_samples_output_folder_only(self):
        chunk_output = os.path.join(self.root, "chunk_out")
        self.assertEqual(
            self.sample_saw("--output_dir", chunk_output)["backend_params"],
            {"output_dir": chunk_output, "overwrite": True},
        )

    def test_the_sample_does_not_see_the_wrappers_flags(self):
        chunk_output = os.path.join(self.root, "chunk_out")
        argv = self.sample_saw("--seed", "7", "--frames", "9", "--output_dir", chunk_output)["argv"]
        self.assertEqual(argv[1], "--config")
        self.assertEqual(argv[3:], ["--headless"])

    def test_without_flags_the_sample_behaves_as_today(self):
        self.assertEqual(
            self.sample_saw(),
            {
                "argv": [self.sample, "--config", self.config, "--headless"],
                "backend_params": {"output_dir": self.config_output, "overwrite": True},
                "num_frames": 6,
                "seeds": {"rep": 42, "numpy": 42},
            },
        )

    def test_seed_stops_when_a_seed_line_is_not_found_exactly_once(self):
        cases = {
            "missing": (NUMPY_SEED_LINE,),
            "twice": (REP_SEED_LINE, REP_SEED_LINE, NUMPY_SEED_LINE),
        }
        for name, seed_lines in cases.items():
            with self.subTest(name):
                self.write_sample(*seed_lines)
                result = self.run_wrapper("--seed", "7")
                self.assertNotEqual(result.returncode, 0, "a changed sample was run with its own seeds")
                self.assertFalse(os.path.exists(self.record), "the sample ran")


if __name__ == "__main__":
    unittest.main()
