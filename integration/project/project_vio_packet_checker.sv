// =============================================================================
// project_vio_packet_checker.sv
// 目录层次：integration/project；VIO 完整报文的可选业务 sidecar 参考实现。
// 文件职责：在 project_env 外部创建采样 sequence、RM 入口和 keyed common SCB；
// project_env 不持有此对象，也不因未启用 VIO 而创建任何报文线程。VTX hub 样本
// 代表环境发往 DUT 的基准报文，自动进入 vtx_scb 的 expected；VRX hub 样本代表
// DUT 写回并被环境收到的实际报文，自动进入 vrx_scb 的 actual。用户通过
// push_actual_bytes(VIO_PACKET_VTX, bytes) 提供 DUT 的 VTX 输出，通过
// prepare_rx(instance, qid, bytes) 把标记写入 payload 并登记参考报文。
// 主要依赖：virtio_net_pkg、simflow/uvm_gen 生成的 common_lib_pkg；AIP 构建时
// 可选依赖 aip_core_pkg。该文件不加入原始 project_integration.f，只有需要完整
// 报文检查的 test 才显式加入自己的 filelist。
// 所有权与生命周期：checker 拥有两个 common SCB 和采样 sequence；Function、
// hub、ring、Host memory、PCIe 资源仍由 project_env/VIO 所有。shutdown 后 worker
// 排空并停止，release 再解除订阅；end checker 只观察状态，不消费报文。
// wire 模式统一解析 20B trace tail，公共 SCB 只按 stream/sequence 匹配完整 Ethernet
// 字节；AIP 日志桥只替换显示，保留 UVM 计数和公共 SCB 的错误限额/失败状态。
// =============================================================================

`ifndef PROJECT_VIO_PACKET_CHECKER_SV
`define PROJECT_VIO_PACKET_CHECKER_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
import common_lib_pkg::*;

`ifdef AIP_CMDLINE_SV
import aip_core_pkg::*;
typedef class project_vio_packet_end_checker;
typedef class project_vio_packet_scb;

// 只挂在本 sidecar 的两个 SCB 上；把显示送到 AIP，保留 UVM_COUNT 等原报告动作。
// 不注册全局 catcher，不改变其他工程 SCB 的日志。
class project_vio_packet_report extends uvm_report_catcher;
    project_vio_packet_scb	owner;

    // 保存当前 SCB 的借用句柄；生命周期与该 SCB 相同，不接管报文。
    extern function new(project_vio_packet_scb	scb);

    // 非 fatal 的 SCB/VIO 日志由 owner 彩色输出一次；fatal 保留完整 UVM 处理。
    extern virtual function action_e catch();
endclass
`endif

// 复用 common SCB 的匹配、限流和统计；只补 wire 差异和无效 trace 的错误归账。
class project_vio_packet_scb extends common_uvm_scb #(virtio_packet_sample);
    `uvm_component_utils(project_vio_packet_scb)
`ifdef AIP_CMDLINE_SV
    protected project_vio_packet_report	m_report;
`endif

    // 建立实例局部的 AIP 日志桥；未编译 AIP 时保留普通 UVM 输出。
    extern function new(string	name, uvm_component	parent);

    // 先比原始字节；仅在详细错误限额内生成 net_packet 字段差异和字节窗口。
    extern virtual function bit compare_items(
        virtio_packet_sample	expected,
        virtio_packet_sample	actual,
        int			kind,
        output string		diff
    );

    // 无法得到可信 key 的输入记为 SCB input overflow/error，和普通 mismatch 共用限额。
    // 不尝试用坏 tail 猜测 expected；仍保留待匹配包，check_phase 可报告缺失。
    extern function void reject_packet(
        virtio_packet_sample	sample,
        string			why,
        bit			expected = 0,
        string			id = "VIO_TRACE_TAIL"
    );

`ifdef AIP_CMDLINE_SV
    // 仅负责彩色显示，不重复比较/计数；错误状态和 UVM severity 计数仍由原 SCB 保存。
    extern function void report_message(
        uvm_severity	severity,
        string		id,
        string		message
    );
`endif
endclass

function project_vio_packet_scb::new(string	name, uvm_component	parent);
    super.new(name, parent);
`ifdef AIP_CMDLINE_SV
    m_report = new(this);
    uvm_report_cb::add(this, m_report);
