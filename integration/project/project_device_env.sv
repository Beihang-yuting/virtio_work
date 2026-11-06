// integration/project：DPU 解析完成后的 PCIe/VIO 组装层，由 project_env_pkg 包含。
// 依赖 dpu_device_env、pcie_dpu_cfg_adapter、pcie_tl_env 和 virtio_net_env。
// 本层继承 DPU 生命周期以保证 super.build_phase 先发布冻结快照，再创建消费者；
// VIO 本身不继承 DPU，也不再次分配 Host/PF/VF、BDF、BAR 或 qpair。
// 组件归 UVM 所有；project_cfg、共享内存、外部 VIF/backend 均为借用句柄。
class project_device_env extends dpu_device_env;
    `uvm_component_utils(project_device_env)

    project_env_cfg	cfg;
    pcie_global_cfg	projected_pcie_cfg;
    pcie_tl_env		pcie_env;
    virtio_net_env	vio_envs[int unsigned];
    // 仅默认 executor 使用该 backend；平台注入 executor 时由平台负责连接它。
    pcie_tl_dpu_reg_backend	reg_backend;

    // 构造组件壳；配置与快照在 build 中获取，不在 new 中访问父组件。
    function new(string	name, uvm_component	parent);
        super.new(name, parent);
    endfunction

    // 对外汇总配置错误；保留全部适配器诊断，任一错误阻止创建 PCIe 子环境。
    protected function void require_no_errors(string	stage, string	errors[$]);
        string	message;

        message = stage;
        foreach (errors[i]) message = {message, "; ", errors[i]};
        if (errors.size() != 0) `uvm_fatal("PROJECT_DEVICE", message)
    endfunction

    // 将 DPU 的冻结身份/地址/资源投影到 PCIe；只从 hw cfg 复制物理链路策略。
    // 不使用 hw cfg 的 device images 覆盖快照；Root 内存绑定在 PCIe build 前完成。
    protected function void project_pcie_config();
        pcie_dpu_cfg_adapter	adapter;
        pcie_dpu_system_cfg	policy;
        host_mem_manager	manager;
        string			errors[$];
        string			why;

        adapter = pcie_dpu_cfg_adapter::type_id::create("dpu_to_pcie");
        if (!adapter.project_with_root_bindings(get_snapshot(), get_resource_snapshot(),
                cfg.pcie_hw_cfg.topology, cfg.attachments, cfg.root_bindings,
                projected_pcie_cfg, errors)) begin
            require_no_errors("DPU to PCIe projection failed", errors);
            `uvm_fatal("PROJECT_DEVICE", "DPU to PCIe projection returned no configuration")
        end
        policy = pcie_dpu_system_cfg::type_id::create("pcie_link_policy");
        policy.pcie_policy = cfg.pcie_hw_cfg;
        // 当前 helper 不复制此开关，必须在 helper 的 validate 之前显式传递。
        projected_pcie_cfg.svt_bridge_enable = cfg.pcie_hw_cfg.svt_bridge_enable;
        if (!policy.apply_pcie_policy(projected_pcie_cfg, errors))
            require_no_errors("PCIe physical policy failed", errors);

        foreach (cfg.root_bindings.bindings[i]) begin
            pcie_dpu_root_binding	binding;

            binding = cfg.root_bindings.bindings[i];
            if (!cfg.host_mem_pool_binding.has_host(binding.host_id))
                `uvm_fatal("PROJECT_DEVICE", "Root refers to a Host without shared memory")
            manager = cfg.host_mem_pool_binding.get_host(binding.host_id);
            if (cfg.pcie_cfg.host_mem_by_root.exists(binding.root_index)) begin
                if ((cfg.pcie_cfg.host_mem_by_root[binding.root_index] != manager) ||
                    !cfg.pcie_cfg.host_id_by_root.exists(binding.root_index) ||
                    (cfg.pcie_cfg.host_id_by_root[binding.root_index] != binding.host_id))
                    `uvm_fatal("PROJECT_DEVICE", "pre-bound PCIe memory disagrees with DPU Host owner")
            end else if (!cfg.pcie_cfg.bind_host_memory(
                    binding.root_index, binding.host_id, manager, why))
                `uvm_fatal("PROJECT_DEVICE", why)
        end
    endfunction

    // 必须先调用 DPU build：它唯一执行 resolver 并发布 device/resource/manager。
    // 子 VIO 继承 config_db 的快照发布范围；每 Host 只收到自己的行为 cfg。
    virtual function void build_phase(uvm_phase	phase);
        if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg) || cfg == null)
            `uvm_fatal("PROJECT_DEVICE", "project_cfg is missing")
        super.build_phase(phase);
        project_pcie_config();

        uvm_config_db#(pcie_global_cfg)::set(this, "pcie_env", "global_cfg", projected_pcie_cfg);
        uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "cfg", cfg.pcie_cfg);
        uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "tl_policy_cfg", cfg.pcie_cfg);
        if (cfg.backend_factory != null)
            uvm_config_db#(pcie_tl_backend_factory)::set(
                this, "pcie_env", "pcie_tl_backend_factory", cfg.backend_factory);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        foreach (cfg.vio_cfg_by_host[h]) begin
            string	child_name;

            child_name = $sformatf("vio_h%0d", h);
            uvm_config_db#(virtio_net_env_config)::set(this, child_name, "cfg", cfg.vio_cfg_by_host[h]);
            vio_envs[h] = virtio_net_env::type_id::create(child_name, this);
        end
    endfunction

    // 根据规范物理节点顺序找到 EP 槽位；禁止把 Function 下标当成 EP 下标。
    // 无对应节点返回 -1，调用者据此拒绝错误 attachment。
    protected function int find_ep_slot(string	node_id);
        if (pcie_env.topology_adapter == null) return -1;
        if (pcie_env.cfg.switch_enable) begin
            foreach (pcie_env.topology_adapter.switch_ep_node_ids[i])
                if (pcie_env.topology_adapter.switch_ep_node_ids[i] == node_id) return i;
        end else begin
            foreach (pcie_env.topology_adapter.direct_ep_node_ids[i])
                if (pcie_env.topology_adapter.direct_ep_node_ids[i] == node_id) return i;
        end
        return -1;
    endfunction

    // 统一数组和单 EP 的历史接口。provider 可能刻意不创建 DUT 一侧的 agent，
    // 因而 null EP monitor 是合法的；Root driver/sequencer 则必须存在。
    protected function pcie_tl_base_monitor ep_monitor_at(int	slot);
        if (pcie_env.ep_agents.size() != 0) begin
            if (slot >= 0 && slot < pcie_env.ep_agents.size() && pcie_env.ep_agents[slot] != null)
                return pcie_env.ep_agents[slot].monitor;
            return null;
        end
        if (slot == 0 && pcie_env.ep_agent != null) return pcie_env.ep_agent.monitor;
        return null;
    endfunction

    // native SV_IF 每个方向显式注入接口；provider 自己管理 HDL/SVT 接口。
    // 该参考实现不替平台实例化 Serial/SVT VIP，也不重连 provider-owned adapter。
    protected function void bind_native_vifs();
        if (pcie_env.backend_provider_active || pcie_env.cfg.if_mode != SV_IF_MODE) return;
        foreach (pcie_env.rc_adapters[r]) begin
            if (pcie_env.rc_adapters[r] == null) continue;
            if (!cfg.rc_vifs.exists(r) || cfg.rc_vifs[r] == null)
                `uvm_fatal("PROJECT_DEVICE", $sformatf("missing native RC VIF for Root%0d", r))
            pcie_env.rc_adapters[r].vif = cfg.rc_vifs[r];
        end
        foreach (cfg.pcie_hw_cfg.topology.nodes[n]) begin
            string	node_id;
            int		slot;

            if (cfg.pcie_hw_cfg.topology.nodes[n].kind != PCIE_TOPO_NODE_EP) continue;
            node_id = cfg.pcie_hw_cfg.topology.nodes[n].node_id;
            slot = find_ep_slot(node_id);
            if (slot < 0) continue;
            if (!cfg.ep_vifs.exists(node_id) || cfg.ep_vifs[node_id] == null)
                `uvm_fatal("PROJECT_DEVICE", {"missing native EP VIF for ", node_id})
            if (pcie_env.ep_adapters.size() != 0) begin
                if (slot >= pcie_env.ep_adapters.size() || pcie_env.ep_adapters[slot] == null)
                    `uvm_fatal("PROJECT_DEVICE", "physical EP has no native adapter")
                pcie_env.ep_adapters[slot].vif = cfg.ep_vifs[node_id];
            end else begin
                if (slot != 0 || pcie_env.ep_adapter == null)
                    `uvm_fatal("PROJECT_DEVICE", "single EP has no native adapter")
                pcie_env.ep_adapter.vif = cfg.ep_vifs[node_id];
            end
        end
    endfunction

    // 全项目统一分配协议监测接口，并在任何 VIO bind 前检查跨 Host 句柄复用。
    // cfg 已登记的身份优先；否则使用显式池或兼容 top 的全局 slot 池。
    protected function void bind_protocol_vifs();
        virtual virtio_protocol_event_if	used[$];
        virtual virtio_protocol_event_if	vif;
        int unsigned				slot;
        string					why;

        slot = 0;
        foreach (vio_envs[h]) begin
            foreach (vio_envs[h].function_instances[i]) begin
                virtio_function_instance	f;

                f = vio_envs[h].function_instances[i];
                if (!cfg.vio_cfg_by_host[h].get_protocol_event_vif(f.pcie_id, vif)) begin
                    if (cfg.protocol_vifs.size() != 0) begin
                        if (slot >= cfg.protocol_vifs.size())
                            `uvm_fatal("PROJECT_DEVICE", "protocol VIF pool is too small")
                        vif = cfg.protocol_vifs[slot];
                    end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                            null, "uvm_test_top", $sformatf("protocol_event_vif_%0d", slot), vif))
                        `uvm_fatal("PROJECT_DEVICE", "global protocol VIF slot is missing")
                    if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why))
                        `uvm_fatal("PROJECT_DEVICE", why)
                end
                foreach (used[j]) begin
                    if (used[j] == vif)
                        `uvm_fatal("PROJECT_DEVICE", "protocol VIF reused by distinct Functions/Hosts")
                end
                used.push_back(vif);
                slot++;
            end
        end
    endfunction

    // 用 Function 的完整身份找到 domain→Root 与 Function→物理 EP，统一连接 VIO。
    // child connect 已完成，故 sequencer/driver/monitor 均可使用；失败立即停止。
    virtual function void connect_phase(uvm_phase	phase);
        string	why;

        super.connect_phase(phase);
        bind_native_vifs();
        bind_protocol_vifs();
        if (reg_backend != null) begin
            reg_backend.bind_virtual_sequencer(pcie_env.v_seqr);
            foreach (cfg.root_bindings.bindings[i]) begin
                pcie_dpu_root_binding	b;

                b = cfg.root_bindings.bindings[i];
                reg_backend.bind_domain_root(b.host_id, b.segment_id, b.root_index);
            end
        end
        foreach (vio_envs[h]) begin
            virtio_pcie_function_endpoint	endpoints[$];

            foreach (vio_envs[h].function_instances[i]) begin
                virtio_function_instance	f;
                virtio_pcie_function_endpoint	endpoint;
                int unsigned			root;
                int				ep_slot;
                string				node_id;
                string				link_id;
                bit				has_fn_num;
                int unsigned			fn_num;

                f = vio_envs[h].function_instances[i];
                if (!cfg.root_bindings.find_root(f.pcie_id.domain.host_id,
                        f.pcie_id.domain.segment_id, root))
                    `uvm_fatal("PROJECT_DEVICE", "VIO domain has no Root binding")
                if (!cfg.attachments.find_by_function(f.service_key.function_key,
                        node_id, link_id, has_fn_num, fn_num))
                    `uvm_fatal("PROJECT_DEVICE", "VIO Function has no physical attachment")
                ep_slot = find_ep_slot(node_id);
                if (ep_slot < 0 || pcie_env.configured_ep_root_index(ep_slot, -1) != int'(root))
                    `uvm_fatal("PROJECT_DEVICE", "VIO physical EP/Root mapping disagrees")
                if (root >= pcie_env.rc_agents.size() || pcie_env.rc_agents[root] == null)
                    `uvm_fatal("PROJECT_DEVICE", "VIO requires a VIP-owned RC for its Root")
                endpoint = virtio_pcie_function_endpoint::type_id::create(
                    $sformatf("endpoint_h%0d_f%0d", h, i));
                endpoint.configure(f.pcie_id, pcie_env.rc_agents[root].sequencer,
                    pcie_env.rc_agents[root].rc_driver, cfg.completion_adapter,
                    pcie_env.rc_agents[root].monitor, ep_monitor_at(ep_slot));
                endpoints.push_back(endpoint);
            end
            if (!vio_envs[h].bind_pcie_endpoints(endpoints))
                `uvm_fatal("PROJECT_DEVICE", "VIO endpoint binding failed")
        end
    endfunction

    // 平台确认 reset/link/DMA 服务就绪后调用一次；计划已包含 bootstrap，不能
    // 先单独 apply_bootstrap 再重复执行。失败报告保留 DPU 状态与具体操作原因。
    task configure_device();
        dpu_reg_plan		plan;
        dpu_execution_report	report;
        string			why;

        if (!build_vio_register_plan(plan, why)) `uvm_fatal("PROJECT_DEVICE", why)
        apply_vio_register_plan(plan, report);
        if (report == null) `uvm_fatal("PROJECT_DEVICE", "DPU returned no execution report")
        if (report.status() != DPU_CFG_STATUS_SUCCEEDED)
            `uvm_fatal("PROJECT_DEVICE", report.reason())
    endtask

    // 所有 Host 先登记完整 service 身份，再统一注册命令；空 Host 合法，全局空拒绝。
    // 每个仿真只调用一次；TX 提交与业务完成的区别由平台 finish/check 负责收口。
    function void register_aip_commands();
        int unsigned	active_hosts;
        string		why;

        active_hosts = 0;
        foreach (vio_envs[h]) begin
            if (vio_envs[h].function_instances.size() == 0) continue;
            if (!virtio_aip_registry::bind_env(vio_envs[h], why))
                `uvm_fatal("PROJECT_DEVICE", why)
            active_hosts++;
        end
        if (active_hosts == 0) `uvm_fatal("PROJECT_DEVICE", "no VIO service available for AIP")
        if (!virtio_aip_registry::register_commands(why))
            `uvm_fatal("PROJECT_DEVICE", why)
    endfunction
endclass
