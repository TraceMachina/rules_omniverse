# Local build cancellation regression

From the repository root on macOS or Linux, with Bazel and Python 3.8+ available:

```sh
python3 e2e/cancellation/run.py
```

This runs the actual `isaac_sim_action` rule and container runner in temporary
Bzlmod workspaces. It cancels a real Bazel build in two ways: SIGINT to the
Bazel client and failure of a sibling action. Fake Docker records daemon state
that survives its client, so this needs no Docker, GPU or NVIDIA SDK.

Both cancellation methods run at four controlled boundaries:

| Phase | Boundary |
| --- | --- |
| `before_create` | Before the adapter calls Docker to create a container |
| `after_create` | A container ID exists, but the container has not started |
| `before_output` | The CPU script has started, but has not written output |
| `after_output` | A nested output directory and partial result exist |

Each case checks that no test container remains and ownership hand-back ran,
then rebuilds and checks for complete output before running `bazel clean`.
A cancelled partial result must not satisfy the rebuild. The original rule
without graceful termination fails; the graceful-termination-only change
also fails `after_create` because `docker kill` refuses a created container.
It is run separately from `bazel test //...` because it starts Bazel itself.

To retain all logs, add `--logs /path/to/log-parent`. To check a separate
checkout, add `--repository /path/to/rules_omniverse`. Downloading the fixture's
Bazel dependencies needs network access unless they are already cached.
Use `--phases after_create --modes interrupt` to select one case.

## Optional: real Docker and Linux file ownership

On a Linux machine with Python, Bazel, and Docker available to a non-root user,
use a Linux filesystem for the checkout and test logs. Pull a Python 3 image,
look up its immutable repository digest, and pass it explicitly:

```sh
docker pull python:3.12-slim-bookworm
docker image inspect python:3.12-slim-bookworm --format '{{json .RepoDigests}}'
python3 e2e/cancellation/run.py --docker-image 'python@sha256:YOUR_DIGEST'
```

This mode forwards calls to the real Docker daemon. The test adapter removes
`--gpus`, replaces the Isaac Sim image and entrypoint with the supplied Python
image and a small script, and runs that script as UID/GID 1234:1234. It verifies
that cancellation returns actual file ownership to the worker's UID/GID and
that the container is stopped. Test containers have a unique label for cleanup
even when testing a broken checkout. On a broken checkout, the harness also
records the result of `bazel clean` before repairing only its own fixture's
output tree for cleanup. The nested `rgb` directory is created by UID 1234,
matching the permission boundary that a top-level file alone would miss.

For `after_create`, the adapter explicitly uses `docker create` followed by
`docker start --attach`, pausing between them. This establishes the runner's
behaviour with a real created container. It does not claim to reproduce every
Docker client's internal startup timing. The other phases use `docker run`.

Verified with Bazel 8.4.2 on macOS arm64 (fake Docker) and Linux arm64 in a
Colima VM (real Docker). This establishes the cancellation and ownership
mechanics; it does not run Isaac Sim, exercise an NVIDIA runtime or test
NativeLink. Real Isaac Sim confirmation still requires authorized access to a
compatible GPU and the pinned NVIDIA image.

Both modes passed all eight cases on the tested machines. Forced SIGKILL,
daemon/host failure, cancellation while a create RPC is in flight before its
ID is available, and cleanup exceeding Bazel's grace period remain outside
this test's guarantee.
