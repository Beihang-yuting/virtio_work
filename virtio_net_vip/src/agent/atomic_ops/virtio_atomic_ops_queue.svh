    // 本文件是 virtio_atomic_ops 类体的一部分（队列建立与拆除），只由
    // agent/virtio_atomic_ops.sv 在类定义内部 `include；不得单独编译或在类外包含。

    // ========================================================================
    // Queue Management
    // ========================================================================

    // setup_queue -- 建立、映射、编程并使能一条队列
    //
    // 输入为 Function 内 queue_id、请求深度和环格式；queue_size=0 采用设备上限，成功
    // 返回 ok=1，并由 ops/vq_mgr 分别持有 IOMMU 映射和 ring 对象。上下文不全、恢复
    // pending、queue_id 已存在、私有深度非法、分配/映射/向量/后端编程失败均返回 0；
    // 重复 queue_id 在任何分配和设备访问前拒绝，其余在设备尚未取得 ring 所有权的
    // 失败点立即回收本次资源。
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
        if (queue_recovery_pending || ctrl_recovery_pending) begin
            `uvm_error("ATOMIC_OPS",
                "setup_queue: verified Function reset required before creating another queue")
            return;
        end
        if ((transport == null) || (vq_mgr == null) || (iommu == null) ||
            (mem == null)) begin
            `uvm_error("ATOMIC_OPS", "setup_queue: incomplete queue context")
            return;
        end

        // 若复用 manager 中的旧对象，会在设备仍可能拥有旧 ring 时再次分配 ring，并
        // 覆盖 ops 保存的映射和编程记录。重复 queue_id 必须在分配资源、查询后端或
        // 访问 MMIO 之前拒绝，旧生命周期保持原样。
        if (vq_mgr.has_queue(queue_id)) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: queue_id=%0d already exists", queue_id))
            return;
        end

        // 私有环的 q_depth 是 log2 编码，且 custom_virtqueue 固定保留一个槽。显式请求
        // 在查询设备上限和“超上限裁剪”之前校验，避免 1/8192/非 2 次幂被裁成另一个
        // 合法值后进入后端。queue_size=0 仍表示采用后端上报的已校验默认深度。
        if ((vq_type == VQ_CUSTOM) && (queue_size != 0) &&
            ((queue_size < 2) || (queue_size > 4096) ||
             ((queue_size & (queue_size - 1)) != 0))) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                {"setup_queue: private queue_id=%0d size %0d is invalid; ",
                 "expected a power of two in 2..4096"}, queue_id, queue_size))
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

        // 8. 本队列的 MSI-X 向量：初始化已分配的直接取用；之后新建的队列（MQ 扩容）
        // 现分配一个不占用其他队列的向量。configure_queue 在 queue_enable 之前写入并回读。
        msix_vector = transport.notify_mgr.allocate_queue_vector(queue_id);
        if (msix_vector == 32'hFFFF) begin
            foreach (region_iovas[i])
                iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                     region_iovas[i]);
            ring_iovas.delete(queue_id);
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: no free MSI-X vector for queue_id=%0d", queue_id))
            return;
        end

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

    // teardown_queue_verified -- 确认停队后释放一条队列，并把确认结果返回调用方
    //
    // 输入 queue_id 是当前 Function 内的队列号；stopped=1 表示后端已经确认设备不再
    // 访问该队列，且 Host ring、普通数据 DMA 和 manager 项均已释放。后端停队失败时
    // stopped=0，全部仍归 Host 所有的资源保持原状，并置 queue_recovery_pending，要求
    // 调用方执行 verified Function reset。该结果用于 MQ 缩容和批量建队回滚，避免靠
    // “队列是否还存在”间接猜测硬件停队结果。
    virtual task teardown_queue_verified(int unsigned queue_id, output bit stopped);
        virtqueue_base vq;
        uvm_object tokens[$];
        virtio_config_backend backend;

        stopped = 0;

        `uvm_info("ATOMIC_OPS",
            $sformatf("teardown_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // 1. 先确认设备停止访问该队列再动 ring/DMA。virtio 1.2 §4.1.4.3.2 禁止写 queue_enable=0：
        // 协商 VIRTIO_F_RING_RESET 时经后端 Q_RESET 并轮询完成；否则由后端停队（标准设备没有单队列
        // 停止手段，返回未确认；私有设备走寄存器停队）。未确认时保留全部 ring/DMA，由 Function 复位回收。
        backend = cfg_backend();
        if (negotiated_features[VIRTIO_F_RING_RESET])
            backend.reset_queue(queue_id, stopped);
        else
            backend.disable_queue(queue_program_of(queue_id), stopped);
        if (!stopped) begin
            queue_recovery_pending = 1;
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

    // teardown_queue -- 兼容 MANUAL/既有调用方的无返回值入口
    //
    // 输入 queue_id 与 teardown_queue_verified 相同；副作用及失败资源所有权完全委托
    // 给 verified 版本。需要决定后续状态迁移的调用方必须直接使用 verified 接口。
    virtual task teardown_queue(int unsigned queue_id);
        bit stopped;

        teardown_queue_verified(queue_id, stopped);
    endtask

    // rollback_created_queues -- 回滚一批刚建立、尚未交付给调用方的队列
    //
    // created_qids 按建立顺序传入。先逐队请求确认停 DMA；全部成功时仅释放这些队列。
    // 任一后端不能确认（标准 common-config 未协商 RING_RESET 即属于此情况）时，执行
    // verified Function reset，因为此时没有更窄且安全的停队手段。复位成功会统一释放
    // 本 Function 全部队列并返回 rollback_complete=1；复位失败则保留尚未安全停止的
    // ring/DMA，保持 recovery pending 并返回 0。
    protected task rollback_created_queues(
        ref int unsigned created_qids[$],
        output bit rollback_complete
    );
        bit stopped;
        bit reset_complete;

        rollback_complete = 1;
        foreach (created_qids[i]) begin
            teardown_queue_verified(created_qids[i], stopped);
            if (!stopped)
                rollback_complete = 0;
        end
        if (rollback_complete)
            return;

        queue_recovery_pending = 1;
        queue_rollback_function_reset_attempted = 1;
        device_reset_verified(reset_complete);
        if (!reset_complete) begin
            `uvm_error("ATOMIC_OPS",
                {"rollback_created_queues: verified Function reset failed; ",
                 "retaining queue DMA and requiring recovery"})
            return;
        end
        rollback_complete = 1;
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
    // 任一队列失败时按创建顺序尝试拆除本次已建队列并返回 ok=0。若单队列停队均已
    // 确认，则不触碰范围外队列；任一停队未确认时升级为 verified Function reset，因而
    // 整个 Function 都需要重新初始化。复位失败时安全保留尚未停止的 ring/DMA 并置
    // recovery pending，禁止继续创建队列。
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
        bit rollback_complete;

        ok = 0;
        queue_rollback_function_reset_attempted = 0;
        for (int unsigned i = first_pair; i < first_pair + num_pairs; i++) begin
            setup_queue(i * 2, queue_size, vq_type, queue_ok);  // receiveq_i
            if (!queue_ok) begin
                rollback_created_queues(created_qids, rollback_complete);
                return;
            end
            created_qids.push_back(i * 2);
            setup_queue(i * 2 + 1, queue_size, vq_type, queue_ok);  // transmitq_i
            if (!queue_ok) begin
                rollback_created_queues(created_qids, rollback_complete);
                return;
            end
            created_qids.push_back(i * 2 + 1);
        end
        ok = 1;
    endtask

    // ------------------------------------------------------------------------
    // control_queue_id -- num_pairs 对数据队列时 control VQ 的队列号
    //
    // virtio 1.2 §5.1.2：协商 MQ 时 controlq 编号为 2*max_virtqueue_pairs（设备 config 上限），
    // 否则为 2（单对）。取 max(num_pairs, 设备上限)，设备上报值小于当前对数时也不与数据队列
    // 重号；之后 MQ 扩容新建的 RX/TX 不会落到 control VQ 上。
    // ------------------------------------------------------------------------
    virtual task control_queue_id(int unsigned num_pairs, output int unsigned ctrl_qid);
        virtio_net_device_config_t net_cfg;

        ctrl_qid = num_pairs * 2;
        if (negotiated_features[VIRTIO_NET_F_MQ]) begin
            read_net_config(net_cfg);
            if (net_cfg.max_virtqueue_pairs > num_pairs)
                ctrl_qid = 2 * net_cfg.max_virtqueue_pairs;
        end
    endtask

    // setup_control_queue -- 计算、建立并登记本生命周期的 control VQ
    //
    // 输入 num_pairs 是当前数据队列对数，vq_type/queue_size 与普通建队含义相同；ok
    // 仅在队列完整映射、编程、使能并保存显式身份后返回 1。未协商 CTRL_VQ、已有
    // recovery pending、设备布局改变导致队列号与既有身份冲突，或底层建队失败时不
    // 更新身份并返回 0。成功建立的队列由 vq_mgr/ops 持有，直到拆队或整设备复位。
    virtual task setup_control_queue(
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size,
        output bit       ok
    );
        int unsigned ctrl_qid;
        bit queue_ok;

        ok = 0;
        if (!negotiated_features[VIRTIO_NET_F_CTRL_VQ]) begin
            `uvm_error("ATOMIC_OPS",
                "setup_control_queue: VIRTIO_NET_F_CTRL_VQ was not negotiated")
            return;
        end
        if (ctrl_recovery_pending) begin
            `uvm_error("ATOMIC_OPS",
                "setup_control_queue: verified device reset required before rebuilding control VQ")
            return;
        end

        control_queue_id(num_pairs, ctrl_qid);
        if (ctrl_queue_id_valid && (ctrl_queue_id_value != ctrl_qid)) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_control_queue: control VQ identity changed from %0d to %0d without device reset",
                ctrl_queue_id_value, ctrl_qid))
            return;
        end

        setup_queue(ctrl_qid, queue_size, vq_type, queue_ok);
        if (!queue_ok)
            return;

        ctrl_queue_id_value = ctrl_qid;
        ctrl_queue_id_valid = 1;
        ok = 1;
    endtask

    // setup_all_queues -- 建立全部数据队列对以及协商存在的 control VQ
    //
    // 输入 num_pairs/vq_type/queue_size 描述目标拓扑；成功时 ok=1，数据队列与显式登记
    // 的 control VQ 均已编程使能。布局非法或任一建队失败时 ok=0，并通过统一回滚路径
    // 安全释放本轮资源；后端不能确认停队时可能升级为 verified Function reset。
    virtual task setup_all_queues(
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size,
        output bit        ok
    );
        bit queue_ok;
        bit rollback_complete;
        int unsigned data_qids[$];

        ok = 0;
        queue_rollback_function_reset_attempted = 0;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: num_pairs=%0d type=%s size=%0d",
                      num_pairs, vq_type.name(), queue_size), UVM_MEDIUM)

        // 未协商 MQ 时 controlq 固定为 2（N=1，virtio 1.2 §5.1.2）；多于 1 对的数据队列
        // 会占用队列 2，与 control VQ 冲突，必须在建队前拒绝。
        if (negotiated_features[VIRTIO_NET_F_CTRL_VQ] && !negotiated_features[VIRTIO_NET_F_MQ] &&
            (num_pairs > 1)) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_all_queues: %0d queue pairs with a control VQ requires VIRTIO_NET_F_MQ",
                num_pairs))
            return;
        end

        // Setup receive and transmit queue pairs
        setup_queue_range(0, num_pairs, vq_type, queue_size, queue_ok);
        if (!queue_ok)
            return;

        // Setup control queue if CTRL_VQ negotiated.
        if (negotiated_features[VIRTIO_NET_F_CTRL_VQ]) begin
            setup_control_queue(num_pairs, vq_type, queue_size, queue_ok);
            if (!queue_ok) begin
                for (int unsigned qid = 0; qid < num_pairs * 2; qid++)
                    data_qids.push_back(qid);
                rollback_created_queues(data_qids, rollback_complete);
                return;
            end
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: complete, total queues=%0d",
                      vq_mgr.get_queue_count()), UVM_MEDIUM)
        ok = 1;
    endtask
