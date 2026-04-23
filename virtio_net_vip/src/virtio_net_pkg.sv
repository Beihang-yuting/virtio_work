// =============================================================================
// virtio_net_pkg.sv
// Top-level package for the virtio-net UVM VIP.
//
// Import order: uvm_pkg, then external packages, then local sources in
// dependency order (types → shared → iommu → virtqueue → transport →
// callbacks/transactions/agent → dataplane → sriov → env → sequences).
// =============================================================================

`ifndef VIRTIO_NET_PKG_SV
`define VIRTIO_NET_PKG_SV

package virtio_net_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import host_mem_pkg::*;

  // ---------------------------------------------------------------------------
  // Phase 1 – Types and shared utilities
  // ---------------------------------------------------------------------------
  // `include "types/virtio_net_types.sv"
  // `include "types/virtio_net_config.sv"
  // `include "shared/virtio_net_utils.sv"

  // ---------------------------------------------------------------------------
  // Phase 2 – IOMMU model
  // ---------------------------------------------------------------------------
  // `include "iommu/virtio_iommu_model.sv"

  // ---------------------------------------------------------------------------
  // Phase 3 – Virtqueue engine
  // ---------------------------------------------------------------------------
  // `include "virtqueue/virtio_desc_table.sv"
  // `include "virtqueue/virtio_avail_ring.sv"
  // `include "virtqueue/virtio_used_ring.sv"
  // `include "virtqueue/virtio_virtqueue.sv"

  // ---------------------------------------------------------------------------
  // Phase 4 – Transport (MMIO / PCI)
  // ---------------------------------------------------------------------------
  // `include "transport/virtio_transport_base.sv"
  // `include "transport/virtio_mmio_transport.sv"
  // `include "transport/virtio_pci_transport.sv"

  // ---------------------------------------------------------------------------
  // Phase 5 – Callbacks, transactions, and agent
  // ---------------------------------------------------------------------------
  // `include "callbacks/virtio_net_callbacks.sv"
  // `include "agent/virtio_net_seq_item.sv"
  // `include "agent/virtio_net_driver.sv"
  // `include "agent/virtio_net_monitor.sv"
  // `include "agent/virtio_net_sequencer.sv"
  // `include "agent/virtio_net_agent.sv"

  // ---------------------------------------------------------------------------
  // Phase 6 – Dataplane
  // ---------------------------------------------------------------------------
  // `include "dataplane/virtio_net_tx_engine.sv"
  // `include "dataplane/virtio_net_rx_engine.sv"
  // `include "dataplane/virtio_net_dataplane.sv"

  // ---------------------------------------------------------------------------
  // Phase 7 – SR-IOV
  // ---------------------------------------------------------------------------
  // `include "sriov/virtio_sriov_cfg.sv"
  // `include "sriov/virtio_sriov_agent.sv"

  // ---------------------------------------------------------------------------
  // Phase 8 – Environment
  // ---------------------------------------------------------------------------
  // `include "env/virtio_net_scoreboard.sv"
  // `include "env/virtio_net_coverage.sv"
  // `include "env/virtio_net_env.sv"

  // ---------------------------------------------------------------------------
  // Phase 9 – Sequences
  // ---------------------------------------------------------------------------
  // Base sequences
  // `include "seq/base/virtio_net_base_seq.sv"

  // Lifecycle scenario sequences
  // `include "seq/scenario/lifecycle/virtio_net_init_seq.sv"
  // `include "seq/scenario/lifecycle/virtio_net_reset_seq.sv"

  // Dataplane scenario sequences
  // `include "seq/scenario/dataplane/virtio_net_tx_seq.sv"
  // `include "seq/scenario/dataplane/virtio_net_rx_seq.sv"

  // Interrupt scenario sequences
  // `include "seq/scenario/interrupt/virtio_net_intr_seq.sv"

  // Migration scenario sequences
  // `include "seq/scenario/migration/virtio_net_migrate_seq.sv"

  // SR-IOV scenario sequences
  // `include "seq/scenario/sriov/virtio_net_sriov_seq.sv"

  // Error scenario sequences
  // `include "seq/scenario/error/virtio_net_error_seq.sv"

  // Concurrency scenario sequences
  // `include "seq/scenario/concurrency/virtio_net_concur_seq.sv"

  // Dynamic scenario sequences
  // `include "seq/scenario/dynamic/virtio_net_dynamic_seq.sv"

  // Boundary scenario sequences
  // `include "seq/scenario/boundary/virtio_net_boundary_seq.sv"

  // Virtual sequences
  // `include "seq/virtual/virtio_net_vseq.sv"

endpackage : virtio_net_pkg

`endif // VIRTIO_NET_PKG_SV
