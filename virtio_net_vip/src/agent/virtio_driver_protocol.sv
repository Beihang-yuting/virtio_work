`ifndef VIRTIO_DRIVER_PROTOCOL_SV
`define VIRTIO_DRIVER_PROTOCOL_SV

// dataplane 在本文件之后编译；这里只把它作为参数类型使用。
typedef class virtio_net_dataplane;

// ============================================================================
// virtio_driver_protocol
//
// 目录层次：src/agent；一个 Function 的驱动协议（标准 virtio / DPU 私有环）。
// Function 只在 prepare_driver_candidates 中选择一次协议；此后 ops/FSM 候选的创建
// 与校验、协议专属配置冻结、dataplane 引擎安装、MANUAL kick/poll、驱动复位与
// 关机复位语义全部由协议对象分派，driver/function/FSM 不再做类型转换。
// 协议对象不持有 ring/DMA；资源始终归所选 ops 所有。
// ============================================================================

virtual class virtio_driver_protocol extends uvm_object;
    // 构造不访问设备。
    function new(string name = "virtio_driver_protocol");
        super.new(name);
    endfunction

    // 协议名，供日志与测试。
    pure virtual function string protocol_name();
    // MANUAL 事务是否可直接读写标准 virtio status 寄存器。
    pure virtual function bit allows_status_access();
    // 驱动复位与 Function 关机是否必须等待设备确认停 DMA（失败保留全部资源）。
    pure virtual function bit requires_verified_reset();
    // 预检：校验行为配置，按需创建 ops/FSM 候选；已提供的对象类型不符时返回 0。
    // 不访问设备，不冻结配置。
    pure virtual function bit prepare_candidates(
        string label, uvm_component parent, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
    // 提交：把协议专属配置冻结进 ops；失败时 why 说明原因。
    pure virtual function bit bind_ops(virtio_atomic_ops ops,
                                       virtio_driver_config_t behavior,
                                       output string why);
    // 让 Function 的 dataplane 引擎与 sequence/FSM 共用同一个 ops。
    pure virtual function void install_dataplane(virtio_net_dataplane dataplane,
                                                 virtio_atomic_ops ops, string label);
    // MANUAL ATOMIC_KICK。
    pure virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
    // MANUAL ATOMIC_POLL_USED。
    pure virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
    // VIO_TXN_RESET。
    pure virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm,
                            virtio_transaction req);
endclass

// 标准 virtio-pci 驱动：逐字保留 driver/function 原非私有分支行为。
class virtio_standard_driver_protocol extends virtio_driver_protocol;
    `uvm_object_utils(virtio_standard_driver_protocol)

    // 构造不访问设备。
    function new(string name = "virtio_standard_driver_protocol");
        super.new(name);
    endfunction

    virtual function string protocol_name();
        return "standard";
    endfunction

    virtual function bit allows_status_access();
        return 1;
    endfunction

    virtual function bit requires_verified_reset();
        return 0;
    endfunction

    // 未提供时用 factory 创建标准 FSM 与 ops；创建失败留给调用方的空句柄检查报告。
    virtual function bit prepare_candidates(
        string label, uvm_component parent, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
        if (candidate_fsm == null)
            candidate_fsm = virtio_auto_fsm::type_id::create(
                {label, "_fsm"}, parent);
        if (candidate_ops == null)
            candidate_ops = virtio_atomic_ops::type_id::create(
                {label, "_ops"}, parent);
        return 1;
    endfunction

    // 标准驱动没有需要冻结的协议专属配置。
    virtual function bit bind_ops(virtio_atomic_ops ops,
                                  virtio_driver_config_t behavior,
                                  output string why);
        why = "";
        return 1;
    endfunction

    // 标准 dataplane 引擎保持 Function 构造时的默认配置。
    virtual function void install_dataplane(virtio_net_dataplane dataplane,
                                            virtio_atomic_ops ops, string label);
    endfunction

    virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
        virtqueue_base vq;

        vq = ops.vq_mgr.get_queue(queue_id);
        if (vq != null)
            vq.kick();
        else
            `uvm_error("VIRTIO_DRV",
                $sformatf("ATOMIC_KICK: queue %0d not found", queue_id))
    endtask

    virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
        uvm_object token;
        int unsigned len;
        virtqueue_base vq;

        vq = ops.vq_mgr.get_queue(req.queue_id);
        if (vq != null)
            void'(vq.poll_used(token, len));
        else
            `uvm_error("VIRTIO_DRV",
                $sformatf("ATOMIC_POLL_USED: queue %0d not found", req.queue_id))
    endtask

    virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm,
                       virtio_transaction req);
        ops.device_reset();
    endtask
endclass

`endif // VIRTIO_DRIVER_PROTOCOL_SV
