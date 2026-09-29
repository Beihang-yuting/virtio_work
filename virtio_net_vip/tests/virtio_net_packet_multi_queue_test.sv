// tests/：多队列报文端到端回归；依赖 net_packet_pkg 的报文类型与模板枚举，
// 以及 virtio_net_pkg 的队列、TX/RX 引擎。测试拥有创建的 packet_item 和队列
// 句柄，运行阶段由 UVM 管理；外部 package 各只编译一次以保持类型身份一致。
`ifndef VIRTIO_NET_PACKET_MULTI_QUEUE_TEST_SV
`define VIRTIO_NET_PACKET_MULTI_QUEUE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import net_packet_pkg::*;
import virtio_net_pkg::*;

// 中文说明：真实 net_packet 多队列数据面测试。
//
// 队列布局固定为：
//   q0/q2：RX；q1/q3：TX。
// 四个 split virtqueue 共享同一个 Host memory、IOMMU、BDF 和
// virtqueue_manager。TX 侧检查 descriptor 中的 IOVA 是否能经 IOMMU
// 读回原始报文；RX 侧通过 write_from_device_for_host() 写回 IOVA，
// 再由 RX engine 从 used ring 恢复 packet_item。这样测试覆盖了：
//   packet_item -> TX descriptor -> IOVA/GPA -> used completion
//   device DMA write -> RX descriptor -> IOVA/GPA -> packet_item
class virtio_net_packet_multi_queue_test extends uvm_test;
    `uvm_component_utils(virtio_net_packet_multi_queue_test)

    localparam int unsigned QUEUE_SIZE = 8;
    localparam int unsigned PACKETS_PER_QUEUE = 4;
    localparam bit [15:0] DEVICE_BDF = 16'h0800;

    virtio_shared_mem_fixture mem_fixture;
    host_mem_manager         mem;
    virtio_iommu_model       iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector err_inj;
    virtio_wait_policy       wait_pol;
    virtqueue_manager        vq_mgr;
    virtio_net_dataplane     dataplane;
    split_virtqueue          queues[int unsigned];

    packet_item              tx_packets[int unsigned][$];
    int unsigned             tx_descs[int unsigned][$];
    packet_item              rx_packets[int unsigned][$];
    int unsigned             rx_descs[int unsigned][$];

    function new(string name = "virtio_net_packet_multi_queue_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ------------------------------------------------------------------
    // Host-memory ring helpers.  Split-ring fields are little-endian.
    // ------------------------------------------------------------------
    function bit [15:0] read_u16(bit [63:0] addr);
        byte data[];
        mem.read_mem(addr, 2, data);
        return {data[1], data[0]};
    endfunction

    function bit [31:0] read_u32(bit [63:0] addr);
        byte data[];
        mem.read_mem(addr, 4, data);
        return {data[3], data[2], data[1], data[0]};
    endfunction

    function bit [63:0] read_u64(bit [63:0] addr);
        byte data[];
        bit [63:0] value;
        mem.read_mem(addr, 8, data);
        value = {data[7], data[6], data[5], data[4],
                 data[3], data[2], data[1], data[0]};
        return value;
    endfunction

    function void read_descriptor(
        split_virtqueue vq,
        int unsigned desc_id,
        output bit [63:0] addr,
        output bit [31:0] len,
        output bit [15:0] flags,
        output bit [15:0] next
    );
        bit [63:0] raw_addr;
        raw_addr = read_u64(vq.desc_table_addr + desc_id * 16);
        addr  = raw_addr;
        len   = read_u32(vq.desc_table_addr + desc_id * 16 + 8);
        flags = read_u16(vq.desc_table_addr + desc_id * 16 + 12);
        next  = read_u16(vq.desc_table_addr + desc_id * 16 + 14);
    endfunction

    function void write_used_entry(
        split_virtqueue vq,
        int unsigned used_slot,
        int unsigned desc_id,
        int unsigned used_len,
        int unsigned used_count
    );
        byte id_bytes[4];
        byte len_bytes[4];
        byte idx_bytes[2];
        bit [63:0] entry_addr;

        entry_addr = vq.device_ring_addr + 4 + used_slot * 8;
        id_bytes[0] = desc_id[7:0];
        id_bytes[1] = desc_id[15:8];
        id_bytes[2] = desc_id[23:16];
        id_bytes[3] = desc_id[31:24];
        len_bytes[0] = used_len[7:0];
        len_bytes[1] = used_len[15:8];
        len_bytes[2] = used_len[23:16];
        len_bytes[3] = used_len[31:24];
        idx_bytes[0] = used_count[7:0];
        idx_bytes[1] = used_count[15:8];
        mem.write_mem(entry_addr, id_bytes);
        mem.write_mem(entry_addr + 4, len_bytes);
        mem.write_mem(vq.device_ring_addr + 2, idx_bytes);
    endfunction

    function packet_item make_packet(string name, int unsigned length);
        packet_item item;

        item = packet_item::type_id::create(name);
        assert(item.pkt.randomize() with {
            pkt_kind == ETH_IPV4_TCP;
            pkt_len == length;
        }) else `uvm_fatal("NET_PACKET_TEST", "packet randomization failed")
        // post_randomize() normally packs automatically; call explicitly so
        // this helper also remains valid with older net_packet revisions.
        item.pkt.do_pack();
        return item;
    endfunction

    function void build_rx_bytes(
        packet_item item,
        output byte data[]
    );
        virtio_net_hdr_t hdr;
        byte unsigned hdr_bytes[$];
        byte unsigned packet_bytes[$];

        hdr = '{default: 0};
        virtio_net_hdr_util::pack_hdr(hdr, 64'h0, hdr_bytes);
        assert(virtio_net_packet_adapter::pack(item, packet_bytes))
            else `uvm_fatal("NET_PACKET_TEST", "failed to pack RX packet")
        data = new[hdr_bytes.size() + packet_bytes.size()];
        foreach (hdr_bytes[i])
            data[i] = hdr_bytes[i];
        foreach (packet_bytes[i])
            data[hdr_bytes.size() + i] = packet_bytes[i];
    endfunction

    // Check the two direct TX descriptors and read both buffers through the
    // IOMMU translation boundary.  A successful check proves the descriptor
    // contains device-visible IOVA rather than a raw Host GPA.
    function bit check_tx_chain(
        split_virtqueue vq,
        int unsigned head,
        packet_item expected
    );
        bit [63:0] hdr_iova, data_iova, gpa;
        bit [31:0] hdr_len, data_len;
        bit [15:0] hdr_flags, data_flags, next;
        bit [15:0] data_next;
        iommu_fault_e fault;
        byte hdr_data[];
        byte payload_data[];
        byte unsigned expected_data[$];

        read_descriptor(vq, head, hdr_iova, hdr_len, hdr_flags, next);
        if (!(hdr_flags & VIRTQ_DESC_F_NEXT))
            return 0;
        read_descriptor(vq, next, data_iova, data_len, data_flags, data_next);
        if ((data_flags & VIRTQ_DESC_F_NEXT) || data_next != 0)
            return 0;
        if (hdr_len != virtio_net_hdr_util::get_hdr_size(64'h0))
            return 0;
        if (!iommu.translate_for_host(0, DEVICE_BDF, hdr_iova, hdr_len,
                                      DMA_TO_DEVICE, gpa, fault))
            return 0;
        mem.read_mem(gpa, hdr_len, hdr_data);
        foreach (hdr_data[i])
            if (hdr_data[i] != 0)
                return 0;

        assert(virtio_net_packet_adapter::pack(expected, expected_data))
            else return 0;
        if (data_len != expected_data.size())
            return 0;
        if (!iommu.translate_for_host(0, DEVICE_BDF, data_iova, data_len,
                                      DMA_TO_DEVICE, gpa, fault))
            return 0;
        mem.read_mem(gpa, data_len, payload_data);
        if (payload_data.size() != expected_data.size())
            return 0;
        foreach (expected_data[i])
            if (payload_data[i] != expected_data[i])
                return 0;
        return 1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [63:0] features = 64'h0;
        int unsigned tx_qids[2] = '{1, 3};
        int unsigned rx_qids[2] = '{0, 2};

        phase.raise_objection(this);

        // One shared Host memory and one IOMMU namespace model the common
        // Host domain used by multiple VIO queues on a real function.
        mem_fixture = virtio_shared_mem_fixture::type_id::create(
            "packet_mem_fixture");
        if (!mem_fixture.create_host(
                0, 64'h0000_0001_2000_0000,
                64'h0000_0001_23FF_FFFF, HOST_MEM_RANDOM))
            `uvm_fatal("NET_PACKET_TEST", "failed to create shared Host-0 memory")
        mem      = mem_fixture.get_host(0);
        if (mem == null)
            `uvm_fatal("NET_PACKET_TEST", "shared Host-0 memory handle is null")
        iommu    = virtio_iommu_model::type_id::create("multi_queue_iommu");
        barrier  = virtio_memory_barrier_model::type_id::create("multi_queue_barrier");
        err_inj  = virtqueue_error_injector::type_id::create("multi_queue_err_inj");
        wait_pol = virtio_wait_policy::type_id::create("multi_queue_wait_pol");
        vq_mgr   = virtqueue_manager::type_id::create("multi_queue_vq_mgr");
        dataplane = virtio_net_dataplane::type_id::create("multi_queue_dataplane");

        begin
            string iova_why;
            assert(iommu.configure_iova_aperture(
                   64'h0000_0001_0000_0000,
                   64'h0000_0001_1000_0000,
                   IOMMU_IOVA_RANDOM, iova_why))
            else `uvm_fatal("NET_PACKET_TEST", "failed to configure IOVA aperture")
        end
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.host_id = 0;
        vq_mgr.bdf = DEVICE_BDF;

        // Four independent split queues, each with four outstanding packets.
        for (int unsigned qid = 0; qid < 4; qid++) begin
            virtqueue_base base_vq;
            base_vq = vq_mgr.create_queue(qid, QUEUE_SIZE, VQ_SPLIT);
            assert($cast(queues[qid], base_vq))
                else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                    "queue %0d is not a split virtqueue", qid))
            queues[qid].alloc_rings();
            assert(queues[qid].get_free_count() == QUEUE_SIZE)
                else `uvm_fatal("NET_PACKET_TEST", "queue ring allocation failed")
        end

        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE,
                            2048, 0, vq_mgr, mem, iommu, DEVICE_BDF, 0);

        // ----------------------------- TX q1/q3 -------------------------
        for (int unsigned qsel = 0; qsel < 2; qsel++) begin
            int unsigned qid = tx_qids[qsel];
            for (int unsigned i = 0; i < PACKETS_PER_QUEUE; i++) begin
                packet_item item;
                int unsigned desc_id;
                item = make_packet($sformatf("tx_q%0d_pkt%0d", qid, i),
                                   128 + i * 16);
                tx_packets[qid].push_back(item);
                desc_id = '1;
                dataplane.tx_engine.submit_packet(qid, item, 1'b0, desc_id);
                assert(desc_id != '1)
                    else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                        "TX q%0d packet %0d was not submitted", qid, i))
                tx_descs[qid].push_back(desc_id);
                assert(read_u16(queues[qid].driver_ring_addr + 2) == i + 1)
                    else `uvm_fatal("NET_PACKET_TEST", "TX avail index mismatch")
                assert(read_u16(queues[qid].driver_ring_addr + 4 + i * 2) == desc_id)
                    else `uvm_fatal("NET_PACKET_TEST", "TX avail descriptor mismatch")
                assert(check_tx_chain(queues[qid], desc_id, item))
                    else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                        "TX q%0d descriptor/IOMMU payload mismatch", qid))
            end
            assert(queues[qid].get_free_count() == QUEUE_SIZE - 2 * PACKETS_PER_QUEUE)
                else `uvm_fatal("NET_PACKET_TEST", "TX queue free count mismatch")

            for (int unsigned i = 0; i < PACKETS_PER_QUEUE; i++)
                write_used_entry(queues[qid], i, tx_descs[qid][i],
                                 10 + tx_packets[qid][i].pkt.raw_data.size(), i + 1);

            begin
                uvm_object completed[$];
                dataplane.tx_engine.complete_tx(qid, PACKETS_PER_QUEUE, completed);
                assert(completed.size() == PACKETS_PER_QUEUE)
                    else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                        "TX q%0d completion count mismatch", qid))
                assert(queues[qid].get_free_count() == QUEUE_SIZE)
                    else `uvm_fatal("NET_PACKET_TEST", "TX descriptors not reclaimed")
            end
        end

        // ----------------------------- RX q0/q2 -------------------------
        for (int unsigned qsel = 0; qsel < 2; qsel++) begin
            int unsigned qid = rx_qids[qsel];
            dataplane.rx_engine.refill_buffers(qid, PACKETS_PER_QUEUE);
            assert(read_u16(queues[qid].driver_ring_addr + 2) == PACKETS_PER_QUEUE)
                else `uvm_fatal("NET_PACKET_TEST", "RX avail index mismatch")

            for (int unsigned i = 0; i < PACKETS_PER_QUEUE; i++) begin
                packet_item item;
                bit [63:0] buf_iova;
                bit [31:0] buf_len;
                bit [15:0] buf_flags;
                bit [15:0] buf_next;
                bit [63:0] desc_id;
                byte rx_data[];
                iommu_fault_e fault;

                item = make_packet($sformatf("rx_q%0d_pkt%0d", qid, i),
                                   192 + i * 16);
                rx_packets[qid].push_back(item);
                desc_id = read_u16(queues[qid].driver_ring_addr + 4 + i * 2);
                rx_descs[qid].push_back(desc_id);
                read_descriptor(queues[qid], desc_id, buf_iova, buf_len,
                                buf_flags, buf_next);
                assert((buf_flags & VIRTQ_DESC_F_WRITE) && buf_len >= 2048)
                    else `uvm_fatal("NET_PACKET_TEST", "RX buffer descriptor invalid")
                build_rx_bytes(item, rx_data);
                assert(rx_data.size() <= buf_len)
                    else `uvm_fatal("NET_PACKET_TEST", "RX packet exceeds buffer")
                assert(iommu.write_from_device_for_host(
                           0, mem, DEVICE_BDF, buf_iova, rx_data, fault))
                    else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                        "RX q%0d device DMA write failed (%s)", qid, fault.name()))
                write_used_entry(queues[qid], i, desc_id, rx_data.size(), i + 1);
            end

            begin
                uvm_object received[$];
                dataplane.rx_engine.receive_packets(qid, PACKETS_PER_QUEUE,
                                                    received);
                assert(received.size() == PACKETS_PER_QUEUE)
                    else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                        "RX q%0d receive count mismatch", qid))
                foreach (received[i]) begin
                    packet_item actual;
                    assert($cast(actual, received[i]))
                        else `uvm_fatal("NET_PACKET_TEST", "RX did not restore packet_item")
                    assert(virtio_net_packet_adapter::compare(
                               rx_packets[qid][i], actual))
                        else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                            "RX q%0d packet %0d raw bytes mismatch", qid, i))
                end
                assert(queues[qid].get_free_count() == QUEUE_SIZE)
                    else `uvm_fatal("NET_PACKET_TEST", "RX descriptors not reclaimed")
            end
        end

        dataplane.cleanup_all();
        foreach (queues[qid])
            queues[qid].free_rings();
        vq_mgr.leak_check();
        iommu.leak_check();
        mem.leak_check();
        assert(iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("NET_PACKET_TEST", "IOMMU mappings leaked")

        `uvm_info("NET_PACKET_TEST",
                  "packet_item multi-queue TX/RX dataplane test PASSED",
                  UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass : virtio_net_packet_multi_queue_test

`endif
