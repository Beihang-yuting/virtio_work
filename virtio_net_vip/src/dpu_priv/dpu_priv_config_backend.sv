// 目录层次：src/dpu_priv；DPU 私有设备的寄存器级配置后端：通用 ops/FSM 对私有 Function 的全部设备副作用
// 都经这里，按真实驱动 icpu-kernel-driver（lance_net_mailbox@f2c9cd6）AF 路径的寄存器序列访问设备；
// 序列表与疑点见 devmodel/vdev_dpu_priv.sv 文件头（本后端实现其中 #1–#8、#10、#16、#17、#20、#21、#24、#25、
// #27–#29、#31、#33）。依赖 transport 的 BAR accessor 与 custom_virtqueue；保存冻结的队列参数表与已配置队列，
// 不持有 Host 内存或映射。
// 私有设备没有 virtio status/feature/device-config：status 是驱动侧影子值（复位清零），特性恒 0，device
// config 全零；队列上限为私有默认环大小。VIP 私有数据面固定 polling：不编程 PCI MSI-X 表，但按驱动建立
// 设备侧 MSI-X 映射。只实现 pfvf_id=0 的 AF 路径（PF/VF mailbox 未建模）。
// 全局资源（M-9）：gq = gv = 队列对号（local_qid>>1），gfid=0。
`ifndef DPU_PRIV_CONFIG_BACKEND_SV
`define DPU_PRIV_CONFIG_BACKEND_SV

