// 目录层次：examples/dpu_priv_ring；由 filelists/tests.f 编入维护回归的 DPU 私有环合同测试。
// 依赖预编译 host_mem_pkg、virtio_net_pkg 中的生产私有回调；字节黄金值来自 53 主机
// icpu-kernel-driver/txrx.h 在同平台 GCC 9.4 编译的 C 位字段探针。
// 测试拥有 Host memory、queue manager、回调与模拟设备 CQ 写入；所有环在结束时
// 释放。本文件不访问真实 DUT/MMIO，只验证驱动可见的描述符、通知值与回收语义。
`ifndef DPU_PRIV_RING_CONTRACT_TEST_SV
`define DPU_PRIV_RING_CONTRACT_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import host_mem_pkg::*;
import virtio_net_pkg::*;

// UVM 的 uvm_object 是抽象类型；这个最小具体 token 仅用于确认私有 CQ
// 返回的对象身份。测试创建并持有它，不把缓冲或 DMA 资源所有权交给回调。
class dpu_priv_test_token extends uvm_object;
    `uvm_object_utils(dpu_priv_test_token)

    // 创建无负载的身份 token；name 只供诊断，生命周期由所属测试管理。
    function new(string name = "dpu_priv_test_token");
        super.new(name);
    endfunction
endclass

// 通过真实 custom_virtqueue 接口走发布和完成，避免测试直接调用 packer 得到
// 自证结果。缩小的环用于 wrap；另用驱动默认 512 项检查实际内存几何。
class dpu_priv_ring_contract_test extends uvm_test;
    `uvm_component_utils(dpu_priv_ring_contract_test)

    host_mem_manager mem;
    virtio_iommu_model iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector err_inj;
    virtio_wait_policy wait_pol;
    virtqueue_manager manager;

    // 构造测试组件；资源直到 build_phase 才分配，仿真结束由 UVM 管理组件生命期。
    function new(string name = "dpu_priv_ring_contract_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 建立一个 Host-0 内存域与共享队列依赖；队列按需在各测试中创建，避免
    // 混淆 TX/RX 的独立环状态。内存或依赖为空时立即中止。
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        mem = host_mem_manager::type_id::create("dpu_priv_host0_mem");
        mem.set_host_id(0);
        mem.set_alloc_policy(HOST_MEM_FIRST_FIT);
        mem.init_region(64'h0000_0001_0000_0000,
                        64'h0000_0001_00ff_ffff, MODE_LINEAR, 16);
        if (!mem.is_initialized())
            `uvm_fatal("DPU_PRIV", "Host-0 memory initialization failed")

        iommu = virtio_iommu_model::type_id::create("dpu_priv_iommu");
        barrier = virtio_memory_barrier_model::type_id::create("dpu_priv_barrier");
        err_inj = virtqueue_error_injector::type_id::create("dpu_priv_err_inj");
        wait_pol = virtio_wait_policy::type_id::create("dpu_priv_wait_pol");
        manager = virtqueue_manager::type_id::create("dpu_priv_vq_manager");
        manager.mem = mem;
        manager.iommu = iommu;
        manager.barrier = barrier;
        manager.err_inj = err_inj;
        manager.wait_pol = wait_pol;
        manager.host_id = 0;
        manager.bdf = 16'h0100;
    endfunction

    // 从生产队列工厂创建 VQ_CUSTOM，然后在 alloc_rings 前注入方向专属回调。
    // qid 是 VIP 本地队列 ID，local_qid 则是驱动通知字中的 DPU 本地队列号。
    // 若工厂类型不符或回调未分配环，fatal 阻止后续读写无效地址。
    protected function void make_queue(
        input int unsigned qid,
        input int unsigned size,
        input bit tx_mode,
        input int unsigned local_qid,
        output custom_virtqueue vq,
        output dpu_priv_ring_callback cb
    );
        virtqueue_base base_vq;

        base_vq = manager.create_queue(qid, size, VQ_CUSTOM);
        if (!$cast(vq, base_vq))
            `uvm_fatal("DPU_PRIV", "queue manager did not create custom_virtqueue")
        cb = new($sformatf("dpu_priv_cb_%0d", qid), tx_mode, local_qid);
        vq.custom_cb = cb;
        vq.alloc_rings();
        if (vq.desc_table_addr == 0 || cb.cq_addr == 0)
            `uvm_fatal("DPU_PRIV", "private ring allocation failed")
    endfunction

    // 对比 Host memory 中的真实描述符/CQ 字节与 C 编译器黄金数组。长度和
    // 任一字节不一致都给出偏移并停止，避免只比较解码结果而遗漏保留位。
    protected function void expect_bytes(
        input bit [63:0] address,
        input byte expected[],
        input string label
    );
        byte actual[];

        mem.read_mem(address, expected.size(), actual);
        if (actual.size() != expected.size())
            `uvm_fatal("DPU_PRIV", $sformatf(
                "%s: size=%0d expected=%0d", label,
                actual.size(), expected.size()))
        foreach (expected[i]) begin
            if (actual[i] !== expected[i])
                `uvm_fatal("DPU_PRIV", $sformatf(
                    "%s byte[%0d]=%02h expected=%02h", label,
                    i, actual[i], expected[i]))
        end
    endfunction

    // 发布一条私有 TX 数据描述符并模拟 CQ 指针前进。期望的 16 字节是用
    // 与 txrx.h 相同的 C 位字段声明在 53 主机上生成；请求长度 2048 合法，
    // 与驱动分片上限一致。完成只看 CQ，不依赖描述符 used 位。
    protected task test_tx_layout_and_completion();
        custom_virtqueue tx;
        dpu_priv_ring_callback cb;
        virtio_sg_list sgs[];
        virtio_sg_entry entry;
        uvm_object sent_token;
        uvm_object returned_token;
        int unsigned head;
        int unsigned completed_len;
        byte golden[16] = '{8'hef, 8'hcd, 8'hab, 8'h89,
                            8'h67, 8'h45, 8'h23, 8'h01,
                            8'h00, 8'h08, 8'hf0, 8'haa,
                            8'h5a, 8'h3d, 8'h92, 8'h00};
        byte cq_done[2] = '{8'h01, 8'h80};

        make_queue(1, 8, 1, 1, tx, cb);
        if (tx.get_free_count() != 7)
            `uvm_fatal("DPU_PRIV", "TX queue did not reserve one empty slot")

        cb.dport_info = 12'habc;
        cb.dport_id = 10'h16a;
        cb.dport_type = 3'd5;
        cb.rss_lag = 1;
        cb.cpu_tx_cos = 3'd3;
        cb.l3_cs = 1;
        cb.l4_cs = 0;
        cb.fwd = 2'd2;

        entry.addr = 64'h0123_4567_89ab_cdef;
        entry.len = 2048;
        entry.is_indirect = 0;
        sgs = new[1];
        sgs[0].entries.push_back(entry);
        sent_token = dpu_priv_test_token::type_id::create("tx_golden_token");
        head = tx.add_buf(sgs, 1, 0, sent_token, 0);
        if (head != 0)
            `uvm_fatal("DPU_PRIV", "first TX descriptor did not use slot 0")
        expect_bytes(tx.desc_table_addr, golden, "private TX C ABI");

        tx.kick();
        if (cb.last_notify_word != 32'h8001_0001 || cb.notify_count != 1)
            `uvm_fatal("DPU_PRIV", "TX notify differs from driver 32-bit BAR value")
        if (barrier.wmb_count == 0)
            `uvm_fatal("DPU_PRIV", "TX descriptor publication lacks wmb")

        // 驱动私有 TX CQ 的 head_index=1、wrap=1，小端字节为 01 80。
        mem.write_mem(cb.cq_addr, cq_done);
        returned_token = null;
        completed_len = 0;
        if (!tx.poll_used(returned_token, completed_len) ||
            returned_token != sent_token || completed_len != 2048)
            `uvm_fatal("DPU_PRIV", "TX CQ did not reclaim the posted request")
        if (tx.poll_used(returned_token, completed_len) ||
            tx.get_free_count() != 7)
            `uvm_fatal("DPU_PRIV", "TX CQ reclaimed a request twice")

        manager.destroy_queue(1);
    endtask

    // 用单个 65537B SG 验证驱动的 64KiB DMA 分片：第一个 data desc
    // 覆盖 65536B，第二个从原地址顺延并覆盖 1B；next 只在首段置位。
    // 两条描述符算作同一包，CQ 越过链尾后只返回一个 token 和原始总长度。
    protected task test_tx_large_sg_split();
        custom_virtqueue tx;
        dpu_priv_ring_callback cb;
        virtio_sg_list sgs[];
        virtio_sg_entry entry;
        uvm_object sent_token;
        uvm_object returned_token;
        int unsigned head;
        int unsigned completed_len;
        byte first_desc[16] = '{8'h00, 8'h00, 8'h02, 8'h00,
                                8'h00, 8'h00, 8'h00, 8'h00,
                                8'h00, 8'h00, 8'h01, 8'h00,
                                8'h00, 8'h00, 8'h89, 8'h00};
        byte second_desc[16] = '{8'h00, 8'h00, 8'h03, 8'h00,
                                 8'h00, 8'h00, 8'h00, 8'h00,
                                 8'h01, 8'h00, 8'h00, 8'h00,
                                 8'h00, 8'h00, 8'h80, 8'h00};
        byte cq_done[2] = '{8'h02, 8'h80};

        make_queue(7, 8, 1, 7, tx, cb);
        entry.addr = 64'h0000_0000_0002_0000;
        entry.len = 65537;
        entry.is_indirect = 0;
        sgs = new[1];
        sgs[0].entries.push_back(entry);
        sent_token = dpu_priv_test_token::type_id::create("tx_split_token");

        head = tx.add_buf(sgs, 1, 0, sent_token, 0);
        if (head != 0 || tx.get_pending_count() != 1 ||
            tx.get_free_count() != 5)
            `uvm_fatal("DPU_PRIV", "TX 64KiB SG did not consume exactly two slots")
        expect_bytes(tx.desc_table_addr, first_desc, "TX first 64KiB segment");
        expect_bytes(tx.desc_table_addr + 16, second_desc, "TX second segment");

        tx.kick();
        if (cb.last_notify_word != 32'h8002_0007)
            `uvm_fatal("DPU_PRIV", "TX split tail notification differs from driver")
        mem.write_mem(cb.cq_addr, cq_done);
        returned_token = null;
        completed_len = 0;
        if (!tx.poll_used(returned_token, completed_len) ||
            returned_token != sent_token || completed_len != 65537 ||
            tx.get_free_count() != 7)
            `uvm_fatal("DPU_PRIV", "TX split CQ did not complete one whole packet")

        manager.destroy_queue(7);
    endtask

    // RX 发布仅填写 DMA 地址、2048 字节容量与两个 wrap 位；其余私有
    // 路由字段必须清零。先解析 GCC 黄金 CQ，再以单 buffer 完成一帧，
    // 确认长度取自 CQ 的 pkt_len 而非 posted 描述符的 len。
    protected task test_rx_layout_and_completion();
        custom_virtqueue rx;
        dpu_priv_ring_callback cb;
        virtio_sg_list sgs[];
        virtio_sg_entry entry;
        uvm_object sent_token;
        uvm_object returned_token;
        int unsigned head;
        int unsigned completed_len;
        int unsigned desc_num;
        int unsigned pkt_len;
        int unsigned head_idx;
        bit cq_wrap;
        byte golden[16] = '{8'hef, 8'hcd, 8'hab, 8'h89,
                            8'h67, 8'h45, 8'h23, 8'h01,
                            8'h00, 8'h08, 8'h00, 8'h00,
                            8'h00, 8'h00, 8'h80, 8'h00};
        byte cq_golden[16] = '{8'had, 8'h6a, 8'h69, 8'h2a,
                               8'h34, 8'h12, 8'hea, 8'hc5,
                               8'hbc, 8'h5a, 8'h00, 8'h00,
                               8'h00, 8'h00, 8'h00, 8'h00};
        byte cq_done[16] = '{8'h00, 8'h00, 8'h00, 8'h10,
                             8'h00, 8'h00, 8'hea, 8'h85,
                             8'h00, 8'h00, 8'h00, 8'h00,
                             8'h00, 8'h00, 8'h00, 8'h00};

        make_queue(0, 8, 0, 0, rx, cb);
        entry.addr = 64'h0123_4567_89ab_cdef;
        entry.len = 2048;
        entry.is_indirect = 0;
        sgs = new[1];
        sgs[0].entries.push_back(entry);
        sent_token = dpu_priv_test_token::type_id::create("rx_golden_token");
        head = rx.add_buf(sgs, 0, 1, sent_token, 0);
        if (head != 0)
            `uvm_fatal("DPU_PRIV", "first RX descriptor did not use slot 0")
        expect_bytes(rx.desc_table_addr, golden, "private RX C ABI");

        rx.kick();
        if (cb.last_notify_word != 32'h8001_0000)
            `uvm_fatal("DPU_PRIV", "RX notify differs from driver 32-bit BAR value")

        mem.write_mem(cb.cq_addr, cq_golden);
        expect_bytes(cb.cq_addr, cq_golden, "private RX CQ C ABI");
        if (!cb.decode_rx_cq(0, desc_num, pkt_len, cq_wrap, head_idx) ||
            desc_num != 2 || pkt_len != 1514 || !cq_wrap ||
            head_idx != 16'h1234)
            `uvm_fatal("DPU_PRIV", "RX CQ bitfield decoder differs from C ABI")

        // 当前回调只回收单 buffer 帧；把同一个槽改成 desc_num=1 的合法完成。
        mem.write_mem(cb.cq_addr, cq_done);
        returned_token = null;
        completed_len = 0;
        if (!rx.poll_used(returned_token, completed_len) ||
            returned_token != sent_token || completed_len != 1514)
            `uvm_fatal("DPU_PRIV", "RX CQ did not return packet length/token")
        if (rx.poll_used(returned_token, completed_len) ||
            rx.get_free_count() != 7)
            `uvm_fatal("DPU_PRIV", "RX CQ reclaimed a request twice")

        manager.destroy_queue(0);
    endtask

    // 驱动以 PAGE_SIZE 对齐描述符和紧邻其后的 CQ；512 项默认配置下
    // TX 是 8192B 描述符+2B CQ→12288B，RX 是 8192B+8192B→16384B。
    protected task test_default_geometry();
        custom_virtqueue tx;
        custom_virtqueue rx;
        dpu_priv_ring_callback tx_cb;
        dpu_priv_ring_callback rx_cb;

        make_queue(3, 512, 1, 3, tx, tx_cb);
        make_queue(2, 512, 0, 2, rx, rx_cb);
        if (tx_cb.cq_addr != tx.desc_table_addr + 8192 ||
            tx_cb.ring_alloc_bytes != 12288 ||
            (tx.desc_table_addr % 4096) != 0)
            `uvm_fatal("DPU_PRIV", "default TX ring/CQ geometry differs from driver")
        if (rx_cb.cq_addr != rx.desc_table_addr + 8192 ||
            rx_cb.ring_alloc_bytes != 16384 ||
            (rx.desc_table_addr % 4096) != 0)
            `uvm_fatal("DPU_PRIV", "default RX ring/CQ geometry differs from driver")
        manager.destroy_queue(3);
        manager.destroy_queue(2);
    endtask

    // 按缩小的 4 项 TX 环反复发布/完成，验证索引越过环尾时 avail/used
    // 与通知 wrap 翻转，且 CQ 消费后仍保持 N-1 容量。缩尺只加速状态测试，
    // 实际默认 512 项的字节几何另由 test_default_geometry 验证。
    protected task test_tx_wrap();
        custom_virtqueue tx;
        dpu_priv_ring_callback cb;
        virtio_sg_list sgs[];
        virtio_sg_entry entry;
        uvm_object sent[5];
        uvm_object returned_token;
        int unsigned head;
        int unsigned completed_len;
        byte cq_three[2] = '{8'h03, 8'h80};
        byte cq_wrapped[2] = '{8'h01, 8'h00};
        byte wrapped_desc[];

        make_queue(5, 4, 1, 5, tx, cb);
        sgs = new[1];
        entry.len = 64;
        entry.is_indirect = 0;

        for (int unsigned i = 0; i < 3; i++) begin
            entry.addr = 64'h2000 + i * 64;
            sgs[0].entries.delete();
            sgs[0].entries.push_back(entry);
            sent[i] = dpu_priv_test_token::type_id::create(
                $sformatf("wrap_token_%0d", i));
            head = tx.add_buf(sgs, 1, 0, sent[i], 0);
            if (head != i)
                `uvm_fatal("DPU_PRIV", "TX initial ring indices differ from driver")
        end
        if (tx.get_free_count() != 0)
            `uvm_fatal("DPU_PRIV", "TX ring failed to preserve one empty slot")
        tx.kick();
        if (cb.last_notify_word != 32'h8003_0005)
            `uvm_fatal("DPU_PRIV", "TX pre-wrap tail notification differs from driver")
        mem.write_mem(cb.cq_addr, cq_three);
        for (int unsigned i = 0; i < 3; i++) begin
            returned_token = null;
            if (!tx.poll_used(returned_token, completed_len) ||
                returned_token != sent[i] || completed_len != 64)
                `uvm_fatal("DPU_PRIV", "TX CQ wrap prelude returned wrong token")
        end

        for (int unsigned i = 3; i < 5; i++) begin
            entry.addr = 64'h2000 + i * 64;
            sgs[0].entries.delete();
            sgs[0].entries.push_back(entry);
            sent[i] = dpu_priv_test_token::type_id::create(
                $sformatf("wrap_token_%0d", i));
            head = tx.add_buf(sgs, 1, 0, sent[i], 0);
            if (head != (i % 4))
                `uvm_fatal("DPU_PRIV", "TX ring slot after wrap is wrong")
        end
        tx.kick();
        if (cb.last_notify_word != 32'h0001_0005 || cb.producer_wrap != 0)
            `uvm_fatal("DPU_PRIV", "TX wrapped notify/index differs from driver")
        mem.read_mem(tx.desc_table_addr, 16, wrapped_desc);
        if ((wrapped_desc[14] & 8'h80) != 0 ||
            (wrapped_desc[15] & 8'h80) == 0)
            `uvm_fatal("DPU_PRIV", "wrapped descriptor avail/used bits not flipped")

        mem.write_mem(cb.cq_addr, cq_wrapped);
        for (int unsigned i = 3; i < 5; i++) begin
            returned_token = null;
            if (!tx.poll_used(returned_token, completed_len) ||
                returned_token != sent[i] || completed_len != 64)
                `uvm_fatal("DPU_PRIV", "TX CQ post-wrap token mismatch")
        end
        if (tx.get_free_count() != 3)
            `uvm_fatal("DPU_PRIV", "TX post-wrap capacity is wrong")

        manager.destroy_queue(5);
    endtask

    // 依序执行位布局、通知、回收、默认几何及 wrap 检查；全部成功后归还
    // 环分配并运行 Host memory/IOMMU 泄漏检查，失败由各 task 抛 UVM_FATAL。
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_tx_layout_and_completion();
        test_tx_large_sg_split();
        test_rx_layout_and_completion();
        test_default_geometry();
        test_tx_wrap();
        manager.destroy_all();
        mem.leak_check();
        iommu.leak_check();
        `uvm_info("DPU_PRIV", "DPU private TX/RX ring contract PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass

`endif
