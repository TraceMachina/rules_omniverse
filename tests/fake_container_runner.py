#!/usr/bin/env python3
"""Container-runner test double that executes a Python payload on the host."""

import argparse
import os
import shutil
import subprocess
import sys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime")
    parser.add_argument("--image", required=True)
    parser.add_argument("--gpu-count", type=int, required=True)
    parser.add_argument("--shm-size")
    parser.add_argument("--network")
    parser.add_argument("--entrypoint")
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--forward-env", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    environment = dict(os.environ)
    exec_root_token = "__RULES_OMNIVERSE_EXEC_ROOT__"
    for value in args.env:
        value = value.replace(exec_root_token, os.getcwd())
        name, separator, content = value.partition("=")
        if not separator:
            parser.error("--env values must use NAME=VALUE")
        environment[name] = content
    for name in args.forward_env:
        if name not in environment:
            parser.error(f"forwarded variable is missing: {name}")

    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("a fake container command is required")
    command = [value.replace(exec_root_token, os.getcwd()) for value in command]
    if command[0].endswith(".py"):
        python = sys.executable or shutil.which("python3")
        if not python:
            parser.error("python3 is required to run a Python payload")
        command.insert(0, python)
    subprocess.run(command, check=True, env=environment)


if __name__ == "__main__":
    main()
