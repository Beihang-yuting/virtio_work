#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"

# 中文说明：bootstrap 只同步仍保留的 PCIe submodule，并检查项目外的
# dpu_common、net_packet、pcie_work、host_mem 和 queue_work 是否已经位于受支持的
# 外部 checkout；net_packet 明确跟随 origin/master，其余需要稳定回归的依赖固定版本；
# 它不复制或修改项目外的控制面、报文生成器、Host memory 或 PCIe VIP 源码。
dpu_common_revision="a595b5cb5ab0bf653975be68996b5d46deb5a63d"
net_packet_url="https://github.com/Beihang-yuting/net_packet.git"
pcie_work_revision="9aedf898f44ca260f3120a3fb162b7bb9fbafb5e"
host_mem_revision="365b7553fc7dac6b4ad55886a8e4869153607c28"
host_mem_url="https://github.com/Beihang-yuting/host_mem.git"
if [[ -z "${QUEUE_WORK_ROOT:-}" ]]; then
  QUEUE_WORK_ROOT="$(cd "$root_dir/../queue_work" 2>/dev/null && pwd || true)"
fi
if [[ -z "${QUEUE_WORK_ROOT:-}" ]]; then
  echo "QUEUE_WORK_ROOT must point to the external queue_work checkout" >&2
  exit 2
fi
queue_work_root="$(cd "$QUEUE_WORK_ROOT" 2>/dev/null && pwd)" || {
  echo "QUEUE_WORK_ROOT is not a readable directory: ${QUEUE_WORK_ROOT}" >&2
  exit 2
}
if [[ ! -f "$queue_work_root/src/gq/gq_pkg.sv" ||
      ! -f "$queue_work_root/integration/dpu_queue_resource_binder.sv" ]]; then
  echo "external queue_work checkout is missing GQ integration sources: $queue_work_root" >&2
  exit 2
fi
if [[ -z "${DPU_COMMON_ROOT:-}" ]]; then
  echo "DPU_COMMON_ROOT must point to the external dpu_common checkout" >&2
  exit 2
fi
dpu_common_root="$(cd "$DPU_COMMON_ROOT" 2>/dev/null && pwd)" || {
  echo "DPU_COMMON_ROOT is not a readable directory: ${DPU_COMMON_ROOT}" >&2
  exit 2
}
dpu_common_actual="$(git -C "$dpu_common_root" rev-parse HEAD 2>/dev/null || true)"
if [[ "$dpu_common_actual" != "$dpu_common_revision" ]]; then
  echo "dpu_common revision mismatch: expected $dpu_common_revision actual $dpu_common_actual" >&2
  exit 5
fi
if [[ -z "${NET_PACKET_ROOT:-}" ]]; then
  echo "NET_PACKET_ROOT must point to the external net_packet checkout" >&2
  exit 2
fi
if [[ -e "$root_dir/virtio_net_vip/ext/net_packet" ]]; then
  echo "local net_packet extension is forbidden; remove virtio_net_vip/ext/net_packet and use NET_PACKET_ROOT" >&2
  exit 7
