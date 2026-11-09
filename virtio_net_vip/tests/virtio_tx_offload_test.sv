// tests：VTX每包参数、标准header和Custom扩展描述符的聚焦合同测试。
// 复用net_packet与真实Host memory/ops/ring；只替代PCIe通知和设备完成，不模拟DUT分段。
// fixture拥有内存，ops拥有每包DMA；每项完成后检查回收，避免把扩展槽当成额外数据DMA。
`include "virtio_mock_transport.sv"
`include "virtio_vq_test_kit.sv"
`include "virtio_shared_mem_fixture.sv"

import aip_core_pkg::*;
import virtio_aip_pkg::*;

// 满环等待超过预算才报错；只捕获负例指定的ID和完整消息。
// callback仅在该次提交期间安装，其他错误继续交给UVM报告，不能被测试吞掉。
class virtio_tx_full_catcher extends uvm_report_catcher;
    string	expected_id;
    string	expected_message;
    int		caught_count;

    // 不拥有队列或DMA；计数仅统计精确匹配的预期报告。
    extern function new(string	name = "tx_full_catcher");

    // 错误来源或消息不同则原样抛出；匹配时记录供测试断言。
    extern virtual function action_e catch();
endclass

function virtio_tx_full_catcher::new(string	name = "tx_full_catcher");
    super.new(name);
endfunction

function uvm_report_catcher::action_e virtio_tx_full_catcher::catch();
    if (get_severity() == UVM_ERROR && get_id() == expected_id &&
        get_message() == expected_message) begin
        caught_count++;
        return CAUGHT;
    end
    return THROW;
endfunction

// 暴露真实sequence的参数采样入口；不复制宏实现，不创建新的参数注册表。
class virtio_tx_param_probe extends virtio_aip_sequence;
    // 只指定测试参数路径，所有参数仍由父类宏读取。
    extern function new(string name = "tx_param_probe");

    // 返回本次值副本，用于检查运行期改值和别名隔离。
    extern function void sample(output virtio_tx_offload_t request);
endclass

function virtio_tx_param_probe::new(string name = "tx_param_probe");
    super.new(name);
    path = "vio.tx";
endfunction

function void virtio_tx_param_probe::sample(output virtio_tx_offload_t request);
    load_tx_offload(request);
endfunction

class virtio_tx_offload_test extends uvm_test;
    `uvm_component_utils(virtio_tx_offload_test)

    virtio_shared_mem_fixture	fixture;
    virtio_vq_test_kit		kit;
    virtio_atomic_ops		ops;
    virtio_iommu_model		iommu;
    virtio_mock_transport	transport;
    bit [63:0]			features;
    int				driver_dump;
    int unsigned		random_kind_counts[packet_template_e];
    int unsigned		random_ip_options;
    int unsigned		random_tcp_options;
    int unsigned		random_jumbo;

    // 标准UVM构造；实际资源在run_phase创建。
    extern function new(string name, uvm_component parent);

    // 任一合同不满足即停止测试，保留首个失败原因。
    extern function void require_true(bit value, string message);

    // 创建固定地址/长度报文；payload仍由net_packet生成，返回对象由测试持有。
    extern function packet_item make_packet(packet_template_e kind, int unsigned length);

    // 随机生成八类普通/VLAN IPv4/IPv6 TCP/UDP报文、IP/TCP options、地址和payload。
    // 包长至少256B，保证Custom GSO模式下32..128B的MSS确实需要扩展描述符。
    extern function packet_item make_random_packet();

    // 独立按线速字段计算伪首部和并检查真实DMA字节；不复用被测adapter/parser作期望。
    // 可选导出Custom描述符供上传驱动原始C位域结构逐项核对，地址本身经IOMMU读回验证。
    extern function void check_published_packet(virtqueue_base	vq, int unsigned	head,
        packet_item	item, virtio_tx_offload_t	request);

    // 从真实Host内存读取小端字段；仅供黄金descriptor检查。
    extern function bit [63:0] read_le(bit [63:0] address, int unsigned count);

    // 按当前Host/BDF翻译descriptor地址再读取DMA数据，不假定IOVA等于GPA。
    extern function void read_dma(bit [63:0] address, int unsigned count, output byte data[]);

    // 检查标准能力依赖、协议类型、options长度、MSS门限及seed，不接触DMA。
    extern function void check_headers();

    // 用同一参数入口验证覆盖值逐次读取；先前请求保持原值，另一路径不串扰。
    extern task check_params();

    // 经过真实ops发布Packed/Custom描述符；检查DMA字节、尾指针、回绕与回收。
    extern task check_rings();

    // 默认三种格式各发1000包穿越深度128的ring；TX_RANDOM扩展逐包/逐批/完成延迟随机。
    // TX_DEPTH/TX_PACKETS只控制测试规模，生产行为仍经真实ops和队列执行。
    extern task check_capacity();

    // 聚焦检查全部完成后检查内存泄漏；不声称DUT已完成checksum/GSO。
    extern virtual task run_phase(uvm_phase phase);
