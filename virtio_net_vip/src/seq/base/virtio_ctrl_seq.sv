`ifndef VIRTIO_CTRL_SEQ_SV
`define VIRTIO_CTRL_SEQ_SV

// ============================================================================
// virtio_ctrl_seq (seq/base)
//
// 控制面单命令序列:向 driver 下发一条 VIO_TXN_CTRL_CMD 事务,由 driver 经
// ctrl virtqueue 发给设备,并把设备返回的 ack 回写到 ack_result 供调用方
// 检查。ctrl_class/ctrl_cmd 可随机化,ctrl_data 由调用方按具体命令的
// payload 格式填好——本序列不理解也不校验各命令的数据布局。
// 前置条件:driver 已完成初始化且协商出 CTRL_VQ,否则行为取决于 driver
// 的错误处理。依赖 virtio_base_seq 的配置注入约定。
// ============================================================================

class virtio_ctrl_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_ctrl_seq)

    rand virtio_ctrl_class_e ctrl_class;
    rand bit [7:0]           ctrl_cmd;
    byte unsigned            ctrl_data[];

    // Output
    virtio_ctrl_ack_e ack_result;

    // 构造函数:仅透传名称;命令内容由调用方或随机化给定。
    function new(string name = "virtio_ctrl_seq");
        super.new(name);
    endfunction

    // 组装控制命令事务并阻塞发送;完成后把 req.ctrl_ack 拷入 ack_result 并
    // 打印结果。不判断 ack 成败——是否视为错误由调用场景决定。
    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type   = VIO_TXN_CTRL_CMD;
        req.ctrl_class = ctrl_class;
        req.ctrl_cmd   = ctrl_cmd;
        req.ctrl_data  = ctrl_data;
        send_configured_txn(req);

        ack_result = req.ctrl_ack;

        `uvm_info(get_type_name(), $sformatf(
            "CTRL: class=%s cmd=0x%02h ack=%s",
            ctrl_class.name(), ctrl_cmd, ack_result.name()), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_CTRL_SEQ_SV
