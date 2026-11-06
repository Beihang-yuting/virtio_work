# 项目 env / env_cfg 完整代码：DPU、Intel PCIe 和 VIO

下面逐文件完整展开参考源码，没有省略函数体。将配置文件的成员和方法合入你的
`env_cfg`，将环境文件的成员和方法合入你的 `env`，统一替换类名、factory 宏和
`uvm_config_db` 的类型即可。已有 env 维持自己的基类，本示例使用 `uvm_env`。
不需要把 `project_env` 再实例化在你的 env 中，也不需要任何 DPU 派生类。

```text
你的 env extends uvm_env
├── dpu_env : dpu_device_env
│   ├── vio_h0 : virtio_net_env
│   └── vio_h1 : virtio_net_env  （按 Host 数创建）
└── pcie_env : pcie_tl_env
```

VIO 的 UVM parent 使用 `dpu_env`，这样 DPU 先发布 snapshot，VIO 后读取；
创建动作和 `vio_envs[h]` 句柄仍放在你的大 env。PCIe 只接收 `pcie_tl_env_config`，
不创建 global/topology 配置，不依赖 SVT 或建链。
详细参数、生命周期、共享资源和适用范围见 [集成说明](../integration/project/README.md)。

本参考固定使用 Intel PCIe，唯一入口为 `filelists/project_integration.f`。
无需定义接口选择宏；普通 TL VIF、EP 配对和 MODEL completion adapter 已删除。
Intel 使用 `SV_IF_MODE` + adapter instance override；真实 DUT 为 EP 应用逻辑，
每 Host 仅创建 RC，`SIDE=HARD_IP`，`num_ep=0`。

