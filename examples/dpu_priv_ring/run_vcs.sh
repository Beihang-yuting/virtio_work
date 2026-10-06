#!/usr/bin/env bash
# 目录层次：examples/dpu_priv_ring。只编译此示例与生产 package，使用 53 主机的
# VCS/UVM 验证私有驱动接入流程与环字节布局；产物写入 build/examples/dpu_priv_ring。
# 外部依赖由调用方提供并通过 check_deps.sh 校验，本脚本不修改其 checkout。
set -euo pipefail

example_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$example_dir/../.." && pwd)"

"$root_dir/scripts/check_deps.sh"
if [[ -z "${VCS_HOME:-}" || ! -x "$VCS_HOME/bin/vcs" ]]; then
  echo "VCS_HOME must point to an installed VCS" >&2
  exit 3
fi

cd "$root_dir"
mkdir -p build/examples/dpu_priv_ring
simv="$root_dir/build/examples/dpu_priv_ring/simv"

"$VCS_HOME/bin/vcs" \
  -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f "$root_dir/filelists/dpu_common.f" \
  -f "$root_dir/filelists/virtio_net.f" \
  -f "$example_dir/example.f" \
  -top dpu_priv_ring_tb_top -o "$simv"

"$simv" +UVM_TESTNAME="${TEST:-dpu_priv_driver_flow_test}" \
  +UVM_VERBOSITY="${UVM_VERBOSITY:-UVM_LOW}"
