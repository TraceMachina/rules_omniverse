"""Analysis tests for isaac_sim_action and isaac_sim_platform."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_EXEC_ROOT_TOKEN = "__RULES_OMNIVERSE_EXEC_ROOT__/"
_LAUNCHER = "omniverse/private/isaac_sim_launcher.py"
_MNEMONIC = "IsaacSimAction"

def _normalize(value):
    # Exec paths may carry the runner's execroot token; treat both forms alike.
    return value.replace(_EXEC_ROOT_TOKEN, "")

def _flag_values(runner_args, flag):
    return [runner_args[i + 1] for i in range(len(runner_args) - 1) if runner_args[i] == flag]

def _action_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # The target's only default output is the <name>_out directory.
    outputs = target[DefaultInfo].files.to_list()
    out_name = target.label.name + "_out"
    asserts.equals(env, [out_name], [f.basename for f in outputs], "default outputs")
    asserts.true(env, len(outputs) == 1 and outputs[0].is_directory, "<name>_out must be a tree artifact")
    if len(outputs) != 1:
        return analysistest.end(env)
    out_dir = outputs[0].path

    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == _MNEMONIC]
    if len(actions) != 1:
        analysistest.fail(env, "expected one %s action, found mnemonics %s" % (
            _MNEMONIC,
            [a.mnemonic for a in analysistest.target_actions(env)],
        ))
        return analysistest.end(env)
    action = actions[0]
    asserts.equals(env, [out_dir], [f.path for f in action.outputs.to_list()], "action outputs")

    argv = action.argv
    if "--" not in argv:
        analysistest.fail(env, "no -- separator between runner flags and container arguments: %s" % argv)
        return analysistest.end(env)
    split = argv.index("--")
    runner_args = argv[1:split]
    container_args = [_normalize(v) for v in argv[split + 1:]]

    # Runner flags.
    asserts.equals(env, [ctx.attr.expected_image], _flag_values(runner_args, "--image"), "--image")
    asserts.equals(env, ["/isaac-sim/python.sh"], _flag_values(runner_args, "--entrypoint"), "--entrypoint")
    asserts.equals(env, ["1"], _flag_values(runner_args, "--gpu-count"), "--gpu-count")
    asserts.equals(env, [ctx.attr.expected_network], _flag_values(runner_args, "--network"), "--network")
    container_env = _flag_values(runner_args, "--env")
    for required in ["ACCEPT_EULA=Y", "PRIVACY_CONSENT=N", "PYTHONUNBUFFERED=1"]:
        asserts.true(env, required in container_env, "missing --env %s in %s" % (required, container_env))

    # Container arguments: launcher, launcher flags, --, script, user args, --frames.
    expected = [v.replace("{output}", out_dir) for v in ctx.attr.expected_container_args]
    asserts.equals(env, expected, container_args, "container arguments")

    # Inputs.
    input_paths = [f.path for f in action.inputs.to_list()]
    for path in [_LAUNCHER] + ctx.attr.expected_inputs:
        asserts.true(env, path in input_paths, "missing action input %s" % path)

    # The cache-mount variable belongs to the worker, never to the action.
    for value in argv + action.env.keys() + action.env.values():
        asserts.false(env, "OMNI_CONTAINER_CACHE_MOUNTS" in value, "action sets OMNI_CONTAINER_CACHE_MOUNTS: %s" % value)

    return analysistest.end(env)

action_test = analysistest.make(
    _action_test_impl,
    attrs = {
        "expected_container_args": attr.string_list(
            doc = "Exact container arguments; {output} stands for the <name>_out exec path.",
        ),
        "expected_image": attr.string(),
        "expected_inputs": attr.string_list(),
        "expected_network": attr.string(default = "host"),
    },
)

def _action_requires_digest_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "@sha256:")
    return analysistest.end(env)

action_requires_digest_test = analysistest.make(
    _action_requires_digest_test_impl,
    expect_failure = True,
)

def _action_rejects_frames_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "frames")
    return analysistest.end(env)

action_rejects_frames_test = analysistest.make(
    _action_rejects_frames_test_impl,
    expect_failure = True,
)

def _platform_rejects_worker_runtime_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "worker_runtime")
    asserts.expect_failure(env, "driver")
    return analysistest.end(env)

platform_rejects_worker_runtime_test = analysistest.make(
    _platform_rejects_worker_runtime_test_impl,
    expect_failure = True,
)

def _platform_rejects_container_runtime_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "container-runtime")
    asserts.expect_failure(env, "docker")
    return analysistest.end(env)

platform_rejects_container_runtime_test = analysistest.make(
    _platform_rejects_container_runtime_test_impl,
    expect_failure = True,
)

def _single_action(env):
    # Returns (action, <name>_out exec path), or (None, None) after recording a failure.
    target = analysistest.target_under_test(env)
    outputs = target[DefaultInfo].files.to_list()
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == _MNEMONIC]
    if len(actions) != 1 or len(outputs) != 1:
        analysistest.fail(env, "expected one %s action and one output, found %s and %s" % (
            _MNEMONIC,
            [a.mnemonic for a in analysistest.target_actions(env)],
            [f.path for f in outputs],
        ))
        return None, None
    return actions[0], outputs[0].path

def _runner_args(action):
    argv = action.argv
    return argv[1:argv.index("--")] if "--" in argv else argv[1:]

def _action_runner_flag_test_impl(ctx):
    env = analysistest.begin(ctx)
    action, out_dir = _single_action(env)
    if action:
        values = [_normalize(v) for v in _flag_values(_runner_args(action), ctx.attr.flag)]
        asserts.equals(env, [out_dir], values, ctx.attr.flag)
    return analysistest.end(env)

# isaac_sim_action passes an opt-in runner flag naming its output.
action_runner_flag_test = analysistest.make(
    _action_runner_flag_test_impl,
    attrs = {
        "flag": attr.string(doc = "Runner flag that must appear once, with the <name>_out exec path."),
    },
)

def _action_absolute_script_test_impl(ctx):
    env = analysistest.begin(ctx)
    action, _ = _single_action(env)
    if action:
        argv = action.argv
        container_args = argv[argv.index("--") + 1:] if "--" in argv else []
        if "--" not in container_args:
            analysistest.fail(env, "no -- between launcher flags and script: %s" % container_args)
        else:
            script = container_args[container_args.index("--") + 1]
            asserts.equals(env, _EXEC_ROOT_TOKEN + ctx.attr.expected_script, script, "script argument")
    return analysistest.end(env)

# The script path given to the launcher is absolute inside the container.
action_absolute_script_test = analysistest.make(
    _action_absolute_script_test_impl,
    attrs = {
        "expected_script": attr.string(doc = "Exec path of the script; it must arrive prefixed with the execroot token."),
    },
)

def _action_input_flags_test_impl(ctx):
    env = analysistest.begin(ctx)
    action, _ = _single_action(env)
    if action:
        values = [_normalize(v) for v in _flag_values(_runner_args(action), "--input")]
        expected = [_LAUNCHER] + ctx.attr.expected_inputs
        asserts.equals(env, sorted(expected), sorted(values), "--input values (any order)")
    return analysistest.end(env)

# isaac_sim_action names every file the container reads with --input.
action_input_flags_test = analysistest.make(
    _action_input_flags_test_impl,
    attrs = {
        "expected_inputs": attr.string_list(doc = "Exec paths besides the launcher, each expected exactly once."),
    },
)

def _script_args(action):
    # The container arguments after the script, or None if the layout is wrong.
    argv = action.argv
    container_args = argv[argv.index("--") + 1:] if "--" in argv else []
    if "--" not in container_args:
        return None
    return container_args[container_args.index("--") + 2:]

def _action_script_args_test_impl(ctx):
    env = analysistest.begin(ctx)
    action, out_dir = _single_action(env)
    if action:
        actual = _script_args(action)
        if actual == None:
            analysistest.fail(env, "no -- between launcher flags and script: %s" % action.argv)
            return analysistest.end(env)
        raw = ctx.attr.expected_script_args
        expected = [
            v.replace("{output}", out_dir).replace("{bindir}", ctx.bin_dir.path).replace("{execroot}", _EXEC_ROOT_TOKEN[:-1])
            for v in raw
        ]

        # {output} may be either exec path form; {input:NAME} must be absolute.
        compared = [
            _normalize(v) if i < len(raw) and "{output}" in raw[i] else v
            for i, v in enumerate(actual)
        ]
        asserts.equals(env, expected, compared, "script arguments")
    return analysistest.end(env)

# {input:NAME} becomes the absolute path of the one input with that basename.
action_script_args_test = analysistest.make(
    _action_script_args_test_impl,
    attrs = {
        "expected_script_args": attr.string_list(
            doc = "Exact arguments after the script. {output} is the <name>_out exec path (either form); " +
                  "{execroot} is the execroot token, compared exactly; {bindir} is the bin directory.",
        ),
    },
)

def _action_container_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    action, out_dir = _single_action(env)
    if action:
        actual = _flag_values(_runner_args(action), "--env")
        for value in ctx.attr.expected_env:
            expected = value.replace("{output}", out_dir).replace("{execroot}", _EXEC_ROOT_TOKEN[:-1])
            asserts.true(env, expected in actual, "missing --env %s in %s" % (expected, actual))
    return analysistest.end(env)

# isaac_sim_action expands {output} and {input:NAME} in container_env values, as in args.
action_container_env_test = analysistest.make(
    _action_container_env_test_impl,
    attrs = {
        "expected_env": attr.string_list(
            doc = "NAME=VALUE entries that must each be passed with --env. {output} is the <name>_out " +
                  "exec path; {execroot} is the execroot token.",
        ),
    },
)

def _action_rejects_input_placeholder_test_impl(ctx):
    env = analysistest.begin(ctx)
    for message in ctx.attr.expected_messages:
        asserts.expect_failure(env, message)
    return analysistest.end(env)

# An {input:NAME} matching no input, or more than one, fails analysis.
action_rejects_input_placeholder_test = analysistest.make(
    _action_rejects_input_placeholder_test_impl,
    attrs = {
        "expected_messages": attr.string_list(doc = "Texts the analysis error must each contain."),
    },
    expect_failure = True,
)

def _example_config_resolves_test_impl(ctx):
    env = analysistest.begin(ctx)
    action, _ = _single_action(env)
    if action:
        script_args = _script_args(action) or []
        configs = [script_args[i + 1] for i in range(len(script_args) - 1) if script_args[i] == "--config"]
        if len(configs) != 1:
            analysistest.fail(env, "expected one --config in the script arguments: %s" % script_args)
            return analysistest.end(env)
        config = configs[0]
        asserts.true(env, config.startswith(_EXEC_ROOT_TOKEN), "--config %s is not absolute (no execroot token)" % config)
        generated = [f.path for f in action.inputs.to_list() if not f.is_source and f.basename.endswith(".yaml")]
        asserts.true(
            env,
            _normalize(config) in generated,
            "--config %s is not a generated .yaml input of the action %s" % (config, generated),
        )
    return analysistest.end(env)

# The example's --config is the absolute path of its generated config.
example_config_resolves_test = analysistest.make(_example_config_resolves_test_impl)
