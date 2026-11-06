"""Headless NVIDIA Isaac Sim scripts as declared GPU container actions (see examples/isaac_sim)."""

load("//omniverse:providers.bzl", "OmniGpuActionInfo")
load(
    "//omniverse/private:gpu.bzl",
    "CONTAINER_GPU_EXEC_GROUPS",
    "CONTAINER_GPU_RUNNER_ATTR",
    "EXEC_ROOT_TOKEN",
    "gpu_exec_properties",
    "omni_gpu_platform",
    "run_container_gpu_action",
)

_OCI_CONTAINER_RUNTIME_CONSTRAINT = Label("//omniverse/constraints:oci_container_runtime")
_ISAAC_SIM_ENTRYPOINT = "/isaac-sim/python.sh"
_ISAAC_SIM_ENV = {
    "ACCEPT_EULA": "Y",
    "PRIVACY_CONSENT": "N",
    "PYTHONUNBUFFERED": "1",
}

_INPUT_PLACEHOLDER = "{input:"

def _input_placeholder_names(value):
    names = []
    rest = value
    for _ in range(len(value)):
        start = rest.find(_INPUT_PLACEHOLDER)
        if start < 0:
            break
        end = rest.find("}", start)
        if end < 0:
            break
        names.append(rest[start + len(_INPUT_PLACEHOLDER):end])
        rest = rest[end + 1:]
    return names

def _expand_placeholders(attribute, values, inputs, output):
    # inputs are the files {input:NAME} may name; a file listed twice counts once.
    paths_by_basename = {}
    for file in inputs:
        paths = paths_by_basename.setdefault(file.basename, [])
        if file.path not in paths:
            paths.append(file.path)

    expanded = []
    for value in values:
        result = value
        for name in _input_placeholder_names(value):
            placeholder = _INPUT_PLACEHOLDER + name + "}"
            paths = paths_by_basename.get(name, [])
            if not paths:
                fail("isaac_sim_action %s: %s matches no file of script, scene, assets or data (their basenames: %s)" % (
                    attribute,
                    placeholder,
                    ", ".join(sorted(paths_by_basename.keys())),
                ))
            if len(paths) > 1:
                fail("isaac_sim_action %s: %s is ambiguous; it matches %s" % (attribute, placeholder, ", ".join(paths)))

            # Absolute, like the script path, so it does not depend on the working directory.
            result = result.replace(placeholder, EXEC_ROOT_TOKEN + "/" + paths[0])
        expanded.append(result.replace("{output}", output.path))
    return expanded

def _isaac_sim_action_impl(ctx):
    if "@sha256:" not in ctx.attr.image:
        fail("isaac_sim_action image must be pinned by digest (contain @sha256:), got %r" % ctx.attr.image)
    if ctx.attr.frames_set and ctx.attr.frames < 1:
        fail("isaac_sim_action frames must be a positive integer, got %d" % ctx.attr.frames)

    output = ctx.actions.declare_directory(ctx.label.name + "_out")
    placeholder_inputs = [ctx.file.script] + ctx.files.scene + ctx.files.assets + ctx.files.data

    arguments = [ctx.file._launcher.path]
    if ctx.file.scene:
        arguments.extend(["--scene", ctx.file.scene.path])
    for asset in ctx.files.assets:
        arguments.extend(["--asset", asset.path])
    arguments.append("--")

    # Absolute, because the container's working directory is the execution root, not /isaac-sim.
    arguments.append(EXEC_ROOT_TOKEN + "/" + ctx.file.script.path)
    arguments.extend(_expand_placeholders("arguments", ctx.attr.arguments, placeholder_inputs, output))
    if ctx.attr.frames_set:
        arguments.extend(["--frames", str(ctx.attr.frames)])

    # Values take the same placeholders as arguments.
    names = ctx.attr.container_env.keys()
    values = _expand_placeholders("container_env", ctx.attr.container_env.values(), placeholder_inputs, output)
    container_env = dict(zip(names, values))
    container_env.update(_ISAAC_SIM_ENV)

    inputs = [ctx.file._launcher] + placeholder_inputs

    # Source inputs are symlinks in the execution root; the runner mounts their targets.
    input_flags = []
    for path in {f.path: None for f in inputs}:
        input_flags.extend(["--input", path])

    run_container_gpu_action(
        ctx,
        runner = ctx.attr.runner[DefaultInfo].files_to_run,
        image = ctx.attr.image,
        gpu_count = 1,
        shm_size = ctx.attr.shm_size,
        network = ctx.attr.network,
        entrypoint = _ISAAC_SIM_ENTRYPOINT,
        container_env = container_env,
        forward_worker_env = ctx.attr.forward_worker_env,
        # The image runs as its own non-root user and Kit exits 0 when the script raises.
        runner_flags = [
            "--writable-output",
            output.path,
            "--require-nonempty-output",
            output.path,
        ] + input_flags,
        arguments = arguments,
        inputs = inputs,
        outputs = [output],
        mnemonic = "IsaacSimAction",
        progress_message = ctx.attr.progress_message or "Running Isaac Sim action %{label}",
        execution_requirements = ctx.attr.execution_requirements,
    )

    output_set = depset([output])
    return [
        DefaultInfo(files = output_set),
        OmniGpuActionInfo(
            container_image = ctx.attr.image,
            outputs = output_set,
            tree_outputs = output_set,
        ),
    ]

