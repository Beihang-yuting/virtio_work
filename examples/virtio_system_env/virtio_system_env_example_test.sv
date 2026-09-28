// 目录层次：examples/virtio_system_env，仅由示例 filelist 显式编译，不进入默认 VIP 包。
// 职责：在同一示例文件中演示系统配置、DPU/virtio/可选 PCIe 层次组装及双 Host 资源检查。
// 依赖：预先编译的 UVM、host_mem、pcie_tl、dpu_resource 与 virtio_net 包。
// 所有权与生命周期：测试持有配置，UVM 管理组件至仿真结束；DPU 独占拓扑解析与快照发布，
// 系统环境持有共享内存池，池管理每个 Host 的内存管理器；外部传入的配置和池仅共享句柄。
// 本示例不发送 PCIe 流量、不模拟复位；配置在 build 阶段完成，run 阶段只读取已冻结快照。

`ifndef VIRTIO_SYSTEM_ENV_EXAMPLE_TEST_SV
`define VIRTIO_SYSTEM_ENV_EXAMPLE_TEST_SV

// Example-local top-level configuration, environment, and executable test.
// Compile this file explicitly after virtio_net_pkg; it is not part of the
// default VIP package or maintained regression filelist.
import uvm_pkg::*;
`include "uvm_macros.svh"
import host_mem_pkg::*;
import pcie_tl_pkg::*;
import dpu_resource_pkg::*;
import virtio_net_pkg::*;


// Authoring boundary for the complete virtio verification hierarchy.
//
// dpu_cfg is the only owner of device topology and resource placement.  The
// virtio configurations below contain driver behavior only.  Keeping these
// objects together gives a test one stable place to edit while preserving the
// ownership boundary enforced by dpu_device_env.
// 配置层把拓扑入口和驱动行为集中供测试编写，但保留 DPU 对拓扑/资源的唯一解析权，避免双份配置漂移。
class virtio_system_env_config extends uvm_object;
    `uvm_object_utils(virtio_system_env_config)

    // Global DPU authoring and resolver policy.
    dpu_device_env_config dpu_cfg;

    // Single-host convenience configuration.  For more than one Host, fill
    // vio_cfg_by_host explicitly so every child has an unambiguous scope.
    virtio_net_env_config default_vio_cfg;
    virtio_net_env_config vio_cfg_by_host[int unsigned];

    // Optional PCIe TL environment.  Keeping it nullable allows MODEL-only
    // unit environments to use the same top-level configuration object.
    pcie_tl_env_config pcie_cfg;
    bit create_pcie_env = 0;

    // A caller may provide a pre-created pool.  When null, the top environment
    // creates one and owns its Host managers for the lifetime of the UVM run.
    host_mem_pool host_mem_pool_binding;
    bit auto_create_host_memory = 1;
    bit use_dpu_gpa_aperture = 1;
    alloc_mode_e host_mem_mode = MODE_BUDDY;
    int unsigned host_mem_granule = DEFAULT_MIN_GRANULE;

    // Optional explicit Host order.  Empty means derive the set from
    // dpu_cfg.device_cfg.hosts; order affects only component names/logging.
    int unsigned host_ids[$];

    // 按名称创建 DPU 和默认单 Host 行为配置；可选 PCIe 与外部内存池保持空句柄，供调用方后续填写。
    function new(string name = "virtio_system_env_config");
        super.new(name);
        dpu_cfg = dpu_device_env_config::type_id::create({name, "_dpu_cfg"});
        default_vio_cfg = virtio_net_env_config::type_id::create(
            {name, "_default_vio_cfg"});
        pcie_cfg = null;
        host_mem_pool_binding = null;
    endfunction

    // Register a per-Host behavior configuration.  The caller retains
    // ownership of the object; the top environment only borrows the handle.
    // 登记 host_id 对应的借用配置句柄，成功返回 1；空配置、身份不符或重复登记返回 0 并填写 why，不修改映射。
    function bit set_host_vio_config(
        input int unsigned host_id,
        input virtio_net_env_config host_cfg,
        output string why
    );
        why = "";
        if (host_cfg == null) begin
            why = $sformatf("Host %0d virtio configuration is null", host_id);
            return 0;
        end
        if (host_cfg.host_id != host_id) begin
            why = $sformatf(
                "Host %0d virtio configuration carries host_id=%0d",
                host_id, host_cfg.host_id);
            return 0;
        end
        if (vio_cfg_by_host.exists(host_id)) begin
            why = $sformatf("Host %0d virtio configuration already exists", host_id);
            return 0;
        end
        vio_cfg_by_host[host_id] = host_cfg;
        return 1;
    endfunction

    // 追加显式 Host 构建顺序；重复 ID 返回 0 和 why，成功返回 1；是否存在于 DPU 拓扑由 validate 检查。
    function bit add_host_id(input int unsigned host_id, output string why);
        why = "";
        foreach (host_ids[index]) begin
            if (host_ids[index] == host_id) begin
                why = $sformatf("duplicate top-level Host id %0d", host_id);
                return 0;
            end
        end
        host_ids.push_back(host_id);
        return 1;
    endfunction

    // Return whether a Host identity is present in the DPU authoring object.
    // The top-level environment may intentionally select a subset through
    // host_ids, but it must never manufacture a Host which the resolver does
    // not know about.
    // 只读查找 DPU 声明的 Host 身份，避免系统层凭空新增拓扑；配置缺失或未找到返回 0，找到返回 1。
    function bit host_is_declared(input int unsigned host_id);
        if ((dpu_cfg == null) || (dpu_cfg.device_cfg == null))
            return 0;
        foreach (dpu_cfg.device_cfg.hosts[index]) begin
            if ((dpu_cfg.device_cfg.hosts[index] != null) &&
                (dpu_cfg.device_cfg.hosts[index].host_id == host_id))
                return 1;
        end
        return 0;
    endfunction

    // Resolve the Host set without mutating the authoring object.  This keeps
    // validation usable before UVM build_phase and avoids hidden topology.
    // 清空并输出待构建 Host 队列，优先显式顺序，否则从 DPU 拓扑提取；空集合、空条目或重复 ID 返回 0 和 why。
    // 不修改源拓扑；失败时 ids 可能含已收集的部分结果，调用方必须检查返回值。
    function bit collect_host_ids(output int unsigned ids[$], output string why);
        ids.delete();
        why = "";
        if (host_ids.size() != 0) begin
            foreach (host_ids[index]) begin
                foreach (ids[prior]) begin
                    if (ids[prior] == host_ids[index]) begin
                        why = $sformatf("duplicate top-level Host id %0d",
                                       host_ids[index]);
                        return 0;
                    end
                end
                ids.push_back(host_ids[index]);
            end
        end else begin
            if ((dpu_cfg == null) || (dpu_cfg.device_cfg == null)) begin
                why = "top-level DPU device configuration is null";
                return 0;
            end
            foreach (dpu_cfg.device_cfg.hosts[index]) begin
                if (dpu_cfg.device_cfg.hosts[index] == null) begin
                    why = $sformatf("DPU Host entry %0d is null", index);
                    return 0;
                end
                foreach (ids[prior]) begin
                    if (ids[prior] == dpu_cfg.device_cfg.hosts[index].host_id) begin
                        why = $sformatf("duplicate DPU Host id %0d",
                                       dpu_cfg.device_cfg.hosts[index].host_id);
                        return 0;
                    end
                end
                ids.push_back(dpu_cfg.device_cfg.hosts[index].host_id);
            end
        end
        if (ids.size() == 0) begin
            why = "top-level DPU configuration declares no Host";
            return 0;
        end
        return 1;
    endfunction

    // 按 host_id 借用显式行为配置；仅当声明/选择的 Host 数不超过 1 时回退默认配置，并更新其 host_id。
    // 多 Host 缺少显式配置时返回 null，防止不同 Host 无意共享默认配置的可变状态。
    function virtio_net_env_config get_host_vio_config(
        input int unsigned host_id
    );
        int unsigned declared_host_count;

        if (vio_cfg_by_host.exists(host_id))
            return vio_cfg_by_host[host_id];
        declared_host_count = 0;
        if (host_ids.size() != 0)
            declared_host_count = host_ids.size();
        else if ((dpu_cfg != null) && (dpu_cfg.device_cfg != null)) begin
            foreach (dpu_cfg.device_cfg.hosts[index]) begin
                if (dpu_cfg.device_cfg.hosts[index] != null)
                    declared_host_count++;
            end
        end
        if ((declared_host_count <= 1) && (default_vio_cfg != null)) begin
            default_vio_cfg.host_id = host_id;
            return default_vio_cfg;
        end
        return null;
    endfunction

    // 在构建前检查 DPU 配置、Host 身份映射和可选 PCIe 配置，首个错误写入 why 并返回 0。
    // 成功返回 1；通过默认配置回退时可能更新其 host_id；资源放置是否合法仍由 DPU 解析器判断。
    function bit validate(output string why);
        int unsigned ids[$];

        why = "";
        if (dpu_cfg == null) begin
            why = "virtio_system_env_config.dpu_cfg is null";
            return 0;
        end
        if ((dpu_cfg.device_cfg == null) ||
            (dpu_cfg.placement_cfg == null)) begin
            why = "DPU device/placement authoring configuration is incomplete";
            return 0;
        end
        if (!collect_host_ids(ids, why))
            return 0;
        foreach (ids[index]) begin
            virtio_net_env_config host_cfg;

            if (!host_is_declared(ids[index])) begin
                why = $sformatf(
                    "top-level Host %0d is not declared in dpu_cfg.device_cfg.hosts",
                    ids[index]);
                return 0;
            end
            host_cfg = get_host_vio_config(ids[index]);
            if (host_cfg == null) begin
                why = $sformatf(
                    "Host %0d has no virtio_net_env_config; set vio_cfg_by_host[%0d]",
                    ids[index], ids[index]);
                return 0;
            end
            if (host_cfg.host_id != ids[index]) begin
                why = $sformatf(
                    "Host %0d virtio config has host_id=%0d",
                    ids[index], host_cfg.host_id);
                return 0;
            end
        end
        // Associative-map writes are public for convenience, so validate them
        // even when the caller bypassed set_host_vio_config().  A typo here
        // would otherwise leave an unused configuration object that hides the
        // missing behavior for the intended Host.
        foreach (vio_cfg_by_host[map_host_id]) begin
            if (!host_is_declared(map_host_id)) begin
                why = $sformatf(
                    "vio_cfg_by_host contains undeclared Host %0d",
                    map_host_id);
                return 0;
            end
            if (vio_cfg_by_host[map_host_id] == null) begin
                why = $sformatf(
                    "vio_cfg_by_host[%0d] is null", map_host_id);
                return 0;
            end
            if (vio_cfg_by_host[map_host_id].host_id != map_host_id) begin
                why = $sformatf(
                    "vio_cfg_by_host[%0d] carries host_id=%0d",
                    map_host_id, vio_cfg_by_host[map_host_id].host_id);
                return 0;
            end
        end
        if (create_pcie_env && (pcie_cfg == null)) begin
            why = "create_pcie_env is set but pcie_cfg is null";
            return 0;
        end
        return 1;
    endfunction
