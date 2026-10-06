`ifndef VIRTIO_CTRL_VQ_TEST_SV
`define VIRTIO_CTRL_VQ_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// 目录层次：tests/。control VQ 编号与 ctrl_send 资源回滚的聚焦回归。不建 PCIe 通路，
// 寄存器桩 transport 只记录建队与通知；建队、DMA 映射与回滚全部走生产 atomic ops。
// 测试拥有全部 Host memory/IOMMU/队列对象，每个子测试结束时拆除并检查泄漏。

// 寄存器桩：common-config 访问只记录、不发 TLP；read_net_config 返回可编程的
// max_virtqueue_pairs，用于验证 controlq 按 2*max_virtqueue_pairs 编号。
class virtio_ctrl_vq_test_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_ctrl_vq_test_transport)

    int unsigned max_virtqueue_pairs;
    int unsigned net_config_reads;
    int unsigned kick_count;
    int unsigned programmed_qids[$];

    function new(string name = "virtio_ctrl_vq_test_transport");
        super.new(name);
        max_virtqueue_pairs = 1;
        net_config_reads = 0;
        kick_count = 0;
    endfunction

    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        net_config_reads++;
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

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
        kick_count++;
    endtask
endclass : virtio_ctrl_vq_test_transport

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

class virtio_ctrl_vq_test extends uvm_test;
    `uvm_component_utils(virtio_ctrl_vq_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_ctrl_vq_at_twice_max_pairs();
        `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // 一个 Function 的最小装配：ring 内存给 vq_mgr，ops_mem 给 ops 的数据/控制缓冲。
    protected function void wire_ops(
        virtio_atomic_ops             ops,
        virtio_ctrl_vq_test_transport transport,
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
        transport.bdf = bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = ops_mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
    endfunction

    // 设备 max_virtqueue_pairs=2、当前 1 对：control VQ 必须是 4，扩到 2 对时
    // 新建的 RX1/TX1（2/3）不得与 control VQ 冲突。
    task test_ctrl_vq_at_twice_max_pairs();
        virtio_ctrl_vq_test_transport transport =
            virtio_ctrl_vq_test_transport::type_id::create("mq_transport");
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
        transport.max_virtqueue_pairs = 2;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;

        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        assert(ok && vq_mgr.has_queue(4) &&
               !vq_mgr.has_queue(2) &&
               (vq_mgr.get_queue_count() == 3))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "control VQ must be queue 2*max_virtqueue_pairs=4 (ok=%0b q2=%0b q4=%0b count=%0d)",
                ok, vq_mgr.has_queue(2), vq_mgr.has_queue(4),
                vq_mgr.get_queue_count()))

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
endclass : virtio_ctrl_vq_test

`endif // VIRTIO_CTRL_VQ_TEST_SV
