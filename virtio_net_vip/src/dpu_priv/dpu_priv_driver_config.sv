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
    bit	notify_bar_present;
    bit	notify_offset_present;
    bit [31:0] notify_offset = 0;
    bit [11:0] dport_info;
    bit [9:0] dport_id;
    bit [2:0] dport_type, cpu_tx_cos;
    bit rss_lag, l3_cs, l4_cs;
    bit	i_l3_cs;
    bit	i_l4_cs;
    bit [1:0] fwd = 1;

    // 从已采样的默认控制继承显式字段，不重新随机，不覆盖队列自己的 local_qid。
    extern function void inherit_params(input dpu_priv_queue_config	source, input string	path);

    // 参数归属：vio.private.* 默认控制字段或其 q<qid> 子路径覆盖。
    // 先用 64 位数值检查位宽，避免负数/高位被窄字段静默截断；不持有运行态 ring。
    function void	load_params(string	path = "vio.private", bit	load_local_qid = 1);
`ifdef AIP_CMDLINE_SV
        bit	present;
        longint unsigned	local_qid;
        longint unsigned	notify_bar;
        longint unsigned	notify_offset;
        longint unsigned	dport_info;
        longint unsigned	dport_id;
        longint unsigned	dport_type;
        longint unsigned	cpu_tx_cos;
        longint unsigned	rss_lag;
        longint unsigned	l3_cs;
        longint unsigned	l4_cs;
        longint unsigned	i_l3_cs;
        longint unsigned	i_l4_cs;
        longint unsigned	fwd;
        `DPU_AIP_PRESENT(path, "notify_bar", present)
        notify_bar_present |= present;
        `DPU_AIP_PRESENT(path, "notify_offset", present)
        notify_offset_present |= present;
        local_qid = this.local_qid;
        if (load_local_qid) begin
            `DPU_AIP_UINT(path, longint unsigned, local_qid, this.local_qid);
        end
        `DPU_AIP_UINT(path, longint unsigned, notify_bar, this.notify_bar);
        `DPU_AIP_UINT(path, longint unsigned, notify_offset, this.notify_offset);
        `DPU_AIP_UINT(path, longint unsigned, dport_info, this.dport_info);
        `DPU_AIP_UINT(path, longint unsigned, dport_id, this.dport_id);
        `DPU_AIP_UINT(path, longint unsigned, dport_type, this.dport_type);
        `DPU_AIP_UINT(path, longint unsigned, cpu_tx_cos, this.cpu_tx_cos);
        `DPU_AIP_UINT(path, longint unsigned, rss_lag, this.rss_lag);
        `DPU_AIP_UINT(path, longint unsigned, l3_cs, this.l3_cs);
        `DPU_AIP_UINT(path, longint unsigned, l4_cs, this.l4_cs);
        `DPU_AIP_UINT(path, longint unsigned, i_l3_cs, this.i_l3_cs);
        `DPU_AIP_UINT(path, longint unsigned, i_l4_cs, this.i_l4_cs);
        `DPU_AIP_UINT(path, longint unsigned, fwd, this.fwd);
        if (local_qid > 255) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".local_qid 超出字段范围"})
            return;
        end
        if (notify_bar > 5) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".notify_bar 超出字段范围"})
            return;
        end
        if (notify_offset > 64'hffff_ffff) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".notify_offset 超出字段范围"})
            return;
        end
        if (dport_info > 4095) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".dport_info 超出字段范围"})
            return;
        end
        if (dport_id > 1023) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".dport_id 超出字段范围"})
            return;
        end
        if (dport_type > 7) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".dport_type 超出字段范围"})
            return;
        end
        if (cpu_tx_cos > 7) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".cpu_tx_cos 超出字段范围"})
            return;
        end
        if (rss_lag > 1) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".rss_lag 超出字段范围"})
            return;
        end
        if (l3_cs > 1) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".l3_cs 超出字段范围"})
            return;
        end
        if (l4_cs > 1) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".l4_cs 超出字段范围"})
            return;
        end
        if (i_l3_cs > 1) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".i_l3_cs 超出字段范围"})
            return;
        end
        if (i_l4_cs > 1) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".i_l4_cs 超出字段范围"})
            return;
        end
        if (fwd > 3) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".fwd 超出字段范围"})
            return;
        end
        if ((notify_offset & 3) != 0) begin
            `uvm_fatal("VIO_PRIVATE_PARAM", {path, ".notify_offset 必须 4 字节对齐"})
            return;
        end
        this.local_qid = local_qid;
        this.notify_bar = notify_bar;
        this.notify_offset = notify_offset;
        this.dport_info = dport_info;
        this.dport_id = dport_id;
        this.dport_type = dport_type;
        this.cpu_tx_cos = cpu_tx_cos;
        this.rss_lag = rss_lag;
        this.l3_cs = l3_cs;
        this.l4_cs = l4_cs;
        this.i_l3_cs = i_l3_cs;
        this.i_l4_cs = i_l4_cs;
        this.fwd = fwd;
`endif
    endfunction

    // 创建未绑定的队列配置；调用方随后填写 local_qid，方向来自 RX偶/TX奇约定。
    function new(string name = "dpu_priv_queue_config");
        super.new(name);
    endfunction
endclass

