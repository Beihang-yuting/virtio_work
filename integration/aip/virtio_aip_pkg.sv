// integration/aip：可选 AIP 命令到 Virtio UVM sequence 的唯一 package 入口。
// 依赖先编译 aip_core_pkg、virtio_net_pkg（以及它们的资源/报文依赖）。
// 注册表只借用用户 env/Function；不创建 PCIe、DMA 或 DUT。每次命令拥有独立
// sequence/transaction/packet，常驻命令对象由 AIP 注册表持有直到仿真结束。
// 用户在 build 后绑定 env，在 register_aip_commands() 中显式注册；命令在 run
// 阶段执行。取消只终止 sequence，已经交给 driver 的事务和 DMA 不会自动撤回。
`ifndef VIRTIO_AIP_PKG_SV
`define VIRTIO_AIP_PKG_SV
package virtio_aip_pkg;
	timeunit 1ns;
	timeprecision 1ps;
	import uvm_pkg::*;
	import aip_core_pkg::*;
	import virtio_net_pkg::*;
	import net_packet_pkg::*;
	import dpu_resource_pkg::*;
	`include "uvm_macros.svh"

	typedef class virtio_aip_command;

	// 映射层保留完整 service 身份，避免把数组下标、BDF 或跨 host PF号当成目标。
	// 同一 env 重复绑定幂等；不同 env 的同名 service 冲突会在提交之前拒绝。
	class virtio_aip_registry;
		static virtio_function_instance	targets[string];
		static virtio_net_env	target_envs[string];
		static longint unsigned	cancelled_generation[string];
		static longint unsigned	owner_generation[string];
		static bit			needs_init[string];
		static bit			needs_reset[string];
		static process			owners[string];
		static string			owner_targets[string];
		static bit			owner_is_tx[string];

		// 事务级仲裁不能保护MQ/复位与多包流之间的生命周期，因此在命令入口按
		// service设置租约。仅TX/TX共享；RX会阻塞同一driver，必须避免同时启动。
		// 租约只约束本注册表命令；用户直接启动的sequence须由用户串行化生命周期。
		// 被取消owner遗留租约被回收，但目标标记需reset，绝不假设DMA已撤销。
		static function bit	acquire(string	command, string	target, bit	is_tx,
			output string	why);
			string	stale[$];

			foreach (owners[name]) begin
				if (owners[name].status() == process::KILLED) stale.push_back(name);
			end
			foreach (stale[i]) begin
				mark_cancelled(owner_targets[stale[i]], owner_generation[stale[i]]);
				owners.delete(stale[i]);
				owner_targets.delete(stale[i]);
				owner_is_tx.delete(stale[i]);
				owner_generation.delete(stale[i]);
			end
			foreach (owners[name]) begin
				if (owner_targets[name] == target && !(is_tx && owner_is_tx[name])) begin
					why = {"target busy with ", name};
					return 0;
				end
			end
			owners[command] = process::self();
			owner_targets[command] = target;
			owner_is_tx[command] = is_tx;
			owner_generation[command] = target_envs.exists(target) ?
				target_envs[target].external_service_generation(targets[target].service_key) : 0;
			why = "";
			return 1;
		endfunction

		// 正常退出移除本命令租约，不操作其他命令或任何driver资源。
		static function void release_lease(string	command);
			owners.delete(command);
			owner_targets.delete(command);
			owner_is_tx.delete(command);
			owner_generation.delete(command);
		endfunction

		// 将 service key 转为用户路径；VIO service kind 在本包固定，PF 不显示 vf。
		static function string	target_name(dpu_service_key_t	key);
			if (key.function_key.kind == DPU_FUNCTION_VF)
				return $sformatf("h%0d.pf%0d.vf%0d.i%0d", key.function_key.host_id,
					key.function_key.pf_id, key.function_key.vf_id, key.service_instance_id);
			return $sformatf("h%0d.pf%0d.i%0d", key.function_key.host_id,
				key.function_key.pf_id, key.service_instance_id);
		endfunction

		// 只绑定已构建的 env；两遍检查保证冲突时不留下部分注册。
		static function bit	bind_env(virtio_net_env	env, output string	why);
			string				name;
			virtio_function_instance	candidates[string];

			why = "";
			if (env == null || env.function_instances.size() == 0) begin
				why = "env is null or has no built VIO service";
				return 0;
			end
			foreach (env.function_instances[i]) begin
				if (env.function_instances[i] == null) begin
					why = "null Function in env";
					return 0;
				end
				if (env.function_instances[i].service_key.service_kind != DPU_SERVICE_VIO_NET) begin
					why = "target service is not VIO_NET"; return 0;
				end
				name = target_name(env.function_instances[i].service_key);
				if (candidates.exists(name) && candidates[name] != env.function_instances[i]) begin
					why = {"duplicate target within env: ", name}; return 0;
				end
				candidates[name] = env.function_instances[i];
				if (targets.exists(name) && targets[name] != env.function_instances[i]) begin
					why = {"duplicate target: ", name};
					return 0;
				end
			end
			foreach (env.function_instances[i]) begin
				name = target_name(env.function_instances[i].service_key);
				targets[name] = env.function_instances[i];
				target_envs[name] = env;
			end
			return 1;
		endfunction

		// 空 target 只在恰有一个 service 时推断；不按第一个 PF 猜测多 host 目标。
		static function bit	resolve(string	name, output virtio_function_instance	target,
			output string	why);
			target = null;
			why = "";
			if (name == "" && targets.num() == 1) void'(targets.first(name));
			if (!targets.exists(name)) begin
				why = {"unknown/ambiguous target: ", name};
				return 0;
			end
			target = targets[name];
			return 1;
		endfunction

		// 取消不回收 DMA；记录取消时的准备代号，stop 和同代确认均不能清除。
		extern static function void mark_cancelled(input string name, input longint unsigned generation);

		// 外部模式只在确认的新一代才放行业务；传统模式仍走原 reset/init 门禁。
		extern static function bit external_reuse_ready(input string name);

		// 项目只公开业务命令；保留 legacy register_commands 给独立用户。
		extern static function bit register_business_commands(output string why);

		// 注册定义在 command 类之后；只实例化对象，不在 function 内展开 class 宏。
		extern static function bit	register_commands(output string	why);
		// 独立名称拥有 AIP 独立 BUSY 槽；不同路径允许 tx0/tx1 各自加载参数。
		extern static function bit	register_tx_command(string	name, string	path, output string	why);
	endclass

	// 参数、报文及事务编排集中在可复用序列中；driver仍只接收 virtio_transaction。
	// finish_item仅代表driver处理已返回；TX成功表示提交，DUT/scoreboard结果由用户验证。
	class virtio_aip_sequence extends uvm_sequence #(virtio_transaction);
		`uvm_object_utils(virtio_aip_sequence)
		virtio_txn_type_e		operation;
		virtio_function_instance	target;
		string				path;
		string				target_path;
		string				result_text;
		bit				ok;
		int unsigned			count;
		int unsigned			pair;
		int unsigned			pkt_len;
		int unsigned			len_min;
		int unsigned			len_max;
		int unsigned			gap_ns;
		int unsigned			expected;
		int unsigned			timeout_ns;
		int unsigned			pairs;
		packet_template_e		kind;
		virtio_rss_config_t		rss;

		// 每次调用重建默认参数，避免运行期 override 清除后沿用前一调用缓存。
		function new(string	name = "virtio_aip_sequence");
			super.new(name);
			operation = VIO_TXN_SEND_PKTS;
			count = 1;
			kind = ETH_IPV4_TCP;
			ok = 0;
		endfunction

		// 使用 AIP typed scalar 入口：运行期 override 整数仅支持 literal；plusarg
		// 可沿用 AIP 随机表达式。独立 len_min/len_max 用于运行期可调长度范围。
		protected function int unsigned	scalar(string	name, int unsigned	default_value);
			longint unsigned	value;
			string			raw;

			// AIP先按绝对值检查64位宽，再转换到无符号类型；例如-(2^64-1)
			// 会回绕为1。因此在唯一一次随机采样前检查原始表达式的负号。
			// 整数表达式中负号只表示负数；合法inc/dec使用正步长，不受影响。
			raw = aip_cmdline#(longint unsigned)::get_cmdline_string(name, path);
			if (aip_str::str_find(raw, "-") >= 0)
				`uvm_fatal("VIO_AIP_PARAM", $sformatf("%s.%s requires an unsigned value: %s", path, name, raw))
			aip_cmdline#(longint unsigned)::get_single_value(name, path, default_value, value,
				`__FILE__, `__LINE__);
			if (value > 64'h0000_0000_ffff_ffff)
				`uvm_fatal("VIO_AIP_PARAM", $sformatf("%s.%s must fit unsigned 32 bits; got %0d", path, name, value))
			return int'(value);
		endfunction

		// 加载当前 operation 的参数；target 子路径缺省继承 vio.target。
		// RSS表和密钥使用显式size+逐元素键，拒绝越界，不悄悄截断。
		function bit	load_params(string	parameter_path);
			string			value;
			string			names[$];
			int			values[$];
			packet_template_e	enum_value;
			int unsigned		table_size;
			int unsigned		byte_value;

			path = parameter_path;
			target_path = aip_cmdline#(string)::get_cmdline_string("target", path);
			if (target_path == "") target_path = aip_cmdline#(string)::get_cmdline_string("target", "vio");
			if (!virtio_aip_registry::resolve(target_path, target, result_text)) return 0;
			target_path = virtio_aip_registry::target_name(target.service_key);
			case (operation)
				VIO_TXN_SEND_PKTS: begin
					pair = scalar("pair", 0);
					pkt_len = scalar("len", 64);
					len_min = scalar("len_min", pkt_len);
					len_max = scalar("len_max", pkt_len);
					gap_ns = scalar("gap_ns", 0);
					if (len_min < 14 || len_max < len_min || len_max > 65535) begin
						result_text = "TX requires 14 <= len_min <= len_max <= 65535";
						return 0;
					end
					value = aip_cmdline#(string)::get_cmdline_string("kind", path);
					if (value != "") begin
						enum_value = enum_value.first();
						forever begin
							names.push_back(enum_value.name());
							values.push_back(int'(enum_value));
							if (enum_value == enum_value.last()) break;
							enum_value = enum_value.next();
						end
						kind = packet_template_e'(aip_cmdline_enum::resolve(value, names, values));
					end
				end
				VIO_TXN_WAIT_PKTS: begin
					expected = scalar("expected", 1);
					timeout_ns = scalar("timeout_ns", 50000);
					if (expected == 0 || timeout_ns == 0) begin
						result_text = "RX expected and timeout_ns must be positive";
						return 0;
					end
				end
				VIO_TXN_SET_MQ: pairs = scalar("pairs", 1);
				VIO_TXN_SET_RSS: begin
					rss.hash_types = scalar("hash_types", 0);
					rss.hash_key_size = scalar("hash_key_size", 40);
					table_size = scalar("table_size", 1);
					if (rss.hash_key_size == 0 || rss.hash_key_size > 255 ||
						table_size == 0 || table_size > 32768 || (table_size & (table_size-1)) != 0) begin
						result_text = "invalid RSS key/table size (table must be power of two)";
						return 0;
					end
					rss.hash_key = new[rss.hash_key_size];
					rss.indirection_table = new[table_size];
					foreach (rss.hash_key[i]) begin
						byte_value = scalar($sformatf("hash_key[%0d]", i), 0);
						if (byte_value > 255) begin
							result_text = "RSS hash key element exceeds byte range";
							return 0;
						end
						rss.hash_key[i] = byte'(byte_value);
					end
					foreach (rss.indirection_table[i])
						rss.indirection_table[i] = scalar($sformatf("indirection_table[%0d]", i), 0);
				end
				default: ;
			endcase
			return 1;
		endfunction

		// 预检最终绑定，禁止 sequence 假跑在空 sequencer、未接 PCIe 或另一FSM上。
		function bit	ready_binding();
			if (target == null || target.driver_agent == null || target.transport == null) begin
				result_text = "missing Function/agent/transport binding";
				return 0;
			end
			if (target.driver_agent.sequencer == null || target.driver_agent.driver == null ||
				target.driver_agent.driver.fsm == null || target.driver_agent.driver.ops == null) begin
				result_text = "missing active sequencer/driver/FSM/ops binding";
				return 0;
			end
			if (target.driver_agent.driver.seq_item_port.size() == 0) begin
				result_text = "driver sequencer port is not connected"; return 0;
			end
			if (target.transport.bar == null || target.transport.bar.pcie_rc_seqr == null ||
				target.driver_agent.driver.ops.transport != target.transport ||
				target.driver_agent.driver.fsm.ops != target.driver_agent.driver.ops) begin
				result_text = "missing or inconsistent PCIe/ops/FSM binding";
				return 0;
			end
			return 1;
		endfunction

		// 单事务等待保持标准UVM语义；取消时AIP调用kill，不撤回driver已接受工作。
		protected task submit(virtio_transaction	item);
			start_item(item);
			finish_item(item);
			aip_activity::tick();
		endtask

		// kill只撤销sequence线程；driver接受的事务仍可继续，因此下一命令必须先
		// 传统模式经过reset恢复；外部模式只允许stop，再由平台quiesce/reprepare/verify恢复。
		virtual function void do_kill();
			ok = 0;
			result_text = "sequence cancelled; accepted driver work is not rolled back";
			virtio_aip_registry::mark_cancelled(target_path,
				virtio_aip_registry::target_envs.exists(target_path) ?
				virtio_aip_registry::target_envs[target_path].external_service_generation(virtio_aip_registry::targets[target_path].service_key) : 0);
			super.do_kill();
		endfunction

		// 主动间隔分成短片段喂AIP watchdog；等待仅推进时间，不伪造收包或设备完成。
		protected task active_delay(int unsigned	delay_ns);
			int unsigned	remaining;
			int unsigned	slice;

			remaining = delay_ns;
			while (remaining != 0) begin
				slice = remaining > 1000 ? 1000 : remaining;
				#(slice * 1ns);
				remaining -= slice;
				aip_activity::tick();
			end
		endtask

		// 主体先检查状态，再发事务并核对FSM/ACK/收到数量。全局UVM错误计数采用
		// 保守语义：并发命令产生错误也会使本命令失败，绝不将UVM_ERROR包装成OK。
		virtual task body();
			virtio_auto_fsm		fsm;
			virtio_transaction	item;
			virtio_transaction	probe;
			packet_item		packet_handle;
			uvm_report_server	reports;
			int			errors_before;
			fsm_state_e		state_before;

			ok = 0;
			if (!ready_binding()) return;
			if (get_sequencer() != target.driver_agent.sequencer) begin
				result_text = "sequence started on a sequencer belonging to another target"; return;
			end
			if (target.driver_agent.ops.uses_external_configuration()) begin
				if (!(operation inside {VIO_TXN_START_DP, VIO_TXN_SEND_PKTS, VIO_TXN_WAIT_PKTS, VIO_TXN_STOP_DP})) begin
					result_text = "external mode accepts business/stop only; platform owns device configuration"; return;
				end
				if (!virtio_aip_registry::external_reuse_ready(target_path) && operation != VIO_TXN_STOP_DP) begin
					result_text = "external cancellation requires stop, platform quiescence, release, new prepare and verified confirmation"; return;
				end
			end else if (virtio_aip_registry::needs_reset.exists(target_path) &&
				virtio_aip_registry::needs_reset[target_path] && operation != VIO_TXN_RESET) begin
				result_text = "target cancelled/failed reset; run vio_reset before reuse"; return;
			end
			if (virtio_aip_registry::needs_init.exists(target_path) &&
				virtio_aip_registry::needs_init[target_path] &&
				!(operation inside {VIO_TXN_INIT, VIO_TXN_RESET})) begin
				result_text = "target was reset; run vio_init before reuse"; return;
			end
			fsm = target.driver_agent.driver.fsm;
			// 外部取消后允许幂等受控 stop；不清取消标志，更不推断硬件已停 DMA。
			if (target.driver_agent.ops.uses_external_configuration() && operation == VIO_TXN_STOP_DP &&
				fsm.state == FSM_READY && fsm.external_workers_stopped()) begin
				ok = 1;
				result_text = "VIP already stopped; platform quiescence and a new verified generation still required after cancellation";
				return;
			end
			state_before = fsm.state;
			reports = uvm_report_server::get_server();
			errors_before = reports.get_severity_count(UVM_ERROR) + reports.get_severity_count(UVM_FATAL);
			case (operation)
				VIO_TXN_INIT: if (!(fsm.state inside {FSM_IDLE, FSM_READY, FSM_REINIT_REQUIRED}) &&
					!(virtio_aip_registry::needs_init.exists(target_path) && virtio_aip_registry::needs_init[target_path])) begin
					result_text = "init requires IDLE/READY/REINIT_REQUIRED"; return;
				end
				VIO_TXN_START_DP: if (fsm.state != FSM_READY || !fsm.mq_pair_count_is_committed()) begin
					result_text = "start requires READY and committed MQ"; return;
				end
				VIO_TXN_SEND_PKTS, VIO_TXN_WAIT_PKTS: if (fsm.state != FSM_RUNNING) begin
					result_text = "TX/RX requires RUNNING"; return;
				end
				VIO_TXN_STOP_DP: if (fsm.state != FSM_RUNNING) begin
					result_text = "stop requires RUNNING"; return;
				end
				VIO_TXN_SET_MQ, VIO_TXN_SET_RSS: if (!(fsm.state inside {FSM_READY, FSM_RUNNING})) begin
					result_text = "MQ/RSS requires READY or RUNNING"; return;
				end
				default: ;
			endcase
			if (operation == VIO_TXN_SEND_PKTS) begin
				for (int unsigned	i = 0; i < count; i++) begin
					// 每次提交都复查pair，不允许底层send_packets的raw queue-id后备路径。
					if (fsm.state != FSM_RUNNING || pair >= fsm.active_queue_pair_count()) begin
						result_text = "TX pair out of active range or dataplane stopped"; return;
					end
					if (virtio_aip_registry::needs_reset.exists(target_path) && virtio_aip_registry::needs_reset[target_path]) begin
						result_text = target.driver_agent.ops.uses_external_configuration() ?
						"external TX cancelled; stop and reprepare after platform quiescence" :
						"another TX stream was cancelled; target requires reset"; return;
					end
					packet_handle = packet_item::type_id::create($sformatf("packet_%0d", i));
					packet_handle.pkt = new();
					packet_handle.pkt.build_from_template(kind);
					packet_handle.pkt.pkt_len = $urandom_range(len_max, len_min);
					packet_handle.pkt.load_params({path, ".hdr"});
					// pack可能为完整协议头或trailer扩长；必须在pack之前拒绝短于
					// 模板结构的请求，不能把自动修正后的长度宣称为用户长度成功。
					if (packet_handle.pkt.pkt_len < packet_handle.pkt.get_all_headers_length() +
						packet_handle.pkt.get_all_trailers_length()) begin
						result_text = "TX length is shorter than selected template headers/trailers"; return;
					end
					packet_handle.pkt.do_pack();
					if (packet_handle.pkt.pkt_len < 14 || packet_handle.pkt.pkt_len > 65535 ||
						packet_handle.pkt.raw_data.size() != packet_handle.pkt.pkt_len) begin
						result_text = "packed packet length differs from requested length or exceeds bounds"; return;
					end
					item = virtio_transaction::type_id::create("send");
					item.txn_type = VIO_TXN_SEND_PKTS;
					item.queue_id = pair;
					item.packets.push_back(packet_handle);
					submit(item);
					if (errors_before != reports.get_severity_count(UVM_ERROR) + reports.get_severity_count(UVM_FATAL)) begin
						result_text = "UVM error/fatal during TX submission; remaining packets not submitted"; return;
					end
					if (i+1 < count && gap_ns != 0) active_delay(gap_ns);
					aip_activity::tick();
				end
				ok = (fsm.state == FSM_RUNNING);
				result_text = $sformatf("submitted %0d packets (DUT completion/scoreboard not checked)", count);
			end else if (operation == VIO_TXN_WAIT_PKTS) begin
				// 一个真实WAIT事务保持driver原有总超时语义；有限heartbeat只在用户
				// 等待预算内活动。预算耗尽后停止tick，卡住的driver仍可被AIP watchdog发现。
				// 这里不注入报文，也不通过重复短wait制造多次中间超时warning。
				item = virtio_transaction::type_id::create("wait_rx");
				item.txn_type = VIO_TXN_WAIT_PKTS;
				item.expected_count = expected;
				item.timeout_ns = timeout_ns;
				fork : bounded_rx_wait
					begin
						submit(item);
					end
					begin
						active_delay(timeout_ns);
						wait (0);
					end
				join_any
				disable bounded_rx_wait;
				ok = item.received_pkts.size() >= expected;
				result_text = $sformatf("RX %s: received=%0d expected=%0d", ok ? "complete" : "timeout/stopped", item.received_pkts.size(), expected);
			end else begin
				item = virtio_transaction::type_id::create("operation");
				item.txn_type = operation;
				item.expected_count = expected;
				item.timeout_ns = timeout_ns;
				item.num_pairs = pairs;
				item.rss_cfg = rss;
				if (operation == VIO_TXN_SET_MQ && (pairs == 0 || pairs > fsm.max_supported_mq_pairs())) begin
					result_text = "MQ pair count out of configured range"; return;
				end
				if (operation == VIO_TXN_SET_RSS) begin
					foreach (rss.indirection_table[i]) begin
						if (rss.indirection_table[i] >= fsm.active_queue_pair_count()) begin
							result_text = "RSS indirection pair out of active range"; return;
						end
					end
				end
				// Reset必须先等worker退出；标准协议需读回status，不能读未赋值success。
				if (operation == VIO_TXN_RESET && fsm.state == FSM_RUNNING) begin
					probe = virtio_transaction::type_id::create("stop_before_reset");
					probe.txn_type = VIO_TXN_STOP_DP;
					submit(probe);
					if (fsm.state != FSM_READY) begin result_text = "reset could not stop dataplane"; return; end
				end
				if (operation == VIO_TXN_RESET) virtio_aip_registry::needs_reset[target_path] = 1;
				submit(item);
				case (operation)
					VIO_TXN_INIT: ok = (fsm.state == FSM_READY);
					VIO_TXN_START_DP: ok = (fsm.state == FSM_RUNNING);
					VIO_TXN_STOP_DP: ok = (fsm.state == FSM_READY);
					VIO_TXN_SET_MQ: ok = (fsm.state == state_before &&
						fsm.active_queue_pair_count() == pairs && fsm.mq_pair_count_is_committed());
					VIO_TXN_SET_RSS: ok = (fsm.state == state_before);
					VIO_TXN_RESET: begin
						if (target.driver_agent.driver.protocol != null &&
							!target.driver_agent.driver.protocol.allows_status_access()) ok = item.success;
						else begin
							probe = virtio_transaction::type_id::create("verify_reset");
							probe.txn_type = VIO_TXN_ATOMIC_OP;
							probe.atomic_op = ATOMIC_READ_STATUS;
							probe.status_val = '1;
							submit(probe);
							ok = (probe.status_val == DEV_STATUS_RESET &&
								target.driver_agent.driver.ops.vq_mgr != null &&
								target.driver_agent.driver.ops.vq_mgr.get_queue_count() == 0);
						end
					end
					default: ok = 0;
				endcase
				result_text = $sformatf("%s %s; state=%s received=%0d", operation.name(),
					ok ? "completed" : "failed", fsm.state.name(), item.received_pkts.size());
			end
			if (errors_before != reports.get_severity_count(UVM_ERROR) + reports.get_severity_count(UVM_FATAL)) begin
				ok = 0;
				result_text = "UVM error/fatal occurred during operation; inspect simulation log";
			end
			// 标准reset不修改FSM影子；本层门禁明确要求重新init，避免把READY缓存
			// 当成仍有队列。ops的verified reset负责真正回收DMA，适配层不改它的状态。
			if (ok && operation == VIO_TXN_RESET) begin
				virtio_aip_registry::needs_reset[target_path] = 0;
				virtio_aip_registry::needs_init[target_path] = 1;
				result_text = {result_text, "; vio_init required before reuse"};
			end
			if (ok && operation == VIO_TXN_INIT) virtio_aip_registry::needs_init[target_path] = 0;
		endtask
	endclass

	// 动态命令对象只保存操作与参数路径；每次执行均新建sequence，结果写本次handle。
	// AIP负责同名BUSY和watchdog；不同TX别名共享sequencer的正常逐事务仲裁。
	class virtio_aip_command extends aip_cmd;
		virtio_txn_type_e	operation;
		string			parameter_path;

		// 显式new才注册，不使用package加载时的静态自动注册副作用。
		function new(string	name, virtio_txn_type_e	op, string	path);
			super.new(name);
			operation = op;
			parameter_path = path;
			background_allowed = 1;
			group = "virtio";
			description = "Virtio sequence command; TX success means submission only";
			param_info = (op == VIO_TXN_SEND_PKTS) ? "count=<positive integer> [wait=0]" : "[wait=0]";
		endfunction

		// 启动前登记使AIP能按调用取消；正常退出注销。取消不能回滚driver在途事务。
		virtual task cmd_exec();
			virtio_aip_sequence	seq;
			string			count_text;
			longint unsigned	parsed_count;
			int			width;

			seq = virtio_aip_sequence::type_id::create(cmd_name);
			seq.operation = operation;
			status = 1;
			// 本适配器只承诺有限count，不用定时强杀模拟time模式；不支持的
			// 参数必须显式失败，防止用户以为time流已跑完而实际只提交一包。
			if (aip_cmd::get_arg(args_in, "time") != "") begin
				result_out = "time is unsupported; vio_tx supports finite count only"; return;
			end
			if (operation != VIO_TXN_SEND_PKTS && aip_cmd::get_arg(args_in, "count") != "") begin
				result_out = "count is supported only by TX commands"; return;
			end
			if (operation == VIO_TXN_SEND_PKTS) begin
				count_text = aip_cmd::get_arg(args_in, "count");
				if (count_text != "") begin
					// str_to_num在64位结果上取负；先拒绝负号，避免巨大负数
					// 回绕成小正数并意外下发事务。此路径返回命令失败，不终止仿真。
					if (aip_str::str_find(count_text, "-") >= 0) begin
						result_out = "count must be a positive integer literal, not a negative value"; return;
					end
					parsed_count = aip_str::str_to_num(count_text, width);
					if (width == 0 || parsed_count == 0 || parsed_count > 32'h7fffffff) begin
						result_out = "count must be a positive 31-bit integer literal"; return;
					end
					seq.count = int'(parsed_count);
				end
			end
			if (!seq.load_params(parameter_path) || !seq.ready_binding()) begin
				result_out = seq.result_text;
				return;
			end
			if (!virtio_aip_registry::acquire(cmd_name, seq.target_path,
				operation == VIO_TXN_SEND_PKTS, result_out)) return;
			aip_cmd_seq_registry::register(cmd_name, seq);
			seq.start(seq.target.driver_agent.sequencer);
			aip_cmd_seq_registry::unregister(cmd_name);
			virtio_aip_registry::release_lease(cmd_name);
			status = seq.ok ? 0 : 1;
			result_out = seq.result_text;
		endtask
	endclass

	// 整组预检名称，避免碰撞后只注册一半；允许先bind或先register，执行时统一预检。
	function bit	virtio_aip_registry::register_commands(output string	why);
		string			names[$] = '{"vio_init", "vio_start", "vio_tx", "vio_wait_rx", "vio_set_mq", "vio_set_rss", "vio_stop", "vio_reset"};
		string			paths[$] = '{"vio", "vio", "vio.tx", "vio.rx", "vio.mq", "vio.rss", "vio", "vio"};
		virtio_txn_type_e	ops[$] = '{VIO_TXN_INIT, VIO_TXN_START_DP, VIO_TXN_SEND_PKTS, VIO_TXN_WAIT_PKTS, VIO_TXN_SET_MQ, VIO_TXN_SET_RSS, VIO_TXN_STOP_DP, VIO_TXN_RESET};
		virtio_aip_command	command;

		why = "";
		foreach (names[i]) begin
			if (aip_cmd::get_handle(names[i]) != null) begin
				why = {"command already registered: ", names[i]}; return 0;
			end
		end
		foreach (names[i]) command = new(names[i], ops[i], paths[i]);
		return 1;
	endfunction

	// 记录外部取消代号；不更改核心 READY，也不把停止等同于设备停止 DMA。
	function void virtio_aip_registry::mark_cancelled(input string name, input longint unsigned generation);
		needs_reset[name] = 1;
		if (!cancelled_generation.exists(name) || generation > cancelled_generation[name])
			cancelled_generation[name] = generation;
	endfunction

	// 核心确认凭证与单调准备代号联合判断，旧代重复确认永远不能解除取消。
	function bit virtio_aip_registry::external_reuse_ready(input string name);
		longint unsigned	generation;
		if (!needs_reset.exists(name) || !needs_reset[name]) return 1;
		if (!target_envs.exists(name) || !targets.exists(name) || !cancelled_generation.exists(name)) return 0;
		generation = target_envs[name].external_service_generation(targets[name].service_key, 1);
		if (generation <= cancelled_generation[name]) return 0;
		needs_reset[name] = 0;
		return 1;
	endfunction

	// 名称整组预检，外部项目不重新注册已移除的设备 reset/init/MQ/RSS 链。
	function bit virtio_aip_registry::register_business_commands(output string why);
		string	names[$] = '{"vio_start", "vio_tx", "vio_wait_rx", "vio_stop"};
		string	paths[$] = '{"vio", "vio.tx", "vio.rx", "vio"};
		virtio_txn_type_e	ops[$] = '{VIO_TXN_START_DP, VIO_TXN_SEND_PKTS, VIO_TXN_WAIT_PKTS, VIO_TXN_STOP_DP};
		virtio_aip_command	command;
		why = "";
		foreach (names[i]) begin
			if (aip_cmd::get_handle(names[i]) != null) begin
				why = {"command already registered: ", names[i]}; return 0;
			end
		end
		foreach (names[i]) command = new(names[i], ops[i], paths[i]);
		return 1;
	endfunction

	// 创建独立TX别名；path不得为空，避免运行期参数意外落到全局命名空间。
	function bit	virtio_aip_registry::register_tx_command(string	name, string	path, output string	why);
		virtio_aip_command	command;

		why = "";
		if (name == "" || path == "" || aip_cmd::get_handle(name) != null) begin
			why = "TX command requires unused nonempty name and parameter path"; return 0;
		end
		command = new(name, VIO_TXN_SEND_PKTS, path);
		return 1;
	endfunction
endpackage
`endif
