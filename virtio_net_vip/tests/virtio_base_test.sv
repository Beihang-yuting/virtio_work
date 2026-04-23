`ifndef VIRTIO_BASE_TEST_SV
`define VIRTIO_BASE_TEST_SV

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

    virtio_net_env          env;
    virtio_net_env_config   cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        cfg = virtio_net_env_config::type_id::create("cfg");
        configure_default(cfg);

        uvm_config_db #(virtio_net_env_config)::set(this, "env", "cfg", cfg);
        env = virtio_net_env::type_id::create("env", this);
    endfunction

    // Override in subclasses to customize config before env build
    virtual function void configure_default(virtio_net_env_config cfg);
        cfg.num_vfs              = 0;           // pure PF mode
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

    // Convenience: set VF count
    function void set_num_vfs(int unsigned n);
        cfg.num_vfs = n;
    endfunction

endclass : virtio_base_test

`endif // VIRTIO_BASE_TEST_SV
