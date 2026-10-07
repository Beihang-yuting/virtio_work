// 目录层次：src/dataplane；Function.dataplane 的 RX 薄适配层。
// buffer 投递、取包、合包、DMA 所有权与 notify 全部由注入的 virtio_atomic_ops
// （rx_refill / rx_receive_frames）执行；引擎只做可选的 RX checksum 校验、把帧
// 转为 packet_item（或 wrapper）、维护统计与自动补充门限。私有 Function 注入
// 通用 ops，并以 refill_threshold=0 关闭自动补充。host_id/bdf 记录 DMA 身份，
// 供 fabric 测试断言，收发不读取。
`ifndef VIRTIO_RX_ENGINE_SV
`define VIRTIO_RX_ENGINE_SV

// ============================================================================
// virtio_rx_pkt_wrapper
//
// Lightweight fallback object that carries a received packet's payload and
// parsed virtio_net_hdr back to the caller when the protocol parser rejects
// malformed data. Valid packets are returned as net_packet::packet_item.
// ============================================================================

// 协议解析失败时仍保留原始字节和 Virtio header，供错误测试检查；由接收者持有。
class virtio_rx_pkt_wrapper extends uvm_object;
    `uvm_object_utils(virtio_rx_pkt_wrapper)

    byte unsigned    payload[$];
    virtio_net_hdr_t net_hdr;
    int unsigned     pkt_len;

    // 构造函数：空包装对象（长度 0）；payload/net_hdr 由 RX 引擎回填。
    function new(string name = "virtio_rx_pkt_wrapper");
        super.new(name);
        pkt_len = 0;
    endfunction

endclass : virtio_rx_pkt_wrapper

// 只保存配置与统计；DMA 资源由 ops 所有，停机前由上层确认设备停止 DMA。
class virtio_rx_engine extends uvm_object;
    `uvm_object_utils(virtio_rx_engine)

    // ===== External references (set by parent before use) =====
    // ops 是规范 RX 路径（借用）：buffer 分配、通知、取包与 DMA 回收由它执行。
    virtio_atomic_ops           ops;
    virtio_offload_engine       offload;
    bit [15:0]                  bdf;
    int unsigned                host_id;

    // ===== Configuration =====
    bit [63:0]       negotiated_features;
    int unsigned     buf_size         = 1526;    // 描述符可写容量
    int unsigned     refill_threshold = 16;      // free < 此值时自动补充；0 关闭

    // ===== Statistics =====
    longint unsigned total_rx_packets = 0;
    longint unsigned total_rx_bytes   = 0;
    longint unsigned total_rx_merged  = 0;       // MRG_RXBUF merge events

    // 初始化未协商的引擎；构造时不分配 buffer，ops 须先绑定再投递。
    function new(string name = "virtio_rx_engine");
        super.new(name);
        negotiated_features = 64'h0;
    endfunction

    // 中文说明：优先把真实线速 payload 解析为 net_packet packet_item；
    // 对故意注入的 malformed/非 Ethernet 数据保留 wrapper，便于错误场景
    // 继续观察原始字节和 virtio header。
    protected function uvm_object build_received_packet(
        input byte unsigned payload[$],
        input virtio_net_hdr_t net_hdr
    );
        packet_item packet_obj;
        virtio_rx_pkt_wrapper fallback_obj;

        if (virtio_net_packet_adapter::unpack(payload, packet_obj))
            return packet_obj;

        fallback_obj = virtio_rx_pkt_wrapper::type_id::create("rx_pkt");
        fallback_obj.payload   = payload;
        fallback_obj.net_hdr   = net_hdr;
        fallback_obj.pkt_len   = payload.size();
        return fallback_obj;
    endfunction

    // 查询每个 RX buffer 的可写容量（私有 Function 装配为不含 header 的私有容量）。
    virtual function int unsigned get_rx_buf_size();
        return buf_size;
    endfunction : get_rx_buf_size

    // 向 queue_id 最多补充 count 个可写 buffer（容量取 get_rx_buf_size()），受空闲
    // 描述符限制；分配、映射、所有权登记与真实 notify 由 ops 执行。队列不存在则报错。
    virtual task refill_buffers(
        int unsigned queue_id,
        int unsigned count
    );
        if ((ops == null) || (ops.vq_mgr == null) ||
            (ops.vq_mgr.get_queue(queue_id) == null)) begin
            `uvm_error("RX_ENG",
                $sformatf("refill_buffers: queue %0d not found", queue_id))
            return;
        end
        ops.rx_refill(queue_id, count, get_rx_buf_size());
        `uvm_info("RX_ENG",
            $sformatf("refill_buffers: queue=%0d requested=%0d buf_size=%0d",
                      queue_id, count, get_rx_buf_size()),
            UVM_HIGH)
    endtask : refill_buffers

    // 经 ops 取得至多 budget 个帧（ops 完成合包与 DMA 回收），可选校验 RX checksum，
    // 合法帧返回 packet_item、非法帧返回 wrapper；之后按 free-count 门限补充。
    virtual task receive_packets(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        virtqueue_base    vq;
        virtio_rx_frame_t frames[$];

        if ((ops == null) || (ops.vq_mgr == null)) begin
            `uvm_error("RX_ENG", $sformatf(
                "receive_packets: queue %0d has no bound atomic ops", queue_id))
            return;
        end
        vq = ops.vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("RX_ENG",
                $sformatf("receive_packets: queue %0d not found", queue_id))
            return;
        end

        ops.rx_receive_frames(queue_id, budget, frames);
        foreach (frames[i]) begin
            if (negotiated_features[VIRTIO_NET_F_GUEST_CSUM] &&
                !offload.verify_rx_csum(frames[i].net_hdr, frames[i].payload))
                `uvm_warning("RX_ENG", $sformatf(
                    "receive_packets: RX checksum verification failed, pkt_size=%0d",
                    frames[i].payload.size()))
            if (frames[i].num_buffers > 1)
                total_rx_merged++;
            received.push_back(build_received_packet(frames[i].payload,
                                                     frames[i].net_hdr));
            total_rx_packets++;
            total_rx_bytes += frames[i].payload.size();
        end

        `uvm_info("RX_ENG",
            $sformatf("receive_packets: queue=%0d received=%0d", queue_id, frames.size()),
            UVM_HIGH)

        // Auto-refill if free count drops below threshold
        if (vq.get_free_count() < refill_threshold)
            refill_buffers(queue_id, refill_threshold);
    endtask : receive_packets

    // 输出收包、字节与合包计数，不改变运行态。
    function void print_stats();
        `uvm_info("RX_ENG_STATS",
            $sformatf("RX Stats: packets=%0d bytes=%0d merged=%0d",
                      total_rx_packets, total_rx_bytes, total_rx_merged),
            UVM_LOW)
    endfunction : print_stats

endclass : virtio_rx_engine

`endif // VIRTIO_RX_ENGINE_SV
