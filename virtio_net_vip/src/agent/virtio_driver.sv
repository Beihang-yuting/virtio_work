`ifndef VIRTIO_DRIVER_SV
`define VIRTIO_DRIVER_SV

// ============================================================================
// virtio_driver
//
// UVM driver that receives virtio_transaction items from the sequencer and
// dispatches to virtio_atomic_ops (MANUAL mode) or virtio_auto_fsm (AUTO mode)
// based on the transaction type.
//
// Depends on:
//   - virtio_transaction (sequence item)
//   - virtio_atomic_ops  (low-level atomic operations)
//   - virtio_auto_fsm    (lifecycle state machine)
// ============================================================================

class virtio_driver extends uvm_driver #(virtio_transaction);
    `uvm_component_utils(virtio_driver)

    // ===== References (injected by agent in connect_phase) =====
    virtio_atomic_ops   ops;
    virtio_auto_fsm     fsm;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ========================================================================
    // Run Phase -- forever loop pulling transactions from sequencer
    // ========================================================================

    virtual task run_phase(uvm_phase phase);
        forever begin
            seq_item_port.get_next_item(req);
            `uvm_info("VIRTIO_DRV",
                $sformatf("Processing: %s", req.convert2string()), UVM_HIGH)
            process_transaction(req);
            seq_item_port.item_done();
        end
    endtask

    // ========================================================================
    // Transaction Dispatcher
    //
    // Routes each transaction type to the appropriate ops/fsm method.
    // ========================================================================

    protected virtual task process_transaction(virtio_transaction req);
        case (req.txn_type)
            // ----- Lifecycle -----
            VIO_TXN_INIT:       fsm.full_init();
            VIO_TXN_RESET:      ops.device_reset();
            VIO_TXN_SHUTDOWN:   fsm.stop_dataplane();

            // ----- Data plane (AUTO mode) -----
            VIO_TXN_SEND_PKTS:  fsm.send_packets(req.packets, req.queue_id);
            VIO_TXN_WAIT_PKTS:  fsm.wait_packets(req.expected_count, req.received_pkts, req.timeout_ns);
            VIO_TXN_START_DP:   fsm.start_dataplane();
            VIO_TXN_STOP_DP:    fsm.stop_dataplane();

            // ----- Control plane -----
            VIO_TXN_CTRL_CMD:   ops.ctrl_send(req.ctrl_class, req.ctrl_cmd, req.ctrl_data, req.ctrl_ack);
            VIO_TXN_SET_MQ:     fsm.configure_mq(req.num_pairs);
            VIO_TXN_SET_RSS:    fsm.configure_rss(req.rss_cfg);

            // ----- Atomic ops (MANUAL mode) -----
            VIO_TXN_ATOMIC_OP:  dispatch_atomic_op(req);

            // ----- Migration -----
            VIO_TXN_FREEZE:     fsm.freeze_for_migration(req.snapshot);
            VIO_TXN_RESTORE:    fsm.restore_from_migration(req.snapshot);

            // ----- Queue management -----
            VIO_TXN_RESET_QUEUE: fsm.reset_single_queue(req.queue_id);
            VIO_TXN_SETUP_QUEUE: ops.setup_queue(req.queue_id, req.queue_size, req.vq_type);

            // ----- Error injection -----
            VIO_TXN_INJECT_ERROR: dispatch_error_injection(req);

            default:
                `uvm_error("VIRTIO_DRV",
                    $sformatf("Unknown txn_type: %s", req.txn_type.name()))
        endcase
    endtask

    // ========================================================================
    // Atomic Operation Dispatcher (MANUAL mode)
    //
    // Routes individual atomic operations for fine-grained sequence control.
    // ========================================================================

    protected virtual task dispatch_atomic_op(virtio_transaction req);
        case (req.atomic_op)
            ATOMIC_SET_STATUS:
                ops.transport.write_device_status(req.status_val);

            ATOMIC_READ_STATUS:
                ops.transport.read_device_status(req.status_val);

            ATOMIC_SETUP_QUEUE:
                ops.setup_queue(req.queue_id, req.queue_size, req.vq_type);

            ATOMIC_TX_SUBMIT:
                ops.tx_submit(req.queue_id, req.net_hdr, req.pkt,
                              req.indirect, req.desc_id);

            ATOMIC_TX_COMPLETE:
                ops.tx_complete(req.queue_id, req.completed_pkts, req.budget);

            ATOMIC_RX_REFILL:
                ops.rx_refill(req.queue_id, req.num_bufs);

            ATOMIC_RX_RECEIVE:
                ops.rx_receive(req.queue_id, req.received_pkts, req.budget);

            ATOMIC_KICK: begin
                virtqueue_base vq;
                vq = ops.vq_mgr.get_queue(req.queue_id);
                if (vq != null)
                    vq.kick();
                else
                    `uvm_error("VIRTIO_DRV",
                        $sformatf("ATOMIC_KICK: queue %0d not found", req.queue_id))
            end

            ATOMIC_POLL_USED: begin
                uvm_object token;
                int unsigned len;
                virtqueue_base vq;
                vq = ops.vq_mgr.get_queue(req.queue_id);
                if (vq != null)
                    void'(vq.poll_used(token, len));
                else
                    `uvm_error("VIRTIO_DRV",
                        $sformatf("ATOMIC_POLL_USED: queue %0d not found", req.queue_id))
            end

            ATOMIC_CTRL_SEND:
                ops.ctrl_send(req.ctrl_class, req.ctrl_cmd,
                              req.ctrl_data, req.ctrl_ack);

            default:
                `uvm_error("VIRTIO_DRV",
                    $sformatf("Unknown atomic_op: %s", req.atomic_op.name()))
        endcase
    endtask

    // ========================================================================
    // Error Injection Dispatcher
    //
    // Injects descriptor/barrier/IOMMU errors via the virtqueue interface.
    // ========================================================================

    protected virtual task dispatch_error_injection(virtio_transaction req);
        virtqueue_base vq;
        vq = ops.vq_mgr.get_queue(req.queue_id);

        if (vq != null) begin
            vq.inject_desc_error(req.vq_error_type);
            `uvm_info("VIRTIO_DRV",
                $sformatf("Injected error: queue=%0d type=%s",
                          req.queue_id, req.vq_error_type.name()), UVM_MEDIUM)
        end else begin
            `uvm_error("VIRTIO_DRV",
                $sformatf("INJECT_ERROR: queue %0d not found", req.queue_id))
        end
    endtask

endclass : virtio_driver

`endif // VIRTIO_DRIVER_SV
