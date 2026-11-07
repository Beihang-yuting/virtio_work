// tests：外部协议合同测试；黄金字节由测试独立给定，Host 内存由 fixture 持有。
// 不连接设备模型，准备/确认阶段不得依赖配置寄存器响应。
import uvm_pkg::*;
import dpu_resource_pkg::*;
import virtio_net_pkg::*;
import pcie_tl_pkg::*;
import net_packet_pkg::*;
`include "uvm_macros.svh"

class virtio_external_configuration_test extends uvm_test;
	`uvm_component_utils(virtio_external_configuration_test)

	// 仅构造测试组件；资源在 run_phase 内建立和释放。
	extern function new(string name, uvm_component parent);

	// 统一断言，不覆盖 UVM component.check。
	extern function void require_true(bit condition, string message);

	// 先锁定 pre-placement 精确需求及当前驱动 CQ 数据格式。
	extern virtual task run_phase(uvm_phase phase);
endclass

function virtio_external_configuration_test::new(string name, uvm_component parent);
	super.new(name, parent);
endfunction

function void virtio_external_configuration_test::require_true(bit condition, string message);
	if (!condition) `uvm_fatal("EXTERNAL_CONTRACT", message)
endfunction

task virtio_external_configuration_test::run_phase(uvm_phase phase);
	virtio_net_env_config	cfg;
	vio_service_requirement_t	requirement;
	dpu_service_key_t	key;
	string	why;
	virtio_shared_mem_fixture	fixture;
	virtio_vq_test_kit	kit;
	virtio_iommu_model	iommu;
	custom_virtqueue	rx;
	dpu_priv_rx_cq_t	cq;
	byte	golden[16] = '{8'had,8'hb5,8'h4e,8'hd3,8'hc7,8'h12,8'h00,8'hc2,
		8'hbc,8'ha5,8'h34,8'h12,8'h78,8'h56,8'hbc,8'h0a};

	phase.raise_objection(this);
	cfg = new("external_cfg");
	cfg.external_configuration = 1;
	cfg.default_num_pairs = 33;
	key.function_key = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_VF, vf_id:0};
	key.service_kind = DPU_SERVICE_VIO_NET;
	key.service_instance_id = 0;
	require_true(!cfg.resolve_final_service_requirement(key, requirement, why),
		"over-capacity service must reject instead of clamping");
	cfg = new("valid_cfg");
	cfg.external_configuration = 1;
	cfg.default_num_pairs = 2;
	cfg.default_vq_type = VQ_PACKED;
	cfg.default_queue_size = 16;
	require_true(cfg.resolve_final_service_requirement(key, requirement, why), why);
	require_true(requirement.behavior.num_queue_pairs == 2, "exact pair requirement");

	fixture = new("memory");
	require_true(fixture.create_host(0, 64'h100000000, 64'h100ffffff), "host memory");
	iommu = new("iommu");
	kit = virtio_vq_test_kit::create_kit("cq", fixture.get_host(0), iommu, 16'h11);
	rx = new("rx");
	rx.setup(0, 16, kit.mem, iommu, kit.barrier, kit.err_inj, kit.wait_pol, 16'h11, 0);
	rx.tx_mode = 0;
	rx.alloc_rings();
	kit.mem.write_mem(rx.cq_addr, golden);
	require_true(rx.query_rx_cq(0, cq), "typed RX CQ query");
	require_true(($bits(cq) == 128) && (cq.desc_num == 13) &&
		(cq.sport_type == 5) && (cq.sport_id == 10'h2b5) && cq.offload_vlan_vld &&
            (cq.vlan_tpid_type == 2) && (cq.ptype == 8'h4e) && (cq.profile == 3) &&
            (cq.csum_check_status == 3) && (cq.pkt_num == 7) && (cq.pkt_head_split_len == 8'h12) &&
		(cq.pkt_len == 512) && cq.cq_wrapper && cq.tnl_pkt_flag &&
		(cq.hash_value == 16'h1234) && (cq.timestamp_index == 12'h5bc) &&
		(cq.offload_ovlan == 16'h5678) && (cq.vsid == 12'habc), "independent CQ golden bytes");
	rx.free_rings();
	fixture.leak_check();
	`uvm_info("EXTERNAL_CONTRACT_PASS", "external requirement and current CQ contracts passed", UVM_NONE)
	phase.drop_objection(this);
endtask


