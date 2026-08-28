`ifndef DPU_RESOURCE_RESOLVER_TEST_SV
`define DPU_RESOURCE_RESOLVER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_corruptible_device_snapshot extends dpu_device_snapshot;
    `uvm_object_utils(dpu_corruptible_device_snapshot)

    function new(string name = "dpu_corruptible_device_snapshot");
        super.new(name);
    endfunction

    function void delete_service_owner(input dpu_service_key_t service_key);
        string service_name;
        service_name = dpu_service_key_name(service_key);
        m_frozen = 0;
        m_services.delete(service_name);
        m_service_owners.delete(service_name);
        foreach (m_service_order[index]) begin
            if (m_service_order[index] == service_name) begin
                m_service_order.delete(index);
                return;
            end
        end
    endfunction
endclass : dpu_corruptible_device_snapshot

class dpu_resource_resolver_test extends uvm_test;
    `uvm_component_utils(dpu_resource_resolver_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_function_key();
        dpu_function_key_t key;
        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_PF;
        key.vf_id = 0;
        return key;
    endfunction

    function automatic dpu_bar_request make_coordinator_bar(
        input dpu_function_kind_e kind, input dpu_bar_role_e role
    );
        dpu_bar_request bar;
        bar = dpu_bar_request::type_id::create("coordinator_bar");
        bar.role = role;
        bar.placement = DPU_ALLOC_AUTO;
        case (kind)
            DPU_FUNCTION_PF: case (role)
                DPU_BAR_DEVICE_MEMORY: begin bar.even_bar_id = 0; bar.size = 64'h0200_0000; bar.alignment = 64'h0200_0000; end
                DPU_BAR_MAILBOX:       begin bar.even_bar_id = 2; bar.size = 64'h0001_0000; bar.alignment = 64'h0001_0000; end
                default:                begin bar.even_bar_id = 4; bar.size = 64'h0001_0000; bar.alignment = 64'h0001_0000; end
            endcase
            default: case (role)
                DPU_BAR_DEVICE_MEMORY: begin bar.even_bar_id = 0; bar.size = 64'h4000; bar.alignment = 64'h4000; end
                DPU_BAR_MAILBOX:       begin bar.even_bar_id = 2; bar.size = 64'h4000; bar.alignment = 64'h4000; end
                default:                begin bar.even_bar_id = 4; bar.size = 64'h8000; bar.alignment = 64'h8000; end
            endcase
        endcase
        return bar;
    endfunction

    function automatic dpu_function_cfg make_coordinator_function(
        input int unsigned pf_id, input dpu_function_kind_e kind,
        input int unsigned vf_id
    );
        dpu_function_cfg function_cfg;
        function_cfg = dpu_function_cfg::type_id::create("coordinator_function");
        function_cfg.key.host_id = 0;
        function_cfg.key.pf_id = pf_id;
        function_cfg.key.kind = kind;
        function_cfg.key.vf_id = vf_id;
        function_cfg.domain_key.host_id = 0;
        function_cfg.domain_key.segment_id = 0;
        function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        function_cfg.bars.push_back(make_coordinator_bar(kind, DPU_BAR_DEVICE_MEMORY));
        function_cfg.bars.push_back(make_coordinator_bar(kind, DPU_BAR_MAILBOX));
        function_cfg.bars.push_back(make_coordinator_bar(kind, DPU_BAR_MSIX));
        return function_cfg;
    endfunction

    function automatic dpu_device_cfg make_coordinator_source();
        dpu_device_cfg cfg;
        dpu_host_cfg host;
        dpu_pcie_domain_cfg domain;
        dpu_bdf_range_t bdf_range;
        dpu_mmio_window_cfg window;
        dpu_vf_pool_cfg pool;
        dpu_vf_template_cfg template;

        cfg = dpu_device_cfg::type_id::create("coordinator_source");
        host = dpu_host_cfg::type_id::create("coordinator_host");
        host.host_id = 0;
        domain = dpu_pcie_domain_cfg::type_id::create("coordinator_domain");
        domain.key.host_id = 0;
        domain.key.segment_id = 0;
        bdf_range.first_bdf = 16'h0010;
        bdf_range.last_bdf = 16'h00ff;
        domain.bdf_ranges.push_back(bdf_range);
        window = dpu_mmio_window_cfg::type_id::create("coordinator_window");
        window.base = 64'h0000_0001_0000_0000;
        window.limit = 64'h0000_0002_0000_0000;
        window.allowed_roles = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX,
                                 DPU_BAR_MSIX};
        domain.mmio_windows.push_back(window);
        host.pcie_domains.push_back(domain);
        cfg.hosts.push_back(host);
        cfg.functions.push_back(make_coordinator_function(0, DPU_FUNCTION_PF, 0));
        cfg.functions.push_back(make_coordinator_function(1, DPU_FUNCTION_PF, 0));
        pool = dpu_vf_pool_cfg::type_id::create("coordinator_vf_pool");
        pool.parent_pf = cfg.functions[0].key;
        template = dpu_vf_template_cfg::type_id::create("coordinator_vf7");
        template.vf_id = 7;
        template.domain_key = cfg.functions[0].domain_key;
        template.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        template.bars.push_back(make_coordinator_bar(DPU_FUNCTION_VF,
                                                      DPU_BAR_DEVICE_MEMORY));
        template.bars.push_back(make_coordinator_bar(DPU_FUNCTION_VF,
                                                      DPU_BAR_MAILBOX));
        template.bars.push_back(make_coordinator_bar(DPU_FUNCTION_VF,
                                                      DPU_BAR_MSIX));
        pool.vf_templates.push_back(template);
        cfg.vf_pools.push_back(pool);
        cfg.af_request.requester = cfg.functions[0].key;
        return cfg;
    endfunction

    function automatic dpu_resource_placement_cfg make_coordinator_placement();
        dpu_resource_placement_cfg cfg;
        dpu_resource_pool_config_t profile;
        dpu_vio_placement_request request;
        dpu_function_key_t vf7;

        cfg = dpu_resource_placement_cfg::type_id::create("coordinator_placement");
        profile.name = "virtio.qpair";
        profile.class_id = 0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 128;
        profile.max_per_function = 32;
        cfg.profiles.push_back(profile);
        request = dpu_vio_placement_request::type_id::create("request_20");
        request.request_id = 20;
        request.total_qpairs = 1;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.fixed_devices.push_back(make_coordinator_function(1, DPU_FUNCTION_PF, 0).key);
        cfg.vio_requests.push_back(request);
        request = dpu_vio_placement_request::type_id::create("request_10");
        request.request_id = 10;
        request.total_qpairs = 1;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.fixed_devices.push_back(make_coordinator_function(0, DPU_FUNCTION_PF, 0).key);
        cfg.vio_requests.push_back(request);
        vf7 = make_coordinator_function(0, DPU_FUNCTION_VF, 7).key;
        request = dpu_vio_placement_request::type_id::create("request_30");
        request.request_id = 30;
        request.total_qpairs = 1;
        request.candidate_kind = DPU_VIO_CANDIDATE_VF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.fixed_devices.push_back(vf7);
        cfg.vio_requests.push_back(request);
        return cfg;
    endfunction

    function automatic dpu_vio_qpair_override make_global_pin(
        input int unsigned pair_index, input int unsigned global_id
    );
        dpu_vio_qpair_override override;
        override = dpu_vio_qpair_override::type_id::create("global_pin");
        override.request_pair_index = pair_index;
        override.global_mode = DPU_ASSIGN_PINNED;
        override.requested_global_qpair_id = global_id;
        return override;
    endfunction

    function void test_configuration_resolver_atomicity();
        dpu_configuration_resolver coordinator;
        dpu_device_cfg source_cfg;
        dpu_resource_placement_cfg placement_cfg;
        dpu_resource_placement_cfg bad_placement;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_device_snapshot failed_device_snapshot;
        dpu_resource_snapshot failed_resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_vio_qpair_binding_t request10;
        dpu_vio_qpair_binding_t request20;
        dpu_vio_qpair_binding_t request30;
        dpu_pcie_function_id_t vf_pcie;
        dpu_bar_pair_lease_t vf_bar;
        dpu_service_key_t services[$];
        dpu_function_key_t vf7;
        string why;
        bit found_vf_service;

        coordinator = dpu_configuration_resolver::type_id::create("coordinator");
        source_cfg = make_coordinator_source();
        placement_cfg = make_coordinator_placement();
        if (!coordinator.resolve(source_cfg, placement_cfg, device_snapshot,
                                 resource_snapshot, diagnostic))
            `uvm_fatal("CONFIG_RESOLVER", diagnostic.message)
        if (!device_snapshot.is_frozen() || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot))
            `uvm_fatal("CONFIG_RESOLVER", "coordinator did not publish matching frozen snapshots")
        if (!resource_snapshot.get_vio_binding(10, 0, request10) ||
            !resource_snapshot.get_vio_binding(20, 0, request20) ||
            !resource_snapshot.get_vio_binding(30, 0, request30) ||
            (request10.global_qpair_id >= request20.global_qpair_id))
            `uvm_fatal("CONFIG_RESOLVER", "request IDs did not determine AUTO global allocation order")
        vf7 = make_coordinator_function(0, DPU_FUNCTION_VF, 7).key;
        if (!device_snapshot.get_pcie_id(vf7, vf_pcie, why) ||
            !device_snapshot.get_bar(vf7, DPU_BAR_DEVICE_MEMORY, vf_bar, why))
            `uvm_fatal("CONFIG_RESOLVER", {"materialized VF omitted BDF or BAR: ", why})
        device_snapshot.list_services(DPU_SERVICE_VIO_NET, services);
        found_vf_service = 0;
        foreach (services[index]) begin
            if (dpu_same_function_key(services[index].function_key, vf7))
                found_vf_service = 1;
        end
        if (!found_vf_service || (source_cfg.functions.size() != 2) ||
            (source_cfg.functions[0].services.size() != 0) ||
            (source_cfg.vf_pools[0].vf_templates[0].vf_id != 7))
            `uvm_fatal("CONFIG_RESOLVER", "coordinator mutated source authoring or lost VF service")

        bad_placement = dpu_resource_placement_cfg::type_id::create("bad_placement");
        bad_placement.copy_from(placement_cfg);
        bad_placement.vio_requests[1].total_qpairs = 2;
        bad_placement.vio_requests[1].qpair_overrides.push_back(make_global_pin(0, 9));
        bad_placement.vio_requests[1].qpair_overrides.push_back(make_global_pin(1, 9));
        failed_device_snapshot = device_snapshot;
        failed_resource_snapshot = resource_snapshot;
        if (coordinator.resolve(source_cfg, bad_placement, failed_device_snapshot,
                                failed_resource_snapshot, diagnostic))
            `uvm_fatal("CONFIG_RESOLVER", "conflicting configuration resolved")
        if ((failed_device_snapshot != null) || (failed_resource_snapshot != null) ||
            (diagnostic.stage != DPU_PLACE_STAGE_RESOURCE_RESOLUTION) ||
            (diagnostic.error_code != DPU_PLACE_ERR_GLOBAL_QID_CONFLICT))
            `uvm_fatal("CONFIG_RESOLVER", "atomic failure leaked snapshots or diagnostic")
        if (!device_snapshot.is_frozen() || !resource_snapshot.is_frozen() ||
            !resource_snapshot.get_vio_binding(10, 0, request10) ||
            (request10.global_qpair_id != 0) ||
            (placement_cfg.vio_requests[1].total_qpairs != 1) ||
            (placement_cfg.vio_requests[1].qpair_overrides.size() != 0))
            `uvm_fatal("CONFIG_RESOLVER", "failed candidate resolution mutated prior state")
    endfunction

    function automatic dpu_device_snapshot make_device_snapshot(
        output dpu_service_key_t service_key,
        input int unsigned service_instance_id = 0,
        input bit add_second_vio_service = 0
    );
        dpu_device_snapshot snapshot;
        dpu_dut_caps caps;
        dpu_function_key_t function_key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bar;
        dpu_service_key_t second_service_key;
        string why;

        snapshot = dpu_device_snapshot::type_id::create("device_snapshot");
        caps = dpu_dut_caps::type_id::create("dut_caps");
        function_key = make_function_key();
        pcie_id.domain.host_id = 0;
        pcie_id.domain.segment_id = 0;
        pcie_id.bdf = 16'h0010;
        bar.role = DPU_BAR_DEVICE_MEMORY;
        bar.even_bar_id = 0;
        bar.base = 64'h0000_0001_0000_0000;
        bar.size = 64'h0000_0000_0200_0000;
        service_key.function_key = function_key;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = service_instance_id;
        if (!snapshot.set_dut_caps(caps, why) ||
            !snapshot.add_function(function_key, pcie_id, why) ||
            !snapshot.add_bar(function_key, bar, why) ||
            !snapshot.add_service(service_key, why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        if (add_second_vio_service) begin
            second_service_key = service_key;
            second_service_key.service_instance_id =
                (service_instance_id == 0) ? 1 : 0;
            if (!snapshot.add_service(second_service_key, why))
                `uvm_fatal("RESOURCE_SNAPSHOT", why)
        end
        if (!snapshot.set_expected_af(function_key, why) ||
            !snapshot.freeze(why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        return snapshot;
    endfunction

    function automatic dpu_device_snapshot make_two_service_snapshot(
        output dpu_service_key_t first_service,
        output dpu_service_key_t second_service
    );
        dpu_device_snapshot snapshot;
        dpu_dut_caps caps;
        dpu_function_key_t first_function;
        dpu_function_key_t second_function;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bar;
        string why;

        snapshot = dpu_device_snapshot::type_id::create("two_service_snapshot");
        caps = dpu_dut_caps::type_id::create("two_service_caps");
        first_function = make_function_key();
        second_function = first_function;
        second_function.pf_id = 1;
        pcie_id.domain.host_id = 0;
        pcie_id.domain.segment_id = 0;
        pcie_id.bdf = 16'h0010;
        bar.role = DPU_BAR_DEVICE_MEMORY;
        bar.even_bar_id = 0;
        bar.base = 64'h0000_0001_0000_0000;
        bar.size = 64'h0000_0000_0200_0000;
        first_service.function_key = first_function;
        first_service.service_kind = DPU_SERVICE_VIO_NET;
        first_service.service_instance_id = 0;
        second_service.function_key = second_function;
        second_service.service_kind = DPU_SERVICE_VIO_NET;
        second_service.service_instance_id = 0;
        if (!snapshot.set_dut_caps(caps, why) ||
            !snapshot.add_function(first_function, pcie_id, why) ||
            !snapshot.add_bar(first_function, bar, why) ||
            !snapshot.add_service(first_service, why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        pcie_id.bdf = 16'h0018;
        bar.base = 64'h0000_0001_0400_0000;
        if (!snapshot.add_function(second_function, pcie_id, why) ||
            !snapshot.add_bar(second_function, bar, why) ||
            !snapshot.add_service(second_service, why) ||
            !snapshot.set_expected_af(first_function, why) ||
            !snapshot.freeze(why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        return snapshot;
    endfunction

    function automatic dpu_corruptible_device_snapshot
        make_corruptible_device_snapshot(output dpu_service_key_t service_key);
        dpu_corruptible_device_snapshot snapshot;
        dpu_dut_caps caps;
        dpu_function_key_t function_key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bar;
        string why;

        snapshot = dpu_corruptible_device_snapshot::type_id::create(
            "corruptible_device_snapshot");
        caps = dpu_dut_caps::type_id::create("corruptible_device_caps");
        function_key = make_function_key();
        pcie_id.domain.host_id = 0;
        pcie_id.domain.segment_id = 0;
        pcie_id.bdf = 16'h0010;
        bar.role = DPU_BAR_DEVICE_MEMORY;
        bar.even_bar_id = 0;
        bar.base = 64'h0000_0001_0000_0000;
        bar.size = 64'h0000_0000_0200_0000;
        service_key.function_key = function_key;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = 0;
        if (!snapshot.set_dut_caps(caps, why) ||
            !snapshot.add_function(function_key, pcie_id, why) ||
            !snapshot.add_bar(function_key, bar, why) ||
            !snapshot.add_service(service_key, why) ||
            !snapshot.set_expected_af(function_key, why) ||
            !snapshot.freeze(why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        return snapshot;
    endfunction

    function automatic dpu_normalized_placement_plan make_two_service_plan(
        input dpu_service_key_t first_service,
        input dpu_service_key_t second_service
    );
        dpu_normalized_placement_plan plan;
        dpu_normalized_vio_request request;
        dpu_vio_participant_target_t target;
        dpu_normalized_vio_pair_t pair;
        dpu_resource_pool_config_t profile;
        string why;

        plan = dpu_normalized_placement_plan::type_id::create("two_service_plan");
        plan.effective_global_capacity = 128;
        plan.effective_device_capacity = 32;
        profile.name = "virtio.qpair";
        profile.class_id = 0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 128;
        profile.max_per_function = 32;
        plan.set_profiles('{profile});
        for (int unsigned index = 0; index < 2; index++) begin
            dpu_service_key_t service_key;
            service_key = (index == 0) ? first_service : second_service;
            request = dpu_normalized_vio_request::type_id::create(
                $sformatf("two_service_request_%0d", index));
            request.request_id = index + 3;
            request.service_instance_id = 0;
            request.total_qpairs = 1;
            request.device_policy = DPU_VIO_DEVICE_FIXED;
            request.ordering = DPU_PLACEMENT_CANONICAL;
            request.canonical_candidates.push_back(service_key.function_key);
            request.effective_candidates.push_back(service_key.function_key);
            target.request_id = request.request_id;
            target.service_key = service_key;
            target.qpair_count = 1;
            request.targets.push_back(target);
            pair.request_pair_index = 0;
            pair.service_key = service_key;
            pair.local_mode = DPU_ASSIGN_PINNED;
            pair.requested_local_pair_id = 3;
            pair.global_mode = DPU_ASSIGN_AUTO;
            pair.requested_global_qpair_id = 0;
            request.pairs.push_back(pair);
            if (!plan.add_request(request, why))
                `uvm_fatal("RESOURCE_RESOLVER", why)
        end
        if (!plan.freeze(why))
            `uvm_fatal("RESOURCE_RESOLVER", why)
        return plan;
    endfunction

    function automatic dpu_normalized_placement_plan make_plan(
        input dpu_service_key_t service_key,
        input int unsigned effective_global_capacity = 128,
        input int unsigned effective_device_capacity = 32,
        input int unsigned total_qpairs = 1,
        input int unsigned participant_qpairs = 1,
        input dpu_assignment_mode_e local_modes[$] = '{} ,
        input int unsigned local_ids[$] = '{},
        input dpu_assignment_mode_e global_modes[$] = '{},
        input int unsigned global_ids[$] = '{},
        input int unsigned supplied_reservation_ids[$] = '{},
        input dpu_global_id_range_t supplied_reservation_ranges[$] = '{}
    );
        dpu_normalized_placement_plan plan;
        dpu_normalized_vio_request request;
        dpu_vio_participant_target_t target;
        dpu_normalized_vio_pair_t pair;
        dpu_resource_pool_config_t profile;
        int unsigned reservation_ids[$];
        dpu_global_id_range_t reservation_ranges[$];
        string why;

        plan = dpu_normalized_placement_plan::type_id::create("plan");
        plan.effective_global_capacity = effective_global_capacity;
        plan.effective_device_capacity = effective_device_capacity;
        profile.name = "virtio.qpair";
        profile.class_id = 0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 128;
        profile.max_per_function = 32;
        plan.set_profiles('{profile});
        reservation_ids = supplied_reservation_ids;
        reservation_ranges = supplied_reservation_ranges;
        if ((supplied_reservation_ids.size() == 0) &&
            (supplied_reservation_ranges.size() == 0)) begin
            reservation_ids.push_back(4);
            reservation_ranges.push_back('{first_id: 8, last_id: 9});
        end
        plan.set_reservations(reservation_ids, reservation_ranges);
        request = dpu_normalized_vio_request::type_id::create("request");
        request.request_id = 3;
        request.service_instance_id = 0;
        request.total_qpairs = total_qpairs;
        request.seed = 17;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.ordering = DPU_PLACEMENT_CANONICAL;
        request.canonical_candidates.push_back(service_key.function_key);
        request.effective_candidates.push_back(service_key.function_key);
        target.request_id = 3;
        target.service_key = service_key;
        target.qpair_count = participant_qpairs;
        request.targets.push_back(target);
        for (int unsigned pair_index = 0; pair_index < total_qpairs;
             pair_index++) begin
            pair.request_pair_index = pair_index;
            pair.service_key = service_key;
            pair.local_mode = (pair_index < local_modes.size()) ?
                              local_modes[pair_index] : DPU_ASSIGN_AUTO;
            pair.requested_local_pair_id = (pair_index < local_ids.size()) ?
                                           local_ids[pair_index] : 0;
            pair.global_mode = (pair_index < global_modes.size()) ?
                               global_modes[pair_index] : DPU_ASSIGN_AUTO;
            pair.requested_global_qpair_id = (pair_index < global_ids.size()) ?
                                             global_ids[pair_index] : 0;
            request.pairs.push_back(pair);
        end
        if (!plan.add_request(request, why) || !plan.freeze(why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        return plan;
    endfunction

    function automatic void expect_resolve_failure(
        input string name,
        input dpu_resource_resolver resolver,
        input dpu_device_snapshot device_snapshot,
        input dpu_normalized_placement_plan plan,
        input dpu_placement_error_e expected_error,
        input bit expect_request_context,
        input bit expect_pair_context
    );
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;

        resource_snapshot = dpu_resource_snapshot::type_id::create({name, "_snapshot"});
        diagnostic = dpu_placement_diagnostic::type_id::create({name, "_diag"});
        if (resolver.resolve(device_snapshot, plan, resource_snapshot, diagnostic) ||
            (resource_snapshot != null) ||
            (diagnostic.error_code != expected_error) ||
            (diagnostic.has_request_id != expect_request_context) ||
            (diagnostic.has_pair_index != expect_pair_context))
            `uvm_fatal("RESOURCE_RESOLVER", {name, " accepted an invalid allocation or lost diagnostic context"})
    endfunction

    function void test_deleted_service_owner_is_snapshot_mismatch();
        dpu_corruptible_device_snapshot device_snapshot;
        dpu_service_key_t service_key;
        dpu_resource_resolver resolver;

        device_snapshot = make_corruptible_device_snapshot(service_key);
        device_snapshot.delete_service_owner(service_key);
        resolver = dpu_resource_resolver::type_id::create("corruptible_resolver");
        expect_resolve_failure("deleted_service_owner", resolver, device_snapshot,
            make_plan(service_key), DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
            0, 0);
    endfunction

    function automatic void expect_binding(
        input dpu_resource_snapshot snapshot,
        input int unsigned pair_index,
        input int unsigned local_id,
        input int unsigned global_id
    );
        dpu_vio_qpair_binding_t observed;

        if (!snapshot.get_vio_binding(3, pair_index, observed) ||
            (observed.local_pair_id != local_id) ||
            (observed.rx_local_virtqueue_id != (2 * local_id)) ||
            (observed.tx_local_virtqueue_id != ((2 * local_id) + 1)) ||
            (observed.global_qpair_id != global_id))
            `uvm_fatal("RESOURCE_RESOLVER", "resolved qpair binding disagrees with allocation contract")
    endfunction

    function automatic void expect_freeze_failure(
        input string name,
        input dpu_normalized_placement_plan plan,
        input dpu_device_snapshot device_snapshot,
        input dpu_vio_qpair_binding_t binding,
        input dpu_placement_error_e expected_error,
        input bit expect_request_context,
        input bit expect_pair_context,
        input bit expect_service_context,
        input bit expect_function_context
    );
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;

        resource_snapshot = dpu_resource_snapshot::type_id::create(name);
        diagnostic = dpu_placement_diagnostic::type_id::create({name, "_diag"});
        if (!resource_snapshot.set_normalized_plan(plan, diagnostic) ||
            !resource_snapshot.add_vio_binding(binding, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", diagnostic.message)
        if (resource_snapshot.freeze(device_snapshot, diagnostic) ||
            (diagnostic.error_code != expected_error) ||
            (diagnostic.has_request_id != expect_request_context) ||
            (diagnostic.has_pair_index != expect_pair_context) ||
            (diagnostic.has_service_key != expect_service_context) ||
            (diagnostic.has_function_key != expect_function_context))
            `uvm_fatal("RESOURCE_SNAPSHOT", {name, " accepted invalid snapshot or lost diagnostic context"})
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_snapshot device_snapshot;
        dpu_normalized_placement_plan plan;
        dpu_resource_snapshot resource_snapshot;
        dpu_service_key_t service_key;
        dpu_placement_diagnostic diagnostic;
        dpu_vio_qpair_binding_t binding;
        dpu_vio_qpair_binding_t observed;
        dpu_vio_qpair_binding_t bindings[$];
        dpu_normalized_vio_request request;
        dpu_normalized_vio_request request_again;
        int unsigned reservation_ids[$];
        dpu_vio_qpair_binding_t invalid_binding;
        dpu_device_snapshot nonzero_instance_snapshot;
        dpu_device_snapshot multiple_vio_snapshot;
        dpu_service_key_t nonzero_instance_service;
        dpu_service_key_t multiple_vio_service;
        dpu_placement_diagnostic null_diagnostic;
        dpu_resource_resolver resolver;
        dpu_assignment_mode_e local_modes[$];
        dpu_assignment_mode_e global_modes[$];
        int unsigned local_ids[$];
        int unsigned global_ids[$];
        dpu_global_id_range_t reservation_ranges[$];
        dpu_device_snapshot two_service_snapshot;
        dpu_service_key_t second_service_key;

        super.build_phase(phase);
        device_snapshot = make_device_snapshot(service_key);
        resolver = dpu_resource_resolver::type_id::create("resolver");

        // PINNED IDs win first, PREFERRED IDs fall back to the lowest free
        // value, and AUTO IDs skip a normalized individual/range reservation.
        local_modes = '{DPU_ASSIGN_PINNED, DPU_ASSIGN_PREFERRED,
                        DPU_ASSIGN_AUTO, DPU_ASSIGN_AUTO};
        local_ids = '{3, 3, 0, 0};
        global_modes = '{DPU_ASSIGN_PINNED, DPU_ASSIGN_PREFERRED,
                         DPU_ASSIGN_AUTO, DPU_ASSIGN_AUTO};
        global_ids = '{7, 7, 0, 0};
        reservation_ranges = '{'{first_id: 1, last_id: 2}};
        plan = make_plan(service_key, 128, 32, 4, 4, local_modes, local_ids,
                         global_modes, global_ids, '{2}, reservation_ranges);
        resource_snapshot = null;
        if (!resolver.resolve(device_snapshot, plan, resource_snapshot, diagnostic) ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen())
            `uvm_fatal("RESOURCE_RESOLVER", diagnostic.message)
        expect_binding(resource_snapshot, 0, 3, 7);
        expect_binding(resource_snapshot, 1, 0, 0);
        expect_binding(resource_snapshot, 2, 1, 3);
        expect_binding(resource_snapshot, 3, 2, 4);

        two_service_snapshot = make_two_service_snapshot(service_key,
                                                          second_service_key);
        plan = make_two_service_plan(service_key, second_service_key);
        resource_snapshot = null;
        if (!resolver.resolve(two_service_snapshot, plan, resource_snapshot,
                              diagnostic) || (resource_snapshot == null))
            `uvm_fatal("RESOURCE_RESOLVER", diagnostic.message)
        if (!resource_snapshot.get_vio_binding(3, 0, observed) ||
            (observed.local_pair_id != 3) || (observed.global_qpair_id != 0) ||
            !resource_snapshot.get_vio_binding(4, 0, observed) ||
            (observed.local_pair_id != 3) || (observed.global_qpair_id != 1))
            `uvm_fatal("RESOURCE_RESOLVER", "local reuse/global uniqueness contract failed")

        local_modes = '{DPU_ASSIGN_PINNED, DPU_ASSIGN_PINNED};
        local_ids = '{0, 0};
        global_modes = '{DPU_ASSIGN_AUTO, DPU_ASSIGN_AUTO};
        global_ids = '{0, 0};
        expect_resolve_failure("duplicate_local_pin", resolver, device_snapshot,
            make_plan(service_key, 128, 32, 2, 2, local_modes, local_ids,
                      global_modes, global_ids), DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
            1, 1);

        local_modes = '{DPU_ASSIGN_PINNED};
        local_ids = '{32};
        global_modes = '{DPU_ASSIGN_AUTO};
        global_ids = '{0};
        expect_resolve_failure("local_hard_limit_resolve", resolver, device_snapshot,
            make_plan(service_key, 128, 32, 1, 1, local_modes, local_ids,
                      global_modes, global_ids), DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
            1, 1);

        local_modes = '{DPU_ASSIGN_AUTO};
        local_ids = '{0};
        global_modes = '{DPU_ASSIGN_PINNED};
        global_ids = '{2048};
        expect_resolve_failure("global_hard_limit_resolve", resolver, device_snapshot,
            make_plan(service_key, 2048, 32, 1, 1, local_modes, local_ids,
                      global_modes, global_ids), DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
            1, 1);

        global_ids = '{7};
        reservation_ranges = '{'{first_id: 7, last_id: 7}};
        expect_resolve_failure("reserved_global_pin", resolver, device_snapshot,
            make_plan(service_key, 128, 32, 1, 1, local_modes, local_ids,
                      global_modes, global_ids, '{}, reservation_ranges),
            DPU_PLACE_ERR_GLOBAL_QID_RESERVED, 1, 1);

        local_modes = '{DPU_ASSIGN_AUTO, DPU_ASSIGN_AUTO};
        local_ids = '{0, 0};
        global_modes = '{DPU_ASSIGN_PINNED, DPU_ASSIGN_PINNED};
        global_ids = '{7, 7};
        expect_resolve_failure("duplicate_global_pin", resolver, device_snapshot,
            make_plan(service_key, 128, 32, 2, 2, local_modes, local_ids,
                      global_modes, global_ids), DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
            1, 1);

        reservation_ranges = '{};
        expect_resolve_failure("bad_reservation_id", resolver, device_snapshot,
            make_plan(service_key, 128, 32, 1, 1, '{DPU_ASSIGN_AUTO}, '{0},
                      '{DPU_ASSIGN_AUTO}, '{0}, '{2048}, reservation_ranges),
            DPU_PLACE_ERR_INVALID_RESERVATION, 0, 0);
        reservation_ranges = '{'{first_id: 9, last_id: 8}};
        expect_resolve_failure("reversed_reservation_range", resolver, device_snapshot,
            make_plan(service_key, 128, 32, 1, 1, '{DPU_ASSIGN_AUTO}, '{0},
                      '{DPU_ASSIGN_AUTO}, '{0}, '{}, reservation_ranges),
            DPU_PLACE_ERR_INVALID_RESERVATION, 0, 0);
        reservation_ranges = '{'{first_id: 1, last_id: 2048}};
        expect_resolve_failure("reservation_range_hard_limit", resolver, device_snapshot,
            make_plan(service_key, 128, 32, 1, 1, '{DPU_ASSIGN_AUTO}, '{0},
                      '{DPU_ASSIGN_AUTO}, '{0}, '{}, reservation_ranges),
            DPU_PLACE_ERR_INVALID_RESERVATION, 0, 0);

        reservation_ranges = '{'{first_id: 0, last_id: 1}};
        expect_resolve_failure("global_unreserved_capacity_exhausted", resolver,
            device_snapshot, make_plan(service_key, 2, 32, 1, 1,
            '{DPU_ASSIGN_AUTO}, '{0}, '{DPU_ASSIGN_AUTO}, '{0}, '{},
            reservation_ranges), DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED, 0, 0);

        plan = make_plan(service_key);
        diagnostic = dpu_placement_diagnostic::type_id::create("diagnostic");
        resource_snapshot = dpu_resource_snapshot::type_id::create(
            "resource_snapshot");
        binding.request_id = 3;
        binding.request_pair_index = 0;
        binding.service_key = service_key;
        binding.local_pair_id = 17;
        binding.rx_local_virtqueue_id = 34;
        binding.tx_local_virtqueue_id = 35;
        binding.global_qpair_id = 91;
        if (!resource_snapshot.set_normalized_plan(plan, diagnostic) ||
            !resource_snapshot.add_vio_binding(binding, diagnostic) ||
            !resource_snapshot.freeze(device_snapshot, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", diagnostic.message)
        if (!resource_snapshot.get_vio_binding_by_global(91, observed) ||
            (observed.local_pair_id != 17))
            `uvm_fatal("RESOURCE_SNAPSHOT", "global reverse lookup disagrees")
        observed.local_pair_id = 0;
        if (!resource_snapshot.get_vio_binding(3, 0, observed) ||
            (observed.local_pair_id != 17))
            `uvm_fatal("RESOURCE_SNAPSHOT", "binding query leaked mutable state")
        resource_snapshot.list_vio_bindings(bindings);
        bindings[0].global_qpair_id = 0;
        resource_snapshot.list_vio_bindings(bindings);
        if ((bindings.size() != 1) || (bindings[0].global_qpair_id != 91))
            `uvm_fatal("RESOURCE_SNAPSHOT", "binding list leaked mutable state")
        if (!resource_snapshot.get_normalized_request(3, request))
            `uvm_fatal("RESOURCE_SNAPSHOT", "normalized request is missing")
        request.targets[0].qpair_count = 0;
        if (!resource_snapshot.get_normalized_request(3, request_again) ||
            (request_again.targets[0].qpair_count != 1))
            `uvm_fatal("RESOURCE_SNAPSHOT", "normalized request leaked mutable state")
        resource_snapshot.list_reserved_global_qpair_ids(reservation_ids);
        reservation_ids[0] = 0;
        resource_snapshot.list_reserved_global_qpair_ids(reservation_ids);
        if ((reservation_ids.size() != 1) || (reservation_ids[0] != 4))
            `uvm_fatal("RESOURCE_SNAPSHOT", "reservation query leaked mutable state")
        if (!resource_snapshot.references_device_snapshot(device_snapshot))
            `uvm_fatal("RESOURCE_SNAPSHOT", "device snapshot identity was not retained")
        if (resource_snapshot.add_vio_binding(binding, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", "frozen snapshot accepted a binding")

        invalid_binding = binding;
        invalid_binding.local_pair_id = 32;
        invalid_binding.rx_local_virtqueue_id = 64;
        invalid_binding.tx_local_virtqueue_id = 65;
        expect_freeze_failure("local_hard_limit", make_plan(service_key, 128, 33),
                              device_snapshot, invalid_binding,
                              DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE, 1, 1, 1, 0);

        invalid_binding = binding;
        invalid_binding.global_qpair_id = 2048;
        expect_freeze_failure("global_hard_limit", make_plan(service_key, 2049, 32),
                              device_snapshot, invalid_binding,
                              DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE, 1, 1, 1, 0);

        expect_freeze_failure("participant_hard_limit",
                              make_plan(service_key, 128, 33, 33, 33),
                              device_snapshot, binding,
                              DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                              1, 0, 1, 0);

        nonzero_instance_snapshot = make_device_snapshot(nonzero_instance_service, 1);
        invalid_binding = binding;
        invalid_binding.service_key = nonzero_instance_service;
        expect_freeze_failure("nonzero_service_instance",
                              make_plan(nonzero_instance_service),
                              nonzero_instance_snapshot, invalid_binding,
                              DPU_PLACE_ERR_INVALID_REQUEST, 1, 0, 1, 1);

        multiple_vio_snapshot = make_device_snapshot(multiple_vio_service, 0, 1);
        invalid_binding = binding;
        invalid_binding.service_key = multiple_vio_service;
        expect_freeze_failure("multiple_vio_services",
                              make_plan(multiple_vio_service), multiple_vio_snapshot,
                              invalid_binding, DPU_PLACE_ERR_INVALID_REQUEST,
                              1, 0, 1, 1);

        resource_snapshot = dpu_resource_snapshot::type_id::create("null_diagnostic");
        if (!resource_snapshot.set_normalized_plan(plan, diagnostic) ||
            !resource_snapshot.add_vio_binding(binding, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", diagnostic.message)
        null_diagnostic = null;
        if (resource_snapshot.freeze(null, null_diagnostic) ||
            (null_diagnostic == null) ||
            (null_diagnostic.error_code != DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH))
            `uvm_fatal("RESOURCE_SNAPSHOT", "failure did not publish a usable diagnostic")
        test_deleted_service_owner_is_snapshot_mismatch();
        test_configuration_resolver_atomicity();
    endfunction
endclass : dpu_resource_resolver_test

`endif // DPU_RESOURCE_RESOLVER_TEST_SV