Intel cfg/VIF 在 `prepare_intel_bindings()` 中、PCIe 子组件 build 之前下发。
它支持从大 cfg 注入或借用现有 bind wrapper 发布的句柄，缺接口/冲突/跨端口复用
均立即失败。接口路径为 `uvm_test_top.env.pcie_env.rc_adapter_0` 等。
完整的 test/top 注入代码、Intel 字段表与 HDL bind 说明见
[Intel 配置放在哪里](../integration/project/README.md#intel-配置放在哪里)。


## 拷贝时需要保留的内容

1. `env_cfg`：除了三个子 cfg，还要带上每 Host 的 VIO cfg、Host→slot 映射以及
   平台句柄。`load_params()` 包含规模读取和默认 Host/PF/VF 输入生成，不能只拷贝
   三行子配置加载调用。如果项目已有自己的输入生成，就在原位置合入参数调用。
2. `env`：保留共享内存准备、build/connect 和 VIF/endpoint 绑定的辅助函数。
   尤其是先安装寄存器 backend，再由 DPU 子组件 build 绑定快照。
3. `test`：保留加载 cfg、注入平台句柄、发布 cfg、等待平台就绪、DPU 初始化、
   AIP 命令注册及业务收尾。标量参数由 load 负责，不需要逐项赋值。
4. `package/filelist`：只补当前工程缺少的依赖；这些文件仍是独立参考入口，
   不加入原生产 filelist/package，也不能把被 include 的 `.sv` 再单独编译。

## 大配置与参数构造：project_env_cfg.sv

默认输入为 1 Host、1 PF、0 VF。`load_params()` 只执行一次；默认生成器拒绝覆盖非空的 Host/Function/placement。

代码中的宏是 `DPU_AIP_UINT`（UINT 为无符号整数），定义于外部
`dpu_common/src/dpu_aip_params.svh`；并没有 `DPU_AIP_UNIT`。
宏由独立 filelist 的编译/include 顺序带入，package 的 `import` 本身不导入宏。
若你的工程分开预编译各 package，请同时保留 AIP 宏可见性和该宏头的 include 设置，
可对照 [AIP 编译说明](aip_parameters.md#编译与文件定位)。


[源文件](../integration/project/project_env_cfg.sv)

```systemverilog
// integration/project：项目级配置组合与参数构建示例。
// 依赖 DPU、PCIe TL、Intel adapter、VIO 与 AIP；由 project_env_pkg 按顺序包含。
// cfg 拥有创建的配置对象，借用平台注入的 pool、IOMMU 与 VIF。
// load_params 只生成输入，不解析快照、不创建组件、不访问 DUT；每个对象只加载一次。
// 每 Host 一个 segment 0 和一组 TL 接口；PF/VF 共用接口，不配置 SVT 或链路训练。
// 固定使用真实 EP 应用 DUT 的 Intel HARD_IP 接口；每 Host 仅创建一个 RC。
class project_env_cfg extends uvm_object;
    `uvm_object_utils(project_env_cfg)

    dpu_device_env_config	dpu_cfg;
    virtio_net_env_config	vio_cfg;
    virtio_net_env_config	vio_cfg_by_host[int unsigned];
    pcie_tl_env_config		pcie_cfg;
    // 值是 RC agent 下标；EP 由真实 DUT 提供。缺省 h→h，PF/VF 共用 Host 的 slot。
    int unsigned			tl_slot_by_host[int unsigned];

    host_mem_pool			host_mem_pool_binding;
    alloc_mode_e			host_mem_mode = MODE_BUDDY;
    int unsigned			host_mem_granule = DEFAULT_MIN_GRANULE;

    // 按物理 RC slot 索引，不是按 PF/VF 索引；同一 Host 的 Function 共用端口。
    // 平台可注入句柄，或由 bind wrapper 向实际 adapter 路径发布；env 会复用并校验。
    // Intel cfg 没有 load_params；这里不宣称 pcie_cfg.intel.* 已自动注册。
    intel_pcie_adapter_config	intel_cfg_by_slot[int unsigned];
    intel_pcie_vif_t			intel_rc_vifs[int unsigned];

    virtual virtio_protocol_event_if	protocol_vifs[$];

    // 这是配置生成规模，不是另一套已解析拓扑；最终身份以 DPU snapshot 为准。
    longint unsigned	hosts = 1;
    longint unsigned	pfs_per_host = 1;
    longint unsigned	vfs_per_pf = 0;
    protected bit	params_loaded = 0;

    // 创建配置容器；固定 REAL_DUT，实际 Intel 接口由 bind wrapper 或平台注入。
    // new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
    function new(string	name = "project_env_cfg");
        super.new(name);
        dpu_cfg = dpu_device_env_config::type_id::create("dpu_cfg");
        vio_cfg = virtio_net_env_config::type_id::create("vio_cfg");
        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        vio_cfg.execution_mode = VIRTIO_EXEC_REAL_DUT;
        dpu_cfg.device_cfg.af_request.mode = DPU_AF_SELECTED;
        dpu_cfg.device_cfg.af_request.requester =
            '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
    endfunction

    // 构造全局 Host 模板；GPA 和 MMIO 分开，BDF 范围覆盖默认 PF/VF 规模。
    // 每 Host 的 identity 和参数覆盖由 load_params 设置，不在这里解析实际地址。
    protected function dpu_host_cfg make_host_template();
        dpu_host_cfg		host;
        dpu_pcie_domain_cfg	domain;
        dpu_mmio_window_cfg	window;
        dpu_bdf_range_t		bdf_range;

        host = dpu_host_cfg::type_id::create("host_template");
        host.has_gpa_aperture = 1;
        host.gpa_base = 64'h0000_1000_0000_0000;
        host.gpa_limit = host.gpa_base + 64'h1000_0000;
        domain = dpu_pcie_domain_cfg::type_id::create("domain_template");
        domain.key = '{host_id:0, segment_id:0};
        bdf_range = '{first_bdf:16'h0010, last_bdf:16'h0fff};
        domain.bdf_ranges.push_back(bdf_range);
        window = dpu_mmio_window_cfg::type_id::create("mmio_template");
        window.base = 64'h0000_0020_0000_0000;
        window.limit = window.base + 64'h0000_0001_0000_0000;
        window.allowed_roles = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX};
        domain.mmio_windows.push_back(window);
        domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;
        host.pcie_domains.push_back(domain);
        return host;
    endfunction

    // 按 Host/PF/VF 身份创建 Function，并从 DUT caps 取得 BAR 规格。
    // 全部 BAR/BDF 均由 resolver 最终放置；未知规格立即 fatal，不能制造设备能力。
    protected function dpu_function_cfg make_function(
        int unsigned	host_id,
        int unsigned	pf_id,
        dpu_function_kind_e	kind,
        int unsigned	vf_id
    );
        dpu_function_cfg	f;
        dpu_bar_role_e		roles[3] = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX};
        string			why;

        f = dpu_function_cfg::type_id::create(
            $sformatf("fn_h%0d_pf%0d_%0d_vf%0d", host_id, pf_id, kind, vf_id));
        f.key = '{host_id:host_id, pf_id:pf_id, kind:kind, vf_id:vf_id};
        f.domain_key = '{host_id:host_id, segment_id:0};
        f.bdf_mode = DPU_ALLOC_AUTO;
        f.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        foreach (roles[i]) begin
            dpu_bar_profile_t	profile;
            dpu_bar_request	bar;

            if (!dpu_cfg.device_cfg.dut_caps.lookup_bar_profile(kind, roles[i], profile, why))
                `uvm_fatal("PROJECT_CFG", why)
            bar = dpu_bar_request::type_id::create($sformatf("bar_%0d", i));
            bar.role = profile.role;
            bar.even_bar_id = profile.even_bar_id;
            bar.size = profile.size;
            bar.alignment = profile.alignment;
            bar.placement = DPU_ALLOC_AUTO;
            f.bars.push_back(bar);
        end
        return f;
    endfunction

    // 验证 Host→TL slot 是完整的一一映射；不补缺项，避免错配后静默使用 Root0。
    // 仅支持每 Host 一个 segment 0；失败返回原因，不修改输入配置或访问 DUT。
    function bit validate_tl_mapping(output string	why);
        bit		used_slots[int unsigned];
        int unsigned	count;

        why = "";
        count = dpu_cfg.device_cfg.hosts.size();
        if (count == 0 || tl_slot_by_host.num() != count || vio_cfg_by_host.num() != count) begin
            why = "each DPU Host needs exactly one VIO config and TL slot";
            return 0;
        end
        foreach (dpu_cfg.device_cfg.hosts[i]) begin
            dpu_host_cfg	host;
            int unsigned	slot;

            host = dpu_cfg.device_cfg.hosts[i];
            if (host == null) begin
                why = "DPU Host config is null";
                return 0;
            end
            if (!tl_slot_by_host.exists(host.host_id) ||
                !vio_cfg_by_host.exists(host.host_id) || vio_cfg_by_host[host.host_id] == null) begin
                why = $sformatf("Host%0d has no VIO config or TL slot", host.host_id);
                return 0;
            end
            slot = tl_slot_by_host[host.host_id];
            if (slot >= count || used_slots.exists(slot)) begin
                why = "TL slots must be unique and cover 0..Host_count-1";
                return 0;
            end
            if (host.pcie_domains.size() != 1) begin
                why = "Intel project requires one PCIe domain per Host";
                return 0;
            end
            if (host.pcie_domains[0] == null) begin
                why = "Host PCIe domain is null";
                return 0;
            end
            if (host.pcie_domains[0].key.host_id != host.host_id ||
                host.pcie_domains[0].key.segment_id != 0) begin
                why = "Intel project requires Host-owned segment 0";
                return 0;
            end
            used_slots[slot] = 1;
        end
        return 1;
    endfunction

    // 唯一参数构建入口：先采样规模/模板，再创建 Host/PF/VF/placement 和 Host 行为。
    // 再调用幂等返回，不重新采样；已有输入的项目应把加载入口合入原构造点，省去生成循环。
    // 默认生成器拒绝覆盖非空逻辑配置，避免重复追加 Host/PF/VF 和资源请求。
    // base_test 无须逐项赋值；AIP-off 时保留默认值，但仍正常创建对象。
    virtual function void load_params();
        dpu_dut_caps			caps;
        dpu_host_cfg			host_template;
        dpu_resource_pool_config_t	profile;
        dpu_vio_placement_request	request;
        int unsigned			max_initial_pairs;
        string				why;

        if (params_loaded) return;
        if ((dpu_cfg.device_cfg.hosts.size() != 0) ||
            (dpu_cfg.device_cfg.functions.size() != 0) ||
            (dpu_cfg.placement_cfg.vio_requests.size() != 0) ||
            (dpu_cfg.placement_cfg.profiles.size() != 0))
            `uvm_fatal("PROJECT_CFG", "default authoring cannot overwrite an existing DPU topology")
        dpu_cfg.device_cfg.load_params("dpu");
        caps = dpu_cfg.device_cfg.dut_caps;
        if (!caps.validate(why)) `uvm_fatal("PROJECT_CFG", why)
`ifdef AIP_CMDLINE_SV
        `DPU_AIP_UINT("dpu", longint unsigned, hosts, this.hosts)
        `DPU_AIP_UINT("dpu", longint unsigned, pfs_per_host, this.pfs_per_host)
        `DPU_AIP_UINT("dpu", longint unsigned, vfs_per_pf, this.vfs_per_pf)
        begin
            alloc_mode_e		mem_mode;
            host_mem_alloc_policy_e	mem_policy;
            longint unsigned		mem_granule;

            `aip_enum("dpu", alloc_mode_e, mem_mode, host_mem_mode)
            `aip_enum("dpu", host_mem_alloc_policy_e, mem_policy, vio_cfg.host_mem_policy)
            `DPU_AIP_UINT("dpu", longint unsigned, mem_granule, host_mem_granule)
            if ((mem_granule == 0) || (mem_granule > 64) ||
                ((mem_granule & (mem_granule - 1)) != 0))
                `uvm_fatal("PROJECT_CFG", "dpu.mem_granule must be a power of two in 1..64")
            host_mem_mode = mem_mode;
            host_mem_granule = int'(mem_granule);
            vio_cfg.host_mem_policy = mem_policy;
        end
`endif
        if ((hosts == 0) || (hosts > caps.max_hosts) ||
            (pfs_per_host == 0) || (pfs_per_host > caps.max_pfs_per_host) ||
            (pfs_per_host > 4) || (vfs_per_pf > caps.max_vfs_per_pf))
            `uvm_fatal("PROJECT_CFG", "Host/PF/VF counts exceed DUT or VIO source-id capacity")
        if ((hosts * pfs_per_host * (1 + vfs_per_pf)) > caps.max_functions)
            `uvm_fatal("PROJECT_CFG", "total Function count exceeds DUT capability")

        vio_cfg.load_params("vio");
        if (vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT)
            `uvm_fatal("PROJECT_INTEL", "Intel reference requires REAL_DUT EP application logic")
        host_template = make_host_template();
        host_template.load_params("dpu");
        profile.name = "virtio.qpair";
        profile.class_id = '0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = caps.vio_global_qpair_count;
        profile.max_per_function = caps.max_vio_net_qpairs_per_device;
        dpu_cfg.placement_cfg.profiles.push_back(profile);
        request = dpu_vio_placement_request::type_id::create("vio_request");
        request.request_id = 0;
        request.candidate_kind = (vfs_per_pf == 0) ? DPU_VIO_CANDIDATE_PF_ONLY : DPU_VIO_CANDIDATE_VF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        max_initial_pairs = 0;

        for (int unsigned	h = 0; h < hosts; h++) begin
            dpu_host_cfg		host;
            virtio_net_env_config	host_vio;
            bit [64:0]			base;
            bit [64:0]			limit;

            host = dpu_host_cfg::type_id::create($sformatf("host_%0d", h));
            host.copy_from(host_template);
            host.host_id = h;
            host.pcie_domains[0].key.host_id = h;
            base = {1'b0, host.gpa_base} + h * 65'h0000_0100_0000_0000;
            limit = {1'b0, host.gpa_limit} + h * 65'h0000_0100_0000_0000;
            if (base[64] || limit[64]) `uvm_fatal("PROJECT_CFG", "Host GPA stride overflows")
            host.gpa_base = base[63:0];
            host.gpa_limit = limit[63:0];
            base = {1'b0, host.pcie_domains[0].mmio_windows[0].base} + h * 65'h0000_0010_0000_0000;
            limit = {1'b0, host.pcie_domains[0].mmio_windows[0].limit} + h * 65'h0000_0010_0000_0000;
            if (base[64] || limit[64]) `uvm_fatal("PROJECT_CFG", "Host MMIO stride overflows")
            host.pcie_domains[0].mmio_windows[0].base = base[63:0];
            host.pcie_domains[0].mmio_windows[0].limit = limit[63:0];
            host.load_params($sformatf("dpu.h%0d", h));
            dpu_cfg.device_cfg.hosts.push_back(host);

            host_vio = virtio_net_env_config::type_id::create($sformatf("vio_cfg_h%0d", h));
            host_vio.copy_defaults_from(vio_cfg);
            host_vio.host_id = h;
            host_vio.host_scope_enable = 1;
            host_vio.host_scope_id = h;
            host_vio.load_params($sformatf("vio.h%0d", h));
            host_vio.enable_service_params("vio");
            if (host_vio.execution_mode != vio_cfg.execution_mode)
                `uvm_fatal("PROJECT_CFG", "one PCIe environment requires consistent VIO execution modes")
            vio_cfg_by_host[h] = host_vio;
            if (host_vio.default_num_pairs > max_initial_pairs)
                max_initial_pairs = host_vio.default_num_pairs;

            for (int unsigned	pf = 0; pf < pfs_per_host; pf++) begin
                dpu_function_cfg	f;
                string			path;

                path = $sformatf("dpu.h%0d.pf%0d", h, pf);
                f = make_function(h, pf, DPU_FUNCTION_PF, 0);
                f.load_params(path);
                dpu_cfg.device_cfg.functions.push_back(f);
                if (vfs_per_pf == 0) begin
                    request.fixed_devices.push_back(f.key);
                end
                for (int unsigned	vf = 0; vf < vfs_per_pf; vf++) begin
                    f = make_function(h, pf, DPU_FUNCTION_VF, vf);
                    f.load_params($sformatf("%s.vf%0d", path, vf));
                    dpu_cfg.device_cfg.functions.push_back(f);
                    request.fixed_devices.push_back(f.key);
                end
            end
        end
        // 单个 placement request 在候选间分配资源；按最大初始 pairs 预留，
        // 保证 Host 行为覆盖不会因为全局平均分配而缺容量。用户仍可覆盖 qpairs。
        request.total_qpairs = request.fixed_devices.size() * max_initial_pairs;
        dpu_cfg.placement_cfg.vio_requests.push_back(request);
        dpu_cfg.placement_cfg.load_params("dpu");
        dpu_cfg.vio_policy.load_params("dpu");
        if (tl_slot_by_host.num() == 0) begin
            for (int unsigned	h = 0; h < hosts; h++) tl_slot_by_host[h] = h;
        end
        if (!validate_tl_mapping(why)) `uvm_fatal("PROJECT_CFG", why)

        // Intel 的接口选择由下面的固定模式和 env 的 instance override 完成，
        // 无需额外选择宏。标量参数仍加载，但不能绕过真实 DUT 的方向与信用约束。
        pcie_cfg.if_mode = SV_IF_MODE;
        pcie_cfg.rc_is_active = UVM_ACTIVE;
        pcie_cfg.ep_auto_response = 0;
        pcie_cfg.use_unified_mem = 1;
        pcie_cfg.mem_access_mode = PCIE_TL_MEM_PER_BUFFER;
        // 真实 EP 应用逻辑由 DUT 提供；Intel adapter 即使放在 passive agent 旁也会驱动
        // 引脚，因此必须关闭 EP 组件，而不是仅将 EP 标成 UVM_PASSIVE。
        pcie_cfg.rc_agent_enable = 1;
        pcie_cfg.ep_agent_enable = 0;
        pcie_cfg.num_rc = tl_slot_by_host.num();
        pcie_cfg.num_ep = 0;
        // 公共 FC 不门控；每端口有限 AVST credit 由 intel_cfg 独立管理。
        pcie_cfg.infinite_credit = 1;
        pcie_cfg.load_params("pcie_cfg");
        if (pcie_cfg.ep_auto_response)
            `uvm_fatal("PROJECT_CFG", "real EP DUT must provide its own responses")
        if (!pcie_cfg.infinite_credit)
            `uvm_fatal("PROJECT_INTEL", "pcie_cfg.infinite_credit must be 1; Intel owns AVST credits")
        params_loaded = 1;
    endfunction
endclass
```

## 你的 env 中的组合代码：project_env.sv

以下是完整环境，辅助函数均已展开。VIO 创建处的 `dpu_env` 参数必须保留，不能换成 `this`。

[源文件](../integration/project/project_env.sv)

```systemverilog
// integration/project：可拷入已有项目的组合式 env；只继承 uvm_env。
// 依赖 DPU、PCIe TL、Intel adapter、VIO 与 AIP，由 project_env_pkg 在 cfg 后包含。
// 本层直接创建 DPU/PCIe/VIO；VIO 的 parent 指向 DPU，使 UVM 自动保证快照先发布。
// 平台已有 pool/executor 时只借用并校验，不能偷偷替换。
// 默认 executor 在 DPU build 前安装 backend；接口连接与初始化由 connect/run 入口负责。
// 固定 Intel HARD_IP，在子组件 build 前取得或发布 cfg/VIF；EP 功能由真实 DUT 提供。
class project_env extends uvm_env;
    `uvm_component_utils(project_env)

    project_env_cfg		cfg;
    dpu_device_env		dpu_env;
    pcie_tl_env			pcie_env;
    virtio_net_env		vio_envs[int unsigned];
    host_mem_pool		shared_pool;
    pcie_tl_dpu_reg_backend	reg_backend;

    // 构造项目组件壳；资源创建延迟到 build，以允许 test 注入已有平台对象。
    function new(string	name, uvm_component	parent);
        super.new(name, parent);
    endfunction

    // 为每个 Host 准备唯一 manager；DPU 的 GPA limit 是开区间，pool end 是闭区间。
    // 已有 manager 必须覆盖声明 aperture 且策略一致，不重置已有分配/数据。
    protected function void prepare_host_memory();
        host_mem_pool	dpu_pool;

        shared_pool = cfg.host_mem_pool_binding;
        if (cfg.dpu_cfg.host_mem_pool_ref != null) begin
            if (!$cast(dpu_pool, cfg.dpu_cfg.host_mem_pool_ref))
                `uvm_fatal("PROJECT_ENV", "DPU memory owner is not a host_mem_pool")
            if (shared_pool != null && shared_pool != dpu_pool)
                `uvm_fatal("PROJECT_ENV", "project and DPU specify distinct Host pools")
            shared_pool = dpu_pool;
        end
        if (shared_pool == null) shared_pool = host_mem_pool::type_id::create("shared_pool");
        foreach (cfg.dpu_cfg.device_cfg.hosts[i]) begin
            dpu_host_cfg		host;
            virtio_net_env_config	vio;
            host_mem_manager		manager;

            host = cfg.dpu_cfg.device_cfg.hosts[i];
            if (host == null || !host.has_gpa_aperture || host.gpa_limit <= host.gpa_base)
                `uvm_fatal("PROJECT_ENV", "each Host requires a nonempty GPA aperture")
            if (!cfg.vio_cfg_by_host.exists(host.host_id))
                `uvm_fatal("PROJECT_ENV", "Host has no VIO behavior configuration")
            vio = cfg.vio_cfg_by_host[host.host_id];
            if (!shared_pool.has_host(host.host_id)) begin
                if (!shared_pool.create_host(host.host_id, host.gpa_base, host.gpa_limit - 1,
                        cfg.host_mem_mode, cfg.host_mem_granule, vio.host_mem_policy))
                    `uvm_fatal("PROJECT_ENV", "could not initialize Host memory")
            end
            manager = shared_pool.get_host(host.host_id);
            if (!manager.is_initialized() || manager.get_host_id() != host.host_id ||
                !manager.contains_range(host.gpa_base, host.gpa_limit - host.gpa_base) ||
                manager.get_alloc_policy() != vio.host_mem_policy)
                `uvm_fatal("PROJECT_ENV", "existing Host memory disagrees with configured aperture/policy")
            if (vio.host_mem_binding != null ||
                (vio.host_mem_pool_binding != null && vio.host_mem_pool_binding != shared_pool))
                `uvm_fatal("PROJECT_ENV", "Host VIO cfg must borrow the project-owned pool")
            vio.host_mem_pool_binding = shared_pool;
            vio.mem_base = host.gpa_base;
            vio.mem_end = host.gpa_limit - 1;
        end
        cfg.host_mem_pool_binding = shared_pool;
        cfg.dpu_cfg.host_mem_pool_ref = shared_pool;
    endfunction

    // 按显式 Host→slot 准备 TL cfg；只借用同一 Host manager，不复制 BDF/BAR。
    // 每 Host 只保留一个 RC，EP 和配置空间/MMIO 响应来自真实 DUT。
    // 既有绑定只校验不重建；Switch、多余绑定或不同 manager 都拒绝。
    protected function void prepare_pcie_config();
        string	why;

        if (!cfg.validate_tl_mapping(why)) `uvm_fatal("PROJECT_ENV", why)
        if (cfg.pcie_cfg.switch_enable)
            `uvm_fatal("PROJECT_ENV", "Intel project reference does not create a Switch")
        cfg.pcie_cfg.rc_agent_enable = 1;
        cfg.pcie_cfg.num_rc = cfg.tl_slot_by_host.num();
        if (cfg.vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT ||
            cfg.pcie_cfg.if_mode != SV_IF_MODE || !cfg.pcie_cfg.infinite_credit ||
            cfg.pcie_cfg.rc_is_active != UVM_ACTIVE || cfg.pcie_cfg.ep_auto_response ||
            !cfg.pcie_cfg.use_unified_mem)
            `uvm_fatal("PROJECT_INTEL", "Intel requires REAL_DUT, SV_IF_MODE, active RC, unified memory and infinite public FC")
        cfg.pcie_cfg.ep_agent_enable = 0;
        cfg.pcie_cfg.num_ep = 0;
        if (cfg.pcie_cfg.ep_root_by_index.num() != 0)
            `uvm_fatal("PROJECT_INTEL", "real EP DUT must not have VIP EP-to-Root bindings")
        foreach (cfg.tl_slot_by_host[h]) begin
            int unsigned		slot;
            host_mem_manager	manager;

            slot = cfg.tl_slot_by_host[h];
            manager = shared_pool.get_host(h);
            if (cfg.pcie_cfg.host_mem_by_root.exists(slot)) begin
                if (cfg.pcie_cfg.host_mem_by_root[slot] != manager ||
                    !cfg.pcie_cfg.host_id_by_root.exists(slot) ||
                    cfg.pcie_cfg.host_id_by_root[slot] != h)
                    `uvm_fatal("PROJECT_ENV", "PCIe Host memory binding disagrees with DPU owner")
            end else if (!cfg.pcie_cfg.bind_host_memory(slot, h, manager, why))
                `uvm_fatal("PROJECT_ENV", why)
        end
        if (cfg.pcie_cfg.host_mem_by_root.num() != cfg.tl_slot_by_host.num())
            `uvm_fatal("PROJECT_ENV", "extra PCIe Root bindings are not part of this project")
    endfunction

    // 在 pcie_env::create 前解析每个端口的配置和 VIF：cfg 显式句柄与 wrapper 发布值
    // 必须相同；只缺配置时可创建 HARD_IP 默认对象，缺 HDL 接口则不能自动补造。
    // 复用 wrapper 对象以保留端口压力/信用设置，拒绝跨端口共享可变 cfg 或物理 VIF。
    protected function void prepare_intel_bindings();
        intel_pcie_adapter_config	used_cfgs[$];
        intel_pcie_vif_t			used_vifs[$];

        foreach (cfg.tl_slot_by_host[h]) begin
            int unsigned			slot;
            string				path;
            intel_pcie_adapter_config	port_cfg;
            intel_pcie_adapter_config	published_cfg;
            intel_pcie_vif_t			vif;
            intel_pcie_vif_t			published_vif;

            slot = cfg.tl_slot_by_host[h];
            path = $sformatf("pcie_env.rc_adapter_%0d", slot);
            port_cfg = null;
            published_cfg = null;
            vif = null;
            published_vif = null;
            if (cfg.intel_cfg_by_slot.exists(slot)) begin
                port_cfg = cfg.intel_cfg_by_slot[slot];
                if (port_cfg == null) `uvm_fatal("PROJECT_INTEL", "explicit Intel cfg is null")
            end
            if (uvm_config_db#(intel_pcie_adapter_config)::get(this, path, "intel_cfg", published_cfg)) begin
                if (published_cfg == null || (port_cfg != null && port_cfg != published_cfg))
                    `uvm_fatal("PROJECT_INTEL", "project and wrapper publish different Intel cfg handles")
                port_cfg = published_cfg;
            end
            if (port_cfg == null) begin
                port_cfg = intel_pcie_adapter_config::type_id::create($sformatf("intel_cfg_%0d", slot));
                port_cfg.side = INTEL_PCIE_HARD_IP;
            end
            if (port_cfg.side != INTEL_PCIE_HARD_IP)
                `uvm_fatal("PROJECT_INTEL", "EP application DUT requires explicit INTEL_PCIE_HARD_IP side")
            port_cfg.validate();

            if (cfg.intel_rc_vifs.exists(slot)) begin
                vif = cfg.intel_rc_vifs[slot];
                if (vif == null) `uvm_fatal("PROJECT_INTEL", "explicit Intel VIF is null")
            end
            if (uvm_config_db#(intel_pcie_vif_t)::get(this, path, "vif", published_vif)) begin
                if (published_vif == null || (vif != null && vif != published_vif))
                    `uvm_fatal("PROJECT_INTEL", "project and wrapper publish different Intel VIFs")
                vif = published_vif;
            end
            if (vif == null)
                `uvm_fatal("PROJECT_INTEL", $sformatf("missing Intel VIF at %s.%s", get_full_name(), path))
            foreach (used_cfgs[i]) begin
                if (used_cfgs[i] == port_cfg || used_vifs[i] == vif)
                    `uvm_fatal("PROJECT_INTEL", "Intel cfg or VIF reused by distinct TL slots")
            end
            used_cfgs.push_back(port_cfg);
            used_vifs.push_back(vif);
            cfg.intel_cfg_by_slot[slot] = port_cfg;
            cfg.intel_rc_vifs[slot] = vif;
            uvm_config_db#(intel_pcie_adapter_config)::set(this, path, "intel_cfg", port_cfg);
            uvm_config_db#(intel_pcie_vif_t)::set(this, path, "vif", vif);
        end
        if (cfg.intel_cfg_by_slot.num() != cfg.tl_slot_by_host.num() ||
            cfg.intel_rc_vifs.num() != cfg.tl_slot_by_host.num())
            `uvm_fatal("PROJECT_INTEL", "Intel bindings contain an unused TL slot")
    endfunction

    // connect 时只校验实际创建的 adapter，不再补绑接口；否则 adapter build 早已失败。
    // 确认 instance override 和 bridge 生效，防止接口配置看似存在却仍走公共 TLM 回环。
    protected function void check_intel_bindings();
        if (!pcie_env.bridge_required || pcie_env.ep_agent != null ||
            pcie_env.ep_agents.size() != 0 || pcie_env.ep_adapter != null ||
            pcie_env.ep_adapters.size() != 0)
            `uvm_fatal("PROJECT_INTEL", "Intel needs the external-pin bridge and RC-only component tree")
        foreach (cfg.intel_cfg_by_slot[slot]) begin
            intel_pcie_if_adapter	adapter;

            if (slot >= pcie_env.rc_adapters.size())
                `uvm_fatal("PROJECT_INTEL", "Intel RC adapter slot is missing")
            if (!$cast(adapter, pcie_env.rc_adapters[slot]) || adapter == null)
                `uvm_fatal("PROJECT_INTEL", "Intel instance factory override did not take effect")
            if (adapter.cfg != cfg.intel_cfg_by_slot[slot] ||
                adapter.avst_vif != cfg.intel_rc_vifs[slot])
                `uvm_fatal("PROJECT_INTEL", "Intel adapter consumed different cfg/VIF handles")
        end
    endfunction

    // 这里只创建组件和发布输入，不提前查询 DPU snapshot，也不手动调用子组件 build。
    // create(..., dpu_env) 让 VIO 位于 DPU 子树；框架先 build DPU，再 build VIO。
    // PCIe 只需要 Host 内存和 TL cfg，可以与 DPU 同级，不依赖二者遍历先后顺序。
    virtual function void build_phase(uvm_phase	phase);
        dpu_pcie_reg_executor		executor;

        super.build_phase(phase);
        if (!uvm_config_db#(project_env_cfg)::get(this, "", "cfg", cfg) || cfg == null)
            `uvm_fatal("PROJECT_ENV", "project environment cfg is missing")
        cfg.load_params();
        prepare_host_memory();
        prepare_pcie_config();

        if (cfg.dpu_cfg.executor == null) begin
            reg_backend = pcie_tl_dpu_reg_backend::type_id::create("reg_backend");
            executor = dpu_pcie_reg_executor::type_id::create("reg_executor");
            executor.set_backend(reg_backend);
            cfg.dpu_cfg.executor = executor;
        end
        uvm_config_db#(dpu_device_env_config)::set(this, "dpu_env", "cfg", cfg.dpu_cfg);
        dpu_env = dpu_device_env::type_id::create("dpu_env", this);

        prepare_intel_bindings();
        // bridge 的历史字段名含 svt，但这里只开启外部引脚传输，不创建 SVT/provider。
        intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env");
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        foreach (cfg.vio_cfg_by_host[h]) begin
            string	child_name;

            child_name = $sformatf("vio_h%0d", h);
            uvm_config_db#(virtio_net_env_config)::set(
                dpu_env, child_name, "cfg", cfg.vio_cfg_by_host[h]);
            vio_envs[h] = virtio_net_env::type_id::create(child_name, dpu_env);
        end
    endfunction

    // 全项目统一分配协议 VIF；显式身份映射优先，兼容 top 的全局 VIF slot 入口。
    // 在 Function 绑定 PCIe 前拒绝空接口和跨 Host/Function 复用，不依赖各 Host 局部计数。
    protected function void bind_protocol_vifs();
        virtual virtio_protocol_event_if	used[$];
        virtual virtio_protocol_event_if	vif;
        int unsigned				slot;
        string					why;

        slot = 0;
        foreach (vio_envs[h]) begin
            foreach (vio_envs[h].function_instances[i]) begin
                virtio_function_instance	f;

                f = vio_envs[h].function_instances[i];
                if (!cfg.vio_cfg_by_host[h].get_protocol_event_vif(f.pcie_id, vif)) begin
                    if (cfg.protocol_vifs.size() != 0) begin
                        if (slot >= cfg.protocol_vifs.size())
                            `uvm_fatal("PROJECT_ENV", "protocol VIF pool is too small")
                        vif = cfg.protocol_vifs[slot];
                    end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                            null, "uvm_test_top", $sformatf("protocol_event_vif_%0d", slot), vif))
                        `uvm_fatal("PROJECT_ENV", "global protocol VIF slot is missing")
                    if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why))
                        `uvm_fatal("PROJECT_ENV", why)
                end
                if (vif == null) `uvm_fatal("PROJECT_ENV", "protocol VIF is null")
                foreach (used[j]) begin
                    if (used[j] == vif)
                        `uvm_fatal("PROJECT_ENV", "protocol VIF reused by distinct Functions/Hosts")
                end
                used.push_back(vif);
                slot++;
            end
        end
    endfunction

    // connect 自底向上运行，此时 DPU 快照和 PCIe/VIO 子组件均已完成 build/connect。
    // 从 Function 的完整身份选择 Host 对应的 TL slot；BDF/BAR 不在 PCIe 中重新分配。
    virtual function void connect_phase(uvm_phase	phase);
        super.connect_phase(phase);
        if (pcie_env.global_cfg != null || pcie_env.topology_adapter != null ||
            pcie_env.backend_provider_active || pcie_env.cfg != cfg.pcie_cfg)
            `uvm_fatal("PROJECT_ENV", "Intel project requires the direct PCIe cfg-only path")
        check_intel_bindings();
        bind_protocol_vifs();
        if (reg_backend != null) begin
            reg_backend.bind_virtual_sequencer(pcie_env.v_seqr);
            foreach (cfg.tl_slot_by_host[h])
                reg_backend.bind_domain_root(h, 0, cfg.tl_slot_by_host[h]);
        end
        foreach (vio_envs[h]) begin
            virtio_pcie_function_endpoint	endpoints[$];
            int unsigned				slot;

            slot = cfg.tl_slot_by_host[h];
            if (slot >= pcie_env.rc_agents.size() || pcie_env.rc_agents[slot] == null)
                `uvm_fatal("PROJECT_ENV", "Host has no native RC agent")
            foreach (vio_envs[h].function_instances[i]) begin
                virtio_function_instance		f;
                virtio_pcie_function_endpoint	endpoint;

                f = vio_envs[h].function_instances[i];
                if (f.pcie_id.domain.host_id != h || f.pcie_id.domain.segment_id != 0)
                    `uvm_fatal("PROJECT_ENV", "Function does not belong to its Host segment 0")
                endpoint = virtio_pcie_function_endpoint::type_id::create(
                    $sformatf("endpoint_h%0d_f%0d", h, i));
                // Completion 由 PCIe RC driver 接收；无模型 completion adapter 或 EP monitor。
                // 同 Host 的所有 Function 共用该 RC，完整身份仍由 endpoint 保留。
                endpoint.configure(f.pcie_id, pcie_env.rc_agents[slot].sequencer,
                    pcie_env.rc_agents[slot].rc_driver, null,
                    pcie_env.rc_agents[slot].monitor, null);
                endpoints.push_back(endpoint);
            end
            if (!vio_envs[h].bind_pcie_endpoints(endpoints))
                `uvm_fatal("PROJECT_ENV", "VIO endpoint binding failed")
        end
    endfunction

    // 平台确认复位、TL 接口和 DMA 服务就绪后调用；计划包含 bootstrap，不能重复配置。
    // 状态管理和执行报告全部委托已创建的 dpu_env，不在项目层复制另一份执行状态。
    task configure_device();
        dpu_reg_plan		plan;
        dpu_execution_report	report;
        string			why;

        if (!dpu_env.build_vio_register_plan(plan, why)) `uvm_fatal("PROJECT_ENV", why)
        dpu_env.apply_vio_register_plan(plan, report);
        if (report == null) `uvm_fatal("PROJECT_ENV", "DPU returned no execution report")
        if (report.status() != DPU_CFG_STATUS_SUCCEEDED)
            `uvm_fatal("PROJECT_ENV", report.reason())
    endtask

    // 每个仿真调用一次：按完整 service 身份登记各 Host，再注册已有 Tcl 命令。
    // 空 Host 可跳过；全局没有 VIO service 或重复注册属于接入错误。
    function void register_aip_commands();
        int unsigned	active_hosts;
        string		why;

        active_hosts = 0;
        foreach (vio_envs[h]) begin
            if (vio_envs[h].function_instances.size() == 0) continue;
            if (!virtio_aip_registry::bind_env(vio_envs[h], why))
                `uvm_fatal("PROJECT_ENV", why)
            active_hosts++;
        end
        if (active_hosts == 0) `uvm_fatal("PROJECT_ENV", "no VIO service available for AIP")
        if (!virtio_aip_registry::register_commands(why)) `uvm_fatal("PROJECT_ENV", why)
    endfunction
endclass
```

## test 的最少接入顺序：project_base_test.sv

这是可选的虚基类参考。已有 test 直接移植 build/run 中的操作，并用现有平台代码实现三个 hook；无需改变 test 的继承关系。

[源文件](../integration/project/project_base_test.sv)

```systemverilog
// integration/project：可继承的 AIP base_test，由 project_env_pkg 最后包含。
// 依赖本目录 env/cfg 与 AIP bridge；基类拥有 objection 和统一配置/命令入口。
// 不知道平台的 reset/TL 接口/DMA/业务完成信号，故将这三处保留为强制实现的接口，
// 防止空 hook 假装平台已准备好。派生 test 用 factory 注册，本虚类不注册 factory。
virtual class project_base_test extends uvm_test;
    project_env_cfg	cfg;
    project_env		env;

    // 构造 test 壳；构建参数由 cfg.load_params 负责，无需在 new 重复逐项赋值。
    function new(string	name, uvm_component	parent);
        super.new(name, parent);
    endfunction

    // 在 cfg 加载后、env 构建前注入平台 pool/IOMMU/VIF 等句柄。
    // cfg 若已由 top 完整注入，派生类可显式提供空实现；此 hook 不重新 load_params。
    pure virtual function void bind_platform_handles();

    // 等待真实复位/Intel 接口就绪，准备 requester-aware DMA 和平台网络检查器。
    // 必须有平台自己的超时及错误处理；返回即授权后续 DPU 寄存器计划访问设备。
    pure virtual task prepare_platform();

    // Tcl 退出后等待业务完成并检查数据、DMA、PCIe/协议监测与资源回收。
    // vio_tx 返回只表示提交，不能仅凭 AIP run_loop 退出认定业务测试通过。
    pure virtual task finish_platform();

    // 支持 top 提供预建 cfg 或使用 factory；单一参数入口后只下发同一 cfg 句柄。
    virtual function void build_phase(uvm_phase	phase);
        super.build_phase(phase);
        if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg))
            cfg = project_env_cfg::type_id::create("cfg");
        if (cfg == null) `uvm_fatal("PROJECT_TEST", "project_cfg is null")
        cfg.load_params();
        bind_platform_handles();
        uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
        env = project_env::type_id::create("env", this);
    endfunction

    // 唯一运行顺序：平台就绪→DPU 配置→注册 seq 命令→Tcl→业务收尾。
    // 运行期 Tcl 只能改变下一条命令采样的参数，不能改写已冻结拓扑。
    virtual task run_phase(uvm_phase	phase);
        phase.raise_objection(this);
        prepare_platform();
        env.configure_device();
        env.register_aip_commands();
        aip_tcl_bridge::run_loop();
        finish_platform();
        phase.drop_objection(this);
    endtask
endclass
```

