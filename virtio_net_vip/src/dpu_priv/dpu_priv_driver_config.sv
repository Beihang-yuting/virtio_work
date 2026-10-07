// 目录层次：src/dpu_priv；定义私有队列的控制接口与分层配置。
// 依赖 virtio_pci_transport、UVM 和驱动 txrx.h 的字段宽度；由 virtio_net_pkg 纳入。
// test/顶层拥有配置和设备控制实现；每个 Function 的 ops 借用配置并保存已建队的
// context 副本。control 必须在返回成功前完成设备配置/停 DMA，不拥有 Host 内存。
`ifndef DPU_PRIV_DRIVER_CONFIG_SV
`define DPU_PRIV_DRIVER_CONFIG_SV

// 设备控制接收明确的 Host/BDF/local_qid 与 IOVA，不能用全局资源编号代替本地号。
// ring_iova 覆盖整块连续 desc+CQ；cq_iova 是其中偏移，禁止分别随机映射。
typedef struct {
    int unsigned host_id;
    bit [15:0] bdf;
    int unsigned queue_id, local_qid, queue_size, rx_buf_size;
    bit tx_mode;
    bit [63:0] ring_iova, cq_iova;
    int unsigned ring_bytes;
    int unsigned notify_bar;
    bit [31:0] notify_offset;
} dpu_priv_queue_context_t;

// AF 直配和 PF/VF mailbox 使用不同控制面，故把驱动协议与寄存器执行分开。
// 派生类必须实现真正的配置与 DMA 停止确认；没有默认“配置成功”的空实现。
virtual class dpu_priv_device_control extends uvm_object;
    // 仅初始化诊断名；控制对象由调用方持有，可按 Host/BDF 分派不同后端。
    function new(string name = "dpu_priv_device_control");
        super.new(name);
    endfunction

    // 复位指定 Function 并确认它停止 DMA；失败 ok=0，调用方保留所有映射。
    pure virtual task reset_device(int unsigned host_id, bit [15:0] bdf,
                                   output bit ok);
    // 配置并启动一条私有队列；失败必须保证该队列未启动 DMA，供调用方安全回滚。
    pure virtual task configure_queue(dpu_priv_queue_context_t ctx, output bit ok);
    // 停止队列并等待 DMA 排空；只有 ok=1 才允许释放 ring 和数据缓冲。
    pure virtual task disable_queue(dpu_priv_queue_context_t ctx, output bit ok);

    // 默认通知等价于驱动 writel(value, notify_addr)，通过已绑定的 BAR accessor
    // 发送一个 32-bit MMIO 写；AF/mailbox 模型可覆写，不能调用标准 virtio kick。
    virtual task notify_queue(virtio_pci_transport transport,
                              dpu_priv_queue_context_t ctx, bit [31:0] value);
        if ((transport == null) || (transport.bar == null)) begin
            `uvm_error("DPU_PRIV_CONTROL", "notify: PCIe transport/BAR 未绑定")
            return;
        end
        transport.bar.write_reg(ctx.notify_bar, ctx.notify_offset, 4, value);
    endtask
endclass

// 每队列覆盖配置只保存通知和 TX 控制，不持有 ring 索引；运行态由 custom_virtqueue 持有。
class dpu_priv_queue_config extends uvm_object;
    `uvm_object_utils(dpu_priv_queue_config)
    int unsigned local_qid;
    int unsigned notify_bar = 0;
    bit [31:0] notify_offset = 0;
    bit [11:0] dport_info;
    bit [9:0] dport_id;
    bit [2:0] dport_type, cpu_tx_cos;
    bit rss_lag, l3_cs, l4_cs;
    bit [1:0] fwd = 1;

    // 创建未绑定的队列配置；调用方随后填写 local_qid，方向来自 RX偶/TX奇约定。
    function new(string name = "dpu_priv_queue_config");
        super.new(name);
    endfunction
endclass

// 每 Function 独立配置：env_cfg 按完整 service key 注册它，再交给该 Function 的
// 私有 ops/FSM。默认映射 local_qid_base+queue_id；单队列覆盖允许独立路由/通知。
class dpu_priv_driver_config extends uvm_object;
    `uvm_object_utils(dpu_priv_driver_config)
    dpu_priv_device_control control;
    int unsigned default_queue_size = 512;
    int unsigned rx_buf_size = 2048;
    int unsigned local_qid_base = 0;
    dpu_priv_queue_config defaults;
    dpu_priv_queue_config queues[int unsigned];

    // 创建本 Function 的默认队列配置；控制后端必须由上层注入，不自动造设备模型。
    function new(string name = "dpu_priv_driver_config");
        super.new(name);
        defaults = dpu_priv_queue_config::type_id::create({name, "_defaults"});
    endfunction

    // 返回配置副本，冻结本次建队所用字段；输入 qid 是该 Function 的 RX/TX 队列号。
    // 不修改源配置，缺省时推导本地号；非法配置由 validate 在建队前拒绝。
    function dpu_priv_queue_config resolve_queue(int unsigned qid);
        dpu_priv_queue_config source_cfg, result;
        source_cfg = queues.exists(qid) ? queues[qid] : defaults;
        if (source_cfg == null) return null;
        result = new($sformatf("private_queue_%0d_cfg", qid));
        result.local_qid = queues.exists(qid) ? source_cfg.local_qid :
                                               local_qid_base + qid;
        result.notify_bar = source_cfg.notify_bar;
        result.notify_offset = source_cfg.notify_offset;
        result.dport_info = source_cfg.dport_info;
        result.dport_id = source_cfg.dport_id;
        result.dport_type = source_cfg.dport_type;
        result.cpu_tx_cos = source_cfg.cpu_tx_cos;
        result.rss_lag = source_cfg.rss_lag;
        result.l3_cs = source_cfg.l3_cs;
        result.l4_cs = source_cfg.l4_cs;
        result.fwd = source_cfg.fwd;
        return result;
    endfunction

    // 检查基础几何和指定队列对的本地号唯一性/方向；失败只返回 why，不配置硬件。
    // 私有数据路径目前为 polling、非 TSO、单 buffer RX；RX CQ 包长只有 14 位。
    function bit validate(int unsigned pairs, output string why);
        bit used_qids[int unsigned];
        dpu_priv_queue_config q;
        why = "";
        if ((control == null) || (defaults == null) || (pairs == 0) ||
            (pairs > 128) || (default_queue_size < 2) ||
            (default_queue_size > 4096) ||
            ((default_queue_size & (default_queue_size-1)) != 0) ||
            (rx_buf_size < 64) || (rx_buf_size > 16383)) begin
            why = "private control/defaults、队列对数、环大小或 RX buffer 配置非法";
            return 0;
        end
        foreach (queues[qid]) begin
            if ((qid >= 2*pairs) || (queues[qid] == null)) begin
                why = "private 队列覆盖下标越界或句柄为空";
                return 0;
            end
        end
        for (int unsigned qid = 0; qid < 2*pairs; qid++) begin
            q = resolve_queue(qid);
            if ((q == null) || (q.local_qid > 255) ||
                ((q.local_qid % 2) != (qid % 2)) ||
                used_qids.exists(q.local_qid) || (q.notify_bar > 5) ||
                (q.notify_offset[1:0] != 0)) begin
                why = $sformatf("private queue %0d 本地号重复/方向错误或通知地址非法", qid);
                return 0;
            end
            used_qids[q.local_qid] = 1;
        end
        return 1;
    endfunction
endclass
`endif
