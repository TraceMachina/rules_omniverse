# Isaac Sim scene_based_sdg

This example runs NVIDIA's `scene_based_sdg` Replicator sample, which ships in
the image, as an `isaac_sim_action`. It renders a warehouse scene with random
props into `bazel-bin/examples/isaac_sim/scene_based_sdg_out/`.

| File | Role |
| --- | --- |
| `BUILD.bazel` | The platform, a genrule that writes the sample's config (`num_frames: 10`, output in `scene_based_sdg_out`), and the target, which passes it as `--config {input:scene_based_sdg.yaml}` |
| `isaac_sim.pin` | The image, `nvcr.io/nvidia/isaac-sim:6.2.0.1` pinned by digest; the target's `image` must equal it |
| `run_scene_based_sdg.py` | Runs the sample from the image in the same process |

## Prerequisites

- A Linux x86_64 worker with an NVIDIA GPU that has RT cores, for example an
  L40S. A100 and H100 are not supported.
- NVIDIA driver 595.58.03 or newer.
- Docker with the NVIDIA container toolkit, usable by the user that runs
  actions: `docker run --rm --gpus 1 ubuntu nvidia-smi` must work.
- NGC access: `docker login nvcr.io` (user `$oauthtoken`, password an NGC API
  key), then `docker pull "$(cat examples/isaac_sim/isaac_sim.pin)"` once.

## Worker setup

Without cache mounts, every action downloads assets and compiles shaders
again. Create the cache folders once, owned by uid 1234, the image's user.
Docker would create a missing one owned by root, which that user cannot write.

```bash
sudo mkdir -p /data/isaac-sim/bazel-cache/{main,computecache,kit,hub}
sudo chown -R 1234:1234 /data/isaac-sim/bazel-cache
export OMNI_CONTAINER_CACHE_MOUNTS=/data/isaac-sim/bazel-cache/main:/isaac-sim/.cache,/data/isaac-sim/bazel-cache/computecache:/isaac-sim/.nv/ComputeCache,/data/isaac-sim/bazel-cache/kit:/isaac-sim/kit/cache,/data/isaac-sim/bazel-cache/hub:/var/cache/hub
```

For example, on an L40S the first run fills about 2.1 GB, and later 10-frame
runs take about 70 s instead of 300 s.

With NativeLink, set these in the worker's `local` block.
`additional_environment` passes the mounts to each action, and `query_cmd`
reads `gpu_model` and `worker_runtime` from the machine, so they follow a GPU
or driver change. The scheduler matches both exactly:

```json5
additional_environment: {
  PATH: "from_environment",
  OMNI_CONTAINER_CACHE_MOUNTS: "from_environment",
},
platform_properties: {
  cpu_count: { query_cmd: "nproc" },
  gpu_count: { values: ["1"] },
  gpu_model: { query_cmd: "/bin/sh -c '/usr/bin/nvidia-smi --id=0 --query-gpu=name --format=csv,noheader | /usr/bin/sed s/^NVIDIA.//'" },
  worker_runtime: { query_cmd: "/bin/sh -c 'echo nvidia-driver-$(/usr/bin/nvidia-smi --id=0 --query-gpu=driver_version --format=csv,noheader)'" },
  "container-runtime": { values: ["docker"] },
},
```

On an L40S with driver 595.99.02 this gives `L40S` and
`nvidia-driver-595.99.02`. In NativeLink 1.8.3, `query_cmd`:

- runs without a shell, so a pipe or `$(...)` needs `/bin/sh -c`;
- runs with a cleared environment and no `PATH`, so commands inside
  `/bin/sh -c` need absolute paths;
- turns each line it prints into a value, so it must print exactly one line.

Set `unsatisfiable_action_timeout_s` on the scheduler, above the time the
worker takes to restart. An action no connected worker can run then fails with
`FAILED_PRECONDITION` instead of waiting forever (the default, 0):

```json5
schedulers: [
  {
    name: "MAIN_SCHEDULER",
    simple: {
      unsatisfiable_action_timeout_s: 60,
      supported_platform_properties: {
        cpu_count: "minimum",
        gpu_count: "minimum",
        gpu_model: "exact",
        worker_runtime: "exact",
        "container-runtime": "exact",
      },
    },
  },
],
```