## package 依赖与包含顺序：project_env_pkg.sv


[源文件](../integration/project/project_env_pkg.sv)

```systemverilog
// integration/project：项目参考组装的唯一 package 编译入口。
// 顺序：AIP→DPU/Host memory/PCIe TL/VIO→AIP glue→本包。
// 固定 Intel 接入；Intel interface/adapter package 必须在本包之前编译。
// include 的普通 .sv 不可另行编译；本包只定义类型，不创建组件或取得外部资源。
package project_env_pkg;
    timeunit 1ns;
    timeprecision 1ps;

    import uvm_pkg::*;
    import aip_core_pkg::*;
    import host_mem_pkg::*;
    import dpu_resource_pkg::*;
    import pcie_tl_pkg::*;
    import virtio_net_pkg::*;
    import virtio_aip_pkg::*;
    import intel_pcie_adapter_pkg::*;
    `include "uvm_macros.svh"

    `include "project_env_cfg.sv"
    `include "project_env.sv"
    `include "project_base_test.sv"
endpackage
```

## 独立编译入口：project_integration.f

设置 `INTEL_PCIE_ROOT`，本入口直接编译 Intel interface 和 adapter。
默认几何为 4×256 bit；如果 DUT 使用其他几何，须使各编译单元的参数宏保持一致。
使用 bind 时，在自己的工程 filelist 中继续添加
`$INTEL_PCIE_ROOT/bind/intel_pcie_bind_wrapper.sv` 和项目 bind 文件，
不要重复添加 Intel 的整份公共库 filelist。

