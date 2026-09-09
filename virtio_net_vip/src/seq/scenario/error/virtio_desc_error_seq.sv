`ifndef VIRTIO_DESC_ERROR_SEQ_SV
`define VIRTIO_DESC_ERROR_SEQ_SV

// ============================================================================
// virtio_desc_error_seq (seq/scenario/error)
//
// 描述符级错误注入场景:通过 VIO_TXN_INJECT_ERROR 把 err_type(取值范围
// 即 virtqueue_error_e 全集:环链成环、越界索引、屏障缺失等)配置到队列 0
// 的错误注入器,然后再发一个 TX,让注入的错误在真实数据路径上被触发/
// 消费。取舍:错误如何落到 ring 字节由 virtqueue_error_injector 决定,
// 本序列只声明语义错误类型并给出触发流量。
// 依赖:driver 对 INJECT_ERROR 的路由 + virtio_tx_seq。
// ============================================================================

class virtio_desc_error_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_desc_error_seq)

    rand virtqueue_error_e err_type;

    // 构造函数:错误类型不给默认值,由随机化或调用方指定。
    function new(string name = "virtio_desc_error_seq");
        super.new(name);
    endfunction

    // 正常启动 -> 注入 err_type 到队列 0 -> 发 1 包触发;错误的检出与
    // 恢复由 driver/scoreboard 负责观测。
    virtual task body();
        virtio_transaction req;

        do_init();
        send_txn(VIO_TXN_START_DP);

        `uvm_info(get_type_name(), $sformatf(
            "Injecting descriptor error: %s", err_type.name()), UVM_MEDIUM)

        req = virtio_transaction::type_id::create("req");
        req.txn_type      = VIO_TXN_INJECT_ERROR;
        req.vq_error_type = err_type;
        req.queue_id      = 0;
        send_configured_txn(req);

        // Try to send a packet after error injection
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_err");
            tx_s.num_packets         = 1;
            tx_s.queue_id            = 0;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), $sformatf(
            "Descriptor error test complete: %s", err_type.name()), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_DESC_ERROR_SEQ_SV