_isaac_sim_action = rule(
    implementation = _isaac_sim_action_impl,
    attrs = {
        "arguments": attr.string_list(
            doc = "Script arguments. {output} is replaced by the <name>_out directory path, and " +
                  "{input:NAME} by the absolute path of the one file of script, scene, assets or data named NAME.",
        ),
        "assets": attr.label_list(
            allow_files = True,
            doc = "Files the scene may depend on. Each file is passed to the launcher as --asset.",
        ),
        "container_env": attr.string_dict(
            doc = "Extra non-secret environment values for the container, with the same placeholders as arguments. " +
                  "ACCEPT_EULA, PRIVACY_CONSENT and PYTHONUNBUFFERED are always set.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional action inputs, such as script configuration, not passed on the command line.",
        ),
        "execution_requirements": attr.string_dict(
            doc = "Bazel execution requirements; the macro always includes no-sandbox.",
        ),
        "forward_worker_env": attr.string_list(
            doc = "Names of worker-injected variables forwarded without recording their values in the action.",
        ),
        "frames": attr.int(
            doc = "Frame count appended to the script arguments as --frames when frames_set is true.",
        ),
        "frames_set": attr.bool(
            doc = "Whether frames was given.",
        ),
        "image": attr.string(
            mandatory = True,
            doc = "Isaac Sim OCI image, pinned by @sha256: digest.",
        ),
        "network": attr.string(
            default = "host",
            doc = "Container network mode; host lets Isaac Sim reach online assets.",
        ),
        "progress_message": attr.string(
            doc = "Optional action progress message.",
        ),
        "runner": CONTAINER_GPU_RUNNER_ATTR,
        "scene": attr.label(
            allow_single_file = True,
            doc = "USD stage whose local dependencies must all be declared in scene or assets.",
        ),
        "script": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Isaac Sim Python script run with the image's python.sh.",
        ),
        "shm_size": attr.string(
            default = "64g",
            doc = "Container shared-memory allocation.",
        ),
        "_launcher": attr.label(
            allow_single_file = True,
            default = Label("//omniverse/private:isaac_sim_launcher.py"),
        ),
    },
    doc = "Runs a headless Isaac Sim script in a pinned Isaac Sim image and captures its output directory.",
    exec_groups = CONTAINER_GPU_EXEC_GROUPS,
)

