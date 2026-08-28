`ifndef DPU_RESOURCE_MANAGER_TEST_SV
`define DPU_RESOURCE_MANAGER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

// Test-only corruption hooks verify that manager import is atomic and copies
// externally visible profile identities instead of aliasing a snapshot's
// internal storage. All leases themselves still come from the coordinator.
class dpu_resource_manager_snapshot_probe extends dpu_resource_snapshot;
    `uvm_object_utils(dpu_resource_manager_snapshot_probe)

    function new(string name = "dpu_resource_manager_snapshot_probe");
        super.new(name);
    endfunction

    function void corrupt_profile_capacity(
        input string profile_name,
        input int unsigned capacity
    );
        foreach (m_profiles[index]) begin
            if (m_profiles[index].name == profile_name)
                m_profiles[index].capacity = capacity;
        end
    endfunction

    function void corrupt_profile_name(
        input string old_name,
        input string new_name
    );
        foreach (m_profiles[index]) begin
            if (m_profiles[index].name == old_name)
                m_profiles[index].name = new_name;
        end
    endfunction

    function void corrupt_profile_class_id(
        input string profile_name,
        input dpu_resource_class_id_t class_id
    );
        foreach (m_profiles[index]) begin
            if (m_profiles[index].name == profile_name)
                m_profiles[index].class_id = class_id;
        end
    endfunction
endclass : dpu_resource_manager_snapshot_probe

class dpu_resource_manager_device_snapshot_probe extends dpu_device_snapshot;
    `uvm_object_utils(dpu_resource_manager_device_snapshot_probe)

    function new(string name = "dpu_resource_manager_device_snapshot_probe");
        super.new(name);
    endfunction

    function void mark_unfrozen();
        m_frozen = 0;
    endfunction
endclass : dpu_resource_manager_device_snapshot_probe


