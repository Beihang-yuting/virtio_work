`ifndef VIRTIO_PCIE_REAL_DUT_HOST_MEM_RESPONDER_SV
`define VIRTIO_PCIE_REAL_DUT_HOST_MEM_RESPONDER_SV

// 所属层次：virtio_work PCIe/REAL_DUT 适配层。
// 文件职责：把被动 RC monitor 观察到的真实 Endpoint→Root Complex Memory
//           Read/Write TLP 交给外部 pcie_work RC driver；driver 再通过已绑定的
//           host_mem_api 访问共享 Host memory，并为 Memory Read 发 Completion。
// 主要依赖：pcie_work 的 pcie_tl_base_monitor/pcie_tl_rc_driver、host_mem、
//           virtio_pcie_iova_host_mem_proxy 和 virtio_iommu_model。
// 所有权与生命周期：monitor、driver、Host manager、IOMMU 都由顶层环境拥有，
//                     本类只借用句柄；clone 出来的 TLP 由异步 worker 临时拥有，
//                     worker 结束后自动释放。shutdown() 只等待在途 worker，
//                     不释放外部组件或 Host allocation。
// 设计边界：本类不是 virtio 设备模型，不解析 virtqueue、不产生 notify、不更新
//            used ring；已有完整 PCIe RC/FULL-VIP responder 时必须禁用本类，
//            否则同一请求会得到重复 Completion。
class virtio_pcie_real_dut_host_mem_responder extends uvm_subscriber #(pcie_tl_tlp);
    `uvm_component_utils(virtio_pcie_real_dut_host_mem_responder)

    // EP-originated DMA is observed by the RC-side monitor in pcie_work:
    // the RC adapter receives the EP->RC direction.  The EP monitor observes
    // RC->EP traffic and must not be used as the Host-memory request source.
    protected pcie_tl_base_monitor m_rc_monitor;
    protected pcie_tl_rc_driver    m_rc_driver;
    protected host_mem_manager      m_host_mem;
    protected virtio_pcie_iova_host_mem_proxy m_iova_mem_proxy;
    protected virtio_iommu_model    m_iommu;
    protected semaphore             m_service_lock;
    protected bit                   m_bound;
    protected bit                   m_enabled;
    protected bit                   m_filter_requester;
    protected bit [15:0]            m_endpoint_bdf;
    // 已绑定函数的身份元组独立于可选 requester filter；filter 可以在
    // bind 之后调整，但不能改变 IOVA proxy 所属的真实 Function。
    protected bit [15:0]            m_bound_endpoint_bdf;
    protected int unsigned          m_bound_host_id;
    protected int unsigned          m_inflight;
    protected int unsigned          m_request_count;
    protected int unsigned          m_mem_read_count;
    protected int unsigned          m_mem_write_count;
    protected int unsigned          m_dropped_count;
    protected int unsigned          m_completion_count;

    // 功能：构造未绑定、未启用的 REAL_DUT responder；只创建本地互斥量和
    //       统计状态，不创建 Host memory、IOMMU 映射或 PCIe agent。
    // 输入：name/parent 为 UVM 层次信息。输出：新组件句柄；调用方仍需 bind_function。
    function new(
        string name = "virtio_pcie_real_dut_host_mem_responder",
        uvm_component parent = null
    );
        super.new(name, parent);
        m_service_lock = new(1);
        m_iova_mem_proxy = null;
        m_iommu = null;
        m_bound = 0;
        m_enabled = 0;
        m_filter_requester = 0;
        m_endpoint_bdf = '0;
        m_bound_endpoint_bdf = '0;
        m_bound_host_id = 0;
        m_inflight = 0;
        m_request_count = 0;
        m_mem_read_count = 0;
        m_mem_write_count = 0;
        m_dropped_count = 0;
        m_completion_count = 0;
    endfunction

    // 功能：绑定唯一的被动 RC monitor、主动 RC driver、共享 Host memory 和
    //       (可选) IOMMU requester 域。RC monitor 流必须是 EP→RC；本 subscriber
    //       不接受 RC→EP 请求。
    // 输入：完整 monitor/driver/memory/IOMMU/Host/BDF 元组；输出 why 描述失败原因。
    // 副作用：安装 IOVA proxy、打开 RC driver unified-memory responder，并连接
    //          analysis port。相同完整元组重复调用幂等；任一字段改变则拒绝。
    // 边界：空句柄、BDF=0、driver 无 adapter、Host ID/BDF 不匹配均失败。
    // “bind”是 SystemVerilog 关键字的一部分，故公开 API 使用 bind_function。
    function bit bind_function(
        input pcie_tl_base_monitor rc_monitor,
        input pcie_tl_rc_driver rc_driver,
        input host_mem_manager host_mem,
        output string why,
        input virtio_iommu_model iommu = null,
        input int unsigned host_id = 0,
        input bit [15:0] endpoint_bdf = '0
    );
        why = "";
        if (rc_monitor == null) begin
            why = "RC monitor is null";
            return 0;
        end
        if (rc_monitor.tlp_ap == null) begin
            why = "RC monitor analysis port is null";
            return 0;
        end
        if (rc_driver == null) begin
            why = "RC driver is null";
            return 0;
        end
        if (rc_driver.adapter == null) begin
            why = "RC driver has no PCIe adapter";
            return 0;
        end
        // 中文说明：BDF 0 是 Root Complex/默认未解析身份，不能作为真实
        // Endpoint 的 requester domain。若在这里放行，IOMMU 会把多个未完成
        // 绑定的设备错误地合并到同一个 (Host,BDF) 映射域。
        if (endpoint_bdf == 16'h0000) begin
            why = "endpoint BDF 0 is not a resolved PCIe function identity";
            return 0;
        end
        if (host_mem == null) begin
            why = "Host-memory handle is null";
            return 0;
        end
        if (m_bound) begin
            // 同一完整元组的重复调用是幂等操作；任何 monitor/driver、
            // Host、IOMMU 或 BDF 变化都必须拒绝，避免在有在途 DMA 时
            // 静默替换 requester domain。
            if ((m_rc_monitor == rc_monitor) &&
                (m_rc_driver == rc_driver) &&
                (m_host_mem == host_mem) &&
                (m_iommu == iommu) &&
                (m_bound_host_id == host_id) &&
                (m_bound_endpoint_bdf == endpoint_bdf))
                return 1;
            why = "responder is already bound to a different endpoint/RC/memory/IOMMU tuple";
            return 0;
        end

        m_rc_monitor = rc_monitor;
        m_rc_driver = rc_driver;
        m_host_mem = host_mem;
        m_iommu = iommu;
        m_bound_host_id = host_id;
        m_bound_endpoint_bdf = endpoint_bdf;

        // The RC driver owns the protocol response path.  Preserve its
        // adapter/tag/ordering state; only install the shared memory backend
        // and enable its request handler.
        if (iommu != null) begin
            m_iova_mem_proxy = virtio_pcie_iova_host_mem_proxy::type_id::create(
                "real_dut_iova_mem_proxy");
            if (!m_iova_mem_proxy.configure(
                    host_mem, iommu, host_id, endpoint_bdf, why)) begin
                m_iova_mem_proxy = null;
                return 0;
            end
            m_rc_driver.mem = m_iova_mem_proxy;
        end else begin
            // 直通仅保留给明确没有 IOMMU 的旧集成；推荐的 REAL_DUT
            // 路径必须传入 iommu，否则设备发出的 IOVA 会被误当成 GPA。
            m_rc_driver.mem = host_mem;
            `uvm_warning("REAL_DMA",
                         "REAL_DUT responder is using direct GPA compatibility mode")
        end
        m_rc_driver.use_unified_mem = 1'b1;
        m_rc_driver.auto_response_enable = 1'b1;

        if (!m_bound) begin
            rc_monitor.tlp_ap.connect(this.analysis_export);
            m_bound = 1;
        end
        return 1;
    endfunction

    // 功能：设置可选 requester-BDF 严格过滤器。
    // 输入：enable 和期望 Endpoint BDF；输出：无返回值。
    // 副作用：后续 write() 只接受匹配 BDF 的 EP Memory TLP；不改变已绑定的
    //          IOVA requester 域。关闭过滤时仍依赖 monitor 方向隔离。
    function void set_requester_filter(
        input bit enable,
        input bit [15:0] endpoint_bdf
    );
        m_filter_requester = enable;
        m_endpoint_bdf = endpoint_bdf;
    endfunction

    // 查询接口：返回是否已完成完整绑定；不修改状态。
    function bit bound(); return m_bound; endfunction

    // 查询接口：返回是否允许接收新的 EP-originated Memory TLP；不修改状态。
    function bit enabled(); return m_enabled; endfunction

    // 功能：启用已绑定 responder。未绑定时保持关闭并报告 warning。
    // 输入/输出：无；副作用：后续 write() 才会 clone 和派发请求。
    function void enable();
        if (!m_bound) begin
            `uvm_warning("REAL_DMA", "enable called before bind")
            return;
        end
        m_enabled = 1'b1;
    endfunction
    // 功能：停止接收新的 TLP；不取消已启动 worker，调用方需随后 shutdown。
    function void disable_responder(); m_enabled = 1'b0; endfunction

    // 功能：先禁止新请求，再等待所有在途 worker 退出，供 DUT reset/teardown
    //       使用。输入/输出：无；副作用：阻塞仿真时间直到 inflight=0。
    // 不能命名为 stop()，因为该名称可能与 UVM phase 生命周期接口冲突。
    task shutdown();
        m_enabled = 1'b0;
        while (m_inflight != 0)
            #1ns;
    endtask

    // 以下查询只返回统计快照，不改变 worker、Host 或 IOMMU 状态。
    function int unsigned request_count(); return m_request_count; endfunction
    function int unsigned mem_read_count(); return m_mem_read_count; endfunction
    function int unsigned mem_write_count(); return m_mem_write_count; endfunction
    function int unsigned dropped_count(); return m_dropped_count; endfunction
    function int unsigned completion_count(); return m_completion_count; endfunction
    function int unsigned inflight_count(); return m_inflight; endfunction
    function bit using_iova_translation(); return (m_iova_mem_proxy != null); endfunction
    function virtio_pcie_iova_host_mem_proxy iova_mem_proxy();
        return m_iova_mem_proxy;
    endfunction

    // 中文说明：task 参数按调用时复制 TLP 句柄；与 clone() 配合后，
    // worker 不再捕获 write() 的 automatic 局部变量。这样即使 fork
    // 在父函数返回后的时间片才启动，也始终使用同一份请求快照。
    // 接口契约：输入必须是 write() 已经 clone 的非空 TLP；输出无直接返回值，
    //          由 RC driver 完成 Host memory 读写/Completion 发送。
    // 副作用：串行持有服务锁，更新 Completion 计数并释放一个 inflight worker。
    // 边界：shutdown/disable 期间仍会正确释放锁和计数，但不会再调用 driver。
    protected task automatic service_request(input pcie_tl_tlp request);
        m_service_lock.get();
        if (m_enabled && (m_rc_driver != null) && (request != null)) begin
            m_rc_driver.handle_request(request);
            if (request.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK})
                m_completion_count++;
        end
        m_service_lock.put();
        if (m_inflight != 0)
            m_inflight--;
    endtask

    // 功能：接收 RC monitor 的分析回调，过滤非 EP Memory TLP，先深拷贝再派发
    //       异步 worker。输入 t 由 monitor 所有，返回后可能被复用；本函数不拥有
    //       原对象。副作用：更新接收/丢弃计数并创建 worker；clone 失败只计 dropped。
    // 并发约束：worker 通过 service_lock 串行调用 RC driver，避免 Completion/TLP
    //             发送交错；write() 本身不阻塞 monitor。
    virtual function void write(pcie_tl_tlp t);
        pcie_tl_mem_tlp mem_tlp;
        uvm_object cloned_object;
        pcie_tl_tlp request_copy;
        if (!m_bound || !m_enabled || (t == null))
            return;
        if (!$cast(mem_tlp, t) ||
            !(t.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR}))
            return;
        if (m_filter_requester && (mem_tlp.requester_id != m_endpoint_bdf)) begin
            m_dropped_count++;
            `uvm_warning("REAL_DMA", $sformatf(
                "dropping EP monitor Memory TLP with requester BDF 0x%04h (expected 0x%04h)",
                mem_tlp.requester_id, m_endpoint_bdf))
            return;
        end

        // RC monitor 的 TLP 对象可能在 write() 返回后被复用或继续更新。
        // 必须在 fork 之前做深拷贝；worker 中的 handle assignment 只能
        // 复制句柄，无法隔离地址、BE 和 payload。clone 失败时不发布
        // request/inflight 计数，避免把不可服务的对象伪装成已接收 DMA。
        cloned_object = t.clone();
        if ((cloned_object == null) || !$cast(request_copy, cloned_object)) begin
            m_dropped_count++;
            `uvm_error("REAL_DMA", "failed to clone EP-originated PCIe TLP")
            return;
        end

        m_request_count++;
        if (t.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK})
            m_mem_read_count++;
        else
        m_mem_write_count++;
        m_inflight++;
        fork
            service_request(request_copy);
        join_none
    endfunction

endclass : virtio_pcie_real_dut_host_mem_responder

`endif