[源文件](../filelists/project_integration.f)

```text
// Intel HARD_IP + 真实 EP 应用 DUT 的唯一项目参考入口；从 virtio_work 根运行。
// 依赖根由调用方提供；Intel interface、adapter 和 DUT 的接口几何必须一致。
// 已有统一工程 filelist 时，按此顺序增补缺失包，禁止把已有包再次编译。
-f filelists/aip_integration.f
+incdir+$INTEL_PCIE_ROOT/src
$INTEL_PCIE_ROOT/src/interface/intel_pcie_if.sv
$INTEL_PCIE_ROOT/src/adapter/intel_pcie_adapter_pkg.sv
+incdir+integration/project
integration/project/project_env_pkg.sv
```

## 句柄注入与参数时机

`project_base_test.build_phase()` 在加载参数后调用 `bind_platform_handles()`。
使用 bind wrapper 时，由 wrapper 提前发布到实际 adapter 路径，env 直接复用，
不需要再填充 `cfg.intel_rc_vifs[slot]`、`cfg.intel_cfg_by_slot[slot]`；平台若直接持有
Intel interface，也可以在该 hook 中注入这两类句柄。两种方式均需给每个
活动 Function 分配独立的 `cfg.protocol_vifs`。也可沿用 top 的
`protocol_event_vif_N` 注册入口。已有 Host pool 放在 `cfg.host_mem_pool_binding`，
已有 IOMMU 放在 `cfg.vio_cfg_by_host[h].iommu_binding`。
这些是对象句柄，不能通过 plusarg 创建 interface 或替代 HDL 连线。

