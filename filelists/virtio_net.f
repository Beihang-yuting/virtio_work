// All paths are relative to the repository root.
// host_mem@ef056b3 and net_packet@e2af702 have no SystemVerilog sources at
// their pinned revisions, so they deliberately contribute no paths here.

// PCIe TL VIP: interface before the package that uses it.
+incdir+virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src
virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src/pcie_tl_if.sv
virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src/pcie_tl_pkg.sv

// Local virtio-net package; it includes its sources in dependency order.
+incdir+virtio_net_vip/src
virtio_net_vip/src/virtio_net_pkg.sv
