#!/usr/bin/env python3
"""Record daemon state independently of the Docker client's lifetime.

This models the cancellation boundary only: no container or GPU is started.
The state survives a killed client until the runner explicitly calls kill.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import time


def gate(state):
    """Hold an exact startup boundary until cancellation or a normal rebuild."""
    (state / "ready").touch()
    while not (state / "finish").exists():
        time.sleep(0.05)


def real_docker(args, state):
    """CPU-only adapter: retain the real Docker daemon and ownership handling."""
    docker = os.environ["CANCELLATION_REAL_DOCKER"]
    args = [os.environ["CANCELLATION_CPU_IMAGE"] if value == "fixture@sha256:0123" else value for value in args]
    if args[0] in ("kill", "rm"):
        result = subprocess.run([docker] + args, check=False)
        (state / ("kill_called" if args[0] == "kill" else "rm_called")).touch()
        if result.returncode == 0:
            (state / "active").unlink(missing_ok=True)
            (state / "killed").touch()
        return result.returncode
    if "--user" in args:
        result = subprocess.run([docker] + args, check=False)
        if result.returncode == 0:
            (state / "handback").touch()
        return result.returncode

    # The test has no NVIDIA runtime. Replace only GPU selection and the
    # Isaac Sim entrypoint/script; run and kill still reach the real daemon.
    index = args.index("--gpus")
    del args[index:index + 2]
    args[args.index("--entrypoint") + 1] = "/usr/local/bin/python3"
    image_index = args.index(os.environ["CANCELLATION_CPU_IMAGE"])
    args[image_index + 1:] = [str(Path.cwd() / "script.py")]
    args[1:1] = [
        "--user", "1234:1234", "--volume", f"{state}:{state}",
        "--env", f"FIXTURE_STATE={state}",
        "--env", f"FIXTURE_PHASE={os.environ['CANCELLATION_TEST_PHASE']}",
        "--label", f"rules_omniverse.cancellation_test={state}",
    ]
    phase = os.environ["CANCELLATION_TEST_PHASE"]
    if phase == "before_create":
        gate(state)
    if phase == "after_create":
        # Split Docker's create/start lifecycle to hold a real, created but
        # not running container at a reproducible boundary. This is a test
        # adapter, not a claim about the timing of every docker run version.
        created = subprocess.run([docker, "create"] + args[1:], check=True, capture_output=True, text=True)
        (state / "created").touch()
        gate(state)
        os.execv(docker, [docker, "start", "--attach", created.stdout.strip()])
    os.execv(docker, [docker] + args)


def main():
    state = Path(os.environ["CANCELLATION_TEST_STATE"])
    args = sys.argv[1:]
    with (state / "calls.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps(args) + "\n")

    if "CANCELLATION_REAL_DOCKER" in os.environ:
        return real_docker(args, state)

    if args == ["kill", "cancellation-fixture"]:
        (state / "kill_called").touch()
        if not (state / "active").exists():
            print("container is not running", file=sys.stderr)
            return 1
        (state / "active").unlink()
        (state / "created").unlink(missing_ok=True)
        (state / "killed").touch()
        return 0
    if args == ["rm", "-f", "cancellation-fixture"]:
        (state / "active").unlink(missing_ok=True)
        (state / "created").unlink(missing_ok=True)
        (state / "rm_called").touch()
        return 0
    if args[0] != "run":
        raise ValueError(f"unexpected Docker command: {args}")
    if "--user" in args:
        if (state / "active").exists():
            raise ValueError("ownership hand-back started before container stopped")
        (state / "handback").touch()
        return 0

    output = None
    for index, arg in enumerate(args[:-1]):
        if arg == "--env" and args[index + 1].startswith("FIXTURE_OUTPUT="):
            output = Path(args[index + 1].split("=", 1)[1])
    if output is None:
        raise ValueError("missing FIXTURE_OUTPUT")

    phase = os.environ["CANCELLATION_TEST_PHASE"]
    if phase == "before_create":
        gate(state)
    Path(args[args.index("--cidfile") + 1]).write_text("cancellation-fixture")
    (state / "created").touch()
    if phase == "after_create":
        gate(state)
    (state / "active").touch()
    if phase == "before_output":
        gate(state)
    output.mkdir(parents=True, exist_ok=True)
    frames = output / "rgb"
    frames.mkdir(exist_ok=True)
    (frames / "result.txt").write_text("partial\n", encoding="utf-8")
    (state / "ready").touch()
    while (state / "active").exists():
        if (state / "finish").exists():
            (frames / "result.txt").write_text("complete\n", encoding="utf-8")
            (state / "active").unlink()
            (state / "created").unlink(missing_ok=True)
            return 0
        time.sleep(0.05)
    return 137


if __name__ == "__main__":
    sys.exit(main())
