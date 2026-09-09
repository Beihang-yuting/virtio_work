`ifndef VIRTIO_RX_SEQ_SV
`define VIRTIO_RX_SEQ_SV

// ============================================================================
// virtio_rx_seq (seq/base)
//
// 收包等待序列:发送 VIO_TXN_WAIT_PKTS,阻塞等待 driver 收到 expected_count
// 个报文或超时(timeout_ns),然后把 driver 回填的 received_pkts 拷入
// received 供调用方检查。超时属于正常返回路径:received.size() 可能小于
// expected_count,是否报错由调用场景决定,本序列只打印统计。
// 约束意图:默认期望 1..64 个报文,timeout 不随机(50us 固定默认)。
// ============================================================================

class virtio_rx_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_rx_seq)

    rand int unsigned expected_count;
    int unsigned      timeout_ns;

    // Output: received packets
    uvm_object received[$];

    constraint c_defaults {
        expected_count inside {[1:64]};
    }

    // 构造函数:默认等 1 个报文、50us 超时。
    function new(string name = "virtio_rx_seq");
        super.new(name);
        expected_count = 1;
        timeout_ns     = 50000;
    endfunction

    // 发送 WAIT_PKTS 事务并阻塞;副作用是把收到的报文对象填入 received。
    // 边界:超时返回时 received 可能不满(甚至为空),不在此判错。
    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type       = VIO_TXN_WAIT_PKTS;
        req.expected_count = expected_count;
        req.timeout_ns     = timeout_ns;
        send_configured_txn(req);

        received = req.received_pkts;

        `uvm_info(get_type_name(), $sformatf(
            "RX: received %0d/%0d packets (timeout=%0dns)",
            received.size(), expected_count, timeout_ns), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_RX_SEQ_SV
