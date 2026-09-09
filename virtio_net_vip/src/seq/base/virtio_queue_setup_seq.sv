`ifndef VIRTIO_QUEUE_SETUP_SEQ_SV
`define VIRTIO_QUEUE_SETUP_SEQ_SV

// ============================================================================
// virtio_queue_setup_seq (seq/base)
//
// 单队列配置序列:发送 VIO_TXN_SETUP_QUEUE,让 driver 为指定 queue_id 分配
// ring 内存并写入队列寄存器。独立于 virtio_init_seq 存在,便于边界/动态
// 场景单独重配某个队列(如 queue reset 后重建、非常规 size 测试)。
// 约束意图:size 限定为 virtio 规范允许的 2 的幂(16..1024),默认 split。
// ============================================================================

class virtio_queue_setup_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_queue_setup_seq)

    rand int unsigned     queue_id;
    rand int unsigned     queue_size;
    rand virtqueue_type_e vq_type;

    constraint c_defaults {
        queue_id   inside {[0:15]};
        queue_size inside {16, 32, 64, 128, 256, 512, 1024};
        vq_type == VQ_SPLIT;
    }

    // 构造函数:默认队列 0、256 深度、split ring。
    function new(string name = "virtio_queue_setup_seq");
        super.new(name);
        queue_id   = 0;
        queue_size = 256;
        vq_type    = VQ_SPLIT;
    endfunction

    // 发送 SETUP_QUEUE 事务并阻塞到配置完成;非法 size/id 的拒绝行为由
    // driver/设备侧决定,本序列不做本地校验。
    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type   = VIO_TXN_SETUP_QUEUE;
        req.queue_id   = queue_id;
        req.queue_size = queue_size;
        req.vq_type    = vq_type;
        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "Queue setup: id=%0d size=%0d type=%s",
            queue_id, queue_size, vq_type.name()), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_QUEUE_SETUP_SEQ_SV