单 Host 默认 slot 为 0，只 bind 一个 wrapper。多 Host 用 `tl_slot_by_host` 指定接口组，
每个实际物理端口各 bind 一个 wrapper、各用独立 `rc_adapter_N` 路径；同 Host 的
PF/VF 共用该端口。`+dpu.hosts` 不会生成 HDL bind，扩展前需添加真实端口的 bind 并重新编译。
完整单/多 Host 示例见 [bind 接入说明](../integration/project/README.md#从一个-host-扩展到多个-host)。
真实输入、接口和注入时机可对照
[smoke test](../integration/project/tests/project_env_smoke_test.sv)；其
[top](../integration/project/tests/project_env_tb.sv) 仅提供空闲接口，不能代替 DUT top。

例如启动参数：

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=0
+vio.pairs=1 +vio.queue_size=512
+pcie_cfg.init_ph_credit=23 +pcie_cfg.cpl_timeout_ns=200000
```

默认 PF 服务进入 AIP 后：

```tcl
set_param vio.target h0.pf0.i0
set_param vio.tx.kind ETH_IPV4_UDP
set_param vio.tx.len 128
vio_init
vio_start
vio_tx count=100
```

DPU 寄存器计划访问 DUT，应等复位/TL/DMA 服务就绪后执行。
计划已含 bootstrap，不要另行先执行 bootstrap。运行期 `set_param` 不会重建被冻结的
Host/PF/BDF/BAR 或 PCIe 环境；它只影响后续会再次采样对应参数的 sequence。
报文提交后的真正完成检查由项目 test 负责。

## 与当前库接口的对应

[VIO cfg](../virtio_net_vip/src/env/virtio_net_env_config.sv) 已提供 `iommu_binding` 和
`bind_protocol_event_vif/get_protocol_event_vif/has_protocol_event_bindings`；
[VIO env](../virtio_net_vip/src/env/virtio_net_env.sv) 消费这些接口。
外部 IOMMU 只校验不重建，协议 VIF 按完整 Function 身份绑定。
拷到旧版 VIO 工程时，需要同时确认这些接口已经同步。

Intel cfg 暂无 `load_params()`，使用其原有 SV 字段设置 AVST credits/parity/gap。
公共 `pcie_cfg.*` 参数继续加载，但 `infinite_credit` 必须为 1。
Intel RX 的 BAR/PF/VF sideband 来自 `tlp.cq_route`；此组合层不会自动从 snapshot
补齐它。bridge 已提供 RC 请求派发，不要重复开启 VIO Host-memory responder。

该参考依赖平台已有的 requester-aware DMA 路由和硬件数据面配置。
它不新增 Virtio 设备模型，也不补齐额外 VTX/VRX/QSCH 配置。
验证范围和结果见 [集成说明](../integration/project/README.md)。

报错 `virtio_aip_pkg.sv` 找不到 `get_all_trailers_length` 时，见
[net_packet 依赖排查](aip_parameters.md#virtio_aip_pkgsv-找不到-get_all_trailers_length)。
正确调用是 `packet_handle.pkt.get_all_trailers_length()`；需要含 RoCEv2 trailer
支持的 net_packet main，并确保实际编译了对应 package。