// 无设备 spy：记录全部访问，普通写只允许已确认后的队列通知。
class vio_external_spy_bar extends virtio_bar_accessor;
    `uvm_object_utils(vio_external_spy_bar)
    int unsigned	config_accesses;
    int unsigned	mmio_reads;
    int unsigned	mmio_writes;
    bit [31:0]	last_word;
    virtio_pcie_observer_adapter	observer;

    // 仅创建计数器，BAR 租约沿用真实 Function 的冻结值。
    extern function new(string name = "external_spy");

    // 配置读记录为不允许的访问，不伪造 capability。
    extern virtual task config_read(bit [11:0] addr, ref bit [31:0] data);

    // 配置写记录为不允许的访问。
    extern virtual task config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);

    // MMIO 读记录为不允许的访问。
    extern virtual task read_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, ref bit [31:0] data);

    // MMIO 写只统计和保存数据，不驱动任何设备完成。
    extern virtual task write_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, bit [31:0] data);

    // MSI-X 表不可由外部 VIO 写，使用同一计数器抓取误调用。
    extern virtual task write_msix_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, bit [31:0] data);

    // MSI-X mask 的读也属于禁止的自动配置访问。
    extern virtual task read_msix_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, ref bit [31:0] data);
endclass

function vio_external_spy_bar::new(string name = "external_spy");
    super.new(name);
endfunction

task vio_external_spy_bar::config_read(bit [11:0] addr, ref bit [31:0] data);
    config_accesses++;
    data = 0;
endtask

task vio_external_spy_bar::config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
    config_accesses++;
endtask

task vio_external_spy_bar::read_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, ref bit [31:0] data);
    mmio_reads++;
    data = 0;
endtask

task vio_external_spy_bar::write_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, bit [31:0] data);
    pcie_tl_mem_tlp	notification;

    mmio_writes++;
    last_word = data;
    if (observer != null) begin
        notification = new("observed_notify");
        notification.kind = TLP_MEM_WR;
        notification.addr = (bar_base[bar_id] + offset) & ~64'h3;
        notification.length = 1;
        notification.first_be = ((size == 2) ? 4'h3 : 4'hf) << offset[1:0];
        notification.last_be = 0;
        notification.payload = new[4];
        // PCIe payload 保持 DWORD 对齐，16bit offset+2 使用高两条 byte lane。
        for (int unsigned i = 0; i < size; i++)
            notification.payload[i + offset[1:0]] = data[i*8 +: 8];
        observer.write(notification);
    end
endtask

task vio_external_spy_bar::write_msix_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, bit [31:0] data);
    config_accesses++;
endtask

task vio_external_spy_bar::read_msix_reg(int unsigned bar_id, bit [31:0] offset,
        int unsigned size, ref bit [31:0] data);
    config_accesses++;
    data = 0;
endtask


// 真实 DPU snapshot→env→Function→ops/FSM 合同测试；只由测试显式注入 DMA 完成。
// +EXTERNAL_CUSTOM/+EXTERNAL_MSIX 选择四种组合，所有场景均发送512B且保留非identity DMA。
class virtio_external_lifecycle_test extends uvm_test;
    `uvm_component_utils(virtio_external_lifecycle_test)
    virtio_net_env	env;
    virtio_net_env_config	cfg;
    dpu_device_env	device_env;
    dpu_service_key_t	service_key;
    uvm_sequencer #(pcie_tl_tlp)	rc_seqr;
    bit	custom_mode;
    bit	msix_mode;
    bit	tx_only;

    // 只构造测试组件。
    extern function new(string name, uvm_component parent);

    // 断言失败立即终止，不吞生产日志。
    extern function void require_true(bit condition, string message);

    // 建立真实冻结拓扑；AF 与业务 VF 分离，避免测试假定 global qpair==local qid。
    extern virtual function void build_phase(uvm_phase phase);

    // 从真实小端 descriptor 读出 DMA 地址，避免测试绕过映射直接写 payload GPA。
    extern function bit [63:0] descriptor_address(input bit [63:0] descriptor_gpa);

    // 当前 CQ 和 Packed USED 的完成通过 IOMMU 设备写入口注入，不直接调用完成 API。
    extern function void dma_write(input virtio_function_instance instance,
        input bit [63:0] iova, input byte bytes[]);

    // observer 接收真实 Memory Write TLP，消息地址故意选 APIC 范围外，data 不编码向量。
    extern function void deliver_msix(input virtio_function_instance instance,
        input vio_external_queue_binding_t binding, input bit wrong = 0);

    // 覆盖未知值、未确认提交、伪造/旧代 scope、quiescence、512B 收发和共享中断。
    extern virtual task run_phase(uvm_phase phase);
endclass

function virtio_external_lifecycle_test::new(string name, uvm_component parent);
    super.new(name, parent);
endfunction

