// 目录层次：virtio_net_vip/src/devmodel；标准 virtio-net PCI 设备模型（1af4:1041，virtio 1.2）。
// 寄存器：BAR0 common_cfg@0x0、ISR@0x1000、device_cfg@0x2000；BAR2 notify（off=q，multiplier 4）；
// BAR4 MSI-X（底座）。数据路径：split/packed（含 INDIRECT）、TX→同对 RX 回环、ctrl VQ、事件抑制。
// 只依据收到的寄存器写与 DMA 读到的 ring 字节工作，不引用驱动侧对象；header 编解码自实现。
// 工作项编码：队列号 q（RX=偶、TX=奇、ctrl=2N；N 在协商 MQ 时为 max_pairs，否则为 1，virtio 1.2 §5.1.2）。
`ifndef VDEV_VIRTIO_PCI_SV
`define VDEV_VIRTIO_PCI_SV

class vdev_virtio_pci extends vdev_base;
    `uvm_component_utils(vdev_virtio_pci)

    localparam bit [31:0]   ISR_OFF     = 32'h1000;
    localparam bit [31:0]   DEVCFG_OFF  = 32'h2000;
    localparam int unsigned NOTIFY_MULT = 4;
    localparam bit [15:0]   NO_VECTOR   = 16'hffff;

    // 设备参数：init() 前由环境设置。
    bit [63:0]   device_features;
    int unsigned max_pairs;
    int unsigned queue_max;
    bit [47:0]   mac;
    bit [15:0]   mtu;

    typedef struct {
        bit [15:0] size;
        bit [15:0] msix;
        bit        enable;
        bit [63:0] desc;
        bit [63:0] driver;
        bit [63:0] device;
        bit [2:0]  addr_set;      // 自复位以来是否写过 desc/driver/device（bit0/1/2；地址 0 也合法）
        bit        in_reset;      // queue_reset 完成后读回 1，直到再次使能或设备复位
        bit [15:0] last_avail;    // split：自由计数的消费位置；packed：下一个槽号
        bit [15:0] used_idx;      // split：自由计数的 used 位置
        bit        wrap;          // packed：设备当前槽的 wrap
        bit        broken;
    } vq_t;

    typedef struct {
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] flags;
        bit [15:0] next;
        bit [15:0] id;
    } desc_t;

    protected vq_t       vqs[];
    protected bit [7:0]  status;
    protected bit [7:0]  status_before_reset;
    protected bit [31:0] dfselect;
    protected bit [31:0] gfselect;
    protected bit [63:0] driver_features;
    protected bit [15:0] config_msix;
    protected bit [15:0] qsel;
    protected bit [7:0]  isr;
    protected bit [7:0]  generation;
    protected int unsigned curr_pairs;

    function new(string name = "vdev_virtio_pci", uvm_component parent = null);
        super.new(name, parent);
        device_features = 0;
        device_features[VIRTIO_F_VERSION_1] = 1;
        max_pairs = 1;
        queue_max = 256;
        mac = 48'h02_00_00_00_00_01;
        mtu = 16'd1500;
        status = 0;
        status_before_reset = 0;
        generation = 0;
    endfunction

    function int unsigned num_queues();
        return 2 * max_pairs + (device_features[VIRTIO_NET_F_CTRL_VQ] ? 1 : 0);
    endfunction

    virtual function void init();
        bit [63:0] sizes[3];

        sizes[0] = 64'h4000;
        sizes[1] = 64'h1000;
        sizes[2] = 64'h1_0000;
        init_header(16'h1af4, 16'h1041, 24'h020000, 8'h01, sizes);
        vqs = new[num_queues()];
        add_virtio_cap(VIRTIO_PCI_CAP_COMMON_CFG, 0, 32'h0, 32'h40, 0);
        add_virtio_cap(VIRTIO_PCI_CAP_NOTIFY_CFG, 2, 32'h0, num_queues() * NOTIFY_MULT, NOTIFY_MULT);
        add_virtio_cap(VIRTIO_PCI_CAP_ISR_CFG, 0, ISR_OFF, 32'h4, 0);
        add_virtio_cap(VIRTIO_PCI_CAP_DEVICE_CFG, 0, DEVCFG_OFF, 32'h100, 0);
        add_msix(4, 32'h0, 32'h8000, 2 * max_pairs + 2);
        status = 0;
        reset_device();
    endfunction

    // virtio_pci_cap：cap_len、cfg_type、bar、offset、length（notify 另带 multiplier）。
    protected function void add_virtio_cap(bit [7:0] cfg_type, int unsigned bar, bit [31:0] off,
                                           bit [31:0] len, bit [31:0] mult);
        bit [7:0] body[];

        body = new[(cfg_type == VIRTIO_PCI_CAP_NOTIFY_CFG) ? 18 : 14];
        foreach (body[i])
            body[i] = 0;
        body[0] = body.size() + 2;
        body[1] = cfg_type;
        body[2] = bar;
        for (int unsigned b = 0; b < 4; b++) begin
            body[6 + b] = off[8*b +: 8];
            body[10 + b] = len[8*b +: 8];
            if (body.size() == 18)
                body[14 + b] = mult[8*b +: 8];
        end
        void'(add_cap(8'h09, body));
    endfunction

    // ---------------- 分类与协商结果 ----------------
    protected function bit is_packed();
        return driver_features[VIRTIO_F_RING_PACKED];
    endfunction
    // 已协商的数据队列数 2N 即 ctrl VQ 的队列号。
    protected function int unsigned data_queues();
        return driver_features[VIRTIO_NET_F_MQ] ? 2 * max_pairs : 2;
    endfunction
    // 已协商队列集合：数据队列加（协商 CTRL_VQ 时）ctrl VQ；其余队列号不可用。
    protected function bit queue_in_use(int unsigned q);
        return (q < data_queues()) || is_ctrl(q);
    endfunction
    protected function bit is_rx(int unsigned q);
        return (q < data_queues()) && ((q % 2) == 0);
    endfunction
    protected function bit is_tx(int unsigned q);
        return (q < data_queues()) && ((q % 2) == 1);
    endfunction
    protected function bit is_ctrl(int unsigned q);
        return (q == data_queues()) && driver_features[VIRTIO_NET_F_CTRL_VQ];
    endfunction
    protected function int unsigned hdr_len();
        if (driver_features[VIRTIO_NET_F_HASH_REPORT])
            return 20;
        return (driver_features[VIRTIO_F_VERSION_1] || driver_features[VIRTIO_NET_F_MRG_RXBUF]) ? 12 : 10;
    endfunction
    protected function bit [15:0] vector_or_none(bit [15:0] v);
        return (v < msix_vectors) ? v : NO_VECTOR;
    endfunction

    // ---------------- 复位 ----------------
    protected function void reset_vq(int unsigned q);
        vqs[q].size = queue_max;
        vqs[q].msix = NO_VECTOR;
        vqs[q].enable = 0;
        vqs[q].desc = 0;
        vqs[q].driver = 0;
        vqs[q].device = 0;
        vqs[q].addr_set = 0;
        vqs[q].in_reset = 0;
        vqs[q].last_avail = 0;
        vqs[q].used_idx = 0;
        vqs[q].wrap = 1;
        vqs[q].broken = 0;
    endfunction

    protected function void reset_device();
        quiesce();
        status = 0;
        driver_features = 0;
        dfselect = 0;
        gfselect = 0;
        config_msix = NO_VECTOR;
        qsel = 0;
        isr = 0;
        curr_pairs = 1;
        foreach (vqs[q])
            reset_vq(q);
    endfunction

    // ---------------- 寄存器镜像 ----------------
    protected function bit [511:0] common_image();
        bit [511:0] img;

        img = 0;
        img[8*'h00 +: 32] = dfselect;
        img[8*'h04 +: 32] = (dfselect == 0) ? device_features[31:0] :
                            ((dfselect == 1) ? device_features[63:32] : 32'h0);
        img[8*'h08 +: 32] = gfselect;
        img[8*'h0c +: 32] = (gfselect == 0) ? driver_features[31:0] :
                            ((gfselect == 1) ? driver_features[63:32] : 32'h0);
        img[8*'h10 +: 16] = config_msix;
        img[8*'h12 +: 16] = num_queues();
        img[8*'h14 +: 8]  = draining() ? status_before_reset : status;
        img[8*'h15 +: 8]  = generation;
        img[8*'h16 +: 16] = qsel;
        if (qsel < vqs.size()) begin
            // FEATURES_OK 之后，已协商集合以外的队列报告 queue_size 0（不可用）。
            img[8*'h18 +: 16] = ((status & DEV_STATUS_FEATURES_OK) && !queue_in_use(qsel)) ? 16'h0 : vqs[qsel].size;
            img[8*'h1a +: 16] = vqs[qsel].msix;
            img[8*'h1c +: 16] = vqs[qsel].enable;
            img[8*'h1e +: 16] = qsel;
            img[8*'h20 +: 64] = vqs[qsel].desc;
            img[8*'h28 +: 64] = vqs[qsel].driver;
            img[8*'h30 +: 64] = vqs[qsel].device;
            img[8*'h38 +: 16] = qsel;
            img[8*'h3a +: 16] = vqs[qsel].in_reset;
        end
        return img;
    endfunction

    protected function string common_field(bit [31:0] off, output int q);
        q = ((off >= 32'h18) && (off < 32'h3c)) ? int'(qsel) : -1;
        case (off)
            32'h00: return "device_feature_select";
            32'h04: return "device_feature";
            32'h08: return "driver_feature_select";
            32'h0c: return "driver_feature";
            32'h10: return "config_msix_vector";
            32'h12: return "num_queues";
            32'h14: return "device_status";
            32'h15: return "config_generation";
            32'h16: return "queue_select";
            32'h18: return "queue_size";
            32'h1a: return "queue_msix_vector";
            32'h1c: return "queue_enable";
            32'h1e: return "queue_notify_off";
            32'h20: return "queue_desc_lo";
            32'h24: return "queue_desc_hi";
            32'h28: return "queue_driver_lo";
            32'h2c: return "queue_driver_hi";
            32'h30: return "queue_device_lo";
            32'h34: return "queue_device_hi";
            32'h38: return "queue_notify_data";
            32'h3a: return "queue_reset";
            default: return $sformatf("0x%02h", off);
        endcase
    endfunction

    // virtio_net_config：mac、status(LINK_UP)、max_virtqueue_pairs、mtu、speed、duplex。
    protected function bit [2047:0] devcfg_image();
        bit [2047:0] img;

        img = 0;
        for (int unsigned i = 0; i < 6; i++)
            img[8*i +: 8] = mac[8*(5 - i) +: 8];
        img[8*6 +: 16]  = 16'h0001;
        img[8*8 +: 16]  = max_pairs;
        img[8*10 +: 16] = mtu;
        img[8*12 +: 32] = 32'd10000;
        img[8*16 +: 8]  = 8'h01;
        return img;
    endfunction

    protected function string devcfg_field(bit [31:0] off);
        if (off < 6)
            return "mac";
        case (off)
            32'h06: return "status";
            32'h08: return "max_virtqueue_pairs";
            32'h0a: return "mtu";
            32'h0c: return "speed";
            32'h10: return "duplex";
            default: return $sformatf("0x%02h", off);
        endcase
    endfunction

    // ---------------- MMIO ----------------
    virtual function bit [31:0] region_read(int unsigned bar, bit [31:0] off, int unsigned size);
        bit [2047:0] img;
        bit [31:0] v;
        int q;
        string field;

        v = 0;
        if ((bar == 0) && (off < 32'h40)) begin
            img = common_image();
            v = img[8*off +: 32];
            field = common_field(off, q);
            reg_event(0, "common_cfg", field, q, v & size_mask(size));
        end else if ((bar == 0) && (off >= ISR_OFF) && (off < ISR_OFF + 4)) begin
            if (off == ISR_OFF) begin
                v = isr;
                isr = 0;
            end
            reg_event(0, "isr", "isr", -1, v);
        end else if ((bar == 0) && (off >= DEVCFG_OFF) && (off < DEVCFG_OFF + 32'h100)) begin
            img = devcfg_image();
            v = img[8*(off - DEVCFG_OFF) +: 32];
            reg_event(0, "device_cfg", devcfg_field(off - DEVCFG_OFF), -1, v & size_mask(size));
        end
        return v;
    endfunction

    virtual function void region_write(int unsigned bar, bit [31:0] off, int unsigned size,
                                       bit [31:0] data);
        int q;
        string field;

        if ((bar == 2) && (off < num_queues() * NOTIFY_MULT)) begin
            notify(off / NOTIFY_MULT, data);
            return;
        end
        if ((bar == 0) && (off < 32'h40)) begin
            field = common_field(off, q);
            reg_event(1, "common_cfg", field, q, data);
            common_write(off, data);
            return;
        end
        // ISR 与 device_cfg 只读；其它偏移无寄存器。写被忽略但留痕。
        reg_event(1, ((bar == 0) && (off >= DEVCFG_OFF)) ? "device_cfg" : $sformatf("bar%0d", bar),
                  $sformatf("0x%0h", off), -1, data);
    endfunction

    protected function void common_write(bit [31:0] off, bit [31:0] data);
        bit valid_q;
        bit idle_q;

        valid_q = (qsel < vqs.size());
        idle_q = valid_q && !vqs[qsel].enable;
        case (off)
            32'h00: dfselect = data;
            32'h08: gfselect = data;
            32'h0c: if (!(status & DEV_STATUS_FEATURES_OK)) begin
                        if (gfselect == 0)
                            driver_features[31:0] = data;
                        else if (gfselect == 1)
                            driver_features[63:32] = data;
                    end
            32'h10: config_msix = vector_or_none(data[15:0]);
            32'h14: write_status(data[7:0]);
            32'h16: qsel = data[15:0];
            32'h18: if (idle_q) vqs[qsel].size = data[15:0];
            32'h1a: if (valid_q) vqs[qsel].msix = vector_or_none(data[15:0]);
            32'h1c: if (valid_q) queue_enable(qsel, data[0]);
            32'h20, 32'h24, 32'h28, 32'h2c, 32'h30, 32'h34:
                if (idle_q)
                    queue_addr_write(off, data);
            32'h3a: if (valid_q && data[0] && driver_features[VIRTIO_F_RING_RESET]) begin
                        reset_vq(qsel);
                        vqs[qsel].in_reset = 1;
                    end
            default: ;
        endcase
    endfunction

    // 队列地址半字写：0x20/0x28/0x30 为 desc/driver/device 低 32 位，+4 为高 32 位。
    protected function void queue_addr_write(bit [31:0] off, bit [31:0] data);
        int unsigned which;
        bit [63:0] a;

        which = (off - 32'h20) / 8;
        a = (which == 0) ? vqs[qsel].desc : ((which == 1) ? vqs[qsel].driver : vqs[qsel].device);
        if (off[2])
            a[63:32] = data;
        else
            a[31:0] = data;
        case (which)
            0: vqs[qsel].desc = a;
            1: vqs[qsel].driver = a;
            default: vqs[qsel].device = a;
        endcase
        vqs[qsel].addr_set[which] = 1;
    endfunction

    protected function void write_status(bit [7:0] v);
        bit [7:0] old;
        vdev_event e;

        old = status;
        if (v == 0) begin
            status_before_reset = status;
            reset_device();
        end else begin
            if ((v & DEV_STATUS_FEATURES_OK) && !(old & DEV_STATUS_FEATURES_OK)) begin
                e = new_event(VDEV_FEATURES);
                e.dev_offered = device_features;
                e.drv_accepted = driver_features;
                emit(e);
                if (((driver_features & ~device_features) != 0) ||
                    (device_features[VIRTIO_F_VERSION_1] && !driver_features[VIRTIO_F_VERSION_1]))
                    v = v & ~DEV_STATUS_FEATURES_OK;
            end
            // DEVICE_NEEDS_RESET 由设备置位，只有复位能清除。
            status = v | (old & DEV_STATUS_DEVICE_NEEDS_RESET);
        end
        e = new_event(VDEV_STATUS);
        e.from_status = old;
        e.to_status = status;
        emit(e);
    endfunction

    protected function string enable_check(int unsigned q);
        if (!(status & DEV_STATUS_FEATURES_OK))
            return "FEATURES_OK not set";
        if (!queue_in_use(q))
            return $sformatf("queue %0d is outside the negotiated queue set", q);
        if ((vqs[q].size == 0) || (vqs[q].size > queue_max))
            return $sformatf("queue_size %0d outside 1..%0d", vqs[q].size, queue_max);
        if (!is_packed() && ((vqs[q].size & (vqs[q].size - 1)) != 0))
            return "split queue_size is not a power of 2";
        if (!vqs[q].addr_set[0])
            return "queue_desc not written";
        if (!vqs[q].addr_set[1])
            return "queue_driver not written";
        if (!vqs[q].addr_set[2])
            return "queue_device not written";
        return "";
    endfunction

    protected function void queue_enable(int unsigned q, bit v);
        string why;
        vdev_event e;

        if (!v) begin
            // virtio 1.x 驱动不应写 0；按停队处理，后续 notify 被忽略。
            vqs[q].enable = 0;
            return;
        end
        if (vqs[q].enable)
            return;
        why = enable_check(q);
        if (why != "") begin
            `uvm_warning("VDEV_QUEUE", $sformatf("BDF 0x%04h queue %0d enable rejected: %s", bdf, q, why))
            return;
        end
        vqs[q].enable = 1;
        vqs[q].in_reset = 0;
        vqs[q].last_avail = 0;
        vqs[q].used_idx = 0;
        vqs[q].wrap = 1;
        vqs[q].broken = 0;
        e = new_event(VDEV_QUEUE_CFG);
        e.q = q;
        e.size = vqs[q].size;
        e.vector = vqs[q].msix;
        e.enable = 1;
        e.ring_fmt = is_packed() ? "packed" : "split";
        emit(e);
    endfunction

    protected function void notify(int unsigned slot, bit [31:0] data);
        vdev_event e;
        int unsigned q;

        q = data[15:0];
        e = new_event(VDEV_NOTIFY);
        e.q = q;
        if (driver_features[VIRTIO_F_NOTIFICATION_DATA]) begin
            e.next_idx = is_packed() ? data[30:16] : data[31:16];
            e.wrap = is_packed() ? data[31] : 1'b0;
        end
        emit(e);
        n_notify++;
        if ((q != slot) || (q >= vqs.size()) || !vqs[q].enable || !(status & DEV_STATUS_DRIVER_OK)) begin
            `uvm_warning("VDEV_QUEUE", $sformatf(
                "BDF 0x%04h ignored notify data=0x%08h at slot %0d (queue disabled, mismatched or before DRIVER_OK)",
                bdf, data, slot))
            return;
        end
        // 协商 MQ 后，VQ_PAIRS_SET 打开的队列对之外（virtio 1.2 §5.1.6.5.5）：驱动不得在 TX 队列放包，
        // 告警且不发送；设备不得向 RX 队列放包，但驱动可以先补 buffer（Linux virtnet_open 对全部
        // max_queue_pairs 补 RX），只记 notify、不调度，对数扩大后 inject_rx 调度时再读 avail。
        if (driver_features[VIRTIO_NET_F_MQ] && (is_rx(q) || is_tx(q)) && (q / 2 >= curr_pairs)) begin
            if (is_tx(q))
                `uvm_warning("VDEV_QUEUE", $sformatf(
                    "BDF 0x%04h ignored notify on queue %0d beyond the active queue pairs (%0d)",
                    bdf, q, curr_pairs))
            return;
        end
        schedule(q);
    endfunction

    // 链非法：停用队列、置 DEVICE_NEEDS_RESET 并发配置中断（MSI-X 未使能时置 ISR bit1）。
    protected function void device_error(int unsigned q, string why);
        bit [7:0] old;
        vdev_event e;

        `uvm_warning("VDEV_RING", $sformatf("BDF 0x%04h queue %0d: %s", bdf, q, why))
        vqs[q].broken = 1;
        old = status;
        status = status | DEV_STATUS_DEVICE_NEEDS_RESET;
        e = new_event(VDEV_STATUS);
        e.from_status = old;
        e.to_status = status;
        emit(e);
        // 函数上下文不能直接发 MSI-X：置 PBA 并交给 worker 投递（屏蔽时保持挂起）。
        if (msix_enabled()) begin
            if (config_msix < msix_vectors) begin
                msix_pending[config_msix] = 1;
                irq_q.push_back(config_msix);
                -> work_ev;
            end
        end else
            isr = isr | 8'h02;
    endfunction

    // ---------------- 数据路径 ----------------
    virtual task service_queue(int unsigned q);
        int unsigned my_epoch;
        int unsigned id;
        int unsigned slot;
        int unsigned slots;
        int unsigned used_len;
        bit got;
        bit ok;
        desc_t chain[$];

        my_epoch = epoch;
        while ((my_epoch == epoch) && (q < vqs.size()) && vqs[q].enable && !vqs[q].broken &&
               (status & DEV_STATUS_DRIVER_OK)) begin
            if (is_rx(q) && !has_backlog(q / 2))
                break;
            fetch(q, got, id, slot, slots, chain);
            if (!got || (my_epoch != epoch) || !chain_ok(q, chain))
                break;
            consume(q, chain, used_len, ok);
            if (!ok || (my_epoch != epoch))
                break;
            if (!vqs[q].enable)          // 处理期间被停队或 queue_reset：不再写回
                break;
            if (take_fault(q, VQ_FAULT_BEFORE_USED))
                used_len++;
            push_used(q, id, slot, slots, used_len, ok);
            if (!ok)
                break;
        end
    endtask

    // 取下一条可用链：split 读 avail，packed 按 wrap 判断槽可用；读完整条链（展开 INDIRECT）。
    protected task fetch(int unsigned q, output bit got, output int unsigned id,
                         output int unsigned slot, output int unsigned slots, ref desc_t chain[$]);
        bit [7:0] b[];
        bit ok;
        bit [15:0] avail_idx;
        bit [15:0] flags;

        got = 0;
        id = 0;
        slot = vqs[q].last_avail;
        slots = 0;
        chain.delete();
        if (!is_packed()) begin
            dma_rd(vqs[q].driver + 2, 2, b, ok);
            if (!ok)
                return;
            avail_idx = {b[1], b[0]};
            // EVENT_IDX：环空时先发布 avail_event=last_avail 再复读 avail idx，避免漏掉
            // 驱动在两次读之间按旧 avail_event 抑制的通知。
            if ((avail_idx == vqs[q].last_avail) && driver_features[VIRTIO_F_RING_EVENT_IDX]) begin
                b = new[2];
                b[0] = vqs[q].last_avail[7:0];
                b[1] = vqs[q].last_avail[15:8];
                dma_wr(vqs[q].device + 4 + 8 * vqs[q].size, b, ok);
                if (!ok)
                    return;
                dma_rd(vqs[q].driver + 2, 2, b, ok);
                if (!ok)
                    return;
                avail_idx = {b[1], b[0]};
            end
            if (avail_idx == vqs[q].last_avail)
                return;
            if (16'(avail_idx - vqs[q].last_avail) > vqs[q].size) begin
                device_error(q, $sformatf("avail idx %0d is more than queue_size ahead of %0d",
                                          avail_idx, vqs[q].last_avail));
                return;
            end
            dma_rd(vqs[q].driver + 4 + 2 * (vqs[q].last_avail % vqs[q].size), 2, b, ok);
            if (!ok)
                return;
            id = {b[1], b[0]};
            vqs[q].last_avail++;
            slots = 1;
            read_split_chain(q, id, ok, chain);
        end else begin
            dma_rd(vqs[q].desc + 16 * slot + 14, 2, b, ok);
            if (!ok)
                return;
            flags = {b[1], b[0]};
            if ((flags[7] != vqs[q].wrap) || (flags[15] == vqs[q].wrap))
                return;
            read_packed_chain(q, ok, id, slots, chain);
        end
        if (!ok) begin
            device_error(q, "malformed descriptor chain (bad index, loop, nested/empty indirect or DMA fault)");
            return;
        end
        got = 1;
        if (take_fault(q, VQ_FAULT_PRE_DEVICE_READ)) begin
            if (err_inj.err_type == VQ_ERR_ZERO_LEN_BUF)
                chain[0].len = 0;
            else
                chain[0].flags = chain[0].flags ^ VIRTQ_DESC_F_WRITE;
        end
    endtask

    protected task read_desc(bit [63:0] addr, bit packed_fmt, output bit ok, output desc_t d);
        bit [7:0] b[];

        d = '{default: 0};
        dma_rd(addr, 16, b, ok);
        if (!ok)
            return;
        d.addr = {b[7], b[6], b[5], b[4], b[3], b[2], b[1], b[0]};
        d.len = {b[11], b[10], b[9], b[8]};
        if (packed_fmt) begin
            d.id = {b[13], b[12]};
            d.flags = {b[15], b[14]};
        end else begin
            d.flags = {b[13], b[12]};
            d.next = {b[15], b[14]};
        end
    endtask

    // INDIRECT 表：split 格式按 next 链接，packed 格式顺序排列；禁止嵌套。
    // split 表内 next 越界或成环（跳数超过表项数）视为非法，ok=0，由 fetch 报 device_error。
    protected task read_indirect(desc_t ind, bit packed_fmt, output bit ok, ref desc_t chain[$]);
        desc_t d;
        int unsigned n;
        int unsigned i;

        ok = 0;
        n = ind.len / 16;
        if ((ind.len == 0) || ((ind.len % 16) != 0))
            return;
        i = 0;
        for (int unsigned hop = 0; hop < n; hop++) begin
            read_desc(ind.addr + 16 * i, packed_fmt, ok, d);
            if (!ok || (d.flags & VIRTQ_DESC_F_INDIRECT)) begin
                ok = 0;
                return;
            end
            chain.push_back(d);
            if (packed_fmt) begin
                i++;
                continue;
            end
            if (!(d.flags & VIRTQ_DESC_F_NEXT))
                return;                     // ok=1：链在表内正常结束
            if (d.next >= n) begin
                ok = 0;
                return;
            end
            i = d.next;
        end
        ok = packed_fmt;                    // split 跳数用尽仍有 NEXT：成环
    endtask

    protected task read_split_chain(int unsigned q, int unsigned head, output bit ok,
                                    ref desc_t chain[$]);
        desc_t d;
        int unsigned idx;
        int unsigned guard;

        ok = 0;
        idx = head;
        guard = 0;
        forever begin
            if ((idx >= vqs[q].size) || (guard++ > vqs[q].size))
                return;
            read_desc(vqs[q].desc + 16 * idx, 0, ok, d);
            if (!ok)
                return;
            if (d.flags & VIRTQ_DESC_F_INDIRECT) begin
                read_indirect(d, 0, ok, chain);
                return;
            end
            chain.push_back(d);
            if (!(d.flags & VIRTQ_DESC_F_NEXT))
                break;
            idx = d.next;
        end
        ok = 1;
    endtask

    // packed 链：从当前槽顺序读到无 NEXT；buffer id 取链尾描述符；推进槽与 wrap。
    protected task read_packed_chain(int unsigned q, output bit ok, output int unsigned id,
                                     output int unsigned slots, ref desc_t chain[$]);
        desc_t d;

        ok = 0;
        id = 0;
        slots = 0;
        forever begin
            if (slots >= vqs[q].size)
                return;
            read_desc(vqs[q].desc + 16 * vqs[q].last_avail, 1, ok, d);
            if (!ok)
                return;
            slots++;
            vqs[q].last_avail++;
            if (vqs[q].last_avail == vqs[q].size) begin
                vqs[q].last_avail = 0;
                vqs[q].wrap = ~vqs[q].wrap;
            end
            id = d.id;
            if (d.flags & VIRTQ_DESC_F_INDIRECT) begin
                read_indirect(d, 1, ok, chain);
                return;
            end
            chain.push_back(d);
            if (!(d.flags & VIRTQ_DESC_F_NEXT))
                break;
        end
        ok = 1;
    endtask

    protected function bit chain_ok(int unsigned q, desc_t chain[$]);
        bit seen_write;
        string why;

        seen_write = 0;
        why = "";
        foreach (chain[i]) begin
            if ((why == "") && (chain[i].len == 0))
                why = $sformatf("descriptor %0d has zero length", i);
            if (chain[i].flags & VIRTQ_DESC_F_WRITE)
                seen_write = 1;
            else if ((why == "") && seen_write)
                why = "device-readable descriptor after a writable one";
        end
        if ((why == "") && is_tx(q) && seen_write)
            why = "TX chain contains a writable descriptor";
        if ((why == "") && is_rx(q) && !(chain[0].flags & VIRTQ_DESC_F_WRITE))
            why = "RX chain starts with a device-readable descriptor";
        if (why == "")
            return 1;
        device_error(q, why);
        return 0;
    endfunction

    protected task read_readable(desc_t chain[$], output bit ok, ref bit [7:0] data[$]);
        bit [7:0] b[];

        data.delete();
        ok = 1;
        foreach (chain[i]) begin
            if (chain[i].flags & VIRTQ_DESC_F_WRITE)
                continue;
            dma_rd(chain[i].addr, chain[i].len, b, ok);
            if (!ok)
                return;
            foreach (b[j])
                data.push_back(b[j]);
        end
    endtask

    protected task consume(int unsigned q, desc_t chain[$], output int unsigned used_len,
                           output bit ok);
        bit [7:0] data[$];

        used_len = 0;
        ok = 1;
        if (is_tx(q)) begin
            read_readable(chain, ok, data);
            if (ok)
                tx_frame(q, chain, data);
        end else if (is_rx(q))
            rx_frame(q, chain, used_len, ok);
        else if (is_ctrl(q))
            ctrl_cmd(q, chain, used_len, ok);
    endtask

    protected function vdev_event chain_event(int unsigned q, desc_t chain[$]);
        vdev_event e;

        e = new_event(VDEV_DESC_CHAIN);
        e.q = q;
        foreach (chain[i]) begin
            e.seg_len.push_back(chain[i].len);
            e.seg_flags.push_back(chain[i].flags);
        end
        return e;
    endfunction

    protected function virtio_net_hdr_t decode_hdr(bit [7:0] d[$]);
        virtio_net_hdr_t h;

        h = '{default: 0};
        if (d.size() < 10)
            return h;
        h.flags = d[0];
        h.gso_type = d[1];
        h.hdr_len = {d[3], d[2]};
        h.gso_size = {d[5], d[4]};
        h.csum_start = {d[7], d[6]};
        h.csum_offset = {d[9], d[8]};
        if ((hdr_len() >= 12) && (d.size() >= 12))
            h.num_buffers = {d[11], d[10]};
        return h;
    endfunction

    protected function void encode_hdr(virtio_net_hdr_t h, ref bit [7:0] out[$]);
        out.delete();
        out = '{h.flags, h.gso_type, h.hdr_len[7:0], h.hdr_len[15:8], h.gso_size[7:0],
                h.gso_size[15:8], h.csum_start[7:0], h.csum_start[15:8], h.csum_offset[7:0],
                h.csum_offset[15:8]};
        if (hdr_len() >= 12) begin
            out.push_back(h.num_buffers[7:0]);
            out.push_back(h.num_buffers[15:8]);
        end
        while (out.size() < hdr_len())
            out.push_back(8'h00);
    endfunction

    // TX：解 header、发 desc_chain/pkt 事件，帧回环到同对 RX。
    protected function void tx_frame(int unsigned q, desc_t chain[$], bit [7:0] data[$]);
        vdev_event e;
        bit [7:0] frame[$];

        e = chain_event(q, chain);
        e.has_hdr = 1;
        e.hdr = decode_hdr(data);
        emit(e);
        if (data.size() > hdr_len())
            frame = data[hdr_len():$];
        e = new_event(VDEV_PKT);
        e.dir = "tx";
        e.q = q;
        e.bytes = frame;
        e.len = frame.size();
        emit(e);
        inject_rx(q / 2, frame);
    endfunction

    // RX：header（num_buffers=1）+ 帧写进可写描述符；单链放不下时丢帧（buffer 以 len 0 归还）。
    protected task rx_frame(int unsigned q, desc_t chain[$], output int unsigned used_len,
                            output bit ok);
        virtio_net_hdr_t hdr;
        bit [7:0] payload[$];
        bit [7:0] part[];
        frame_t f;
        int unsigned room;
        int unsigned cursor;
        int unsigned n;
        vdev_event e;

        used_len = 0;
        ok = 1;
        f = rx_backlog[q / 2][0];
        void'(rx_backlog[q / 2].pop_front());
        hdr = '{default: 0};
        hdr.num_buffers = 1;
        encode_hdr(hdr, payload);
        foreach (f.data[i])
            payload.push_back(f.data[i]);
        room = 0;
        foreach (chain[i])
            room += chain[i].len;
        if (payload.size() > room) begin
            `uvm_warning("VDEV_RX", $sformatf(
                "BDF 0x%04h queue %0d dropped a %0d-byte frame: buffer chain holds %0d bytes",
                bdf, q, payload.size(), room))
            return;
        end
        cursor = 0;
        foreach (chain[i]) begin
            if (cursor >= payload.size())
                break;
            n = payload.size() - cursor;
            if (n > chain[i].len)
                n = chain[i].len;
            part = new[n];
            foreach (part[j])
                part[j] = payload[cursor + j];
            dma_wr(chain[i].addr, part, ok);
            if (!ok)
                return;
            cursor += n;
        end
        e = chain_event(q, chain);
        e.has_hdr = 1;
        e.hdr = hdr;
        emit(e);
        e = new_event(VDEV_PKT);
        e.dir = "rx";
        e.q = q;
        e.bytes = f.data;
        e.len = f.data.size();
        emit(e);
        used_len = payload.size();
    endtask

    // ctrl：可读部分 {class, cmd, data...}，最后一个可写描述符的首字节是 ack。
    protected task ctrl_cmd(int unsigned q, desc_t chain[$], output int unsigned used_len,
                            output bit ok);
        bit [7:0] req[$];
        bit [7:0] ack_b[];
        bit [7:0] args[$];
        vdev_event e;

        used_len = 0;
        read_readable(chain, ok, req);
        if (!ok)
            return;
        if ((req.size() < 2) || !(chain[chain.size() - 1].flags & VIRTQ_DESC_F_WRITE)) begin
            device_error(q, "malformed control command");
            ok = 0;
            return;
        end
        if (req.size() > 2)
            args = req[2:$];
        ack_b = new[1];
        ack_b[0] = ctrl_apply(req[0], req[1], args);
        dma_wr(chain[chain.size() - 1].addr, ack_b, ok);
        if (!ok)
            return;
        e = new_event(VDEV_CTRL);
        e.q = q;
        e.ctrl_class = req[0];
        e.ctrl_cmd = req[1];
        e.ctrl_data = args;
        e.ack = ack_b[0];
        emit(e);
        used_len = 1;
    endtask

    // virtio 1.2 §5.1.6.5：未协商对应特性或参数非法时 ACK_ERR(1)。
    protected function bit [7:0] ctrl_apply(bit [7:0] cls, bit [7:0] cmd, bit [7:0] data[$]);
        bit [15:0] pairs;

        case (cls)
            VIRTIO_NET_CTRL_MQ: begin
                if (!driver_features[VIRTIO_NET_F_MQ] || (cmd != VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET) ||
                    (data.size() != 2))
                    return 1;
                pairs = {data[1], data[0]};
                if ((pairs == 0) || (pairs > max_pairs))
                    return 1;
                curr_pairs = pairs;
                return 0;
            end
            VIRTIO_NET_CTRL_RX:
                return (driver_features[VIRTIO_NET_F_CTRL_RX] && (data.size() == 1) &&
                        ((cmd <= 1) || ((cmd <= 5) && driver_features[VIRTIO_NET_F_CTRL_RX_EXTRA]))) ? 0 : 1;
            VIRTIO_NET_CTRL_MAC: begin
                if ((cmd == VIRTIO_NET_CTRL_MAC_ADDR_SET) && driver_features[VIRTIO_NET_F_CTRL_MAC_ADDR] &&
                    (data.size() == 6)) begin
                    mac = {data[0], data[1], data[2], data[3], data[4], data[5]};
                    generation++;
                    return 0;
                end
                return ((cmd == VIRTIO_NET_CTRL_MAC_TABLE_SET) && driver_features[VIRTIO_NET_F_CTRL_RX]) ? 0 : 1;
            end
            VIRTIO_NET_CTRL_VLAN:
                return (driver_features[VIRTIO_NET_F_CTRL_VLAN] && (cmd <= 1) && (data.size() == 2)) ? 0 : 1;
            VIRTIO_NET_CTRL_ANNOUNCE:
                return (driver_features[VIRTIO_NET_F_GUEST_ANNOUNCE] && (cmd == 0)) ? 0 : 1;
            default:
                return 1;
        endcase
    endfunction

    // 写回 used：split 写 used 元素再写 used idx；packed 在链首槽写 len/id，最后写 flags。
    protected task push_used(int unsigned q, int unsigned id, int unsigned slot, int unsigned slots,
                             int unsigned len, output bit ok);
        bit [7:0] b[];
        bit [15:0] old_idx;
        bit slot_wrap;
        bit wrapped;
        vdev_event e;

        if (!is_packed()) begin
            b = new[8];
            for (int unsigned i = 0; i < 4; i++) begin
                b[i] = id >> (8 * i);
                b[4 + i] = len >> (8 * i);
            end
            dma_wr(vqs[q].device + 4 + 8 * (vqs[q].used_idx % vqs[q].size), b, ok);
            if (!ok)
                return;
            old_idx = vqs[q].used_idx;
            vqs[q].used_idx++;
            b = new[2];
            b[0] = vqs[q].used_idx[7:0];
            b[1] = vqs[q].used_idx[15:8];
            dma_wr(vqs[q].device + 2, b, ok);
        end else begin
            // 按序处理：used 位置即链首槽，used wrap 即链首槽的 wrap（取链已推进 wrap，越过环尾则取反）。
            old_idx = slot;
            wrapped = ((slot + slots) >= vqs[q].size);
            slot_wrap = wrapped ? ~vqs[q].wrap : vqs[q].wrap;
            b = new[6];
            for (int unsigned i = 0; i < 4; i++)
                b[i] = len >> (8 * i);
            b[4] = id[7:0];
            b[5] = id[15:8];
            dma_wr(vqs[q].desc + 16 * slot + 8, b, ok);
            if (!ok)
                return;
            b = new[2];
            b[0] = slot_wrap ? 8'h80 : 8'h00;
            b[1] = slot_wrap ? 8'h80 : 8'h00;
            dma_wr(vqs[q].desc + 16 * slot + 14, b, ok);
        end
        if (!ok)
            return;
        n_complete++;
        e = new_event(VDEV_COMPLETE);
        e.q = q;
        e.id = id;
        e.len = len;
        emit(e);
        used_notify(q, old_idx, wrapped);
    endtask

    // 事件抑制：split 按 EVENT_IDX 的 used_event 或 avail.flags NO_INTERRUPT；packed 读驱动事件抑制区
    // {off_wrap, flags}：0 启用、1 禁用、2 按描述符（仅 EVENT_IDX 协商时有效，按 off_wrap 判断；
    // 本次写回越过环尾时总是通知，同 QEMU signalled_used_valid 语义）。
    // old_idx：split 为写回前的 used idx，packed 为写回前的 used 槽号；wrapped 仅 packed 使用。
    protected task used_notify(int unsigned q, bit [15:0] old_idx, bit wrapped);
        bit [7:0] b[];
        bit [15:0] ev;
        bit [15:0] new_idx;
        bit ok;
        bit need;

        if (!is_packed() && driver_features[VIRTIO_F_RING_EVENT_IDX]) begin
            dma_rd(vqs[q].driver + 4 + 2 * vqs[q].size, 2, b, ok);
            ev = ok ? {b[1], b[0]} : 16'h0;
            need = ok && (16'(vqs[q].used_idx - ev - 1) < 16'(vqs[q].used_idx - old_idx));
        end else if (!is_packed()) begin
            dma_rd(vqs[q].driver, 2, b, ok);
            need = ok && !b[0][0];
        end else begin
            dma_rd(vqs[q].driver, 4, b, ok);
            need = ok && (b[2][1:0] != 2'b01);
            if (need && (b[2][1:0] == 2'b10) && driver_features[VIRTIO_F_RING_EVENT_IDX] && !wrapped) begin
                ev = {1'b0, b[1][6:0], b[0]};
                if (b[1][7] != vqs[q].wrap)
                    ev = ev - vqs[q].size;
                new_idx = vqs[q].last_avail;
                need = (16'(new_idx - ev - 1) < 16'(new_idx - old_idx));
            end
        end
        if (!need)
            return;
        if (msix_enabled())
            raise_irq(vqs[q].msix);
        else
            isr = isr | 8'h01;
    endtask
endclass
`endif
