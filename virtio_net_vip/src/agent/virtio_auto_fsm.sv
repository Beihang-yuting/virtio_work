`ifndef VIRTIO_AUTO_FSM_SV
`define VIRTIO_AUTO_FSM_SV

// ============================================================================
// virtio_auto_fsm
//
// Complete lifecycle state machine for the virtio-net driver VIP.
// Orchestrates device initialization, data plane operation, reconfiguration,
// live migration, and error recovery using virtio_atomic_ops.
//
// Critical implementation rules enforced:
//   1. Named fork blocks only: fork : block_name ... join*; disable block_name;
//   2. No bare #delay -- all waits use wait_pol or named fork with #(ns * 1ns)
//   3. All background tasks check dataplane_running after every wait
//   4. start_dataplane uses fork : dataplane_tasks ... join_none
//   5. stop_dataplane uses -> stop_event and disable dataplane_tasks
//
// Depends on:
//   - virtio_atomic_ops (low-level driver operations)
//   - virtio_net_types.sv (fsm_state_e, virtio_driver_config_t, etc.)
//   - virtio_wait_policy (timeout/polling)
// ============================================================================

class virtio_auto_fsm extends uvm_object;
    `uvm_object_utils(virtio_auto_fsm)

    // ===== State =====
    fsm_state_e   state = FSM_IDLE;

    // ===== References =====
    virtio_atomic_ops       ops;
    virtio_driver_config_t  drv_cfg;

    // ===== Background task control =====
    protected bit   dataplane_running = 0;
    protected event stop_event;

    // ===== Events for inter-task signaling =====
    uvm_event  used_ring_updated_event;   // fired when used ring has new entries
    uvm_event  packet_completed_event;    // fired on each TX/RX completion
    uvm_event  config_change_event;       // fired on device config change
    uvm_event  interrupt_event;           // fired on interrupt received

    // ===== Internal state =====
    protected int unsigned  num_total_queues;
    protected int unsigned  active_num_pairs;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_auto_fsm");
        super.new(name);
        used_ring_updated_event = new("used_ring_updated_event");
        packet_completed_event  = new("packet_completed_event");
        config_change_event     = new("config_change_event");
        interrupt_event         = new("interrupt_event");
        num_total_queues        = 0;
        active_num_pairs        = 1;
    endfunction

    // ========================================================================
    // Complete Initialization
    //
    // FSM_IDLE -> FSM_DISCOVERING -> FSM_NEGOTIATING -> FSM_QUEUE_SETUP
    //          -> FSM_MSIX_SETUP -> FSM_READY
    // ========================================================================

    virtual task full_init();
        bit [63:0] negotiated;
        bit        feat_ok;
        int unsigned total_queues;

        `uvm_info("AUTO_FSM", "full_init: starting initialization sequence", UVM_LOW)

        // ---- Step 1: BAR discovery ----
        state = FSM_DISCOVERING;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- discovering BARs", state.name()), UVM_MEDIUM)
        ops.transport.discover_and_init_bars();

        // ---- Step 2: Feature negotiation ----
        state = FSM_NEGOTIATING;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- negotiating features", state.name()), UVM_MEDIUM)

        ops.device_reset();

        ops.set_acknowledge();
        ops.set_driver();

        ops.negotiate_features(drv_cfg.driver_features, negotiated);

        ops.set_features_ok(feat_ok);
        if (!feat_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", "full_init: device rejected features")
            ops.set_failed();
            return;
        end

        // ---- Step 3: Queue setup ----
        state = FSM_QUEUE_SETUP;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- setting up queues", state.name()), UVM_MEDIUM)

        active_num_pairs = drv_cfg.num_queue_pairs;
        total_queues = 2 * active_num_pairs;
        if (negotiated[VIRTIO_NET_F_CTRL_VQ])
            total_queues = total_queues + 1;
        num_total_queues = total_queues;

        ops.setup_all_queues(active_num_pairs, drv_cfg.vq_type, drv_cfg.queue_size);

        // ---- Step 4: MSI-X setup ----
        state = FSM_MSIX_SETUP;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- setting up MSI-X", state.name()), UVM_MEDIUM)

        ops.setup_msix(num_total_queues);

        // ---- Step 5: DRIVER_OK ----
        ops.set_driver_ok();
        state = FSM_READY;

        `uvm_info("AUTO_FSM",
            $sformatf("full_init: complete, state=%s, %0d queues, features=0x%016h",
                      state.name(), num_total_queues, negotiated), UVM_LOW)
    endtask

    // ========================================================================
    // Data Plane Control
    // ========================================================================

    // ------------------------------------------------------------------------
    // start_dataplane -- FSM_READY -> FSM_RUNNING
    //
    // Pre-fills RX buffers and forks all background tasks in a named block.
    // ------------------------------------------------------------------------
    virtual task start_dataplane();
        if (state != FSM_READY) begin
            `uvm_error("AUTO_FSM",
                $sformatf("start_dataplane: invalid state %s (expected FSM_READY)", state.name()))
            return;
        end

        `uvm_info("AUTO_FSM", "start_dataplane: starting data plane", UVM_MEDIUM)

        dataplane_running = 1;
        state = FSM_RUNNING;

        // Pre-fill RX buffers for all receive queues (even-numbered queues)
        for (int unsigned i = 0; i < active_num_pairs; i++) begin
            int unsigned rx_qid = i * 2;
            ops.rx_refill(rx_qid, drv_cfg.queue_size);
        end

        // Fork all background tasks in a named block
        fork : dataplane_tasks
            begin : rx_refill_loops
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    automatic int unsigned rx_qid = i * 2;
                    fork
                        rx_refill_loop(rx_qid);
                    join_none
                end
                wait fork;
            end

            begin : tx_complete_loops
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    automatic int unsigned tx_qid = i * 2 + 1;
                    fork
                        tx_complete_loop(tx_qid);
                    join_none
                end
                wait fork;
            end

            interrupt_handler_loop();

            begin : adaptive_irq_check
                if (drv_cfg.irq_mode == IRQ_POLLING) begin
                    adaptive_irq_loop();
                end
            end

            config_change_handler();
        join_none

        `uvm_info("AUTO_FSM", "start_dataplane: background tasks forked", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // stop_dataplane -- FSM_RUNNING -> FSM_READY
    //
    // Signals all background tasks to exit, then kills them via disable.
    // ------------------------------------------------------------------------
    virtual task stop_dataplane();
        if (state != FSM_RUNNING) begin
            `uvm_warning("AUTO_FSM",
                $sformatf("stop_dataplane: state is %s, not FSM_RUNNING", state.name()))
        end

        `uvm_info("AUTO_FSM", "stop_dataplane: stopping data plane", UVM_MEDIUM)

        // Signal all background tasks to exit
        dataplane_running = 0;
        -> stop_event;

        // Brief wait for tasks to check the flag and exit gracefully
        begin
            int unsigned interval = ops.wait_pol.default_poll_interval_ns;
            #(interval * 2 * 1ns);
        end

        // Kill all remaining background tasks
        disable dataplane_tasks;

        state = FSM_READY;

        `uvm_info("AUTO_FSM", "stop_dataplane: data plane stopped", UVM_MEDIUM)
    endtask

    // ========================================================================
    // High-Level Data Operations
    // ========================================================================

    // ------------------------------------------------------------------------
    // send_packets -- Submit packets for transmission
    //
    // Builds a default virtio_net_hdr per packet and submits via tx_submit.
    // queue_id is treated as a pair index if < active_num_pairs.
    // ------------------------------------------------------------------------
    virtual task send_packets(uvm_object pkts[$], int unsigned queue_id = 0);
        int unsigned tx_qid;
        int unsigned desc_id;

        // Transmit queues are odd-numbered: pair_index*2+1
        if (queue_id < active_num_pairs)
            tx_qid = queue_id * 2 + 1;
        else
            tx_qid = queue_id;

        `uvm_info("AUTO_FSM",
            $sformatf("send_packets: count=%0d queue_id=%0d", pkts.size(), tx_qid), UVM_MEDIUM)

        foreach (pkts[i]) begin
            virtio_net_hdr_t hdr;

            // Build default virtio_net_hdr
            hdr.flags       = 8'h00;
            hdr.gso_type    = VIRTIO_NET_HDR_GSO_NONE;
            hdr.hdr_len     = 16'h0000;
            hdr.gso_size    = 16'h0000;
            hdr.csum_start  = 16'h0000;
            hdr.csum_offset = 16'h0000;
            hdr.num_buffers = 16'h0000;
            hdr.hash_value  = 32'h00000000;
            hdr.hash_report = 16'h0000;

            // If CSUM offload is negotiated, set NEEDS_CSUM flag
            if (ops.negotiated_features[VIRTIO_NET_F_CSUM]) begin
                hdr.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
            end

            ops.tx_submit(tx_qid, hdr, pkts[i], 0, desc_id);
        end
    endtask

    // ------------------------------------------------------------------------
    // wait_packets -- Wait for packets to arrive on receive queues
    //
    // Uses mixed event + polling approach (no bare #delay).
    // Loop until count >= expected or timeout, using named fork blocks.
    // ------------------------------------------------------------------------
    virtual task wait_packets(
        int unsigned expected_count,
        ref uvm_object received[$],
        int unsigned timeout_ns
    );
        int unsigned   count = 0;
        realtime       start_time;
        int unsigned   interval;
        int unsigned   budget;
        int unsigned   eff_timeout;

        interval    = ops.wait_pol.default_poll_interval_ns;
        budget      = drv_cfg.napi_budget;
        if (budget == 0) budget = 64;
        eff_timeout = ops.wait_pol.effective_timeout(timeout_ns);
        start_time  = $realtime;

        `uvm_info("AUTO_FSM",
            $sformatf("wait_packets: expecting %0d, timeout=%0dns", expected_count, eff_timeout),
            UVM_MEDIUM)

        while (count < expected_count) begin
            realtime elapsed_ns;
            elapsed_ns = ($realtime - start_time) / 1ns;

            if (elapsed_ns >= eff_timeout) begin
                `uvm_warning("AUTO_FSM",
                    $sformatf("wait_packets: timeout after %0dns, received %0d/%0d",
                              eff_timeout, count, expected_count))
                return;
            end

            if (!dataplane_running) begin
                `uvm_info("AUTO_FSM",
                    "wait_packets: dataplane stopped, exiting wait", UVM_MEDIUM)
                return;
            end

            // Wait for used ring event or poll interval (named fork)
            fork : pkt_wait_blk
                begin : pkt_wait_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : pkt_wait_timeout_arm
                    #(interval * 1ns);
                end
                begin : pkt_wait_stop_arm
                    @stop_event;
                end
            join_any
            disable pkt_wait_blk;

            if (!dataplane_running)
                return;

            // Poll all receive queues for new packets
            for (int unsigned i = 0; i < active_num_pairs; i++) begin
                int unsigned rx_qid = i * 2;
                uvm_object   rx_pkts[$];

                ops.rx_receive(rx_qid, rx_pkts, budget);

                foreach (rx_pkts[j]) begin
                    received.push_back(rx_pkts[j]);
                    count++;
                    packet_completed_event.trigger();
                end
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("wait_packets: received %0d/%0d", count, expected_count), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Reconfiguration
    // ========================================================================

    // ------------------------------------------------------------------------
    // configure_mq -- Change the number of active queue pairs
    // ------------------------------------------------------------------------
    virtual task configure_mq(int unsigned num_pairs);
        bit success;

        `uvm_info("AUTO_FSM",
            $sformatf("configure_mq: changing from %0d to %0d pairs",
                      active_num_pairs, num_pairs), UVM_MEDIUM)

        ops.ctrl_set_mq_pairs(num_pairs, success);

        if (success) begin
            // Teardown queues that are no longer needed
            if (num_pairs < active_num_pairs) begin
                for (int unsigned i = num_pairs; i < active_num_pairs; i++) begin
                    ops.teardown_queue(i * 2);      // receiveq
                    ops.teardown_queue(i * 2 + 1);  // transmitq
                end
            end

            // Setup new queues if expanding
            if (num_pairs > active_num_pairs) begin
                for (int unsigned i = active_num_pairs; i < num_pairs; i++) begin
                    ops.setup_queue(i * 2,     drv_cfg.queue_size, drv_cfg.vq_type);
                    ops.setup_queue(i * 2 + 1, drv_cfg.queue_size, drv_cfg.vq_type);
                end
            end

            active_num_pairs = num_pairs;
        end else begin
            `uvm_error("AUTO_FSM",
                $sformatf("configure_mq: device rejected MQ change to %0d pairs", num_pairs))
        end
    endtask

    // ------------------------------------------------------------------------
    // configure_rss -- Update RSS configuration via control VQ
    // ------------------------------------------------------------------------
    virtual task configure_rss(virtio_rss_config_t cfg);
        bit success;

        `uvm_info("AUTO_FSM", "configure_rss: updating RSS configuration", UVM_MEDIUM)
        ops.ctrl_set_rss(cfg, success);

        if (!success) begin
            `uvm_error("AUTO_FSM", "configure_rss: device rejected RSS configuration")
        end
    endtask

    // ========================================================================
    // Migration
    // ========================================================================

    // ------------------------------------------------------------------------
    // freeze_for_migration -- FSM_RUNNING -> FSM_SUSPENDING -> FSM_FROZEN
    //
    // Stops the data plane and snapshots all device state.
    // ------------------------------------------------------------------------
    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);
        `uvm_info("AUTO_FSM", "freeze_for_migration: starting freeze", UVM_LOW)

        // 1. Stop data plane
        if (state == FSM_RUNNING) begin
            state = FSM_SUSPENDING;
            stop_dataplane();
            // Override state since stop_dataplane sets FSM_READY
            state = FSM_SUSPENDING;
        end

        // 2. Save negotiated features and device status
        snap.negotiated_features = ops.negotiated_features;
        begin
            bit [7:0] dev_status;
            ops.transport.read_device_status(dev_status);
            snap.device_status = dev_status;
        end

        // 3. Read device config
        ops.transport.read_net_config(snap.net_config);

        // 4. Save all queue states
        snap.num_queue_pairs = active_num_pairs;
        snap.queue_snapshots = new[num_total_queues];

        for (int unsigned q = 0; q < num_total_queues; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(q);
            if (vq != null) begin
                vq.save_state(snap.queue_snapshots[q]);
            end
        end

        state = FSM_FROZEN;

        `uvm_info("AUTO_FSM",
            $sformatf("freeze_for_migration: frozen, %0d queues saved", num_total_queues), UVM_LOW)
    endtask

    // ------------------------------------------------------------------------
    // restore_from_migration -- FSM_IDLE -> FSM_FROZEN -> FSM_READY -> FSM_RUNNING
    //
    // Restores device state from a snapshot and restarts data plane.
    // ------------------------------------------------------------------------
    virtual task restore_from_migration(virtio_device_snapshot_t snap);
        bit feat_ok;

        `uvm_info("AUTO_FSM", "restore_from_migration: starting restore", UVM_LOW)

        state = FSM_FROZEN;

        // 1. Reset and re-initialize transport
        ops.device_reset();
        ops.set_acknowledge();
        ops.set_driver();

        // 2. Restore negotiated features
        begin
            bit [63:0] result;
            ops.negotiate_features(snap.negotiated_features, result);
        end

        ops.set_features_ok(feat_ok);
        if (!feat_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", "restore_from_migration: feature negotiation failed")
            ops.set_failed();
            return;
        end

        // 3. Restore queues: setup fresh, then overlay snapshot data
        active_num_pairs   = snap.num_queue_pairs;
        num_total_queues   = snap.queue_snapshots.size();

        ops.setup_all_queues(active_num_pairs, drv_cfg.vq_type, drv_cfg.queue_size);

        // Restore ring data and indices from snapshot
        for (int unsigned q = 0; q < num_total_queues; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(q);
            if (vq != null && q < snap.queue_snapshots.size()) begin
                vq.restore_state(snap.queue_snapshots[q]);
            end
        end

        // 4. Restore MSI-X
        ops.setup_msix(num_total_queues);

        // 5. DRIVER_OK
        ops.set_driver_ok();
        state = FSM_READY;

        // 6. Restart data plane
        start_dataplane();

        `uvm_info("AUTO_FSM", "restore_from_migration: restore complete, data plane running", UVM_LOW)
    endtask

    // ========================================================================
    // Error Recovery
    // ========================================================================

    // ------------------------------------------------------------------------
    // handle_device_needs_reset -- Full device recovery cycle
    //
    // FSM_RUNNING -> FSM_ERROR -> FSM_RECOVERING -> full_init -> start_dataplane
    // ------------------------------------------------------------------------
    virtual task handle_device_needs_reset();
        `uvm_info("AUTO_FSM", "handle_device_needs_reset: starting recovery", UVM_LOW)

        state = FSM_ERROR;

        // Stop data plane if running
        if (dataplane_running) begin
            dataplane_running = 0;
            -> stop_event;
            begin
                int unsigned interval = ops.wait_pol.default_poll_interval_ns;
                #(interval * 2 * 1ns);
            end
            disable dataplane_tasks;
        end

        state = FSM_RECOVERING;

        // Full device reset and re-initialization
        ops.device_reset();

        state = FSM_IDLE;
        full_init();

        if (state == FSM_READY)
            start_dataplane();

        `uvm_info("AUTO_FSM",
            $sformatf("handle_device_needs_reset: recovery complete, state=%s", state.name()),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------------------
    // reset_single_queue -- Reset and re-setup a single queue
    //
    // Does not change overall FSM state. If the queue is a receive queue,
    // refills RX buffers after re-setup.
    // ------------------------------------------------------------------------
    virtual task reset_single_queue(int unsigned queue_id);
        `uvm_info("AUTO_FSM",
            $sformatf("reset_single_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // Teardown the queue
        ops.teardown_queue(queue_id);

        // Reset via transport (writes Q_RESET, polls until complete)
        ops.reset_queue(queue_id);

        // Re-setup the queue
        ops.setup_queue(queue_id, drv_cfg.queue_size, drv_cfg.vq_type);

        // If this is a receive queue (even-numbered), refill RX buffers
        if (queue_id % 2 == 0 && queue_id < active_num_pairs * 2) begin
            ops.rx_refill(queue_id, drv_cfg.queue_size);
        end

        `uvm_info("AUTO_FSM",
            $sformatf("reset_single_queue: queue_id=%0d complete", queue_id), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Background Tasks
    //
    // ALL background tasks must:
    //   - Loop with while (dataplane_running)
    //   - Use named fork blocks for internal waits
    //   - Check dataplane_running after every wait
    //   - Exit gracefully on stop_event
    // ========================================================================

    // ------------------------------------------------------------------------
    // rx_refill_loop -- Periodically refill RX buffers for a queue
    // ------------------------------------------------------------------------
    protected virtual task rx_refill_loop(int unsigned queue_id);
        int unsigned interval;
        int unsigned threshold;

        interval  = ops.wait_pol.default_poll_interval_ns;
        threshold = drv_cfg.rx_refill_threshold;
        if (threshold == 0)
            threshold = drv_cfg.queue_size / 4;

        `uvm_info("AUTO_FSM",
            $sformatf("rx_refill_loop: queue_id=%0d started, threshold=%0d",
                      queue_id, threshold), UVM_HIGH)

        while (dataplane_running) begin
            virtqueue_base vq;

            // Wait for event or poll interval (named fork)
            fork : rx_refill_wait_blk
                begin : rx_refill_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : rx_refill_timeout_arm
                    #(interval * 1ns);
                end
                begin : rx_refill_stop_arm
                    @stop_event;
                end
            join_any
            disable rx_refill_wait_blk;

            if (!dataplane_running) return;

            // Check if refill is needed
            vq = ops.vq_mgr.get_queue(queue_id);
            if (vq != null) begin
                int unsigned free_count = vq.get_free_count();
                if (free_count >= threshold) begin
                    ops.rx_refill(queue_id, free_count);
                end
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("rx_refill_loop: queue_id=%0d exiting", queue_id), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // tx_complete_loop -- Periodically poll for TX completions
    // ------------------------------------------------------------------------
    protected virtual task tx_complete_loop(int unsigned queue_id);
        int unsigned interval;
        int unsigned budget;

        interval = ops.wait_pol.default_poll_interval_ns;
        budget   = drv_cfg.napi_budget;
        if (budget == 0)
            budget = 64;

        `uvm_info("AUTO_FSM",
            $sformatf("tx_complete_loop: queue_id=%0d started, budget=%0d",
                      queue_id, budget), UVM_HIGH)

        while (dataplane_running) begin
            uvm_object completed[$];

            // Wait for event or poll interval (named fork)
            fork : tx_complete_wait_blk
                begin : tx_complete_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : tx_complete_timeout_arm
                    #(interval * 1ns);
                end
                begin : tx_complete_stop_arm
                    @stop_event;
                end
            join_any
            disable tx_complete_wait_blk;

            if (!dataplane_running) return;

            ops.tx_complete(queue_id, completed, budget);

            if (completed.size() > 0) begin
                packet_completed_event.trigger();
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("tx_complete_loop: queue_id=%0d exiting", queue_id), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // interrupt_handler_loop -- Dispatch incoming interrupts
    // ------------------------------------------------------------------------
    protected virtual task interrupt_handler_loop();
        int unsigned interval;

        interval = ops.wait_pol.default_poll_interval_ns;

        `uvm_info("AUTO_FSM", "interrupt_handler_loop: started", UVM_HIGH)

        while (dataplane_running) begin
            // Wait for interrupt event or poll interval (named fork)
            fork : irq_handler_wait_blk
                begin : irq_handler_evt_arm
                    interrupt_event.wait_trigger();
                end
                begin : irq_handler_timeout_arm
                    #(interval * 1ns);
                end
                begin : irq_handler_stop_arm
                    @stop_event;
                end
            join_any
            disable irq_handler_wait_blk;

            if (!dataplane_running) return;

            // Signal that used ring may have new entries
            used_ring_updated_event.trigger();
        end

        `uvm_info("AUTO_FSM", "interrupt_handler_loop: exiting", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // adaptive_irq_loop -- Switch between MSI-X and polling based on rate
    //
    // Monitors packet completion rate over a window. If rate exceeds a
    // threshold, switches to polling mode. If rate drops, switches back
    // to interrupt-driven mode.
    // ------------------------------------------------------------------------
    protected virtual task adaptive_irq_loop();
        int unsigned interval;
        int unsigned pkt_count_window = 0;
        int unsigned high_rate_threshold;
        int unsigned low_rate_threshold;
        bit          currently_polling = 0;

        interval = ops.wait_pol.default_poll_interval_ns * 10;  // Longer measurement window
        high_rate_threshold = drv_cfg.coal_max_packets;
        if (high_rate_threshold == 0)
            high_rate_threshold = 256;
        low_rate_threshold = high_rate_threshold / 4;

        `uvm_info("AUTO_FSM", "adaptive_irq_loop: started", UVM_HIGH)

        while (dataplane_running) begin
            pkt_count_window = 0;

            // Count packet completions over one measurement window (named fork)
            fork : adaptive_irq_wait_blk
                begin : adaptive_irq_evt_arm
                    while (dataplane_running) begin
                        packet_completed_event.wait_trigger();
                        pkt_count_window++;
                    end
                end
                begin : adaptive_irq_timeout_arm
                    #(interval * 1ns);
                end
                begin : adaptive_irq_stop_arm
                    @stop_event;
                end
            join_any
            disable adaptive_irq_wait_blk;

            if (!dataplane_running) return;

            // Evaluate rate and switch mode if needed
            if (!currently_polling && pkt_count_window > high_rate_threshold) begin
                // High rate: switch to polling
                currently_polling = 1;
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    virtqueue_base vq;
                    vq = ops.vq_mgr.get_queue(i * 2);
                    if (vq != null) vq.disable_cb();
                    vq = ops.vq_mgr.get_queue(i * 2 + 1);
                    if (vq != null) vq.disable_cb();
                end
                `uvm_info("AUTO_FSM",
                    $sformatf("adaptive_irq: switching to POLLING (rate=%0d > %0d)",
                              pkt_count_window, high_rate_threshold), UVM_MEDIUM)
            end else if (currently_polling && pkt_count_window < low_rate_threshold) begin
                // Low rate: switch back to MSI-X interrupts
                currently_polling = 0;
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    virtqueue_base vq;
                    vq = ops.vq_mgr.get_queue(i * 2);
                    if (vq != null) vq.enable_cb();
                    vq = ops.vq_mgr.get_queue(i * 2 + 1);
                    if (vq != null) vq.enable_cb();
                end
                `uvm_info("AUTO_FSM",
                    $sformatf("adaptive_irq: switching to MSI-X (rate=%0d < %0d)",
                              pkt_count_window, low_rate_threshold), UVM_MEDIUM)
            end
        end

        `uvm_info("AUTO_FSM", "adaptive_irq_loop: exiting", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // config_change_handler -- Monitor device configuration changes
    //
    // Periodically checks for device config changes (link status,
    // GUEST_ANNOUNCE, DEVICE_NEEDS_RESET).
    // ------------------------------------------------------------------------
    protected virtual task config_change_handler();
        int unsigned interval;

        interval = ops.wait_pol.default_poll_interval_ns * 5;

        `uvm_info("AUTO_FSM", "config_change_handler: started", UVM_HIGH)

        while (dataplane_running) begin
            // Wait for config change event or poll interval (named fork)
            fork : cfg_change_wait_blk
                begin : cfg_change_evt_arm
                    config_change_event.wait_trigger();
                end
                begin : cfg_change_timeout_arm
                    #(interval * 1ns);
                end
                begin : cfg_change_stop_arm
                    @stop_event;
                end
            join_any
            disable cfg_change_wait_blk;

            if (!dataplane_running) return;

            // Re-read device configuration and handle changes
            begin
                virtio_net_device_config_t cfg;
                ops.transport.read_net_config(cfg);

                // Check link status if STATUS feature is negotiated
                if (ops.negotiated_features[VIRTIO_NET_F_STATUS]) begin
                    if (cfg.status & 16'h0001) begin
                        `uvm_info("AUTO_FSM",
                            "config_change_handler: link is UP", UVM_MEDIUM)
                    end else begin
                        `uvm_info("AUTO_FSM",
                            "config_change_handler: link is DOWN", UVM_MEDIUM)
                    end
                end

                // Check GUEST_ANNOUNCE request
                if (ops.negotiated_features[VIRTIO_NET_F_GUEST_ANNOUNCE]) begin
                    if (cfg.status & 16'h0002) begin
                        bit announce_ok;
                        ops.ctrl_announce_ack(announce_ok);
                        `uvm_info("AUTO_FSM",
                            $sformatf("config_change_handler: guest announce ack=%0b",
                                      announce_ok), UVM_MEDIUM)
                    end
                end

                // Check DEVICE_NEEDS_RESET
                begin
                    bit [7:0] dev_status;
                    ops.transport.read_device_status(dev_status);
                    if (dev_status & DEV_STATUS_DEVICE_NEEDS_RESET) begin
                        `uvm_warning("AUTO_FSM",
                            "config_change_handler: DEVICE_NEEDS_RESET detected")
                        handle_device_needs_reset();
                        return;
                    end
                end
            end
        end

        `uvm_info("AUTO_FSM", "config_change_handler: exiting", UVM_HIGH)
    endtask

endclass : virtio_auto_fsm

`endif // VIRTIO_AUTO_FSM_SV
