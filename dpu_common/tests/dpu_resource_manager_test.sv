`ifndef DPU_RESOURCE_MANAGER_TEST_SV
`define DPU_RESOURCE_MANAGER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

// Snapshot imports retain the full DUT function inventory, while VIO qpair
// ownership remains service-scoped and immutable.
class dpu_resource_manager_test extends uvm_test;
    `uvm_component_utils(dpu_resource_manager_test)

    dpu_device_snapshot device_snapshot;
    dpu_resource_snapshot resource_snapshot;
    dpu_service_key_t service_key;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_function_key(
        input int unsigned host_id, input int unsigned pf_id,
        input dpu_function_kind_e kind, input int unsigned vf_id
    );
        dpu_function_key_t key;
        key.host_id = host_id;
        key.pf_id = pf_id;
        key.kind = kind;
        key.vf_id = vf_id;
        return key;
    endfunction

    function automatic dpu_function_cfg make_function_cfg(
        input dpu_function_key_t key
    );
        dpu_function_cfg function_cfg;
        function_cfg = dpu_function_cfg::type_id::create("function_cfg");
        function_cfg.key = key;
        function_cfg.domain_key.host_id = key.host_id;
        function_cfg.domain_key.segment_id = key.host_id;
        function_cfg.bdf_mode = DPU_ALLOC_AUTO;
        return function_cfg;
    endfunction

    function automatic dpu_device_cfg make_capacity_device_cfg();
        dpu_device_cfg cfg;
        dpu_function_cfg function_cfg;
        dpu_bar_request af_bar;
        dpu_service_decl vio_service;

        cfg = dpu_device_cfg::type_id::create("capacity_cfg");
        cfg.dut_caps.max_hosts = DPU_MAX_HOSTS;
        cfg.dut_caps.max_pfs_per_host = DPU_MAX_PFS_PER_HOST;
        cfg.dut_caps.max_vfs_per_pf = DPU_MAX_VFS_PER_PF;
        cfg.dut_caps.max_functions = DPU_MAX_FUNCTIONS;
        for (int unsigned host_id = 0; host_id < DPU_MAX_HOSTS; host_id++) begin
            dpu_host_cfg host;
            dpu_pcie_domain_cfg domain;
            dpu_bdf_range_t bdf_range;
            dpu_mmio_window_cfg window;

            host = dpu_host_cfg::type_id::create("host");
            host.host_id = host_id;
            domain = dpu_pcie_domain_cfg::type_id::create("domain");
            domain.key.host_id = host_id;
            domain.key.segment_id = host_id;
            bdf_range.first_bdf = 16'h0010;
            bdf_range.last_bdf = 16'h011f;
            domain.bdf_ranges.push_back(bdf_range);
            window = dpu_mmio_window_cfg::type_id::create("window");
            window.base = 64'h0000_0001_0000_0000;
            window.limit = 64'h0000_0001_0400_0000;
            window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
            domain.mmio_windows.push_back(window);
            host.pcie_domains.push_back(domain);
            cfg.hosts.push_back(host);
            for (int unsigned pf_id = 0;
                 pf_id < DPU_MAX_PFS_PER_HOST; pf_id++) begin
                function_cfg = make_function_cfg(make_function_key(
                    host_id, pf_id, DPU_FUNCTION_PF, 0));
                if ((host_id == 0) && (pf_id == 0)) begin
                    af_bar = dpu_bar_request::type_id::create("af_bar");
                    af_bar.role = DPU_BAR_DEVICE_MEMORY;
                    af_bar.even_bar_id = 0;
                    af_bar.size = 64'h0000_0000_0200_0000;
                    af_bar.alignment = 64'h0000_0000_0200_0000;
                    af_bar.placement = DPU_ALLOC_AUTO;
                    function_cfg.bars.push_back(af_bar);
                    vio_service = dpu_service_decl::type_id::create("vio_service");
                    vio_service.service_kind = DPU_SERVICE_VIO_NET;
                    vio_service.service_instance_id = 0;
                    function_cfg.services.push_back(vio_service);
                end
                cfg.functions.push_back(function_cfg);
            end
        end
        for (int unsigned function_index = 0; function_index < 60;
             function_index++) begin
            int unsigned host_id;
            int unsigned pf_id;
            host_id = function_index / DPU_MAX_PFS_PER_HOST;
            pf_id = function_index % DPU_MAX_PFS_PER_HOST;
            for (int unsigned vf_id = 0; vf_id < DPU_MAX_VFS_PER_PF; vf_id++)
                cfg.functions.push_back(make_function_cfg(make_function_key(
                    host_id, pf_id, DPU_FUNCTION_VF, vf_id)));
        end
        cfg.af_request.mode = DPU_AF_SELECTED;
        cfg.af_request.requester = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
        return cfg;
    endfunction

    function automatic dpu_resource_snapshot make_resource_snapshot(
        input dpu_device_snapshot snapshot,
        input dpu_service_key_t owner,
        input int unsigned profile_capacity = 2048,
        input int unsigned profile_per_function = 32,
        input bit freeze_snapshot = 1,
        input dpu_resource_class_id_t qpair_snapshot_class_id = 0,
        input bit add_reordered_aux_profile = 0,
        input bit conflict_class_ids = 0,
        input int unsigned reservation_ids[$] = '{},
        input dpu_global_id_range_t reservation_ranges[$] = '{}
    );
        dpu_normalized_placement_plan plan;
        dpu_normalized_vio_request request;
        dpu_normalized_vio_pair_t pair;
        dpu_vio_participant_target_t target;
        dpu_resource_pool_config_t profile;
        dpu_resource_pool_config_t auxiliary_profile;
        dpu_vio_qpair_binding_t binding;
        dpu_resource_snapshot result;
        dpu_placement_diagnostic diagnostic;
        string why;

        plan = dpu_normalized_placement_plan::type_id::create("manager_plan");
        plan.effective_global_capacity = 2048;
        plan.effective_device_capacity = 32;
        profile.name = "virtio.qpair";
        profile.class_id = qpair_snapshot_class_id;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = profile_capacity;
        profile.max_per_function = profile_per_function;
        if (add_reordered_aux_profile || conflict_class_ids) begin
            auxiliary_profile.name = "auxiliary.resource";
            auxiliary_profile.class_id = conflict_class_ids ?
                                       qpair_snapshot_class_id : 7;
            auxiliary_profile.kind = DPU_RESOURCE_KIND_DMA_WINDOW;
            auxiliary_profile.capacity = 64;
            auxiliary_profile.max_per_function = 4;
            plan.set_profiles('{auxiliary_profile, profile});
        end
        else begin
            plan.set_profiles('{profile});
        end
        plan.set_reservations(reservation_ids, reservation_ranges);
        request = dpu_normalized_vio_request::type_id::create("manager_request");
        request.request_id = 77;
        request.service_instance_id = owner.service_instance_id;
        request.total_qpairs = 2;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.ordering = DPU_PLACEMENT_CANONICAL;
        request.canonical_candidates.push_back(owner.function_key);
        request.effective_candidates.push_back(owner.function_key);
        target.request_id = request.request_id;
        target.service_key = owner;
        target.qpair_count = 2;
        request.targets.push_back(target);
        pair.request_pair_index = 0;
        pair.service_key = owner;
        pair.local_mode = DPU_ASSIGN_PINNED;
        pair.requested_local_pair_id = 17;
        pair.global_mode = DPU_ASSIGN_PINNED;
        pair.requested_global_qpair_id = 91;
        request.pairs.push_back(pair);
        pair.request_pair_index = 1;
        pair.requested_local_pair_id = 3;
        pair.requested_global_qpair_id = 7;
        request.pairs.push_back(pair);
        if (!plan.add_request(request, why) || !plan.freeze(why))
            `uvm_fatal("DPU_RESOURCE", {"cannot make resource plan: ", why})
        result = dpu_resource_snapshot::type_id::create("manager_resource_snapshot");
        diagnostic = dpu_placement_diagnostic::type_id::create("manager_diag");
        binding.request_id = 77;
        binding.service_key = owner;
        binding.request_pair_index = 0;
        binding.local_pair_id = 17;
        binding.rx_local_virtqueue_id = 34;
        binding.tx_local_virtqueue_id = 35;
        binding.global_qpair_id = 91;
        if (!result.set_normalized_plan(plan, diagnostic) ||
            !result.add_vio_binding(binding, diagnostic))
            `uvm_fatal("DPU_RESOURCE", diagnostic.message)
        binding.request_pair_index = 1;
        binding.local_pair_id = 3;
        binding.rx_local_virtqueue_id = 6;
        binding.tx_local_virtqueue_id = 7;
        binding.global_qpair_id = 7;
        if (!result.add_vio_binding(binding, diagnostic))
            `uvm_fatal("DPU_RESOURCE", diagnostic.message)
        if (freeze_snapshot && !result.freeze(snapshot, diagnostic))
            `uvm_fatal("DPU_RESOURCE", diagnostic.message)
        return result;
    endfunction

    function void assert_unconfigured(
        input dpu_resource_manager manager,
        input dpu_function_key_t key,
        input string name
    );
        dpu_resource_class_id_t class_id;
        string why;
        if (manager.contains_function(key) ||
            manager.lookup_resource_class("virtio.qpair", class_id, why))
            `uvm_fatal("DPU_RESOURCE", {name, " published partial import state"})
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_resolver resolver;
        dpu_service_key_t services[$];
        string why;

        super.build_phase(phase);
        resolver = dpu_device_resolver::type_id::create("manager_device_resolver");
        if (!resolver.resolve(make_capacity_device_cfg(), device_snapshot, why))
            `uvm_fatal("DPU_RESOURCE", {"device resolution failed: ", why})
        device_snapshot.list_services(DPU_SERVICE_VIO_NET, services);
        if (services.size() != 1)
            `uvm_fatal("DPU_RESOURCE", "resolved device lost its VIO service")
        service_key = services[0];
        resource_snapshot = make_resource_snapshot(device_snapshot, service_key);
    endfunction

    virtual task run_phase(uvm_phase phase);
        dpu_resource_manager manager;
        dpu_resource_manager wrong_manager;
        dpu_resource_manager failed_manager;
        dpu_resource_registry_authority authority;
        dpu_resource_registry_authority wrong_authority;
        dpu_resource_class_id_t qpair_class_id;
        dpu_resource_lease_t leases[$];
        dpu_function_key_t keys[$];
        dpu_resource_snapshot unfrozen_resource;
        dpu_resource_snapshot expanded_resource;
        dpu_resource_snapshot conflicted_resource;
        dpu_device_snapshot mismatched_device;
        dpu_device_resolver resolver;
        int unsigned global_id;
        int unsigned reservation_ids[$];
        dpu_global_id_range_t reservation_ranges[$];
        string why;

        phase.raise_objection(this);
        device_snapshot.list_functions(keys);
        if (keys.size() != DPU_MAX_FUNCTIONS)
            `uvm_fatal("DPU_RESOURCE", "resolved snapshot lost 1024-function coverage")

        reservation_ids = '{4};
        reservation_ranges = '{'{first_id: 8, last_id: 9}};
        resource_snapshot = make_resource_snapshot(
            device_snapshot, service_key, 2048, 32, 1, 41, 1, 0,
            reservation_ids, reservation_ranges);
        manager = dpu_resource_manager::type_id::create("snapshot_manager");
        authority = manager.claim_registry_authority();
        if ((authority == null) || !manager.configure_from_snapshots(
                authority, device_snapshot, resource_snapshot, why))
            `uvm_fatal("DPU_RESOURCE", {"snapshot import failed: ", why})
        if (!manager.is_seeded_from_snapshots(device_snapshot, resource_snapshot))
            `uvm_fatal("DPU_RESOURCE", "manager lost exact snapshot identity")
        if (!manager.lookup_resource_class("virtio.qpair", qpair_class_id, why) ||
            (qpair_class_id != 41) ||
            !manager.local_pair_to_global_qpair(service_key, qpair_class_id, 17,
                                                global_id) || (global_id != 91))
            `uvm_fatal("DPU_RESOURCE", {"manager query disagrees with snapshot: ", why})
        manager.list_service_leases(service_key, leases);
        if ((leases.size() != 2) || (leases[0].local_id != 3) ||
            (leases[1].local_id != 17) || !leases[0].frozen || !leases[1].frozen ||
            (leases[0].owner.kind != DPU_RESOURCE_OWNER_SERVICE) ||
            (dpu_service_key_name(leases[1].owner.service_key) !=
             dpu_service_key_name(service_key)))
            `uvm_fatal("DPU_RESOURCE", "imported service leases lost frozen ownership")
        leases[0].global_id = 0;
        manager.list_service_leases(service_key, leases);
        if (leases[0].global_id != 7)
            `uvm_fatal("DPU_RESOURCE", "service lease query leaked mutable state")
        if (!manager.mark_function_device_ready(keys[1], why) ||
            !manager.acquire_leases(keys[1], qpair_class_id, 0, 10, leases, why))
            `uvm_fatal("DPU_RESOURCE", {"legacy allocation probe failed: ", why})
        foreach (leases[index]) begin
            if ((leases[index].global_id == 4) || (leases[index].global_id == 8) ||
                (leases[index].global_id == 9))
                `uvm_fatal("DPU_RESOURCE", "legacy allocation consumed a reserved global qpair")
        end
        if (manager.configure_from_snapshots(authority, device_snapshot,
                                             resource_snapshot, why) ||
            !manager.is_seeded_from_snapshots(device_snapshot, resource_snapshot))
            `uvm_fatal("DPU_RESOURCE", "second snapshot import changed manager state")

        wrong_manager = dpu_resource_manager::type_id::create("wrong_manager");
        wrong_authority = wrong_manager.claim_registry_authority();
        failed_manager = dpu_resource_manager::type_id::create("wrong_authority_manager");
        failed_manager.claim_registry_authority();
        if (failed_manager.configure_from_snapshots(wrong_authority, device_snapshot,
                                                    resource_snapshot, why))
            `uvm_fatal("DPU_RESOURCE", "wrong registry authority imported snapshots")
        assert_unconfigured(failed_manager, keys[0], "wrong authority");

        failed_manager = dpu_resource_manager::type_id::create("unfrozen_manager");
        authority = failed_manager.claim_registry_authority();
        unfrozen_resource = make_resource_snapshot(device_snapshot, service_key,
                                                   2048, 32, 0);
        if (failed_manager.configure_from_snapshots(authority, device_snapshot,
                                                    unfrozen_resource, why))
            `uvm_fatal("DPU_RESOURCE", "unfrozen resource snapshot imported")
        assert_unconfigured(failed_manager, keys[0], "unfrozen snapshot");

        failed_manager = dpu_resource_manager::type_id::create("expanded_manager");
        authority = failed_manager.claim_registry_authority();
        expanded_resource = make_resource_snapshot(device_snapshot, service_key,
                                                   2049, 32);
        if (failed_manager.configure_from_snapshots(authority, device_snapshot,
                                                    expanded_resource, why))
            `uvm_fatal("DPU_RESOURCE", "profile expansion imported")
        assert_unconfigured(failed_manager, keys[0], "profile expansion");

        failed_manager = dpu_resource_manager::type_id::create("class_id_conflict_manager");
        authority = failed_manager.claim_registry_authority();
        conflicted_resource = make_resource_snapshot(
            device_snapshot, service_key, 2048, 32, 1, 41, 1, 1,
            reservation_ids, reservation_ranges);
        if (failed_manager.configure_from_snapshots(authority, device_snapshot,
                                                    conflicted_resource, why))
            `uvm_fatal("DPU_RESOURCE", "conflicting snapshot class IDs imported")
        assert_unconfigured(failed_manager, keys[0], "conflicting class IDs");

        resolver = dpu_device_resolver::type_id::create("mismatch_resolver");
        if (!resolver.resolve(make_capacity_device_cfg(), mismatched_device, why))
            `uvm_fatal("DPU_RESOURCE", {"mismatch device resolution failed: ", why})
        failed_manager = dpu_resource_manager::type_id::create("mismatch_manager");
        authority = failed_manager.claim_registry_authority();
        if (failed_manager.configure_from_snapshots(authority, mismatched_device,
                                                    resource_snapshot, why))
            `uvm_fatal("DPU_RESOURCE", "mismatched snapshots imported")
        assert_unconfigured(failed_manager, keys[0], "mismatched snapshots");
        phase.drop_objection(this);
    endtask
endclass : dpu_resource_manager_test

`endif // DPU_RESOURCE_MANAGER_TEST_SV
