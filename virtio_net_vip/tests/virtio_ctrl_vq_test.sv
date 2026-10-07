`ifndef VIRTIO_CTRL_VQ_TEST_SV
`define VIRTIO_CTRL_VQ_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// 目录层次：tests/。control VQ 编号与 ctrl_send 资源回滚的聚焦回归。不建 PCIe 通路，
// 寄存器桩 transport 只记录建队与通知；建队、DMA 映射与回滚全部走生产 atomic ops。
// 测试拥有全部 Host memory/IOMMU/队列对象，每个子测试结束时拆除并检查泄漏。

// 设备接受 MQ 变更：只替换 control 命令往返，建队/拆队仍走生产实现。
class virtio_ctrl_vq_test_mq_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_ctrl_vq_test_mq_ops)

    int unsigned mq_requests[$];

    function new(string name = "virtio_ctrl_vq_test_mq_ops");
        super.new(name);
    endfunction

    virtual task ctrl_set_mq_pairs(int unsigned num_pairs, ref bit success);
        mq_requests.push_back(num_pairs);
        success = 1;
    endtask
endclass : virtio_ctrl_vq_test_mq_ops

// 只为断言暴露受保护的分配表，不改变分配行为。
class virtio_ctrl_vq_test_mem extends host_mem_manager;
    `uvm_object_utils(virtio_ctrl_vq_test_mem)

    function new(string name = "virtio_ctrl_vq_test_mem");
        super.new(name);
    endfunction

    function int unsigned outstanding_allocations();
        return alloc_table.size();
    endfunction
endclass : virtio_ctrl_vq_test_mem

// fail_map_after=N（N>0）时第 N 次及之后的映射返回 '1，模拟 IOVA 耗尽；0 表示不注入。
class virtio_ctrl_vq_test_iommu extends virtio_iommu_model;
    `uvm_object_utils(virtio_ctrl_vq_test_iommu)

    int unsigned fail_map_after;
    int unsigned map_calls;

    function new(string name = "virtio_ctrl_vq_test_iommu");
        super.new(name);
        fail_map_after = 0;
        map_calls = 0;
    endfunction

    virtual function bit [63:0] map_for_host(int unsigned host_id,
                                             bit [15:0] bdf,
                                             bit [63:0] gpa,
                                             int unsigned size,
                                             dma_dir_e dir,
                                             string file = "",
                                             int line = 0);
        map_calls++;
        if ((fail_map_after != 0) && (map_calls >= fail_map_after))
            return '1;
        return super.map_for_host(host_id, bdf, gpa, size, dir, file, line);
    endfunction

    function int unsigned active_mapping_count();
        return mapping_table.size();
    endfunction
endclass : virtio_ctrl_vq_test_iommu

