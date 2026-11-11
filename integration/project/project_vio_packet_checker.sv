// =============================================================================
// project_vio_packet_checker.sv
// 目录层次：integration/project；VIO 完整报文的可选业务 sidecar 参考实现。
// 文件职责：在 project_env 外部创建采样 sequence、RM 入口和 keyed common SCB；
// project_env 不持有此对象，也不因未启用 VIO 而创建任何报文线程。用户可继承
// 本类覆盖 RM 逻辑，或直接调用 push_expected() 把参考模型结果送入对应 SCB。
// 主要依赖：virtio_net_pkg、simflow/uvm_gen 生成的 common_lib_pkg；AIP 构建时
// 可选依赖 aip_core_pkg。该文件不加入原始 project_integration.f，只有需要完整
// 报文检查的 test 才显式加入自己的 filelist。
// 所有权与生命周期：checker 拥有两个 common SCB 和采样 sequence；Function、
// hub、ring、Host memory、PCIe 资源仍由 project_env/VIO 所有。shutdown 后 worker
// 排空并停止，release 再解除订阅；end checker 只观察状态，不消费报文。
// =============================================================================

`ifndef PROJECT_VIO_PACKET_CHECKER_SV
`define PROJECT_VIO_PACKET_CHECKER_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
import common_lib_pkg::*;

`ifdef AIP_CMDLINE_SV
typedef class project_vio_packet_end_checker;
`endif

