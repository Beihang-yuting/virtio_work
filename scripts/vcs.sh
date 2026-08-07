#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
source "$root_dir/scripts/test_manifest.sh"

if [[ -z "${VCS_HOME:-}" ]]; then
  echo "VCS_HOME is not set; source the VCS environment before running VCS" >&2
  exit 3
fi

if [[ ! -x "$VCS_HOME/bin/vcs" ]]; then
  echo "VCS executable not found: $VCS_HOME/bin/vcs" >&2
  exit 4
fi

compile_only=0
case "$#" in
  0)
    ;;
  1)
    if [[ "$1" != "--compile-only" ]]; then
      echo "unsupported argument: $1" >&2
      exit 2
    fi
    compile_only=1
    ;;
  *)
    echo "unsupported arguments: $*" >&2
    exit 2
    ;;
esac

TEST="${TEST:-}"
if ! is_virtio_maintained_test "$TEST"; then
  echo "unsupported TEST: $TEST" >&2
  exit 2
fi

"$root_dir/scripts/check_deps.sh"
cd "$root_dir"
mkdir -p build

vcs_args=(
  -full64
  -sverilog
  -ntb_opts uvm-1.2
  -timescale=1ns/1ps
  -f "$root_dir/filelists/dpu_common.f"
  -f "$root_dir/filelists/virtio_net.f"
)

vcs_args+=(
  -f "$root_dir/filelists/tests.f"
  -top virtio_tb_top
  -o "$root_dir/build/simv"
)

"$VCS_HOME/bin/vcs" "${vcs_args[@]}"
if (( compile_only )); then
  exit 0
fi
"$root_dir/build/simv" +UVM_TESTNAME="$TEST" +UVM_VERBOSITY="${UVM_VERBOSITY:-UVM_LOW}"
