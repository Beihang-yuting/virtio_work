// 目录层次：src/dataplane；提供标准 Virtio RX buffer 投递、取包与解析引擎。
// 依赖队列管理器、Host memory、IOMMU、packet adapter 和 offload/callback；外部
// 依赖由 Function 借用注入，引擎拥有自己分配的 RX buffer 及其 DMA 映射，完成时
// 回收。停机前上层必须确认设备停止 DMA，并完成未消费 buffer 的生命周期处理。
// 私有派生引擎覆写投递/收包与容量查询，把所有权统一交给私有 ops，不使用此表。
`ifndef VIRTIO_RX_ENGINE_SV
`define VIRTIO_RX_ENGINE_SV

// ============================================================================
// virtio_rx_engine
//
// Handles packet reception on the driver (guest) side:
//   1. Pre-fills RX virtqueues with device-writable buffers.
//   2. Polls used ring for completed RX descriptors.
//   3. Parses virtio_net_hdr from received buffers.
//   4. Merges multi-buffer packets (MRG_RXBUF mode).
//   5. Verifies RX checksums when GUEST_CSUM is negotiated.
//   6. Auto-refills buffers when free count drops below threshold.
//
// Three buffer modes are supported:
//   RX_MODE_MERGEABLE -- Multiple small buffers can be merged for one packet.
//                        Header includes num_buffers field.
//   RX_MODE_BIG       -- Single large buffer (64K+) per packet.
//   RX_MODE_SMALL     -- Single buffer sized for MTU + header.
//
// Depends on:
//   - virtqueue_manager, virtqueue_base (add_buf, poll_used, kick)
//   - host_mem_manager (alloc, read_mem, mem_set, free)
//   - virtio_iommu_model (map, unmap)
//   - virtio_offload_engine (RX checksum verification)
//   - virtio_net_hdr_util (unpack_hdr, get_hdr_size)
//   - virtio_buf_tracker (buffer lifecycle tracking)
// ============================================================================

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

