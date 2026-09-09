`ifndef VIRTIO_KICK_SEQ_SV
`define VIRTIO_KICK_SEQ_SV

// ============================================================================
// virtio_kick_seq (seq/base)
//
// 手动 doorbell 序列:以 VIO_TXN_ATOMIC_OP + ATOMIC_KICK 通知设备处理指定
// 队列。走 atomic-op 通道是为了配合 MANUAL 驱动模式——上层自己控制
// avail ring 的发布节奏时,用本序列单独触发 kick,而不是依赖 driver 在
// SEND_PKTS 里自动 kick。
// 约束意图:queue_id 默认落在 0..15 的常规队列范围。
// ============================================================================

class virtio_kick_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_kick_seq)

    rand int unsigned queue_id;

    constraint c_defaults {
        queue_id inside {[0:15]};
    }

    // 构造函数:默认 kick 队列 0。
    function new(string name = "virtio_kick_seq");
        super.new(name);
        queue_id = 0;
    endfunction

    // 发送 ATOMIC_KICK 事务并阻塞到 driver 完成 doorbell 写入;无返回值,
    // 设备是否真正消费队列由后续 poll/中断路径观察。
    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type  = VIO_TXN_ATOMIC_OP;
        req.atomic_op = ATOMIC_KICK;
        req.queue_id  = queue_id;
        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "Kick: queue=%0d", queue_id), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_KICK_SEQ_SV
