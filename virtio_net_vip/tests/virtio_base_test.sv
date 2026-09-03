`ifndef VIRTIO_BASE_TEST_SV
`define VIRTIO_BASE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

// ============================================================================
// virtio_base_test
//
// Base test class for all virtio-net tests. Creates the environment and
// configuration with sensible defaults. Subclasses override
// configure_default() to customize config before the env is built.
//
// Depends on:
//   - virtio_net_env, virtio_net_env_config
//   - All types from virtio_net_types.sv
// ============================================================================

class virtio_base_test extends uvm_test;
    `uvm_component_utils(virtio_base_test)

    dpu_device_env             device_env;
    virtio_test_device_builder device_builder;
    dpu_device_env_config      device_cfg;
    virtio_net_env_config      cfg;
    host_mem_pool               host_mem_owners;
    virtio_net_env             env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_function_cfg pf_cfg;
        dpu_function_key_t vio_devices[$];

        super.build_phase(phase);

        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        void'(device_builder.add_host_domain(0, 0));
        pf_cfg = device_builder.add_pf(0, 0, 0);
        device_builder.add_real_dut_bars(pf_cfg);
        void'(device_builder.allow_vio_service(pf_cfg));
        vio_devices.push_back(pf_cfg.key);
        void'(device_builder.add_fixed_vio_request(0, vio_devices, 1));
        device_builder.select_af(pf_cfg);

        cfg = virtio_net_env_config::type_id::create("cfg");
        configure_default(cfg);
        // Own Host memory at the test/topology level and inject the same
        // per-Host manager into the VIO environment.  Additional RDMA/VBLK
        // environments can reuse host_mem_owners.get_host(host_id).
        host_mem_owners = host_mem_pool::type_id::create("host_mem_owners");
        if (!host_mem_owners.create_host(
                cfg.host_id, cfg.mem_base, cfg.mem_end,
                MODE_BUDDY, DEFAULT_MIN_GRANULE, cfg.host_mem_policy)) begin
            `uvm_fatal("VIRTIO_BASE_TEST", $sformatf(
                "could not create Host %0d memory manager", cfg.host_id))
            return;
        end
        device_cfg = device_builder.make_env_config();
        // Publish the owner through the protocol-neutral DPU environment
        // hook; the child VIO env resolves it after snapshot publication.
        device_cfg.host_mem_pool_ref = host_mem_owners;

        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "device_env.env", "cfg", cfg);
        env = virtio_net_env::type_id::create("env", device_env);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        host_mem_manager expected_host_mem;

        super.end_of_elaboration_phase(phase);
        if ((host_mem_owners == null) || (env == null) ||
            !host_mem_owners.has_host(cfg.host_id)) begin
            `uvm_fatal("VIRTIO_BASE_TEST",
                       "Host memory pool binding was not constructed")
            return;
        end
        expected_host_mem = host_mem_owners.get_host(cfg.host_id);
        if ((expected_host_mem == null) || (env.host_mem != expected_host_mem))
            `uvm_fatal("VIRTIO_BASE_TEST",
                       "VIO environment did not use the pool-owned Host manager")
    endfunction

    // Override in subclasses to customize config before env build
    virtual function void configure_default(virtio_net_env_config cfg);
        cfg.default_num_pairs    = 1;
        cfg.default_queue_size   = 256;
        cfg.default_vq_type      = VQ_SPLIT;
        cfg.default_driver_features = '1;       // all features
        cfg.default_rx_mode      = RX_MODE_MERGEABLE;
        cfg.default_irq_mode     = IRQ_MSIX_PER_QUEUE;
        cfg.default_napi_budget  = 64;
        cfg.mem_base             = 64'h0000_0001_0000_0000;
        cfg.mem_end              = 64'h0000_0001_FFFF_FFFF;
        cfg.iommu_strict         = 1;
        cfg.scb_enable           = 1;
        cfg.cov_enable           = 0;
    endfunction

    // Convenience: enable coverage
    function void enable_coverage();
        cfg.cov_enable = 1;
    endfunction

    // Test-only convenience: make VFs eligible for a later placement request.
    function void add_vio_vfs(int unsigned n);
        for (int unsigned vf_id = 0; vf_id < n; vf_id++) begin
            dpu_function_cfg vf_cfg;

            vf_cfg = device_builder.add_vf(0, 0, vf_id, 0);
            device_builder.add_real_dut_bars(vf_cfg);
            void'(device_builder.allow_vio_service(vf_cfg));
        end
    endfunction

endclass : virtio_base_test

`endif // VIRTIO_BASE_TEST_SV
