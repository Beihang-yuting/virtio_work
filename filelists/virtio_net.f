// All paths are relative to the repository root.
// Compile host_mem_pkg before the PCIe package that imports it. The
// virtio-net package includes host_mem_manager.sv in its own package scope.
// The pinned net_packet revision currently contributes no SystemVerilog sources.

+incdir+virtio_net_vip/ext/host_mem/src
virtio_net_vip/ext/host_mem/src/host_mem_pkg.sv

// PCIe TL VIP: interface before the package that uses it.
+incdir+virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src
virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src/pcie_tl_if.sv
virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src/pcie_tl_pkg.sv

// Local virtio-net package; it includes its sources in dependency order.
+incdir+virtio_net_vip/src
virtio_net_vip/src/virtio_net_pkg.sv
