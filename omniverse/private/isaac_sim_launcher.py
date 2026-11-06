#!/usr/bin/env python3
"""Check a scene's dependencies are declared, then run an Isaac Sim script.

Usage: isaac_sim_launcher.py [--scene SCENE] [--asset PATH]... -- SCRIPT [SCRIPT_ARGS...]

This file is also the program of each process the launcher starts, so no
process gets -c code, which Kit's start-up rejects when it has a line break:

  isaac_sim_launcher.py check-scene SCENE [ASSET...]
      the dependency check, in a process that can import the image's pxr
  isaac_sim_launcher.py run-script FD SCRIPT [SCRIPT_ARGS...]
      the script, reporting how it ended to the pipe FD
"""

import argparse
import builtins
import functools
import glob
import importlib.machinery
import io
import os
import re
import subprocess
import sys
import types

_ONLINE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]+:/")

_CHECK_SCENE = "check-scene"
_RUN_SCRIPT = "run-script"


def _parse(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(
        prog="isaac_sim_launcher.py",
        usage="%(prog)s [--scene SCENE] [--asset PATH]... -- SCRIPT [SCRIPT_ARGS...]",
    )
    parser.add_argument("--scene")
    parser.add_argument("--asset", action="append", default=[])
    if "--" not in argv:
        parser.error("missing -- before SCRIPT")
    split = argv.index("--")
    options = parser.parse_args(argv[:split])
    command = argv[split + 1 :]
    if not command:
        parser.error("missing SCRIPT after --")
    return options, command


def _this_program(role: str, *args: str) -> list[str]:
    """The command line of a process that runs this file in role."""
    return [sys.executable, os.path.abspath(__file__), role, *args]


def _status(returncode: int) -> int:
    """A process's exit status as a shell reports it: 128 + S when killed by signal S."""
    if returncode < 0:
        return 128 - returncode
    return returncode


def _real(path: str) -> str | None:
    if not os.path.exists(path):
        return None
    return os.path.realpath(path)


def _check_scene(scene: str, assets: list[str]) -> list[str]:
    """Returns the scene's undeclared local dependencies, warning about online ones."""
    from pxr import UsdUtils

    layers, resolved_assets, unresolved = UsdUtils.ComputeAllDependencies(scene)
    declared = {_real(path) for path in [scene, *assets]} - {None}

    resolved = [layer.realPath or layer.identifier for layer in layers] + list(resolved_assets)
    undeclared = []
    for path, is_resolved in [(p, True) for p in resolved] + [(p, False) for p in unresolved]:
        if _ONLINE.match(path):
            print("isaac_sim_launcher: warning: online dependency is not checked: %s" % path, file=sys.stderr)
            continue
        if not is_resolved or _real(path) not in declared:
            if path not in undeclared:
                undeclared.append(path)
    return undeclared


def _report_undeclared(scene: str, assets: list[str]) -> int:
    """Prints an error naming every undeclared dependency; returns the exit status."""
    undeclared = _check_scene(scene, assets)
    if undeclared:
        print(
            "isaac_sim_launcher: error: %s depends on files not declared in scene or assets:\n%s"
            % (scene, "\n".join("  " + path for path in undeclared)),
            file=sys.stderr,
        )
        return 1
    return 0


def _prepend(paths: list[str], value: str | None) -> str:
    return ":".join(paths + ([value] if value else []))


def _check_with_image_pxr(scene: str, assets: list[str]) -> int:
    """Runs the check in a new process that can import the image's pxr.

    In the image, sys.executable is <root>/kit/python/bin/python3 and pxr lives
    in <root>/extscache/omni.usd.libs-<version>+<hash>.../. Only that process
    gets these paths; the launcher's environment, and so the script's, is
    unchanged.
    """
    # <root>/kit/python/bin/python3 -> <root>, without resolving symlinks.
    root = os.path.normpath(os.path.join(sys.executable, *[os.pardir] * 4))
    libs_pattern = os.path.join("extscache", "omni.usd.libs-*")
    pattern = os.path.join(root, libs_pattern)
    found = glob.glob(os.path.join(glob.escape(root), libs_pattern))
    matches = sorted(path for path in found if os.path.isdir(path))
    if len(matches) != 1:
        print(
            "isaac_sim_launcher: error: pxr is not importable, and %s matches %d folders instead of 1:%s"
            % (pattern, len(matches), "".join("\n  " + path for path in matches)),
            file=sys.stderr,
        )
        return 1
    [libs] = matches
    env = dict(os.environ)
    env["PYTHONPATH"] = _prepend([libs], env.get("PYTHONPATH"))
    env["LD_LIBRARY_PATH"] = _prepend(
        [os.path.join(libs, "bin"), os.path.join(libs, "lib")], env.get("LD_LIBRARY_PATH")
    )
    command = _this_program(_CHECK_SCENE, scene, *assets)
    return _status(subprocess.run(command, env=env, check=False).returncode)


def _check(scene: str, assets: list[str]) -> int:
    try:
        from pxr import UsdUtils  # noqa: F401
    except ImportError:
        return _check_with_image_pxr(scene, assets)
    return _report_undeclared(scene, assets)


def _exit_code(error: BaseException | None) -> int:
    """The launcher's exit code for a script that ended with error in flight; None means a normal finish."""
    if error is None:
        return 0
    if isinstance(error, SystemExit):
        if error.code is None:
            return 0
        if isinstance(error.code, int) and 0 <= error.code <= 255:
            return error.code
    return 1


def _patch_close(report) -> None:
    """Makes SimulationApp.close() report how the script ended, patched on the class before the script runs.

    In the image, `import isaacsim` registers isaacsim.simulation_app as a
    placeholder and defines SimulationApp in simulation_app.simulation_app, so
    the class is patched where both import forms find it. Importing isaacsim
    does not start Kit. Without a usable isaacsim the script runs unpatched.
    """
    try:
        import isaacsim
    except Exception:
        return
    app_class = getattr(isaacsim, "SimulationApp", None)
    if app_class is None:
        return
    close = app_class.close

    @functools.wraps(close)
    def close_and_report(app, *args, **kwargs):
        # close() never returns in the image, so this is the last chance to report.
        report(_exit_code(sys.exc_info()[1]))
        return close(app, *args, **kwargs)

    app_class.close = close_and_report


def _run_here(fd: int, command: list[str]) -> int:
    """Runs the script as __main__ in this process, reporting how it ended to fd.

    The script sees what `python SCRIPT` gives it, except that isaacsim is
    already imported. It reports when it calls SimulationApp.close() and when
    it returns or raises.
    """
    # A program the script execs into cannot report for it.
    os.set_inheritable(fd, False)

    def report(code: int) -> None:
        os.write(fd, b"%d\n" % code)

    script = command[0]
    sys.argv[:] = command
    if not sys.flags.safe_path:
        # `python LAUNCHER` put the launcher's folder where `python SCRIPT` puts the script's.
        sys.path[0] = os.path.dirname(os.path.realpath(script))
    # After sys.path is set, so isaacsim is found where the script would find it.
    _patch_close(report)

    main_module = types.ModuleType("__main__")
    main_module.__dict__.update(
        __file__=script,
        __cached__=None,
        __builtins__=builtins,
        __loader__=importlib.machinery.SourceFileLoader("__main__", script),
    )
    sys.modules["__main__"] = main_module
    try:
        with io.open_code(script) as f:
            code = compile(f.read(), script, "exec", dont_inherit=True)
        exec(code, main_module.__dict__)
    except SystemExit as e:
        report(_exit_code(e))
        raise
    except BaseException as e:
        report(_exit_code(e))
        # Print the traceback from the script's own frame, as `python SCRIPT` would.
        e.__traceback__ = e.__traceback__.tb_next
        sys.excepthook(type(e), e, e.__traceback__)
        return 1
    report(_exit_code(None))
    return 0


def _read_reports(fd: int) -> list[int]:
    """Reads the completion reports already written, without waiting for EOF.

    A process the script left running may still hold the write end. Every
    report was written before the script's process exited.
    """
    os.set_blocking(fd, False)
    data = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            break
        if not chunk:
            break
        data += chunk
    return [int(report) for report in data.split()]


def _run_script(command: list[str]) -> int:
    """Runs the script and exits by how it ended, not by how its process ended.

    Kit ends the process with 0 whatever the script did, so the script's
    process reports the script's ending over a pipe. Nothing it prints is read.
    """
    read_end, write_end = os.pipe()
    try:
        process = subprocess.Popen(_this_program(_RUN_SCRIPT, str(write_end), *command), pass_fds=[write_end])
    finally:
        os.close(write_end)
    try:
        status = _status(process.wait())
        reports = _read_reports(read_end)
    finally:
        os.close(read_end)
    failures = [report for report in reports if report != 0]
    if failures:
        return failures[0]
    if not reports:
        print(
            "isaac_sim_launcher: error: %s ended with no completion report (exit status %d); "
            "its process was replaced with os.exec*, ended with os._exit(), or ended by Kit" % (command[0], status),
            file=sys.stderr,
        )
        return status or 1
    return status


def main(argv: list[str]) -> int:
    if argv[:1] == [_CHECK_SCENE]:
        return _report_undeclared(argv[1], argv[2:])
    if argv[:1] == [_RUN_SCRIPT]:
        return _run_here(int(argv[1]), argv[2:])
    options, command = _parse(argv)
    if options.scene:
        status = _check(options.scene, options.asset)
        if status != 0:
            return status
    return _run_script(command)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