`endif
endfunction

function bit project_vio_packet_scb::compare_items(
    virtio_packet_sample	expected,
    virtio_packet_sample	actual,
    int				kind,
    output string		diff
);
    if (expected.self_define_do_compare(actual, diff, kind)) return 1;
    if (m_detail_emitted < m_cfg.m_err_limit)
        diff = {expected.identity_detail(), "\n  ", expected.wire_diff(actual)};
    return 0;
endfunction

function void project_vio_packet_scb::reject_packet(
    virtio_packet_sample	sample,
    string			why,
    bit				expected = 0,
    string			id = "VIO_TRACE_TAIL"
);
    state_t		state;
    byte unsigned	tail[$];
    string		detail;
    string		locate_why;
    int			trace_base;

    state = state_for(0);
    if (expected) begin
        m_expected_inputs++;
        state.expected_inputs++;
    end else begin
        m_actual_inputs++;
        state.actual_inputs++;
    end
    record_overflow(state, 0, expected ? "expected" : "actual", sample, -1);
    detail = why;
    if (m_detail_emitted < m_cfg.m_err_limit && sample != null) begin
        trace_base = sample.frame_bytes.size() > 20 ? sample.frame_bytes.size() - 20 : 0;
        if (!virtio_packet_trace::locate(sample.frame_bytes, trace_base, locate_why))
            trace_base = sample.frame_bytes.size() > 20 ? sample.frame_bytes.size() - 20 : 0;
        for (int	i = trace_base;
             i < sample.frame_bytes.size() && i < trace_base + 20; i++)
            tail.push_back(sample.frame_bytes[i]);
        detail = {detail, $sformatf(" frame_len=%0d\n  tail:%s",
                  sample.frame_bytes.size(), packet_utils::hex_dump(tail))};
        if (sample.identity_valid)
            detail = {sample.identity_detail(), "\n  ", detail};
    end
    emit_detail(0, id, detail);
endfunction

`ifdef AIP_CMDLINE_SV
function project_vio_packet_report::new(project_vio_packet_scb	scb);
    super.new("vio_packet_report");
    owner = scb;
endfunction

function uvm_report_catcher::action_e project_vio_packet_report::catch();
    string	id;

    id = get_id();
    if (get_severity() != UVM_FATAL &&
        ((id.substr(0, 3) == "SCB_") || (id.substr(0, 3) == "VIO_"))) begin
        if ((get_action() & UVM_DISPLAY) != 0) begin
            owner.report_message(get_severity(), id, get_message());
            set_action(get_action() & ~UVM_DISPLAY);
        end
    end
    return THROW;
endfunction

function void project_vio_packet_scb::report_message(
    uvm_severity	severity,
    string		id,
    string		message
);
    case (severity)
        UVM_ERROR:   `aip_uerror(("[%s] %s", id, message));
        UVM_WARNING: `aip_uwarning(("[%s] %s", id, message));
        UVM_INFO:    `aip_uinfo(("[%s] %s", id, message));
        default: ;
    endcase
endfunction
`endif

class project_vio_packet_checker extends uvm_component;
    `uvm_component_utils(project_vio_packet_checker)

    typedef project_vio_packet_scb	packet_scb_t;

    packet_scb_t	vtx_scb;
    packet_scb_t	vrx_scb;
    common_uvm_scb_cfg	scb_cfg;

    protected virtio_function_instance	m_functions[$];
    protected virtio_packet_seq		m_sequences[$];
    protected int unsigned		m_consumer_ids[$];
    protected bit			m_worker_alive[int unsigned];
    protected int unsigned		m_active_workers;
    protected bit			m_stop;
    protected bit			m_workers_started;
`ifdef AIP_CMDLINE_SV
    protected project_vio_packet_end_checker	m_end_checker;
