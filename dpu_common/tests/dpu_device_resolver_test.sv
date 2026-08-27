`ifndef DPU_DEVICE_RESOLVER_TEST_SV
`define DPU_DEVICE_RESOLVER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_device_resolver_test extends uvm_test;
    `uvm_component_utils(dpu_device_resolver_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_bar_request make_bar(
        input dpu_function_kind_e kind,
        input dpu_bar_role_e role
    );
        dpu_bar_request request;

        request = dpu_bar_request::type_id::create("bar_request");
        request.role = role;
        request.placement = DPU_ALLOC_AUTO;
        request.pinned_base = '0;
        case (kind)
            DPU_FUNCTION_PF: case (role)
                DPU_BAR_DEVICE_MEMORY: begin
                    request.even_bar_id = 0;
                    request.size = 64'h0000_0000_0200_0000;
                    request.alignment = 64'h0000_0000_0200_0000;
                end
                DPU_BAR_MAILBOX: begin
                    request.even_bar_id = 2;
                    request.size = 64'h0000_0000_0001_0000;
                    request.alignment = 64'h0000_0000_0001_0000;
                end
                DPU_BAR_MSIX: begin
                    request.even_bar_id = 4;
                    request.size = 64'h0000_0000_0001_0000;
                    request.alignment = 64'h0000_0000_0001_0000;
                end
                default: `uvm_fatal("RESOLVER_TEST", "unsupported PF BAR role")
            endcase
            DPU_FUNCTION_VF: case (role)
                DPU_BAR_DEVICE_MEMORY: begin
                    request.even_bar_id = 0;
                    request.size = 64'h0000_0000_0000_4000;
                    request.alignment = 64'h0000_0000_0000_4000;
                end
                DPU_BAR_MAILBOX: begin
                    request.even_bar_id = 2;
                    request.size = 64'h0000_0000_0000_4000;
                    request.alignment = 64'h0000_0000_0000_4000;
                end
                DPU_BAR_MSIX: begin
                    request.even_bar_id = 4;
                    request.size = 64'h0000_0000_0000_8000;
                    request.alignment = 64'h0000_0000_0000_8000;
                end
                default: `uvm_fatal("RESOLVER_TEST", "unsupported VF BAR role")
            endcase
            default: `uvm_fatal("RESOLVER_TEST", "unsupported function kind")
        endcase
        return request;
    endfunction

    function automatic void expect_bar_request(
        input dpu_bar_request request,
        input dpu_bar_role_e role,
        input int unsigned even_bar_id,
        input bit [63:0] size,
        input bit [63:0] alignment
    );
        if ((request.role != role) || (request.even_bar_id != even_bar_id) ||
            (request.size != size) || (request.alignment != alignment))
            `uvm_fatal("RESOLVER_TEST", "BAR request does not match literal profile")
    endfunction

    function automatic dpu_function_cfg make_function(
        input int unsigned host_id,
        input int unsigned pf_id,
        input dpu_function_kind_e kind,
        input int unsigned vf_id,
        input int unsigned segment_id
    );
        dpu_function_cfg function_cfg;

        function_cfg = dpu_function_cfg::type_id::create("function_cfg");
        function_cfg.key.host_id = host_id;
        function_cfg.key.pf_id = pf_id;
        function_cfg.key.kind = kind;
        function_cfg.key.vf_id = vf_id;
        function_cfg.domain_key.host_id = host_id;
        function_cfg.domain_key.segment_id = segment_id;
        function_cfg.bdf_mode = DPU_ALLOC_AUTO;
        function_cfg.pinned_bdf = '0;
        function_cfg.bars.push_back(make_bar(kind, DPU_BAR_DEVICE_MEMORY));
        function_cfg.bars.push_back(make_bar(kind, DPU_BAR_MAILBOX));
        function_cfg.bars.push_back(make_bar(kind, DPU_BAR_MSIX));
        return function_cfg;
    endfunction

    function automatic dpu_host_cfg make_host(
        input int unsigned host_id,
        input int unsigned segment_id
    );
        dpu_host_cfg host;
        dpu_pcie_domain_cfg domain;
        dpu_bdf_range_t bdf_range;
        dpu_mmio_window_cfg window;

        host = dpu_host_cfg::type_id::create("host");
        host.host_id = host_id;
        domain = dpu_pcie_domain_cfg::type_id::create("domain");
        domain.key.host_id = host_id;
        domain.key.segment_id = segment_id;
        bdf_range.first_bdf = 16'h0010;
        bdf_range.last_bdf = 16'h00ff;
        domain.bdf_ranges.push_back(bdf_range);
        window = dpu_mmio_window_cfg::type_id::create("window");
        window.base = 64'h0000_0001_0000_0000;
        window.limit = 64'h0000_0002_0000_0000;
        window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
        window.allowed_roles.push_back(DPU_BAR_MAILBOX);
        window.allowed_roles.push_back(DPU_BAR_MSIX);
        domain.mmio_windows.push_back(window);
        host.pcie_domains.push_back(domain);
        return host;
    endfunction

    function automatic dpu_service_decl make_service(
        input dpu_service_kind_e service_kind,
        input int unsigned service_instance_id
    );
        dpu_service_decl service;

        service = dpu_service_decl::type_id::create("service");
        service.service_kind = service_kind;
        service.service_instance_id = service_instance_id;
        return service;
    endfunction

    function automatic dpu_device_cfg make_valid_cfg();
        dpu_device_cfg cfg;
        dpu_function_cfg vf7;

        cfg = dpu_device_cfg::type_id::create("cfg");
        cfg.hosts.push_back(make_host(0, 0));
        cfg.hosts.push_back(make_host(1, 1));
        cfg.functions.push_back(make_function(0, 0, DPU_FUNCTION_PF, 0, 0));
        cfg.functions.push_back(make_function(1, 0, DPU_FUNCTION_PF, 0, 1));
        cfg.functions.push_back(make_function(1, 3, DPU_FUNCTION_PF, 0, 1));
        vf7 = make_function(1, 3, DPU_FUNCTION_VF, 7, 1);
        vf7.services.push_back(make_service(DPU_SERVICE_VIO_NET, 0));
        vf7.services.push_back(make_service(DPU_SERVICE_RDMA, 0));
        cfg.functions.push_back(vf7);
        cfg.af_request.mode = DPU_AF_SELECTED;
        cfg.af_request.requester.host_id = 1;
        cfg.af_request.requester.pf_id = 0;
        cfg.af_request.requester.kind = DPU_FUNCTION_PF;
        cfg.af_request.requester.vf_id = 0;
        return cfg;
    endfunction

    function automatic dpu_device_cfg clone_cfg(input dpu_device_cfg source);
        dpu_device_cfg clone;

        clone = dpu_device_cfg::type_id::create("clone");
        clone.copy_from(source);
        return clone;
    endfunction

    function automatic void expect_valid(
        input dpu_device_resolver resolver,
        input dpu_device_cfg cfg
    );
        string why;

        if (!resolver.validate(cfg, why))
            `uvm_fatal("RESOLVER_TEST", {"valid configuration rejected: ", why})
    endfunction

    function automatic bit contains(
        input string text,
        input string expected
    );
        int index;

        if (expected.len() == 0)
            return 1;
        if (text.len() < expected.len())
            return 0;
        for (index = 0; index <= text.len() - expected.len(); index++) begin
            if (text.substr(index, index + expected.len() - 1) == expected)
                return 1;
        end
        return 0;
    endfunction

    function automatic void expect_invalid(
        input dpu_device_resolver resolver,
        input dpu_device_cfg cfg,
        input string expected
    );
        string why;

        if (resolver.validate(cfg, why))
            `uvm_fatal("RESOLVER_TEST", {"configuration unexpectedly passed: ", expected})
        if (!contains(why, expected))
            `uvm_fatal("RESOLVER_TEST",
                $sformatf("expected diagnostic '%s', got '%s'", expected, why))
    endfunction

    // Catches a regression where the validator rejects a legal sparse topology.
    function void test_valid_sparse_config(input dpu_device_resolver resolver);
        expect_valid(resolver, make_valid_cfg());
    endfunction

    // Catches a DUT BAR profile that disagrees with real BAR0/1, BAR2/3, or BAR4/5.
    function void test_real_dut_bar_profile_literals(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        expect_bar_request(cfg.functions[0].bars[0], DPU_BAR_DEVICE_MEMORY,
                           0, 64'h0000_0000_0200_0000,
                           64'h0000_0000_0200_0000);
        expect_bar_request(cfg.functions[0].bars[1], DPU_BAR_MAILBOX,
                           2, 64'h0000_0000_0001_0000,
                           64'h0000_0000_0001_0000);
        expect_bar_request(cfg.functions[0].bars[2], DPU_BAR_MSIX,
                           4, 64'h0000_0000_0001_0000,
                           64'h0000_0000_0001_0000);
        expect_bar_request(cfg.functions[3].bars[0], DPU_BAR_DEVICE_MEMORY,
                           0, 64'h0000_0000_0000_4000,
                           64'h0000_0000_0000_4000);
        expect_bar_request(cfg.functions[3].bars[1], DPU_BAR_MAILBOX,
                           2, 64'h0000_0000_0000_4000,
                           64'h0000_0000_0000_4000);
        expect_bar_request(cfg.functions[3].bars[2], DPU_BAR_MSIX,
                           4, 64'h0000_0000_0000_8000,
                           64'h0000_0000_0000_8000);
        expect_valid(resolver, cfg);
    endfunction

    // Catches shallow child copies that let a clone mutate its source host.
    function void test_copy_from_is_deep(input dpu_device_resolver resolver);
        dpu_device_cfg source;
        dpu_device_cfg clone;

        source = make_valid_cfg();
        clone = clone_cfg(source);
        clone.dut_caps.max_hosts = 3;
        clone.hosts[0].host_id = 3;
        clone.hosts[1].pcie_domains[0].mmio_windows[0].base =
            64'h0000_0003_0000_0000;
        clone.functions[3].bars[0].size = 64'h0000_0000_0000_1000;
        clone.functions[3].services[0].service_instance_id = 9;
        clone.af_request.requester.host_id = 0;
        if ((source.dut_caps.max_hosts != 2) ||
            (source.hosts[0].host_id != 0) ||
            (source.hosts[1].pcie_domains[0].mmio_windows[0].base !=
             64'h0000_0001_0000_0000) ||
            (source.functions[3].bars[0].size != 64'h0000_0000_0000_4000) ||
            (source.functions[3].services[0].service_instance_id != 0) ||
            (source.af_request.requester.host_id != 1))
            `uvm_fatal("RESOLVER_TEST", "device config copy shares owned children")
        expect_valid(resolver, source);
    endfunction

    // Catches a resolver change that accepts duplicate host identities.
    function void test_duplicate_host_key(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;
        dpu_host_cfg duplicate;

        cfg = make_valid_cfg();
        duplicate = dpu_host_cfg::type_id::create("duplicate_host");
        duplicate.copy_from(cfg.hosts[0]);
        cfg.hosts.push_back(duplicate);
        expect_invalid(resolver, cfg, "duplicate host key h0");
    endfunction

    // Catches a resolver change that accepts duplicate domain identities.
    function void test_duplicate_pcie_domain_key(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;
        dpu_pcie_domain_cfg duplicate;

        cfg = make_valid_cfg();
        duplicate = dpu_pcie_domain_cfg::type_id::create("duplicate_domain");
        duplicate.copy_from(cfg.hosts[1].pcie_domains[0]);
        cfg.hosts[1].pcie_domains.push_back(duplicate);
        expect_invalid(resolver, cfg, "duplicate PCIe domain key h1.s1");
    endfunction

    // Catches a function whose domain host is not its function-key host.
    function void test_function_domain_other_host(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[2].domain_key.host_id = 0;
        cfg.functions[2].domain_key.segment_id = 0;
        expect_invalid(resolver, cfg,
                       "function refers to a domain on another host h1.pf3.k0.vf0");
    endfunction

    // Catches acceptance of a VF without its explicitly declared parent PF.
    function void test_vf_requires_declared_parent_pf(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions.delete(2);
        expect_invalid(resolver, cfg,
                       "VF function requires its declared parent PF h1.pf3.k1.vf7");
    endfunction

    // Catches a resolver change that accepts duplicate function identities.
    function void test_duplicate_function_key(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;
        dpu_function_cfg duplicate;

        cfg = make_valid_cfg();
        duplicate = dpu_function_cfg::type_id::create("duplicate_function");
        duplicate.copy_from(cfg.functions[2]);
        cfg.functions.push_back(duplicate);
        expect_invalid(resolver, cfg, "duplicate function key h1.pf3.k0.vf0");
    endfunction

    // Catches a resolver change that accepts duplicate service identities.
    function void test_duplicate_service_key(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;
        dpu_service_decl duplicate;

        cfg = make_valid_cfg();
        duplicate = dpu_service_decl::type_id::create("duplicate_service");
        duplicate.copy_from(cfg.functions[3].services[0]);
        cfg.functions[3].services.push_back(duplicate);
        expect_invalid(resolver, cfg,
                       "duplicate service key h1.pf3.k1.vf7.svc0.i0");
    endfunction

    // Catches a profile limit change that permits two VIO-net instances per function.
    function void test_one_vio_net_instance_per_function(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[3].services.push_back(make_service(DPU_SERVICE_VIO_NET, 1));
        expect_invalid(resolver, cfg,
                       "current DUT profile permits one VIO-net instance per function h1.pf3.k1.vf7");
    endfunction

    // Catches acceptance of an AF requester that is not a declared PF0.
    function void test_af_requester_must_be_declared_pf0(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.af_request.requester.pf_id = 3;
        expect_invalid(resolver, cfg,
                       "AF requester must be a declared PF0 h1.pf3.k0.vf0");
    endfunction

    // Catches acceptance of two BAR requests with the same role on one function.
    function void test_bar_request_duplicate_role(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;
        dpu_bar_request duplicate;

        cfg = make_valid_cfg();
        duplicate = dpu_bar_request::type_id::create("duplicate_bar");
        duplicate.copy_from(cfg.functions[3].bars[0]);
        cfg.functions[3].bars.push_back(duplicate);
        expect_invalid(resolver, cfg,
                       "BAR request has duplicate role h1.pf3.k1.vf7");
    endfunction

    // Catches a BAR role/pair mismatch accepted against the DUT profile.
    function void test_bar_request_role_pair_profile_mismatch(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[3].bars[0].even_bar_id = 4;
        expect_invalid(resolver, cfg,
                       "BAR request role/pair does not match the DUT profile h1.pf3.k1.vf7");
    endfunction

    virtual task run_phase(uvm_phase phase);
        dpu_device_resolver resolver;

        phase.raise_objection(this);
        resolver = dpu_device_resolver::type_id::create("resolver");
        test_valid_sparse_config(resolver);
        test_real_dut_bar_profile_literals(resolver);
        test_copy_from_is_deep(resolver);
        test_duplicate_host_key(resolver);
        test_duplicate_pcie_domain_key(resolver);
        test_function_domain_other_host(resolver);
        test_vf_requires_declared_parent_pf(resolver);
        test_duplicate_function_key(resolver);
        test_duplicate_service_key(resolver);
        test_one_vio_net_instance_per_function(resolver);
        test_af_requester_must_be_declared_pf0(resolver);
        test_bar_request_duplicate_role(resolver);
        test_bar_request_role_pair_profile_mismatch(resolver);
        phase.drop_objection(this);
    endtask
endclass : dpu_device_resolver_test

`endif // DPU_DEVICE_RESOLVER_TEST_SV
