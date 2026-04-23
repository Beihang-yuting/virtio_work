`ifndef VIRTIO_VF_INSTANCE_SV
`define VIRTIO_VF_INSTANCE_SV

// ============================================================================
// virtio_vf_instance
//
// Per-VF wrapper holding all virtio driver components. References
// pcie_tl_func_context (via uvm_object handle) for BDF/BAR -- no duplication
// of PCIe-level data.
//
// SR-IOV PF/VF management (BDF calculation, config space, BAR, VF
// enable/disable) is delegated to pcie_tl_vip's pcie_tl_func_manager.
// This class manages only virtio-specific concerns: queue mapping,
// driver lifecycle, and failover.
//
// Lifecycle:
//   VF_CREATED -> configure() -> VF_CONFIGURED -> init() -> VF_ACTIVE
//   VF_ACTIVE -> shutdown() -> VF_DISABLED
//   VF_ACTIVE -> on_flr() -> VF_FLR -> reinit_after_flr() -> VF_CONFIGURED
//
// Depends on:
//   - virtio_driver_agent, virtqueue_manager, virtio_net_dataplane
//   - virtio_pci_transport, virtio_atomic_ops, virtio_auto_fsm
//   - host_mem_manager, virtio_iommu_model, virtio_memory_barrier_model
//   - virtqueue_error_injector, virtio_wait_policy
//   - virtio_net_types.sv (vf_state_e, virtio_driver_config_t)
// ============================================================================

