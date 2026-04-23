`ifndef VIRTIO_TX_ENGINE_SV
`define VIRTIO_TX_ENGINE_SV

// ============================================================================
// virtio_buf_tracker
//
// Lightweight tracker for DMA buffer allocations associated with a single
// virtqueue operation. Stores parallel lists of GPA, IOVA, and size so that
// cleanup (iommu.unmap + mem.free) can be performed after completion.
// ============================================================================

class virtio_buf_tracker extends uvm_object;
    `uvm_object_utils(virtio_buf_tracker)

    bit [63:0]   gpa_list[$];
    bit [63:0]   iova_list[$];
    int unsigned size_list[$];

    function new(string name = "virtio_buf_tracker");
        super.new(name);
    endfunction

    function void add(bit [63:0] gpa, bit [63:0] iova, int unsigned size);
        gpa_list.push_back(gpa);
        iova_list.push_back(iova);
        size_list.push_back(size);
    endfunction

    function int unsigned count();
        return gpa_list.size();
    endfunction
endclass : virtio_buf_tracker

typedef byte unsigned virtio_byte_queue_t[$];

// ============================================================================
// virtio_tx_engine
//
// Handles packet transmission on the driver (guest) side:
//   1. Builds virtio_net_hdr from raw packet data (checksum, GSO fields).
//   2. Constructs scatter-gather chains (header buffer + data buffer).
//   3. Submits chains to a transmit virtqueue via virtqueue_manager.
//   4. Handles TX completion: polls used ring, unmaps DMA, frees memory.
//
// The packet is passed as a uvm_object handle (packet_item from net_packet).
// Runtime $cast is used for type-safe access; if cast fails the engine
// treats raw_data as an opaque byte queue.
//
// Depends on:
//   - virtqueue_manager, virtqueue_base (add_buf, poll_used, kick)
//   - host_mem_manager (alloc, write_mem, free)
//   - virtio_iommu_model (map, unmap)
//   - virtio_offload_engine (checksum, GSO helpers)
//   - virtio_dataplane_callback (optional custom chain builder)
//   - virtio_net_hdr_util (pack_hdr)
//   - virtio_buf_tracker (buffer lifecycle tracking)
// ============================================================================

class virtio_tx_engine extends uvm_object;
    `uvm_object_utils(virtio_tx_engine)

    // ===== External references (set by parent before use) =====
    virtqueue_manager           vq_mgr;
    host_mem_manager            mem;
    virtio_iommu_model          iommu;
    virtio_offload_engine       offload;
    virtio_dataplane_callback   custom_cb;   // null = standard mode
    bit [15:0]                  bdf;

    // ===== Configuration =====
    bit [63:0]       negotiated_features;
    int unsigned     mtu = 1500;

    // ===== Statistics =====
    longint unsigned total_tx_packets  = 0;
    longint unsigned total_tx_bytes    = 0;
    longint unsigned total_tx_errors   = 0;
    longint unsigned total_tx_sg_count = 0;

    // ===== Buffer tracking: token -> buf_tracker =====
    // Each submitted packet gets a virtio_buf_tracker stored here so that
    // complete_tx can unmap and free the corresponding DMA buffers.
    protected virtio_buf_tracker tx_buf_map[uvm_object];

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtio_tx_engine");
        super.new(name);
        negotiated_features = 64'h0;
    endfunction

    // ==================================================================
    // submit_packet
    //
    // Top-level TX entry point. Builds virtio_net_hdr from the packet,
    // then submits the header + payload to the specified transmit queue.
    //
    // Parameters:
    //   queue_id     -- Target TX virtqueue ID
    //   pkt          -- packet_item handle (as uvm_object)
    //   use_indirect -- Use indirect descriptors if supported
    //   desc_id      -- [output] Descriptor ID returned by add_buf
    // ==================================================================
    virtual task submit_packet(
        int unsigned     queue_id,
        uvm_object       pkt,
        bit              use_indirect,
        ref int unsigned desc_id
    );
        byte unsigned    pkt_data[$];
        virtio_net_hdr_t hdr;

        // ---- 1. Extract raw packet bytes ----
        pkt_data = extract_pkt_data(pkt);
        if (pkt_data.size() == 0) begin
            `uvm_error("TX_ENG",
                $sformatf("submit_packet: empty packet data on queue %0d", queue_id))
            total_tx_errors++;
            return;
        end

        // ---- 2. Build virtio_net_hdr ----
        build_net_hdr(pkt_data, hdr);

        // ---- 3. GSO: for virtio TX the driver sends the full large packet
        //         with GSO fields set in the header. The device performs
        //         segmentation. So we do NOT segment here — just set the
        //         header fields (already done in build_net_hdr). ----

        // ---- 4. Submit to virtqueue ----
        submit_single(queue_id, pkt_data, hdr, pkt, use_indirect, desc_id);

    endtask : submit_packet

    // ==================================================================
    // submit_single (protected)
    //
    // Builds the scatter-gather chain and calls add_buf on the virtqueue.
    // ==================================================================
    protected virtual task submit_single(
        int unsigned     queue_id,
        byte unsigned    pkt_data[$],
        virtio_net_hdr_t hdr,
        uvm_object       token,
        bit              use_indirect,
        ref int unsigned desc_id
    );
        virtqueue_base     vq;
        virtio_sg_list     sgs[$];
        virtio_sg_list     sgs_arr[];
        virtio_buf_tracker tracker;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("TX_ENG",
                $sformatf("submit_single: queue %0d not found", queue_id))
            total_tx_errors++;
            return;
        end

        // Build tracker for this submission
        tracker = virtio_buf_tracker::type_id::create("tx_tracker");

        // Build scatter-gather chain
        if (custom_cb != null) begin
            custom_cb.custom_tx_build_chain(token, hdr, sgs);
        end else begin
            standard_tx_build_chain(pkt_data, hdr, sgs, tracker);
        end

        // Convert dynamic queue to static array for add_buf
        sgs_arr = new[sgs.size()];
        foreach (sgs[i])
            sgs_arr[i] = sgs[i];

        // All SGs are device-readable (out): n_out = sgs.size(), n_in = 0
        desc_id = vq.add_buf(sgs_arr, sgs_arr.size(), 0, token, use_indirect);

        // Store tracker for cleanup at completion time
        tx_buf_map[token] = tracker;

        // Update statistics
        total_tx_packets++;
        total_tx_bytes    += pkt_data.size();
        total_tx_sg_count += sgs_arr.size();

        `uvm_info("TX_ENG",
            $sformatf("submit_single: queue=%0d desc_id=%0d pkt_size=%0d sgs=%0d",
                      queue_id, desc_id, pkt_data.size(), sgs_arr.size()),
            UVM_HIGH)

    endtask : submit_single

    // ==================================================================
    // standard_tx_build_chain (protected)
    //
    // Standard TX chain layout: [net_hdr (out)] [pkt_data (out)]
    // Both buffers are device-readable (DMA_TO_DEVICE).
    // ==================================================================
    protected virtual task standard_tx_build_chain(
        byte unsigned          pkt_data[$],
        virtio_net_hdr_t       hdr,
        ref virtio_sg_list     sgs[$],
        ref virtio_buf_tracker tracker
    );
        byte unsigned  hdr_bytes[$];
        bit [63:0]     hdr_gpa, hdr_iova;
        bit [63:0]     data_gpa, data_iova;
        virtio_sg_list hdr_sg, data_sg;

        // ---- 1. Pack net_hdr to bytes ----
        virtio_net_hdr_util::pack_hdr(hdr, negotiated_features, hdr_bytes);

        // ---- 2. Allocate host memory for header buffer ----
        hdr_gpa = mem.alloc(hdr_bytes.size(), .align(1));
        begin
            byte hdr_tmp[] = new[hdr_bytes.size()];
            foreach (hdr_bytes[i]) hdr_tmp[i] = hdr_bytes[i];
            mem.write_mem(hdr_gpa, hdr_tmp);
        end

        // ---- 3. Allocate host memory for data buffer ----
        data_gpa = mem.alloc(pkt_data.size(), .align(1));
        begin
            byte data_tmp[] = new[pkt_data.size()];
            foreach (pkt_data[i]) data_tmp[i] = pkt_data[i];
            mem.write_mem(data_gpa, data_tmp);
        end

        // ---- 4. DMA map both (device reads these) ----
        hdr_iova  = iommu.map(bdf, hdr_gpa,  hdr_bytes.size(), DMA_TO_DEVICE);
        data_iova = iommu.map(bdf, data_gpa, pkt_data.size(),  DMA_TO_DEVICE);

        // ---- 5. Track allocations for cleanup ----
        tracker.add(hdr_gpa,  hdr_iova,  hdr_bytes.size());
        tracker.add(data_gpa, data_iova, pkt_data.size());

        // ---- 6. Build scatter-gather lists ----
        hdr_sg.entries.push_back('{addr: hdr_iova,  len: hdr_bytes.size()});
        data_sg.entries.push_back('{addr: data_iova, len: pkt_data.size()});
        sgs.push_back(hdr_sg);
        sgs.push_back(data_sg);

    endtask : standard_tx_build_chain

    // ==================================================================
    // build_net_hdr (protected)
    //
    // Populates virtio_net_hdr fields based on raw packet data and
    // negotiated features. Sets checksum offload, GSO/TSO, and
    // hash report fields as appropriate.
    // ==================================================================
    protected virtual function void build_net_hdr(
        byte unsigned        pkt_data[$],
        ref virtio_net_hdr_t hdr
    );
        hdr = '{default: 0};

        // ---- Checksum offload ----
        if (negotiated_features[VIRTIO_NET_F_CSUM]) begin
            hdr.flags       = VIRTIO_NET_HDR_F_NEEDS_CSUM;
            hdr.csum_start  = offload.calc_csum_start(pkt_data);
            hdr.csum_offset = offload.calc_csum_offset(pkt_data);
        end

        // ---- GSO/TSO (header fields only -- device handles segmentation) ----
        if (offload.needs_gso(pkt_data)) begin
            hdr.gso_type = offload.get_gso_type(pkt_data);
            hdr.gso_size = offload.get_mss_value();
            hdr.hdr_len  = offload.get_all_hdr_len(pkt_data);
        end

        // ---- Hash report ----
        if (negotiated_features[VIRTIO_NET_F_HASH_REPORT]) begin
            hdr.hash_value  = offload.rss_calc_hash(pkt_data);
            hdr.hash_report = offload.rss_get_hash_type(pkt_data);
        end
    endfunction : build_net_hdr

    // ==================================================================
    // complete_tx
    //
    // Polls the used ring for completed TX descriptors, cleans up DMA
    // mappings and host memory, and returns completed tokens.
    //
    // Parameters:
    //   queue_id  -- TX virtqueue ID to poll
    //   budget    -- Maximum number of completions to process
    //   completed -- [output] List of completed packet tokens
    // ==================================================================
    virtual task complete_tx(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    completed[$]
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("TX_ENG",
                $sformatf("complete_tx: queue %0d not found", queue_id))
            return;
        end

        count = 0;
        while (count < budget) begin
            if (!vq.poll_used(token, len))
                break;

            // Cleanup DMA buffers for this token
            cleanup_tx_buffers(token);

            completed.push_back(token);
            count++;
        end

        `uvm_info("TX_ENG",
            $sformatf("complete_tx: queue=%0d completed=%0d", queue_id, count),
            UVM_HIGH)

    endtask : complete_tx

    // ==================================================================
    // cleanup_tx_buffers (protected)
    //
    // Unmaps IOMMU entries and frees host memory for all buffers
    // associated with a completed TX token.
    // ==================================================================
    protected virtual function void cleanup_tx_buffers(uvm_object token);
        virtio_buf_tracker tracker;

        if (!tx_buf_map.exists(token)) begin
            `uvm_info("TX_ENG",
                "cleanup_tx_buffers: no tracker found (custom_cb or already cleaned)",
                UVM_HIGH)
            return;
        end

        tracker = tx_buf_map[token];

        for (int i = 0; i < tracker.count(); i++) begin
            iommu.unmap(bdf, tracker.iova_list[i]);
            mem.free(tracker.gpa_list[i]);
        end

        tx_buf_map.delete(token);
    endfunction : cleanup_tx_buffers

    // ==================================================================
    // extract_pkt_data (protected)
    //
    // Extracts raw byte data from a uvm_object packet handle.
    // Uses uvm_packer to call pack() on the object, converting the
    // resulting bitstream to a byte queue. In a full net_packet
    // integration, $cast to packet_item would access pkt.raw_data
    // directly.
    // ==================================================================
    protected virtual function virtio_byte_queue_t extract_pkt_data(uvm_object pkt);
        byte unsigned data[$];
        uvm_packer packer;
        int unsigned pack_size;

        if (pkt == null) begin
            `uvm_error("TX_ENG", "extract_pkt_data: null packet handle")
            return data;
        end

        packer = new();
        pkt.do_pack(packer);
        pack_size = packer.get_packed_size();

        if (pack_size > 0) begin
            bit bitstream[];
            byte unsigned byte_val;
            int unsigned num_bytes;

            packer.get_bits(bitstream);
            num_bytes = bitstream.size() / 8;
            for (int i = 0; i < num_bytes; i++) begin
                byte_val = 0;
                for (int b = 0; b < 8; b++)
                    byte_val = {byte_val[6:0], bitstream[i*8 + b]};
                data.push_back(byte_val);
            end
        end

        return data;
    endfunction : extract_pkt_data

    // ==================================================================
    // print_stats -- Log TX engine statistics
    // ==================================================================
    function void print_stats();
        `uvm_info("TX_ENG_STATS",
            $sformatf({"TX Stats: packets=%0d bytes=%0d errors=%0d ",
                       "sg_chains=%0d outstanding=%0d"},
                      total_tx_packets, total_tx_bytes, total_tx_errors,
                      total_tx_sg_count, tx_buf_map.size()),
            UVM_LOW)
    endfunction : print_stats

    // ==================================================================
    // leak_check -- Warn about outstanding TX buffers at test end
    // ==================================================================
    function void leak_check();
        if (tx_buf_map.size() > 0) begin
            `uvm_warning("TX_ENG_LEAK",
                $sformatf("%0d outstanding TX buffer tracker(s) -- possible leak",
                          tx_buf_map.size()))
        end else begin
            `uvm_info("TX_ENG_LEAK",
                "TX engine: clean -- no outstanding buffer trackers", UVM_LOW)
        end
    endfunction : leak_check

endclass : virtio_tx_engine

`endif // VIRTIO_TX_ENGINE_SV
