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
    int unsigned         num_hosts = 0;           // 0 selects legacy flat-VF mode
    int unsigned         num_pfs_per_host[];
    int unsigned         num_vfs_per_pf[][];
    dpu_dut_caps          dut_caps;

    // Per-VF configs (optional, falls back to defaults)
    virtio_driver_config_t  vf_configs[];

    typedef struct {
        dpu_service_key_t key;
        virtio_driver_config_t cfg;
    } service_config_entry_t;

    protected service_config_entry_t m_service_configs[string];

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
        dut_caps = dpu_dut_caps::type_id::create("dut_caps");
    endfunction

    function bit uses_fabric_topology();
        return (num_hosts != 0) || (num_pfs_per_host.size() != 0) ||
               (num_vfs_per_pf.size() != 0);
    endfunction

    function int unsigned total_fabric_pfs();
        int unsigned total;
        total = 0;
        foreach (num_pfs_per_host[host_id])
            total += num_pfs_per_host[host_id];
        return total;
    endfunction

    function int unsigned total_fabric_vfs();
        int unsigned total;
        total = 0;
        foreach (num_vfs_per_pf[host_id])
            foreach (num_vfs_per_pf[host_id][pf_id])
                total += num_vfs_per_pf[host_id][pf_id];
        return total;
    endfunction

    // ========================================================================
    // make_default_driver_config
    //
    // Build behavior from the default fields and cap it with the authority
    // supplied by the caller.  The legacy getter below remains temporarily
    // for unconverted positional callers.
    // ========================================================================

    function virtio_driver_config_t make_default_driver_config(
        input int unsigned max_pairs
    );
        virtio_driver_config_t cfg;

        cfg.num_queue_pairs     = (default_num_pairs > max_pairs) ?
                                  max_pairs : default_num_pairs;
        cfg.queue_size          = default_queue_size;
        cfg.max_vio_net_qpairs_per_device = max_pairs;
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

    function virtio_driver_config_t get_default_driver_config();
        int unsigned max_pairs;

        max_pairs = (dut_caps == null) ? DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE :
                                        dut_caps.max_vio_net_qpairs_per_device;
        return make_default_driver_config(max_pairs);
    endfunction

    // ========================================================================
    // get_vf_config
    //
    // Get config for a specific VF. Returns the explicit vf_configs entry if
    // present, otherwise falls back to get_default_driver_config().
    // ========================================================================

    function virtio_driver_config_t get_vf_config(int unsigned vf_idx);
        virtio_driver_config_t cfg;

        if (vf_configs.size() > vf_idx)
            cfg = vf_configs[vf_idx];
        else
            cfg = get_default_driver_config();
        cfg.max_vio_net_qpairs_per_device =
            (dut_caps == null) ? DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE :
                                 dut_caps.max_vio_net_qpairs_per_device;
        return cfg;
    endfunction

    protected function bit validate_driver_behavior(
        input virtio_driver_config_t driver_cfg,
        input string label,
        output string why
    );
        if (driver_cfg.num_queue_pairs == 0) begin
            why = {label, " has zero queue pairs"};
            return 0;
        end
        if ((driver_cfg.queue_size != 0) &&
            ((driver_cfg.queue_size & (driver_cfg.queue_size - 1)) != 0)) begin
            why = {label, " queue size is not a power of two"};
            return 0;
        end
        if (driver_cfg.bw_limit_enable && (driver_cfg.bw_limit_mbps == 0)) begin
            why = {label, " enables a zero bandwidth limit"};
            return 0;
        end
        why = "";
        return 1;
    endfunction

    function bit add_service_config(
        input dpu_service_key_t key,
        input virtio_driver_config_t driver_cfg,
        output string why
    );
        string service_name;

        service_name = dpu_service_key_name(key);
        if (key.service_kind != DPU_SERVICE_VIO_NET) begin
            why = {"VIO service configuration requires VIO-net key ",
                   service_name};
            return 0;
        end
        if (m_service_configs.exists(service_name)) begin
            why = {"duplicate VIO service configuration ", service_name};
            return 0;
        end
        foreach (m_service_configs[existing_name]) begin
            if (dpu_same_function_key(
                    m_service_configs[existing_name].key.function_key,
                    key.function_key)) begin
                why = {"VIO function already has service configuration ",
                       dpu_function_key_name(key.function_key)};
                return 0;
            end
        end
        if (!validate_driver_behavior(driver_cfg, service_name, why))
            return 0;
        m_service_configs[service_name].key = key;
        m_service_configs[service_name].cfg = driver_cfg;
        why = "";
        return 1;
    endfunction

    function bit get_service_config(
        input dpu_service_key_t key,
        input int unsigned max_pairs,
        output virtio_driver_config_t driver_cfg,
        output string why
    );
        string service_name;

        service_name = dpu_service_key_name(key);
        if (key.service_kind != DPU_SERVICE_VIO_NET) begin
            why = {"VIO service configuration requires VIO-net key ",
                   service_name};
            return 0;
        end
        if ((max_pairs == 0) ||
            (max_pairs > DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE)) begin
            why = $sformatf("VIO behavior max pairs %0d is outside 1..%0d",
                            max_pairs, DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE);
            return 0;
        end
        if (m_service_configs.exists(service_name))
            driver_cfg = m_service_configs[service_name].cfg;
        else
            driver_cfg = make_default_driver_config(max_pairs);
        if (driver_cfg.num_queue_pairs > max_pairs)
            driver_cfg.num_queue_pairs = max_pairs;
        driver_cfg.max_vio_net_qpairs_per_device = max_pairs;
        why = "";
        return 1;
    endfunction

    function bit validate_local(output string why);
        virtio_driver_config_t default_cfg;

        if (mem_base >= mem_end) begin
            why = $sformatf("mem_base=0x%016h >= mem_end=0x%016h",
                            mem_base, mem_end);
            return 0;
        end
        default_cfg = make_default_driver_config(
            DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE);
        if (!validate_driver_behavior(default_cfg, "default VIO behavior", why))
            return 0;
        foreach (m_service_configs[service_name]) begin
            if (m_service_configs[service_name].key.service_kind !=
                DPU_SERVICE_VIO_NET) begin
                why = {"VIO service configuration requires VIO-net key ",
                       service_name};
                return 0;
            end
            if (!validate_driver_behavior(m_service_configs[service_name].cfg,
                                          service_name, why))
                return 0;
        end
        why = "";
        return 1;
    endfunction

    function bit validate_against_snapshot(
        input dpu_device_snapshot snapshot,
        output string why
    );
        dpu_dut_caps snapshot_caps;
        dpu_function_key_t owner;
        string service_why;

        if ((snapshot == null) || !snapshot.is_frozen()) begin
            why = "VIO service configuration requires a non-null frozen snapshot";
            return 0;
        end
        if (!validate_local(why))
            return 0;
        snapshot_caps = snapshot.snapshot_dut_caps();
        if (snapshot_caps == null) begin
            why = "frozen snapshot has no DUT capabilities";
            return 0;
        end
        if ((snapshot_caps.max_vio_net_qpairs_per_device == 0) ||
            (snapshot_caps.max_vio_net_qpairs_per_device >
             DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE)) begin
            why = "frozen snapshot has an invalid VIO qpair capability";
            return 0;
        end
        foreach (m_service_configs[service_name]) begin
            if (m_service_configs[service_name].key.service_kind !=
                DPU_SERVICE_VIO_NET) begin
                why = {"VIO service configuration requires VIO-net key ",
                       service_name};
                return 0;
            end
            if (!snapshot.get_service_owner(
                    m_service_configs[service_name].key, owner, service_why)) begin
                why = {"VIO service configuration is not declared by snapshot ",
                       service_name, ": ", service_why};
                return 0;
            end
            if (m_service_configs[service_name].cfg.num_queue_pairs >
                snapshot_caps.max_vio_net_qpairs_per_device) begin
                why = $sformatf(
                    "VIO service configuration %s queue pairs %0d exceeds snapshot limit %0d",
                    service_name,
                    m_service_configs[service_name].cfg.num_queue_pairs,
                    snapshot_caps.max_vio_net_qpairs_per_device);
                return 0;
            end
        end
        why = "";
        return 1;
    endfunction

    // ========================================================================
    // validate
    //
    // Sanity-check configuration values. Returns 1 on success, 0 on error.
    // ========================================================================

    function bit validate();
        bit ok = 1;
        bit caps_valid = 0;
        string caps_why;

        if (dut_caps == null) begin
            caps_why = "null capability object";
            `uvm_error("ENV_CFG", $sformatf(
                "invalid DUT capabilities: %s", caps_why))
            ok = 0;
        end
        else if (!dut_caps.validate(caps_why)) begin
            `uvm_error("ENV_CFG", $sformatf(
                "invalid DUT capabilities: %s", caps_why))
            ok = 0;
        end
        else begin
            caps_valid = 1;
            if (default_num_pairs == 0) begin
                `uvm_error("ENV_CFG",
                    "default_num_pairs=0 must be nonzero")
                ok = 0;
            end
            else if (default_num_pairs >
                     dut_caps.max_vio_net_qpairs_per_device) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "default_num_pairs=%0d exceeds VIO-net device limit %0d",
                    default_num_pairs,
                    dut_caps.max_vio_net_qpairs_per_device))
                ok = 0;
            end
            foreach (vf_configs[vf_id]) begin
                if (vf_configs[vf_id].num_queue_pairs == 0) begin
                    `uvm_error("ENV_CFG", $sformatf(
                        "VF%0d num_queue_pairs=0 must be nonzero", vf_id))
                    ok = 0;
                end
                else if (vf_configs[vf_id].num_queue_pairs >
                         dut_caps.max_vio_net_qpairs_per_device) begin
                    `uvm_error("ENV_CFG", $sformatf(
                        "VF%0d num_queue_pairs=%0d exceeds VIO-net device limit %0d",
                        vf_id, vf_configs[vf_id].num_queue_pairs,
                        dut_caps.max_vio_net_qpairs_per_device))
                    ok = 0;
                end
            end
        end

        if (num_vfs > max_vfs) begin
            `uvm_error("ENV_CFG",
                $sformatf("num_vfs=%0d exceeds max_vfs=%0d", num_vfs, max_vfs))
            ok = 0;
        end

        if (uses_fabric_topology() && caps_valid) begin
            int unsigned total_functions;

            if (num_hosts == 0) begin
                `uvm_error("ENV_CFG", "num_hosts=0 must be nonzero")
                ok = 0;
            end
            else if (num_hosts > dut_caps.max_hosts) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "num_hosts=%0d exceeds DUT limit %0d",
                    num_hosts, dut_caps.max_hosts))
                ok = 0;
            end
            if ((num_hosts != 0) &&
                ((num_pfs_per_host.size() != num_hosts) ||
                 (num_vfs_per_pf.size() != num_hosts))) begin
                `uvm_error("ENV_CFG", "topology arrays must contain one entry per host")
                ok = 0;
            end
            total_functions = 0;
            for (int unsigned host_id = 0; host_id < num_hosts; host_id++) begin
                longint unsigned pf_block_bdf;

                if ((host_id >= num_pfs_per_host.size()) ||
                    (host_id >= num_vfs_per_pf.size()))
                    continue;
                if (num_pfs_per_host[host_id] == 0) begin
                    `uvm_error("ENV_CFG", $sformatf(
                        "host %0d PF count 0 must be nonzero", host_id))
                    ok = 0;
                end
                else if (num_pfs_per_host[host_id] >
                         dut_caps.max_pfs_per_host) begin
                    `uvm_error("ENV_CFG", $sformatf(
                        "host %0d PF count %0d exceeds DUT limit %0d",
                        host_id, num_pfs_per_host[host_id],
                        dut_caps.max_pfs_per_host))
                    ok = 0;
                end
                if (num_vfs_per_pf[host_id].size() != num_pfs_per_host[host_id]) begin
                    `uvm_error("ENV_CFG", $sformatf(
                        "host %0d VF topology does not match its PF count", host_id))
                    ok = 0;
                    continue;
                end
                total_functions += num_pfs_per_host[host_id];
                foreach (num_vfs_per_pf[host_id][pf_id]) begin
                    pf_block_bdf = pf_bdf +
                        ((host_id * DPU_MAX_PFS_PER_HOST + pf_id) *
                         (DPU_MAX_VFS_PER_PF + 1));
                    if (num_vfs_per_pf[host_id][pf_id] >
                        dut_caps.max_vfs_per_pf) begin
                        `uvm_error("ENV_CFG", $sformatf(
                            "host %0d PF %0d VF count %0d exceeds DUT limit %0d",
                            host_id, pf_id,
                            num_vfs_per_pf[host_id][pf_id],
                            dut_caps.max_vfs_per_pf))
                        ok = 0;
                    end
                    if ((pf_block_bdf + num_vfs_per_pf[host_id][pf_id]) >
                        16'hffff) begin
                        `uvm_error("ENV_CFG", $sformatf(
                            "host %0d PF %0d BDF block overflows 16 bits",
                            host_id, pf_id))
                        ok = 0;
                    end
                    total_functions += num_vfs_per_pf[host_id][pf_id];
                end
            end
            if (total_functions > dut_caps.max_functions) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "requested %0d functions exceeds DUT limit %0d",
                    total_functions, dut_caps.max_functions))
                ok = 0;
            end
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
        s = {s, $sformatf("  fabric: hosts=%0d, PFs=%0d, VFs=%0d\n",
                          num_hosts, total_fabric_pfs(), total_fabric_vfs())};
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