class project_vio_packet_checker extends uvm_component;
    `uvm_component_utils(project_vio_packet_checker)

    typedef common_uvm_scb #(virtio_packet_sample) packet_scb_t;

    packet_scb_t			vtx_scb;
    packet_scb_t			vrx_scb;
    common_uvm_scb_cfg		scb_cfg;

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
        string name="project_vio_packet_checker",
        uvm_component parent=null
    );

    // 功能：创建方向 SCB 并应用公共配置。
    // 输入/输出：输入 UVM phase；无输出。
    // 边界/副作用：不访问 Function/DUT；SCB 使用 SCB_UNORDERED 仅作为未 keyed
    // 兼容路径，完整报文调用 push_*_keyed。
    extern virtual function void build_phase(uvm_phase phase);

    // 功能：绑定一个已完成配置的 VIO Function，并建立 VTX/RX 两个 consumer。
    // 输入/输出：输入 Function instance；无返回值。
    // 边界/副作用：重复绑定同一对象被忽略；未配置 Function 报错；不配置队列。
    extern function void bind_function(virtio_function_instance instance);

    // 功能：把 RM 生成的 expected 样本送入对应方向 SCB。
    // 输入/输出：输入方向和完整样本；无返回值。
    // 边界/副作用：有 packet_key 时使用 keyed API；没有 key 时走旧 stream API，
    // 便于先调通采样再逐步接入 payload 中的稳定报文标记。
    extern function void push_expected(
        vio_packet_dir_e direction,
        virtio_packet_sample sample
    );

    // 功能：把采样到的 actual 样本送入对应方向 SCB。
    // 输入/输出：输入方向和完整样本；无返回值。
    // 边界/副作用：keyed 样本按 Function/queue stream 独立乱序匹配；空 key 保持
    // 兼容 stream FIFO，用户若要求跨方向严格配对应在 RM/解析器中补 key。
    extern function void push_actual(
        vio_packet_dir_e direction,
        virtio_packet_sample sample
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
    extern function void register_end_checker(string name="vio_packet_scb");
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
    // 边界/副作用：无绑定 Function 时不创建线程；线程只取 hub 样本并调用 actual 接口。
    extern virtual task run_phase(uvm_phase phase);

    // 功能：轮询一个 Function 的 VTX/RX mailbox。
    // 输入/输出：输入 binding 下标；无输出。
    // 边界/副作用：每次等待最多 1ns，确保 shutdown 能及时结束；不启动 PCIe sequence。
    extern task run_worker(int unsigned index);

    // 功能：在报告阶段输出两个 SCB 的汇总。
    // 输入/输出：输入 UVM phase；无输出。
    // 边界/副作用：只打印配置允许的报告，不自动释放订阅或资源。
    extern virtual function void report_phase(uvm_phase phase);
endclass

function project_vio_packet_checker::new(
    string name="project_vio_packet_checker",
    uvm_component parent=null
);
    super.new(name, parent);
    m_stop            = 0;
    m_workers_started = 0;
    m_active_workers  = 0;
endfunction

function void project_vio_packet_checker::build_phase(uvm_phase phase);
    super.build_phase(phase);
    vtx_scb = packet_scb_t::type_id::create("vtx_scb", this);
    vrx_scb = packet_scb_t::type_id::create("vrx_scb", this);
    if (uvm_config_db#(common_uvm_scb_cfg)::get(this, "", "scb_cfg", scb_cfg)) begin
        uvm_config_db#(common_uvm_scb_cfg)::set(this, "vtx_scb", "cfg", scb_cfg);
        uvm_config_db#(common_uvm_scb_cfg)::set(this, "vrx_scb", "cfg", scb_cfg);
    end
endfunction

function void project_vio_packet_checker::bind_function(
    virtio_function_instance instance
);
    virtio_packet_seq sample_seq;
    int unsigned consumer_id;

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
    m_functions.push_back(instance);
    m_sequences.push_back(sample_seq);
    m_consumer_ids.push_back(consumer_id);
endfunction

function void project_vio_packet_checker::push_expected(
    vio_packet_dir_e direction,
    virtio_packet_sample sample
);
    packet_scb_t scoreboard;
    longint unsigned stream_id;

    if (sample == null) return;
    scoreboard = (direction == VIO_PACKET_VTX) ? vtx_scb : vrx_scb;
    stream_id = sample.flow_stream_id();
    if (sample.has_packet_key())
        scoreboard.push_expected_keyed(sample, stream_id, -1, sample.packet_key);
    else
        scoreboard.push_expected(sample, stream_id);
endfunction

function void project_vio_packet_checker::push_actual(
    vio_packet_dir_e direction,
    virtio_packet_sample sample
);
    packet_scb_t scoreboard;
    longint unsigned stream_id;

    if (sample == null) return;
    scoreboard = (direction == VIO_PACKET_VTX) ? vtx_scb : vrx_scb;
    stream_id = sample.flow_stream_id();
    if (sample.has_packet_key())
        scoreboard.push_actual_keyed(sample, stream_id, -1, sample.packet_key);
    else
        scoreboard.push_actual(sample, stream_id);
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
    string name="vio_packet_scb"
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

task project_vio_packet_checker::run_phase(uvm_phase phase);
    if (m_workers_started) return;
    m_workers_started = 1;
    foreach (m_sequences[i]) begin
        automatic int unsigned index = i;
        fork
            run_worker(index);
        join_none
    end
endtask

task project_vio_packet_checker::run_worker(int unsigned index);
    virtio_packet_sample packet;
    bit got_packet;

    m_worker_alive[index] = 1;
    m_active_workers++;
    forever begin
        got_packet = 0;
        while (m_sequences[index].hub.pending(VIO_PACKET_VTX,
                                               m_consumer_ids[index]) != 0) begin
            m_sequences[index].mon_xaction(
                packet, VIO_PACKET_VTX, m_consumer_ids[index], 0);
            if (packet != null) begin
                push_actual(VIO_PACKET_VTX, packet);
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
            push_actual(VIO_PACKET_VTX, packet);
            continue;
        end
        m_sequences[index].mon_xaction(
            packet, VIO_PACKET_VRX, m_consumer_ids[index], 1ns);
        if (packet != null) push_actual(VIO_PACKET_VRX, packet);
    end
    m_worker_alive[index] = 0;
    m_active_workers--;
endtask

function void project_vio_packet_checker::report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (vtx_scb != null) vtx_scb.print_report();
    if (vrx_scb != null) vrx_scb.print_report();
endfunction

`ifdef AIP_CMDLINE_SV
import aip_core_pkg::*;

class project_vio_packet_end_checker extends aip_end_checker;
    protected project_vio_packet_checker m_owner;

    // 功能：创建 AIP end_test 适配器。
    // 输入/输出：输入 sidecar；输出为轻量借用适配器。
    // 边界/副作用：不注册全局 checker；注册动作由 test 明确执行。
    extern function new(project_vio_packet_checker owner);

    extern virtual function bit is_done();

    extern virtual function bit has_failed();

    extern virtual function string status_detail();
endclass

function project_vio_packet_end_checker::new(project_vio_packet_checker owner);
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
