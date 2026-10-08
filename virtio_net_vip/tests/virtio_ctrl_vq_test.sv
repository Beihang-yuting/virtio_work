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
    bit          accept_mq_requests;
    bit          fail_next_setup_range;

    // 构造可编程 MQ ops 桩；默认接受设备命令且不注入建队失败，无外部资源副作用。
    function new(string name = "virtio_ctrl_vq_test_mq_ops");
        super.new(name);
        accept_mq_requests = 1;
        fail_next_setup_range = 0;
    endfunction

    // 记录 MQ 目标并返回测试指定的设备 ACK；输入为目标队列对数，success 为设备
    // 接受结果。该桩不改队列，后续建拆队仍由生产 atomic ops 完成。
    virtual task ctrl_set_mq_pairs(int unsigned num_pairs, ref bit success);
        mq_requests.push_back(num_pairs);
        success = accept_mq_requests;
    endtask

    // 可注入一次扩容建队失败，用于验证运行态 FSM 失败后保持 worker 停止；未注入时
    // 原样调用生产 setup_queue_range，输出 ok 保留真实建队与回滚结果。
    virtual task setup_queue_range(
        int unsigned     first_pair,
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size,
        output bit       ok
    );
        if (fail_next_setup_range) begin
            fail_next_setup_range = 0;
            ok = 0;
            return;
        end
        super.setup_queue_range(first_pair, num_pairs, vq_type, queue_size, ok);
    endtask
endclass : virtio_ctrl_vq_test_mq_ops

// control VQ 重建失败注入：正常建队仍走生产实现，测试在超时前置位
// fail_next_setup 后，只拒绝下一次 setup_queue。这样可精确覆盖“Q_RESET 已确认、旧队列
// 已销毁，但同编号 control VQ 无法重新建立”的边界，不伪造停队和资源回收结果。
class virtio_ctrl_vq_test_rebuild_fail_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_ctrl_vq_test_rebuild_fail_ops)

    bit          fail_next_setup;
    int unsigned setup_attempts;

    function new(string name = "virtio_ctrl_vq_test_rebuild_fail_ops");
        super.new(name);
        fail_next_setup = 0;
        setup_attempts = 0;
    endfunction

    // 建队探针：输入输出与生产 setup_queue 一致；注入打开时本次返回 ok=0、产生一条
    // 可捕获错误且不创建任何队列，随后自动关闭注入。其余调用完整委托生产实现。
    virtual task setup_queue(
        int unsigned     queue_id,
        int unsigned     queue_size,
        virtqueue_type_e vq_type,
        output bit       ok
    );
        setup_attempts++;
        if (fail_next_setup) begin
            fail_next_setup = 0;
            ok = 0;
            `uvm_error("CTRL_VQ_TEST_INJECT", $sformatf(
                "injected setup failure for control VQ %0d", queue_id))
            return;
        end
        super.setup_queue(queue_id, queue_size, vq_type, ok);
    endtask
endclass : virtio_ctrl_vq_test_rebuild_fail_ops

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

// MSI-X 桩：表项 MMIO 与 Message Control 配置读写都在本地吞掉（读回 0），不需要 PCIe 通路；
// 向量分配仍走生产 notification manager。
class virtio_ctrl_vq_test_null_bar extends virtio_bar_accessor;
    `uvm_object_utils(virtio_ctrl_vq_test_null_bar)

    function new(string name = "virtio_ctrl_vq_test_null_bar");
        super.new(name);
    endfunction

    virtual task write_msix_reg(int unsigned bar_id, bit [31:0] offset,
                                int unsigned size, bit [31:0] data);
    endtask

    virtual task read_msix_reg(int unsigned bar_id, bit [31:0] offset,
                               int unsigned size, ref bit [31:0] data);
        data = '0;
    endtask

    virtual task config_read(bit [11:0] addr, ref bit [31:0] data);
        data = '0;
    endtask

    virtual task config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
    endtask
endclass : virtio_ctrl_vq_test_null_bar

// 迁移/MSI-X 用寄存器桩：status/复位/特性协商/队列编程/向量绑定在本地建模并记录（enable_vectors：
// setup_single_queue 置 Q_ENABLE 时该队列的向量；remapped_after_enable：对已使能队列改写向量的
// 队列号，复位清除使能）；BAR 发现为空操作；
// max_virtqueue_pairs 可编程，使 control VQ 位于 2*max_virtqueue_pairs（与数据队列不连续）。
class virtio_ctrl_vq_migration_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_ctrl_vq_migration_transport)

    int unsigned max_virtqueue_pairs;
    bit [7:0]    device_status;
    int unsigned programmed_qids[$];
    int unsigned msix_bound_qids[$];
    int unsigned msix_bound_vectors[int unsigned];
    int unsigned enable_vectors[int unsigned];
    bit          queue_enabled[int unsigned];
    int unsigned remapped_after_enable[$];

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

    virtual task discover_and_init_bars();
    endtask

    virtual task read_device_status(ref bit [7:0] status);
        status = device_status;
    endtask

    virtual task write_device_status(bit [7:0] status);
        device_status = status;
    endtask

    virtual task reset_device_verified(ref bit reset_complete);
        device_status = 0;
        queue_enabled.delete();
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
        enable_vectors[queue_id] = msix_vector;
        queue_enabled[queue_id] = 1;
    endtask

    virtual task write_queue_enable(bit enable);
    endtask

    virtual task write_config_msix_vector(int unsigned vector);
    endtask

    virtual task write_queue_msix_vector(int unsigned queue_id, int unsigned vector);
        msix_bound_qids.push_back(queue_id);
        msix_bound_vectors[queue_id] = vector;
        if (queue_enabled.exists(queue_id))
            remapped_after_enable.push_back(queue_id);
    endtask

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
    endtask
endclass : virtio_ctrl_vq_migration_transport

// 数据面启停只切换状态；迁移采集/恢复全部走生产 FSM 与迁移引擎。
class virtio_ctrl_vq_test_migration_fsm extends virtio_auto_fsm;
    `uvm_object_utils(virtio_ctrl_vq_test_migration_fsm)

    int unsigned start_count;

    function new(string name = "virtio_ctrl_vq_test_migration_fsm");
        super.new(name);
        start_count = 0;
    endfunction

    function void set_topology(int unsigned num_pairs, int unsigned num_queues);
        active_num_pairs = num_pairs;
        num_total_queues = num_queues;
        // 手工注入的拓扑用于模拟设备已经接受的运行前基线；显式设置提交态，避免
        // 测试依赖构造函数缺省值，也与 migration restore 的未提交阶段清楚区分。
        mq_pairs_committed = 1;
    endfunction

    // 暴露生产自动恢复体供测试驱动；实现仍完整执行基类的 reset/full_init/MQ 提交
    // 顺序，本 wrapper 不改变状态或资源。
    task run_complete_device_recovery();
        complete_device_recovery();
    endtask

    // 返回 FSM 维护的队列诊断计数，用于断言迁移回滚成功后已经记录空拓扑。
    function int unsigned tracked_total_queue_count();
        return num_total_queues;
    endfunction

    virtual task stop_dataplane();
        state = FSM_READY;
    endtask

    virtual task start_dataplane();
        // 测试桩只省略无限 worker，不得省略生产入口的 MQ 提交门禁；若调用方在
        // committed=0 时试图启动，立即失败，从而让迁移/自动恢复顺序错误可见。
        if ((state != FSM_READY) || !mq_pairs_committed) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"migration FSM start bypassed readiness gate: state=%s ",
                 "committed=%0b"}, state.name(), mq_pairs_committed))
            return;
        end
        start_count++;
        state = FSM_RUNNING;
    endtask
endclass : virtio_ctrl_vq_test_migration_fsm

// 运行期 MQ 测试需要观察 worker 的生命周期，但不能让无限循环的真实 worker 掩盖
// 建拆队结果。本桩只替换数据面启停：每次 start 记录一个新代次及当代 RX/TX qid，
// configure_mq/do_configure_mq 和队列资源操作仍完整复用生产实现。
class virtio_ctrl_vq_test_runtime_mq_fsm extends virtio_auto_fsm;
    `uvm_object_utils(virtio_ctrl_vq_test_runtime_mq_fsm)

    int unsigned stop_count;
    int unsigned start_count;
    int unsigned worker_generation;
    int unsigned worker_qids[$];

    // 构造运行态探针；计数和 worker 集合清零，拓扑由 prime_running_topology 注入。
    function new(string name = "virtio_ctrl_vq_test_runtime_mq_fsm");
        super.new(name);
        stop_count = 0;
        start_count = 0;
        worker_generation = 0;
    endfunction

    // 建立测试入口拓扑并模拟一代正在运行的 worker。输入为活动队列对数和含 control
    // VQ 的总队列数；副作用是状态进入 RUNNING、代次置 1 并刷新 worker_qids。
    function void prime_running_topology(
        int unsigned num_pairs,
        int unsigned num_queues
    );
        active_num_pairs = num_pairs;
        num_total_queues = num_queues;
        // 本 helper 构造的是已经由设备接受并正在运行的入口拓扑；显式置位避免测试
        // 依赖构造函数的缺省值，也区分 full_init 尚待首次 control 提交的预建拓扑。
        mq_pairs_committed = 1;
        worker_generation = 1;
        worker_qids.delete();
        for (int unsigned pair = 0; pair < active_num_pairs; pair++) begin
            worker_qids.push_back(pair * 2);
            worker_qids.push_back(pair * 2 + 1);
        end
        state = FSM_RUNNING;
    endfunction

    // 暴露生产 FSM 维护的总队列计数供恢复断言使用；只读，不改变拓扑所有权。
    // verified Function reset 成功后该值必须为 0，即使 active_num_pairs 仍保留最近
    // 一次成功提交的诊断值。
    function int unsigned tracked_total_queue_count();
        return num_total_queues;
    endfunction

    // 模拟同步停止旧代 worker；无输入输出，副作用是 stop_count 加一、清空 worker
    // 集合并进入 READY。测试只在 RUNNING 调用，其他状态视为测试接线错误。
    virtual task stop_dataplane();
        if (state != FSM_RUNNING)
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "runtime MQ stop entered from %s", state.name()))
        stop_count++;
        worker_qids.delete();
        state = FSM_READY;
    endtask

    // 按已经提交的 active_num_pairs 模拟启动新代 worker；无输入输出，副作用是
    // start_count/worker_generation 加一、记录全部 RX/TX qid 并进入 RUNNING。
    virtual task start_dataplane();
        if (state != FSM_READY)
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "runtime MQ start entered from %s", state.name()))
        start_count++;
        worker_generation++;
        worker_qids.delete();
        for (int unsigned pair = 0; pair < active_num_pairs; pair++) begin
            worker_qids.push_back(pair * 2);
            worker_qids.push_back(pair * 2 + 1);
        end
        state = FSM_RUNNING;
    endtask
endclass : virtio_ctrl_vq_test_runtime_mq_fsm

