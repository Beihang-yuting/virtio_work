`ifndef DPU_RESOURCE_MANAGER_TEST_SV
`define DPU_RESOURCE_MANAGER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

// ============================================================================
// dpu_resource_manager_test
//
// Defines the generic lease boundary for the snapshot-seeded resource manager:
// 4 hosts x 16 PFs plus 60 x 16 VFs consume all 1024 function identities.
// ============================================================================

class dpu_resource_manager_test extends uvm_test;
    `uvm_component_utils(dpu_resource_manager_test)

    dpu_device_env device_env;
    dpu_device_env_config device_env_cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_resource_pool_config_t qpair_profile;

        super.build_phase(phase);
        device_env_cfg = dpu_device_env_config::type_id::create("device_env_cfg");
        device_env_cfg.device_cfg = make_capacity_device_cfg();
        qpair_profile = make_resource_profile(
            "virtio.qpair", DPU_RESOURCE_KIND_QUEUE, 2048, 32
        );
        device_env_cfg.resource_profiles.push_back(qpair_profile);
        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_env_cfg
        );
        device_env = dpu_device_env::type_id::create("device_env", this);
    endfunction

    function automatic dpu_function_key_t make_function_key(
        int unsigned host_id,
        int unsigned pf_id,
        dpu_function_kind_e kind,
        int unsigned vf_id
    );
        dpu_function_key_t key;

        key.host_id = host_id;
        key.pf_id = pf_id;
        key.kind = kind;
        key.vf_id = vf_id;
        return key;
    endfunction

    function automatic dpu_resource_pool_config_t make_resource_profile(
        string name,
        dpu_resource_kind_e kind,
        int unsigned capacity,
        int unsigned max_per_function
    );
        dpu_resource_pool_config_t profile;

        profile.name = name;
        profile.kind = kind;
        profile.capacity = capacity;
        profile.max_per_function = max_per_function;
        return profile;
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
                    host_id, pf_id, DPU_FUNCTION_PF, 0
                ));
                if ((host_id == 0) && (pf_id == 0)) begin
                    af_bar = dpu_bar_request::type_id::create("af_bar");
                    af_bar.role = DPU_BAR_DEVICE_MEMORY;
                    af_bar.even_bar_id = 0;
                    af_bar.size = 64'h0000_0000_0200_0000;
                    af_bar.alignment = 64'h0000_0000_0200_0000;
                    af_bar.placement = DPU_ALLOC_AUTO;
                    function_cfg.bars.push_back(af_bar);
                end
                cfg.functions.push_back(function_cfg);
            end
        end
        for (int unsigned function_index = 0;
             function_index < 60; function_index++) begin
            int unsigned host_id;
            int unsigned pf_id;

            host_id = function_index / DPU_MAX_PFS_PER_HOST;
            pf_id = function_index % DPU_MAX_PFS_PER_HOST;
            for (int unsigned vf_id = 0;
                 vf_id < DPU_MAX_VFS_PER_PF; vf_id++) begin
                cfg.functions.push_back(make_function_cfg(make_function_key(
                    host_id, pf_id, DPU_FUNCTION_VF, vf_id
                )));
            end
        end
        cfg.af_request.mode = DPU_AF_SELECTED;
        cfg.af_request.requester = make_function_key(
            0, 0, DPU_FUNCTION_PF, 0
        );
        return cfg;
    endfunction

    task assert_canonical_device_identities_and_bar_profiles();
        dpu_function_key_t function_key;
        dpu_function_key_t different_function_key;
        dpu_pcie_domain_key_t domain_key;
        dpu_pcie_domain_key_t different_domain_key;
        dpu_service_key_t service_key;
        dpu_bar_profile_t profile;
        dpu_dut_caps source_caps;
        dpu_dut_caps copied_caps;
        dpu_dut_caps duplicate_caps;
        string why;

        // Catches a production regression that drops one of the canonical
        // function identity fields from the name or equality comparison.
        function_key = make_function_key(1, 2, DPU_FUNCTION_VF, 3);
        different_function_key = make_function_key(1, 2, DPU_FUNCTION_VF, 4);
        if ((dpu_function_key_name(function_key) != "h1.pf2.k1.vf3") ||
            !dpu_same_function_key(function_key, function_key) ||
            dpu_same_function_key(function_key, different_function_key)) begin
            `uvm_fatal("DPU_DEVICE_TYPES", "function key helpers lost identity")
        end
        domain_key.host_id = 1;
        domain_key.segment_id = 7;
        different_domain_key = domain_key;
        different_domain_key.segment_id = 8;
        if (!dpu_same_domain_key(domain_key, domain_key) ||
            dpu_same_domain_key(domain_key, different_domain_key)) begin
            `uvm_fatal("DPU_DEVICE_TYPES", "domain key helper lost identity")
        end
        service_key.function_key = function_key;
        service_key.service_kind = DPU_SERVICE_RDMA;
        service_key.service_instance_id = 5;
        if (dpu_service_key_name(service_key) != "h1.pf2.k1.vf3.svc1.i5") begin
            `uvm_fatal("DPU_DEVICE_TYPES", "service key name lost identity")
        end

        // Catches a production regression that changes a default BAR role,
        // BAR ID, size, alignment, copy isolation, or duplicate validation.
        source_caps = dpu_dut_caps::type_id::create("source_caps");
        if (!source_caps.lookup_bar_profile(
            DPU_FUNCTION_PF, DPU_BAR_DEVICE_MEMORY, profile, why) ||
            (profile.even_bar_id != 0) ||
            (profile.size != 64'h0000_0000_0200_0000) ||
            (profile.alignment != 64'h0000_0000_0200_0000)) begin
            `uvm_fatal("DPU_CAPS", {"missing PF device-memory profile: ", why})
        end
        if (!source_caps.lookup_bar_profile(
            DPU_FUNCTION_PF, DPU_BAR_MAILBOX, profile, why) ||
            (profile.even_bar_id != 2) ||
            (profile.size != 64'h0000_0000_0001_0000) ||
            (profile.alignment != 64'h0000_0000_0001_0000)) begin
            `uvm_fatal("DPU_CAPS", {"missing PF mailbox profile: ", why})
        end
        if (!source_caps.lookup_bar_profile(
            DPU_FUNCTION_PF, DPU_BAR_MSIX, profile, why) ||
            (profile.even_bar_id != 4) ||
            (profile.size != 64'h0000_0000_0001_0000) ||
            (profile.alignment != 64'h0000_0000_0001_0000)) begin
            `uvm_fatal("DPU_CAPS", {"missing PF MSI-X profile: ", why})
        end
        if (!source_caps.lookup_bar_profile(
            DPU_FUNCTION_VF, DPU_BAR_DEVICE_MEMORY, profile, why) ||
            (profile.even_bar_id != 0) ||
            (profile.size != 64'h0000_0000_0000_4000) ||
            (profile.alignment != 64'h0000_0000_0000_4000)) begin
            `uvm_fatal("DPU_CAPS", {"missing VF device-memory profile: ", why})
        end
        if (!source_caps.lookup_bar_profile(
            DPU_FUNCTION_VF, DPU_BAR_MAILBOX, profile, why) ||
            (profile.even_bar_id != 2) ||
            (profile.size != 64'h0000_0000_0000_4000) ||
            (profile.alignment != 64'h0000_0000_0000_4000)) begin
            `uvm_fatal("DPU_CAPS", {"missing VF mailbox profile: ", why})
        end
        if (!source_caps.lookup_bar_profile(
            DPU_FUNCTION_VF, DPU_BAR_MSIX, profile, why) ||
            (profile.even_bar_id != 4) ||
            (profile.size != 64'h0000_0000_0000_8000) ||
            (profile.alignment != 64'h0000_0000_0000_8000)) begin
            `uvm_fatal("DPU_CAPS", {"missing VF MSI-X profile: ", why})
        end
        copied_caps = dpu_dut_caps::type_id::create("copied_caps");
        copied_caps.copy_from(source_caps);
        source_caps.bar_profiles[0].size = '0;
        if (copied_caps.bar_profiles[0].size != 64'h0000_0000_0200_0000) begin
            `uvm_fatal("DPU_CAPS", "BAR profile copy aliases its source")
        end
        duplicate_caps = dpu_dut_caps::type_id::create("duplicate_caps");
        duplicate_caps.bar_profiles.push_back(duplicate_caps.bar_profiles[0]);
        if (duplicate_caps.validate(why)) begin
            `uvm_fatal("DPU_CAPS", "duplicate BAR profile unexpectedly validated")
        end
    endtask

    task assert_registration_and_activation_guards();
        dpu_resource_manager guard_manager;
        dpu_function_key_t parent_key;
        dpu_function_key_t orphan_vf_key;
        dpu_bar_pair_lease_t bars[$];
        string why;

        guard_manager = dpu_resource_manager::type_id::create("guard_manager");
        parent_key = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
        orphan_vf_key = make_function_key(0, 0, DPU_FUNCTION_VF, 0);

        if (guard_manager.register_function(orphan_vf_key, why)) begin
            `uvm_fatal("DPU_RESOURCE", "VF registration succeeded without its PF parent")
        end
        if (!guard_manager.register_function(parent_key, why)) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "guard PF registration failed: %s", why))
        end
        if (guard_manager.activate_function(parent_key, bars, why)) begin
            `uvm_fatal("DPU_RESOURCE", "activation succeeded before resource profiles sealed")
        end
    endtask

    task assert_global_qpair_capacity(
        dpu_resource_manager manager,
        dpu_resource_class_id_t qpair_class_id,
        int unsigned qpair_capacity
    );
        dpu_function_key_t key;
        dpu_function_key_t overflow_key;
        dpu_bar_pair_lease_t bars[$];
        dpu_resource_lease_t leases[$];
        int unsigned global_id;
        string why;

        for (int unsigned host_id = 0; host_id < DPU_MAX_HOSTS; host_id++) begin
            for (int unsigned pf_id = 0; pf_id < DPU_MAX_PFS_PER_HOST; pf_id++) begin
                key = make_function_key(host_id, pf_id, DPU_FUNCTION_PF, 0);
                if (!manager.activate_function(key, bars, why)) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "PF activation failed for host %0d PF %0d: %s",
                        host_id, pf_id, why))
                end
                if (bars.size() != 0)
                    `uvm_fatal("DPU_RESOURCE",
                        "snapshot-seeded manager synthesized BAR leases")
                if (manager.acquire_leases(
                    key, qpair_class_id, 0, 1, leases, why
                )) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "QP lease succeeded before readiness for host %0d PF %0d",
                        host_id, pf_id))
                end
                if (!manager.mark_function_device_ready(key, why)) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "PF readiness failed for host %0d PF %0d: %s",
                        host_id, pf_id, why))
                end
                if ((host_id == 0) && (pf_id == 0)) begin
                    if (!manager.acquire_leases(
                        key, qpair_class_id, 0, 1, leases, why
                    )) begin
                        `uvm_fatal("DPU_RESOURCE", $sformatf(
                            "first PF QP lease failed: %s", why))
                    end
                    if (manager.acquire_leases(
                        key, qpair_class_id, 0, 1, leases, why
                    )) begin
                        `uvm_fatal("DPU_RESOURCE",
                            "duplicate local QP ID unexpectedly succeeded")
                    end
                    if (!manager.acquire_leases(
                        key, qpair_class_id, 1, 31, leases, why
                    )) begin
                        `uvm_fatal("DPU_RESOURCE", $sformatf(
                            "remaining first-PF QP leases failed: %s", why))
                    end
                end
                else if (!manager.acquire_leases(
                    key, qpair_class_id, 0, 32, leases, why
                )) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "QP lease failed for host %0d PF %0d: %s",
                        host_id, pf_id, why))
                end
            end
        end

        overflow_key = make_function_key(0, 0, DPU_FUNCTION_VF, 0);
        if (!manager.activate_function(overflow_key, bars, why)) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "overflow VF activation failed: %s", why))
        end
        if (!manager.mark_function_device_ready(overflow_key, why)) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "overflow VF readiness failed: %s", why))
        end
        if (manager.acquire_leases(
            overflow_key, qpair_class_id, 0, 32'hffff_ffff, leases, why
        )) begin
            `uvm_fatal("DPU_RESOURCE",
                "overflow VF unexpectedly acquired an enormous QP range")
        end
        if (why != "resource-class per-function quota would be exceeded") begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "enormous QP range did not reject by quota: %s", why))
        end
        if (manager.acquire_leases(
            overflow_key, qpair_class_id, 0, 1, leases, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", "the 2,049th QP lease unexpectedly succeeded")
        end

        key = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
        if (!manager.local_to_global(key, qpair_class_id, 0, global_id)) begin
            `uvm_fatal("DPU_RESOURCE", "PF local QP ID did not resolve globally")
        end
        if (global_id != 0) begin
            `uvm_fatal("DPU_RESOURCE", "first PF QP lease did not retain global ID zero")
        end
        if (manager.acquire_leases(
            key, qpair_class_id, 0, 1, leases, why
        )) begin
            `uvm_fatal("DPU_RESOURCE",
                "quota-exhausted PF unexpectedly reacquired local QP ID zero")
        end
        if (why != "local resource ID is already leased by this function") begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "duplicate local QP ID was masked by another rejection: %s", why))
        end
        if (manager.acquire_leases(
            key, qpair_class_id, 32, 1, leases, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", "per-function QP quota unexpectedly exceeded")
        end
        if (!manager.freeze_function(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "PF freeze failed: %s", why))
        end
        if (manager.acquire_leases(
            key, qpair_class_id, 32, 1, leases, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", "frozen PF unexpectedly acquired a QP lease")
        end
        if (manager.release_leases(key, qpair_class_id, why)) begin
            `uvm_fatal("DPU_RESOURCE", "frozen PF unexpectedly released QP leases")
        end
        if (!manager.restore_function(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "PF restore failed: %s", why))
        end
        if (!manager.release_leases(key, qpair_class_id, why)) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "PF QP release failed: %s", why))
        end
        if (!manager.acquire_leases(
            overflow_key, qpair_class_id, 0, 1, leases, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "QP lease did not recover after release: %s", why))
        end
        if (!manager.local_to_global(
            overflow_key, qpair_class_id, 0, global_id
        )) begin
            `uvm_fatal("DPU_RESOURCE",
                "recovered VF QP lease has no global ID")
        end
        if (global_id >= qpair_capacity) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "recovered VF QP global ID %0d exceeds the QP pool capacity %0d",
                global_id, qpair_capacity))
        end
    endtask

    virtual task run_phase(uvm_phase phase);
        dpu_resource_manager manager;
        dpu_resource_manager child_manager;
        dpu_function_key_t key;
        dpu_resource_class_id_t qpair_class_id;
        string why;

        phase.raise_objection(this);

        assert_canonical_device_identities_and_bar_profiles();
        assert_registration_and_activation_guards();

        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "device_env.protocol_client", "dpu_resource_manager", manager
        )) begin
            `uvm_fatal("DPU_RESOURCE", "device env did not publish its resource manager")
        end
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "device_env.another_client", "dpu_resource_manager", child_manager
        )) begin
            `uvm_fatal("DPU_RESOURCE", "device env did not publish its manager to child scope")
        end
        if (child_manager != manager) begin
            `uvm_fatal("DPU_RESOURCE", "device env child scopes received different managers")
        end
        if (manager.configure_mmio_aperture(
            64'h0001_1000_0000_0000, 64'h0001_1010_0000_0000
        )) begin
            `uvm_fatal("DPU_RESOURCE",
                "snapshot-seeded manager accepted MMIO aperture ownership")
        end
        if (!manager.lookup_resource_class(
            "virtio.qpair", qpair_class_id, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "device QP profile lookup failed: %s", why))
        end

        key = make_function_key(3, 12, DPU_FUNCTION_VF, 0);
        if (manager.register_function(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", "manager registered a function absent from snapshot")
        end

        key = make_function_key(0, 0, DPU_FUNCTION_VF, 16);
        if (manager.validate_vf_key(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", "VF key with vf_id == 16 unexpectedly validated")
        end

        assert_global_qpair_capacity(
            manager, qpair_class_id, 2048
        );

        phase.drop_objection(this);
    endtask

endclass : dpu_resource_manager_test

`endif // DPU_RESOURCE_MANAGER_TEST_SV