function void virtio_external_lifecycle_test::require_true(bit condition, string message);
    if (!condition) `uvm_fatal("EXTERNAL_LIFECYCLE", message)
endfunction

function void virtio_external_lifecycle_test::build_phase(uvm_phase phase);
    virtio_test_device_builder	builder;
    dpu_function_cfg	pf;
    dpu_function_cfg	vf;
    dpu_function_key_t	owners[$];
    dpu_device_env_config	device_cfg;
    vio_service_requirement_t	requirement;
    string	why;

    super.build_phase(phase);
    custom_mode = $test$plusargs("EXTERNAL_CUSTOM");
    msix_mode = $test$plusargs("EXTERNAL_MSIX");
    builder = new("builder");
    void'(builder.add_host_domain(0, 0));
    pf = builder.add_pf(0, 0, 0);
    vf = builder.add_vf(0, 0, 0, 0);
    builder.add_real_dut_bars(pf);
    builder.add_real_dut_bars(vf);
    builder.select_af(pf);
    service_key = builder.allow_vio_service(vf);
    owners.push_back(vf.key);
    void'(builder.add_fixed_vio_request(0, owners, 1));
    device_cfg = builder.make_env_config();
    cfg = new("cfg");
    cfg.external_configuration = 1;
    cfg.execution_mode = VIRTIO_EXEC_REAL_DUT;
    cfg.completion_mode = msix_mode ? VIRTIO_COMPLETION_MSIX : VIRTIO_COMPLETION_POLLING;
    cfg.default_vq_type = custom_mode ? VQ_CUSTOM : VQ_PACKED;
    cfg.default_queue_size = 16;
    cfg.rx_enable = !tx_only;
    cfg.iova_base = 64'h80000000;
    cfg.iova_limit = 64'h81000000;
    cfg.scb_enable = 0;
    require_true(cfg.resolve_final_service_requirement(service_key, requirement, why), why);
    if (custom_mode) begin
        dpu_priv_driver_config	private_cfg;
        private_cfg = cfg.get_dpu_private_config(service_key);
        private_cfg.defaults.i_l3_cs = 1;
        private_cfg.defaults.i_l4_cs = 1;
        foreach (private_cfg.queues[q]) begin
            private_cfg.queues[q].i_l3_cs = 1;
            private_cfg.queues[q].i_l4_cs = 1;
        end
    end
    uvm_config_db#(dpu_device_env_config)::set(this, "device_env", "cfg", device_cfg);
    device_env = dpu_device_env::type_id::create("device_env", this);
    uvm_config_db#(virtio_net_env_config)::set(this, "device_env.env", "cfg", cfg);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "device_env.env.*.driver_agent", "is_active", UVM_PASSIVE);
    env = virtio_net_env::type_id::create("env", device_env);
    rc_seqr = new("rc_seqr", this);
endfunction

function bit [63:0] virtio_external_lifecycle_test::descriptor_address(input bit [63:0] descriptor_gpa);
    byte	bytes[];
    bit [63:0]	address;

    env.host_mem.read_mem(descriptor_gpa, 8, bytes);
    foreach (bytes[i]) address[i*8 +: 8] = bytes[i];
    return address;
endfunction

function void virtio_external_lifecycle_test::dma_write(input virtio_function_instance instance,
        input bit [63:0] iova, input byte bytes[]);
    iommu_fault_e	fault;

    require_true(env.iommu.write_from_device_for_host(instance.pcie_id.domain.host_id,
        env.host_mem, instance.bdf, iova, bytes, fault), "device DMA write must translate");
endfunction

function void virtio_external_lifecycle_test::deliver_msix(input virtio_function_instance instance,
        input vio_external_queue_binding_t binding, input bit wrong = 0);
    pcie_tl_mem_tlp	message;

    message = new("received_msix");
    message.kind = TLP_MEM_WR;
    message.addr = binding.message_address;
    message.length = 1;
    message.first_be = 4'hf;
    message.last_be = 0;
    message.payload = new[4];
    for (int unsigned i = 0; i < 4; i++) message.payload[i] = binding.message_data[i*8 +: 8];
    if (wrong) message.payload[3] ^= 8'h80;
    instance.driver_agent.observer.write(message);
endfunction

task virtio_external_lifecycle_test::run_phase(uvm_phase phase);
    virtio_function_instance	instance;
    virtio_atomic_ops	ops;
    virtio_auto_fsm	fsm;
    vio_external_spy_bar	spy;
    vio_external_queue_binding_t	bindings[$];
    vio_external_queue_binding_t	binding;
    dpu_vio_qpair_binding_t	pairs[$];
    vio_external_setup	setup;
    vio_external_setup	stale;
    vio_external_setup	forged;
    vio_config_scope	scope;
    vio_config_scope	wrong_scope;
    dpu_service_key_t	keys[$];
    vio_queue_setup_t	records[$];
    vio_queue_setup_t	tx;
    vio_queue_setup_t	rx;
    packet_item	packet;
    virtio_net_hdr_t	hdr;
    uvm_object	completed[$];
    uvm_object	received[$];
    byte unsigned	wire_bytes[$];
    byte	bytes[];
    byte	readback[];
    bit [63:0]	data_iova;
    bit [63:0]	data_gpa;
    iommu_fault_e	fault;
    int unsigned	desc_id;
    int unsigned	writes_before;
    int unsigned	pending_before;
    int unsigned	polls_before;
    bit	ok;
    string	why;
    bit [31:0]	control;
    int unsigned	qids[$];
    virtqueue_base	probe_queue;
    dpu_priv_driver_config	private_cfg;
    dpu_service_key_t	unknown_key;

    phase.raise_objection(this);
    instance = env.function_instances[0];
    spy = new("spy");
    spy.configure_fabric_bar_pairs(instance.bar_pairs);
    instance.transport.bar = spy;
    require_true(env.bind_pcie(rc_seqr), "real Function bind");
    spy.observer = instance.driver_agent.observer;
    // 顶层协议时钟复位期间会清空暂存脉冲；先等真实复位释放再建立语义历史。
    wait (instance.driver_agent.monitor.protocol_vif.rst_n === 1'b1);
    ops = instance.driver_agent.ops;
    fsm = instance.driver_agent.fsm;
    device_env.get_resource_snapshot().list_vio_bindings_for_service(service_key, pairs);
    require_true(pairs.size() == 1, "one actual qpair");
    for (int unsigned q = 0; q < 2; q++) begin
        binding.service_key = service_key;
        binding.local_qid = q;
        binding.notify_bar = 2;
        binding.notify_offset = 64'h100;
        binding.notify_encoding = VIO_NOTIFY_DPU32;
        binding.local_vector = pairs[0].local_msix_vector_id;
        binding.global_vector = pairs[0].global_msix_vector_id;
        binding.msix_valid = msix_mode;
        binding.message_address = 64'h12345678000;
        binding.message_data = 32'hcafe5678;
        binding.masked = 0;
        bindings.push_back(binding);
    end
    bindings[0].notify_offset[7] = 1'bx;
    env.prepare_external_configuration(bindings, setup, ok, why);
    require_true(!ok && setup == null && !ops.has_active_queues(), "unknown notify must reject before allocation");
    bindings[0].notify_offset = 64'h100;
    bindings[0].notify_bar = 6;
    env.prepare_external_configuration(bindings, setup, ok, why);
    require_true(!ok && setup == null, "out-of-range BAR must reject");
    bindings[0].notify_bar = 2;
    env.prepare_external_configuration(bindings, setup, ok, why);
    require_true(ok && setup != null, why);
    require_true(spy.config_accesses == 0 && spy.mmio_reads == 0 && spy.mmio_writes == 0,
        "prepare has no config/MMIO/notify side effects");
    setup.list_queues(records);
    require_true(setup.get_queue(service_key, 1, tx) && setup.get_queue(service_key, 0, rx), "export directions");
    require_true(tx.desc_iova != tx.desc_gpa && rx.desc_iova != rx.desc_gpa, "non-identity rings");
    require_true(tx.qpair.global_qpair_id == pairs[0].global_qpair_id &&
        tx.notification.global_vector == pairs[0].global_msix_vector_id, "real allocated resource IDs");
    require_true(custom_mode ? (tx.cq_bytes == 2 && rx.cq_bytes == 256 && tx.usable_descriptors == 15) :
        (tx.driver_iova != 0 && tx.device_iova != 0 && tx.cq_bytes == 0), "mode-specific exported geometry");
    if (custom_mode)
        require_true(tx.private_tx_control.i_l3_cs && tx.private_tx_control.i_l4_cs &&
            tx.ring_valid_bytes == 258 && rx.ring_valid_bytes == 512,
            "exported Custom controls and logical ring geometry");
    records[0].desc_iova = 0;
    require_true(setup.get_queue(service_key, 0, rx) && rx.desc_iova != 0, "setup returns immutable copies");
    packet = new("frame512");
    require_true(packet.pkt.randomize() with {pkt_kind == ETH_IPV4_TCP; pkt_len == 512;}, "512B frame");
    packet.pkt.do_pack();
    hdr = '{default:0};
    ops.tx_submit(1, hdr, packet, 0, desc_id);
    ops.rx_refill(0, 1);
    ops.kick_queue(1);
    require_true(desc_id == '1 && spy.mmio_writes == 0 && instance.vq_mgr.get_queue(1).get_pending_count() == 0,
        "prepared generation cannot submit or notify");
    scope = new("all", setup, keys);
    require_true(!env.confirm_external_configuration(setup, scope, 1'bx, why), "unknown platform confirmation");
    qids.push_back(0);
    qids.push_back(1);
    require_true(!fsm.accept_external_configuration(env, setup.get_generation(), qids, instance.drv_cfg, why),
        "known env and generation cannot forge private confirmation credential");
    probe_queue = instance.vq_mgr.get_queue(1);
    probe_queue.desc_table_addr += 16;
    require_true(!env.confirm_external_configuration(setup, scope, 1, why), "changed ring owner address rejected");
    probe_queue.desc_table_addr = tx.desc_gpa;
    unknown_key = service_key;
    unknown_key.service_instance_id++;
    keys.push_back(unknown_key);
    wrong_scope = new("unknown_scope", setup, keys);
    require_true(!env.confirm_external_configuration(setup, wrong_scope, 1, why), "unknown service scope rejected");
    keys.delete();
    setup.list_queues(records);
    forged = new("forged", env, device_env.get_snapshot(), device_env.get_resource_snapshot(), setup.get_generation(), records);
    wrong_scope = new("forged_scope", forged, keys);
    require_true(!env.confirm_external_configuration(forged, wrong_scope, 1, why), "forged setup rejected");
    require_true(!env.release_external_resources(setup, 0, why), "exported unconfirmed resources retain without quiescence");
    if (custom_mode) begin
        private_cfg = cfg.get_dpu_private_config(service_key);
        private_cfg.defaults.i_l3_cs = 0;
        private_cfg.defaults.i_l4_cs = 0;
        foreach (private_cfg.queues[q]) begin
            private_cfg.queues[q].i_l3_cs = 0;
            private_cfg.queues[q].i_l4_cs = 0;
        end
    end
    if (msix_mode) deliver_msix(instance, bindings[0]);
    require_true(env.confirm_external_configuration(setup, scope, 1, why), why);
    require_true(fsm.state == FSM_READY && instance.state == VF_CONFIGURED &&
        env.external_service_confirmed(setup, service_key), "Function and FSM readiness handoff");
    // 早到消息保留且共享向量每个方向分别领取，不能被一条队列吞掉。
    if (msix_mode) begin
        require_true(instance.transport.notify_mgr.consume_external_pending(0), "early RX message retained");
        require_true(instance.transport.notify_mgr.consume_external_pending(1), "early TX message retained independently");
    end
    ops.tx_submit(1, hdr, packet, 0, desc_id);
    require_true(desc_id != '1, "512B TX accepted after confirm");
    require_true(spy.last_word == (custom_mode ? 32'h80010001 : 32'h80020001), "DPU32 notify uses local cursor");
    env.host_mem.read_mem(tx.desc_gpa, custom_mode ? 16 : 32, bytes);
    if (custom_mode) begin
        control = {bytes[15], bytes[14], bytes[13], bytes[12]};
        require_true(control[25:24] == 2'b11, "current i_l3/i_l4 descriptor bits");
        data_iova = descriptor_address(tx.desc_gpa);
    end else begin
        require_true({bytes[11],bytes[10],bytes[9],bytes[8]} == 12, "Packed retains standard virtio-net header");
        data_iova = descriptor_address(tx.desc_gpa + 16);
    end
    require_true(env.iommu.translate_for_host(0, instance.bdf, data_iova, 512, DMA_TO_DEVICE, data_gpa, fault), "TX payload mapping");
    require_true(data_iova != data_gpa, "TX payload nonidentity DMA");
    env.host_mem.read_mem(data_gpa, 512, readback);
    require_true(virtio_net_packet_adapter::pack(packet, wire_bytes), "frame byte adapter");
    require_true(wire_bytes.size() == 512, "wire size");
    foreach (readback[i]) require_true(readback[i] == byte'(wire_bytes[i]), "TX payload byte preserved");
    if (custom_mode) begin
        bytes = new[2]; bytes[0] = 1; bytes[1] = 8'h80;
        dma_write(instance, tx.device_iova, bytes);
    end else begin
        env.host_mem.read_mem(tx.desc_gpa + 14, 2, bytes);
        bytes[1] |= 8'h80;
        dma_write(instance, tx.desc_iova + 14, bytes);
    end
    ops.rx_refill(0, 1);
    if (custom_mode) begin
        bytes = new[16]; foreach (bytes[i]) bytes[i] = 0;
        bytes[5] = 16; bytes[7] = 8'h82;
        dma_write(instance, rx.device_iova, bytes);
        require_true(!instance.vq_mgr.get_queue(0).vq_poll(0) &&
            instance.vq_mgr.get_queue(0).get_pending_count() == 1,
            "head-split CQ cannot consume posted buffer");
        bytes[5] = 0; bytes[6] = 1; bytes[7] = 8'h88;
        dma_write(instance, rx.device_iova, bytes);
        require_true(!instance.vq_mgr.get_queue(0).vq_poll(0) &&
            instance.vq_mgr.get_queue(0).get_pending_count() == 1,
            "multi-buffer packet length cannot consume posted ownership");
    end
    data_iova = descriptor_address(rx.desc_gpa);
    bytes = new[custom_mode ? 512 : 524];
    foreach (bytes[i]) bytes[i] = (i < (custom_mode ? 0 : 12)) ? 0 : byte'(wire_bytes[i-(custom_mode ? 0 : 12)]);
    dma_write(instance, data_iova, bytes);
    if (custom_mode) begin
        // DW1低16位非零metadata，desc_num/pkt_num不等于1，仍是合法单buffer。
        bytes = new[16]; foreach (bytes[i]) bytes[i] = 0;
        bytes[3] = 8'hd0; bytes[4] = 8'hc7; bytes[6] = 0; bytes[7] = 8'h82;
        dma_write(instance, rx.device_iova, bytes);
    end else begin
        bytes = new[4]; bytes[0] = 8'h0c; bytes[1] = 2; bytes[2] = 0; bytes[3] = 0;
        dma_write(instance, rx.desc_iova + 8, bytes);
        env.host_mem.read_mem(rx.desc_gpa + 14, 2, bytes); bytes[1] |= 8'h80;
        dma_write(instance, rx.desc_iova + 14, bytes);
    end
    if (msix_mode) begin
        ops.tx_complete(1, completed, 8);
        ops.rx_receive(0, received, 8);
        require_true(completed.size() == 0 && received.size() == 0, "DMA used without interrupt cannot complete");
        deliver_msix(instance, bindings[0], 1);
        ops.tx_complete(1, completed, 8);
        require_true(completed.size() == 0, "unknown message cannot complete");
        deliver_msix(instance, bindings[0]);
    end
    ops.tx_complete(1, completed, 8);
    ops.rx_receive(0, received, 8);
    require_true(completed.size() == 1 && completed[0] == packet && received.size() == 1,
        "512B TX/RX completed through fixed policy and shared vector");
    writes_before = spy.mmio_writes;
    fsm.start_dataplane();
    require_true(!env.release_external_resources(setup, 1, why), "running workers prevent release");
    if (msix_mode) begin
        ops.tx_submit(1, hdr, packet, 0, desc_id);
        require_true(desc_id != '1, "running TX submission");
        // Packed 统计占用 descriptor ID，Custom 统计包；保存各自实际基线，不混用单位。
        pending_before = instance.vq_mgr.get_queue(1).get_pending_count();
        polls_before = instance.vq_mgr.get_queue(1).total_poll_used_ops;
        require_true(pending_before != 0, "running submission owns pending resources");
        if (custom_mode) begin
            bytes = new[2]; bytes[0] = 2; bytes[1] = 8'h80;
            dma_write(instance, tx.device_iova, bytes);
        end else begin
            env.host_mem.read_mem(tx.desc_gpa + 2*16 + 14, 2, bytes);
            bytes[1] |= 8'h80;
            dma_write(instance, tx.desc_iova + 2*16 + 14, bytes);
        end
        #(10us);
        require_true(instance.vq_mgr.get_queue(1).get_pending_count() == pending_before &&
            instance.vq_mgr.get_queue(1).total_poll_used_ops == polls_before,
            "MSI-X background worker must not complete by timeout polling");
        deliver_msix(instance, bindings[1]);
        #(10us);
        require_true(instance.vq_mgr.get_queue(1).get_pending_count() == 0,
            "received message wakes background completion");
    end else #(3us);
    fsm.stop_dataplane();
    require_true(spy.config_accesses == 0 && spy.mmio_reads == 0, "workers never access status or masks");
    require_true(!env.release_external_resources(setup, 0, why), "VIP stop alone cannot release DMA");
    require_true(env.release_external_resources(setup, 1, why), why);
    require_true(!ops.has_active_queues() && !env.external_service_confirmed(setup, service_key), "release invalidates readiness");
    stale = setup;
    env.prepare_external_configuration(bindings, setup, ok, why);
    require_true(ok && setup.get_generation() > stale.get_generation(), "new preparation advances generation");
    require_true(!env.confirm_external_configuration(stale, scope, 1, why), "old generation cannot be reconfirmed");
    require_true(env.release_external_resources(setup, 1, why), why);
    // 留足时钟释放 notify/reset 暂存事件，防止测试提前结束掩盖 SVA 错误。
    repeat (8) @(posedge instance.driver_agent.monitor.protocol_vif.clk);
    require_true(instance.driver_agent.monitor.protocol_vif.outstanding_submission_count == 0,
        "released generation clears protocol submission credit");
    env.host_mem.leak_check();
    env.iommu.leak_check();
    `uvm_info("EXTERNAL_LIFECYCLE_PASS", $sformatf("512B %s %s lifecycle/observer passed", custom_mode ? "Custom" : "Packed", msix_mode ? "MSIX" : "polling"), UVM_NONE)
    phase.drop_objection(this);
