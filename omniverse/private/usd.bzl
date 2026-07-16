"""Adapter-based OpenUSD conversion, validation, profiling, and optimization rules."""

load("//omniverse:providers.bzl", "OmniUsdInfo")

_NVIDIA_GPU_CONSTRAINT = Label("//omniverse/constraints:nvidia_gpu")

def _adapter_arguments(ctx, output = None, report = None):
    substitutions = {
        "{src}": ctx.file.src.path,
    }
    if output:
        substitutions["{out}"] = output.path
    if report:
        substitutions["{report}"] = report.path

    values = []
    for value in ctx.attr.arguments:
        expanded = value
        for placeholder, path in substitutions.items():
            expanded = expanded.replace(placeholder, path)
        values.append(expanded)
    return values

def _run_adapter(ctx, operation, outputs, output = None, report = None):
    tool = ctx.attr.tool[DefaultInfo].files_to_run
    args = ctx.actions.args()
    args.add("--operation", operation)
    args.add_all(_adapter_arguments(ctx, output = output, report = report))

    run_args = {
        "arguments": [args],
        "executable": tool,
        "inputs": depset([ctx.file.src] + ctx.files.data),
        "mnemonic": "OmniUsd%s" % operation.capitalize(),
        "outputs": outputs,
        "progress_message": "%s OpenUSD stage %%{label}" % operation.capitalize(),
        "tools": [tool],
    }
    ctx.actions.run(**run_args)

def _original_source(ctx):
    if OmniUsdInfo in ctx.attr.src:
        return ctx.attr.src[OmniUsdInfo].source
    return ctx.file.src

def _omni_usd_validate_impl(ctx):
    report = ctx.actions.declare_file(ctx.attr.report or ctx.label.name + ".validation.json")
    _run_adapter(ctx, "validate", [report], report = report)
    return [
        DefaultInfo(files = depset([report])),
        OmniUsdInfo(operation = "validate", report = report, source = _original_source(ctx), stage = ctx.file.src),
    ]

def _omni_usd_profile_impl(ctx):
    report = ctx.actions.declare_file(ctx.attr.report or ctx.label.name + ".profile.json")
    _run_adapter(ctx, "profile", [report], report = report)
    return [
        DefaultInfo(files = depset([report])),
        OmniUsdInfo(operation = "profile", report = report, source = _original_source(ctx), stage = ctx.file.src),
    ]

def _omni_usd_convert_impl(ctx):
    output = ctx.actions.declare_file(ctx.attr.output or ctx.label.name + ".usd")
    _run_adapter(ctx, "convert", [output], output = output)
    return [
        DefaultInfo(files = depset([output])),
        OmniUsdInfo(operation = "convert", report = None, source = _original_source(ctx), stage = output),
    ]

def _omni_usd_optimize_impl(ctx):
    output = ctx.actions.declare_file(ctx.attr.output or ctx.label.name + ".usd")
    _run_adapter(ctx, "optimize", [output], output = output)
    return [
        DefaultInfo(files = depset([output])),
        OmniUsdInfo(operation = "optimize", report = None, source = _original_source(ctx), stage = output),
    ]

def _common_attrs(default_arguments, src_allow_files = [".usd", ".usda", ".usdc", ".usdz"]):
    return {
        "arguments": attr.string_list(
            default = default_arguments,
            doc = "Adapter arguments supporting {src}, {out}, and {report} placeholders as applicable.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional action inputs needed by the adapter.",
        ),
        "src": attr.label(
            allow_single_file = src_allow_files,
            mandatory = True,
            doc = "Input asset. Validation, profiling, and optimization require OpenUSD; conversion accepts adapter-supported formats.",
        ),
        "tool": attr.label(
            cfg = "exec",
            executable = True,
            mandatory = True,
            doc = "Executable adapter implementing the selected operation.",
        ),
    }

def _usd_rule(rule_impl, attrs, doc):
    return rule(
        implementation = rule_impl,
        attrs = attrs,
        doc = doc,
    )

