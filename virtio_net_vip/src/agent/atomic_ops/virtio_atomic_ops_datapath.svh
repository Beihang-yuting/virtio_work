    // 本文件是 virtio_atomic_ops 类体的一部分（TX/RX 数据路径），只由
    // agent/virtio_atomic_ops.sv 在类定义内部 `include；不得单独编译或在类外包含。

    // ========================================================================
    // TX Data Path
    // ========================================================================

    // ------------------------------------------------------------------------
    // tx_submit -- Submit a packet for transmission
    //
    // Steps:
    //   1. Pack virtio_net_hdr to bytes
    //   2. Get wire bytes (net_packet adapter, else do_pack)
    //   3. Allocate host_mem for hdr + data buffers
    //   4. Write hdr and data to host_mem
    //   5. Map through IOMMU (DMA_TO_DEVICE)
    //   6. Build scatter-gather lists
    //   7. add_buf to virtqueue
    //   8. Kick if needed
    //   9. Return desc_id
    // ------------------------------------------------------------------------
    virtual task tx_submit(
        int unsigned     queue_id,
        virtio_net_hdr_t net_hdr,
        uvm_object       pkt,
        bit              use_indirect,
        ref int unsigned desc_id
    );
        virtqueue_base   vq;
        byte unsigned    hdr_bytes[$];
        byte unsigned    pkt_bytes[];
        int unsigned     hdr_size;
        int unsigned     hdr_dma_size;
        int unsigned     pkt_size;
        int unsigned     pkt_dma_size;
        int              hdr_idx;
        int              pkt_idx;
        virtio_sg_list   sgs[2];
        virtio_sg_entry  hdr_entry;
        virtio_sg_entry  pkt_entry;
        byte             hdr_data[];
        byte             pkt_data[];
        byte unsigned    wire_bytes[$];
        virtio_dma_buffer_set dma_set;
        int unsigned     n_out;

        desc_id = '1;
        if (use_indirect &&
            !negotiated_features[VIRTIO_F_RING_INDIRECT_DESC]) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: queue %0d requested indirect descriptors without negotiating VIRTIO_F_RING_INDIRECT_DESC",
                queue_id))
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d", queue_id), UVM_HIGH)

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: queue %0d not found", queue_id))
            return;
        end

        // 1. Pack net_hdr to bytes.  队列格式不带 virtio-net header（DPU 私有环）时只发
        // 原始帧，header 中的 offload 请求无处承载，显式拒绝。
        hdr_size = vq.net_hdr_bytes(negotiated_features);
        if ((hdr_size == 0) && ((net_hdr.flags != 0) ||
                                (net_hdr.gso_type != VIRTIO_NET_HDR_GSO_NONE))) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: queue %0d carries no virtio-net header; offload request rejected",
                queue_id))
            return;
        end
        if (hdr_size != 0) begin
            virtio_net_hdr_util::pack_hdr(net_hdr, negotiated_features, hdr_bytes);
            hdr_size = hdr_bytes.size();
        end
        // PCIe Memory Read completions are DWORD based.  Keep the descriptor
        // length byte-accurate, but give the model/RC responder a DWORD-padded
        // backing allocation so a final partial DWORD never crosses an exact
        // host_mem block boundary.
        hdr_dma_size = (hdr_size + 3) & ~3;

        // 2. Get wire bytes.  packet_item.do_pack() 带 32-bit UVM 长度前缀，不是
        // 线速帧，先经 adapter 取 raw_data；其他对象保留原 do_pack 字节流。
        if (virtio_net_packet_adapter::pack(pkt, wire_bytes)) begin
            pkt_bytes = new[wire_bytes.size()];
            foreach (wire_bytes[i]) pkt_bytes[i] = wire_bytes[i];
        end else begin
            uvm_packer packer;
            packer = new();
            pkt.do_pack(packer);
            packer.get_bytes(pkt_bytes);
        end
        pkt_size = pkt_bytes.size();

        // If packet has no data from do_pack, use minimum Ethernet frame size
        if (pkt_size == 0)
            pkt_size = 64;
        // Keep the backing allocation DWORD padded after the minimum-size
        // fallback as well; otherwise an empty packet would request a
        // zero-byte host_mem allocation even though the descriptor carries
        // the 64-byte minimum frame.
        pkt_dma_size = (pkt_size + 3) & ~3;

        // 3. Allocate host_mem for hdr + data buffers.  A failed second
        //    allocation rolls back the first; nothing is mapped yet.
        dma_set = new("tx_dma");
        dma_set.bind_domain(mem, iommu, get_iommu_host_id(transport), transport.bdf);
        hdr_idx = (hdr_size == 0) ? -1 : dma_set.alloc(hdr_dma_size);
        pkt_idx = ((hdr_size != 0) && (hdr_idx < 0)) ? -1 : dma_set.alloc(pkt_dma_size);
        if (pkt_idx < 0) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: host_mem alloc failed for queue %0d", queue_id))
            return;
        end

        // 4. Write hdr and data to host_mem
        if (hdr_size != 0) begin
            hdr_data = new[hdr_size];
            foreach (hdr_bytes[i]) hdr_data[i] = hdr_bytes[i];
            dma_set.write(hdr_idx, hdr_data);
        end

        if (pkt_bytes.size() > 0) begin
            pkt_data = new[pkt_size];
            foreach (pkt_bytes[i]) pkt_data[i] = pkt_bytes[i];
            dma_set.write(pkt_idx, pkt_data);
        end

        // 5. Map through IOMMU (DMA_TO_DEVICE -- device reads these buffers)
        if ((hdr_size != 0) && !dma_set.map(hdr_idx, DMA_TO_DEVICE)) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: failed to map header for queue %0d", queue_id))
            return;
        end
        if (!dma_set.map(pkt_idx, DMA_TO_DEVICE)) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: failed to map payload for queue %0d", queue_id))
            return;
        end

        // 6. Build scatter-gather lists: [hdr_sg(out)] [data_sg(out)]；无 header 时只有 data。
        n_out = 0;
        if (hdr_size != 0) begin
            hdr_entry.addr = dma_set.get_iova(hdr_idx);
            hdr_entry.len  = hdr_size;
            sgs[n_out].entries.push_back(hdr_entry);
            n_out++;
        end

        pkt_entry.addr = dma_set.get_iova(pkt_idx);
        pkt_entry.len  = pkt_size;
        sgs[n_out].entries.push_back(pkt_entry);
        n_out++;

        // 7. Add buffers to virtqueue (n_out=2, n_in=0).  The data buffers
        //    belong to this operation, not to add_buf(); a rejected chain
        //    rolls back and never reaches the completion map or notify path.
        desc_id = vq.add_buf(sgs, n_out, 0, pkt, use_indirect);
        if (desc_id == '1) begin
            dma_set.release_all();
            return;
        end

        // Hand the ownership records (hdr first, matching tx_complete's
        // per-packet retirement count) to completion/reset before notifying.
        if (!tx_dma_map.exists(queue_id))
            tx_dma_map[queue_id] = {};
        adopt_dma_set(dma_set, tx_dma_map[queue_id]);

        // 8. Kick if device needs notification
        if (vq.needs_notification())
            kick_with_fault(vq, queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d desc_id=%0d hdr_iova=0x%016h pkt_iova=0x%016h",
                      queue_id, desc_id, hdr_entry.addr, pkt_entry.addr), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // tx_complete -- Poll used ring for completed TX buffers
    // ------------------------------------------------------------------------
    virtual task tx_complete(
        int unsigned     queue_id,
        ref uvm_object   completed_pkts[$],
        int unsigned     max_budget
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count = 0;

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
    endtask

    // ========================================================================
    // RX Data Path
    // ========================================================================

    // ------------------------------------------------------------------------
    // rx_refill -- Pre-fill receive queue with empty buffers
    // ------------------------------------------------------------------------
    // buf_size 为描述符可写长度（含 virtio-net header）；0 表示默认 header+1514，
    // dataplane 引擎传入其配置容量。所有覆写须保持同一签名。
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
        end

        // Kick if device needs notification
        if (filled > 0 && vq.needs_notification())
            kick_with_fault(vq, queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("rx_refill: queue_id=%0d filled=%0d/%0d", queue_id, filled, num_bufs),
            UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // rx_receive_frames -- Poll used ring and return header + payload frames
    //
    // 每个 used 项按 MRG_RXBUF 语义合并后续 buffer；每个描述符的 IOVA/GPA
    // 所有权在复制后立即退休。帧追加到 frames，不解析报文协议。
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

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

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
                count++;
            end else begin
                break;
            end
        end

        if (rx_dma_map.exists(queue_id) &&
            (rx_dma_map[queue_id].size() == 0))
            rx_dma_map.delete(queue_id);
    endtask

    // ------------------------------------------------------------------------
    // rx_receive -- Poll used ring for received packets
    //
    // 合法以太网帧解析为 packet_item；解析失败时若 used 项带 token 则返回 token。
    // ------------------------------------------------------------------------
    virtual task rx_receive(
        int unsigned     queue_id,
        ref uvm_object   received_pkts[$],
        int unsigned     max_budget
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

        if (frames.size() > 0)
            `uvm_info("ATOMIC_OPS",
                $sformatf("rx_receive: queue_id=%0d received=%0d", queue_id, frames.size()), UVM_HIGH)
    endtask