`endif

    // 功能：创建两个方向的 keyed SCB，但不绑定 Function 或启动 worker。
    // 输入/输出：输入 UVM 名称和父组件；输出为新 checker。
    // 边界/副作用：SCB 配置可在 build 前通过 uvm_config_db 注入；无 VIO 时保持空闲。
    extern function new(
        string		name="project_vio_packet_checker",
        uvm_component	parent=null
    );

    // 功能：创建方向 SCB 并应用公共配置。
    // 输入/输出：输入 UVM phase；无输出。
    // 边界/副作用：不访问 Function/DUT；所有报文使用尾标记的 stream/sequence 匹配。
    extern virtual function void build_phase(uvm_phase	phase);

    // 功能：绑定一个已完成配置的 VIO Function，并建立 VTX/RX 两个 consumer。
    // 输入/输出：输入 Function instance；无返回值。
    // 边界/副作用：重复绑定同一对象被忽略；未配置 Function 报错；不配置队列。
    // 绑定后 TX 会在 payload 尾部写入 20B 标记，其他采样 consumer 也会看到该内容。
    extern function void bind_function(virtio_function_instance instance);

    // 功能：把 RM 生成的 expected 样本送入对应方向 SCB。
    // 输入/输出：输入方向和完整样本；无返回值。
    // 边界/副作用：校验 trace 后按 stream/sequence 入队；没有有效 tail 时报告错误。
    extern function void push_expected(
        vio_packet_dir_e	direction,
        virtio_packet_sample	sample
    );

    // 功能：把 DUT 侧 actual 样本送入对应方向 SCB。
    // 输入/输出：输入方向和完整样本；无返回值。
    // 边界/副作用：VTX 由用户 DUT 输出 monitor 调用，VRX 通常由内部 worker 自动调用；
    // 按尾标记关联；VRX 还校验真实收包 Function/queue 是否与注入目标一致。
    extern function void push_actual(
        vio_packet_dir_e	direction,
        virtio_packet_sample	sample
    );

    // Ethernet TX monitor 的直接入口：只传完整原始帧，无需知道 PF/VF/qid。
    // 帧不含 preamble/FCS；坏 tail 记录错误而不匹配其他包。
    extern function void push_actual_bytes(
        vio_packet_dir_e	direction,
        byte unsigned		bytes[$]
    );

    // VRX 注入前为指定 Function/local virtqueue 的原始帧写入 payload tail，并登记 expected。
    // bytes 长度保持不变，调用者将修改后的同一份字节交给 Ethernet 驱动；失败返回 0。
    extern function bit prepare_rx(
        virtio_function_instance	instance,
        int unsigned			queue_id,
        ref byte unsigned		bytes[$]
    );

    // 共用入队路径：只从线上标记恢复 key，保留真实 VRX 入口身份以识别错队列。
    extern protected function void push_packet(
        bit			expected,
        vio_packet_dir_e	direction,
        virtio_packet_sample	sample
    );

    // 功能：请求所有采样 worker 停止，先排空已经发布的样本。
    // 输入/输出：无输入；无返回值。
    // 边界/副作用：不释放 Function 资源或取消订阅；release_subscriptions() 等 worker 排空后再解除订阅。
    extern function void shutdown();

    // 功能：等待 worker 排空 mailbox 后解除所有订阅。
    // 输入/输出：无输入；无返回值。
    // 边界/副作用：不释放 Function、ring、Host memory 或 PCIe 资源。
    extern task release_subscriptions();

`ifdef AIP_CMDLINE_SV
    // 功能：把本 sidecar 注册为 AIP end_test 的具名检查器。
    // 输入/输出：输入全局 checker 名称；无返回值。
    // 边界/副作用：只注册适配器，不启动/停止 worker；同名不同对象由 AIP 拒绝。
    extern function void register_end_checker(
        string	name="vio_packet_scb"
    );
`endif

    // 功能：判断 worker 已停止且两个 SCB 没有 pending/错误。
    // 输入/输出：无输入；返回 end_test wait_done 可用的完成状态。
    // 边界/副作用：未调用 shutdown 时始终返回 0；不调用 check_phase，避免提前 finalize。
    extern function bit is_done();

    // 功能：返回两个 SCB 是否已记录严重错误。
    // 输入/输出：无输入；返回失败状态。
    // 边界/副作用：pending 在 check_phase 前不算失败，便于 end_test 先 drain。
    extern function bit has_failed();

    // 功能：返回 end checker 的诊断摘要。
    // 输入/输出：无输入；返回两个 SCB 的摘要文本。
    // 边界/副作用：只读，不 finalize 或打印整张问题表。
    extern function string status_detail();

    // 功能：在 run_phase 中为每个绑定 Function 启动持久采样 worker。
    // 输入/输出：输入 UVM phase；无输出。
    // 边界/副作用：无绑定 Function 时不创建线程；VTX hub 样本进入 expected，
    // VRX hub 样本进入 actual。
    extern virtual task run_phase(uvm_phase	phase);

    // 功能：轮询一个 Function 的 VTX/RX mailbox。
    // 输入/输出：输入 binding 下标；无输出。
    // 边界/副作用：每次等待最多 1ns，确保 shutdown 能及时结束；不启动 PCIe sequence。
    extern task run_worker(int unsigned	index);

endclass

function project_vio_packet_checker::new(
    string		name="project_vio_packet_checker",
    uvm_component	parent=null
);
    super.new(name, parent);
    m_stop            = 0;
    m_workers_started = 0;
    m_active_workers  = 0;
endfunction

function void project_vio_packet_checker::build_phase(uvm_phase	phase);
    super.build_phase(phase);
    vtx_scb = packet_scb_t::type_id::create("vtx_scb", this);
    vrx_scb = packet_scb_t::type_id::create("vrx_scb", this);
    if (uvm_config_db#(common_uvm_scb_cfg)::get(this, "", "scb_cfg", scb_cfg)) begin
        uvm_config_db#(common_uvm_scb_cfg)::set(this, "vtx_scb", "cfg", scb_cfg);
        uvm_config_db#(common_uvm_scb_cfg)::set(this, "vrx_scb", "cfg", scb_cfg);
    end
endfunction

function void project_vio_packet_checker::bind_function(
    virtio_function_instance	instance
);
    virtio_packet_seq	sample_seq;
    int unsigned	consumer_id;

    if (instance == null) begin
        `uvm_error("VIO_PACKET_SCB", "cannot bind a null Function")
        return;
    end
    foreach (m_functions[i])
        if (m_functions[i] == instance) return;
    if (m_workers_started) begin
        `uvm_error("VIO_PACKET_SCB", "bind_function must be called before run_phase")
        return;
    end
    sample_seq = virtio_packet_seq::type_id::create(
        $sformatf("packet_seq_%0d", m_sequences.size()));
    sample_seq.bind_function(instance);
    if (sample_seq.hub == null) begin
        `uvm_error("VIO_PACKET_SCB", "Function has no packet hub")
        return;
    end
    consumer_id = m_sequences.size();
    sample_seq.subscribe(VIO_PACKET_VTX, consumer_id, 1024);
    sample_seq.subscribe(VIO_PACKET_VRX, consumer_id, 1024);
    sample_seq.ops.packet_trace_enabled = 1;
    m_functions.push_back(instance);
    m_sequences.push_back(sample_seq);
    m_consumer_ids.push_back(consumer_id);
