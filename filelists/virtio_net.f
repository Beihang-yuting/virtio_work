// All paths are relative to the repository root.
// Compile host_mem_pkg before the PCIe package that imports it. The
// virtio-net package includes host_mem_manager.sv and host_mem_pool.sv in its
// own package scope; the pool must be visible before env configuration.
// net_packet is sourced only from the external NET_PACKET_ROOT checkout.

// net_packet is an external, independently versioned checkout.  Its UVM
// wrappers are included inside virtio_net_pkg so packet_item is visible to
// package-scoped dataplane classes without creating a second global copy.
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

+incdir+$HOST_MEM_ROOT/src
$HOST_MEM_ROOT/src/host_mem_pkg.sv

// PCIe TL VIP is an external checkout.  Keep the interface and package
// compile order explicit so this project cannot silently fall back to the
// historical local copy under virtio_net_vip/ext/pcie_tl_vip.
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
