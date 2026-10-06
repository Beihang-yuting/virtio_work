// 目录层次：virtio_net_vip/src/dpu_priv；由 virtio_net_pkg 在 custom_virtqueue 后纳入。
// 职责：把 icpu-kernel-driver 的 DPU_RING_T_PRIV TX/RX 描述符、完成队列和通知字
// 映射到 custom_virtqueue 回调，不改变 VIP 默认队列实现。
// 主要依赖：virtio_net_pkg 中的 virtqueue_custom_callback/virtqueue_base、
// host_mem_pkg 中的 host_mem_manager，以及驱动 txrx.h、txrx.c 的小端位域布局。
// 所有权与生命周期：每个回调只绑定一个 custom_virtqueue；回调独占分配的连续
// ring 内存，free_rings 归还。SG 地址、token、IOMMU 映射由调用方持有；回调
// 只在完成或 detach 前借用 token，不释放用户数据缓冲。复位保留 ring 分配。
// 适用边界：普通 TX data desc 与单 buffer RX；不支持 DPU_TSO 扩展描述符、
// 间接描述符、RX 多 buffer 分片、迁移与错误注入。回调只产生通知字，
// 生产 dpu_priv_atomic_ops/device_control 负责发送实际 MMIO。

`ifndef DPU_PRIV_RING_CALLBACK_SV
`define DPU_PRIV_RING_CALLBACK_SV