endtask


// TX-only 验证实际 worker 不访问缺席 RX 队列，同时覆盖 QID16 高 byte lane。
class virtio_external_direction_test extends virtio_external_lifecycle_test;
    `uvm_component_utils(virtio_external_direction_test)

    // 复用真实拓扑和检查器，不创建第二套设备模拟。
    extern function new(string name, uvm_component parent);

    // 在冻结最终需求前禁用 RX；其余拓扑装配沿用生命周期测试。
    extern virtual function void build_phase(uvm_phase phase);

    // 单方向准备/启动/停止及观察器 doorbell 解码，失败立即保留现场。
    extern virtual task run_phase(uvm_phase phase);
endclass

function virtio_external_direction_test::new(string name, uvm_component parent);
    super.new(name, parent);
endfunction

function void virtio_external_direction_test::build_phase(uvm_phase phase);
    tx_only = 1;
    super.build_phase(phase);
endfunction

task virtio_external_direction_test::run_phase(uvm_phase phase);
    virtio_function_instance	instance;
    vio_external_spy_bar	spy;
    dpu_vio_qpair_binding_t	pairs[$];
    vio_external_queue_binding_t	bindings[$];
    vio_external_queue_binding_t	binding;
    vio_external_setup	setup;
    vio_config_scope	scope;
    dpu_service_key_t	keys[$];
    vio_queue_setup_t	records[$];
    virtio_transaction	observed;
    packet_item	packet;
    virtio_net_hdr_t	hdr;
    int unsigned	desc_id;
    bit	ok;
    string	why;

    phase.raise_objection(this);
    require_true(!custom_mode && !msix_mode, "direction case uses Packed polling");
    instance = env.function_instances[0];
    spy = new("spy_direction");
    spy.configure_fabric_bar_pairs(instance.bar_pairs);
    instance.transport.bar = spy;
    require_true(env.bind_pcie(rc_seqr), "direction Function bind");
    spy.observer = instance.driver_agent.observer;
    // 顶层协议时钟复位期间会清空暂存脉冲；先等真实复位释放再建立语义历史。
    wait (instance.driver_agent.monitor.protocol_vif.rst_n === 1'b1);
    device_env.get_resource_snapshot().list_vio_bindings_for_service(service_key, pairs);
    binding.service_key = service_key;
    binding.local_qid = 1;
    binding.notify_bar = 2;
    binding.notify_offset = 64'h102;
    binding.notify_encoding = VIO_NOTIFY_QID16;
    binding.local_vector = pairs[0].local_msix_vector_id;
    binding.global_vector = pairs[0].global_msix_vector_id;
    binding.msix_valid = 0;
    binding.message_address = 0;
    binding.message_data = 0;
    binding.masked = 0;
    bindings.push_back(binding);
    env.prepare_external_configuration(bindings, setup, ok, why);
    require_true(ok, why);
    setup.list_queues(records);
    require_true(records.size() == 1 && records[0].notification.local_qid == 1 &&
        !instance.vq_mgr.has_queue(0), "disabled RX allocates no queue");
    scope = new("tx_only", setup, keys);
    require_true(env.confirm_external_configuration(setup, scope, 1, why), why);
    instance.driver_agent.fsm.start_dataplane();
    #(3us);
    require_true(spy.mmio_writes == 0 && !instance.vq_mgr.has_queue(0),
        "TX-only workers never prefill or notify RX");
    packet = new("direction_frame");
    require_true(packet.pkt.randomize() with {pkt_kind == ETH_IPV4_TCP; pkt_len == 512;}, "direction frame");
    packet.pkt.do_pack();
    hdr = '{default:0};
    instance.driver_agent.ops.tx_submit(1, hdr, packet, 0, desc_id);
    require_true(desc_id != '1 && spy.mmio_writes == 1 && spy.last_word == 1,
        "QID16 emits only local queue number");
    require_true(instance.driver_agent.monitor.bar_event_fifo.try_get(observed) &&
        observed.atomic_op == ATOMIC_KICK && observed.queue_id == 1 && observed.monitor_data == 1,
        "observer decodes QID16 from upper byte lane");
    instance.driver_agent.fsm.stop_dataplane();
    require_true(spy.config_accesses == 0 && spy.mmio_reads == 0, "direction workers have no configuration accesses");
    require_true(env.release_external_resources(setup, 1, why), why);
    repeat (8) @(posedge instance.driver_agent.monitor.protocol_vif.clk);
    require_true(instance.driver_agent.monitor.protocol_vif.outstanding_submission_count == 0,
        "TX-only release clears protocol credit");
    `uvm_info("EXTERNAL_DIRECTION_PASS", "TX-only workers and QID16 upper byte lane passed", UVM_NONE)
    phase.drop_objection(this);
