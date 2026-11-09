`ifndef PACKED_VIRTQUEUE_SV
`define PACKED_VIRTQUEUE_SV

// src/virtqueue：标准 Packed ring 的描述符发布与完成回收。依赖 Host memory、
// IOMMU 和 virtqueue_base；队列拥有 ring、间接表及链记录，报文 DMA 归 atomic ops。
// 一条链共用一个 Buffer ID，链尾 ID 供设备回写。本地保存分配 ID/链长度，不能依赖
// 设备保留 NEXT 或逐项回写；完成只在 AVAIL/USED 同时匹配当前 wrap 时可见。
// 队列迁移同时保存 ring 字节和本地链记录；free/reset/detach 清理记录，避免悬空 token。

class packed_virtqueue extends virtqueue_base;
    `uvm_object_utils(packed_virtqueue)

    // ===== Internal state =====
    protected int unsigned next_avail_idx;
    protected int unsigned next_used_idx;
    protected bit          avail_wrap_counter;
    protected bit          used_wrap_counter;
    protected bit          event_idx_enabled;
    protected bit          in_order_enabled;
    protected int unsigned desc_ring_size;
    protected bit [63:0]   driver_event_addr;
    protected bit [63:0]   device_event_addr;

    // Free descriptor ID management
    protected int unsigned			free_id_list[$];
    protected virtqueue_packed_chain_t	chains[int unsigned];

    // 摘除 token 时一并清除本地链记录；调用方仍须先确认设备已经停止 DMA。
    extern virtual function void detach_all_unused(ref uvm_object	tokens[$]);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    // 构造函数：索引清零、两个 wrap counter 按 virtio 规范置 1（首圈 AVAIL=1/
    // USED=0 的判定基准）；真正可用要等 setup()+alloc_rings()。
    function new(string name = "packed_virtqueue");
        super.new(name);
        next_avail_idx     = 0;
        next_used_idx      = 0;
        avail_wrap_counter = 1;
        used_wrap_counter  = 1;
        event_idx_enabled  = 0;
        in_order_enabled   = 0;
        desc_ring_size     = 0;
        log_tag            = "PACKED_VQ";
    endfunction

    // =================================================================
    // Helper methods -- byte-level packing for host_mem access
    // =================================================================

    // Write a single 16-byte packed descriptor entry to host_mem
    //   Offset 0:  addr[63:0]   (8 bytes, LE)
    //   Offset 8:  len[31:0]    (4 bytes, LE)
    //   Offset 12: id[15:0]     (2 bytes, LE)
    //   Offset 14: flags[15:0]  (2 bytes, LE)
    protected function void write_packed_desc(int unsigned idx,
                                              bit [63:0] addr,
                                              bit [31:0] len,
                                              bit [15:0] id,
                                              bit [15:0] flags);
        byte data[16];
        for (int i = 0; i < 8; i++) data[i]    = addr[i*8 +: 8];
        for (int i = 0; i < 4; i++) data[8+i]  = len[i*8 +: 8];
        for (int i = 0; i < 2; i++) data[12+i] = id[i*8 +: 8];
        for (int i = 0; i < 2; i++) data[14+i] = flags[i*8 +: 8];
        mem.write_mem(desc_table_addr + idx * 16, data);
    endfunction

    // 间接表项按 pvirtq_desc 布局写（virtio 1.1 §2.8.19）：addr、len、id、flags。表内描述符
    // 顺序排列、数量为 len/16，不使用 NEXT 与 next；buffer id 只取自主环描述符，表项 id 写 0。
    protected virtual function void write_indirect_desc(
        bit [63:0] table_gpa,
        int unsigned index,
        bit [63:0] addr,
        bit [31:0] len,
        bit [15:0] flags,
        bit [15:0] next
    );
        byte data[16];
        bit [15:0] pflags;

        pflags = flags & ~VIRTQ_DESC_F_NEXT;
        for (int i = 0; i < 8; i++) data[i]    = addr[i*8 +: 8];
        for (int i = 0; i < 4; i++) data[8+i]  = len[i*8 +: 8];
        for (int i = 0; i < 2; i++) data[12+i] = 8'h00;
        for (int i = 0; i < 2; i++) data[14+i] = pflags[i*8 +: 8];
        mem.write_mem(table_gpa + index * 16, data);
    endfunction

    // Read packed descriptor fields from host_mem
    protected function void read_packed_desc(int unsigned idx,
                                             ref bit [63:0] addr,
                                             ref bit [31:0] len,
                                             ref bit [15:0] id,
                                             ref bit [15:0] flags);
        byte data[];
        mem.read_mem(desc_table_addr + idx * 16, 16, data);
        addr  = {data[7], data[6], data[5], data[4], data[3], data[2], data[1], data[0]};
        len   = {data[11], data[10], data[9], data[8]};
        id    = {data[13], data[12]};
        flags = {data[15], data[14]};
    endfunction

    // Write 16-bit value to event suppression area at given address + byte offset
    protected function void write_event_16(bit [63:0] base_addr, int unsigned byte_offset,
                                           bit [15:0] val);
        byte data[2];
        data[0] = val[7:0];
        data[1] = val[15:8];
        mem.write_mem(base_addr + byte_offset, data);
    endfunction

    // Read 16-bit value from event suppression area
    protected function bit [15:0] read_event_16(bit [63:0] base_addr, int unsigned byte_offset);
        byte data[];
        mem.read_mem(base_addr + byte_offset, 2, data);
        return {data[1], data[0]};
    endfunction

    // Advance a ring index with wrap-around, toggling the wrap counter
    protected function void advance_idx(ref int unsigned idx, ref bit wrap_counter);
        idx++;
        if (idx >= queue_size) begin
            idx = 0;
            wrap_counter = ~wrap_counter;
        end
    endfunction

    // =================================================================
    // Lifecycle methods
    // =================================================================

    // 分配并清零 ring/event 区，建立初始空闲 ID；分配失败时不标记就绪。
    extern virtual function void alloc_rings();

    // 设备停止 DMA 后释放 ring、间接表和链记录；报文 DMA 由 ops 释放。
    extern virtual function void free_rings();

    // ------------------------------------------------------------------
    // reset_queue -- Free rings and reset all internal state
    // ------------------------------------------------------------------
    virtual function void reset_queue();
        free_rings();
        next_avail_idx     = 0;
        next_used_idx      = 0;
        avail_wrap_counter = 1;
        used_wrap_counter  = 1;
        event_idx_enabled  = 0;
        in_order_enabled   = 0;
        desc_ring_size     = 0;
        free_id_list.delete();
        clear_op_counters();

        `uvm_info("PACKED_VQ",
            $sformatf("reset_queue: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // =================================================================
    // Driver operations
    // =================================================================

    // 发布完整 SG 链：各槽共用一个 Buffer ID，本地保留全部分配 ID。
    // 先准备链及元数据，最后发布首槽；返回首槽索引，失败返回 '1。
    extern virtual function int unsigned add_buf(
        virtio_sg_list	sgs[],
        int unsigned	n_out_sgs,
        int unsigned	n_in_sgs,
        uvm_object	token,
        bit		indirect
    );

    // 完成位匹配当前 wrap 后，通过 Buffer ID 找到 token 和完整链并释放槽位。
    // 成功输出 token/len 并返回 1；未完成或非法 ID 返回 0，不推进游标。
    extern virtual function bit poll_used(
        ref uvm_object		token,
        ref int unsigned	len
    );

    // =================================================================
    // Notification control
    // =================================================================

    // Event suppression flags encoding (bits 0-1):
    //   0x0 = ENABLE  -- notifications enabled
    //   0x1 = DISABLE -- notifications disabled
    //   0x2 = DESC    -- notify based on descriptor index/wrap

    // ------------------------------------------------------------------
    // disable_cb -- Suppress device notifications via driver event suppression
    // ------------------------------------------------------------------
    virtual function void disable_cb();
        // Write DISABLE (0x1) to driver event suppression flags
        write_event_16(driver_event_addr, 2, 16'h0001);
        `uvm_info("PACKED_VQ",
            $sformatf("disable_cb: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // enable_cb -- Re-enable device notifications
    // ------------------------------------------------------------------
    virtual function void enable_cb();
        // Write ENABLE (0x0) to driver event suppression flags
        write_event_16(driver_event_addr, 2, 16'h0000);
        barrier.mb("after packed enable_cb");
        `uvm_info("PACKED_VQ",
            $sformatf("enable_cb: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // enable_cb_delayed -- Enable with DESC-based notification
    // ------------------------------------------------------------------
    virtual function void enable_cb_delayed();
        if (event_idx_enabled) begin
            bit [15:0] desc_flags;
            // Write DESC mode (0x2) to driver event suppression flags
            // Set wrap counter bit (bit 15) and current next_used_idx
            desc_flags = 16'h0002;
            if (used_wrap_counter)
                desc_flags = desc_flags | 16'h8000;

            write_event_16(driver_event_addr, 0, next_used_idx[15:0]);
            write_event_16(driver_event_addr, 2, desc_flags);
        end else begin
            enable_cb();
        end

        `uvm_info("PACKED_VQ",
            $sformatf("enable_cb_delayed: queue_id=%0d event_idx=%0b",
                      queue_id, event_idx_enabled),
            UVM_HIGH)
    endfunction

    // 按当前完成游标检查 AVAIL/USED/wrap；last_used 保留基类接口，不回收资源。
    extern virtual function bit vq_poll(int unsigned	last_used);

    // =================================================================
    // Query methods
    // =================================================================

    // 返回可用的空闲 buffer ID 数：packed 队列的可用额度由 free_id_list 管理，
    // 不读 host memory。
    virtual function int unsigned get_free_count();
        return free_id_list.size();
    endfunction

    // 返回已占用的 buffer ID 数（queue_size - 空闲数），含设备已完成但驱动尚
    // 未 poll_used 收割的部分；VQ_RESET 态恒为 0。
    virtual function int unsigned get_pending_count();
        if (state == VQ_RESET)
            return 0;
        return queue_size - free_id_list.size();
    endfunction

    // 描述符环与两份 4B event suppression 结构，各在自己的 GPA 上映射。
    virtual function void get_ring_regions(output bit [63:0] gpas[$],
                                           output int unsigned sizes[$]);
        gpas  = '{desc_table_addr, driver_ring_addr, device_ring_addr};
        sizes = '{16 * queue_size, 4, 4};
    endfunction

    // Packed notification data carries the next descriptor slot and the
    // driver wrap counter, not the number of published chains.
    virtual function int unsigned get_notify_next_idx();
        return next_avail_idx;
    endfunction
    virtual function bit get_notify_wrap();
        return avail_wrap_counter;
    endfunction

    // ------------------------------------------------------------------
    // needs_notification -- Check device event suppression flags
    //
    // Device event suppression tells the driver whether to send kicks:
    //   DISABLE (0x1): return 0
    //   ENABLE  (0x0): return 1
    //   DESC    (0x2): compare wrap counter and desc index
    // ------------------------------------------------------------------
    virtual function bit needs_notification();
        bit [15:0] dev_event_flags;
        bit [15:0] dev_event_desc;
        bit [1:0]  mode;

        dev_event_flags = read_event_16(device_event_addr, 2);
        mode = dev_event_flags[1:0];

        case (mode)
            2'b00: return 1;  // ENABLE
            2'b01: return 0;  // DISABLE
            2'b10: begin      // DESC
                bit dev_wrap;
                int unsigned dev_desc_idx;

                dev_event_desc = read_event_16(device_event_addr, 0);
                dev_wrap = dev_event_flags[15];
                dev_desc_idx = dev_event_desc;

                // Notify if we've reached or passed the requested descriptor
                // Use wrap-aware comparison
                if (avail_wrap_counter == dev_wrap)
                    return (next_avail_idx >= dev_desc_idx);
                else
                    return (next_avail_idx < dev_desc_idx);
            end
            default: return 1;
        endcase
    endfunction

    // =================================================================
    // Error injection
    // =================================================================

    // 向通用注入器声明本队列的线上描述符格式为 packed（16 字节
    // addr/len/id/flags 布局），使其能正确定位字段做破坏。
    virtual function virtqueue_type_e descriptor_format();
        return VQ_PACKED;
    endfunction

    // =================================================================
    // Migration snapshot
    // =================================================================

    // 保存 ring 字节、游标和链元数据；snap 持有值副本，不转移队列资源。
    extern virtual function void save_state(ref virtqueue_snapshot_t	snap);

    // 恢复到已分配的兼容 ring；先验证 ID/链/token 集合，失败不接管快照资源。
    extern virtual function bit restore_state(virtqueue_snapshot_t	snap);

endclass : packed_virtqueue

// 发布一条完整 SG 链；容量不足或间接表失败时不改变分配记录。
function int unsigned packed_virtqueue::add_buf(
    virtio_sg_list	sgs[],
    int unsigned	n_out_sgs,
    int unsigned	n_in_sgs,
    uvm_object	token,
    bit		indirect
);
    int unsigned			total_needed = 0;
    int unsigned			total_sgs;
    int unsigned			head_idx;
    int unsigned			head_id;
    int unsigned			sg_count = 0;
    bit				is_write;
    bit [15:0]			head_flags;
    virtqueue_packed_chain_t	record;
    bit [63:0]			indirect_iova;
    int unsigned			indirect_size;
    int unsigned			ring_desc_count;

    if (n_out_sgs > (32'hffff_ffff - n_in_sgs)) begin
        `uvm_error("VQ_INDIRECT", $sformatf(
            "queue_id=%0d SG count overflow out=%0d in=%0d",
            queue_id, n_out_sgs, n_in_sgs))
        return '1;
    end
    total_sgs = n_out_sgs + n_in_sgs;
    if (total_sgs == 0 || total_sgs > sgs.size()) begin
        `uvm_error("VQ_INDIRECT", $sformatf(
            "queue_id=%0d invalid SG list count=%0d available=%0d",
            queue_id, total_sgs, sgs.size()))
        return '1;
    end

    // Calculate total descriptors needed
    for (int unsigned s = 0; s < total_sgs; s++) begin
        total_needed += sgs[s].entries.size();
    end

    if (total_needed == 0) begin
        `uvm_error("PACKED_VQ",
            $sformatf("add_buf: queue_id=%0d no sg entries provided", queue_id))
        return '1;
    end

    ring_desc_count = indirect ? 1 : total_needed;

    // Check free descriptors.  An indirect request consumes one packed
    // main descriptor regardless of its scatter-gather entry count.
    if (free_id_list.size() < ring_desc_count) begin
        `uvm_error("PACKED_VQ",
            $sformatf("add_buf: queue_id=%0d need %0d descriptors but only %0d free",
                      queue_id, ring_desc_count, free_id_list.size()))
        return '1;
    end

    head_idx = next_avail_idx;
    head_id = free_id_list[0];
    record.buffer_id = head_id;
    record.desc_ids.delete();

    if (indirect) begin
        bit [15:0]	flags;

        if (!prepare_indirect_table(sgs, n_out_sgs, n_in_sgs, head_id, token,
                                    indirect_iova, indirect_size))
            return '1;

        flags = VIRTQ_DESC_F_INDIRECT;
        if (avail_wrap_counter)
            flags |= VIRTQ_DESC_F_AVAIL;
        if (!avail_wrap_counter)
            flags |= VIRTQ_DESC_F_USED;

        record.desc_ids.push_back(free_id_list.pop_front());
        head_flags = flags;
        write_packed_desc(next_avail_idx, indirect_iova, indirect_size,
                          head_id[15:0], flags ^ VIRTQ_DESC_F_AVAIL);
        advance_idx(next_avail_idx, avail_wrap_counter);
    end else begin
        // Process each sg list
        for (int unsigned s = 0; s < total_sgs; s++) begin
            is_write = (s >= n_out_sgs);

            for (int unsigned e = 0; e < sgs[s].entries.size(); e++) begin
                bit [15:0]	flags = 0;
                int unsigned	buf_id;

                // Take a buffer ID from the free list
                buf_id = free_id_list.pop_front();

                // ID 是每包身份；各槽的分配 ID 仅在本地用于精确释放。
                record.desc_ids.push_back(buf_id);

                // Set flags
                if (is_write)
                    flags = flags | VIRTQ_DESC_F_WRITE;

                sg_count++;
                if (sg_count < total_needed)
                    flags = flags | VIRTQ_DESC_F_NEXT;

                // Set AVAIL and USED bits based on wrap counter
                // AVAIL = avail_wrap_counter, USED = !avail_wrap_counter
                if (avail_wrap_counter)
                    flags = flags | VIRTQ_DESC_F_AVAIL;
                // else AVAIL bit stays 0

                if (!avail_wrap_counter)
                    flags = flags | VIRTQ_DESC_F_USED;
                // else USED bit stays 0

                // 首槽最后发布，避免设备先看到不完整的 SG 链。
                if (sg_count == 1) begin
                    head_flags = flags;
                    flags ^= VIRTQ_DESC_F_AVAIL;
                end
                write_packed_desc(next_avail_idx,
                                  sgs[s].entries[e].addr,
                                  sgs[s].entries[e].len,
                                  head_id[15:0],
                                  flags);

                // Advance next_avail_idx
                advance_idx(next_avail_idx, avail_wrap_counter);
            end
        end
    end

    // 本地记录先于首槽发布就绪。设备可覆盖首槽的 ID/NEXT，但不能改变链所有权。
    token_map[head_id] = token;
    chains[head_id] = record;
    barrier.wmb("before packed ring descriptors visible");
    write_event_16(desc_table_addr, head_idx * 16 + 14, head_flags);
    mark_published_descriptor(head_idx);

    total_add_buf_ops++;

    `uvm_info("PACKED_VQ",
        $sformatf({"add_buf: queue_id=%0d head_idx=%0d head_id=%0d ",
                   "n_out=%0d n_in=%0d total_desc=%0d free=%0d"},
                  queue_id, head_idx, head_id, n_out_sgs, n_in_sgs,
                  ring_desc_count, free_id_list.size()),
        UVM_HIGH)

    return head_idx;
endfunction

// 回收一个合法完成的包，按本地链记录释放全部槽；未知 ID 不推进游标。
function bit packed_virtqueue::poll_used(
    ref uvm_object		token,
    ref int unsigned	len
);
    bit [63:0]			d_addr;
    bit [31:0]			d_len;
    bit [15:0]			d_id;
    bit [15:0]			d_flags;
    virtqueue_packed_chain_t	record;

    if (!vq_poll(next_used_idx)) return 0;
    barrier.rmb("before reading packed used descriptors");
    read_packed_desc(next_used_idx, d_addr, d_len, d_id, d_flags);

    if (!token_map.exists(d_id) || !chains.exists(d_id)) begin
        `uvm_error("PACKED_VQ", $sformatf(
            "poll_used: queue_id=%0d slot=%0d buf_id=%0d has no pending chain",
            queue_id, next_used_idx, d_id))
        return 0;
    end

    record = chains[d_id];
    token = token_map[d_id];
    len = d_len;
    token_map.delete(d_id);
    chains.delete(d_id);
    release_indirect_table(d_id);

    // USED 只需回写一项。按提交时的数量跳过整条链，不能扫描回写后的 NEXT。
    foreach (record.desc_ids[i]) begin
        free_id_list.push_back(record.desc_ids[i]);
        advance_idx(next_used_idx, used_wrap_counter);
    end
    total_poll_used_ops++;
    `uvm_info("PACKED_VQ", $sformatf(
        "poll_used: queue_id=%0d buf_id=%0d desc_count=%0d len=%0d free=%0d",
        queue_id, d_id, record.desc_ids.size(), len, free_id_list.size()), UVM_HIGH)
    return 1;
endfunction

// 同时核对 AVAIL、USED 和当前 wrap，不读取或删除 token。
function bit packed_virtqueue::vq_poll(int unsigned	last_used);
    bit [63:0]	d_addr;
    bit [31:0]	d_len;
    bit [15:0]	d_id;
    bit [15:0]	d_flags;
    bit		desc_used;
    bit		desc_avail;

    read_packed_desc(next_used_idx, d_addr, d_len, d_id, d_flags);
    desc_used = (d_flags & VIRTQ_DESC_F_USED) != 0;
    desc_avail = (d_flags & VIRTQ_DESC_F_AVAIL) != 0;
    return (desc_avail == desc_used) && (desc_used == used_wrap_counter);
endfunction

// 保存线上字节、空闲 ID 和未完成链；快照不转移资源所有权。
function void packed_virtqueue::save_state(ref virtqueue_snapshot_t	snap);
    int unsigned	total_size = desc_ring_size + 4 + 4;
    byte		ring_data[];

    // driver/device_ring_addr 与 event 地址在 alloc_rings/free_rings 中同步维护。
    fill_snapshot_header(next_avail_idx, next_used_idx,
                         avail_wrap_counter, used_wrap_counter, snap);

    // Read entire ring + event suppression areas
    mem.read_mem(desc_table_addr, total_size, ring_data);

    snap.ring_data = new[total_size];
    foreach (ring_data[i]) snap.ring_data[i] = ring_data[i];
    snap.split_free_head = 0;
    snap.split_num_free = 0;
    snap.packed_free_ids = free_id_list;
    snap.packed_chains.delete();
    foreach (chains[id]) snap.packed_chains.push_back(chains[id]);
    save_migration_ownership(snap);

    `uvm_info("PACKED_VQ",
        $sformatf({"save_state: queue_id=%0d next_avail=%0d next_used=%0d ",
                   "avail_wrap=%0b used_wrap=%0b ring_data=%0d bytes"},
                  queue_id, next_avail_idx, next_used_idx,
                  avail_wrap_counter, used_wrap_counter, snap.ring_data.size()),
        UVM_MEDIUM)
endfunction

// 先校验链与 ID 分配集合，再恢复快照；不能从设备回写的 NEXT 推导链长。
function bit packed_virtqueue::restore_state(virtqueue_snapshot_t	snap);
    int unsigned	total_size;
    byte		region_data[];
    bit		allocated_ids[int unsigned];
    bit		token_ids[int unsigned];

    total_size = 16 * snap.queue_size + 4 + 4;

    // setup_queue() owns the destination allocation, IOMMU mappings, and
    // transport programming.  Never replace that contiguous ring during
    // migration restore; copy the saved bytes into it instead.
    if ((queue_id != snap.queue_id) || (queue_size != snap.queue_size) ||
        (desc_ring_size != (16 * snap.queue_size)) ||
        (desc_table_addr == 0) ||
        (driver_event_addr != (desc_table_addr + desc_ring_size)) ||
        (device_event_addr != (driver_event_addr + 4)) ||
        (snap.ring_data.size() != total_size)) begin
        `uvm_error("PACKED_VQ",
            $sformatf("restore_state: missing or incompatible setup ring for queue_id=%0d",
                      snap.queue_id))
        return 0;
    end
    if (snap.packed_free_ids.size() > queue_size)
        return 0;
    // Validate allocation IDs before attaching request ownership.  An
    // invalid ID list is an overlay failure, not a reason to leave a
    // partially restored token/indirect-table map behind.
    foreach (snap.packed_free_ids[i]) begin
        int unsigned	id;

        id = snap.packed_free_ids[i];
        if (id >= queue_size) begin
            `uvm_error("PACKED_VQ", $sformatf(
                "restore_state: invalid free ID %0d for queue_id=%0d",
                id, queue_id))
            return 0;
        end
        foreach (snap.packed_free_ids[j]) begin
            if ((j < i) && (snap.packed_free_ids[j] == id)) begin
                `uvm_error("PACKED_VQ", $sformatf(
                    "restore_state: duplicate free ID %0d for queue_id=%0d",
                    id, queue_id))
                return 0;
            end
        end
    end
    // 完整分配集合必须覆盖每个 ID 恰好一次，链记录与 token 一一对应。
    // 在恢复所有权之前检查，失败不会留下半恢复的链或间接表。
    if (snap.packed_chains.size() != snap.pending_tokens.size()) return 0;
    foreach (snap.pending_tokens[i])
        token_ids[snap.pending_tokens[i].head_id] = 1;
    foreach (snap.packed_free_ids[i]) allocated_ids[snap.packed_free_ids[i]] = 1;
    foreach (snap.packed_chains[i]) begin
        virtqueue_packed_chain_t	record;

        record = snap.packed_chains[i];
        if (record.desc_ids.size() == 0 || !token_ids.exists(record.buffer_id))
            return 0;
        if (record.buffer_id != record.desc_ids[0]) return 0;
        token_ids.delete(record.buffer_id);
        foreach (record.desc_ids[j]) begin
            if (record.desc_ids[j] >= queue_size || allocated_ids.exists(record.desc_ids[j]))
                return 0;
            allocated_ids[record.desc_ids[j]] = 1;
        end
    end
    if (allocated_ids.num() != queue_size || token_ids.num() != 0) return 0;
    if (!restore_migration_ownership(snap)) return 0;

    // Write ring data back
    region_data = new[total_size];
    foreach (region_data[i]) region_data[i] = snap.ring_data[i];
    mem.write_mem(desc_table_addr, region_data);

    chains.delete();
    foreach (snap.packed_chains[i])
        chains[snap.packed_chains[i].buffer_id] = snap.packed_chains[i];

    // Restore indices and wrap counters
    next_avail_idx     = snap.last_avail_idx;
    next_used_idx      = snap.last_used_idx;
    avail_wrap_counter = snap.avail_wrap;
    used_wrap_counter  = snap.used_wrap;

    // Preserve the exact allocation order. Reconstructing only from
    // token_map loses chained direct descriptors and changes packed IDs.
    free_id_list.delete();
    foreach (snap.packed_free_ids[i]) begin
        int unsigned	id;

        id = snap.packed_free_ids[i];
        free_id_list.push_back(id);
    end

    `uvm_info("PACKED_VQ",
        $sformatf({"restore_state: queue_id=%0d next_avail=%0d next_used=%0d ",
                   "avail_wrap=%0b used_wrap=%0b"},
                  queue_id, next_avail_idx, next_used_idx,
                  avail_wrap_counter, used_wrap_counter),
        UVM_MEDIUM)
    return 1;
endfunction

// 平台停机后释放 ring 及所有链记录，不隐式释放 ops 持有的报文 DMA。
function void packed_virtqueue::free_rings();
    release_queue_ownership();
    chains.delete();
    free_id_list.delete();
    if (desc_table_addr != 0) mem.free(desc_table_addr);

    desc_table_addr   = 0;
    driver_ring_addr  = 0;
    device_ring_addr  = 0;
    driver_event_addr = 0;
    device_event_addr = 0;
    clear_published_descriptor();
    state             = VQ_RESET;

    `uvm_info("PACKED_VQ",
        $sformatf("free_rings: queue_id=%0d", queue_id), UVM_HIGH)
endfunction

// 分配并清零 ring，重建完整空闲 ID 集合；失败保留未就绪状态。
function void packed_virtqueue::alloc_rings();
    int unsigned	total_size;

    desc_ring_size = 16 * queue_size;
    // Ring + driver event suppression (4 bytes) + device event suppression (4 bytes)
    total_size = desc_ring_size + 4 + 4;

    // Allocate as one contiguous block, 4096-byte aligned
    desc_table_addr = mem.alloc(total_size, .align(4096));

    if (desc_table_addr == '1) begin
        `uvm_error("PACKED_VQ",
            $sformatf("alloc_rings failed for queue_id=%0d size=%0d", queue_id, queue_size))
        return;
    end

    // Compute event suppression addresses
    driver_event_addr = desc_table_addr + desc_ring_size;
    device_event_addr = driver_event_addr + 4;

    // Set driver_ring_addr and device_ring_addr for base class dump_ring
    driver_ring_addr = driver_event_addr;
    device_ring_addr = device_event_addr;

    // Zero-fill entire region
    mem.mem_set(desc_table_addr, 0, total_size);

    // Initialize state
    next_avail_idx     = 0;
    next_used_idx      = 0;
    avail_wrap_counter = 1;
    used_wrap_counter  = 1;

    chains.delete();

    // Pre-fill free_id_list with 0..queue_size-1
    free_id_list.delete();
    for (int unsigned i = 0; i < queue_size; i++) begin
        free_id_list.push_back(i);
    end

    state = VQ_CONFIGURE;

    `uvm_info("PACKED_VQ",
        $sformatf({"alloc_rings: queue_id=%0d size=%0d ",
                   "desc=0x%016x driver_event=0x%016x device_event=0x%016x"},
                  queue_id, queue_size,
                  desc_table_addr, driver_event_addr, device_event_addr),
        UVM_HIGH)
endfunction

// token 和链记录一起摘除；真正的 ring 释放仍由既有停机/复位路径负责。
function void packed_virtqueue::detach_all_unused(ref uvm_object	tokens[$]);
    super.detach_all_unused(tokens);
    chains.delete();
endfunction

`endif // PACKED_VIRTQUEUE_SV