class dpu_priv_config_backend extends virtio_config_backend;
    `uvm_object_utils(dpu_priv_config_backend)

    // 驱动 register.h / af_mng.h / mailbox.h 的地址（BAR0，除注明 BAR2）。
    localparam bit [31:0] QINFO_BDF         = 32'h0000_0004;   // BAR2
    localparam bit [31:0] QINFO_HOST        = 32'h0000_000c;   // BAR2
    localparam bit [31:0] AF_DECLARATION    = 32'h000_1010;
    localparam bit [31:0] QID_MAP_SEL       = 32'h002_0044;
    localparam bit [31:0] QID_MAP_BASE      = 32'h002_8000;
    localparam bit [31:0] MSIX_CTRL_BASE    = 32'h004_8000;
    localparam bit [31:0] MSIX_INFO_BASE    = 32'h005_4000;
    localparam bit [31:0] BDF_MAP_BASE      = 32'h005_6000;
    localparam bit [31:0] MB_AF_HOST        = 32'h006_0040;
    localparam bit [31:0] MSIX_LINEAR_BASE  = 32'h00c_0000;
    localparam bit [31:0] VTX_RESET         = 32'h088_0100;
    localparam bit [31:0] VTX_RESET_DONE    = 32'h088_0104;
    localparam bit [31:0] VTX_RAM_CFG       = 32'h088_0130;
    localparam bit [31:0] VTX_CONTENT       = 32'h088_0134;
    localparam bit [31:0] VTX_STAT_CLR      = 32'h088_0154;   // vtx_stat_clr_cfg：{en[31], q_num[24:16], start_q[15:0]}
    localparam bit [31:0] VTX_STAT_CLR_DONE = 32'h088_0158;
    localparam bit [31:0] VTX_PARA_RD       = 32'h089_0000;
    localparam bit [31:0] VRX_RESET         = 32'h090_0108;
    localparam bit [31:0] VRX_RESET_DONE    = 32'h090_010c;
    localparam bit [31:0] VRX_WR_CFG        = 32'h090_0200;
    localparam bit [31:0] VRX_CONTENT       = 32'h090_0204;
    localparam bit [31:0] VRX_RD_CFG        = 32'h090_0210;
    localparam bit [31:0] VRX_RD_DATA       = 32'h090_0214;
    localparam bit [31:0] VRX_TAIL          = 32'h090_2000;
    localparam bit [31:0] QSCH_STATE        = 32'h0b2_2000;
    localparam bit [31:0] SOFT_RESET        = 32'h100_0014;
    // 驱动 init_interrupt_scheme：needed = num_lan_msix + 1（mailbox）+ DPU_AF_EXTRA_INTR_NUM-1（=13）。
    localparam int unsigned AF_EXTRA_INTR   = 13;

    protected dpu_priv_queue_config  queue_cfg[int unsigned];
    protected int unsigned           default_size;
    protected int unsigned           rx_size;
    protected int unsigned           pairs;
    protected bit [7:0]              status_shadow;
    protected bit                    probed;
    protected bit [2:0]              host;
    protected bit                    qid_bank;
    protected virtio_queue_program_t active[int unsigned];

    function new(string name = "dpu_priv_config_backend");
        super.new(name);
        default_size = 0;
        rx_size = 0;
        pairs = 0;
        status_shadow = 0;
        probed = 0;
        host = 0;
        qid_bank = 0;
    endfunction

    // 冻结一份已校验的私有配置（调用方先 validate，且 ops 无活动队列）。
    function void bind_private(dpu_priv_driver_config cfg, int unsigned qpairs);
        default_size = cfg.default_queue_size;
        rx_size = cfg.rx_buf_size;
        pairs = qpairs;
        queue_cfg.delete();
        for (int unsigned qid = 0; qid < qpairs * 2; qid++)
            queue_cfg[qid] = cfg.resolve_queue(qid);
        status_shadow = 0;
    endfunction

    // ---------------- MMIO 与轮询 ----------------
    protected task wr0(bit [31:0] off, bit [31:0] v);
        transport.bar.write_reg(0, off, 4, v);
    endtask

    protected task rd0(bit [31:0] off, output bit [31:0] v);
        bit [31:0] d;

        transport.bar.read_reg(0, off, 4, d);
        v = d;
    endtask

    protected task wr2(bit [31:0] off, bit [31:0] v);
        transport.bar.write_reg(2, off, 4, v);
    endtask

    protected task rd2(bit [31:0] off, output bit [31:0] v);
        bit [31:0] d;

        transport.bar.read_reg(2, off, 4, d);
        v = d;
    endtask

    // 读到 (v & mask) == want 为止；超时返回 0（不报错，由调用方决定）。上限取 queue_reset_timeout_ns。
    protected task poll0(bit [31:0] off, bit [31:0] mask, bit [31:0] want, output bit ok);
        bit [31:0] v;
        int unsigned waited;
        int unsigned interval;
        int unsigned limit;

        interval = (transport.wait_pol.default_poll_interval_ns == 0) ? 1 :
                   transport.wait_pol.default_poll_interval_ns;
        limit = transport.wait_pol.effective_timeout(transport.wait_pol.queue_reset_timeout_ns);
        waited = 0;
        forever begin
            rd0(off, v);
            if ((v & mask) == want) begin
                ok = 1;
                return;
            end
            if (waited >= limit) begin
                ok = 0;
                return;
            end
            #(interval * 1ns);
            waited += interval;
        end
    endtask

    // ---------------- 参数字 ----------------
    // VTX DW2：q_depth[3:0]、queue_en[4]、seg_en[7]=1、sport_type[14:12]=host、dma_msix[25:15]=gv。
    protected function bit [31:0] vtx_dw2(virtio_queue_program_t q, bit en);
        bit [31:0] v;

        v = 0;
        v[3:0] = $clog2(q.queue_size);
        v[4] = en;
        v[7] = 1'b1;
        v[14:12] = host;
        v[25:15] = q.local_qid >> 1;
        return v;
    endfunction

    // VRX DW2：q_depth[3:0]、queue_en[4]、dport_type[8:6]=host、dport_id[18:9]=gfid(0)、dma_msix[29:19]=gv。
    protected function bit [31:0] vrx_dw2(virtio_queue_program_t q, bit en);
        bit [31:0] v;

        v = 0;
        v[3:0] = $clog2(q.queue_size);
        v[4] = en;
        v[8:6] = host;
        v[29:19] = q.local_qid >> 1;
        return v;
    endfunction

    protected task write_vtx(int unsigned gq, bit [31:0] dw[4]);
        for (int unsigned i = 0; i < 4; i++)
            wr0(VTX_CONTENT + 4 * i, dw[i]);
        wr0(VTX_RAM_CFG, gq);
        wr0(VTX_RAM_CFG, gq | 32'h2000);
    endtask

    protected task read_vtx(int unsigned gq, output bit [31:0] dw[4]);
        bit [31:0] v;

        for (int unsigned i = 0; i < 4; i++) begin
            rd0(VTX_PARA_RD + 16 * gq + 4 * i, v);
            dw[i] = v;
        end
    endtask

    // #21 fill_qid_map_table：128 项逐项写 4 DW 再读回；本 Function 的队列对 i=local_qid>>1 有效（gq=i），
    // 其余写无效项；最后置 bank 就绪并读回，下次换另一 bank。
    protected task write_qid_map(bit [63:0] bar0, output bit ok);
        bit valid[int unsigned];
        bit [31:0] e[4];
        bit [31:0] v;
        bit [31:0] base;

        ok = 0;
        foreach (queue_cfg[qid])
            valid[queue_cfg[qid].local_qid >> 1] = 1;
        for (int unsigned i = 0; i < 128; i++) begin
            if (valid.exists(i)) begin
                e[0] = {bar0[31:7], i[5], i[4:0], 1'b1};
                e[1] = {host, bar0[60:32]};
                e[2] = {21'h0, i[10:0]};
            end else begin
                e[0] = 32'hffff_ffff;
                e[1] = 32'hffff_ffff;
                e[2] = 32'h0000_07ff;
            end
            e[3] = 32'h0;
            base = QID_MAP_BASE + qid_bank * 32'h4000 + 16 * i;
            for (int unsigned w = 0; w < 4; w++)
                wr0(base + 4 * w, e[w]);
            for (int unsigned w = 0; w < 4; w++) begin
                rd0(base + 4 * w, v);
                if (v != e[w])
                    return;
            end
        end
        wr0(QID_MAP_SEL, {30'h0, qid_bank, 1'b1});
        rd0(QID_MAP_SEL, v);
        if (v != {30'h0, qid_bank, 1'b1})
            return;
        qid_bank = ~qid_bank;
        ok = 1;
    endtask

    // ---------------- 生命周期钩子 ----------------
    // probe（#1 Command MSE|BME，#2–#8、#10、#16、#17、#20、#21），每个后端只做一次。
    virtual task discover();
        bit [31:0] v;
        bit [31:0] lo;
        bit [31:0] hi;
        bit [31:0] srcid;
        bit ok;

        if (probed)
            return;
        transport.enable_memory_and_bus_master();
        rd2(QINFO_HOST, v);
        if (v[6:0] != 0) begin
            `uvm_error("DPU_PRIV_BACKEND", $sformatf(
                "qinfo host_id=0x%08h reports pfvf_id %0d; only the AF path (pfvf_id=0) is modeled", v, v[6:0]))
            return;
        end
        host = v[9:7];
        wr0(SOFT_RESET, 32'h7);
        wr0(SOFT_RESET, 32'h0);
        rd0(AF_DECLARATION, v);
        if (v[3]) begin
            `uvm_error("DPU_PRIV_BACKEND", $sformatf("AF is already declared (0x1010=0x%08h)", v))
            return;
        end
        wr0(AF_DECLARATION, 32'h5555_aaaa);
        rd0(AF_DECLARATION, v);
        if (v != {28'h0, 1'b1, host}) begin
            `uvm_error("DPU_PRIV_BACKEND", $sformatf("AF declaration readback 0x%08h, expected 0x%08h",
                       v, {28'h0, 1'b1, host}))
            return;
        end
        wr0(MB_AF_HOST, {28'h0, 1'b1, v[2:0]});
        rd0(AF_DECLARATION, v);
        if (!v[3]) begin
            `uvm_error("DPU_PRIV_BACKEND", "AF declaration was lost after the mailbox AF host write")
            return;
        end
        wr2(QINFO_BDF, {15'h0, 1'b1, transport.bdf});
        srcid = {host, 10'h0};
        for (int unsigned i = 0; i < pairs + 1 + AF_EXTRA_INTR; i++)
            wr0(MSIX_LINEAR_BASE + 4 * ((srcid << 7) + i), {20'h0, 1'b1, i[10:0]});
        wr0(BDF_MAP_BASE, {15'h0, 1'b1, transport.bdf});
        transport.bar.config_read(PCI_CFG_BAR0, lo);
        transport.bar.config_read(PCI_CFG_BAR0 + 12'h4, hi);
        write_qid_map({hi, lo[31:4], 4'h0}, ok);
        if (!ok) begin
            `uvm_error("DPU_PRIV_BACKEND", "qid map readback mismatch")
            return;
        end
        probed = 1;
    endtask

    // Function 复位 = 驱动 dpu_down：先停全部 TX 再停全部 RX（#33）；任一未确认停止即 ok=0，调用方保留全部
    // DMA。AF 声明与映射表保留（对应驱动未 rmmod）。成功后影子 status 清零。
    virtual task reset(output bit ok);
        virtio_queue_program_t order[$];
        bit done;

        foreach (active[id])
            if (active[id].tx_mode)
                order.push_back(active[id]);
        foreach (active[id])
            if (!active[id].tx_mode)
                order.push_back(active[id]);
        ok = 1;
        foreach (order[i]) begin
            disable_queue(order[i], done);
            if (!done) begin
                ok = 0;
                return;
            end
        end
        status_shadow = 0;
    endtask

    virtual task read_status(output bit [7:0] status);
        status = status_shadow;
    endtask

    virtual task write_status(bit [7:0] status);
        status_shadow = status;
    endtask

    virtual task read_device_features(output bit [63:0] features);
        features = 0;
    endtask

    virtual task write_driver_features(bit [63:0] features);
    endtask

    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        accepted = 0;
    endtask

    // 表内队列的上限是私有默认环大小；表外队列返回 0，ops 在建队前拒绝。
    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        max_size = queue_cfg.exists(queue_id) ? default_size : 0;
    endtask

    // 把参数表应用到新建的私有队列（方向、本地号、TX 首描述符控制）与编程参数
    // （本地号、RX 容量、doorbell 位置）；非私有格式或表外队列拒绝。
    virtual function bit prepare_queue(virtqueue_base vq, ref virtio_queue_program_t q);
        custom_virtqueue pvq;
        dpu_priv_queue_config c;

        if (!$cast(pvq, vq) || (pvq == null) || !queue_cfg.exists(q.queue_id)) begin
            `uvm_error("DPU_PRIV_BACKEND", $sformatf(
                "prepare_queue: queue %0d 不是已配置的私有队列", q.queue_id))
            return 0;
        end
        c = queue_cfg[q.queue_id];
        pvq.tx_mode = q.tx_mode;
        pvq.local_qid = c.local_qid;
        pvq.dport_info = c.dport_info;
        pvq.dport_id = c.dport_id;
        pvq.dport_type = c.dport_type;
        pvq.cpu_tx_cos = c.cpu_tx_cos;
        pvq.rss_lag = c.rss_lag;
        pvq.l3_cs = c.l3_cs;
        pvq.l4_cs = c.l4_cs;
        pvq.fwd = c.fwd;
        q.local_qid = c.local_qid;
        q.rx_buf_size = rx_size;
        q.notify_bar = c.notify_bar;
        q.notify_offset = c.notify_offset;
        return 1;
    endfunction

    // #24（TX，queue_en=0 并读回比较 desc_addr）/ #25（RX，先查 VRX tail=0x8000，queue_en=1）。
    virtual task configure_queue(virtio_queue_program_t q, output bit ok);
        bit [31:0] dw[4];
        bit [31:0] v;
        int unsigned gq;

        ok = 0;
        gq = q.local_qid >> 1;
        if (q.tx_mode) begin
            dw[0] = q.desc_iova[31:0];
            dw[1] = q.desc_iova[63:32];
            dw[2] = vtx_dw2(q, 0);
            dw[3] = 32'h0;
            write_vtx(gq, dw);
            read_vtx(gq, dw);
            if ({dw[1], dw[0]} != q.desc_iova)
                return;
        end else begin
            rd0(VRX_TAIL + 4 * gq, v);
            if (v[15:0] != 16'h8000)
                return;
            wr0(VRX_CONTENT, q.desc_iova[31:0]);
            wr0(VRX_CONTENT + 4, q.desc_iova[63:32]);
            wr0(VRX_CONTENT + 8, vrx_dw2(q, 1));
            wr0(VRX_WR_CFG, gq);
            wr0(VRX_WR_CFG, 32'h1_0000 | gq);
        end
        active[q.queue_id] = q;
        ok = 1;
    endtask

    // #28（TX：读回参数后置 queue_en=1）/ #27（RX：本队列对向量 info=valid|self_mask，解除全局屏蔽）。
    virtual task enable_queue(virtio_queue_program_t q, output bit ok);
        bit [31:0] dw[4];
        int unsigned gq;

        gq = q.local_qid >> 1;
        if (q.tx_mode) begin
            read_vtx(gq, dw);
            dw[2][4] = 1'b1;
            write_vtx(gq, dw);
        end else begin
            wr0(MSIX_INFO_BASE + 4 * gq, {19'h0, 1'b1, 1'b1, host, 8'h0});
            wr0(MSIX_CTRL_BASE + 16 * gq + 32'hc, 32'h0);
        end
        ok = 1;
    endtask

    // #33：TX 置 queue_en=0 → 等 QSCH 空闲 → 队列复位 → 清 TX 统计（stat_clr）；RX 间接读回 3 DW 参数
    // （af_mng.c:1564）→ 置 queue_en=0 → 复位，最后清该队列对的中断 info。任一轮询超时 ok=0（不报错），
    // 队列仍记为已配置以便重试。
    virtual task disable_queue(virtio_queue_program_t q, output bit ok);
        bit [31:0] dw[4];
        bit [31:0] v;
        int unsigned gq;

        ok = 0;
        gq = q.local_qid >> 1;
        if (q.tx_mode) begin
            read_vtx(gq, dw);
            dw[2][4] = 1'b0;
            write_vtx(gq, dw);
            poll0(QSCH_STATE + 4 * gq, 32'h0000_0e00, 32'h0, ok);
            if (!ok)
                return;
            wr0(VTX_RESET, gq);
            wr0(VTX_RESET, gq | 32'h8000_0000);
            poll0(VTX_RESET_DONE, 32'h1, 32'h1, ok);
            if (!ok)
                return;
            wr0(VTX_STAT_CLR, gq | 32'h1_0000);
            wr0(VTX_STAT_CLR, gq | 32'h8001_0000);
            poll0(VTX_STAT_CLR_DONE, 32'h1, 32'h1, ok);
            if (!ok)
                return;
        end else begin
            for (int unsigned i = 0; i < 3; i++) begin
                wr0(VRX_RD_CFG, (i << 14) | gq);
                wr0(VRX_RD_CFG, (i << 14) | gq | 32'h1_0000);
                rd0(VRX_RD_DATA, v);
                dw[i] = v;
            end
            dw[2][4] = 1'b0;
            for (int unsigned i = 0; i < 3; i++)
                wr0(VRX_CONTENT + 4 * i, dw[i]);
            wr0(VRX_WR_CFG, gq);
            wr0(VRX_WR_CFG, 32'h1_0000 | gq);
            wr0(VRX_RESET_DONE, 32'h0);
            wr0(VRX_RESET, gq);
            wr0(VRX_RESET, gq | 32'h8000_0000);
            poll0(VRX_RESET_DONE, 32'h1, 32'h1, ok);
            if (!ok)
                return;
            wr0(MSIX_INFO_BASE + 4 * gq, 32'h0);
        end
        active.delete(q.queue_id);
    endtask

    // 私有队列复位 = 停队（teardown 已确认）+ 重建；这里没有寄存器动作。
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        ok = 1;
    endtask

    // VIP 私有数据面固定 polling，不编程 PCI MSI-X 表；设备侧映射在 discover/enable_queue 中按驱动建立。
    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        ok = 1;
    endtask

    virtual task clear_msix(output bit ok);
        ok = 1;
    endtask

    // #29/#31：BAR0+0 共享 doorbell，驱动 writel({wrap, tail, local_qid})。
    virtual task notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap);
        transport.bar.write_reg(q.notify_bar, q.notify_offset, 4,
                                custom_virtqueue::notify_word(wrap, next_idx, q.local_qid));
    endtask

    // 私有设备没有 virtio-net device config。
    virtual task read_net_config(output virtio_net_device_config_t cfg);
        cfg = '{default: 0};
    endtask
endclass
`endif
