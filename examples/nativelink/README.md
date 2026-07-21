# NativeLink terminal timing

NativeLink does not need an Omniverse build-viewer extension. Bazel already
prints elapsed time and its action-process summary in the terminal, including
remote execution and remote-cache hits.

Bazel runs on the client machine where this repository is checked out. The
NVIDIA host runs NativeLink and the GPU SDK environment; it does not need a
Bazel installation. The verified measurement temporarily co-located them to
remove network variability, but the rules and rc file use standard REAPI and do
not require that topology.

Run the declared active capability report against a prepared GPU worker:

```bash
/usr/bin/time -p bazel --bazelrc=/path/to/private-h200.bazelrc \
  build --config=h200 //examples/nativelink/gpu:active_capability_report
```

Record Bazel's `INFO: Elapsed time` and `INFO: ... processes` lines. Then remove
only the local Bazel outputs and repeat the same command against the same
NativeLink cache:

```bash
bazel clean
/usr/bin/time -p bazel --bazelrc=/path/to/private-h200.bazelrc \
  build --config=h200 //examples/nativelink/gpu:active_capability_report
```

The second terminal record should identify remote cache hits and show the
measured replay time. A valid comparison includes the exact target, Bazel
version, rules commit, worker image or environment identity, GPU model, and both
complete timing lines. Do not claim a cold-cache result unless the first build
used a fresh demo cache.

This comparison demonstrates NativeLink execution versus NativeLink cache
replay. It does not claim that NativeLink makes the underlying GPU workload
itself faster than a direct local run; its value is remote GPU
scheduling, shared content/action caching, explicit worker properties, and a
reproducible REAPI boundary.

The reusable rules do not select H200s. GPU model and count are parameters on
`omni_gpu_action`, GPU-enabled USD rules, and `omni_gpu_platform`. The H200
configuration under [`gpu`](gpu/README.md) is one concrete deployment example.
