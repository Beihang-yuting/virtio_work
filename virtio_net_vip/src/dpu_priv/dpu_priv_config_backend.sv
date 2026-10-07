// 目录层次：src/dpu_priv；DPU 私有环的配置后端：通用 ops/FSM 对私有 Function 的全部
// 设备副作用都经这里。依赖 dpu_priv_device_control（借用，D 阶段由寄存器级实现替换）
// 与 custom_virtqueue。保存本 Function 冻结的队列参数表，不持有 Host 内存或映射。
// 私有设备没有 virtio status/feature/MSI-X/device-config 寄存器：status 是驱动侧影子
// 值（复位清零），特性恒为 0，device config 全零，队列上限为私有默认环大小，当前固定
// polling，MSI-X 编程为空操作。
`ifndef DPU_PRIV_CONFIG_BACKEND_SV
`define DPU_PRIV_CONFIG_BACKEND_SV

class dpu_priv_config_backend extends virtio_config_backend;
    `uvm_object_utils(dpu_priv_config_backend)

    // 设备控制实现；bind_private 从私有配置注入。
    dpu_priv_device_control control;
    // 冻结的队列参数表（Function 内 RX 偶/TX 奇队列号 → 本地号、doorbell、TX 控制）。
    protected dpu_priv_queue_config queue_cfg[int unsigned];
    protected int unsigned default_size;
    protected int unsigned rx_size;
    protected bit [7:0]    status_shadow;

    // 构造不访问设备；配置由私有协议 bind_ops 冻结进来。
    function new(string name = "dpu_priv_config_backend");
        super.new(name);
        control = null;
        default_size = 0;
        rx_size = 0;
        status_shadow = 0;
    endfunction

    // 冻结一份已校验的私有配置（调用方先 validate，且 ops 无活动队列）。
    function void bind_private(dpu_priv_driver_config cfg, int unsigned pairs);
        control = cfg.control;
        default_size = cfg.default_queue_size;
        rx_size = cfg.rx_buf_size;
        queue_cfg.delete();
        for (int unsigned qid = 0; qid < pairs*2; qid++)
            queue_cfg[qid] = cfg.resolve_queue(qid);
        status_shadow = 0;
    endfunction

    // 统一编程参数 → 私有控制上下文（字段一一对应，私有环 desc_iova 即 ring_iova）。
    static function dpu_priv_queue_context_t to_context(virtio_queue_program_t q);
        dpu_priv_queue_context_t ctx;

        ctx = '{default:0};
        ctx.host_id = q.host_id;
        ctx.bdf = q.bdf;
        ctx.queue_id = q.queue_id;
        ctx.local_qid = q.local_qid;
        ctx.queue_size = q.queue_size;
        ctx.rx_buf_size = q.rx_buf_size;
        ctx.tx_mode = q.tx_mode;
        ctx.ring_iova = q.desc_iova;
        ctx.cq_iova = q.device_iova;
        ctx.ring_bytes = q.ring_bytes;
        ctx.notify_bar = q.notify_bar;
        ctx.notify_offset = q.notify_offset;
        return ctx;
    endfunction

    // 私有 Function 没有 virtio capability 链；AF 声明与 BAR2 qinfo 在 D 阶段接入。
    virtual task discover();
    endtask

    // Function 级复位由控制后端确认停 DMA；成功后影子 status 清零。
    virtual task reset(output bit ok);
        bit done;

        control.reset_device(transport.iommu_host_id(), transport.bdf, done);
        if (done)
            status_shadow = 0;
        ok = done;
    endtask

    virtual task read_status(output bit [7:0] status);
        status = status_shadow;
    endtask

    virtual task write_status(bit [7:0] status);
        status_shadow = status;
    endtask

    virtual task read_device_features(output bit [63:0] features);
        features = 0;
    endtask

    virtual task write_driver_features(bit [63:0] features);
    endtask

    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        accepted = 0;
    endtask

    // 表内队列的上限是私有默认环大小；表外队列返回 0，ops 在建队前拒绝。
    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        max_size = queue_cfg.exists(queue_id) ? default_size : 0;
    endtask

    // 把参数表应用到新建的私有队列（方向、本地号、TX 首描述符控制）与编程参数
    // （本地号、RX 容量、doorbell 位置）；非私有格式或表外队列拒绝。
    virtual function bit prepare_queue(virtqueue_base vq, ref virtio_queue_program_t q);
        custom_virtqueue pvq;
        dpu_priv_queue_config c;

        if (!$cast(pvq, vq) || (pvq == null) || !queue_cfg.exists(q.queue_id)) begin
            `uvm_error("DPU_PRIV_BACKEND", $sformatf(
                "prepare_queue: queue %0d 不是已配置的私有队列", q.queue_id))
            return 0;
        end
        c = queue_cfg[q.queue_id];
        pvq.tx_mode = q.tx_mode;
        pvq.local_qid = c.local_qid;
        pvq.dport_info = c.dport_info;
        pvq.dport_id = c.dport_id;
        pvq.dport_type = c.dport_type;
        pvq.cpu_tx_cos = c.cpu_tx_cos;
        pvq.rss_lag = c.rss_lag;
        pvq.l3_cs = c.l3_cs;
        pvq.l4_cs = c.l4_cs;
        pvq.fwd = c.fwd;
        q.local_qid = c.local_qid;
        q.rx_buf_size = rx_size;
        q.notify_bar = c.notify_bar;
        q.notify_offset = c.notify_offset;
        return 1;
    endfunction

    // 配置并启动一条私有队列；失败时控制后端保证该队列未启动 DMA。
    virtual task configure_queue(virtio_queue_program_t q, output bit ok);
        bit done;

        control.configure_queue(to_context(q), done);
        ok = done;
    endtask

    // 私有队列在 configure_queue 中已经启动。
    virtual task enable_queue(virtio_queue_program_t q, output bit ok);
        ok = 1;
    endtask

    // 停止队列并等待 DMA 排空；只有 ok=1 才允许调用方释放 ring 与数据缓冲。
    virtual task disable_queue(virtio_queue_program_t q, output bit ok);
        bit done;

        control.disable_queue(to_context(q), done);
        ok = done;
    endtask

    // 私有队列复位 = 停队（teardown 已确认）+ 重建；这里没有寄存器动作。
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        ok = 1;
    endtask

    // 当前固定 polling，没有要编程的向量。
    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        ok = 1;
    endtask

    virtual task clear_msix(output bit ok);
        ok = 1;
    endtask

    // 私有 doorbell：驱动 writel({wrap, tail, local_qid}, notify_addr)。
    virtual task notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap);
        control.notify_queue(transport, to_context(q),
            custom_virtqueue::notify_word(wrap, next_idx, q.local_qid));
    endtask

    // 私有 Function 没有 virtio-net device config：全零，不报错、不访问设备。
    virtual task read_net_config(output virtio_net_device_config_t cfg);
        cfg = '{default:0};
    endtask
endclass
`endif
