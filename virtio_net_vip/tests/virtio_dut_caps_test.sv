`ifndef VIRTIO_DUT_CAPS_TEST_SV
`define VIRTIO_DUT_CAPS_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

class virtio_dut_caps_test extends uvm_test;
    `uvm_component_utils(virtio_dut_caps_test)

    dpu_fabric_env fabric;
    dpu_fabric_env_config fabric_cfg;
    dpu_resource_manager manager;
    dpu_function_key_t valid_pf;
    dpu_function_key_t valid_vf;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_key(
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

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        fabric_cfg = dpu_fabric_env_config::type_id::create("fabric_cfg");
        fabric = dpu_fabric_env::type_id::create("fabric", this);
    endfunction

    task assert_real_dut_capability_defaults();
        dpu_dut_caps invalid_caps;
        dpu_dut_caps zero_caps;
        string why;

        if ((fabric_cfg.dut_caps.max_hosts != 2) ||
            (fabric_cfg.dut_caps.max_pfs_per_host != 4) ||
            (fabric_cfg.dut_caps.max_vfs_per_pf != 16) ||
            (fabric_cfg.dut_caps.vio_global_qpair_count != 2048) ||
            (fabric_cfg.dut_caps.max_vio_net_qpairs_per_device != 32)) begin
            `uvm_fatal("DUT_CAPS", "default real-DUT capability profile is incorrect")
        end

        invalid_caps = dpu_dut_caps::type_id::create("invalid_caps");
        invalid_caps.max_vio_net_qpairs_per_device = 33;
        if (invalid_caps.validate(why)) begin
            `uvm_fatal("DUT_CAPS", "capability profile accepted 33 VIO qpairs/device")
        end

        zero_caps = dpu_dut_caps::type_id::create("zero_caps");
        zero_caps.max_hosts = 0;
        if (zero_caps.validate(why)) begin
            `uvm_fatal("DUT_CAPS", "capability profile accepted zero hosts")
        end
        if (why != "DUT host capability must be nonzero") begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "zero host capability returned an inaccurate reason: %s", why))
        end
    endtask

    task configure_fabric();
        dpu_resource_pool_config_t qpair_profile;
        string why;

        fabric_cfg.mmio_aperture_base = 64'h0001_0000_0000_0000;
        fabric_cfg.mmio_aperture_limit = 64'h0001_0100_0000_0000;
        qpair_profile.name = "virtio.qpair";
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = fabric_cfg.dut_caps.vio_global_qpair_count;
        qpair_profile.max_per_function =
            fabric_cfg.dut_caps.max_vio_net_qpairs_per_device;
        fabric_cfg.resource_profiles.push_back(qpair_profile);
        if (!fabric.apply_resource_profiles(fabric_cfg, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf("Fabric configuration failed: %s", why))
        end
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "fabric", "dpu_resource_manager", manager
        )) begin
            `uvm_fatal("DUT_CAPS", "Fabric did not publish its resource manager")
        end
    endtask

    task assert_manager_topology_limits();
        dpu_function_key_t invalid_key;
        string why;

        valid_pf = make_key(0, 0, DPU_FUNCTION_PF, 0);
        if (!manager.register_function(valid_pf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid PF rejected: %s", why))

        invalid_key = make_key(2, 0, DPU_FUNCTION_PF, 0);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "host_id 2 exceeded the real-DUT capability")

        invalid_key = make_key(0, 4, DPU_FUNCTION_PF, 0);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "pf_id 4 exceeded the real-DUT capability")

        valid_vf = make_key(0, 0, DPU_FUNCTION_VF, 15);
        if (!manager.register_function(valid_vf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid VF15 rejected: %s", why))

        invalid_key = make_key(0, 0, DPU_FUNCTION_VF, 16);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "vf_id 16 exceeded the real-DUT capability")
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        assert_real_dut_capability_defaults();
        configure_fabric();
        assert_manager_topology_limits();
        phase.drop_objection(this);
    endtask
endclass : virtio_dut_caps_test

`endif // VIRTIO_DUT_CAPS_TEST_SV