def _invoke_usd_rule(
        rule_impl,
        name,
        gpu,
        gpu_count,
        gpu_model,
        exec_compatible_with,
        exec_properties,
        kwargs):
    constraints = list(exec_compatible_with or [])
    properties = dict(exec_properties or {})
    if gpu:
        if gpu_count < 1:
            fail("gpu_count must be at least 1")
        constraints.append(_NVIDIA_GPU_CONSTRAINT)
        properties["gpu_count"] = str(gpu_count)
        if gpu_model:
            properties["gpu_model"] = gpu_model
    elif gpu_model:
        fail("gpu_model requires gpu = True")
    rule_impl(
        name = name,
        exec_compatible_with = constraints,
        exec_properties = properties,
        **kwargs
    )

_validate_attrs = _common_attrs(["--input", "{src}", "--report", "{report}"])
_validate_attrs["report"] = attr.string(doc = "Output report path, relative to this package.")
_omni_usd_validate = _usd_rule(
    _omni_usd_validate_impl,
    _validate_attrs,
    "Validates an OpenUSD stage through an explicit adapter and emits a JSON report.",
)

_profile_attrs = _common_attrs(["--input", "{src}", "--report", "{report}"])
_profile_attrs["report"] = attr.string(doc = "Output report path, relative to this package.")
_omni_usd_profile = _usd_rule(
    _omni_usd_profile_impl,
    _profile_attrs,
    "Profiles an OpenUSD stage through an explicit adapter and emits a JSON report.",
)

_convert_attrs = _common_attrs(
    ["--input", "{src}", "--output", "{out}"],
    # Conversion adapters define their own supported source formats. Keeping
    # this open lets usd-convert-asset and usd-convert-gsplat add formats
    # without requiring a rules_omniverse release.
    src_allow_files = True,
)
_convert_attrs["output"] = attr.string(doc = "Converted OpenUSD output path, relative to this package.")
_omni_usd_convert = _usd_rule(
    _omni_usd_convert_impl,
    _convert_attrs,
    "Converts an OpenUSD stage through an explicit adapter.",
)

_optimize_attrs = _common_attrs(["--input", "{src}", "--output", "{out}"])
_optimize_attrs["output"] = attr.string(doc = "Optimized OpenUSD output path, relative to this package.")
_omni_usd_optimize = _usd_rule(
    _omni_usd_optimize_impl,
    _optimize_attrs,
    "Optimizes an OpenUSD stage through an explicit adapter.",
)

def omni_usd_validate(
        name,
        gpu = False,
        gpu_count = 1,
        gpu_model = "",
        exec_compatible_with = None,
        exec_properties = None,
        **kwargs):
    """Validates an OpenUSD stage, optionally on an NVIDIA GPU platform."""
    _invoke_usd_rule(_omni_usd_validate, name, gpu, gpu_count, gpu_model, exec_compatible_with, exec_properties, kwargs)

def omni_usd_profile(
        name,
        gpu = False,
        gpu_count = 1,
        gpu_model = "",
        exec_compatible_with = None,
        exec_properties = None,
        **kwargs):
    """Profiles an OpenUSD stage, optionally on an NVIDIA GPU platform."""
    _invoke_usd_rule(_omni_usd_profile, name, gpu, gpu_count, gpu_model, exec_compatible_with, exec_properties, kwargs)

def omni_usd_convert(
        name,
        gpu = False,
        gpu_count = 1,
        gpu_model = "",
        exec_compatible_with = None,
        exec_properties = None,
        **kwargs):
    """Converts an OpenUSD stage, optionally on an NVIDIA GPU platform."""
    _invoke_usd_rule(_omni_usd_convert, name, gpu, gpu_count, gpu_model, exec_compatible_with, exec_properties, kwargs)

def omni_usd_optimize(
        name,
        gpu = False,
        gpu_count = 1,
        gpu_model = "",
        exec_compatible_with = None,
        exec_properties = None,
        **kwargs):
    """Optimizes an OpenUSD stage, optionally on an NVIDIA GPU platform."""
    _invoke_usd_rule(_omni_usd_optimize, name, gpu, gpu_count, gpu_model, exec_compatible_with, exec_properties, kwargs)
