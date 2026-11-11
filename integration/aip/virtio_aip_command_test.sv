// integration/aip：命令适配器的录制driver单元测试，不代表真实DUT/PCIe验证。
// 依赖virtio_aip_pkg、UVM和PCIe类型；最小env只提供两个完整service身份和连接。
// 测试拥有所有stub组件；录制driver保留事务引用供断言，绝不执行总线或DMA。
// +CMD_NEGATIVE=unsigned_wrap为独立fatal负例，不能纳入正常零错误汇总。
`ifndef VIRTIO_AIP_COMMAND_TEST_SV
`define VIRTIO_AIP_COMMAND_TEST_SV
import uvm_pkg::*;
import aip_core_pkg::*;
import virtio_net_pkg::*;
import net_packet_pkg::*;
import virtio_aip_pkg::*;
import pcie_tl_pkg::*;
import dpu_resource_pkg::*;
`include "uvm_macros.svh"

// 仅覆写事务分派，保留真实UVM get_next_item/item_done路径以验证包裹类型。
class virtio_aip_recording_driver extends virtio_driver;
	`uvm_component_utils(virtio_aip_recording_driver)
	virtio_transaction	seen[$];
	realtime		seen_times[$];

	// 构造不创建资源；ops/FSM由stub agent注入。
	function new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	// 记录实际提交的事务；生命周期只推进测试 FSM，不启动真实收包或 DMA。
	protected virtual task process_transaction(virtio_transaction	req);
		seen.push_back(req);
		seen_times.push_back($realtime);
		case (req.txn_type)
			VIO_TXN_INIT: fsm.state = FSM_READY;
			VIO_TXN_START_DP: fsm.state = FSM_RUNNING;
			VIO_TXN_STOP_DP: fsm.state = FSM_READY;
			default: ;
		endcase
	endtask
endclass

// 最小agent避免创建真实monitor；只有本测试需要的seqr/driver/ops/FSM绑定。
class virtio_aip_stub_agent extends virtio_driver_agent;
	`uvm_component_utils(virtio_aip_stub_agent)

	// 构造由UVM管理组件生命周期。
	function new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	// 在build创建真实typed sequencer与录制driver；不建立真实队列或DMA。
	virtual function void build_phase(uvm_phase	phase);
		driver = virtio_aip_recording_driver::type_id::create("driver", this);
		sequencer = virtio_sequencer::type_id::create("sequencer", this);
		ops = virtio_atomic_ops::type_id::create("ops");
		fsm = virtio_auto_fsm::type_id::create("fsm");
		fsm.ops = ops;
		driver.ops = ops;
		driver.fsm = fsm;
	endfunction

	// 连接真实UVM仲裁端口；不调用依赖monitor的父类实现。
	virtual function void connect_phase(uvm_phase	phase);
		driver.seq_item_port.connect(sequencer.seq_item_export);
	endfunction

	// 测试连接已显式设置；禁止父类访问未创建的monitor。
	virtual function void start_of_simulation_phase(uvm_phase	phase);
	endfunction
endclass

// Function只承载身份与通路引用；不用真实snapshot构建，避免把stub误称集成测试。
class virtio_aip_stub_function extends virtio_function_instance;
	`uvm_component_utils(virtio_aip_stub_function)

	// 构造沿用Function初始身份，实际host在env内赋值。
	function new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	// PCIe sequencer仅作绑定哨兵，录制driver不使用它发送任何TLP。
	virtual function void build_phase(uvm_phase	phase);
		driver_agent = virtio_aip_stub_agent::type_id::create("agent", this);
		transport = virtio_pci_transport::type_id::create("transport");
		transport.bar.pcie_rc_seqr = new("pcie_sentinel", this);
	endfunction

	// 子agent先完成connect；此处给ops补齐与Function相同的transport引用。
	virtual function void connect_phase(uvm_phase	phase);
		driver_agent.ops.transport = transport;
	endfunction
endclass

