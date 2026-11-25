# NativeLink H200 execution

This directory is the reference Bazel Remote Execution configuration for the
GPU demos. NativeLink is used because its worker properties can explicitly
match `gpu_count=1` and `gpu_model=H200`, while Bazel continues to communicate
through the standard Remote Execution API.

Run Bazel on the client machine. Run NativeLink and the NVIDIA SDK environment
on the H200 host. Bazel is not a worker prerequisite.

Other REAPI backends may work, but this repository does not claim equivalent
provenance, worker customization, scheduling predictability, cache behavior, or
GPU performance for them.

## Test layers

The repository's `fake_gpu` and `fake_gpu_platform` fixtures run without GPU
hardware. They are deliberately small, hermetic substitutes used to test the
Bazel rule contract: platform constraints, emitted execution properties,
argument expansion, inputs, outputs, and Bzlmod integration. Passing those tests
does not mean that CUDA, an Omniverse library, or NativeLink ran.

Real-GPU validation is a separate layer, and the H200 series is the primary
hardware test bench. The checked-in reference evidence was produced on an H200,
not by the fake fixture. It covers `ovphysx` GPU initialization and simulation,
`ovrtx.Renderer()` initialization, NativeLink 1.6.1 remote execution, H200 worker
matching, output retrieval, and action-cache replay. Hardware-specific results
are recorded in the demo documentation so they are not confused with portable
CI coverage.

The rules are not H200-only. Users select `gpu_count`, optionally select
`gpu_model`, and register a compatible platform for an H200, A100, L40S, or
another suitable NVIDIA GPU. A platform other than the documented H200 bench
should be preflighted with its actual SDK and driver stack before relying on it.

## Preflight

Start with the read-only inventory as a declared remote action. From the local
Bazel checkout, use the private rc that points at the secured NativeLink
endpoint:

```bash
bazel --bazelrc=/absolute/path/private-h200.bazelrc \
  build --config=h200 //examples/nativelink/gpu:capability_report
```

Review
`bazel-bin/examples/nativelink/gpu/h200_capability_report.json`. Only then run
the active remote probe, which initializes `ovphysx`, `ovrtx`, and NVENC:

```bash
bazel --bazelrc=/absolute/path/private-h200.bazelrc \
  build --config=h200 //examples/nativelink/gpu:active_capability_report
```

An `ovrtx` or NVENC failure does not invalidate the H200 for `ovphysx`, USD
Search, reconstruction, or synthetic-data workloads. It gates only the RTX and
raw-frame streaming demos.

On the verified host, `ovphysx` GPU initialization and `ovrtx.Renderer()` both
succeeded. FFmpeg exposed its NVENC codecs, but encoder initialization returned
`unsupported device`; the H200 therefore remains the compute/physics worker,
while an NVENC-capable GPU is required for the reference hardware-encoded
streaming path.

## NativeLink

This configuration is validated against NativeLink 1.6.1. The verified official
image and binary digests are:

```text
ghcr.io/tracemachina/nativelink@sha256:bd4d6f0a48ceea1f8040fc637bff43b630af6cc8eccd60db75b96911680f21cc
binary sha256: f92d7a326ecf294ebd300f4d1e66721207404e753922852aa181e0c88e8fc98e
```

The extracted static binary must report `nativelink 1.6.1` before it serves the
cache or executor. Revalidate the configuration before substituting another
version or image digest.

Set `NL_NVME_ROOT`, start that NativeLink binary with
`nativelink-h200.json5`, copy `h200.bazelrc.example` into a private ignored rc
file, and replace `H200_HOST` there.

The plaintext client listener defaults to `127.0.0.1:50051`. Reach it from the
Bazel client through a private local port forward, or place NativeLink behind an
authenticated TLS proxy and use its secured endpoint. Do not publish the raw
gRPC port to the internet.

The reference worker also sets `use_namespaces` and `use_mount_namespace` to
`false` because it was validated on a dedicated, single-tenant evaluation host.
That configuration executes actions as the NativeLink service account and is
for trusted actions only; it is not a multi-tenant security boundary. A
production deployment must provide suitable worker isolation—such as validated
Linux namespaces, containerized workers, or disposable dedicated machines—in
addition to authenticated transport and least-privilege service credentials.

The worker's `additional_environment` configuration copies `PYTHONPATH`, the
three optional `RULES_OMNIVERSE_USD_*` interpreter/path selectors,
`RULES_OMNIVERSE_BAZEL_VERSION`, and `RULES_OMNIVERSE_EXECUTION_BACKEND` from the
NativeLink service environment into each action. Set required values privately
when launching NativeLink so SDK locations and measured provenance stay
deployment-specific. The public JSON5 contains environment-variable names only.
For the verified run the metadata values were Bazel 8.4.2 and `NativeLink 1.6.1`.

Long GPU actions use deployment-controlled NativeLink limits. The example
defaults `NL_MAX_ACTION_TIMEOUT` to two hours and
`NL_MAX_UPLOAD_TIMEOUT` to thirty minutes. Operators can change both values
without changing `rules_omniverse` or the target definition.

Pass the private rc file as a Bazel startup option; merely creating an arbitrary
`user.bazelrc` file does not make Bazel read it:

