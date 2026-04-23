`ifndef VIRTIO_ATOMIC_OPS_SV
`define VIRTIO_ATOMIC_OPS_SV

// ============================================================================
// virtio_atomic_ops
//
// Low-level atomic operations library for the virtio-net driver VIP.
// One method per real Linux virtio-net driver operation.
//
// Used by:
//   - virtio_auto_fsm (AUTO mode): full lifecycle orchestration
//   - Sequences directly (MANUAL mode): fine-grained control
//
// Depends on:
//   - virtio_pci_transport (PCI register access, kick, feature negotiation)
//   - virtqueue_manager (queue create/destroy/get)
//   - host_mem_manager (buffer allocation)
//   - virtio_iommu_model (DMA address translation)
//   - virtio_wait_policy (timeout/polling)
//   - virtio_net_types.sv (all type/struct definitions)
//   - virtio_net_hdr.sv (header pack/unpack)
// ============================================================================

class virtio_atomic_ops extends uvm_object;
    `uvm_object_utils(virtio_atomic_ops)

    // ===== External component references (set by agent) =====
    virtio_pci_transport       transport;
    virtqueue_manager          vq_mgr;
    host_mem_manager           mem;
    virtio_iommu_model         iommu;
    virtio_wait_policy         wait_pol;

    // ===== Negotiated state =====
    bit [63:0]                 negotiated_features;

    // ===== Internal tracking =====
    protected bit [63:0]       tx_iova_map[int unsigned][$];   // queue_id -> list of IOVAs for cleanup
    protected bit [63:0]       rx_iova_map[int unsigned][$];   // queue_id -> list of IOVAs for cleanup
    protected bit [63:0]       ring_iovas[int unsigned][$];    // queue_id -> ring IOVAs (desc, avail, used)

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_atomic_ops");
        super.new(name);
        negotiated_features = '0;
    endfunction

    // ========================================================================
    // Device Lifecycle
    // ========================================================================

    // ------------------------------------------------------------------------
    // device_reset -- Write status=0 and clean up all queue/DMA state
    // ------------------------------------------------------------------------
    virtual task device_reset();
        `uvm_info("ATOMIC_OPS", "device_reset: starting", UVM_MEDIUM)

        transport.reset_device();

        // Detach all queues if any exist
        if (vq_mgr.get_queue_count() > 0) begin
            vq_mgr.detach_all_queues();
        end

        // Clear all tracked IOMMU mappings for rings
        foreach (ring_iovas[qid]) begin
            foreach (ring_iovas[qid][i]) begin
                iommu.unmap(transport.bdf, ring_iovas[qid][i]);
            end
        end
        ring_iovas.delete();
        tx_iova_map.delete();
        rx_iova_map.delete();

        negotiated_features = '0;

        `uvm_info("ATOMIC_OPS", "device_reset: complete", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // set_acknowledge -- Set ACKNOWLEDGE bit in device status
    // ------------------------------------------------------------------------
    virtual task set_acknowledge();
        transport.write_device_status(DEV_STATUS_ACKNOWLEDGE);
        `uvm_info("ATOMIC_OPS", "set_acknowledge: done", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver -- OR current status with DRIVER bit and write back
    // ------------------------------------------------------------------------
    virtual task set_driver();
        bit [7:0] status;
        transport.read_device_status(status);
        status = status | DEV_STATUS_DRIVER;
        transport.write_device_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_features_ok -- Set FEATURES_OK and verify device accepted it
    // ------------------------------------------------------------------------
    virtual task set_features_ok(ref bit ok);
        bit [7:0] status;
        bit [7:0] readback;

        transport.read_device_status(status);
        status = status | DEV_STATUS_FEATURES_OK;
        transport.write_device_status(status);

        // Poll to confirm FEATURES_OK is still set
        transport.read_device_status(readback);
        ok = (readback & DEV_STATUS_FEATURES_OK) ? 1 : 0;

        if (!ok) begin
            `uvm_error("ATOMIC_OPS",
                "set_features_ok: device rejected features (FEATURES_OK not set)")
        end else begin
            `uvm_info("ATOMIC_OPS",
                $sformatf("set_features_ok: confirmed, status=0x%02h", readback), UVM_HIGH)
        end
    endtask

    // ------------------------------------------------------------------------
    // verify_features_ok -- Re-read status and check FEATURES_OK bit
    // ------------------------------------------------------------------------
    virtual task verify_features_ok(ref bit ok);
        bit [7:0] status;
        transport.read_device_status(status);
        ok = (status & DEV_STATUS_FEATURES_OK) ? 1 : 0;
        `uvm_info("ATOMIC_OPS",
            $sformatf("verify_features_ok: status=0x%02h ok=%0b", status, ok), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver_ok -- OR current status with DRIVER_OK bit
    // ------------------------------------------------------------------------
    virtual task set_driver_ok();
        bit [7:0] status;
        transport.read_device_status(status);
        status = status | DEV_STATUS_DRIVER_OK;
        transport.write_device_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver_ok: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_failed -- OR current status with FAILED bit
    // ------------------------------------------------------------------------
    virtual task set_failed();
        bit [7:0] status;
        transport.read_device_status(status);
        status = status | DEV_STATUS_FAILED;
        transport.write_device_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_failed: status=0x%02h", status), UVM_HIGH)
    endtask

    // ========================================================================
    // Feature Negotiation
    // ========================================================================

    // ------------------------------------------------------------------------
    // read_device_features -- Read device-offered feature bits
    // ------------------------------------------------------------------------
    virtual task read_device_features(ref bit [63:0] features);
        transport.read_device_features(features);
    endtask

    // ------------------------------------------------------------------------
    // write_driver_features -- Write driver-selected feature bits
    // ------------------------------------------------------------------------
    virtual task write_driver_features(bit [63:0] features);
        transport.write_driver_features(features);
    endtask

    // ------------------------------------------------------------------------
    // negotiate_features -- AND device features with driver caps, write result
    // ------------------------------------------------------------------------
    virtual task negotiate_features(bit [63:0] driver_caps, ref bit [63:0] result);
        transport.negotiate_features(driver_caps, result);
        negotiated_features = result;
        `uvm_info("ATOMIC_OPS",
            $sformatf("negotiate_features: result=0x%016h", result), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Queue Management
    // ========================================================================

    // ------------------------------------------------------------------------
    // setup_queue -- Full queue setup: create, alloc rings, map IOMMU, enable
    // ------------------------------------------------------------------------
    virtual task setup_queue(
        int unsigned       queue_id,
        int unsigned       queue_size,
        virtqueue_type_e   vq_type
    );
        virtqueue_base     vq;
        int unsigned       max_size;
        int unsigned       eff_size;
        int unsigned       desc_size;
        int unsigned       avail_size;
        int unsigned       used_size;
        bit [63:0]         desc_iova;
        bit [63:0]         avail_iova;
        bit [63:0]         used_iova;
        int unsigned       msix_vector;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d size=%0d type=%s",
                      queue_id, queue_size, vq_type.name()), UVM_MEDIUM)

        // 1. Select queue on transport
        transport.select_queue(queue_id);

        // 2. Read device-advertised max queue size
        transport.read_queue_num_max(max_size);

        // 3. Determine effective size
        if (queue_size == 0)
            eff_size = max_size;
        else if (queue_size > max_size) begin
            `uvm_warning("ATOMIC_OPS",
                $sformatf("setup_queue: requested size %0d exceeds max %0d, using max",
                          queue_size, max_size))
            eff_size = max_size;
        end else
            eff_size = queue_size;

        // 4. Create queue via manager
        vq = vq_mgr.create_queue(queue_id, eff_size, vq_type);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("setup_queue: failed to create queue %0d", queue_id))
            return;
        end

        // 5. Allocate ring memory
        vq.alloc_rings();

        // 6. Compute ring region sizes for IOMMU mapping
        case (vq_type)
            VQ_SPLIT: begin
                desc_size  = 16 * eff_size;
                avail_size = 6 + 2 * eff_size;
                used_size  = 6 + 8 * eff_size;
            end
            VQ_PACKED: begin
                desc_size  = 16 * eff_size;
                avail_size = 8;  // event suppression struct
                used_size  = 8;  // event suppression struct
            end
            default: begin
                desc_size  = 16 * eff_size;
                avail_size = 6 + 2 * eff_size;
                used_size  = 6 + 8 * eff_size;
            end
        endcase

        // 7. Map ring addresses through IOMMU
        desc_iova  = iommu.map(transport.bdf, vq.desc_table_addr,  desc_size,  DMA_BIDIRECTIONAL);
        avail_iova = iommu.map(transport.bdf, vq.driver_ring_addr, avail_size, DMA_BIDIRECTIONAL);
        used_iova  = iommu.map(transport.bdf, vq.device_ring_addr, used_size,  DMA_BIDIRECTIONAL);

        // Track ring IOVAs for cleanup
        ring_iovas[queue_id] = '{desc_iova, avail_iova, used_iova};

        // 8. Determine MSI-X vector for this queue
        if (transport.notify_mgr.queue_vectors.size() > queue_id)
            msix_vector = transport.notify_mgr.queue_vectors[queue_id];
        else
            msix_vector = 0;

        // 9. Setup queue on transport (writes addresses, size, enables)
        transport.setup_single_queue(queue_id, eff_size,
                                     desc_iova, avail_iova, used_iova,
                                     msix_vector);

        // 10. Mark queue as enabled
        vq.state = VQ_ENABLED;
        vq.queue_enable = 1;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d complete, desc_iova=0x%016h avail_iova=0x%016h used_iova=0x%016h",
                      queue_id, desc_iova, avail_iova, used_iova), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // teardown_queue -- Disable, detach, unmap, and destroy a queue
    // ------------------------------------------------------------------------
    virtual task teardown_queue(int unsigned queue_id);
        virtqueue_base vq;
        uvm_object tokens[$];

        `uvm_info("ATOMIC_OPS",
            $sformatf("teardown_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // 1. Disable queue on transport
        transport.select_queue(queue_id);
        transport.write_queue_enable(0);

        // 2. Detach all unused buffers
        vq = vq_mgr.get_queue(queue_id);
        if (vq != null)
            vq.detach_all_unused(tokens);

        // 3. Unmap ring IOVAs
        if (ring_iovas.exists(queue_id)) begin
            foreach (ring_iovas[queue_id][i]) begin
                iommu.unmap(transport.bdf, ring_iovas[queue_id][i]);
            end
            ring_iovas.delete(queue_id);
        end

        // 4. Clean up TX/RX IOVA tracking
        if (tx_iova_map.exists(queue_id))
            tx_iova_map.delete(queue_id);
        if (rx_iova_map.exists(queue_id))
            rx_iova_map.delete(queue_id);

        // 5. Destroy queue
        vq_mgr.destroy_queue(queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("teardown_queue: queue_id=%0d complete, detached %0d tokens",
                      queue_id, tokens.size()), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // reset_queue -- Per-queue reset using virtio 1.2 queue reset mechanism
    // ------------------------------------------------------------------------
    virtual task reset_queue(int unsigned queue_id);
        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // Write Q_RESET and poll until complete
        transport.write_queue_reset(queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d reset complete", queue_id), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // setup_all_queues -- Create all queue pairs + control queue
    // ------------------------------------------------------------------------
    virtual task setup_all_queues(
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size
    );
        int unsigned ctrl_qid;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: num_pairs=%0d type=%s size=%0d",
                      num_pairs, vq_type.name(), queue_size), UVM_MEDIUM)

        // Setup receive and transmit queue pairs
        for (int unsigned i = 0; i < num_pairs; i++) begin
            setup_queue(i * 2,     queue_size, vq_type);  // receiveq_i
            setup_queue(i * 2 + 1, queue_size, vq_type);  // transmitq_i
        end

        // Setup control queue if CTRL_VQ negotiated
        if (negotiated_features[VIRTIO_NET_F_CTRL_VQ]) begin
            ctrl_qid = num_pairs * 2;
            setup_queue(ctrl_qid, queue_size, vq_type);
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: complete, total queues=%0d",
                      vq_mgr.get_queue_count()), UVM_MEDIUM)
    endtask

    // ========================================================================
    // TX Data Path
    // ========================================================================

    // ------------------------------------------------------------------------
    // tx_submit -- Submit a packet for transmission
    //
    // Steps:
    //   1. Pack virtio_net_hdr to bytes
    //   2. Get raw packet data via do_pack
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
        int unsigned     pkt_size;
        bit [63:0]       hdr_gpa;
        bit [63:0]       pkt_gpa;
        bit [63:0]       hdr_iova;
        bit [63:0]       pkt_iova;
        virtio_sg_list   sgs[2];
        virtio_sg_entry  hdr_entry;
        virtio_sg_entry  pkt_entry;
        int unsigned     result;
        byte             hdr_data[];
        byte             pkt_data[];

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d", queue_id), UVM_HIGH)

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: queue %0d not found", queue_id))
            return;
        end

        // 1. Pack net_hdr to bytes
        virtio_net_hdr_util::pack_hdr(net_hdr, negotiated_features, hdr_bytes);
        hdr_size = hdr_bytes.size();

        // 2. Get raw packet data from pkt via do_pack
        begin
            uvm_packer packer;
            packer = new();
            pkt.do_pack(packer);
            packer.get_bytes(pkt_bytes);
        end
        pkt_size = pkt_bytes.size();

        // If packet has no data from do_pack, use minimum Ethernet frame size
        if (pkt_size == 0)
            pkt_size = 64;

        // 3. Allocate host_mem for hdr + data buffers
        hdr_gpa = mem.alloc(hdr_size, .align(1));
        pkt_gpa = mem.alloc(pkt_size, .align(1));

        if (hdr_gpa == '1 || pkt_gpa == '1) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: host_mem alloc failed for queue %0d", queue_id))
            return;
        end

        // 4. Write hdr and data to host_mem
        hdr_data = new[hdr_size];
        foreach (hdr_bytes[i]) hdr_data[i] = hdr_bytes[i];
        mem.write_mem(hdr_gpa, hdr_data);

        if (pkt_bytes.size() > 0) begin
            pkt_data = new[pkt_size];
            foreach (pkt_bytes[i]) pkt_data[i] = pkt_bytes[i];
            mem.write_mem(pkt_gpa, pkt_data);
        end

        // 5. Map through IOMMU (DMA_TO_DEVICE -- device reads these buffers)
        hdr_iova = iommu.map(transport.bdf, hdr_gpa, hdr_size, DMA_TO_DEVICE);
        pkt_iova = iommu.map(transport.bdf, pkt_gpa, pkt_size, DMA_TO_DEVICE);

        // Track IOVAs for cleanup
        if (!tx_iova_map.exists(queue_id))
            tx_iova_map[queue_id] = {};
        tx_iova_map[queue_id].push_back(hdr_iova);
        tx_iova_map[queue_id].push_back(pkt_iova);

        // 6. Build scatter-gather lists: [hdr_sg(out)] [data_sg(out)]
        hdr_entry.addr = hdr_iova;
        hdr_entry.len  = hdr_size;
        sgs[0].entries.push_back(hdr_entry);

        pkt_entry.addr = pkt_iova;
        pkt_entry.len  = pkt_size;
        sgs[1].entries.push_back(pkt_entry);

        // 7. Add buffers to virtqueue (n_out=2, n_in=0)
        result = vq.add_buf(sgs, 2, 0, pkt, use_indirect);
        desc_id = result;

        // 8. Kick if device needs notification
        if (vq.needs_notification()) begin
            transport.kick(queue_id, vq.total_add_buf_ops, 0);
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d desc_id=%0d hdr_iova=0x%016h pkt_iova=0x%016h",
                      queue_id, desc_id, hdr_iova, pkt_iova), UVM_HIGH)
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

        // Clean up IOMMU mappings for completed TX buffers
        // (Each TX uses 2 IOVAs: hdr + data)
        if (tx_iova_map.exists(queue_id)) begin
            int unsigned iovas_to_free = count * 2;
            for (int unsigned i = 0; i < iovas_to_free && tx_iova_map[queue_id].size() > 0; i++) begin
                bit [63:0] iova = tx_iova_map[queue_id].pop_front();
                iommu.unmap(transport.bdf, iova);
            end
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
    virtual task rx_refill(
        int unsigned     queue_id,
        int unsigned     num_bufs
    );
        virtqueue_base   vq;
        int unsigned     buf_size;
        int unsigned     hdr_size;
        int unsigned     filled = 0;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        // Determine buffer size based on header size + typical MTU
        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        // Use reasonable default: header + 1514 (standard Ethernet MTU)
        buf_size = hdr_size + 1514;

        while (filled < num_bufs && vq.get_free_count() > 0) begin
            bit [63:0]       buf_gpa;
            bit [63:0]       buf_iova;
            virtio_sg_list   sgs[1];
            virtio_sg_entry  buf_entry;
            int unsigned     result;

            // Allocate RX buffer from host memory
            buf_gpa = mem.alloc(buf_size, .align(1));
            if (buf_gpa == '1) begin
                `uvm_warning("ATOMIC_OPS",
                    $sformatf("rx_refill: host_mem alloc failed at buffer %0d", filled))
                break;
            end

            // Zero-fill the buffer
            mem.mem_set(buf_gpa, 0, buf_size);

            // Map through IOMMU (DMA_FROM_DEVICE -- device writes to this buffer)
            buf_iova = iommu.map(transport.bdf, buf_gpa, buf_size, DMA_FROM_DEVICE);

            // Track IOVA for cleanup
            if (!rx_iova_map.exists(queue_id))
                rx_iova_map[queue_id] = {};
            rx_iova_map[queue_id].push_back(buf_iova);

            // Build sg: single device-writable buffer (n_out=0, n_in=1)
            buf_entry.addr = buf_iova;
            buf_entry.len  = buf_size;
            sgs[0].entries.push_back(buf_entry);

            result = vq.add_buf(sgs, 0, 1, null, 0);
            filled++;
        end

        // Kick if device needs notification
        if (filled > 0 && vq.needs_notification()) begin
            transport.kick(queue_id, vq.total_add_buf_ops, 0);
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("rx_refill: queue_id=%0d filled=%0d/%0d", queue_id, filled, num_bufs),
            UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // rx_receive -- Poll used ring for received packets
    // ------------------------------------------------------------------------
    virtual task rx_receive(
        int unsigned     queue_id,
        ref uvm_object   received_pkts[$],
        int unsigned     max_budget
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count = 0;
        int unsigned     hdr_size;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        while (count < max_budget) begin
            if (vq.poll_used(token, len)) begin
                // The used ring len tells us the actual bytes written by the
                // device. In a full implementation we would:
                //   1. Read buffer from host_mem
                //   2. Unpack virtio_net_hdr from buffer head
                //   3. Parse remaining data as packet
                //   4. Handle MRG_RXBUF: if num_buffers > 1, consume more entries
                // For the VIP we track the completion event.

                if (token != null)
                    received_pkts.push_back(token);

                count++;
            end else begin
                break;
            end
        end

        // Clean up IOMMU mappings for consumed RX buffers
        if (rx_iova_map.exists(queue_id)) begin
            for (int unsigned i = 0; i < count && rx_iova_map[queue_id].size() > 0; i++) begin
                bit [63:0] iova = rx_iova_map[queue_id].pop_front();
                iommu.unmap(transport.bdf, iova);
            end
        end

        if (count > 0)
            `uvm_info("ATOMIC_OPS",
                $sformatf("rx_receive: queue_id=%0d received=%0d", queue_id, count), UVM_HIGH)
    endtask

    // ========================================================================
    // Control VQ
    // ========================================================================

    // ------------------------------------------------------------------------
    // ctrl_send -- Send a control command and wait for ACK
    //
    // Steps:
    //   1. Build ctrl header: {class[7:0], cmd[7:0]}
    //   2. Build data buffer
    //   3. Build ack buffer (1 byte, device-writable)
    //   4. sgs: [hdr_sg(out)] [data_sg(out)] [ack_sg(in)]
    //   5. add_buf to control queue
    //   6. Kick control queue
    //   7. Poll used ring until ack buffer filled
    //   8. Read ack status from host_mem
    // ------------------------------------------------------------------------
    virtual task ctrl_send(
        virtio_ctrl_class_e  ctrl_class,
        bit [7:0]            cmd,
        byte unsigned        data[],
        ref virtio_ctrl_ack_e ack
    );
        virtqueue_base   ctrl_vq;
        int unsigned     ctrl_qid;
        byte unsigned    hdr_buf[2];
        bit [63:0]       hdr_gpa, data_gpa, ack_gpa;
        bit [63:0]       hdr_iova, data_iova, ack_iova;
        virtio_sg_list   sgs[3];
        virtio_sg_entry  entry;
        int unsigned     result;
        uvm_object       token;
        int unsigned     used_len;
        byte             ack_readback[];
        byte             write_buf[];
        bit              got_used;
        int unsigned     data_alloc_size;

        `uvm_info("ATOMIC_OPS",
            $sformatf("ctrl_send: class=%s cmd=0x%02h data_len=%0d",
                      ctrl_class.name(), cmd, data.size()), UVM_MEDIUM)

        // Find control queue (highest queue ID among managed queues)
        ctrl_qid = 0;
        begin
            int unsigned max_qid = 0;
            foreach (ring_iovas[qid]) begin
                if (qid > max_qid) max_qid = qid;
            end
            ctrl_qid = max_qid;
        end

        ctrl_vq = vq_mgr.get_queue(ctrl_qid);
        if (ctrl_vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("ctrl_send: control queue %0d not found", ctrl_qid))
            ack = VIRTIO_NET_CTRL_ACK_ERR;
            return;
        end

        // 1. Build ctrl header: {class[7:0], cmd[7:0]}
        hdr_buf[0] = ctrl_class;
        hdr_buf[1] = cmd;

        // 2. Allocate host_mem for hdr, data, and ack
        hdr_gpa = mem.alloc(2, .align(1));
        ack_gpa = mem.alloc(1, .align(1));

        write_buf = new[2];
        write_buf[0] = hdr_buf[0];
        write_buf[1] = hdr_buf[1];
        mem.write_mem(hdr_gpa, write_buf);

        data_alloc_size = (data.size() > 0) ? data.size() : 1;
        data_gpa = mem.alloc(data_alloc_size, .align(1));

        if (data.size() > 0) begin
            write_buf = new[data.size()];
            foreach (data[i]) write_buf[i] = data[i];
            mem.write_mem(data_gpa, write_buf);
        end

        // Initialize ack to 0xFF (invalid)
        write_buf = new[1];
        write_buf[0] = 8'hFF;
        mem.write_mem(ack_gpa, write_buf);

        // 3. Map through IOMMU
        hdr_iova  = iommu.map(transport.bdf, hdr_gpa,  2, DMA_TO_DEVICE);
        data_iova = iommu.map(transport.bdf, data_gpa, data_alloc_size, DMA_TO_DEVICE);
        ack_iova  = iommu.map(transport.bdf, ack_gpa,  1, DMA_FROM_DEVICE);

        // 4. Build scatter-gather: [hdr(out)] [data(out)] [ack(in)]
        entry.addr = hdr_iova;
        entry.len  = 2;
        sgs[0].entries.push_back(entry);

        entry.addr = data_iova;
        entry.len  = data_alloc_size;
        sgs[1].entries.push_back(entry);

        entry.addr = ack_iova;
        entry.len  = 1;
        sgs[2].entries.push_back(entry);

        // 5. Add to control queue (n_out=2, n_in=1)
        result = ctrl_vq.add_buf(sgs, 2, 1, null, 0);

        // 6. Kick control queue
        if (ctrl_vq.needs_notification())
            transport.kick(ctrl_qid, ctrl_vq.total_add_buf_ops, 0);

        // 7. Poll used ring until ack buffer is filled
        got_used = 0;
        begin
            int unsigned poll_count = 0;
            int unsigned max_polls;
            int unsigned interval = wait_pol.default_poll_interval_ns;

            max_polls = wait_pol.effective_timeout(wait_pol.default_timeout_ns) /
                        ((interval > 0) ? interval : 1) + 1;
            if (max_polls > wait_pol.max_poll_attempts)
                max_polls = wait_pol.max_poll_attempts;

            while (poll_count < max_polls) begin
                if (ctrl_vq.poll_used(token, used_len)) begin
                    got_used = 1;
                    break;
                end
                #(interval * 1ns);
                poll_count++;
            end
        end

        if (!got_used) begin
            `uvm_error("ATOMIC_OPS", "ctrl_send: timeout waiting for control VQ completion")
            ack = VIRTIO_NET_CTRL_ACK_ERR;
        end else begin
            // 8. Read ack status from host_mem
            mem.read_mem(ack_gpa, 1, ack_readback);
            if (ack_readback[0] == VIRTIO_NET_OK)
                ack = VIRTIO_NET_CTRL_ACK_OK;
            else
                ack = VIRTIO_NET_CTRL_ACK_ERR;
        end

        // Cleanup IOMMU mappings
        iommu.unmap(transport.bdf, hdr_iova);
        iommu.unmap(transport.bdf, data_iova);
        iommu.unmap(transport.bdf, ack_iova);

        // Free host memory
        mem.free(hdr_gpa);
        mem.free(data_gpa);
        mem.free(ack_gpa);

        `uvm_info("ATOMIC_OPS",
            $sformatf("ctrl_send: class=%s cmd=0x%02h ack=%s",
                      ctrl_class.name(), cmd, ack.name()), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Control VQ Convenience Wrappers
    // ========================================================================

    // ------------------------------------------------------------------------
    // ctrl_set_mac -- Set device MAC address via CTRL_MAC_ADDR_SET
    // ------------------------------------------------------------------------
    virtual task ctrl_set_mac(bit [47:0] mac, ref bit success);
        byte unsigned data[6];
        virtio_ctrl_ack_e ack;

        data[0] = mac[47:40];
        data[1] = mac[39:32];
        data[2] = mac[31:24];
        data[3] = mac[23:16];
        data[4] = mac[15:8];
        data[5] = mac[7:0];

        ctrl_send(VIRTIO_NET_CTRL_CLS_MAC, VIRTIO_NET_CTRL_MAC_ADDR_SET, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_promisc -- Enable/disable promiscuous mode
    // ------------------------------------------------------------------------
    virtual task ctrl_set_promisc(bit enable, ref bit success);
        byte unsigned data[1];
        virtio_ctrl_ack_e ack;

        data[0] = enable;
        ctrl_send(VIRTIO_NET_CTRL_CLS_RX, VIRTIO_NET_CTRL_RX_PROMISC, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_allmulti -- Enable/disable all-multicast mode
    // ------------------------------------------------------------------------
    virtual task ctrl_set_allmulti(bit enable, ref bit success);
        byte unsigned data[1];
        virtio_ctrl_ack_e ack;

        data[0] = enable;
        ctrl_send(VIRTIO_NET_CTRL_CLS_RX, VIRTIO_NET_CTRL_RX_ALLMULTI, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_mac_table -- Set unicast/multicast MAC filter tables
    // Format: {uni_count[4], uni_macs[6*n], multi_count[4], multi_macs[6*m]}
    // ------------------------------------------------------------------------
    virtual task ctrl_set_mac_table(
        bit [47:0] unicast_macs[$],
        bit [47:0] multicast_macs[$],
        ref bit success
    );
        byte unsigned data[];
        virtio_ctrl_ack_e ack;
        int unsigned offset;
        int unsigned total_size;
        int unsigned uc_count;
        int unsigned mc_count;

        uc_count = unicast_macs.size();
        mc_count = multicast_macs.size();
        total_size = 4 + uc_count * 6 + 4 + mc_count * 6;
        data = new[total_size];

        // Unicast count (32-bit LE)
        offset = 0;
        data[offset]   = uc_count[7:0];
        data[offset+1] = uc_count[15:8];
        data[offset+2] = uc_count[23:16];
        data[offset+3] = uc_count[31:24];
        offset += 4;

        // Unicast MACs
        foreach (unicast_macs[i]) begin
            data[offset]   = unicast_macs[i][47:40];
            data[offset+1] = unicast_macs[i][39:32];
            data[offset+2] = unicast_macs[i][31:24];
            data[offset+3] = unicast_macs[i][23:16];
            data[offset+4] = unicast_macs[i][15:8];
            data[offset+5] = unicast_macs[i][7:0];
            offset += 6;
        end

        // Multicast count (32-bit LE)
        data[offset]   = mc_count[7:0];
        data[offset+1] = mc_count[15:8];
        data[offset+2] = mc_count[23:16];
        data[offset+3] = mc_count[31:24];
        offset += 4;

        // Multicast MACs
        foreach (multicast_macs[i]) begin
            data[offset]   = multicast_macs[i][47:40];
            data[offset+1] = multicast_macs[i][39:32];
            data[offset+2] = multicast_macs[i][31:24];
            data[offset+3] = multicast_macs[i][23:16];
            data[offset+4] = multicast_macs[i][15:8];
            data[offset+5] = multicast_macs[i][7:0];
            offset += 6;
        end

        ctrl_send(VIRTIO_NET_CTRL_CLS_MAC, VIRTIO_NET_CTRL_MAC_TABLE_SET, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_vlan_filter -- Add or remove a VLAN filter entry
    // ------------------------------------------------------------------------
    virtual task ctrl_set_vlan_filter(bit [11:0] vlan_id, bit add, ref bit success);
        byte unsigned data[2];
        virtio_ctrl_ack_e ack;
        bit [7:0] cmd;

        data[0] = vlan_id[7:0];
        data[1] = {4'h0, vlan_id[11:8]};

        cmd = add ? VIRTIO_NET_CTRL_VLAN_ADD : VIRTIO_NET_CTRL_VLAN_DEL;
        ctrl_send(VIRTIO_NET_CTRL_CLS_VLAN, cmd, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_mq_pairs -- Set the number of active queue pairs (MQ)
    // ------------------------------------------------------------------------
    virtual task ctrl_set_mq_pairs(int unsigned num_pairs, ref bit success);
        byte unsigned data[2];
        virtio_ctrl_ack_e ack;

        data[0] = num_pairs[7:0];
        data[1] = num_pairs[15:8];

        ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_rss -- Configure RSS via control VQ
    // ------------------------------------------------------------------------
    virtual task ctrl_set_rss(virtio_rss_config_t rss_cfg, ref bit success);
        byte unsigned data[];
        virtio_ctrl_ack_e ack;
        int unsigned offset;
        int unsigned total_size;

        // Format: hash_types(4) + indirection_table_mask(2) + unclassified_queue(2) +
        //         indirection_table(2*N) + max_tx_vq(2) + hash_key_length(1) + hash_key(K)
        total_size = 4 + 2 + 2 + rss_cfg.indirection_table.size() * 2 + 2 + 1 +
                     rss_cfg.hash_key.size();
        data = new[total_size];
        offset = 0;

        // hash_types (32-bit LE)
        data[offset]   = rss_cfg.hash_types[7:0];
        data[offset+1] = rss_cfg.hash_types[15:8];
        data[offset+2] = rss_cfg.hash_types[23:16];
        data[offset+3] = rss_cfg.hash_types[31:24];
        offset += 4;

        // indirection_table_mask (16-bit LE)
        begin
            int unsigned tbl_mask = rss_cfg.indirection_table.size() - 1;
            data[offset]   = tbl_mask[7:0];
            data[offset+1] = tbl_mask[15:8];
        end
        offset += 2;

        // unclassified_queue (16-bit LE) -- default queue 0
        data[offset]   = 8'h00;
        data[offset+1] = 8'h00;
        offset += 2;

        // indirection_table entries (16-bit LE each)
        foreach (rss_cfg.indirection_table[i]) begin
            data[offset]   = rss_cfg.indirection_table[i][7:0];
            data[offset+1] = rss_cfg.indirection_table[i][15:8];
            offset += 2;
        end

        // max_tx_vq (16-bit LE) -- 0 = all
        data[offset]   = 8'h00;
        data[offset+1] = 8'h00;
        offset += 2;

        // hash_key_length (1 byte)
        data[offset] = rss_cfg.hash_key_size[7:0];
        offset += 1;

        // hash_key
        foreach (rss_cfg.hash_key[i]) begin
            data[offset] = rss_cfg.hash_key[i];
            offset++;
        end

        ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, 8'h01, data, ack);  // RSS cmd = 0x01
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_announce_ack -- Acknowledge a gratuitous ARP/ND announcement
    // ------------------------------------------------------------------------
    virtual task ctrl_announce_ack(ref bit success);
        byte unsigned data[];
        virtio_ctrl_ack_e ack;

        ctrl_send(VIRTIO_NET_CTRL_CLS_ANNOUNCE, VIRTIO_NET_CTRL_ANNOUNCE_ACK, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ========================================================================
    // Interrupt Handling
    // ========================================================================

    // ------------------------------------------------------------------------
    // handle_interrupt -- Dispatch an interrupt by MSI-X vector
    // ------------------------------------------------------------------------
    virtual task handle_interrupt(int unsigned vector);
        transport.notify_mgr.on_interrupt_received(vector);
    endtask

    // ------------------------------------------------------------------------
    // napi_poll -- NAPI-style polling loop for a queue
    //
    // Enters polling mode, drains up to budget completions, then re-enables
    // interrupts if budget was not exhausted.
    // ------------------------------------------------------------------------
    virtual task napi_poll(int unsigned queue_id, int unsigned budget, ref int unsigned work_done);
        virtqueue_base vq;
        uvm_object     token;
        int unsigned   len;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            work_done = 0;
            return;
        end

        // Enter polling mode (disable interrupts for this queue)
        transport.notify_mgr.enter_polling_mode(queue_id);
        vq.disable_cb();

        work_done = 0;
        while (work_done < budget) begin
            if (vq.poll_used(token, len)) begin
                work_done++;
            end else begin
                break;
            end
        end

        // If budget not exhausted, exit polling mode and re-enable interrupts
        if (work_done < budget) begin
            vq.enable_cb();
            transport.notify_mgr.exit_polling_mode(queue_id);
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("napi_poll: queue_id=%0d work_done=%0d/%0d",
                      queue_id, work_done, budget), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // setup_msix -- Configure MSI-X vectors for all queues
    // ------------------------------------------------------------------------
    virtual task setup_msix(int unsigned num_queues);
        interrupt_mode_e actual_mode;

        if (transport.cap_mgr.has_msix()) begin
            transport.notify_mgr.setup_msix(
                transport.cap_mgr.get_msix_table_size(),
                transport.cap_mgr.msix_table_bir,
                transport.cap_mgr.msix_table_offset
            );
            transport.notify_mgr.allocate_irq_vectors(num_queues, actual_mode);

            // Bind config change vector
            transport.write_config_msix_vector(transport.notify_mgr.config_vector);

            // Bind per-queue vectors
            for (int unsigned q = 0; q < num_queues; q++) begin
                transport.write_queue_msix_vector(q, transport.notify_mgr.queue_vectors[q]);
            end

            // Unmask all vectors
            transport.notify_mgr.unmask_all();
        end else begin
            transport.notify_mgr.irq_mode = IRQ_INTX;
            transport.notify_mgr.intx_enabled = 1;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_msix: num_queues=%0d mode=%s",
                      num_queues, transport.notify_mgr.irq_mode.name()), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // teardown_msix -- Mask and release all MSI-X vectors
    // ------------------------------------------------------------------------
    virtual task teardown_msix();
        transport.notify_mgr.mask_all();
        `uvm_info("ATOMIC_OPS", "teardown_msix: all vectors masked", UVM_MEDIUM)
    endtask

endclass : virtio_atomic_ops

`endif // VIRTIO_ATOMIC_OPS_SV