// Snapshot imports retain the full DUT function inventory, while VIO qpair
// ownership remains service-scoped, coordinator-authored, and immutable.
class dpu_resource_manager_test extends uvm_test;
    `uvm_component_utils(dpu_resource_manager_test)

    dpu_device_snapshot device_snapshot;
    dpu_resource_snapshot resource_snapshot;
    dpu_service_key_t service_key;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_function_key(
        input int unsigned host_id,
        input int unsigned pf_id,
        input dpu_function_kind_e kind,
        input int unsigned vf_id
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

        cfg = dpu_device_cfg::type_id::create("capacity_cfg");
        cfg.dut_caps.max_hosts = DPU_MAX_HOSTS;
        cfg.dut_caps.max_pfs_per_host = DPU_MAX_PFS_PER_HOST;
        cfg.dut_caps.max_vfs_per_pf = DPU_MAX_VFS_PER_PF;
        cfg.dut_caps.max_functions = DPU_MAX_FUNCTIONS;
        for (int unsigned host_id = 0;
             host_id < DPU_MAX_HOSTS;
             host_id++) begin
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
                 pf_id < DPU_MAX_PFS_PER_HOST;
                 pf_id++) begin
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
                    function_cfg.eligible_service_kinds.push_back(
                        DPU_SERVICE_VIO_NET);
                end
                cfg.functions.push_back(function_cfg);
            end
        end
        for (int unsigned function_index = 0;
             function_index < 60;
             function_index++) begin
            int unsigned host_id;
            int unsigned pf_id;

            host_id = function_index / DPU_MAX_PFS_PER_HOST;
            pf_id = function_index % DPU_MAX_PFS_PER_HOST;
            for (int unsigned vf_id = 0;
                 vf_id < DPU_MAX_VFS_PER_PF;
                 vf_id++) begin
                cfg.functions.push_back(make_function_cfg(make_function_key(
                    host_id, pf_id, DPU_FUNCTION_VF, vf_id)));
            end
        end
        cfg.af_request.mode = DPU_AF_SELECTED;
        cfg.af_request.requester = make_function_key(
            0, 0, DPU_FUNCTION_PF, 0);
        return cfg;
    endfunction

    function automatic dpu_resource_placement_cfg make_capacity_placement_cfg();
        dpu_resource_placement_cfg placement_cfg;
        dpu_resource_pool_config_t auxiliary_profile;
        dpu_resource_pool_config_t qpair_profile;
        dpu_vio_placement_request request;
        dpu_vio_qpair_override qpair_override;
        dpu_global_id_range_t reservation_range;
        dpu_function_key_t owner;

        placement_cfg = dpu_resource_placement_cfg::type_id::create(
            "capacity_placement_cfg");
        auxiliary_profile.name = "auxiliary.resource";
        auxiliary_profile.class_id = 7;
        auxiliary_profile.kind = DPU_RESOURCE_KIND_DMA_WINDOW;
        auxiliary_profile.capacity = 64;
        auxiliary_profile.max_per_function = 4;
        placement_cfg.profiles.push_back(auxiliary_profile);
        qpair_profile.name = "virtio.qpair";
        qpair_profile.class_id = 41;
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = 2048;
        qpair_profile.max_per_function = 32;
        placement_cfg.profiles.push_back(qpair_profile);
        placement_cfg.reserved_global_qpair_ids.push_back(4);
        reservation_range.first_id = 8;
        reservation_range.last_id = 9;
        placement_cfg.reserved_global_qpair_ranges.push_back(reservation_range);

        owner = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
        request = dpu_vio_placement_request::type_id::create(
            "capacity_request");
        request.request_id = 77;
        request.service_instance_id = 0;
        request.total_qpairs = 2;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.ordering = DPU_PLACEMENT_CANONICAL;
        request.fixed_devices.push_back(owner);

        qpair_override = dpu_vio_qpair_override::type_id::create(
            "capacity_pair_0");
        qpair_override.request_pair_index = 0;
        qpair_override.owner_mode = DPU_ASSIGN_PINNED;
        qpair_override.requested_owner = owner;
        qpair_override.local_mode = DPU_ASSIGN_PINNED;
        qpair_override.requested_local_pair_id = 17;
        qpair_override.global_mode = DPU_ASSIGN_PINNED;
        qpair_override.requested_global_qpair_id = 91;
        request.qpair_overrides.push_back(qpair_override);

        qpair_override = dpu_vio_qpair_override::type_id::create(
            "capacity_pair_1");
        qpair_override.request_pair_index = 1;
        qpair_override.owner_mode = DPU_ASSIGN_PINNED;
        qpair_override.requested_owner = owner;
        qpair_override.local_mode = DPU_ASSIGN_PINNED;
        qpair_override.requested_local_pair_id = 3;
        qpair_override.global_mode = DPU_ASSIGN_PINNED;
        qpair_override.requested_global_qpair_id = 7;
        request.qpair_overrides.push_back(qpair_override);
        placement_cfg.vio_requests.push_back(request);
        return placement_cfg;
    endfunction

    function automatic void resolve_capacity_pair(
        input string name,
        output dpu_device_snapshot resolved_device_snapshot,
        output dpu_resource_snapshot resolved_resource_snapshot
    );
        dpu_configuration_resolver resolver;
        dpu_placement_diagnostic diagnostic;
        dpu_device_cfg device_cfg;
        dpu_resource_placement_cfg placement_cfg;

        device_cfg = make_capacity_device_cfg();
        placement_cfg = make_capacity_placement_cfg();
        resolver = dpu_configuration_resolver::type_id::create(
            {name, "_resolver"});
        if (!resolver.resolve(device_cfg, placement_cfg,
                              resolved_device_snapshot,
                              resolved_resource_snapshot, diagnostic)) begin
            `uvm_fatal("DPU_RESOURCE", {"configuration resolution failed: ",
                       diagnostic.message})
        end
    endfunction

    function void assert_unconfigured(
        input dpu_resource_manager manager,
        input dpu_function_key_t key,
        input string name
    );
        dpu_resource_class_id_t class_id;
        string why;

        if (manager.contains_function(key) ||
            manager.lookup_resource_class("virtio.qpair", class_id, why)) begin
            `uvm_fatal("DPU_RESOURCE",
                {name, " published partial import state"})
        end
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_service_key_t services[$];

        super.build_phase(phase);
        dpu_device_snapshot::type_id::set_type_override(
            dpu_resource_manager_device_snapshot_probe::get_type());
        dpu_resource_snapshot::type_id::set_type_override(
            dpu_resource_manager_snapshot_probe::get_type());
        resolve_capacity_pair(
            "manager", device_snapshot, resource_snapshot);
        device_snapshot.list_services(DPU_SERVICE_VIO_NET, services);
        if (services.size() != 1)
            `uvm_fatal("DPU_RESOURCE", "resolved device lost its VIO service")
        service_key = services[0];
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
        dpu_device_snapshot unfrozen_device;
        dpu_resource_snapshot unfrozen_device_resource;
        dpu_resource_snapshot expanded_resource;
        dpu_resource_snapshot conflicted_resource;
        dpu_resource_snapshot mismatched_resource;
        dpu_device_snapshot mismatched_device;
        dpu_resource_manager_snapshot_probe snapshot_probe;
        dpu_resource_manager_device_snapshot_probe device_snapshot_probe;
        dpu_dut_caps caps;
        int unsigned global_id;
        string why;

        phase.raise_objection(this);
        device_snapshot.list_functions(keys);
        if (keys.size() != DPU_MAX_FUNCTIONS)
            `uvm_fatal("DPU_RESOURCE",
                "resolved snapshot lost 1024-function coverage")

        manager = dpu_resource_manager::type_id::create("snapshot_manager");
        authority = manager.claim_registry_authority();
        if ((authority == null) || !manager.configure_from_snapshots(
                authority, device_snapshot, resource_snapshot, why)) begin
            `uvm_fatal("DPU_RESOURCE", {"snapshot import failed: ", why})
        end
        if (!manager.is_seeded_from_snapshots(
                device_snapshot, resource_snapshot)) begin
            `uvm_fatal("DPU_RESOURCE", "manager lost exact snapshot identity")
        end
        foreach (keys[index]) begin
            if (!manager.contains_function(keys[index]))
                `uvm_fatal("DPU_RESOURCE", "manager lost function inventory")
        end
        caps = manager.snapshot_dut_caps();
        if ((caps == null) || (caps.max_functions != DPU_MAX_FUNCTIONS) ||
            (caps.vio_global_qpair_count != DPU_MAX_VIO_GLOBAL_QPAIRS) ||
            (caps.max_vio_net_qpairs_per_device !=
             DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE)) begin
            `uvm_fatal("DPU_RESOURCE", "manager lost DUT capability limits")
        end
        if (!manager.lookup_resource_class(
                "virtio.qpair", qpair_class_id, why) ||
            (qpair_class_id != 41) ||
            !manager.local_pair_to_global_qpair(
                service_key, qpair_class_id, 17, global_id) ||
            (global_id != 91)) begin
            `uvm_fatal("DPU_RESOURCE",
                {"manager query disagrees with snapshot: ", why})
        end
        manager.list_service_leases(service_key, leases);
        if ((leases.size() != 2) || (leases[0].local_id != 3) ||
            (leases[1].local_id != 17) ||
            !leases[0].frozen || !leases[1].frozen ||
            (leases[0].owner.kind != DPU_RESOURCE_OWNER_SERVICE) ||
            (dpu_service_key_name(leases[1].owner.service_key) !=
             dpu_service_key_name(service_key))) begin
            `uvm_fatal("DPU_RESOURCE",
                "imported service leases lost frozen ownership")
        end
        leases[0].global_id = 0;
        manager.list_service_leases(service_key, leases);
        if (leases[0].global_id != 7)
            `uvm_fatal("DPU_RESOURCE", "service lease query leaked mutable state")
        if (manager.configure_from_snapshots(
                authority, device_snapshot, resource_snapshot, why) ||
            !manager.is_seeded_from_snapshots(
                device_snapshot, resource_snapshot)) begin
            `uvm_fatal("DPU_RESOURCE",
                "second snapshot import changed manager state")
        end

        wrong_manager = dpu_resource_manager::type_id::create("wrong_manager");
        wrong_authority = wrong_manager.claim_registry_authority();
        failed_manager = dpu_resource_manager::type_id::create(
            "wrong_authority_manager");
        void'(failed_manager.claim_registry_authority());
        if (failed_manager.configure_from_snapshots(
                wrong_authority, device_snapshot, resource_snapshot, why)) begin
            `uvm_fatal("DPU_RESOURCE",
                "wrong registry authority imported snapshots")
        end
        assert_unconfigured(failed_manager, keys[0], "wrong authority");

        failed_manager = dpu_resource_manager::type_id::create(
            "unfrozen_manager");
        authority = failed_manager.claim_registry_authority();
        unfrozen_resource = dpu_resource_snapshot::type_id::create(
            "unfrozen_resource");
        if (failed_manager.configure_from_snapshots(
                authority, device_snapshot, unfrozen_resource, why)) begin
            `uvm_fatal("DPU_RESOURCE", "unfrozen resource snapshot imported")
        end
        assert_unconfigured(failed_manager, keys[0], "unfrozen snapshot");

        // Resolve a fully valid, identity-matched pair, then use a test-only
        // device hook to expose the manager guard independently.  The frozen
        // resource snapshot continues to reference this exact device handle.
        resolve_capacity_pair("unfrozen_device", unfrozen_device,
                              unfrozen_device_resource);
        if (!$cast(device_snapshot_probe, unfrozen_device) ||
            !unfrozen_device_resource.references_device_snapshot(
                unfrozen_device)) begin
            `uvm_fatal("DPU_RESOURCE",
                "unfrozen-device fixture lost exact snapshot identity")
        end
        device_snapshot_probe.mark_unfrozen();
        if (unfrozen_device.is_frozen() ||
            !unfrozen_device_resource.references_device_snapshot(
                unfrozen_device)) begin
            `uvm_fatal("DPU_RESOURCE",
                "unfrozen-device probe changed resource snapshot identity")
        end
        failed_manager = dpu_resource_manager::type_id::create(
            "unfrozen_device_manager");
        authority = failed_manager.claim_registry_authority();
        if (failed_manager.configure_from_snapshots(
                authority, unfrozen_device, unfrozen_device_resource, why) ||
            (why != "resource snapshot is not frozen against the supplied device snapshot") ||
            failed_manager.is_snapshot_seeded()) begin
            `uvm_fatal("DPU_RESOURCE",
                "unfrozen device snapshot did not receive the freeze/reference rejection")
        end
        assert_unconfigured(failed_manager, keys[0], "unfrozen device snapshot");

        resolve_capacity_pair(
            "expanded", mismatched_device, expanded_resource);
        if (!$cast(snapshot_probe, expanded_resource))
            `uvm_fatal("DPU_RESOURCE", "expanded snapshot lacks probe type")
        snapshot_probe.corrupt_profile_capacity("virtio.qpair", 2049);
        failed_manager = dpu_resource_manager::type_id::create(
            "expanded_manager");
        authority = failed_manager.claim_registry_authority();
        if (failed_manager.configure_from_snapshots(
                authority, mismatched_device, expanded_resource, why)) begin
            `uvm_fatal("DPU_RESOURCE", "profile expansion imported")
        end
        assert_unconfigured(failed_manager, keys[0], "profile expansion");

        resolve_capacity_pair(
            "conflicted", mismatched_device, conflicted_resource);
        if (!$cast(snapshot_probe, conflicted_resource))
            `uvm_fatal("DPU_RESOURCE", "conflicted snapshot lacks probe type")
        snapshot_probe.corrupt_profile_class_id("auxiliary.resource", 41);
        failed_manager = dpu_resource_manager::type_id::create(
            "class_id_conflict_manager");
        authority = failed_manager.claim_registry_authority();
        if (failed_manager.configure_from_snapshots(
                authority, mismatched_device, conflicted_resource, why)) begin
            `uvm_fatal("DPU_RESOURCE",
                "conflicting snapshot class IDs imported")
        end
        assert_unconfigured(failed_manager, keys[0], "conflicting class IDs");

        resolve_capacity_pair(
            "mismatch", mismatched_device, mismatched_resource);
        failed_manager = dpu_resource_manager::type_id::create(
            "mismatch_manager");
        authority = failed_manager.claim_registry_authority();
        if (failed_manager.configure_from_snapshots(
                authority, mismatched_device, resource_snapshot, why)) begin
            `uvm_fatal("DPU_RESOURCE", "mismatched snapshots imported")
        end
        assert_unconfigured(failed_manager, keys[0], "mismatched snapshots");

        if (!$cast(snapshot_probe, resource_snapshot))
            `uvm_fatal("DPU_RESOURCE", "resource snapshot lacks probe type")
        snapshot_probe.corrupt_profile_name(
            "virtio.qpair", "mutated.snapshot.profile");
        if (!manager.lookup_resource_class(
                "virtio.qpair", qpair_class_id, why) ||
            manager.lookup_resource_class(
                "mutated.snapshot.profile", qpair_class_id, why)) begin
            `uvm_fatal("DPU_RESOURCE",
                "manager aliased resource snapshot profile storage")
        end
        phase.drop_objection(this);
    endtask
endclass : dpu_resource_manager_test

`endif // DPU_RESOURCE_MANAGER_TEST_SV
