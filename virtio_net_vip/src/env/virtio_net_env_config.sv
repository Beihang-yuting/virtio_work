`ifndef VIRTIO_NET_ENV_CONFIG_SV
`define VIRTIO_NET_ENV_CONFIG_SV

// ============================================================================
// virtio_net_env_config
//
// Unified configuration object for the virtio-net UVM environment.
// Provides topology settings (PF/VF count), per-VF driver configs with
// fallback defaults, PCIe addressing, memory regions, IOMMU policy,
// performance limits, and verification component enables.
//
// Usage:
//   1. Create and configure in the test
//   2. Set into config_db: uvm_config_db#(virtio_net_env_config)::set(...)
//   3. The env retrieves it in build_phase
//
// Depends on: virtio_net_types.sv (all enums and structs)
// ============================================================================

class virtio_net_env_config extends uvm_object;
    `uvm_object_utils(virtio_net_env_config)

    // ===== Topology =====
    int unsigned         num_vfs = 0;            // 0 = pure PF mode
    int unsigned         max_vfs = 256;

    // Per-VF configs (optional, falls back to defaults)
    virtio_driver_config_t  vf_configs[];

    // ===== Default driver config =====
    int unsigned         default_num_pairs = 1;
    int unsigned         default_queue_size = 256;  // 0 = device max
    virtqueue_type_e     default_vq_type = VQ_SPLIT;
    bit [63:0]           default_driver_features = '1;  // all features
    rx_buf_mode_e        default_rx_mode = RX_MODE_MERGEABLE;
    interrupt_mode_e     default_irq_mode = IRQ_MSIX_PER_QUEUE;
    int unsigned         default_napi_budget = 64;
    int unsigned         default_rx_buf_size = 1526;
    int unsigned         default_rx_refill_threshold = 16;
    int unsigned         default_mtu = 1500;
    int unsigned         default_mss = 1460;
    driver_mode_e        default_driver_mode = DRV_MODE_AUTO;

    // ===== PCIe =====
    bit [15:0]           pf_bdf = 16'h0100;  // bus=1, dev=0, func=0

    // ===== Memory =====
    bit [63:0]           mem_base = 64'h0000_0001_0000_0000;
    bit [63:0]           mem_end  = 64'h0000_0001_FFFF_FFFF;

    // ===== IOMMU =====
    bit                  iommu_strict = 1;

    // ===== Performance =====
    bit                  bw_limit_enable = 0;
    int unsigned         bw_limit_mbps = 0;

    // ===== Verification =====
    bit                  scb_enable = 1;
    bit                  cov_enable = 0;

    // ===== Failover =====
    bit                  failover_enable = 0;
    int unsigned         primary_vf_id = 0;
    int unsigned         standby_vf_id = 1;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_net_env_config");
        super.new(name);
    endfunction

    // ========================================================================
    // get_default_driver_config
    //
    // Build a virtio_driver_config_t from the default fields. Used for VFs
    // that do not have an explicit entry in vf_configs[].
    // ========================================================================

    function virtio_driver_config_t get_default_driver_config();
        virtio_driver_config_t cfg;
        cfg.num_queue_pairs     = default_num_pairs;
        cfg.queue_size          = default_queue_size;
        cfg.vq_type             = default_vq_type;
        cfg.driver_features     = default_driver_features;
        cfg.rx_buf_mode         = default_rx_mode;
        cfg.rx_buf_size         = default_rx_buf_size;
        cfg.rx_refill_threshold = default_rx_refill_threshold;
        cfg.irq_mode            = default_irq_mode;
        cfg.napi_budget         = default_napi_budget;
        cfg.coal_max_packets    = 0;
        cfg.coal_max_usecs      = 0;
        cfg.bw_limit_enable     = bw_limit_enable;
        cfg.bw_limit_mbps       = bw_limit_mbps;
        cfg.mode                = default_driver_mode;
        return cfg;
    endfunction

    // ========================================================================
    // get_vf_config
    //
    // Get config for a specific VF. Returns the explicit vf_configs entry if
    // present, otherwise falls back to get_default_driver_config().
    // ========================================================================

    function virtio_driver_config_t get_vf_config(int unsigned vf_idx);
        if (vf_configs.size() > vf_idx)
            return vf_configs[vf_idx];
        return get_default_driver_config();
    endfunction

    // ========================================================================
    // validate
    //
    // Sanity-check configuration values. Returns 1 on success, 0 on error.
    // ========================================================================

    function bit validate();
        bit ok = 1;

        if (num_vfs > max_vfs) begin
            `uvm_error("ENV_CFG",
                $sformatf("num_vfs=%0d exceeds max_vfs=%0d", num_vfs, max_vfs))
            ok = 0;
        end

        if (mem_base >= mem_end) begin
            `uvm_error("ENV_CFG",
                $sformatf("mem_base=0x%016h >= mem_end=0x%016h", mem_base, mem_end))
            ok = 0;
        end

        if (default_queue_size != 0 && (default_queue_size & (default_queue_size - 1)) != 0) begin
            `uvm_warning("ENV_CFG",
                $sformatf("default_queue_size=%0d is not a power of 2", default_queue_size))
        end

        if (failover_enable && num_vfs < 2) begin
            `uvm_warning("ENV_CFG",
                "failover_enable requires at least 2 VFs")
        end

        return ok;
    endfunction

    // ========================================================================
    // convert2string
    // ========================================================================

    virtual function string convert2string();
        string s;
        s = $sformatf("virtio_net_env_config:\n");
        s = {s, $sformatf("  num_vfs=%0d, max_vfs=%0d\n", num_vfs, max_vfs)};
        s = {s, $sformatf("  pf_bdf=0x%04h\n", pf_bdf)};
        s = {s, $sformatf("  mem_base=0x%016h, mem_end=0x%016h\n", mem_base, mem_end)};
        s = {s, $sformatf("  iommu_strict=%0b\n", iommu_strict)};
        s = {s, $sformatf("  default: pairs=%0d, qsize=%0d, vq_type=%s, mode=%s\n",
                          default_num_pairs, default_queue_size,
                          default_vq_type.name(), default_driver_mode.name())};
        s = {s, $sformatf("  default: rx_mode=%s, irq_mode=%s, mtu=%0d\n",
                          default_rx_mode.name(), default_irq_mode.name(), default_mtu)};
        s = {s, $sformatf("  bw_limit: enable=%0b, mbps=%0d\n", bw_limit_enable, bw_limit_mbps)};
        s = {s, $sformatf("  scb_enable=%0b, cov_enable=%0b\n", scb_enable, cov_enable)};
        s = {s, $sformatf("  failover: enable=%0b, primary=%0d, standby=%0d",
                          failover_enable, primary_vf_id, standby_vf_id)};
        return s;
    endfunction

endclass : virtio_net_env_config

`endif // VIRTIO_NET_ENV_CONFIG_SV
