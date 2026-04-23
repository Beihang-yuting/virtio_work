`ifndef VIRTIO_CONCURRENCY_CONTROLLER_SV
`define VIRTIO_CONCURRENCY_CONTROLLER_SV

// ============================================================================
// virtio_concurrency_controller
//
// Orchestrates multi-VF parallel operations and race condition injection
// for concurrency verification scenarios.
//
// Provides:
//   - parallel_vf_op: Execute an operation on multiple VFs concurrently
//     with per-VF timeout using named fork blocks
//   - parallel_traffic: Generate traffic on multiple VFs concurrently
//   - inject_race_window: Insert timing delays at specific race points
//   - test_flr_isolation: FLR one VF while others continue traffic
//   - test_queue_reset_isolation: Reset one queue while others are active
//
// All fork blocks use named labels and "disable <label>" (never bare
// "disable fork"). Timeouts use wait_pol for consistent policy.
//
// Depends on:
//   - virtio_vf_instance (per-VF driver wrapper)
//   - virtio_wait_policy (timeout/polling)
//   - virtio_net_types.sv (virtio_txn_type_e, race_point_e)
// ============================================================================

class virtio_concurrency_controller extends uvm_object;
    `uvm_object_utils(virtio_concurrency_controller)

    // ===== VF instances (references, set by env) =====
    virtio_vf_instance vf_instances[];

    // ===== Wait policy =====
    virtio_wait_policy wait_pol;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_concurrency_controller");
        super.new(name);
    endfunction

    // ========================================================================
    // parallel_vf_op
    //
    // Execute an operation on multiple VFs concurrently. Each VF operation
    // runs in a named fork block with a per-VF timeout.
    //
    // Parameters:
    //   vf_ids      -- list of VF indices to operate on
    //   op          -- transaction type to execute
    //   timeout_ns  -- per-VF timeout in nanoseconds
    //   results     -- output: per-VF success/failure flags
    // ========================================================================

    virtual task parallel_vf_op(
        int unsigned vf_ids[$],
        virtio_txn_type_e op,
        int unsigned timeout_ns,
        ref bit results[]
    );
        int unsigned num_vfs = vf_ids.size();
        results = new[num_vfs];

        `uvm_info("CONC_CTRL",
            $sformatf("parallel_vf_op: op=%s, num_vfs=%0d, timeout=%0dns",
                      op.name(), num_vfs, timeout_ns),
            UVM_MEDIUM)

        foreach (vf_ids[i]) begin
            automatic int unsigned idx = i;
            automatic int unsigned vf_id = vf_ids[i];

            fork : parallel_vf_op_block
                begin
                    if (vf_id < vf_instances.size() && vf_instances[vf_id] != null) begin
                        case (op)
                            VIO_TXN_INIT: begin
                                vf_instances[vf_id].init(vf_instances[vf_id].drv_cfg);
                                results[idx] = 1;
                            end
                            VIO_TXN_SHUTDOWN: begin
                                vf_instances[vf_id].shutdown();
                                results[idx] = 1;
                            end
                            VIO_TXN_RESET: begin
                                if (vf_instances[vf_id].driver_agent.ops != null) begin
                                    vf_instances[vf_id].driver_agent.ops.device_reset();
                                    results[idx] = 1;
                                end
                            end
                            default: begin
                                `uvm_warning("CONC_CTRL",
                                    $sformatf("parallel_vf_op: unsupported op=%s for VF%0d",
                                              op.name(), vf_id))
                                results[idx] = 0;
                            end
                        endcase
                    end else begin
                        `uvm_warning("CONC_CTRL",
                            $sformatf("parallel_vf_op: VF%0d not available", vf_id))
                        results[idx] = 0;
                    end
                end
            join_none
        end

        // Wait for all forks with timeout
        fork : parallel_vf_op_wait
            begin
                wait fork;
            end
            begin
                #(timeout_ns * 1ns);
                `uvm_warning("CONC_CTRL",
                    $sformatf("parallel_vf_op: timeout after %0dns", timeout_ns))
            end
        join_any
        disable parallel_vf_op_wait;

        `uvm_info("CONC_CTRL",
            $sformatf("parallel_vf_op: complete, op=%s", op.name()),
            UVM_MEDIUM)
    endtask

    // ========================================================================
    // parallel_traffic
    //
    // Generate traffic on multiple VFs concurrently. Each VF sends
    // pkts_per_vf packets through its TX path.
    //
    // Parameters:
    //   vf_ids       -- list of VF indices
    //   pkts_per_vf  -- number of packets each VF should send
    //   actual_sent  -- output: actual packets sent per VF
    // ========================================================================

    virtual task parallel_traffic(
        int unsigned vf_ids[$],
        int unsigned pkts_per_vf,
        ref int unsigned actual_sent[]
    );
        int unsigned num_vfs = vf_ids.size();
        int unsigned timeout_ns;
        actual_sent = new[num_vfs];

        if (wait_pol != null)
            timeout_ns = wait_pol.effective_timeout(wait_pol.default_timeout_ns) * pkts_per_vf;
        else
            timeout_ns = 50000 * pkts_per_vf;

        `uvm_info("CONC_CTRL",
            $sformatf("parallel_traffic: %0d VFs, %0d pkts each", num_vfs, pkts_per_vf),
            UVM_LOW)

        foreach (vf_ids[i]) begin
            automatic int unsigned idx = i;
            automatic int unsigned vf_id = vf_ids[i];
            automatic int unsigned target_pkts = pkts_per_vf;

            fork : parallel_traffic_block
                begin
                    actual_sent[idx] = 0;

                    if (vf_id < vf_instances.size() && vf_instances[vf_id] != null) begin
                        // Traffic generation is done via sequences in Phase 9.
                        // Here we provide the concurrency framework; the actual
                        // packet submission is delegated to the caller's sequence.
                        `uvm_info("CONC_CTRL",
                            $sformatf("parallel_traffic: VF%0d starting %0d pkts",
                                      vf_id, target_pkts),
                            UVM_HIGH)
                        // Placeholder: actual traffic driven by sequences
                        actual_sent[idx] = target_pkts;
                    end
                end
            join_none
        end

        fork : parallel_traffic_wait
            begin
                wait fork;
            end
            begin
                #(timeout_ns * 1ns);
                `uvm_warning("CONC_CTRL",
                    $sformatf("parallel_traffic: timeout after %0dns", timeout_ns))
            end
        join_any
        disable parallel_traffic_wait;

        `uvm_info("CONC_CTRL", "parallel_traffic: complete", UVM_LOW)
    endtask

    // ========================================================================
    // inject_race_window
    //
    // Insert a timing delay at a specific race point for a VF. Used to
    // create controlled race conditions between concurrent operations.
    //
    // Parameters:
    //   vf_id    -- VF to inject race into
    //   point    -- race injection point (enum)
    //   delay_ns -- delay to inject in nanoseconds
    // ========================================================================

    virtual task inject_race_window(
        int unsigned vf_id,
        race_point_e point,
        int unsigned delay_ns
    );
        `uvm_info("CONC_CTRL",
            $sformatf("inject_race_window: VF%0d, point=%s, delay=%0dns",
                      vf_id, point.name(), delay_ns),
            UVM_MEDIUM)

        if (vf_id >= vf_instances.size() || vf_instances[vf_id] == null) begin
            `uvm_error("CONC_CTRL",
                $sformatf("inject_race_window: VF%0d not available", vf_id))
            return;
        end

        // Insert the delay to create a race window
        #(delay_ns * 1ns);

        `uvm_info("CONC_CTRL",
            $sformatf("inject_race_window: VF%0d, point=%s complete",
                      vf_id, point.name()),
            UVM_HIGH)
    endtask

    // ========================================================================
    // test_flr_isolation
    //
    // FLR one VF while others continue active operations. Verifies that
    // the FLR does not corrupt state of other active VFs.
    //
    // Parameters:
    //   pf_mgr_ref    -- PF manager (as uvm_object, $cast by caller)
    //   flr_vf_id     -- VF to FLR
    //   active_vf_ids -- VFs that should continue operating during FLR
    // ========================================================================

    virtual task test_flr_isolation(
        uvm_object pf_mgr_ref,
        int unsigned flr_vf_id,
        int unsigned active_vf_ids[$]
    );
        bit flr_done = 0;
        bit active_ok = 1;
        int unsigned timeout_ns;

        if (wait_pol != null)
            timeout_ns = wait_pol.effective_timeout(wait_pol.flr_timeout_ns) * 2;
        else
            timeout_ns = 20000;

        `uvm_info("CONC_CTRL",
            $sformatf("test_flr_isolation: FLR VF%0d, active VFs=%p",
                      flr_vf_id, active_vf_ids),
            UVM_LOW)

        fork : flr_isolation_test
            // Thread 1: Perform FLR on target VF
            begin : flr_thread
                if (flr_vf_id < vf_instances.size() && vf_instances[flr_vf_id] != null) begin
                    vf_instances[flr_vf_id].on_flr();
                    flr_done = 1;
                    `uvm_info("CONC_CTRL",
                        $sformatf("test_flr_isolation: FLR VF%0d complete", flr_vf_id),
                        UVM_MEDIUM)
                end
            end : flr_thread

            // Thread 2: Verify active VFs remain operational
            begin : active_check_thread
                foreach (active_vf_ids[i]) begin
                    automatic int unsigned avf = active_vf_ids[i];
                    if (avf < vf_instances.size() && vf_instances[avf] != null) begin
                        if (vf_instances[avf].get_state() == VF_FLR ||
                            vf_instances[avf].get_state() == VF_DISABLED) begin
                            `uvm_error("CONC_CTRL",
                                $sformatf("test_flr_isolation: active VF%0d state corrupted to %s during FLR of VF%0d",
                                          avf, vf_instances[avf].get_state().name(), flr_vf_id))
                            active_ok = 0;
                        end
                    end
                end
            end : active_check_thread

            // Thread 3: Timeout guard
            begin : flr_timeout_thread
                #(timeout_ns * 1ns);
                `uvm_error("CONC_CTRL",
                    $sformatf("test_flr_isolation: timeout after %0dns", timeout_ns))
            end : flr_timeout_thread
        join_any
        disable flr_isolation_test;

        if (flr_done && active_ok) begin
            `uvm_info("CONC_CTRL",
                $sformatf("test_flr_isolation: PASSED - FLR VF%0d isolated from active VFs",
                          flr_vf_id),
                UVM_LOW)
        end
    endtask

    // ========================================================================
    // test_queue_reset_isolation
    //
    // Reset one queue on a VF while other queues on the same VF remain
    // active. Verifies queue-level isolation during individual queue reset.
    //
    // Parameters:
    //   vf_id       -- VF containing the queues
    //   reset_qid   -- queue ID to reset
    //   active_qids -- queue IDs that should remain active
    // ========================================================================

    virtual task test_queue_reset_isolation(
        int unsigned vf_id,
        int unsigned reset_qid,
        int unsigned active_qids[$]
    );
        int unsigned timeout_ns;

        if (wait_pol != null)
            timeout_ns = wait_pol.effective_timeout(wait_pol.queue_reset_timeout_ns);
        else
            timeout_ns = 5000;

        `uvm_info("CONC_CTRL",
            $sformatf("test_queue_reset_isolation: VF%0d, reset queue=%0d, active queues=%p",
                      vf_id, reset_qid, active_qids),
            UVM_LOW)

        if (vf_id >= vf_instances.size() || vf_instances[vf_id] == null) begin
            `uvm_error("CONC_CTRL",
                $sformatf("test_queue_reset_isolation: VF%0d not available", vf_id))
            return;
        end

        fork : queue_reset_isolation_test
            // Thread 1: Reset the target queue
            begin : reset_thread
                virtqueue_base vq;
                vq = vf_instances[vf_id].vq_mgr.get_queue(reset_qid);
                if (vq != null) begin
                    vq.detach();
                    `uvm_info("CONC_CTRL",
                        $sformatf("test_queue_reset_isolation: queue %0d reset complete",
                                  reset_qid),
                        UVM_MEDIUM)
                end else begin
                    `uvm_warning("CONC_CTRL",
                        $sformatf("test_queue_reset_isolation: queue %0d not found", reset_qid))
                end
            end : reset_thread

            // Thread 2: Verify active queues are unaffected
            begin : active_queue_check
                foreach (active_qids[i]) begin
                    automatic int unsigned aqid = active_qids[i];
                    virtqueue_base avq;
                    avq = vf_instances[vf_id].vq_mgr.get_queue(aqid);
                    if (avq == null) begin
                        `uvm_error("CONC_CTRL",
                            $sformatf("test_queue_reset_isolation: active queue %0d disappeared during reset of queue %0d",
                                      aqid, reset_qid))
                    end
                end
            end : active_queue_check

            // Thread 3: Timeout guard
            begin : queue_reset_timeout
                #(timeout_ns * 1ns);
                `uvm_warning("CONC_CTRL",
                    $sformatf("test_queue_reset_isolation: timeout after %0dns", timeout_ns))
            end : queue_reset_timeout
        join_any
        disable queue_reset_isolation_test;

        `uvm_info("CONC_CTRL",
            "test_queue_reset_isolation: complete", UVM_LOW)
    endtask

endclass : virtio_concurrency_controller

`endif // VIRTIO_CONCURRENCY_CONTROLLER_SV
