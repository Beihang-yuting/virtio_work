// 目录层次：virtio_net_vip/src/devmodel；VCS 回归用的设备端口：接在 pcie_tl EP driver 上。
// RC→EP 的 CfgRd/CfgWr（按目标 BDF）与 MemRd/MemWr（按设备 BAR 窗口）交给设备并在请求入口直接回
// Completion；无设备认领的请求走 EP driver 基类。请求入口与 EP 的 Completion 接收共用 TLM 线程，必须
// 零时间；设备 DMA 只在设备 worker 中发起。设备 DMA：按 IOVA/GPA 两侧 4KiB 边界切块，经平台 IOMMU 翻译
// 后由 virtio_pcie_model_dma_adapter 发 EP-originated MemRd/MemWr。MSI-X：pcie_tl 的 RC 会把 EP MemWr
// 写进 Host memory，APIC 窗口没有后备内存，因此端口把 MSI-X MemWr 直接发布到 EP monitor 的 tlp_ap——
// 与真实链路上被动观察到的 TLP 相同，VIP observer 照常解码。
// 所有权：借用 EP driver/monitor/IOMMU；只创建每个 requester 的 DMA adapter。
`ifndef VDEV_UVM_EP_PORT_SV
`define VDEV_UVM_EP_PORT_SV

typedef class vdev_uvm_ep_port;

// pcie_tl EP driver 的设备模型接入点（fixture 以 factory override 替换 pcie_tl_ep_driver）。
class vdev_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(vdev_ep_driver)

    vdev_uvm_ep_port port;

    function new(string name = "vdev_ep_driver", uvm_component parent = null);
        super.new(name, parent);
        port = null;
    endfunction

    virtual task handle_request(pcie_tl_tlp req);
        bit handled;

        handled = 0;
        if (port != null)
            port.serve(req, handled);
        if (!handled)
            super.handle_request(req);
    endtask
endclass

