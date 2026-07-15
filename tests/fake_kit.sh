#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" --enable com.nativelink.test.viewer "*)
    exit 0
    ;;
  *"app.kit "*)
    exit 0
    ;;
  *)
    echo "missing extension enable arg: $*" >&2
    exit 1
    ;;
esac
