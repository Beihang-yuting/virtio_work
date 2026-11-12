// =============================================================================
// integration/project/tests：VIO wire trace、项目 checker 与 TX DMA 的聚焦测试。
// 文件职责：用固定字节验证 20B tail/CRC/显式 stream registry，再复用生成的
// common SCB 检查乱序、坏路由和限流；最后经真实 atomic ops、Packed/Custom
// virtqueue 和 Host memory 验证 trace 在 DMA 前写入。测试不拥有生产 registry，
// 因而 ID 耗尽用例必须最后运行；fixture 拥有 Host memory，ops 拥有提交后的 DMA。
// 主要依赖：virtio_net_pkg、net_packet、mock transport/vq test kit、生成的
// common_lib_pkg、project_vio_packet_checker 以及更新版 aip_core_pkg。
// =============================================================================

`include "virtio_mock_transport.sv"
`include "virtio_vq_test_kit.sv"
`include "virtio_shared_mem_fixture.sv"

import uvm_pkg::*;
import dpu_resource_pkg::*;
import net_packet_pkg::*;
import virtio_net_pkg::*;
import common_lib_pkg::*;
`ifdef AIP_CMDLINE_SV
import aip_core_pkg::*;
`endif

// 生产 resource client 的映射只能来自冻结 snapshot；本测试只需隔离验证
// packet_identity 的查询行为，因此子类只向 protected 只读表注入一条确定映射。
class project_vio_resource_client_probe extends virtio_resource_client;
    // 创建空映射 probe；映射必须随后通过 seed_mapping 显式注入。
    extern function new(string	name="project_vio_resource_client_probe");

    // 注入一对 RX/TX local qid 到同一 global qpair；不伪造 snapshot/runtime 状态。
    extern function void seed_mapping(
        int unsigned	rx_local_qid,
        int unsigned	tx_local_qid,
        int unsigned	global_qid
    );
endclass

function project_vio_resource_client_probe::new(string	name);
    super.new(name);
endfunction

function void project_vio_resource_client_probe::seed_mapping(
    int unsigned	rx_local_qid,
    int unsigned	tx_local_qid,
    int unsigned	global_qid
);
    virtio_qpair_mapping_t	mapping;

    mapping = '{default:0};
    mapping.rx_virtqueue_id = rx_local_qid;
    mapping.tx_virtqueue_id = tx_local_qid;
    mapping.rx_global_qid   = global_qid;
    mapping.tx_global_qid   = global_qid;
    qpair_mappings.push_back(mapping);
endfunction

class project_vio_packet_test extends uvm_test;
    `uvm_component_utils(project_vio_packet_test)

    project_vio_packet_checker	checker;
    virtio_function_instance	bound_function;
    virtio_atomic_ops		bound_ops;
    common_uvm_scb_cfg		scb_cfg;

    virtio_shared_mem_fixture	fixture;
    virtio_vq_test_kit		kit;
    virtio_iommu_model		iommu;
    virtio_mock_transport	transport;

    // 创建测试组件；资源和队列等到 run_phase 才分配。
    extern function new(string	name="project_vio_packet_test",
                        uvm_component	parent=null);

    // 提前创建 checker、Function 外壳和待绑定 ops，使 checker 能在 run_phase 前订阅 hub。
    extern virtual function void build_phase(uvm_phase	phase);

    // 把 Function 的真实 driver-agent 入口接到测试 ops，并验证 bind_function 自动开 trace。
    extern virtual function void connect_phase(uvm_phase	phase);

    // 任一合同失败立即终止，消息包含聚焦条件，避免后续错误覆盖首因。
    extern function void require_true(bit	value, string	message);

    // 构造一个身份完整但不持有外部资源的样本；调用方可再修改单个身份维度。
    extern function virtio_packet_sample make_identity(
        string			name,
        vio_packet_dir_e	direction,
        longint unsigned	epoch = 0
    );

    // 构造确定性 Ethernet/IPv4/UDP 字节；42B 后递增，便于注入协议字段和 payload 差异。
    extern function void make_frame(int unsigned	length,
                                    ref byte unsigned	bytes[$]);

    // 重新计算当前帧最后20B tail 的 CRC；只用于构造通过 CRC 的字段负例。
    extern function void rewrite_tail_crc(ref byte unsigned	bytes[$]);

    // 从 Host memory 读取小端数值，供 descriptor 地址和长度检查。
    extern function bit [63:0] read_le(bit [63:0]	address,
                                       int unsigned	count);

    // 按 Host/BDF 翻译 IOVA 后读取真实 DMA 字节；翻译失败即测试失败。
    extern function void read_dma(
        bit [63:0]	address,
        int unsigned	count,
        ref byte		data[]
    );

    // 验证 CRC 已知向量、tail 字节布局、序号和身份维度不会共享 stream ID。
    extern function void check_trace_layout_and_identity();

    // 验证 decode 对长度、magic、版本、方向、CRC 和未知 ID 的逐层拒绝。
    extern function void check_trace_rejections();

    // 验证字节比较只看 wire frame，并给出头、payload 与长度的有限差异。
    extern function void check_wire_compare();

    // 验证 keyed SCB 支持 actual-first/跨 key 乱序，并拒绝实际 VRX 错队列。
    extern function void check_checker_order_and_route();

    // 产生1000个输入错误，验证默认只显示10条但总计完整；limit=0仍保持 FAIL。
    extern function void check_checker_error_limit();

    // 把 fatal 的动作临时限制为显示，验证局部 AIP catcher 不改写或吞掉 fatal 文本。
    extern function void check_fatal_passthrough();

    // 真实提交 Standard Packed 与 Custom 队列并回读 DMA；另一路未绑定 ops 验证原字节。
    extern task check_tx_dma();

    // 耗尽全局16bit stream ID，验证第65536个不同流被拒绝且不修改字节、不回绕。
    extern function void check_stream_exhaustion();

    // 按由轻到重的顺序执行；ID耗尽最后运行，结束前排空 checker worker 和 DMA。
    extern virtual task run_phase(uvm_phase	phase);
