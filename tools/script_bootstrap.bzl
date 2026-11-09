"""A py_binary started by rules_python's shell script, which needs no python3 on PATH."""

_BOOTSTRAP_IMPL = "@rules_python//python/config_settings:bootstrap_impl"

def _script_bootstrap_transition_impl(_settings, _attr):
    return {_BOOTSTRAP_IMPL: "script"}

_script_bootstrap_transition = transition(
    implementation = _script_bootstrap_transition_impl,
    inputs = [],
    outputs = [_BOOTSTRAP_IMPL],
)

def _script_bootstrap_binary_impl(ctx):
    binary = ctx.attr.binary[0][DefaultInfo]
    target = binary.files_to_run.executable
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = executable, target_file = target, is_executable = True)
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(files = [target]).merge(binary.default_runfiles),
    )]

script_bootstrap_binary = rule(
    implementation = _script_bootstrap_binary_impl,
    attrs = {
        "binary": attr.label(
            cfg = _script_bootstrap_transition,
            executable = True,
            mandatory = True,
            doc = "The py_binary to run.",
        ),
    },
    executable = True,
    doc = "Runs binary with bootstrap_impl=script set for it, so its users add no flag.",
)
