`ifndef SPLIT_VIRTQUEUE_SV
`define SPLIT_VIRTQUEUE_SV

// ============================================================================
// split_virtqueue
//
// Full implementation of the virtio split virtqueue per the virtio 1.2
// specification. Extends virtqueue_base and implements all 18 pure virtual
// methods.
//
// Memory layout (three regions allocated from host_mem_manager):
//   Descriptor table: 16 bytes/entry, 4096-byte aligned
//   Available ring:   6 + 2*queue_size bytes, 2-byte aligned
//   Used ring:        6 + 8*queue_size bytes, 4096-byte aligned
//
// Depends on:
//   - virtqueue_base (base class)
//   - host_mem_manager (memory backend)
//   - virtio_iommu_model (DMA address translation)
//   - virtio_memory_barrier_model (memory ordering)
//   - virtqueue_error_injector (fault injection)
//   - virtio_net_types.sv (all type definitions)
// ============================================================================

class split_virtqueue extends virtqueue_base;
    `uvm_object_utils(split_virtqueue)

    // ===== Internal state =====
    protected int unsigned free_head;
    protected int unsigned last_used_idx;
    protected int unsigned num_free;
    protected bit          event_idx_enabled;
    protected int unsigned avail_idx;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "split_virtqueue");
        super.new(name);
        free_head         = 0;
        last_used_idx     = 0;
        num_free          = 0;
        event_idx_enabled = 0;
        avail_idx         = 0;
    endfunction

    // =================================================================
    // Helper methods -- byte-level packing for host_mem access
    // =================================================================

    // Write a single 16-byte descriptor entry to host_mem
    protected function void write_desc(int unsigned idx,
                                       bit [63:0] addr,
                                       bit [31:0] len,
                                       bit [15:0] flags,
                                       bit [15:0] next);
        byte data[16];
        for (int i = 0; i < 8; i++) data[i]    = addr[i*8 +: 8];
        for (int i = 0; i < 4; i++) data[8+i]   = len[i*8 +: 8];
        for (int i = 0; i < 2; i++) data[12+i]  = flags[i*8 +: 8];
        for (int i = 0; i < 2; i++) data[14+i]  = next[i*8 +: 8];
        mem.write_mem(desc_table_addr + idx * 16, data);
    endfunction

    // Read descriptor fields from host_mem
    protected function void read_desc(int unsigned idx,
                                      ref bit [63:0] addr,
                                      ref bit [31:0] len,
                                      ref bit [15:0] flags,
                                      ref bit [15:0] next);
        byte data[];
        mem.read_mem(desc_table_addr + idx * 16, 16, data);
        addr  = {data[7], data[6], data[5], data[4], data[3], data[2], data[1], data[0]};
        len   = {data[11], data[10], data[9], data[8]};
        flags = {data[13], data[12]};
        next  = {data[15], data[14]};
    endfunction

    // Read the next field of a descriptor
    protected function bit [15:0] read_desc_next(int unsigned idx);
        byte data[];
        mem.read_mem(desc_table_addr + idx * 16 + 14, 2, data);
        return {data[1], data[0]};
    endfunction

    // Read the flags field of a descriptor
    protected function bit [15:0] read_desc_flags(int unsigned idx);
        byte data[];
        mem.read_mem(desc_table_addr + idx * 16 + 12, 2, data);
        return {data[1], data[0]};
    endfunction

    // Write 16-bit value to avail ring at given byte offset
    protected function void write_avail_16(int unsigned byte_offset, bit [15:0] val);
        byte data[2];
        data[0] = val[7:0];
        data[1] = val[15:8];
        mem.write_mem(driver_ring_addr + byte_offset, data);
    endfunction

    // Read 16-bit value from avail ring at given byte offset
    protected function bit [15:0] read_avail_16(int unsigned byte_offset);
        byte data[];
        mem.read_mem(driver_ring_addr + byte_offset, 2, data);
        return {data[1], data[0]};
    endfunction

    // Write 16-bit value to used ring at given byte offset
    protected function void write_used_16(int unsigned byte_offset, bit [15:0] val);
        byte data[2];
        data[0] = val[7:0];
        data[1] = val[15:8];
        mem.write_mem(device_ring_addr + byte_offset, data);
    endfunction

    // Read 16-bit value from used ring at given byte offset
    protected function bit [15:0] read_used_16(int unsigned byte_offset);
        byte data[];
        mem.read_mem(device_ring_addr + byte_offset, 2, data);
        return {data[1], data[0]};
    endfunction

    // Read 32-bit value from used ring at given byte offset
    protected function bit [31:0] read_used_32(int unsigned byte_offset);
        byte data[];
        mem.read_mem(device_ring_addr + byte_offset, 4, data);
        return {data[3], data[2], data[1], data[0]};
    endfunction

    // =================================================================
    // Lifecycle methods
    // =================================================================

    // ------------------------------------------------------------------
    // alloc_rings -- Allocate and initialize all three ring regions
    // ------------------------------------------------------------------
    virtual function void alloc_rings();
        int unsigned desc_size  = 16 * queue_size;
        int unsigned avail_size = 6 + 2 * queue_size;
        int unsigned used_size  = 6 + 8 * queue_size;

        // Allocate from host memory with required alignment
        desc_table_addr  = mem.alloc(desc_size,  .align(4096));
        driver_ring_addr = mem.alloc(avail_size, .align(2));
        device_ring_addr = mem.alloc(used_size,  .align(4096));

        if (desc_table_addr == '1 || driver_ring_addr == '1 || device_ring_addr == '1) begin
            `uvm_error("SPLIT_VQ",
                $sformatf("alloc_rings failed for queue_id=%0d size=%0d", queue_id, queue_size))
            return;
        end

        // Zero-fill all three regions
        mem.mem_set(desc_table_addr,  0, desc_size);
        mem.mem_set(driver_ring_addr, 0, avail_size);
        mem.mem_set(device_ring_addr, 0, used_size);

        // Initialize free descriptor linked list
        for (int unsigned i = 0; i < queue_size; i++) begin
            bit [15:0] next_idx = (i < queue_size - 1) ? (i + 1) : 0;
            write_desc(i, 64'h0, 32'h0, 16'h0, next_idx);
        end

        free_head     = 0;
        num_free      = queue_size;
        avail_idx     = 0;
        last_used_idx = 0;
        state         = VQ_CONFIGURE;

        `uvm_info("SPLIT_VQ",
            $sformatf({"alloc_rings: queue_id=%0d size=%0d ",
                       "desc=0x%016x avail=0x%016x used=0x%016x"},
                      queue_id, queue_size,
                      desc_table_addr, driver_ring_addr, device_ring_addr),
            UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // free_rings -- Deallocate all three ring regions
    // ------------------------------------------------------------------
    virtual function void free_rings();
        if (desc_table_addr != 0)  mem.free(desc_table_addr);
        if (driver_ring_addr != 0) mem.free(driver_ring_addr);
        if (device_ring_addr != 0) mem.free(device_ring_addr);

        desc_table_addr  = 0;
        driver_ring_addr = 0;
        device_ring_addr = 0;
        state            = VQ_RESET;

        `uvm_info("SPLIT_VQ",
            $sformatf("free_rings: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // reset_queue -- Free rings and reset all internal state
    // ------------------------------------------------------------------
    virtual function void reset_queue();
        free_rings();
        free_head         = 0;
        last_used_idx     = 0;
        num_free          = 0;
        avail_idx         = 0;
        event_idx_enabled = 0;
        token_map.delete();
        dma_mappings.delete();
        total_add_buf_ops   = 0;
        total_poll_used_ops = 0;
        total_kick_ops      = 0;

        `uvm_info("SPLIT_VQ",
            $sformatf("reset_queue: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // detach_all_unused -- Collect all outstanding tokens and clean up
    // ------------------------------------------------------------------
    virtual function void detach_all_unused(ref uvm_object tokens[$]);
        // Collect all tokens
        foreach (token_map[desc_id]) begin
            tokens.push_back(token_map[desc_id]);
        end

        // Unmap all outstanding DMA mappings
        foreach (dma_mappings[i]) begin
            iommu.unmap(bdf, dma_mappings[i].iova);
        end

        token_map.delete();
        dma_mappings.delete();

        `uvm_info("SPLIT_VQ",
            $sformatf("detach_all_unused: queue_id=%0d returned %0d tokens",
                      queue_id, tokens.size()),
            UVM_HIGH)
    endfunction

    // =================================================================
    // Driver operations
    // =================================================================

    // ------------------------------------------------------------------
    // add_buf -- Add scatter-gather buffers to the descriptor ring
    //
    // sgs[0..n_out_sgs-1] are device-readable (out), rest are writable (in).
    // Returns the head descriptor index, or '1 on error.
    // ------------------------------------------------------------------
    virtual function int unsigned add_buf(
        virtio_sg_list  sgs[],
        int unsigned    n_out_sgs,
        int unsigned    n_in_sgs,
        uvm_object      token,
        bit             indirect
    );
        int unsigned total_needed = 0;
        int unsigned head;
        int unsigned idx;
        int unsigned sg_idx = 0;
        int unsigned total_sgs = n_out_sgs + n_in_sgs;
        bit          is_write;

        // Calculate total descriptors needed
        for (int unsigned s = 0; s < total_sgs; s++) begin
            total_needed += sgs[s].entries.size();
        end

        if (total_needed == 0) begin
            `uvm_error("SPLIT_VQ",
                $sformatf("add_buf: queue_id=%0d no sg entries provided", queue_id))
            return '1;
        end

        // Check free descriptors
        if (num_free < total_needed) begin
            `uvm_error("SPLIT_VQ",
                $sformatf("add_buf: queue_id=%0d need %0d descriptors but only %0d free",
                          queue_id, total_needed, num_free))
            return '1;
        end

        head = free_head;

        // Process each sg list
        for (int unsigned s = 0; s < total_sgs; s++) begin
            is_write = (s >= n_out_sgs);  // in_sgs are device-writable

            for (int unsigned e = 0; e < sgs[s].entries.size(); e++) begin
                bit [15:0] flags = 0;
                bit [15:0] next_val;

                // Take descriptor from free list
                idx = free_head;
                free_head = read_desc_next(idx);
                num_free--;

                // Set flags
                if (is_write)
                    flags = flags | VIRTQ_DESC_F_WRITE;

                // Determine if this is the last entry in the entire chain
                sg_idx++;
                if (sg_idx < total_needed) begin
                    flags = flags | VIRTQ_DESC_F_NEXT;
                    next_val = free_head[15:0];
                end else begin
                    next_val = 0;
                end

                // Write descriptor
                write_desc(idx,
                           sgs[s].entries[e].addr,
                           sgs[s].entries[e].len,
                           flags,
                           next_val);
            end
        end

        // Memory barrier before avail ring update
        barrier.wmb("before avail ring update");

        // Write head index to avail ring entry
        write_avail_16(4 + (avail_idx % queue_size) * 2, head[15:0]);

        // Increment avail_idx
        avail_idx++;

        // Write updated avail_idx to avail ring idx field
        write_avail_16(2, avail_idx[15:0]);

        // Full barrier after avail update, before kick check
        barrier.mb("after avail update, before kick check");

        // Store token for later retrieval
        token_map[head] = token;

        total_add_buf_ops++;

        `uvm_info("SPLIT_VQ",
            $sformatf("add_buf: queue_id=%0d head=%0d n_out=%0d n_in=%0d total_desc=%0d free=%0d",
                      queue_id, head, n_out_sgs, n_in_sgs, total_needed, num_free),
            UVM_HIGH)

        return head;
    endfunction

    // ------------------------------------------------------------------
    // kick -- Notify the device that new buffers are available
    // ------------------------------------------------------------------
    virtual task kick();
        total_kick_ops++;
        `uvm_info("SPLIT_VQ",
            $sformatf("kick: queue_id=%0d avail_idx=%0d", queue_id, avail_idx),
            UVM_HIGH)
        // Actual transport kick (PCIe TLP) will be connected externally
    endtask

    // ------------------------------------------------------------------
    // poll_used -- Check for completed buffers in the used ring
    //
    // Returns 1 if a completed buffer was found, 0 otherwise.
    // On success, token and len are set from the used ring entry.
    // ------------------------------------------------------------------
    virtual function bit poll_used(
        ref uvm_object      token,
        ref int unsigned     len
    );
        bit [15:0] device_used_idx;
        bit [31:0] used_id;
        bit [31:0] used_len;
        int unsigned ring_offset;
        int unsigned desc_idx;

        // Read barrier before reading used ring
        barrier.rmb("before reading used ring");

        // Read device's used idx from used ring
        device_used_idx = read_used_16(2);

        // Check if there are new entries
        if (device_used_idx == last_used_idx[15:0])
            return 0;

        // Read used ring entry: {id[31:0], len[31:0]}
        // at offset 4 + (last_used_idx % queue_size) * 8
        ring_offset = 4 + (last_used_idx % queue_size) * 8;
        used_id  = read_used_32(ring_offset);
        used_len = read_used_32(ring_offset + 4);

        desc_idx = used_id;

        // Recover token
        if (!token_map.exists(desc_idx)) begin
            `uvm_error("SPLIT_VQ",
                $sformatf("poll_used: queue_id=%0d desc_id=%0d not found in token_map",
                          queue_id, desc_idx))
            return 0;
        end
        token = token_map[desc_idx];
        token_map.delete(desc_idx);

        // Reclaim descriptor chain back to free list
        begin
            int unsigned chain_idx = desc_idx;
            bit [63:0] d_addr;
            bit [31:0] d_len;
            bit [15:0] d_flags;
            bit [15:0] d_next;
            int unsigned safety_count = 0;

            forever begin
                read_desc(chain_idx, d_addr, d_len, d_flags, d_next);

                // Push this descriptor back to free list head
                write_desc(chain_idx, 64'h0, 32'h0, 16'h0, free_head[15:0]);
                free_head = chain_idx;
                num_free++;

                if (!(d_flags & VIRTQ_DESC_F_NEXT))
                    break;

                chain_idx = d_next;
                safety_count++;
                if (safety_count > queue_size) begin
                    `uvm_error("SPLIT_VQ",
                        $sformatf("poll_used: queue_id=%0d circular descriptor chain detected",
                                  queue_id))
                    break;
                end
            end
        end

        last_used_idx++;
        len = used_len;

        total_poll_used_ops++;

        `uvm_info("SPLIT_VQ",
            $sformatf("poll_used: queue_id=%0d desc_id=%0d len=%0d free=%0d",
                      queue_id, desc_idx, used_len, num_free),
            UVM_HIGH)

        return 1;
    endfunction

    // =================================================================
    // Notification control (NAPI style)
    // =================================================================

    // ------------------------------------------------------------------
    // disable_cb -- Suppress device interrupts
    // ------------------------------------------------------------------
    virtual function void disable_cb();
        write_avail_16(0, VIRTQ_AVAIL_F_NO_INTERRUPT);
        `uvm_info("SPLIT_VQ",
            $sformatf("disable_cb: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // enable_cb -- Re-enable device interrupts
    // ------------------------------------------------------------------
    virtual function void enable_cb();
        write_avail_16(0, 16'h0);
        barrier.mb("after enable_cb");
        `uvm_info("SPLIT_VQ",
            $sformatf("enable_cb: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // enable_cb_delayed -- Enable interrupts with EVENT_IDX optimization
    // ------------------------------------------------------------------
    virtual function void enable_cb_delayed();
        if (event_idx_enabled) begin
            bit [15:0] device_used_idx;
            // Read current device used idx
            device_used_idx = read_used_16(2);
            // Write to used_event in avail ring (offset 4 + 2*queue_size)
            write_avail_16(4 + 2 * queue_size, device_used_idx);
        end else begin
            enable_cb();
        end

        `uvm_info("SPLIT_VQ",
            $sformatf("enable_cb_delayed: queue_id=%0d event_idx=%0b",
                      queue_id, event_idx_enabled),
            UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // vq_poll -- Check if used ring has new entries since last_used
    // ------------------------------------------------------------------
    virtual function bit vq_poll(int unsigned last_used);
        bit [15:0] device_used_idx;
        device_used_idx = read_used_16(2);
        return (device_used_idx != last_used[15:0]);
    endfunction

    // =================================================================
    // Query methods
    // =================================================================

    virtual function int unsigned get_free_count();
        return num_free;
    endfunction

    virtual function int unsigned get_pending_count();
        return queue_size - num_free;
    endfunction

    // ------------------------------------------------------------------
    // needs_notification -- Check if device needs a kick
    //
    // With EVENT_IDX: uses vring_need_event algorithm.
    // Without: checks VIRTQ_USED_F_NO_NOTIFY flag in used ring.
    // ------------------------------------------------------------------
    virtual function bit needs_notification();
        if (event_idx_enabled) begin
            bit [15:0] avail_event;
            bit [15:0] new_idx;
            bit [15:0] old_idx;
            // avail_event is at used ring offset 4 + 8*queue_size
            avail_event = read_used_16(4 + 8 * queue_size);
            new_idx = avail_idx[15:0];
            old_idx = avail_idx[15:0] - 16'h1;
            // vring_need_event: (new_idx - event_idx - 1) < (new_idx - old_idx)
            return ((new_idx - avail_event - 16'h1) < (new_idx - old_idx));
        end else begin
            bit [15:0] used_flags;
            used_flags = read_used_16(0);
            return !(used_flags & VIRTQ_USED_F_NO_NOTIFY);
        end
    endfunction

    // =================================================================
    // DMA helpers
    // =================================================================

    virtual function bit [63:0] dma_map_buf(
        bit [63:0] gpa, int unsigned size, dma_dir_e dir
    );
        bit [63:0] iova;
        iommu_mapping_t mapping;

        iova = iommu.map(bdf, gpa, size, dir);

        mapping.bdf     = bdf;
        mapping.gpa     = gpa;
        mapping.iova    = iova;
        mapping.size    = size;
        mapping.dir     = dir;
        mapping.desc_id = 0;
        dma_mappings.push_back(mapping);

        `uvm_info("SPLIT_VQ",
            $sformatf("dma_map_buf: queue_id=%0d gpa=0x%016x iova=0x%016x size=%0d dir=%s",
                      queue_id, gpa, iova, size, dir.name()),
            UVM_HIGH)

        return iova;
    endfunction

    virtual function void dma_unmap_buf(bit [63:0] iova);
        int found_idx = -1;

        foreach (dma_mappings[i]) begin
            if (dma_mappings[i].iova == iova) begin
                found_idx = i;
                break;
            end
        end

        if (found_idx >= 0) begin
            iommu.unmap(bdf, iova);
            dma_mappings.delete(found_idx);
            `uvm_info("SPLIT_VQ",
                $sformatf("dma_unmap_buf: queue_id=%0d iova=0x%016x", queue_id, iova),
                UVM_HIGH)
        end else begin
            `uvm_error("SPLIT_VQ",
                $sformatf("dma_unmap_buf: queue_id=%0d iova=0x%016x not found in dma_mappings",
                          queue_id, iova))
        end
    endfunction

    // =================================================================
    // Error injection
    // =================================================================

    virtual function void inject_desc_error(virtqueue_error_e err_type);
        case (err_type)
            VQ_ERR_SKIP_WMB_BEFORE_AVAIL,
            VQ_ERR_SKIP_RMB_BEFORE_USED,
            VQ_ERR_SKIP_MB_BEFORE_KICK: begin
                barrier.inject_barrier_skip(err_type);
            end
            default: begin
                if (err_inj != null)
                    err_inj.configure(err_type);
                else
                    `uvm_warning("SPLIT_VQ",
                        $sformatf("inject_desc_error: queue_id=%0d err_inj is null, cannot inject %s",
                                  queue_id, err_type.name()))
            end
        endcase

        `uvm_info("SPLIT_VQ",
            $sformatf("inject_desc_error: queue_id=%0d type=%s", queue_id, err_type.name()),
            UVM_MEDIUM)
    endfunction

    // =================================================================
    // Migration snapshot
    // =================================================================

    // ------------------------------------------------------------------
    // save_state -- Capture full queue state for live migration
    // ------------------------------------------------------------------
    virtual function void save_state(ref virtqueue_snapshot_t snap);
        int unsigned desc_size  = 16 * queue_size;
        int unsigned avail_size = 6 + 2 * queue_size;
        int unsigned used_size  = 6 + 8 * queue_size;
        int unsigned total_ring_size = desc_size + avail_size + used_size;
        byte desc_data[];
        byte avail_data[];
        byte used_data[];

        snap.queue_id       = queue_id;
        snap.queue_size     = queue_size;
        snap.desc_addr      = desc_table_addr;
        snap.driver_addr    = driver_ring_addr;
        snap.device_addr    = device_ring_addr;
        snap.last_avail_idx = avail_idx;
        snap.last_used_idx  = last_used_idx;
        snap.avail_wrap     = 0;
        snap.used_wrap      = 0;

        // Read all ring memory
        mem.read_mem(desc_table_addr, desc_size, desc_data);
        mem.read_mem(driver_ring_addr, avail_size, avail_data);
        mem.read_mem(device_ring_addr, used_size, used_data);

        // Concatenate into single ring_data array
        snap.ring_data = new[total_ring_size];
        foreach (desc_data[i])  snap.ring_data[i] = desc_data[i];
        foreach (avail_data[i]) snap.ring_data[desc_size + i] = avail_data[i];
        foreach (used_data[i])  snap.ring_data[desc_size + avail_size + i] = used_data[i];

        `uvm_info("SPLIT_VQ",
            $sformatf("save_state: queue_id=%0d avail_idx=%0d last_used_idx=%0d ring_data=%0d bytes",
                      queue_id, avail_idx, last_used_idx, snap.ring_data.size()),
            UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // restore_state -- Restore queue state from a migration snapshot
    // ------------------------------------------------------------------
    virtual function void restore_state(virtqueue_snapshot_t snap);
        int unsigned desc_size  = 16 * snap.queue_size;
        int unsigned avail_size = 6 + 2 * snap.queue_size;
        int unsigned used_size  = 6 + 8 * snap.queue_size;
        byte region_data[];

        queue_id   = snap.queue_id;
        queue_size = snap.queue_size;

        // Allocate new rings
        desc_table_addr  = mem.alloc(desc_size,  .align(4096));
        driver_ring_addr = mem.alloc(avail_size, .align(2));
        device_ring_addr = mem.alloc(used_size,  .align(4096));

        if (desc_table_addr == '1 || driver_ring_addr == '1 || device_ring_addr == '1) begin
            `uvm_error("SPLIT_VQ",
                $sformatf("restore_state: alloc failed for queue_id=%0d", queue_id))
            return;
        end

        // Write descriptor table data back
        region_data = new[desc_size];
        foreach (region_data[i]) region_data[i] = snap.ring_data[i];
        mem.write_mem(desc_table_addr, region_data);

        // Write avail ring data back
        region_data = new[avail_size];
        foreach (region_data[i]) region_data[i] = snap.ring_data[desc_size + i];
        mem.write_mem(driver_ring_addr, region_data);

        // Write used ring data back
        region_data = new[used_size];
        foreach (region_data[i]) region_data[i] = snap.ring_data[desc_size + avail_size + i];
        mem.write_mem(device_ring_addr, region_data);

        // Restore indices
        avail_idx     = snap.last_avail_idx;
        last_used_idx = snap.last_used_idx;

        // Restore free count based on outstanding tokens
        num_free  = queue_size - token_map.size();
        free_head = 0;

        state = VQ_CONFIGURE;

        `uvm_info("SPLIT_VQ",
            $sformatf("restore_state: queue_id=%0d avail_idx=%0d last_used_idx=%0d",
                      queue_id, avail_idx, last_used_idx),
            UVM_MEDIUM)
    endfunction

endclass : split_virtqueue

`endif // SPLIT_VIRTQUEUE_SV
