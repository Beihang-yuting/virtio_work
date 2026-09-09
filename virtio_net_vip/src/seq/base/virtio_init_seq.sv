`ifndef VIRTIO_INIT_SEQ_SV
`define VIRTIO_INIT_SEQ_SV

// ============================================================================
// virtio_init_seq (seq/base)
//
// 标准设备初始化序列:发送一条 VIO_TXN_INIT 事务,由 driver 完成
// reset -> 状态机推进 -> feature 协商 -> 队列建立的完整流程(细节在 driver
// 侧,本序列只声明目标配置)。driver_features 非零时优先生效,否则退回
// 基类的 negotiated_features——这样上层既可以显式指定要协商的 feature,
// 也可以沿用父序列传下来的协商结果。
// 随机约束意图:默认 1..8 个队列对、split ring,保证未加约束的随机场景
// 也落在常规配置内。
// ============================================================================

class virtio_init_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_init_seq)

    rand int unsigned     num_queue_pairs;
    rand virtqueue_type_e vq_type;
    rand bit [63:0]       driver_features;

    constraint c_defaults {
        num_queue_pairs inside {[1:8]};
        vq_type == VQ_SPLIT;
    }

    // 构造函数:给出不随机化时的保守默认值(1 对队列、feature 全零即
    // "跟随 negotiated_features")。
    function new(string name = "virtio_init_seq");
        super.new(name);
        num_queue_pairs = 1;
        driver_features = '0;
    endfunction

    // 发送 INIT 事务并阻塞到 driver 初始化完成;feature 取值规则见文件头。
    // 失败(如设备拒绝 feature)由 driver 上报,本序列不做结果检查。
    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type  = VIO_TXN_INIT;
        req.num_pairs = num_queue_pairs;
        req.vq_type   = vq_type;
        req.features  = (driver_features != '0) ? driver_features : negotiated_features;
        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "Init complete: pairs=%0d vq_type=%s features=0x%016h",
            num_queue_pairs, vq_type.name(), req.features), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_INIT_SEQ_SV
