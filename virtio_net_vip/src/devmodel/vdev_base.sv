// 目录层次：virtio_net_vip/src/devmodel；独立设备模型的公共底座。
// 职责：PCI 配置空间（Type 0 头、64 位 BAR、能力链 PCIe/MSI-X/子类 vendor cap、扩展空间 0x100 的
// 调试 VSEC 与 marker 寄存器 0x108）、MSI-X 表/PBA 与屏蔽语义、语义事件 event_ap、单 worker 队列服务
// 调度、TX→RX 回环缓存、设备侧故障点。子类只实现 BAR 寄存器区与队列服务。
// 依赖 vdev_port、virtqueue_error_injector（可选）与 virtio 类型常量；不引用任何驱动侧对象。
// 时序：配置/MMIO 处理是零时间函数（端口在请求入口直接调用，不得阻塞）；DMA 与中断只在
// run_phase 的 worker 中发生。INTx 消息不建模：MSI-X 未使能时设备只置 ISR（子类）。
`ifndef VDEV_BASE_SV
`define VDEV_BASE_SV

virtual class vdev_base extends uvm_component;
    localparam bit [11:0] DEBUG_VSEC_OFF   = 12'h100;
    localparam bit [11:0] DEBUG_MARKER_OFF = 12'h108;
    localparam bit [15:0] DEBUG_VSEC_ID    = 16'h5644;

    vdev_port                       port;
    bit [15:0]                      bdf;
    uvm_analysis_port #(vdev_event) event_ap;
    virtqueue_error_injector        err_inj;

    typedef struct { bit [7:0] data[$]; } frame_t;

    protected bit [7:0]    cfg[4096];
    protected bit [7:0]    cfg_wmask[4096];
    protected bit [63:0]   bar_size[6];
    protected bit [7:0]    last_cap;
    protected bit [7:0]    next_cap;
    protected bit [7:0]    msix_cap;
    protected int unsigned msix_bar;
    protected int unsigned msix_vectors;
    protected bit [31:0]   msix_table_off;
    protected bit [31:0]   msix_pba_off;
    protected bit [31:0]   msix_table[];
    protected bit          msix_pending[];
    protected frame_t      rx_backlog[int unsigned][$];
    protected int unsigned work_q[$];
    protected int unsigned irq_q[$];
    protected event        work_ev;
    protected int unsigned epoch;
    protected int unsigned busy_epoch;
    protected bit          busy;
    protected int unsigned n_notify, n_dma_rd, n_dma_wr, n_complete, n_irq;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        event_ap = new("event_ap", this);
        port = null;
        err_inj = null;
        bdf = '0;
        msix_cap = 0;
        msix_vectors = 0;
        epoch = 0;
        busy = 0;
        n_notify = 0;
        n_dma_rd = 0;
        n_dma_wr = 0;
        n_complete = 0;
        n_irq = 0;
    endfunction

    // 构建配置空间并复位设备状态；BDF 与设备参数须先设置。
    pure virtual function void init();
    // BAR 寄存器区读写（MSI-X 区已由底座处理）；size 为 1/2/4，读返回值右对齐。
    pure virtual function bit [31:0] region_read(int unsigned bar, bit [31:0] off, int unsigned size);
    pure virtual function void region_write(int unsigned bar, bit [31:0] off, int unsigned size,
                                            bit [31:0] data);
    // 服务一个工作项（编码由子类定义）；只在 worker 中调用。
    pure virtual task service_queue(int unsigned q);

    // ---------------- 统计（测试断言用） ----------------
    function int unsigned notify_count();     return n_notify;   endfunction
    function int unsigned dma_read_count();   return n_dma_rd;   endfunction
    function int unsigned dma_write_count();  return n_dma_wr;   endfunction
    function int unsigned completion_count(); return n_complete; endfunction
    function int unsigned interrupt_count();  return n_irq;      endfunction

    // ---------------- 字节/位工具 ----------------
    protected function bit [31:0] get_cfg(bit [11:0] off, int unsigned n);
        bit [31:0] v;

        v = 0;
        for (int unsigned b = 0; b < n; b++)
            v[8*b +: 8] = cfg[off + b];
        return v;
    endfunction

    protected function void put_cfg(bit [11:0] off, int unsigned n, bit [31:0] v);
        for (int unsigned b = 0; b < n; b++)
            cfg[off + b] = v[8*b +: 8];
    endfunction

    // 1/2/4 字节访问的值掩码。
    static function bit [31:0] size_mask(int unsigned size);
        return (size >= 4) ? 32'hffff_ffff : ((32'h1 << (8 * size)) - 1);
    endfunction

    // 把 size 字节的写数据按字节偏移 lane 合并进 32 位寄存器。
    static function bit [31:0] merge32(bit [31:0] old, bit [1:0] lane, int unsigned size,
                                       bit [31:0] data);
        bit [31:0] m;

        m = size_mask(size) << (8 * lane);
        return (old & ~m) | ((data << (8 * lane)) & m);
    endfunction

    // ---------------- 配置空间构建 ----------------
    // Type 0 头：ID、类代码、64 位非预取 MMIO BAR（尺寸 0 表示未实现）、PCIe 能力（v2 端点，
    // 使主机开放 4 KiB 配置空间）与调试 VSEC。可写位：command 的 MEM/BME/INTx-disable、中断线、
    // BAR 地址位、marker 寄存器；MSI-X 控制位由 add_msix 打开。
    protected function void init_header(bit [15:0] vid, bit [15:0] did, bit [23:0] class_code,
                                        bit [7:0] rev, bit [63:0] sizes[3]);
        bit [63:0] mask;
        bit [7:0] body[];

        foreach (cfg[i]) begin
            cfg[i] = 0;
            cfg_wmask[i] = 0;
        end
        put_cfg(12'h000, 2, vid);
        put_cfg(12'h002, 2, did);
        cfg_wmask[12'h004] = 8'h06;
        cfg_wmask[12'h005] = 8'h04;
        cfg[12'h006] = 8'h10;
        cfg[12'h008] = rev;
        put_cfg(12'h009, 3, class_code);
        put_cfg(12'h02c, 2, vid);
        put_cfg(12'h02e, 2, did);
        cfg[12'h03d] = 8'h01;
        cfg_wmask[12'h03c] = 8'hff;
        for (int unsigned i = 0; i < 3; i++) begin
            bar_size[2*i] = sizes[i];
            bar_size[2*i + 1] = 0;
            if (sizes[i] == 0)
                continue;
            cfg[12'h010 + 8*i] = 8'h04;
            mask = ~(sizes[i] - 1);
            for (int unsigned b = 0; b < 8; b++)
                cfg_wmask[12'h010 + 8*i + b] = mask[8*b +: 8] & ((b == 0) ? 8'hf0 : 8'hff);
        end
        last_cap = 0;
        next_cap = 8'h40;
        body = new[58];
        foreach (body[i])
            body[i] = 0;
        body[0] = 8'h02;
        void'(add_cap(8'h10, body));
        put_cfg(DEBUG_VSEC_OFF, 4, {12'h000, 4'h1, 16'h000b});
        put_cfg(DEBUG_VSEC_OFF + 4, 4, {12'h00c, 4'h0, DEBUG_VSEC_ID});
        for (int unsigned b = 0; b < 4; b++)
            cfg_wmask[DEBUG_MARKER_OFF + b] = 8'hff;
    endfunction

    // 在标准能力链尾追加一个能力（body 从能力第 2 字节起），返回其偏移；4 字节对齐。
    protected function bit [7:0] add_cap(bit [7:0] id, bit [7:0] body[]);
        bit [7:0] off;

        off = next_cap;
        cfg[off] = id;
        cfg[off + 1] = 8'h00;
        foreach (body[i])
            cfg[off + 2 + i] = body[i];
        if (last_cap == 0)
            cfg[12'h034] = off;
        else
            cfg[last_cap + 1] = off;
        last_cap = off;
        next_cap = (off + 2 + body.size() + 3) & 8'hfc;
        return off;
    endfunction

    // MSI-X 能力与表：vectors 个表项（复位为屏蔽），PBA 只读；Enable/Function Mask 可写。
    protected function void add_msix(int unsigned bar, bit [31:0] table_off, bit [31:0] pba_off,
                                     int unsigned vectors);
        bit [7:0] body[];
        bit [15:0] ctrl;
        bit [31:0] t;
        bit [31:0] p;

        body = new[10];
        ctrl = vectors - 1;
        t = table_off | bar;
        p = pba_off | bar;
        body[0] = ctrl[7:0];
        body[1] = ctrl[15:8];
        for (int unsigned b = 0; b < 4; b++) begin
            body[2 + b] = t[8*b +: 8];
            body[6 + b] = p[8*b +: 8];
        end
        msix_cap = add_cap(8'h11, body);
        cfg_wmask[msix_cap + 3] = 8'hc0;
        msix_bar = bar;
        msix_table_off = table_off;
        msix_pba_off = pba_off;
        msix_vectors = vectors;
        msix_table = new[4 * vectors];
        msix_pending = new[vectors];
        for (int unsigned v = 0; v < vectors; v++) begin
            msix_table[4*v] = 0;
            msix_table[4*v + 1] = 0;
            msix_table[4*v + 2] = 0;
            msix_table[4*v + 3] = 1;
            msix_pending[v] = 0;
        end
    endfunction

    // ---------------- 主机侧入口（零时间） ----------------
    function bit [31:0] cfg_read(bit [11:0] addr);
        bit [11:0] a;
        bit [31:0] v;

        a = {addr[11:2], 2'b00};
        v = get_cfg(a, 4);
        reg_event(0, "cfg", $sformatf("0x%03h", a), -1, v);
        return v;
    endfunction

    // 按字节使能与 cfg_wmask 合并；marker 写只发 marker 事件；MSI-X 控制变化后补发挂起中断。
    function void cfg_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        bit [11:0] a;
        vdev_event e;

        a = {addr[11:2], 2'b00};
        for (int unsigned b = 0; b < 4; b++)
            if (be[b])
                cfg[a + b] = (cfg[a + b] & ~cfg_wmask[a + b]) | (data[8*b +: 8] & cfg_wmask[a + b]);
        if (a == DEBUG_MARKER_OFF) begin
            e = new_event(VDEV_MARKER);
            e.scenario = get_cfg(DEBUG_MARKER_OFF, 4);
            emit(e);
            return;
        end
        reg_event(1, "cfg", $sformatf("0x%03h", a), -1, data);
        if ((msix_cap != 0) && (a == {4'h0, msix_cap}))
            flush_pending();
    endfunction

    function bit [63:0] bar_base(int unsigned bar);
        bit [63:0] v;

        for (int unsigned b = 0; b < 8; b++)
            v[8*b +: 8] = cfg[12'h010 + 4*bar + b];
        return {v[63:4], 4'h0};
    endfunction

    function bit claims(bit [63:0] addr, output int unsigned bar, output bit [31:0] offset);
        bit [63:0] base;

        bar = 0;
        offset = 0;
        for (int unsigned b = 0; b < 6; b += 2) begin
            if (bar_size[b] == 0)
                continue;
            base = bar_base(b);
            if ((base != 0) && (addr >= base) && (addr < base + bar_size[b])) begin
                bar = b;
                offset = addr - base;
                return 1;
            end
        end
        return 0;
    endfunction

    function bit [31:0] mmio_read(int unsigned bar, bit [31:0] off, int unsigned size);
        if ((msix_vectors != 0) && (bar == msix_bar))
            return msix_read(off, size);
        return region_read(bar, off, size) & size_mask(size);
    endfunction

    function void mmio_write(int unsigned bar, bit [31:0] off, int unsigned size, bit [31:0] data);
        if ((msix_vectors != 0) && (bar == msix_bar))
            msix_write(off, size, data);
        else
            region_write(bar, off, size, data & size_mask(size));
    endfunction

    // 设备网络侧入包（测试激励或回环）：按队列对缓存，等该对 RX 队列有 buffer 时写入。
    function void inject_rx(int unsigned pair, bit [7:0] frame[$]);
        frame_t f;

        f.data = frame;
        if (!rx_backlog.exists(pair))
            rx_backlog[pair] = {};
        rx_backlog[pair].push_back(f);
        schedule(2 * pair);
    endfunction

    // ---------------- MSI-X ----------------
    protected function bit msix_enabled();
        bit [31:0] ctrl;

        ctrl = get_cfg({4'h0, msix_cap} + 2, 2);
        return (msix_cap != 0) && ctrl[15];
    endfunction

    protected function bit [31:0] msix_read(bit [31:0] off, int unsigned size);
        bit [31:0] v;
        int unsigned base;

        v = 0;
        if ((off >= msix_table_off) && (off < msix_table_off + 16 * msix_vectors)) begin
            v = msix_table[(off - msix_table_off) / 4] >> (8 * off[1:0]);
            reg_event(0, "msix", $sformatf("vec%0d.dw%0d", (off - msix_table_off) / 16,
                      ((off - msix_table_off) / 4) % 4), -1, v);
        end else if ((off >= msix_pba_off) &&
                     (off < msix_pba_off + 8 * ((msix_vectors + 63) / 64))) begin
            base = ((off - msix_pba_off) & ~32'h3) * 8;
            for (int unsigned i = 0; i < 32; i++)
                if (base + i < msix_vectors)
                    v[i] = msix_pending[base + i];
            v = v >> (8 * off[1:0]);
            reg_event(0, "msix", "pba", -1, v);
        end
        return v & size_mask(size);
    endfunction

    protected function void msix_write(bit [31:0] off, int unsigned size, bit [31:0] data);
        int unsigned idx;

        if ((off < msix_table_off) || (off >= msix_table_off + 16 * msix_vectors))
            return;
        idx = (off - msix_table_off) / 4;
        msix_table[idx] = merge32(msix_table[idx], off[1:0], size, data);
        reg_event(1, "msix", $sformatf("vec%0d.dw%0d", idx / 4, idx % 4), -1, msix_table[idx]);
        if (((idx % 4) == 3) && !msix_table[idx][0] && msix_pending[idx / 4]) begin
            irq_q.push_back(idx / 4);
            -> work_ev;
        end
    endfunction

    // 使能/功能屏蔽变化后，把已解除屏蔽的挂起向量交给 worker 补发。
    protected function void flush_pending();
        bit [31:0] ctrl;

        ctrl = get_cfg({4'h0, msix_cap} + 2, 2);
        if (!ctrl[15] || ctrl[14])
            return;
        foreach (msix_pending[v])
            if (msix_pending[v] && !msix_table[4*v + 3][0])
                irq_q.push_back(v);
        -> work_ev;
    endfunction

    // 发一个 MSI-X 向量：未使能不发；功能屏蔽或向量屏蔽时置 PBA；NO_VECTOR/越界忽略。
    protected task raise_irq(int unsigned vector);
        bit [31:0] ctrl;
        vdev_event e;

        if (vector >= msix_vectors)
            return;
        ctrl = get_cfg({4'h0, msix_cap} + 2, 2);
        if (!ctrl[15])
            return;
        if (ctrl[14] || msix_table[4*vector + 3][0]) begin
            msix_pending[vector] = 1;
            return;
        end
        msix_pending[vector] = 0;
        port.raise_msix(bdf, {msix_table[4*vector + 1], msix_table[4*vector]},
                        msix_table[4*vector + 2]);
        n_irq++;
        e = new_event(VDEV_IRQ);
        e.vector = vector;
        emit(e);
    endtask

    // ---------------- worker、DMA、复位 ----------------
    // 单 worker 串行处理：补发中断优先，再服务队列；busy_epoch 用于复位时判断在途工作。
    virtual task run_phase(uvm_phase phase);
        int unsigned q;

        forever begin
            while ((work_q.size() == 0) && (irq_q.size() == 0))
                @(work_ev);
            if (irq_q.size() != 0) begin
                raise_irq(irq_q.pop_front());
                continue;
            end
            q = work_q.pop_front();
            busy = 1;
            busy_epoch = epoch;
            service_queue(q);
            busy = 0;
        end
    endtask

    protected function void schedule(int unsigned q);
        foreach (work_q[i])
            if (work_q[i] == q)
                return;
        work_q.push_back(q);
        -> work_ev;
    endfunction

    // 复位：丢弃待处理工作与回环帧；在途服务看到 epoch 变化后停止。
    protected function void quiesce();
        epoch++;
        work_q.delete();
        irq_q.delete();
        rx_backlog.delete();
    endfunction

    // 复位后仍有在途服务（DMA 未停）。
    protected function bit draining();
        return busy && (busy_epoch != epoch);
    endfunction

    protected function bit has_backlog(int unsigned pair);
        return rx_backlog.exists(pair) && (rx_backlog[pair].size() != 0);
    endfunction

    protected task dma_rd(bit [63:0] addr, int unsigned len, output bit [7:0] data[], output bit ok);
        port.dma_read(bdf, addr, len, data, ok);
        n_dma_rd++;
    endtask

    protected task dma_wr(bit [63:0] addr, bit [7:0] data[], output bit ok);
        port.dma_write(bdf, addr, data, ok);
        n_dma_wr++;
    endtask

    // 设备侧故障点：只消费本模型能实现的错误类型（PRE_DEVICE_READ：零长、方向翻转；
    // BEFORE_USED：完成长度多报 1）。其它类型留给驱动侧时序点或专用接口。
    protected function bit take_fault(int unsigned q, virtqueue_error_phase_e phase);
        if (err_inj == null)
            return 0;
        if ((phase == VQ_FAULT_PRE_DEVICE_READ) &&
            !(err_inj.err_type inside {VQ_ERR_ZERO_LEN_BUF, VQ_ERR_WRONG_FLAGS}))
            return 0;
        if ((phase == VQ_FAULT_BEFORE_USED) && (err_inj.err_type != VQ_ERR_WRONG_USED_LEN))
            return 0;
        return err_inj.should_inject(q, phase);
    endfunction

    // ---------------- 事件 ----------------
    protected function vdev_event new_event(vdev_event_kind_e kind);
        vdev_event e;

        e = vdev_event::type_id::create("vdev_event");
        e.kind = kind;
        e.fn = bdf;
        return e;
    endfunction

    protected function void emit(vdev_event e);
        event_ap.write(e);
    endfunction

    protected function void reg_event(bit wr, string region, string field, int q, bit [63:0] val);
        vdev_event e;

        e = new_event(wr ? VDEV_REG_WR : VDEV_REG_RD);
        e.region = region;
        e.field = field;
        e.q = q;
        e.val = val;
        emit(e);
    endfunction
endclass
`endif
