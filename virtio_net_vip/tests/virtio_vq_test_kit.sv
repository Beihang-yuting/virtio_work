`ifndef VIRTIO_VQ_TEST_KIT_SV
`define VIRTIO_VQ_TEST_KIT_SV

import uvm_pkg::*;
import dpu_resource_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// 目录层次：tests。virtqueue 级测试公共件：一套共享支撑对象（barrier、error
// injector、wait policy、queue manager）、split/packed 队列创建、atomic ops 接线，
// 以及设备侧 used ring 写回和 packed USED 标志写回。Host memory 与 IOMMU 由调用方
// 提供（可以是测试子类），本类不拥有它们的生命周期。
class virtio_vq_test_kit extends uvm_object;
    `uvm_object_utils(virtio_vq_test_kit)

    host_mem_manager            mem;
    virtio_iommu_model          iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector    err_inj;
    virtio_wait_policy          wait_pol;
    virtqueue_manager           vq_mgr;
    int unsigned                host_id;

    function new(string name = "virtio_vq_test_kit");
        super.new(name);
    endfunction

    // 以 prefix 命名新建 barrier/err_inj/wait_pol；vq_mgr 为空时新建，否则复用调用方
    // 的 manager（例如 Function 自带的 vq_mgr）。共享引用、bdf 与 host_id 写入 manager。
    static function virtio_vq_test_kit create_kit(
        string prefix,
        host_mem_manager mem,
        virtio_iommu_model iommu,
        bit [15:0] bdf,
        int unsigned host_id = 0,
        virtqueue_manager vq_mgr = null
    );
        virtio_vq_test_kit kit;

        kit = virtio_vq_test_kit::type_id::create({prefix, "_kit"});
        kit.mem = mem;
        kit.iommu = iommu;
        kit.host_id = host_id;
        kit.barrier = virtio_memory_barrier_model::type_id::create({prefix, "_barrier"});
        kit.err_inj = virtqueue_error_injector::type_id::create({prefix, "_err_inj"});
        kit.wait_pol = virtio_wait_policy::type_id::create({prefix, "_wait_pol"});
        if (vq_mgr == null)
            vq_mgr = virtqueue_manager::type_id::create({prefix, "_vq_mgr"});
        kit.vq_mgr = vq_mgr;
        kit.vq_mgr.mem = mem;
        kit.vq_mgr.iommu = iommu;
        kit.vq_mgr.barrier = kit.barrier;
        kit.vq_mgr.err_inj = kit.err_inj;
        kit.vq_mgr.wait_pol = kit.wait_pol;
        kit.vq_mgr.bdf = bdf;
        kit.vq_mgr.host_id = host_id;
        return kit;
    endfunction

    // 中文说明：单元测试用的 host0 PCIe identity（segment 0，BDF 由调用方给出）。
    // 取代旧的“transport 未配置 identity 时默认 host0”兼容路径。
    static function dpu_pcie_function_id_t host0_pcie_id(input bit [15:0] bdf);
        dpu_pcie_function_id_t pcie_id;
        pcie_id.domain.host_id = 0;
        pcie_id.domain.segment_id = 0;
        pcie_id.bdf = bdf;
        return pcie_id;
    endfunction

    // 独立创建（不登记到 vq_mgr）并分配一个 split 队列，供只测队列本身的用例。
    function split_virtqueue make_split(
        string name, int unsigned queue_id, int unsigned queue_size, bit [15:0] bdf
    );
        split_virtqueue vq;

        vq = split_virtqueue::type_id::create(name);
        vq.setup(queue_id, queue_size, mem, iommu, barrier, err_inj, wait_pol,
                 bdf, host_id);
        vq.alloc_rings();
        return vq;
    endfunction

    // 独立创建（不登记到 vq_mgr）并分配一个 packed 队列。
    function packed_virtqueue make_packed(
        string name, int unsigned queue_id, int unsigned queue_size, bit [15:0] bdf
    );
        packed_virtqueue vq;

        vq = packed_virtqueue::type_id::create(name);
        vq.setup(queue_id, queue_size, mem, iommu, barrier, err_inj, wait_pol,
                 bdf, host_id);
        vq.alloc_rings();
        return vq;
    endfunction

    // 经 vq_mgr.create_queue 登记并分配一个 split 队列，供 atomic ops 按 queue_id 查找。
    function split_virtqueue add_split(int unsigned queue_id, int unsigned queue_size);
        split_virtqueue vq;

        if (!$cast(vq, vq_mgr.create_queue(queue_id, queue_size, VQ_SPLIT)))
            `uvm_fatal("VQ_TEST_KIT", $sformatf(
                "could not create managed split queue %0d", queue_id))
        vq.alloc_rings();
        return vq;
    endfunction

    // 经 vq_mgr.create_queue 登记并分配一个 packed 队列。
    function packed_virtqueue add_packed(int unsigned queue_id, int unsigned queue_size);
        packed_virtqueue vq;

        if (!$cast(vq, vq_mgr.create_queue(queue_id, queue_size, VQ_PACKED)))
            `uvm_fatal("VQ_TEST_KIT", $sformatf(
                "could not create managed packed queue %0d", queue_id))
        vq.alloc_rings();
        return vq;
    endfunction

    // 标准 Function 的配置后端由 virtio_function_instance 在提交时下发；不经 Function
    // 直接装配 ops 的测试用本函数显式注入 common-config 后端。
    static function void bind_common_backend(virtio_atomic_ops ops);
        ops.config_backend = virtio_common_cfg_backend::type_id::create(
            {ops.get_name(), "_cfg_backend"});
    endfunction

    // 把 ops 接到本套件的 vq_mgr/mem/iommu/wait_pol 与给定 transport；ops 为空时新建
    // 标准 virtio_atomic_ops。不修改 transport.bdf，由调用方设置。
    function virtio_atomic_ops make_ops(
        virtio_pci_transport transport, string name = "", virtio_atomic_ops ops = null
    );
        if (ops == null)
            ops = virtio_atomic_ops::type_id::create(name);
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        bind_common_backend(ops);
        return ops;
    endfunction

    // 设备侧 split 完成：在 used ring 第 used_slot 槽写入小端 {id=head, len=used_len}，
    // 再把 used.idx 写为 used_idx。槽位取模与 idx 递增由调用方负责，同一函数覆盖
    // 顺序、乱序与回绕场景。
    static function void complete_split_at(
        host_mem_manager mem,
        virtqueue_base vq,
        int unsigned used_slot,
        int unsigned head,
        int unsigned used_len,
        int unsigned used_idx
    );
        byte entry[];
        byte idx_bytes[];

        entry = new[8];
        for (int unsigned i = 0; i < 4; i++) begin
            entry[i]     = head[i * 8 +: 8];
            entry[i + 4] = used_len[i * 8 +: 8];
        end
        idx_bytes = new[2];
        idx_bytes[0] = used_idx[7:0];
        idx_bytes[1] = used_idx[15:8];
        mem.write_mem(vq.device_ring_addr + 4 + used_slot * 8, entry);
        mem.write_mem(vq.device_ring_addr + 2, idx_bytes);
    endfunction

    // 模拟标准设备：读取链尾 ID，只写一个 used 项，清 NEXT 并正确处理两种 wrap。
    // 不读取 VIP 的 token/链记录，使测试能够发现错误的 ID 约定和回收长度。
    extern static function void complete_packed(
        host_mem_manager	mem,
        virtqueue_base	vq,
        int unsigned	head
    );
endclass : virtio_vq_test_kit

// 完成项覆盖链头；链尾的 Buffer ID 与 used flags 是设备唯一需要交还的身份。
function void virtio_vq_test_kit::complete_packed(
    host_mem_manager	mem,
    virtqueue_base	vq,
    int unsigned	head
);
    byte		data[];
    byte		completion[4];
    bit [15:0]	flags;
    bit [15:0]	buffer_id;
    bit		wrap;
    int unsigned	slot;
    int unsigned	count;

    mem.read_mem(vq.desc_table_addr + head * 16, 16, data);
    wrap = (data[14] & 8'h80) != 0;
    slot = head;
    count = 0;
    do begin
        mem.read_mem(vq.desc_table_addr + slot * 16, 16, data);
        buffer_id = {data[13], data[12]};
        flags = {data[15], data[14]};
        slot = (slot + 1) % vq.queue_size;
        count++;
        if (count > vq.queue_size) begin
            `uvm_fatal("PACKED_DEVICE", "descriptor chain exceeds ring size")
            return;
        end
    end while ((flags & VIRTQ_DESC_F_NEXT) != 0);

    flags = wrap ? (VIRTQ_DESC_F_AVAIL | VIRTQ_DESC_F_USED) : 0;
    completion = '{buffer_id[7:0], buffer_id[15:8], flags[7:0], flags[15:8]};
    mem.write_mem(vq.desc_table_addr + head * 16 + 12, completion);
endfunction

`endif // VIRTIO_VQ_TEST_KIT_SV
