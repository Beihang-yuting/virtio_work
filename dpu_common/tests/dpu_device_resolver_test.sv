`ifndef DPU_DEVICE_RESOLVER_TEST_SV
`define DPU_DEVICE_RESOLVER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_snapshot_integrity_probe extends dpu_device_snapshot;
    `uvm_object_utils(dpu_snapshot_integrity_probe)

    function new(string name = "dpu_snapshot_integrity_probe");
        super.new(name);
    endfunction

    function void corrupt_add_reverse_only(
        input dpu_pcie_function_id_t pcie_id,
        input dpu_function_key_t key
    );
        m_reverse_functions[dpu_pcie_function_id_name(pcie_id)] = key;
    endfunction

    function void corrupt_add_unordered_bar(
        input dpu_function_key_t key,
        input dpu_pcie_domain_key_t domain,
        input dpu_bar_pair_lease_t bar
    );
        string bar_name;

        bar_name = dpu_function_bar_key_name(key, bar.role);
        m_bars[bar_name] = bar;
        m_bar_domains[bar_name] = domain;
        m_bar_functions[bar_name] = key;
    endfunction

    function void corrupt_delete_bar_domain(
        input dpu_function_key_t key,
        input dpu_bar_role_e role
    );
        m_bar_domains.delete(dpu_function_bar_key_name(key, role));
    endfunction

    function void corrupt_bar_owner(
        input dpu_function_key_t key,
        input dpu_bar_role_e role,
        input dpu_function_key_t wrong_owner
    );
        m_bar_functions[dpu_function_bar_key_name(key, role)] = wrong_owner;
    endfunction

    function void corrupt_bar_domain(
        input dpu_function_key_t key,
        input dpu_bar_role_e role,
        input dpu_pcie_domain_key_t wrong_domain
    );
        m_bar_domains[dpu_function_bar_key_name(key, role)] = wrong_domain;
    endfunction

    function void corrupt_bar_base(
        input dpu_function_key_t key,
        input dpu_bar_role_e role,
        input bit [63:0] wrong_base
    );
        m_bars[dpu_function_bar_key_name(key, role)].base = wrong_base;
    endfunction

    function void corrupt_bar_role(
        input dpu_function_key_t key,
        input dpu_bar_role_e indexed_role,
        input dpu_bar_role_e wrong_role
    );
        m_bars[dpu_function_bar_key_name(key, indexed_role)].role = wrong_role;
    endfunction
endclass : dpu_snapshot_integrity_probe

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

    function automatic dpu_device_cfg make_single_pf_cfg();
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        while (cfg.hosts.size() > 1)
            cfg.hosts.delete(cfg.hosts.size() - 1);
        while (cfg.functions.size() > 1)
            cfg.functions.delete(cfg.functions.size() - 1);
        cfg.af_request.requester = cfg.functions[0].key;
        return cfg;
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

    function automatic void expect_resolved(
        input dpu_device_resolver resolver,
        input dpu_device_cfg cfg,
        output dpu_device_snapshot snapshot
    );
        string why;

        snapshot = null;
        if (!resolver.resolve(cfg, snapshot, why))
            `uvm_fatal("RESOLVER_TEST", {"valid resolution rejected: ", why})
        if ((snapshot == null) || !snapshot.is_frozen())
            `uvm_fatal("RESOLVER_TEST", "resolver did not publish a frozen snapshot")
    endfunction

    function automatic void expect_resolution_invalid(
        input dpu_device_resolver resolver,
        input dpu_device_cfg cfg,
        input string expected
    );
        dpu_device_snapshot snapshot;
        string why;

        snapshot = null;
        if (resolver.resolve(cfg, snapshot, why))
            `uvm_fatal("RESOLVER_TEST",
                {"configuration unexpectedly resolved: ", expected})
        if (snapshot != null)
            `uvm_fatal("RESOLVER_TEST", "failed resolution published a snapshot")
        if (!contains(why, expected))
            `uvm_fatal("RESOLVER_TEST",
                $sformatf("expected resolution diagnostic '%s', got '%s'",
                          expected, why))
    endfunction

    function automatic void expect_pcie_id(
        input dpu_device_snapshot snapshot,
        input dpu_function_key_t key,
        input int unsigned host_id,
        input int unsigned segment_id,
        input bit [15:0] bdf
    );
        dpu_pcie_function_id_t pcie_id;
        string why;

        if (!snapshot.get_pcie_id(key, pcie_id, why))
            `uvm_fatal("RESOLVER_TEST", {"missing PCIe ID: ", why})
        if ((pcie_id.domain.host_id != host_id) ||
            (pcie_id.domain.segment_id != segment_id) ||
            (pcie_id.bdf != bdf))
            `uvm_fatal("RESOLVER_TEST",
                $sformatf("unexpected PCIe ID for %s: h%0d.s%0d.b%04h",
                          dpu_function_key_name(key), pcie_id.domain.host_id,
                          pcie_id.domain.segment_id, pcie_id.bdf))
    endfunction

    function automatic void expect_bar(
        input dpu_device_snapshot snapshot,
        input dpu_function_key_t key,
        input dpu_bar_role_e role,
        input int unsigned even_bar_id,
        input bit [63:0] base,
        input bit [63:0] size
    );
        dpu_bar_pair_lease_t bar;
        string why;

        if (!snapshot.get_bar(key, role, bar, why))
            `uvm_fatal("RESOLVER_TEST", {"missing BAR: ", why})
        if ((bar.role != role) || (bar.even_bar_id != even_bar_id) ||
            (bar.base != base) || (bar.size != size))
            `uvm_fatal("RESOLVER_TEST",
                $sformatf("unexpected BAR for %s role %0d: BAR%0d %016h/%016h",
                          dpu_function_key_name(key), role, bar.even_bar_id,
                          bar.base, bar.size))
    endfunction

    function automatic void set_pf_bar_profile(
        input dpu_device_cfg cfg,
        input dpu_bar_role_e role,
        input int unsigned even_bar_id,
        input bit [63:0] size,
        input bit [63:0] alignment
    );
        foreach (cfg.dut_caps.bar_profiles[index]) begin
            if ((cfg.dut_caps.bar_profiles[index].kind == DPU_FUNCTION_PF) &&
                (cfg.dut_caps.bar_profiles[index].role == role)) begin
                cfg.dut_caps.bar_profiles[index].even_bar_id = even_bar_id;
                cfg.dut_caps.bar_profiles[index].size = size;
                cfg.dut_caps.bar_profiles[index].alignment = alignment;
                return;
            end
        end
        `uvm_fatal("RESOLVER_TEST", "missing PF BAR profile in fixture")
    endfunction

    function automatic dpu_snapshot_integrity_probe make_mutable_snapshot();
        dpu_snapshot_integrity_probe snapshot;
        dpu_dut_caps caps;
        dpu_function_key_t af_key;
        dpu_function_key_t peer_key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bar;
        string why;

        snapshot = dpu_snapshot_integrity_probe::type_id::create(
            "mutable_snapshot");
        caps = dpu_dut_caps::type_id::create("snapshot_caps");
        af_key.host_id = 0;
        af_key.pf_id = 0;
        af_key.kind = DPU_FUNCTION_PF;
        af_key.vf_id = 0;
        peer_key.host_id = 0;
        peer_key.pf_id = 1;
        peer_key.kind = DPU_FUNCTION_PF;
        peer_key.vf_id = 0;
        pcie_id.domain.host_id = 0;
        pcie_id.domain.segment_id = 0;
        pcie_id.bdf = 16'h0010;
        if (!snapshot.set_dut_caps(caps, why) ||
            !snapshot.add_function(af_key, pcie_id, why))
            `uvm_fatal("RESOLVER_TEST", {"snapshot fixture failed: ", why})
        pcie_id.bdf = 16'h0011;
        if (!snapshot.add_function(peer_key, pcie_id, why))
            `uvm_fatal("RESOLVER_TEST", {"snapshot fixture failed: ", why})
        bar.role = DPU_BAR_DEVICE_MEMORY;
        bar.even_bar_id = 0;
        bar.base = 64'h0000_0001_0000_0000;
        bar.size = 64'h0000_0000_0200_0000;
        if (!snapshot.add_bar(af_key, bar, why))
            `uvm_fatal("RESOLVER_TEST", {"snapshot fixture failed: ", why})
        bar.role = DPU_BAR_MAILBOX;
        bar.even_bar_id = 2;
        bar.base = 64'h0000_0001_0200_0000;
        bar.size = 64'h0000_0000_0001_0000;
        if (!snapshot.add_bar(peer_key, bar, why) ||
            !snapshot.set_expected_af(af_key, why))
            `uvm_fatal("RESOLVER_TEST", {"snapshot fixture failed: ", why})
        return snapshot;
    endfunction

    function automatic bit freeze_rejects_corruption(
        input dpu_snapshot_integrity_probe snapshot,
        input string expected
    );
        string why;

        if (snapshot.freeze(why)) begin
            `uvm_error("RESOLVER_TEST",
                {"malformed snapshot unexpectedly froze: ", expected})
            return 0;
        end
        if (snapshot.is_frozen())
            `uvm_fatal("RESOLVER_TEST", "failed freeze published snapshot state")
        if (!contains(why, expected))
            `uvm_fatal("RESOLVER_TEST",
                $sformatf("expected freeze diagnostic '%s', got '%s'",
                          expected, why))
        return 1;
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

    // Catches AUTO allocation running before PINNED allocation, non-canonical
    // function ordering, or domain-less BDF/BAR uniqueness maps.
    function void test_deterministic_domain_aware_allocation(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg_a;
        dpu_device_cfg cfg_b;
        dpu_device_snapshot snapshot_a;
        dpu_device_snapshot snapshot_b;
        dpu_function_key_t keys[$];
        dpu_function_key_t reverse_key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_address_match_t match;
        dpu_bar_pair_lease_t bar;
        dpu_bdf_range_t low_bdf_range;
        string why;

        cfg_a = make_valid_cfg();
        low_bdf_range.first_bdf = 16'h0010;
        low_bdf_range.last_bdf = 16'h0013;
        foreach (cfg_a.hosts[host_index]) begin
            dpu_mmio_window_cfg low_window;

            cfg_a.hosts[host_index].pcie_domains[0].bdf_ranges[0].first_bdf =
                16'h0020;
            cfg_a.hosts[host_index].pcie_domains[0].bdf_ranges[0].last_bdf =
                16'h0023;
            cfg_a.hosts[host_index].pcie_domains[0].bdf_ranges.push_back(
                low_bdf_range);
            cfg_a.hosts[host_index].pcie_domains[0].mmio_windows[0].base =
                64'h0000_0002_0000_0000;
            cfg_a.hosts[host_index].pcie_domains[0].mmio_windows[0].limit =
                64'h0000_0003_0000_0000;
            low_window = dpu_mmio_window_cfg::type_id::create("low_window");
            low_window.base = 64'h0000_0001_0000_0000;
            low_window.limit = 64'h0000_0002_0000_0000;
            low_window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
            low_window.allowed_roles.push_back(DPU_BAR_MAILBOX);
            low_window.allowed_roles.push_back(DPU_BAR_MSIX);
            cfg_a.hosts[host_index].pcie_domains[0].mmio_windows.push_back(
                low_window);
        end
        cfg_a.hosts[1].pcie_domains[0].reserved_bdfs.push_back(16'h0011);
        cfg_a.functions[2].bdf_mode = DPU_ALLOC_PINNED;
        cfg_a.functions[2].pinned_bdf = 16'h0010;
        cfg_a.functions[2].bars[0].placement = DPU_ALLOC_PINNED;
        cfg_a.functions[2].bars[0].pinned_base = 64'h0000_0001_0000_0000;

        cfg_b = clone_cfg(cfg_a);
        cfg_b.hosts.reverse();
        cfg_b.functions.reverse();
        foreach (cfg_b.hosts[host_index]) begin
            cfg_b.hosts[host_index].pcie_domains[0].bdf_ranges.reverse();
            cfg_b.hosts[host_index].pcie_domains[0].mmio_windows.reverse();
        end
        foreach (cfg_b.functions[index])
            cfg_b.functions[index].bars.reverse();

        expect_resolved(resolver, cfg_a, snapshot_a);
        expect_resolved(resolver, cfg_b, snapshot_b);

        expect_pcie_id(snapshot_a, cfg_a.functions[0].key, 0, 0, 16'h0010);
        expect_pcie_id(snapshot_a, cfg_a.functions[1].key, 1, 1, 16'h0012);
        expect_pcie_id(snapshot_a, cfg_a.functions[2].key, 1, 1, 16'h0010);
        expect_pcie_id(snapshot_a, cfg_a.functions[3].key, 1, 1, 16'h0013);
        expect_pcie_id(snapshot_b, cfg_a.functions[0].key, 0, 0, 16'h0010);
        expect_pcie_id(snapshot_b, cfg_a.functions[1].key, 1, 1, 16'h0012);
        expect_pcie_id(snapshot_b, cfg_a.functions[2].key, 1, 1, 16'h0010);
        expect_pcie_id(snapshot_b, cfg_a.functions[3].key, 1, 1, 16'h0013);

        expect_bar(snapshot_a, cfg_a.functions[0].key,
                   DPU_BAR_DEVICE_MEMORY, 0,
                   64'h0000_0001_0000_0000, 64'h0000_0000_0200_0000);
        expect_bar(snapshot_a, cfg_a.functions[2].key,
                   DPU_BAR_DEVICE_MEMORY, 0,
                   64'h0000_0001_0000_0000, 64'h0000_0000_0200_0000);
        expect_bar(snapshot_a, cfg_a.functions[1].key,
                   DPU_BAR_DEVICE_MEMORY, 0,
                   64'h0000_0001_0200_0000, 64'h0000_0000_0200_0000);
        expect_bar(snapshot_b, cfg_a.functions[1].key,
                   DPU_BAR_DEVICE_MEMORY, 0,
                   64'h0000_0001_0200_0000, 64'h0000_0000_0200_0000);

        snapshot_a.list_functions(keys);
        if ((keys.size() != 4) ||
            !dpu_same_function_key(keys[0], cfg_a.functions[0].key) ||
            !dpu_same_function_key(keys[1], cfg_a.functions[1].key) ||
            !dpu_same_function_key(keys[2], cfg_a.functions[2].key) ||
            !dpu_same_function_key(keys[3], cfg_a.functions[3].key))
            `uvm_fatal("RESOLVER_TEST", "function list is not canonical")

        if (!snapshot_a.get_pcie_id(cfg_a.functions[2].key, pcie_id, why) ||
            !snapshot_a.find_function(pcie_id, reverse_key, why) ||
            !dpu_same_function_key(reverse_key, cfg_a.functions[2].key))
            `uvm_fatal("RESOLVER_TEST", "forward/reverse BDF queries disagree")
        if (!snapshot_a.resolve_bar_address(
                pcie_id.domain, 64'h0000_0001_0000_1234, match, why) ||
            !dpu_same_function_key(match.function_key, cfg_a.functions[2].key) ||
            (match.role != DPU_BAR_DEVICE_MEMORY) ||
            (match.bar_base != 64'h0000_0001_0000_0000) ||
            (match.bar_size != 64'h0000_0000_0200_0000) ||
            (match.offset != 64'h0000_0000_0000_1234))
            `uvm_fatal("RESOLVER_TEST", "BAR reverse lookup disagrees with lease")
        if (!snapshot_a.get_bar(cfg_a.functions[2].key,
                                DPU_BAR_DEVICE_MEMORY, bar, why) ||
            (bar.base != match.bar_base) || (bar.size != match.bar_size))
            `uvm_fatal("RESOLVER_TEST", "BAR forward/reverse queries disagree")
    endfunction

    // Catches an AUTO BAR allocator that does not align window bases or scan
    // past a reserved interval to the next legal aligned address.
    function void test_auto_bar_lowest_aligned_after_reservation(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;
        dpu_device_snapshot snapshot;
        dpu_address_range_t reservation;

        cfg = make_valid_cfg();
        cfg.hosts[0].pcie_domains[0].mmio_windows[0].base =
            64'h0000_0001_0001_0000;
        reservation.base = 64'h0000_0001_0200_0000;
        reservation.limit = 64'h0000_0001_0400_0000;
        cfg.hosts[0].pcie_domains[0].reserved_mmio_ranges.push_back(reservation);
        expect_resolved(resolver, cfg, snapshot);
        expect_bar(snapshot, cfg.functions[0].key, DPU_BAR_DEVICE_MEMORY, 0,
                   64'h0000_0001_0400_0000, 64'h0000_0000_0200_0000);
    endfunction

    // Catches omission of reserved-BDF rejection for exact requests.
    function void test_pinned_bdf_reserved(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.hosts[0].pcie_domains[0].reserved_bdfs.push_back(16'h0010);
        cfg.functions[0].bdf_mode = DPU_ALLOC_PINNED;
        cfg.functions[0].pinned_bdf = 16'h0010;
        expect_resolution_invalid(resolver, cfg, "reserved BDF");
    endfunction

    // Catches omission of configured-range checking for exact BDF requests.
    function void test_pinned_bdf_out_of_range(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[0].bdf_mode = DPU_ALLOC_PINNED;
        cfg.functions[0].pinned_bdf = 16'h0100;
        expect_resolution_invalid(resolver, cfg, "outside configured BDF ranges");
    endfunction

    // Catches a BDF reverse index that silently overwrites a same-domain owner.
    function void test_pinned_bdf_same_domain_duplicate(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[1].bdf_mode = DPU_ALLOC_PINNED;
        cfg.functions[1].pinned_bdf = 16'h0020;
        cfg.functions[2].bdf_mode = DPU_ALLOC_PINNED;
        cfg.functions[2].pinned_bdf = 16'h0020;
        expect_resolution_invalid(resolver, cfg, "duplicate BDF");
    endfunction

    // Catches AUTO BDF wraparound or allocation outside declared ranges.
    function void test_auto_bdf_exhaustion(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.hosts[1].pcie_domains[0].bdf_ranges[0].last_bdf = 16'h0011;
        cfg.hosts[1].pcie_domains[0].reserved_bdfs.push_back(16'h0011);
        expect_resolution_invalid(resolver, cfg, "BDF space exhausted");
    endfunction

    // Catches AUTO allocation probing the entire 16-bit BDF space instead of
    // iterating the configured high ranges, and catches a 16-bit loop counter
    // that wraps before assigning the inclusive 16'hffff endpoint.
    function void test_auto_bdf_scans_sorted_ranges_to_ffff(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;
        dpu_device_snapshot snapshot;
        dpu_function_cfg function_cfg;
        dpu_function_key_t last_key;

        cfg = dpu_device_cfg::type_id::create("high_bdf_cfg");
        cfg.dut_caps.max_hosts = 4;
        cfg.dut_caps.max_pfs_per_host = 16;
        cfg.dut_caps.max_vfs_per_pf = 16;
        for (int unsigned host_id = 0; host_id < 4; host_id++) begin
            dpu_host_cfg host;

            host = make_host(host_id, host_id);
            host.pcie_domains[0].bdf_ranges[0].first_bdf = 16'hff00;
            host.pcie_domains[0].bdf_ranges[0].last_bdf = 16'hffff;
            for (int unsigned range_index = 1; range_index < 64;
                 range_index++) begin
                dpu_bdf_range_t repeated_range;

                repeated_range.first_bdf = 16'hff00;
                repeated_range.last_bdf = 16'hffff;
                host.pcie_domains[0].bdf_ranges.push_back(repeated_range);
            end
            cfg.hosts.push_back(host);
            for (int unsigned pf_id = 0; pf_id < 16; pf_id++) begin
                function_cfg = make_function(host_id, pf_id,
                                             DPU_FUNCTION_PF, 0, host_id);
                function_cfg.bars.delete();
                if ((host_id == 0) && (pf_id == 0))
                    function_cfg.bars.push_back(
                        make_bar(DPU_FUNCTION_PF, DPU_BAR_DEVICE_MEMORY));
                cfg.functions.push_back(function_cfg);
                for (int unsigned vf_id = 0; vf_id < 15; vf_id++) begin
                    function_cfg = make_function(host_id, pf_id,
                                                 DPU_FUNCTION_VF, vf_id,
                                                 host_id);
                    function_cfg.bars.delete();
                    cfg.functions.push_back(function_cfg);
                end
            end
        end
        cfg.af_request.requester.host_id = 0;
        cfg.af_request.requester.pf_id = 0;
        cfg.af_request.requester.kind = DPU_FUNCTION_PF;
        cfg.af_request.requester.vf_id = 0;

        expect_resolved(resolver, cfg, snapshot);
        last_key.host_id = 3;
        last_key.pf_id = 15;
        last_key.kind = DPU_FUNCTION_VF;
        last_key.vf_id = 14;
        expect_pcie_id(snapshot, last_key, 3, 3, 16'hffff);
    endfunction

    // Catches acceptance of an odd or out-of-range 64-bit BAR pair.
    function void test_bar_pair_shape(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[0].bars[0].even_bar_id = 1;
        expect_resolution_invalid(resolver, cfg, "role/pair");
        cfg = make_valid_cfg();
        cfg.functions[0].bars[0].even_bar_id = 6;
        expect_resolution_invalid(resolver, cfg, "role/pair");
    endfunction

    // Catches acceptance of a correctly paired request labeled with the wrong role.
    function void test_bar_role_pair_mismatch_on_resolve(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[0].bars[0].role = DPU_BAR_MAILBOX;
        expect_resolution_invalid(resolver, cfg, "role/pair");
    endfunction

    // Catches acceptance of a PINNED BAR base that violates its alignment.
    function void test_pinned_bar_misaligned(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[0].bars[0].placement = DPU_ALLOC_PINNED;
        cfg.functions[0].bars[0].pinned_base = 64'h0000_0001_0001_0000;
        expect_resolution_invalid(resolver, cfg, "misaligned BAR base");
    endfunction

    // Catches omission of domain-qualified MMIO reservation checks.
    function void test_pinned_bar_reserved(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;
        dpu_address_range_t reservation;

        cfg = make_valid_cfg();
        reservation.base = 64'h0000_0001_0000_0000;
        reservation.limit = 64'h0000_0001_0200_0000;
        cfg.hosts[0].pcie_domains[0].reserved_mmio_ranges.push_back(reservation);
        cfg.functions[0].bars[0].placement = DPU_ALLOC_PINNED;
        cfg.functions[0].bars[0].pinned_base = reservation.base;
        expect_resolution_invalid(resolver, cfg, "reserved MMIO");
    endfunction

    // Catches a same-domain BAR reverse index that silently overwrites overlap.
    function void test_pinned_bar_same_domain_overlap(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.functions[1].bars[0].placement = DPU_ALLOC_PINNED;
        cfg.functions[1].bars[0].pinned_base = 64'h0000_0001_0000_0000;
        cfg.functions[2].bars[0].placement = DPU_ALLOC_PINNED;
        cfg.functions[2].bars[0].pinned_base = 64'h0000_0001_0000_0000;
        expect_resolution_invalid(resolver, cfg, "BAR overlap");
    endfunction

    // Catches allocation outside a compatible MMIO window.
    function void test_auto_bar_exhaustion(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_valid_cfg();
        cfg.hosts[0].pcie_domains[0].mmio_windows[0].limit =
            64'h0000_0001_0100_0000;
        expect_resolution_invalid(resolver, cfg, "BAR space exhausted");
    endfunction

    // Catches zero, non-power-of-two, or wrapping BAR interval arithmetic.
    function void test_bar_arithmetic_guards(input dpu_device_resolver resolver);
        dpu_device_cfg cfg;

        cfg = make_single_pf_cfg();
        set_pf_bar_profile(cfg, DPU_BAR_DEVICE_MEMORY, 0, '0,
                           64'h0000_0000_0001_0000);
        cfg.functions[0].bars[0].size = '0;
        cfg.functions[0].bars[0].alignment = 64'h0000_0000_0001_0000;
        expect_resolution_invalid(resolver, cfg, "size and alignment must be nonzero");

        cfg = make_single_pf_cfg();
        set_pf_bar_profile(cfg, DPU_BAR_DEVICE_MEMORY, 0,
                           64'h0000_0000_0001_0000,
                           64'h0000_0000_0000_3000);
        cfg.functions[0].bars[0].size = 64'h0000_0000_0001_0000;
        cfg.functions[0].bars[0].alignment = 64'h0000_0000_0000_3000;
        expect_resolution_invalid(resolver, cfg, "alignment must be a power of two");

        cfg = make_single_pf_cfg();
        set_pf_bar_profile(cfg, DPU_BAR_DEVICE_MEMORY, 0,
                           64'h0000_0000_0001_0000,
                           64'h0000_0000_0001_0000);
        cfg.functions[0].bars[0].size = 64'h0000_0000_0001_0000;
        cfg.functions[0].bars[0].alignment = 64'h0000_0000_0001_0000;
        cfg.functions[0].bars[0].placement = DPU_ALLOC_PINNED;
        cfg.functions[0].bars[0].pinned_base = 64'hffff_ffff_ffff_0000;
        cfg.hosts[0].pcie_domains[0].mmio_windows[0].base =
            64'hffff_ffff_ffff_0000;
        cfg.hosts[0].pcie_domains[0].mmio_windows[0].limit =
            64'hffff_ffff_ffff_ffff;
        expect_resolution_invalid(resolver, cfg, "BAR address overflow");
    endfunction

    // Catches snapshots that expose owned handles, accept mutation after
    // publication, or allow queries before freeze.
    function void test_snapshot_immutability_and_service_queries(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg cfg;
        dpu_device_snapshot snapshot;
        dpu_device_snapshot unpublished;
        dpu_dut_caps caps_copy;
        dpu_dut_caps caps_again;
        dpu_service_key_t services[$];
        dpu_service_key_t added_service;
        dpu_function_key_t owner;
        dpu_function_key_t af_key;
        dpu_bar_pair_lease_t af_bar0;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t stored_bar;
        dpu_pcie_function_id_t ignored_id;
        string why;

        cfg = make_valid_cfg();
        expect_resolved(resolver, cfg, snapshot);
        snapshot.list_services(DPU_SERVICE_VIO_NET, services);
        if ((services.size() != 1) ||
            !dpu_same_function_key(services[0].function_key,
                                   cfg.functions[3].key) ||
            !snapshot.get_service_owner(services[0], owner, why) ||
            !dpu_same_function_key(owner, cfg.functions[3].key))
            `uvm_fatal("RESOLVER_TEST", "service ownership/list query mismatch")
        if (!snapshot.get_expected_af(af_key, af_bar0, why) ||
            !dpu_same_function_key(af_key, cfg.functions[1].key) ||
            (af_bar0.role != DPU_BAR_DEVICE_MEMORY) ||
            (af_bar0.even_bar_id != 0))
            `uvm_fatal("RESOLVER_TEST", "expected AF query mismatch")

        if (!snapshot.list_bars(cfg.functions[3].key, bars, why) ||
            (bars.size() != 3) ||
            (bars[0].role != DPU_BAR_DEVICE_MEMORY) ||
            (bars[1].role != DPU_BAR_MAILBOX) ||
            (bars[2].role != DPU_BAR_MSIX) ||
            (bars[0].base != 64'h0000_0001_0204_0000))
            `uvm_fatal("RESOLVER_TEST", "BAR list is not canonical or literal")
        bars[0].base = '0;
        if (!snapshot.get_bar(cfg.functions[3].key, DPU_BAR_DEVICE_MEMORY,
                              stored_bar, why) ||
            (stored_bar.base != 64'h0000_0001_0204_0000))
            `uvm_fatal("RESOLVER_TEST", "snapshot BAR list was not defensive")

        caps_copy = snapshot.snapshot_dut_caps();
        caps_copy.max_hosts = 4;
        caps_copy.bar_profiles[0].size = 64'h1;
        caps_again = snapshot.snapshot_dut_caps();
        if ((caps_again.max_hosts != 2) ||
            (caps_again.bar_profiles[0].size != 64'h0000_0000_0200_0000))
            `uvm_fatal("RESOLVER_TEST", "snapshot leaked mutable capability state")

        added_service.function_key = cfg.functions[0].key;
        added_service.service_kind = DPU_SERVICE_VBLK;
        added_service.service_instance_id = 7;
        if (snapshot.add_service(added_service, why))
            `uvm_fatal("RESOLVER_TEST", "frozen snapshot accepted mutation")
        services.delete();
        snapshot.list_services(DPU_SERVICE_VBLK, services);
        if (services.size() != 0)
            `uvm_fatal("RESOLVER_TEST", "rejected mutation changed snapshot")

        unpublished = dpu_device_snapshot::type_id::create("unpublished");
        if (unpublished.get_pcie_id(cfg.functions[0].key, ignored_id, why))
            `uvm_fatal("RESOLVER_TEST", "unfrozen snapshot allowed a query")
    endfunction

    // Catches failure paths that retain a partial new snapshot or mutate a
    // previously published snapshot through shared authoring state.
    function void test_failed_resolve_is_atomic(
        input dpu_device_resolver resolver
    );
        dpu_device_cfg good_cfg;
        dpu_device_cfg bad_cfg;
        dpu_device_snapshot first_snapshot;
        dpu_device_snapshot failed_snapshot;
        dpu_pcie_function_id_t pcie_id;
        string why;

        good_cfg = make_valid_cfg();
        expect_resolved(resolver, good_cfg, first_snapshot);
        bad_cfg = clone_cfg(good_cfg);
        bad_cfg.hosts[0].pcie_domains[0].reserved_bdfs.push_back(16'h0010);
        bad_cfg.functions[0].bdf_mode = DPU_ALLOC_PINNED;
        bad_cfg.functions[0].pinned_bdf = 16'h0010;
        failed_snapshot = first_snapshot;
        if (resolver.resolve(bad_cfg, failed_snapshot, why))
            `uvm_fatal("RESOLVER_TEST", "invalid second resolve passed")
        if (failed_snapshot != null)
            `uvm_fatal("RESOLVER_TEST", "failed second resolve retained output")
        if (!first_snapshot.get_pcie_id(good_cfg.functions[0].key,
                                        pcie_id, why) ||
            (pcie_id.bdf != 16'h0010))
            `uvm_fatal("RESOLVER_TEST", "failed resolve changed old snapshot")
    endfunction

    // Catches freeze accepting reverse-only BDFs, incomplete BAR maps/order,
    // wrong BAR owners/domains, overlapping intervals, or BAR key/value drift.
    function void test_snapshot_freeze_cross_checks_all_indexes();
        dpu_snapshot_integrity_probe snapshot;
        dpu_function_key_t af_key;
        dpu_function_key_t peer_key;
        dpu_pcie_function_id_t phantom_pcie;
        dpu_pcie_domain_key_t wrong_domain;
        dpu_bar_pair_lease_t unordered_bar;
        int unsigned missed_rejections;

        af_key.host_id = 0;
        af_key.pf_id = 0;
        af_key.kind = DPU_FUNCTION_PF;
        af_key.vf_id = 0;
        peer_key.host_id = 0;
        peer_key.pf_id = 1;
        peer_key.kind = DPU_FUNCTION_PF;
        peer_key.vf_id = 0;
        missed_rejections = 0;

        snapshot = make_mutable_snapshot();
        phantom_pcie.domain.host_id = 0;
        phantom_pcie.domain.segment_id = 0;
        phantom_pcie.bdf = 16'h0012;
        snapshot.corrupt_add_reverse_only(phantom_pcie, peer_key);
        if (!freeze_rejects_corruption(snapshot, "PCIe index cardinality"))
            missed_rejections++;

        snapshot = make_mutable_snapshot();
        unordered_bar.role = DPU_BAR_MSIX;
        unordered_bar.even_bar_id = 4;
        unordered_bar.base = 64'h0000_0001_0201_0000;
        unordered_bar.size = 64'h0000_0000_0001_0000;
        wrong_domain.host_id = 0;
        wrong_domain.segment_id = 0;
        snapshot.corrupt_add_unordered_bar(peer_key, wrong_domain,
                                           unordered_bar);
        if (!freeze_rejects_corruption(snapshot, "BAR index cardinality"))
            missed_rejections++;

        snapshot = make_mutable_snapshot();
        snapshot.corrupt_delete_bar_domain(peer_key, DPU_BAR_MAILBOX);
        if (!freeze_rejects_corruption(snapshot, "BAR index cardinality"))
            missed_rejections++;

        snapshot = make_mutable_snapshot();
        snapshot.corrupt_bar_owner(peer_key, DPU_BAR_MAILBOX, af_key);
        if (!freeze_rejects_corruption(snapshot, "BAR owning function"))
            missed_rejections++;

        snapshot = make_mutable_snapshot();
        wrong_domain.host_id = 0;
        wrong_domain.segment_id = 9;
        snapshot.corrupt_bar_domain(peer_key, DPU_BAR_MAILBOX, wrong_domain);
        if (!freeze_rejects_corruption(snapshot, "BAR owning domain"))
            missed_rejections++;

        snapshot = make_mutable_snapshot();
        snapshot.corrupt_bar_base(peer_key, DPU_BAR_MAILBOX,
                                  64'h0000_0001_0000_0000);
        if (!freeze_rejects_corruption(snapshot, "BAR interval overlap"))
            missed_rejections++;

        snapshot = make_mutable_snapshot();
        snapshot.corrupt_bar_role(peer_key, DPU_BAR_MAILBOX, DPU_BAR_MSIX);
        if (!freeze_rejects_corruption(snapshot, "BAR key identity"))
            missed_rejections++;

        if (missed_rejections != 0)
            `uvm_fatal("RESOLVER_TEST",
                $sformatf("snapshot freeze missed %0d integrity defects",
                          missed_rejections))
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
        test_deterministic_domain_aware_allocation(resolver);
        test_auto_bar_lowest_aligned_after_reservation(resolver);
        test_pinned_bdf_reserved(resolver);
        test_pinned_bdf_out_of_range(resolver);
        test_pinned_bdf_same_domain_duplicate(resolver);
        test_auto_bdf_exhaustion(resolver);
        test_auto_bdf_scans_sorted_ranges_to_ffff(resolver);
        test_bar_pair_shape(resolver);
        test_bar_role_pair_mismatch_on_resolve(resolver);
        test_pinned_bar_misaligned(resolver);
        test_pinned_bar_reserved(resolver);
        test_pinned_bar_same_domain_overlap(resolver);
        test_auto_bar_exhaustion(resolver);
        test_bar_arithmetic_guards(resolver);
        test_snapshot_immutability_and_service_queries(resolver);
        test_failed_resolve_is_atomic(resolver);
        test_snapshot_freeze_cross_checks_all_indexes();
        phase.drop_objection(this);
    endtask
endclass : dpu_device_resolver_test

`endif // DPU_DEVICE_RESOLVER_TEST_SV
