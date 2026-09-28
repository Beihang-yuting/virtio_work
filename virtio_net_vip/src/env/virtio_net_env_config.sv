`ifndef VIRTIO_NET_ENV_CONFIG_SV
`define VIRTIO_NET_ENV_CONFIG_SV

// ============================================================================
// virtio_net_env_config
//
// Unified configuration object for the virtio-net UVM environment.
// 所属层次：src/env，作为 test authoring 与 virtio_net_env 的行为配置边界。
// 中文说明：本对象只描述 virtio 驱动行为、内存和验证策略；Host/PF/VF/BDF/BAR
// 拓扑以及 qpair 归属必须由全局 dpu_common snapshot 提供。
// 主要依赖：virtio_net_types、dpu_resource_pkg 的 service key/snapshot，
// 以及 host_mem_pool。test 持有配置对象；环境在 build/connect 阶段借用，
// 不接管其生命周期，也不改写冻结的控制面快照。
// Provides VIO service behavior, memory regions, IOMMU policy, performance
// limits, and verification component enables. Device topology and placement
// belong exclusively to the frozen global device snapshot.
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

    typedef struct {
        dpu_service_key_t key;
        virtio_driver_config_t cfg;
    } service_config_entry_t;

    protected service_config_entry_t m_service_configs[string];

    // 可选 service 白名单。空队列保持旧环境的全量消费语义；非空时按完整
    // service key 精确筛选，允许多个子环境共享同一对冻结快照与资源管理器。
    dpu_service_key_t service_keys[$];

    // 可选 Host 范围在快照发布后按 owner.host_id 过滤；因此 AUTO placement
    // 的最终归属仍由控制面决定，不按 authoring 顺序预猜 PF/VF 身份。
    bit          host_scope_enable = 0;
    int unsigned host_scope_id = 0;

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

    // 默认由环境模拟设备行为；接入真实 PCIe DUT 时切换为 REAL_DUT。
    virtio_execution_mode_e execution_mode = VIRTIO_EXEC_MODEL;
    virtio_completion_mode_e completion_mode = VIRTIO_COMPLETION_MSIX;

    // ===== Memory =====
    // mem_base/mem_end 是 Host GPA aperture；实际分配器由 host_mem_pool 注入，
    // 业务环境不会为同一个 Host 再创建第二份 backing storage。
    bit [63:0]           mem_base = 64'h0000_0001_0000_0000;
    bit [63:0]           mem_end  = 64'h0000_0001_FFFF_FFFF;
    // Host address-domain selection.  A top-level DPU environment can inject
    // the shared manager for this Host; when null, the legacy single-Host
    // behavior creates one locally.
    int unsigned         host_id = 0;
    host_mem_alloc_policy_e host_mem_policy = HOST_MEM_RANDOM;
    host_mem_manager     host_mem_binding = null;
    // Optional top-level ownership object.  When supplied, the environment
    // resolves host_id through this pool and shares the returned manager with
    // every service environment bound to the same Host.
    host_mem_pool        host_mem_pool_binding = null;

    // ===== IOMMU =====
    // IOVA 属于设备可见地址空间，与 GPA/BAR 数值空间独立；随机策略用于压力
    // 验证，FIRST_FIT 仅用于需要稳定布局的调试场景。
    bit                  iommu_strict = 1;
    // IOVA is a device-visible address space and is intentionally configured
    // independently from Host GPA/BAR apertures.  The default keeps the
    // existing 64-bit model range while selecting the random allocator;
    // FIRST_FIT remains available for deterministic debug runs.
    bit [63:0]           iova_base = 64'h0000_0000_8000_0000;
    bit [63:0]           iova_limit = 64'hffff_ffff_ffff_f000;
    iommu_iova_alloc_policy_e iova_alloc_policy = IOMMU_IOVA_RANDOM;

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

    // 仅初始化 UVM 配置对象；默认字段在声明处设定，构造函数不创建外部资源。
    function new(string name = "virtio_net_env_config");
        super.new(name);
    endfunction

    // 功能：将一个 VIO-net service key 加入可选白名单。
    // 输入/输出：输入完整 key，成功返回 1，失败返回 0 并填写 why。
    // 边界/副作用：拒绝非 VIO 或重复键；声明存在性和 Host 归属留待冻结快照校验。
    function bit add_service_key(
        input dpu_service_key_t key,
        output string why
    );
        string service_name;

        service_name = dpu_service_key_name(key);
        why = "";
        if (key.service_kind != DPU_SERVICE_VIO_NET) begin
            why = {"service scope requires VIO-net key ", service_name};
            return 0;
        end
        foreach (service_keys[index]) begin
            if (dpu_service_key_name(service_keys[index]) == service_name) begin
                why = {"duplicate service scope key ", service_name};
                return 0;
            end
        end
        service_keys.push_back(key);
        return 1;
    endfunction

    // 功能：查询 key 是否落在当前白名单内；空白名单表示旧版全量消费。
    // 输入/输出：输入完整 key，返回是否选中；只读，不改变配置或快照。
    function bit service_key_selected(input dpu_service_key_t key);
        string service_name;

        if (service_keys.size() == 0)
            return 1;
        service_name = dpu_service_key_name(key);
        foreach (service_keys[index]) begin
            if (dpu_service_key_name(service_keys[index]) == service_name)
                return 1;
        end
        return 0;
    endfunction

    // 功能：按最终 function owner 判断是否属于本 Host。
    // 输入/输出：输入快照 owner，返回是否选中；白名单与 Host 筛选保持独立。
    // 边界/副作用：关闭 Host scope 时允许任意 owner；不推断或修改资源归属。
    function bit service_host_selected(input dpu_function_key_t owner);
        return !host_scope_enable || (owner.host_id == host_scope_id);
    endfunction

    // ========================================================================
    // make_default_driver_config
    //
    // Build behavior from the default fields and cap it with the snapshot
    // authority supplied by the caller.
    // ========================================================================

    // 根据环境默认字段生成单个 service 的驱动行为，并把 qpair 上限限制为
    // snapshot 传入的 max_pairs；不修改环境配置本身。
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
        cfg.irq_mode            = (completion_mode == VIRTIO_COMPLETION_POLLING) ?
                                  IRQ_POLLING : default_irq_mode;
        cfg.napi_budget         = default_napi_budget;
        cfg.coal_max_packets    = 0;
        cfg.coal_max_usecs      = 0;
        cfg.bw_limit_enable     = bw_limit_enable;
        cfg.bw_limit_mbps       = bw_limit_mbps;
        cfg.mode                = default_driver_mode;
        return cfg;
    endfunction

    // 读取命令行覆盖，非法值返回可读原因并保持原配置不变。
    function bit apply_plusargs(output string why);
        string mode_name;
        string completion_name;

        why = "";
        if ($value$plusargs("VIRTIO_EXEC_MODE=%s", mode_name)) begin
            if ((mode_name == "MODEL") || (mode_name == "model"))
                execution_mode = VIRTIO_EXEC_MODEL;
            else if ((mode_name == "REAL_DUT") || (mode_name == "real_dut"))
                execution_mode = VIRTIO_EXEC_REAL_DUT;
            else begin
                why = {"unsupported VIRTIO_EXEC_MODE=", mode_name,
                       "; expected MODEL or REAL_DUT"};
                return 0;
            end
        end
        if ($value$plusargs("VIRTIO_COMPLETION_MODE=%s", completion_name)) begin
            if ((completion_name == "MSIX") || (completion_name == "msix"))
                completion_mode = VIRTIO_COMPLETION_MSIX;
            else if ((completion_name == "POLLING") ||
                     (completion_name == "polling"))
                completion_mode = VIRTIO_COMPLETION_POLLING;
            else begin
                why = {"unsupported VIRTIO_COMPLETION_MODE=", completion_name,
                       "; expected MSIX or POLLING"};
                return 0;
            end
        end
        return validate_execution_mode(why);
    endfunction

    // 枚举底层值仍可能被强制赋成保留值，因此在环境创建前显式校验。
    function bit validate_execution_mode(output string why);
        why = "";
        case (execution_mode)
            VIRTIO_EXEC_MODEL, VIRTIO_EXEC_REAL_DUT: begin end
            default: begin
                why = "invalid virtio execution mode";
                return 0;
            end
        endcase
        case (completion_mode)
            VIRTIO_COMPLETION_MSIX, VIRTIO_COMPLETION_POLLING: begin end
            default: begin
                why = "invalid virtio completion mode";
                return 0;
            end
        endcase
        return 1;
    endfunction

    // 校验 queue 数量、队列大小和带宽参数等本地行为约束；失败时通过 why
    // 返回可读原因，不产生状态副作用。
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

    // 为一个完整 service key 注册显式驱动行为；拒绝重复 service、同 Function
    // 多份配置和非法行为，成功后由本对象拥有该配置副本。
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

    // 按 service key 查询行为配置；未显式注册时生成默认配置，并将 qpair 数量
    // 截断到 resource snapshot 实际分配值，失败通过 why 返回。
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

    // 检查内存/IOVA aperture、默认行为和显式 service 配置的本地约束；不依赖
    // 外部 snapshot，失败原因写入 why。
    function bit validate_local(output string why);
        virtio_driver_config_t default_cfg;

        if (mem_base >= mem_end) begin
            why = $sformatf("mem_base=0x%016h >= mem_end=0x%016h",
                            mem_base, mem_end);
            return 0;
        end
        if ((iova_base == 0) || ((iova_base & 64'hfff) != 0) ||
            ((iova_limit & 64'hfff) != 0) || (iova_limit <= iova_base)) begin
            why = $sformatf(
                "invalid IOVA aperture [0x%016h,0x%016h): base/limit must be nonzero, page-aligned and nonempty",
                iova_base, iova_limit);
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

    // 将本地业务行为与冻结 device snapshot 的 capability 和 service 声明对照，
    // 防止环境越权创建拓扑或请求超过 DUT 单 Function qpair 上限。
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
        // Host 范围必须与该业务环境的内存/IOMMU Host ID 一致，防止跨域消费。
        if (host_scope_enable && (host_scope_id != host_id)) begin
            why = $sformatf(
                "host scope id %0d disagrees with environment host_id %0d",
                host_scope_id, host_id);
            return 0;
        end
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
        // 先用冻结快照验证显式白名单：完整 service key 必须已声明，owner 必须
        // 属于当前 Host；按键而非数组下标筛选，避免 PF/VF 创建顺序影响隔离。
        foreach (service_keys[index]) begin
            string scope_name;

            scope_name = dpu_service_key_name(service_keys[index]);
            if (service_keys[index].service_kind != DPU_SERVICE_VIO_NET) begin
                why = {"service scope requires VIO-net key ", scope_name};
                return 0;
            end
            for (int prior = 0; prior < index; prior++) begin
                if (dpu_service_key_name(service_keys[prior]) == scope_name) begin
                    why = {"duplicate service scope key ", scope_name};
                    return 0;
                end
            end
            if (!snapshot.get_service_owner(
                    service_keys[index], owner, service_why)) begin
                why = {"service scope key is not declared by snapshot ",
                       scope_name, ": ", service_why};
                return 0;
            end
            if ((service_keys.size() != 0 || host_scope_enable) &&
                (owner.host_id != host_id)) begin
                why = $sformatf(
                    "service scope key %s belongs to Host %0d, but this environment is bound to Host %0d",
                    scope_name, owner.host_id, host_id);
                return 0;
            end
            if (host_scope_enable && !service_host_selected(owner)) begin
                why = $sformatf(
                    "service scope key %s belongs to Host %0d, expected Host %0d",
                    scope_name, owner.host_id, host_scope_id);
                return 0;
            end
        end
        foreach (m_service_configs[service_name]) begin
            if (m_service_configs[service_name].key.service_kind !=
                DPU_SERVICE_VIO_NET) begin
                why = {"VIO service configuration requires VIO-net key ",
                       service_name};
                return 0;
            end
            if (!service_key_selected(m_service_configs[service_name].key)) begin
                why = {"VIO service configuration is outside the selected ",
                       "service scope ", service_name};
                return 0;
            end
            if (!snapshot.get_service_owner(
                    m_service_configs[service_name].key, owner, service_why)) begin
                why = {"VIO service configuration is not declared by snapshot ",
                       service_name, ": ", service_why};
                return 0;
            end
            if ((service_keys.size() != 0 || host_scope_enable) &&
                !service_host_selected(owner)) begin
                why = $sformatf(
                    "VIO service configuration %s belongs to Host %0d, expected Host %0d",
                    service_name, owner.host_id, host_scope_id);
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
    // convert2string
    // ========================================================================

    // 生成调试字符串，覆盖 Host memory、IOVA、默认驱动和验证开关；无状态副作用。
    virtual function string convert2string();
        string s;
        s = $sformatf("virtio_net_env_config:\n");
        s = {s, $sformatf("  service_scope=%0d (%s)\n", service_keys.size(),
                          (service_keys.size() == 0) ? "all VIO services" :
                          "explicit service keys")};
        s = {s, $sformatf("  mem_base=0x%016h, mem_end=0x%016h\n", mem_base, mem_end)};
        s = {s, $sformatf("  host_id=%0d, host_mem_policy=%s, host_mem_binding=%s, host_mem_pool=%s\n",
                          host_id, host_mem_policy.name(),
                          (host_mem_binding == null) ? "none" : host_mem_binding.get_name(),
                          (host_mem_pool_binding == null) ? "none" : host_mem_pool_binding.get_name())};
        s = {s, $sformatf("  iommu_strict=%0b, iova=[0x%016h,0x%016h), policy=%s\n",
                          iommu_strict, iova_base, iova_limit,
                          iova_alloc_policy.name())};
        s = {s, $sformatf("  execution=%s, completion=%s\n",
                          execution_mode.name(), completion_mode.name())};
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
