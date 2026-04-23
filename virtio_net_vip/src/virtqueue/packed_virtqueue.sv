`ifndef PACKED_VIRTQUEUE_SV
`define PACKED_VIRTQUEUE_SV

// ============================================================================
// packed_virtqueue
//
// Full implementation of the virtio packed virtqueue per the virtio 1.2
// specification. Extends virtqueue_base and implements all 18 pure virtual
// methods.
//
// Memory layout (single contiguous region):
//   Descriptor ring: 16 bytes/entry, 4096-byte aligned
//   Driver Event Suppression: 4 bytes (immediately after descriptor ring)
//   Device Event Suppression: 4 bytes (after driver event suppression)
//
// Packed virtqueue key differences from split:
//   - Single ring instead of three separate regions
//   - AVAIL and USED flags embedded in descriptor flags field
//   - Wrap counter toggles when ring index wraps around
//   - In-order completion support (VIRTIO_F_IN_ORDER)
//
// Depends on:
//   - virtqueue_base (base class)
//   - host_mem_manager (memory backend)
//   - virtio_iommu_model (DMA address translation)
//   - virtio_memory_barrier_model (memory ordering)
//   - virtqueue_error_injector (fault injection)
//   - virtio_net_types.sv (all type definitions)
// ============================================================================

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
    protected int unsigned free_id_list[$];

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "packed_virtqueue");
        super.new(name);
        next_avail_idx     = 0;
        next_used_idx      = 0;
        avail_wrap_counter = 1;
        used_wrap_counter  = 1;
        event_idx_enabled  = 0;
        in_order_enabled   = 0;
        desc_ring_size     = 0;
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

    // Read only the flags field of a packed descriptor
    protected function bit [15:0] read_packed_desc_flags(int unsigned idx);
        byte data[];
        mem.read_mem(desc_table_addr + idx * 16 + 14, 2, data);
        return {data[1], data[0]};
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

    // ------------------------------------------------------------------
    // alloc_rings -- Allocate and initialize packed descriptor ring and
    //                event suppression areas
    // ------------------------------------------------------------------
    virtual function void alloc_rings();
        int unsigned total_size;

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

    // ------------------------------------------------------------------
    // free_rings -- Deallocate all ring memory
    // ------------------------------------------------------------------
    virtual function void free_rings();
        if (desc_table_addr != 0) mem.free(desc_table_addr);

        desc_table_addr   = 0;
        driver_ring_addr  = 0;
        device_ring_addr  = 0;
        driver_event_addr = 0;
        device_event_addr = 0;
        state             = VQ_RESET;

        `uvm_info("PACKED_VQ",
            $sformatf("free_rings: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

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
        token_map.delete();
        dma_mappings.delete();
        total_add_buf_ops   = 0;
        total_poll_used_ops = 0;
        total_kick_ops      = 0;

        `uvm_info("PACKED_VQ",
            $sformatf("reset_queue: queue_id=%0d", queue_id), UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // detach_all_unused -- Collect all outstanding tokens and clean up
    // ------------------------------------------------------------------
    virtual function void detach_all_unused(ref uvm_object tokens[$]);
        foreach (token_map[desc_id]) begin
            tokens.push_back(token_map[desc_id]);
        end

        foreach (dma_mappings[i]) begin
            iommu.unmap(bdf, dma_mappings[i].iova);
        end

        token_map.delete();
        dma_mappings.delete();

        `uvm_info("PACKED_VQ",
            $sformatf("detach_all_unused: queue_id=%0d returned %0d tokens",
                      queue_id, tokens.size()),
            UVM_HIGH)
    endfunction

    // =================================================================
    // Driver operations
    // =================================================================

    // ------------------------------------------------------------------
    // add_buf -- Add scatter-gather buffers to the packed descriptor ring
    //
    // For each sg entry:
    //   1. Allocate a buffer ID from free_id_list
    //   2. Write descriptor at next_avail_idx with AVAIL/USED flags
    //   3. Advance next_avail_idx, flip wrap counter on wrap
    //
    // Returns the first descriptor index (head), or '1 on error.
    // ------------------------------------------------------------------
    virtual function int unsigned add_buf(
        virtio_sg_list  sgs[],
        int unsigned    n_out_sgs,
        int unsigned    n_in_sgs,
        uvm_object      token,
        bit             indirect
    );
        int unsigned total_needed = 0;
        int unsigned total_sgs = n_out_sgs + n_in_sgs;
        int unsigned head_idx;
        int unsigned head_id;
        int unsigned sg_count = 0;
        bit          is_write;

        // Calculate total descriptors needed
        for (int unsigned s = 0; s < total_sgs; s++) begin
            total_needed += sgs[s].entries.size();
        end

        if (total_needed == 0) begin
            `uvm_error("PACKED_VQ",
                $sformatf("add_buf: queue_id=%0d no sg entries provided", queue_id))
            return '1;
        end

        // Check free descriptors
        if (free_id_list.size() < total_needed) begin
            `uvm_error("PACKED_VQ",
                $sformatf("add_buf: queue_id=%0d need %0d descriptors but only %0d free",
                          queue_id, total_needed, free_id_list.size()))
            return '1;
        end

        head_idx = next_avail_idx;

        // Process each sg list
        for (int unsigned s = 0; s < total_sgs; s++) begin
            is_write = (s >= n_out_sgs);

            for (int unsigned e = 0; e < sgs[s].entries.size(); e++) begin
                bit [15:0] flags = 0;
                int unsigned buf_id;

                // Take a buffer ID from the free list
                buf_id = free_id_list.pop_front();

                // Remember the head buffer ID for token tracking
                if (sg_count == 0) head_id = buf_id;

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

                // Write descriptor
                write_packed_desc(next_avail_idx,
                                  sgs[s].entries[e].addr,
                                  sgs[s].entries[e].len,
                                  buf_id[15:0],
                                  flags);

                // Advance next_avail_idx
                advance_idx(next_avail_idx, avail_wrap_counter);
            end
        end

        // Memory barrier before making descriptors visible
        barrier.wmb("before packed ring descriptors visible");

        // Store token keyed by head buffer ID
        token_map[head_id] = token;

        total_add_buf_ops++;

        `uvm_info("PACKED_VQ",
            $sformatf({"add_buf: queue_id=%0d head_idx=%0d head_id=%0d ",
                       "n_out=%0d n_in=%0d total_desc=%0d free=%0d"},
                      queue_id, head_idx, head_id, n_out_sgs, n_in_sgs,
                      total_needed, free_id_list.size()),
            UVM_HIGH)

        return head_idx;
    endfunction

    // ------------------------------------------------------------------
    // kick -- Notify the device that new buffers are available
    // ------------------------------------------------------------------
    virtual task kick();
        total_kick_ops++;
        `uvm_info("PACKED_VQ",
            $sformatf("kick: queue_id=%0d next_avail_idx=%0d wrap=%0b",
                      queue_id, next_avail_idx, avail_wrap_counter),
            UVM_HIGH)
        // Actual transport kick (PCIe TLP) connected externally
    endtask

    // ------------------------------------------------------------------
    // poll_used -- Check for completed buffers in the packed ring
    //
    // In packed virtqueue, the device marks descriptors as used by
    // toggling the USED flag to match the used_wrap_counter.
    //
    // Returns 1 if a completed buffer was found, 0 otherwise.
    // ------------------------------------------------------------------
    virtual function bit poll_used(
        ref uvm_object      token,
        ref int unsigned     len
    );
        bit [63:0] d_addr;
        bit [31:0] d_len;
        bit [15:0] d_id;
        bit [15:0] d_flags;
        bit        desc_used;
        int unsigned buf_id;

        // Read barrier before reading used descriptors
        barrier.rmb("before reading packed used descriptors");

        // Read descriptor at next_used_idx
        read_packed_desc(next_used_idx, d_addr, d_len, d_id, d_flags);

        // Check if this descriptor has been marked used by the device
        // The USED flag should match used_wrap_counter
        desc_used = (d_flags & VIRTQ_DESC_F_USED) ? 1'b1 : 1'b0;

        if (desc_used != used_wrap_counter)
            return 0;

        buf_id = d_id;

        // Recover token
        if (!token_map.exists(buf_id)) begin
            `uvm_error("PACKED_VQ",
                $sformatf("poll_used: queue_id=%0d buf_id=%0d not found in token_map",
                          queue_id, buf_id))
            return 0;
        end
        token = token_map[buf_id];
        token_map.delete(buf_id);

        // Return buffer ID to free list
        free_id_list.push_back(buf_id);

        len = d_len;

        // Advance through the chain if NEXT flag is set
        advance_idx(next_used_idx, used_wrap_counter);

        if (d_flags & VIRTQ_DESC_F_NEXT) begin
            // Walk the chain to skip chained descriptors
            int unsigned safety_count = 0;
            bit [63:0] chain_addr;
            bit [31:0] chain_len;
            bit [15:0] chain_id;
            bit [15:0] chain_flags;

            forever begin
                read_packed_desc(next_used_idx, chain_addr, chain_len,
                                 chain_id, chain_flags);

                // Return chained buffer IDs to free list
                free_id_list.push_back(chain_id);

                advance_idx(next_used_idx, used_wrap_counter);

                if (!(chain_flags & VIRTQ_DESC_F_NEXT))
                    break;

                safety_count++;
                if (safety_count > queue_size) begin
                    `uvm_error("PACKED_VQ",
                        $sformatf("poll_used: queue_id=%0d circular chain detected",
                                  queue_id))
                    break;
                end
            end
        end

        total_poll_used_ops++;

        `uvm_info("PACKED_VQ",
            $sformatf("poll_used: queue_id=%0d buf_id=%0d len=%0d free=%0d",
                      queue_id, buf_id, d_len, free_id_list.size()),
            UVM_HIGH)

        return 1;
    endfunction

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

    // ------------------------------------------------------------------
    // vq_poll -- Check if ring has new used entries since last_used
    // ------------------------------------------------------------------
    virtual function bit vq_poll(int unsigned last_used);
        bit [63:0] d_addr;
        bit [31:0] d_len;
        bit [15:0] d_id;
        bit [15:0] d_flags;
        bit        desc_used;

        read_packed_desc(next_used_idx, d_addr, d_len, d_id, d_flags);
        desc_used = (d_flags & VIRTQ_DESC_F_USED) ? 1'b1 : 1'b0;
        return (desc_used == used_wrap_counter);
    endfunction

    // =================================================================
    // Query methods
    // =================================================================

    virtual function int unsigned get_free_count();
        return free_id_list.size();
    endfunction

    virtual function int unsigned get_pending_count();
        return queue_size - free_id_list.size();
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
    // DMA helpers (same pattern as split virtqueue)
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

        `uvm_info("PACKED_VQ",
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
            `uvm_info("PACKED_VQ",
                $sformatf("dma_unmap_buf: queue_id=%0d iova=0x%016x", queue_id, iova),
                UVM_HIGH)
        end else begin
            `uvm_error("PACKED_VQ",
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
                    `uvm_warning("PACKED_VQ",
                        $sformatf({"inject_desc_error: queue_id=%0d err_inj is null, ",
                                   "cannot inject %s"},
                                  queue_id, err_type.name()))
            end
        endcase

        `uvm_info("PACKED_VQ",
            $sformatf("inject_desc_error: queue_id=%0d type=%s",
                      queue_id, err_type.name()),
            UVM_MEDIUM)
    endfunction

    // =================================================================
    // Migration snapshot
    // =================================================================

    // ------------------------------------------------------------------
    // save_state -- Capture full packed queue state for live migration
    // ------------------------------------------------------------------
    virtual function void save_state(ref virtqueue_snapshot_t snap);
        int unsigned total_size = desc_ring_size + 4 + 4;
        byte ring_data[];

        snap.queue_id       = queue_id;
        snap.queue_size     = queue_size;
        snap.desc_addr      = desc_table_addr;
        snap.driver_addr    = driver_event_addr;
        snap.device_addr    = device_event_addr;
        snap.last_avail_idx = next_avail_idx;
        snap.last_used_idx  = next_used_idx;
        snap.avail_wrap     = avail_wrap_counter;
        snap.used_wrap      = used_wrap_counter;

        // Read entire ring + event suppression areas
        mem.read_mem(desc_table_addr, total_size, ring_data);

        snap.ring_data = new[total_size];
        foreach (ring_data[i]) snap.ring_data[i] = ring_data[i];

        `uvm_info("PACKED_VQ",
            $sformatf({"save_state: queue_id=%0d next_avail=%0d next_used=%0d ",
                       "avail_wrap=%0b used_wrap=%0b ring_data=%0d bytes"},
                      queue_id, next_avail_idx, next_used_idx,
                      avail_wrap_counter, used_wrap_counter, snap.ring_data.size()),
            UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // restore_state -- Restore packed queue state from a migration snapshot
    // ------------------------------------------------------------------
    virtual function void restore_state(virtqueue_snapshot_t snap);
        int unsigned total_size;
        byte region_data[];

        queue_id       = snap.queue_id;
        queue_size     = snap.queue_size;
        desc_ring_size = 16 * queue_size;
        total_size     = desc_ring_size + 4 + 4;

        // Allocate new ring
        desc_table_addr = mem.alloc(total_size, .align(4096));

        if (desc_table_addr == '1) begin
            `uvm_error("PACKED_VQ",
                $sformatf("restore_state: alloc failed for queue_id=%0d", queue_id))
            return;
        end

        driver_event_addr = desc_table_addr + desc_ring_size;
        device_event_addr = driver_event_addr + 4;
        driver_ring_addr  = driver_event_addr;
        device_ring_addr  = device_event_addr;

        // Write ring data back
        region_data = new[total_size];
        foreach (region_data[i]) region_data[i] = snap.ring_data[i];
        mem.write_mem(desc_table_addr, region_data);

        // Restore indices and wrap counters
        next_avail_idx     = snap.last_avail_idx;
        next_used_idx      = snap.last_used_idx;
        avail_wrap_counter = snap.avail_wrap;
        used_wrap_counter  = snap.used_wrap;

        // Rebuild free_id_list: IDs not in token_map are free
        free_id_list.delete();
        for (int unsigned i = 0; i < queue_size; i++) begin
            if (!token_map.exists(i))
                free_id_list.push_back(i);
        end

        state = VQ_CONFIGURE;

        `uvm_info("PACKED_VQ",
            $sformatf({"restore_state: queue_id=%0d next_avail=%0d next_used=%0d ",
                       "avail_wrap=%0b used_wrap=%0b"},
                      queue_id, next_avail_idx, next_used_idx,
                      avail_wrap_counter, used_wrap_counter),
            UVM_MEDIUM)
    endfunction

endclass : packed_virtqueue

`endif // PACKED_VIRTQUEUE_SV
