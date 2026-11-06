#!/usr/bin/env python3
"""Run the Isaac Sim image's scene_based_sdg sample with the given arguments.

Usage: run_scene_based_sdg.py --config CONFIG.yaml [--headless]

The sample ships in the image and must be run by its absolute path. A missing
--config file makes the sample fall back to its default config without failing,
so this checks the file exists first.
"""

import argparse
import os
import runpy
import sys

SAMPLE = "/isaac-sim/standalone_examples/replicator/scene_based_sdg/scene_based_sdg.py"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    options, _ = parser.parse_known_args()

    if not os.path.isfile(SAMPLE):
        sys.exit("scene_based_sdg sample not found at %s; is this the image in isaac_sim.pin?" % SAMPLE)
    if not os.path.isfile(options.config):
        sys.exit("config %s does not exist" % options.config)

    # Run the sample in this process, as `python SAMPLE ARGS...` would: the
    # launcher's completion report comes from this process, so the sample must
    # not replace it or run in another one. run_path sets sys.argv[0] to
    # SAMPLE; the sample's exceptions propagate.
    if not sys.flags.safe_path:
        sys.path[0] = os.path.dirname(os.path.realpath(SAMPLE))
    runpy.run_path(SAMPLE, run_name="__main__")


if __name__ == "__main__":
    main()
