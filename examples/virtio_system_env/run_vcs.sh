#!/usr/bin/env bash
# 目录层次：examples/virtio_system_env。示例源文件已随 filelists/tests.f 编译
# （私有环流程测试继承它），本脚本只负责运行不在维护清单中的示例测试。依赖仓库
# 脚本完成依赖校验，编译产物保存在 build/examples/virtio_system_env。
set -euo pipefail

example_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$example_dir/../.." && pwd)"

source "$root_dir/scripts/test_manifest.sh"
"$root_dir/scripts/check_deps.sh"

if [[ -z "${VCS_HOME:-}" || ! -x "$VCS_HOME/bin/vcs" ]]; then
  echo "VCS_HOME must point to an installed VCS before running this example" >&2
  exit 3
fi

compile_only=0
case "$#" in
  0) ;;
  1)
    if [[ "$1" != "--compile-only" ]]; then
      echo "usage: $0 [--compile-only]" >&2
      exit 2
    fi
    compile_only=1
    ;;
  *)
    echo "usage: $0 [--compile-only]" >&2
    exit 2
    ;;
esac

cd "$root_dir"
mkdir -p build/examples/virtio_system_env
simv="$root_dir/build/examples/virtio_system_env/simv"

"$VCS_HOME/bin/vcs" \
  -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f "$root_dir/filelists/dpu_common.f" \
  -f "$root_dir/filelists/virtio_net.f" \
  -f "$root_dir/filelists/queue_work_integration.f" \
  -f "$root_dir/filelists/tests.f" \
  -top virtio_tb_top -o "$simv"

if (( !compile_only )); then
  "$simv" +UVM_TESTNAME=virtio_system_env_example_test \
    +UVM_VERBOSITY="${UVM_VERBOSITY:-UVM_LOW}"
fi
