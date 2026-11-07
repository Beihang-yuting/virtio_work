// integration/project/tests：冻结 BAR 公共接口定向回归，依赖项目包和真实 DPU 快照。
// 测试只拥有本地模型，不创建 DUT 响应；所有失败通过公开返回值或 driver fatal 观察。
package project_bar_registry_test_pkg;
    import uvm_pkg::*;
    import dpu_resource_pkg::*;
    import pcie_tl_pkg::*;
    import project_env_pkg::*;
    import intel_pcie_adapter_pkg::*;
    `include "uvm_macros.svh"

    // 用公开 snapshot builder 建立跨 Host 重址、同号 VF 和非 role 顺序 BAR。
    class project_bar_registry_test extends uvm_test;
        `uvm_component_utils(project_bar_registry_test)
        int unsigned					checks;
        project_pcie_rc_driver			driver;
        pcie_tl_if_adapter				adapter;
        uvm_sequencer #(pcie_tl_tlp)	sequencer;

        // UVM 构造；不分配外部资源。
        extern function	new(
            string			name = "project_bar_registry_test",
            uvm_component	parent = null
        );

        // 建立真实派生 driver，后续通过公开 route_tlp 检查发送前决策。
        extern virtual function void	build_phase(
            uvm_phase	phase
        );

        // 四态检查保留失败计数，不拦截生产错误。
        extern function void	expect_true(
            logic	condition,
            string	detail
        );

        // 构造冻结快照；两 Host 可重用同数值地址和 BDF。
        extern function dpu_device_snapshot	make_snapshot(
            int unsigned	host_count = 2,
            bit				add_empty_host = 0
        );

        // 覆盖名字/地址/引用/路由及非法发送，不依赖项目 env 自动配置。
        extern virtual task	run_phase(
            uvm_phase	phase
        );
    endclass

    // UVM 构造；不分配外部资源。
    function	project_bar_registry_test::new(
        string			name = "project_bar_registry_test",
        uvm_component	parent = null
    );
        super.new(name, parent);
    endfunction

    // 建立真实派生 driver，后续通过公开 route_tlp 检查发送前决策。
    function void	project_bar_registry_test::build_phase(
        uvm_phase	phase
    );
        super.build_phase(phase);
        driver = project_pcie_rc_driver::type_id::create("driver", this);
        adapter = pcie_tl_if_adapter::type_id::create("adapter", this);
        driver.adapter = adapter;
        driver.codec = pcie_tl_codec::type_id::create("codec");
        sequencer = new("sequencer", this);
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

    // 四态检查保留失败计数，不拦截生产错误。
    function void	project_bar_registry_test::expect_true(
        logic	condition,
        string	detail
    );
        checks++;

        if (condition !== 1'b1) begin
            `uvm_error("BAR_CHECK", detail)
        end
    endfunction

    // 构造冻结快照；两 Host 可重用同数值地址和 BDF。
    function dpu_device_snapshot	project_bar_registry_test::make_snapshot(
        int unsigned	host_count = 2,
        bit				add_empty_host = 0
    );
        dpu_device_snapshot	snapshot;
        dpu_dut_caps		caps;
        string				why;

        snapshot = dpu_device_snapshot::type_id::create("snapshot");
        caps = dpu_dut_caps::type_id::create("caps");
        expect_true(snapshot.set_dut_caps(caps, why), why);

        for (int unsigned	h = 0; h < host_count; h++) begin
            dpu_host_info_t	host;

            host = '{default:0};
            host.host_id = h;
            host.enabled = 1;
            host.address_width = 64;
            expect_true(snapshot.add_host(host, why), why);

            for (int unsigned	p = 0; p < 2; p++) begin
                for (int unsigned	v = 0; v < 2; v++) begin
                    dpu_function_key_t		key;
                    dpu_pcie_function_id_t	id;
                    dpu_bar_pair_lease_t	bar;

                    key = '{h, p, (v == 0 ? DPU_FUNCTION_PF : DPU_FUNCTION_VF), 0};
                    id = '{'{h, 0}, 16'(p * 16 + v)};
                    expect_true(snapshot.add_function(key, id, why), why);
                    bar = '{DPU_BAR_DEVICE_MEMORY, 0, 64'h10000 + p * 'h10000 + v * 'h4000, 64'h1000};
                    expect_true(snapshot.add_bar(key, bar, why), why);
                    bar = '{DPU_BAR_MAILBOX, 4, bar.base + 'h1000, 64'h1000};
                    expect_true(snapshot.add_bar(key, bar, why), why);

                    if (h == 0 && p == 0 && v == 0) begin
                        expect_true(snapshot.set_expected_af(key, why), why);
                    end
                end
            end
        end

        if (add_empty_host) begin
            dpu_host_info_t	empty_host;

            empty_host = '{default:0};
            empty_host.host_id = host_count;
            empty_host.address_width = 64;
            expect_true(snapshot.add_host(empty_host, why), why);
        end
        expect_true(snapshot.freeze(why), why);
        return snapshot;
    endfunction

    // 覆盖名字/地址/引用/路由及非法发送，不依赖项目 env 自动配置。
    task	project_bar_registry_test::run_phase(
        uvm_phase	phase
    );
        dpu_device_snapshot		snapshot;
        project_bar_registry	registry;
        project_bar_registry	other;
        project_bar_registry	single;
        dpu_device_snapshot		single_snapshot;
        project_bar_target_t	target;
        project_bar_target_t	again;
        dpu_function_key_t		keys[$];
        pcie_tl_cq_route_t		route;
        pcie_tl_mem_tlp			mem;
        pcie_tl_cpl_tlp			cpl;
        pcie_tl_cfg_tlp			cfg_tlp;
        pcie_tl_tlp				sent;
        intel_pcie_avst_codec	intel_codec;
        intel_pcie_packet		packet;
        bit [63:0]				address;
        string					why;
        string					negative;
        string					bad_names[$];
        phase.raise_objection(this);
        snapshot = make_snapshot();
        registry = project_bar_registry::type_id::create("registry");
        expect_true(!registry.resolve_name("pf0.bar0", target, why), "unready query accepted");
        expect_true(!registry.print_bar_map(why), "unready final map printed");
        single_snapshot = make_snapshot(1);
        single = project_bar_registry::type_id::create("single");
        expect_true(single.initialize(single_snapshot, 1, why), why);
        expect_true(single.bind_host(0, 0, why), why);
        expect_true(single.bind_function('{0, 0, DPU_FUNCTION_PF, 0}, 0, -1, 0, why), why);
        expect_true(single.freeze(why), why);
        expect_true(single.resolve_name("pf0.bar0", again, why), why);
        expect_true(again.canonical_name == "h0.pf0.bar0", "single Host shorthand wrong");
        single_snapshot = make_snapshot(1, 1);
        single = project_bar_registry::type_id::create("empty_host");
        expect_true(single.initialize(single_snapshot, 1, why), why);
        expect_true(single.bind_host(0, 0, why), why);
        expect_true(!single.freeze(why), "missing functionless Host binding accepted");
        expect_true(single.bind_host(1, 1, why), why);
        expect_true(single.freeze(why), why);
        expect_true(registry.initialize(snapshot, 1, why), why);
        expect_true(registry.bind_host(0, 1, why), why);
        expect_true(!registry.bind_host(1, 1, why), "duplicate RC slot accepted");
        expect_true(registry.bind_host(1, 0, why), why);
        snapshot.list_functions(keys);
        expect_true(!registry.bind_function(keys[0], 8, -1, 16'h9000, why), "PF truncation accepted");
        expect_true(!registry.bind_function(keys[1], 0, 2048, 16'h9001, why), "VF truncation accepted");

        foreach (keys[i]) begin
            expect_true(registry.bind_function(keys[i], 7 - keys[i].pf_id,
                keys[i].kind == DPU_FUNCTION_VF ? int'(100 + keys[i].pf_id) : -1,
                16'(16'h9000 + keys[i].pf_id * 16 + keys[i].kind), why), why);
        end
        expect_true(!registry.bind_function(keys[0], 7, -1, 16'h9000, why), "duplicate Function mapping accepted");
        expect_true(registry.freeze(why), why);
        expect_true(!registry.bind_host(0, 0, why), "frozen mutation accepted");
        expect_true(registry.resolve_name("h1.pf1.vf0.bar4", target, why), why);
        expect_true(target.rc_slot == 0 && target.bar_lease.even_bar_id == 4 &&
            target.route.pf_index == 6 && target.route.vf_index == 101, "wrong explicit route or BAR id");
        expect_true(registry.resolve_function(target.function_key, 4, again, why), why);
        expect_true(again.canonical_name == target.canonical_name, "function/name mismatch");
        expect_true(registry.resolve_base(1, 0, target.bar_lease.base, again, why), why);
        expect_true(again.canonical_name == target.canonical_name, "base/name mismatch");
        expect_true(registry.resolve_base(0, 0, target.bar_lease.base, again, why), why);
        expect_true(again.function_key.host_id == 0 && again.rc_slot == 1, "same numeric base crossed Host domain");
        expect_true(registry.resolve_name("h1.pf0.vf0.bar4", again, why), why);
        expect_true(again.function_key.pf_id == 0 && again.route.vf_index == 100 &&
            again.bar_lease.base != target.bar_lease.base, "same VF id lost parent PF identity");
        expect_true(!registry.resolve_base(1, 0, target.bar_lease.base + 4, again, why), "interior base accepted");
        expect_true(!registry.resolve_name("pf0.bar0", again, why), "ambiguous Host accepted");
        expect_true(registry.resolve_name("pf0.bar0", again, why, 1, 1), why);
        expect_true(again.function_key.host_id == 1, "explicit access Host ignored");
        expect_true(!registry.resolve_name("h0.pf0.bar0", again, why, 1, 1), "conflicting access Host accepted");
        bad_names = '{"", "vf0.bar0", "h1.pf0.bar1", "h1.pf0.bar3", "h1.pf0.bar5", "pf-1.bar0",
        "h4294967296.pf0.bar0", "h1.pf4294967296.bar0", "h1.pf0.vf4294967296.bar0",
        "h1.pf0.bar4294967296", "h1.pf0.bar0junk", "h1.pf0.bar0.", " h1.pf0.bar0",
        "h1.pf0.bar", "h1.pf0.vf.bar0", "h1.pf0.bar2", "h2.pf0.bar0"};

        foreach (bad_names[i]) begin
            expect_true(!registry.resolve_name(bad_names[i], again, why), {"bad name accepted: ", bad_names[i]});
        end
        expect_true(registry.check_range(target, 'hffc, 4, address, why), why);
        expect_true(address == target.bar_lease.base + 'hffc, "tail address wrong");
        expect_true(!registry.check_range(target, 'hffd, 4, address, why), "tail crossing accepted");
        expect_true(!registry.check_range(target, 64'hfffffffffffffffc, 8, address, why), "overflow accepted");
        expect_true(!registry.check_range(target, 0, 0, address, why), "zero size accepted");
        other = project_bar_registry::type_id::create("other");
        expect_true(other.initialize(snapshot, 2, why), why);
        expect_true(other.bind_host(0, 1, why) && other.bind_host(1, 0, why), why);
        expect_true(other.freeze(why), why);
        expect_true(!other.check_range(target, 0, 4, address, why), "old generation accepted");
        again = target;
        again.bar_lease.base++;
        expect_true(!registry.check_range(again, 0, 4, address, why), "modified value copy accepted");
        again = target;
        again.snapshot = make_snapshot();
        expect_true(!registry.check_range(again, 0, 4, address, why), "different snapshot identity accepted");
        expect_true(!other.resolve_name("h0.pf0.bar0", again, why), "unbound Intel route accepted");
        expect_true(!registry.route_memory(1, 1, target.bar_lease.base, 4, route, why), "unsupported segment accepted");
        expect_true(registry.route_memory(1, 0, target.bar_lease.base + 'hffc, 4, route, why), why);
        expect_true(route.pf_index == 6 && route.vf_index == 101 && route.bar_id == 4, "memory route wrong");
        expect_true(registry.route_completion(1, 0, 16'h9011, route, why), why);
        expect_true(route.pf_index == 6 && route.vf_index == 101, "completion requester map wrong");
        expect_true(!registry.route_completion(1, 0, 16'h1234, route, why), "unknown requester accepted");
        mem = pcie_tl_mem_tlp::type_id::create("mem");
        mem.kind = TLP_MEM_WR;
        mem.fmt = FMT_3DW_WITH_DATA;
        mem.payload = new[4];
        mem.addr = target.bar_lease.base;
        mem.length = 1;
        mem.first_be = 4'hf;
        mem.last_be = 0;
        mem.requester_id = 16'hf000;
        expect_true(!driver.route_tlp(mem, why), "uninstalled driver accepted request");
        expect_true(!driver.install_registry(registry, 1, 0, 1, why), "wrong driver RC slot accepted");
        expect_true(driver.install_registry(registry, 1, 0, 0, why), why);
        expect_true(driver.install_registry(registry, 1, 0, 0, why), "identical reinstallation rejected");
        expect_true(!driver.install_registry(other, 1, 0, 0, why), "live registry replacement accepted");
        expect_true(driver.route_tlp(mem, why), why);
        expect_true(mem.cq_route.bar_id == 4 && mem.cq_route.vf_index == 101 &&
            mem.requester_id == 16'hf000, "driver altered Memory identity");

        // 走真实父类 send pipeline 到 TLM adapter；再用真实 Intel codec 校验物理位域。
        driver.send_tlp(mem);
        expect_true(adapter.tlm_tx_fifo.try_get(sent), "successful send did not reach adapter");
        intel_codec = intel_pcie_avst_codec::type_id::create("intel_codec");
        packet = intel_codec.encode(sent);
        expect_true(packet != null, "Intel codec rejected routed Memory packet");

        if (packet != null) begin
            expect_true(packet.bar == 4 && packet.pfnum == 6 && packet.vfactive && packet.vfnum == 101,
                "Intel codec sideband differs from frozen target");
        end
        mem.addr = target.bar_lease.base + 'hffc;
        mem.length = 2;
        mem.last_be = 1;
        expect_true(!driver.route_tlp(mem, why), "driver accepted cross-window tail");
        mem.addr = 64'hfffffffffffffffc;
        expect_true(!driver.route_tlp(mem, why), "driver accepted 64-bit address overflow");
        mem.addr = target.bar_lease.base;
        mem.length = 1;
        mem.last_be = 0;
        mem.first_be = 0;
        expect_true(!driver.route_tlp(mem, why), "driver accepted empty BE");
        mem.first_be = 4'hf;
        cpl = pcie_tl_cpl_tlp::type_id::create("cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.type_f = TLP_TYPE_CPL;
        cpl.length = 0;
        cpl.requester_id = 16'h9011;
        cpl.completer_id = 16'hf000;
        expect_true(driver.route_tlp(cpl, why), why);
        expect_true(cpl.cq_route.vf_index == 101 && cpl.requester_id == 16'h9011 &&
            cpl.completer_id == 16'hf000, "driver altered Completion identity");
        driver.send_tlp(cpl);
        expect_true(adapter.tlm_tx_fifo.try_get(sent), "Completion did not reach adapter");
        packet = intel_codec.encode(sent);
        expect_true(packet != null, "Intel codec rejected Completion");

        if (packet != null) begin
            expect_true(packet.pfnum == 6 && packet.vfactive && packet.vfnum == 101,
                "Completion Intel sideband uses wrong identity");
        end
        cfg_tlp = pcie_tl_cfg_tlp::type_id::create("config");
        cfg_tlp.kind = TLP_CFG_RD0;
        expect_true(!driver.route_tlp(cfg_tlp, why), "Config TLP accepted");
        void'($value$plusargs("PROJECT_BAR_NEGATIVE=%s", negative));

        if (negative == "config") begin
            driver.send_tlp(cfg_tlp);
        end

        if (negative == "window") begin
            mem.addr = 64'hdeadbeef;
            driver.send_tlp(mem);
        end
        expect_true(registry.print_bar_map(why, 1), why);
        expect_true(registry.print_bar_map(why, 1), why);
        expect_true(registry.print_bar_map(why), why);
        `uvm_info("BAR_CHECK", $sformatf("checks=%0d", checks), UVM_LOW)
        phase.drop_objection(this);
    endtask
endpackage
