`ifndef VIRTIO_DRIVER_AGENT_SV
`define VIRTIO_DRIVER_AGENT_SV

// ============================================================================
// virtio_driver_agent
//
// UVM agent that instantiates and connects:
//   - virtio_driver    (active mode only) -- drives transactions
//   - virtio_sequencer (active mode only) -- arbitrates sequences
//   - virtio_monitor   (always)           -- passive protocol observation
//
// The agent receives shared component references (ops, fsm) from the env
// before build_phase and injects them into the driver during connect_phase.
//
// Usage:
//   - Set is_active via uvm_config_db or agent config before build_phase
//   - Assign ops and fsm from the env before connect_phase
//   - Connect monitor.transport and monitor.vq_mgr from the env
//
// Depends on:
//   - virtio_driver, virtio_monitor, virtio_sequencer
//   - virtio_atomic_ops, virtio_auto_fsm
// ============================================================================

class virtio_driver_agent extends uvm_agent;
    `uvm_component_utils(virtio_driver_agent)

    // ===== Sub-components =====
    virtio_driver       driver;
    virtio_monitor      monitor;
    virtio_pcie_observer_adapter observer;
    virtio_sequencer    sequencer;

    // ===== Shared component references (set by env before build) =====
    virtio_atomic_ops   ops;
    virtio_auto_fsm     fsm;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ========================================================================
    // Build Phase
    //
    // Always creates the monitor. In active mode, also creates the driver
    // and sequencer.
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Monitor is always present (passive observation)
        monitor = virtio_monitor::type_id::create("monitor", this);
        observer = virtio_pcie_observer_adapter::type_id::create("observer", this);

        // Driver and sequencer only in active mode
        if (get_is_active() == UVM_ACTIVE) begin
            driver    = virtio_driver::type_id::create("driver", this);
            sequencer = virtio_sequencer::type_id::create("sequencer", this);
        end
    endfunction

    // ========================================================================
    // Apply the latest shared references to the active driver and monitor.
    // This is invoked again at start_of_simulation so parent connect_phase
    // late bindings are propagated after child connect_phase has completed.
    // ========================================================================

    function void apply_component_bindings();
        if (get_is_active() == UVM_ACTIVE) begin
            if (ops != null)
                driver.ops = ops;
            if (fsm != null)
                driver.fsm = fsm;
        end

        if (ops != null) begin
            if (monitor.transport == null && ops.transport != null)
                monitor.transport = ops.transport;
            if (monitor.vq_mgr == null && ops.vq_mgr != null)
                monitor.vq_mgr = ops.vq_mgr;
            monitor.negotiated_features = ops.negotiated_features;
        end
        observer.monitor = monitor;
    endfunction

    // ========================================================================
    // Connect Phase
    //
    // Connects the active driver to its sequencer, then applies the shared
    // component references available at this phase.
    // ========================================================================

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);

        apply_component_bindings();
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        if (get_is_active() == UVM_ACTIVE) begin
            apply_component_bindings();
            if ((driver == null) || (driver.ops == null))
                `uvm_error("VIRTIO_AGENT",
                    "active driver has no virtio_atomic_ops binding")
            if ((driver == null) || (driver.fsm == null))
                `uvm_error("VIRTIO_AGENT",
                    "active driver has no virtio_auto_fsm binding")
        end
    endfunction

endclass : virtio_driver_agent

`endif // VIRTIO_DRIVER_AGENT_SV
