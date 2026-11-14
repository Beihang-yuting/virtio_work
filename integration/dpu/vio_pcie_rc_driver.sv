// integration/dpu：固定 Intel 接入的 RC 发送前路由桥，依赖冻结 BAR registry。
// 借用 registry；请求、Tag、Completion 生命周期继续由通用 RC driver 管理。
// env 应对 pcie_tl_rc_driver 安装实例 override，路径 pcie_env.rc_agent_<slot>.driver，
// 保留 agent 自己的 base_driver override 链；connect 阶段检查 cast 后安装冻结映射。
class vio_pcie_rc_driver extends pcie_tl_rc_driver;
	`uvm_component_utils(vio_pcie_rc_driver)
	protected dpu_pcie_bar_map	m_registry;
	protected int unsigned		m_host_id;
	protected int unsigned		m_segment_id;
	protected int unsigned		m_rc_slot;

	local dpu_msix_message_t	m_messages[$];

	local virtio_host_mem_view	m_proxies[bit [15:0]];
	local virtio_iommu_model	m_iommu;
	local host_mem_manager		m_backing;
	local bit					m_receive_installed;

    // 功能：登记某个冻结 Requester 的 VIO IOVA 视图，复用公共 RC 选择机制。
    // 输入输出及副作用：requester 经 registry 解析 BDF；why 输出配置错误，成功借用 backing/IOMMU。
    // 失败边界：接收路径未安装、Requester 未知或视图配置失败时拒绝，重复调用幂等。
    extern function bit install_vio_dma_view(bit [15:0] requester, output string why);

	// 整个 catalog 预检后一次冻结；消息 sink 与 DMA 都保留本 RC 的 Host 域。
	// 功能：安装本 Host 的 DMA backing、VIO IOMMU 和 MSI-X catalog。
	// 输入输出及副作用：backing/iommu 保存非拥有引用，messages 复制，why 输出拒绝原因。
	// 失败边界：重复安装、空 registry/backing/IOMMU、未初始化或 Host 不符、消息目录无效拒绝。
	extern function bit install_receive_path(
		input host_mem_manager		backing,
		input virtio_iommu_model	iommu,
		input dpu_msix_message_t	messages[$],
		output string				why
	);

	// 重载前纯校验新的MSI-X消息目录，保留Host域和既有DMA backing/IOMMU。
	// 功能：只读检查 MSI-X 消息目录的 Host、编码和唯一性。
	// 输入输出及副作用：messages 为候选目录；why 输出首项错误，不替换已发布目录。
	// 失败边界：registry 缺失、Host 不符、未知字段、未对齐地址或地址/data 重复拒绝。
	extern function bit validate_message_catalog(
		input dpu_msix_message_t	messages[$],
		output string				why
	);

	// 仅在项目确认无活动VIO代时更新消息识别；不重复安装路由或替换内存句柄。
	// 功能：停业务后替换 MSI-X 接收目录，保留 DMA 绑定。
	// 输入输出及副作用：messages 验证成功后复制到 m_messages；why 输出错误，无时间推进。
	// 失败边界：receive path 未安装或目录校验失败返回 0，原目录保留。
	extern function bit replace_message_catalog(
		input dpu_msix_message_t	messages[$],
		output string				why
	);

	// 只读检查完整 wire 请求；返回 sink 标志，不写 Host、不消耗 observer 的消息。
	// 功能：整笔校验 DMA 请求并识别归属正确的 MSI-X sink。
	// 输入输出及副作用：request 经冻结 Requester authority 校验；message_sink/why 输出结果，普通请求预检唯一 view。
	// 失败边界：未安装、类型/编码不符、payload 不符、空 BE、回绕/跨页、未知 Requester、无所有权/冲突/权限失败拒绝。
	extern function bit validate_receive(
		input pcie_tl_tlp	request,
		output bit			message_sink,
		output string		why
	);

	// bridge 仍是唯一 responder；父类按 requester 选择稳定的 DMA 视图。
	extern virtual task handle_request(pcie_tl_tlp req);

	// 只构造组件，不推断 Host 或默认 PF0 路由。
	// 功能：构造未绑定 registry/backing 的 RC 桥。
	// 输入输出及副作用：name/parent 传给父类；只初始化组件，不推断 Host 或 PF。
	// 失败边界：环境必须随后安装冻结 registry 和 receive path。
	extern function new(
		string			name = "vio_pcie_rc_driver",
		uvm_component	parent = null
	);

	// 显式注入已冻结 registry 与自身域/slot；已安装后只允许完全相同的重复注入，禁止静默更换活跃映射。
	// 功能：绑定冻结 BAR registry 及 RC 所在 Host/segment/slot。
	// 输入输出及副作用：registry 为非拥有引用；host_id/segment_id/rc_slot 校验后记录，why 返回拒绝原因。
	// 失败边界：空或未冻结 registry、slot 不符或替换已有不同绑定拒绝；同源重复安装幂等。
	extern function bit install_registry(
		dpu_pcie_bar_map	registry,
		int unsigned		host_id,
		int unsigned		segment_id,
		int unsigned		rc_slot,
		output string		why
	);

	// 唯一发送前判定入口；先核对实际 Type/Fmt 与地址编码，再路由；失败清空旧 route，保留身份和 Tag。
	// 功能：在发送前校验 Memory/Completion 编码并由冻结 registry 生成路由。
	// 输入输出及副作用：tlp 的 cq_route 先清空，成功写入新 route；why 输出错误，不分配 Tag。
	// 失败边界：空请求、无 registry、kind/type/fmt 不符、地址截断/回绕/跨 4KB、BAR 或 Requester 未命中、Config/其他类型拒绝。
	extern function bit route_tlp(
		pcie_tl_tlp		tlp,
		output string	why
	);

	// 先完成路由再进入父类；失败为明确 fatal 且立即返回，不分配 Tag、不发送观察/数据。
	// 功能：路由成功后复用父类发送和 Completion/Tag 生命周期。
	// 输入输出及副作用：tlp 经 route_tlp 写入路由后发送；失败报告 fatal。
	// 失败边界：路由失败立即返回，不触发父类发送或分配 Tag。
	extern virtual task send_tlp(pcie_tl_tlp tlp);
endclass

// 只构造组件，不推断 Host 或默认 PF0 路由。
// 功能：构造未绑定 registry/backing 的 RC 桥。
// 输入输出及副作用：name/parent 传给父类；只初始化组件，不推断 Host 或 PF。
// 失败边界：环境必须随后安装冻结 registry 和 receive path。
function vio_pcie_rc_driver::new(
	string			name = "vio_pcie_rc_driver",
	uvm_component	parent = null
);
	super.new(name, parent);
endfunction

// 显式注入已冻结 registry 与自身域/slot；已安装后只允许完全相同的重复注入，禁止静默更换活跃映射。
// 功能：绑定冻结 BAR registry 及 RC 所在 Host/segment/slot。
// 输入输出及副作用：registry 为非拥有引用；host_id/segment_id/rc_slot 校验后记录，why 返回拒绝原因。
// 失败边界：空或未冻结 registry、slot 不符或替换已有不同绑定拒绝；同源重复安装幂等。
function bit vio_pcie_rc_driver::install_registry(
	dpu_pcie_bar_map	registry,
	int unsigned		host_id,
	int unsigned		segment_id,
	int unsigned		rc_slot,
	output string		why
);
	int unsigned	bound_slot;

	why = "project RC requires a frozen registry";

	if (registry == null) begin
		return 0;
	end

	if (!registry.get_slot(host_id, segment_id, bound_slot, why)) begin
		return 0;
	end

	if (bound_slot != rc_slot) begin
		why = "project RC slot disagrees with registry Host binding";
		return 0;
	end

	if (m_registry != null && (m_registry != registry || m_host_id != host_id ||
		m_segment_id != segment_id || m_rc_slot != rc_slot)) begin
		why = "project RC registry binding is immutable after installation";
		return 0;
	end

	m_registry   = registry;
	m_host_id    = host_id;
	m_segment_id = segment_id;
	m_rc_slot    = rc_slot;
	why          = "";
	return 1;
endfunction

// 唯一发送前判定入口；先核对实际 Type/Fmt 与地址编码，再路由；失败清空旧 route，保留身份和 Tag。
// 功能：在发送前校验 Memory/Completion 编码并由冻结 registry 生成路由。
// 输入输出及副作用：tlp 的 cq_route 先清空，成功写入新 route；why 输出错误，不分配 Tag。
// 失败边界：空请求、无 registry、kind/type/fmt 不符、地址截断/回绕/跨 4KB、BAR 或 Requester 未命中、Config/其他类型拒绝。
function bit vio_pcie_rc_driver::route_tlp(
	pcie_tl_tlp		tlp,
	output string	why
);
	pcie_tl_mem_tlp		mem;
	pcie_tl_cpl_tlp		cpl;
	pcie_tl_cq_route_t	route;
	bit [64:0]			first_address;
	bit [64:0]			last_address;
	int					first_lane;
	int					last_lane;

	why = "project RC has no installed BAR registry or request is null";

	if (tlp == null) begin
		return 0;
	end
	tlp.cq_route = pcie_tl_cq_route_default();

	if (m_registry == null) begin
		return 0;
	end

	case (tlp.kind)
		TLP_MEM_RD, TLP_MEM_WR, TLP_MEM_RD_LK: begin
			if (!$cast(mem, tlp)) begin
				why = "Memory TLP kind/type mismatch";
				return 0;
			end
			// kind 是对象语义，codec 却直接写 type_f/fmt；普通赋值不会执行随机约束，
			// 必须在父类发送前核对，避免 Config 伪装或读写/锁定语义改变。
			if (mem.type_f != (mem.kind == TLP_MEM_RD_LK ? TLP_TYPE_MEM_RD_LK : TLP_TYPE_MEM_RD) ||
				(mem.kind == TLP_MEM_WR && !(mem.fmt inside {FMT_3DW_WITH_DATA, FMT_4DW_WITH_DATA})) ||
				(mem.kind != TLP_MEM_WR && !(mem.fmt inside {FMT_3DW_NO_DATA, FMT_4DW_NO_DATA}))) begin
				why = "Memory kind/Type/Fmt mismatch";
				return 0;
			end

			// 3DW 编码只携带低 32 位；不能用完整高地址通过 BAR 检查后再在线上截断。
			if ((mem.fmt inside {FMT_3DW_NO_DATA, FMT_3DW_WITH_DATA}) && mem.addr[63:32] != 0) begin
				why = "3DW Memory cannot encode a nonzero upper address";
				return 0;
			end

			first_lane = -1;
			last_lane  = -1;
			// BE 可能稀疏：检查首末使能字节之间的整个跨度，不仅检查起始地址。
			// wire DWORD 与 BAR 范围各自保留意义；不用 request.addr 低位替代 first_be。
			for (int	unsigned	i = 0; i < pcie_tl_mem_dw_count(mem) * 4; i++) begin
				if (pcie_tl_mem_lane_enabled(mem, i)) begin
					if (first_lane < 0) begin
						first_lane = int'(i);
					end
					last_lane = int'(i);
				end
			end

			if (first_lane < 0) begin
				why = "Memory request has no enabled bytes";
				return 0;
			end
			first_address = {1'b0, pcie_tl_mem_wire_addr(mem)} + 65'(first_lane);
			last_address  = {1'b0, pcie_tl_mem_wire_addr(mem)} + 65'(last_lane);

			if (first_address[64] || last_address[64] || first_address[63:12] != last_address[63:12]) begin
				why = "Memory request overflows address or crosses 4KB boundary";
				return 0;
			end

			if (!m_registry.route_memory(
					m_host_id,
					m_segment_id,
					first_address[63:0],
					64'(last_lane - first_lane + 1),
					route,
					why
				)) begin
				return 0;
			end
		end
		TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK: begin
			if (!$cast(cpl, tlp)) begin
				why = "Completion TLP kind/type mismatch";
				return 0;
			end

			// Completion 只有 3DW 形式；Type 的锁定位和 Fmt 的数据位须与 kind 同义。
			if (cpl.type_f != ((cpl.kind inside {TLP_CPL_LK, TLP_CPLD_LK}) ? TLP_TYPE_CPL_LK : TLP_TYPE_CPL) ||
				cpl.fmt != ((cpl.kind inside {TLP_CPLD, TLP_CPLD_LK}) ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA)) begin
				why = "Completion kind/Type/Fmt mismatch";
				return 0;
			end

			if (!m_registry.route_completion(m_host_id, m_segment_id, cpl.requester_id, route, why)) begin
				return 0;
			end
		end
		TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1: begin
			why = "Configuration TLP is prohibited by project external-device mode";
			return 0;
		end
		default: begin
			why = "project RC supports only Memory requests and Completions";
			return 0;
		end
	endcase
	tlp.cq_route = route;
	why          = "";
	return 1;
endfunction

// 先完成路由再进入父类；失败为明确 fatal 且立即返回，不分配 Tag、不发送观察/数据。
// 功能：路由成功后复用父类发送和 Completion/Tag 生命周期。
// 输入输出及副作用：tlp 经 route_tlp 写入路由后发送；失败报告 fatal。
// 失败边界：路由失败立即返回，不触发父类发送或分配 Tag。
task vio_pcie_rc_driver::send_tlp(pcie_tl_tlp tlp);
	string	why;

	if (!route_tlp(tlp, why)) begin
		`uvm_fatal("PROJECT_RC_ROUTE", why)
		return;
	end
	super.send_tlp(tlp);
