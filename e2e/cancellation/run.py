#!/usr/bin/env python3
"""Cancel real Bazel actions with fake Docker; needs Bazel and Python, no GPU."""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


PHASES = ("before_create", "after_create", "before_output", "after_output")
MODES = ("interrupt", "sibling_failure")


def run_case(root, repository, bazel, mode, docker_image, phase):
    case = root / f"{mode}-{phase}"
    workspace = case / "workspace"
    state = case / "state"
    fake_bin = case / "bin"
    for directory in (workspace, state, fake_bin):
        directory.mkdir(parents=True)
    if docker_image:
        state.chmod(0o777)
    (workspace / ".bazelversion").write_text(
        (repository / ".bazelversion").read_text(encoding="utf-8"), encoding="utf-8"
    )
    # Use the same interpreter as the harness, even with Bazel's strict PATH.
    fake = fake_bin / "docker"
    source = Path(__file__).with_name("fake_docker.py").read_text(encoding="utf-8")
    fake.write_text(f"#!{sys.executable}\n" + source.split("\n", 1)[1], encoding="utf-8")
    fake.chmod(0o755)
    runner = workspace / "runner.sh"
    docker_environment = ""
    if docker_image:
        docker_environment = (
            f"export CANCELLATION_REAL_DOCKER={shlex.quote(shutil.which('docker'))}\n"
            f"export CANCELLATION_CPU_IMAGE={shlex.quote(docker_image)}\n"
        )
    runner.write_text(
        "#!/usr/bin/env bash\n"
        f"export PATH={shlex.quote(str(fake_bin))}:\"$PATH\"\n"
        f"export CANCELLATION_TEST_STATE={shlex.quote(str(state))}\n"
        f"export CANCELLATION_TEST_PHASE={shlex.quote(phase)}\n"
        + docker_environment
        + f"exec bash {shlex.quote(str(repository / 'omniverse/private/container_gpu_runner.sh'))} \"$@\"\n",
        encoding="utf-8",
    )
    runner.chmod(0o755)
    shutil.copyfile(Path(__file__).with_name("cpu_script.py"), workspace / "script.py")
    (workspace / "MODULE.bazel").write_text(
        'module(name = "cancellation_fixture")\n'
        'bazel_dep(name = "rules_omniverse", version = "0.3.0")\n'
        'bazel_dep(name = "platforms", version = "1.0.0")\n'
        f'local_path_override(module_name = "rules_omniverse", path = {json.dumps(str(repository))})\n'
        'register_execution_platforms("//:fake_gpu")\n',
        encoding="utf-8",
    )
    fail_command = f"while [ ! -f {shlex.quote(str(state / 'fail_now'))} ]; do sleep 0.05; done; exit 1"
    (workspace / "BUILD.bazel").write_text(
        'load("@rules_omniverse//omniverse:defs.bzl", "isaac_sim_action", "omni_gpu_platform", "omni_worker_script")\n'
        'omni_gpu_platform(name = "fake_gpu", parents = ["@platforms//host"], constraint_values = ["@rules_omniverse//omniverse/constraints:oci_container_runtime"], gpu_model = "FAKE_GPU")\n'
        'omni_worker_script(name = "runner", src = "runner.sh")\n'
        'isaac_sim_action(name = "cancel_me", image = "fixture@sha256:0123", script = "script.py", runner = ":runner", container_env = {"FIXTURE_OUTPUT": "__RULES_OMNIVERSE_EXEC_ROOT__/{output}"})\n'
        f'genrule(name = "fail", outs = ["never.txt"], cmd = {json.dumps(fail_command)}, tags = ["no-sandbox", "local"])\n',
        encoding="utf-8",
    )
    startup = [bazel, f"--output_base={case / 'output'}", "--ignore_all_rc_files"]
    build = startup + [
        "build", "--enable_bzlmod", "--jobs=4", "--local_resources=cpu=4",
        "--remote_cache=", "--remote_executor=", "//:cancel_me",
    ]
    command = build + (["//:fail"] if mode == "sibling_failure" else [])
    process = None
    try:
        with (case / "cancel.log").open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                command, cwd=workspace, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            deadline = time.monotonic() + 120
            while not (state / "ready").exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("action did not become ready")
                time.sleep(0.05)
            if docker_image and phase == "after_output":
                # A real Linux bind mount must expose the image user's UID,
                # not a macOS file-sharing translation of ownership.
                result_file = next((case / "output/execroot/_main/bazel-out").glob("*/bin/cancel_me_out/rgb/result.txt"))
                if (result_file.stat().st_uid, result_file.stat().st_gid) != (1234, 1234):
                    raise AssertionError("fixture did not create output as UID/GID 1234:1234")
                print(
                    f"Linux Docker: output before cancellation UID/GID {result_file.stat().st_uid}:{result_file.stat().st_gid}",
                    flush=True,
                )
            if mode == "interrupt":
                process.send_signal(signal.SIGINT)
            else:
                # Let the sibling fail only after the ownership precondition
                # has been observed, avoiding a race with fast cleanup.
                (state / "fail_now").touch()
            process.wait(timeout=30)

        result = {
            "case": mode,
            "phase": phase,
            "build_exit": process.returncode,
            "container_stopped": not (state / "active").exists(),
            "kill_called": (state / "kill_called").exists(),
            "container_removed": not (state / "created").exists(),
            "ownership_handback_called": (state / "handback").exists(),
        }
        if docker_image:
            if phase == "after_output":
                result["output_uid_after_cancellation"] = result_file.stat().st_uid
                result["output_gid_after_cancellation"] = result_file.stat().st_gid
            docker = shutil.which("docker")
            # Check all states, including a created container that never ran.
            # Auto-removal can finish just after docker kill returns.
            deadline = time.monotonic() + 5
            while True:
                remaining = subprocess.check_output(
                    [docker, "ps", "-aq", "--filter", f"label=rules_omniverse.cancellation_test={state}"],
                    text=True, timeout=10,
                ).split()
                if not remaining or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            result["containers_remaining"] = len(remaining)
            result["container_removed"] = not remaining
            result["container_stopped"] = not any(
                subprocess.check_output([docker, "inspect", "--format", "{{.State.Running}}", cid], text=True).strip() == "true"
                for cid in remaining
            )
        print(json.dumps(result, sort_keys=True), flush=True)
        expected_exit = 8 if mode == "interrupt" else 1
        expected_kill = phase != "before_create"
        if process.returncode != expected_exit or result["kill_called"] != expected_kill or not all(
            result[key] for key in ("container_stopped", "container_removed", "ownership_handback_called")
        ):
            if docker_image:
                with (case / "failed-clean.log").open("w", encoding="utf-8") as log:
                    clean = subprocess.run(
                        startup + ["clean"], cwd=workspace, stdout=log,
                        stderr=subprocess.STDOUT, check=False, timeout=30,
                    )
                print(f"Clean after failed cancellation cleanup: exit {clean.returncode}", flush=True)
            raise AssertionError("cancelled action skipped cleanup")

        if docker_image and phase == "after_output":
            if result_file.stat().st_uid != os.getuid() or result_file.stat().st_gid != os.getgid():
                raise AssertionError("cancelled output was not returned to the worker UID/GID")
            print(f"PASS Linux Docker: output UID/GID 1234:1234 -> {os.getuid()}:{os.getgid()}, container stopped", flush=True)

        # A cancelled partial result must not count as a completed action.
        (state / "finish").touch()
        with (case / "rebuild.log").open("w", encoding="utf-8") as log:
            subprocess.run(build, cwd=workspace, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        result_file = workspace / "bazel-bin/cancel_me_out/rgb/result.txt"
        if result_file.read_text(encoding="utf-8") != "complete\n":
            raise AssertionError("rebuild reused partial output")
        with (case / "clean.log").open("w", encoding="utf-8") as log:
            subprocess.run(startup + ["clean"], cwd=workspace, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
        print(f"PASS {mode}/{phase}: cleanup, complete rebuild, and bazel clean", flush=True)
    except Exception:
        for log in sorted(case.glob("*.log")):
            print(f"--- {log.name} ---\n{log.read_text(encoding='utf-8')}", file=sys.stderr)
        raise
    finally:
        if docker_image:
            # A failing baseline can leave a real daemon-owned container.
            # Remove only containers labelled with this unique case directory.
            docker = shutil.which("docker")
            containers = subprocess.check_output(
                [docker, "ps", "-aq", "--filter", f"label=rules_omniverse.cancellation_test={state}"],
                text=True, timeout=15,
            ).split()
            if containers:
                subprocess.run([docker, "rm", "-f"] + containers, check=True, timeout=20)
            # Repair only this fixture's tree after recording a broken
            # baseline, so even a negative run can remove its temporary files.
            for output in (case / "output/execroot/_main/bazel-out").glob("*/bin/cancel_me_out"):
                if any(path.lstat().st_uid != os.getuid() for path in output.rglob("*")):
                    subprocess.run(
                        [docker, "run", "--rm", "--user", "0:0", "--network", "none",
                         "--volume", f"{output}:/output", "--entrypoint", "chown", docker_image,
                         "-R", "-h", f"{os.getuid()}:{os.getgid()}", "/output"],
                        check=True, timeout=20,
                    )
        # Release any fake client left behind by a failing reproduction.
        (state / "active").unlink(missing_ok=True)
        (state / "finish").touch()
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        subprocess.run(
            startup + ["shutdown"], cwd=workspace,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--logs", type=Path, help="Keep logs in a new directory below this path")
    parser.add_argument("--docker-image", help="Linux only: use a real Python 3 image pinned by @sha256:, with a CPU adapter")
    parser.add_argument("--phases", nargs="+", choices=PHASES, default=PHASES)
    parser.add_argument("--modes", nargs="+", choices=MODES, default=MODES)
    args = parser.parse_args()
    bazel = shutil.which("bazel")
    if bazel is None:
        parser.error("bazel is not on PATH")
    if args.docker_image and (
        sys.platform != "linux" or os.getuid() == 0
        or not shutil.which("docker") or "@sha256:" not in args.docker_image
    ):
        parser.error("--docker-image requires a non-root Linux user, Docker, and a Python image pinned by @sha256:")
    if args.logs:
        args.logs.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="cancellation-", dir=args.logs.resolve()))
        print(f"Logs: {root}", flush=True)
        for mode in args.modes:
            for phase in args.phases:
                run_case(root, args.repository.resolve(), bazel, mode, args.docker_image, phase)
    else:
        with tempfile.TemporaryDirectory(prefix="rules-omniverse-cancellation-") as temporary:
            for mode in args.modes:
                for phase in args.phases:
                    run_case(Path(temporary), args.repository.resolve(), bazel, mode, args.docker_image, phase)


if __name__ == "__main__":
    main()
