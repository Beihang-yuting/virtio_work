`ifndef VIRTIO_DRIVER_SV
`define VIRTIO_DRIVER_SV

// ============================================================================
// virtio_driver
//
// 目录层次：src/agent；统一事务分派器，依赖 transaction、ops 和 FSM。
// 借用 Function 注入的 ops/FSM，不持有 ring/DMA；私有模式的通知、完成和复位
// 仍交给私有 ops，禁止绕过其资源所有权或访问标准 status 寄存器。
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

    // 建立 UVM driver 组件；ops/FSM 在 Function 提交绑定时注入。
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ========================================================================
    // Run Phase -- forever loop pulling transactions from sequencer
    // ========================================================================

    // 持续获取事务并在分派结束后确认完成；不单独持有事务资源或创建 DMA。
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

    // 按事务类型调用统一 API；私有复位须先停止后台 worker，再确认设备停止 DMA。
    protected virtual task process_transaction(virtio_transaction req);
        bit setup_ok;
        dpu_priv_atomic_ops private_ops;
        bit is_private;
        is_private = $cast(private_ops, ops);

        case (req.txn_type)
            // ----- Lifecycle -----
            VIO_TXN_INIT:       fsm.full_init();
            VIO_TXN_RESET: begin
                if (is_private) begin
                    if (fsm.state == FSM_RUNNING) fsm.stop_dataplane();
                    ops.device_reset_verified(req.success);
                    fsm.state = req.success ? FSM_REINIT_REQUIRED : FSM_ERROR;
                end else ops.device_reset();
            end
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
            VIO_TXN_RESTORE:    fsm.restore_from_migration(req.snapshot, req.success);

            // ----- Queue management -----
            VIO_TXN_RESET_QUEUE: fsm.reset_single_queue(req.queue_id);
            VIO_TXN_SETUP_QUEUE: begin
                ops.setup_queue(req.queue_id, req.queue_size, req.vq_type, setup_ok);
                req.success = setup_ok;
            end

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

    // MANUAL 操作仍受所选协议约束；私有 kick/poll 经 ops 保留通知与回收语义。
    protected virtual task dispatch_atomic_op(virtio_transaction req);
        bit setup_ok;
        dpu_priv_atomic_ops private_ops;
        bit is_private;
        int unsigned private_poll_budget = 1;

        // 私有协议的状态控制由 AF/mailbox 后端负责；显式拒绝标准状态访问，
        // 其余请求继续分派到同一 Function 的 ops，保持 DMA 所有权一致。
        is_private = $cast(private_ops, ops);
        if (is_private && ((req.atomic_op == ATOMIC_SET_STATUS) ||
                           (req.atomic_op == ATOMIC_READ_STATUS))) begin
            req.success = 0;
            `uvm_error("VIRTIO_DRV", "私有驱动不能访问标准 Virtio status 寄存器")
            return;
        end

        case (req.atomic_op)
            ATOMIC_SET_STATUS:
                ops.transport.write_device_status(req.status_val);

            ATOMIC_READ_STATUS:
                ops.transport.read_device_status(req.status_val);

            ATOMIC_SETUP_QUEUE: begin
                ops.setup_queue(req.queue_id, req.queue_size, req.vq_type, setup_ok);
                req.success = setup_ok;
            end

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
                if (is_private)
                    private_ops.kick_queue(req.queue_id);
                else begin
                    vq = ops.vq_mgr.get_queue(req.queue_id);
                    if (vq != null)
                        vq.kick();
                    else
                        `uvm_error("VIRTIO_DRV",
                            $sformatf("ATOMIC_KICK: queue %0d not found", req.queue_id))
                end
            end

            ATOMIC_POLL_USED: begin
                uvm_object token;
                int unsigned len;
                virtqueue_base vq;
                // 私有完成必须经过 ops 回收数据 DMA，不能裸 poll 丢弃 token。
                if (is_private) begin
                    if (req.queue_id % 2)
                        ops.tx_complete(req.queue_id, req.completed_pkts, private_poll_budget);
                    else
                        ops.rx_receive(req.queue_id, req.received_pkts, private_poll_budget);
                end else begin
                    vq = ops.vq_mgr.get_queue(req.queue_id);
                    if (vq != null)
                        void'(vq.poll_used(token, len));
                    else
                        `uvm_error("VIRTIO_DRV",
                            $sformatf("ATOMIC_POLL_USED: queue %0d not found", req.queue_id))
                end
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

    // 将故障注入委托给目标队列；私有回调对不支持的错误类型显式报错，不猜位布局。
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
