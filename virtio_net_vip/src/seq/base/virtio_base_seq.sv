`ifndef VIRTIO_BASE_SEQ_SV
`define VIRTIO_BASE_SEQ_SV

// ============================================================================
// virtio_base_seq (seq/base)
//
// 所有 virtio 序列的公共基类:把"构造 virtio_transaction 并通过 sequencer
// 下发"的样板收拢在这里,派生序列只需描述场景本身。
//
// 中文契约:
// - drv_cfg / negotiated_features 由上层(test、虚拟序列或父序列)在 start()
//   之前注入,派生序列创建子序列时必须逐层向下传递;本类不做任何默认协商。
// - 本类不持有 env 组件句柄,唯一交互通道是 m_sequencer(由 start() 绑定的
//   per-VF sequencer),事务的真正执行在 driver 侧完成。
// - 序列对象由调用方 create 并 start,结束后交给 UVM 引用计数回收;本类
//   不缓存事务句柄,也不负责释放。
// 主要依赖:virtio_transaction(事务类型)、virtio_init_seq(do_init 用,
// 因相互引用而前向声明)。
// ============================================================================

// Forward declaration for circular dependency
typedef class virtio_init_seq;

// Base class for all virtio sequences
class virtio_base_seq extends uvm_sequence #(virtio_transaction);
    `uvm_object_utils(virtio_base_seq)

    // Common configuration
    virtio_driver_config_t  drv_cfg;
    bit [63:0]              negotiated_features;

    // 构造函数:仅透传名称;配置字段留待上层注入,不在此赋默认值。
    function new(string name = "virtio_base_seq");
        super.new(name);
    endfunction

    // Helper: create and send a transaction by type
    protected virtual task send_txn(virtio_txn_type_e txn_type);
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type = txn_type;
        start_item(req);
        finish_item(req);
    endtask

    // Helper: send a pre-built transaction
    protected virtual task send_configured_txn(virtio_transaction req);
        start_item(req);
        finish_item(req);
    endtask

    // Helper: standard init -> start dataplane
    protected virtual task do_init();
        virtio_init_seq init_s = virtio_init_seq::type_id::create("init_s");
        init_s.drv_cfg = drv_cfg;
        init_s.negotiated_features = negotiated_features;
        init_s.start(m_sequencer);
    endtask

    // Helper: standard reset
    protected virtual task do_reset();
        send_txn(VIO_TXN_RESET);
    endtask

endclass

`endif // VIRTIO_BASE_SEQ_SV