endclass

function project_vio_packet_test::new(string	name, uvm_component	parent);
    super.new(name, parent);
endfunction

function void project_vio_packet_test::build_phase(uvm_phase	phase);
    super.build_phase(phase);

    scb_cfg = new("scb_cfg");
    scb_cfg.m_cmp_mode     = SCB_UNORDERED;
    scb_cfg.m_err_limit    = 10;
    scb_cfg.m_report_en    = 0;
    scb_cfg.m_pending_limit = 0;
    uvm_config_db#(common_uvm_scb_cfg)::set(this, "checker", "scb_cfg", scb_cfg);

    // 此 Function 只提供 checker.bind_function 所需的真实 agent/ops 层次，
    // 测试直接调用 ops，不启动需要 FSM 的 sequence driver。
    uvm_config_db#(uvm_active_passive_enum)::set(
        this, "bound_function.driver_agent", "is_active", UVM_PASSIVE);

    checker        = project_vio_packet_checker::type_id::create("checker", this);
    bound_function = virtio_function_instance::type_id::create("bound_function", this);
    bound_ops      = virtio_atomic_ops::type_id::create("bound_ops");
endfunction

function void project_vio_packet_test::connect_phase(uvm_phase	phase);
    super.connect_phase(phase);
    require_true(bound_function.driver_agent != null,
                 "Function driver_agent was not built before connect_phase");
    require_true(!bound_ops.packet_trace_enabled,
                 "new ops must leave packet trace disabled");
    bound_function.driver_agent.ops = bound_ops;
    checker.bind_function(bound_function);
    require_true(bound_ops.packet_trace_enabled,
                 "checker.bind_function must enable packet trace");
endfunction