// 这一层隔离驱动私有 ring 与标准 virtio packed ring：二者虽然都是 16 字节
// 描述符，但 W1/W2、CQ 与 doorbell 语义完全不同，不能复用 packed_virtqueue。
// 公开配置在 alloc_rings 前填写，分配后冻结方向与 local_qid；运行态由本实例
// 独占，不能在多个 VQ 之间共享。通知字交给私有 ops/control，BAR 访问不属于回调职责。
class dpu_priv_ring_callback extends virtqueue_custom_callback;
    `uvm_object_utils(dpu_priv_ring_callback)

    // 驱动 dpu_ring.local_qid 是 u8：RX 通常为 2*qpair，TX 为 2*qpair+1。
    // 此值属于 PF/VF 本地队列空间，不能由 VQ 的全局 queue_id 推断。
    bit          tx_mode;
    int unsigned local_qid;

    // TX 首个 data desc 的路由和校验控制；后续 SG 描述符只携带数据字段。
    bit [11:0] dport_info;
    bit [9:0]  dport_id;
    bit [2:0]  dport_type;
    bit        rss_lag;
    bit [2:0]  cpu_tx_cos;
    bit        l3_cs;
    bit        l4_cs;
    bit [1:0]  fwd;

    // 驱动对齐分配，CQ 紧随 N 个 16B 描述符；地址与大小供 DUT/测试配置。
    bit [63:0] cq_addr;
    int unsigned ring_alloc_bytes;

    // kick 记录驱动 writel 的数据；私有 ops 在屏障完成后交给 control 写 BAR。
    bit [31:0] last_notify_word;
    int unsigned notify_count;

    // 各索引均是 ring 槽号；wrap 初值为 1，每越过 N-1 槽翻转一次。
    int unsigned producer_index;
    bit          producer_wrap;
    int unsigned consumer_index;
    bit          consumer_wrap;
    int unsigned cq_consumer_index;
    bit          cq_consumer_wrap;

    // pending 按发布顺序保存每包首槽、链长、TX 字节数/RX buffer 长度和借用 token。
    // 留空一槽限制使生产者与消费者的同槽索引没有满/空歧义。
    typedef struct {
        int unsigned head_index;
        int unsigned desc_count;
        int unsigned byte_count;
        uvm_object token;
    } pending_record_t;

    protected pending_record_t pending[$];
    protected int unsigned pending_desc_count;
    protected int unsigned unnotified_desc_count;
    protected bit completion_notifications_enabled;

    protected bit ring_allocated;
    protected bit allocated_tx_mode;
    protected int unsigned allocated_local_qid;
    protected int unsigned allocated_queue_size;
    protected bit [63:0] ring_base;
    protected host_mem_manager ring_mem;
    protected virtqueue_base owner_vq;

    // 构造回调并给出方向、本地队列号；其余公开 TX 控制字段可在 alloc 前设置。
    // 默认 fwd=DPU_FWD_NORMAL；未分配内存，失败由后续 alloc_rings 报告。
    function new(string name = "dpu_priv_ring_callback",
                 bit tx_mode = 1, int unsigned local_qid = 0);
        super.new(name);
        this.tx_mode = tx_mode;
        this.local_qid = local_qid;
        fwd = 2'd1;
        reset_runtime();
        ring_allocated = 0;
        ring_alloc_bytes = 0;
        ring_base = 0;
        cq_addr = 0;
        ring_mem = null;
        owner_vq = null;
    endfunction

    // 清理队列侧的索引、借用 token 和通知记录，不触及 ring 内存或外部 SG。
    // 由构造、复位和释放共同调用；完成队列的物理初值由 initialize_ring 写入。
    protected function void reset_runtime();
        pending.delete();
        pending_desc_count = 0;
        unnotified_desc_count = 0;
        producer_index = 0;
        producer_wrap = 1;
        consumer_index = 0;
        consumer_wrap = 1;
        cq_consumer_index = 0;
        cq_consumer_wrap = 1;
        completion_notifications_enabled = 1;
        last_notify_word = 0;
        notify_count = 0;
    endfunction

    // 按驱动 dpu_setup_{tx,rx}_rings 清零完整分配块；TX CQ 初始 head=0、
    // wrap=1，RX CQ 全零使首圈期望的 cq_wrapper=1 不会误判为空队列有完成。
    // 仅在已持有有效 ring 内存时调用。
    protected function void initialize_ring();
        byte initial_tx_cq[2];

        ring_mem.mem_set(ring_base, 0, ring_alloc_bytes);
        if (allocated_tx_mode) begin
            initial_tx_cq[0] = 8'h00;
            initial_tx_cq[1] = 8'h80;
            ring_mem.write_mem(cq_addr, initial_tx_cq);
        end
    endfunction

    // 校验回调仍绑定分配时的 VQ/内存/几何；配置在 alloc 后变化则拒绝操作，
    // 防止按 TX 的 2B CQ 去读 RX 的 16B CQ。失败返回 0 并报 UVM_ERROR。
    protected function bit binding_ok(virtqueue_base vq, string operation);
        if (!ring_allocated || (vq == null) || (vq != owner_vq) ||
            (vq.mem != ring_mem) || (vq.desc_table_addr != ring_base) ||
            (vq.queue_size != allocated_queue_size) ||
            (tx_mode != allocated_tx_mode) ||
            (local_qid != allocated_local_qid)) begin
            `uvm_error("DPU_PRIV_RING", $sformatf(
                "%s: ring 未分配或 VQ/方向/local_qid 已改变", operation))
            return 0;
        end
        return 1;
    endfunction

    // 把单个描述符写成驱动原生 little-endian 16B：addr[63:0]、W1、W2。
    // W1.len 仅 18 位，必须整字打包后一次写入，避免覆盖相邻的 dport 字段。
    protected function void write_descriptor(int unsigned index, bit [63:0] addr,
                                             bit [31:0] word1, bit [31:0] word2);
        byte data[16];

        for (int unsigned i = 0; i < 8; i++)
            data[i] = addr[i*8 +: 8];
        for (int unsigned i = 0; i < 4; i++) begin
            data[8+i] = word1[i*8 +: 8];
            data[12+i] = word2[i*8 +: 8];
        end
        ring_mem.write_mem(ring_base + index * 16, data);
    endfunction

    // 推进一个槽并处理 wrap；只由预检通过的写入/完成回收路径调用。
    // queue_size 在 alloc 时限制为 2..4096，因此索引总在可编码范围内。
    protected function void advance_slot(ref int unsigned index, ref bit wrap);
        index++;
        if (index == allocated_queue_size) begin
            index = 0;
            wrap = ~wrap;
        end
    endfunction

    // 从 TX CQ 读驱动的 vtx_completion_queue_reg：bit[14:0] head_index，
    // bit[15] wrapcounter。输出仅用于观察，读入前由调用者执行 rmb。
    protected function void read_tx_cq(output int unsigned head_index,
                                       output bit wrap);
        byte data[];
        bit [15:0] word0;

        ring_mem.read_mem(cq_addr, 2, data);
        word0 = {data[1], data[0]};
        head_index = word0[14:0];
        wrap = word0[15];
    endfunction

    // 解码一条 RX CQ 前两个 dword，供集成测试与设备黄金字节交叉验证。
    // W0[31:28]=desc_num；W1[15:0]=head_idx、[29:16]=pkt_len、[31]=wrapper。
    // 驱动实际按包长顺序消费 RX buffer，head_idx/desc_num 不参与它的取包路径；
    // 当前实现仍检查 desc_num=1，避免把不支持的多 buffer 包错误交给上层。
    // 非 RX、未分配或下标越界返回 0，不读内存；成功返回 1 并填全部输出。
    function bit decode_rx_cq(int unsigned index,
                              output int unsigned desc_num,
                              output int unsigned pkt_len,
                              output bit wrap,
                              output int unsigned head_idx);
        byte data[];
        bit [31:0] word0;
        bit [31:0] word1;

        desc_num = 0;
        pkt_len = 0;
        wrap = 0;
        head_idx = 0;
        if (!ring_allocated || allocated_tx_mode ||
            (index >= allocated_queue_size)) begin
            `uvm_error("DPU_PRIV_RING", "decode_rx_cq: 非 RX ring 或 CQ 下标越界")
            return 0;
        end

        ring_mem.read_mem(cq_addr + index * 16, 8, data);
        word0 = {data[3], data[2], data[1], data[0]};
        word1 = {data[7], data[6], data[5], data[4]};
        desc_num = word0[31:28];
        head_idx = word1[15:0];
        pkt_len = word1[29:16];
        wrap = word1[31];
        return 1;
    endfunction

    // 按 txrx.c 的 PAGE_SIZE 对齐规则分配连续 desc+CQ；不自动生成 SG/DMA 映射。
    // 允许 N=2..4096，包含 4/8 槽的缩尺 wrap 测试；local_qid 限定驱动 u8。
    // 分配失败或重复绑定时报错并保持原状态。成功后 VQ 的 device_ring_addr
    // 指向 CQ；driver_ring_addr=0 表示私有格式没有独立 driver event ring。
    virtual function void cb_alloc_rings(virtqueue_base vq);
        custom_virtqueue custom_vq;
        int unsigned used_bytes;
        bit [63:0] allocation;

        if (ring_allocated || (vq == null) || !$cast(custom_vq, vq) ||
            (vq.mem == null) || (vq.queue_size < 2) ||
            (vq.queue_size > 4096) || (local_qid > 255)) begin
            `uvm_error("DPU_PRIV_RING",
                "alloc_rings: 重复分配、无效 VQ/内存、N 不在 2..4096 或 local_qid 超过 255")
            return;
        end

        used_bytes = vq.queue_size * (tx_mode ? 16 : 32) + (tx_mode ? 2 : 0);
        ring_alloc_bytes = (used_bytes + 4095) & 32'hffff_f000;
        allocation = vq.mem.alloc(ring_alloc_bytes, .align(4096));
        if (allocation == '1) begin
            ring_alloc_bytes = 0;
            `uvm_error("DPU_PRIV_RING", "alloc_rings: host_mem 分配失败")
            return;
        end

        ring_allocated = 1;
        allocated_tx_mode = tx_mode;
        allocated_local_qid = local_qid;
        allocated_queue_size = vq.queue_size;
        ring_base = allocation;
        ring_mem = vq.mem;
        owner_vq = vq;
        cq_addr = ring_base + allocated_queue_size * 16;

        vq.desc_table_addr = ring_base;
        vq.driver_ring_addr = 0;
        vq.device_ring_addr = cq_addr;
        custom_vq.desc_entry_size = 16;
        custom_vq.desc_field_defs = '{"addr:64:0", "word1:32:8", "word2:32:12"};

        reset_runtime();
        initialize_ring();
        vq.queue_enable = 0;
        vq.state = VQ_CONFIGURE;
    endfunction

    // 释放本回调独占的 ring 分配并清 VQ 地址；SG 数据和调用方 IOMMU 映射不属于
    // 回调，需由调用方自行回收。重复释放安全；错 VQ 释放会报错且保留原绑定。
    virtual function void cb_free_rings(virtqueue_base vq);
        if (!ring_allocated)
            return;
        if (vq != owner_vq) begin
            `uvm_error("DPU_PRIV_RING", "free_rings: VQ 不是 ring 所有者")
            return;
        end

        ring_mem.free(ring_base);
        reset_runtime();
        ring_allocated = 0;
        ring_alloc_bytes = 0;
        ring_base = 0;
        cq_addr = 0;
        ring_mem = null;
        owner_vq = null;
        vq.desc_table_addr = 0;
        vq.driver_ring_addr = 0;
        vq.device_ring_addr = 0;
        vq.queue_enable = 0;
        vq.state = VQ_RESET;
    endfunction

    // 清除运行态并重新初始化 CQ，保留同一块 ring 分配供重新配置。
    // 必须在设备停止 DMA 后调用；未分配时只清内部状态，错误绑定则不触内存。
    virtual function void cb_reset_queue(virtqueue_base vq);
        if (!ring_allocated) begin
            reset_runtime();
            if (vq != null)
                vq.state = VQ_RESET;
            return;
        end
        if (!binding_ok(vq, "reset_queue"))
            return;

        reset_runtime();
        initialize_ring();
        vq.queue_enable = 0;
        vq.state = VQ_CONFIGURE;
        vq.total_add_buf_ops = 0;
        vq.total_poll_used_ops = 0;
        vq.total_kick_ops = 0;
    endfunction

    // 设备停用后按发布顺序归还所有未由 poll_used 交付的 token，并复位 ring。
    // 与标准 VQ 一样，调用者须先停 DMA；否则设备可能继续访问已重新初始化的槽。
    virtual function void cb_detach_all_unused(virtqueue_base vq,
                                               ref uvm_object tokens[$]);
        if (!ring_allocated)
            return;
        if (!binding_ok(vq, "detach_all_unused"))
            return;

        foreach (pending[i])
            tokens.push_back(pending[i].token);
        cb_reset_queue(vq);
    endfunction

    // 预检整个 SG 请求后再改 Host 内存，失败返回 '1，索引、CQ 和内存均不变。
    // TX 允许多个出向 SG data desc，并仿驱动 DPU_TXD_DATALEN_MAX=65536 将
    // 过长 SG 拆成连续 64KiB data desc；首描述符写控制，链尾 next=0。
    // 驱动对超过 7 个 data desc 的 skb 先做 linearize；回调没有 skb 字节所有权，
    // 不能安全合并 SG，故直接拒绝拆分后超过 7 项的请求。
    // RX 仅允许一条入向 buffer。indirect/is_indirect、0 长度、RX 超过 18 位的
    // 长度、地址溢出、方向错误或空间不足均拒绝。DPU_TSO 无编码入口。
    virtual function int unsigned cb_add_buf(virtqueue_base vq,
                                             virtio_sg_list sgs[],
                                             int unsigned n_out_sgs,
                                             int unsigned n_in_sgs,
                                             uvm_object token,
                                             bit indirect);
        int unsigned list_count;
        int unsigned needed;
        longint unsigned byte_total;
        int unsigned head_index;
        int unsigned write_index;
        bit write_wrap;
        int unsigned ordinal;
        int unsigned segment_count;
        int unsigned segment_len;
        int unsigned remaining_len;
        longint unsigned sg_len64;
        bit [63:0] segment_addr;
        bit [31:0] word1;
        bit [31:0] word2;
        pending_record_t record;

        if (!binding_ok(vq, "add_buf"))
            return '1;
        if (indirect || (n_out_sgs > (32'hffff_ffff - n_in_sgs))) begin
            `uvm_error("DPU_PRIV_RING", "add_buf: 不支持 indirect 或 SG 数量溢出")
            return '1;
        end

        list_count = n_out_sgs + n_in_sgs;
        if ((list_count > sgs.size()) ||
            (allocated_tx_mode && ((n_out_sgs == 0) || (n_in_sgs != 0))) ||
            (!allocated_tx_mode && ((n_out_sgs != 0) || (n_in_sgs != 1)))) begin
            `uvm_error("DPU_PRIV_RING", "add_buf: SG 列表个数或 TX/RX 方向不合法")
            return '1;
        end

        needed = 0;
        byte_total = 0;
        for (int unsigned s = 0; s < list_count; s++) begin
            if (sgs[s].entries.size() == 0) begin
                `uvm_error("DPU_PRIV_RING", "add_buf: SG 列表不可为空")
                return '1;
            end
            for (int unsigned e = 0; e < sgs[s].entries.size(); e++) begin
                sg_len64 = sgs[s].entries[e].len;
                if (sgs[s].entries[e].is_indirect ||
                    (sgs[s].entries[e].len == 0) ||
                    (!allocated_tx_mode &&
                     (sgs[s].entries[e].len > 32'h0003_ffff)) ||
                    (sgs[s].entries[e].addr >
                     (64'hffff_ffff_ffff_ffff - (sg_len64 - 1)))) begin
                    `uvm_error("DPU_PRIV_RING", "add_buf: 间接 SG、RX 长度或 SG 地址范围不合法")
                    return '1;
                end
                segment_count = allocated_tx_mode ?
                    int'((sg_len64 + 65535) / 65536) : 1;
                needed += segment_count;
                byte_total += sgs[s].entries[e].len;
                if ((needed > allocated_queue_size - 1) ||
                    (byte_total > 64'h0000_0000_ffff_ffff)) begin
                    `uvm_error("DPU_PRIV_RING", "add_buf: 单包描述符或字节数超限")
                    return '1;
                end
            end
        end

        if ((allocated_tx_mode && (needed > 7)) ||
            (!allocated_tx_mode && (needed != 1)) ||
            (needed > cb_get_free_count(vq))) begin
            `uvm_error("DPU_PRIV_RING",
                "add_buf: TX 最多 7 条 data desc、RX 单 buffer，且 ring 需留空一槽")
            return '1;
        end

        head_index = producer_index;
        write_index = producer_index;
        write_wrap = producer_wrap;
        ordinal = 0;
        for (int unsigned s = 0; s < list_count; s++) begin
            for (int unsigned e = 0; e < sgs[s].entries.size(); e++) begin
                remaining_len = sgs[s].entries[e].len;
                segment_addr = sgs[s].entries[e].addr;
                while (remaining_len != 0) begin
                    segment_len = (allocated_tx_mode && (remaining_len > 65536)) ?
                                  65536 : remaining_len;
                    word1 = 0;
                    word2 = 0;
                    word1[17:0] = segment_len[17:0];
                    if (allocated_tx_mode && (ordinal == 0)) begin
                        word1[29:18] = dport_info;
                        word1[31:30] = dport_id[1:0];
                        word2[7:0] = dport_id[9:2];
                        word2[10:8] = dport_type;
                        word2[11] = rss_lag;
                        word2[14:12] = cpu_tx_cos;
                        word2[17] = l3_cs;
                        word2[18] = l4_cs;
                        word2[20:19] = fwd;
                    end
                    word2[15] = 0; // DPU_DATA_DESC；扩展/TSO 描述符不在当前实现内。
                    word2[16] = allocated_tx_mode && (ordinal + 1 < needed);
                    word2[23] = write_wrap;
                    word2[31] = ~write_wrap;

                    write_descriptor(write_index, segment_addr, word1, word2);
                    advance_slot(write_index, write_wrap);
                    remaining_len -= segment_len;
                    if (remaining_len != 0)
                        segment_addr += segment_len;
                    ordinal++;
                end
            end
        end

        record.head_index = head_index;
        record.desc_count = needed;
        record.byte_count = int'(byte_total);
        record.token = token;
        pending.push_back(record);
        producer_index = write_index;
        producer_wrap = write_wrap;
        pending_desc_count += needed;
        unnotified_desc_count += needed;
        vq.total_add_buf_ops++;
        return head_index;
    endfunction

    // 先用 wmb 发布描述符，再记录驱动 writel 格式
    // {wrapcounter[31], tail_ptr[30:16], local_qid[15:0]}，由 ops/control 继续执行 MMIO。
    // 未绑定 barrier 时拒绝通知，避免把尚未排序的描述符误当已发布。
    virtual task cb_kick(virtqueue_base vq);
        if (!binding_ok(vq, "kick"))
            return;
        if (vq.barrier == null) begin
            `uvm_error("DPU_PRIV_RING", "kick: 缺少 memory barrier")
            return;
        end

        vq.barrier.wmb("DPU private ring descriptors before notify");
        last_notify_word = {producer_wrap, producer_index[14:0],
                            allocated_local_qid[15:0]};
        notify_count++;
        unnotified_desc_count = 0;
        vq.total_kick_ops++;
    endtask

    // TX 按 CQ head_index 回收已完整越过的 SG 包；RX 按 CQ wrapper、pkt_len
    // 回收下一条已投递 buffer。成功返回原 token 和整包字节数；无完成返回 0。
    // TX CQ wrap 必须与 head 前进方向一致；RX 的 desc_num!=1 或包长超过
    // posted buffer 时报告错误且不移动任何索引，避免静默丢失多 buffer 包。
    virtual function bit cb_poll_used(virtqueue_base vq,
                                      ref uvm_object token,
                                      ref int unsigned len);
        int unsigned cq_head;
        bit cq_wrap;
        bit expected_wrap;
        int unsigned distance;
        int unsigned rx_desc_num;
        int unsigned rx_pkt_len;
        int unsigned rx_head_idx;
        pending_record_t record;

        if (!binding_ok(vq, "poll_used") || (pending.size() == 0))
            return 0;
        if (vq.barrier != null)
            vq.barrier.rmb("DPU private ring CQ before completion read");

        if (allocated_tx_mode) begin
            read_tx_cq(cq_head, cq_wrap);
            if (cq_head >= allocated_queue_size) begin
                `uvm_error("DPU_PRIV_RING", "poll_used: TX CQ head_index 越界")
                return 0;
            end
            distance = (cq_head + allocated_queue_size - consumer_index) %
                       allocated_queue_size;
            expected_wrap = consumer_wrap ^ (cq_head < consumer_index);
            if ((cq_wrap != expected_wrap) ||
                (distance > pending_desc_count)) begin
                `uvm_error("DPU_PRIV_RING", "poll_used: TX CQ head/wrap 超出已投递区间")
                return 0;
            end
            if (distance < pending[0].desc_count)
                return 0;
        end else begin
            if (!decode_rx_cq(cq_consumer_index, rx_desc_num, rx_pkt_len,
                              cq_wrap, rx_head_idx))
                return 0;
            if (cq_wrap != cq_consumer_wrap)
                return 0;
            if ((rx_desc_num != 1) || (rx_pkt_len == 0) ||
                (rx_pkt_len > pending[0].byte_count)) begin
                `uvm_error("DPU_PRIV_RING", $sformatf(
                    "poll_used: RX 仅支持单 buffer，CQ desc_num=%0d pkt_len=%0d posted_len=%0d",
                    rx_desc_num, rx_pkt_len, pending[0].byte_count))
                return 0;
            end
        end

        record = pending.pop_front();
        if (record.head_index != consumer_index) begin
            `uvm_error("DPU_PRIV_RING", "poll_used: 待回收包与 consumer_index 不一致")
            pending.push_front(record);
            return 0;
        end
        for (int unsigned i = 0; i < record.desc_count; i++)
            advance_slot(consumer_index, consumer_wrap);
        if (!allocated_tx_mode)
            advance_slot(cq_consumer_index, cq_consumer_wrap);
        pending_desc_count -= record.desc_count;
        token = record.token;
        len = allocated_tx_mode ? record.byte_count : rx_pkt_len;
        vq.total_poll_used_ops++;
        return 1;
    endfunction

    // 私有 CQ 没有 virtio event suppression 字段；这里只登记上层轮询偏好，
    // 不伪造设备中断屏蔽。未分配时不访问 ring。
    virtual function void cb_disable_cb(virtqueue_base vq);
        if (binding_ok(vq, "disable_cb"))
            completion_notifications_enabled = 0;
    endfunction

    // 恢复本地完成通知偏好；真实中断使能仍需外层设备控制路径配置。
    virtual function void cb_enable_cb(virtqueue_base vq);
        if (binding_ok(vq, "enable_cb"))
            completion_notifications_enabled = 1;
    endfunction

    // 驱动私有 CQ 无 event-index 延迟门限，退化为本地普通使能。
    virtual function void cb_enable_cb_delayed(virtqueue_base vq);
        cb_enable_cb(vq);
    endfunction

    // 不消耗 CQ，仅检查下一完整 TX 包或下一 RX CQ 项是否可收割。
    // last_used 是标准 VQ 参数；驱动私有 CQ 只按本地 head/wrapper 判定，故忽略它。
    virtual function bit cb_vq_poll(virtqueue_base vq, int unsigned last_used);
        int unsigned cq_head;
        bit cq_wrap;
        bit expected_wrap;
        int unsigned distance;
        int unsigned rx_desc_num;
        int unsigned rx_pkt_len;
        int unsigned rx_head_idx;

        if (!binding_ok(vq, "vq_poll") || (pending.size() == 0))
            return 0;
        if (vq.barrier != null)
            vq.barrier.rmb("DPU private ring CQ before poll check");
        if (allocated_tx_mode) begin
            read_tx_cq(cq_head, cq_wrap);
            if (cq_head >= allocated_queue_size)
                return 0;
            distance = (cq_head + allocated_queue_size - consumer_index) %
                       allocated_queue_size;
            expected_wrap = consumer_wrap ^ (cq_head < consumer_index);
            return (cq_wrap == expected_wrap) &&
                   (distance <= pending_desc_count) &&
                   (distance >= pending[0].desc_count);
        end

        if (!decode_rx_cq(cq_consumer_index, rx_desc_num, rx_pkt_len,
                          cq_wrap, rx_head_idx))
            return 0;
        return (cq_wrap == cq_consumer_wrap) && (rx_desc_num == 1) &&
               (rx_pkt_len != 0) && (rx_pkt_len <= pending[0].byte_count);
    endfunction

    // 返回当前仍可发布的描述符槽数；始终留一空槽，未分配返回 0。
    virtual function int unsigned cb_get_free_count(virtqueue_base vq);
        if (!ring_allocated || (vq != owner_vq))
            return 0;
        return allocated_queue_size - 1 - pending_desc_count;
    endfunction

    // 返回已投递但未通过 poll_used 交付的包数，而不是其 SG 描述符数。
    virtual function int unsigned cb_get_pending_count(virtqueue_base vq);
        if (!ring_allocated || (vq != owner_vq))
            return 0;
        return pending.size();
    endfunction

    // DPU 私有 ring 没有设备 event suppression；只要有新描述符，驱动需要
    // 写一次 tail doorbell。完成通知偏好与主机→设备 doorbell 独立。
    virtual function bit cb_needs_notification(virtqueue_base vq);
        if (!ring_allocated || (vq != owner_vq))
            return 0;
        return unnotified_desc_count != 0;
    endfunction

    // 通用错误注入器不知道私有 W1/W2 与 CQ 的位布局；显式拒绝而不改内存。
    virtual function void cb_inject_desc_error(virtqueue_base vq,
                                               virtqueue_error_e err_type);
        `uvm_error("DPU_PRIV_RING", $sformatf(
            "inject_desc_error: 私有 ring 未实现错误注入，err=%s", err_type.name()))
    endfunction

    // 迁移快照缺少私有 CQ 与包/SG 所有权记录；显式报错，保持 snap 不变。
    virtual function void cb_save_state(virtqueue_base vq,
                                        ref virtqueue_snapshot_t snap);
        `uvm_error("DPU_PRIV_RING", "save_state: 私有 ring 迁移未实现")
    endfunction

    // 拒绝未实现的恢复，不修改 ring、CQ 或 VQ 状态，返回 0。
    virtual function bit cb_restore_state(virtqueue_base vq,
                                          virtqueue_snapshot_t snap);
        `uvm_error("DPU_PRIV_RING", "restore_state: 私有 ring 迁移未实现")
        return 0;
    endfunction
endclass : dpu_priv_ring_callback

`endif // DPU_PRIV_RING_CALLBACK_SV
