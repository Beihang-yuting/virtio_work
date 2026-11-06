#!/usr/bin/env bash
# scripts：可选 AIP 开发验证入口。显式编译调用方指定的跨仓库工作树，
# 不修改旧回归的固定依赖版本门；产物属于 build/aip，日志采用既有严格检查。
# VCS 验证请在 10.11.10.53 上 source ~/.bashrc 后运行；密码不写入脚本。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
export DPU_COMMON_ROOT="${DPU_COMMON_ROOT:-$root_dir/../dpu_common}"
export NET_PACKET_ROOT="${NET_PACKET_ROOT:-$root_dir/../net_packet}"
export HOST_MEM_ROOT="${HOST_MEM_ROOT:-$root_dir/../host_mem}"
export PCIE_WORK_ROOT="${PCIE_WORK_ROOT:-$root_dir/../pcie_work}"
: "${AIP_CORE_ROOT:?请指定 aip_core/update 的 checkout 根目录}"
: "${VCS_HOME:?请先加载仿真主机的 VCS 环境}"
export AIP_CORE_ROOT
# AIP 的 Tcl 模块加载器使用 AIP_CORE；与 SV/filelist 的根保持一致。
export AIP_CORE="$AIP_CORE_ROOT"

for source_file in \
  "$AIP_CORE_ROOT/src/sv/aip_core_pkg.sv" \
  "$DPU_COMMON_ROOT/src/dpu_aip_params.svh" \
  "$NET_PACKET_ROOT/src/net_packet_pkg.sv" \
  "$HOST_MEM_ROOT/src/host_mem_pkg.sv" \
  "$PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_pkg.sv"; do
  if [[ ! -f "$source_file" ]]; then
    echo "缺少 AIP 集成所需源码：$source_file" >&2
    exit 2
  fi
done
if [[ ! -x "$VCS_HOME/bin/vcs" ]]; then
  echo "VCS 不可执行：$VCS_HOME/bin/vcs" >&2
  exit 2
fi

compile_only=0
if [[ "${1:-}" == "--compile-only" ]]; then
  compile_only=1
  shift
fi
test_name="${TEST:-virtio_aip_params_test}"
if [[ ! "$test_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
  echo "非法 TEST 类名：$test_name" >&2
  exit 2
fi
build_dir="$root_dir/build/aip"
mkdir -p "$build_dir"
cd "$root_dir"

"$VCS_HOME/bin/vcs" -full64 -sverilog -ntb_opts uvm-1.2 \
  -timescale=1ns/1ps -debug_access+all \
  -f filelists/aip_integration.f -f filelists/aip_tests.f \
  -top virtio_tb_top -Mdir="$build_dir/csrc" -o "$build_dir/simv" \
  -l "$build_dir/compile.log"
"$script_dir/strict_log_check.sh" compile "$build_dir/compile.log"
if (( compile_only )); then
  exit 0
fi

sim_args=(-exitstatus "+UVM_TESTNAME=$test_name" "+UVM_VERBOSITY=${UVM_VERBOSITY:-UVM_LOW}")
if [[ -n "${TCL_CASE:-}" ]]; then
  if [[ ! -f "$TCL_CASE" ]]; then
    echo "TCL_CASE 文件不存在：$TCL_CASE" >&2
    exit 2
  fi
  sim_args+=(-ucli -do "$TCL_CASE")
fi
"$build_dir/simv" "${sim_args[@]}" "$@" -l "$build_dir/$test_name.log"
"$script_dir/strict_log_check.sh" sim "$build_dir/$test_name.log"
