// 目录层次：src/dpu_priv；DPU 私有环驱动协议。依赖私有 ops/FSM 与
// dpu_priv_driver_config（借用，env_cfg 按 service key 注入）。不访问标准 status/MSI-X；
// 复位与关机必须由控制后端确认停 DMA，失败保留资源并进入错误态。
`ifndef DPU_PRIV_DRIVER_PROTOCOL_SV
`define DPU_PRIV_DRIVER_PROTOCOL_SV

class dpu_priv_driver_protocol extends virtio_driver_protocol;
    `uvm_object_utils(dpu_priv_driver_protocol)

    // 本 Function 的私有配置；prepare/bind 前由 Function 注入。
    dpu_priv_driver_config private_cfg;

    // 构造不访问设备。
    function new(string name = "dpu_priv_driver_protocol");
        super.new(name);
        private_cfg = null;
    endfunction

    virtual function string protocol_name();
        return "dpu_priv";
    endfunction

    // 私有协议的状态控制由 AF/mailbox 后端负责。
    virtual function bit allows_status_access();
        return 0;
    endfunction

    virtual function bit requires_verified_reset();
        return 1;
    endfunction

    // 校验私有配置与 VQ_CUSTOM/polling 行为，创建私有 ops/FSM；已提供的对象类型冲突时拒绝。
    virtual function bit prepare_candidates(
        string label, uvm_component parent, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
        dpu_priv_atomic_ops private_ops;
        dpu_priv_auto_fsm private_fsm;
        string why;

        why = "private_cfg 未注入";
        if ((private_cfg == null) ||
            !private_cfg.validate(behavior.num_queue_pairs, why) ||
            behavior.vq_type != VQ_CUSTOM || behavior.irq_mode != IRQ_POLLING) begin
            `uvm_error("FUNCTION_BIND", {"私有驱动配置非法: ", why})
            return 0;
        end
        if (candidate_ops == null)
            candidate_ops = dpu_priv_atomic_ops::type_id::create({label, "_ops"});
        if (candidate_fsm == null)
            candidate_fsm = dpu_priv_auto_fsm::type_id::create({label, "_fsm"});
        if (!$cast(private_ops, candidate_ops) || !$cast(private_fsm, candidate_fsm)) begin
            `uvm_error("FUNCTION_BIND", "私有配置与已绑定 ops/FSM 类型冲突")
            return 0;
        end
        return (candidate_ops != null) && (candidate_fsm != null);
    endfunction

    // 冻结一份私有配置与私有配置后端进 ops（有活动队列时 ops 拒绝重配）。
    virtual function bit bind_ops(virtio_atomic_ops ops,
                                  virtio_config_backend backend,
                                  virtio_driver_config_t behavior,
                                  output string why);
        dpu_priv_atomic_ops private_ops;
        dpu_priv_config_backend private_backend;

        why = "";
        if (!$cast(private_ops, ops) || (private_ops == null)) begin
            why = "私有协议要求 dpu_priv_atomic_ops";
            return 0;
        end
        if (!$cast(private_backend, backend) || (private_backend == null)) begin
            why = "私有协议要求 dpu_priv_config_backend";
            return 0;
        end
        return private_ops.configure_private(private_cfg, behavior.num_queue_pairs,
                                             private_backend, why);
    endfunction

    // 私有 Function 复用标准引擎类与同一 ops；私有 buffer 容量不含 Virtio header，
    // 补充由调用方/FSM 控制。
    virtual function void install_dataplane(virtio_net_dataplane dataplane,
                                            virtio_atomic_ops ops, string label);
        if (dataplane == null)
            return;
        dataplane.rx_engine.buf_size = private_cfg.rx_buf_size;
        dataplane.rx_engine.refill_threshold = 0;
    endfunction

    // 发布内存屏障后发送私有 32-bit doorbell。
    virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
        dpu_priv_atomic_ops private_ops;

        if (!$cast(private_ops, ops) || (private_ops == null)) begin
            `uvm_error("VIRTIO_DRV", "私有协议未绑定私有 ops")
            return;
        end
        private_ops.kick_queue(queue_id);
    endtask

    // 私有完成必须经过 ops 回收数据 DMA，不能裸 poll 丢弃 token。
    virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
        int unsigned budget;

        budget = 1;
        if (req.queue_id % 2)
            ops.tx_complete(req.queue_id, req.completed_pkts, budget);
        else
            ops.rx_receive(req.queue_id, req.received_pkts, budget);
    endtask

    // 先停止后台 worker，再确认设备停止 DMA；结果决定 FSM 进入重初始化或错误态。
    virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm,
                       virtio_transaction req);
        if (fsm.state == FSM_RUNNING) fsm.stop_dataplane();
        ops.device_reset_verified(req.success);
        fsm.state = req.success ? FSM_REINIT_REQUIRED : FSM_ERROR;
    endtask
endclass
`endif
