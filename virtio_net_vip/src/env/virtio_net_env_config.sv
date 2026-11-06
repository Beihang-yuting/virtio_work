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
// 以及 host_mem_pool、virtio_iommu_model 和协议事件接口；可选 AIP 读取在本类
// load_params 中显式发生。公共 IOMMU/VIF 只借用，不作为普通参数复制或重建。
// test 持有配置对象；环境在 build/connect 阶段借用，
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

    // 仅在顶层显式启用后，为实际解析出的 service 加载并缓存一次参数副本。
    // 与显式配置表分开，避免改变私有协议“是否显式设置队列大小”的判断。
    protected bit	aip_service_params_enabled = 0;
    protected string	aip_service_root = "vio";
    protected virtio_driver_config_t	m_param_service_configs[string];

    // 私有驱动按完整 service key 选择，避免全局 factory override 影响标准 PF/VF。
    // 配置由上层持有；Function 在 PCIe 绑定时冻结队列配置副本。
    typedef struct {
        dpu_service_key_t key;
        dpu_priv_driver_config cfg;
    } private_config_entry_t;
    protected private_config_entry_t m_private_configs[string];

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

    // 平台可注入已有 IOMMU；env 只校验策略一致性，不能清空外部映射表。
    // null 保持原来的 env 自建行为；copy_defaults_from 不复制公共资源句柄。
    virtio_iommu_model	iommu_binding = null;

    // 协议断言接口按完整 PCIe 身份登记，避免多个 Host env 都使用全局 slot 0。
    // 空表兼容原来的 protocol_event_vif_<slot>；非空表要求覆盖全部 active Function。
    protected virtual virtio_protocol_event_if	protocol_vifs[string];

    // 登记已解析 Function 的独立协议接口；拒绝空接口、重复身份和同表接口复用。
    // 平台负责跨 env 唯一分配；本方法不读取参数，也不改写 Function 身份。
    function bit bind_protocol_event_vif(
        dpu_pcie_function_id_t	function_id,
        virtual virtio_protocol_event_if	vif,
        output string	why
    );
        string	key;

        why = "";
        key = dpu_pcie_function_id_name(function_id);
        if (vif == null) begin
            why = {"null protocol event interface for ", key};
            return 0;
        end
        if (protocol_vifs.exists(key)) begin
            why = {"duplicate protocol event binding for ", key};
            return 0;
        end
        foreach (protocol_vifs[other]) begin
            if (protocol_vifs[other] == vif) begin
                why = {"protocol event interface already belongs to ", other};
                return 0;
            end
        end
        protocol_vifs[key] = vif;
        return 1;
    endfunction

    // 查询是否启用完整身份映射；启用后禁止退回全局 slot，避免部分配置串接。
    function bit has_protocol_event_bindings();
        return protocol_vifs.num() != 0;
    endfunction

    // 只读取得指定 Function 的接口；未命中返回 0 并清空输出，不分配候选接口。
    function bit get_protocol_event_vif(
        dpu_pcie_function_id_t	function_id,
        output virtual virtio_protocol_event_if	vif
    );
        string	key;

        key = dpu_pcie_function_id_name(function_id);
        vif = null;
        if (!protocol_vifs.exists(key)) return 0;
        vif = protocol_vifs[key];
        return vif != null;
    endfunction

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

    // 配置拥有等待策略模板；env 在 build 时复制，运行时不再读取全局参数表。
    virtio_wait_policy	wait_policy_cfg;

    // ========================================================================
    // Constructor
    // ========================================================================

    // 初始化默认字段及自有等待策略模板；不读取参数或创建外部内存/DMA资源。
    function new(string name = "virtio_net_env_config");
        super.new(name);
        wait_policy_cfg = virtio_wait_policy::type_id::create({name, "_wait_policy"});
    endfunction

    // 参数归属：vio.* 默认值、vio.hN.* Host 覆盖；service 级仅开放驱动行为。
    // 解析与字段放在同一个类中，短名称不泄漏 default_* 内部命名。须在 service
    // 副本登记前显式调用；AIP 未编译时为空操作，不访问 DUT 或分配资源。
    function void	load_params(string	path = "vio");
