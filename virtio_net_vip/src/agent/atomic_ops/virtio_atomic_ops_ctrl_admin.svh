    // 本文件是 virtio_atomic_ops 类体的一部分（Admin VQ 与 control VQ），只由
    // agent/virtio_atomic_ops.sv 在类定义内部 `include；不得单独编译或在类外包含。

    // ========================================================================
    // Control VQ
    // ========================================================================

    // ------------------------------------------------------------------------
    // admin_vq_submit -- Submit one PF Admin-VQ request and consume response
    //
    // The PF manager owns feature/lease/target validation.  This helper owns
    // only the DMA, descriptor, notification, completion and cleanup
    // lifecycle of a validated, independently configured Admin VQ.
    // ------------------------------------------------------------------------
    virtual task admin_vq_submit(
        virtio_admin_vq_context admin_context,
        byte unsigned           cmd_data[],
        ref byte unsigned       result[],
        ref bit                 ok,
        input bit               lock_already_held = 0
    );
        virtio_dma_buffer_set dma_set;
        int              request_idx;
        int              response_idx;
        bit              submitted;
        bit              completion_seen;
        bit              reset_required;
        bit              reset_complete;
        int unsigned     desc_id;
        int unsigned     used_len;
        int unsigned     max_polls;
        int unsigned     poll_count;
        int unsigned     poll_interval;
        int unsigned     effective_timeout;
        int unsigned     response_len;
        longint unsigned poll_quotient;
        uvm_object       completed_token;
        uvm_object       detached_tokens[$];
        virtio_sg_list   sgs[];
        virtio_sg_entry  entry;
        byte             write_buf[];
        byte             response_buf[];

        ok = 0;
        result = new[0];
        submitted = 0;
        completion_seen = 0;
        reset_required = 0;
        reset_complete = 0;
        dma_set = new("admin_vq_dma");

        if (admin_context == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: null Admin VQ context")
            return;
        end
        if (admin_context.submit_lock == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ context has no submission lock")
            return;
        end

        if (!lock_already_held)
            admin_context.submit_lock.get(1);
        begin : admin_vq_submit_locked
        do begin
        // The PF manager validates before calling this helper.  Repeat the
        // context checks while holding the shared-VQ lock: a prior command
        // may have performed recovery while this caller waited for ownership.
        if ((admin_context.vq == null) ||
            (admin_context.transport == null) || (admin_context.mem == null) ||
            (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
            (admin_context.response_capacity == 0) || !admin_context.configured ||
            !admin_context.special_vq_lease_valid || admin_context.special_vq_lease.frozen ||
            !admin_context.negotiated_features[VIRTIO_F_ADMIN_VQ]) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: incomplete Admin VQ context")
            break;
        end
        // This public helper may be called without virtio_pf_manager.  Once
        // it owns the submission lock, confirm that descriptors, DMA, and
        // notification still address one VQ/requester/memory/IOMMU binding.
        // Reject before allocation or any queue/device-visible side effect.
        if ((admin_context.queue_id != admin_context.vq.queue_id) ||
            (admin_context.vq.host_id !=
                admin_context.transport.iommu_host_id()) ||
            (admin_context.vq.bdf != admin_context.transport.bdf) ||
            (admin_context.vq.mem != admin_context.mem) ||
            (admin_context.vq.iommu != admin_context.iommu)) begin
            `uvm_error("ATOMIC_OPS",
                "admin_vq_submit: Admin VQ binding is inconsistent")
            break;
        end
        if (admin_context.full_reset_owner == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ has no PF lifecycle reset owner")
            break;
        end
        if (admin_context.recovery_required || admin_context.dma_quarantined) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ requires verified recovery")
            break;
        end
        if (cmd_data.size() == 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: empty Admin VQ request")
            break;
        end

        dma_set.bind_domain(admin_context.mem, admin_context.iommu,
                            get_iommu_host_id(admin_context.transport),
                            admin_context.transport.bdf);
        request_idx = dma_set.alloc(cmd_data.size());
        if (request_idx < 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: request allocation failed")
            break;
        end
        response_idx = dma_set.alloc(admin_context.response_capacity);
        if (response_idx < 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: response allocation failed")
            break;
        end

        write_buf = new[cmd_data.size()];
        foreach (cmd_data[index])
            write_buf[index] = cmd_data[index];
        dma_set.write(request_idx, write_buf);
        dma_set.fill(response_idx, 8'hFF);

        if (!dma_set.map(request_idx, DMA_TO_DEVICE)) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: request DMA map failed")
            break;
        end
        if (!dma_set.map(response_idx, DMA_FROM_DEVICE)) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: response DMA map failed")
            break;
        end

        sgs = new[2];
        entry.addr = dma_set.get_iova(request_idx);
        entry.len = cmd_data.size();
        entry.is_indirect = 0;
        sgs[0].entries.push_back(entry);
        entry.addr = dma_set.get_iova(response_idx);
        entry.len = admin_context.response_capacity;
        entry.is_indirect = 0;
        sgs[1].entries.push_back(entry);

        desc_id = admin_context.vq.add_buf(sgs, 1, 1, null, 0);
        if (desc_id == '1) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "admin_vq_submit: queue %0d rejected Admin VQ descriptor chain",
                admin_context.queue_id))
            break;
        end

        submitted = 1;
        kick_with_fault(admin_context.vq, admin_context.queue_id,
                        admin_context.transport);

        // Both timeout and interval derive from the shared wait policy;
        // there is no operation-specific arbitrary delay here.
        effective_timeout = admin_context.wait_pol.effective_timeout(
            admin_context.wait_pol.default_timeout_ns
        );
        poll_interval = admin_context.wait_pol.default_poll_interval_ns;
        if (poll_interval == 0)
            poll_interval = 1;
        // Cap the widened quotient before adding one.  A saturated
        // UINT_MAX timeout with interval one must not wrap its poll count
        // to zero.
        poll_quotient = effective_timeout / poll_interval;
        if (poll_quotient >= admin_context.wait_pol.max_poll_attempts)
            max_polls = admin_context.wait_pol.max_poll_attempts;
        else
            max_polls = poll_quotient + 1;
        poll_count = 0;

        while (poll_count < max_polls) begin
            if (admin_context.vq.poll_used(completed_token, used_len)) begin
                completion_seen = 1;
                break;
            end
            poll_count++;
            if (poll_count < max_polls)
                #(poll_interval * 1ns);
        end

        if (!completion_seen) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "admin_vq_submit: timeout waiting for Admin VQ %0d completion after %0dns",
                admin_context.queue_id, effective_timeout))
            reset_required = 1;
        end else if ((used_len == 0) || (used_len > admin_context.response_capacity)) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "admin_vq_submit: invalid Admin VQ response length %0d (capacity=%0d)",
                used_len, admin_context.response_capacity))
            reset_required = 1;
        end else begin
            response_len = used_len - 1;
            admin_context.mem.read_mem(dma_set.get_gpa(response_idx), used_len, response_buf);
            result = new[response_len];
            foreach (result[index])
                result[index] = response_buf[index + 1];
            if (response_buf[0] != VIRTIO_NET_OK) begin
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "admin_vq_submit: device rejected Admin VQ request with status 0x%02h",
                    response_buf[0]))
            end else begin
                ok = 1;
            end
        end
        end while (0);

        // A rejected add_buf() owns no descriptor.  For an accepted request
        // that timed out or returned malformed completion data, reset before
        // releasing its software ownership or DMA buffers: a late completion
        // must not DMA into memory we are about to free.  Q_RESET is valid
        // only when VIRTIO_F_RING_RESET was negotiated; Admin VQ alone does
        // not imply that feature, so otherwise reset the whole device.
        if (submitted && reset_required) begin
            if (admin_context.negotiated_features[VIRTIO_F_RING_RESET])
                admin_context.transport.write_queue_reset_verified(
                    admin_context.queue_id, reset_complete
                );
            else
                admin_context.full_reset_owner.reset_pf_lifecycle(reset_complete);
            admin_context.configured = 0;
            admin_context.recovery_required = 1;
            if (reset_complete) begin
                admin_context.vq.detach_all_unused(detached_tokens);
                admin_context.vq.reset_queue();
                admin_context.vq.alloc_rings();
            end else begin
                admin_context.dma_quarantined = 1;
                dma_set.quarantine_into(admin_context.quarantined_iovas,
                                        admin_context.quarantined_gpas);
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "admin_vq_submit: Admin VQ %0d reset did not complete; DMA is quarantined",
                    admin_context.queue_id))
            end
        end

        // 未隔离时（各失败路径、正常完成、已确认复位）统一释放本次缓冲；
        // 隔离后集合已为空，这里是空操作。
        dma_set.release_all();
        end : admin_vq_submit_locked
        if (!lock_already_held)
            admin_context.submit_lock.put(1);
    endtask

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
        virtio_dma_buffer_set dma_set;
        int              hdr_idx;
        int              ack_idx;
        int              data_idx;
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

        // 所有失败路径都返回 ERR；只有读到设备写回的 OK 才改为 OK。
        ack = VIRTIO_NET_CTRL_ACK_ERR;

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
            return;
        end

        // 1. Build ctrl header: {class[7:0], cmd[7:0]}
        hdr_buf[0] = ctrl_class;
        hdr_buf[1] = cmd;

        // 2. Allocate host_mem in the original hdr -> ack -> data order.  每次
        // 失败都回滚本次已分配的缓冲（尚无映射和描述符引用它们）。
        data_alloc_size = (data.size() > 0) ? data.size() : 1;
        dma_set = new("ctrl_dma");
        dma_set.bind_domain(mem, iommu, get_iommu_host_id(transport), transport.bdf);
        hdr_idx = dma_set.alloc(2);
        if (hdr_idx < 0) begin
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control header")
            return;
        end
        ack_idx = dma_set.alloc(1);
        if (ack_idx < 0) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control ack")
            return;
        end
        data_idx = dma_set.alloc(data_alloc_size);
        if (data_idx < 0) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control data")
            return;
        end

        write_buf = new[2];
        write_buf[0] = hdr_buf[0];
        write_buf[1] = hdr_buf[1];
        dma_set.write(hdr_idx, write_buf);

        if (data.size() > 0) begin
            write_buf = new[data.size()];
            foreach (data[i]) write_buf[i] = data[i];
            dma_set.write(data_idx, write_buf);
        end

        // Initialize ack to 0xFF (invalid)
        write_buf = new[1];
        write_buf[0] = 8'hFF;
        dma_set.write(ack_idx, write_buf);

        // 3. Map through IOMMU in the original hdr -> data -> ack order.  `||`
        // 短路：任一映射失败即停止后续映射，撤销已成功的映射并释放三块缓冲；
        // 描述符尚未发布，设备不可能访问这些 IOVA。
        if (!dma_set.map(hdr_idx, DMA_TO_DEVICE) ||
            !dma_set.map(data_idx, DMA_TO_DEVICE) ||
            !dma_set.map(ack_idx, DMA_FROM_DEVICE)) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", "ctrl_send: failed to map control buffers")
            return;
        end

        // 4. Build scatter-gather: [hdr(out)] [data(out)] [ack(in)]
        entry.addr = dma_set.get_iova(hdr_idx);
        entry.len  = 2;
        sgs[0].entries.push_back(entry);

        entry.addr = dma_set.get_iova(data_idx);
        entry.len  = data_alloc_size;
        sgs[1].entries.push_back(entry);

        entry.addr = dma_set.get_iova(ack_idx);
        entry.len  = 1;
        sgs[2].entries.push_back(entry);

        // 5. Add to control queue (n_out=2, n_in=1); a rejected chain owns
        //    no descriptor, so roll back without notifying.
        result = ctrl_vq.add_buf(sgs, 2, 1, null, 0);
        if (result == '1) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", $sformatf(
                "ctrl_send: control queue %0d rejected descriptor chain", ctrl_qid))
            return;
        end

        // 6. Kick control queue
        if (ctrl_vq.needs_notification())
            kick_with_fault(ctrl_vq, ctrl_qid);

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
        end else begin
            // 8. Read ack status from host_mem
            mem.read_mem(dma_set.get_gpa(ack_idx), 1, ack_readback);
            if (ack_readback[0] == VIRTIO_NET_OK)
                ack = VIRTIO_NET_CTRL_ACK_OK;
        end

        // Cleanup IOMMU mappings and host memory
        dma_set.release_all();

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