For stores, servers and transport, see [`examples/nativelink/gpu`](../nativelink/gpu/README.md)
and the [NativeLink documentation](https://docs.nativelink.com/).

## Run

In `BUILD.bazel`, set the platform's `gpu_model` and `driver`, and the
target's `gpu_model`, to what
`nvidia-smi --query-gpu=name,driver_version --format=csv,noheader` prints.
Locally, on the worker:

```bash
bazel build \
  --extra_execution_platforms=//examples/isaac_sim:isaac_sim_l40s_linux_x86_64 \
  //examples/isaac_sim:scene_based_sdg
```

Local actions see only their declared environment, so local runs don't use
the worker's cache mounts. With NativeLink, put this in a private rc file.
`--remote_executor` points at the scheduler's execution endpoint and
`--remote_cache` at the CAS endpoint, which may be different ports:

```bash
build:isaac --remote_executor=grpc://SCHEDULER_HOST:50052
build:isaac --remote_cache=grpc://CAS_HOST:50051
build:isaac --remote_local_fallback=false
build:isaac --remote_timeout=600
build:isaac --extra_execution_platforms=//examples/isaac_sim:isaac_sim_l40s_linux_x86_64
```

Then run `bazel --bazelrc=/absolute/path/private-isaac.bazelrc build
--config=isaac //examples/isaac_sim:scene_based_sdg`. From macOS, also add
`build:isaac --cpu=k8 --host_cpu=k8`; without both, the client computes a
different action key than the Linux worker and never gets a cache hit.

## Datasets

`//examples/isaac_sim:scene_based_sdg_dataset` renders the same sample as
three chunks of 10 frames with seeds 42, 43 and 44. Each chunk is its own
cached action, and `scene_based_sdg_dataset_chunk_<i>` builds one alone. Raising
`chunks` renders only the new chunks.

`run_scene_based_sdg.py` accepts `--seed`, `--frames` and `--output_dir`. The
sample has no such flags: the wrapper changes the sample's two hard-coded seed
lines when it runs, and gives the sample a copy of the config with `num_frames`
and `backend_params.output_dir` replaced. It stops if a seed line is not found
exactly once, for example in a different image. Without these flags the sample
runs unchanged.

## Updating the driver

A driver update is a deliberate cache reset. Update the driver on the worker
(its `worker_runtime` follows through `query_cmd`), then `driver` in
`isaac_sim_platform`. The new `worker_runtime` changes every action's key, so
actions run again; until the BUILD file is updated they fail with
`FAILED_PRECONDITION`.

## Troubleshooting

| Error | Meaning and fix |
| --- | --- |
| `ended with no completion report` | The script's process ended without reporting: it exec'd, called `os._exit()`, reloaded the module defining `SimulationApp`, or Kit exited on its own. Run other code in the same process, for example with `runpy.run_path`. |
| `depends on files not declared in scene or assets` | Add the listed files to `assets`. |
| `Failed Precondition: ... no worker can satisfy: 'worker_runtime' requested ...` | No worker offers that label. Set `driver` or `gpu_model` to what the worker reports. |
| `container exited 0 but its output ... is empty` | The script wrote nothing into `{output}`. Check the path, and the log for an error Kit caught. |
| `image must be pinned by digest (contain @sha256:)` | Use `name:tag@sha256:...`; `docker inspect --format '{{index .RepoDigests 0}}' IMAGE` prints it. |
| `{input:NAME} matches no file of script, scene, assets or data` | Declare the file, or fix `NAME`, a basename. |
| `{input:NAME} is ambiguous` | Two declared files have that basename. Rename one. |
| `fchmod ... Operation not permitted` from `bazel clean` or a rebuild | Output ownership cleanup was interrupted, failed or exceeded Bazel's grace period (see [Cancelling local builds](#cancelling-local-builds)). Find the container with `docker ps --filter ancestor=nvcr.io/nvidia/isaac-sim@sha256:72d85e83fe76ac0dbe3cf6e77523c9ee9664db02c2e0fc92be35ee3c16cf3402` (the digest in `isaac_sim.pin`) and stop it with `docker kill <id>`. Then, in the workspace, run `sudo chown -R "$(id -u):$(id -g)" "$(bazel info output_base)"`. |

## Cancelling local builds

`isaac_sim_action` requests `supports-graceful-termination` from Bazel. On
ordinary local cancellation, this lets the runner receive SIGTERM, kill its
Docker container and restore output ownership before exiting. Without this
requirement, Bazel can kill the runner before its cleanup traps run
([issue #13](https://github.com/TraceMachina/rules_omniverse/issues/13)).
If the ID has been written but the container has not started, `docker kill`
cannot stop it; the runner falls back to `docker rm -f` for that same ID.

Cleanup must finish within Bazel's `--local_termination_grace_seconds` period
(15 seconds by default in Bazel 8.4.2). Forced SIGKILL, a host/daemon failure,
or cleanup taking longer can still leave a container or incorrectly owned
output; the recovery above remains available.

The [cancellation regression](../../e2e/cancellation/README.md) exercises actual
Bazel cancellation with fake Docker and, optionally, real CPU containers on
Linux. It verifies four controlled boundaries around creation, startup and
output, followed by a complete rebuild and clean. A create request still in
flight before its ID is available is not covered. These checks do not
constitute a GPU or Isaac Sim verification of the fix.

## Limits

- Errors that Kit catches and only logs are not detected. Neither is an
  exception the script catches and handles, unless it calls `close()` inside
  the `except` block, which counts as a failure.
- The success report is sent before `close()` flushes Replicator's writers,
  so an error Kit only logs during that flush is missed.
- Local cancellation cleanup depends on Bazel allowing graceful termination
  and Docker remaining available. Forced termination and cleanup timeouts
  still require manual recovery; see [Cancelling local builds](#cancelling-local-builds).
- Local runs mount whole source folders read-only, so a script can read
  undeclared files that are not in the cache key.
- The sample loads its scene from NVIDIA's online assets (`network = "host"`).
  Online content and the cache mounts are not in the cache key.
