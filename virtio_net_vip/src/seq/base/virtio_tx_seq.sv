`ifndef VIRTIO_TX_SEQ_SV
`define VIRTIO_TX_SEQ_SV

// ============================================================================
// virtio_tx_seq (seq/base)
//
// 发包序列:发送一条 VIO_TXN_SEND_PKTS 事务。注意所有权/语义:事务真正
// 携带的是 packet_items 里的报文对象(body 逐个拷入 req.packets),
// num_packets 只是随机化 knob/场景意图,body 并不使用它——packet_items
// 为空时事务不带 payload,由 driver 决定如何处理(参见
// virtio_live_migration_seq 文件头的说明)。报文对象由调用方创建并持有,
// 本序列只传引用。
// 约束意图:默认 1..64 包、队列 0..15、直接描述符(可选 indirect)。
// ============================================================================

class virtio_tx_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_tx_seq)

    rand int unsigned num_packets;
    rand int unsigned queue_id;
    rand bit          use_indirect;

    // Packet items to send (populated externally or via pre_body)
    uvm_object packet_items[$];

    constraint c_defaults {
        num_packets inside {[1:64]};
        queue_id    inside {[0:15]};
        use_indirect == 0;
    }

    // 构造函数:默认 1 包、队列 0、直接描述符。
    function new(string name = "virtio_tx_seq");
        super.new(name);
        num_packets  = 1;
        queue_id     = 0;
        use_indirect = 0;
    endfunction

    // 把 packet_items 拷入事务并阻塞发送;完成即返回,发送结果的核对交给
    // scoreboard/上层场景。
    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type = VIO_TXN_SEND_PKTS;
        req.queue_id = queue_id;
        req.indirect = use_indirect;

        foreach (packet_items[i])
            req.packets.push_back(packet_items[i]);

        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "TX: sent %0d packets on queue %0d (indirect=%0b)",
            req.packets.size(), queue_id, use_indirect), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_TX_SEQ_SV
