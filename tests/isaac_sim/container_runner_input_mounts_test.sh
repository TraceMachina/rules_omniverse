#!/usr/bin/env bash
# With --input PATH, container_gpu_runner.sh mounts read-only, before the
# image, the real directory behind every symlink the container would meet on
# PATH and could not follow, at the path the link names. Without --input the
# command line is unchanged.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

src="$base/src"
checkout="$base/rules_omniverse"
output_base="$base/output_base"
bin_dir="bazel-out/k8-fastbuild/bin/examples"

# A non-sandboxed Bazel 8 execution root, as a local run sees it:
# - top-level entries of the main repository link into its source tree, a
#   directory (examples) or a file (BUILD.bazel, run_scene_based_sdg.py);
# - external/rules_omniverse+ links to the output base's entry, which for a
#   local_path_override links to the checkout: two hops;
# - generated files are real files under bazel-out, and a link may point to
#   another file under the execution root.
mkdir -p "$src/examples/isaac_sim" "$checkout/omniverse/private" \
  "$output_base/external" "$work/external" "$work/$bin_dir"
echo run >"$src/examples/isaac_sim/run.py"
echo build >"$src/BUILD.bazel"
echo sdg >"$src/run_scene_based_sdg.py"
echo launcher >"$checkout/omniverse/private/isaac_sim_launcher.py"
echo config >"$work/$bin_dir/config.yaml"
ln -s "$src/examples" "$work/examples"
ln -s "$src/BUILD.bazel" "$work/BUILD.bazel"
ln -s "$src/run_scene_based_sdg.py" "$work/run_scene_based_sdg.py"
ln -s "$checkout" "$output_base/external/rules_omniverse+"
ln -s "$output_base/external/rules_omniverse+" "$work/external/rules_omniverse+"
ln -s "$work/$bin_dir/config.yaml" "$work/$bin_dir/alias.yaml"
ln -s "$base/gone/missing.py" "$work/dangling.py"

# Runs the runner; arguments are runner flags.
run_with_inputs() {
  run_runner --network host --entrypoint /isaac-sim/python.sh --env ACCEPT_EULA=Y "$@"
}

# The command line without --input. Must stay exactly this.
expected_plain="$(printf '%s\n' \
  run --rm \
  --gpus 1 \
  --network host \
  --shm-size 64g \
  --volume "$work:$work" \
  --workdir "$work" \
  --entrypoint /isaac-sim/python.sh \
  --env ACCEPT_EULA=Y \
  "$image" \
  launcher.py)"

# $1 label, rest: the exact "--volume" values expected on top of the plain
# command line, each once, before the image, in any order.
check_mounts() {
  local label="$1"
  shift
  check_invoked "$label" || return 0
  ((status == 0)) || fail "$label: runner exited $status"
  split_volumes "$label"
  local want got
  want="$(printf '%s\n' ${1+"$@"} | sed '/^$/d' | sort)"
  got="$(sort <<<"$added" | sed '/^$/d')"
  if [[ "$got" != "$want" ]]; then
    fail "$label: added mounts differ"
    diff <(echo "$want") <(echo "$got") | sed 's/^/  /' >&2 || true
  fi
  if [[ "$remaining" != "$expected_plain" ]]; then
    fail "$label: command line differs beyond the added mounts"
    diff <(echo "$expected_plain") <(echo "$remaining") | sed 's/^/  /' >&2 || true
  fi
}

run_with_inputs
check_argv "no --input" "$expected_plain"

# A file under a top-level directory symlink: that directory, same path.
run_with_inputs --input examples/isaac_sim/run.py
check_mounts "top-level directory symlink" "$src/examples:$src/examples:ro"

# The launcher in a local_path_override repository, which the container cannot
# open without a mount: the checkout is mounted where
# external/rules_omniverse+ points, in the output base.
run_with_inputs --input external/rules_omniverse+/omniverse/private/isaac_sim_launcher.py
check_mounts "external/ symlink to a local_path_override" \
  "$checkout:$output_base/external/rules_omniverse+:ro"

# A real generated file, and a link to a file under the execution root: nothing.
run_with_inputs --input "$bin_dir/config.yaml" --input "$bin_dir/alias.yaml"
check_mounts "inputs already under the execution root"

# Two file symlinks into the same directory: one mount of that directory.
run_with_inputs --input BUILD.bazel --input run_scene_based_sdg.py
check_mounts "two file symlinks into one directory" "$src:$src:ro"

# All of it together, with an input repeated: each directory once.
run_with_inputs \
  --input external/rules_omniverse+/omniverse/private/isaac_sim_launcher.py \
  --input run_scene_based_sdg.py \
  --input examples/isaac_sim/run.py \
  --input "$bin_dir/config.yaml" \
  --input BUILD.bazel \
  --input examples/isaac_sim/run.py
check_mounts "all inputs together" \
  "$checkout:$output_base/external/rules_omniverse+:ro" \
  "$src:$src:ro" \
  "$src/examples:$src/examples:ro"

# The other PATH forms: absolute, and prefixed with the execroot token.
run_with_inputs --input "$work/examples/isaac_sim/run.py" --input __RULES_OMNIVERSE_EXEC_ROOT__/BUILD.bazel
check_mounts "absolute and token PATH forms" "$src/examples:$src/examples:ro" "$src:$src:ro"

# A missing input or a dangling link fails before docker runs, naming PATH.
for missing in does/not/exist.py dangling.py; do
  run_with_inputs --input examples/isaac_sim/run.py --input "$missing"
  check_refused "--input $missing" "$missing"
done

finish
