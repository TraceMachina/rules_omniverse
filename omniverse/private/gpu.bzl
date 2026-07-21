"""Generic actions that require a registered NVIDIA GPU execution platform."""

load("//omniverse:providers.bzl", "OmniGpuActionInfo")

_GPU_EXEC_GROUP = "omniverse_gpu"
_NVIDIA_GPU_CONSTRAINT = Label("//omniverse/constraints:nvidia_gpu")
_EXEC_ROOT_TOKEN = "__RULES_OMNIVERSE_EXEC_ROOT__"

def _omni_worker_script_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.file.src,
        is_executable = True,
    )
    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = ctx.runfiles(files = [ctx.file.src] + ctx.files.data),
        ),
    ]

omni_worker_script = rule(
    implementation = _omni_worker_script_impl,
    attrs = {
        "data": attr.label_list(
            allow_files = True,
            doc = "Runtime files made available beside the worker script.",
        ),
        "src": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Executable script with a worker-compatible shebang, such as /usr/bin/env python3.",
        ),
    },
    doc = "Declares a script executable without embedding a host-specific language runtime.",
    executable = True,
)

def _expand_arguments(values, inputs, outputs, execroot = "."):
    substitutions = {}
    for file in inputs:
        substitutions["{input:%s}" % file.basename] = file.path
    for file in outputs:
        substitutions["{output:%s}" % file.basename] = file.path
    if len(inputs) == 1:
        substitutions["{input}"] = inputs[0].path
    if len(outputs) == 1:
        substitutions["{output}"] = outputs[0].path

    expanded = []
    for value in values:
        if value == "{inputs}":
            expanded.extend([file.path for file in inputs])
            continue
        if value == "{outputs}":
            expanded.extend([file.path for file in outputs])
            continue
        if value == "{input}":
            if len(inputs) != 1:
                fail("{input} requires exactly one src; use {inputs} or {input:<basename>}")
            expanded.append(inputs[0].path)
            continue
        if value == "{output}":
            if len(outputs) != 1:
                fail("{output} requires exactly one out; use {outputs} or {output:<basename>}")
            expanded.append(outputs[0].path)
            continue

        result = value
        result = result.replace("{execroot}", execroot)
        for placeholder, path in substitutions.items():
            result = result.replace(placeholder, path)
        expanded.append(result)
    return expanded

def _declare_outputs(ctx):
    file_outputs = list(ctx.outputs.outs)
    tree_outputs = [ctx.actions.declare_directory(path) for path in ctx.attr.tree_outs]
    outputs = file_outputs + tree_outputs
    if not outputs:
        fail("at least one of outs or tree_outs must be provided")
    return file_outputs, tree_outputs, outputs

def _expand_environment(values, inputs, outputs, execroot = "."):
    expanded = {}
    for name, value in values.items():
        expanded[name] = _expand_arguments([value], inputs, outputs, execroot = execroot)[0]
    return expanded

def _omni_gpu_action_impl(ctx):
    inputs = ctx.files.srcs + ctx.files.data
    _, tree_outputs, outputs = _declare_outputs(ctx)
    tool = ctx.attr.tool[DefaultInfo].files_to_run
    args = ctx.actions.args()
    args.add_all(_expand_arguments(ctx.attr.arguments, ctx.files.srcs, outputs))

    ctx.actions.run(
        executable = tool,
        arguments = [args],
        env = ctx.attr.env,
        execution_requirements = ctx.attr.execution_requirements,
        exec_group = _GPU_EXEC_GROUP,
        inputs = depset(inputs),
        mnemonic = ctx.attr.mnemonic,
        outputs = outputs,
        progress_message = ctx.attr.progress_message or "Running GPU action %{label}",
        tools = [tool],
    )

    output_set = depset(outputs)
    return [
        DefaultInfo(files = output_set),
        OmniGpuActionInfo(
            container_image = "",
            outputs = output_set,
            tree_outputs = depset(tree_outputs),
        ),
    ]