endtask


`ifdef AIP_CMDLINE_SV
import aip_core_pkg::*;

// 使用实际 AIP override 表验证三级覆盖与 prepare 前缓存，测试结束恢复自身键。
class virtio_external_parameter_test extends uvm_test;
    `uvm_component_utils(virtio_external_parameter_test)
    bit	prior_present[string];
    string	prior_value[string];

    // 仅构造组件。
    extern function new(string name, uvm_component parent);

    // 独立命名空间写入参数，首次触及保存原值。
    extern function void put(input string key, input string value);

    // 失败立即报告，避免无效配置继续流入准备阶段。
    extern function void require_true(input bit condition, input string message);

    // 显式0、每队列私有控制、精确容量和已缓存值都通过真实参数加载验证。
    extern virtual task run_phase(uvm_phase phase);
endclass

function virtio_external_parameter_test::new(string name, uvm_component parent);
    super.new(name, parent);
endfunction

function void virtio_external_parameter_test::put(input string key, input string value);
    if (!prior_present.exists(key)) begin
        prior_present[key] = aip_cmdline_override::has(key);
        if (prior_present[key]) prior_value[key] = aip_cmdline_override::get_val(key);
    end
    aip_cmdline_override::set_val(key, value);
endfunction

function void virtio_external_parameter_test::require_true(input bit condition, input string message);
    if (!condition) `uvm_fatal("EXTERNAL_PARAMS", message)
endfunction

task virtio_external_parameter_test::run_phase(uvm_phase phase);
    virtio_net_env_config	cfg;
    vio_service_requirement_t	first_value;
    vio_service_requirement_t	again;
    virtio_driver_config_t	behavior;
    dpu_priv_driver_config	private_cfg;
    dpu_priv_queue_config	q0;
    dpu_priv_queue_config	q1;
    dpu_service_key_t	key;
    string	why;
    string	root_path;
    string	service_path;

    phase.raise_objection(this);
    root_path = "task2.vio";
    service_path = {root_path, ".h0.pf0.vf0.i0"};
    key.function_key = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_VF, vf_id:0};
    key.service_kind = DPU_SERVICE_VIO_NET;
    key.service_instance_id = 0;
    put({root_path, ".enabled"}, "0");
    put({root_path, ".pairs"}, "4");
    put({root_path, ".queue_type"}, "VQ_CUSTOM");
    put({root_path, ".queue_size"}, "16");
    put({root_path, ".notify_base"}, "0");
    put({root_path, ".notify_bar"}, "2");
    put({root_path, ".notify_encoding"}, "VIO_NOTIFY_DPU32");
    put({root_path, ".private.i_l3_cs"}, "1");
    put({root_path, ".private.i_l4_cs"}, "1");
    put({root_path, ".h0.enabled"}, "1");
    put({root_path, ".h0.pairs"}, "3");
    put({service_path, ".pairs"}, "2");
    put({service_path, ".rx_enable"}, "0");
    put({service_path, ".completion_mode"}, "VIRTIO_COMPLETION_MSIX");
    put({service_path, ".private.q1.i_l4_cs"}, "0");
    if ($test$plusargs("EXTERNAL_BAD_CHECKSUM")) put({service_path, ".private.q1.i_l3_cs"}, "2");
    cfg = new("external_parameter_cfg");
    cfg.external_configuration = 1;
    cfg.enable_service_params(root_path);
    require_true(cfg.resolve_final_service_requirement(key, first_value, why), why);
    require_true(first_value.enabled && first_value.tx_enable && !first_value.rx_enable &&
        first_value.behavior.num_queue_pairs == 2 && first_value.behavior.queue_size == 16 &&
        first_value.behavior.driver_features == 0 && first_value.notify_layout_valid &&
        first_value.notify_base == 0 && first_value.completion_mode == VIRTIO_COMPLETION_MSIX &&
        first_value.behavior.irq_mode != IRQ_POLLING, "exact final service override and explicit zero");
    private_cfg = cfg.get_dpu_private_config(key);
    q0 = private_cfg.resolve_queue(0);
    q1 = private_cfg.resolve_queue(1);
    require_true(q0.i_l3_cs && q0.i_l4_cs && q1.i_l3_cs && !q1.i_l4_cs, "private default then per-queue override");
    put({service_path, ".pairs"}, "1");
    put({service_path, ".completion_mode"}, "VIRTIO_COMPLETION_POLLING");
    require_true(cfg.resolve_final_service_requirement(key, again, why) &&
        again.behavior.num_queue_pairs == 2 && again.completion_mode == VIRTIO_COMPLETION_MSIX,
        "final requirement must not resample after placement");
    require_true(!cfg.get_service_config(key, 1, behavior, why), "insufficient placement must reject not clamp");
    foreach (prior_present[k]) begin
        if (prior_present[k]) aip_cmdline_override::set_val(k, prior_value[k]);
        else aip_cmdline_override::clear(k);
    end
    `uvm_info("EXTERNAL_PARAMS_PASS", "actual AIP final-service/private parameter contracts passed", UVM_NONE)
    phase.drop_objection(this);
endtask

`endif
