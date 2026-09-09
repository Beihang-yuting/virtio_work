`ifndef VIRTIO_PCIE_IOVA_HOST_MEM_PROXY_SV
`define VIRTIO_PCIE_IOVA_HOST_MEM_PROXY_SV

// 中文说明：REAL_DUT 的 PCIe Memory TLP 地址是设备可见的 IOVA，而
// host_mem_manager 保存的是 Host GPA backing。这个适配器是两者之间唯一
// 的地址边界：读先做 IOVA->GPA 翻译，写通过 write_from_device_for_host()
// 完成权限检查和 dirty-page 记录。它不创建新的 allocator，也不复制内存。
// 文件职责：把 RC 侧设备 DMA 的 IOVA 地址适配为共享 Host memory 的 API。
// 主要依赖：host_mem_api/host_mem_manager、virtio_iommu_model 及其 DMA 方向检查。
// 所有权：只借用调用方传入的 manager 和 IOMMU，不拥有、不释放，也不负责 map/unmap。
// 生命周期：new 后先 configure 一次；随后可作为 host_mem_api 使用，teardown 时仅
//           由调用方回收底层 manager 的分配。direct GPA 只用于显式 legacy 场景。
class virtio_pcie_iova_host_mem_proxy extends host_mem_api;
    `uvm_object_utils(virtio_pcie_iova_host_mem_proxy)

    protected host_mem_manager   m_mem;
    protected virtio_iommu_model m_iommu;
    protected int unsigned       m_host_id;
    protected bit [15:0]         m_bdf;
    protected bit                 m_configured;
    protected bit                 m_direct_gpa_mode;
    protected int unsigned       m_read_count;
    protected int unsigned       m_write_count;
    protected int unsigned       m_translation_fault_count;

    // 接口契约：创建未配置的轻量代理，所有句柄为空、计数器清零；不分配内存。
    function new(string name = "virtio_pcie_iova_host_mem_proxy");
        super.new(name);
        m_mem = null;
        m_iommu = null;
        m_host_id = 0;
        m_bdf = '0;
        m_configured = 0;
        m_direct_gpa_mode = 0;
        m_read_count = 0;
        m_write_count = 0;
        m_translation_fault_count = 0;
    endfunction

    // 接口契约：输入共享 manager、IOMMU、host_id 和 requester BDF，why 返回失败原因。
    // 成功只保存句柄和 requester 域；同一四元组可重复调用，不能切换到另一域。
    // 失败条件：任一句柄为空、manager 未初始化、manager Host ID 不匹配，或已配置
    //           后传入不同对象/Host/BDF。失败不应被当作建立了新的映射。
    // 副作用与所有权：不创建 IOVA/GPA 映射、不分配 backing、不接管传入对象。
    function bit configure(
        input host_mem_manager mem,
        input virtio_iommu_model iommu,
        input int unsigned host_id,
        input bit [15:0] bdf,
        output string why
    );
        why = "";
        if (mem == null) begin why = "Host memory manager is null"; return 0; end
        if (iommu == null) begin why = "IOMMU model is null"; return 0; end
        if (!mem.is_initialized()) begin why = "Host memory manager is not initialized"; return 0; end
        if (mem.get_host_id() != host_id) begin
            why = $sformatf("Host ID mismatch: manager=%0d requested=%0d",
                           mem.get_host_id(), host_id);
            return 0;
        end
        if (m_configured && ((m_mem != mem) || (m_iommu != iommu) ||
                             (m_host_id != host_id) || (m_bdf != bdf))) begin
            why = "IOVA proxy is already configured for a different domain";
            return 0;
        end
        m_mem = mem;
        m_iommu = iommu;
        m_host_id = host_id;
        m_bdf = bdf;
        m_configured = 1;
        return 1;
    endfunction

    // 接口契约：切换 legacy 直通模式；打开后 addr 按 GPA 解释并跳过 IOMMU 翻译、
    // 权限检查和 dirty-page 记录。REAL_DUT 默认关闭，调用方必须显式承担无 IOMMU
    // 前提；本函数无失败返回，也不会修改底层 manager。
    function void set_direct_gpa_mode(input bit enable);
        m_direct_gpa_mode = enable;
    endfunction
    // 返回当前是否将传入地址按 GPA 直通；只读，不改变代理状态。
    function bit direct_gpa_mode(); return m_direct_gpa_mode; endfunction
    // 以下统计只记录本代理成功完成的读写/翻译失败次数，不代表 DUT 硬件计数器。
    function int unsigned read_count(); return m_read_count; endfunction
    function int unsigned write_count(); return m_write_count; endfunction
    function int unsigned translation_fault_count();
        return m_translation_fault_count;
    endfunction

    // 内部契约：把设备读请求的 IOVA 解析为 GPA。DMA_TO_DEVICE 表示设备读取
    // Host；未配置、范围不足或 IOMMU 翻译失败返回 0，后者递增 fault 计数；
    // 直通模式只检查 manager aperture，不经过 IOMMU。
    protected function bit resolve_read(
        input bit [63:0] iova,
        input int unsigned size,
        output bit [63:0] gpa
    );
        iommu_fault_e fault;
        gpa = '0;
        if (!m_configured || (m_mem == null)) return 0;
        if (m_direct_gpa_mode) begin
            gpa = iova;
            return m_mem.contains_range(gpa, size);
        end
        if ((m_iommu == null) || !m_iommu.translate_for_host(
                m_host_id, m_bdf, iova, size, DMA_TO_DEVICE, gpa, fault)) begin
            m_translation_fault_count++;
            return 0;
        end
        return 1;
    endfunction

    // host_mem_api 委托接口：以下操作作用于同一个底层 manager。代理不复制状态；
    // init_region/set_alloc_policy/set_host_id 可能改变共享 manager/requester 状态，
    // 应在 configure 前由唯一 owner 调用。未绑定时按底层能力返回失败或空操作。
    virtual function void init_region(
        bit [63:0] base_addr,
        bit [63:0] end_addr,
        alloc_mode_e m = MODE_BUDDY,
        int unsigned granule = DEFAULT_MIN_GRANULE,
        byte poison = DEFAULT_POISON
    );
        if (m_mem != null) m_mem.init_region(base_addr, end_addr, m, granule, poison);
    endfunction

    virtual function void set_alloc_policy(host_mem_alloc_policy_e policy);
        if (m_mem != null) m_mem.set_alloc_policy(policy);
    endfunction
    virtual function host_mem_alloc_policy_e get_alloc_policy();
        return (m_mem == null) ? HOST_MEM_FIRST_FIT : m_mem.get_alloc_policy();
    endfunction
    virtual function void set_host_id(int unsigned id);
        m_host_id = id;
    endfunction
    virtual function int unsigned get_host_id(); return m_host_id; endfunction
    virtual function bit is_initialized();
        return (m_mem != null) && m_mem.is_initialized();
    endfunction
    virtual function bit contains_range(bit [63:0] base, bit [63:0] size);
        return (m_mem != null) && m_mem.contains_range(base, size);
    endfunction
    virtual function bit intersects_region(bit [63:0] base, bit [63:0] size);
        return (m_mem != null) && m_mem.intersects_region(base, size);
    endfunction
    virtual function bit reserve_range(bit [63:0] base, bit [63:0] size,
                                       string owner = "", string file = "",
                                       int line = 0);
        return (m_mem != null) && m_mem.reserve_range(base, size, owner, file, line);
    endfunction
    virtual function bit [63:0] alloc(int unsigned size, int unsigned align = 1,
                                      string file = "", int line = 0);
        return (m_mem == null) ? '1 : m_mem.alloc(size, align, file, line);
    endfunction
    virtual function void free(bit [63:0] addr, string file = "", int line = 0);
        if (m_mem != null) m_mem.free(addr, file, line);
    endfunction

    // 接口契约：addr 是设备可见 IOVA，data 是输出字节数组。成功路径先翻译再读
    // 共享 GPA backing，并递增 read_count；未配置、size=0、越界或翻译失败时
    // data 为空且静默返回，不产生新的分配。
    virtual function void read_mem(bit [63:0] addr, int unsigned size,
                                   ref byte data[], input string file = "",
                                   input int line = 0);
        bit [63:0] gpa;
        data = new[0];
        if ((size == 0) || !resolve_read(addr, size, gpa)) return;
        m_mem.read_mem(gpa, size, data, file, line);
        m_read_count++;
    endfunction

    // 接口契约：addr 是设备可见 IOVA，data 是设备写入字节。正常模式通过
    // write_from_device_for_host 保留权限/dirty tracking；空数据、未配置、范围或
    // 权限失败时不写入且不递增 write_count。直通模式直接写 GPA。
    virtual function void write_mem(bit [63:0] addr, byte data[],
                                    string file = "", int line = 0);
        bit [63:0] gpa;
        iommu_fault_e fault;
        if ((data.size() == 0) || !m_configured || (m_mem == null)) return;
        if (m_direct_gpa_mode) begin
            if (!m_mem.contains_range(addr, data.size())) return;
            m_mem.write_mem(addr, data, file, line);
        end else if ((m_iommu != null) && m_iommu.write_from_device_for_host(
                         m_host_id, m_mem, m_bdf, addr, data, fault)) begin
            gpa = addr; // only used for diagnostics/debug; translation is internal
        end else begin
            m_translation_fault_count++;
            return;
        end
        m_write_count++;
    endfunction

    // 注意：这是底层 host_mem_api 的比较辅助，addr1/addr2 按 manager/GPA 解释，
    // 不执行 IOVA 翻译；只读比较，不改变映射或计数。
    virtual function bit mem_compare(bit [63:0] addr1, bit [63:0] addr2,
                                     int unsigned size,
                                     output int unsigned mismatch_offset,
                                     input string file = "", input int line = 0);
        return (m_mem != null) && m_mem.mem_compare(addr1, addr2, size,
                                                    mismatch_offset, file, line);
    endfunction
    // 将泄漏检查委托给共享 manager；不释放对象、不改变映射状态。
    virtual function void leak_check(string file = "", int line = 0);
        if (m_mem != null) m_mem.leak_check(file, line);
    endfunction
endclass : virtio_pcie_iova_host_mem_proxy

`endif