_omni_gpu_action = rule(
    implementation = _omni_gpu_action_impl,
    attrs = {
        "arguments": attr.string_list(
            doc = "Tool arguments. Supports {input}, {inputs}, {output}, {outputs}, {execroot}, and basename-qualified placeholders.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional action inputs not expanded into arguments.",
        ),
        "env": attr.string_dict(
            doc = "Environment variables supplied to the action.",
        ),
        "execution_requirements": attr.string_dict(
            doc = "Optional Bazel execution requirements such as no-local.",
        ),
        "mnemonic": attr.string(
            default = "OmniGpuAction",
            doc = "Action mnemonic shown by Bazel and remote execution telemetry.",
        ),
        "outs": attr.output_list(
            doc = "Files the tool must create.",
        ),
        "progress_message": attr.string(
            doc = "Optional action progress message.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Input files available to the tool and argument placeholders.",
        ),
        "tool": attr.label(
            cfg = config.exec(_GPU_EXEC_GROUP),
            executable = True,
            mandatory = True,
            doc = "Executable that performs the GPU work.",
        ),
        "tree_outs": attr.string_list(
            doc = "Directory artifacts the tool must create.",
        ),
    },
    doc = "Runs a declared action on an execution platform carrying the nvidia_gpu constraint.",
    exec_groups = {
        _GPU_EXEC_GROUP: exec_group(
            exec_compatible_with = ["//omniverse/constraints:nvidia_gpu"],
        ),
    },
)

def _omni_container_gpu_action_impl(ctx):
    inputs = ctx.files.srcs + ctx.files.data
    _, tree_outputs, outputs = _declare_outputs(ctx)
    runner = ctx.attr.runner[DefaultInfo].files_to_run
    args = ctx.actions.args()
    args.add("--runtime", ctx.attr.container_runtime)
    args.add("--image", ctx.attr.image)
    args.add("--gpu-count", ctx.attr.gpu_count)
    args.add("--shm-size", ctx.attr.shm_size)
    args.add("--network", ctx.attr.network)
    if ctx.attr.entrypoint:
        args.add("--entrypoint", ctx.attr.entrypoint)
    for name, value in sorted(_expand_environment(ctx.attr.container_env, ctx.files.srcs, outputs, execroot = _EXEC_ROOT_TOKEN).items()):
        args.add("--env", "%s=%s" % (name, value))
    for name in sorted(ctx.attr.forward_worker_env):
        args.add("--forward-env", name)
    args.add("--")
    args.add_all(_expand_arguments(ctx.attr.arguments, ctx.files.srcs, outputs, execroot = _EXEC_ROOT_TOKEN))

    ctx.actions.run(
        executable = runner,
        arguments = [args],
        exec_group = _GPU_EXEC_GROUP,
        execution_requirements = ctx.attr.execution_requirements,
        inputs = depset(inputs),
        mnemonic = ctx.attr.mnemonic,
        outputs = outputs,
        progress_message = ctx.attr.progress_message or "Running containerized GPU action %{label}",
        tools = [runner],
    )

    output_set = depset(outputs)
    return [
        DefaultInfo(files = output_set),
        OmniGpuActionInfo(
            container_image = ctx.attr.image,
            outputs = output_set,
            tree_outputs = depset(tree_outputs),
        ),
    ]