endclass : virtio_system_env_config

// Short name used by tests that prefer the conventional *_cfg suffix.
typedef virtio_system_env_config virtio_system_env_cfg;

// Hierarchical assembly root for DPU, virtio-net and optional PCIe TL VIPs.
// dpu_device_env owns topology/resource resolution. Every virtio child is
// created below it so the child receives the exact frozen snapshot pair that
// dpu_device_env publishes through uvm_config_db. This root owns one
// host_mem_pool and creates exactly one manager per logical Host.
// 组装层把 virtio 放在 DPU 之下，以复用父层发布的同一对冻结快照；内存池则在 Host 间集中登记、分别管理。
// 外部池可被借用，故本层只补齐缺失管理器，不替换调用方已有的管理器。
class virtio_system_env extends uvm_env;
    `uvm_component_utils(virtio_system_env)

    virtio_system_env_config cfg;
    dpu_device_env dpu_env;
    virtio_net_env virtio_envs[int unsigned];
    pcie_tl_env pcie_env;
    host_mem_pool host_mem_pool_ref;

    protected int unsigned active_host_ids[$];
    protected bit configuration_valid;

    // 向 UVM 注册 name/parent 组件关系并初始化借用句柄和有效标志；资源分配延后到 build_phase。
    function new(string name, uvm_component parent);
        super.new(name, parent);
        cfg = null;
        dpu_env = null;
        pcie_env = null;
        host_mem_pool_ref = null;
        configuration_valid = 0;
    endfunction

    // 从系统配置查找 Host 原始声明并返回共享句柄；任一上级配置缺失或身份未找到均返回 null，不创建对象。
    protected function dpu_host_cfg find_host_cfg(input int unsigned host_id);
        if ((cfg == null) || (cfg.dpu_cfg == null) ||
            (cfg.dpu_cfg.device_cfg == null))
            return null;
        foreach (cfg.dpu_cfg.device_cfg.hosts[index]) begin
            if ((cfg.dpu_cfg.device_cfg.hosts[index] != null) &&
                (cfg.dpu_cfg.device_cfg.hosts[index].host_id == host_id))
                return cfg.dpu_cfg.device_cfg.hosts[index];
        end
        return null;
    endfunction

    // Prefer a DPU Host GPA aperture when one was authored. Otherwise use the
    // per-Host virtio behavior aperture.
    // 输出指定 Host 的内存范围与分配策略：策略来自 virtio 配置，启用且存在 DPU GPA 窗口时优先采用该范围。
    // 否则采用 virtio 范围；缺少行为配置或 base_addr >= end_addr 返回 0 和 why，成功返回 1。
    protected function bit get_host_memory_region(
        input int unsigned host_id,
        input virtio_net_env_config host_vio_cfg,
        output bit [63:0] base_addr,
        output bit [63:0] end_addr,
        output host_mem_alloc_policy_e policy,
        output string why
    );
        dpu_host_cfg host_cfg;

        why = "";
        base_addr = '0;
        end_addr = '0;
        policy = HOST_MEM_RANDOM;
        if (host_vio_cfg == null) begin
            why = $sformatf("Host %0d has no virtio configuration", host_id);
            return 0;
        end
        policy = host_vio_cfg.host_mem_policy;
        host_cfg = find_host_cfg(host_id);
        if (cfg.use_dpu_gpa_aperture && (host_cfg != null) &&
            host_cfg.has_gpa_aperture) begin
            base_addr = host_cfg.gpa_base;
            end_addr = host_cfg.gpa_limit;
        end else begin
            base_addr = host_vio_cfg.mem_base;
            end_addr = host_vio_cfg.mem_end;
        end
        if (base_addr >= end_addr) begin
            why = $sformatf(
                "Host %0d memory aperture is invalid [0x%016h,0x%016h]",
                host_id, base_addr, end_addr);
            return 0;
        end
        return 1;
    endfunction

    // 借用外部池或创建系统池，并确保每个 active_host_ids 都有身份正确的管理器，成功返回 1。
    // 禁止自动创建且管理器缺失、范围非法或创建失败时返回 0 和 why；已有管理器保留，部分创建不回滚。
    protected function bit prepare_host_memory(output string why);
        why = "";
        if (cfg.host_mem_pool_binding == null)
            host_mem_pool_ref = host_mem_pool::type_id::create("host_mem_pool");
        else
            host_mem_pool_ref = cfg.host_mem_pool_binding;
        if (host_mem_pool_ref == null) begin
            why = "could not create or obtain the shared host_mem_pool";
            return 0;
        end

        foreach (active_host_ids[index]) begin
            int unsigned host_id;
            virtio_net_env_config host_vio_cfg;
            bit [63:0] base_addr;
            bit [63:0] end_addr;
            host_mem_alloc_policy_e policy;
            host_mem_manager manager;

            host_id = active_host_ids[index];
            host_vio_cfg = cfg.get_host_vio_config(host_id);
            if (!get_host_memory_region(host_id, host_vio_cfg,
                                        base_addr, end_addr, policy, why))
                return 0;
            if (!host_mem_pool_ref.has_host(host_id)) begin
                if (!cfg.auto_create_host_memory) begin
                    why = $sformatf(
                        "Host %0d has no manager and auto_create_host_memory is disabled",
                        host_id);
                    return 0;
                end
                if (!host_mem_pool_ref.create_host(
                        host_id, base_addr, end_addr, cfg.host_mem_mode,
                        cfg.host_mem_granule, policy)) begin
                    why = $sformatf("could not create shared Host %0d memory", host_id);
                    return 0;
                end
            end
            manager = host_mem_pool_ref.get_host(host_id);
            if ((manager == null) || (manager.get_host_id() != host_id)) begin
                why = $sformatf("shared Host %0d memory handle is invalid", host_id);
                return 0;
            end
        end
        return 1;
    endfunction

    // 从 config_db 取得配置并先校验和准备内存，再创建 DPU 父层与按 Host 分离的 virtio 子层。
    // 配置会被补入共享池和 Host 作用域；任一步失败报告 fatal 并返回，只有完整构建才置 configuration_valid。
    virtual function void build_phase(uvm_phase phase);
        string why;

        super.build_phase(phase);
        if (!uvm_config_db#(virtio_system_env_config)::get(
                this, "", "cfg", cfg)) begin
            `uvm_fatal("VIRTIO_SYSTEM_ENV",
                       "virtio_system_env_config 'cfg' is missing")
            return;
        end
        if ((cfg == null) || !cfg.validate(why)) begin
            `uvm_fatal("VIRTIO_SYSTEM_ENV", {"invalid top-level configuration: ", why})
            return;
        end
        if (!cfg.collect_host_ids(active_host_ids, why)) begin
            `uvm_fatal("VIRTIO_SYSTEM_ENV", {"could not collect Hosts: ", why})
            return;
        end
        if (!prepare_host_memory(why)) begin
            `uvm_fatal("VIRTIO_SYSTEM_ENV", {"Host memory setup failed: ", why})
            return;
        end

        cfg.dpu_cfg.host_mem_pool_ref = host_mem_pool_ref;
        uvm_config_db#(dpu_device_env_config)::set(
            this, "dpu_env", "cfg", cfg.dpu_cfg);
        dpu_env = dpu_device_env::type_id::create("dpu_env", this);

        // Every Host gets a distinct child and a distinct host_id. Host scope
        // is enabled automatically, so AUTO VIO placement remains authoritative
        // until dpu_device_env publishes its frozen snapshot.
        foreach (active_host_ids[index]) begin
            int unsigned host_id;
            virtio_net_env_config host_vio_cfg;
            string child_name;

            host_id = active_host_ids[index];
            host_vio_cfg = cfg.get_host_vio_config(host_id);
            host_vio_cfg.host_id = host_id;
            host_vio_cfg.host_mem_binding = null;
            host_vio_cfg.host_mem_pool_binding = host_mem_pool_ref;
            host_vio_cfg.host_scope_enable = 1'b1;
            host_vio_cfg.host_scope_id = host_id;
            child_name = $sformatf("virtio_env_h%0d", host_id);
            uvm_config_db#(virtio_net_env_config)::set(
                this, {"dpu_env.", child_name}, "cfg", host_vio_cfg);
            virtio_envs[host_id] = virtio_net_env::type_id::create(
                child_name, dpu_env);
        end

        if (cfg.create_pcie_env) begin
            if (cfg.pcie_cfg == null) begin
                `uvm_fatal("VIRTIO_SYSTEM_ENV",
                           "create_pcie_env is set but pcie_cfg is null")
                return;
            end
            uvm_config_db#(pcie_tl_env_config)::set(
                this, "pcie_env", "cfg", cfg.pcie_cfg);
            pcie_env = pcie_tl_env::type_id::create("pcie_env", this);
        end
        configuration_valid = 1;
    endfunction

    // 调用 UVM 父类连接阶段；PCIe 端点选择依赖测试拓扑，故本层不自动连接，由测试显式调用绑定接口。
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // PCIe binding is deliberately explicit. A single-Root test can use
        // bind_pcie_host(); a multi-Root test supplies keyed endpoints.
    endfunction

    // 返回指定 Host 已构建的 virtio 子环境借用句柄；Host 未构建时返回 null，无状态修改。
    function virtio_net_env get_virtio_env(input int unsigned host_id);
        if (virtio_envs.exists(host_id))
            return virtio_envs[host_id];
        return null;
    endfunction

    // 从共享池借用指定 Host 的内存管理器；池尚未准备或 Host 未注册时返回 null，不分配新内存。
    function host_mem_manager get_host_mem(input int unsigned host_id);
        if ((host_mem_pool_ref == null) ||
            !host_mem_pool_ref.has_host(host_id))
            return null;
        return host_mem_pool_ref.get_host(host_id);
    endfunction

    // 转发 DPU 设备快照句柄供只读消费；DPU 环境未创建时返回 null，快照发布时机由 DPU 环境决定。
    function dpu_device_snapshot get_device_snapshot();
        if (dpu_env == null)
            return null;
        return dpu_env.get_snapshot();
    endfunction

    // 转发 DPU 资源快照共享句柄；DPU 环境未创建时返回 null，使用者应确认快照已发布且冻结。
    function dpu_resource_snapshot get_resource_snapshot();
        if (dpu_env == null)
            return null;
        return dpu_env.get_resource_snapshot();
    endfunction

    // 借用 DPU 拥有的资源管理器；DPU 尚未构建时返回 null，系统层不另建资源分配权威。
    function dpu_resource_manager get_resource_manager();
        if (dpu_env == null)
            return null;
        return dpu_env.get_resource_manager();
    endfunction

    // 返回可选 PCIe 子环境句柄；未启用或尚未创建时为 null，不触发延迟创建。
    function pcie_tl_env get_pcie_env();
        return pcie_env;
    endfunction

    // Convenience API for the one-Host/one-Root case.
    // 把指定 Host 的 RC sequencer、可选完成适配器与监视器交给子环境绑定，适用于单 Root 连接。
    // 构建未成功或 Host 不存在返回 0；其余成功/失败及绑定副作用由子环境接口决定。
    function bit bind_pcie_host(
        input int unsigned host_id,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_tlm_completion_adapter tlm_adapter = null,
        input pcie_tl_base_monitor pcie_rc_monitor = null,
        input pcie_tl_base_monitor pcie_ep_monitor = null
    );
        virtio_net_env host_env;

        host_env = get_virtio_env(host_id);
        if (!configuration_valid || (host_env == null))
            return 0;
        return host_env.bind_pcie(
            pcie_rc_seqr, tlm_adapter, pcie_rc_monitor, pcie_ep_monitor);
    endfunction

    // Split a complete endpoint list by Host and let each child match its
    // segment+BDF identity. No positional function index is used.
    // 按端点的 Host 身份分组，再由子环境按 segment+BDF 匹配，避免依赖列表位置。
    // 未构建、子绑定失败、空端点或未知 Host 端点返回 0，否则返回 1；失败前完成的子绑定不回滚。
    function bit bind_pcie_endpoints(
        input virtio_pcie_function_endpoint endpoints[$]
    );
        bit endpoint_used[];

        if (!configuration_valid)
            return 0;
        endpoint_used = new[endpoints.size()];
        foreach (virtio_envs[host_id]) begin
            virtio_pcie_function_endpoint scoped[$];

            foreach (endpoints[index]) begin
                if ((endpoints[index] != null) &&
                    (endpoints[index].pcie_id.domain.host_id == host_id)) begin
                    scoped.push_back(endpoints[index]);
                    endpoint_used[index] = 1;
                end
            end
            if (!virtio_envs[host_id].bind_pcie_endpoints(scoped))
                return 0;
        end
        foreach (endpoint_used[index]) begin
            if (!endpoint_used[index])
                return 0;
        end
        return 1;
    endfunction
