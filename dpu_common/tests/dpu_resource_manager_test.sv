`ifndef DPU_RESOURCE_MANAGER_TEST_SV
`define DPU_RESOURCE_MANAGER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

// ============================================================================
// dpu_resource_manager_test
//
// Defines the topology boundary contract for the future resource manager:
// 4 hosts x 16 PFs plus 60 x 16 VFs consume all 1024 function identities.
// The manager implementation is intentionally deferred to Task 3.
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

    task assert_fabric_global_qpair_capacity(
        dpu_resource_manager manager,
        dpu_resource_class_id_t qpair_class_id
    );
        dpu_function_key_t key;
        dpu_function_key_t overflow_key;
        dpu_bar_pair_lease_t bars[$];
        dpu_resource_lease_t leases[$];
        string why;

        manager.configure_mmio_aperture(
            64'h0001_0000_0000_0000, 64'h0001_0010_0000_0000);

        for (int unsigned host_id = 0; host_id < DPU_MAX_HOSTS; host_id++) begin
            for (int unsigned pf_id = 0; pf_id < DPU_MAX_PFS_PER_HOST; pf_id++) begin
                key = make_function_key(host_id, pf_id, DPU_FUNCTION_PF, 0);
                if (!manager.activate_function(key, bars, why)) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "PF activation failed for host %0d PF %0d: %s",
                        host_id, pf_id, why))
                end
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
                if (!manager.acquire_leases(
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
            overflow_key, qpair_class_id, 0, 1, leases, why
        )) begin
            `uvm_fatal("DPU_RESOURCE", "the 2,049th QP lease unexpectedly succeeded")
        end

        key = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
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
    endtask

    virtual task run_phase(uvm_phase phase);
        dpu_resource_manager manager;
        dpu_function_key_t key;
        dpu_resource_pool_config_t qpair_profile;
        dpu_resource_class_id_t qpair_class_id;
        dpu_resource_class_id_t rejected_class_id;
        string why;

        phase.raise_objection(this);

        qpair_profile = make_resource_profile(
            "virtio.qpair", DPU_RESOURCE_KIND_QUEUE, 2048, 32);
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
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "fabric", "dpu_resource_manager", manager
        )) begin
            `uvm_fatal("DPU_RESOURCE", $sformatf(
                "Fabric did not publish its resource manager"))
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

        assert_fabric_global_qpair_capacity(manager, qpair_class_id);

        phase.drop_objection(this);
    endtask

endclass : dpu_resource_manager_test

`endif // DPU_RESOURCE_MANAGER_TEST_SV