// 只吞掉登记过的 (id, 消息模式) UVM_ERROR，其余错误照常失败。
class virtio_ctrl_vq_test_catcher extends uvm_report_catcher;
    string       expected_ids[$];
    string       expected_msgs[$];
    int unsigned caught_count;

    function new(string name = "virtio_ctrl_vq_test_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    function void expect_error(string id, string msg_pattern);
        expected_ids.push_back(id);
        expected_msgs.push_back(msg_pattern);
    endfunction

    virtual function action_e catch();
        if (get_severity() != UVM_ERROR)
            return THROW;
        foreach (expected_ids[i]) begin
            if ((get_id() == expected_ids[i]) &&
                uvm_is_match(expected_msgs[i], get_message())) begin
                caught_count++;
                return CAUGHT;
            end
        end
        return THROW;
    endfunction
endclass : virtio_ctrl_vq_test_catcher

// MSI-X 表写入桩：只吞掉表项 MMIO，不需要 PCIe 通路；向量分配仍走生产 notification manager。
class virtio_ctrl_vq_test_null_bar extends virtio_bar_accessor;
    `uvm_object_utils(virtio_ctrl_vq_test_null_bar)

    function new(string name = "virtio_ctrl_vq_test_null_bar");
        super.new(name);
    endfunction

    virtual task write_msix_reg(int unsigned bar_id, bit [31:0] offset,
                                int unsigned size, bit [31:0] data);
    endtask
endclass : virtio_ctrl_vq_test_null_bar

// 迁移/MSI-X 用寄存器桩：status/复位/特性协商/队列编程/向量绑定在本地建模并记录；
// max_virtqueue_pairs 可编程，使 control VQ 位于 2*max_virtqueue_pairs（与数据队列不连续）。
class virtio_ctrl_vq_migration_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_ctrl_vq_migration_transport)

    int unsigned max_virtqueue_pairs;
    bit [7:0]    device_status;
    int unsigned programmed_qids[$];
    int unsigned msix_bound_qids[$];
    int unsigned msix_bound_vectors[int unsigned];

    function new(string name = "virtio_ctrl_vq_migration_transport");
        virtio_ctrl_vq_test_null_bar null_bar;
        super.new(name);
        max_virtqueue_pairs = 1;
        device_status = 0;
        null_bar = virtio_ctrl_vq_test_null_bar::type_id::create("ctrl_vq_null_bar");
        bar = null_bar;
        notify_mgr.bar = null_bar;
        cap_mgr.bar_ref = null_bar;
    endfunction

    virtual task read_device_status(ref bit [7:0] status);
        status = device_status;
    endtask

    virtual task write_device_status(bit [7:0] status);
        device_status = status;
    endtask

    virtual task reset_device_verified(ref bit reset_complete);
        device_status = 0;
        reset_complete = 1;
    endtask

    virtual task negotiate_features(bit [63:0] driver_supported,
                                    ref bit [63:0] negotiated);
        negotiated = driver_supported;
        driver_features = negotiated;
    endtask

    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        cfg = '{default: 0};
        cfg.max_virtqueue_pairs = max_virtqueue_pairs;
    endtask

    virtual task select_queue(int unsigned queue_id);
    endtask

    virtual task read_queue_num_max(ref int unsigned max_size);
        max_size = 8;
    endtask

    virtual task setup_single_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        bit [63:0]   desc_addr,
        bit [63:0]   driver_addr,
        bit [63:0]   device_addr,
        int unsigned msix_vector
    );
        programmed_qids.push_back(queue_id);
    endtask

    virtual task write_queue_enable(bit enable);
    endtask

    virtual task write_config_msix_vector(int unsigned vector);
    endtask

    virtual task write_queue_msix_vector(int unsigned queue_id, int unsigned vector);
        msix_bound_qids.push_back(queue_id);
        msix_bound_vectors[queue_id] = vector;
    endtask

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
    endtask
endclass : virtio_ctrl_vq_migration_transport

// 数据面启停只切换状态；迁移采集/恢复全部走生产 FSM 与迁移引擎。
class virtio_ctrl_vq_test_migration_fsm extends virtio_auto_fsm;
    `uvm_object_utils(virtio_ctrl_vq_test_migration_fsm)

    function new(string name = "virtio_ctrl_vq_test_migration_fsm");
        super.new(name);
    endfunction

    function void set_topology(int unsigned num_pairs, int unsigned num_queues);
        active_num_pairs = num_pairs;
        num_total_queues = num_queues;
    endfunction

    virtual task stop_dataplane();
        state = FSM_READY;
    endtask

    virtual task start_dataplane();
        state = FSM_RUNNING;
    endtask
endclass : virtio_ctrl_vq_test_migration_fsm

class virtio_ctrl_vq_test extends uvm_test;
    `uvm_component_utils(virtio_ctrl_vq_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_ctrl_vq_at_twice_max_pairs();
        test_ctrl_send_alloc_failure_rolls_back();
        test_ctrl_send_map_failure_rolls_back();
        test_ctrl_vq_outside_data_range_migration_and_msix();
        `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // 一个 Function 的最小装配：ring 内存给 vq_mgr，ops_mem 给 ops 的数据/控制缓冲。
    protected function void wire_ops(
        virtio_atomic_ops             ops,
        virtio_mock_transport transport,
        virtqueue_manager             vq_mgr,
        host_mem_manager              ring_mem,
        host_mem_manager              ops_mem,
        virtio_iommu_model            iommu,
        bit [15:0]                    bdf
    );
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("ctrl_vq_barrier");
        virtqueue_error_injector err_inj =
            virtqueue_error_injector::type_id::create("ctrl_vq_err_inj");
        virtio_wait_policy wait_pol =
            virtio_wait_policy::type_id::create("ctrl_vq_wait_pol");

        vq_mgr.mem = ring_mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = bdf;
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(bdf));
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = ops_mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
    endfunction

    // 设备 max_virtqueue_pairs=2、当前 1 对：control VQ 必须是 4，扩到 2 对时
    // 新建的 RX1/TX1（2/3）不得与 control VQ 冲突。
    task test_ctrl_vq_at_twice_max_pairs();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("mq_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("mq_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("mq_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("mq_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("mq_iommu");
        virtio_auto_fsm fsm = virtio_auto_fsm::type_id::create("mq_fsm");
        int unsigned expected_qids[$];
        bit ok;
        string why;

        mem.init_region(64'h7000_0000, 64'h7000_FFFF);
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h0901);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;

        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        assert(ok && vq_mgr.has_queue(4) &&
               !vq_mgr.has_queue(2) &&
               (vq_mgr.get_queue_count() == 3) &&
               (transport.net_config_reads == 1))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "control VQ must be queue 2*max_virtqueue_pairs=4 (ok=%0b q2=%0b q4=%0b count=%0d net_config_reads=%0d)",
                ok, vq_mgr.has_queue(2), vq_mgr.has_queue(4),
                vq_mgr.get_queue_count(), transport.net_config_reads))

        fsm.ops = ops;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        assert(fsm.bind_mq_pair_limit(2, why))
            else `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.configure_mq(2);
        expected_qids = '{0, 1, 4, 2, 3};
        assert((fsm.state != FSM_ERROR) && (ops.mq_requests.size() == 1) &&
               (ops.mq_requests[0] == 2) && (vq_mgr.get_queue_count() == 5) &&
               (transport.programmed_qids == expected_qids))
            else `uvm_fatal("CTRL_VQ_TEST",
                "MQ expansion 1->2 collided with the control VQ")

        foreach (expected_qids[i])
            ops.teardown_queue(expected_qids[i]);
        assert((vq_mgr.get_queue_count() == 0) &&
               (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", "control VQ layout test leaked queue resources")
        mem.leak_check();

        `uvm_info("CTRL_VQ_TEST", "control VQ at 2*max_virtqueue_pairs test PASSED", UVM_LOW)
    endtask

    // ops 内存只有一个 16B 最小块：header 占用后 ack 申请失败。ctrl_send 必须释放
    // header，不映射、不入队、不通知，并以 ACK_ERR 返回。
    task test_ctrl_send_alloc_failure_rolls_back();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("alloc_fail_transport");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("alloc_fail_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("alloc_fail_vq_mgr");
        virtio_ctrl_vq_test_mem ring_mem =
            virtio_ctrl_vq_test_mem::type_id::create("alloc_fail_ring_mem");
        virtio_ctrl_vq_test_mem ctrl_mem =
            virtio_ctrl_vq_test_mem::type_id::create("alloc_fail_ctrl_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("alloc_fail_iommu");
        virtio_ctrl_vq_test_catcher catcher;
        virtqueue_base ctrl_vq;
        virtio_ctrl_ack_e ack;
        byte unsigned data[];
        int unsigned maps_before;
        bit ok;

        ring_mem.init_region(64'h7100_0000, 64'h7100_FFFF);
        ctrl_mem.init_region(64'h7200_0000, 64'h7200_000F);
        wire_ops(ops, transport, vq_mgr, ring_mem, ctrl_mem, iommu, 16'h0902);
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.setup_queue(2, 8, VQ_SPLIT, ok);
        assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")
        ctrl_vq = vq_mgr.get_queue(2);
        maps_before = iommu.active_mapping_count();

        data = new[2];
        data[0] = 8'h01;
        data[1] = 8'h00;
        ack = VIRTIO_NET_CTRL_ACK_OK;
        catcher = new("alloc_fail_catcher");
        catcher.expect_error("HOST_MEM", "*alloc: insufficient space*");
        catcher.expect_error("ATOMIC_OPS", "*ctrl_send: host_mem alloc failed*");
        uvm_report_cb::add(null, catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      data, ack);
        uvm_report_cb::delete(null, catcher);
        assert((ack == VIRTIO_NET_CTRL_ACK_ERR) && (catcher.caught_count == 2) &&
               (ctrl_mem.outstanding_allocations() == 0) &&
               (iommu.active_mapping_count() == maps_before) &&
               (transport.kick_count == 0) && (ctrl_vq.get_free_count() == 8))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "ctrl_send ack-allocation failure leaked resources or notified the device (ack=%s caught=%0d allocs=%0d maps=%0d/%0d kicks=%0d free=%0d)",
                ack.name(), catcher.caught_count, ctrl_mem.outstanding_allocations(),
                iommu.active_mapping_count(), maps_before, transport.kick_count,
                ctrl_vq.get_free_count()))

        ops.teardown_queue(2);
        assert((iommu.active_mapping_count() == 0) &&
               (ring_mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", "alloc-failure test leaked control queue resources")
        ring_mem.leak_check();
        ctrl_mem.leak_check();
        `uvm_info("CTRL_VQ_TEST", "ctrl_send allocation-failure rollback test PASSED", UVM_LOW)
    endtask

    // header 映射成功、data 映射失败：ctrl_send 必须撤销 header 映射并释放三块缓冲。
    task test_ctrl_send_map_failure_rolls_back();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("map_fail_transport");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("map_fail_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("map_fail_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("map_fail_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("map_fail_iommu");
        virtio_ctrl_vq_test_catcher catcher;
        virtqueue_base ctrl_vq;
        virtio_ctrl_ack_e ack;
        byte unsigned data[];
        int unsigned maps_before;
        int unsigned allocs_before;
        bit ok;

        mem.init_region(64'h7300_0000, 64'h7300_FFFF);
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h0903);
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.setup_queue(2, 8, VQ_SPLIT, ok);
        assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")
        ctrl_vq = vq_mgr.get_queue(2);
        maps_before = iommu.active_mapping_count();
        allocs_before = mem.outstanding_allocations();

        data = new[2];
        data[0] = 8'h01;
        data[1] = 8'h00;
        ack = VIRTIO_NET_CTRL_ACK_OK;
        iommu.map_calls = 0;
        iommu.fail_map_after = 2;
        catcher = new("map_fail_catcher");
        catcher.expect_error("ATOMIC_OPS", "*ctrl_send: failed to map control buffers*");
        uvm_report_cb::add(null, catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      data, ack);
        uvm_report_cb::delete(null, catcher);
        iommu.fail_map_after = 0;
        assert((ack == VIRTIO_NET_CTRL_ACK_ERR) && (catcher.caught_count == 1) &&
               (mem.outstanding_allocations() == allocs_before) &&
               (iommu.active_mapping_count() == maps_before) &&
               (transport.kick_count == 0) && (ctrl_vq.get_free_count() == 8))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "ctrl_send map failure leaked resources or notified the device (ack=%s caught=%0d allocs=%0d/%0d maps=%0d/%0d kicks=%0d free=%0d)",
                ack.name(), catcher.caught_count, mem.outstanding_allocations(),
                allocs_before, iommu.active_mapping_count(), maps_before,
                transport.kick_count, ctrl_vq.get_free_count()))

        ops.teardown_queue(2);
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", "map-failure test leaked control queue resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST", "ctrl_send map-failure rollback test PASSED", UVM_LOW)
    endtask

    // 设备 max_virtqueue_pairs=4、当前 1 对 + CTRL_VQ：队列为 {0,1,8}。MSI-X 必须给
    // control VQ 8 绑定向量（不得写不存在的队列 2）；freeze 必须保存队列 8，restore
    // 必须按实际队列号重建并覆盖，全过程不泄漏 ring/DMA。
    task test_ctrl_vq_outside_data_range_migration_and_msix();
        virtio_ctrl_vq_migration_transport transport =
            virtio_ctrl_vq_migration_transport::type_id::create("gap_transport");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("gap_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("gap_vq_mgr");
        virtio_ctrl_vq_test_mem mem = virtio_ctrl_vq_test_mem::type_id::create("gap_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("gap_iommu");
        virtio_ctrl_vq_test_migration_fsm fsm =
            virtio_ctrl_vq_test_migration_fsm::type_id::create("gap_fsm");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("gap_barrier");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("gap_wait_pol");
        virtio_device_snapshot_t snapshot;
        int unsigned expected_qids[$];
        int unsigned snapshot_qids[$];
        int unsigned restored_qids[$];
        bit ok;
        bit restore_ok;

        mem.init_region(64'h7100_0000, 64'h7100_FFFF);
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = 16'h0902;
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0902));
        transport.max_virtqueue_pairs = 4;
        transport.cap_mgr.msix_found = 1;
        transport.cap_mgr.msix_table_size = 8;
        transport.cap_mgr.msix_table_bir = 4;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        expected_qids = '{0, 1, 8};

        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 3) || (vq_mgr.get_queue(8) == null))
            `uvm_fatal("CTRL_VQ_TEST", "setup did not place the control VQ at 2*max_virtqueue_pairs=8")

        // MSI-X：每条实际队列一个向量，control VQ 8 必须绑定，不得写队列 2。
        ops.setup_msix(3);
        if ((transport.msix_bound_qids != expected_qids) ||
            (transport.notify_mgr.queue_vectors.size() <= 8) ||
            (transport.notify_mgr.queue_vectors[8] != transport.msix_bound_vectors[8]) ||
            (transport.msix_bound_vectors[8] == 0) ||
            (transport.msix_bound_vectors[8] == transport.msix_bound_vectors[1]) ||
            (transport.notify_mgr.queue_vectors[2] != 32'hFFFF))
            `uvm_error("CTRL_VQ_TEST", $sformatf(
                "MSI-X vectors were not bound to the actual queue set: bound=%p vectors=%p",
                transport.msix_bound_qids, transport.notify_mgr.queue_vectors))

        // freeze：快照按实际队列号保存 control VQ 8。
        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        fsm.set_topology(1, 3);
        fsm.state = FSM_RUNNING;
        fsm.freeze_for_migration(snapshot);
        foreach (snapshot.queue_snapshots[i])
            snapshot_qids.push_back(snapshot.queue_snapshots[i].queue_id);
        if ((fsm.state != FSM_FROZEN) || (snapshot.queue_count != 3) ||
            (snapshot_qids != expected_qids) ||
            (snapshot.queue_snapshots[2].queue_size != 8))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "freeze did not capture the control VQ outside 0..2N-1: state=%s ids=%p",
                fsm.state.name(), snapshot_qids))

        // restore：复位后按快照重建 {0,1,8}，覆盖状态并重新绑定向量。
        ops.device_reset();
        if (vq_mgr.get_queue_count() != 0)
            `uvm_fatal("CTRL_VQ_TEST", "verified reset did not release source queues")
        transport.msix_bound_qids.delete();
        fsm.restore_from_migration(snapshot, restore_ok);
        vq_mgr.get_queue_ids(restored_qids);
        if (!restore_ok || (fsm.state != FSM_RUNNING) ||
            (restored_qids != expected_qids) ||
            (transport.msix_bound_qids != expected_qids))
            `uvm_error("CTRL_VQ_TEST", $sformatf(
                "restore did not rebuild the control VQ outside 0..2N-1: ok=%0b state=%s queues=%p bound=%p",
                restore_ok, fsm.state.name(), restored_qids, transport.msix_bound_qids))

        foreach (expected_qids[i])
            ops.teardown_queue(expected_qids[i]);
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST", "control VQ migration/MSI-X test leaked queue resources")
        mem.leak_check();

        `uvm_info("CTRL_VQ_TEST",
            "control VQ outside data range migration and MSI-X test PASSED", UVM_LOW)
    endtask
endclass : virtio_ctrl_vq_test

`endif // VIRTIO_CTRL_VQ_TEST_SV
