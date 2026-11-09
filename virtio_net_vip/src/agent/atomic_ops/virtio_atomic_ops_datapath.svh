    // src/agent/atomic_ops：virtio_atomic_ops 类体中的 TX/RX 数据路径，由
    // agent/virtio_atomic_ops.sv 在类定义内部 include，不单独编译。
    // 依赖 packet adapter、virtqueue、Host memory 和 IOMMU；ops 拥有每包 DMA，
    // 发布失败时回滚，成功后随队列完成释放。报文对象只借用，发送字节使用副本。

    // ========================================================================
    // TX Data Path
    // ========================================================================

    // ------------------------------------------------------------------------
    // tx_submit：读取本包真实字节，按请求生成标准 header 或 Custom 控制，随后
    // 等待空位后分配并映射DMA、发布SG、通知设备。desc_id返回队列首槽，失败保持'1。
    // timeout_ns只限制本包等待空位的时间；0使用wait_policy默认值。
    // notify=0允许合并DB；空间不足时仍先通知已提交部分，避免双方互等。
    // tx_offload.valid=0 保留调用方显式 net_hdr/私有队列默认值；显式请求在
    // DMA 分配前完成协议与能力检查，不修改原始 packet 或 Function 的配置。
    // ------------------------------------------------------------------------
    extern virtual task tx_submit(
        int unsigned		queue_id,
        virtio_net_hdr_t		net_hdr,
        uvm_object		pkt,
        bit			use_indirect,
        ref int unsigned	desc_id,
        input virtio_tx_offload_t	tx_offload = '0,
        input int unsigned		timeout_ns = 0,
        input bit			notify = 1,
        input virtio_tx_seg_t	tx_seg = '0
    );

    // 只计算本包分段，不分配资源；非法参数返回原因，由 tx_submit 在发布前 fatal。
    extern protected function bit plan_tx_segments(
        virtqueue_base	vq,
        int unsigned	packet_length,
        int unsigned	header_size,
        bit		tso,
        bit		indirect,
        virtio_tx_seg_t	request,
        output int unsigned	lengths[$],
        output int unsigned	needed,
        output string	why
    );

    // ------------------------------------------------------------------------
    // tx_complete -- Poll used ring for completed TX buffers
    // ------------------------------------------------------------------------
    virtual task tx_complete(
        int unsigned     queue_id,
        ref uvm_object   completed_pkts[$],
        input int unsigned     max_budget
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count = 0;

        if (!completion_permitted(queue_id)) return;
        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        while (count < max_budget) begin
            if (vq.poll_used(token, len)) begin
                completed_pkts.push_back(token);
                count++;
            end else begin
                break;
            end
        end

        // Clean up IOMMU mappings for completed TX buffers：每包 header+data 两条，
        // 不带 header 的队列格式只有 data 一条。
        if (tx_dma_map.exists(queue_id)) begin
            int unsigned iovas_to_free =
                count * ((vq.net_hdr_bytes(negotiated_features) == 0) ? 1 : 2);
            for (int unsigned i = 0; i < iovas_to_free && tx_dma_map[queue_id].size() > 0; i++) begin
                normal_dma_record_t record = tx_dma_map[queue_id].pop_front();
                retire_normal_dma_record(record);
            end
            if (tx_dma_map[queue_id].size() == 0)
                tx_dma_map.delete(queue_id);
        end

        if (count > 0)
            `uvm_info("ATOMIC_OPS",
                $sformatf("tx_complete: queue_id=%0d completed=%0d", queue_id, count), UVM_HIGH)
        if (count == max_budget && count != 0) retain_external_completion(queue_id);
    endtask

    // ========================================================================
    // RX Data Path
    // ========================================================================

    // ------------------------------------------------------------------------
    // rx_refill -- Pre-fill receive queue with empty buffers
    // ------------------------------------------------------------------------
    // buf_size 为描述符可写长度（含 virtio-net header）；0 表示默认 header+1514，
    // dataplane 引擎传入其配置容量。只累计实际投递数，满环不重复打印；分配/映射错误保留。
    virtual task rx_refill(
        int unsigned     queue_id,
        int unsigned     num_bufs,
        int unsigned     buf_size = 0
    );
        virtqueue_base   vq;
        int unsigned     buf_dma_size;
        int unsigned     hdr_size;
        int unsigned     filled = 0;
        virtio_dma_buffer_set dma_set;

        if (!external_queue_ready(queue_id)) return;
        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        // Determine buffer size based on header size + typical MTU
        hdr_size = vq.net_hdr_bytes(negotiated_features);

        // 默认容量：配置后端给出的队列 RX 容量（私有环），否则 header + 1514。
        if ((buf_size == 0) && queue_programs.exists(queue_id))
            buf_size = queue_programs[queue_id].rx_buf_size;
        if (buf_size == 0)
            buf_size = hdr_size + 1514;
        buf_dma_size = (buf_size + 3) & ~3;

        // 每个 buffer 是一次独立提交：成功后所有权转入 rx_dma_map，集合清空复用。
        dma_set = new("rx_dma");
        dma_set.bind_domain(mem, iommu, get_iommu_host_id(transport), transport.bdf);

        while (filled < num_bufs && vq.get_free_count() > 0) begin
            int              buf_idx;
            virtio_sg_list   sgs[1];
            virtio_sg_entry  buf_entry;
            int unsigned     result;

            // Allocate RX buffer from host memory
            buf_idx = dma_set.alloc(buf_dma_size);
            if (buf_idx < 0) begin
                `uvm_warning("ATOMIC_OPS",
                    $sformatf("rx_refill: host_mem alloc failed at buffer %0d", filled))
                break;
            end

            // Zero-fill the buffer
            dma_set.fill(buf_idx, 8'h00);

            // Map through IOMMU (DMA_FROM_DEVICE -- device writes to this buffer)
            if (!dma_set.map(buf_idx, DMA_FROM_DEVICE)) begin
                dma_set.release_all();
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "rx_refill: failed to map buffer %0d for queue %0d",
                    filled, queue_id))
                break;
            end

            // Build sg: single device-writable buffer (n_out=0, n_in=1)
            buf_entry.addr = dma_set.get_iova(buf_idx);
            buf_entry.len  = buf_size;
            sgs[0].entries.push_back(buf_entry);

            result = vq.add_buf(sgs, 0, 1, null, 0);
            if (result == '1) begin
                dma_set.release_all();
                break;
            end

            // Track the complete DMA ownership pair for completion/reset.
            if (!rx_dma_map.exists(queue_id))
                rx_dma_map[queue_id] = {};
            adopt_dma_set(dma_set, rx_dma_map[queue_id]);
            filled++;
            rx_posted_buffers++;
        end

        // Kick if device needs notification
        if (filled > 0 && vq.needs_notification())
            kick_with_fault(vq, queue_id);

    endtask

    // ------------------------------------------------------------------------
    // rx_receive_frames -- Poll used ring and return header + payload frames
    //
    // 每个 used 项按 MRG_RXBUF 语义合并后续 buffer；每个描述符的 IOVA/GPA
    // 所有权在复制后立即退休。帧追加到 frames，不解析报文协议；空轮询仅计数。
    // ------------------------------------------------------------------------
    virtual task rx_receive_frames(
        int unsigned          queue_id,
        int unsigned          max_budget,
        ref virtio_rx_frame_t frames[$]
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count = 0;
        int unsigned     hdr_size;

        if (!completion_permitted(queue_id)) return;
        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        if (max_budget != 0) rx_polls++;
        hdr_size = vq.net_hdr_bytes(negotiated_features);

        while (count < max_budget) begin
            if (vq.poll_used(token, len)) begin
                normal_dma_record_t record;
                byte buf_data[];
                byte unsigned first_bytes[$];
                virtio_rx_frame_t frame;

                if (!rx_dma_map.exists(queue_id) ||
                    (rx_dma_map[queue_id].size() == 0)) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "rx_receive: used entry has no DMA ownership queue=%0d",
                        queue_id))
                    break;
                end
                record = rx_dma_map[queue_id].pop_front();
                mem.read_mem(record.gpa, len, buf_data);
                foreach (buf_data[i]) first_bytes.push_back(buf_data[i]);
                if (buf_data.size() < hdr_size) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "rx_receive: buffer shorter than virtio header queue=%0d len=%0d hdr=%0d",
                        queue_id, buf_data.size(), hdr_size))
                    retire_normal_dma_record(record);
                    break;
                end
                if (hdr_size != 0)
                    virtio_net_hdr_util::unpack_hdr(first_bytes,
                                                    negotiated_features, frame.net_hdr);
                else
                    frame.net_hdr = '{default:0};
                for (int unsigned i = hdr_size; i < buf_data.size(); i++)
                    frame.payload.push_back(buf_data[i]);
                // Only MRG_RXBUF gives num_buffers meaning; a VERSION_1
                // header carries the field for a single-buffer packet.
                frame.num_buffers = ((frame.net_hdr.num_buffers == 0) ||
                                     !negotiated_features[VIRTIO_NET_F_MRG_RXBUF]) ? 1 :
                                    frame.net_hdr.num_buffers;
                frame.token = token;
                retire_normal_dma_record(record);

                // Merge continuation buffers.  Every consumed descriptor
                // retires its own IOVA/GPA ownership only after its bytes
                // are copied.
                for (int unsigned merge = 1; merge < frame.num_buffers; merge++) begin
                    normal_dma_record_t merge_record;
                    byte merge_data[];
                    uvm_object merge_token;
                    int unsigned merge_len;
                    if (!vq.poll_used(merge_token, merge_len) ||
                        !rx_dma_map.exists(queue_id) ||
                        (rx_dma_map[queue_id].size() == 0)) begin
                        `uvm_error("ATOMIC_OPS", $sformatf(
                            "rx_receive: missing merged buffer queue=%0d expected=%0d got=%0d",
                            queue_id, frame.num_buffers, merge))
                        break;
                    end
                    merge_record = rx_dma_map[queue_id].pop_front();
                    mem.read_mem(merge_record.gpa, merge_len, merge_data);
                    foreach (merge_data[i]) frame.payload.push_back(merge_data[i]);
                    retire_normal_dma_record(merge_record);
                end

                frames.push_back(frame);
                rx_packets++;
                rx_bytes += frame.payload.size();
                count++;
            end else begin
                break;
            end
        end

        if (max_budget != 0 && count == 0) rx_empty_polls++;

        if (rx_dma_map.exists(queue_id) &&
            (rx_dma_map[queue_id].size() == 0))
            rx_dma_map.delete(queue_id);
        if (count == max_budget && count != 0) retain_external_completion(queue_id);
    endtask

    // ------------------------------------------------------------------------
    // rx_receive -- Poll used ring for received packets
    //
    // 合法以太网帧解析为 packet_item；解析失败时若 used 项带 token 则返回 token。
    // 帧数与空轮询统一由 rx_receive_frames 计数，此适配入口不重复输出日志。
    // ------------------------------------------------------------------------
    virtual task rx_receive(
        int unsigned     queue_id,
        ref uvm_object   received_pkts[$],
        input int unsigned     max_budget
    );
        virtio_rx_frame_t frames[$];

        rx_receive_frames(queue_id, max_budget, frames);
        foreach (frames[i]) begin
            packet_item parsed_item;
            if (virtio_net_packet_adapter::unpack(frames[i].payload, parsed_item))
                received_pkts.push_back(parsed_item);
            else if (frames[i].token != null)
                received_pkts.push_back(frames[i].token);
        end
    endtask