def isaac_sim_action(
        name,
        image,
        script,
        arguments = [],
        data = [],
        scene = None,
        assets = [],
        frames = None,
        gpu_model = "",
        exec_properties = None,
        execution_requirements = {},
        **kwargs):
    """Runs a headless Isaac Sim script as a cacheable GPU container action.

    The script writes into the <name>_out directory, the target's only output.

    Args:
      name: Target name.
      image: Isaac Sim OCI image pinned by digest, such as nvcr.io/nvidia/isaac-sim@sha256:....
      script: Isaac Sim Python script, for example a Replicator data generation script.
      arguments: Script arguments; {output} is replaced by the output directory path, and {input:NAME}
        by the absolute path of the one file of script, scene, assets or data whose basename is NAME.
        A NAME that matches no file, or more than one, fails analysis.
      data: Extra inputs, such as the script's configuration file.
      scene: Optional USD stage checked by the launcher before the script runs.
      assets: Files the scene depends on; any local dependency missing from scene or assets fails the action.
      frames: Optional positive frame count, appended as --frames <N>.
      gpu_model: Optional scheduler model string, such as H200 or L40S.
      exec_properties: Additional Bazel execution properties.
      execution_requirements: Additional Bazel execution requirements, such as no-local. no-sandbox
        is always set, because sandboxed inputs are symlinks the container cannot follow.
      **kwargs: Remaining attributes, such as tags, network or shm_size.
    """
    requirements = dict(execution_requirements)
    requirements["no-sandbox"] = "1"
    _isaac_sim_action(
        name = name,
        assets = assets,
        data = data,
        exec_properties = gpu_exec_properties(exec_properties, 1, gpu_model),
        execution_requirements = requirements,
        frames = frames if frames != None else 0,
        frames_set = frames != None,
        image = image,
        scene = scene,
        script = script,
        arguments = arguments,
        **kwargs
    )

def _isaac_sim_invalid_target_impl(ctx):
    fail(ctx.attr.message)

_isaac_sim_invalid_target = rule(
    implementation = _isaac_sim_invalid_target_impl,
    attrs = {
        "message": attr.string(mandatory = True),
    },
    doc = "Fails analysis with message; stands in for a target declared with invalid arguments.",
)

def isaac_sim_platform(
        name,
        gpu_model,
        driver,
        gpu_count = 1,
        constraint_values = None,
        exec_properties = None,
        **kwargs):
    """Declares a GPU execution platform for Isaac Sim containers.

    Adds the oci_container_runtime constraint and the container-runtime and
    worker_runtime exec properties on top of omni_gpu_platform.

    Args:
      name: Target name.
      gpu_model: Scheduler model string, such as H200 or L40S.
      driver: NVIDIA driver version on the worker; sets worker_runtime to nvidia-driver-<driver>.
      gpu_count: GPUs on the worker.
      constraint_values: Additional platform constraints; None is the same as [].
      exec_properties: Additional exec properties; may not set worker_runtime or container-runtime.
        None is the same as {}.
      **kwargs: Remaining platform attributes, such as tags or parents.
    """
    constraint_values = constraint_values or []
    exec_properties = exec_properties or {}
    problems = []
    if "worker_runtime" in exec_properties:
        problems.append(
            "do not set worker_runtime in exec_properties; the driver argument sets it " +
            "(driver = %r gives worker_runtime = %r)" % (driver, "nvidia-driver-" + driver),
        )
    if "container-runtime" in exec_properties:
        problems.append(
            "do not set container-runtime in exec_properties; it is always \"docker\" " +
            "(only docker is supported for now)",
        )
    if problems:
        _isaac_sim_invalid_target(
            name = name,
            message = "isaac_sim_platform %s: %s" % (name, "; ".join(problems)),
            tags = kwargs.get("tags"),
            testonly = kwargs.get("testonly"),
            visibility = kwargs.get("visibility"),
        )
        return

    constraints = [native.package_relative_label(value) for value in constraint_values]
    if _OCI_CONTAINER_RUNTIME_CONSTRAINT not in constraints:
        constraints.append(_OCI_CONTAINER_RUNTIME_CONSTRAINT)

    properties = dict(exec_properties)
    properties["container-runtime"] = "docker"
    properties["worker_runtime"] = "nvidia-driver-" + driver

    omni_gpu_platform(
        name = name,
        constraint_values = constraints,
        exec_properties = properties,
        gpu_count = gpu_count,
        gpu_model = gpu_model,
        **kwargs
    )
