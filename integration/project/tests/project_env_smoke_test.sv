// integration/project/tests：参考组装层的构建/连接回归，不含 RTL 或伪造设备响应。
// 依赖 project_env_pkg；top 提供空闲 native VIF。验证组合式 parent/build 顺序、句柄身份、
// 参数消费和跨 Host 隔离，不发包、不调用寄存器计划，不把结构检查当成数据面通过。
// 注入的 IOMMU 在 build 前已有 live mapping，用于验证共享对象不会被重配。
package project_env_test_pkg;
    timeunit 1ns;
    timeprecision 1ps;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    import host_mem_pkg::*;
    import dpu_resource_pkg::*;
    import pcie_tl_pkg::*;
    import virtio_net_pkg::*;
    import virtio_aip_pkg::*;
    import project_env_pkg::*;
    `include "uvm_macros.svh"

    // 只读探针用于比较受保护的 snapshot 句柄；不替换生产 build/connect 行为。
    class project_vio_probe extends virtio_net_env;
        `uvm_component_utils(project_vio_probe)

        // 保持 UVM 构造契约，无测试状态注入。
        function new(string	name, uvm_component	parent);
            super.new(name, parent);
        endfunction

        // 校验内部消费对象正是 DPU 发布的三份句柄，未复制或私建另一套快照。
        function bit consumes(dpu_device_snapshot	device, dpu_resource_snapshot	resources,
                dpu_resource_manager	manager);
            return configuration_valid && device_snapshot == device &&
                resource_snapshot == resources && device_resource_manager == manager;
        endfunction
    endclass

    // 独立 UVM test 仅验证组装；真实平台可参考 project_base_test 的顺序合入已有 test。
    class project_env_smoke_test extends uvm_test;
        `uvm_component_utils(project_env_smoke_test)
        project_env_cfg		cfg;
        project_env		env;
        virtio_iommu_model	injected_iommu[int unsigned];
        host_mem_pool		injected_pool;
        string			negative;
        int unsigned		checks;

        // 初始化测试计数；负例名称在 build 前从专用 plusarg 取得。
        function new(string	name = "project_env_smoke_test", uvm_component	parent = null);
            super.new(name, parent);
            checks = 0;
        endfunction

        // 四态断言；每次失败记录真实 UVM_ERROR，不降级生产报错。
        function void expect_true(logic	condition, string	detail);
            checks++;
            if (condition !== 1'b1) `uvm_error("PROJECT_CHECK", detail)
        endfunction

        // 用生产参数入口创建 cfg，再注入 top VIF 和已有 pool/IOMMU。
        // negative 分支刻意破坏一个契约，应在生产 build/connect 到达指定 fatal。
        virtual function void build_phase(uvm_phase	phase);
            virtual pcie_tl_if			vif;
            virtual virtio_protocol_event_if	protocol_vif;
            dpu_host_cfg			first_host;
            string				why;

            super.build_phase(phase);
            void'($value$plusargs("PROJECT_NEGATIVE=%s", negative));
            virtio_net_env::type_id::set_type_override(project_vio_probe::get_type());
            cfg = project_env_cfg::type_id::create("cfg");
            cfg.load_params();
            first_host = cfg.dpu_cfg.device_cfg.hosts[0];
            cfg.load_params();
            expect_true(cfg.dpu_cfg.device_cfg.hosts[0] == first_host, "load_params recreated Host input");
            // 交换 Host 与 RC/EP slot，证明端点使用显式映射，而不是偶然相同的数组下标。
            if ($test$plusargs("PROJECT_SWAP_SLOTS")) begin
                if (cfg.hosts != 2) `uvm_fatal("PROJECT_TEST", "swap case requires two Hosts")
                cfg.tl_slot_by_host[0] = 1;
                cfg.tl_slot_by_host[1] = 0;
            end
            injected_pool = host_mem_pool::type_id::create("platform_pool");
            cfg.host_mem_pool_binding = injected_pool;

            foreach (cfg.dpu_cfg.device_cfg.hosts[i]) begin
                dpu_host_cfg		host;
                virtio_iommu_model	iommu;
                virtio_net_env_config	vio;
                bit [63:0]		mapped;

                host = cfg.dpu_cfg.device_cfg.hosts[i];
                vio = cfg.vio_cfg_by_host[host.host_id];
                if (!injected_pool.create_host(host.host_id, host.gpa_base, host.gpa_limit - 1,
                        cfg.host_mem_mode, cfg.host_mem_granule, vio.host_mem_policy))
                    `uvm_fatal("PROJECT_TEST", "cannot prepare platform Host memory")
                iommu = virtio_iommu_model::type_id::create($sformatf("platform_iommu_%0d", host.host_id));
                if (!iommu.configure_iova_aperture(vio.iova_base, vio.iova_limit, vio.iova_alloc_policy, why))
                    `uvm_fatal("PROJECT_TEST", why)
                iommu.strict_permission_check = vio.iommu_strict;
                mapped = iommu.map_fixed_for_host(host.host_id, 16'hfffe, host.gpa_base,
                    4096, DMA_TO_DEVICE, vio.iova_base);
                if (mapped != vio.iova_base) `uvm_fatal("PROJECT_TEST", "cannot seed platform IOMMU")
                injected_iommu[host.host_id] = iommu;
                vio.iommu_binding = iommu;

                if (!uvm_config_db#(virtual pcie_tl_if)::get(null, "uvm_test_top",
                        $sformatf("rc_vif_%0d", host.host_id), vif))
                    `uvm_fatal("PROJECT_TEST", "top has no RC VIF")
                cfg.rc_vifs[host.host_id] = vif;
                if (!uvm_config_db#(virtual pcie_tl_if)::get(null, "uvm_test_top",
                        $sformatf("ep_vif_%0d", host.host_id), vif))
                    `uvm_fatal("PROJECT_TEST", "top has no EP VIF")
                cfg.ep_vifs[host.host_id] = vif;
            end
            if (negative == "iommu_policy") injected_iommu[0].strict_permission_check = !cfg.vio_cfg.iommu_strict;
            if (negative == "missing_root") cfg.tl_slot_by_host.delete(0);
            if (negative == "duplicate_slot") cfg.tl_slot_by_host[1] = cfg.tl_slot_by_host[0];
            if (negative == "invalid_slot") cfg.tl_slot_by_host[0] = cfg.hosts;
            if (negative == "missing_native_vif") cfg.rc_vifs.delete(0);
            if (negative == "reused_native_vif") cfg.rc_vifs[1] = cfg.rc_vifs[0];
            if (negative == "reused_vif" || negative == "null_vif") begin
                if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(null, "uvm_test_top",
                        "protocol_event_vif_0", protocol_vif))
                    `uvm_fatal("PROJECT_TEST", "top has no protocol VIF")
                if (negative == "null_vif") protocol_vif = null;
                repeat (32) cfg.protocol_vifs.push_back(protocol_vif);
            end
            uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
            env = project_env::type_id::create("env", this);
        endfunction

        // 直接验证新增 VIF 注册 API 的拒绝行为；失败返回不应留下错误绑定。
        function void check_protocol_api(virtual virtio_protocol_event_if	vif);
            virtio_net_env_config		probe;
            dpu_pcie_function_id_t		id0;
            dpu_pcie_function_id_t		id1;
            virtual virtio_protocol_event_if	found;
            string				why;

            probe = virtio_net_env_config::type_id::create("vif_api_probe");
            id0 = '{domain:'{host_id:0, segment_id:0}, bdf:16'h10};
            id1 = '{domain:'{host_id:1, segment_id:0}, bdf:16'h10};
            expect_true(!probe.bind_protocol_event_vif(id0, null, why), "null VIF accepted");
            expect_true(!probe.has_protocol_event_bindings(), "failed bind left partial state");
            expect_true(probe.bind_protocol_event_vif(id0, vif, why), "valid VIF binding rejected");
            expect_true(!probe.bind_protocol_event_vif(id0, vif, why), "duplicate identity accepted");
            expect_true(!probe.bind_protocol_event_vif(id1, vif, why), "cross-domain VIF alias accepted");
            expect_true(!probe.get_protocol_event_vif(id1, found) && found == null,
                "missing explicit identity fell back to another domain");
        endfunction

        // 连接后检查生产组件及平台对象身份；解绑测试自有 IOVA，避免 report 泄漏。
        // 可选 EXPECT 参数独立于 AIP，防止加载入口失效却仍以默认值自证通过。
        virtual task run_phase(uvm_phase	phase);
            virtual virtio_protocol_event_if	used[$];
            int					expected;
            int unsigned			active_functions;
            string				why;

            phase.raise_objection(this);
            if (negative != "") `uvm_fatal("PROJECT_TEST", "negative case unexpectedly reached run")
            active_functions = 0;
            expect_true(env.shared_pool == injected_pool, "project replaced platform pool");
            expect_true(cfg.dpu_cfg.host_mem_pool_ref == injected_pool, "DPU has a different pool");
            expect_true(env.reg_backend.device_snapshot == env.dpu_env.get_snapshot(),
                "executor backend did not receive authoritative snapshot during DPU build");
            expect_true(env.reg_backend.virtual_sequencer == env.pcie_env.v_seqr,
                "register backend has wrong virtual sequencer");
            expect_true(env.dpu_env.get_state() == DPU_DEVICE_RESOLVED,
                "assembly unexpectedly executed device configuration");
            expect_true(env.dpu_env.get_type_name() == "dpu_device_env" && env.dpu_env.get_parent() == env,
                "project did not directly create the original DPU env");
            expect_true(env.pcie_env.cfg == cfg.pcie_cfg && env.pcie_env.global_cfg == null &&
                env.pcie_env.topology_adapter == null && !env.pcie_env.backend_provider_active,
                "PCIe did not use the native cfg-only path");
            if ($value$plusargs("PROJECT_EXPECT_HOSTS=%d", expected))
                expect_true(cfg.hosts == expected && env.vio_envs.num() == expected, "dpu.hosts not consumed");
            if ($value$plusargs("PROJECT_EXPECT_PH=%d", expected))
                expect_true(env.pcie_env.fc_mgrs[0].posted_header.current == expected, "PCIe credit override not consumed");

            foreach (env.vio_envs[h]) begin
                project_vio_probe	vio;
                int unsigned		slot;
                bit [63:0]		gpa;
                iommu_fault_e		fault;

                if (!$cast(vio, env.vio_envs[h])) `uvm_fatal("PROJECT_TEST", "VIO probe not installed")
                slot = cfg.tl_slot_by_host[h];
                expect_true(vio.get_parent() == env.dpu_env, "VIO is not in the DPU snapshot publication subtree");
                expect_true(vio.consumes(env.dpu_env.get_snapshot(), env.dpu_env.get_resource_snapshot(),
                    env.dpu_env.get_resource_manager()), "VIO copied or replaced DPU snapshots");
                expect_true(vio.host_mem == injected_pool.get_host(h), "VIO uses a private Host manager");
                expect_true(env.pcie_env.cfg.host_mem_by_root[cfg.tl_slot_by_host[h]] == vio.host_mem,
                    "PCIe and VIO do not share Host memory");
                expect_true(env.pcie_env.rc_agents[slot].rc_driver.mem == vio.host_mem,
                    "native RC driver did not consume the matching Host memory");
                expect_true(env.pcie_env.rc_adapters[slot].vif == cfg.rc_vifs[slot],
                    "native RC adapter has the wrong VIF");
                expect_true(env.reg_backend.root_by_domain[longint'(h) << 32] == slot,
                    "register plan selects a different RC slot than VIO");
                expect_true(vio.iommu == injected_iommu[h], "VIO replaced injected IOMMU");
                expect_true(vio.iommu.translate_for_host(h, 16'hfffe, cfg.vio_cfg_by_host[h].iova_base,
                    64, DMA_TO_DEVICE, gpa, fault), "preexisting IOMMU mapping lost");
                expect_true(gpa == cfg.dpu_cfg.device_cfg.hosts[h].gpa_base, "preexisting IOMMU mapping changed");
                expect_true(vio.iommu.total_maps == 1, "IOMMU was recreated or unexpectedly allocated");
                vio.iommu.unmap_for_host(h, 16'hfffe, cfg.vio_cfg_by_host[h].iova_base);
                foreach (vio.function_instances[i]) begin
                    virtual virtio_protocol_event_if	vif;
                    virtio_function_instance		f;

                    f = vio.function_instances[i];
                    active_functions++;
                    expect_true(f.pcie_id.domain.host_id == h, "Function leaked across Host scope");
                    expect_true(f.transport.bar.pcie_rc_seqr == env.pcie_env.rc_agents[slot].sequencer,
                        "Function selected the wrong Host RC sequencer");
                    expect_true(vio.cfg.get_protocol_event_vif(f.pcie_id, vif), "explicit protocol map missing");
                    expect_true(f.driver_agent.monitor.protocol_vif == vif, "monitor consumed a different VIF");
                    foreach (used[j]) expect_true(used[j] != vif, "monitor VIF aliases another Function/Host");
                    used.push_back(vif);
                    if ($value$plusargs("PROJECT_EXPECT_QUEUE=%d", expected))
                        expect_true(f.driver_agent.fsm.drv_cfg.queue_size == expected, "VIO queue override not consumed");
                end
            end
            if ($value$plusargs("PROJECT_EXPECT_FUNCTIONS=%d", expected))
                expect_true(active_functions == expected, "wrong active VIO Function count");
            env.register_aip_commands();
            expect_true(virtio_aip_registry::targets.num() == active_functions, "AIP omitted/aliased service targets");
            if (used.size() != 0) check_protocol_api(used[0]);
            #1ns;
            `uvm_info("PROJECT_CHECK", $sformatf("PASS checks=%0d hosts=%0d active_functions=%0d",
                checks, cfg.hosts, active_functions), UVM_LOW)
            phase.drop_objection(this);
        endtask
    endclass
endpackage
