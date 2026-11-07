// integration/project：逻辑 BAR 到冻结 DPU 租约与 Intel 路由的唯一投影层。
// 依赖 dpu_resource_pkg/pcie_tl_pkg；借用不可变 snapshot，不分配资源或访问 DUT。
// registry 从 initialize、显式绑定到 freeze 单向演进；新代使用新对象，旧引用不能混用。
// target 描述访问窗口，绝不推导待配置表项的 owner；调用方分别保存两种身份。
typedef struct {
    dpu_function_key_t		function_key;
    dpu_pcie_function_id_t	pcie_id;
    int unsigned			global_function_id;
    dpu_bar_pair_lease_t	bar_lease;
    int unsigned			rc_slot;
    string					canonical_name;
    dpu_device_snapshot		snapshot;
    longint unsigned		snapshot_generation;
    pcie_tl_cq_route_t		route;
} project_bar_target_t;

// 平台 requester 编码可不同于快照 BDF；显式记录可避免 EP/SW 模式推断。
typedef struct {
    dpu_function_key_t	function_key;
    int unsigned		pf_index;
    int					vf_index;
    bit [15:0]			requester_id;
} project_intel_function_route_t;

// 先收集绑定，再冻结可查询的值副本；缺 Intel 绑定可打印，但不可作为发送目标。
class project_bar_registry extends uvm_object;
    `uvm_object_utils(project_bar_registry)
    protected dpu_device_snapshot				m_snapshot;
    protected longint unsigned					m_generation;
    protected bit								m_frozen;
    protected int unsigned						m_slot_by_host[int unsigned];
    protected project_intel_function_route_t	m_routes[string];
    protected project_bar_target_t				m_targets[$];
    protected static bit						m_auto_printed[string];

    // 创建空对象；调用 initialize 前任何查询/绑定都失败。
    extern function	new(
        string	name = "project_bar_registry"
    );

    // 借用冻结快照，generation 由发布方提供且非零；禁止二次初始化。
    extern function bit	initialize(
        dpu_device_snapshot	snapshot,
        longint unsigned	generation,
        output string		why
    );

    // Host 与 RC slot 一一对应；重复/未知 Host 或冻结后修改均失败。
    extern function bit	bind_host(
        int unsigned	host_id,
        int unsigned	rc_slot,
        output string	why
    );

    // 显式绑定 Intel 3 位 PF/11 位 VF 与 DMA requester；PF 的 vf_index 必须为 -1。
    extern function bit	bind_function(
        dpu_function_key_t	key,
        int unsigned		pf_index,
        int					vf_index,
        bit [15:0]			requester_id,
        output string		why
    );

    // 检查所有 Host 路由和实际 BAR，冻结内部投影；不要求未使用 Function 已绑 Intel。
    extern function bit	freeze(
        output string	why
    );

    // 判断生命周期；不给调用方可写内部容器。
    extern function bit	is_frozen();

    // 验证指定 Host/segment 的 RC slot；segment 当前只接受 0。
    extern function bit	get_slot(
        int unsigned		host_id,
        int unsigned		segment_id,
        output int unsigned	rc_slot,
        output string		why
    );

    // 严格完整解析名字；显式前缀与访问上下文冲突时报错，无上下文只允许唯一 Host。
    extern function bit	resolve_name(
        string						name,
        output project_bar_target_t	target,
        output string				why,
        input bit					has_access_host = 0,
        input int unsigned			access_host = 0
    );

    // 使用完整 Function 和实际偶数 BAR ID 查询，绝不把 ID 当成 role。
    extern function bit	resolve_function(
        dpu_function_key_t			key,
        int unsigned				bar_id,
        output project_bar_target_t	target,
        output string				why
    );

    // 高级调试只接受真实 base，域内须唯一；BAR 内部地址不是 base。
    extern function bit	resolve_base(
        int unsigned				host_id,
        int unsigned				segment_id,
        bit [63:0]					base,
        output project_bar_target_t	target,
        output string				why
    );

    // 校验引用身份及内容后以 65 位检查完整区间；失败地址清零，width 不可为零。
    extern function bit	check_range(
        project_bar_target_t	target,
        bit [63:0]				byte_offset,
        bit [63:0]				width_bytes,
        output bit [63:0]		address,
        output string			why
    );

    // Memory 使用实际窗口和整个字节跨度；不读取或改变 requester 身份。
    extern function bit	route_memory(
        int unsigned				host_id,
        int unsigned				segment_id,
        bit [63:0]					address,
        bit [63:0]					width_bytes,
        output pcie_tl_cq_route_t	route,
        output string				why
    );

    // Completion 反查原 Requester ID，完全独立于 Memory 地址和 BAR 归属。
    extern function bit	route_completion(
        int unsigned				host_id,
        int unsigned				segment_id,
        bit [15:0]					requester_id,
        output pcie_tl_cq_route_t	route,
        output string				why
    );

    // 输出稳定排序的真实租约；自动模式按快照身份与代号去重，手工模式可重复。
    extern function bit	print_bar_map(
        output string	why,
        input bit	automatic_print = 0
    );

    // 统一状态门；只在未冻结的已初始化对象上允许构建操作。
    extern protected function bit	mutable(
        output string	why
    );

    // 严格消费文字 token；失败时不推进 cursor。
    extern protected function bit	consume(
        string				name,
        string				token,
        ref int unsigned	cursor
    );

    // 逐字符十进制累积，提前检查 uint 溢出，至少要求一位数字。
    extern protected function bit	decimal(
        string				name,
        ref int unsigned	cursor,
        output int unsigned	value
    );
endclass

// 创建空对象；调用 initialize 前任何查询/绑定都失败。
function	project_bar_registry::new(
    string	name = "project_bar_registry"
);
    super.new(name);
endfunction

// 统一状态门；只在未冻结的已初始化对象上允许构建操作。
function bit	project_bar_registry::mutable(
    output string	why
);
    why = "";

    if (m_snapshot == null || m_frozen) begin
        why = "BAR registry is uninitialized or frozen";
        return 0;
    end
    return 1;
endfunction

// 借用冻结快照，generation 由发布方提供且非零；禁止二次初始化。
function bit	project_bar_registry::initialize(
    dpu_device_snapshot	snapshot,
    longint unsigned	generation,
    output string		why
);
    why = "";

    if (m_snapshot != null || snapshot == null || generation == 0) begin
        why = "BAR registry requires a new instance, frozen snapshot and nonzero generation";
        return 0;
    end

    if (!snapshot.is_frozen()) begin
        why = "BAR registry snapshot is not frozen";
        return 0;
    end
    m_snapshot   = snapshot;
    m_generation = generation;
    return 1;
endfunction

// Host 与 RC slot 一一对应；重复/未知 Host 或冻结后修改均失败。
function bit	project_bar_registry::bind_host(
    int unsigned	host_id,
    int unsigned	rc_slot,
    output string	why
);
    dpu_host_info_t	hosts[$];
    bit				found;

    if (!mutable(why)) begin
        return 0;
    end
    m_snapshot.list_hosts(hosts);

    foreach (hosts[i]) begin
        if (hosts[i].host_id == host_id) begin
            found = 1;
        end
    end

    if (!found || m_slot_by_host.exists(host_id)) begin
        why = "unknown or duplicate Host binding";
        return 0;
    end

    foreach (m_slot_by_host[h]) begin
        if (m_slot_by_host[h] == rc_slot) begin
            why = "RC slot already belongs to another Host";
            return 0;
        end
    end
    m_slot_by_host[host_id] = rc_slot;
    return 1;
endfunction

// 显式绑定 Intel 3 位 PF/11 位 VF 与 DMA requester；PF 的 vf_index 必须为 -1。
function bit	project_bar_registry::bind_function(
    dpu_function_key_t	key,
    int unsigned		pf_index,
    int					vf_index,
    bit [15:0]			requester_id,
    output string		why
);
    dpu_pcie_function_id_t	id;
    string					key_name;

    if (!mutable(why)) begin
        return 0;
    end

    if (!m_snapshot.get_pcie_id(key, id, why)) begin
        return 0;
    end
    key_name = dpu_function_key_name(key);

    if (id.domain.segment_id != 0 || pf_index > 7 ||
        (key.kind == DPU_FUNCTION_PF && vf_index != -1) ||
        (key.kind == DPU_FUNCTION_VF && (vf_index < 0 || vf_index > 2047))) begin
        why = "Intel route exceeds PF/VF width or unsupported segment/kind";
        return 0;
    end

    if (m_routes.exists(key_name)) begin
        why = "duplicate Function route binding";
        return 0;
    end

    foreach (m_routes[k]) begin
        if (m_routes[k].function_key.host_id == key.host_id) begin
            if (m_routes[k].requester_id == requester_id ||
                (m_routes[k].pf_index == pf_index && m_routes[k].vf_index == vf_index)) begin
                why = "ambiguous Intel Function or requester binding in Host domain";
                return 0;
            end
        end
    end
    m_routes[key_name] = '{key, pf_index, vf_index, requester_id};
    return 1;
endfunction

// 检查所有 Host 路由和实际 BAR，冻结内部投影；不要求未使用 Function 已绑 Intel。
function bit	project_bar_registry::freeze(
    output string	why
);
    dpu_function_key_t		keys[$];
    project_bar_target_t	pending[$];
    dpu_host_info_t			hosts[$];

    if (!mutable(why)) begin
        return 0;
    end
    m_snapshot.list_hosts(hosts);

    foreach (hosts[i]) begin
        if (!m_slot_by_host.exists(hosts[i].host_id)) begin
            why = "snapshot Host has no RC binding";
            return 0;
        end
    end
    m_snapshot.list_functions(keys);

    foreach (keys[i]) begin
        dpu_bar_pair_lease_t	bars[$];
        dpu_pcie_function_id_t	id;
        int unsigned			global_id;
        string					key_name;

        if (!m_snapshot.get_pcie_id(keys[i], id, why) ||
            !m_snapshot.get_global_function_id(keys[i], global_id, why) ||
            !m_snapshot.list_bars(keys[i], bars, why)) begin
            return 0;
        end

        if (id.domain.segment_id != 0 || !m_slot_by_host.exists(keys[i].host_id)) begin
            why = "snapshot Function has unsupported segment or missing Host RC binding";
            return 0;
        end
        key_name = dpu_function_key_name(keys[i]);

        // DPU 的列表按 role 排序；这里按真实 BAR 编号排序，避免展示顺序暗示 role=id。
        bars.sort() with (item.even_bar_id);

        foreach (bars[b]) begin
            project_bar_target_t	target;

            if (bars[b].even_bar_id > 4 || bars[b].even_bar_id[0] || bars[b].size == 0) begin
                why = "invalid 64-bit BAR pair id or empty lease";
                return 0;
            end

            if (b > 0 && bars[b - 1].even_bar_id == bars[b].even_bar_id) begin
                why = "duplicate BAR id within Function";
                return 0;
            end
            target.function_key       = keys[i];
            target.pcie_id            = id;
            target.global_function_id = global_id;
            target.bar_lease          = bars[b];
            target.rc_slot            = m_slot_by_host[keys[i].host_id];
            target.canonical_name     = $sformatf("h%0d.pf%0d", keys[i].host_id, keys[i].pf_id);

            if (keys[i].kind == DPU_FUNCTION_VF) begin
                target.canonical_name = {target.canonical_name, $sformatf(".vf%0d", keys[i].vf_id)};
            end
            target.canonical_name      = {target.canonical_name, $sformatf(".bar%0d", bars[b].even_bar_id)};
            target.snapshot            = m_snapshot;
            target.snapshot_generation = m_generation;
            target.route               = pcie_tl_cq_route_default();
            target.route.target_bdf    = id.bdf;
            target.route.target_func   = id.bdf[7:0];
            target.route.bar_id        = 3'(bars[b].even_bar_id);
            target.route.bar_aperture  = 6'($clog2(bars[b].size));

            if (m_routes.exists(key_name)) begin
                target.route.valid    = 1;
                target.route.pf_index = int'(m_routes[key_name].pf_index);
                target.route.is_vf    = keys[i].kind == DPU_FUNCTION_VF;
                target.route.vf_index = m_routes[key_name].vf_index;
            end
            pending.push_back(target);
        end
    end
    m_targets = pending;
    m_frozen  = 1;
    why       = "";
    return 1;
endfunction

// 判断生命周期；不给调用方可写内部容器。
function bit	project_bar_registry::is_frozen();
    return m_frozen;
endfunction

// 验证指定 Host/segment 的 RC slot；segment 当前只接受 0。
function bit	project_bar_registry::get_slot(
    int unsigned		host_id,
    int unsigned		segment_id,
    output int unsigned	rc_slot,
    output string		why
);
    rc_slot = 0;
    why     = "";

    if (!m_frozen || segment_id != 0 || !m_slot_by_host.exists(host_id)) begin
        why = "BAR registry not ready or Host/segment route missing";
        return 0;
    end
    rc_slot = m_slot_by_host[host_id];
    return 1;
endfunction

// 严格消费文字 token；失败时不推进 cursor。
function bit	project_bar_registry::consume(
    string				name,
    string				token,
    ref int unsigned	cursor
);
    if (cursor + token.len() > name.len()) begin
        return 0;
    end

    for (int unsigned	i = 0; i < token.len(); i++) begin
        if (name.getc(cursor + i) != token.getc(i)) begin
            return 0;
        end
    end
    cursor += token.len();
    return 1;
endfunction

// 逐字符十进制累积，提前检查 uint 溢出，至少要求一位数字。
function bit	project_bar_registry::decimal(
    string				name,
    ref int unsigned	cursor,
    output int unsigned	value
);
    int unsigned	start;
    int unsigned	digit;

    start = cursor;
    value = 0;

    while (cursor < name.len() && name.getc(cursor) >= "0" && name.getc(cursor) <= "9") begin
        digit = name.getc(cursor) - "0";

        if (value > (32'hffffffff - digit) / 10) begin
            return 0;
        end
        value = value * 10 + digit;
        cursor++;
    end
    return cursor > start;
endfunction

// 严格完整解析名字；显式前缀与访问上下文冲突时报错，无上下文只允许唯一 Host。
function bit	project_bar_registry::resolve_name(
    string						name,
    output project_bar_target_t	target,
    output string				why,
    input bit					has_access_host = 0,
    input int unsigned			access_host = 0
);
    dpu_function_key_t	key;
    int unsigned		cursor;
    int unsigned		bar_id;
    int unsigned		unique_host;
    bit					explicit_host;

    target = '{function_key:'{0, 0, DPU_FUNCTION_PF, 0},
        bar_lease:'{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
        snapshot:null, canonical_name:"", default:0};
    key           = '{0, 0, DPU_FUNCTION_PF, 0};
    cursor        = 0;
    why           = {"invalid BAR target syntax: ", name};
    explicit_host = consume(name, "h", cursor);

    if (explicit_host) begin
        if (!decimal(name, cursor, key.host_id) || !consume(name, ".", cursor)) begin
            return 0;
        end

        if (has_access_host && key.host_id != access_host) begin
            why = "explicit target Host conflicts with access Host";
            return 0;
        end
    end

    if (!consume(name, "pf", cursor) || !decimal(name, cursor, key.pf_id)) begin
        return 0;
    end

    if (consume(name, ".vf", cursor)) begin
        key.kind = DPU_FUNCTION_VF;

        if (!decimal(name, cursor, key.vf_id)) begin
            return 0;
        end
    end

    if (!consume(name, ".bar", cursor) || !decimal(name, cursor, bar_id) || cursor != name.len()) begin
        return 0;
    end

    if (!explicit_host) begin
        if (has_access_host) begin
            key.host_id = access_host;
        end else if (m_slot_by_host.num() == 1) begin
            void'(m_slot_by_host.first(unique_host));
            key.host_id = unique_host;
        end else begin
            why = "short BAR target requires explicit access Host in multi-Host registry";
            return 0;
        end
    end
    return resolve_function(key, bar_id, target, why);
endfunction

// 使用完整 Function 和实际偶数 BAR ID 查询，绝不把 ID 当成 role。
function bit	project_bar_registry::resolve_function(
    dpu_function_key_t			key,
    int unsigned				bar_id,
    output project_bar_target_t	target,
    output string				why
);
    target = '{function_key:'{0, 0, DPU_FUNCTION_PF, 0},
        bar_lease:'{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
        snapshot:null, canonical_name:"", default:0};
    why    = "BAR registry not frozen, Function/BAR unknown, or Intel route unbound";

    if (!m_frozen) begin
        return 0;
    end

    foreach (m_targets[i]) begin
        if (dpu_same_function_key(m_targets[i].function_key, key) && m_targets[i].bar_lease.even_bar_id == bar_id) begin
            if (!m_targets[i].route.valid) begin
                return 0;
            end
            target = m_targets[i];
            why    = "";
            return 1;
        end
    end
    return 0;
endfunction

// 高级调试只接受真实 base，域内须唯一；BAR 内部地址不是 base。
function bit	project_bar_registry::resolve_base(
    int unsigned				host_id,
    int unsigned				segment_id,
    bit [63:0]					base,
    output project_bar_target_t	target,
    output string				why
);
    int unsigned	slot;
    int				match_index;

    target = '{function_key:'{0, 0, DPU_FUNCTION_PF, 0},
        bar_lease:'{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
        snapshot:null, canonical_name:"", default:0};

    if (!get_slot(host_id, segment_id, slot, why)) begin
        return 0;
    end
    match_index = -1;

    foreach (m_targets[i]) begin
        if (m_targets[i].function_key.host_id == host_id && m_targets[i].bar_lease.base == base) begin
            if (match_index >= 0) begin
                why = "ambiguous BAR base in domain";
                return 0;
            end
            match_index = i;
        end
    end

    if (match_index < 0) begin
        why = "address is not a registered BAR base";
        return 0;
    end
    return resolve_function(m_targets[match_index].function_key, m_targets[match_index].bar_lease.even_bar_id, target, why);
endfunction

// 校验引用身份及内容后以 65 位检查完整区间；失败地址清零，width 不可为零。
function bit	project_bar_registry::check_range(
    project_bar_target_t	target,
    bit [63:0]				byte_offset,
    bit [63:0]				width_bytes,
    output bit [63:0]		address,
    output string			why
);
    project_bar_target_t	current;
    bit [64:0]				last_offset;
    bit [64:0]				first_address;
    bit [64:0]				last_address;

    address = 0;
    why     = "stale BAR target snapshot or generation";

    if (!m_frozen || target.snapshot != m_snapshot || target.snapshot_generation != m_generation) begin
        return 0;
    end

    if (!resolve_function(target.function_key, target.bar_lease.even_bar_id, current, why)) begin
        return 0;
    end

    if (target.pcie_id != current.pcie_id || target.global_function_id != current.global_function_id ||
        target.bar_lease != current.bar_lease || target.rc_slot != current.rc_slot ||
        target.canonical_name != current.canonical_name || target.route != current.route) begin
        why = "BAR target contents differ from frozen registry";
        return 0;
    end

    if (width_bytes == 0) begin
        why = "BAR access has zero width";
        return 0;
    end
    last_offset   = {1'b0, byte_offset} + {1'b0, width_bytes} - 1;
    first_address = {1'b0, current.bar_lease.base} + {1'b0, byte_offset};
    last_address  = first_address + {1'b0, width_bytes} - 1;
    // 先限制 BAR 内偏移，避免两个 65 位和仍在极大无效输入下发生第二次进位。
    if (last_offset[64] || last_offset >= {1'b0, current.bar_lease.size} || first_address[64] || last_address[64]) begin
        why = "BAR access crosses lease boundary or overflows 64-bit address";
        return 0;
    end
    address = first_address[63:0];
    why     = "";
    return 1;
endfunction

// Memory 使用实际窗口和整个字节跨度；不读取或改变 requester 身份。
function bit	project_bar_registry::route_memory(
    int unsigned				host_id,
    int unsigned				segment_id,
    bit [63:0]					address,
    bit [63:0]					width_bytes,
    output pcie_tl_cq_route_t	route,
    output string				why
);
    int unsigned	slot;
    int				match_index;
    bit [63:0]		checked;

    route = pcie_tl_cq_route_default();

    if (!get_slot(host_id, segment_id, slot, why)) begin
        return 0;
    end
    match_index = -1;

    foreach (m_targets[i]) begin
        if (m_targets[i].function_key.host_id == host_id &&
            address >= m_targets[i].bar_lease.base && address - m_targets[i].bar_lease.base < m_targets[i].bar_lease.size) begin
            if (match_index >= 0) begin
                why = "ambiguous Memory address in Host domain";
                return 0;
            end
            match_index = i;
        end
    end

    if (match_index < 0) begin
        why = "Memory address has no registered BAR window";
        return 0;
    end

    if (!check_range(m_targets[match_index], address - m_targets[match_index].bar_lease.base, width_bytes, checked, why)) begin
        return 0;
    end
    route            = m_targets[match_index].route;
    route.bar_offset = address - m_targets[match_index].bar_lease.base;
    return 1;
endfunction

// Completion 反查原 Requester ID，完全独立于 Memory 地址和 BAR 归属。
function bit	project_bar_registry::route_completion(
    int unsigned				host_id,
    int unsigned				segment_id,
    bit [15:0]					requester_id,
    output pcie_tl_cq_route_t	route,
    output string				why
);
    int unsigned			slot;
    dpu_pcie_function_id_t	id;

    route = pcie_tl_cq_route_default();

    if (!get_slot(host_id, segment_id, slot, why)) begin
        return 0;
    end

    foreach (m_routes[k]) begin
        if (m_routes[k].function_key.host_id == host_id && m_routes[k].requester_id == requester_id) begin
            if (!m_snapshot.get_pcie_id(m_routes[k].function_key, id, why)) begin
                return 0;
            end
            route.valid       = 1;
            route.target_bdf  = id.bdf;
            route.target_func = id.bdf[7:0];
            route.pf_index    = int'(m_routes[k].pf_index);
            route.is_vf       = m_routes[k].function_key.kind == DPU_FUNCTION_VF;
            route.vf_index    = m_routes[k].vf_index;
            return 1;
        end
    end
    why = "Completion Requester ID has no explicit Intel Function mapping";
    return 0;
endfunction

// 输出稳定排序的真实租约；自动模式按快照身份与代号去重，手工模式可重复。
function bit	project_bar_registry::print_bar_map(
    output string	why,
    input bit	automatic_print = 0
);
    string	identity;

    why = "";

    if (!m_frozen) begin
        why = "BAR map is not ready for publication";
        return 0;
    end
    identity = $sformatf("%0d:%0d", m_snapshot.get_inst_id(), m_generation);

    if (automatic_print && m_auto_printed.exists(identity)) begin
        return 1;
    end
    `uvm_info("DPU_BAR_MAP", $sformatf("snapshot=%0d identity=%0d", m_generation, m_snapshot.get_inst_id()), UVM_LOW)

    foreach (m_targets[i]) begin
        string	binding;

        binding = m_targets[i].route.valid ? $sformatf("pf=%0d vf=%0d active=%0b", m_targets[i].route.pf_index,
            m_targets[i].route.vf_index, m_targets[i].route.is_vf) : "unbound";
        `uvm_info("DPU_BAR_MAP", $sformatf("target=%s snapshot=%0d host=%0d seg=%0d bdf=%04h gfid=%0d role=%s bar=%0d base=%016h size=%016h last=%016h rc=%0d intel_route=%s",
            m_targets[i].canonical_name, m_generation, m_targets[i].function_key.host_id, m_targets[i].pcie_id.domain.segment_id,
            m_targets[i].pcie_id.bdf, m_targets[i].global_function_id, m_targets[i].bar_lease.role.name(),
            m_targets[i].bar_lease.even_bar_id, m_targets[i].bar_lease.base, m_targets[i].bar_lease.size,
            m_targets[i].bar_lease.base + m_targets[i].bar_lease.size - 1, m_targets[i].rc_slot, binding), UVM_LOW)
    end

    if (automatic_print) begin
        m_auto_printed[identity] = 1;
    end
    return 1;
endfunction
