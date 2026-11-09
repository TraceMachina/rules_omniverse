"""Writes the command line of an isaac_sim_action's action to a JSON file."""

_ActionArgvInfo = provider(
    doc = "The command lines of a target's IsaacSimAction actions.",
    fields = ["argvs"],
)

def _action_argv_aspect_impl(target, _ctx):
    return [_ActionArgvInfo(argvs = [a.argv for a in target.actions if a.mnemonic == "IsaacSimAction"])]

_action_argv_aspect = aspect(implementation = _action_argv_aspect_impl)

def _action_argv_impl(ctx):
    argvs = ctx.attr.action[_ActionArgvInfo].argvs
    if len(argvs) != 1:
        fail("expected one IsaacSimAction, found %d" % len(argvs))
    output = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(output, json.encode(argvs[0]))
    return [DefaultInfo(files = depset([output]))]

action_argv = rule(
    implementation = _action_argv_impl,
    attrs = {
        "action": attr.label(
            aspects = [_action_argv_aspect],
            mandatory = True,
            doc = "The isaac_sim_action target. It is only analysed, never executed.",
        ),
    },
    doc = "Writes <name>.json, the argv of the target's IsaacSimAction.",
)