endfunction

function void project_vio_packet_checker::push_expected(
    vio_packet_dir_e		direction,
    virtio_packet_sample	sample
);
    push_packet(1, direction, sample);
endfunction

function void project_vio_packet_checker::push_actual(
    vio_packet_dir_e		direction,
    virtio_packet_sample	sample
);
    push_packet(0, direction, sample);
endfunction

function void project_vio_packet_checker::push_actual_bytes(
    vio_packet_dir_e	direction,
    byte unsigned	bytes[$]
);
    virtio_packet_sample	sample;

    sample = new("eth_actual");
    sample.direction   = direction;
    sample.frame_bytes = bytes;
    push_actual(direction, sample);
endfunction

function bit project_vio_packet_checker::prepare_rx(
    virtio_function_instance	instance,
    int unsigned		queue_id,
    ref byte unsigned		bytes[$]
);
    virtio_packet_sample	sample;
    string			why;

    foreach (m_functions[i]) begin
        if (m_functions[i] != instance) continue;
        sample = m_sequences[i].ops.packet_identity(queue_id, VIO_PACKET_VRX);
        if (!virtio_packet_trace::stamp(sample, bytes, why)) begin
            vrx_scb.reject_packet(sample, why, 1);
            return 0;
        end
        push_expected(VIO_PACKET_VRX, sample);
        return 1;
    end
    vrx_scb.reject_packet(null, "prepare_rx requires a bound Function", 1);
    return 0;
endfunction

function void project_vio_packet_checker::push_packet(
    bit				expected,
    vio_packet_dir_e		direction,
    virtio_packet_sample	sample
);
    packet_scb_t		scoreboard;
    virtio_packet_sample	parsed;
    string			why;

    scoreboard = direction == VIO_PACKET_VTX ? vtx_scb : vrx_scb;
    if (sample == null) begin
        scoreboard.reject_packet(null, "null packet sample", expected);
        return;
    end
    if (!virtio_packet_trace::decode(sample.frame_bytes, direction, parsed, why)) begin
        scoreboard.reject_packet(sample, why, expected);
        return;
    end
    if (sample.identity_valid && sample.flow_key() != parsed.flow_key()) begin
        scoreboard.reject_packet(sample,
            {"trace belongs to ", parsed.identity_detail()}, expected, "VIO_PACKET_ROUTE");
        return;
    end
    if (expected)
        scoreboard.push_expected_keyed(parsed, parsed.stream_id, -1, parsed.packet_key);
    else
        scoreboard.push_actual_keyed(parsed, parsed.stream_id, -1, parsed.packet_key);
endfunction

function void project_vio_packet_checker::shutdown();
    m_stop = 1;
endfunction

task project_vio_packet_checker::release_subscriptions();
    shutdown();
    wait (m_active_workers == 0);
    foreach (m_sequences[i]) begin
        m_sequences[i].unsubscribe(VIO_PACKET_VTX, m_consumer_ids[i]);
        m_sequences[i].unsubscribe(VIO_PACKET_VRX, m_consumer_ids[i]);
    end
