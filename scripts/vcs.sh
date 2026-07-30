#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"

if [[ -z "${VCS_HOME:-}" ]]; then
  echo "VCS_HOME is not set; source the VCS environment before running VCS" >&2
  exit 3
fi

if [[ ! -x "$VCS_HOME/bin/vcs" ]]; then
  echo "VCS executable not found: $VCS_HOME/bin/vcs" >&2
  exit 4
fi

TEST="${TEST:-}"
case "$TEST" in
  virtio_unit_test|virtio_stress_unit_test|virtio_protocol_test|virtio_e2e_test|virtio_full_integration_test)
    ;;
  *)
    echo "unsupported TEST: $TEST" >&2
    exit 2
    ;;
esac

"$root_dir/scripts/check_deps.sh"
mkdir -p "$root_dir/build"

"$VCS_HOME/bin/vcs" -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f "$root_dir/filelists/dpu_common.f" \
  -f "$root_dir/filelists/virtio_net.f" \
  -f "$root_dir/filelists/tests.f" \
  -top virtio_tb_top -o "$root_dir/build/simv"
"$root_dir/build/simv" +UVM_TESTNAME="$TEST" +UVM_VERBOSITY="${UVM_VERBOSITY:-UVM_LOW}"
