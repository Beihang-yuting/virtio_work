// =============================================================================
// virtio_net_pkg.sv
// Top-level package for the virtio-net UVM VIP.
//
// Import order: uvm_pkg, then external packages, then local sources in
// dependency order (types -> shared -> iommu -> virtqueue -> transport ->
// callbacks/transactions/agent -> dataplane -> sriov -> env -> sequences).
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
  `include "types/virtio_net_types.sv"
  `include "types/virtio_net_hdr.sv"
  `include "shared/virtio_wait_policy.sv"
  `include "shared/virtio_memory_barrier_model.sv"

  // ---------------------------------------------------------------------------
  // Phase 2 – IOMMU model
  // ---------------------------------------------------------------------------
  `include "iommu/virtio_iommu_model.sv"

  // ---------------------------------------------------------------------------
  // Phase 3 – Virtqueue engine
  // ---------------------------------------------------------------------------
  `include "virtqueue/virtqueue_error_injector.sv"
  `include "virtqueue/virtqueue_base.sv"
  `include "virtqueue/split_virtqueue.sv"
  `include "virtqueue/packed_virtqueue.sv"
  `include "virtqueue/custom_virtqueue.sv"
  `include "virtqueue/virtqueue_manager.sv"

  // ---------------------------------------------------------------------------
  // Phase 4 – Transport (PCI)
  // ---------------------------------------------------------------------------
  `include "transport/virtio_pci_regs.sv"
  `include "transport/virtio_pci_cap_manager.sv"
  `include "transport/virtio_bar_accessor.sv"
  `include "transport/virtio_notification_manager.sv"
  `include "transport/virtio_pci_transport.sv"

  // ---------------------------------------------------------------------------
  // Phase 5 – Callbacks, transactions, and agent
  // ---------------------------------------------------------------------------
  `include "callbacks/virtio_dataplane_callback.sv"
  `include "callbacks/virtio_scoreboard_callback.sv"
  `include "callbacks/virtio_coverage_callback.sv"
  `include "types/virtio_transaction.sv"
  `include "agent/virtio_atomic_ops.sv"
  `include "agent/virtio_auto_fsm.sv"
  `include "agent/virtio_driver.sv"
  `include "agent/virtio_monitor.sv"
  `include "agent/virtio_sequencer.sv"
  `include "agent/virtio_driver_agent.sv"

  // ---------------------------------------------------------------------------
  // Phase 6 – Dataplane
  // ---------------------------------------------------------------------------
  `include "dataplane/virtio_csum_engine.sv"
  `include "dataplane/virtio_tso_engine.sv"
  `include "dataplane/virtio_uso_engine.sv"
  `include "dataplane/virtio_rss_engine.sv"
  `include "dataplane/virtio_offload_engine.sv"
  `include "dataplane/virtio_tx_engine.sv"
  `include "dataplane/virtio_rx_engine.sv"
  `include "dataplane/virtio_failover_manager.sv"
  `include "dataplane/virtio_net_dataplane.sv"

  // ---------------------------------------------------------------------------
  // Phase 7 – SR-IOV
  // ---------------------------------------------------------------------------
  `include "sriov/virtio_vf_resource_pool.sv"
  `include "sriov/virtio_vf_instance.sv"
  `include "sriov/virtio_pf_manager.sv"

  // ---------------------------------------------------------------------------
  // Phase 8 – Environment
  // ---------------------------------------------------------------------------
  `include "env/virtio_net_env_config.sv"
  `include "env/virtio_virtual_sequencer.sv"
  `include "env/virtio_scoreboard.sv"
  `include "env/virtio_coverage.sv"
  `include "env/virtio_perf_monitor.sv"
  `include "env/virtio_concurrency_controller.sv"
  `include "env/virtio_dynamic_reconfig.sv"
  `include "env/virtio_net_env.sv"

  // ---------------------------------------------------------------------------
  // Phase 9 – Sequences
  // ---------------------------------------------------------------------------

  // Base sequences
  `include "seq/base/virtio_base_seq.sv"
  `include "seq/base/virtio_init_seq.sv"
  `include "seq/base/virtio_tx_seq.sv"
  `include "seq/base/virtio_rx_seq.sv"
  `include "seq/base/virtio_ctrl_seq.sv"
  `include "seq/base/virtio_queue_setup_seq.sv"
  `include "seq/base/virtio_kick_seq.sv"

  // Lifecycle scenario sequences
  `include "seq/scenario/lifecycle/virtio_lifecycle_full_seq.sv"
  `include "seq/scenario/lifecycle/virtio_status_error_seq.sv"
  `include "seq/scenario/lifecycle/virtio_feature_error_seq.sv"

  // Dataplane scenario sequences
  `include "seq/scenario/dataplane/virtio_tso_seq.sv"
  `include "seq/scenario/dataplane/virtio_mrg_rxbuf_seq.sv"
  `include "seq/scenario/dataplane/virtio_rss_distribution_seq.sv"
  `include "seq/scenario/dataplane/virtio_csum_offload_seq.sv"
  `include "seq/scenario/dataplane/virtio_tunnel_pkt_seq.sv"

  // Interrupt scenario sequences
  `include "seq/scenario/interrupt/virtio_adaptive_irq_seq.sv"
  `include "seq/scenario/interrupt/virtio_event_idx_boundary_seq.sv"

  // Migration scenario sequences
  `include "seq/scenario/migration/virtio_live_migration_seq.sv"
  `include "seq/scenario/migration/virtio_failover_seq.sv"

  // SR-IOV scenario sequences
  `include "seq/scenario/sriov/virtio_multi_vf_init_seq.sv"
  `include "seq/scenario/sriov/virtio_vf_flr_isolation_seq.sv"
  `include "seq/scenario/sriov/virtio_mixed_vq_type_seq.sv"

  // Error scenario sequences
  `include "seq/scenario/error/virtio_desc_error_seq.sv"
  `include "seq/scenario/error/virtio_iommu_fault_seq.sv"
  `include "seq/scenario/error/virtio_pcie_cross_error_seq.sv"
  `include "seq/scenario/error/virtio_bad_packet_seq.sv"

  // Concurrency scenario sequences
  `include "seq/scenario/concurrency/virtio_concurrent_vf_traffic_seq.sv"

  // Dynamic scenario sequences
  `include "seq/scenario/dynamic/virtio_live_mq_resize_seq.sv"

  // Boundary scenario sequences
  `include "seq/scenario/boundary/virtio_boundary_seq.sv"

  // Virtual sequences
  `include "seq/virtual/virtio_smoke_vseq.sv"
  `include "seq/virtual/virtio_full_init_traffic_vseq.sv"
  `include "seq/virtual/virtio_multi_vf_vseq.sv"
  `include "seq/virtual/virtio_stress_vseq.sv"

endpackage : virtio_net_pkg

`endif // VIRTIO_NET_PKG_SV
