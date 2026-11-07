// integration/project：固定 Intel 接入的 RC 发送前路由桥，依赖冻结 BAR registry。
// 借用 registry；请求、Tag、Completion 生命周期继续由通用 RC driver 管理。
// env 应对 pcie_tl_rc_driver 安装实例 override，路径 pcie_env.rc_agent_<slot>.driver，
// 保留 agent 自己的 base_driver override 链；connect 阶段检查 cast 后安装冻结映射。
class project_pcie_rc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(project_pcie_rc_driver)
    protected project_bar_registry	m_registry;
    protected int unsigned			m_host_id;
    protected int unsigned			m_segment_id;
    protected int unsigned			m_rc_slot;

    // 只构造组件，不推断 Host 或默认 PF0 路由。
    extern function	new(
        string			name = "project_pcie_rc_driver",
        uvm_component	parent = null
    );

    // 显式注入已冻结 registry 与自身域/slot；已安装后只允许完全相同的重复注入，禁止静默更换活跃映射。
    extern function bit	install_registry(
        project_bar_registry	registry,
        int unsigned			host_id,
        int unsigned			segment_id,
        int unsigned			rc_slot,
        output string			why
    );

    // 唯一发送前判定入口；成功只修改 cq_route，失败清空旧 route，保留 PCIe 身份和 Tag。
    extern function bit	route_tlp(
        pcie_tl_tlp		tlp,
        output string	why
    );

    // 先完成路由再进入父类；失败为明确 fatal 且立即返回，不分配 Tag、不发送观察/数据。
    extern virtual task	send_tlp(
        pcie_tl_tlp	tlp
    );
endclass

// 只构造组件，不推断 Host 或默认 PF0 路由。
function	project_pcie_rc_driver::new(
    string			name = "project_pcie_rc_driver",
    uvm_component	parent = null
);
    super.new(name, parent);
endfunction

// 显式注入已冻结 registry 与自身域/slot；已安装后只允许完全相同的重复注入，禁止静默更换活跃映射。
function bit	project_pcie_rc_driver::install_registry(
    project_bar_registry	registry,
    int unsigned			host_id,
    int unsigned			segment_id,
    int unsigned			rc_slot,
    output string			why
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

// 唯一发送前判定入口；成功只修改 cq_route，失败清空旧 route，保留 PCIe 身份和 Tag。
function bit	project_pcie_rc_driver::route_tlp(
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
            first_lane = -1;
            last_lane  = -1;
            // BE 可能稀疏：检查首末使能字节之间的整个跨度，不仅检查起始地址。
            // wire DWORD 与 BAR 范围各自保留意义；不用 request.addr 低位替代 first_be。
            for (int unsigned	i = 0; i < pcie_tl_mem_dw_count(mem) * 4; i++) begin
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

            if (!m_registry.route_memory(m_host_id, m_segment_id, first_address[63:0],
                64'(last_lane - first_lane + 1), route, why)) begin
                return 0;
            end
        end
        TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK: begin
            if (!$cast(cpl, tlp)) begin
                why = "Completion TLP kind/type mismatch";
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
task	project_pcie_rc_driver::send_tlp(
    pcie_tl_tlp	tlp
);
    string	why;

    if (!route_tlp(tlp, why)) begin
        `uvm_fatal("PROJECT_RC_ROUTE", why)
        return;
    end
    super.send_tlp(tlp);
endtask