endtask

// 公共消息项先完整预检，成功后借用 Host/IOMMU；不安装第二个 responder。
// 功能：安装本 Host 的 DMA backing、VIO IOMMU 和 MSI-X catalog。
// 输入输出及副作用：backing/iommu 保存非拥有引用，messages 复制，why 输出拒绝原因。
// 失败边界：重复安装、空 registry/backing/IOMMU、未初始化或 Host 不符、消息目录无效拒绝。
function bit vio_pcie_rc_driver::install_receive_path(
	input host_mem_manager		backing,
	input virtio_iommu_model	iommu,
	input dpu_msix_message_t	messages[$],
	output string				why
);
	why = "receive path needs registry, Host memory and IOMMU";
	if (m_receive_installed || m_registry == null || backing == null || iommu == null) return 0;
	if (!backing.is_initialized() || backing.get_host_id() != m_host_id) return 0;
	if (!validate_message_catalog(messages, why)) return 0;
	m_backing           = backing;
	m_iommu             = iommu;
	m_messages          = messages;
	m_receive_installed = 1;
	why                 = "";
	return 1;
endfunction

// 所有消息必须属于本RC的Host，地址对齐且无歧义；只读预检可在多Host提交前重复调用。
// 功能：只读检查 MSI-X 消息目录的 Host、编码和唯一性。
// 输入输出及副作用：messages 为候选目录；why 输出首项错误，不替换已发布目录。
// 失败边界：registry 缺失、Host 不符、未知字段、未对齐地址或地址/data 重复拒绝。
function bit vio_pcie_rc_driver::validate_message_catalog(
	input dpu_msix_message_t	messages[$],
	output string				why
);
	why = "message catalog requires installed registry";
	if (m_registry == null) return 0;
	foreach (messages[i]) begin
		if (messages[i].owner.host_id != m_host_id || $isunknown({messages[i].address, messages[i].data, messages[i].masked}) || messages[i].address[1:0] != 0) begin
			why = "message catalog has wrong Host, unknown data or unaligned address";
			return 0;
		end
		foreach (messages[j]) begin
			if (j < i && messages[i].address == messages[j].address && messages[i].data == messages[j].data) begin
				why = "message catalog contains duplicate/ambiguous receiver";
				return 0;
			end
		end
	end
	why = "";
	return 1;
