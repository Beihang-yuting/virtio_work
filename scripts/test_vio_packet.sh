#!/usr/bin/env bash
# scripts：VIO wire trace/checker 的独立 VCS 验证入口。
# 本机阶段只把当前源码与明确依赖增量同步到 10.11.10.53；远端阶段生成
# common_lib_pkg，编译一个 AIP-enabled 聚焦测试并校验 PASS、限流颜色和 fatal 直通。
# 仿真产物归远端 validation/build 所有；脚本不修改生产源码、不接入全量回归。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# 远端编译函数：输入均为本次 validation 根目录下的固定 sibling checkout。
# 失败时保留 compile/run 日志；边界检查先验证依赖布局，避免误用旧 AIP/net_packet。
run_remote() {
  local validation_root repo_dir build_dir generated_dir compile_log run_log
  local aip_root dpu_root host_mem_root net_packet_root pcie_root simflow_root
  local limit_count red_limit_count fatal_count fatal_aip_count pass_count

  validation_root="${VIO_VALIDATION_ROOT:-/home/ubuntu/ryan/vio_wire_trace_validation}"
  repo_dir="$validation_root/virtio_work"
  build_dir="$repo_dir/build/vio_packet"
  generated_dir="$build_dir/common"
  aip_root="${AIP_CORE_ROOT:-$validation_root/aip_core_set_param_expr}"
  dpu_root="$validation_root/dpu_common"
  host_mem_root="$validation_root/host_mem"
  net_packet_root="$validation_root/net_packet"
  pcie_root="$validation_root/pcie_work"
  simflow_root="$validation_root/simflow"
  compile_log="$build_dir/compile.log"
  run_log="$build_dir/run.log"

  [[ -x "${VCS_HOME:-}/bin/vcs" ]] || {
    echo "VCS environment is unavailable; invoke through bash -ic on 10.11.10.53" >&2
    return 2
  }
  [[ -f "$aip_root/src/sv/aip_core_pkg.sv" ]] || {
    echo "updated AIP layout is missing: $aip_root/src/sv/aip_core_pkg.sv" >&2
    return 2
  }
  [[ -f "$net_packet_root/src/net_packet_pkg.sv" ]] || {
    echo "external net_packet package is missing: $net_packet_root" >&2
    return 2
  }
  [[ -f "$simflow_root/uvm_gen/templates/common/base_scb.sv.j2" ]] || {
    echo "simflow common SCB template is missing: $simflow_root" >&2
    return 2
  }

  export AIP_CORE_ROOT="$aip_root"
  export AIP_CORE="$aip_root"
  export DPU_COMMON_ROOT="$dpu_root"
  export HOST_MEM_ROOT="$host_mem_root"
  export NET_PACKET_ROOT="$net_packet_root"
  export PCIE_WORK_ROOT="$pcie_root"

  mkdir -p "$build_dir"
  rm -rf -- "$generated_dir"
  mkdir -p "$generated_dir"
  PYTHONPATH="$validation_root" python3 - "$generated_dir" <<'PY'
import sys
from simflow.uvm_gen.config import ProjectConfig
from simflow.uvm_gen.generators.common import CommonGenerator

output = sys.argv[1]
config = ProjectConfig(block_name="vio_packet", aip_core=True)
CommonGenerator(config).generate(output)
PY

  {
    printf 'host=%s\n' "$(hostname)"
    printf 'vcs=%s\n' "$($VCS_HOME/bin/vcs -ID 2>&1 | head -n 1)"
    printf 'aip_core_set_param_expr=%s\n' "${VIO_AIP_REV:-unknown}"
    printf 'net_packet=%s\n' "${VIO_NET_PACKET_REV:-unknown}"
  } | tee "$build_dir/versions.log"

  cd "$repo_dir"
  "$VCS_HOME/bin/vcs" -full64 -sverilog -ntb_opts uvm-1.2 \
    -timescale=1ns/1ps -debug_access+all \
    "+incdir+$aip_root/src/sv" "$aip_root/src/sv/aip_core_pkg.sv" \
    -F "$generated_dir/common_lib_pkg.f" \
    -f filelists/dpu_common.f -f filelists/virtio_net.f \
    +incdir+virtio_net_vip/tests \
    integration/project/project_vio_packet_checker.sv \
    integration/project/tests/project_vio_packet_test.sv \
    virtio_net_vip/tests/virtio_tb_top.sv \
    -top virtio_tb_top -Mdir="$build_dir/csrc" -o "$build_dir/simv" \
    -l "$compile_log"
  "$script_dir/strict_log_check.sh" compile "$compile_log"

  "$build_dir/simv" -exitstatus \
    +UVM_TESTNAME=project_vio_packet_test +UVM_VERBOSITY=UVM_LOW \
    -l "$run_log"

  pass_count="$(grep -Fc '[VIO_PACKET_TEST_PASS] wire trace' "$run_log" || true)"
  limit_count="$(grep -F '[SCB_MISMATCH]' "$run_log" | grep -Fc '[ERROR]' || true)"
  red_limit_count="$(grep -F $'\033[91m' "$run_log" | grep -Fc '[SCB_MISMATCH]' || true)"
  fatal_count="$(grep -F 'VIO_FATAL_PROBE' "$run_log" | grep -Fc 'UVM_FATAL' || true)"
  fatal_aip_count="$(grep -F '[VIO_FATAL_PROBE]' "$run_log" | grep -Fc '[ERROR]' || true)"

  [[ "$pass_count" -eq 1 ]] || {
    echo "VIO packet PASS marker missing or duplicated" >&2
    tail -n 120 "$run_log" >&2
    return 1
  }
  [[ "$limit_count" -eq 10 && "$red_limit_count" -eq 10 ]] || {
    echo "expected exactly ten bright-red AIP limit details" >&2
    grep -F 'SCB_MISMATCH' "$run_log" >&2 || true
    return 1
  }
  [[ "$fatal_count" -eq 1 && "$fatal_aip_count" -eq 0 ]] || {
    echo "UVM fatal probe was swallowed, duplicated, or rewritten by AIP" >&2
    grep -F 'VIO_FATAL_PROBE' "$run_log" >&2 || true
    return 1
  }
  grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$' "$run_log" || {
    echo "final UVM_ERROR count is nonzero" >&2
    tail -n 80 "$run_log" >&2
    return 1
  }
  grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$' "$run_log" || {
    echo "final UVM_FATAL count is nonzero" >&2
    tail -n 80 "$run_log" >&2
    return 1
  }

  echo "VIO_PACKET_VCS_PASS log=$run_log"
}