class vdev_uvm_ep_port extends vdev_port;
    `uvm_object_utils(vdev_uvm_ep_port)

    protected vdev_ep_driver                m_ep;
    protected pcie_tl_base_monitor          m_ep_monitor;
    protected virtio_iommu_model            m_iommu;
    protected int unsigned                  m_host_id;
    protected virtio_pcie_model_dma_adapter m_dma[bit [15:0]];

    function new(string name = "vdev_uvm_ep_port");
        super.new(name);
    endfunction

    // 绑定 EP driver（须为 vdev_ep_driver）、EP monitor（MSI-X 发布点）与平台 IOMMU。
    function bit connect_ep(pcie_tl_ep_driver ep, pcie_tl_base_monitor ep_monitor,
                            virtio_iommu_model iommu, int unsigned host_id, output string why);
        why = "";
        if (!$cast(m_ep, ep) || (m_ep == null)) begin
            why = "EP driver is not a vdev_ep_driver";
            return 0;
        end
        if ((ep_monitor == null) || (ep_monitor.tlp_ap == null)) begin
            why = "EP monitor is unavailable";
            return 0;
        end
        if (iommu == null) begin
            why = "IOMMU model is null";
            return 0;
        end
        m_ep_monitor = ep_monitor;
        m_iommu = iommu;
        m_host_id = host_id;
        // 设备寄存器由模型应答；Host memory 属于 RC 侧，不能挂到 EP 上。
        m_ep.mem = null;
        m_ep.use_unified_mem = 0;
        m_ep.port = this;
        return 1;
    endfunction

    // 请求入口：认领则直接回 Completion（MemWr 为 posted，无 Completion）。
    task serve(pcie_tl_tlp req, output bit handled);
        pcie_tl_cfg_tlp cfg_req;
        pcie_tl_mem_tlp mem_req;
        pcie_tl_cpl_tlp cpl;
        vdev_base dev;
        int unsigned bar;
        int unsigned dw_count;
        int unsigned valid;
        int unsigned first;
        int unsigned n;
        bit [31:0] off;
        bit [31:0] data;
        bit [3:0] be;

        handled = 0;
        if (req.kind inside {TLP_CFG_RD0, TLP_CFG_RD1, TLP_CFG_WR0, TLP_CFG_WR1}) begin
            if (!$cast(cfg_req, req))
                return;
            dev = device_by_bdf(cfg_req.completer_id);
            if (dev == null)
                return;
            cpl = m_ep.generate_completion(req, CPL_STATUS_SC);
            cpl.completer_id = dev.bdf;
            if (req.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) begin
                data = dev.cfg_read(cfg_req.get_cfg_addr());
                cpl.kind = TLP_CPLD;
                cpl.fmt = FMT_3DW_WITH_DATA;
                cpl.length = 1;
                cpl.payload = new[4];
                foreach (cpl.payload[i])
                    cpl.payload[i] = data[8*i +: 8];
            end else begin
                data = 0;
                for (int i = 0; (i < 4) && (i < req.payload.size()); i++)
                    data[8*i +: 8] = req.payload[i];
                dev.cfg_write(cfg_req.get_cfg_addr(), data, cfg_req.first_be);
            end
            m_ep.send_tlp(cpl);
            handled = 1;
            return;
        end
        if (!(req.kind inside {TLP_MEM_RD, TLP_MEM_WR}) || !$cast(mem_req, req))
            return;
        dev = device_by_addr({mem_req.addr[63:2], 2'b00}, bar, off);
        if (dev == null)
            return;
        dw_count = (mem_req.length == 0) ? 1024 : mem_req.length;
        if (req.kind == TLP_MEM_WR) begin
            for (int unsigned i = 0; i < dw_count; i++) begin
                be = (i == 0) ? mem_req.first_be : ((i == dw_count - 1) ? mem_req.last_be : 4'hf);
                if (!lanes(be, first, n))
                    continue;
                data = 0;
                for (int unsigned b = 0; b < 4; b++)
                    if (4*i + b < req.payload.size())
                        data[8*b +: 8] = req.payload[4*i + b];
                dev.mmio_write(bar, off + 4*i + first, n, data >> (8 * first));
            end
            handled = 1;
            return;
        end
        cpl = m_ep.generate_completion(req, CPL_STATUS_SC);
        cpl.kind = TLP_CPLD;
        cpl.fmt = FMT_3DW_WITH_DATA;
        cpl.length = mem_req.length;
        cpl.completer_id = dev.bdf;
        cpl.payload = new[4 * dw_count];
        foreach (cpl.payload[i])
            cpl.payload[i] = 8'h00;
        valid = 0;
        for (int unsigned i = 0; i < dw_count; i++) begin
            be = (i == 0) ? mem_req.first_be : ((i == dw_count - 1) ? mem_req.last_be : 4'hf);
            if (!lanes(be, first, n))
                continue;
            data = dev.mmio_read(bar, off + 4*i + first, n) << (8 * first);
            for (int unsigned b = 0; b < 4; b++)
                cpl.payload[4*i + b] = data[8*b +: 8];
            valid += n;
        end
        void'(lanes(mem_req.first_be, first, n));
        cpl.byte_count = valid;
        cpl.lower_addr = {mem_req.addr[6:2], 2'b00} + first;
        m_ep.send_tlp(cpl);
        handled = 1;
    endtask

    // 字节使能 → 首字节与连续字节数；全 0 返回 0。
    protected function bit lanes(bit [3:0] be, output int unsigned first, output int unsigned n);
        int unsigned last;

        first = 0;
        n = 0;
        if (be == 0)
            return 0;
        while (!be[first])
            first++;
        last = 3;
        while (!be[last])
            last--;
        n = last - first + 1;
        return 1;
    endfunction

    virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                          output bit [7:0] data[], output bit ok);
        bit [63:0] gpa;
        bit [7:0] part[];
        bit [7:0] accum[$];
        int unsigned offset;
        int unsigned chunk;

        ok = 0;
        data = new[0];
        offset = 0;
        while (offset < len) begin
            if (!page_chunk(requester, addr + offset, len - offset, DMA_TO_DEVICE, gpa, chunk))
                return;
            adapter(requester).read(gpa, chunk, part);
            if (part.size() != chunk)
                return;
            foreach (part[i])
                accum.push_back(part[i]);
            offset += chunk;
        end
        data = new[accum.size()];
        foreach (accum[i])
            data[i] = accum[i];
        ok = 1;
    endtask

    virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                           output bit ok);
        bit [63:0] gpa;
        bit [7:0] part[];
        int unsigned offset;
        int unsigned chunk;

        ok = 0;
        offset = 0;
        while (offset < data.size()) begin
            if (!page_chunk(requester, addr + offset, data.size() - offset, DMA_FROM_DEVICE,
                            gpa, chunk))
                return;
            part = new[chunk];
            foreach (part[i])
                part[i] = data[offset + i];
            adapter(requester).write(gpa, part);
            offset += chunk;
        end
        ok = 1;
    endtask

    virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
        pcie_tl_mem_tlp tlp;

        tlp = pcie_tl_mem_tlp::type_id::create("vdev_msix");
        tlp.kind = TLP_MEM_WR;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.addr = addr;
        tlp.is_64bit = (addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
        tlp.length = 1;
        tlp.first_be = 4'hf;
        tlp.last_be = 4'h0;
        tlp.requester_id = requester;
        tlp.payload = new[4];
        foreach (tlp.payload[i])
            tlp.payload[i] = data[8*i +: 8];
        m_ep_monitor.tlp_ap.write(tlp);
    endtask

    // 按 IOVA 与翻译后 GPA 两侧 4KiB 边界切块并翻译；翻译失败报告并返回 0。
    protected function bit page_chunk(bit [15:0] requester, bit [63:0] iova, int unsigned remain,
                                      dma_dir_e dir, output bit [63:0] gpa,
                                      output int unsigned chunk);
        bit [63:0] probe;
        iommu_fault_e fault;
        int unsigned iova_left;
        int unsigned gpa_left;
        bit ok;

        gpa = 0;
        chunk = 0;
        ok = (dir == DMA_TO_DEVICE) ?
             m_iommu.translate_for_host(m_host_id, requester, iova, 1, dir, probe, fault) :
             m_iommu.validate_for_host(m_host_id, requester, iova, 1, dir, probe, fault);
        if (ok) begin
            iova_left = 4096 - iova[11:0];
            gpa_left = 4096 - probe[11:0];
            chunk = remain;
            if (chunk > iova_left)
                chunk = iova_left;
            if (chunk > gpa_left)
                chunk = gpa_left;
            ok = (dir == DMA_TO_DEVICE) ?
                 m_iommu.translate_for_host(m_host_id, requester, iova, chunk, dir, gpa, fault) :
                 m_iommu.validate_for_host(m_host_id, requester, iova, chunk, dir, gpa, fault);
        end
        if (!ok)
            `uvm_error("VDEV_DMA", $sformatf(
                "%s translation failed host=%0d requester=0x%04h IOVA=0x%016h fault=%s",
                dir.name(), m_host_id, requester, iova, fault.name()))
        return ok;
    endfunction

    protected function virtio_pcie_model_dma_adapter adapter(bit [15:0] requester);
        string why;

        if (!m_dma.exists(requester)) begin
            m_dma[requester] = virtio_pcie_model_dma_adapter::type_id::create(
                $sformatf("vdev_dma_%04h", requester));
            void'(m_dma[requester].connect_ep(m_ep, requester, why));
        end
        return m_dma[requester];
    endfunction
endclass
`endif
