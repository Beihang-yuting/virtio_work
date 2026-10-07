// 目录层次：src/dpu_priv；定义私有队列的分层配置（每 Function 默认值与单队列覆盖）。
// 依赖 UVM 和驱动 txrx.h 的字段宽度；由 virtio_net_pkg 纳入。test/顶层拥有配置；私有配置后端
// 在 bind_private 时冻结一份副本，设备访问全部由寄存器级后端完成。
`ifndef DPU_PRIV_DRIVER_CONFIG_SV
`define DPU_PRIV_DRIVER_CONFIG_SV

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
// 私有驱动协议与配置后端。默认映射 local_qid_base+queue_id；单队列覆盖允许独立路由/通知。
class dpu_priv_driver_config extends uvm_object;
    `uvm_object_utils(dpu_priv_driver_config)
    int unsigned default_queue_size = 512;
    int unsigned rx_buf_size = 2048;
    int unsigned local_qid_base = 0;
    dpu_priv_queue_config defaults;
    dpu_priv_queue_config queues[int unsigned];

    // 创建本 Function 的默认队列配置。
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
        if ((defaults == null) || (pairs == 0) ||
            (pairs > 128) || (default_queue_size < 2) ||
            (default_queue_size > 4096) ||
            ((default_queue_size & (default_queue_size-1)) != 0) ||
            (rx_buf_size < 64) || (rx_buf_size > 16383)) begin
            why = "private defaults、队列对数、环大小或 RX buffer 配置非法";
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