```bash
bazel --bazelrc=/absolute/path/private-h200.bazelrc \
  build --config=h200 //examples/nativelink/gpu:active_capability_report
```

The host-tool platform executes against the prepared host environment. The
container platform advertises the generic `container-runtime=docker`
capability; the image reference remains an action parameter. Deployments may
also advertise a `container-image` property when they deliberately pre-provision
only a restricted image set, but the ruleset does not require that policy.

The single reference worker advertises one combined fingerprint for its
`ovphysx`, `ovrtx`, and standalone USD environments. NativeLink 1.6.1
exact-property matching treats a local worker property as one value; deployments
with separate workers can use narrower fingerprints for each runtime. The rules
do not prescribe any of these strings.
Because platform properties participate in the remote action identity, changing
a fingerprint separates cache entries and prevents the scheduler from selecting
a differently prepared worker. A pinned container digest remains a strong
production provenance boundary for deployments that choose it, while tags and
private registry references remain supported.

## One worker per GPU

With `--gpus 1`, Docker picks the GPU itself and always starts at device 0,
so several workers on one multi-GPU host would all run on GPU 0. Instead, start
one NativeLink worker process per GPU, each with its own
`RULES_OMNIVERSE_GPU_DEVICES` and its own work directory. The container runner
then passes `--gpus device=<value>`. The worker injects the variable through
`additional_environment`, so it is not part of the action key: a result built on
GPU 3 is a cache hit on GPU 0.

Run the CAS, action cache and scheduler in one process, for example
`nativelink-h200.json5` with its `workers` list emptied (`workers: []`), so no
unpinned worker takes actions onto GPU 0. Then start
[`nativelink-gpu-worker.json5`](nativelink-gpu-worker.json5) once per GPU. Its
store and work directories are named after the GPU and `NL_WORKER_SLOT`, so
no two processes share them:

```bash
export NL_NVME_ROOT=/mnt/nvme
export NL_GPU_MODEL=L40S
export NL_WORKER_RUNTIME="nvidia-driver-$(nvidia-smi --id=0 --query-gpu=driver_version --format=csv,noheader)"
export OMNI_CONTAINER_CACHE_MOUNTS=...  # Optional; see examples/isaac_sim.
# The CAS, action cache and scheduler: nativelink-h200.json5 with workers: [].
nativelink nativelink-scheduler.json5 &
for gpu in $(nvidia-smi --query-gpu=index --format=csv,noheader); do
  RULES_OMNIVERSE_GPU_DEVICES="$gpu" CUDA_VISIBLE_DEVICES="$gpu" \
    nativelink nativelink-gpu-worker.json5 >"worker-gpu$gpu.log" 2>&1 &
done
```

The variable takes a GPU index or a `GPU-`/`MIG-` UUID as `nvidia-smi -L`
prints it, or a comma-separated list. The list must name exactly as many GPUs as the
action's `gpu_count`; otherwise the action fails with `lists N GPU(s), but the
action requests gpu_count M`. Because the scheduler matches `gpu_count` as a
minimum, a worker that advertises two GPUs can also receive a one-GPU action,
which then fails; give every worker one GPU unless all its actions request more.
Unset or empty, the runner passes `--gpus <gpu_count>` as before. Local Bazel
runs never see the variable, since local actions get only their declared
environment.

`gpu_count` is reserved while an action runs, so each worker runs one GPU action
at a time. When the workload is small, several workers may share one GPU: start
more processes with the same `RULES_OMNIVERSE_GPU_DEVICES` and a different
`NL_WORKER_SLOT`. For example, a headless Isaac Sim action uses about 3.6 GB of
GPU memory, so a 24 GB L4 fits several:

```bash
for gpu in $(nvidia-smi --query-gpu=index --format=csv,noheader); do
  for slot in 0 1 2 3; do
    RULES_OMNIVERSE_GPU_DEVICES="$gpu" CUDA_VISIBLE_DEVICES="$gpu" NL_WORKER_SLOT="$slot" \
      nativelink nativelink-gpu-worker.json5 >"worker-gpu$gpu-$slot.log" 2>&1 &
  done
done
```

Actions that share a GPU share its memory and compute without isolation; measure
the peak with `nvidia-smi` and leave headroom. Concurrent Isaac Sim containers
also share the `OMNI_CONTAINER_CACHE_MOUNTS` directories, which has not been
tested under load.

Isaac Sim camera rendering needs a GPU with RT cores, such as an L4, L40S or
A10G. A100, H100 and H200 have none: they run compute and physics, not Isaac
Sim cameras.

Host-tool actions (`omni_gpu_action` and the USD rules with `gpu = True`) do not
go through the container runner. For them the worker also sets
`CUDA_VISIBLE_DEVICES` to the same GPU, which the worker configuration forwards
the same way. Do not put either variable in a target's `env`: it would enter the
action key and override the worker's choice.

A single NativeLink process can also list several `local` workers, each with
`RULES_OMNIVERSE_GPU_DEVICES: { value: "3" }` instead of `"from_environment"`
and its own `work_directory`. Separate processes keep one GPU's worker restart
from stopping the others. `nativelink-gpu-worker.json5` follows the NativeLink
1.8.3 configuration schema and has not yet been run on a multi-GPU host.
