# A small trajectory check through NativeLink

This example checks three robot waypoints against one circular obstacle and
writes a stable JSON report. It uses the existing `omni_usd_validate` rule.
The Python script reads a few custom fields from this USDA fixture; it checks
waypoints only and does not parse arbitrary USD or simulate physics.

## Run locally

From the repository root, with Bazel 8+ and Python 3 available:

```bash
bazel test //examples/nativelink/trajectory/...
python3 examples/nativelink/trajectory/run_cache_demo.py
```

The local runner builds the original scene twice, changes a declared waypoint,
and restores it. Its Bazel output shows local cache reuse. It disables remote
execution and remote caching. The unchanged second build can reuse its current
output. Restoring an older input may execute again locally; the NativeLink run
below separately checks reuse of the earlier result from its action cache.

## Run through NativeLink

Start a Docker engine first (`colima start` works on the tested Mac). Build and
start the local worker from the repository root:

```bash
docker build -t rules-omniverse-trajectory-worker:local \
  -f examples/nativelink/trajectory/Dockerfile \
  examples/nativelink/trajectory
docker run --rm --name rules-omniverse-trajectory-nativelink \
  -v "$PWD/examples/nativelink/trajectory/nativelink.json5:/config:ro" \
  -p 127.0.0.1:50051:50051 -p 127.0.0.1:50061:50061 \
  rules-omniverse-trajectory-worker:local
```

Wait for `Worker registered with scheduler`. In a second terminal at the
repository root:

```bash
python3 examples/nativelink/trajectory/run_nativelink_demo.py
```

Each phase uses a fresh Bazel output base, so a local Bazel cache cannot explain
the remote cache hits. Dependency downloads may reuse Bazel’s shared repository
cache; action results stay isolated. The runner disables local fallback and checks the report
and the action log's runner, cache flag, target, mnemonic, and exit code.

| Input | Expected evidence | Report |
| --- | --- | --- |
| Original | Remote execution | Valid |
| Unchanged | NativeLink cache hit | Valid |
| Changed waypoint | Remote execution | Collision at index 1 |
| Restored | NativeLink cache hit | Valid |

Stop the container after the run:

```bash
docker stop rules-omniverse-trajectory-nativelink
```

## Things to take care of

- Start a fresh container before each remote demo. The first phase expects an
  empty action cache. The container stores its cache internally and `--rm`
  discards it when stopped.
- Run one demo at a time. Both runners temporarily edit `scenario.usda` and
  restore it in `finally`; do not edit the scene or interrupt with a forced kill
  during a run. A forced kill can prevent cleanup.
- The minimal NativeLink image lacks Python. The Dockerfile supplies Python 3
  and makes it available through `/usr/bin/python3`. Keep the worker runtime
  consistent; Python is supplied by the worker, not declared as an action input.
  This example does not establish cache correctness across different runtimes.
- Keep the ports bound to loopback. This configuration has no TLS or
  authentication. The runner ignores Bazel rc files and does not configure
  credentials for a hosted service.
- The verified setup is a CPU worker in a local container on Apple Silicon,
  using Bazel 8.4.2 and NativeLink 1.6.5. Separate hosts, other architectures,
  GPUs, NVIDIA SDKs, ROS, and Isaac Sim remain unverified. No speedup has been
  benchmarked. Image tags are versioned, but not pinned to immutable digests.

Whole-path collision checks, OpenUSD parsing, and real physics would make this
more useful for robotics. They are left for later so this first example can be
run without an NVIDIA SDK, GPU, or robotics stack. Maintainer feedback should
decide which extension comes next.

The NativeLink setup follows its [official guide](https://docs.nativelink.com/remote-execution/first-remote-action).
`nativelink.json5` is copied from the [v1.6.5 local test configuration](https://github.com/TraceMachina/nativelink/blob/v1.6.5/nativelink-config/examples/local_rbe_self_test.json5).
Its original license is included as `NATIVELINK_LICENSE`; the surrounding
repository has its own root `LICENSE`. The checker and demo runners were added
for this example; the existing Bazel rules were reused.