function void project_vio_packet_test::require_true(bit	value, string	message);
    if (!value)
        `uvm_fatal("VIO_PACKET_TEST", message)
endfunction

function virtio_packet_sample project_vio_packet_test::make_identity(
    string			name,
    vio_packet_dir_e	direction,
    longint unsigned	epoch
);
    virtio_packet_sample	sample;

    sample = new(name);
    sample.direction                    = direction;
    sample.identity_valid               = 1;
    sample.function_key                 = '{host_id:0, pf_id:0,
                                            kind:DPU_FUNCTION_PF, vf_id:0};
    sample.service_key.function_key     = sample.function_key;
    sample.service_key.service_kind     = DPU_SERVICE_VIO_NET;
    sample.service_key.service_instance_id = 0;
    sample.host_id                      = 0;
    sample.bdf                          = 16'h0001;
    sample.is_vf                        = 0;
    sample.vf_id                        = 0;
    sample.local_qid                    = 1;
    sample.global_qid                   = 17;
    sample.reset_epoch                  = epoch;
    return sample;
endfunction

function void project_vio_packet_test::make_frame(
    int unsigned	length,
    ref byte unsigned	bytes[$]
);
    int unsigned	checksum_sum;
    bit [15:0]		ipv4_length;
    bit [15:0]		udp_length;

    bytes.delete();
    for (int unsigned	index = 0; index < length; index++)
        bytes.push_back(byte'(index));
    if (length >= 14) begin
        bytes[0]  = 8'h02;
        bytes[6]  = 8'h0a;
        bytes[12] = 8'h08;
        bytes[13] = 8'h00;
    end
    if (length >= 42) begin
        ipv4_length = length - 14;
        udp_length  = length - 34;

        bytes[14] = 8'h45;
        bytes[15] = 8'h00;
        bytes[16] = ipv4_length[15:8];
        bytes[17] = ipv4_length[7:0];
        bytes[18] = 8'h12;
        bytes[19] = 8'h34;
        bytes[20] = 8'h40;
        bytes[21] = 8'h00;
        bytes[22] = 8'h40;
        bytes[23] = 8'h11;
        bytes[24] = 8'h00;
        bytes[25] = 8'h00;
        bytes[26] = 8'hc0;
        bytes[27] = 8'h00;
        bytes[28] = 8'h02;
        bytes[29] = 8'h01;
        bytes[30] = 8'hc6;
        bytes[31] = 8'h33;
        bytes[32] = 8'h64;
        bytes[33] = 8'h02;

        checksum_sum = 0;
        for (int	index = 14; index < 34; index += 2)
            checksum_sum += {bytes[index], bytes[index + 1]};
        while (checksum_sum[31:16] != 0)
            checksum_sum = checksum_sum[15:0] + checksum_sum[31:16];
        bytes[24] = ~checksum_sum[15:8];
        bytes[25] = ~checksum_sum[7:0];

        bytes[34] = 8'h12;
        bytes[35] = 8'h34;
        bytes[36] = 8'h56;
        bytes[37] = 8'h78;
        bytes[38] = udp_length[15:8];
        bytes[39] = udp_length[7:0];
        bytes[40] = 8'h00;
        bytes[41] = 8'h00;
    end
endfunction

function void project_vio_packet_test::rewrite_tail_crc(ref byte unsigned	bytes[$]);
    byte unsigned	tail[$];
    bit [15:0]		crc;
    int			base;

    require_true(bytes.size() >= 20, "rewrite_tail_crc requires a complete tail");
    base = bytes.size() - 20;
    for (int	index = 0; index < 18; index++)
        tail.push_back(bytes[base + index]);
    crc = virtio_packet_trace::crc16(tail);
    bytes[base + 18] = crc[7:0];
    bytes[base + 19] = crc[15:8];
endfunction

function bit [63:0] project_vio_packet_test::read_le(
    bit [63:0]	address,
    int unsigned	count
);
    byte		data[];
    bit [63:0]	value;

    kit.mem.read_mem(address, count, data);
    value = 0;
    foreach (data[index])
        value[index * 8 +: 8] = data[index];
    return value;
endfunction

function void project_vio_packet_test::read_dma(
    bit [63:0]	address,
    int unsigned	count,
    ref byte		data[]
);
    bit [63:0]	gpa;
    iommu_fault_e	fault;

    require_true(iommu.translate_for_host(0, transport.bdf, address, count,
                 DMA_TO_DEVICE, gpa, fault),
                 $sformatf("DMA translation failed address=0x%016h", address));
    kit.mem.read_mem(gpa, count, data);
endfunction

function void project_vio_packet_test::check_trace_layout_and_identity();
    byte unsigned	vector[$];
    byte unsigned	first[$];
    byte unsigned	second[$];
    byte unsigned	variant_bytes[$];
    virtio_packet_sample	base_sample;
    virtio_packet_sample	second_sample;
    virtio_packet_sample	variants[6];
    virtio_packet_sample	decoded;
    bit [15:0]		first_id;
    bit [15:0]		ids[6];
    string		why;
    int			base;

    vector = '{8'h31, 8'h32, 8'h33, 8'h34, 8'h35,
               8'h36, 8'h37, 8'h38, 8'h39};
    require_true(virtio_packet_trace::crc16(vector) == 16'h29b1,
                 "CRC-16/CCITT-FALSE known vector must equal 0x29b1");

    base_sample = make_identity("layout", VIO_PACKET_VTX, 0);
    make_frame(64, first);
    require_true(virtio_packet_trace::stamp(base_sample, first, why), why);
    first_id = base_sample.stream_id;
    base = first.size() - 20;
    require_true(first.size() == 64 && first[base + 0] == 8'h56 &&
                 first[base + 1] == 8'h49 && first[base + 2] == 8'h4f &&
                 first[base + 3] == 8'h31 && first[base + 4] == 1 &&
                 first[base + 5] == byte'(VIO_PACKET_VTX),
                 "tail magic/version/direction layout");
    require_true({first[base + 7], first[base + 6]} == first_id &&
                 {first[base + 17], first[base + 16]} == 16'd64,
                 "tail stream_id and final length must be little-endian");
    for (int	index = 8; index < 16; index++)
        require_true(first[base + index] == 0,
                     "first packet sequence must be little-endian zero");
    require_true(virtio_packet_trace::decode(first, VIO_PACKET_VTX, decoded, why), why);
    require_true(decoded.stream_id == first_id && decoded.packet_sequence == 0 &&
                 decoded.flow_key() == base_sample.flow_key(),
                 "decode must restore registered identity and sequence");

    second_sample = make_identity("layout_second", VIO_PACKET_VTX, 0);
    make_frame(64, second);
    require_true(virtio_packet_trace::stamp(second_sample, second, why), why);
    require_true(second_sample.stream_id == first_id &&
                 second_sample.packet_sequence == 1,
                 "same flow must reuse stream_id and increment sequence");

    variants[0] = make_identity("host", VIO_PACKET_VTX, 0);
    variants[0].host_id = 1;
    variants[0].function_key.host_id = 1;
    variants[0].service_key.function_key = variants[0].function_key;
    variants[1] = make_identity("pf", VIO_PACKET_VTX, 0);
    variants[1].function_key.pf_id = 1;
    variants[1].service_key.function_key = variants[1].function_key;
    variants[2] = make_identity("vf", VIO_PACKET_VTX, 0);
    variants[2].is_vf = 1;
    variants[2].vf_id = 3;
    variants[2].function_key.kind = DPU_FUNCTION_VF;
    variants[2].function_key.vf_id = 3;
    variants[2].service_key.function_key = variants[2].function_key;
    variants[3] = make_identity("qid", VIO_PACKET_VTX, 0);
    variants[3].local_qid = 2;
    variants[3].global_qid = 33;
    variants[4] = make_identity("epoch", VIO_PACKET_VTX, 1);
    variants[5] = make_identity("direction", VIO_PACKET_VRX, 0);
    foreach (variants[index]) begin
        make_frame(64 + index, variant_bytes);
        require_true(virtio_packet_trace::stamp(variants[index], variant_bytes, why), why);
        ids[index] = variants[index].stream_id;
        require_true(ids[index] != first_id,
                     "each changed identity dimension must allocate another stream");
        for (int	prior = 0; prior < index; prior++)
            require_true(ids[index] != ids[prior],
                         "host/PF/VF/qid/epoch/direction stream IDs must not collide");
    end
endfunction

function void project_vio_packet_test::check_fatal_passthrough();
    uvm_report_server	server;
    int			fatal_count;

    server = uvm_report_server::get_server();
    fatal_count = server.get_severity_count(UVM_FATAL);
    checker.vtx_scb.set_report_id_action("VIO_FATAL_PROBE", UVM_DISPLAY);
    checker.vtx_scb.uvm_report_fatal(
        "VIO_FATAL_PROBE",
        "intentional fatal display probe",
        UVM_NONE,
        `__FILE__,
        `__LINE__
    );
    require_true(server.get_severity_count(UVM_FATAL) == fatal_count + 1,
                 "fatal probe must retain native UVM severity accounting");
    server.set_severity_count(UVM_FATAL, fatal_count);
    checker.vtx_scb.set_report_id_action(
        "VIO_FATAL_PROBE",
        UVM_DISPLAY | UVM_COUNT | UVM_EXIT
    );
endfunction

function void project_vio_packet_test::check_trace_rejections();
    byte unsigned	good[$];
    byte unsigned	bad[$];
    byte unsigned	short_frame[$];
    byte unsigned	short_original[$];
    virtio_packet_sample	identity;
    virtio_packet_sample	decoded;
    string		why;
    int			base;

    identity = make_identity("reject", VIO_PACKET_VRX, 9);
    make_frame(60, short_frame);
    short_original = short_frame;
    require_true(!virtio_packet_trace::stamp(identity, short_frame, why) &&
                 uvm_is_match("*at least 20B payload*", why) &&
                 short_frame == short_original,
                 "trace must reject a frame without 20B payload space");
    make_frame(72, good);
    require_true(virtio_packet_trace::stamp(identity, good, why), why);
    base = good.size() - 20;

    bad = good;
    bad[base] ^= 8'h01;
    require_true(!virtio_packet_trace::decode(bad, VIO_PACKET_VRX, decoded, why) &&
                 uvm_is_match("*bad trace magic*", why),
                 "bad magic must be rejected before registry lookup");

    bad = good;
    bad[base + 4] = 2;
    rewrite_tail_crc(bad);
    require_true(!virtio_packet_trace::decode(bad, VIO_PACKET_VRX, decoded, why) &&
                 uvm_is_match("*unsupported trace version*", why),
                 "unknown trace version must be rejected");

    bad = good;
    bad[base + 18] ^= 8'h80;
    require_true(!virtio_packet_trace::decode(bad, VIO_PACKET_VRX, decoded, why) &&
                 uvm_is_match("*bad trace crc*", why),
                 "corrupt CRC must be rejected");

    require_true(!virtio_packet_trace::decode(good, VIO_PACKET_VTX, decoded, why) &&
                 uvm_is_match("*trace direction/flags*", why),
                 "caller direction must match the tail flag");

    bad = good;
    bad[base + 16] = 8'hff;
    bad[base + 17] = 8'h00;
    rewrite_tail_crc(bad);
    require_true(!virtio_packet_trace::decode(bad, VIO_PACKET_VRX, decoded, why) &&
                 uvm_is_match("*frame_length*", why),
                 "declared final length must match the complete frame");

    bad = good;
    bad[base + 6] = 0;
    bad[base + 7] = 0;
    rewrite_tail_crc(bad);
    require_true(!virtio_packet_trace::decode(bad, VIO_PACKET_VRX, decoded, why) &&
                 uvm_is_match("*unknown trace stream_id*", why),
                 "unregistered stream ID must be rejected");
endfunction

function void project_vio_packet_test::check_wire_compare();
    virtio_packet_sample	expected;
    virtio_packet_sample	actual;
    string		diff;
    string		wire_detail;

    expected = make_identity("expected_compare", VIO_PACKET_VTX, 0);
    actual   = make_identity("actual_compare", VIO_PACKET_VTX, 0);
    make_frame(96, expected.frame_bytes);
    actual.frame_bytes = expected.frame_bytes;
    actual.frame_bytes[0] ^= 8'h01;
    wire_detail = expected.wire_diff(actual);
    require_true(!expected.self_define_do_compare(actual, diff) &&
                 uvm_is_match("*first_diff=0*", diff) &&
                 uvm_is_match("*first_diff=0*", wire_detail) &&
                 uvm_is_match("*net_packet:*", wire_detail) &&
                 uvm_is_match(
                     "*dst_mac expect=02:01:02:03:04:05 actual=03:01:02:03:04:05*",
                     wire_detail),
                 "Ethernet mismatch must report both net_packet dst_mac values");

    actual.frame_bytes = expected.frame_bytes;
    actual.frame_bytes[22] ^= 8'h01;
    wire_detail = expected.wire_diff(actual);
    require_true(!expected.self_define_do_compare(actual, diff) &&
                 uvm_is_match("*first_diff=22*", wire_detail) &&
                 uvm_is_match("*net_packet:*", wire_detail) &&
                 uvm_is_match("*ttl expect=64 actual=65*", wire_detail),
                 "IPv4 TTL mismatch must include both net_packet field values");

    actual.frame_bytes = expected.frame_bytes;
    actual.frame_bytes[34] ^= 8'h01;
    wire_detail = expected.wire_diff(actual);
    require_true(!expected.self_define_do_compare(actual, diff) &&
                 uvm_is_match("*first_diff=34*", wire_detail) &&
                 uvm_is_match("*net_packet:*", wire_detail) &&
                 uvm_is_match("*src_port expect=4660 actual=4916*", wire_detail),
                 "UDP source-port mismatch must include both net_packet field values");

    actual.frame_bytes = expected.frame_bytes;
    actual.frame_bytes[48] ^= 8'h5a;
    require_true(!expected.self_define_do_compare(actual, diff) &&
                 uvm_is_match("*first_diff=48*", diff) &&
                 uvm_is_match("*first_diff=48*", expected.wire_diff(actual)),
                 "payload mismatch must report its wire offset");

    actual.frame_bytes = expected.frame_bytes;
    void'(actual.frame_bytes.pop_back());
    require_true(!expected.self_define_do_compare(actual, diff) &&
                 uvm_is_match("*expected_len=96 actual_len=95*", diff) &&
                 uvm_is_match("*expected_len=96 actual_len=95*", expected.wire_diff(actual)),
                 "length mismatch must report both wire lengths");

    actual.frame_bytes = expected.frame_bytes;
    actual.net_hdr.flags = 1;
    actual.descriptor_id = 99;
    require_true(expected.self_define_do_compare(actual, diff),
                 "Virtio metadata must not participate in wire comparison");
endfunction

function void project_vio_packet_test::check_checker_order_and_route();
    byte unsigned	frame0[$];
    byte unsigned	frame1[$];
    byte unsigned	route_frame[$];
    virtio_packet_sample	expected0;
    virtio_packet_sample	expected1;
    virtio_packet_sample	route_expected;
    virtio_packet_sample	route_actual;
    string		why;
    string		summary;

    checker.vtx_scb.reset_state();
    checker.vtx_scb.m_cfg.m_err_limit = 0;
    expected0 = make_identity("order0", VIO_PACKET_VTX, 31);
    expected1 = make_identity("order1", VIO_PACKET_VTX, 31);
    make_frame(64, frame0);
    make_frame(80, frame1);
    require_true(virtio_packet_trace::stamp(expected0, frame0, why), why);
    require_true(virtio_packet_trace::stamp(expected1, frame1, why), why);

    checker.push_actual_bytes(VIO_PACKET_VTX, frame1);
    checker.push_actual_bytes(VIO_PACKET_VTX, frame0);
    checker.push_expected(VIO_PACKET_VTX, expected0);
    checker.push_expected(VIO_PACKET_VTX, expected1);
    require_true(checker.vtx_scb.is_clean() &&
                 uvm_is_match("*match=2 mismatch=0*", checker.vtx_scb.get_summary()),
                 "keyed checker must match actual-first packets across arrival order");

    checker.vrx_scb.reset_state();
    checker.vrx_scb.m_cfg.m_err_limit = 0;
    route_expected = make_identity("route_expected", VIO_PACKET_VRX, 32);
    route_expected.local_qid  = 4;
    route_expected.global_qid = 104;
    make_frame(68, route_frame);
    require_true(virtio_packet_trace::stamp(route_expected, route_frame, why), why);
    checker.push_expected(VIO_PACKET_VRX, route_expected);

    route_actual = make_identity("route_actual", VIO_PACKET_VRX, 32);
    route_actual.local_qid  = 5;
    route_actual.global_qid = 105;
    route_actual.frame_bytes = route_frame;
    checker.push_actual(VIO_PACKET_VRX, route_actual);
    summary = checker.vrx_scb.get_summary();
    require_true(checker.vrx_scb.get_status() == SCB_FAIL &&
                 uvm_is_match("*pending_expected=1*", summary) &&
                 uvm_is_match("*overflow=1*", summary),
                 "real VRX identity from another queue must be rejected without consuming expected");
    checker.vrx_scb.reset_state();
endfunction

function void project_vio_packet_test::check_checker_error_limit();
    uvm_report_server	server;
    virtio_packet_sample	expected;
    byte unsigned	actual_bytes[$];
    string		why;
    int			error_count;
    string		summary;

    server = uvm_report_server::get_server();
    error_count = server.get_severity_count(UVM_ERROR);

    checker.vtx_scb.reset_state();
    checker.vtx_scb.m_cfg.m_err_limit = 10;
    for (int	index = 0; index < 1000; index++) begin
        expected = make_identity("limit_expected", VIO_PACKET_VTX, 64'h4000);
        make_frame(64, expected.frame_bytes);
        expected.frame_bytes[40] = byte'(index);
        require_true(virtio_packet_trace::stamp(expected, expected.frame_bytes, why), why);
        actual_bytes = expected.frame_bytes;
        actual_bytes[40] ^= 8'hff;
        checker.push_expected(VIO_PACKET_VTX, expected);
        checker.push_actual_bytes(VIO_PACKET_VTX, actual_bytes);
    end
    summary = checker.vtx_scb.get_summary();
    require_true(checker.vtx_scb.get_status() == SCB_FAIL &&
                 uvm_is_match("*expected=1000 actual=1000*", summary) &&
                 uvm_is_match("*mismatch=1000*", summary) &&
                 uvm_is_match("*overflow=0*", summary) &&
                 uvm_is_match("*suppressed=990*", summary),
                 {"1000 valid-tail mismatches must retain totals while limiting detail: ",
                  summary});
    require_true(server.get_severity_count(UVM_ERROR) == error_count + 10,
                 "AIP report bridge must preserve exactly ten UVM error counts");
    server.set_severity_count(UVM_ERROR, error_count);

    checker.vtx_scb.reset_state();
    checker.vtx_scb.m_cfg.m_err_limit = 0;
    expected = make_identity("zero_limit_expected", VIO_PACKET_VTX, 64'h4000);
    make_frame(64, expected.frame_bytes);
    require_true(virtio_packet_trace::stamp(expected, expected.frame_bytes, why), why);
    actual_bytes = expected.frame_bytes;
    actual_bytes[41] ^= 8'hff;
    checker.push_expected(VIO_PACKET_VTX, expected);
    checker.push_actual_bytes(VIO_PACKET_VTX, actual_bytes);
    summary = checker.vtx_scb.get_summary();
    require_true(checker.vtx_scb.get_status() == SCB_FAIL &&
                 uvm_is_match("*mismatch=1*", summary) &&
                 uvm_is_match("*suppressed=1*", summary) &&
                 server.get_severity_count(UVM_ERROR) == error_count,
                 "detail limit zero must suppress mismatch detail but keep FAIL and totals");
    checker.vtx_scb.check_phase(null);
    require_true(server.get_severity_count(UVM_ERROR) == error_count + 1,
                 "SCB_FINAL must still report one error when detail limit is zero");
    server.set_severity_count(UVM_ERROR, error_count);
    checker.vtx_scb.reset_state();
    checker.vtx_scb.m_cfg.m_err_limit = 10;
endfunction

task project_vio_packet_test::check_tx_dma();
    packed_virtqueue		packed_vq;
    packed_virtqueue		plain_vq;
    custom_virtqueue		custom_vq;
    virtio_vq_test_kit		plain_kit;
    virtio_atomic_ops		plain_ops;
    virtio_mock_transport	plain_transport;
    packet_item			item;
    packet_item			plain_item;
    virtio_net_hdr_t		hdr;
    uvm_object			completed[$];
    byte				dma_bytes[];
    byte				completion[2];
    byte unsigned		actual_bytes[$];
    int unsigned			head;
    int unsigned			length;
    bit [63:0]			address;
    virtio_packet_sample		decoded;
    project_vio_resource_client_probe	resource_probe;
    virtio_packet_sample		mapped_identity;
    string			why;

    // 前序 checker 用例已有两次成功匹配；DMA 用例独立核对本阶段的两包。
    checker.vtx_scb.reset_state();
    fixture = new("wire_memory");
    require_true(fixture.create_host(0, 64'h0000_0001_0000_0000,
                                     64'h0000_0001_00ff_ffff),
                 "Host memory fixture creation");
    iommu = new("wire_iommu");
    transport = new("wire_transport");
    transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0001));
    kit = virtio_vq_test_kit::create_kit("wire", fixture.get_host(0), iommu,
                                         transport.bdf);
    void'(kit.make_ops(transport, "", bound_ops));
    bound_ops.function_key = '{host_id:0, pf_id:2, kind:DPU_FUNCTION_PF, vf_id:0};
    bound_ops.service_key.function_key = bound_ops.function_key;
    bound_ops.service_key.service_kind = DPU_SERVICE_VIO_NET;
    bound_ops.service_key.service_instance_id = 7;
    bound_ops.function_identity_valid = 1;

    resource_probe = new("resource_probe");
    resource_probe.seed_mapping(0, 1, 77);
    resource_probe.seed_mapping(2, 3, 78);
    transport.fabric_resource_client = resource_probe;
    mapped_identity = bound_ops.packet_identity(1, VIO_PACKET_VTX);
    require_true(mapped_identity.identity_valid && mapped_identity.local_qid == 1 &&
                 mapped_identity.global_qid == 77,
                 "packet identity must query the resource client's local-to-global map");
    require_true(!bound_ops.packet_identity(4, VIO_PACKET_VTX).identity_valid,
                 "unmapped local qid must invalidate packet identity");
    begin
        virtio_atomic_ops	no_transport_ops;
        no_transport_ops = new("no_transport_ops");
        no_transport_ops.function_identity_valid = 1;
        require_true(!no_transport_ops.packet_identity(1, VIO_PACKET_VTX).identity_valid,
                     "transport=null must invalidate packet identity");
    end

    packed_vq = kit.add_packed(1, 8);
    require_true($cast(custom_vq, kit.vq_mgr.create_queue(3, 4, VQ_CUSTOM)),
                 "create Custom queue");
    custom_vq.local_qid = 3;
    custom_vq.alloc_rings();

    item = new("traced_packet");
    make_frame(96, item.pkt.raw_data);
    hdr = '{default:0};
    bound_ops.tx_submit(1, hdr, item, 0, head);
    require_true(head == 0, "first Packed traced submit descriptor ID");
    address = read_le(packed_vq.desc_table_addr + 16, 8);
    length  = read_le(packed_vq.desc_table_addr + 24, 4);
    require_true(length == item.pkt.raw_data.size(),
                 "Standard Packed descriptor must preserve the frame length");
    read_dma(address, length, dma_bytes);
    actual_bytes.delete();
    foreach (dma_bytes[index])
        actual_bytes.push_back(dma_bytes[index]);
    require_true(virtio_packet_trace::decode(actual_bytes, VIO_PACKET_VTX,
                 decoded, why) && decoded.local_qid == 1,
                 {"Standard Packed DMA tail decode failed: ", why});
    checker.push_actual_bytes(VIO_PACKET_VTX, actual_bytes);
    virtio_vq_test_kit::complete_packed(kit.mem, packed_vq, head);
    bound_ops.tx_complete(1, completed, 1);
    require_true(completed.size() == 1, "Standard Packed completion must release traced DMA");

    completed.delete();
    bound_ops.tx_submit(3, hdr, item, 0, head);
    require_true(head == 0, "first Custom traced submit descriptor ID");
    address = read_le(custom_vq.desc_table_addr, 8);
    length  = read_le(custom_vq.desc_table_addr + 8, 4) & 32'h3ffff;
    require_true(length == item.pkt.raw_data.size(),
                 "Custom descriptor must preserve the frame length");
    read_dma(address, length, dma_bytes);
    actual_bytes.delete();
    foreach (dma_bytes[index])
        actual_bytes.push_back(dma_bytes[index]);
    require_true(virtio_packet_trace::decode(actual_bytes, VIO_PACKET_VTX,
                 decoded, why) && decoded.local_qid == 3,
                 {"Custom DMA tail decode failed: ", why});
    checker.push_actual_bytes(VIO_PACKET_VTX, actual_bytes);
    completion[0] = custom_vq.producer_index;
    completion[1] = custom_vq.producer_wrap ? 8'h80 : 0;
    kit.mem.write_mem(custom_vq.cq_addr, completion);
    bound_ops.tx_complete(3, completed, 1);
    require_true(completed.size() == 1, "Custom completion must release traced DMA");

    plain_transport = new("plain_transport");
    plain_transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0002));
    plain_kit = virtio_vq_test_kit::create_kit("plain", fixture.get_host(0), iommu,
                                               plain_transport.bdf);
    plain_ops = plain_kit.make_ops(plain_transport, "plain_ops");
    plain_ops.function_identity_valid = 1;
    plain_vq = plain_kit.add_packed(5, 8);
    plain_item = new("plain_packet");
    make_frame(88, plain_item.pkt.raw_data);
    require_true(!plain_ops.packet_trace_enabled,
                 "ops without checker binding must keep trace disabled");
    plain_ops.tx_submit(5, hdr, plain_item, 0, head);
    address = read_le(plain_vq.desc_table_addr + 16, 8);
    length  = read_le(plain_vq.desc_table_addr + 24, 4);
    require_true(length == plain_item.pkt.raw_data.size(),
                 "unbound Standard submit must preserve original descriptor length");
    begin
        bit [63:0]	plain_gpa;
        iommu_fault_e	plain_fault;
        require_true(iommu.translate_for_host(0, plain_transport.bdf, address, length,
                     DMA_TO_DEVICE, plain_gpa, plain_fault),
                     "plain DMA translation");
        fixture.get_host(0).read_mem(plain_gpa, length, dma_bytes);
    end
    foreach (dma_bytes[index])
        require_true(dma_bytes[index] == plain_item.pkt.raw_data[index],
                     $sformatf("unbound DMA byte changed at %0d", index));
    completed.delete();
    virtio_vq_test_kit::complete_packed(plain_kit.mem, plain_vq, head);
    plain_ops.tx_complete(5, completed, 1);
    require_true(completed.size() == 1, "plain completion must release DMA");

    #20ns;
    require_true(checker.vtx_scb.is_clean() &&
                 uvm_is_match("*match=2 mismatch=0*", checker.vtx_scb.get_summary()),
                 {"checker did not match both real DMA packets: ",
                  checker.vtx_scb.get_summary()});
    kit.vq_mgr.destroy_all();
    plain_kit.vq_mgr.destroy_all();
    fixture.leak_check();
endtask

function void project_vio_packet_test::check_stream_exhaustion();
    virtio_packet_sample	sample;
    virtio_packet_sample	existing;
    byte unsigned	bytes[$];
    byte unsigned	original_bytes[$];
    string		why;
    int unsigned		attempts;

`ifdef AIP_CMDLINE_SV
    aip_log::set_verbosity(aip_log::ERROR);
