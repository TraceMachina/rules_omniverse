#!/usr/bin/env python3
"""Run the Isaac Sim image's scene_based_sdg sample with the given arguments.

Usage: run_scene_based_sdg.py --config CONFIG.yaml [--seed N] [--frames N]
           [--output_dir DIR] [--headless]

The sample ships in the image and must be run by its absolute path. A missing
--config file makes the sample fall back to its default config without failing,
so this checks the file exists first.

The sample hard-codes both of its seeds and takes its frame count and output
folder only from its config. --seed runs its source with the two seed lines
changed, and --frames and --output_dir give it a modified copy of the config.
It does not see these three flags, and without them it runs unchanged.
"""

import argparse
import os
import runpy
import sys
import tempfile
import types

SAMPLE = "/isaac-sim/standalone_examples/replicator/scene_based_sdg/scene_based_sdg.py"
SAMPLE_SEED = 42
SEED_LINES = ("rep.set_global_seed(%d)", "rng = np.random.default_rng(%d)")


def seeded_source(seed: int) -> str:
    """Returns the sample's source with both of its seeds set to seed."""
    with open(SAMPLE) as f:
        lines = f.read().split("\n")
    for template in SEED_LINES:
        original = template % SAMPLE_SEED
        found = [i for i, line in enumerate(lines) if line.strip() == original]
        if len(found) != 1:
            sys.exit(
                "expected the line %r once in %s, found it %d times; is this the image in isaac_sim.pin?"
                % (original, SAMPLE, len(found))
            )
        lines[found[0]] = lines[found[0]].replace(original, template % seed)
    return "\n".join(lines)


def config_with_flags(options: argparse.Namespace) -> str:
    """Returns the path of a config with --frames and --output_dir applied."""
    if options.frames is None and options.output_dir is None:
        return options.config

    # Only runs that use these flags need yaml.
    import yaml

    with open(options.config) as f:
        config = yaml.safe_load(f) or {}
    if options.frames is not None:
        config["num_frames"] = options.frames
    if options.output_dir is not None:
        config.setdefault("backend_params", {})["output_dir"] = options.output_dir
    # The sample ignores a config whose name does not end in .json or .yaml.
    # The file goes away with the container.
    handle, path = tempfile.mkstemp(suffix=".yaml")
    with os.fdopen(handle, "w") as f:
        yaml.safe_dump(config, f)
    return path


def run_source(source: str) -> None:
    """Runs source as the sample, the way run_path runs the sample's file."""
    sys.argv[0] = SAMPLE
    main_module = types.ModuleType("__main__")
    main_module.__file__ = SAMPLE
    sys.modules["__main__"] = main_module
    exec(compile(source, SAMPLE, "exec", dont_inherit=True), main_module.__dict__)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--output_dir")
    options, sample_args = parser.parse_known_args()

    if not os.path.isfile(SAMPLE):
        sys.exit("scene_based_sdg sample not found at %s; is this the image in isaac_sim.pin?" % SAMPLE)
    if not os.path.isfile(options.config):
        sys.exit("config %s does not exist" % options.config)

    # Stops here, before the sample runs, if its seed lines are not as expected.
    source = None if options.seed is None else seeded_source(options.seed)
    if any(value is not None for value in (options.seed, options.frames, options.output_dir)):
        sys.argv[1:] = ["--config", config_with_flags(options)] + sample_args

    # Run the sample in this process, as `python SAMPLE ARGS...` would: the
    # launcher's completion report comes from this process, so the sample must
    # not replace it or run in another one. run_path sets sys.argv[0] to
    # SAMPLE; the sample's exceptions propagate.
    if not sys.flags.safe_path:
        sys.path[0] = os.path.dirname(os.path.realpath(SAMPLE))
    if source is None:
        runpy.run_path(SAMPLE, run_name="__main__")
    else:
        run_source(source)


if __name__ == "__main__":
    main()