// control VQ 设备桩：kick 时从 split avail ring 取走新命令并登记 {head, ack IOVA}；
// answer_on_kick=1 时立即以 VIRTIO_NET_OK 完成，否则留给 complete_pending()（迟到完成）。
// Q_RESET 确认后丢弃待完成命令并从 0 重新计数，与真实设备的队列复位语义一致。
class virtio_ctrl_vq_test_device extends virtio_mock_transport;
    `uvm_object_utils(virtio_ctrl_vq_test_device)

    virtqueue_manager  vq_mgr;
    host_mem_manager   mem;
    virtio_iommu_model iommu;
    bit                answer_on_kick;
    int unsigned       seen_avail;
    int unsigned       used_idx;
    int unsigned       pending_heads[$];
    bit [63:0]         pending_acks[$];

    function new(string name = "virtio_ctrl_vq_test_device");
        super.new(name);
        answer_on_kick = 0;
        seen_avail = 0;
        used_idx = 0;
    endfunction

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
        virtqueue_base vq;
        byte raw[];
        int unsigned avail_idx;
        int unsigned head;

        super.kick(queue_id, next_avail_idx, wrap_counter);
        vq = vq_mgr.get_queue(queue_id);
        mem.read_mem(vq.driver_ring_addr + 2, 2, raw);
        avail_idx = {raw[1], raw[0]};
        while (seen_avail != avail_idx) begin
            mem.read_mem(vq.driver_ring_addr + 4 + (seen_avail % vq.queue_size) * 2, 2, raw);
            head = {raw[1], raw[0]};
            pending_heads.push_back(head);
            pending_acks.push_back(chain_tail(vq, head));
            seen_avail++;
        end
        if (answer_on_kick)
            complete_pending();
    endtask

    virtual task write_queue_reset_verified(int unsigned queue_id,
                                            ref bit reset_complete);
        super.write_queue_reset_verified(queue_id, reset_complete);
        if (reset_complete) begin
            pending_heads.delete();
            pending_acks.delete();
            seen_avail = 0;
            used_idx = 0;
        end
    endtask

    // 以 VIRTIO_NET_OK 完成全部待完成命令：经 IOMMU 写 ack，再发布 used ring 项。
    function void complete_pending();
        virtqueue_base vq;
        byte ack[];
        iommu_fault_e fault;

        vq = vq_mgr.get_queue(last_kick_queue_id);
        ack = new[1];
        ack[0] = VIRTIO_NET_OK;
        foreach (pending_heads[i]) begin
            void'(iommu.write_from_device_for_host(iommu_host_id(), mem, bdf,
                                                   pending_acks[i], ack, fault));
            virtio_vq_test_kit::complete_split_at(mem, vq, used_idx % vq.queue_size,
                                                  pending_heads[i], 1, used_idx + 1);
            used_idx++;
        end
        pending_heads.delete();
        pending_acks.delete();
    endfunction

    // 沿 split 描述符链走到末项（ack，设备可写），返回其 IOVA。
    protected function bit [63:0] chain_tail(virtqueue_base vq, int unsigned head);
        byte raw[];
        int unsigned idx;

        idx = head;
        mem.read_mem(vq.desc_table_addr + idx * 16, 16, raw);
        while ({raw[13], raw[12]} & VIRTQ_DESC_F_NEXT) begin
            idx = {raw[15], raw[14]};
            mem.read_mem(vq.desc_table_addr + idx * 16, 16, raw);
        end
        return {raw[7], raw[6], raw[5], raw[4], raw[3], raw[2], raw[1], raw[0]};
    endfunction
endclass : virtio_ctrl_vq_test_device

// 停队顺序探针：记录 queue_enable 写、Q_RESET 与 ring/DMA 解映射的先后（同一日志）。
class virtio_ctrl_vq_test_order_transport extends virtio_mock_transport;
    `uvm_object_utils(virtio_ctrl_vq_test_order_transport)

    string log[$];
    bit          fail_queue_reset_once;
    int unsigned fail_queue_reset_qid;
    virtqueue_manager reset_probe_vq_mgr;
    bit          queue2_present_at_function_reset;
    bit          queue3_present_at_function_reset;

    function new(string name = "virtio_ctrl_vq_test_order_transport");
        super.new(name);
        fail_queue_reset_once = 0;
        fail_queue_reset_qid = '1;
        reset_probe_vq_mgr = null;
        queue2_present_at_function_reset = 0;
        queue3_present_at_function_reset = 0;
    endfunction

    // 让指定 qid 的下一次 Q_RESET 返回“未确认”，随后自动撤销注入。其余 Q_RESET
    // 继续使用 mock transport 的真实计数和默认成功结果。
    function void fail_next_queue_reset(int unsigned queue_id);
        fail_queue_reset_once = 1;
        fail_queue_reset_qid = queue_id;
    endfunction

    virtual task write_queue_enable(bit enable);
        log.push_back($sformatf("enable %0d", enable));
    endtask

    virtual task write_queue_reset_verified(int unsigned queue_id, ref bit reset_complete);
        super.write_queue_reset_verified(queue_id, reset_complete);
        if (fail_queue_reset_once && (queue_id == fail_queue_reset_qid)) begin
            reset_complete = 0;
            fail_queue_reset_once = 0;
        end
        log.push_back($sformatf("qreset %0d", queue_id));
    endtask

    // 在设备复位真正执行前记下边界；结合 IOMMU 的 unmap 日志，可以证明 q2 已在
    // q3 停队失败前释放，而 q3 的资源一直保留到 verified Function reset。
    virtual task reset_device_verified(ref bit reset_complete);
        log.push_back("freset");
        if (reset_probe_vq_mgr != null) begin
            queue2_present_at_function_reset = reset_probe_vq_mgr.has_queue(2);
            queue3_present_at_function_reset = reset_probe_vq_mgr.has_queue(3);
        end
        super.reset_device_verified(reset_complete);
    endtask
endclass : virtio_ctrl_vq_test_order_transport