// 双host相同PF/instance证明目标不按PF号或数组下标混淆。
class virtio_aip_stub_env extends virtio_net_env;
	`uvm_component_utils(virtio_aip_stub_env)

	// 构造沿用UVM父子关系，不加载生产配置。
	function new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	// 手工提供两个VIO完整service key，无真实资源快照。
	virtual function void build_phase(uvm_phase	phase);
		function_instances = new[2];
		foreach (function_instances[i]) begin
			function_instances[i] = virtio_aip_stub_function::type_id::create($sformatf("function_%0d", i), this);
			function_instances[i].service_key.function_key.host_id = i;
			function_instances[i].service_key.function_key.pf_id = 0;
			function_instances[i].service_key.function_key.kind = DPU_FUNCTION_PF;
			function_instances[i].service_key.function_key.vf_id = 0;
			function_instances[i].service_key.service_kind = DPU_SERVICE_VIO_NET;
			function_instances[i].service_key.service_instance_id = 0;
		end
	endfunction

	// 禁止父env加载真实资源与monitor连接。
	virtual function void connect_phase(uvm_phase	phase);
	endfunction

	// stub无scoreboard；结果由test断言负责，不能调用生产统计。
	virtual function void report_phase(uvm_phase	phase);
	endfunction
endclass

// API、路由、实际报文打包和明确失败路径的契约测试。
class virtio_aip_command_test extends uvm_test;
	`uvm_component_utils(virtio_aip_command_test)
	virtio_aip_stub_env	env;

	// 标准UVM测试构造。
	function new(string	name = "virtio_aip_command_test", uvm_component	parent = null);
		super.new(name, parent);
	endfunction

	// 只构造本文件stub环境，不影响生产driver工厂覆盖。
	virtual function void build_phase(uvm_phase	phase);
		env = virtio_aip_stub_env::type_id::create("env", this);
	endfunction

	// 统一检查同步命令的逐调用结果，失败仅影响测试报告。
	task command(string	text, bit	expected_ok);
		int	status;
		string	result;

		aip_cmd::exec_result(text, SRC_INTERNAL, status, result);
		if ((status == 0) != expected_ok)
			`uvm_error("AIP_TEST", $sformatf("%s: status=%0d result=%s expected_ok=%0b", text, status, result, expected_ok))
	endtask

	// 验证候选/范围生成真实报文，同一命令内修改长度、头、payload和offload。
	extern task check_packet_kinds(virtio_aip_recording_driver	driver);

	// 固定32包的尾批、随机批大小和逐包默认值；检查实际送到driver的通知标志。
	extern task check_notify_batches(virtio_aip_recording_driver	driver);

	// 顺序覆盖空 registry、双 Host 路由、TX 报文、活动 pair 范围及 RX 补充预检。
	virtual task run_phase(uvm_phase	phase);
		string				why;
		string				negative_mode;
		virtio_aip_recording_driver	driver0;
		virtio_aip_recording_driver	driver1;
		packet_item			packet_handle;
		eth_header			actual_eth;
		ipv4_header			actual_ipv4;
		int				before_count;

		phase.raise_objection(this);
		if (!virtio_aip_registry::register_commands(why)) `uvm_fatal("AIP_TEST", why)
		if (aip_cmd::get_handle("vio_wait_rx") != null)
			`uvm_error("AIP_TEST", "obsolete RX wait command is still registered")
		command("vio_init", 0);
		if (!virtio_aip_registry::bind_env(env, why)) `uvm_fatal("AIP_TEST", why)
		if (!$cast(driver0, env.function_instances[0].driver_agent.driver) ||
			!$cast(driver1, env.function_instances[1].driver_agent.driver)) `uvm_fatal("AIP_TEST", "driver cast")
		command("vio_init", 0);
		aip_cmdline_override::set_val("vio.target", "h0.pf0.i0");
		// 标量参数错误沿用fatal语义；负例必须独立仿真，且检查首个fatal ID，
		// 防止尾部的MISSED哨兵被误当作正确拒绝。正常回归不设置此开关。
		if ($value$plusargs("CMD_NEGATIVE=%s", negative_mode)) begin
			if (negative_mode != "unsigned_wrap")
				`uvm_fatal("CMD_NEGATIVE_UNKNOWN", negative_mode)
			aip_cmdline_override::set_val("vio.tx.gap_ns", "-18446744073709551615");
			command("vio_init", 1);
			command("vio_start", 1);
			command("vio_tx", 0);
			`uvm_fatal("CMD_NEGATIVE_MISSED", "negative unsigned scalar was accepted")
		end
		command("vio_init", 1);
		command("vio_start", 1);
		aip_cmdline_override::set_val("vio.tx.kind", "ETH_IPV4_UDP");
		aip_cmdline_override::set_val("vio.tx.len", "96");
		aip_cmdline_override::set_val("vio.tx.hdr.outer_eth.dst_mac", "48'h112233445566");
		command("set_param path=vio.tx.csum value=1", 1);
		command("set_param path=vio.tx.gso value=1", 1);
		command("set_param path=vio.tx.mss value=32", 1);
		command("vio_tx count=3", 1);
		if (driver0.seen.size() != 5 || driver1.seen.size() != 0)
			`uvm_error("AIP_TEST", "host routing or transaction count mismatch")
		foreach (driver0.seen[i]) begin
			if (driver0.seen[i].txn_type != VIO_TXN_SEND_PKTS) continue;
			if (driver0.seen[i].queue_id != 0 || driver0.seen[i].packets.size() != 1)
				`uvm_fatal("AIP_TEST", "TX must carry one packet_item and pair index")
			if (driver0.seen[i].tx_offload != virtio_tx_offload_t'{valid:1, csum:1, gso:1, mss:32})
				`uvm_error("AIP_TEST", "offload settings must accompany the same packet and target")
			if (!$cast(packet_handle, driver0.seen[i].packets[0])) `uvm_fatal("AIP_TEST", "packet wrapper type")
			// build_from_template创建独立layer_stack；outer_eth/outer_ipv4只是
			// randomize池，不是此创建路径下的实际协议头。getter和raw_data同时检查，
			// 保证参数进入真实发送的头对象和线上字节，不能误读未使用的池对象。
			actual_eth = packet_handle.pkt.get_eth();
			actual_ipv4 = packet_handle.pkt.get_ipv4();
			if (actual_eth == null || actual_ipv4 == null || packet_handle.pkt.get_udp() == null)
				`uvm_fatal("AIP_TEST", "ETH_IPV4_UDP template is missing an actual protocol layer")
			if (packet_handle.pkt.raw_data.size() != 96 ||
				actual_eth.dst_mac != 48'h112233445566 || actual_ipv4.protocol != 17 ||
				packet_handle.pkt.raw_data[0] != 8'h11 || packet_handle.pkt.raw_data[1] != 8'h22 ||
				packet_handle.pkt.raw_data[2] != 8'h33 || packet_handle.pkt.raw_data[3] != 8'h44 ||
				packet_handle.pkt.raw_data[4] != 8'h55 || packet_handle.pkt.raw_data[5] != 8'h66 ||
				packet_handle.pkt.raw_data[23] != 8'd17)
				`uvm_error("AIP_TEST", $sformatf(
					"template/length/header override was not packed: len=%0d actual_dst=%012h actual_ip_proto=%0d raw_dst=%02h%02h%02h%02h%02h%02h raw_ip_proto=%0d",
					packet_handle.pkt.raw_data.size(), actual_eth.dst_mac, actual_ipv4.protocol,
					packet_handle.pkt.raw_data[0], packet_handle.pkt.raw_data[1], packet_handle.pkt.raw_data[2],
					packet_handle.pkt.raw_data[3], packet_handle.pkt.raw_data[4], packet_handle.pkt.raw_data[5],
					packet_handle.pkt.raw_data[23]))
		end
		// 改长度和offload后新包重新读取，已提交请求保持原值；clear后恢复默认64。
		aip_cmdline_override::set_val("vio.tx.len", "128");
		command("set_param path=vio.tx.csum value=0", 1);
		command("set_param path=vio.tx.gso value=0", 1);
		command("set_param path=vio.tx.mss value=256", 1);
		command("vio_tx", 1);
		if (!$cast(packet_handle, driver0.seen[$].packets[0]) || packet_handle.pkt.raw_data.size() != 128)
			`uvm_error("AIP_TEST", "runtime length update was not loaded")
		if (driver0.seen[$].tx_offload != virtio_tx_offload_t'{valid:1, csum:0, gso:0, mss:256} ||
			!driver0.seen[2].tx_offload.gso || driver0.seen[2].tx_offload.mss != 32)
			`uvm_error("AIP_TEST", "runtime offload update changed an earlier packet or was not loaded")
		aip_cmdline_override::clear("vio.tx.len");
		if (aip_cmdline#(string)::get_cmdline_string("len", "vio.tx") != "")
			aip_cmdline_override::set_val("vio.tx.len", "64");
		command("vio_tx", 1);
		if (!$cast(packet_handle, driver0.seen[$].packets[0]) || packet_handle.pkt.raw_data.size() != 64)
			`uvm_error("AIP_TEST", "cleared length did not return to default")
		check_packet_kinds(driver0);
		check_notify_batches(driver0);
		before_count = driver0.seen.size();
		aip_cmdline_override::set_val("vio.tx.pair", "1");
		command("vio_tx", 0);
		command("vio_tx count=0", 0);
		// 使用有效pair和RUNNING状态，确保负count不能被后续状态错误偶然挡住。
		aip_cmdline_override::set_val("vio.tx.pair", "0");
		command("vio_tx count=-18446744073709551615", 0);
		command("vio_tx time=100", 0);
		command("vio_init count=2", 0);
		aip_cmdline_override::set_val("vio.tx.pair", "0");
		aip_cmdline_override::set_val("vio.tx.len", "14");
		command("vio_tx", 0);
		aip_cmdline_override::clear("vio.tx.len");
		aip_cmdline_override::set_val("vio.tx.target", "h9.pf0.i0");
		command("vio_tx", 0);
		if (driver0.seen.size() != before_count) `uvm_error("AIP_TEST", "invalid TX reached driver")
		aip_cmdline_override::clear("vio.tx.target");
		aip_cmdline_override::set_val("vio.target", "h1.pf0.i0");
		command("vio_start", 0);
		command("vio_init", 1);
		command("vio_start", 1);
		command("vio_rx_refill count=1", 0);
		command("vio_rx_refill qid=1 count=1", 0);
		command("vio_rx_refill qid=0 count=1", 0);
		command("vio_stop", 1);
		if (driver1.seen.size() < 3) `uvm_error("AIP_TEST", "second host did not receive operations")
		phase.drop_objection(this);
	endtask
endclass

// 优先读取用例命令行给出的TCP候选；无参数时使用set_param设置相同列表。
// 第二段借包间隔在第一包提交后改全部包参数，不依赖随机结果是否恰好不同。
task virtio_aip_command_test::check_packet_kinds(virtio_aip_recording_driver	driver);
	packet_item	item;
	packet_item	first_item;
	packet_item	second_item;
	int		first_index;
	int		lengths[int unsigned];
	int		descriptor_counts[int unsigned];

	aip_cmdline_override::clear("vio.tx.kind");
	if (aip_cmdline#(string)::get_cmdline_string("kind", "vio.tx") == "")
		command("set_param path=vio.tx.kind value=ETH_IPV4_TCP,ETH_IPV6_TCP", 1);
	aip_cmdline_override::clear("vio.tx.len");
	if (aip_cmdline#(string)::get_cmdline_string("len", "vio.tx") == "")
		command("set_param path=vio.tx.len value=[128:256]", 1);
	command("set_param path=vio.tx.desc_count value=[8:10]", 1);
	command("set_param path=vio.tx.seg_mode value=VIO_SEG_RANDOM", 1);
	first_index = driver.seen.size();
	command("vio_tx count=32", 1);
	if (driver.seen.size() != first_index + 32)
		`uvm_fatal("AIP_TEST", "enum candidate burst did not submit 32 packets")
	for (int i = first_index; i < driver.seen.size(); i++) begin
		if (!$cast(item, driver.seen[i].packets[0]))
			`uvm_fatal("AIP_TEST", "enum candidate packet wrapper type")
		if (item.pkt.get_tcp() == null ||
			(item.pkt.get_ipv4() == null && item.pkt.get_ipv6() == null) ||
			!(item.pkt.raw_data.size() inside {[128:256]}))
			`uvm_error("AIP_TEST", "enum candidate was not used to build the actual packet")
		lengths[item.pkt.raw_data.size()] = 1;
		if (!driver.seen[i].tx_seg.count_set ||
			!(driver.seen[i].tx_seg.desc_count inside {[8:10]}) ||
			driver.seen[i].tx_seg.mode != VIO_SEG_RANDOM)
			`uvm_error("AIP_TEST", "SG request was not bound to the generated packet")
		descriptor_counts[driver.seen[i].tx_seg.desc_count] = 1;
	end
	if (descriptor_counts.num() < 2)
		`uvm_error("AIP_TEST", "descriptor count expression was cached across packets")
	if (lengths.num() < 2)
		`uvm_error("AIP_TEST", "length expression was cached across the entire command")

	command("set_param path=vio.tx.kind value=ETH_IPV4_TCP", 1);
	command("set_param path=vio.tx.len value=128", 1);
	command("set_param path=vio.tx.gap_ns value=10", 1);
	command("set_param path=vio.tx.hdr.payload_mode value=PAYLOAD_FIXED", 1);
	command("set_param path=vio.tx.hdr.payload_fixed_val value=0x11", 1);
	command("set_param path=vio.tx.hdr.ipv4.src_addr value=0x0a000001", 1);
	command("set_param path=vio.tx.csum value=0", 1);
	command("set_param path=vio.tx.gso value=0", 1);
	command("set_param path=vio.tx.desc_count value=2", 1);
	command("set_param path=vio.tx.seg_mode value=VIO_SEG_EQUAL", 1);
	first_index = driver.seen.size();
	fork : update_packet_params
		command("vio_tx count=3", 1);
		begin
			wait (driver.seen.size() > first_index);
			command("set_param path=vio.tx.kind value=ETH_IPV4_UDP", 1);
			command("set_param path=vio.tx.len value=256", 1);
			command("set_param path=vio.tx.gap_ns value=20", 1);
			command("set_param path=vio.tx.hdr.payload_fixed_val value=0x22", 1);
			command("set_param path=vio.tx.hdr.ipv4.src_addr value=0x0a000002", 1);
			command("set_param path=vio.tx.csum value=1", 1);
			command("set_param path=vio.tx.gso value=1", 1);
			command("set_param path=vio.tx.mss value=64", 1);
			command("set_param path=vio.tx.desc_count value=5", 1);
			command("set_param path=vio.tx.seg_mode value=VIO_SEG_RANDOM", 1);
		end
	join
	if (driver.seen.size() != first_index + 3)
		`uvm_fatal("AIP_TEST", "runtime packet update burst did not submit three packets")
	if (!$cast(first_item, driver.seen[first_index].packets[0]) ||
		!$cast(second_item, driver.seen[first_index + 1].packets[0]))
		`uvm_fatal("AIP_TEST", "runtime enum packet wrapper type")
	if (first_item.pkt.get_tcp() == null || second_item.pkt.get_udp() == null ||
		first_item.pkt.raw_data[23] != 6 || second_item.pkt.raw_data[23] != 17)
		`uvm_error("AIP_TEST", "kind must be read for each packet within the same vio_tx command")
	if (first_item.pkt.raw_data.size() != 128 || second_item.pkt.raw_data.size() != 256 ||
		first_item.pkt.raw_data[127] != 8'h11 || second_item.pkt.raw_data[255] != 8'h22 ||
		first_item.pkt.raw_data[29] != 1 || second_item.pkt.raw_data[29] != 2 ||
		driver.seen[first_index].tx_offload.gso ||
		driver.seen[first_index + 1].tx_offload != virtio_tx_offload_t'{valid:1, csum:1, gso:1, mss:64})
		`uvm_error("AIP_TEST", "per-packet length/header/payload/offload changed an old packet or was not reloaded")
	if (driver.seen[first_index].tx_seg != virtio_tx_seg_t'{count_set:1, desc_count:2, mode:VIO_SEG_EQUAL} ||
		driver.seen[first_index + 1].tx_seg != virtio_tx_seg_t'{count_set:1, desc_count:5, mode:VIO_SEG_RANDOM})
		`uvm_error("AIP_TEST", "runtime SG change did not stay bound to its packet")
	if (driver.seen_times[first_index + 1] - driver.seen_times[first_index] != 10ns ||
		driver.seen_times[first_index + 2] - driver.seen_times[first_index + 1] != 20ns)
		`uvm_error("AIP_TEST", "gap_ns must be sampled for each packet")

	aip_cmdline_override::clear("vio.tx.desc_count");
	aip_cmdline_override::clear("vio.tx.seg_mode");
	aip_cmdline_override::clear("vio.tx.gap_ns");
	aip_cmdline_override::clear("vio.tx.len");
	aip_cmdline_override::clear("vio.tx.hdr.payload_mode");
	aip_cmdline_override::clear("vio.tx.hdr.payload_fixed_val");
	aip_cmdline_override::clear("vio.tx.hdr.ipv4.src_addr");
	`uvm_info("AIP_KIND_PASS", "enum candidates and in-command per-packet update passed", UVM_NONE)
endtask

// 1000不能被32整除：第1000包必须显式结束尾批；随机范围每批固定，最后一批允许更短。
task virtio_aip_command_test::check_notify_batches(virtio_aip_recording_driver	driver);
	int		first_index;
	int		batch_size;
	int		notify_count;
	int		sizes[int];
	bit		expected_notify;

	command("set_param path=vio.tx.len value=128", 1);
	command("set_param path=vio.tx.notify_batch value=32", 1);
	first_index = driver.seen.size();
	command("vio_tx count=1000", 1);
	if (driver.seen.size() != first_index + 1000)
		`uvm_fatal("AIP_TEST", "batch command did not submit 1000 packets")
	notify_count = 0;
	for (int i = 0; i < 1000; i++) begin
		expected_notify = ((i + 1) % 32 == 0) || (i == 999);
		if (driver.seen[first_index + i].tx_notify != expected_notify)
			`uvm_error("AIP_TEST", "fixed batch boundary or final short batch was not notified")
		if (driver.seen[first_index + i].tx_notify) notify_count++;
	end
	if (notify_count != 32)
		`uvm_error("AIP_TEST", "1000/32 must produce 31 full batches and one final 8-packet batch")

	aip_cmdline_override::clear("vio.tx.notify_batch");
	if (aip_cmdline#(string)::get_cmdline_string("notify_batch", "vio.tx") == "")
		command("set_param path=vio.tx.notify_batch value=[8:16]", 1);
	first_index = driver.seen.size();
	command("vio_tx count=257", 1);
	batch_size = 0;
	for (int i = 0; i < 257; i++) begin
		batch_size++;
		if (!driver.seen[first_index + i].tx_notify) continue;
		if (i != 256) begin
			if (!(batch_size inside {[8:16]}))
				`uvm_error("AIP_TEST", "random batch size is outside configured range")
			sizes[batch_size] = 1;
		end else if (batch_size > 16)
			`uvm_error("AIP_TEST", "random final batch exceeded target size")
		batch_size = 0;
	end
	if (batch_size != 0 || sizes.num() < 2)
		`uvm_error("AIP_TEST", "random batch parameter was cached or final batch was lost")

	command("set_param path=vio.tx.notify_batch value=1", 1);
	aip_cmdline_override::clear("vio.tx.len");
	`uvm_info("AIP_BATCH_PASS", "1000/32 final batch and per-batch range sampling passed", UVM_NONE)
endtask
`endif
