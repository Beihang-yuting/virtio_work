// 目录层次：src/dpu_priv；DPU 私有环驱动协议：只声明私有 Function 与标准 virtio 的差异
// （能力、队列格式、MANUAL kick/poll、复位语义），ops/FSM 均为通用实现。依赖
// dpu_priv_driver_config（借用，env_cfg 按 service key 注入）与 Function 提交时选定的
// dpu_priv_config_backend。复位与关机必须由控制后端确认停 DMA，失败保留资源。
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

    // 私有设备没有标准 status 寄存器，MANUAL 原始 status 访问被 driver 拒绝。
    virtual function bit allows_status_access();
        return 0;
    endfunction

    virtual function bit requires_verified_reset();
        return 1;
    endfunction

    // 私有环没有 virtio-net control VQ；队列数只能停机重配；快照不描述 CQ 与私有控制面。
    virtual function bit has_ctrl_vq();
        return 0;
    endfunction

    virtual function bit supports_mq();
        return 0;
    endfunction

    virtual function bit supports_migration();
        return 0;
    endfunction

    // 私有 Function 只使用私有环，与配置值无关。
    virtual function virtqueue_type_e queue_format(virtqueue_type_e requested);
        return VQ_CUSTOM;
    endfunction

    // 校验私有配置与 polling 行为，再创建通用 ops/FSM 候选。
    virtual function bit prepare_candidates(
        string label, uvm_component parent, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
        string why;

        why = "private_cfg 未注入";
        if ((private_cfg == null) ||
            !private_cfg.validate(behavior.num_queue_pairs, why) ||
            (behavior.irq_mode != IRQ_POLLING)) begin
            `uvm_error("FUNCTION_BIND", {"私有驱动配置非法: ", why})
            return 0;
        end
        return super.prepare_candidates(label, parent, behavior,
                                        candidate_ops, candidate_fsm);
    endfunction

    // 把私有配置冻结进 Function 选定的私有配置后端，再把后端与协议绑定进 ops。ops 仍有
    // 活动队列或后端不是私有后端时拒绝，不改动 ops 与后端。
    virtual function bit bind_ops(virtio_atomic_ops ops,
                                  virtio_config_backend backend,
                                  virtio_driver_config_t behavior,
                                  output string why);
        dpu_priv_config_backend priv_be;

        why = "";
        if ((private_cfg == null) || (ops == null) || ops.has_active_queues()) begin
            why = "private 配置为空或仍有活动队列";
            return 0;
        end
        if (!private_cfg.validate(behavior.num_queue_pairs, why))
            return 0;
        if (!$cast(priv_be, backend) || (priv_be == null)) begin
            why = "私有协议要求 dpu_priv_config_backend";
            return 0;
        end
        priv_be.bind_private(private_cfg, behavior.num_queue_pairs);
        ops.config_backend = backend;
        ops.negotiated_features = 0;
        ops.protocol = this;
        return 1;
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

    // MANUAL ATOMIC_KICK：发布屏障后经私有后端写 32-bit doorbell。
    virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
        ops.kick_queue(queue_id);
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
