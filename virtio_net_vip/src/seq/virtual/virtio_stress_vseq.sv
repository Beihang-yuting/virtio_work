`ifndef VIRTIO_STRESS_VSEQ_SV
`define VIRTIO_STRESS_VSEQ_SV

// ============================================================================
// virtio_stress_vseq
//
// Concurrent stress: multi-VF traffic + random queue resets + random error
// injection + random dynamic reconfig. A duration watchdog stops after
// duration_packets total packets have been sent.
//
// All fork blocks are named per SystemVerilog best practice.
//
// Depends on:
//   - virtio_init_seq, virtio_tx_seq, virtio_rx_seq, virtio_ctrl_seq
//   - virtio_transaction
// ============================================================================

class virtio_stress_vseq extends uvm_sequence;
    `uvm_object_utils(virtio_stress_vseq)

    // Per-VF sequencer references (set by test before start)
    uvm_sequencer #(virtio_transaction) vf_seqrs[];

    rand int unsigned duration_packets;  // total packets before stopping

    constraint c_default {
        duration_packets inside {[1000:10000]};
    }

    // Internal state
    protected int unsigned total_sent;
    protected bit          stop_flag;

    function new(string name = "virtio_stress_vseq");
        super.new(name);
        total_sent = 0;
        stop_flag  = 0;
    endfunction

    virtual task body();
        int unsigned num_vfs;

        if (vf_seqrs.size() == 0)
            `uvm_fatal("STRESS_VSEQ", "vf_seqrs[] not set -- test must assign before start()")

        num_vfs = vf_seqrs.size();
        total_sent = 0;
        stop_flag  = 0;

        `uvm_info("STRESS_VSEQ", $sformatf(
            "Starting stress: %0d VFs, duration=%0d packets",
            num_vfs, duration_packets), UVM_LOW)

        // Init all VFs first (sequential -- simpler for stress setup)
        foreach (vf_seqrs[i]) begin
            virtio_init_seq init_s;
            init_s = virtio_init_seq::type_id::create($sformatf("init_vf%0d", i));
            init_s.num_queue_pairs = 1;
            init_s.vq_type = VQ_SPLIT;
            init_s.start(vf_seqrs[i]);
        end

        // Start dataplane on all VFs
        foreach (vf_seqrs[i]) begin
            virtio_transaction req;
            req = virtio_transaction::type_id::create($sformatf("start_vf%0d", i));
            req.txn_type = VIO_TXN_START_DP;
            start_item(req, -1, vf_seqrs[i]);
            finish_item(req);
        end

        // Fork concurrent stress activities (all named)
        fork : stress_activities

            // Activity 1: Continuous traffic on all VFs
            begin : continuous_traffic
                while (!stop_flag) begin
                    foreach (vf_seqrs[i]) begin
                        automatic int vf_idx = i;
                        if (stop_flag) break;
                        fork : per_vf_tx_burst
                            begin
                                virtio_tx_seq tx_s;
                                int unsigned burst;

                                burst = 16;
                                tx_s = virtio_tx_seq::type_id::create(
                                    $sformatf("stress_tx_vf%0d", vf_idx));
                                tx_s.num_packets = burst;
                                tx_s.queue_id = 1;
                                tx_s.start(vf_seqrs[vf_idx]);

                                total_sent += burst;
                            end
                        join_none
                    end
                    wait fork;
                end
            end

            // Activity 2: Random per-queue reset
            begin : random_queue_reset
                while (!stop_flag) begin
                    int unsigned target_vf;
                    virtio_transaction req;

                    // Wait a random interval between resets
                    #($urandom_range(5000, 20000));
                    if (stop_flag) break;

                    target_vf = $urandom_range(0, num_vfs - 1);
                    req = virtio_transaction::type_id::create("queue_reset");
                    req.txn_type = VIO_TXN_RESET_QUEUE;
                    req.queue_id = 1;  // reset TX queue
                    start_item(req, -1, vf_seqrs[target_vf]);
                    finish_item(req);

                    `uvm_info("STRESS_VSEQ", $sformatf(
                        "Queue reset on VF %0d, queue 1", target_vf), UVM_HIGH)

                    // Re-setup the queue after reset
                    req = virtio_transaction::type_id::create("queue_setup");
                    req.txn_type = VIO_TXN_SETUP_QUEUE;
                    req.queue_id = 1;
                    req.queue_size = 256;
                    start_item(req, -1, vf_seqrs[target_vf]);
                    finish_item(req);
                end
            end

            // Activity 3: Random error injection
            begin : random_error_inject
                while (!stop_flag) begin
                    int unsigned target_vf;
                    virtio_transaction req;
                    int unsigned err_idx;

                    #($urandom_range(10000, 50000));
                    if (stop_flag) break;

                    target_vf = $urandom_range(0, num_vfs - 1);
                    req = virtio_transaction::type_id::create("err_inject");
                    req.txn_type = VIO_TXN_INJECT_ERROR;

                    // Pick a random error type
                    err_idx = $urandom_range(0, 5);
                    case (err_idx)
                        0: req.vq_error_type = VQ_ERR_ZERO_LEN_BUF;
                        1: req.vq_error_type = VQ_ERR_OOB_INDEX;
                        2: req.vq_error_type = VQ_ERR_WRONG_FLAGS;
                        3: req.vq_error_type = VQ_ERR_AVAIL_RING_OVERFLOW;
                        4: req.vq_error_type = VQ_ERR_STALE_DESC;
                        5: req.vq_error_type = VQ_ERR_SPURIOUS_INTERRUPT;
                        default: req.vq_error_type = VQ_ERR_ZERO_LEN_BUF;
                    endcase

                    start_item(req, -1, vf_seqrs[target_vf]);
                    finish_item(req);

                    `uvm_info("STRESS_VSEQ", $sformatf(
                        "Error inject on VF %0d: %s",
                        target_vf, req.vq_error_type.name()), UVM_HIGH)
                end
            end

            // Activity 4: Random dynamic reconfig (MQ resize, MAC change)
            begin : random_reconfig
                while (!stop_flag) begin
                    int unsigned target_vf;
                    virtio_ctrl_seq ctrl_s;
                    int unsigned reconfig_type;

                    #($urandom_range(20000, 80000));
                    if (stop_flag) break;

                    target_vf = $urandom_range(0, num_vfs - 1);
                    reconfig_type = $urandom_range(0, 1);

                    ctrl_s = virtio_ctrl_seq::type_id::create("reconfig_ctrl");

                    case (reconfig_type)
                        0: begin
                            // MAC address change
                            ctrl_s.ctrl_class = VIRTIO_NET_CTRL_CLS_MAC;
                            ctrl_s.ctrl_cmd   = VIRTIO_NET_CTRL_MAC_ADDR_SET;
                            ctrl_s.ctrl_data  = new[6];
                            foreach (ctrl_s.ctrl_data[b])
                                ctrl_s.ctrl_data[b] = $urandom_range(0, 255);
                            ctrl_s.ctrl_data[0] = ctrl_s.ctrl_data[0] & 8'hFE;  // unicast
                        end
                        1: begin
                            // Promisc toggle
                            ctrl_s.ctrl_class = VIRTIO_NET_CTRL_CLS_RX;
                            ctrl_s.ctrl_cmd   = VIRTIO_NET_CTRL_RX_PROMISC;
                            ctrl_s.ctrl_data  = new[1];
                            ctrl_s.ctrl_data[0] = $urandom_range(0, 1);
                        end
                        default: ;
                    endcase

                    ctrl_s.start(vf_seqrs[target_vf]);

                    `uvm_info("STRESS_VSEQ", $sformatf(
                        "Reconfig on VF %0d: type=%0d", target_vf, reconfig_type), UVM_HIGH)
                end
            end

            // Activity 5: Duration watchdog
            begin : duration_watchdog
                while (total_sent < duration_packets) begin
                    #100;
                end
                stop_flag = 1;
                `uvm_info("STRESS_VSEQ", $sformatf(
                    "Duration reached: %0d/%0d packets sent",
                    total_sent, duration_packets), UVM_LOW)
            end

        join_any

        // Signal all activities to stop
        stop_flag = 1;
        #1000;  // allow pending operations to drain
        disable stress_activities;

        // Shutdown: stop + reset all VFs
        foreach (vf_seqrs[i]) begin
            virtio_transaction stop_req, reset_req;

            stop_req = virtio_transaction::type_id::create($sformatf("final_stop_vf%0d", i));
            stop_req.txn_type = VIO_TXN_STOP_DP;
            start_item(stop_req, -1, vf_seqrs[i]);
            finish_item(stop_req);

            reset_req = virtio_transaction::type_id::create($sformatf("final_reset_vf%0d", i));
            reset_req.txn_type = VIO_TXN_RESET;
            start_item(reset_req, -1, vf_seqrs[i]);
            finish_item(reset_req);
        end

        // Post-stress verification is handled by env report_phase:
        // - Scoreboard checks for mismatches
        // - host_mem.leak_check() for descriptor leaks
        // - iommu.leak_check() for DMA mapping leaks

        `uvm_info("STRESS_VSEQ", $sformatf(
            "Stress complete: %0d total packets sent across %0d VFs",
            total_sent, num_vfs), UVM_LOW)
    endtask

endclass : virtio_stress_vseq

`endif // VIRTIO_STRESS_VSEQ_SV