class virtio_ctrl_vq_test_order_iommu extends virtio_ctrl_vq_test_iommu;
    `uvm_object_utils(virtio_ctrl_vq_test_order_iommu)

    virtio_ctrl_vq_test_order_transport log_to;

    function new(string name = "virtio_ctrl_vq_test_order_iommu");
        super.new(name);
    endfunction

    virtual function void unmap_for_host(int unsigned host_id, bit [15:0] bdf, bit [63:0] iova,
                                         string file = "", int line = 0);
        log_to.log.push_back("unmap");
        super.unmap_for_host(host_id, bdf, iova, file, line);
    endfunction
endclass : virtio_ctrl_vq_test_order_iommu

class virtio_ctrl_vq_test extends uvm_test;
    `uvm_component_utils(virtio_ctrl_vq_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_ctrl_vq_at_twice_max_pairs();
        test_ctrl_vq_at_two_without_mq();
        test_ctrl_send_alloc_failure_rolls_back();
        test_ctrl_send_map_failure_rolls_back();
        test_ctrl_send_timeout_resets_queue();
        test_ctrl_send_rebuild_failure_requires_verified_reset();
        test_ctrl_send_timeout_quarantines_without_ring_reset();
        test_ctrl_vq_outside_data_range_migration_and_msix();
        test_two_pair_migration_recommits_mq_before_start();
        test_two_pair_migration_mq_reject_rolls_back();
        test_two_pair_device_recovery_recommits_mq();
        test_two_pair_device_recovery_mq_reject_stays_ready();
        test_mq_expansion_binds_new_queue_vectors();
        test_runtime_mq_restarts_matching_workers();
        test_runtime_mq_device_reject_keeps_old_topology();
        test_runtime_mq_timeout_requires_function_reset();
        test_runtime_mq_failure_keeps_workers_stopped();
        test_runtime_mq_rollback_reset_requires_reinit();
        test_runtime_mq_partial_shrink_requires_reset();
        test_runtime_mq_partial_shrink_reset_failure();
        test_full_init_same_target_programs_mq_once();
        test_full_init_binds_msix_before_enable();
        test_queue_stop_uses_ring_reset();
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
        virtio_vq_test_kit::bind_common_backend(ops);
    endfunction

    // 为迁移与自动恢复用例构造同一套两对标准 Virtio Function：固定 control VQ=4，
    // 真实使用生产队列 manager、IOMMU、Host memory、配置后端和 atomic ops，仅用本地
    // transport 吞掉 PCIe MMIO。所有句柄由本 task 创建并返回，调用方负责最终 reset
    // 和 leak_check。
    protected task build_two_pair_lifecycle_context(
        input string                              prefix,
        input bit [15:0]                          bdf,
        input bit [63:0]                          mem_base,
        output virtio_ctrl_vq_migration_transport transport,
        output virtio_ctrl_vq_test_mq_ops         ops,
        output virtqueue_manager                  vq_mgr,
        output virtio_ctrl_vq_test_mem            mem,
        output virtio_ctrl_vq_test_iommu          iommu,
        output virtio_ctrl_vq_test_migration_fsm  fsm
    );
        virtio_memory_barrier_model barrier;
        virtio_wait_policy wait_pol;
        bit [63:0] features;
        string why;

        transport = virtio_ctrl_vq_migration_transport::type_id::create(
            {prefix, "_transport"});
        ops = virtio_ctrl_vq_test_mq_ops::type_id::create({prefix, "_ops"});
        vq_mgr = virtqueue_manager::type_id::create({prefix, "_vq_mgr"});
        mem = virtio_ctrl_vq_test_mem::type_id::create({prefix, "_mem"});
        iommu = virtio_ctrl_vq_test_iommu::type_id::create({prefix, "_iommu"});
        fsm = virtio_ctrl_vq_test_migration_fsm::type_id::create(
            {prefix, "_fsm"});
        barrier = virtio_memory_barrier_model::type_id::create(
            {prefix, "_barrier"});
        wait_pol = virtio_wait_policy::type_id::create({prefix, "_wait_pol"});

        mem.init_region(mem_base, mem_base + 64'hFFFF);
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = bdf;
        transport.configure_pcie_identity(
            virtio_vq_test_kit::host0_pcie_id(bdf));
        transport.max_virtqueue_pairs = 2;
        transport.cap_mgr.msix_found = 1;
        transport.cap_mgr.msix_table_size = 8;
        transport.cap_mgr.msix_table_bir = 4;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        virtio_vq_test_kit::bind_common_backend(ops);

        features = '0;
        features[VIRTIO_F_VERSION_1] = 1'b1;
        features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        features[VIRTIO_NET_F_MQ] = 1'b1;
        fsm.ops = ops;
        fsm.drv_cfg.driver_features = features;
        fsm.drv_cfg.num_queue_pairs = 2;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
    endtask

    // 把两对 fixture 推进到已提交且正在运行的源端状态。full_init 只预建队列，随后
    // 必须恰好一次同值 MQ 命令提交设备目标，再由门禁感知的轻量 start 桩进入 RUNNING。
    protected task start_two_pair_source(
        virtio_ctrl_vq_test_migration_fsm fsm,
        virtio_ctrl_vq_test_mq_ops        ops,
        virtqueue_manager                 vq_mgr
    );
        fsm.full_init();
        if ((fsm.state != FSM_READY) ||
            (fsm.active_queue_pair_count() != 2) ||
            fsm.mq_pair_count_is_committed() ||
            (vq_mgr.get_queue_count() != 5))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"two-pair source full_init mismatch: state=%s active=%0d ",
                 "committed=%0b queues=%0d"},
                fsm.state.name(), fsm.active_queue_pair_count(),
                fsm.mq_pair_count_is_committed(), vq_mgr.get_queue_count()))

        fsm.configure_mq(2);
        if ((fsm.state != FSM_READY) ||
            !fsm.mq_pair_count_is_committed() ||
            (ops.mq_requests.size() != 1) || (ops.mq_requests[0] != 2))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"two-pair source MQ commit mismatch: state=%s committed=%0b ",
                 "requests=%p"}, fsm.state.name(),
                fsm.mq_pair_count_is_committed(), ops.mq_requests))

        fsm.start_dataplane();
        if ((fsm.state != FSM_RUNNING) || (fsm.start_count != 1))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "two-pair source did not start: state=%s starts=%0d",
                fsm.state.name(), fsm.start_count))
    endtask

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
        // 手工装配已完成，与 full_init 成功后的可重配入口状态保持一致。
        fsm.state = FSM_READY;
        fsm.configure_mq(2);
        expected_qids = '{0, 1, 4, 2, 3};
        assert((fsm.state != FSM_ERROR) && (ops.mq_requests.size() == 1) &&
               (ops.mq_requests[0] == 2) && (vq_mgr.get_queue_count() == 5) &&
               (transport.programmed_qids == expected_qids))
            else `uvm_fatal("CTRL_VQ_TEST",
                "MQ expansion 1->2 collided with the control VQ")

        ops.device_reset();
        assert((vq_mgr.get_queue_count() == 0) &&
               (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", "control VQ layout test leaked queue resources")
        mem.leak_check();

        `uvm_info("CTRL_VQ_TEST", "control VQ at 2*max_virtqueue_pairs test PASSED", UVM_LOW)
    endtask

    // 未协商 MQ（virtio 1.2 §5.1.2）：N=1，control VQ 必须是 2，且不读 max_virtqueue_pairs；
    // 请求 2 对时 control VQ 2 与数据队列 2 冲突，建队必须拒绝且不建任何队列。
    task test_ctrl_vq_at_two_without_mq();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("nomq_transport");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("nomq_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("nomq_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("nomq_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("nomq_iommu");
        virtio_ctrl_vq_test_catcher catcher;
        bit ok;

        mem.init_region(64'h7000_0000, 64'h7000_FFFF);
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h0902);
        transport.mock_net_config.max_virtqueue_pairs = 4;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;

        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        assert(ok && vq_mgr.has_queue(2) && (vq_mgr.get_queue_count() == 3) &&
               (transport.net_config_reads == 0))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "without MQ the control VQ must be queue 2 (ok=%0b q2=%0b count=%0d net_config_reads=%0d)",
                ok, vq_mgr.has_queue(2), vq_mgr.get_queue_count(), transport.net_config_reads))
        // 未协商 RING_RESET 不能单独停队：设备复位回收，再恢复本用例的协商结果。
        ops.device_reset();
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;

        catcher = new("nomq_pairs_catcher");
        catcher.expect_error("ATOMIC_OPS", "*requires VIRTIO_NET_F_MQ*");
        uvm_report_cb::add(null, catcher);
        ops.setup_all_queues(2, VQ_SPLIT, 8, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && (catcher.caught_count == 1) && (vq_mgr.get_queue_count() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "2 pairs without MQ must be rejected before any queue is built (ok=%0b caught=%0d count=%0d)",
                ok, catcher.caught_count, vq_mgr.get_queue_count()))
        assert((iommu.active_mapping_count() == 0) && (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", "control VQ without MQ test leaked queue resources")
        mem.leak_check();

        `uvm_info("CTRL_VQ_TEST", "control VQ at 2 without MQ test PASSED", UVM_LOW)
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
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.setup_control_queue(1, VQ_SPLIT, 8, ok);
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

        ops.device_reset();
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
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.setup_control_queue(1, VQ_SPLIT, 8, ok);
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

        ops.device_reset();
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
        virtio_vq_test_kit::bind_common_backend(ops);
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
        transport.enable_vectors.delete();
        transport.remapped_after_enable.delete();
        fsm.restore_from_migration(snapshot, restore_ok);
        vq_mgr.get_queue_ids(restored_qids);
        if (!restore_ok || (fsm.state != FSM_RUNNING) ||
            (restored_qids != expected_qids) ||
            (transport.msix_bound_qids != expected_qids))
            `uvm_error("CTRL_VQ_TEST", $sformatf(
                "restore did not rebuild the control VQ outside 0..2N-1: ok=%0b state=%s queues=%p bound=%p",
                restore_ok, fsm.state.name(), restored_qids, transport.msix_bound_qids))
        // virtio 1.2 §4.1.4.3.2：恢复的队列同样须在 queue_enable 之前写入最终向量，使能后不再改写。
        if (transport.remapped_after_enable.size() != 0)
            `uvm_error("CTRL_VQ_TEST", $sformatf(
                "restore remapped enabled queues %p after Q_ENABLE", transport.remapped_after_enable))
        foreach (expected_qids[i])
            if (!transport.enable_vectors.exists(expected_qids[i]) ||
                (transport.enable_vectors[expected_qids[i]] !=
                 transport.notify_mgr.queue_vectors[expected_qids[i]]) ||
                (transport.enable_vectors[expected_qids[i]] == 32'hFFFF) ||
                (transport.enable_vectors[expected_qids[i]] == transport.notify_mgr.config_vector))
                `uvm_error("CTRL_VQ_TEST", $sformatf(
                    "restore enabled queue %0d with vector %p instead of its final vector (vectors=%p config=%0d)",
                    expected_qids[i], transport.enable_vectors, transport.notify_mgr.queue_vectors,
                    transport.notify_mgr.config_vector))

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST", "control VQ migration/MSI-X test leaked queue resources")
        mem.leak_check();

        `uvm_info("CTRL_VQ_TEST",
            "control VQ outside data range migration and MSI-X test PASSED", UVM_LOW)
    endtask

    // 两对源端完成 freeze 后，目标端 restore 的 verified reset 会把设备活动对数恢复
    // 为一。生产 FSM 必须在全部队列恢复和 DRIVER_OK 之后恰好重发一次 MQ=2，并且只
    // 能在该命令提交后调用 start。该用例同时验证恢复成功会同步 drv_cfg 镜像。
    task test_two_pair_migration_recommits_mq_before_start();
        virtio_ctrl_vq_migration_transport transport;
        virtio_ctrl_vq_test_mq_ops ops;
        virtqueue_manager vq_mgr;
        virtio_ctrl_vq_test_mem mem;
        virtio_ctrl_vq_test_iommu iommu;
        virtio_ctrl_vq_test_migration_fsm fsm;
        virtio_device_snapshot_t snapshot;
        bit restore_ok;

        build_two_pair_lifecycle_context(
            "migration_mq_success", 16'h0911, 64'h7B00_0000,
            transport, ops, vq_mgr, mem, iommu, fsm);
        start_two_pair_source(fsm, ops, vq_mgr);
        fsm.freeze_for_migration(snapshot);
        if ((fsm.state != FSM_FROZEN) || (snapshot.num_queue_pairs != 2) ||
            (snapshot.queue_count != 5))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"two-pair freeze mismatch: state=%s pairs=%0d queues=%0d"},
                fsm.state.name(), snapshot.num_queue_pairs,
                snapshot.queue_count))

        // 清理源端资源后复用同一 fixture 模拟目标端。故意把行为镜像改成一对，证明
        // restore 成功由快照值覆盖，而不是偶然沿用源端配置。
        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_fatal("CTRL_VQ_TEST",
                "two-pair migration source reset leaked resources")
        ops.mq_requests.delete();
        fsm.start_count = 0;
        fsm.drv_cfg.num_queue_pairs = 1;

        fsm.restore_from_migration(snapshot, restore_ok);
        if (!restore_ok || (fsm.state != FSM_RUNNING) ||
            !fsm.mq_pair_count_is_committed() ||
            (fsm.active_queue_pair_count() != 2) ||
            (fsm.drv_cfg.num_queue_pairs != 2) ||
            (fsm.start_count != 1) ||
            (ops.mq_requests.size() != 1) || (ops.mq_requests[0] != 2) ||
            (vq_mgr.get_queue_count() != 5))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"two-pair migration did not recommit MQ before start: ",
                 "ok=%0b state=%s committed=%0b active/cfg=%0d/%0d ",
                 "starts=%0d requests=%p queues=%0d"},
                restore_ok, fsm.state.name(),
                fsm.mq_pair_count_is_committed(),
                fsm.active_queue_pair_count(), fsm.drv_cfg.num_queue_pairs,
                fsm.start_count, ops.mq_requests,
                vq_mgr.get_queue_count()))

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST",
                "two-pair migration success test leaked resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
            "two-pair migration MQ recommit test PASSED", UVM_LOW)
    endtask

    // 目标端队列全部恢复后若设备明确拒绝 MQ=2，设备结果是确定的 ACK_ERR，但整个
    // migration restore 仍未原子完成。FSM 必须执行一次 verified Function reset，
    // 成功回收全部目标端资源并进入 REINIT_REQUIRED，且不得调用 start 桩。
    task test_two_pair_migration_mq_reject_rolls_back();
        virtio_ctrl_vq_migration_transport transport;
        virtio_ctrl_vq_test_mq_ops ops;
        virtqueue_manager vq_mgr;
        virtio_ctrl_vq_test_mem mem;
        virtio_ctrl_vq_test_iommu iommu;
        virtio_ctrl_vq_test_migration_fsm fsm;
        virtio_ctrl_vq_test_catcher catcher;
        virtio_device_snapshot_t snapshot;
        bit restore_ok;

        build_two_pair_lifecycle_context(
            "migration_mq_reject", 16'h0912, 64'h7C00_0000,
            transport, ops, vq_mgr, mem, iommu, fsm);
        start_two_pair_source(fsm, ops, vq_mgr);
        fsm.freeze_for_migration(snapshot);
        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_fatal("CTRL_VQ_TEST",
                "migration reject source reset leaked resources")

        ops.mq_requests.delete();
        ops.accept_mq_requests = 0;
        fsm.start_count = 0;
        catcher = new("migration_mq_reject_catcher");
        catcher.expect_error("AUTO_FSM",
            "*configure_mq: device rejected MQ change to 2 pairs*");
        catcher.expect_error("AUTO_FSM",
            "*restore_from_migration: MQ target 2 was not committed; restore stopped in state FSM_REINIT_REQUIRED*");
        uvm_report_cb::add(null, catcher);
        fsm.restore_from_migration(snapshot, restore_ok);
        uvm_report_cb::delete(null, catcher);

        if (restore_ok || (catcher.caught_count != 2) ||
            (fsm.state != FSM_REINIT_REQUIRED) ||
            fsm.mq_pair_count_is_committed() || (fsm.start_count != 0) ||
            (ops.mq_requests.size() != 1) || (ops.mq_requests[0] != 2) ||
            (fsm.tracked_total_queue_count() != 0) ||
            (vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"rejected migration MQ did not roll back atomically: ok=%0b ",
                 "caught=%0d state=%s committed=%0b starts=%0d requests=%p ",
                 "tracked/queues=%0d/%0d maps=%0d allocs=%0d"},
                restore_ok, catcher.caught_count, fsm.state.name(),
                fsm.mq_pair_count_is_committed(), fsm.start_count,
                ops.mq_requests, fsm.tracked_total_queue_count(),
                vq_mgr.get_queue_count(), iommu.active_mapping_count(),
                mem.outstanding_allocations()))
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
            "two-pair migration MQ reject rollback test PASSED", UVM_LOW)
    endtask

    // DEVICE_NEEDS_RESET 的自动恢复会重新 full_init；两对配置在该初始化结束时仍是
    // READY+未提交。恢复体必须先发一次同值 MQ=2，再启动恰好一代数据面。
    task test_two_pair_device_recovery_recommits_mq();
        virtio_ctrl_vq_migration_transport transport;
        virtio_ctrl_vq_test_mq_ops ops;
        virtqueue_manager vq_mgr;
        virtio_ctrl_vq_test_mem mem;
        virtio_ctrl_vq_test_iommu iommu;
        virtio_ctrl_vq_test_migration_fsm fsm;

        build_two_pair_lifecycle_context(
            "device_recovery_mq_success", 16'h0913, 64'h7D00_0000,
            transport, ops, vq_mgr, mem, iommu, fsm);
        start_two_pair_source(fsm, ops, vq_mgr);
        ops.mq_requests.delete();
        fsm.start_count = 0;

        fsm.run_complete_device_recovery();
        if ((fsm.state != FSM_RUNNING) ||
            !fsm.mq_pair_count_is_committed() ||
            (fsm.active_queue_pair_count() != 2) ||
            (fsm.start_count != 1) ||
            (ops.mq_requests.size() != 1) || (ops.mq_requests[0] != 2) ||
            (vq_mgr.get_queue_count() != 5))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"two-pair automatic recovery did not recommit before start: ",
                 "state=%s committed=%0b active=%0d starts=%0d requests=%p ",
                 "queues=%0d"}, fsm.state.name(),
                fsm.mq_pair_count_is_committed(),
                fsm.active_queue_pair_count(), fsm.start_count,
                ops.mq_requests, vq_mgr.get_queue_count()))

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST",
                "two-pair automatic recovery success test leaked resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
            "two-pair automatic recovery MQ recommit test PASSED", UVM_LOW)
    endtask

    // 自动恢复期间的明确 MQ ACK_ERR 不表示设备状态不确定，因此保留 full_init 已经
    // 安全建立的五条队列，状态停在 READY+未提交供调用方重试；不得启动 worker，也
    // 不得把数值相同的 active_num_pairs 误当作恢复成功。
    task test_two_pair_device_recovery_mq_reject_stays_ready();
        virtio_ctrl_vq_migration_transport transport;
        virtio_ctrl_vq_test_mq_ops ops;
        virtqueue_manager vq_mgr;
        virtio_ctrl_vq_test_mem mem;
        virtio_ctrl_vq_test_iommu iommu;
        virtio_ctrl_vq_test_migration_fsm fsm;
        virtio_ctrl_vq_test_catcher catcher;

        build_two_pair_lifecycle_context(
            "device_recovery_mq_reject", 16'h0914, 64'h7E00_0000,
            transport, ops, vq_mgr, mem, iommu, fsm);
        start_two_pair_source(fsm, ops, vq_mgr);
        ops.mq_requests.delete();
        ops.accept_mq_requests = 0;
        fsm.start_count = 0;
        catcher = new("device_recovery_mq_reject_catcher");
        catcher.expect_error("AUTO_FSM",
            "*configure_mq: device rejected MQ change to 2 pairs*");
        uvm_report_cb::add(null, catcher);
        fsm.run_complete_device_recovery();
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 1) || (fsm.state != FSM_READY) ||
            fsm.mq_pair_count_is_committed() || (fsm.start_count != 0) ||
            (fsm.active_queue_pair_count() != 2) ||
            (ops.mq_requests.size() != 1) || (ops.mq_requests[0] != 2) ||
            (fsm.tracked_total_queue_count() != 5) ||
            (vq_mgr.get_queue_count() != 5) ||
            (iommu.active_mapping_count() == 0) ||
            (mem.outstanding_allocations() == 0))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"rejected automatic-recovery MQ did not preserve stopped ",
                 "prebuilt topology: caught=%0d state=%s committed=%0b ",
                 "starts=%0d active=%0d requests=%p tracked/queues=%0d/%0d ",
                 "maps=%0d allocs=%0d"}, catcher.caught_count,
                fsm.state.name(), fsm.mq_pair_count_is_committed(),
                fsm.start_count, fsm.active_queue_pair_count(),
                ops.mq_requests, fsm.tracked_total_queue_count(),
                vq_mgr.get_queue_count(), iommu.active_mapping_count(),
                mem.outstanding_allocations()))

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST",
                "two-pair automatic recovery reject test leaked resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
            "two-pair automatic recovery MQ reject test PASSED", UVM_LOW)
    endtask

    // 协商 RING_RESET：显式登记 control VQ 2 后再建立编号更高的普通队列 7，ctrl_send
    // 仍必须使用 2。第一条命令设备不应答，超时后 Q_RESET 并重新建立 control VQ；
    // 局部资源虽已安全恢复，设备是否执行过命令仍不确定，因此后续命令必须被闸门拒绝。
    // 只有 verified Function reset 能清除该状态，重新初始化后的命令才可成功。
    task test_ctrl_send_timeout_resets_queue();
        virtio_ctrl_vq_test_device device =
            virtio_ctrl_vq_test_device::type_id::create("timeout_reset_device");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("timeout_reset_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("timeout_reset_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("timeout_reset_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("timeout_reset_iommu");
        virtio_ctrl_vq_test_catcher catcher;
        virtio_ctrl_ack_e first_ack;
        virtio_ctrl_ack_e blocked_ack;
        virtio_ctrl_ack_e recovered_ack;
        byte unsigned data[];
        int unsigned expected_qids[$];
        int unsigned ctrl_qid;
        bit id_valid;
        bit ok;
        bit reset_complete;

        mem.init_region(64'h7400_0000, 64'h7400_FFFF);
        wire_ops(ops, device, vq_mgr, mem, mem, iommu, 16'h0904);
        device.vq_mgr = vq_mgr;
        device.mem = mem;
        device.iommu = iommu;
        ops.wait_pol.default_timeout_ns = 200;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_control_queue(1, VQ_SPLIT, 8, ok);
        assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")
        ops.setup_queue(7, 8, VQ_SPLIT, ok);
        assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "higher non-control queue setup failed")

        data = new[2];
        data[0] = 8'h01;
        data[1] = 8'h00;
        catcher = new("timeout_reset_catcher");
        catcher.expect_error("ATOMIC_OPS", "*ctrl_send: timeout waiting for control VQ completion*");
        uvm_report_cb::add(null, catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      data, first_ack);
        uvm_report_cb::delete(null, catcher);

        expected_qids = '{2, 7, 2};
        assert((first_ack == VIRTIO_NET_CTRL_ACK_ERR) &&
               (catcher.caught_count == 1) &&
               ops.control_vq_requires_recovery() &&
               (device.queue_reset_count == 1) && (device.last_reset_queue_id == 2) &&
               (device.programmed_qids == expected_qids) &&
               (vq_mgr.get_queue(2).get_free_count() == 8))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"ctrl_send timeout did not recover resources and close the Function ",
                 "gate (ack=%s caught=%0d pending=%0b resets=%0d programmed=%p free=%0d)"},
                first_ack.name(), catcher.caught_count,
                ops.control_vq_requires_recovery(),
                device.queue_reset_count, device.programmed_qids,
                vq_mgr.get_queue(2).get_free_count()))

        // Q_RESET 已使迟到完成失效，但没有证明命令副作用未发生。第二次提交必须在
        // 分配 DMA 和 kick 之前拒绝；随后整 Function reset 清空普通队列 7 和 control VQ。
        device.complete_pending();
        device.answer_on_kick = 1;
        catcher = new("timeout_pending_catcher");
        catcher.expect_error("ATOMIC_OPS",
            "*control VQ recovery is pending; verified device reset required*");
        uvm_report_cb::add(null, catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      data, blocked_ack);
        uvm_report_cb::delete(null, catcher);
        assert((blocked_ack == VIRTIO_NET_CTRL_ACK_ERR) &&
               (catcher.caught_count == 1) && (device.kick_count == 1) &&
               (vq_mgr.get_queue_count() == 2))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"ambiguous control result did not block a second command ",
                 "(ack=%s caught=%0d kicks=%0d queues=%0d)"},
                blocked_ack.name(), catcher.caught_count,
                device.kick_count, vq_mgr.get_queue_count()))

        ops.device_reset_verified(reset_complete);
        id_valid = ops.get_control_queue_id(ctrl_qid);
        assert(reset_complete && !id_valid &&
               !ops.control_vq_requires_recovery() &&
               (vq_mgr.get_queue_count() == 0) &&
               (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"verified reset did not clear ambiguous control state ",
                 "(reset=%0b id=%0b/%0d pending=%0b queues=%0d maps=%0d allocs=%0d)"},
                reset_complete, id_valid, ctrl_qid,
                ops.control_vq_requires_recovery(), vq_mgr.get_queue_count(),
                iommu.active_mapping_count(), mem.outstanding_allocations()))

        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_control_queue(1, VQ_SPLIT, 8, ok);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      data, recovered_ack);
        expected_qids = '{2, 7, 2, 2};
        assert(ok && (recovered_ack == VIRTIO_NET_CTRL_ACK_OK) &&
               (device.programmed_qids == expected_qids) &&
               (device.kick_count == 2))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"control command did not recover after verified reset ",
                 "(setup=%0b ack=%s programmed=%p kicks=%0d)"},
                ok, recovered_ack.name(), device.programmed_qids,
                device.kick_count))

        ops.device_reset_verified(reset_complete);
        assert(reset_complete && (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", "timeout-reset test leaked control queue resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST", "ctrl_send timeout queue-reset test PASSED", UVM_LOW)
    endtask

    // Q_RESET 已确认但 control VQ 重建被注入失败：旧请求 DMA 可以释放，但 Function
    // 必须保留显式 control qid 并进入 recovery pending。第二条命令和普通建队都应在
    // 分配/通知/设备编程前被拒绝；只有成功的 verified device reset 清除身份和闸门，
    // 之后重新初始化才能发送。
    task test_ctrl_send_rebuild_failure_requires_verified_reset();
        virtio_ctrl_vq_test_device device =
            virtio_ctrl_vq_test_device::type_id::create("rebuild_fail_device");
        virtio_ctrl_vq_test_rebuild_fail_ops ops =
            virtio_ctrl_vq_test_rebuild_fail_ops::type_id::create("rebuild_fail_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("rebuild_fail_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("rebuild_fail_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("rebuild_fail_iommu");
        virtio_ctrl_vq_test_catcher catcher;
        virtio_ctrl_ack_e first_ack;
        virtio_ctrl_ack_e blocked_ack;
        virtio_ctrl_ack_e recovered_ack;
        byte unsigned data[];
        int unsigned ctrl_qid;
        bit id_valid;
        bit ok;
        bit reset_complete;

        mem.init_region(64'h7480_0000, 64'h7480_FFFF);
        wire_ops(ops, device, vq_mgr, mem, mem, iommu, 16'h0914);
        device.vq_mgr = vq_mgr;
        device.mem = mem;
        device.iommu = iommu;
        ops.wait_pol.default_timeout_ns = 200;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_control_queue(1, VQ_SPLIT, 8, ok);
        id_valid = ops.get_control_queue_id(ctrl_qid);
        assert(ok && id_valid && (ctrl_qid == 2) &&
               !ops.control_vq_requires_recovery())
            else `uvm_fatal("CTRL_VQ_TEST",
                "rebuild-failure fixture did not register control VQ 2")

        data = new[2];
        data[0] = 8'h01;
        data[1] = 8'h00;
        ops.fail_next_setup = 1;
        catcher = new("rebuild_fail_catcher");
        catcher.expect_error("ATOMIC_OPS",
            "*ctrl_send: timeout waiting for control VQ completion*");
        catcher.expect_error("CTRL_VQ_TEST_INJECT",
            "*injected setup failure for control VQ 2*");
        catcher.expect_error("ATOMIC_OPS",
            "*control VQ 2 could not be re-enabled after reset; verified device reset required*");
        catcher.expect_error("ATOMIC_OPS",
            "*control VQ recovery is pending; verified device reset required*");
        catcher.expect_error("ATOMIC_OPS",
            "*setup_queue: verified Function reset required before creating another queue*");
        uvm_report_cb::add(null, catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ,
                      VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, data, first_ack);
        id_valid = ops.get_control_queue_id(ctrl_qid);
        assert((first_ack == VIRTIO_NET_CTRL_ACK_ERR) && id_valid &&
               (ctrl_qid == 2) && ops.control_vq_requires_recovery() &&
               !vq_mgr.has_queue(2) && (device.queue_reset_count == 1) &&
               (ops.setup_attempts == 2) &&
               (mem.outstanding_allocations() == 0) &&
               (iommu.active_mapping_count() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "failed control VQ rebuild did not close recovery (ack=%s id=%0b/%0d pending=%0b queue=%0b resets=%0d setups=%0d allocs=%0d maps=%0d)",
                first_ack.name(), id_valid, ctrl_qid,
                ops.control_vq_requires_recovery(), vq_mgr.has_queue(2),
                device.queue_reset_count, ops.setup_attempts,
                mem.outstanding_allocations(), iommu.active_mapping_count()))

        // control VQ 恢复失败属于 Function 生命周期边界；公开的普通建队入口也不能
        // 在同一旧生命周期里创建 q7。探针计数会记录调用本身，但设备编程和资源数
        // 必须保持不变。
        ops.setup_queue(7, 8, VQ_SPLIT, ok);
        assert(!ok && (ops.setup_attempts == 3) &&
               (device.programmed_qids.size() == 1) &&
               (mem.outstanding_allocations() == 0) &&
               (iommu.active_mapping_count() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"control recovery gate allowed ordinary queue setup ",
                 "(ok=%0b setups=%0d programmed=%p allocs=%0d maps=%0d)"},
                ok, ops.setup_attempts, device.programmed_qids,
                mem.outstanding_allocations(), iommu.active_mapping_count()))

        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ,
                      VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, data, blocked_ack);
        uvm_report_cb::delete(null, catcher);
        assert((blocked_ack == VIRTIO_NET_CTRL_ACK_ERR) &&
               (catcher.caught_count == 5) && (device.kick_count == 1) &&
               (ops.setup_attempts == 3) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "recovery-pending control command was not rejected before side effects (ack=%s caught=%0d kicks=%0d setups=%0d allocs=%0d)",
                blocked_ack.name(), catcher.caught_count, device.kick_count,
                ops.setup_attempts, mem.outstanding_allocations()))

        // 一次未确认的整设备复位仍不能解除闸门；随后设备确认完成才清除状态。
        device.device_reset_complete = 0;
        catcher = new("rebuild_reset_fail_catcher");
        catcher.expect_error("ATOMIC_OPS",
            "*device_reset: transport reset did not complete; retaining PF DMA*");
        uvm_report_cb::add(null, catcher);
        ops.device_reset_verified(reset_complete);
        uvm_report_cb::delete(null, catcher);
        id_valid = ops.get_control_queue_id(ctrl_qid);
        assert(!reset_complete && (catcher.caught_count == 1) && id_valid &&
               (ctrl_qid == 2) && ops.control_vq_requires_recovery())
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "unverified device reset cleared control recovery state (reset=%0b caught=%0d id=%0b/%0d pending=%0b)",
                reset_complete, catcher.caught_count, id_valid, ctrl_qid,
                ops.control_vq_requires_recovery()))

        device.device_reset_complete = 1;
        ops.device_reset_verified(reset_complete);
        id_valid = ops.get_control_queue_id(ctrl_qid);
        assert(reset_complete && !id_valid &&
               !ops.control_vq_requires_recovery())
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "verified device reset did not clear control recovery state (reset=%0b id=%0b/%0d pending=%0b)",
                reset_complete, id_valid, ctrl_qid,
                ops.control_vq_requires_recovery()))

        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_control_queue(1, VQ_SPLIT, 8, ok);
        device.answer_on_kick = 1;
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ,
                      VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, data, recovered_ack);
        assert(ok && (recovered_ack == VIRTIO_NET_CTRL_ACK_OK) &&
               !ops.control_vq_requires_recovery() &&
               (ops.setup_attempts == 4))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "control VQ did not recover after verified reset (setup=%0b ack=%s pending=%0b setups=%0d)",
                ok, recovered_ack.name(), ops.control_vq_requires_recovery(),
                ops.setup_attempts))

        ops.device_reset_verified(reset_complete);
        assert(reset_complete && (vq_mgr.get_queue_count() == 0) &&
               (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST",
                "control VQ rebuild-failure recovery test leaked resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
            "ctrl_send rebuild-failure verified-reset recovery test PASSED", UVM_LOW)
    endtask

    // 未协商 RING_RESET：超时命令无法单独复位，其缓冲保持映射与分配（IOVA 不会被
    // 复用），迟到完成写入仍有效；control VQ 拒绝后续命令，确认的设备复位后才回收。
    task test_ctrl_send_timeout_quarantines_without_ring_reset();
        virtio_ctrl_vq_test_device device =
            virtio_ctrl_vq_test_device::type_id::create("quarantine_device");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("quarantine_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("quarantine_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("quarantine_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("quarantine_iommu");
        virtio_ctrl_vq_test_catcher catcher;
        virtqueue_base ctrl_vq;
        virtio_ctrl_ack_e first_ack;
        virtio_ctrl_ack_e second_ack;
        byte unsigned data[];
        int unsigned maps_before;
        int unsigned allocs_before;
        bit ok;

        mem.init_region(64'h7500_0000, 64'h7500_FFFF);
        wire_ops(ops, device, vq_mgr, mem, mem, iommu, 16'h0905);
        device.vq_mgr = vq_mgr;
        device.mem = mem;
        device.iommu = iommu;
        ops.wait_pol.default_timeout_ns = 200;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.setup_control_queue(1, VQ_SPLIT, 8, ok);
        assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")
        ctrl_vq = vq_mgr.get_queue(2);
        maps_before = iommu.active_mapping_count();
        allocs_before = mem.outstanding_allocations();

        data = new[2];
        data[0] = 8'h01;
        data[1] = 8'h00;
        catcher = new("quarantine_catcher");
        catcher.expect_error("ATOMIC_OPS", "*ctrl_send: timeout waiting for control VQ completion*");
        catcher.expect_error("ATOMIC_OPS", "*DMA is quarantined until device reset*");
        catcher.expect_error("ATOMIC_OPS", "*teardown_queue: config backend did not confirm queue_id=2 stopped*");
        catcher.expect_error("ATOMIC_OPS", "*ctrl_send: control VQ has quarantined DMA; device reset required*");
        uvm_report_cb::add(null, catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      data, first_ack);
        assert((first_ack == VIRTIO_NET_CTRL_ACK_ERR) && (device.queue_reset_count == 0) &&
               (mem.outstanding_allocations() == allocs_before + 3) &&
               (iommu.active_mapping_count() == maps_before + 3) &&
               (ctrl_vq.get_free_count() == 5))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "ctrl_send timeout released DMA the device may still own (ack=%s resets=%0d allocs=%0d/%0d maps=%0d/%0d free=%0d)",
                first_ack.name(), device.queue_reset_count, mem.outstanding_allocations(),
                allocs_before, iommu.active_mapping_count(), maps_before,
                ctrl_vq.get_free_count()))

        device.complete_pending();   // 迟到完成写入仍映射的隔离缓冲
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      data, second_ack);
        uvm_report_cb::delete(null, catcher);
        assert((second_ack == VIRTIO_NET_CTRL_ACK_ERR) && (catcher.caught_count == 4) &&
               (device.kick_count == 1))
            else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "control VQ accepted a command while DMA was quarantined (ack=%s caught=%0d kicks=%0d)",
                second_ack.name(), catcher.caught_count, device.kick_count))

        ops.device_reset();
        assert((vq_mgr.get_queue_count() == 0) && (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("CTRL_VQ_TEST",
                "verified device reset did not release quarantined control DMA")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST", "ctrl_send timeout quarantine test PASSED", UVM_LOW)
    endtask

    // 1 对 + CTRL_VQ（max_virtqueue_pairs=2，队列 {0,1,4}）扩到 2 对：每条实际队列（含新建
    // 的 RX1/TX1）都必须绑定有效、互不相同、非 config 的向量，并与 notification manager 一致。
    // virtio 1.2 §4.1.4.3.2：新建队列在 queue_enable 前写入最终向量；扩容不得改写已使能队列
    // 的向量（不再整体重建 MSI-X）。
    task test_mq_expansion_binds_new_queue_vectors();
        virtio_ctrl_vq_migration_transport transport =
            virtio_ctrl_vq_migration_transport::type_id::create("mq_msix_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("mq_msix_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("mq_msix_vq_mgr");
        virtio_ctrl_vq_test_mem mem = virtio_ctrl_vq_test_mem::type_id::create("mq_msix_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("mq_msix_iommu");
        virtio_auto_fsm fsm = virtio_auto_fsm::type_id::create("mq_msix_fsm");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("mq_msix_barrier");
        virtio_wait_policy mq_wait_pol =
            virtio_wait_policy::type_id::create("mq_msix_wait_pol");
        int unsigned qids[$];
        int unsigned new_qids[$];
        int unsigned rebinds_before;
        int unsigned programs_before;
        bit seen_vectors[int unsigned];
        bit ok;
        string why;

        mem.init_region(64'h7600_0000, 64'h7600_FFFF);
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.wait_pol = mq_wait_pol;
        vq_mgr.bdf = 16'h0906;
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0906));
        transport.max_virtqueue_pairs = 2;
        transport.cap_mgr.msix_found = 1;
        transport.cap_mgr.msix_table_size = 8;
        transport.cap_mgr.msix_table_bir = 4;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = mq_wait_pol;
        virtio_vq_test_kit::bind_common_backend(ops);
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;

        // 与 full_init 同序：先按将要建立的队列 {0,1,4} 分配向量，再建队。
        ops.setup_msix(3);
        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue(4) == null))
            `uvm_fatal("CTRL_VQ_TEST", "MQ MSI-X test setup did not create queues {0,1,4}")
        rebinds_before = transport.msix_bound_qids.size();
        programs_before = transport.programmed_qids.size();
        fsm.ops = ops;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        // 此用例绕过 full_init 手工建立初始拓扑，需显式进入合法 MQ 状态。
        fsm.state = FSM_READY;
        fsm.configure_mq(2);

        vq_mgr.get_queue_ids(qids);
        if ((fsm.state == FSM_ERROR) || (qids.size() != 5))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "MQ expansion 1->2 failed: state=%s queues=%p", fsm.state.name(), qids))
        for (int unsigned i = programs_before; i < transport.programmed_qids.size(); i++)
            new_qids.push_back(transport.programmed_qids[i]);
        if ((new_qids.size() != 2) || (new_qids[0] != 2) || (new_qids[1] != 3) || (transport.msix_bound_qids.size() != rebinds_before))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "MQ expansion must program only new queues {2,3} and not remap live queues: programmed=%p remapped=%p",
                new_qids, transport.msix_bound_qids))
        foreach (qids[i]) begin
            if (!transport.enable_vectors.exists(qids[i]) ||
                (transport.enable_vectors[qids[i]] !=
                 transport.notify_mgr.queue_vectors[qids[i]]) ||
                (transport.enable_vectors[qids[i]] == 32'hFFFF) ||
                (transport.enable_vectors[qids[i]] ==
                 transport.notify_mgr.config_vector) ||
                seen_vectors.exists(transport.enable_vectors[qids[i]]))
                `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                    "MQ expansion enabled queue %0d without its own valid MSI-X vector: at_enable=%p vectors=%p",
                    qids[i], transport.enable_vectors, transport.notify_mgr.queue_vectors))
            seen_vectors[transport.enable_vectors[qids[i]]] = 1;
        end

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) || (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST", "MQ MSI-X test leaked queue resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST", "MQ expansion new-queue vector binding test PASSED", UVM_LOW)
    endtask

    // 从 RUNNING 连续执行 1->2 扩容、同值 no-op 和 2->1 缩容。生产 atomic ops
    // 负责真实建拆队，runtime FSM 桩记录 worker 代次与 qid；每次有效变更必须恰好
    // stop/start 一次，新代 worker 集合必须与最终活动队列对完全一致，同值请求不得
    // 访问 control VQ 或切换 worker。
    task test_runtime_mq_restarts_matching_workers();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("runtime_mq_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("runtime_mq_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("runtime_mq_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("runtime_mq_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("runtime_mq_iommu");
        virtio_ctrl_vq_test_runtime_mq_fsm fsm =
            virtio_ctrl_vq_test_runtime_mq_fsm::type_id::create("runtime_mq_fsm");
        int unsigned expected_workers[$];
        int unsigned qids[$];
        int unsigned requests_before_noop;
        bit ok;
        string why;

        mem.init_region(64'h7900_0000, 64'h7900_FFFF);
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h0909);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 3))
            `uvm_fatal("CTRL_VQ_TEST",
                "runtime MQ setup did not create data pair 0 and control VQ")

        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.prime_running_topology(1, 3);

        fsm.configure_mq(2);
        expected_workers = '{0, 1, 2, 3};
        if ((fsm.state != FSM_RUNNING) ||
            (fsm.active_queue_pair_count() != 2) ||
            (fsm.drv_cfg.num_queue_pairs != 2) ||
            (fsm.stop_count != 1) || (fsm.start_count != 1) ||
            (fsm.worker_generation != 2) ||
            (fsm.worker_qids != expected_workers) ||
            (vq_mgr.get_queue_count() != 5) ||
            (ops.mq_requests.size() != 1) || (ops.mq_requests[0] != 2)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"runtime MQ expansion did not replace workers atomically: ",
                 "state=%s active=%0d cfg=%0d stop/start=%0d/%0d gen=%0d ",
                 "workers=%p queues=%0d requests=%p"},
                fsm.state.name(), fsm.active_queue_pair_count(),
                fsm.drv_cfg.num_queue_pairs, fsm.stop_count, fsm.start_count,
                fsm.worker_generation, fsm.worker_qids,
                vq_mgr.get_queue_count(), ops.mq_requests))
        end

        requests_before_noop = ops.mq_requests.size();
        fsm.configure_mq(2);
        if ((ops.mq_requests.size() != requests_before_noop) ||
            (fsm.stop_count != 1) || (fsm.start_count != 1) ||
            (fsm.worker_generation != 2) ||
            (fsm.worker_qids != expected_workers) ||
            (fsm.state != FSM_RUNNING)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"same-pair MQ request was not a side-effect-free no-op: ",
                 "requests=%p stop/start=%0d/%0d gen=%0d workers=%p state=%s"},
                ops.mq_requests, fsm.stop_count, fsm.start_count,
                fsm.worker_generation, fsm.worker_qids, fsm.state.name()))
        end

        fsm.configure_mq(1);
        expected_workers = '{0, 1};
        vq_mgr.get_queue_ids(qids);
        if ((fsm.state != FSM_RUNNING) ||
            (fsm.active_queue_pair_count() != 1) ||
            (fsm.drv_cfg.num_queue_pairs != 1) ||
            (fsm.stop_count != 2) || (fsm.start_count != 2) ||
            (fsm.worker_generation != 3) ||
            (fsm.worker_qids != expected_workers) ||
            (qids.size() != 3) || !vq_mgr.has_queue(0) ||
            !vq_mgr.has_queue(1) || !vq_mgr.has_queue(4) ||
            vq_mgr.has_queue(2) || vq_mgr.has_queue(3) ||
            (ops.mq_requests.size() != 2) || (ops.mq_requests[1] != 1)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"runtime MQ shrink did not replace workers atomically: ",
                 "state=%s active=%0d cfg=%0d stop/start=%0d/%0d gen=%0d ",
                 "workers=%p queues=%p requests=%p"},
                fsm.state.name(), fsm.active_queue_pair_count(),
                fsm.drv_cfg.num_queue_pairs, fsm.stop_count, fsm.start_count,
                fsm.worker_generation, fsm.worker_qids, qids,
                ops.mq_requests))
        end

        fsm.stop_dataplane();
        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST", "runtime MQ test leaked queue resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "runtime MQ worker replacement test PASSED", UVM_LOW)
    endtask

    // 运行态 MQ 命令被设备拒绝时，旧 worker 已经按运行期重配约束同步退出，但设备
    // 和 Host 拓扑都没有提交变化。FSM 应停在 READY，保留旧 active/cfg/队列资源，
    // 不得建拆队、复位设备或误启动新一代 worker。
    task test_runtime_mq_device_reject_keeps_old_topology();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("runtime_mq_reject_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("runtime_mq_reject_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("runtime_mq_reject_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("runtime_mq_reject_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("runtime_mq_reject_iommu");
        virtio_ctrl_vq_test_runtime_mq_fsm fsm =
            virtio_ctrl_vq_test_runtime_mq_fsm::type_id::create(
                "runtime_mq_reject_fsm");
        virtio_ctrl_vq_test_catcher catcher;
        int unsigned mappings_before;
        int unsigned allocations_before;
        int unsigned programs_before;
        bit ok;
        string why;

        mem.init_region(64'h7904_0000, 64'h7904_FFFF);
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h090D);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 3))
            `uvm_fatal("CTRL_VQ_TEST",
                "runtime MQ rejection setup did not create queues {0,1,4}")

        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.prime_running_topology(1, 3);
        mappings_before = iommu.active_mapping_count();
        allocations_before = mem.outstanding_allocations();
        programs_before = transport.programmed_qids.size();
        ops.accept_mq_requests = 0;

        catcher = new("runtime_mq_reject_catcher");
        catcher.expect_error("AUTO_FSM",
            "*configure_mq: device rejected MQ change to 2 pairs*");
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(2);
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 1) || (fsm.state != FSM_READY) ||
            (fsm.active_queue_pair_count() != 1) ||
            (fsm.drv_cfg.num_queue_pairs != 1) ||
            (fsm.tracked_total_queue_count() != 3) ||
            (fsm.stop_count != 1) || (fsm.start_count != 0) ||
            (fsm.worker_generation != 1) || (fsm.worker_qids.size() != 0) ||
            (vq_mgr.get_queue_count() != 3) || !vq_mgr.has_queue(0) ||
            !vq_mgr.has_queue(1) || !vq_mgr.has_queue(4) ||
            (iommu.active_mapping_count() != mappings_before) ||
            (mem.outstanding_allocations() != allocations_before) ||
            (transport.programmed_qids.size() != programs_before) ||
            (transport.queue_reset_count != 0) ||
            (transport.device_reset_count != 0) ||
            ops.queues_require_recovery() ||
            (ops.mq_requests.size() != 1) ||
            (ops.mq_requests[0] != 2)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"rejected runtime MQ changed old topology or workers: caught=%0d ",
                 "state=%s active=%0d cfg=%0d tracked/actual=%0d/%0d ",
                 "stop/start=%0d/%0d gen=%0d workers=%p maps=%0d/%0d ",
                 "allocs=%0d/%0d programs=%0d/%0d qreset/freset=%0d/%0d ",
                 "pending=%0b requests=%p"},
                catcher.caught_count, fsm.state.name(),
                fsm.active_queue_pair_count(), fsm.drv_cfg.num_queue_pairs,
                fsm.tracked_total_queue_count(), vq_mgr.get_queue_count(),
                fsm.stop_count, fsm.start_count, fsm.worker_generation,
                fsm.worker_qids, iommu.active_mapping_count(), mappings_before,
                mem.outstanding_allocations(), allocations_before,
                transport.programmed_qids.size(), programs_before,
                transport.queue_reset_count, transport.device_reset_count,
                ops.queues_require_recovery(), ops.mq_requests))
        end

        ops.device_reset_verified(ok);
        if (!ok || (vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_fatal("CTRL_VQ_TEST",
                "runtime MQ rejection cleanup did not release resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "runtime MQ device-rejection test PASSED", UVM_LOW)
    endtask

    // 运行态 MQ 命令已经发布，但设备不返回 used/ACK。control Q_RESET 和同号重建只能
    // 证明旧描述符不再被访问，不能证明设备没有应用新 pair 数。FSM 必须识别 control
    // recovery pending，主动完成 verified Function reset，清空全部队列并进入
    // REINIT_REQUIRED；旧 worker 已停止且不得重启。
    task test_runtime_mq_timeout_requires_function_reset();
        virtio_ctrl_vq_test_device device =
            virtio_ctrl_vq_test_device::type_id::create(
                "runtime_mq_timeout_device");
        virtio_atomic_ops ops =
            virtio_atomic_ops::type_id::create("runtime_mq_timeout_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("runtime_mq_timeout_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("runtime_mq_timeout_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create(
                "runtime_mq_timeout_iommu");
        virtio_ctrl_vq_test_runtime_mq_fsm fsm =
            virtio_ctrl_vq_test_runtime_mq_fsm::type_id::create(
                "runtime_mq_timeout_fsm");
        virtio_ctrl_vq_test_catcher catcher;
        bit ok;
        string why;

        mem.init_region(64'h7906_0000, 64'h7906_FFFF);
        wire_ops(ops, device, vq_mgr, mem, mem, iommu, 16'h090F);
        device.vq_mgr = vq_mgr;
        device.mem = mem;
        device.iommu = iommu;
        device.mock_net_config.max_virtqueue_pairs = 2;
        ops.wait_pol.default_timeout_ns = 200;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 3) ||
            !vq_mgr.has_queue(0) || !vq_mgr.has_queue(1) ||
            !vq_mgr.has_queue(4))
            `uvm_fatal("CTRL_VQ_TEST",
                "runtime MQ timeout setup did not create queues {0,1,4}")

        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.prime_running_topology(1, 3);

        catcher = new("runtime_mq_timeout_catcher");
        catcher.expect_error("ATOMIC_OPS",
            "*ctrl_send: timeout waiting for control VQ completion*");
        catcher.expect_error("AUTO_FSM",
            {"*configure_mq: control command for 2 pairs completed with an unknown ",
             "device result; verified Function reset completed, reinitialization required*"});
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(2);
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 2) ||
            (fsm.state != FSM_REINIT_REQUIRED) ||
            (fsm.active_queue_pair_count() != 1) ||
            (fsm.drv_cfg.num_queue_pairs != 1) ||
            (fsm.tracked_total_queue_count() != 0) ||
            (fsm.stop_count != 1) || (fsm.start_count != 0) ||
            (fsm.worker_generation != 1) || (fsm.worker_qids.size() != 0) ||
            (device.kick_count != 1) ||
            (device.queue_reset_count != 1) ||
            (device.last_reset_queue_id != 4) ||
            (device.device_reset_count != 1) ||
            ops.control_vq_requires_recovery() ||
            ops.queues_require_recovery() ||
            (vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"ambiguous runtime MQ result was not closed by Function reset: ",
                 "caught=%0d state=%s active=%0d cfg=%0d tracked/actual=%0d/%0d ",
                 "stop/start=%0d/%0d gen=%0d workers=%p kicks=%0d qreset=%0d/%0d ",
                 "freset=%0d ctrl/queue_pending=%0b/%0b maps=%0d allocs=%0d"},
                catcher.caught_count, fsm.state.name(),
                fsm.active_queue_pair_count(), fsm.drv_cfg.num_queue_pairs,
                fsm.tracked_total_queue_count(), vq_mgr.get_queue_count(),
                fsm.stop_count, fsm.start_count, fsm.worker_generation,
                fsm.worker_qids, device.kick_count, device.queue_reset_count,
                device.last_reset_queue_id, device.device_reset_count,
                ops.control_vq_requires_recovery(),
                ops.queues_require_recovery(), iommu.active_mapping_count(),
                mem.outstanding_allocations()))
        end

        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "runtime MQ ambiguous-timeout recovery test PASSED", UVM_LOW)
    endtask

    // 运行态扩容在设备接受 MQ 命令后注入建队失败。即使没有创建出新队列，设备已经
    // 接受新 pair 数，FSM 也必须主动完成 verified Function reset，清空 Host 拓扑并进入
    // REINIT_REQUIRED；旧代 worker 保持停止，不得启动新代。随后以同一活动对数再次请求，
    // 验证恢复状态检查位于同值 no-op 之前，不会绕过重新初始化。
    task test_runtime_mq_failure_keeps_workers_stopped();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("runtime_mq_fail_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("runtime_mq_fail_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("runtime_mq_fail_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("runtime_mq_fail_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("runtime_mq_fail_iommu");
        virtio_ctrl_vq_test_runtime_mq_fsm fsm =
            virtio_ctrl_vq_test_runtime_mq_fsm::type_id::create(
                "runtime_mq_fail_fsm");
        virtio_ctrl_vq_test_catcher catcher;
        bit ok;
        string why;

        mem.init_region(64'h7901_0000, 64'h7901_FFFF);
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h090A);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 3))
            `uvm_fatal("CTRL_VQ_TEST", "runtime MQ failure setup did not create queues")

        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.prime_running_topology(1, 3);
        ops.fail_next_setup_range = 1;

        catcher = new("runtime_mq_fail_catcher");
        catcher.expect_error("AUTO_FSM",
            "*configure_mq: failed to setup queue pairs 1..1*");
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(2);
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 1) ||
            (fsm.state != FSM_REINIT_REQUIRED) ||
            (fsm.active_queue_pair_count() != 1) ||
            (fsm.drv_cfg.num_queue_pairs != 1) ||
            (fsm.tracked_total_queue_count() != 0) ||
            (fsm.stop_count != 1) || (fsm.start_count != 0) ||
            (fsm.worker_generation != 1) || (fsm.worker_qids.size() != 0) ||
            (vq_mgr.get_queue_count() != 0) ||
            ops.queue_rollback_used_function_reset() ||
            ops.queues_require_recovery() ||
            (transport.device_reset_count != 1) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0) ||
            (ops.mq_requests.size() != 1) ||
            (ops.mq_requests[0] != 2)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"failed runtime MQ expansion did not reset to reinit: ",
                 "caught=%0d state=%s active=%0d cfg=%0d stop/start=%0d/%0d ",
                 "gen=%0d workers=%p tracked/actual=%0d/%0d used_reset=%0b ",
                 "pending=%0b resets=%0d maps=%0d allocs=%0d requests=%p"},
                catcher.caught_count, fsm.state.name(),
                fsm.active_queue_pair_count(), fsm.drv_cfg.num_queue_pairs,
                fsm.stop_count, fsm.start_count, fsm.worker_generation,
                fsm.worker_qids, fsm.tracked_total_queue_count(),
                vq_mgr.get_queue_count(),
                ops.queue_rollback_used_function_reset(),
                ops.queues_require_recovery(), transport.device_reset_count,
                iommu.active_mapping_count(), mem.outstanding_allocations(),
                ops.mq_requests))
        end

        // active_num_pairs 仍为 1；若同值 no-op 先于状态检查，这次调用会静默成功。
        // 正确实现必须报告恢复状态错误，且不再发 control 命令或再次复位。
        catcher = new("runtime_mq_reinit_guard_catcher");
        catcher.expect_error("AUTO_FSM",
            "*configure_mq: requires FSM_READY or FSM_RUNNING, got FSM_REINIT_REQUIRED*");
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(1);
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 1) ||
            (fsm.state != FSM_REINIT_REQUIRED) ||
            (ops.mq_requests.size() != 1) ||
            (transport.device_reset_count != 1) ||
            (fsm.stop_count != 1) || (fsm.start_count != 0)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"MQ recovery-state guard was bypassed by same-pair request: ",
                 "caught=%0d state=%s requests=%p resets=%0d stop/start=%0d/%0d"},
                catcher.caught_count, fsm.state.name(), ops.mq_requests,
                transport.device_reset_count, fsm.stop_count, fsm.start_count))
        end

        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "runtime MQ failure reset/worker-stop test PASSED", UVM_LOW)
    endtask

    // 扩容时让新 RX 队列建成、新 TX 队列映射失败；未协商 RING_RESET，因此生产
    // setup_queue_range 无法逐队回滚 RX，只能执行 verified Function reset。FSM 必须
    // 根据 rollback-used-reset 与 recovery-pending 的组合进入 REINIT_REQUIRED，不得把
    // 已被整复位清空的 Function 当作仍有旧队列可恢复，也不得启动新代 worker。
    task test_runtime_mq_rollback_reset_requires_reinit();
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("runtime_mq_reset_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("runtime_mq_reset_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("runtime_mq_reset_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("runtime_mq_reset_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("runtime_mq_reset_iommu");
        virtio_ctrl_vq_test_runtime_mq_fsm fsm =
            virtio_ctrl_vq_test_runtime_mq_fsm::type_id::create(
                "runtime_mq_reset_fsm");
        virtio_ctrl_vq_test_catcher catcher;
        bit ok;
        string why;

        mem.init_region(64'h7902_0000, 64'h7902_FFFF);
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h090B);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        // 故意不协商 RING_RESET：新 RX 建成后若新 TX 失败，窄回滚无法确认停 DMA。
        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 3))
            `uvm_fatal("CTRL_VQ_TEST", "runtime MQ reset setup did not create queues")

        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.prime_running_topology(1, 3);

        // split ring 每条队列映射 3 个区域；让新 q2 的三次映射成功，q3 首次映射起失败。
        iommu.fail_map_after = iommu.map_calls + 4;
        catcher = new("runtime_mq_reset_catcher");
        catcher.expect_error("ATOMIC_OPS", "*failed to map queue_id=3 rings*");
        catcher.expect_error("ATOMIC_OPS",
            "*teardown_queue: config backend did not confirm queue_id=2 stopped*");
        catcher.expect_error("AUTO_FSM",
            {"*configure_mq: failed to setup queue pairs 1..1; ",
             "verified Function reset completed, reinitialization required*"});
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(2);
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 3) ||
            (fsm.state != FSM_REINIT_REQUIRED) ||
            (fsm.active_queue_pair_count() != 1) ||
            (fsm.drv_cfg.num_queue_pairs != 1) ||
            (fsm.tracked_total_queue_count() != 0) ||
            (fsm.stop_count != 1) || (fsm.start_count != 0) ||
            (fsm.worker_generation != 1) || (fsm.worker_qids.size() != 0) ||
            (vq_mgr.get_queue_count() != 0) ||
            !ops.queue_rollback_used_function_reset() ||
            ops.queues_require_recovery() ||
            (transport.device_reset_count != 1) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"MQ rollback reset was not converted to reinit: caught=%0d ",
                 "state=%s active=%0d cfg=%0d stop/start=%0d/%0d gen=%0d ",
                 "workers=%p tracked/actual=%0d/%0d used_reset=%0b pending=%0b resets=%0d ",
                 "maps=%0d allocs=%0d"},
                catcher.caught_count, fsm.state.name(),
                fsm.active_queue_pair_count(), fsm.drv_cfg.num_queue_pairs,
                fsm.stop_count, fsm.start_count, fsm.worker_generation,
                fsm.worker_qids, fsm.tracked_total_queue_count(),
                vq_mgr.get_queue_count(),
                ops.queue_rollback_used_function_reset(),
                ops.queues_require_recovery(), transport.device_reset_count,
                iommu.active_mapping_count(), mem.outstanding_allocations()))
        end

        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "runtime MQ rollback-reset reinit test PASSED", UVM_LOW)
    endtask

    // 从 RUNNING 缩容 2->1 时，注入“q2/RX 的 Q_RESET 成功，q3/TX 的 Q_RESET
    // 未确认”。q2 必须在失败发生前独立释放；随后 FSM 必须升级为 verified Function
    // reset，清空 q3 及其余 Function 资源，进入 REINIT_REQUIRED，并保持 worker 停止。
    task test_runtime_mq_partial_shrink_requires_reset();
        virtio_ctrl_vq_test_order_transport transport =
            virtio_ctrl_vq_test_order_transport::type_id::create(
                "runtime_mq_partial_shrink_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create(
                "runtime_mq_partial_shrink_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create(
                "runtime_mq_partial_shrink_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create(
                "runtime_mq_partial_shrink_mem");
        virtio_ctrl_vq_test_order_iommu iommu =
            virtio_ctrl_vq_test_order_iommu::type_id::create(
                "runtime_mq_partial_shrink_iommu");
        virtio_ctrl_vq_test_runtime_mq_fsm fsm =
            virtio_ctrl_vq_test_runtime_mq_fsm::type_id::create(
                "runtime_mq_partial_shrink_fsm");
        virtio_ctrl_vq_test_catcher catcher;
        string expected_prefix[$];
        bit prefix_matches;
        bit ok;
        string why;

        mem.init_region(64'h7903_0000, 64'h7903_FFFF);
        iommu.log_to = transport;
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h090C);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        transport.reset_probe_vq_mgr = vq_mgr;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_all_queues(2, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 5))
            `uvm_fatal("CTRL_VQ_TEST",
                "partial-shrink setup did not create queues {0,1,2,3,4}")

        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 2;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.prime_running_topology(2, 5);

        transport.log.delete();
        transport.fail_next_queue_reset(3);
        catcher = new("runtime_mq_partial_shrink_catcher");
        catcher.expect_error("ATOMIC_OPS",
            "*teardown_queue: config backend did not confirm queue_id=3 stopped*");
        catcher.expect_error("AUTO_FSM",
            {"*configure_mq: transmit queue 3 of pair 1 was not stopped; ",
             "verified Function reset completed*"});
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(1);
        uvm_report_cb::delete(null, catcher);

        // 前缀精确表达半个 pair 的时序：q2 reset 后先释放三个 ring 映射，q3 reset
        // 才失败，之后才允许发起整 Function reset。整复位产生的其余 unmap 位于后面。
        expected_prefix = '{"qreset 2", "unmap", "unmap", "unmap",
                            "qreset 3", "freset"};
        prefix_matches = (transport.log.size() >= expected_prefix.size());
        if (prefix_matches) begin
            foreach (expected_prefix[i]) begin
                if (transport.log[i] != expected_prefix[i])
                    prefix_matches = 0;
            end
        end

        if ((catcher.caught_count != 2) || !prefix_matches ||
            transport.queue2_present_at_function_reset ||
            !transport.queue3_present_at_function_reset ||
            (fsm.state != FSM_REINIT_REQUIRED) ||
            (fsm.active_queue_pair_count() != 2) ||
            (fsm.drv_cfg.num_queue_pairs != 2) ||
            (fsm.tracked_total_queue_count() != 0) ||
            (fsm.stop_count != 1) || (fsm.start_count != 0) ||
            (fsm.worker_generation != 1) || (fsm.worker_qids.size() != 0) ||
            (vq_mgr.get_queue_count() != 0) ||
            ops.queues_require_recovery() ||
            (transport.queue_reset_count != 2) ||
            (transport.last_reset_queue_id != 3) ||
            (transport.device_reset_count != 1) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0) ||
            (ops.mq_requests.size() != 1) ||
            (ops.mq_requests[0] != 1)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"partial MQ shrink did not escalate safely: caught=%0d log=%p ",
                 "q2/q3_at_reset=%0b/%0b state=%s active=%0d cfg=%0d ",
                 "tracked/actual=%0d/%0d stop/start=%0d/%0d gen=%0d workers=%p ",
                 "pending=%0b qresets=%0d last_qid=%0d freset=%0d maps=%0d ",
                 "allocs=%0d requests=%p"},
                catcher.caught_count, transport.log,
                transport.queue2_present_at_function_reset,
                transport.queue3_present_at_function_reset,
                fsm.state.name(), fsm.active_queue_pair_count(),
                fsm.drv_cfg.num_queue_pairs, fsm.tracked_total_queue_count(),
                vq_mgr.get_queue_count(), fsm.stop_count, fsm.start_count,
                fsm.worker_generation, fsm.worker_qids,
                ops.queues_require_recovery(), transport.queue_reset_count,
                transport.last_reset_queue_id, transport.device_reset_count,
                iommu.active_mapping_count(), mem.outstanding_allocations(),
                ops.mq_requests))
        end

        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "runtime MQ partial-shrink reset test PASSED", UVM_LOW)
    endtask

    // 与上一用例相同地让 q2 成功释放、q3 停队未确认，但同时让第一次 Function reset
    // 失败。FSM 必须进入 ERROR，把总队列诊断值更新为 manager 中实际剩余的 4 条，
    // 并保留 q3/其余队列的 ring DMA；断言完成后重试成功的 verified reset 统一回收。
    task test_runtime_mq_partial_shrink_reset_failure();
        virtio_ctrl_vq_test_order_transport transport =
            virtio_ctrl_vq_test_order_transport::type_id::create(
                "runtime_mq_shrink_reset_fail_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create(
                "runtime_mq_shrink_reset_fail_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create(
                "runtime_mq_shrink_reset_fail_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create(
                "runtime_mq_shrink_reset_fail_mem");
        virtio_ctrl_vq_test_order_iommu iommu =
            virtio_ctrl_vq_test_order_iommu::type_id::create(
                "runtime_mq_shrink_reset_fail_iommu");
        virtio_ctrl_vq_test_runtime_mq_fsm fsm =
            virtio_ctrl_vq_test_runtime_mq_fsm::type_id::create(
                "runtime_mq_shrink_reset_fail_fsm");
        virtio_ctrl_vq_test_catcher catcher;
        string expected_log[$];
        int unsigned mappings_before;
        int unsigned allocations_before;
        bit ok;
        string why;

        mem.init_region(64'h7905_0000, 64'h7905_FFFF);
        iommu.log_to = transport;
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h090E);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        transport.reset_probe_vq_mgr = vq_mgr;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_all_queues(2, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 5))
            `uvm_fatal("CTRL_VQ_TEST",
                "shrink-reset-failure setup did not create queues {0,1,2,3,4}")

        fsm.ops = ops;
        fsm.drv_cfg.num_queue_pairs = 2;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.prime_running_topology(2, 5);
        mappings_before = iommu.active_mapping_count();
        allocations_before = mem.outstanding_allocations();

        transport.log.delete();
        transport.fail_next_queue_reset(3);
        transport.device_reset_complete = 0;
        catcher = new("runtime_mq_shrink_reset_fail_catcher");
        catcher.expect_error("ATOMIC_OPS",
            "*teardown_queue: config backend did not confirm queue_id=3 stopped*");
        catcher.expect_error("ATOMIC_OPS",
            "*device_reset: transport reset did not complete; retaining PF DMA*");
        catcher.expect_error("AUTO_FSM",
            {"*configure_mq: transmit queue 3 of pair 1 was not stopped; ",
             "verified Function reset failed*"});
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(1);
        uvm_report_cb::delete(null, catcher);

        expected_log = '{"qreset 2", "unmap", "unmap", "unmap",
                         "qreset 3", "freset"};
        if ((catcher.caught_count != 3) || (transport.log != expected_log) ||
            transport.queue2_present_at_function_reset ||
            !transport.queue3_present_at_function_reset ||
            (fsm.state != FSM_ERROR) ||
            (fsm.active_queue_pair_count() != 2) ||
            (fsm.drv_cfg.num_queue_pairs != 2) ||
            (fsm.tracked_total_queue_count() != 4) ||
            (fsm.stop_count != 1) || (fsm.start_count != 0) ||
            (fsm.worker_generation != 1) || (fsm.worker_qids.size() != 0) ||
            (vq_mgr.get_queue_count() != 4) || vq_mgr.has_queue(2) ||
            !vq_mgr.has_queue(0) || !vq_mgr.has_queue(1) ||
            !vq_mgr.has_queue(3) || !vq_mgr.has_queue(4) ||
            !ops.queues_require_recovery() ||
            (transport.queue_reset_count != 2) ||
            (transport.last_reset_queue_id != 3) ||
            (transport.device_reset_count != 1) ||
            (iommu.active_mapping_count() != mappings_before - 3) ||
            (mem.outstanding_allocations() != allocations_before - 3) ||
            (ops.mq_requests.size() != 1) ||
            (ops.mq_requests[0] != 1)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"failed shrink reset did not retain the partial topology: ",
                 "caught=%0d log=%p expected=%p q2/q3_at_reset=%0b/%0b ",
                 "state=%s active=%0d cfg=%0d tracked/actual=%0d/%0d ",
                 "stop/start=%0d/%0d gen=%0d workers=%p q2=%0b q3=%0b ",
                 "pending=%0b qresets=%0d last_qid=%0d freset=%0d ",
                 "maps=%0d/%0d allocs=%0d/%0d requests=%p"},
                catcher.caught_count, transport.log, expected_log,
                transport.queue2_present_at_function_reset,
                transport.queue3_present_at_function_reset,
                fsm.state.name(), fsm.active_queue_pair_count(),
                fsm.drv_cfg.num_queue_pairs, fsm.tracked_total_queue_count(),
                vq_mgr.get_queue_count(), fsm.stop_count, fsm.start_count,
                fsm.worker_generation, fsm.worker_qids,
                vq_mgr.has_queue(2), vq_mgr.has_queue(3),
                ops.queues_require_recovery(), transport.queue_reset_count,
                transport.last_reset_queue_id, transport.device_reset_count,
                iommu.active_mapping_count(), mappings_before - 3,
                mem.outstanding_allocations(), allocations_before - 3,
                ops.mq_requests))
        end

        // 失败路径有意保留仍可能被设备访问的 DMA。设备随后确认 Function reset 时，
        // 由同一个 verified 接口清除 recovery 闸门并释放全部剩余所有权。
        transport.device_reset_complete = 1;
        ops.device_reset_verified(ok);
        if (!ok || ops.queues_require_recovery() ||
            (transport.device_reset_count != 2) ||
            (vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"verified reset retry did not clean retained shrink resources: ",
                 "ok=%0b pending=%0b resets=%0d queues=%0d maps=%0d allocs=%0d"},
                ok, ops.queues_require_recovery(), transport.device_reset_count,
                vq_mgr.get_queue_count(), iommu.active_mapping_count(),
                mem.outstanding_allocations()))

        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "runtime MQ partial-shrink reset-failure test PASSED", UVM_LOW)
    endtask

    // full_init 可以先按目标值建立两对 Host 队列，但设备在 Function reset 后仍只激活
    // 缺省的一对。首次 configure_mq(2) 即使数值与 active_num_pairs 相同，也必须发送
    // VQ_PAIRS_SET；明确 ACK_ERR 后保持未提交，重试 ACK_OK 才能置为 committed。完成后
    // 第二次同值请求才是零命令、零建拆队、零资源副作用的真正 no-op。
    task test_full_init_same_target_programs_mq_once();
        virtio_ctrl_vq_migration_transport transport =
            virtio_ctrl_vq_migration_transport::type_id::create(
                "init_same_mq_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("init_same_mq_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("init_same_mq_vq_mgr");
        virtio_ctrl_vq_test_mem mem =
            virtio_ctrl_vq_test_mem::type_id::create("init_same_mq_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("init_same_mq_iommu");
        virtio_auto_fsm fsm =
            virtio_auto_fsm::type_id::create("init_same_mq_fsm");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create(
                "init_same_mq_barrier");
        virtio_wait_policy init_wait_pol =
            virtio_wait_policy::type_id::create("init_same_mq_wait_pol");
        virtio_ctrl_vq_test_catcher catcher;
        int unsigned programs_before;
        int unsigned mappings_before;
        int unsigned allocations_before;
        bit [63:0] features;
        string why;

        mem.init_region(64'h76A0_0000, 64'h76A0_FFFF);
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.wait_pol = init_wait_pol;
        vq_mgr.bdf = 16'h0910;
        transport.configure_pcie_identity(
            virtio_vq_test_kit::host0_pcie_id(16'h0910));
        transport.max_virtqueue_pairs = 2;
        transport.cap_mgr.msix_found = 1;
        transport.cap_mgr.msix_table_size = 8;
        transport.cap_mgr.msix_table_bir = 4;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = init_wait_pol;
        virtio_vq_test_kit::bind_common_backend(ops);
        fsm.ops = ops;
        features = '0;
        features[VIRTIO_F_VERSION_1] = 1'b1;
        features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        features[VIRTIO_NET_F_MQ] = 1'b1;
        fsm.drv_cfg.driver_features = features;
        fsm.drv_cfg.num_queue_pairs = 2;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.full_init();

        programs_before = transport.programmed_qids.size();
        mappings_before = iommu.active_mapping_count();
        allocations_before = mem.outstanding_allocations();
        if ((fsm.state != FSM_READY) ||
            (fsm.active_queue_pair_count() != 2) ||
            fsm.mq_pair_count_is_committed() ||
            (vq_mgr.get_queue_count() != 5) || (programs_before != 5)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"full_init did not leave the prebuilt two-pair MQ target ",
                 "uncommitted: state=%s active=%0d committed=%0b queues=%0d ",
                 "programs=%0d"},
                fsm.state.name(), fsm.active_queue_pair_count(),
                fsm.mq_pair_count_is_committed(), vq_mgr.get_queue_count(),
                programs_before))
        end

        // 未提交的预建目标不能启动 worker；该调用必须在任何 RX refill/fork 之前返回。
        catcher = new("init_same_mq_start_gate_catcher");
        catcher.expect_error("AUTO_FSM",
            "*start_dataplane: MQ target has not been committed*");
        uvm_report_cb::add(null, catcher);
        fsm.start_dataplane();
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 1) || (fsm.state != FSM_READY) ||
            (iommu.active_mapping_count() != mappings_before) ||
            (mem.outstanding_allocations() != allocations_before)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"uncommitted initial MQ target bypassed the dataplane gate: ",
                 "caught=%0d state=%s maps=%0d/%0d allocs=%0d/%0d"},
                catcher.caught_count, fsm.state.name(),
                iommu.active_mapping_count(), mappings_before,
                mem.outstanding_allocations(), allocations_before))
        end

        // 第一次同值请求由设备明确拒绝：它必须真正到达 control 层，但不得把目标
        // 标成已提交，也不得重建 full_init 已经准备好的队列。
        ops.accept_mq_requests = 0;
        catcher = new("init_same_mq_reject_catcher");
        catcher.expect_error("AUTO_FSM",
            "*configure_mq: device rejected MQ change to 2 pairs*");
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(2);
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 1) ||
            (ops.mq_requests.size() != 1) || (ops.mq_requests[0] != 2) ||
            fsm.mq_pair_count_is_committed() || (fsm.state != FSM_READY) ||
            (transport.programmed_qids.size() != programs_before) ||
            (vq_mgr.get_queue_count() != 5) ||
            (iommu.active_mapping_count() != mappings_before) ||
            (mem.outstanding_allocations() != allocations_before)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"rejected initial same-target MQ request was treated as a ",
                 "no-op or committed: caught=%0d requests=%p committed=%0b ",
                 "state=%s programs=%0d/%0d queues=%0d maps=%0d/%0d ",
                 "allocs=%0d/%0d"},
                catcher.caught_count, ops.mq_requests,
                fsm.mq_pair_count_is_committed(), fsm.state.name(),
                transport.programmed_qids.size(), programs_before,
                vq_mgr.get_queue_count(), iommu.active_mapping_count(),
                mappings_before, mem.outstanding_allocations(),
                allocations_before))
        end

        // ACK_OK 只提交既有目标，不重复建队；随后再请求 2 才允许幂等返回。
        ops.accept_mq_requests = 1;
        fsm.configure_mq(2);
        if ((ops.mq_requests.size() != 2) || (ops.mq_requests[1] != 2) ||
            !fsm.mq_pair_count_is_committed() || (fsm.state != FSM_READY) ||
            (transport.programmed_qids.size() != programs_before) ||
            (vq_mgr.get_queue_count() != 5) ||
            (iommu.active_mapping_count() != mappings_before) ||
            (mem.outstanding_allocations() != allocations_before)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"accepted initial same-target MQ request did not commit in ",
                 "place: requests=%p committed=%0b state=%s programs=%0d/%0d ",
                 "queues=%0d maps=%0d/%0d allocs=%0d/%0d"},
                ops.mq_requests, fsm.mq_pair_count_is_committed(),
                fsm.state.name(), transport.programmed_qids.size(),
                programs_before, vq_mgr.get_queue_count(),
                iommu.active_mapping_count(), mappings_before,
                mem.outstanding_allocations(), allocations_before))
        end
        fsm.configure_mq(2);
        if ((ops.mq_requests.size() != 2) ||
            (transport.programmed_qids.size() != programs_before) ||
            (vq_mgr.get_queue_count() != 5)) begin
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"committed same-target MQ request was not side-effect free: ",
                 "requests=%p programs=%0d/%0d queues=%0d"},
                ops.mq_requests, transport.programmed_qids.size(),
                programs_before, vq_mgr.get_queue_count()))
        end

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST",
                "initial same-target MQ test leaked queue resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST",
                  "full_init same-target MQ commit test PASSED", UVM_LOW)
    endtask

    // virtio 1.2 §4.1.4.3.2：驱动 MUST 在 queue_enable 之前配置好其余队列字段（含 queue_msix_vector）。
    // FSM full_init 建 1 对 + CTRL_VQ（max_virtqueue_pairs=2，队列 {0,1,4}）：每条队列使能时写入的向量
    // 必须就是最终绑定的有效向量（非 NO_VECTOR、非 config 向量），而不是先用占位向量使能、事后改绑。
    task test_full_init_binds_msix_before_enable();
        virtio_ctrl_vq_migration_transport transport =
            virtio_ctrl_vq_migration_transport::type_id::create("init_msix_transport");
        virtio_ctrl_vq_test_mq_ops ops =
            virtio_ctrl_vq_test_mq_ops::type_id::create("init_msix_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("init_msix_vq_mgr");
        virtio_ctrl_vq_test_mem mem = virtio_ctrl_vq_test_mem::type_id::create("init_msix_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("init_msix_iommu");
        virtio_auto_fsm fsm = virtio_auto_fsm::type_id::create("init_msix_fsm");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("init_msix_barrier");
        virtio_wait_policy init_wait_pol =
            virtio_wait_policy::type_id::create("init_msix_wait_pol");
        int unsigned qids[$];
        bit [63:0] features;
        string why;

        mem.init_region(64'h7700_0000, 64'h7700_FFFF);
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.wait_pol = init_wait_pol;
        vq_mgr.bdf = 16'h0907;
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0907));
        transport.max_virtqueue_pairs = 2;
        transport.cap_mgr.msix_found = 1;
        transport.cap_mgr.msix_table_size = 8;
        transport.cap_mgr.msix_table_bir = 4;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = init_wait_pol;
        virtio_vq_test_kit::bind_common_backend(ops);
        fsm.ops = ops;
        features = '0;
        features[VIRTIO_F_VERSION_1] = 1'b1;
        features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        features[VIRTIO_NET_F_MQ] = 1'b1;
        fsm.drv_cfg.driver_features = features;
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.full_init();

        vq_mgr.get_queue_ids(qids);
        if ((fsm.state != FSM_READY) || (qids.size() != 3) || (qids[2] != 4))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "full_init with control VQ failed: state=%s queues=%p", fsm.state.name(), qids))
        foreach (qids[i]) begin
            if (!transport.enable_vectors.exists(qids[i]) ||
                (transport.enable_vectors[qids[i]] != transport.notify_mgr.queue_vectors[qids[i]]) ||
                (transport.enable_vectors[qids[i]] == 32'hFFFF) ||
                (transport.enable_vectors[qids[i]] == transport.notify_mgr.config_vector))
                `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                    "full_init enabled queue %0d with vector %p instead of its final vector (vectors=%p config=%0d)",
                    qids[i], transport.enable_vectors, transport.notify_mgr.queue_vectors,
                    transport.notify_mgr.config_vector))
        end

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) || (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST", "full_init MSI-X test leaked queue resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST", "full_init MSI-X before enable test PASSED", UVM_LOW)
    endtask

    // virtio 1.2 §4.1.4.3.2：驱动不得写 queue_enable=0。单队列复位（reset_single_queue）与 MQ 缩容都经
    // teardown_queue 停队：协商 RING_RESET 时先 Q_RESET（已确认）再解映射；未协商时标准设备无法单独停队，
    // 拒绝并保留队列（不写 enable=0、不解映射）且进入 recovery pending，只能经 verified Function reset
    // 清理后重新建立测试拓扑；缩容仍在提交 MQ 命令前拒绝。
    task test_queue_stop_uses_ring_reset();
        virtio_ctrl_vq_test_order_transport transport =
            virtio_ctrl_vq_test_order_transport::type_id::create("order_transport");
        virtio_ctrl_vq_test_mq_ops ops = virtio_ctrl_vq_test_mq_ops::type_id::create("order_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("order_vq_mgr");
        virtio_ctrl_vq_test_mem mem = virtio_ctrl_vq_test_mem::type_id::create("order_mem");
        virtio_ctrl_vq_test_order_iommu iommu =
            virtio_ctrl_vq_test_order_iommu::type_id::create("order_iommu");
        virtio_ctrl_vq_test_migration_fsm fsm =
            virtio_ctrl_vq_test_migration_fsm::type_id::create("order_fsm");
        virtio_ctrl_vq_test_catcher catcher;
        int unsigned qids[$];
        int unsigned expected_qids[$];
        string want[$];
        byte unsigned blocked_ctrl_data[];
        virtio_ctrl_ack_e blocked_ctrl_ack;
        bit ok;
        string why;

        mem.init_region(64'h7800_0000, 64'h7800_FFFF);
        iommu.log_to = transport;
        wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h0908);
        transport.mock_net_config.max_virtqueue_pairs = 2;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_all_queues(2, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 5))
            `uvm_fatal("CTRL_VQ_TEST", "queue-stop test setup did not create queues {0..4}")
        fsm.ops = ops;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("CTRL_VQ_TEST", why)
        fsm.set_topology(2, 5);

        // 未协商 RING_RESET：拒绝，不访问设备、不解映射，队列保留。
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b0;
        transport.log.delete();
        catcher = new("order_refuse_catcher");
        catcher.expect_error("ATOMIC_OPS", "*teardown_queue: config backend did not confirm queue_id=1 stopped*");
        catcher.expect_error("AUTO_FSM", "*reset_single_queue: queue 1 was not stopped*");
        catcher.expect_error("AUTO_FSM", "*configure_mq: shrinking 2->1 pairs requires VIRTIO_F_RING_RESET*");
        catcher.expect_error("ATOMIC_OPS",
            "*Function queue recovery is pending; verified device reset required before another control command*");
        uvm_report_cb::add(null, catcher);
        fsm.reset_single_queue(1);
        fsm.state = FSM_READY;
        fsm.configure_mq(1);
        blocked_ctrl_data = new[0];
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ,
                      VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      blocked_ctrl_data, blocked_ctrl_ack);
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 4) ||
            (blocked_ctrl_ack != VIRTIO_NET_CTRL_ACK_ERR) ||
            (transport.kick_count != 0) || (transport.log.size() != 0) ||
            (vq_mgr.get_queue_count() != 5) || (ops.mq_requests.size() != 0) ||
            !ops.queues_require_recovery())
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                {"queue stop without RING_RESET was not refused cleanly ",
                 "(caught=%0d ctrl_ack=%s kicks=%0d log=%p queues=%0d mq=%p)"},
                catcher.caught_count, blocked_ctrl_ack.name(),
                transport.kick_count, transport.log,
                vq_mgr.get_queue_count(), ops.mq_requests))

        // 未确认停队后禁止直接重建。先由 verified Function reset 统一停 DMA、释放旧
        // 拓扑，再重新协商并建队；这也验证 recovery 闸门只由确认完成的整复位清除。
        ops.device_reset_verified(ok);
        if (!ok || ops.queues_require_recovery() ||
            (vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_fatal("CTRL_VQ_TEST",
                "verified Function reset did not close the unconfirmed queue stop")
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        ops.setup_all_queues(2, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 5))
            `uvm_fatal("CTRL_VQ_TEST",
                "queue-stop test could not rebuild after verified recovery")
        fsm.set_topology(2, 5);
        fsm.state = FSM_READY;

        // 协商 RING_RESET：reset_single_queue 先 Q_RESET 再解映射，重建后队列 1 回到设备。
        transport.log.delete();
        transport.programmed_qids.delete();
        fsm.reset_single_queue(1);
        want = '{"qreset 1", "unmap", "unmap", "unmap"};
        expected_qids = '{1};
        if ((fsm.state == FSM_ERROR) || (transport.log != want) || !vq_mgr.has_queue(1) ||
            (transport.programmed_qids != expected_qids))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "reset_single_queue did not Q_RESET before unmapping (state=%s log=%p programmed=%p)",
                fsm.state.name(), transport.log, transport.programmed_qids))

        // MQ 缩容 2->1 走同一停队路径：每条队列先 Q_RESET 再解映射。
        transport.log.delete();
        fsm.configure_mq(1);
        want = '{"qreset 2", "unmap", "unmap", "unmap", "qreset 3", "unmap", "unmap", "unmap"};
        vq_mgr.get_queue_ids(qids);
        expected_qids = '{0, 1, 4};
        if ((fsm.state == FSM_ERROR) || (transport.log != want) || (qids != expected_qids))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "MQ shrink did not Q_RESET each queue before unmapping (state=%s log=%p queues=%p)",
                fsm.state.name(), transport.log, qids))

        ops.device_reset();
        if ((vq_mgr.get_queue_count() != 0) || (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST", "queue-stop test leaked queue resources")
        mem.leak_check();
        `uvm_info("CTRL_VQ_TEST", "queue stop via RING_RESET test PASSED", UVM_LOW)
    endtask
endclass : virtio_ctrl_vq_test

`endif // VIRTIO_CTRL_VQ_TEST_SV
