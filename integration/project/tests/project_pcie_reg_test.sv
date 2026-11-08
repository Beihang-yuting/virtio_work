// integration/project/tests：AIP reg_acc→PF0 BAR0包装seq→真实Intel请求/Completion验证。
// 依赖现有project测试包和Intel top；测试拥有应用侧寄存器存储，不配置VIO/DUT表。
// SV模式走exec_result，AIP_TCL模式走真实Tcl bridge；两者共享独立地址/字节/请求计数断言。
package project_pcie_reg_test_pkg;
	import uvm_pkg::*;
	import aip_core_pkg::*;
	import pcie_tl_pkg::*;
	import intel_pcie_adapter_pkg::*;
	import project_env_pkg::*;
	import project_external_integration_test_pkg::*;
	`include "uvm_macros.svh"

	// 命令仅借用真实环境的Host0 RC，不创建新sequencer或第二套BAR分配。
	class project_reg_test_context;
		static uvm_sequencer_base	sqr;
	endclass
	`aip_cmd_reg(reg_acc, project_pcie_reg_seq, project_reg_test_context::sqr, seq.error_msg, seq.check_read_data)

	// 仅接收两笔刻意开启RAM比较的AF状态读错误；协议错误及其他地址仍正常报错。
	class project_reg_expected_data_error extends uvm_report_catcher;
		bit [63:0]	addr;
		int unsigned	count;
		// 捕获器由测试持有，保留到report以精确接收两次预期错误的汇总。
		extern function new();
		// 地址、字节值、错误次数均固定，禁止吞掉真实配置/Completion故障。
		extern virtual function action_e catch();
	endclass

	function project_reg_expected_data_error::new();
		super.new("reg_expected_data_error");
	endfunction

	function uvm_report_catcher::action_e project_reg_expected_data_error::catch();
		if (get_id() == "SCB" && get_severity() == UVM_ERROR) begin
			if (count < 2 && get_message() == $sformatf(
				"Data mismatch at addr=0x%016h: expected=0xaa got=0x08", addr)) begin
				count++;
				return CAUGHT;
			end
			if (count == 2 && get_message() == "FAIL: 2 mismatches, 0 unexpected completions")
				return CAUGHT;
		end
		return THROW;
	endfunction

	// 复用现有build的Intel连接，独立run不启动父类DUT配置或发包。
	class project_pcie_reg_test extends project_bare_config_test;
		`uvm_component_utils(project_pcie_reg_test)
		int unsigned	requests;
		int unsigned	reads;
		int unsigned	writes;
		// 构造测试组件；参数/接口仍由父类build负责。
		extern function new(string name, uvm_component parent);
		// 从真实Intel端接收请求并返回Completion，同时独立核对绝对地址和写入字节。
		extern virtual task app_receive(input int unsigned host);
		// 运行真实命令注册，核对错误和读回；Tcl模式使用同样独立常量期望。
		extern task command(input string text, input bit success, input string expected = "");
		// 显式cfg与同一对象复用、错误后恢复；随后执行SV或Tcl命令并核对全部总线结果。
		extern virtual task run_phase(uvm_phase phase);
	endclass

	// 初始化父类测试容器，不创建额外DUT资源。
	function project_pcie_reg_test::new(string name, uvm_component parent);
		super.new(name, parent);
	endfunction

	// 不使用包装seq输出构造期望：只允许BAR0+1010/2000/3000三处，由固定测试命令访问。
	task project_pcie_reg_test::app_receive(input int unsigned host);
		forever begin
			pcie_tl_tlp		packet;
			pcie_tl_mem_tlp		request;
			pcie_tl_cpl_tlp		completion;
			bit [63:0]		offset;

			wait (apps[host].rx_queue.size() != 0);
			apps[host].receive(packet);
			if (packet == null) continue;
			require_true($cast(request, packet), "reg_acc emitted a non-Memory request");
			offset = pcie_tl_mem_wire_addr(request) - management.bar_lease.base;
			require_true(host == 0 && (offset == 'h1010 || offset == 'h2000 ||
				(offset >= 'h3000 && offset < 'h3010)), "request did not use assigned Host0 PF0 BAR0");
			require_true(request.tc == 0 && request.attr == 0, "register request allowed reordering");
			requests++;
			if (request.kind == TLP_MEM_WR) begin
				writes++;
				foreach (request.payload[i]) begin
					if (pcie_tl_mem_lane_enabled(request, i))
						mmio_bytes[host][pcie_tl_mem_wire_addr(request)+i] = request.payload[i];
				end
			end else begin
				require_true(request.kind == TLP_MEM_RD, "reg_acc emitted an unsupported Memory kind");
				reads++;
				completion = new("reg_readback");
				completion.kind         = TLP_CPLD;
				completion.type_f       = TLP_TYPE_CPL;
				completion.fmt          = FMT_3DW_WITH_DATA;
				completion.requester_id = request.requester_id;
				completion.tag          = request.tag;
				completion.completer_id = 0;
				completion.cpl_status   = CPL_STATUS_SC;
				completion.length       = request.length;
				completion.byte_count   = pcie_tl_mem_valid_bytes(request);
				completion.lower_addr   = request.addr[6:0] +
					pcie_tl_mem_first_valid_in_range(request, 0, pcie_tl_mem_dw_count(request)*4);
				completion.payload = new[pcie_tl_mem_dw_count(request)*4];
				foreach (completion.payload[i])
					completion.payload[i] = mmio_bytes[host].exists(pcie_tl_mem_wire_addr(request)+i) ?
						mmio_bytes[host][pcie_tl_mem_wire_addr(request)+i] : 0;
				// AF为状态寄存器，读值8独立于此前写入的声明magic。
				if (offset == 'h1010) completion.payload = '{8'h08, 8'h00, 8'h00, 8'h00};
				apps[host].send(completion);
			end
		end
	endtask

	// 错误必须由宏第四参数传回status/result，不能只依靠日志或仿真退出码。
	task project_pcie_reg_test::command(input string text, input bit success, input string expected = "");
		int	command_status;
		string	result;

		aip_cmd::exec_result(text, SRC_INTERNAL, command_status, result);
		require_true((command_status == 0) == success && (expected == "" || result == expected),
			$sformatf("%s: status=%0d result=%s expected=%s", text, command_status, result, expected));
	endtask

	// 两模式都先核对显式cfg注入及重复start；之后reg_acc自动从真实RC的config_db取得同一cfg。
	task project_pcie_reg_test::run_phase(uvm_phase phase);
		project_reg_expected_data_error	expected_error;
		project_pcie_reg_seq	access;
		project_pcie_reg_seq	missing;
		string			why;
		bit [127:0]		wide_value;
		int unsigned		before_requests;

		phase.raise_objection(this);
		require_true(cfg.bar_registry.resolve_name("h0.pf0.bar0", management, why), why);
		project_reg_test_context::sqr = cfg.rc_sequencers[cfg.tl_slot_by_host[0]];
		expected_error = new();
		expected_error.addr = management.bar_lease.base + 'h1010;
		uvm_report_cb::add(null, expected_error);
		fork app_receive(0); join_none
		#100ns;

		missing = new("missing_cfg");
		missing.start(null);
		require_true(missing.status == PCIE_RW_ERR && missing.error_msg != "" &&
			missing.issued_tlps.size() == 0, "missing cfg did not return a clean zero-request error");
		access = new("explicit_cfg");
		access.cfg      = cfg;
		access.addr     = 'h2000;
		access.is_write = 1;
		access.wdata    = 'haabbccdd;
		access.start(project_reg_test_context::sqr);
		require_true(access.status == PCIE_RW_OK && access.addr == 'h2000 && access.issued_tlps.size() == 1,
			"explicit cfg write failed or changed the offset");
		access.wdata = 'h11223344;
		access.start(project_reg_test_context::sqr);
		require_true(access.status == PCIE_RW_OK && access.addr == 'h2000 && access.issued_tlps.size() == 1 &&
			pcie_tl_mem_wire_addr(access.issued_tlps[0]) == management.bar_lease.base + 'h2000,
			"reused sequence accumulated BAR base or old issued requests");
		access.addr = management.bar_lease.size;
		access.start(project_reg_test_context::sqr);
		require_true(access.status == PCIE_RW_ERR && access.error_msg != "" && access.rdata == 0 &&
			access.issued_tlps.size() == 0, "out-of-range reuse did not clear outputs or reject before send");
		access.addr     = 'h2000;
		access.is_write = 0;
		access.start(project_reg_test_context::sqr);
		require_true(access.status == PCIE_RW_OK && access.error_msg == "" && access.addr == 'h2000 &&
			access.rdata == 'h11223344 && access.issued_tlps.size() == 1,
			"valid read after range error did not recover or preserve BAR-relative address");

		if ($test$plusargs("AIP_TCL")) begin
			aip_tcl_bridge::run_loop();
		end else begin
			command("reg_acc write 0x1010 4 0x5555aaaa", 1);
			command("reg_acc read 0x1010 check_read_data=0", 1, "rdata=0x8");
			require_true(expected_error.count == 0, "opt-out still compared AF with RAM write history");
			command("reg_acc read 0x1010 check_read_data=1", 1, "rdata=0x8");
			command("reg_acc read 0x1010", 1, "rdata=0x8");
			command("reg_acc op=write addr=0x3000 len=16 data=0x112233445566778899aabbccddeeff00", 1);
			command("reg_acc read 0x3000 16", 1, "rdata=0x112233445566778899aabbccddeeff00");
			command("reg_acc write 0x3000 16 0xffffffffffffffffffffffffffffffff mask=0x5555", 1);
			command("reg_acc op=read addr=0x3000 len=16 mask=0x5555", 1,
				"rdata=0xff00ff00ff00ff00ff00ff00ff00ff00");
			command("reg_acc read 0x3000 16", 1, "rdata=0xff22ff44ff66ff88ffaaffccffeeff00");
			before_requests = requests;
			command("reg_acc read 0x1010 check_read_data=2", 0,
				"ERROR: reg reg_acc: check_read_data must be 0 or 1");
			command("reg_acc read 0x1010 check_read_data=-1", 0,
				"ERROR: reg reg_acc: check_read_data must be 0 or 1");
			command("reg_acc read 0xfffffffffffff000 16", 0,
				"ERROR: reg reg_acc: BAR access crosses lease boundary or overflows 64-bit address");
			require_true(requests == before_requests, "Tcl-compatible range error sent a Memory request");
		end
		#100ns;
		require_true(requests == 26 && writes == 12 && reads == 14,
			$sformatf("missing/extra requests: total=%0d writes=%0d reads=%0d", requests, writes, reads));
		require_true(expected_error.count == 2 && env.pcie_env.scbs[0].mismatched == 2,
			"explicit/default read comparison or per-call opt-out did not behave independently");
		wide_value = table_value('h3000, 16);
		require_true(wide_value == 128'hff22ff44ff66ff88ffaaffccffeeff00 &&
			table_value('h1010, 4) == 'h5555aaaa && table_value('h2000, 4) == 'h11223344,
			"actual Intel writes did not preserve 128bit values or masked bytes");
		require_true(cfg.records.num() == 0 && cfg.vio_setups.num() == 0,
			"register access unexpectedly configured DUT tables or allocated rings");
		`uvm_info("PROJECT_REG_ACC_PASS", $sformatf("tcl=%0b requests=%0d writes=%0d reads=%0d checks=%0d",
			$test$plusargs("AIP_TCL"), requests, writes, reads, checks), UVM_LOW)
		phase.drop_objection(this);
	endtask
endpackage