// 在队列内存操作之上集中处理标准 header、合包和统计；不负责设备控制面停机。
class virtio_rx_engine extends uvm_object;
    `uvm_object_utils(virtio_rx_engine)

    // ===== External references (set by parent before use) =====
    // ops 是规范 RX 路径（借用）：buffer 分配、通知、取包与 DMA 回收由它执行。
    virtio_atomic_ops           ops;
    virtqueue_manager           vq_mgr;
    host_mem_manager            mem;
    virtio_iommu_model          iommu;
    virtio_offload_engine       offload;
    bit [15:0]                  bdf;
    int unsigned                host_id;

    // ===== Configuration =====
    bit [63:0]       negotiated_features;
    rx_buf_mode_e    buf_mode         = RX_MODE_MERGEABLE;
    int unsigned     buf_size         = 1526;    // default for mergeable mode
    int unsigned     refill_threshold = 16;      // refill when free < this

    // ===== Statistics =====
    longint unsigned total_rx_packets = 0;
    longint unsigned total_rx_bytes   = 0;
    longint unsigned total_rx_errors  = 0;
    longint unsigned total_rx_merged  = 0;       // MRG_RXBUF merge events

    // ===== Buffer tracking: gpa -> {iova, size} for outstanding RX buffers =====
    protected bit [63:0]   rx_buf_gpa_to_iova[bit [63:0]];
    protected int unsigned rx_buf_gpa_to_size[bit [63:0]];

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    // 初始化未协商的引擎；构造时不分配 buffer，外部资源须先绑定再投递。
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

    // ==================================================================
    // get_rx_buf_size
    //
    // Returns the appropriate buffer allocation size based on the
    // current buffer mode.
    // ==================================================================
    // 查询模式对应的 buffer 容量；设为虚接口供私有协议返回不含 Virtio header 的容量。
    virtual function int unsigned get_rx_buf_size();
        int unsigned hdr_size;
        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        case (buf_mode)
            RX_MODE_MERGEABLE: return buf_size;
            RX_MODE_BIG:       return 65550;
            RX_MODE_SMALL:     return 1514 + hdr_size;
            default:           return buf_size;
        endcase
    endfunction : get_rx_buf_size

    // ==================================================================
    // refill_buffers
    //
    // Pre-fills the RX virtqueue with device-writable buffers.
    // Each buffer is allocated in host memory, zero-filled, DMA-mapped,
    // and submitted as a single-entry scatter-gather list with n_in=1.
    //
    // Parameters:
    //   queue_id -- RX virtqueue ID
    //   count    -- Number of buffers to add (capped by free descriptors)
    // ==================================================================
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

    // ==================================================================
    // receive_packets
    //
    // Top-level RX entry point. Dispatches to the appropriate receive
    // method based on buffer mode, then auto-refills if needed.
    //
    // Parameters:
    //   queue_id -- RX virtqueue ID to poll
    //   budget   -- Maximum number of packets to receive
    //   received -- [output] List of received packet tokens (uvm_object)
    // ==================================================================
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

    // ==================================================================
    // receive_mergeable (protected)
    //
    // Mergeable buffer receive: parses net_hdr, checks num_buffers,
    // merges additional buffers if needed, and builds the packet.
    // ==================================================================
    // 解析首 buffer 的标准 header，并按 num_buffers 消费后续完成项合包；复制后
    // 回收 buffer。非法 token/header 或缺少后续完成项报错计数，供负向场景诊断。
    protected virtual task receive_mergeable(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        virtqueue_base     vq;
        uvm_object         token;
        int unsigned       len;
        int unsigned       count;
        int unsigned       hdr_size;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("RX_ENG",
                $sformatf("receive_mergeable: queue %0d not found", queue_id))
            return;
        end

        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);
        count = 0;

        while (count < budget) begin
            virtio_buf_tracker tracker;
            byte              buf_data[];
            byte unsigned      payload[$];
            virtio_net_hdr_t   net_hdr;
            bit [63:0]         buf_gpa;
            int unsigned       num_bufs;

            // 1. Poll for next used buffer
            if (!vq.poll_used(token, len))
                break;

            // 2. Recover GPA from tracker token
            if (!$cast(tracker, token) || tracker.count() == 0) begin
                `uvm_error("RX_ENG",
                    "receive_mergeable: invalid tracker token")
                total_rx_errors++;
                continue;
            end

            buf_gpa = tracker.gpa_list[0];

            // 3. Read buffer data from host memory
            mem.read_mem(buf_gpa, len, buf_data);

            // 4. Parse net_hdr from the beginning of the buffer
            if (buf_data.size() < hdr_size) begin
                `uvm_error("RX_ENG",
                    $sformatf("receive_mergeable: buffer too small (%0d < hdr %0d)",
                              buf_data.size(), hdr_size))
                cleanup_rx_buffer(buf_gpa);
                total_rx_errors++;
                continue;
            end

            begin
                byte unsigned buf_data_u[$];
                foreach (buf_data[i]) buf_data_u.push_back(buf_data[i]);
                virtio_net_hdr_util::unpack_hdr(buf_data_u, negotiated_features, net_hdr);

                // 5. Extract payload (everything after the header)
                for (int i = hdr_size; i < len; i++)
                    payload.push_back(buf_data_u[i]);
            end

            // 6. Cleanup first buffer
            cleanup_rx_buffer(buf_gpa);

            // 7. Merge additional buffers if num_buffers > 1
            num_bufs = net_hdr.num_buffers;
            // num_buffers is only meaningful with MRG_RXBUF; a VERSION_1
            // header carries the field but the packet is always one buffer.
            if (num_bufs == 0 || !negotiated_features[VIRTIO_NET_F_MRG_RXBUF])
                num_bufs = 1;  // Spec says 0 means 1 for legacy

            if (num_bufs > 1) begin
                for (int i = 1; i < num_bufs; i++) begin
                    uvm_object         merge_token;
                    int unsigned       merge_len;
                    virtio_buf_tracker merge_tracker;
                    byte              merge_data[];
                    bit [63:0]         merge_gpa;

                    if (!vq.poll_used(merge_token, merge_len)) begin
                        `uvm_error("RX_ENG",
                            $sformatf("receive_mergeable: expected %0d buffers, got %0d",
                                      num_bufs, i))
                        total_rx_errors++;
                        break;
                    end

                    if (!$cast(merge_tracker, merge_token) || merge_tracker.count() == 0) begin
                        `uvm_error("RX_ENG",
                            "receive_mergeable: invalid merge tracker token")
                        total_rx_errors++;
                        continue;
                    end

                    merge_gpa = merge_tracker.gpa_list[0];
                    mem.read_mem(merge_gpa, merge_len, merge_data);

                    // Append all data (no header in continuation buffers)
                    foreach (merge_data[j])
                        payload.push_back(merge_data[j]);

                    cleanup_rx_buffer(merge_gpa);
                end
                total_rx_merged++;
            end

            // 8. RX checksum verification
            if (negotiated_features[VIRTIO_NET_F_GUEST_CSUM]) begin
                if (!offload.verify_rx_csum(net_hdr, payload)) begin
                    `uvm_warning("RX_ENG",
                        $sformatf("receive_mergeable: RX checksum verification failed, pkt_size=%0d",
                                  payload.size()))
                end
            end

            // 9. Return a real net_packet item for valid Ethernet payloads.
            received.push_back(build_received_packet(payload, net_hdr));

            total_rx_packets++;
            total_rx_bytes += payload.size();
            count++;
        end

        `uvm_info("RX_ENG",
            $sformatf("receive_mergeable: queue=%0d received=%0d", queue_id, count),
            UVM_HIGH)

    endtask : receive_mergeable

    // ==================================================================
    // receive_big (protected)
    //
    // Big-buffer mode receive: single large buffer per packet, no merge.
    // ==================================================================
    // 大 buffer 模式委托单 buffer 接收；容量由投递时确定，本入口不再合包。
    protected virtual task receive_big(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        receive_single_buf(queue_id, budget, received);
    endtask : receive_big

    // ==================================================================
    // receive_small (protected)
    //
    // Small-buffer mode receive: single MTU-sized buffer per packet.
    // ==================================================================
    // MTU 大小模式委托单 buffer 接收；输出追加到 received，不改变其已有元素。
    protected virtual task receive_small(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        receive_single_buf(queue_id, budget, received);
    endtask : receive_small

    // ==================================================================
    // receive_single_buf (protected)
    //
    // Shared implementation for big and small modes. Each packet is
    // contained in exactly one buffer (no merging).
    // ==================================================================
    // 每个完成项解析一份标准 header 和 payload，校验可选 checksum 后返回 packet；
    // 非法 token 或过短 header 报错，合法 tracker 的 buffer 在复制后立即回收。
    protected virtual task receive_single_buf(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        virtqueue_base     vq;
        uvm_object         token;
        int unsigned       len;
        int unsigned       count;
        int unsigned       hdr_size;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("RX_ENG",
                $sformatf("receive_single_buf: queue %0d not found", queue_id))
            return;
        end

        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);
        count = 0;

        while (count < budget) begin
            virtio_buf_tracker tracker;
            byte              buf_data[];
            byte unsigned      payload[$];
            virtio_net_hdr_t   net_hdr;
            bit [63:0]         buf_gpa;

            if (!vq.poll_used(token, len))
                break;

            if (!$cast(tracker, token) || tracker.count() == 0) begin
                `uvm_error("RX_ENG", "receive_single_buf: invalid tracker token")
                total_rx_errors++;
                continue;
            end

            buf_gpa = tracker.gpa_list[0];

            // Read used data
            mem.read_mem(buf_gpa, len, buf_data);

            if (buf_data.size() < hdr_size) begin
                `uvm_error("RX_ENG",
                    $sformatf("receive_single_buf: buffer too small (%0d < hdr %0d)",
                              buf_data.size(), hdr_size))
                cleanup_rx_buffer(buf_gpa);
                total_rx_errors++;
                continue;
            end

            // Parse header
            begin
                byte unsigned buf_data_u[$];
                foreach (buf_data[i]) buf_data_u.push_back(buf_data[i]);
                virtio_net_hdr_util::unpack_hdr(buf_data_u, negotiated_features, net_hdr);

                // Extract payload
                for (int i = hdr_size; i < len; i++)
                    payload.push_back(buf_data_u[i]);
            end

            // Cleanup buffer
            cleanup_rx_buffer(buf_gpa);

            // RX checksum verification
            if (negotiated_features[VIRTIO_NET_F_GUEST_CSUM]) begin
                if (!offload.verify_rx_csum(net_hdr, payload)) begin
                    `uvm_warning("RX_ENG",
                        $sformatf("receive_single_buf: RX checksum failed, pkt_size=%0d",
                                  payload.size()))
                end
            end

            // Build a real net_packet item, preserving a wrapper for malformed
            // payloads that the protocol parser cannot decode.
            received.push_back(build_received_packet(payload, net_hdr));

            total_rx_packets++;
            total_rx_bytes += payload.size();
            count++;
        end

        `uvm_info("RX_ENG",
            $sformatf("receive_single_buf: queue=%0d received=%0d", queue_id, count),
            UVM_HIGH)

    endtask : receive_single_buf

    // ==================================================================
    // cleanup_rx_buffer (protected)
    //
    // Unmaps IOMMU entry and frees host memory for a single RX buffer.
    // ==================================================================
    // 注销指定 GPA 的本引擎映射并释放 Host 内存；只能用于已完成的自有 buffer，
    // 不能用它释放其他 ops/引擎所有的资源或仍被设备访问的缓冲。
    protected virtual function void cleanup_rx_buffer(bit [63:0] buf_gpa);
        if (rx_buf_gpa_to_iova.exists(buf_gpa)) begin
            iommu.unmap_for_host(host_id, bdf, rx_buf_gpa_to_iova[buf_gpa]);
            rx_buf_gpa_to_iova.delete(buf_gpa);
        end

        if (rx_buf_gpa_to_size.exists(buf_gpa))
            rx_buf_gpa_to_size.delete(buf_gpa);

        mem.free(buf_gpa);
    endfunction : cleanup_rx_buffer

    // ==================================================================
    // print_stats -- Log RX engine statistics
    // ==================================================================
    // 输出收包、字节、错误与本引擎未回收 buffer 计数，不改变运行态。
    function void print_stats();
        `uvm_info("RX_ENG_STATS",
            $sformatf({"RX Stats: packets=%0d bytes=%0d errors=%0d ",
                       "merged=%0d outstanding_bufs=%0d"},
                      total_rx_packets, total_rx_bytes, total_rx_errors,
                      total_rx_merged, rx_buf_gpa_to_iova.size()),
            UVM_LOW)
    endfunction : print_stats

    // ==================================================================
    // leak_check -- Warn about outstanding RX buffers at test end
    // ==================================================================
    // 检查本引擎持有的未完成 buffer，逐项告警而不强行释放；私有派生类的资源
    // 由 ops 跟踪，须另外检查 ops/IOMMU，不能以此表为空推断私有队列无泄漏。
    function void leak_check();
        if (rx_buf_gpa_to_iova.size() > 0) begin
            `uvm_warning("RX_ENG_LEAK",
                $sformatf("%0d outstanding RX buffer(s) -- possible leak",
                          rx_buf_gpa_to_iova.size()))
            foreach (rx_buf_gpa_to_iova[gpa]) begin
                `uvm_warning("RX_ENG_LEAK",
                    $sformatf("  GPA=0x%016x IOVA=0x%016x size=%0d",
                              gpa, rx_buf_gpa_to_iova[gpa],
                              rx_buf_gpa_to_size.exists(gpa) ? rx_buf_gpa_to_size[gpa] : 0))
            end
        end else begin
            `uvm_info("RX_ENG_LEAK",
                "RX engine: clean -- no outstanding buffers", UVM_LOW)
        end
    endfunction : leak_check

endclass : virtio_rx_engine

`endif // VIRTIO_RX_ENGINE_SV