// 运行期默认控制只取一次；队列继承已采样字段后，再读取自己的 qN 覆盖。
// 缺失字段保留当前队列值，通知显式标志只随对应字段传播，不修改源对象。
function void dpu_priv_queue_config::inherit_params(
    input dpu_priv_queue_config	source,
    input string	path
);
`ifdef AIP_CMDLINE_SV
    bit	present;

    `DPU_AIP_PRESENT(path, "notify_bar", present)
    if (present) notify_bar = source.notify_bar;
    notify_bar_present |= present;
    `DPU_AIP_PRESENT(path, "notify_offset", present)
    if (present) notify_offset = source.notify_offset;
    notify_offset_present |= present;
    `DPU_AIP_PRESENT(path, "dport_info", present)
    if (present) dport_info = source.dport_info;
    `DPU_AIP_PRESENT(path, "dport_id", present)
    if (present) dport_id = source.dport_id;
    `DPU_AIP_PRESENT(path, "dport_type", present)
    if (present) dport_type = source.dport_type;
    `DPU_AIP_PRESENT(path, "cpu_tx_cos", present)
    if (present) cpu_tx_cos = source.cpu_tx_cos;
    `DPU_AIP_PRESENT(path, "rss_lag", present)
    if (present) rss_lag = source.rss_lag;
    `DPU_AIP_PRESENT(path, "l3_cs", present)
    if (present) l3_cs = source.l3_cs;
    `DPU_AIP_PRESENT(path, "l4_cs", present)
    if (present) l4_cs = source.l4_cs;
    `DPU_AIP_PRESENT(path, "i_l3_cs", present)
    if (present) i_l3_cs = source.i_l3_cs;
    `DPU_AIP_PRESENT(path, "i_l4_cs", present)
    if (present) i_l4_cs = source.i_l4_cs;
    `DPU_AIP_PRESENT(path, "fwd", present)
    if (present) fwd = source.fwd;
`endif
endfunction

// 每 Function 独立配置：env_cfg 按完整 service key 注册它，再交给该 Function 的
// 私有驱动协议与配置后端。默认映射 local_qid_base+queue_id；单队列覆盖允许独立路由/通知。
class dpu_priv_driver_config extends uvm_object;
    `uvm_object_utils(dpu_priv_driver_config)
    int unsigned default_queue_size = 512;
    int unsigned rx_buf_size = 2048;
    int unsigned local_qid_base = 0;
    dpu_priv_queue_config defaults;
    dpu_priv_queue_config queues[int unsigned];

    // 参数归属：vio.private.queue_size/rx_buf_size/local_qid_base 及默认控制字段。
    // 必须在 Function bind_private 冻结副本前调用；仅覆盖已声明的 queues，
    // qid 唯一性与方向仍由 validate(pairs, why) 联合检查，不擅自创建/扩容队列。
    // load_queues=0 先只采样默认值，供外层按队列合并已采样控制后单独读取 qN。
    extern function void load_params(string	path = "vio.private", bit	load_queues = 1);

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
        result.notify_bar_present = source_cfg.notify_bar_present;
        result.notify_offset_present = source_cfg.notify_offset_present;
        result.notify_bar = source_cfg.notify_bar;
        result.notify_offset = source_cfg.notify_offset;
        result.dport_info = source_cfg.dport_info;
        result.dport_id = source_cfg.dport_id;
        result.dport_type = source_cfg.dport_type;
        result.cpu_tx_cos = source_cfg.cpu_tx_cos;
        result.rss_lag = source_cfg.rss_lag;
        result.l3_cs = source_cfg.l3_cs;
        result.l4_cs = source_cfg.l4_cs;
        result.i_l3_cs = source_cfg.i_l3_cs;
        result.i_l4_cs = source_cfg.i_l4_cs;
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

// 只解析默认控制或已有队列；可分两步合并运行期默认值，避免 qN 参数被重复抽样。
function void dpu_priv_driver_config::load_params(
    string	path,
    bit	load_queues
);
`ifdef AIP_CMDLINE_SV
    longint unsigned	queue_size;
    longint unsigned	rx_buf_size;
    longint unsigned	local_qid_base;

    `DPU_AIP_UINT(path, longint unsigned, queue_size, default_queue_size);
    `DPU_AIP_UINT(path, longint unsigned, rx_buf_size, this.rx_buf_size);
    `DPU_AIP_UINT(path, longint unsigned, local_qid_base, this.local_qid_base);
    if ((queue_size < 2) || (queue_size > 4096) ||
        ((queue_size & (queue_size - 1)) != 0) ||
        (rx_buf_size < 64) || (rx_buf_size > 16383) ||
        (local_qid_base > 254) || ((local_qid_base & 1) != 0)) begin
        `uvm_fatal("VIO_PRIVATE_PARAM", {path, ": 队列几何/本地队列起点非法"})
        return;
    end
    if (defaults == null) begin
        `uvm_fatal("VIO_PRIVATE_PARAM", {path, ": 缺少默认队列配置"})
        return;
    end
    // 默认队列的 local_qid 由 local_qid_base+qid 推导；只有单队列覆盖读此字段。
    defaults.load_params(path, 0);
    if (load_queues) begin
        foreach (queues[qid]) begin
            if (queues[qid] == null) begin
                `uvm_fatal("VIO_PRIVATE_PARAM", {path, ": 队列覆盖对象为空"})
                return;
            end
            queues[qid].load_params($sformatf("%s.q%0d", path, qid));
        end
    end

    default_queue_size  = int'(queue_size);
    this.rx_buf_size    = int'(rx_buf_size);
    this.local_qid_base = int'(local_qid_base);
`endif
endfunction

`endif
