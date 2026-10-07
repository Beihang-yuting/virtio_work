    // 本文件是 virtio_atomic_ops 类体的一部分（设备生命周期、特性协商与中断），只由
    // agent/virtio_atomic_ops.sv 在类定义内部 `include；不得单独编译或在类外包含。

    // ========================================================================
    // Device Lifecycle
    // ========================================================================

    // ------------------------------------------------------------------------
    // device_reset -- Write status=0 and clean up all queue/DMA state
    // ------------------------------------------------------------------------
    virtual task device_reset_verified(ref bit reset_complete);
        int unsigned tx_qids[$];
        int unsigned rx_qids[$];
        virtio_config_backend backend;

        `uvm_info("ATOMIC_OPS", "device_reset: starting", UVM_MEDIUM)

        reset_complete = 0;
        if ((transport == null) || (vq_mgr == null) || (iommu == null) ||
            ((mem == null) && has_pending_normal_dma())) begin
            `uvm_error("ATOMIC_OPS", "device_reset: incomplete PF lifecycle context")
            return;
        end
        backend = cfg_backend();
        backend.reset(reset_complete);
        if (!reset_complete) begin
            `uvm_error("ATOMIC_OPS", "device_reset: transport reset did not complete; retaining PF DMA")
            return;
        end

        // Detach all queues if any exist
        if (vq_mgr.get_queue_count() > 0) begin
            vq_mgr.detach_all_queues();
        end

        // Clear all tracked IOMMU mappings for rings
        foreach (ring_iovas[qid]) begin
            foreach (ring_iovas[qid][i]) begin
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, ring_iovas[qid][i]);
            end
        end
        ring_iovas.delete();
        queue_programs.delete();
        foreach (tx_dma_map[qid]) begin
            tx_qids.push_back(qid);
        end
        foreach (tx_qids[i]) begin
            retire_normal_dma_records(tx_dma_map[tx_qids[i]]);
            tx_dma_map.delete(tx_qids[i]);
        end
        foreach (rx_dma_map[qid]) begin
            rx_qids.push_back(qid);
        end
        foreach (rx_qids[i]) begin
            retire_normal_dma_records(rx_dma_map[rx_qids[i]]);
            rx_dma_map.delete(rx_qids[i]);
        end
        release_migration_restore_payloads();
        foreach (ctrl_quarantined_iovas[i])
            iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                 ctrl_quarantined_iovas[i]);
        foreach (ctrl_quarantined_gpas[i])
            mem.free(ctrl_quarantined_gpas[i]);
        ctrl_quarantined_iovas.delete();
        ctrl_quarantined_gpas.delete();

        // detach_all_queues() releases descriptor ownership only.  After a
        // verified device reset, free every queue's rings and remove its
        // manager entry before the PF can be reinitialized.
        vq_mgr.destroy_all();

        negotiated_features = '0;

        `uvm_info("ATOMIC_OPS", "device_reset: complete", UVM_MEDIUM)
    endtask

    // 设备发现经配置后端：标准设备枚举 BAR/capability，私有设备由其后端决定。
    virtual task discover_device();
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.discover();
    endtask

    // 便捷入口：执行验证式设备复位但忽略完成标志（结果由日志体现）；
    // 需要判定复位是否成功的调用方应使用 device_reset_verified。
    virtual task device_reset();
        bit reset_complete;

        device_reset_verified(reset_complete);
    endtask

    // MANUAL 原始 status 读写：经配置后端访问，与生命周期 helper 走同一路径；
    // 私有后端拒绝该访问（driver 已按协议在此之前拒绝）。
    virtual task write_device_status(bit [7:0] status);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.write_status(status);
    endtask

    virtual task read_device_status(output bit [7:0] status);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.read_status(status);
    endtask

    // 设备 net config 读取：FSM、迁移与建队片段的唯一入口，经配置后端。
    virtual task read_net_config(output virtio_net_device_config_t cfg);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.read_net_config(cfg);
    endtask

    // ------------------------------------------------------------------------
    // set_acknowledge -- Set ACKNOWLEDGE bit in device status
    // ------------------------------------------------------------------------
    virtual task set_acknowledge();
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.write_status(DEV_STATUS_ACKNOWLEDGE);
        `uvm_info("ATOMIC_OPS", "set_acknowledge: done", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver -- OR current status with DRIVER bit and write back
    // ------------------------------------------------------------------------
    virtual task set_driver();
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_DRIVER;
        backend.write_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_features_ok -- Set FEATURES_OK and verify device accepted it
    // ------------------------------------------------------------------------
    virtual task set_features_ok(ref bit ok);
        virtio_config_backend backend;
        bit [7:0] status;
        bit [7:0] readback;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_FEATURES_OK;
        backend.write_status(status);

        // Poll to confirm FEATURES_OK is still set
        backend.read_status(readback);
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
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        ok = (status & DEV_STATUS_FEATURES_OK) ? 1 : 0;
        `uvm_info("ATOMIC_OPS",
            $sformatf("verify_features_ok: status=0x%02h ok=%0b", status, ok), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver_ok -- OR current status with DRIVER_OK bit
    // ------------------------------------------------------------------------
    virtual task set_driver_ok();
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_DRIVER_OK;
        backend.write_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver_ok: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_failed -- OR current status with FAILED bit
    // ------------------------------------------------------------------------
    virtual task set_failed();
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_FAILED;
        backend.write_status(status);
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
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.read_device_features(features);
    endtask

    // ------------------------------------------------------------------------
    // write_driver_features -- Write driver-selected feature bits
    // ------------------------------------------------------------------------
    virtual task write_driver_features(bit [63:0] features);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.write_driver_features(features);
    endtask

    // ------------------------------------------------------------------------
    // negotiate_features -- AND device features with driver caps, write result
    // ------------------------------------------------------------------------
    virtual task negotiate_features(bit [63:0] driver_caps, ref bit [63:0] result);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.set_features(driver_caps, result);
        negotiated_features = result;
        `uvm_info("ATOMIC_OPS",
            $sformatf("negotiate_features: result=0x%016h", result), UVM_MEDIUM)
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
        virtio_config_backend backend;
        int unsigned queue_ids[$];
        bit msix_ok;

        // 绑定 vq_mgr 中实际存在的队列号（control VQ 可位于 2*max_virtqueue_pairs）；
        // 数量与 num_queues 不符（尚未建队的手工调用）时沿用 0..num_queues-1。
        if ((vq_mgr != null) && (vq_mgr.get_queue_count() == num_queues))
            vq_mgr.get_queue_ids(queue_ids);
        else begin
            for (int unsigned q = 0; q < num_queues; q++)
                queue_ids.push_back(q);
        end
        backend = cfg_backend();
        backend.set_msix(queue_ids, msix_ok);
        if (!msix_ok)
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_msix: config backend rejected %0d queue vectors", num_queues))

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_msix: num_queues=%0d mode=%s",
                      num_queues, transport.notify_mgr.irq_mode.name()), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // teardown_msix -- Mask and release all MSI-X vectors
    // ------------------------------------------------------------------------
    virtual task teardown_msix();
        virtio_config_backend backend;
        bit cleared;

        backend = cfg_backend();
        backend.clear_msix(cleared);
        `uvm_info("ATOMIC_OPS", "teardown_msix: all vectors masked", UVM_MEDIUM)
    endtask