class virtio_vf_instance extends uvm_component;
    `uvm_component_utils(virtio_vf_instance)

    // ===== Identity (from pcie_tl_func_context) =====
    int unsigned         vf_index;
    bit [15:0]           bdf;          // copied from func_context for convenience

    // ===== PCIe context reference (not owned) =====
    // pcie_tl_func_context from func_manager -- provides BDF, BAR, config space
    // Stored as uvm_object to avoid hard package dependency
    uvm_object           pcie_ctx_ref;

    // ===== Virtio sub-components (owned) =====
    virtio_driver_agent       driver_agent;
    virtqueue_manager         vq_mgr;
    virtio_net_dataplane      dataplane;
    virtio_pci_transport      transport;

    // ===== Shared components (references, not owned) =====
    host_mem_manager          mem;
    virtio_iommu_model        iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector  err_inj;
    virtio_wait_policy        wait_pol;

    // ===== State =====
    vf_state_e                state = VF_CREATED;

    // ===== Driver config =====
    virtio_driver_config_t    drv_cfg;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ========================================================================
    // Build Phase
    //
    // Creates owned sub-components: driver_agent (uvm_component), and
    // vq_mgr, dataplane, transport (uvm_objects via factory).
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        driver_agent = virtio_driver_agent::type_id::create("driver_agent", this);
        vq_mgr       = virtqueue_manager::type_id::create("vq_mgr");
        dataplane    = virtio_net_dataplane::type_id::create("dataplane");
        transport    = virtio_pci_transport::type_id::create("transport");
    endfunction

    // ========================================================================
    // configure -- Configure with BDF/BAR from pcie_tl_func_context
    //
    // Called by the env after build_phase. Sets identity fields and wires
    // the transport and virtqueue manager with the VF's BDF and BAR base.
    // ========================================================================

    virtual function void configure(
        int unsigned vf_idx,
        bit [15:0]   device_bdf,
        bit [63:0]   bar_base,
        uvm_object   pcie_ctx     // pcie_tl_func_context
    );
        vf_index     = vf_idx;
        bdf          = device_bdf;
        pcie_ctx_ref = pcie_ctx;

        // Configure transport
        transport.bdf      = device_bdf;
        transport.is_vf    = 1;
        transport.vf_index = vf_idx;
        transport.bar.bar_base[0] = bar_base;
        transport.bar.requester_id = device_bdf;

        // Configure virtqueue manager
        vq_mgr.bdf = device_bdf;

        `uvm_info("VF_INSTANCE",
            $sformatf("configure: vf_index=%0d, bdf=0x%04h, bar_base=0x%016h",
                      vf_idx, device_bdf, bar_base),
            UVM_MEDIUM)
    endfunction

    // ========================================================================
    // wire_shared -- Wire shared components (called by env connect_phase)
    //
    // Injects references to shared infrastructure (memory, IOMMU, barriers,
    // error injector, wait policy, PCIe sequencer) into all sub-components.
    // Also creates and wires virtio_atomic_ops and virtio_auto_fsm.
    // ========================================================================

    virtual function void wire_shared(
        host_mem_manager          hmem,
        virtio_iommu_model        iommu_mdl,
        virtio_memory_barrier_model bar_mdl,
        virtqueue_error_injector  einj,
        virtio_wait_policy        wpol,
        uvm_sequencer #(uvm_sequence_item) pcie_rc_seqr
    );
        virtio_atomic_ops ops;
        virtio_auto_fsm   fsm;

        mem      = hmem;
        iommu    = iommu_mdl;
        barrier  = bar_mdl;
        err_inj  = einj;
        wait_pol = wpol;

        // Wire into virtqueue manager
        vq_mgr.mem     = hmem;
        vq_mgr.iommu   = iommu_mdl;
        vq_mgr.barrier = bar_mdl;
        vq_mgr.err_inj = einj;
        vq_mgr.wait_pol = wpol;

        // Wire into transport
        transport.wait_pol = wpol;
        transport.bar.pcie_rc_seqr = pcie_rc_seqr;
        transport.notify_mgr.bar   = transport.bar;
        transport.cap_mgr.bar_ref  = transport.bar;

        // Create and wire atomic_ops
        ops = virtio_atomic_ops::type_id::create(
            $sformatf("vf%0d_ops", vf_index));
        ops.transport = transport;
        ops.vq_mgr    = vq_mgr;
        ops.mem       = hmem;
        ops.iommu     = iommu_mdl;
        ops.wait_pol  = wpol;

        // Create and wire auto_fsm
        fsm = virtio_auto_fsm::type_id::create(
            $sformatf("vf%0d_fsm", vf_index));
        fsm.ops     = ops;
        fsm.drv_cfg = drv_cfg;

        // Wire into driver agent
        driver_agent.ops = ops;
        driver_agent.fsm = fsm;

        `uvm_info("VF_INSTANCE",
            $sformatf("wire_shared: vf_index=%0d wiring complete", vf_index),
            UVM_MEDIUM)
    endfunction

    // ========================================================================
    // Lifecycle: init
    //
    // Store driver config and mark VF as configured. The full device
    // initialization happens via sequence (VIO_TXN_INIT) driven through
    // the driver agent.
    // ========================================================================

    virtual task init(virtio_driver_config_t cfg);
        drv_cfg = cfg;
        state   = VF_CONFIGURED;

        `uvm_info("VF_INSTANCE",
            $sformatf("init: vf_index=%0d, state=%s, mode=%s, queue_pairs=%0d",
                      vf_index, state.name(), cfg.mode.name(),
                      cfg.num_queue_pairs),
            UVM_MEDIUM)
    endtask

    // ========================================================================
    // Lifecycle: shutdown
    //
    // Stops the dataplane (if active) and resets the device.
    // ========================================================================

    virtual task shutdown();
        `uvm_info("VF_INSTANCE",
            $sformatf("shutdown: vf_index=%0d, current state=%s",
                      vf_index, state.name()),
            UVM_MEDIUM)

        if (state == VF_ACTIVE) begin
            if (driver_agent.fsm != null)
                driver_agent.fsm.stop_dataplane();
        end

        if (driver_agent.ops != null)
            driver_agent.ops.device_reset();

        state = VF_DISABLED;

        `uvm_info("VF_INSTANCE",
            $sformatf("shutdown: vf_index=%0d complete, state=%s",
                      vf_index, state.name()),
            UVM_MEDIUM)
    endtask

    // ========================================================================
    // on_flr -- Function Level Reset cleanup
    //
    // Called when the PF manager initiates an FLR for this VF.
    // Detaches all queues and cleans up DMA state. Does NOT touch PCIe
    // registers -- the PCIe FLR itself is handled by pcie_tl_func_manager.
    // ========================================================================

    virtual function void on_flr();
        `uvm_info("VF_INSTANCE",
            $sformatf("on_flr: vf_index=%0d, current state=%s",
                      vf_index, state.name()),
            UVM_MEDIUM)

        // Detach all queues (release outstanding descriptors)
        vq_mgr.detach_all_queues();

        // Clean up dataplane state
        dataplane.cleanup_all();

        state = VF_FLR;

        `uvm_info("VF_INSTANCE",
            $sformatf("on_flr: vf_index=%0d complete, state=%s",
                      vf_index, state.name()),
            UVM_MEDIUM)
    endfunction

    // ========================================================================
    // reinit_after_flr -- Reinitialize VF after FLR completes
    //
    // Resets state to VF_CREATED and calls init() with the new config.
    // The actual device re-initialization happens via sequence.
    // ========================================================================

    virtual task reinit_after_flr(virtio_driver_config_t cfg);
        `uvm_info("VF_INSTANCE",
            $sformatf("reinit_after_flr: vf_index=%0d, current state=%s",
                      vf_index, state.name()),
            UVM_MEDIUM)

        state = VF_CREATED;
        init(cfg);
    endtask

    // ========================================================================
    // get_state -- Return current VF state
    // ========================================================================

    virtual function vf_state_e get_state();
        return state;
    endfunction

    // ========================================================================
    // set_active -- Mark VF as active (called after successful init sequence)
    // ========================================================================

    virtual function void set_active();
        if (state != VF_CONFIGURED) begin
            `uvm_warning("VF_INSTANCE",
                $sformatf("set_active: vf_index=%0d unexpected state=%s (expected VF_CONFIGURED)",
                          vf_index, state.name()))
        end
        state = VF_ACTIVE;
    endfunction

endclass : virtio_vf_instance

`endif // VIRTIO_VF_INSTANCE_SV
