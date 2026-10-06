// 目录层次：src/dpu_priv；在公共 FSM API 下执行 DPU 私有环生命周期。
// 依赖 dpu_priv_atomic_ops；复用有停止确认的收发 worker，不执行 virtio 特性协商。
// FSM 借用 ops/配置，ops 持有 DMA 资源；必须先 stop_dataplane 再复位或释放队列。
`ifndef DPU_PRIV_AUTO_FSM_SV
`define DPU_PRIV_AUTO_FSM_SV

// 通过 do_full_init 的虚钩子替换标准状态寄存器流程，统一 sequence 无需另写建队代码。
// 当前使用 polling；标准配置变化、中断自适应、迁移和 control VQ 不适用于此协议。
class dpu_priv_auto_fsm extends virtio_auto_fsm;
    `uvm_object_utils(dpu_priv_auto_fsm)

    // 复用基类停止事件和状态计数；构造不访问设备。
    function new(string name = "dpu_priv_auto_fsm");
        super.new(name);
    endfunction

    // 私有初始化：确认复位停 DMA、创建 RX/TX 队列后进入 READY；失败进入 ERROR。
    // 不调用 BAR 枚举/标准 feature handshake；平台须在控制后端执行前准备好 PCIe 路径。
    protected virtual task do_full_init();
        dpu_priv_atomic_ops private_ops;
        dpu_priv_queue_context_t ctx;
        bit ok;
        if ((state == FSM_RUNNING) || !$cast(private_ops, ops) ||
            (drv_cfg.vq_type != VQ_CUSTOM) || (drv_cfg.irq_mode != IRQ_POLLING)) begin
            `uvm_error("DPU_PRIV_FSM", "初始化要求私有 ops、VQ_CUSTOM、polling 和已停止的数据面")
            return;
        end
        state = FSM_NEGOTIATING;
        ops.device_reset_verified(ok);
        if (!ok) begin state = FSM_ERROR; return; end
        active_num_pairs = drv_cfg.num_queue_pairs;
        num_total_queues = 2*active_num_pairs;
        state = FSM_QUEUE_SETUP;
        ops.setup_all_queues(active_num_pairs, VQ_CUSTOM, drv_cfg.queue_size, ok);
        if (!ok) begin state = FSM_ERROR; return; end
        // queue_size=0 表示使用私有默认 512；背景补 RX 需要解析后的实际数量。
        if (private_ops.get_queue_context(0, ctx)) drv_cfg.queue_size = ctx.queue_size;
        state = FSM_READY;
    endtask

    // 私有协议没有标准 config-change 寄存器；保留可停止 worker，避免后台误读 BAR。
    protected virtual task config_change_handler(int unsigned worker_epoch);
        while (dataplane_worker_may_run(worker_epoch)) @stop_event;
    endtask

    // 当前固定 polling，后台不访问标准 MSI-X 自适应配置；随停止事件退出。
    protected virtual task adaptive_irq_loop(int unsigned worker_epoch);
        while (dataplane_worker_may_run(worker_epoch)) @stop_event;
    endtask

    // 动态 MQ 需设备特定 mailbox 事务；当前只允许初始化前通过配置改变队列数量。
    protected virtual task do_configure_mq(int unsigned num_pairs);
        `uvm_error("DPU_PRIV_FSM", "私有动态 MQ 尚无设备控制事务，请停机后重配")
    endtask

    // 私有快照尚未描述 CQ/私有控制面，明确拒绝而不修改快照或设备。
    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);
        `uvm_error("DPU_PRIV_FSM", "私有环暂不支持迁移快照")
    endtask

    // 拒绝不兼容的标准迁移恢复，保持现场并返回失败。
    protected virtual task do_restore_from_migration(virtio_device_snapshot_t snap,
                                                       output bit ok);
        ok = 0;
        `uvm_error("DPU_PRIV_FSM", "私有环暂不支持迁移恢复")
    endtask

    // 停止后台 worker 后重建单队列；停 DMA 失败时保留队列且进入 ERROR，不继续分配。
    virtual task reset_single_queue(int unsigned queue_id);
        bit was_running, ok;
        was_running = (state == FSM_RUNNING);
        if (was_running) stop_dataplane();
        ops.teardown_queue(queue_id);
        if (ops.vq_mgr.has_queue(queue_id)) begin state = FSM_ERROR; return; end
        ops.setup_queue(queue_id, drv_cfg.queue_size, VQ_CUSTOM, ok);
        if (!ok) begin state = FSM_ERROR; return; end
        state = FSM_READY;
        if (was_running) start_dataplane();
    endtask
endclass
`endif
