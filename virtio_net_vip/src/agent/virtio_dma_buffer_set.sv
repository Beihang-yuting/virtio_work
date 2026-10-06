// 目录层次：src/agent；一次提交（TX/RX/control VQ/Admin VQ）涉及的普通数据 DMA
// 缓冲集合，负责 alloc → write → map → 失败回滚 → 退休。本类不报告错误，由调用方
// 用自己的报告 ID 说明失败原因。所有权经 disown（交给 ops 的 TX/RX 跟踪表）或
// quarantine_into（设备未确认停 DMA）转出后，release_all 不再触碰这些资源。
// 释放顺序：先按添加顺序 unmap 已映射项，再按添加顺序 free 全部 GPA。
`ifndef VIRTIO_DMA_BUFFER_SET_SV
`define VIRTIO_DMA_BUFFER_SET_SV

class virtio_dma_buffer_set extends uvm_object;
    `uvm_object_utils(virtio_dma_buffer_set)

    protected host_mem_manager   mem;
    protected virtio_iommu_model iommu;
    protected int unsigned       host_id;
    protected bit [15:0]         bdf;

    // 四个并行队列，索引即 alloc() 的返回值。
    protected bit [63:0]   gpas[$];
    protected bit [63:0]   iovas[$];
    protected int unsigned sizes[$];
    protected bit          mapped[$];

    // 构造空集合；alloc 之前必须先 bind_domain。
    function new(string name = "virtio_dma_buffer_set");
        super.new(name);
    endfunction

    // 绑定本次提交使用的 Host memory、IOMMU 和 {host_id, bdf} 请求者域。
    function void bind_domain(host_mem_manager m, virtio_iommu_model io,
                              int unsigned hid, bit [15:0] requester_bdf);
        mem     = m;
        iommu   = io;
        host_id = hid;
        bdf     = requester_bdf;
    endfunction

    // 分配 size 字节并登记，返回索引；分配失败返回 -1 且不登记。
    function int alloc(int unsigned size, int unsigned align = 1);
        bit [63:0] gpa;

        gpa = mem.alloc(size, .align(align));
        if (gpa == '1)
            return -1;
        gpas.push_back(gpa);
        iovas.push_back(64'h0);
        sizes.push_back(size);
        mapped.push_back(1'b0);
        return gpas.size() - 1;
    endfunction

    // 把 data 写到第 idx 个缓冲起始处（长度可小于分配长度）。
    function void write(int unsigned idx, byte data[]);
        mem.write_mem(gpas[idx], data);
    endfunction

    // 用 value 填满第 idx 个缓冲的整个分配长度。
    function void fill(int unsigned idx, byte value);
        mem.mem_set(gpas[idx], value, sizes[idx]);
    endfunction

    // 按分配长度映射第 idx 个缓冲；IOVA 为 '1 或 0 视为失败并返回 0，
    // 失败项不标记为已映射，release_all 只释放其 GPA。
    function bit map(int unsigned idx, dma_dir_e dir);
        bit [63:0] iova;

        iova = iommu.map_for_host(host_id, bdf, gpas[idx], sizes[idx], dir);
        if ((iova == '1) || (iova == 0))
            return 0;
        iovas[idx]  = iova;
        mapped[idx] = 1'b1;
        return 1;
    endfunction

    function bit [63:0] get_gpa(int unsigned idx);
        return gpas[idx];
    endfunction

    function bit [63:0] get_iova(int unsigned idx);
        return iovas[idx];
    endfunction

    function int unsigned count();
        return gpas.size();
    endfunction

    function int unsigned get_host_id();
        return host_id;
    endfunction

    function bit [15:0] get_bdf();
        return bdf;
    endfunction

    // 回滚或退休：先 unmap 全部已映射项，再 free 全部 GPA，最后清空登记。
    // 只能在设备不会再访问这些缓冲时调用（未提交、已完成或已确认复位）。
    function void release_all();
        foreach (mapped[i]) begin
            if (mapped[i])
                iommu.unmap_for_host(host_id, bdf, iovas[i]);
        end
        foreach (gpas[i])
            mem.free(gpas[i]);
        clear();
    endfunction

    // 所有权已转交其他记录（例如 ops 的 tx/rx_dma_map），只清登记。
    function void disown();
        clear();
    endfunction

    // 设备未确认停止 DMA：把已映射 IOVA 与全部 GPA 按添加顺序追加到隔离列表，
    // 本集合放弃所有权，由隔离列表的持有者在确认复位后回收。
    function void quarantine_into(ref bit [63:0] q_iovas[$], ref bit [63:0] q_gpas[$]);
        foreach (mapped[i]) begin
            if (mapped[i])
                q_iovas.push_back(iovas[i]);
        end
        foreach (gpas[i])
            q_gpas.push_back(gpas[i]);
        clear();
    endfunction

    protected function void clear();
        gpas.delete();
        iovas.delete();
        sizes.delete();
        mapped.delete();
    endfunction
endclass : virtio_dma_buffer_set

`endif // VIRTIO_DMA_BUFFER_SET_SV