`endif
    attempts = 0;
    while (attempts < 65536) begin
        sample = make_identity("exhaust", VIO_PACKET_VTX,
                               64'h1000_0000 + attempts);
        make_frame(64, bytes);
        if (!virtio_packet_trace::stamp(sample, bytes, why))
            break;
        attempts++;
        if (sample.stream_id == 16'hffff)
            break;
    end
    require_true(sample != null && sample.stream_id == 16'hffff,
                 "registry must allocate stream_id 0xffff exactly once");

    sample = make_identity("overflow", VIO_PACKET_VTX, 64'hffff_ffff);
    make_frame(64, bytes);
    original_bytes = bytes;
    require_true(!virtio_packet_trace::stamp(sample, bytes, why) &&
                 uvm_is_match("*space exhausted*", why) && bytes == original_bytes &&
                 sample.stream_id == 0,
                 "new stream after 65535 IDs must fail without byte mutation or wrap");

    existing = make_identity("existing_after_full", VIO_PACKET_VTX, 0);
    make_frame(64, bytes);
    require_true(virtio_packet_trace::stamp(existing, bytes, why) &&
                 existing.stream_id != 0 && existing.packet_sequence == 2,
                 "existing stream must remain usable after registry exhaustion");
endfunction

task project_vio_packet_test::run_phase(uvm_phase	phase);
    phase.raise_objection(this);

    check_trace_layout_and_identity();
    check_trace_rejections();
    check_wire_compare();
    check_checker_order_and_route();
    check_tx_dma();
    check_checker_error_limit();
    check_fatal_passthrough();
    checker.shutdown();
    checker.release_subscriptions();
    checker.vtx_scb.reset_state();
    checker.vrx_scb.reset_state();
    check_stream_exhaustion();

    `uvm_info("VIO_PACKET_TEST_PASS",
              "wire trace, keyed checker, AIP limit and Standard/Custom DMA passed",
              UVM_NONE)
    phase.drop_objection(this);
endtask
