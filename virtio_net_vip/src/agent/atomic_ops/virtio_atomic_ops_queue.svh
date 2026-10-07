    // 本文件是 virtio_atomic_ops 类体的一部分（队列建立与拆除），只由
    // agent/virtio_atomic_ops.sv 在类定义内部 `include；不得单独编译或在类外包含。

    // ========================================================================
    // Queue Management
    // ========================================================================

    // ------------------------------------------------------------------------
    // setup_queue -- Full queue setup: create, alloc rings, map IOMMU, enable
    // ------------------------------------------------------------------------
    virtual task setup_queue(
        int unsigned       queue_id,
        int unsigned       queue_size,
        virtqueue_type_e   vq_type,
        output bit          ok
    );
        virtqueue_base     vq;
        virtio_config_backend backend;
        virtio_queue_program_t qprog;
        int unsigned       max_size;
        int unsigned       eff_size;
        bit [63:0]         region_gpas[$];
        int unsigned       region_sizes[$];
        bit [63:0]         region_iovas[$];
        int unsigned       ring_bytes;
        bit                map_failed;
        bit [63:0]         desc_iova;
        bit [63:0]         avail_iova;
        bit [63:0]         used_iova;
        int unsigned       msix_vector;
        bit                configured;

        ok = 0;
        if ((transport == null) || (vq_mgr == null) || (iommu == null) ||
            (mem == null)) begin
            `uvm_error("ATOMIC_OPS", "setup_queue: incomplete queue context")
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d size=%0d type=%s",
                      queue_id, queue_size, vq_type.name()), UVM_MEDIUM)

        // 1-2. Select queue and read device-advertised max queue size
        backend = cfg_backend();
        backend.query_queue_max(queue_id, max_size);

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

        if (eff_size == 0) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: device reported zero-sized queue %0d", queue_id))
            return;
        end

        // 4. Create queue via manager
        vq = vq_mgr.create_queue(queue_id, eff_size, vq_type);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("setup_queue: failed to create queue %0d", queue_id))
            return;
        end

        // ring DMA 的 host 域必须是 transport 冻结 identity 的 host；vq_mgr.host_id
        // 接线错误时拒绝建队，不得静默按另一个 host（例如 host0）做 ring DMA。
        if (transport.pcie_id_valid && (vq.host_id != transport.iommu_host_id())) begin
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: queue_id=%0d vq host_id=%0d does not match transport DMA host %0d",
                queue_id, vq.host_id, transport.iommu_host_id()))
            return;
        end

        // 4b. 编程参数基本字段；后端可按其队列参数表配置队列对象并补全参数
        // （私有：方向、本地号、RX 容量、doorbell）。拒绝时设备未被访问。
        qprog = virtio_empty_queue_program();
        qprog.host_id    = get_iommu_host_id(transport);
        qprog.bdf        = transport.bdf;
        qprog.queue_id   = queue_id;
        qprog.queue_size = eff_size;
        qprog.vq_type    = vq_type;
        qprog.local_qid  = queue_id;
        qprog.tx_mode    = queue_id[0];
        if (!backend.prepare_queue(vq, qprog)) begin
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: config backend rejected queue_id=%0d", queue_id))
            return;
        end

        // 5. Allocate ring memory
        vq.alloc_rings();

        // 6-7. 按队列格式声明的 ring 区逐区映射（split 三区、packed 描述符环加两份
        // 4B event 结构、私有环整块 desc+CQ）。全部映射后统一判定，失败撤销已成功的
        // 映射并销毁队列；未分配出 ring（空区表）按映射失败处理。
        vq.get_ring_regions(region_gpas, region_sizes);
        map_failed = (region_gpas.size() == 0);
        foreach (region_gpas[i]) begin
            region_iovas.push_back(iommu.map_for_host(get_iommu_host_id(transport),
                transport.bdf, region_gpas[i], region_sizes[i], DMA_BIDIRECTIONAL));
            if ((region_iovas[i] == '1) || (region_iovas[i] == 0))
                map_failed = 1;
        end
        if (map_failed) begin
            foreach (region_iovas[i])
                if ((region_iovas[i] != '1) && (region_iovas[i] != 0))
                    iommu.unmap_for_host(get_iommu_host_id(transport),
                                         transport.bdf, region_iovas[i]);
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: failed to map queue_id=%0d rings", queue_id))
            return;
        end

        // Track ring IOVAs for cleanup；三个设备视角地址按区内偏移换算。
        ring_iovas[queue_id] = region_iovas;
        desc_iova  = ring_iova_of(vq.desc_table_addr, region_gpas, region_sizes, region_iovas);
        avail_iova = ring_iova_of(vq.driver_ring_addr, region_gpas, region_sizes, region_iovas);
        used_iova  = ring_iova_of(vq.device_ring_addr, region_gpas, region_sizes, region_iovas);
        ring_bytes = 0;
        foreach (region_sizes[i])
            ring_bytes += region_sizes[i];

        // 8. Determine MSI-X vector for this queue
        if (transport.notify_mgr.queue_vectors.size() > queue_id)
            msix_vector = transport.notify_mgr.queue_vectors[queue_id];
        else
            msix_vector = 0;

        // 9. 经配置后端编程并启用队列（common-config：写大小/地址/向量并置
        // Q_ENABLE）。后端拒绝时设备不得访问该队列，因此可以立即回收 ring 映射。
        qprog.desc_iova   = desc_iova;
        qprog.driver_iova = avail_iova;
        qprog.device_iova = used_iova;
        qprog.ring_bytes  = ring_bytes;
        qprog.msix_vector = msix_vector;
        backend.configure_queue(qprog, configured);
        if (configured)
            backend.enable_queue(qprog, configured);
        if (!configured) begin
            foreach (region_iovas[i])
                iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                     region_iovas[i]);
            ring_iovas.delete(queue_id);
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: config backend rejected queue_id=%0d", queue_id))
            return;
        end
        queue_programs[queue_id] = qprog;

        // 10. Mark queue as enabled
        vq.state = VQ_ENABLED;
        vq.queue_enable = 1;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d complete, desc_iova=0x%016h avail_iova=0x%016h used_iova=0x%016h",
                      queue_id, desc_iova, avail_iova, used_iova), UVM_MEDIUM)
        ok = 1;
    endtask

    // ------------------------------------------------------------------------
    // teardown_queue -- Disable, detach, unmap, and destroy a queue
    // ------------------------------------------------------------------------
    virtual task teardown_queue(int unsigned queue_id);
        virtqueue_base vq;
        uvm_object tokens[$];
        virtio_config_backend backend;
        virtio_queue_program_t qprog;
        bit stopped;

        `uvm_info("ATOMIC_OPS",
            $sformatf("teardown_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // 1. 经配置后端停用队列；后端未确认停止时保留全部 ring/DMA 所有权。
        if (queue_programs.exists(queue_id))
            qprog = queue_programs[queue_id];
        else begin
            qprog = virtio_empty_queue_program();
            qprog.host_id  = get_iommu_host_id(transport);
            qprog.bdf      = transport.bdf;
            qprog.queue_id = queue_id;
        end
        backend = cfg_backend();
        backend.disable_queue(qprog, stopped);
        if (!stopped) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "teardown_queue: config backend did not confirm queue_id=%0d stopped; retaining queue DMA",
                queue_id))
            return;
        end

        // 2. Detach all unused buffers
        vq = vq_mgr.get_queue(queue_id);
        if (vq != null)
            vq.detach_all_unused(tokens);

        // 3. Unmap ring IOVAs
        if (ring_iovas.exists(queue_id)) begin
            foreach (ring_iovas[queue_id][i]) begin
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, ring_iovas[queue_id][i]);
            end
            ring_iovas.delete(queue_id);
        end

        // 4. Retire every still-owned normal data-DMA pair before forgetting
        // the queue.  Completion paths pop the same records first, so this
        // only releases buffers that remain pending at teardown.
        if (tx_dma_map.exists(queue_id)) begin
            retire_normal_dma_records(tx_dma_map[queue_id]);
            tx_dma_map.delete(queue_id);
        end
        if (rx_dma_map.exists(queue_id)) begin
            retire_normal_dma_records(rx_dma_map[queue_id]);
            rx_dma_map.delete(queue_id);
        end

        // 5. Destroy queue
        vq_mgr.destroy_queue(queue_id);
        queue_programs.delete(queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("teardown_queue: queue_id=%0d complete, detached %0d tokens",
                      queue_id, tokens.size()), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // reset_queue -- Per-queue reset using virtio 1.2 queue reset mechanism
    // ------------------------------------------------------------------------
    virtual task reset_queue(int unsigned queue_id);
        virtio_config_backend backend;
        bit reset_ok;

        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // Write Q_RESET and poll until complete
        backend = cfg_backend();
        backend.reset_queue(queue_id, reset_ok);
        if (!reset_ok) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "reset_queue: config backend did not confirm queue_id=%0d reset", queue_id))
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d reset complete", queue_id), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // setup_queue_range -- 建立 [first_pair, first_pair+num_pairs) 的 RX/TX 队列对
    //
    // 队列号按 virtio-net 约定：pair i 的 receiveq 为 2i、transmitq 为 2i+1。
    // 任一队列失败时按创建顺序拆除本次已建队列并返回 ok=0，不触碰范围外队列；
    // teardown_queue 在后端未确认停 DMA 时保留队列资源（私有后端同样适用）。
    // ------------------------------------------------------------------------
    virtual task setup_queue_range(
        int unsigned     first_pair,
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size,
        output bit       ok
    );
        int unsigned created_qids[$];
        bit queue_ok;

        ok = 0;
        for (int unsigned i = first_pair; i < first_pair + num_pairs; i++) begin
            setup_queue(i * 2, queue_size, vq_type, queue_ok);  // receiveq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2);
            setup_queue(i * 2 + 1, queue_size, vq_type, queue_ok);  // transmitq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2 + 1);
        end
        ok = 1;
    endtask

    // ------------------------------------------------------------------------
    // setup_all_queues -- Create all queue pairs + control queue
    // ------------------------------------------------------------------------
    virtual task setup_all_queues(
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size,
        output bit        ok
    );
        int unsigned ctrl_qid;
        bit queue_ok;
        virtio_net_device_config_t net_cfg;

        ok = 0;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: num_pairs=%0d type=%s size=%0d",
                      num_pairs, vq_type.name(), queue_size), UVM_MEDIUM)

        // Setup receive and transmit queue pairs
        setup_queue_range(0, num_pairs, vq_type, queue_size, queue_ok);
        if (!queue_ok)
            return;

        // Setup control queue if CTRL_VQ negotiated.  virtio 1.2 §5.1.2：
        // 协商 MQ 时 controlq 编号为 2*max_virtqueue_pairs（设备 config 上限），
        // 否则为 2（单对）。取 max(num_pairs, 设备上限)，设备上报值小于当前对数时
        // 也不与数据队列重号；之后 MQ 扩容新建的 RX/TX 不会落到 control VQ 上。
        if (negotiated_features[VIRTIO_NET_F_CTRL_VQ]) begin
            ctrl_qid = num_pairs * 2;
            if (negotiated_features[VIRTIO_NET_F_MQ]) begin
                read_net_config(net_cfg);
                if (net_cfg.max_virtqueue_pairs > num_pairs)
                    ctrl_qid = 2 * net_cfg.max_virtqueue_pairs;
            end
            setup_queue(ctrl_qid, queue_size, vq_type, queue_ok);
            if (!queue_ok) begin
                for (int unsigned qid = 0; qid < num_pairs * 2; qid++)
                    teardown_queue(qid);
                return;
            end
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: complete, total queues=%0d",
                      vq_mgr.get_queue_count()), UVM_MEDIUM)
        ok = 1;
    endtask