endclass

function virtio_tx_offload_test::new(string name, uvm_component parent);
    super.new(name, parent);
endfunction

function void virtio_tx_offload_test::require_true(bit value, string message);
    if (!value)
        `uvm_fatal("TX_OFFLOAD_TEST", message)
endfunction

function packet_item virtio_tx_offload_test::make_packet(packet_template_e kind, int unsigned length);
    packet_item	item;
    ipv4_header	ip4;

    item = new("packet");
    item.pkt = new();
    item.pkt.build_from_template(kind);
    item.pkt.pkt_len = length;
    item.pkt.payload_mode = PAYLOAD_INCREMENT;
    ip4 = item.pkt.get_ipv4();
    if (ip4 != null) begin
        ip4.src_addr = 32'h0a000001;
        ip4.dst_addr = 32'h0a000002;
    end
    item.pkt.do_pack();
    return item;
endfunction

// 使用net_packet生成真实报文，不随机化描述符；观察对象保持原始完整checksum作为比对基准。
function packet_item virtio_tx_offload_test::make_random_packet();
    packet_template_e	kinds[8] = '{ETH_IPV4_TCP, ETH_IPV4_UDP, ETH_IPV6_TCP, ETH_IPV6_UDP,
        ETH_VLAN_IPV4_TCP, ETH_VLAN_IPV4_UDP, ETH_VLAN_IPV6_TCP, ETH_VLAN_IPV6_UDP};
    packet_item		item;
    packet_template_e	kind;
    ipv4_header		ip4;
    ipv6_header		ip6;
    tcp_header		tcp;
    int unsigned	length;
    int unsigned	length_class;

    kind = kinds[$urandom_range(0, 7)];
    random_kind_counts[kind]++;
    // 主要覆盖常用小包，保留中包与jumbo随机样本，避免运行时间全部消耗在大payload上。
    length_class = $urandom_range(0, 99);
    if (length_class < 90) length = $urandom_range(256, 768);
    else if (length_class < 99) length = $urandom_range(769, 2048);
    else length = $urandom_range(2049, 9216);
    if (length > 2048) random_jumbo++;
    item = make_packet(kind, length);
    item.pkt.payload_mode = PAYLOAD_RANDOM;
    ip4 = item.pkt.get_ipv4();
    ip6 = item.pkt.get_ipv6();
    if (ip4 != null) begin
        ip4.src_addr = $urandom;
        ip4.dst_addr = $urandom;
        ip4.opt_rr_en = $urandom_range(0, 1);
        ip4.opt_rr_slots = $urandom_range(1, 3);
        if (ip4.opt_rr_en) random_ip_options++;
    end else begin
        ip6.src_addr = {$urandom, $urandom, $urandom, $urandom};
        ip6.dst_addr = {$urandom, $urandom, $urandom, $urandom};
    end
    tcp = item.pkt.get_tcp();
    if (tcp != null) begin
        tcp.opt_ts_en = $urandom_range(0, 1);
        tcp.opt_ts_val = $urandom;
        tcp.opt_ts_ecr = $urandom;
        if (tcp.opt_ts_en) random_tcp_options++;
    end
    item.pkt.do_pack();
    return item;
endfunction

// 头长从协议线上字段直接解码，期望seed自行折叠；逐字节确认offload只改L4 checksum字段。
function void virtio_tx_offload_test::check_published_packet(
    virtqueue_base	vq, int unsigned	head, packet_item	item, virtio_tx_offload_t	request
);
    byte unsigned	wire_bytes[$];
    byte		data[];
    byte		header_bytes[];
    byte		expected_header[12];
    int unsigned	l2_len;
    int unsigned	ip_len;
    int unsigned	l4_start;
    int unsigned	l4_len;
    int unsigned	l4_bytes;
    int unsigned	csum_offset;
    int unsigned	address_start;
    int unsigned	address_end;
    int unsigned	sum;
    int unsigned	data_slot;
    int unsigned	header_len;
    bit			is_ip4;
    bit			is_tcp;
    bit			csum;
    bit			segmented;
    bit [63:0]		data_addr;
    bit [31:0]		data_word1;
    bit [31:0]		data_word2;
    bit [63:0]		extension;
    bit [31:0]		ext_word1;
    bit [31:0]		ext_word2;

    wire_bytes = item.pkt.raw_data;
    l2_len = ({wire_bytes[12], wire_bytes[13]} == 16'h8100) ? 18 : 14;
    is_ip4 = wire_bytes[l2_len][7:4] == 4;
    ip_len = is_ip4 ? int'(wire_bytes[l2_len][3:0]) * 4 : 40;
    is_tcp = wire_bytes[l2_len + (is_ip4 ? 9 : 6)] == 6;
    l4_start = l2_len + ip_len;
    l4_len = is_tcp ? int'(wire_bytes[l4_start + 12][7:4]) * 4 : 8;
    l4_bytes = is_ip4 ? int'({wire_bytes[l2_len+2], wire_bytes[l2_len+3]}) - ip_len :
        int'({wire_bytes[l2_len+4], wire_bytes[l2_len+5]});
    csum_offset = is_tcp ? 16 : 6;
    csum = request.csum || request.gso;
    segmented = request.gso && (l4_bytes - l4_len > request.mss);
    header_len = l4_start + l4_len;

    sum = l4_bytes + (is_tcp ? 6 : 17);
    address_start = l2_len + (is_ip4 ? 12 : 8);
    address_end = address_start + (is_ip4 ? 8 : 32);
    for (int unsigned i = address_start; i < address_end; i += 2)
        sum += int'({wire_bytes[i], wire_bytes[i+1]});
    while (sum >> 16) sum = (sum & 16'hffff) + (sum >> 16);

    data_slot = head;
    if (vq.descriptor_format() == VQ_PACKED || segmented)
        data_slot = (head + 1) % vq.queue_size;
    data_addr = read_le(vq.desc_table_addr + data_slot*16, 8);
    data_word1 = read_le(vq.desc_table_addr + data_slot*16 + 8, 4);
    data_word2 = read_le(vq.desc_table_addr + data_slot*16 + 12, 4);
    require_true((data_word1 & 32'h3ffff) == wire_bytes.size(), "random DMA descriptor length");
    read_dma(data_addr, wire_bytes.size(), data);
    foreach (data[i]) begin
        byte	expected_byte;

        expected_byte = wire_bytes[i];
        if (csum && i == l4_start + csum_offset)
            expected_byte = byte'(sum >> 8);
        else if (csum && i == l4_start + csum_offset + 1)
            expected_byte = byte'(sum);
        if (data[i] !== expected_byte)
            require_true(0, $sformatf("random DMA mismatch at byte %0d: actual=%02h expected=%02h",
                i, data[i], expected_byte));
    end

    if (vq.descriptor_format() == VQ_PACKED) begin
        read_dma(read_le(vq.desc_table_addr + head*16, 8), 12, header_bytes);
        foreach (expected_header[i]) expected_header[i] = 0;
        if (csum) begin
            expected_header[0] = 1;
            expected_header[6] = l4_start;
            expected_header[7] = l4_start >> 8;
            expected_header[8] = csum_offset;
        end
        if (segmented) begin
            expected_header[1] = is_tcp ? (is_ip4 ? 1 : 4) : 5;
            expected_header[2] = header_len;
            expected_header[3] = header_len >> 8;
            expected_header[4] = request.mss;
            expected_header[5] = request.mss >> 8;
        end
        foreach (expected_header[i])
            require_true(header_bytes[i] == expected_header[i], "random virtio_net_hdr byte mismatch");
    end else if (driver_dump != 0) begin
        extension = 0;
        ext_word1 = 0;
        ext_word2 = 0;
        if (segmented) begin
            extension = read_le(vq.desc_table_addr + head*16, 8);
            ext_word1 = read_le(vq.desc_table_addr + head*16 + 8, 4);
            ext_word2 = read_le(vq.desc_table_addr + head*16 + 12, 4);
        end
        $fdisplay(driver_dump, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %08h %08h %016h %08h %08h",
            csum, segmented, is_ip4, is_tcp, l2_len, ip_len, l4_len, request.mss,
            wire_bytes.size(), ext_word2[23], data_word2[23], data_word1, data_word2,
            extension, ext_word1, ext_word2);
    end
endfunction

function bit [63:0] virtio_tx_offload_test::read_le(bit [63:0] address, int unsigned count);
    byte	data[];
    bit [63:0]	value;

    kit.mem.read_mem(address, count, data);
    value = 0;
    foreach (data[i]) value[i*8 +: 8] = data[i];
    return value;
endfunction

function void virtio_tx_offload_test::read_dma(bit [63:0] address, int unsigned count, output byte data[]);
    bit [63:0]		gpa;
    iommu_fault_e	fault;

    require_true(iommu.translate_for_host(0, 16'h1, address, count,
        DMA_TO_DEVICE, gpa, fault), "DMA translation");
    kit.mem.read_mem(gpa, count, data);
endfunction

function void virtio_tx_offload_test::check_headers();
    packet_item			item;
    virtio_tx_offload_t		request;
    virtio_net_hdr_t		hdr;
    vio_private_tx_offload_t	control;
    byte unsigned		data[$];
    string			why;
    ipv4_header			ip4;
    virtio_net_env_config	cfg;
    dpu_service_key_t		key;
    vio_service_requirement_t	requirement;
    packet_template_e		kinds[4] = '{ETH_IPV4_TCP, ETH_IPV4_UDP, ETH_IPV6_TCP, ETH_IPV6_UDP};

    cfg = new("capabilities");
    cfg.external_configuration = 1;
    cfg.default_vq_type = VQ_PACKED;
    cfg.default_driver_features = features & ~64'h1;
    key.function_key = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
    key.service_kind = DPU_SERVICE_VIO_NET;
    key.service_instance_id = 0;
    require_true(!cfg.resolve_final_service_requirement(key, requirement, why),
        "external GSO capabilities require CSUM");
    cfg.default_driver_features = features;
    require_true(cfg.resolve_final_service_requirement(key, requirement, why) &&
        requirement.behavior.driver_features == features, "external Packed accepts TX capabilities");

    request = '{valid:1, csum:1, gso:1, mss:128};
    foreach (kinds[i]) begin
        item = make_packet(kinds[i], 512);
        data = item.pkt.raw_data;
        require_true(virtio_net_packet_adapter::prepare_tx(data, request, 0,
            features, hdr, control, why), why);
        require_true(hdr.flags == 1 && hdr.csum_start == ((i < 2) ? 34 : 54) &&
            hdr.csum_offset == ((i % 2 == 0) ? 16 : 6), "protocol-specific checksum fields");
        require_true(hdr.gso_type == ((i % 2) ? VIRTIO_NET_HDR_GSO_UDP_L4 :
            ((i == 0) ? VIRTIO_NET_HDR_GSO_TCPV4 : VIRTIO_NET_HDR_GSO_TCPV6)) &&
            hdr.gso_size == 128 && hdr.hdr_len == hdr.csum_start + ((i % 2) ? 8 : 20),
            "protocol-specific GSO header");
        if (i == 0)
            require_true({data[50], data[51]} == 16'h15e7, "IPv4 TCP partial checksum golden seed");
    end

    item = make_packet(ETH_VLAN_IPV4_TCP, 512);
    ip4 = item.pkt.get_ipv4();
    ip4.opt_rr_en = 1;
    ip4.opt_rr_slots = 1;
    item.pkt.do_pack();
    data = item.pkt.raw_data;
    require_true(virtio_net_packet_adapter::prepare_tx(data, request, 0,
        features, hdr, control, why), why);
    require_true(hdr.csum_start == 18 + ip4.get_header_length() &&
        hdr.csum_start > 38 && hdr.hdr_len == hdr.csum_start + 20,
        "VLAN and IPv4 options use parsed lengths");

    item = make_packet(ETH_IPV4_TCP, 512);
    data = item.pkt.raw_data;
    require_true(!virtio_net_packet_adapter::prepare_tx(data, request, 0,
        64'h500000000, hdr, control, why), "missing Function CSUM must reject");
    require_true(data == item.pkt.raw_data, "failed preparation preserves packet bytes");

    request.mss = 1460;
    require_true(virtio_net_packet_adapter::prepare_tx(data, request, 0,
        features, hdr, control, why), why);
    require_true(hdr.gso_type == 0 && hdr.flags == 1, "small packet only needs checksum");

    data = item.pkt.raw_data;
    request.mss = 128;
    require_true(virtio_net_packet_adapter::prepare_tx(data, request, 1,
        0, hdr, control, why), why);
    require_true(control.extension == 64'h020254a7 && control.tso && control.l3_cs &&
        control.l4_cs, "driver Custom TSO lower64 golden word");

    request.csum = 0;
    request.gso = 0;
    data = item.pkt.raw_data;
    require_true(virtio_net_packet_adapter::prepare_tx(data, request, 0,
        features, hdr, control, why), why);
    require_true(hdr.flags == 0 && hdr.gso_type == 0 && data == item.pkt.raw_data,
        "explicit off preserves full packet and zero header");
endfunction

task virtio_tx_offload_test::check_params();
    virtio_tx_param_probe	probe;
    virtio_tx_offload_t		first;
    virtio_tx_offload_t		second;
    string			result;
    int				status;

    probe = new();
    aip_cmd::exec_result("set_param path=vio.tx.csum value=1", SRC_INTERNAL, status, result);
    require_true(status == 0, result);
    aip_cmd::exec_result("set_param path=vio.tx.gso value=1", SRC_INTERNAL, status, result);
    require_true(status == 0, result);
    aip_cmd::exec_result("set_param path=vio.tx.mss value=inc:128:256:128", SRC_INTERNAL, status, result);
    require_true(status == 0, result);
    probe.sample(first);
    probe.sample(second);
    // AIP标量inc表示按步长构造的候选集合，每次独立抽样，不保证递增顺序。
    require_true(first.valid && first.csum && first.gso && first.mss inside {128, 256} &&
        second.mss inside {128, 256}, "AIP expression sampled per packet");

    aip_cmd::exec_result("set_param path=vio.tx.csum value=0", SRC_INTERNAL, status, result);
    require_true(status == 0, result);
    aip_cmd::exec_result("set_param path=vio.tx.gso value=0", SRC_INTERNAL, status, result);
    require_true(status == 0, result);
    aip_cmd::exec_result("set_param path=vio.tx.mss value=512", SRC_INTERNAL, status, result);
    require_true(status == 0, result);
    probe.sample(second);
    require_true(!second.csum && !second.gso && second.mss == 512 &&
        first.csum && first.gso && first.mss inside {128, 256},
        "runtime change does not rewrite an earlier request");

    probe.path = "vio.tx_other";
    probe.sample(second);
    require_true(!second.valid && !second.csum && !second.gso, "independent command path");
    aip_cmdline_override::clear("vio.tx.csum");
    aip_cmdline_override::clear("vio.tx.gso");
    aip_cmdline_override::clear("vio.tx.mss");
endtask

task virtio_tx_offload_test::check_rings();
    packed_virtqueue	packed_vq;
    custom_virtqueue	private_vq;
    packet_item		item;
    virtio_net_hdr_t	hdr;
    virtio_tx_offload_t	request;
    uvm_object		completed[$];
    byte		bytes[];
    byte		cq[2];
    int unsigned	head;
    bit [63:0]		address;
    bit [31:0]		word2;

    packed_vq = kit.add_packed(1, 8);
    require_true($cast(private_vq, kit.vq_mgr.create_queue(3, 4, VQ_CUSTOM)), "create Custom queue");
    private_vq.local_qid = 3;
    private_vq.alloc_rings();
    item = make_packet(ETH_IPV4_TCP, 512);
    hdr = '{default:0};
    request = '{valid:1, csum:1, gso:1, mss:128};

    ops.negotiated_features = features;
    ops.tx_submit(1, hdr, item, 0, head, request);
    require_true(head == 0 && packed_vq.get_free_count() == 6, "Packed uses two descriptors");
    require_true(read_le(packed_vq.desc_table_addr + 8, 4) == 12 &&
        read_le(packed_vq.desc_table_addr + 24, 4) == 512, "Packed descriptor lengths");
    address = read_le(packed_vq.desc_table_addr, 8);
    read_dma(address, 12, bytes);
    require_true({bytes[3], bytes[2], bytes[1], bytes[0]} == 32'h00360101 &&
        {bytes[7], bytes[6], bytes[5], bytes[4]} == 32'h00220080 &&
        {bytes[11], bytes[10], bytes[9], bytes[8]} == 32'h00000010, "Packed header golden DWORDs");
    address = read_le(packed_vq.desc_table_addr + 16, 8);
    read_dma(address, 512, bytes);
    require_true({bytes[50], bytes[51]} == 16'h15e7, "actual DMA contains partial seed");
    foreach (bytes[i])
        if (!(i inside {50, 51}))
            require_true(bytes[i] == item.pkt.raw_data[i], "DMA payload remains bound to original packet");
    virtio_vq_test_kit::complete_packed(kit.mem, packed_vq, head);
    ops.tx_complete(1, completed, 1);
    require_true(completed.size() == 1 && completed[0] == item &&
        packed_vq.get_free_count() == 8, "Packed completion reclaims header and packet");

    ops.negotiated_features = 0;
    // 显式请求覆盖队列默认；关→开checksum→关都只占一个data槽，不串到下一包。
    // 三包完成后，下一包的扩展项位于最后一槽，数据跨到槽0。
    private_vq.l3_cs = 1;
    private_vq.l4_cs = 1;
    private_vq.i_l3_cs = 1;
    private_vq.i_l4_cs = 1;
    request.gso = 0;
    for (int n = 0; n < 3; n++) begin
        request.csum = (n == 1);
        ops.tx_submit(3, hdr, item, 0, head, request);
        require_true(head == n && private_vq.get_free_count() == 2,
            "Custom checksum-only packet uses one data descriptor");
        word2 = read_le(private_vq.desc_table_addr + head*16 + 12, 4);
        require_true({word2[25:24], word2[18:17]} == (request.csum ? 4'hf : 0) &&
            !word2[15] && private_vq.l3_cs && private_vq.l4_cs &&
            private_vq.i_l3_cs && private_vq.i_l4_cs,
            "per-packet controls override without changing queue defaults");
        address = read_le(private_vq.desc_table_addr + head*16, 8);
        read_dma(address, 512, bytes);
        require_true({bytes[50], bytes[51]} == (request.csum ? 16'h15e7 :
            {item.pkt.raw_data[50], item.pkt.raw_data[51]}), "Custom checksum DMA seed or full checksum");
        cq[0] = private_vq.producer_index;
        cq[1] = private_vq.producer_wrap ? 8'h80 : 0;
        kit.mem.write_mem(private_vq.cq_addr, cq);
        completed.delete();
        ops.tx_complete(3, completed, 1);
        require_true(completed.size() == 1, "ordinary Custom completion");
    end

    request.gso = 1;
    request.csum = 1;
    ops.tx_submit(3, hdr, item, 0, head, request);
    require_true(head == 3 && private_vq.producer_index == 1 && !private_vq.producer_wrap &&
        private_vq.get_free_count() == 1, "Custom extension participates in wrap and free count");
    require_true(read_le(private_vq.desc_table_addr + 48, 8) == 64'h020254a7 &&
        read_le(private_vq.desc_table_addr + 60, 4) == 32'h038f8000,
        "Custom extension golden words");
    word2 = read_le(private_vq.desc_table_addr + 12, 4);
    require_true(word2 == 32'h80080000 && private_vq.last_notify_word == 32'h00010003,
        "Custom GSO data keeps routing, clears checksum controls and includes extension in notify");

    // 只有扩展项越过CQ时不可回收包；数据项完成后只回收一个packet DMA。
    cq = '{0, 0};
    kit.mem.write_mem(private_vq.cq_addr, cq);
    completed.delete();
    ops.tx_complete(3, completed, 1);
    require_true(completed.size() == 0, "partial extension completion must retain packet");
    cq[0] = 1;
    kit.mem.write_mem(private_vq.cq_addr, cq);
    ops.tx_complete(3, completed, 1);
    require_true(completed.size() == 1 && completed[0] == item &&
        private_vq.get_free_count() == 3, "Custom full completion reclaims both slots");
    kit.vq_mgr.destroy_all();
endtask

// 设备替身仅在看到DB后延迟30ns写完成；发送者自己等待/回收，不能靠预填CQ通过。
// 每包等待预算100ns，整条1000包命令超过100ns也应成功；最后尾批必须被设备看到。
task virtio_tx_offload_test::check_capacity();
    virtqueue_base		vq;
    custom_virtqueue		private_vq;
    virtio_tx_full_catcher	catcher;
    virtio_tx_offload_t	request;
    virtio_net_hdr_t		hdr;
    packet_item			item;
    uvm_object			completed[$];
    int unsigned		qid;
    int unsigned		slots;
    int unsigned		capacity;
    int unsigned		head;
    int unsigned		batch_size;
    int unsigned		kick_start;
    int unsigned		kicks_seen;
    int unsigned		notified_packets;
    int unsigned		consumed_packets;
    int unsigned		tail;
    int unsigned		maps_before;
    bit				wrap;
    bit [15:0]			flags;
    byte				completion[2];
    byte				ring_before[];
    byte				ring_after[];
    realtime			started;
    bit				random_packets;
    int unsigned		depth = 128;
    int unsigned		packet_count = 1000;
    int unsigned		in_batch;
    bit				notify;

    catcher = new();
    hdr = '{default:0};
    random_packets = $test$plusargs("TX_RANDOM");
    void'($value$plusargs("TX_DEPTH=%d", depth));
    void'($value$plusargs("TX_PACKETS=%d", packet_count));
    require_true(depth inside {8, 16, 32, 128, 256} && packet_count >= 1000,
        "TX_DEPTH must be 8/16/32/128/256 and TX_PACKETS must be at least 1000");

    for (int mode = 0; mode < 3; mode++) begin
        // 固定32/超ring的大批量/每批随机三种策略共用一个生产和消费过程。
        for (int batch_mode = 0; batch_mode < (random_packets ? 3 : 2); batch_mode++) begin
            qid = 2*mode + 1;
            slots = (mode == 1) ? 1 : 2;
            capacity = ((mode == 0) ? depth : depth - 1) / slots;
            batch_size = (batch_mode == 0) ? 32 : packet_count;
            if (batch_mode == 2) batch_size = $urandom_range(2, 2*depth);
            in_batch = 0;
            private_vq = null;
            request = '{valid:1, csum:1, gso:(mode != 1), mss:128};
            ops.negotiated_features = (mode == 0) ? features : 0;

            if (mode == 0)
                vq = kit.add_packed(qid, depth);
            else begin
                require_true($cast(private_vq, kit.vq_mgr.create_queue(qid, depth, VQ_CUSTOM)),
                    "create capacity Custom queue");
                private_vq.local_qid = qid;
                private_vq.alloc_rings();
                vq = private_vq;
            end

            kick_start = transport.kick_count;
            kicks_seen = kick_start;
            consumed_packets = 0;
            started = $realtime;
            fork : send_and_consume
                begin : sender
                    for (int n = 0; n < packet_count; n++) begin
                        item = random_packets ? make_random_packet() : make_packet(ETH_IPV4_TCP, 512);
                        if (random_packets) begin
                            request.csum = $urandom_range(0, 1);
                            request.gso = (mode == 0) ? $urandom_range(0, 1) : (mode == 2);
                            request.mss = $urandom_range(32, 128);
                        end
                        in_batch++;
                        notify = in_batch == batch_size || n == packet_count - 1;
                        ops.tx_submit(qid, hdr, item, 0, head, request, 100,
                            notify);
                        require_true(head == ((n * slots) % depth),
                            "full ring must wait and then submit exactly the pending packet");
                        if (random_packets) check_published_packet(vq, head, item, request);
                        if (notify) begin
                            in_batch = 0;
                            if (batch_mode == 2) batch_size = $urandom_range(2, 2*depth);
                        end
                    end
                end
                begin : device
                    while (consumed_packets < packet_count) begin
                        wait (transport.kick_count > kicks_seen);
                        kicks_seen = transport.kick_count;
                        notified_packets = vq.total_add_buf_ops;
                        tail = (notified_packets * slots) % depth;
                        wrap = !(((notified_packets * slots) / depth) % 2);
                        require_true(transport.last_kick_queue_id == qid &&
                            transport.last_kick_next_avail_idx == tail &&
                            transport.last_kick_wrap_counter == wrap,
                            "batch DB must carry actual descriptor tail and wrap");
                        if (private_vq != null)
                            require_true(private_vq.last_notify_word == {wrap, tail[14:0], qid[15:0]},
                                "Custom notification word includes all data and extension slots");

                        if (random_packets) #($urandom_range(30, 45) * 1ns);
                        else #30ns;
                        if (mode == 0) begin
                            for (int n = consumed_packets; n < notified_packets; n++) begin
                                flags = read_le(vq.desc_table_addr + ((n * slots) % depth)*16 + 14, 2);
                                flags[15] = flags[7];
                                completion = '{flags[7:0], flags[15:8]};
                                kit.mem.write_mem(vq.desc_table_addr + ((n * slots) % depth)*16 + 14,
                                    completion);
                            end
                        end else begin
                            completion = '{tail[7:0], {wrap, tail[14:8]}};
                            kit.mem.write_mem(private_vq.cq_addr, completion);
                        end
                        consumed_packets = notified_packets;
                    end
                end
            join

            completed.delete();
            ops.tx_complete(qid, completed, depth);
            require_true(vq.total_add_buf_ops == packet_count && vq.total_poll_used_ops == packet_count &&
                vq.get_free_count() == ((mode == 0) ? depth : depth - 1) &&
                iommu.total_maps == iommu.total_unmaps,
                "every packet must complete and release its DMA allocation");
            require_true($realtime - started > 100ns &&
                transport.kick_count - kick_start < packet_count,
                "timeout is per blocked packet and DB count is reduced by batching");
            `uvm_info("TX_CAPACITY_PASS", $sformatf(
                "mode=%0d depth=%0d packets=%0d batch_mode=%0d random=%0b DBs=%0d elapsed=%0t",
                mode, depth, packet_count, batch_mode, random_packets,
                transport.kick_count - kick_start, $realtime - started), UVM_NONE)

            // 无设备消费时精确等待25ns；不增加DMA、不覆盖旧描述符、不重复通知。
            for (int n = 0; n < capacity; n++)
                ops.tx_submit(qid, hdr, item, 0, head, request, 100, 0);
            ops.flush_tx(qid);
            kit.mem.read_mem(vq.desc_table_addr, depth*16, ring_before);
            kick_start = transport.kick_count;
            maps_before = iommu.total_maps;
            catcher.expected_id = "VIO_TX_TIMEOUT";
            catcher.expected_message = $sformatf(
                "queue %0d waited 25 ns for %0d descriptors; free=%0d",
                qid, slots, vq.get_free_count());
            catcher.caught_count = 0;
            started = $realtime;
            uvm_report_cb::add(null, catcher);
            ops.tx_submit(qid, hdr, item, 0, head, request, 25);
            uvm_report_cb::delete(null, catcher);
            kit.mem.read_mem(vq.desc_table_addr, depth*16, ring_after);
            require_true(catcher.caught_count == 1 && head == '1 &&
                $realtime - started == 25ns && iommu.total_maps == maps_before &&
                transport.kick_count == kick_start && ring_before == ring_after,
                "stalled TX must timeout once without changing pending data or DB");

            // 完成剩余包后清理本轮；不能用destroy掩盖超时路径的所有权泄漏。
            tail = ((packet_count + capacity) * slots) % depth;
            wrap = !((((packet_count + capacity) * slots) / depth) % 2);
            if (mode == 0) begin
                for (int n = packet_count; n < packet_count + capacity; n++) begin
                    flags = read_le(vq.desc_table_addr + ((n * slots) % depth)*16 + 14, 2);
                    flags[15] = flags[7];
                    completion = '{flags[7:0], flags[15:8]};
                    kit.mem.write_mem(vq.desc_table_addr + ((n * slots) % depth)*16 + 14, completion);
                end
            end else begin
                completion = '{tail[7:0], {wrap, tail[14:8]}};
                kit.mem.write_mem(private_vq.cq_addr, completion);
            end
            completed.delete();
            ops.tx_complete(qid, completed, depth);
            require_true(completed.size() == capacity && iommu.total_maps == iommu.total_unmaps,
                "timeout retains prior DMA until completion, then releases all ownership");
            kit.vq_mgr.destroy_all();
        end
    end
    if (random_packets) begin
        require_true(random_kind_counts.num() == 8, "random run did not cover all eight packet templates");
        require_true(random_ip_options != 0 && random_tcp_options != 0 && random_jumbo != 0,
            "random run missed options or jumbo coverage");
        `uvm_info("TX_RANDOM_COVERAGE", $sformatf("IPv4_options=%0d TCP_options=%0d jumbo=%0d",
            random_ip_options, random_tcp_options, random_jumbo), UVM_NONE)
        foreach (random_kind_counts[kind])
            `uvm_info("TX_RANDOM_COVERAGE", $sformatf("%s packets=%0d",
                kind.name(), random_kind_counts[kind]), UVM_NONE)
    end
endtask

task virtio_tx_offload_test::run_phase(uvm_phase phase);
    string	dump_path;

    phase.raise_objection(this);
    if ($value$plusargs("TX_DRIVER_DUMP=%s", dump_path)) begin
        driver_dump = $fopen(dump_path, "w");
        require_true(driver_dump != 0, "cannot open TX_DRIVER_DUMP");
    end
    features = 64'h0100000500001801;
    fixture = new("memory");
    require_true(fixture.create_host(0, 64'h100000000, 64'h100ffffff), "Host memory allocation");
    iommu = new("iommu");
    kit = virtio_vq_test_kit::create_kit("offload", fixture.get_host(0), iommu, 16'h1);
    transport = new("transport");
    transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h1));
    ops = kit.make_ops(transport, "ops");

    check_headers();
    check_params();
    check_rings();
    check_capacity();
    if (driver_dump != 0) $fclose(driver_dump);
    fixture.leak_check();
    `uvm_info("TX_OFFLOAD_PASS", "per-packet AIP, Packed DMA, Custom TSO/wrap/reclaim passed", UVM_NONE)
    phase.drop_objection(this);
endtask