if [[ "${1:-}" == "--remote" ]]; then
  [[ "$#" -eq 1 ]] || {
    echo "--remote accepts no additional arguments" >&2
    exit 2
  }
  run_remote
  exit $?
fi

[[ "$#" -eq 0 ]] || {
  echo "Usage: VCS53_PASSWORD=... $0" >&2
  exit 2
}

: "${VCS53_PASSWORD:?set VCS53_PASSWORD for the one-time SSH password}"
remote_host="${VCS53_HOST:-10.11.10.53}"
remote_user="${VCS53_USER:-ubuntu}"
validation_root="${VIO_VALIDATION_ROOT:-/home/ubuntu/ryan/vio_wire_trace_validation}"
local_aip_root="${AIP_CORE_ROOT:-$repo_root/../aip_core_set_param_expr}"
ssh_target="$remote_user@$remote_host"
ssh_options=(
  -o PubkeyAuthentication=no
  -o PreferredAuthentications=password
  -o KbdInteractiveAuthentication=no
  -o StrictHostKeyChecking=yes
  -o ConnectTimeout=10
  -o ConnectionAttempts=1
)

case "$validation_root" in
  /home/ubuntu/ryan/vio_wire_trace_validation*) ;;
  *)
    echo "VIO_VALIDATION_ROOT must stay under /home/ubuntu/ryan/vio_wire_trace_validation" >&2
    exit 2
    ;;
esac

export SSHPASS="$VCS53_PASSWORD"
sshpass -e ssh "${ssh_options[@]}" "$ssh_target" \
  "mkdir -p '$validation_root/simflow'"

# 只同步编译所需源码；不使用 --delete，远端同名验证目录中的其他产物不会被删除。
sync_tree() {
  local source_dir="$1"
  local target_name="$2"

  sshpass -e rsync -a \
    --exclude=.git --exclude=build --exclude='__pycache__' --exclude='*.pyc' \
    -e "ssh ${ssh_options[*]}" \
    "$source_dir/" "$ssh_target:$validation_root/$target_name/"
}

sync_tree "$repo_root" virtio_work
sync_tree "$repo_root/../dpu_common" dpu_common
sync_tree "$repo_root/../host_mem" host_mem
sync_tree "$repo_root/../net_packet" net_packet
sync_tree "$repo_root/../pcie_work" pcie_work
sync_tree "$local_aip_root" aip_core_set_param_expr

sshpass -e rsync -a -e "ssh ${ssh_options[*]}" \
  "$repo_root/../simflow/__init__.py" \
  "$ssh_target:$validation_root/simflow/__init__.py"
sync_tree "$repo_root/../simflow/uvm_gen" simflow/uvm_gen

aip_rev="$(git -C "$local_aip_root" rev-parse HEAD)"
net_packet_rev="$(git -C "$repo_root/../net_packet" rev-parse HEAD)"

sshpass -e ssh "${ssh_options[@]}" "$ssh_target" \
  "VIO_VALIDATION_ROOT='$validation_root' AIP_CORE_ROOT='$validation_root/aip_core_set_param_expr' VIO_AIP_REV='$aip_rev' VIO_NET_PACKET_REV='$net_packet_rev' bash -ic 'cd \"$validation_root/virtio_work\" && ./scripts/test_vio_packet.sh --remote'"