`ifdef AIP_CMDLINE_SV
        virtio_driver_config_t	behavior;
        virtio_execution_mode_e	exec_mode;
        virtio_completion_mode_e	completion;
        iommu_iova_alloc_policy_e	iova_policy;
        bit [63:0]	base;
        bit [63:0]	iova_size;
        longint unsigned	scb;
        longint unsigned	coverage;
        longint unsigned	strict;
        string	why;

        if ((m_service_configs.num() != 0) || (m_param_service_configs.num() != 0)) begin
            `uvm_fatal("VIO_PARAM", {path, ": 必须在 add_service_config 复制配置之前加载"})
            return;
        end
        if (wait_policy_cfg == null) begin
            `uvm_fatal("VIO_PARAM", {path, ": 等待策略模板为空"})
            return;
        end
        behavior = make_default_driver_config(DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE);
        behavior.num_queue_pairs = default_num_pairs;
        load_driver_params(path, behavior);
        // 显式 name 参数保留公开 completion_mode/iova_base/iommu_strict 短名。
        `aip_enum(path, virtio_execution_mode_e, exec_mode, execution_mode);
        begin
            virtio_completion_mode_e	completion_mode;
            `aip_enum(path, virtio_completion_mode_e, completion_mode, this.completion_mode);
            completion = completion_mode;
        end
        `aip_enum(path, iommu_iova_alloc_policy_e, iova_policy, iova_alloc_policy);
        begin
            bit [63:0]	iova_base;
            `DPU_AIP_UINT(path, bit [63:0], iova_base, this.iova_base);
            base = iova_base;
        end
        `DPU_AIP_UINT(path, bit [63:0], iova_size, iova_limit - this.iova_base);
        `DPU_AIP_UINT(path, longint unsigned, scb, scb_enable);
        `DPU_AIP_UINT(path, longint unsigned, coverage, cov_enable);
        begin
            longint unsigned	iommu_strict;
            `DPU_AIP_UINT(path, longint unsigned, iommu_strict, this.iommu_strict);
            strict = iommu_strict;
        end
        if ((scb > 1) || (coverage > 1) || (strict > 1)) begin
            `uvm_fatal("VIO_PARAM", {path, ": scb/coverage/iommu_strict 必须为 0 或 1"})
            return;
        end
        if ((base == 0) || (iova_size == 0) ||
            (base > (64'hffff_ffff_ffff_ffff - iova_size)) ||
            ((base & 64'hfff) != 0) || ((iova_size & 64'hfff) != 0)) begin
            `uvm_fatal("VIO_PARAM", {path, ": IOVA base/size 必须 4KiB 对齐、非零且不能溢出"})
            return;
        end
        default_num_pairs           = behavior.num_queue_pairs;
        default_queue_size          = behavior.queue_size;
        default_vq_type             = behavior.vq_type;
        default_driver_features     = behavior.driver_features;
        default_napi_budget         = behavior.napi_budget;
        default_rx_refill_threshold = behavior.rx_refill_threshold;
        execution_mode              = exec_mode;
        this.completion_mode        = completion;
        iova_base                   = base;
        iova_limit                  = base + iova_size;
        iova_alloc_policy           = iova_policy;
        iommu_strict                = bit'(strict);
        scb_enable                  = bit'(scb);
        cov_enable                  = bit'(coverage);
        wait_policy_cfg.load_params({path, ".wait"});
        if (!validate_execution_mode(why) || !validate_local(why))
            `uvm_fatal("VIO_PARAM", {path, ": ", why})
`endif
    endfunction

    // 仅解析一份驱动值类型：全局默认与 service 覆盖共用同一张短名映射。
    // 不扩容 DPU 资源，先用宽整数拒绝负值/截断/非法几何，再更新调用方副本。
    function void	load_driver_params(string	path, ref virtio_driver_config_t	behavior);
`ifdef AIP_CMDLINE_SV
        longint unsigned	pairs;
        longint unsigned	queue_size;
        longint unsigned	napi_budget;
        longint unsigned	rx_refill;
        virtqueue_type_e	queue_type;
        bit [63:0]	features;

        `DPU_AIP_UINT(path, longint unsigned, pairs, behavior.num_queue_pairs);
        `DPU_AIP_UINT(path, longint unsigned, queue_size, behavior.queue_size);
        `DPU_AIP_UINT(path, longint unsigned, napi_budget, behavior.napi_budget);
        `DPU_AIP_UINT(path, longint unsigned, rx_refill, behavior.rx_refill_threshold);
        `aip_enum(path, virtqueue_type_e, queue_type, behavior.vq_type);
        `aip_int(path, bit [63:0], features, behavior.driver_features);
        if ((pairs == 0) || (pairs > DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) ||
            ((queue_size != 0) && ((queue_size < 2) || (queue_size > 32768) ||
              ((queue_size & (queue_size - 1)) != 0))) ||
            (napi_budget == 0) || (napi_budget > 64'hffff_ffff) ||
            (rx_refill == 0) || (rx_refill > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ": pairs/queue_size/napi_budget/rx_refill 超出有效范围"})
            return;
        end
        behavior.num_queue_pairs = int'(pairs);
        behavior.queue_size = int'(queue_size);
        behavior.napi_budget = int'(napi_budget);
        behavior.rx_refill_threshold = int'(rx_refill);
        behavior.vq_type         = queue_type;
        behavior.driver_features = features;
`endif
    endfunction

    // 将身份转为稳定的公共路径；PF 不附带 VF 段，实例号始终显式保留。
    // 只格式化输入，不把 function_instances 数组下标当作 PF/VF 身份。
    static function string	service_param_path(dpu_service_key_t	key, string	root = "vio");
        string	path;

        path = $sformatf("%s.h%0d.pf%0d", root,
                         key.function_key.host_id, key.function_key.pf_id);
        if (key.function_key.kind == DPU_FUNCTION_VF)
            path = {path, $sformatf(".vf%0d", key.function_key.vf_id)};
        return {path, $sformatf(".i%0d", key.service_instance_id)};
    endfunction

    // 在 add_service_config 前对现有驱动副本加载精确实例路径，缺省继承该副本。
    // 全局/Host 默认由顶层先加载；本函数不重复读取它们，也不重新采样全局随机值。
    function void	load_service_params(
        dpu_service_key_t	key, ref virtio_driver_config_t	behavior, string	root = "vio"
    );
        load_driver_params(service_param_path(key, root), behavior);
    endfunction

    // 延迟到第一次 get_service_config 时按冻结快照中的真实 service 身份读取。
    // 适用于 AUTO placement 无法预知服务归属的顶层；缓存后禁止重新启用或改根路径。
    function void	enable_service_params(string	root = "vio");
        if (m_param_service_configs.num() != 0) begin
            `uvm_fatal("VIO_PARAM", "service 参数已经加载，不能重新绑定参数根路径")
            return;
        end
        aip_service_params_enabled = 1;
        aip_service_root = root;
    endfunction

    // 从已采样的全局模板复制默认值，供各 Host 再应用自己的覆盖。
    // 不复制 Host 身份、service 注册表或借用的内存句柄；等待策略深拷贝以免串改。
    function void	copy_defaults_from(virtio_net_env_config	rhs);
        if ((rhs == null) || (rhs.wait_policy_cfg == null) || (wait_policy_cfg == null)) begin
            `uvm_fatal("VIO_PARAM", "copy_defaults_from 收到空配置或空等待模板")
            return;
        end
        if ((m_service_configs.num() != 0) || (m_param_service_configs.num() != 0)) begin
            `uvm_fatal("VIO_PARAM", "已有 service 副本，不能重新复制默认模板")
            return;
        end
        default_num_pairs = rhs.default_num_pairs;
        default_queue_size = rhs.default_queue_size;
        default_vq_type = rhs.default_vq_type;
        default_driver_features = rhs.default_driver_features;
        default_rx_mode = rhs.default_rx_mode;
        default_irq_mode = rhs.default_irq_mode;
        default_napi_budget = rhs.default_napi_budget;
        default_rx_buf_size = rhs.default_rx_buf_size;
        default_rx_refill_threshold = rhs.default_rx_refill_threshold;
        default_mtu = rhs.default_mtu;
        default_mss = rhs.default_mss;
        default_driver_mode = rhs.default_driver_mode;
        execution_mode = rhs.execution_mode;
        completion_mode = rhs.completion_mode;
        mem_base = rhs.mem_base;
        mem_end = rhs.mem_end;
        host_mem_policy = rhs.host_mem_policy;
        iommu_strict = rhs.iommu_strict;
        iova_base = rhs.iova_base;
        iova_limit = rhs.iova_limit;
        iova_alloc_policy = rhs.iova_alloc_policy;
        bw_limit_enable = rhs.bw_limit_enable;
        bw_limit_mbps = rhs.bw_limit_mbps;
        scb_enable = rhs.scb_enable;
        cov_enable = rhs.cov_enable;
        wait_policy_cfg.copy(rhs.wait_policy_cfg);
    endfunction



    // 给一个 VIO service 选择 DPU 私有驱动；重复键/空配置立即拒绝，具体队列数量
    // 在 snapshot 限额解析后校验。不改拓扑、Host 内存或其他 service 的驱动类型。
    function bit add_dpu_private_config(dpu_service_key_t key,
                                         dpu_priv_driver_config private_cfg,
                                         output string why);
        string name_key;
        name_key = dpu_service_key_name(key);
        why = "";
        if (m_param_service_configs.exists(name_key)) begin
            why = {"service 参数副本已被消费，不能切换私有协议：", name_key};
            return 0;
        end
        if ((key.service_kind != DPU_SERVICE_VIO_NET) || (private_cfg == null) ||
            m_private_configs.exists(name_key)) begin
            why = "private service key 非法、配置为空或重复登记";
            return 0;
        end
        m_private_configs[name_key] = '{key:key, cfg:private_cfg};
        return 1;
    endfunction

    // 按 service 查询借用的私有配置；返回 null 表示保持标准 Virtio 流程。
    function dpu_priv_driver_config get_dpu_private_config(dpu_service_key_t key);
        string name_key;
        name_key = dpu_service_key_name(key);
        if (m_private_configs.exists(name_key)) return m_private_configs[name_key].cfg;
        return null;
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

    // 返回 execution_mode 对应的执行策略；保留编码返回 null。每次调用返回新的
    // 无状态对象，调用方可缓存。
    function virtio_execution_profile execution_profile();
        return virtio_select_execution_profile(execution_mode);
    endfunction

    // 枚举底层值仍可能被强制赋成保留值，因此在环境创建前显式校验。
    function bit validate_execution_mode(output string why);
        why = "";
        if (virtio_select_execution_profile(execution_mode) == null) begin
            why = "invalid virtio execution mode";
            return 0;
        end
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
        if (m_param_service_configs.exists(service_name)) begin
            why = {"service 参数副本已被消费，不能再替换其配置：", service_name};
            return 0;
        end
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
        // 参数覆盖只在实际请求的 service 上采样一次；不预注册未获资源的候选 VF。
        // 私有默认环深度先合并，再允许该 service 的 queue_size 显式覆盖。
        if (aip_service_params_enabled) begin
            if (m_param_service_configs.exists(service_name)) begin
                driver_cfg = m_param_service_configs[service_name];
            end else begin
                // 缓存保存原始意图；本次资源限额只约束返回值，不能永久截短模板。
                if (!m_service_configs.exists(service_name))
                    driver_cfg.num_queue_pairs = default_num_pairs;
                if (!m_service_configs.exists(service_name) &&
                    m_private_configs.exists(service_name) &&
                    (m_private_configs[service_name].cfg != null))
                    driver_cfg.queue_size = m_private_configs[service_name].cfg.default_queue_size;
                load_service_params(key, driver_cfg, aip_service_root);
                m_param_service_configs[service_name] = driver_cfg;
            end
        end
        if (driver_cfg.num_queue_pairs > max_pairs)
            driver_cfg.num_queue_pairs = max_pairs;
        driver_cfg.max_vio_net_qpairs_per_device = max_pairs;
        // 显式私有配置选择私有队列和 polling；没有 service 级行为覆盖时使用
        // 私有默认环大小。该协议没有 Virtio 特性协商和 Virtio-net header。
        if (m_private_configs.exists(service_name)) begin
            dpu_priv_driver_config private_cfg;
            private_cfg = m_private_configs[service_name].cfg;
            if (!private_cfg.validate(driver_cfg.num_queue_pairs, why)) return 0;
            if (!m_service_configs.exists(service_name) && !aip_service_params_enabled)
                driver_cfg.queue_size = private_cfg.default_queue_size;
            driver_cfg.vq_type = VQ_CUSTOM;
            driver_cfg.irq_mode = IRQ_POLLING;
            driver_cfg.driver_features = 0;
            driver_cfg.rx_buf_size = private_cfg.rx_buf_size;
        end
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
        foreach (m_private_configs[private_name]) begin
            if (m_private_configs[private_name].cfg == null) begin
                why = {"private service 缺少配置 ", private_name};
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
        foreach (m_private_configs[private_name]) begin
            if (!service_key_selected(m_private_configs[private_name].key) ||
                !snapshot.get_service_owner(m_private_configs[private_name].key,
                                              owner, service_why) ||
                (owner.host_id != host_id)) begin
                why = {"private service 不在当前 Host 的冻结快照/选择范围内 ", private_name};
                return 0;
            end
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
        s = {s, $sformatf("  scb_enable=%0b, cov_enable=%0b", scb_enable, cov_enable)};
        return s;
    endfunction

endclass : virtio_net_env_config

`endif // VIRTIO_NET_ENV_CONFIG_SV
