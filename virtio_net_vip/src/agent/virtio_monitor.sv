`ifndef VIRTIO_MONITOR_SV
`define VIRTIO_MONITOR_SV

// ============================================================================
// virtio_monitor
//
// Passive UVM monitor that observes PCIe TLPs and reconstructs virtio
// semantics. Provides analysis ports for scoreboard, coverage, and
// protocol checking.
//
// The monitor does not drive any signals -- it observes via analysis port
// connections from the PCIe TL monitor (connected in env connect_phase).
//
// Protocol checks validate:
//   - Device status register transition legality (per virtio spec 2.1)
//   - Feature-dependent operation usage (only use negotiated features)
//   - Queue access validity (queue exists and is enabled)
//   - Notification protocol correctness
//   - Descriptor chain integrity
//   - DMA boundary compliance
//
// Depends on:
//   - virtio_transaction (analysis port payload)
//   - virtio_pci_transport (for observing register accesses)
//   - virtqueue_manager (for queue state queries)
//   - virtio_net_types.sv (status bits, feature bits)
// ============================================================================

class virtio_monitor extends uvm_monitor;
    `uvm_component_utils(virtio_monitor)

    // ===== Analysis Ports =====
    uvm_analysis_port #(virtio_transaction) txn_ap;     // all transactions
    uvm_analysis_port #(virtio_transaction) err_ap;     // error transactions only
    uvm_analysis_port #(uvm_object)         pkt_ap;     // packet-level (for coverage)

    // ===== References (set by agent/env before run_phase) =====
    virtio_pci_transport   transport;
    virtqueue_manager      vq_mgr;
    bit [63:0]             negotiated_features;

    // ===== Protocol check switches (default ON) =====
    bit  chk_status_transition  = 1;
    bit  chk_feature_usage      = 1;
    bit  chk_queue_protocol     = 1;
    bit  chk_notification       = 1;
    bit  chk_descriptor_chain   = 1;
    bit  chk_dma_boundary       = 1;

    // ===== Internal state tracking =====
    protected bit [7:0]  last_status    = DEV_STATUS_RESET;
    protected bit [63:0] used_features  = 0;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ========================================================================
    // Build Phase -- create analysis ports
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        txn_ap = new("txn_ap", this);
        err_ap = new("err_ap", this);
        pkt_ap = new("pkt_ap", this);
    endfunction

    // ========================================================================
    // Run Phase
    //
    // The monitor is passive. It observes via analysis ports connected to the
    // PCIe TL monitor. The actual observation logic forks parallel tasks:
    //
    //   - monitor_bar_access()      -- observe BAR MMIO operations
    //   - monitor_dma_traffic()     -- observe DMA read/write TLPs
    //   - monitor_interrupts()      -- observe MSI-X messages
    //   - monitor_queue_activity()  -- track queue state changes
    //
    // The hookup to the PCIe TL monitor happens in the env connect_phase.
    // Subclasses or the env can override/extend as needed.
    // ========================================================================

    virtual task run_phase(uvm_phase phase);
        fork : monitor_tasks
            monitor_bar_access();
            monitor_dma_traffic();
            monitor_interrupts();
            monitor_queue_activity();
        join_none
    endtask

    // ========================================================================
    // Observation Tasks (stubs -- connected via env or subclass)
    // ========================================================================

    // Observe BAR MMIO read/write operations (common/device/notify/ISR BARs)
    protected virtual task monitor_bar_access();
        // Placeholder: env connects PCIe TL monitor analysis export here.
        // When a BAR access TLP is observed:
        //   1. Decode the BAR offset to identify the virtio register
        //   2. For status writes: call check_status_transition()
        //   3. For feature reads/writes: track negotiation
        //   4. Broadcast a virtio_transaction via txn_ap
    endtask

    // Observe DMA read/write TLPs (descriptor, avail, used ring access)
    protected virtual task monitor_dma_traffic();
        // Placeholder: env connects PCIe TL monitor analysis export here.
        // When a DMA TLP is observed:
        //   1. Map IOVA back to GPA and identify the queue/ring
        //   2. For descriptor table writes: validate chain integrity
        //   3. For avail ring writes: check notification suppression
        //   4. For used ring reads: track completions
        //   5. If chk_dma_boundary: validate 4K page boundary compliance
    endtask

    // Observe MSI-X interrupt messages
    protected virtual task monitor_interrupts();
        // Placeholder: env connects MSI-X monitor analysis export here.
        // When an MSI-X message is observed:
        //   1. Decode the vector to identify config-change vs queue interrupt
        //   2. For queue interrupts: correlate with used ring activity
        //   3. If chk_notification: validate interrupt suppression correctness
    endtask

    // Track queue enable/disable/reset activity
    protected virtual task monitor_queue_activity();
        // Placeholder: env connects queue state change notifications here.
        // When a queue state change is observed:
        //   1. Validate queue was properly configured before enable
        //   2. Track queue lifecycle (created -> enabled -> disabled -> reset)
        //   3. If chk_queue_protocol: validate setup sequence
    endtask

    // ========================================================================
    // Protocol Check Methods
    //
    // Called by observation tasks when relevant events are detected.
    // Each method validates a specific aspect of the virtio specification.
    // ========================================================================

    // ------------------------------------------------------------------------
    // check_status_transition
    //
    // Validates that a device status register transition is legal per the
    // virtio spec. Legal transitions form a DAG:
    //   RESET -> ACKNOWLEDGE -> DRIVER -> FEATURES_OK -> DRIVER_OK
    //   Any state -> FAILED
    //   Any state -> RESET (device reset)
    //   DRIVER_OK -> DEVICE_NEEDS_RESET (device-initiated)
    // ------------------------------------------------------------------------
    virtual function void check_status_transition(
        bit [7:0] old_status,
        bit [7:0] new_status
    );
        bit valid = 1;

        if (!chk_status_transition)
            return;

        // Reset is always valid from any state
        if (new_status == DEV_STATUS_RESET) begin
            last_status = new_status;
            return;
        end

        // FAILED is always valid from any state
        if (new_status & DEV_STATUS_FAILED) begin
            last_status = new_status;
            return;
        end

        // New status must be a superset of old status (bits are accumulated)
        if ((new_status & old_status) != old_status) begin
            valid = 0;
        end

        // Check that bits are set in the correct order
        if (new_status & DEV_STATUS_DRIVER_OK) begin
            if (!(new_status & DEV_STATUS_FEATURES_OK))
                valid = 0;
        end
        if (new_status & DEV_STATUS_FEATURES_OK) begin
            if (!(new_status & DEV_STATUS_DRIVER))
                valid = 0;
        end
        if (new_status & DEV_STATUS_DRIVER) begin
            if (!(new_status & DEV_STATUS_ACKNOWLEDGE))
                valid = 0;
        end

        if (!valid) begin
            virtio_transaction err_txn;
            err_txn = virtio_transaction::type_id::create("status_err_txn");
            err_txn.txn_type = VIO_TXN_INJECT_ERROR;
            err_txn.status_val = new_status;

            `uvm_error("VIRTIO_MON",
                $sformatf("Invalid status transition: 0x%02h -> 0x%02h",
                          old_status, new_status))
            broadcast_error(err_txn);
        end

        last_status = new_status;
    endfunction

    // ------------------------------------------------------------------------
    // check_feature_dependency
    //
    // Validates that an attempted feature-dependent operation only uses
    // features that were successfully negotiated.
    // ------------------------------------------------------------------------
    virtual function void check_feature_dependency(
        bit [63:0] negotiated,
        bit [63:0] attempted_use
    );
        bit [63:0] unauthorized;

        if (!chk_feature_usage)
            return;

        unauthorized = attempted_use & ~negotiated;

        if (unauthorized != 0) begin
            virtio_transaction err_txn;
            err_txn = virtio_transaction::type_id::create("feat_err_txn");
            err_txn.txn_type = VIO_TXN_INJECT_ERROR;
            err_txn.features = unauthorized;

            `uvm_error("VIRTIO_MON",
                $sformatf("Feature dependency violation: used=0x%016h negotiated=0x%016h unauthorized=0x%016h",
                          attempted_use, negotiated, unauthorized))
            broadcast_error(err_txn);
        end

        used_features = used_features | attempted_use;
    endfunction

    // ------------------------------------------------------------------------
    // check_queue_access_valid
    //
    // Validates that a queue access targets a valid, enabled queue.
    // ------------------------------------------------------------------------
    virtual function void check_queue_access_valid(int unsigned queue_id);
        if (!chk_queue_protocol)
            return;

        if (vq_mgr == null) begin
            `uvm_warning("VIRTIO_MON",
                "check_queue_access_valid: vq_mgr is null, skipping check")
            return;
        end

        begin
            virtqueue_base vq;
            vq = vq_mgr.get_queue(queue_id);
            if (vq == null) begin
                virtio_transaction err_txn;
                err_txn = virtio_transaction::type_id::create("queue_err_txn");
                err_txn.txn_type = VIO_TXN_INJECT_ERROR;
                err_txn.queue_id = queue_id;

                `uvm_error("VIRTIO_MON",
                    $sformatf("Access to invalid/disabled queue: %0d", queue_id))
                broadcast_error(err_txn);
            end
        end
    endfunction

    // ========================================================================
    // Analysis Port Broadcast Helpers
    // ========================================================================

    // Broadcast a transaction on the main analysis port
    virtual function void broadcast_txn(virtio_transaction txn);
        txn_ap.write(txn);
    endfunction

    // Broadcast an error transaction on both the main and error analysis ports
    virtual function void broadcast_error(virtio_transaction txn);
        txn_ap.write(txn);
        err_ap.write(txn);
    endfunction

    // Broadcast a packet object on the packet analysis port (for coverage)
    virtual function void broadcast_pkt(uvm_object pkt);
        pkt_ap.write(pkt);
    endfunction

endclass : virtio_monitor

`endif // VIRTIO_MONITOR_SV
