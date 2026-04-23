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

        // Driver and sequencer only in active mode
        if (get_is_active() == UVM_ACTIVE) begin
            driver    = virtio_driver::type_id::create("driver", this);
            sequencer = virtio_sequencer::type_id::create("sequencer", this);
        end
    endfunction

    // ========================================================================
    // Connect Phase
    //
    // Connects driver to sequencer and injects shared component references
    // into the driver and monitor.
    // ========================================================================

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (get_is_active() == UVM_ACTIVE) begin
            // Connect driver's seq_item_port to sequencer's export
            driver.seq_item_port.connect(sequencer.seq_item_export);

            // Inject shared component references into driver
            if (ops != null)
                driver.ops = ops;
            else
                `uvm_warning("VIRTIO_AGENT",
                    "ops handle is null -- driver will not function correctly")

            if (fsm != null)
                driver.fsm = fsm;
            else
                `uvm_warning("VIRTIO_AGENT",
                    "fsm handle is null -- driver AUTO-mode transactions will fail")
        end

        // Inject transport and vq_mgr references into monitor
        // These are typically set by the env after agent construction:
        //   agent.monitor.transport = env.transport;
        //   agent.monitor.vq_mgr   = env.vq_mgr;
        if (ops != null) begin
            if (monitor.transport == null && ops.transport != null)
                monitor.transport = ops.transport;
            if (monitor.vq_mgr == null && ops.vq_mgr != null)
                monitor.vq_mgr = ops.vq_mgr;
            monitor.negotiated_features = ops.negotiated_features;
        end
    endfunction

endclass : virtio_driver_agent

`endif // VIRTIO_DRIVER_AGENT_SV