endtask

`ifdef AIP_CMDLINE_SV
function void project_vio_packet_checker::register_end_checker(
    string	name="vio_packet_scb"
);
    m_end_checker = new(this);
    aip_tcl_bridge::register_end_checker(name, m_end_checker);
endfunction
`endif

function bit project_vio_packet_checker::is_done();
    if (!m_stop || (m_active_workers != 0)) return 0;
    foreach (m_sequences[i]) begin
        if ((m_sequences[i].hub.pending(VIO_PACKET_VTX, m_consumer_ids[i]) != 0) ||
            (m_sequences[i].hub.pending(VIO_PACKET_VRX, m_consumer_ids[i]) != 0))
            return 0;
    end
    return vtx_scb.is_clean() && vrx_scb.is_clean();
endfunction

function bit project_vio_packet_checker::has_failed();
    return (vtx_scb.get_status() == SCB_FAIL) ||
           (vrx_scb.get_status() == SCB_FAIL);
endfunction

function string project_vio_packet_checker::status_detail();
    return {"vtx={", vtx_scb.get_summary(), "} vrx={",
            vrx_scb.get_summary(), "}"};
endfunction

task project_vio_packet_checker::run_phase(uvm_phase	phase);
    if (m_workers_started) return;
    m_workers_started = 1;
    foreach (m_sequences[i]) begin
        automatic int unsigned	index = i;
        fork
            run_worker(index);
        join_none
    end
endtask

task project_vio_packet_checker::run_worker(int unsigned	index);
    virtio_packet_sample	packet;
    bit				got_packet;

    m_worker_alive[index] = 1;
    m_active_workers++;
    forever begin
        got_packet = 0;
        while (m_sequences[index].hub.pending(VIO_PACKET_VTX,
                                               m_consumer_ids[index]) != 0) begin
            m_sequences[index].mon_xaction(
                packet, VIO_PACKET_VTX, m_consumer_ids[index], 0);
            if (packet != null) begin
                // VTX 是环境发往 DUT 的基准报文；DUT 的对应输出由用户
                // monitor 通过 push_actual(VIO_PACKET_VTX, ...) 提供。
                push_expected(VIO_PACKET_VTX, packet);
                got_packet = 1;
            end
        end
        while (m_sequences[index].hub.pending(VIO_PACKET_VRX,
                                               m_consumer_ids[index]) != 0) begin
            m_sequences[index].mon_xaction(
                packet, VIO_PACKET_VRX, m_consumer_ids[index], 0);
            if (packet != null) begin
                push_actual(VIO_PACKET_VRX, packet);
                got_packet = 1;
            end
        end
        if (m_stop && !got_packet) break;
        if (got_packet) continue;
        m_sequences[index].mon_xaction(
            packet, VIO_PACKET_VTX, m_consumer_ids[index], 1ns);
        if (packet != null) begin
            push_expected(VIO_PACKET_VTX, packet);
            continue;
        end
        m_sequences[index].mon_xaction(
            packet, VIO_PACKET_VRX, m_consumer_ids[index], 1ns);
        if (packet != null) push_actual(VIO_PACKET_VRX, packet);
    end
    m_worker_alive[index] = 0;
    m_active_workers--;
endtask

`ifdef AIP_CMDLINE_SV
class project_vio_packet_end_checker extends aip_end_checker;
    protected project_vio_packet_checker	m_owner;

    // 功能：创建 AIP end_test 适配器。
    // 输入/输出：输入 sidecar；输出为轻量借用适配器。
    // 边界/副作用：不注册全局 checker；注册动作由 test 明确执行。
    extern function new(project_vio_packet_checker	owner);

    // 只查询 owner 的 worker/pending 状态；不提前 finalize SCB。
    extern virtual function bit is_done();

    // 查询累计失败，供 end_test 及时结束失败用例；不清空错误。
    extern virtual function bit has_failed();

    // 返回两方向摘要，借用 owner，不访问 DUT。
    extern virtual function string status_detail();
endclass

function project_vio_packet_end_checker::new(project_vio_packet_checker	owner);
    m_owner = owner;
endfunction

function bit project_vio_packet_end_checker::is_done();
    return (m_owner != null) && m_owner.is_done();
endfunction

function bit project_vio_packet_end_checker::has_failed();
    return (m_owner != null) && m_owner.has_failed();
endfunction

function string project_vio_packet_end_checker::status_detail();
    return (m_owner == null) ? "VIO packet checker is null" :
                                m_owner.status_detail();
endfunction
`endif

`endif
