// 目录层次：filelists。外部 package 各编译一次，顺序为 net_packet、Host memory、
// PCIe，最后编译本地 virtio_net_pkg；相同源码不可再以旧 filelist 或文本 include
// 重复加入，否则 packet_item/host_mem_manager 会出现不同的类型身份。
// NET_PACKET_ROOT 与 HOST_MEM_ROOT 由依赖检查解析，调用者管理其 checkout。
+define+UVM
+incdir+$NET_PACKET_ROOT/src
+incdir+$NET_PACKET_ROOT/src/common
+incdir+$NET_PACKET_ROOT/src/protocols
+incdir+$NET_PACKET_ROOT/src/protocols/l2
+incdir+$NET_PACKET_ROOT/src/protocols/l3
+incdir+$NET_PACKET_ROOT/src/protocols/l4
+incdir+$NET_PACKET_ROOT/src/protocols/tunnel
+incdir+$NET_PACKET_ROOT/src/protocols/rdma
+incdir+$NET_PACKET_ROOT/src/protocols/storage
+incdir+$NET_PACKET_ROOT/src/protocols/app
+incdir+$NET_PACKET_ROOT/src/core
+incdir+$NET_PACKET_ROOT/src/parser
+incdir+$NET_PACKET_ROOT/src/sequence
+incdir+$NET_PACKET_ROOT/src/stream
+incdir+$NET_PACKET_ROOT/src/uvm_wrapper
$NET_PACKET_ROOT/src/net_packet_pkg.sv

+incdir+$HOST_MEM_ROOT/src
$HOST_MEM_ROOT/src/host_mem_pkg.sv

// PCIe TL VIP is an external checkout. Keep the interface and package compile
// order explicit so this project cannot silently fall back to a local copy.
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/types
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/shared
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/agent
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/env
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/adapter
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/seq/base
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/seq/constraints
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/seq/scenario
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/seq/virtual
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/switch
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/topology

$PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_if.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/topology/pcie_topology_pkg.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_pkg.sv

// Local virtio-net package; it includes its sources in dependency order.
+incdir+virtio_net_vip/src
+incdir+virtio_net_vip/src/pcie
virtio_net_vip/src/agent/virtio_protocol_event_if.sv
virtio_net_vip/src/virtio_net_pkg.sv
virtio_net_vip/src/agent/virtio_protocol_assertions.sv
