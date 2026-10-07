`ifndef VIRTIO_AUTO_FSM_SV
`define VIRTIO_AUTO_FSM_SV

// ============================================================================
// virtio_auto_fsm
//
// Complete lifecycle state machine for the virtio-net driver VIP.
// Orchestrates device initialization, data plane operation, reconfiguration,
// live migration, and error recovery using virtio_atomic_ops.
//
// Critical implementation rules enforced:
//   1. Named fork blocks only: fork : block_name ... join*; disable block_name;
//   2. No bare #delay -- all waits use wait_pol or named fork with #(ns * 1ns)
//   3. All background tasks check their run epoch after every wait
//   4. start_dataplane uses fork : dataplane_tasks ... join_none
//   5. stop_dataplane waits for an explicit completion acknowledgement from
//      every background task before any caller may reset queue/DMA ownership
//
// Depends on:
//   - virtio_atomic_ops (low-level driver operations)
//   - virtio_migration_engine (migration checksum/capture/restore steps)
//   - virtio_net_types.sv (fsm_state_e, virtio_driver_config_t, etc.)
//   - virtio_wait_policy (timeout/polling)
// ============================================================================

class virtio_auto_fsm extends uvm_report_object;
    `uvm_object_utils(virtio_auto_fsm)

    // ===== State =====
    fsm_state_e   state = FSM_IDLE;

    // ===== References =====
    virtio_atomic_ops       ops;
    virtio_driver_config_t  drv_cfg;

    // ===== Background task control =====
    protected bit   dataplane_running = 0;
    protected event stop_event;
    protected int unsigned dataplane_epoch = 0;
    protected bit          dataplane_stop_requested = 0;
    protected int unsigned dataplane_workers_expected = 0;
    protected int unsigned dataplane_workers_completed = 0;
    protected int unsigned dataplane_workers_stopped_epoch = 0;
    protected int unsigned recovery_requested_epoch = 0;

    // ===== Events for inter-task signaling =====
    uvm_event  used_ring_updated_event;   // fired when used ring has new entries
    uvm_event  packet_completed_event;    // fired on each TX/RX completion
    uvm_event  config_change_event;       // fired on device config change
    uvm_event  interrupt_event;           // fired on interrupt received

    // ===== Internal state =====
    protected int unsigned  num_total_queues;
    protected int unsigned  active_num_pairs;
    local int unsigned      max_vio_net_qpairs_per_device;
    local bit               mq_pair_limit_bound;

    // 迁移计算与恢复步骤（校验和、采集、校验、重建）；FSM 只负责状态与数据面启停。
    protected virtio_migration_engine migration;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_auto_fsm");
        super.new(name);
        used_ring_updated_event = new("used_ring_updated_event");
        packet_completed_event  = new("packet_completed_event");
        config_change_event     = new("config_change_event");
        interrupt_event         = new("interrupt_event");
        num_total_queues        = 0;
        active_num_pairs        = 1;
        max_vio_net_qpairs_per_device = DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        mq_pair_limit_bound = 0;
        migration = virtio_migration_engine::type_id::create({name, "_migration"});
    endfunction

    // 取本 function 在 IOMMU 视角下的 host id（经 transport 转发）；
    // ops/transport 尚未接入属于接线错误，直接 fatal，不默认 host0。
    protected function int unsigned iommu_host_id();
        if ((ops == null) || (ops.transport == null)) begin
            `uvm_fatal("AUTO_FSM",
                "DMA host domain requested before ops/transport were bound")
            return 0;
        end
        return ops.transport.iommu_host_id();
    endfunction

    // Snapshot the function's effective MQ limit.  The limit always comes
    // from the function's frozen DUT capability and must be nonzero.
    // Repeated binds are idempotent, but a different value is rejected so a
    // live FSM cannot diverge from its configured queue state.
    function bit mq_pair_limit_binding_supported(
        input int unsigned configured_limit,
        output string why
    );
        if (configured_limit == 0) begin
            why = "FSM MQ pair limit must be a nonzero per-function value";
            return 0;
        end
        if (configured_limit > DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) begin
            why = $sformatf(
                "FSM MQ pair limit %0d exceeds model ceiling %0d",
                configured_limit, DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE);
            return 0;
        end
        if (!mq_pair_limit_bound ||
            (configured_limit == max_vio_net_qpairs_per_device)) begin
            why = "";
            return 1;
        end
        why = $sformatf(
            "FSM MQ pair limit is already bound to %0d; cannot rebind to %0d",
            max_vio_net_qpairs_per_device, configured_limit);
        return 0;
    endfunction

    // 把 function 级 MQ 队列对上限绑定进 FSM：上限必须非零；首次绑定生效并置
    // mq_pair_limit_bound，重复绑定同值幂等，改绑不同值被
    // mq_pair_limit_binding_supported 拒绝（why 给出原因）。
    // 返回 1 表示绑定成功或幂等命中。
    function bit bind_mq_pair_limit(
        input int unsigned configured_limit,
        output string why
    );
        if (!mq_pair_limit_binding_supported(configured_limit, why))
            return 0;
        if (!mq_pair_limit_bound) begin
            max_vio_net_qpairs_per_device = configured_limit;
            mq_pair_limit_bound = 1;
        end
        why = "";
        return 1;
    endfunction

    // 查询当前生效的 MQ 队列对上限（绑定前为模型缺省上限）。
    function int unsigned max_supported_mq_pairs();
        return max_vio_net_qpairs_per_device;
    endfunction

    // 迁移快照整体校验和（委托迁移引擎）；派生 FSM/测试改写快照后据此重算。
    protected function bit [63:0] migration_snapshot_checksum(
        virtio_device_snapshot_t snap
    );
        return migration.migration_snapshot_checksum(snap);
    endfunction

    // A worker belongs to precisely one start_dataplane() generation.  The
    // epoch check prevents a worker that missed a transient event from doing
    // work again after a later start flips dataplane_running back to one.
    protected function bit dataplane_worker_may_run(int unsigned worker_epoch);
        return dataplane_running && !dataplane_stop_requested &&
               (worker_epoch == dataplane_epoch);
    endfunction

    // 记录一个 dataplane worker 的退出。仅接受当前 epoch 的 worker
    //（旧代 worker 的迟到上报被丢弃），且完成数不会超过期望数；
    // 最后一个 worker 退出时记下 stopped_epoch 供 stop/recovery 同步等待。
    protected function void complete_dataplane_worker(int unsigned worker_epoch);
        if ((worker_epoch != dataplane_epoch) ||
            (dataplane_workers_expected == 0) ||
            (dataplane_workers_completed >= dataplane_workers_expected))
            return;
        dataplane_workers_completed++;
        if (dataplane_workers_completed == dataplane_workers_expected) begin
            dataplane_workers_stopped_epoch = worker_epoch;
        end
    endfunction

    // worker 内部发起本代 dataplane 停止请求：清 running、置 stop 标志并
    // 广播 stop_event 唤醒其他 worker；epoch 不匹配（已换代）则静默忽略，
    // 防止旧 worker 误停新一代数据面。
    protected task request_dataplane_stop(int unsigned worker_epoch);
        if (worker_epoch != dataplane_epoch)
            return;
        dataplane_running = 0;
        dataplane_stop_requested = 1;
        -> stop_event;
    endtask

    // ========================================================================
    // Complete Initialization
    //
    // FSM_IDLE -> FSM_DISCOVERING -> FSM_NEGOTIATING -> FSM_MSIX_SETUP
    //          -> FSM_QUEUE_SETUP -> FSM_READY
    // ========================================================================

    // 本 Function 的队列格式：驱动协议可改写配置值（私有协议固定 VQ_CUSTOM）。
    protected function virtqueue_type_e queue_format();
        if ((ops == null) || (ops.protocol == null))
            return drv_cfg.vq_type;
        return ops.protocol.queue_format(drv_cfg.vq_type);
    endfunction

    task full_init();
        if ($isunknown(drv_cfg.num_queue_pairs) ||
            (drv_cfg.num_queue_pairs == 0) ||
            (drv_cfg.num_queue_pairs > max_vio_net_qpairs_per_device)) begin
            `uvm_error("AUTO_FSM", $sformatf(
                {"full_init: configured queue-pair count %0d is outside ",
                 "supported range 1..%0d"},
                drv_cfg.num_queue_pairs,
                max_vio_net_qpairs_per_device))
            return;
        end
        do_full_init();
    endtask

    // full_init 的实现体（入参已由 full_init 校验）：按 virtio 1.x 顺序推进
    // DISCOVERING（BAR 发现，按 transport 的发现策略）→ NEGOTIATING（复位、
    // ACK/DRIVER、特性协商、FEATURES_OK）→ MSIX_SETUP（按将要建立的队列分配并绑定
    // 向量）→ QUEUE_SETUP（按队列对数建队，CTRL_VQ 协商成功时额外 +1 队列；每条队列在
    // queue_enable 前写入最终向量，virtio 1.2 §4.1.4.3.2）→ FSM_READY。
    // 任一步失败置 FSM_ERROR 并向设备写 FAILED 后返回。
    // protected virtual 以便派生 FSM 覆写初始化流程。
    protected virtual task do_full_init();
        bit [63:0] negotiated;
        bit        feat_ok;
        bit        setup_ok;
        bit        reset_ok;
        int unsigned total_queues;

        // 要求确认停 DMA 的协议（私有环）不得在数据面运行时重初始化：复位会在后台
        // worker 仍持有队列/DMA 时销毁队列。拒绝且不改变状态；标准协议保持原行为。
        if ((state == FSM_RUNNING) && (ops.protocol != null) &&
            ops.protocol.requires_verified_reset()) begin
            `uvm_error("AUTO_FSM", "full_init: dataplane is running; stop it before re-initialization")
            return;
        end

        `uvm_info("AUTO_FSM", "full_init: starting initialization sequence", UVM_LOW)

        // ---- Step 1: BAR discovery ----
        state = FSM_DISCOVERING;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- discovering BARs", state.name()), UVM_MEDIUM)
        ops.discover_device();

        // ---- Step 2: Feature negotiation ----
        state = FSM_NEGOTIATING;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- negotiating features", state.name()), UVM_MEDIUM)

        // 要求确认停 DMA 的协议（私有环）复位未确认即失败，保留全部资源；标准协议
        // 保持原 device_reset 调用（测试子类会覆写它）。
        if ((ops.protocol != null) && ops.protocol.requires_verified_reset()) begin
            ops.device_reset_verified(reset_ok);
            if (!reset_ok) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", "full_init: device reset not confirmed; retaining DMA")
                return;
            end
        end else
            ops.device_reset();

        ops.set_acknowledge();
        ops.set_driver();

        ops.negotiate_features(drv_cfg.driver_features, negotiated);

        ops.set_features_ok(feat_ok);
        if (!feat_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", "full_init: device rejected features")
            ops.set_failed();
            return;
        end

        active_num_pairs = drv_cfg.num_queue_pairs;
        total_queues = 2 * active_num_pairs;
        if (negotiated[VIRTIO_NET_F_CTRL_VQ])
            total_queues = total_queues + 1;
        num_total_queues = total_queues;

        // ---- Step 3: MSI-X setup ----
        // 先于建队：setup_queue 取 notify_mgr 中已分配的向量，在 queue_enable 前写入。
        state = FSM_MSIX_SETUP;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- setting up MSI-X", state.name()), UVM_MEDIUM)

        ops.setup_msix(num_total_queues);

        // ---- Step 4: Queue setup ----
        state = FSM_QUEUE_SETUP;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- setting up queues", state.name()), UVM_MEDIUM)

        ops.setup_all_queues(active_num_pairs, queue_format(),
                             drv_cfg.queue_size, setup_ok);
        if (!setup_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", "full_init: queue setup failed")
            ops.set_failed();
            return;
        end

        // ---- Step 5: DRIVER_OK ----
        ops.set_driver_ok();
        state = FSM_READY;

        `uvm_info("AUTO_FSM",
            $sformatf("full_init: complete, state=%s, %0d queues, features=0x%016h",
                      state.name(), num_total_queues, negotiated), UVM_LOW)
    endtask

    // ========================================================================
    // Data Plane Control
    // ========================================================================

    // ------------------------------------------------------------------------
    // start_dataplane -- FSM_READY -> FSM_RUNNING
    //
    // Pre-fills RX buffers and forks all background tasks in a named block.
    // ------------------------------------------------------------------------
    virtual task start_dataplane();
        int unsigned run_epoch;

        if (state != FSM_READY) begin
            `uvm_error("AUTO_FSM",
                $sformatf("start_dataplane: invalid state %s (expected FSM_READY)", state.name()))
            return;
        end
        if ((dataplane_workers_expected != 0) &&
            (dataplane_workers_completed != dataplane_workers_expected)) begin
            `uvm_error("AUTO_FSM",
                "start_dataplane: previous dataplane workers have not stopped")
            return;
        end

        `uvm_info("AUTO_FSM", "start_dataplane: starting data plane", UVM_MEDIUM)

        dataplane_epoch++;
        dataplane_stop_requested = 0;
        dataplane_workers_expected = 5;
        dataplane_workers_completed = 0;
        dataplane_running = 1;
        run_epoch = dataplane_epoch;
        state = FSM_RUNNING;

        // Pre-fill RX buffers for all receive queues (even-numbered queues)
        for (int unsigned i = 0; i < active_num_pairs; i++) begin
            int unsigned rx_qid = i * 2;
            ops.rx_refill(rx_qid, drv_cfg.queue_size);
        end

        // Fork all background tasks in a named block
        fork : dataplane_tasks
            begin : rx_refill_loops
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    automatic int unsigned rx_qid = i * 2;
                    fork
                        rx_refill_loop(rx_qid, run_epoch);
                    join_none
                end
                wait fork;
                complete_dataplane_worker(run_epoch);
            end

            begin : tx_complete_loops
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    automatic int unsigned tx_qid = i * 2 + 1;
                    fork
                        tx_complete_loop(tx_qid, run_epoch);
                    join_none
                end
                wait fork;
                complete_dataplane_worker(run_epoch);
            end

            begin
                interrupt_handler_loop(run_epoch);
                complete_dataplane_worker(run_epoch);
            end

            begin : adaptive_irq_check
                if (drv_cfg.irq_mode == IRQ_POLLING) begin
                    adaptive_irq_loop(run_epoch);
                end
                complete_dataplane_worker(run_epoch);
            end

            begin
                config_change_handler(run_epoch);
                complete_dataplane_worker(run_epoch);
            end
        join_none

        // DEVICE_NEEDS_RESET may be detected by config_change_handler(), one
        // of the workers above.  Keep recovery outside that worker set so it
        // can wait for the complete acknowledgement without self-deadlock.
        fork : dataplane_recovery_watch
            dataplane_recovery_supervisor(run_epoch);
        join_none

        `uvm_info("AUTO_FSM", "start_dataplane: background tasks forked", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // stop_dataplane -- FSM_RUNNING -> FSM_READY
    //
    // Signals all background tasks to exit, then waits for their explicit
    // acknowledgement.  Returning before that acknowledgement would let a PF
    // reset detach queues while a worker still owns a VQ/DMA operation.
    // ------------------------------------------------------------------------
    virtual task stop_dataplane();
        if (state != FSM_RUNNING) begin
            `uvm_warning("AUTO_FSM",
                $sformatf("stop_dataplane: state is %s, not FSM_RUNNING", state.name()))
        end

        `uvm_info("AUTO_FSM", "stop_dataplane: stopping data plane", UVM_MEDIUM)

        if ((dataplane_workers_expected != 0) &&
            (dataplane_workers_completed != dataplane_workers_expected)) begin
            int unsigned stop_epoch = dataplane_epoch;
            request_dataplane_stop(stop_epoch);
            wait (dataplane_workers_stopped_epoch == stop_epoch);
        end else begin
            dataplane_running = 0;
            dataplane_stop_requested = 1;
        end

        state = FSM_READY;

        `uvm_info("AUTO_FSM", "stop_dataplane: data plane stopped", UVM_MEDIUM)
    endtask

    // ========================================================================
    // High-Level Data Operations
    // ========================================================================

    // ------------------------------------------------------------------------
    // send_packets -- Submit packets for transmission
    //
    // Builds a default virtio_net_hdr per packet and submits via tx_submit.
    // queue_id is treated as a pair index if < active_num_pairs.
    // ------------------------------------------------------------------------
    virtual task send_packets(uvm_object pkts[$], int unsigned queue_id = 0);
        int unsigned tx_qid;
        int unsigned desc_id;

        // Transmit queues are odd-numbered: pair_index*2+1
        if (queue_id < active_num_pairs)
            tx_qid = queue_id * 2 + 1;
        else
            tx_qid = queue_id;

        `uvm_info("AUTO_FSM",
            $sformatf("send_packets: count=%0d queue_id=%0d", pkts.size(), tx_qid), UVM_MEDIUM)

        foreach (pkts[i]) begin
            virtio_net_hdr_t hdr;

            // Build default virtio_net_hdr
            hdr.flags       = 8'h00;
            hdr.gso_type    = VIRTIO_NET_HDR_GSO_NONE;
            hdr.hdr_len     = 16'h0000;
            hdr.gso_size    = 16'h0000;
            hdr.csum_start  = 16'h0000;
            hdr.csum_offset = 16'h0000;
            hdr.num_buffers = 16'h0000;
            hdr.hash_value  = 32'h00000000;
            hdr.hash_report = 16'h0000;

            // If CSUM offload is negotiated, set NEEDS_CSUM flag
            if (ops.negotiated_features[VIRTIO_NET_F_CSUM]) begin
                hdr.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
            end

            ops.tx_submit(tx_qid, hdr, pkts[i], 0, desc_id);
        end
    endtask

    // ------------------------------------------------------------------------
    // wait_packets -- Wait for packets to arrive on receive queues
    //
    // Uses mixed event + polling approach (no bare #delay).
    // Loop until count >= expected or timeout, using named fork blocks.
    // ------------------------------------------------------------------------
    virtual task wait_packets(
        int unsigned expected_count,
        ref uvm_object received[$],
        int unsigned timeout_ns
    );
        int unsigned   count = 0;
        realtime       start_time;
        int unsigned   interval;
        int unsigned   budget;
        int unsigned   eff_timeout;

        interval    = ops.wait_pol.default_poll_interval_ns;
        budget      = drv_cfg.napi_budget;
        if (budget == 0) budget = 64;
        eff_timeout = ops.wait_pol.effective_timeout(timeout_ns);
        start_time  = $realtime;

        `uvm_info("AUTO_FSM",
            $sformatf("wait_packets: expecting %0d, timeout=%0dns", expected_count, eff_timeout),
            UVM_MEDIUM)

        while (count < expected_count) begin
            realtime elapsed_ns;
            elapsed_ns = ($realtime - start_time) / 1ns;

            if (elapsed_ns >= eff_timeout) begin
                `uvm_warning("AUTO_FSM",
                    $sformatf("wait_packets: timeout after %0dns, received %0d/%0d",
                              eff_timeout, count, expected_count))
                return;
            end

            if (!dataplane_running) begin
                `uvm_info("AUTO_FSM",
                    "wait_packets: dataplane stopped, exiting wait", UVM_MEDIUM)
                return;
            end

            // Wait for used ring event or poll interval (named fork)
            fork : pkt_wait_blk
                begin : pkt_wait_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : pkt_wait_timeout_arm
                    #(interval * 1ns);
                end
                begin : pkt_wait_stop_arm
                    @stop_event;
                end
            join_any
            disable pkt_wait_blk;

            if (!dataplane_running)
                return;

            // Poll all receive queues for new packets
            for (int unsigned i = 0; i < active_num_pairs; i++) begin
                int unsigned rx_qid = i * 2;
                uvm_object   rx_pkts[$];

                ops.rx_receive(rx_qid, rx_pkts, budget);

                foreach (rx_pkts[j]) begin
                    received.push_back(rx_pkts[j]);
                    count++;
                    packet_completed_event.trigger();
                end
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("wait_packets: received %0d/%0d", count, expected_count), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Reconfiguration
    // ========================================================================

    // ------------------------------------------------------------------------
    // configure_mq -- Change the number of active queue pairs
    // ------------------------------------------------------------------------
    task configure_mq(int unsigned num_pairs);
        if ((ops != null) && (ops.protocol != null) && !ops.protocol.supports_mq()) begin
            `uvm_error("AUTO_FSM", "configure_mq: driver protocol does not support dynamic MQ")
            return;
        end
        if ($isunknown(num_pairs) || (num_pairs == 0) ||
            (num_pairs > max_vio_net_qpairs_per_device)) begin
            `uvm_error("AUTO_FSM", $sformatf(
                "configure_mq: requested %0d pairs is outside supported range 1..%0d",
                num_pairs, max_vio_net_qpairs_per_device))
            return;
        end
        do_configure_mq(num_pairs);
    endtask

    // configure_mq 的实现体：先经 ctrl VQ 向设备提交 MQ 变更，设备接受后
    // 再收敛队列——缩容拆除多余的 RX/TX 队列，扩容经 ops.setup_queue_range 按对新建
    // （任一失败拆除本次新建的全部队列并 FSM_ERROR；新队列由 setup_queue 分配向量并在
    // queue_enable 之前写入，已使能队列的向量不变），最后更新 active_num_pairs 与
    // num_total_queues。
    // 设备拒绝时仅报错、不动现有队列。
    protected virtual task do_configure_mq(int unsigned num_pairs);
        bit success;
        bit setup_ok;

        `uvm_info("AUTO_FSM",
            $sformatf("configure_mq: changing from %0d to %0d pairs",
                      active_num_pairs, num_pairs), UVM_MEDIUM)

        ops.ctrl_set_mq_pairs(num_pairs, success);

        if (success) begin
            // Teardown queues that are no longer needed
            if (num_pairs < active_num_pairs) begin
                for (int unsigned i = num_pairs; i < active_num_pairs; i++) begin
                    ops.teardown_queue(i * 2);      // receiveq
                    ops.teardown_queue(i * 2 + 1);  // transmitq
                end
            end

            // Setup new queues if expanding; a failure tears down every pair
            // created by this expansion before reporting.
            if (num_pairs > active_num_pairs) begin
                ops.setup_queue_range(active_num_pairs, num_pairs - active_num_pairs,
                                      drv_cfg.vq_type, drv_cfg.queue_size, setup_ok);
                if (!setup_ok) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "configure_mq: failed to setup queue pairs %0d..%0d",
                        active_num_pairs, num_pairs - 1))
                    return;
                end
            end

            active_num_pairs = num_pairs;
            num_total_queues = ops.vq_mgr.get_queue_count();
        end else begin
            `uvm_error("AUTO_FSM",
                $sformatf("configure_mq: device rejected MQ change to %0d pairs", num_pairs))
        end
    endtask

    // ------------------------------------------------------------------------
    // configure_rss -- Update RSS configuration via control VQ
    // ------------------------------------------------------------------------
    virtual task configure_rss(virtio_rss_config_t cfg);
        bit success;

        `uvm_info("AUTO_FSM", "configure_rss: updating RSS configuration", UVM_MEDIUM)
        ops.ctrl_set_rss(cfg, success);

        if (!success) begin
            `uvm_error("AUTO_FSM", "configure_rss: device rejected RSS configuration")
        end
    endtask

    // ========================================================================
    // Migration
    // ========================================================================

    // ------------------------------------------------------------------------
    // freeze_for_migration -- FSM_RUNNING -> FSM_SUSPENDING -> FSM_FROZEN
    //
    // Stops the data plane and snapshots all device state.
    // ------------------------------------------------------------------------
    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);
        bit capture_ok;

        if ((ops != null) && (ops.protocol != null) && !ops.protocol.supports_migration()) begin
            `uvm_error("AUTO_FSM", "freeze_for_migration: driver protocol does not support migration")
            return;
        end
        `uvm_info("AUTO_FSM", "freeze_for_migration: starting freeze", UVM_LOW)

        if ((ops == null) || (ops.iommu == null) || (ops.mem == null) ||
            (ops.transport == null)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: missing IOMMU or host-memory context")
            return;
        end

        // 1. Enable a new generation before requesting dataplane quiesce.
        // Any in-flight device write observed while workers drain belongs to
        // this snapshot, and no older dirty bitmap can leak into it.
        snap.dirty_generation =
            ops.iommu.begin_dirty_generation_for_host(iommu_host_id());

        // 2. Stop data plane
        if (state == FSM_RUNNING) begin
            state = FSM_SUSPENDING;
            stop_dataplane();
            // Override state since stop_dataplane sets FSM_READY
            state = FSM_SUSPENDING;
        end

        // 3-6. 特性/状态/设备配置/队列/普通 DMA 所有权/脏页/完整映射采集与整体校验和。
        migration.capture_snapshot(ops, iommu_host_id(), active_num_pairs,
                                   num_total_queues, capture_ok, snap);
        if (!capture_ok) begin
            state = FSM_ERROR;
            return;
        end

        state = FSM_FROZEN;

        `uvm_info("AUTO_FSM",
            $sformatf("freeze_for_migration: frozen, %0d queues, %0d dirty pages, and %0d live mappings saved",
                      num_total_queues, snap.dirty_pages.size(),
                      snap.mapping_records.size()), UVM_LOW)
    endtask

    // ------------------------------------------------------------------------
    // restore_from_migration -- FSM_IDLE -> FSM_FROZEN -> FSM_READY -> FSM_RUNNING
    //
    // Restores device state from a snapshot and restarts data plane.
    // ------------------------------------------------------------------------
    task restore_from_migration(virtio_device_snapshot_t snap,
                                output bit ok);
        ok = 0;
        if ((ops != null) && (ops.protocol != null) && !ops.protocol.supports_migration()) begin
            `uvm_error("AUTO_FSM", "restore_from_migration: driver protocol does not support migration")
            return;
        end
        if ($isunknown(snap.num_queue_pairs) ||
            (snap.num_queue_pairs == 0) ||
            (snap.num_queue_pairs > max_vio_net_qpairs_per_device)) begin
            `uvm_error("AUTO_FSM", $sformatf(
                {"restore_from_migration: snapshot queue-pair count %0d is ",
                 "outside supported range 1..%0d"},
                snap.num_queue_pairs,
                max_vio_net_qpairs_per_device))
            return;
        end
        do_restore_from_migration(snap, ok);
    endtask

    // restore_from_migration 的实现体：先做全部前置校验（依赖组件齐全、
    // snapshot 整体校验和、队列数/各队列 snapshot 合法性、普通与队列 DMA
    // 记录、脏页记录），任一失败即 FSM_ERROR + set_failed 并保持 ok=0；
    // 校验通过后才复位设备、回放映射与脏页、重建队列并重启数据面。
    // 输出 ok=1 仅当完整恢复成功。
    protected virtual task do_restore_from_migration(
        virtio_device_snapshot_t snap,
        output bit ok
    );
        bit set_failed_required;
        bit step_ok;
        virtio_migration_engine::migration_record_group_t mapping_groups[$];

        ok = 0;

        `uvm_info("AUTO_FSM", "restore_from_migration: starting restore", UVM_LOW)

        state = FSM_FROZEN;

        // Verify all saved backing pages before reset, queue reconstruction,
        // or dataplane restart.  Keeping the pre-freeze mapping alive here
        // lets migration reject unmap/remap changes deterministically.
        if ((ops == null) || (ops.iommu == null) || (ops.mem == null) ||
            (ops.transport == null) || (ops.vq_mgr == null)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: incomplete transport, queue, IOMMU, or host-memory context")
            return;
        end
        if (!migration.validate_restore_snapshot(ops, iommu_host_id(),
                                                 drv_cfg.queue_size, snap,
                                                 set_failed_required)) begin
            state = FSM_ERROR;
            if (set_failed_required)
                ops.set_failed();
            return;
        end
        migration.collect_dirty_fallback_groups(snap, mapping_groups);

        // 1-3. 验证式复位、恢复原特性字、按固定 IOVA 重建映射与普通 DMA 所有权。
        migration.restore_device_and_dma(ops, snap, mapping_groups, step_ok);
        if (!step_ok) begin
            state = FSM_ERROR;
            return;
        end

        // 4. MSI-X：与 full_init 相同，先按将要恢复的队列分配并绑定向量，
        // 恢复的队列在 queue_enable 之前写入最终向量（virtio 1.2 §4.1.4.3.2）。
        active_num_pairs = snap.num_queue_pairs;
        num_total_queues = snap.queue_count;
        ops.setup_msix(num_total_queues);

        // 5. 按快照拓扑重建队列并覆盖 ring 状态。
        migration.restore_queues(ops, snap, drv_cfg, step_ok);
        if (!step_ok) begin
            state = FSM_ERROR;
            return;
        end

        // 6. DRIVER_OK
        ops.set_driver_ok();
        state = FSM_READY;

        // 7. Restart data plane
        start_dataplane();
        if (state != FSM_RUNNING) begin
            migration.rollback(ops);
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: data plane did not restart")
            ops.set_failed();
            return;
        end

        ok = 1;

        `uvm_info("AUTO_FSM", "restore_from_migration: restore complete, data plane running", UVM_LOW)
    endtask

    // ========================================================================
    // Error Recovery
    // ========================================================================

    protected task complete_device_recovery();
        state = FSM_RECOVERING;

        // Full device reset and re-initialization happens only after the
        // dataplane worker set has acknowledged its exit.
        ops.device_reset();

        state = FSM_IDLE;
        full_init();

        if (state == FSM_READY)
            start_dataplane();
    endtask

    // 后台恢复监督者：阻塞等待本代全部 dataplane worker 退出后，若恢复
    // 请求仍属于该 epoch（未被换代/取消），清请求标志、置 FSM_ERROR 并执行
    // 完整设备恢复（复位 + full_init + 重启数据面）。
    // 之所以等 worker 全退，是避免复位与在途 DMA 并发。
    protected task dataplane_recovery_supervisor(int unsigned worker_epoch);
        wait (dataplane_workers_stopped_epoch == worker_epoch);
        if (recovery_requested_epoch != worker_epoch)
            return;

        recovery_requested_epoch = 0;
        `uvm_info("AUTO_FSM",
            "dataplane recovery supervisor: all workers stopped", UVM_LOW)
        state = FSM_ERROR;
        complete_device_recovery();
    endtask

    // ------------------------------------------------------------------------
    // handle_device_needs_reset -- Full device recovery cycle
    //
    // FSM_RUNNING -> FSM_ERROR -> FSM_RECOVERING -> full_init -> start_dataplane
    // ------------------------------------------------------------------------
    virtual task handle_device_needs_reset();
        `uvm_info("AUTO_FSM", "handle_device_needs_reset: starting recovery", UVM_LOW)

        state = FSM_ERROR;

        if (dataplane_running)
            stop_dataplane();

        complete_device_recovery();

        `uvm_info("AUTO_FSM",
            $sformatf("handle_device_needs_reset: recovery complete, state=%s", state.name()),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------------------
    // reset_single_queue -- Reset and re-setup a single queue
    //
    // 先停后台 worker（它们会轮询被拆除的队列），teardown 未确认停 DMA 时保留队列并
    // 进入 FSM_ERROR；重建成功后 RX 队列补 buffer，原先运行的数据面重新启动。
    // ------------------------------------------------------------------------
    virtual task reset_single_queue(int unsigned queue_id);
        bit setup_ok;
        bit was_running;
        `uvm_info("AUTO_FSM",
            $sformatf("reset_single_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        was_running = (state == FSM_RUNNING);
        if (was_running)
            stop_dataplane();

        ops.teardown_queue(queue_id);
        if (ops.vq_mgr.has_queue(queue_id)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", $sformatf(
                "reset_single_queue: queue %0d was not stopped; retaining it", queue_id))
            return;
        end

        // 经配置后端复位（标准：Q_RESET；私有：teardown 已完成停队）
        ops.reset_queue(queue_id);

        ops.setup_queue(queue_id, drv_cfg.queue_size, queue_format(), setup_ok);
        if (!setup_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", $sformatf(
                "reset_single_queue: failed to setup queue %0d", queue_id))
            return;
        end

        // If this is a receive queue (even-numbered), refill RX buffers
        if (queue_id % 2 == 0 && queue_id < active_num_pairs * 2) begin
            ops.rx_refill(queue_id, drv_cfg.queue_size);
        end

        if (was_running)
            start_dataplane();

        `uvm_info("AUTO_FSM",
            $sformatf("reset_single_queue: queue_id=%0d complete", queue_id), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Background Tasks
    //
    // ALL background tasks must:
    //   - Loop with dataplane_worker_may_run(worker_epoch)
    //   - Use named fork blocks for internal waits
    //   - Check the run epoch after every wait and shared operation
    //   - Exit gracefully on stop_event
    // ========================================================================

    // ------------------------------------------------------------------------
    // rx_refill_loop -- Periodically refill RX buffers for a queue
    // ------------------------------------------------------------------------
    protected virtual task rx_refill_loop(
        int unsigned queue_id, int unsigned worker_epoch
    );
        int unsigned interval;
        int unsigned threshold;

        interval  = ops.wait_pol.default_poll_interval_ns;
        threshold = drv_cfg.rx_refill_threshold;
        if (threshold == 0)
            threshold = drv_cfg.queue_size / 4;

        `uvm_info("AUTO_FSM",
            $sformatf("rx_refill_loop: queue_id=%0d started, threshold=%0d",
                      queue_id, threshold), UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            virtqueue_base vq;

            // Wait for event or poll interval (named fork)
            fork : rx_refill_wait_blk
                begin : rx_refill_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : rx_refill_timeout_arm
                    #(interval * 1ns);
                end
                begin : rx_refill_stop_arm
                    @stop_event;
                end
            join_any
            disable rx_refill_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Check if refill is needed
            vq = ops.vq_mgr.get_queue(queue_id);
            if (vq != null) begin
                int unsigned free_count = vq.get_free_count();
                if (free_count >= threshold) begin
                    ops.rx_refill(queue_id, free_count);
                end
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("rx_refill_loop: queue_id=%0d exiting", queue_id), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // tx_complete_loop -- Periodically poll for TX completions
    // ------------------------------------------------------------------------
    protected virtual task tx_complete_loop(
        int unsigned queue_id, int unsigned worker_epoch
    );
        int unsigned interval;
        int unsigned budget;

        interval = ops.wait_pol.default_poll_interval_ns;
        budget   = drv_cfg.napi_budget;
        if (budget == 0)
            budget = 64;

        `uvm_info("AUTO_FSM",
            $sformatf("tx_complete_loop: queue_id=%0d started, budget=%0d",
                      queue_id, budget), UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            uvm_object completed[$];

            // Wait for event or poll interval (named fork)
            fork : tx_complete_wait_blk
                begin : tx_complete_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : tx_complete_timeout_arm
                    #(interval * 1ns);
                end
                begin : tx_complete_stop_arm
                    @stop_event;
                end
            join_any
            disable tx_complete_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            ops.tx_complete(queue_id, completed, budget);

            if (completed.size() > 0) begin
                packet_completed_event.trigger();
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("tx_complete_loop: queue_id=%0d exiting", queue_id), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // interrupt_handler_loop -- Dispatch incoming interrupts
    // ------------------------------------------------------------------------
    protected virtual task interrupt_handler_loop(int unsigned worker_epoch);
        int unsigned interval;

        interval = ops.wait_pol.default_poll_interval_ns;

        `uvm_info("AUTO_FSM", "interrupt_handler_loop: started", UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            // Wait for interrupt event or poll interval (named fork)
            fork : irq_handler_wait_blk
                begin : irq_handler_evt_arm
                    interrupt_event.wait_trigger();
                end
                begin : irq_handler_timeout_arm
                    #(interval * 1ns);
                end
                begin : irq_handler_stop_arm
                    @stop_event;
                end
            join_any
            disable irq_handler_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Signal that used ring may have new entries
            used_ring_updated_event.trigger();
        end

        `uvm_info("AUTO_FSM", "interrupt_handler_loop: exiting", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // adaptive_irq_loop -- Switch between MSI-X and polling based on rate
    //
    // Monitors packet completion rate over a window. If rate exceeds a
    // threshold, switches to polling mode. If rate drops, switches back
    // to interrupt-driven mode.
    // ------------------------------------------------------------------------
    protected virtual task adaptive_irq_loop(int unsigned worker_epoch);
        int unsigned interval;
        int unsigned pkt_count_window = 0;
        int unsigned high_rate_threshold;
        int unsigned low_rate_threshold;
        bit          currently_polling = 0;

        interval = ops.wait_pol.default_poll_interval_ns * 10;  // Longer measurement window
        high_rate_threshold = drv_cfg.coal_max_packets;
        if (high_rate_threshold == 0)
            high_rate_threshold = 256;
        low_rate_threshold = high_rate_threshold / 4;

        `uvm_info("AUTO_FSM", "adaptive_irq_loop: started", UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            pkt_count_window = 0;

            // Count packet completions over one measurement window (named fork)
            fork : adaptive_irq_wait_blk
                begin : adaptive_irq_evt_arm
                    while (dataplane_worker_may_run(worker_epoch)) begin
                        packet_completed_event.wait_trigger();
                        pkt_count_window++;
                    end
                end
                begin : adaptive_irq_timeout_arm
                    #(interval * 1ns);
                end
                begin : adaptive_irq_stop_arm
                    @stop_event;
                end
            join_any
            disable adaptive_irq_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Evaluate rate and switch mode if needed
            if (!currently_polling && pkt_count_window > high_rate_threshold) begin
                // High rate: switch to polling
                currently_polling = 1;
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    virtqueue_base vq;
                    vq = ops.vq_mgr.get_queue(i * 2);
                    if (vq != null) vq.disable_cb();
                    vq = ops.vq_mgr.get_queue(i * 2 + 1);
                    if (vq != null) vq.disable_cb();
                end
                `uvm_info("AUTO_FSM",
                    $sformatf("adaptive_irq: switching to POLLING (rate=%0d > %0d)",
                              pkt_count_window, high_rate_threshold), UVM_MEDIUM)
            end else if (currently_polling && pkt_count_window < low_rate_threshold) begin
                // Low rate: switch back to MSI-X interrupts
                currently_polling = 0;
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    virtqueue_base vq;
                    vq = ops.vq_mgr.get_queue(i * 2);
                    if (vq != null) vq.enable_cb();
                    vq = ops.vq_mgr.get_queue(i * 2 + 1);
                    if (vq != null) vq.enable_cb();
                end
                `uvm_info("AUTO_FSM",
                    $sformatf("adaptive_irq: switching to MSI-X (rate=%0d < %0d)",
                              pkt_count_window, low_rate_threshold), UVM_MEDIUM)
            end
        end

        `uvm_info("AUTO_FSM", "adaptive_irq_loop: exiting", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // config_change_handler -- Monitor device configuration changes
    //
    // Periodically checks for device config changes (link status,
    // GUEST_ANNOUNCE, DEVICE_NEEDS_RESET).
    // ------------------------------------------------------------------------
    protected virtual task config_change_handler(int unsigned worker_epoch);
        int unsigned interval;

        interval = ops.wait_pol.default_poll_interval_ns * 5;

        `uvm_info("AUTO_FSM", "config_change_handler: started", UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            // Wait for config change event or poll interval (named fork)
            fork : cfg_change_wait_blk
                begin : cfg_change_evt_arm
                    config_change_event.wait_trigger();
                end
                begin : cfg_change_timeout_arm
                    #(interval * 1ns);
                end
                begin : cfg_change_stop_arm
                    @stop_event;
                end
            join_any
            disable cfg_change_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Re-read device configuration and handle changes
            begin
                virtio_net_device_config_t cfg;
                ops.read_net_config(cfg);

                // Check link status if STATUS feature is negotiated
                if (ops.negotiated_features[VIRTIO_NET_F_STATUS]) begin
                    if (cfg.status & 16'h0001) begin
                        `uvm_info("AUTO_FSM",
                            "config_change_handler: link is UP", UVM_MEDIUM)
                    end else begin
                        `uvm_info("AUTO_FSM",
                            "config_change_handler: link is DOWN", UVM_MEDIUM)
                    end
                end

                // Check GUEST_ANNOUNCE request
                if (ops.negotiated_features[VIRTIO_NET_F_GUEST_ANNOUNCE]) begin
                    if (cfg.status & 16'h0002) begin
                        bit announce_ok;
                        ops.ctrl_announce_ack(announce_ok);
                        `uvm_info("AUTO_FSM",
                            $sformatf("config_change_handler: guest announce ack=%0b",
                                      announce_ok), UVM_MEDIUM)
                    end
                end

                // Check DEVICE_NEEDS_RESET
                begin
                    bit [7:0] dev_status;
                    ops.read_device_status(dev_status);
                    if (dev_status & DEV_STATUS_DEVICE_NEEDS_RESET) begin
                        `uvm_warning("AUTO_FSM",
                            "config_change_handler: DEVICE_NEEDS_RESET detected")
                        recovery_requested_epoch = worker_epoch;
                        request_dataplane_stop(worker_epoch);
                        return;
                    end
                end
            end
        end

        `uvm_info("AUTO_FSM", "config_change_handler: exiting", UVM_HIGH)
    endtask

endclass : virtio_auto_fsm

`endif // VIRTIO_AUTO_FSM_SV
