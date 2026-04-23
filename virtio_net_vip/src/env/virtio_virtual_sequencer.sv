`ifndef VIRTIO_VIRTUAL_SEQUENCER_SV
`define VIRTIO_VIRTUAL_SEQUENCER_SV

// ============================================================================
// virtio_virtual_sequencer
//
// Top-level virtual sequencer that aggregates per-VF sequencers and provides
// access to shared component references for virtual sequences.
//
// Virtual sequences targeting multiple VFs or coordinating cross-VF
// operations use this sequencer. It holds:
//   - Per-VF driver sequencers (for sending virtio_transactions)
//   - PCIe RC sequencer (for direct TLP operations)
//   - References to shared components (PF manager, IOMMU, host memory)
//
// All references are wired by virtio_net_env in connect_phase.
//
// Depends on:
//   - virtio_sequencer (per-VF sequencer)
// ============================================================================

class virtio_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(virtio_virtual_sequencer)

    // ===== Per-VF sequencers =====
    virtio_sequencer  vf_seqrs[];

    // ===== PCIe RC sequencer (for direct TLP operations) =====
    uvm_sequencer #(uvm_sequence_item) pcie_rc_seqr;

    // ===== Shared component refs (for virtual sequences that need them) =====
    uvm_object  pf_mgr_ref;       // virtio_pf_manager
    uvm_object  iommu_ref;        // virtio_iommu_model
    uvm_object  host_mem_ref;     // host_mem_manager

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

endclass : virtio_virtual_sequencer

`endif // VIRTIO_VIRTUAL_SEQUENCER_SV