endclass : virtio_system_env

// A small, executable authoring example.  It intentionally uses the public
// dpu_common objects directly instead of virtio_test_device_builder.
// 测试层直接使用公开 DPU 配置对象，演示真实的编写入口而不依赖测试构造器；只检查资源组装便于独立运行。
class virtio_system_env_example_test extends uvm_test;
    `uvm_component_utils(virtio_system_env_example_test)

    virtio_system_env_config system_cfg;
    virtio_system_env        system_env;

    // 创建示例测试的 UVM 组件关系；配置与子环境在 build 阶段生成，不在构造阶段分配。
    function new(string name = "virtio_system_env_example_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 从非空 caps 按功能种类和 BAR 角色查询硬件规格，复制角色、偶数 BAR 号、大小与对齐，地址采用自动放置。
    // 返回新请求供功能配置持有；规格查找失败报告 fatal 并返回 null，调用方须提供有效能力对象。
    function dpu_bar_request make_bar(
        input dpu_dut_caps caps,
        input dpu_function_kind_e kind,
        input dpu_bar_role_e role,
        input string name
    );
        dpu_bar_profile_t profile;
        dpu_bar_request bar;
        string why;

        if (!caps.lookup_bar_profile(kind, role, profile, why)) begin
            `uvm_fatal("SYSTEM_EXAMPLE", {"BAR profile lookup failed: ", why})
            return null;
        end
        bar = dpu_bar_request::type_id::create(name);
        bar.role = profile.role;
        bar.even_bar_id = profile.even_bar_id;
        bar.size = profile.size;
        bar.alignment = profile.alignment;
        bar.placement = DPU_ALLOC_AUTO;
        return bar;
    endfunction

    // 以 Host/PF/功能种类/VF 身份创建功能声明，示例把 segment_id 映射为 host_id，并声明 VIO 能力与三类 BAR。
    // 返回新对象交给 device_cfg 持有；BDF 自动解析，BAR 查询失败沿用 make_bar 的 fatal 路径。
    function dpu_function_cfg make_function(
        input dpu_dut_caps caps,
        input int unsigned host_id,
        input int unsigned pf_id,
        input dpu_function_kind_e kind,
        input int unsigned vf_id
    );
        dpu_function_cfg f;

        f = dpu_function_cfg::type_id::create($sformatf(
            "fn_h%0d_pf%0d_kind%0d_vf%0d", host_id, pf_id, kind, vf_id));
        f.key.host_id = host_id;
        f.key.pf_id = pf_id;
        f.key.kind = kind;
        f.key.vf_id = vf_id;
        f.domain_key.host_id = host_id;
        f.domain_key.segment_id = host_id;
        f.bdf_mode = DPU_ALLOC_AUTO;
        f.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        f.bars.push_back(make_bar(caps, kind, DPU_BAR_DEVICE_MEMORY,
                                  {f.get_name(), "_mem"}));
        f.bars.push_back(make_bar(caps, kind, DPU_BAR_MAILBOX,
                                  {f.get_name(), "_mailbox"}));
        f.bars.push_back(make_bar(caps, kind, DPU_BAR_MSIX,
                                  {f.get_name(), "_msix"}));
        return f;
    endfunction

    // 按示例 Host 编号创建独立 GPA 范围、PCIe 域、BDF 候选范围与 MMIO 窗口，返回由设备配置持有的新对象。
    // 此固定地址公式面向本例 Host 0/1，未检查任意大编号的溢出；BAR 在窗口内采用随机放置。
    function dpu_host_cfg make_host(input int unsigned host_id);
        dpu_host_cfg host;
        dpu_pcie_domain_cfg domain;
        dpu_mmio_window_cfg window;
        dpu_bdf_range_t bdf_range;

        host = dpu_host_cfg::type_id::create($sformatf("host_%0d", host_id));
        host.host_id = host_id;
        host.has_gpa_aperture = 1;
        host.gpa_base = 64'h0000_1000_0000_0000 +
                        host_id * 64'h0000_0100_0000_0000;
        host.gpa_limit = host.gpa_base + 64'h0000_0000_1000_0000;

        domain = dpu_pcie_domain_cfg::type_id::create(
            $sformatf("domain_%0d", host_id));
        domain.key.host_id = host_id;
        domain.key.segment_id = host_id;
        bdf_range.first_bdf = 16'h0010;
        bdf_range.last_bdf = 16'h00ff;
        domain.bdf_ranges.push_back(bdf_range);
        window = dpu_mmio_window_cfg::type_id::create(
            $sformatf("window_%0d", host_id));
        window.base = 64'h0000_0020_0000_0000 +
                      host_id * 64'h0000_0010_0000_0000;
        window.limit = window.base + 64'h0000_0001_0000_0000;
        window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
        window.allowed_roles.push_back(DPU_BAR_MAILBOX);
        window.allowed_roles.push_back(DPU_BAR_MSIX);
        domain.mmio_windows.push_back(window);
        domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;
        host.pcie_domains.push_back(domain);
        return host;
    endfunction

    // 创建并填充 system_cfg：两个 Host 各有一 PF、两 VF，共享容量 2048、单功能上限 32 的队列资源池。
    // 每个 VF 请求一对队列，驱动配置按服务键匹配，AF 指向 Host 0 PF 0；配置登记失败报告 fatal。
    function void author_config();
        dpu_dut_caps caps;
        dpu_resource_pool_config_t profile;
        string why;

        system_cfg = virtio_system_env_config::type_id::create("system_cfg");
        caps = system_cfg.dpu_cfg.device_cfg.dut_caps;
        caps.max_hosts = 2;
        caps.max_pfs_per_host = 1;
        caps.max_vfs_per_pf = 2;

        profile.name = "virtio.qpair";
        profile.class_id = '0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 2048;
        profile.max_per_function = 32;
        system_cfg.dpu_cfg.placement_cfg.profiles.push_back(profile);

        for (int unsigned host_id = 0; host_id < 2; host_id++) begin
            dpu_function_cfg pf_cfg;
            virtio_net_env_config host_vio_cfg;
            dpu_function_key_t fixed_devices[$];
            dpu_vio_placement_request request;

            system_cfg.dpu_cfg.device_cfg.hosts.push_back(
                make_host(host_id));
            pf_cfg = make_function(caps, host_id, 0, DPU_FUNCTION_PF, 0);
            system_cfg.dpu_cfg.device_cfg.functions.push_back(pf_cfg);

            host_vio_cfg = virtio_net_env_config::type_id::create(
                $sformatf("host_vio_cfg_%0d", host_id));
            host_vio_cfg.host_id = host_id;
            host_vio_cfg.default_num_pairs = 1;
            host_vio_cfg.default_queue_size = 256;
            host_vio_cfg.default_driver_features = '1;

            for (int unsigned vf_id = 0; vf_id < 2; vf_id++) begin
                dpu_function_cfg vf_cfg;
                dpu_service_key_t service_key;
                virtio_driver_config_t driver_cfg;

                vf_cfg = make_function(caps, host_id, 0,
                                       DPU_FUNCTION_VF, vf_id);
                system_cfg.dpu_cfg.device_cfg.functions.push_back(vf_cfg);
                fixed_devices.push_back(vf_cfg.key);
                service_key.function_key = vf_cfg.key;
                service_key.service_kind = DPU_SERVICE_VIO_NET;
                service_key.service_instance_id = 0;
                driver_cfg = host_vio_cfg.make_default_driver_config(32);
                driver_cfg.num_queue_pairs = 1;
                if (!host_vio_cfg.add_service_config(
                        service_key, driver_cfg, why))
                    `uvm_fatal("SYSTEM_EXAMPLE", why)
            end

            request = dpu_vio_placement_request::type_id::create(
                $sformatf("vio_request_%0d", host_id));
            request.request_id = host_id;
            request.total_qpairs = fixed_devices.size();
            request.candidate_kind = DPU_VIO_CANDIDATE_VF_ONLY;
            request.device_policy = DPU_VIO_DEVICE_FIXED;
            request.ordering = DPU_PLACEMENT_CANONICAL;
            request.fixed_devices = fixed_devices;
            system_cfg.dpu_cfg.placement_cfg.vio_requests.push_back(request);
            if (!system_cfg.set_host_vio_config(
                    host_id, host_vio_cfg, why))
                `uvm_fatal("SYSTEM_EXAMPLE", why)
        end

        system_cfg.dpu_cfg.device_cfg.af_request.mode = DPU_AF_SELECTED;
        system_cfg.dpu_cfg.device_cfg.af_request.requester.host_id = 0;
        system_cfg.dpu_cfg.device_cfg.af_request.requester.pf_id = 0;
        system_cfg.dpu_cfg.device_cfg.af_request.requester.kind = DPU_FUNCTION_PF;
        system_cfg.dpu_cfg.device_cfg.af_request.requester.vf_id = 0;
    endfunction

    // 编写示例配置并发布给系统子环境；将驱动代理设为 passive，使资源/层次检查无需 PCIe 激励连接。
    // 随后创建 system_env，由 UVM 后续遍历构建其子层；配置错误沿用 author_config 和子环境的 fatal 路径。
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        author_config();
        // This example validates hierarchy/resource ownership only.  A
        // traffic test leaves the agents active and calls bind_pcie_host() or
        // bind_pcie_endpoints() before starting a driver sequence.
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "system_env.dpu_env.*.*.*.driver_agent",
            "is_active", UVM_PASSIVE);
        uvm_config_db#(virtio_system_env_config)::set(
            this, "system_env", "cfg", system_cfg);
        system_env = virtio_system_env::type_id::create("system_env", this);
    endfunction

    // 在 build/connect 完成后检查双 Host 内存隔离、子环境及冻结资源快照，验证四个 VF 队列绑定身份和全局 ID 唯一性。
    // 持有 objection 直至检查结束；任一不变量失败报告 fatal，本任务不启动流量、不等待时钟或执行复位。
    virtual task run_phase(uvm_phase phase);
        host_mem_manager host0_mem;
        host_mem_manager host1_mem;
        dpu_resource_snapshot resource_snapshot;
        dpu_resource_pool_config_t profiles[$];
        dpu_vio_qpair_binding_t bindings[$];
        int unsigned seen_global_qpairs[$];
        int unsigned host_binding_count[2];
        bit qpair_profile_found;

        phase.raise_objection(this);
        host0_mem = system_env.get_host_mem(0);
        host1_mem = system_env.get_host_mem(1);
        if ((host0_mem == null) || (host1_mem == null) ||
            (host0_mem == host1_mem)) begin
            `uvm_fatal("SYSTEM_EXAMPLE",
                       "Hosts 0 and 1 did not receive distinct memory managers")
        end
        if ((system_env.get_virtio_env(0) == null) ||
            (system_env.get_virtio_env(1) == null)) begin
            `uvm_fatal("SYSTEM_EXAMPLE",
                       "per-Host virtio environments were not created")
        end

        // The profile is a single global pool.  This small smoke allocates
        // four entries from its 2048-ID capacity (two VFs per Host, one pair
        // per VF); it intentionally does not try to instantiate 2048 queues.
        resource_snapshot = system_env.get_resource_snapshot();
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            `uvm_fatal("SYSTEM_EXAMPLE",
                       "top-level environment did not publish a frozen resource snapshot")
        end
        resource_snapshot.list_resource_profiles(profiles);
        qpair_profile_found = 0;
        foreach (profiles[index]) begin
            if (profiles[index].name == "virtio.qpair") begin
                qpair_profile_found = 1;
                if ((profiles[index].capacity != 2048) ||
                    (profiles[index].max_per_function != 32)) begin
                    `uvm_fatal("SYSTEM_EXAMPLE",
                               "virtio.qpair profile does not expose the 2048/32 global limits")
                end
            end
        end
        if (!qpair_profile_found)
            `uvm_fatal("SYSTEM_EXAMPLE", "virtio.qpair profile is missing")

        resource_snapshot.list_vio_bindings(bindings);
        if (bindings.size() != 4)
            `uvm_fatal("SYSTEM_EXAMPLE", $sformatf(
                       "expected four VF qpair bindings, got %0d", bindings.size()))
        host_binding_count[0] = 0;
        host_binding_count[1] = 0;
        foreach (bindings[index]) begin
            if (bindings[index].service_key.service_kind != DPU_SERVICE_VIO_NET)
                `uvm_fatal("SYSTEM_EXAMPLE", "non-VIO binding leaked into VIO snapshot")
            if (bindings[index].service_key.function_key.kind != DPU_FUNCTION_VF)
                `uvm_fatal("SYSTEM_EXAMPLE", "VIO binding owner is not a VF")
            if (bindings[index].service_key.function_key.host_id >= 2) begin
                `uvm_fatal("SYSTEM_EXAMPLE", "VIO binding owner has an unknown Host")
                continue;
            end
            if (bindings[index].request_id !=
                bindings[index].service_key.function_key.host_id)
                `uvm_fatal("SYSTEM_EXAMPLE",
                           "VIO request ID is detached from its Host authoring scope")
            foreach (seen_global_qpairs[prior]) begin
                if (seen_global_qpairs[prior] == bindings[index].global_qpair_id)
                    `uvm_fatal("SYSTEM_EXAMPLE", "duplicate global qpair ID in snapshot")
            end
            seen_global_qpairs.push_back(bindings[index].global_qpair_id);
            host_binding_count[
                bindings[index].service_key.function_key.host_id]++;
        end
        if ((host_binding_count[0] != 2) || (host_binding_count[1] != 2))
            `uvm_fatal("SYSTEM_EXAMPLE",
                       "VIO qpair bindings are not split two-per-Host")
        `uvm_info("SYSTEM_EXAMPLE",
                  "2 Hosts, 2 PFs, 4 VFs and per-Host Host memory managers are configured",
                  UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass : virtio_system_env_example_test

`endif // VIRTIO_SYSTEM_ENV_EXAMPLE_TEST_SV