endfunction

// 同步替换消息匹配表；调用方已停业务，本函数不推进时间且不改变RC路由和DMA资源。
// 功能：停业务后替换 MSI-X 接收目录，保留 DMA 绑定。
// 输入输出及副作用：messages 验证成功后复制到 m_messages；why 输出错误，无时间推进。
// 失败边界：receive path 未安装或目录校验失败返回 0，原目录保留。
function bit vio_pcie_rc_driver::replace_message_catalog(
	input dpu_msix_message_t	messages[$],
	output string				why
);
	if (!m_receive_installed) begin
		why = "receive path is not installed";
		return 0;
	end
	if (!validate_message_catalog(messages, why)) return 0;
	m_messages = messages;
	return 1;
endfunction

// 校验全部使能字节及权限，确保失败发生在首个 dirty write/Completion 之前。
// sink 只识别完整四字节消息；未知消息仍走严格 DMA，不能吞掉普通内存访问。
// 功能：整笔校验 DMA 请求并识别归属正确的 MSI-X sink。
// 输入输出及副作用：request 经冻结 Requester authority 校验；message_sink/why 输出结果，普通请求预检唯一 view。
// 失败边界：未安装、类型/编码不符、payload 不符、空 BE、回绕/跨页、未知 Requester、无所有权/冲突/权限失败拒绝。
function bit vio_pcie_rc_driver::validate_receive(
	input pcie_tl_tlp	request,
	output bit			message_sink,
	output string		why
);
	pcie_tl_mem_tlp			r;
	dpu_function_key_t		key;
	dpu_pcie_function_id_t	id;
	bit [64:0]				address;
	bit [31:0]				data;
	int unsigned			count;
	int						first_lane;
	int						last_lane;

	message_sink = 0;
	why          = "external RC accepts only valid Memory requests";
	if (!m_receive_installed || request == null) return 0;
	if (!$cast(r, request)) return 0;
	if (!(r.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR}) ||
		r.type_f != (r.kind == TLP_MEM_RD_LK ? TLP_TYPE_MEM_RD_LK : TLP_TYPE_MEM_RD) ||
		(r.kind == TLP_MEM_WR && !(r.fmt inside {FMT_3DW_WITH_DATA, FMT_4DW_WITH_DATA})) ||
		(r.kind != TLP_MEM_WR && !(r.fmt inside {FMT_3DW_NO_DATA, FMT_4DW_NO_DATA})) ||
		((r.fmt inside {FMT_3DW_NO_DATA, FMT_3DW_WITH_DATA}) && r.addr[63:32] != 0))
		return 0;
	count = pcie_tl_mem_dw_count(r) * 4;
	if (r.kind == TLP_MEM_WR && r.payload.size() != count) begin
		why = "DMA write payload length differs from wire length";
		return 0;
	end
	first_lane = -1;
	last_lane  = -1;
	for (int	unsigned	i = 0; i < count; i++) begin
		if (pcie_tl_mem_lane_enabled(r, i)) begin
			if (first_lane < 0) first_lane = i;
			last_lane = i;
		end
	end
	address = {1'b0, pcie_tl_mem_wire_addr(r)} + count - 1;
	if (first_lane < 0 || address[64] || address[63:12] != r.addr[63:12]) begin
		why = "DMA request has empty lanes, overflow or crosses 4KB";
		return 0;
	end
	if (!m_registry.resolve_requester(m_host_id, r.requester_id, key, id, why)) return 0;
	if (r.kind == TLP_MEM_WR && last_lane - first_lane == 3 && pcie_tl_mem_valid_bytes(r) == 4) begin
		data = '0;
		for (int	unsigned	i = 0; i < 4; i++) data[i*8+:8] = r.payload[first_lane+i];
		foreach (m_messages[i]) begin
			if (dpu_same_function_key(m_messages[i].owner, key) &&
                m_messages[i].address == pcie_tl_mem_wire_addr(r) + first_lane && m_messages[i].data == data) begin
				message_sink = 1;
				why          = "";
				return 1;
			end
		end
	end

    begin
        host_mem_api selected;
        if (!m_proxies.exists(r.requester_id) && !install_vio_dma_view(r.requester_id, why)) return 0;
        if (!select_dma_view(r, selected, why)) return 0;
    end
	why = "";
	return 1;
endfunction

// 功能：在公共 RC 中登记冻结 Requester 对应的 VIO 翻译视图。
// 输入输出及副作用：requester 解析为 Host/BDF，why 输出错误；仅首次创建非拥有 view。
// 失败边界：未安装接收路径、未知 Requester 或 configure/register 拒绝时返回 0。
function bit vio_pcie_rc_driver::install_vio_dma_view(bit [15:0] requester, output string why);
    dpu_function_key_t key;
    dpu_pcie_function_id_t id;
    why = "receive path is not installed";
    if (!m_receive_installed) return 0;
    if (!m_registry.resolve_requester(m_host_id, requester, key, id, why)) return 0;
    if (!m_proxies.exists(requester)) begin
        m_proxies[requester] = virtio_host_mem_view::type_id::create("requester_proxy");
        if (!m_proxies[requester].configure(m_backing, m_iommu, m_host_id, id.bdf, why)) begin
            m_proxies.delete(requester);
            return 0;
        end
    end
    return register_dma_view(requester, m_proxies[requester], why);
endfunction

// 功能：识别 MSI-X sink，普通 DMA 交由父类按 Requester 选择稳定视图。
// 输入输出及副作用：req 完整预检后可能更新 Host 或发送 Completion；不交换共享 mem 指针。
// 失败边界：预检失败在数据副作用前报告错误并返回；sink 不触碰 Host backing。
task vio_pcie_rc_driver::handle_request(pcie_tl_tlp req);
    bit message_sink;
    string why;
    if (!validate_receive(req, message_sink, why)) begin
        `uvm_error("PROJECT_RC_DMA", why)
        return;
    end
    if (message_sink) return;
    super.handle_request(req);
endtask