fi
net_packet_root="$(cd "$NET_PACKET_ROOT" 2>/dev/null && pwd)" || {
  echo "NET_PACKET_ROOT is not a readable directory: ${NET_PACKET_ROOT}" >&2
  exit 2
}
if [[ "$net_packet_root" == "$root_dir"/* ]]; then
  echo "local net_packet checkout is forbidden; use external NET_PACKET_ROOT=$net_packet_root" >&2
  exit 7
fi
for source_file in \
    filelist.f \
    src/core/packet.sv \
    src/uvm_wrapper/packet_item.sv \
    src/uvm_wrapper/packet_sequence.sv \
    src/uvm_wrapper/protocol_seq_wrapper.sv; do
  if [[ ! -f "$net_packet_root/$source_file" ]]; then
    echo "external net_packet checkout is missing $source_file: $net_packet_root" >&2
    exit 2
  fi
done
net_packet_origin="$(git -C "$net_packet_root" remote get-url origin 2>/dev/null || true)"
if [[ "$net_packet_origin" != "$net_packet_url" ]]; then
  echo "net_packet origin mismatch: expected $net_packet_url actual $net_packet_origin" >&2
  exit 6
fi
net_packet_branch="$(git -C "$net_packet_root" symbolic-ref --short -q HEAD 2>/dev/null || true)"
if [[ "$net_packet_branch" != "master" ]]; then
  echo "net_packet checkout must be on remote master branch: actual ${net_packet_branch:-detached}" >&2
  exit 5
fi
net_packet_upstream="$(git -C "$net_packet_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
if [[ "$net_packet_upstream" != "origin/master" ]]; then
  echo "net_packet master must track origin/master: actual ${net_packet_upstream:-none}" >&2
  exit 5
fi
net_packet_actual="$(git -C "$net_packet_root" rev-parse HEAD 2>/dev/null || true)"
export NET_PACKET_ROOT="$net_packet_root"
if [[ -z "${PCIE_WORK_ROOT:-}" ]]; then
  echo "PCIE_WORK_ROOT must point to the external pcie_work checkout" >&2
  exit 2
fi
pcie_work_root="$(cd "$PCIE_WORK_ROOT" 2>/dev/null && pwd)" || {
  echo "PCIE_WORK_ROOT is not a readable directory: ${PCIE_WORK_ROOT}" >&2
  exit 2
}
pcie_work_actual="$(git -C "$pcie_work_root" rev-parse HEAD 2>/dev/null || true)"
if [[ "$pcie_work_actual" != "$pcie_work_revision" ]]; then
  echo "pcie_work revision mismatch: expected $pcie_work_revision actual $pcie_work_actual" >&2
  exit 5
fi

if [[ -z "${HOST_MEM_ROOT:-}" ]]; then
  echo "HOST_MEM_ROOT must point to the external host_mem checkout" >&2
  exit 2
fi
host_mem_root="$(cd "$HOST_MEM_ROOT" 2>/dev/null && pwd)" || {
  echo "HOST_MEM_ROOT is not a readable directory: ${HOST_MEM_ROOT}" >&2
  exit 2
}
if [[ "$host_mem_root" == "$root_dir"/* ]]; then
  echo "local host_mem checkout is forbidden; use external HOST_MEM_ROOT=$host_mem_root" >&2
  exit 7
fi
for source_file in \
    src/host_mem_pkg.sv \
    src/host_mem_manager.sv \
    src/host_mem_pool.sv \
    tb/host_mem_random_tb.sv; do
  if [[ ! -f "$host_mem_root/$source_file" ]]; then
    echo "external host_mem checkout is missing $source_file: $host_mem_root" >&2
    exit 2
  fi
done
host_mem_actual="$(git -C "$host_mem_root" rev-parse HEAD 2>/dev/null || true)"
if [[ "$host_mem_actual" != "$host_mem_revision" ]]; then
  echo "host_mem revision mismatch: expected $host_mem_revision actual $host_mem_actual" >&2
  exit 5
fi
host_mem_origin="$(git -C "$host_mem_root" remote get-url origin 2>/dev/null || true)"
if [[ "$host_mem_origin" != "$host_mem_url" ]]; then
  echo "host_mem origin mismatch: expected $host_mem_url actual $host_mem_origin" >&2
  exit 6
fi
export HOST_MEM_ROOT="$host_mem_root"

git -C "$root_dir" submodule sync --recursive
git -C "$root_dir" submodule status --recursive
echo "dpu_common=$dpu_common_revision (external: $dpu_common_root)"
echo "pcie_work=$pcie_work_revision (external: $pcie_work_root)"
echo "net_packet=$net_packet_actual (external master: $net_packet_root)"
echo "host_mem=$host_mem_revision (external: $host_mem_root)"
