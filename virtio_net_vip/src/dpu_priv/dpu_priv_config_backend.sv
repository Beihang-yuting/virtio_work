// 目录层次：src/dpu_priv；把 DPU 私有环控制面接到统一的 virtio_config_backend。
// 依赖 dpu_priv_device_control（用户/后续 AF 直配实现）与 virtio_queue_program_t；
// control 为借用引用，本对象不持有 Host 内存或映射。私有协议没有标准 status/feature/
// MSI-X 寄存器，这些入口显式拒绝且不访问设备。
`ifndef DPU_PRIV_CONFIG_BACKEND_SV
`define DPU_PRIV_CONFIG_BACKEND_SV

class dpu_priv_config_backend extends virtio_config_backend;
    `uvm_object_utils(dpu_priv_config_backend)

    // 设备控制实现；由 dpu_priv_atomic_ops.configure_private 注入。
    dpu_priv_device_control control;

    // 构造不访问设备；control 由私有 ops 注入。
    function new(string name = "dpu_priv_config_backend");
        super.new(name);
        control = null;
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

    // 私有控制上下文 → 统一编程参数；to_context(from_context(ctx)) 恒等。
    static function virtio_queue_program_t from_context(dpu_priv_queue_context_t ctx);
        virtio_queue_program_t q;

        q = virtio_empty_queue_program();
        q.host_id = ctx.host_id;
        q.bdf = ctx.bdf;
        q.queue_id = ctx.queue_id;
        q.queue_size = ctx.queue_size;
        q.vq_type = VQ_CUSTOM;
        q.desc_iova = ctx.ring_iova;
        q.device_iova = ctx.cq_iova;
        q.ring_bytes = ctx.ring_bytes;
        q.local_qid = ctx.local_qid;
        q.rx_buf_size = ctx.rx_buf_size;
        q.tx_mode = ctx.tx_mode;
        q.notify_bar = ctx.notify_bar;
        q.notify_offset = ctx.notify_offset;
        return q;
    endfunction

    // 私有协议不使用的标准寄存器入口统一报告，不访问设备。
    protected function void reject(string operation);
        `uvm_error("DPU_PRIV_OPS", {operation, ": 私有驱动不使用标准 Virtio 控制寄存器"})
    endfunction

    // Function 级复位由控制后端确认停 DMA；Host/BDF 取自绑定的 transport。
    virtual task reset(output bit ok);
        bit done;

        control.reset_device(transport.iommu_host_id(), transport.bdf, done);
        ok = done;
    endtask

    virtual task read_status(output bit [7:0] status);
        status = 0;
        reject("read_status");
    endtask

    virtual task write_status(bit [7:0] status);
        reject("write_status");
    endtask

    virtual task read_device_features(output bit [63:0] features);
        features = 0;
        reject("read_device_features");
    endtask

    virtual task write_driver_features(bit [63:0] features);
        reject("write_driver_features");
    endtask

    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        accepted = 0;
        reject("set_features");
    endtask

    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        max_size = 0;
        reject("query_queue_max");
    endtask

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

    // 私有队列复位由 ops 以 teardown+setup 实现，不存在标准 Q_RESET。
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        ok = 0;
        reject("reset_queue");
    endtask

    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        ok = 0;
        reject("set_msix");
    endtask

    virtual task clear_msix(output bit ok);
        ok = 0;
        reject("clear_msix");
    endtask

    // 私有 doorbell：等价于驱动 writel(value, notify_addr)，经控制后端发出。
    task notify_queue(dpu_priv_queue_context_t ctx, bit [31:0] value);
        control.notify_queue(transport, ctx, value);
    endtask
endclass
`endif