_omni_container_gpu_action = rule(
    implementation = _omni_container_gpu_action_impl,
    attrs = {
        "gpu_count": attr.int(mandatory = True),
        "runner": attr.label(
            cfg = config.exec(_GPU_EXEC_GROUP),
            default = Label("//omniverse/private:container_gpu_runner"),
            doc = "Worker-side wrapper that launches the selected OCI runtime.",
            executable = True,
        ),
        "arguments": attr.string_list(
            doc = "Image entrypoint arguments with the same placeholders as omni_gpu_action.",
        ),
        "container_env": attr.string_dict(
            doc = "Non-secret environment values passed to the container. Path placeholders are expanded.",
        ),
        "container_runtime": attr.string(
            default = "docker",
            doc = "Worker-side OCI runtime command.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional action inputs not expanded into arguments.",
        ),
        "entrypoint": attr.string(
            doc = "Optional container entrypoint override.",
        ),
        "execution_requirements": attr.string_dict(
            doc = "Optional Bazel execution requirements such as no-local.",
        ),
        "forward_worker_env": attr.string_list(
            doc = "Names of worker-injected variables forwarded without recording their values in the action.",
        ),
        "image": attr.string(
            mandatory = True,
            doc = "OCI image reference. Tags, digests, and private registry references are supported.",
        ),
        "mnemonic": attr.string(
            default = "OmniContainerGpuAction",
            doc = "Action mnemonic shown by Bazel and remote execution telemetry.",
        ),
        "network": attr.string(
            default = "none",
            doc = "Container network mode. The hermetic default is none.",
        ),
        "outs": attr.output_list(
            doc = "Files the container must create.",
        ),
        "progress_message": attr.string(
            doc = "Optional action progress message.",
        ),
        "shm_size": attr.string(
            default = "64g",
            doc = "Container shared-memory allocation.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Input files available inside the mounted action sandbox.",
        ),
        "tree_outs": attr.string_list(
            doc = "Directory artifacts the container must create.",
        ),
    },
    doc = "Runs a caller-selected OCI image on a registered NVIDIA GPU execution platform.",
    exec_groups = {
        _GPU_EXEC_GROUP: exec_group(
            exec_compatible_with = [
                "//omniverse/constraints:nvidia_gpu",
                "//omniverse/constraints:oci_container_runtime",
            ],
        ),
    },
)

def _gpu_exec_properties(exec_properties, gpu_count, gpu_model):
    if gpu_count < 1:
        fail("gpu_count must be at least 1")

    properties = dict(exec_properties or {})
    properties["%s.gpu_count" % _GPU_EXEC_GROUP] = str(gpu_count)
    if gpu_model:
        properties["%s.gpu_model" % _GPU_EXEC_GROUP] = gpu_model
    return properties

def omni_gpu_action(name, gpu_count = 1, gpu_model = "", exec_properties = None, **kwargs):
    """Runs an action on a user-selected NVIDIA GPU execution worker.

    Args:
      name: Target name.
      gpu_count: Minimum number of GPUs requested from the remote scheduler.
      gpu_model: Optional scheduler model string, such as H200, L40S, or A100.
      exec_properties: Additional Bazel execution properties.
      **kwargs: Remaining attributes for the underlying action rule.
    """
    _omni_gpu_action(
        name = name,
        exec_properties = _gpu_exec_properties(exec_properties, gpu_count, gpu_model),
        **kwargs
    )

def omni_container_gpu_action(
        name,
        image,
        gpu_count = 1,
        gpu_model = "",
        exec_properties = None,
        **kwargs):
    """Runs a caller-selected container as a declared GPU action.

    The worker must provide the selected OCI runtime and NVIDIA container GPU
    support. Only explicitly declared inputs and outputs are mounted. Secret
    values must be injected by the worker and named with forward_worker_env;
    never place secret values in container_env.
    """
    properties = _gpu_exec_properties(exec_properties, gpu_count, gpu_model)
    _omni_container_gpu_action(
        name = name,
        exec_properties = properties,
        gpu_count = gpu_count,
        image = image,
        **kwargs
    )

def omni_gpu_platform(
        name,
        gpu_count = 1,
        gpu_model = "",
        constraint_values = None,
        exec_properties = None,
        **kwargs):
    """Declares a GPU execution platform without assuming a particular model."""
    if gpu_count < 1:
        fail("gpu_count must be at least 1")

    constraints = list(constraint_values or [])
    if _NVIDIA_GPU_CONSTRAINT not in constraints:
        constraints.append(_NVIDIA_GPU_CONSTRAINT)

    properties = dict(exec_properties or {})
    properties["gpu_count"] = str(gpu_count)
    if gpu_model:
        properties["gpu_model"] = gpu_model

    native.platform(
        name = name,
        constraint_values = constraints,
        exec_properties = properties,
        **kwargs
    )
