// integration/dpu：VIO 与公共 DUT 配置的生命周期连接，不复制表字段或 PCIe 发送实现。
// 借用 sequencer 发布的 dpu_cfg 和各 Host VIO env；实际 setup 始终只由 VIO env 持有。
class vio_dpu_cfg_seq extends dpu_cfg_seq;
	`uvm_object_utils(vio_dpu_cfg_seq)

	// sequence 不拥有 cfg、env 或 ring，构造不产生硬件副作用。
	extern function new(string	name = "vio_dpu_cfg_seq");
	// 默认 body 在公共表之后调用；只准备并导出实际队列。
	extern virtual task prepare_queues(
		output bit		ok,
		output string	why
	);
	// 默认 body 在全部表成功后调用；失败不开放发包。
	extern virtual function void commit_queues(
		output bit		ok,
		output string	why
	);
	// 独立入口与默认 body 复用准备过程；首个 Host 成功后即返回可供失败清理的范围。
	extern task prepare_vio_configuration(
		output dpu_cfg_scope	selection,
		output bit				ok,
		output string			why
	);
	// 全部 Host 预检后确认所选 service，不在 DPU cfg 保存 setup。
	extern function void commit_vio_configuration(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);
	// DUT 已停止 DMA 后释放整 Host 代，随后清除 DPU 导出值。
	extern function void release_vio_resources(
		input dpu_cfg_scope	selection,
		input logic			dut_quiesced,
		output bit			ok,
		output string		why
	);
	// 从实际启动 sequencer 查找 env，支持每个 Host 独立实例。
	extern protected function bit get_env(
		input int unsigned		host_id,
		output virtio_net_env	env,
		output string			why
	);
	// 构造 VIO 本代局部选择并统一预检；不分配 ring 或修改确认状态。
	extern protected function bit get_scopes(
		input dpu_cfg_scope		selection,
		output virtio_net_env	envs[int unsigned],
		output vio_config_scope	scopes[int unsigned],
		output string			why
	);
endclass

// 只构造外壳，资源来自已有 env。
function vio_dpu_cfg_seq::new(string	name);
	super.new(name);
endfunction

// 默认流程复用独立准备入口。
task vio_dpu_cfg_seq::prepare_queues(
	output bit		ok,
	output string	why
);
	prepare_vio_configuration(selection, ok, why);
endtask

// 默认流程复用同一确认入口，保持单一生命周期路径。
function void vio_dpu_cfg_seq::commit_queues(
	output bit		ok,
	output string	why
);
	commit_vio_configuration(selection, ok, why);
endfunction

// config_db 保存借用句柄；缺失时不猜测组件路径或退回其他 Host。
function bit vio_dpu_cfg_seq::get_env(
	input int unsigned		host_id,
	output virtio_net_env	env,
	output string			why
);
	why = $sformatf("PCIe sequencer has no vio_env_h%0d", host_id);
	return m_sequencer != null && uvm_config_db#(virtio_net_env)::get(m_sequencer, "", $sformatf("vio_env_h%0d", host_id), env) && env != null;
endfunction

// 本地准备不发送 TLP；由单个配置 sequence 在写 VIO 表之前调用。
// 所有 Host 的绑定先解析，真实 ring 仅由核心 env 分配；每个成功 Host 在导出前保留释放入口。
// 后续准备/导出失败不自动停 DUT 或释放资源，由调用方确认停机后使用返回的 selection 清理。
task vio_dpu_cfg_seq::prepare_vio_configuration(
	output dpu_cfg_scope	selection,
	output bit				ok,
	output string			why
);
	dpu_vio_qpair_binding_t			pairs[$];
	vio_external_queue_binding_t	bindings[int unsigned][$];
	vio_service_requirement_t		requirement;
	dpu_function_key_t				functions[$];
	int unsigned					bars[$];
	dpu_host_info_t					hosts[$];
	virtio_net_env					envs[int unsigned];
	dpu_vio_queue_t					queues[$];
	dpu_vio_queue_t					all_queues[$];

	ok        = 0;
	selection = null;
	why       = "DPU configuration must be published first";
	if (cfg == null || !cfg.runtime_ready) return;
	cfg.device_snapshot.list_hosts(hosts);
	foreach (hosts[i]) begin
		if (!get_env(hosts[i].host_id, envs[hosts[i].host_id], why)) return;
		if (envs[hosts[i].host_id].get_external_setup() != null) begin
			why = "release existing VIO generation before reprepare";
			return;
		end
	end
	cfg.resource_snapshot.list_vio_bindings(pairs);
	foreach (pairs[p]) begin
		int unsigned	h;

		h = pairs[p].service_key.function_key.host_id;
		if (!envs[h].cfg.resolve_final_service_requirement(pairs[p].service_key, requirement, why))
			return;
		for (int	direction = 0; direction < 2; direction++) begin
			vio_external_queue_binding_t	b;
			bit [64:0]						offset;
			bit								message_found;
			dpu_priv_driver_config			private_cfg;
			dpu_priv_queue_config			private_queue;

			if ((direction == 0 && !requirement.rx_enable) || (direction == 1 && !requirement.tx_enable))
				continue;
			b.service_key = pairs[p].service_key;
			b.local_qid = direction == 0 ? pairs[p].rx_local_virtqueue_id : pairs[p].tx_local_virtqueue_id;
			private_cfg = envs[h].cfg.get_dpu_private_config(b.service_key);
			private_queue = null;
			if (requirement.behavior.vq_type == VQ_CUSTOM && private_cfg != null)
				private_queue = private_cfg.resolve_queue(b.local_qid);
			if (!requirement.notify_layout_valid && (private_queue == null || !private_queue.notify_offset_present)) begin
				why = "service/queue has no explicit doorbell binding";
				return;
			end
			offset = {1'b0, requirement.notify_base} + 65'(b.local_qid) * {1'b0, requirement.notify_stride};
			if (offset[64]) begin
				why = "doorbell offset overflow";
				return;
			end
			b.notify_bar    = requirement.notify_bar;
			b.notify_offset = offset[63:0];
			if (private_queue != null) begin
				if (private_queue.notify_bar_present) b.notify_bar = private_queue.notify_bar;
				if (private_queue.notify_offset_present)
					b.notify_offset = private_queue.notify_offset;
			end
			b.notify_encoding = requirement.notify_encoding;
			b.local_vector    = pairs[p].local_msix_vector_id;
			b.global_vector   = pairs[p].global_msix_vector_id;
			b.msix_valid      = 0;
			b.message_address = 0;
			b.message_data    = 0;
			b.masked          = 0;
			message_found     = 0;
			foreach (cfg.frozen_messages[m]) begin
				if (dpu_same_function_key(cfg.frozen_messages[m].owner, b.service_key.function_key) && cfg.frozen_messages[m].local_vector == b.local_vector) begin
					if (cfg.frozen_messages[m].global_vector != b.global_vector) begin
						why = "public vector disagrees with qpair binding";
						return;
					end
					message_found     = 1;
					b.msix_valid      = 1;
					b.message_address = cfg.frozen_messages[m].address;
					b.message_data    = cfg.frozen_messages[m].data;
					b.masked          = cfg.frozen_messages[m].masked;
				end
			end
			if (requirement.completion_mode == VIRTIO_COMPLETION_MSIX && !message_found) begin
				why = "MSI-X service has no frozen public message";
				return;
			end
			bindings[h].push_back(b);
		end
	end
	foreach (bindings[h]) begin
		vio_external_setup	setup;

		envs[h].prepare_external_configuration(bindings[h], setup, ok, why);
		if (!ok) return;
		// 首个成功 Host 已拥有 ring，不能等全部 Host 导出成功才交付清理范围。
		// get_scopes 只选当前实际存在的代，因此失败 Host 尚无 setup 时不会参与释放。
		if (selection == null) selection = new("vio_scope", cfg.device_snapshot, functions, bars);
		if (!envs[h].export_dpu_queues(setup, null, queues, why)) begin
			ok = 0;
			return;
		end
		foreach (queues[q]) all_queues.push_back(queues[q]);
	end
	// 表布局/策略生成失败同样保留已交付的清理范围；空配置仍返回 null。
	ok = cfg.set_queues(all_queues, why);
endtask

// 全部 Host 检查通过后才允许确认或释放；空 Host 不扩大为该 Host 的全部 service。
function bit vio_dpu_cfg_seq::get_scopes(
	input dpu_cfg_scope		selection,
	output virtio_net_env	envs[int unsigned],
	output vio_config_scope	scopes[int unsigned],
	output string			why
);
	dpu_host_info_t		hosts[$];
	dpu_service_key_t	keys[$];
	vio_queue_setup_t	queues[$];
	bit					seen[string];
	virtio_net_env		env;
	vio_external_setup	setup;

	envs.delete();
	scopes.delete();
	if (selection == null || !selection.validate(cfg.device_snapshot, why)) return 0;
	cfg.device_snapshot.list_hosts(hosts);
	foreach (hosts[i]) begin
		if (!get_env(hosts[i].host_id, env, why)) return 0;
		setup = env.get_external_setup();
		if (setup == null) continue;
		setup.list_queues(queues);
		keys.delete();
		seen.delete();
		foreach (queues[q]) begin
			if (!selection.selects_service(queues[q].service_key) || seen.exists(dpu_service_key_name(queues[q].service_key)))
				continue;
			seen[dpu_service_key_name(queues[q].service_key)] = 1;
			keys.push_back(queues[q].service_key);
		end
		if (keys.size() == 0) continue;
		scopes[hosts[i].host_id] = new("vio_scope", setup, keys);
		if (!env.preflight_external_configuration(setup, scopes[hosts[i].host_id], why)) return 0;
		envs[hosts[i].host_id] = env;
	end
	why = "selection has no live VIO queues";
	if (envs.num() == 0) return 0;
	why = "";
	return 1;
endfunction

// 所选队列全部预检成功才逐 Host 确认；核心保留实际 ring 的最终一致性检查。
function void vio_dpu_cfg_seq::commit_vio_configuration(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	virtio_net_env		envs[int unsigned];
	vio_config_scope	scopes[int unsigned];

	ok = 0;
	if (!get_scopes(selection, envs, scopes, why)) return;
	foreach (envs[h])
	if (!envs[h].confirm_external_configuration(envs[h].get_external_setup(), scopes[h], 1, why))
		return;
	ok  = 1;
	why = "";
endfunction

// 只允许整 Host 的当前代释放；先检查所有选择，失败不释放任何一个 Host。
function void vio_dpu_cfg_seq::release_vio_resources(
	input dpu_cfg_scope	selection,
	input logic			dut_quiesced,
	output bit			ok,
	output string		why
);
	virtio_net_env		envs[int unsigned];
	vio_config_scope	scopes[int unsigned];
	vio_queue_setup_t	queues[$];

	ok  = 0;
	why = "release needs explicit platform quiescence";
	if (dut_quiesced !== 1'b1 || !get_scopes(selection, envs, scopes, why)) return;
	foreach (envs[h]) begin
		envs[h].get_external_setup().list_queues(queues);
		foreach (queues[q])
		if (!scopes[h].selects(queues[q].service_key)) begin
			why = "release must select complete Host generation";
			return;
		end
		if (!envs[h].preflight_external_configuration(envs[h].get_external_setup(), null, why))
			return;
	end
	foreach (envs[h]) begin
		if (!envs[h].release_external_resources(envs[h].get_external_setup(), dut_quiesced, why))
			return;
		cfg.clear_host_queues(h);
	end
	ok  = 1;
	why = "";
endfunction
