`ifndef DPU_RESOURCE_MANAGER_TEST_SV
`define DPU_RESOURCE_MANAGER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

// ============================================================================
// dpu_resource_manager_test
//
// Defines the topology boundary contract for the Fabric resource manager:
// 4 hosts x 16 PFs plus 60 x 16 VFs consume all 1024 function identities.
// ============================================================================

class dpu_resource_manager_test extends uvm_test;
    `uvm_component_utils(dpu_resource_manager_test)

    dpu_fabric_env fabric;
    dpu_fabric_env_config fabric_cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        fabric_cfg = dpu_fabric_env_config::type_id::create("fabric_cfg");
        fabric = dpu_fabric_env::type_id::create("fabric", this);
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

    task assert_pf_bar_layout(input dpu_bar_pair_lease_t bars[$]);
        if (bars.size() != 3) begin
            `uvm_fatal("DPU_RESOURCE", "PF activation did not return three BAR pairs")
        end
        if ((bars[0].role != DPU_BAR_FUNCTION_DEVICE) ||
            (bars[0].even_bar_id != 0) ||
            (bars[0].size != 64'h0000_0000_0200_0000)) begin
            `uvm_fatal("DPU_RESOURCE", "PF function-device BAR pair is incorrect")
        end
        if ((bars[1].role != DPU_BAR_RESERVED) ||
            (bars[1].even_bar_id != 2) ||
            (bars[1].size != 64'h0000_0000_0001_0000)) begin
            `uvm_fatal("DPU_RESOURCE", "PF reserved BAR pair is incorrect")
        end
        if ((bars[2].role != DPU_BAR_MSIX) ||
            (bars[2].even_bar_id != 4) ||
            (bars[2].size != 64'h0000_0000_0001_0000)) begin
            `uvm_fatal("DPU_RESOURCE", "PF MSI-X BAR pair is incorrect")
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

    task assert_fabric_global_qpair_capacity(
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
                if ((host_id == 0) && (pf_id == 0))
                    assert_pf_bar_layout(bars);
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
        dpu_resource_pool_config_t qpair_profile;
        dpu_resource_class_id_t qpair_class_id;
        dpu_resource_class_id_t rejected_class_id;
        string why;

        phase.raise_objection(this);

        assert_registration_and_activation_guards();

        qpair_profile = make_resource_profile(
            "virtio.qpair", DPU_RESOURCE_KIND_QUEUE, 2048, 32);
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "fabric", "dpu_resource_manager", manager
        )) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "Fabric did not publish its resource manager"))
        end
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "fabric.protocol_client", "dpu_resource_manager", child_manager
        )) begin
            `uvm_fatal("DPU_RESOURCE", "Fabric did not publish its manager to child scope")
        end
        if (child_manager != manager) begin
            `uvm_fatal("DPU_RESOURCE", "Fabric child scope received a different manager")
        end
        if (manager.register_resource_class(
            qpair_profile.name, qpair_profile.kind, qpair_profile.capacity,
            qpair_profile.max_per_function, rejected_class_id, why
        )) begin
            `uvm_fatal("DPU_RESOURCE",
                "Fabric client bypassed profile registration before apply")
        end
        if (manager.seal_resource_classes(why)) begin
            `uvm_fatal("DPU_RESOURCE",
                "Fabric client bypassed profile sealing before apply")
        end
        if (manager.configure_mmio_aperture(
            64'h0001_1000_0000_0000, 64'h0001_1010_0000_0000
        )) begin
            `uvm_fatal("DPU_RESOURCE",
                "Fabric client bypassed shared MMIO aperture configuration")
        end
        fabric_cfg.mmio_aperture_base = 64'h0001_0000_0000_0000;
        fabric_cfg.mmio_aperture_limit = 64'h0001_0010_0000_0000;
        fabric_cfg.resource_profiles.push_back(qpair_profile);
        if (!fabric.apply_resource_profiles(fabric_cfg, why)) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "Fabric QP profile application failed: %s", why))
        end
        if (!fabric.lookup_resource_class(
            qpair_profile.name, qpair_class_id, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "Fabric QP profile lookup failed: %s", why))
        end
        if (manager.register_resource_class(
            qpair_profile.name, qpair_profile.kind, qpair_profile.capacity,
            qpair_profile.max_per_function,
            rejected_class_id, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", "sealed Fabric registry accepted direct QP registration")
        end

        for (int unsigned host_id = 0; host_id < DPU_MAX_HOSTS; host_id++) begin
            for (int unsigned pf_id = 0; pf_id < DPU_MAX_PFS_PER_HOST; pf_id++) begin
                key = make_function_key(host_id, pf_id, DPU_FUNCTION_PF, 0);
                if (!manager.register_function(key, why)) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "PF registration failed for host %0d PF %0d: %s",
                        host_id, pf_id, why))
                end
            end
        end

        for (int unsigned function_index = 0; function_index < 60; function_index++) begin
            int unsigned host_id;
            int unsigned pf_id;

            host_id = function_index / DPU_MAX_PFS_PER_HOST;
            pf_id = function_index % DPU_MAX_PFS_PER_HOST;
            for (int unsigned vf_id = 0; vf_id < DPU_MAX_VFS_PER_PF; vf_id++) begin
                key = make_function_key(host_id, pf_id, DPU_FUNCTION_VF, vf_id);
                if (!manager.register_function(key, why)) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "VF registration failed for host %0d PF %0d VF %0d: %s",
                        host_id, pf_id, vf_id, why))
                end
            end
        end

        key = make_function_key(3, 12, DPU_FUNCTION_VF, 0);
        if (manager.register_function(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", "the 961st VF registration unexpectedly succeeded")
        end

        key = make_function_key(0, 0, DPU_FUNCTION_VF, 16);
        if (manager.validate_vf_key(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", "VF key with vf_id == 16 unexpectedly validated")
        end

        assert_fabric_global_qpair_capacity(
            manager, qpair_class_id, qpair_profile.capacity
        );

        phase.drop_objection(this);
    endtask

endclass : dpu_resource_manager_test

`endif // DPU_RESOURCE_MANAGER_TEST_SV
