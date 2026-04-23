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
//   - virtio_dataplane_callback (optional custom RX parsing)
//   - virtio_net_hdr_util (unpack_hdr, get_hdr_size)
//   - virtio_buf_tracker (buffer lifecycle tracking)
// ============================================================================

// ============================================================================
// virtio_rx_pkt_wrapper
//
// Lightweight uvm_object that carries a received packet's payload and
// parsed virtio_net_hdr back to the caller. In a full net_packet
// integration, this would be replaced by packet_item with proper
// protocol parsing via $cast.
// ============================================================================

class virtio_rx_pkt_wrapper extends uvm_object;
    `uvm_object_utils(virtio_rx_pkt_wrapper)

    byte unsigned    payload[$];
    virtio_net_hdr_t net_hdr;
    int unsigned     pkt_len;

    function new(string name = "virtio_rx_pkt_wrapper");
        super.new(name);
        pkt_len = 0;
    endfunction

endclass : virtio_rx_pkt_wrapper

class virtio_rx_engine extends uvm_object;
    `uvm_object_utils(virtio_rx_engine)

    // ===== External references (set by parent before use) =====
    virtqueue_manager           vq_mgr;
    host_mem_manager            mem;
    virtio_iommu_model          iommu;
    virtio_offload_engine       offload;
    virtio_dataplane_callback   custom_cb;   // null = standard mode
    bit [15:0]                  bdf;

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
    function new(string name = "virtio_rx_engine");
        super.new(name);
        negotiated_features = 64'h0;
    endfunction

    // ==================================================================
    // get_rx_buf_size
    //
    // Returns the appropriate buffer allocation size based on the
    // current buffer mode.
    // ==================================================================
    function int unsigned get_rx_buf_size();
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
    virtual task refill_buffers(
        int unsigned queue_id,
        int unsigned count
    );
        virtqueue_base     vq;
        int unsigned       alloc_size;
        int unsigned       filled;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("RX_ENG",
                $sformatf("refill_buffers: queue %0d not found", queue_id))
            return;
        end

        alloc_size = get_rx_buf_size();
        filled = 0;

        while (filled < count && vq.get_free_count() > 0) begin
            bit [63:0]         buf_gpa, buf_iova;
            virtio_sg_list     sg;
            virtio_sg_list     sgs_arr[];
            virtio_buf_tracker tracker;

            // 1. Allocate host memory (64-byte aligned for cache line)
            buf_gpa = mem.alloc(alloc_size, .align(64));
            mem.mem_set(buf_gpa, 0, alloc_size);

            // 2. DMA map (device writes into these buffers)
            buf_iova = iommu.map(bdf, buf_gpa, alloc_size, DMA_FROM_DEVICE);

            // 3. Track for cleanup
            rx_buf_gpa_to_iova[buf_gpa] = buf_iova;
            rx_buf_gpa_to_size[buf_gpa] = alloc_size;

            // 4. Create tracker as token (carries GPA for retrieval at poll time)
            tracker = virtio_buf_tracker::type_id::create("rx_buf_tracker");
            tracker.add(buf_gpa, buf_iova, alloc_size);

            // 5. Build single-entry SG list (device-writable)
            sg.entries.push_back('{addr: buf_iova, len: alloc_size});
            sgs_arr = new[1];
            sgs_arr[0] = sg;

            // 6. Submit: n_out=0, n_in=1 (device-writable)
            vq.add_buf(sgs_arr, 0, 1, tracker, 0);

            filled++;
        end

        // Kick if device needs notification about new buffers
        if (filled > 0 && vq.needs_notification())
            vq.kick();

        `uvm_info("RX_ENG",
            $sformatf("refill_buffers: queue=%0d filled=%0d buf_size=%0d",
                      queue_id, filled, alloc_size),
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
    virtual task receive_packets(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        virtqueue_base vq;

        if (custom_cb != null) begin
            custom_receive(queue_id, budget, received);
        end else begin
            case (buf_mode)
                RX_MODE_MERGEABLE: receive_mergeable(queue_id, budget, received);
                RX_MODE_BIG:       receive_big(queue_id, budget, received);
                RX_MODE_SMALL:     receive_small(queue_id, budget, received);
            endcase
        end

        // Auto-refill if free count drops below threshold
        vq = vq_mgr.get_queue(queue_id);
        if (vq != null && vq.get_free_count() < refill_threshold)
            refill_buffers(queue_id, refill_threshold);

    endtask : receive_packets

    // ==================================================================
    // receive_mergeable (protected)
    //
    // Mergeable buffer receive: parses net_hdr, checks num_buffers,
    // merges additional buffers if needed, and builds the packet.
    // ==================================================================
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
            if (num_bufs == 0)
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

            // 9. Build received packet object.
            //    In a full net_packet integration this would $cast to packet_item
            //    and call pkt.pkt.unpack(payload). We use virtio_rx_pkt_wrapper
            //    as a lightweight carrier for the raw bytes and parsed header.
            begin
                virtio_rx_pkt_wrapper rx_pkt;
                rx_pkt = virtio_rx_pkt_wrapper::type_id::create("rx_pkt");
                rx_pkt.payload   = payload;
                rx_pkt.net_hdr   = net_hdr;
                rx_pkt.pkt_len   = payload.size();
                received.push_back(rx_pkt);
            end

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

            // Build received packet
            begin
                virtio_rx_pkt_wrapper rx_pkt;
                rx_pkt = virtio_rx_pkt_wrapper::type_id::create("rx_pkt");
                rx_pkt.payload   = payload;
                rx_pkt.net_hdr   = net_hdr;
                rx_pkt.pkt_len   = payload.size();
                received.push_back(rx_pkt);
            end

            total_rx_packets++;
            total_rx_bytes += payload.size();
            count++;
        end

        `uvm_info("RX_ENG",
            $sformatf("receive_single_buf: queue=%0d received=%0d", queue_id, count),
            UVM_HIGH)

    endtask : receive_single_buf

    // ==================================================================
    // custom_receive (protected)
    //
    // Delegates reception to the custom callback for non-standard
    // buffer layouts or parsing.
    // ==================================================================
    protected virtual task custom_receive(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("RX_ENG",
                $sformatf("custom_receive: queue %0d not found", queue_id))
            return;
        end

        count = 0;
        while (count < budget) begin
            virtio_buf_tracker tracker;
            byte              buf_data[];
            virtio_net_hdr_t   net_hdr;
            uvm_object         parsed_pkt;
            bit [63:0]         buf_gpa;

            if (!vq.poll_used(token, len))
                break;

            if (!$cast(tracker, token) || tracker.count() == 0) begin
                `uvm_error("RX_ENG", "custom_receive: invalid tracker token")
                total_rx_errors++;
                continue;
            end

            buf_gpa = tracker.gpa_list[0];
            mem.read_mem(buf_gpa, len, buf_data);

            // Delegate to custom callback for parsing
            begin
                byte unsigned buf_data_u[$];
                foreach (buf_data[i]) buf_data_u.push_back(buf_data[i]);
                custom_cb.custom_rx_parse_buf(buf_data_u, net_hdr, parsed_pkt);
            end

            cleanup_rx_buffer(buf_gpa);

            if (parsed_pkt != null)
                received.push_back(parsed_pkt);

            total_rx_packets++;
            total_rx_bytes += len;
            count++;
        end

        `uvm_info("RX_ENG",
            $sformatf("custom_receive: queue=%0d received=%0d", queue_id, count),
            UVM_HIGH)

    endtask : custom_receive

    // ==================================================================
    // cleanup_rx_buffer (protected)
    //
    // Unmaps IOMMU entry and frees host memory for a single RX buffer.
    // ==================================================================
    protected virtual function void cleanup_rx_buffer(bit [63:0] buf_gpa);
        if (rx_buf_gpa_to_iova.exists(buf_gpa)) begin
            iommu.unmap(bdf, rx_buf_gpa_to_iova[buf_gpa]);
            rx_buf_gpa_to_iova.delete(buf_gpa);
        end

        if (rx_buf_gpa_to_size.exists(buf_gpa))
            rx_buf_gpa_to_size.delete(buf_gpa);

        mem.free(buf_gpa);
    endfunction : cleanup_rx_buffer

    // ==================================================================
    // print_stats -- Log RX engine statistics
    // ==================================================================
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
