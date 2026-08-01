`ifndef VIRTIO_IOMMU_MODEL_SV
`define VIRTIO_IOMMU_MODEL_SV

// ============================================================================
// virtio_iommu_model
//
// Models IOMMU address translation for DMA operations in the virtio-net VIP.
//
// Provides:
//   - map/unmap of guest physical addresses (GPA) to I/O virtual addresses
//     (IOVA) with a bump allocator
//   - translate() for DMA address resolution with permission and range checks
//   - Fault injection via configurable rules
//   - Use-after-unmap detection
//   - Dirty page tracking (4KB granularity)
//   - Leak checking at test end
//   - Translation statistics
//
// Depends on: virtio_net_types.sv (dma_dir_e, iommu_fault_e,
//             iommu_mapping_entry_t, iommu_fault_rule_t)
// ============================================================================

class virtio_iommu_model extends uvm_object;
    `uvm_object_utils(virtio_iommu_model)

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    localparam bit [63:0] IOVA_BASE      = 64'h8000_0000;
    localparam int unsigned PAGE_SIZE     = 4096;
    localparam int unsigned PAGE_SHIFT    = 12;

    // ------------------------------------------------------------------
    // Bump allocator state
    // ------------------------------------------------------------------
    protected bit [63:0] next_iova = IOVA_BASE;

    // ------------------------------------------------------------------
    // Mapping table: keyed by {bdf[15:0], iova[63:0]} = 80-bit key
    // ------------------------------------------------------------------
    protected iommu_mapping_entry_t mapping_table[bit [79:0]];

    // ------------------------------------------------------------------
    // Unmap history for use-after-unmap detection
    // ------------------------------------------------------------------
    protected iommu_mapping_entry_t unmap_history[$];

    // ------------------------------------------------------------------
    // Fault injection rules
    // ------------------------------------------------------------------
    protected iommu_fault_rule_t fault_rules[$];

    // ------------------------------------------------------------------
    // Dirty page tracking
    // ------------------------------------------------------------------
    bit dirty_tracking_enable = 0;
    protected bit dirty_bitmap[bit [63:0]];
    // page ID -> mapping key -> completed device-write snapshot.  A device
    // write is not dirty until its bytes have reached host memory; retaining
    // this full post-write span before completion cleanup protects migration
    // from the following unmap/free pair.
    protected virtio_dirty_page_snapshot_t dirty_page_snapshot[
        bit [63:0]
    ][bit [79:0]];
    protected bit [63:0] dirty_generation_counter = 0;
    protected bit [63:0] active_dirty_generation = 0;

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    bit strict_permission_check = 1;

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------
    int unsigned total_maps       = 0;
    int unsigned total_unmaps     = 0;
    int unsigned total_translates = 0;
    int unsigned total_faults     = 0;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtio_iommu_model");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // map -- Allocate IOVA and create a mapping entry
    //
    // Allocates a page-aligned IOVA region via bump allocator and stores
    // the mapping in the associative array keyed by {bdf, iova}.
    // Returns the allocated IOVA.
    // ------------------------------------------------------------------
    virtual function bit [63:0] map(bit [15:0] bdf,
                            bit [63:0] gpa,
                            int unsigned size,
                            dma_dir_e dir,
                            string file = "",
                            int line = 0);
        bit [63:0] iova;
        bit [79:0] key;
        iommu_mapping_entry_t entry;
        bit [63:0] aligned_size;
        bit [63:0] allocation_end;

        // Keep the legacy bump allocator subject to the same range and
        // collision rules as map_fixed().  In particular, do not let the
        // 32-bit caller size overflow while it is rounded to a page span.
        if (size == 0) begin
            `uvm_error("IOMMU_MAP", "map: zero-size mapping is invalid")
            return '1;
        end
        aligned_size = ({32'd0, size} + PAGE_SIZE - 1) / PAGE_SIZE;
        aligned_size = aligned_size * PAGE_SIZE;
        if ((next_iova < IOVA_BASE) ||
            ((next_iova & (PAGE_SIZE - 1)) != 0) ||
            (next_iova > (64'hffff_ffff_ffff_ffff - aligned_size))) begin
            `uvm_error("IOMMU_MAP", $sformatf(
                "map: invalid IOVA range start=0x%016x size=%0d",
                next_iova, size))
            return '1;
        end

        iova = next_iova;
        allocation_end = iova + aligned_size;
        foreach (mapping_table[live_key]) begin
            iommu_mapping_entry_t live_entry;
            bit [63:0] live_aligned_size;
            bit [63:0] live_end;

            live_entry = mapping_table[live_key];
            if ((live_entry.bdf != bdf) || !live_entry.valid)
                continue;
            live_aligned_size = ({32'd0, live_entry.size} + PAGE_SIZE - 1) /
                                PAGE_SIZE;
            live_aligned_size = live_aligned_size * PAGE_SIZE;
            if (live_entry.iova >
                (64'hffff_ffff_ffff_ffff - live_aligned_size)) begin
                `uvm_error("IOMMU_MAP", $sformatf(
                    "map: live mapping has invalid IOVA range start=0x%016x size=%0d",
                    live_entry.iova, live_entry.size))
                return '1;
            end
            live_end = live_entry.iova + live_aligned_size;
            if ((iova < live_end) && (live_entry.iova < allocation_end)) begin
                `uvm_error("IOMMU_MAP", $sformatf(
                    "map: IOVA collision BDF=0x%04x requested=[0x%016x..0x%016x) live=[0x%016x..0x%016x)",
                    bdf, iova, allocation_end, live_entry.iova, live_end))
                return '1;
            end
        end

        next_iova = allocation_end;

        // Build mapping entry
        entry.bdf         = bdf;
        entry.gpa         = gpa;
        entry.iova        = iova;
        entry.size        = size;
        entry.dir         = dir;
        entry.valid       = 1;
        entry.map_time    = $realtime;
        entry.caller_file = file;
        entry.caller_line = line;

        // Store in table with 80-bit key: {bdf, iova}
        key = {bdf, iova};
        mapping_table[key] = entry;

        total_maps++;

        `uvm_info("IOMMU_MAP",
            $sformatf("BDF=0x%04x GPA=0x%016x -> IOVA=0x%016x size=%0d dir=%s [%s:%0d]",
                      bdf, gpa, iova, size, dir.name(), file, line),
            UVM_HIGH)

        return iova;
    endfunction

    // ------------------------------------------------------------------
    // map_fixed -- Create a mapping at a previously assigned stable IOVA
    //
    // Migration uses this to recreate a retired source mapping without
    // rewriting every possible descriptor format that may retain its IOVA.
    // A fixed range must be page aligned, lie in the model IOVA range, not
    // wrap, and not overlap a live range in the same requester domain.
    // Retired history deliberately does not reserve an IOVA: a restored
    // mapping is allowed to reuse the source address after reset.
    // ------------------------------------------------------------------
    virtual function bit [63:0] map_fixed(bit [15:0] bdf,
                                          bit [63:0] gpa,
                                          int unsigned size,
                                          dma_dir_e dir,
                                          bit [63:0] requested_iova,
                                          string file = "",
                                          int line = 0);
        bit [79:0] key;
        iommu_mapping_entry_t entry;
        bit [63:0] aligned_size;
        bit [63:0] requested_end;

        if (size == 0) begin
            `uvm_error("IOMMU_MAP", "map_fixed: zero-size mapping is invalid")
            return '1;
        end
        aligned_size = ({32'd0, size} + PAGE_SIZE - 1) / PAGE_SIZE;
        aligned_size = aligned_size * PAGE_SIZE;
        if ((requested_iova < IOVA_BASE) ||
            ((requested_iova & (PAGE_SIZE - 1)) != 0) ||
            (requested_iova > (64'hffff_ffff_ffff_ffff - aligned_size))) begin
            `uvm_error("IOMMU_MAP", $sformatf(
                "map_fixed: invalid IOVA range start=0x%016x size=%0d",
                requested_iova, size))
            return '1;
        end
        requested_end = requested_iova + aligned_size;
        foreach (mapping_table[live_key]) begin
            iommu_mapping_entry_t live_entry;
            bit [63:0] live_aligned_size;
            bit [63:0] live_end;

            live_entry = mapping_table[live_key];
            if (live_entry.bdf != bdf || !live_entry.valid)
                continue;
            live_aligned_size = ({32'd0, live_entry.size} + PAGE_SIZE - 1) /
                                PAGE_SIZE;
            live_aligned_size = live_aligned_size * PAGE_SIZE;
            live_end = live_entry.iova + live_aligned_size;
            if ((requested_iova < live_end) && (live_entry.iova < requested_end)) begin
                `uvm_error("IOMMU_MAP", $sformatf(
                    "map_fixed: IOVA collision BDF=0x%04x requested=[0x%016x..0x%016x) live=[0x%016x..0x%016x)",
                    bdf, requested_iova, requested_end,
                    live_entry.iova, live_end))
                return '1;
            end
        end

        entry.bdf         = bdf;
        entry.gpa         = gpa;
        entry.iova        = requested_iova;
        entry.size        = size;
        entry.dir         = dir;
        entry.valid       = 1;
        entry.map_time    = $realtime;
        entry.caller_file = file;
        entry.caller_line = line;
        key = {bdf, requested_iova};
        mapping_table[key] = entry;
        if (requested_end > next_iova)
            next_iova = requested_end;
        total_maps++;

        `uvm_info("IOMMU_MAP", $sformatf(
            "Fixed BDF=0x%04x GPA=0x%016x -> IOVA=0x%016x size=%0d dir=%s [%s:%0d]",
            bdf, gpa, requested_iova, size, dir.name(), file, line), UVM_HIGH)
        return requested_iova;
    endfunction

    // ------------------------------------------------------------------
    // unmap -- Remove a mapping from the table
    //
    // Moves the entry to unmap_history for use-after-unmap detection.
    // Reports an error if the mapping is not found.
    // ------------------------------------------------------------------
    virtual function void unmap(bit [15:0] bdf,
                        bit [63:0] iova,
                        string file = "",
                        int line = 0);
        bit [79:0] key;

        key = {bdf, iova};

        if (!mapping_table.exists(key)) begin
            `uvm_error("IOMMU_UNMAP",
                $sformatf("Mapping not found: BDF=0x%04x IOVA=0x%016x [%s:%0d]",
                          bdf, iova, file, line))
            return;
        end

        // Save to history before removing
        mapping_table[key].valid = 0;
        unmap_history.push_back(mapping_table[key]);
        mapping_table.delete(key);

        total_unmaps++;

        `uvm_info("IOMMU_UNMAP",
            $sformatf("BDF=0x%04x IOVA=0x%016x [%s:%0d]",
                      bdf, iova, file, line),
            UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // translate -- Resolve IOVA to GPA with full checking
    //
    // Returns 1 on success (gpa set), 0 on fault (fault set).
    // Device-to-guest writes must use write_from_device() so post-write dirty
    // capture cannot be bypassed.  This public API is therefore limited to
    // device reads (DMA_TO_DEVICE); write_from_device() calls the protected
    // translation primitive below after it has committed to the write path.
    //
    // Check order for allowed translations: fault injection -> mapping lookup
    // -> use-after-unmap -> range check -> permission check -> compute GPA.
    //   -> range check -> permission check -> compute GPA.
    // ------------------------------------------------------------------
    function bit translate(bit [15:0] bdf,
                           bit [63:0] iova,
                           int unsigned size,
                           dma_dir_e access_dir,
                           ref bit [63:0] gpa,
                           ref iommu_fault_e fault);
        if ((access_dir == DMA_FROM_DEVICE) ||
            (access_dir == DMA_BIDIRECTIONAL)) begin
            total_translates++;
            total_faults++;
            fault = IOMMU_FAULT_PERMISSION;
            `uvm_error("IOMMU_DMA_WRITE", $sformatf(
                "translate: DMA write translation is forbidden; use write_from_device() (BDF=0x%04x IOVA=0x%016x)",
                bdf, iova))
            return 0;
        end
        return translate_internal(bdf, iova, size, access_dir, gpa, fault);
    endfunction

    // write_from_device() is the sole device-write boundary.  Keeping this
    // primitive protected prevents callers from translating a writable DMA
    // range and updating host memory without producing a dirty record.
    protected function bit translate_internal(bit [15:0] bdf,
                                              bit [63:0] iova,
                                              int unsigned size,
                                              dma_dir_e access_dir,
                                              ref bit [63:0] gpa,
                                              ref iommu_fault_e fault);
        bit [79:0] key;
        iommu_mapping_entry_t entry;

        total_translates++;
        fault = IOMMU_NO_FAULT;

        // 1. Check fault injection rules first
        if (check_fault_rules(bdf, iova, access_dir, fault)) begin
            total_faults++;
            `uvm_info("IOMMU_FAULT_INJ",
                $sformatf("Injected fault %s: BDF=0x%04x IOVA=0x%016x dir=%s",
                          fault.name(), bdf, iova, access_dir.name()),
                UVM_MEDIUM)
            return 0;
        end

        // 2. Find a live mapping before considering retired history.  A
        // fixed restore mapping is allowed to reuse a source IOVA that was
        // intentionally placed in unmap_history by the prior reset.
        key = find_mapping_for_iova(bdf, iova);
        if (key == '1) begin
            if (check_use_after_unmap(bdf, iova)) begin
                fault = IOMMU_FAULT_UNMAPPED;
                total_faults++;
                return 0;
            end
            fault = IOMMU_FAULT_UNMAPPED;
            total_faults++;
            `uvm_info("IOMMU_FAULT",
                $sformatf("No mapping found: BDF=0x%04x IOVA=0x%016x size=%0d",
                          bdf, iova, size),
                UVM_MEDIUM)
            return 0;
        end

        entry = mapping_table[key];

        // 3. Range check: (iova + size) <= (entry.iova + entry.size)
        if ((iova + size) > (entry.iova + entry.size)) begin
            fault = IOMMU_FAULT_OUT_OF_RANGE;
            total_faults++;
            `uvm_info("IOMMU_FAULT",
                $sformatf("Out of range: BDF=0x%04x IOVA=0x%016x+%0d exceeds mapping [0x%016x..0x%016x)",
                          bdf, iova, size, entry.iova, entry.iova + entry.size),
                UVM_MEDIUM)
            return 0;
        end

        // 4. Permission check
        if (strict_permission_check) begin
            if (!check_permission(entry.dir, access_dir)) begin
                fault = IOMMU_FAULT_PERMISSION;
                total_faults++;
                `uvm_info("IOMMU_FAULT",
                    $sformatf("Permission denied: BDF=0x%04x IOVA=0x%016x mapped=%s access=%s",
                              bdf, iova, entry.dir.name(), access_dir.name()),
                    UVM_MEDIUM)
                return 0;
            end
        end

        // 5. Compute GPA
        gpa = entry.gpa + (iova - entry.iova);

        return 1;
    endfunction

    // ------------------------------------------------------------------
    // Fault injection
    // ------------------------------------------------------------------

    // Add a fault injection rule. First matching rule wins during translate.
    function void add_fault_rule(iommu_fault_rule_t rule);
        fault_rules.push_back(rule);
        `uvm_info("IOMMU_FAULT_RULE",
            $sformatf("Added rule: bdf_mask=0x%04x iova=[0x%016x..0x%016x] dir=%s fault=%s count=%0d",
                      rule.bdf_mask, rule.iova_start, rule.iova_end,
                      rule.dir.name(), rule.fault_type.name(), rule.trigger_count),
            UVM_HIGH)
    endfunction

    // Clear all fault injection rules.
    function void clear_fault_rules();
        fault_rules.delete();
        `uvm_info("IOMMU_FAULT_RULE", "All fault rules cleared", UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // check_fault_rules -- Check if any fault rule matches
    //
    // Returns 1 if a matching active rule is found (fault is set).
    // First matching rule wins. Rules with trigger_count > 0 are
    // exhausted after triggered >= trigger_count.
    // ------------------------------------------------------------------
    protected function bit check_fault_rules(bit [15:0] bdf,
                                             bit [63:0] iova,
                                             dma_dir_e access_dir,
                                             ref iommu_fault_e fault);
        for (int i = 0; i < fault_rules.size(); i++) begin
            iommu_fault_rule_t rule = fault_rules[i];

            // Skip exhausted rules
            if (rule.trigger_count > 0 && rule.triggered >= rule.trigger_count)
                continue;

            // BDF match: 0xFFFF = wildcard, otherwise exact match
            if (rule.bdf_mask != 16'hFFFF && rule.bdf_mask != bdf)
                continue;

            // IOVA range match
            if (iova < rule.iova_start || iova > rule.iova_end)
                continue;

            // Direction match
            if (rule.dir != DMA_BIDIRECTIONAL && rule.dir != access_dir)
                continue;

            // Rule matches -- increment triggered count
            fault_rules[i].triggered++;
            fault = rule.fault_type;
            return 1;
        end

        return 0;
    endfunction

    // ------------------------------------------------------------------
    // Use-after-unmap detection
    // ------------------------------------------------------------------

    // Check if the given IOVA was previously unmapped. Logs uvm_error
    // if a matching entry is found in unmap_history.
    function bit check_use_after_unmap(bit [15:0] bdf, bit [63:0] iova);
        foreach (unmap_history[i]) begin
            if (unmap_history[i].bdf == bdf &&
                iova >= unmap_history[i].iova &&
                iova < (unmap_history[i].iova + unmap_history[i].size)) begin
                `uvm_error("IOMMU_USE_AFTER_UNMAP",
                    $sformatf("Access to unmapped IOVA: BDF=0x%04x IOVA=0x%016x was mapped at [%s:%0d]",
                              bdf, iova, unmap_history[i].caller_file, unmap_history[i].caller_line))
                return 1;
            end
        end
        return 0;
    endfunction

    // ------------------------------------------------------------------
    // Dirty page tracking
    // ------------------------------------------------------------------

    // Start a fresh migration generation.  The bitmap is discarded before
    // tracking is enabled, so a subsequent capture can contain only writes
    // performed after this call.
    function bit [63:0] begin_dirty_generation();
        dirty_generation_counter++;
        // Generation zero is reserved as the uninitialized snapshot value.
        if (dirty_generation_counter == 0)
            dirty_generation_counter = 1;
        active_dirty_generation = dirty_generation_counter;
        dirty_bitmap.delete();
        dirty_page_snapshot.delete();
        dirty_tracking_enable = 1;
        return active_dirty_generation;
    endfunction

    // Atomically return the dirty set belonging to the active generation and
    // stop collecting it.  SystemVerilog functions execute without advancing
    // simulation time, so a writer cannot interleave with the copy/clear.
    function void capture_dirty_generation(ref bit [63:0] dirty_pages[$]);
        dirty_pages.delete();
        if (!dirty_tracking_enable)
            return;
        foreach (dirty_bitmap[page]) begin
            dirty_pages.push_back(page);
        end
        dirty_bitmap.delete();
        dirty_tracking_enable = 0;
    endfunction

    // Snapshot every live mapping belonging to one requester.  Dirty-page
    // tracking intentionally records only completed device writes; migration
    // also needs the complete bytes of clean live mappings still reachable
    // from raw queue state, such as outstanding TX or indirect descriptors.
    // Copy them while the source allocation is known to be live.
    function bit snapshot_live_mappings(
        host_mem_manager mem,
        bit [15:0] bdf,
        ref virtio_mapping_snapshot_t records[$]
    );
        records.delete();
        if (mem == null) begin
            `uvm_error("IOMMU_MIGRATION",
                "snapshot_live_mappings: missing host memory")
            return 0;
        end
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;
            virtio_mapping_snapshot_t record;

            entry = mapping_table[key];
            if (!entry.valid || (entry.bdf != bdf))
                continue;
            if (entry.size == 0) begin
                records.delete();
                `uvm_error("IOMMU_MIGRATION", $sformatf(
                    "snapshot_live_mappings: zero-size mapping BDF=0x%04x IOVA=0x%016h",
                    bdf, entry.iova))
                return 0;
            end
            record.mapping.bdf = entry.bdf;
            record.mapping.gpa = entry.gpa;
            record.mapping.iova = entry.iova;
            record.mapping.size = entry.size;
            record.mapping.dir = entry.dir;
            record.mapping.desc_id = 0;
            record.checksum = '0;
            mem.read_mem(entry.gpa, entry.size, record.payload);
            if (record.payload.size() != entry.size) begin
                records.delete();
                `uvm_error("IOMMU_MIGRATION", $sformatf(
                    "snapshot_live_mappings: unable to capture %0d bytes at GPA=0x%016h",
                    entry.size, entry.gpa))
                return 0;
            end
            records.push_back(record);
        end
        return 1;
    endfunction

    // The one production boundary for a device-to-guest DMA write.  A caller
    // must use this instead of translate()+host_mem.write_mem(): translation
    // alone happens before the write and cannot preserve bytes once a
    // completion unmaps and frees the buffer.  The completed mapping span is
    // copied while it remains allocated, then normal cleanup may proceed.
    function bit write_from_device(
        host_mem_manager mem,
        bit [15:0] bdf,
        bit [63:0] iova,
        byte data[],
        ref iommu_fault_e fault
    );
        bit [63:0] gpa;
        bit [79:0] mapping_key;
        iommu_mapping_entry_t mapping_entry;

        fault = IOMMU_NO_FAULT;
        if (mem == null) begin
            `uvm_error("IOMMU_DIRTY", "write_from_device: missing host memory")
            return 0;
        end
        if (data.size() == 0)
            return 1;
        if (!translate_internal(bdf, iova, data.size(), DMA_FROM_DEVICE,
                                gpa, fault))
            return 0;

        // write_mem performs the actual guest-memory mutation before dirty
        // capture.  The mapping remains live until this function returns.
        mem.write_mem(gpa, data);
        if (!dirty_tracking_enable)
            return 1;
        mapping_key = find_mapping_for_iova(bdf, iova);
        if (mapping_key == '1) begin
            `uvm_error("IOMMU_DIRTY",
                "write_from_device: successful translation lost its mapping")
            return 0;
        end
        mapping_entry = mapping_table[mapping_key];
        snapshot_completed_dma_write(mem, gpa, data.size(), mapping_key,
                                     mapping_entry);
        return 1;
    endfunction

    // Capture every exact mapping/page intersection touched by a completed
    // device write.  A subsequent write to the same mapping updates the
    // stored span with the latest post-write host-memory contents.
    protected function void snapshot_completed_dma_write(
        host_mem_manager mem,
        bit [63:0] write_gpa,
        int unsigned write_size,
        bit [79:0] mapping_key,
        iommu_mapping_entry_t mapping_entry
    );
        bit [63:0] page_start;
        bit [63:0] page_end;
        iommu_mapping_t mapping;

        if (!dirty_tracking_enable || (write_size == 0))
            return;
        page_start = write_gpa >> PAGE_SHIFT;
        page_end   = (write_gpa + write_size - 1) >> PAGE_SHIFT;
        mapping = '{default: 0};
        mapping.bdf = mapping_entry.bdf;
        mapping.gpa = mapping_entry.gpa;
        mapping.iova = mapping_entry.iova;
        mapping.size = mapping_entry.size;
        mapping.dir = mapping_entry.dir;

        for (bit [63:0] p = page_start; ; p++) begin
            virtio_dirty_page_snapshot_t record;
            bit [63:0] page_base;
            bit [63:0] page_end_gpa;
            bit [63:0] mapping_end;
            bit [63:0] span_end;

            page_base = p << PAGE_SHIFT;
            page_end_gpa = page_base + PAGE_SIZE;
            mapping_end = mapping.gpa + mapping.size;
            record.page_id = p;
            record.mapping = mapping;
            record.mapped_gpa = (mapping.gpa > page_base) ?
                                mapping.gpa : page_base;
            span_end = (mapping_end < page_end_gpa) ? mapping_end : page_end_gpa;
            if (span_end <= record.mapped_gpa) begin
                `uvm_error("IOMMU_DIRTY", $sformatf(
                    "write_from_device: empty mapping span for dirty page 0x%016h", p))
                return;
            end
            record.mapped_size = span_end - record.mapped_gpa;
            mem.read_mem(record.mapped_gpa, record.mapped_size, record.payload);
            if (record.payload.size() != record.mapped_size) begin
                `uvm_error("IOMMU_DIRTY", $sformatf(
                    "write_from_device: unable to snapshot %0d bytes at 0x%016h",
                    record.mapped_size, record.mapped_gpa))
                return;
            end
            dirty_bitmap[p] = 1;
            dirty_page_snapshot[p][mapping_key] = record;
            if (p == page_end)
                break;
        end
    endfunction

    // Backwards-compatible legacy helper.  New migration code must use the
    // explicit begin/capture generation pair above.
    function void get_and_clear_dirty(ref bit [63:0] dirty_pages[$]);
        dirty_pages.delete();
        foreach (dirty_bitmap[page]) begin
            dirty_pages.push_back(page);
        end
        dirty_bitmap.delete();
    endfunction

    // Return the mapping identity that covered a captured page.  A dirty page
    // may be produced by a sub-page mapping, so overlap (not full-page
    // coverage) identifies the mapping that observed the write.
    function bit get_dirty_page_mapping(
        bit [63:0] page_id, ref iommu_mapping_t mapping
    );
        bit [63:0] page_base;
        bit [63:0] page_end;

        mapping = '{default: 0};
        page_base = page_id << PAGE_SHIFT;
        page_end = page_base + PAGE_SIZE;
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;
            entry = mapping_table[key];
            if (entry.valid && (entry.gpa < page_end) &&
                ((entry.gpa + entry.size) > page_base)) begin
                mapping.bdf = entry.bdf;
                mapping.gpa = entry.gpa;
                mapping.iova = entry.iova;
                mapping.size = entry.size;
                mapping.dir = entry.dir;
                mapping.desc_id = 0;
                return 1;
            end
        end
        return 0;
    endfunction

    // Return completed dirty records, including the exact post-write payload
    // captured while the mapping/allocation was still live.
    function void get_dirty_page_records(
        bit [63:0] page_id, ref virtio_dirty_page_snapshot_t records[$]
    );
        records.delete();
        if (!dirty_page_snapshot.exists(page_id))
            return;
        foreach (dirty_page_snapshot[page_id][key]) begin
            records.push_back(dirty_page_snapshot[page_id][key]);
        end
    endfunction

    // Compatibility projection for callers that need only identities.
    function void get_dirty_page_mappings(
        bit [63:0] page_id, ref iommu_mapping_t mappings[$]
    );
        mappings.delete();
        if (!dirty_page_snapshot.exists(page_id))
            return;
        foreach (dirty_page_snapshot[page_id][key]) begin
            mappings.push_back(dirty_page_snapshot[page_id][key].mapping);
        end
    endfunction

    // Confirm that a complete mapping snapshot still names one exact live
    // mapping, or one exact mapping retired since freeze.  Retired backing
    // memory is never dereferenced; the snapshot itself owns those bytes.
    function bit verify_mapping_identity(
        iommu_mapping_t expected, output bit retired
    );
        retired = 0;
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;

            entry = mapping_table[key];
            if (entry.valid && (entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir)) begin
                return 1;
            end
        end
        foreach (unmap_history[i]) begin
            iommu_mapping_entry_t entry;

            entry = unmap_history[i];
            if ((entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir)) begin
                retired = 1;
                return 1;
            end
        end
        return 0;
    endfunction

    // Return one exact live mapping after migration has recreated a stable
    // source IOVA. Queue ownership restoration uses the destination GPA while
    // retaining the descriptor-visible IOVA from the snapshot.
    function bit get_live_mapping(bit [15:0] bdf, bit [63:0] iova,
                                  ref iommu_mapping_t mapping);
        bit [79:0] key;

        mapping = '{default: 0};
        key = {bdf, iova};
        if (!mapping_table.exists(key) || !mapping_table[key].valid)
            return 0;
        mapping.bdf = mapping_table[key].bdf;
        mapping.gpa = mapping_table[key].gpa;
        mapping.iova = mapping_table[key].iova;
        mapping.size = mapping_table[key].size;
        mapping.dir = mapping_table[key].dir;
        mapping.desc_id = 0;
        return 1;
    endfunction

    // Confirm that a saved page is backed by the exact live mapping, or by an
    // exact mapping retired into unmap_history after freeze.  A caller may use
    // a retired identity only after it has validated snapshot-owned payload;
    // it must never dereference the retired host allocation.
    function bit verify_dirty_page_mapping(
        bit [63:0] page_id, iommu_mapping_t expected, output bit retired
    );
        bit [63:0] page_base;
        bit [63:0] page_end;

        retired = 0;
        page_base = page_id << PAGE_SHIFT;
        page_end = page_base + PAGE_SIZE;
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;
            entry = mapping_table[key];
            if (entry.valid && (entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir) &&
                (entry.gpa < page_end) &&
                ((entry.gpa + entry.size) > page_base)) begin
                return 1;
            end
        end
        foreach (unmap_history[i]) begin
            iommu_mapping_entry_t entry;

            entry = unmap_history[i];
            if ((entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir) &&
                (entry.gpa < page_end) &&
                ((entry.gpa + entry.size) > page_base)) begin
                retired = 1;
                return 1;
            end
        end
        return 0;
    endfunction

    // ------------------------------------------------------------------
    // Leak check -- warn about outstanding mappings at test end
    // ------------------------------------------------------------------
    function void leak_check();
        if (mapping_table.size() == 0) begin
            `uvm_info("IOMMU_LEAK", "No outstanding mappings -- clean shutdown", UVM_LOW)
            return;
        end

        `uvm_warning("IOMMU_LEAK",
            $sformatf("%0d outstanding mapping(s) at test end:", mapping_table.size()))

        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t e = mapping_table[key];
            `uvm_warning("IOMMU_LEAK",
                $sformatf("  BDF=0x%04x IOVA=0x%016x GPA=0x%016x size=%0d dir=%s [%s:%0d]",
                          e.bdf, e.iova, e.gpa, e.size, e.dir.name(),
                          e.caller_file, e.caller_line))
        end
    endfunction

    // ------------------------------------------------------------------
    // find_mapping_for_iova -- Helper to find a mapping covering iova
    //
    // Iterates mapping_table to find an entry whose [iova, iova+size)
    // range covers the requested IOVA. Returns the 80-bit key if found,
    // '1 (all-ones) if not found.
    // ------------------------------------------------------------------
    protected function bit [79:0] find_mapping_for_iova(bit [15:0] bdf,
                                                        bit [63:0] iova);
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t e = mapping_table[key];
            if (e.bdf == bdf &&
                e.valid &&
                iova >= e.iova &&
                iova < (e.iova + e.size)) begin
                return key;
            end
        end
        return '1;
    endfunction

    // ------------------------------------------------------------------
    // check_permission -- Verify DMA direction compatibility
    //
    // DMA_BIDIRECTIONAL allows both read and write.
    // DMA_TO_DEVICE mapping cannot be read as DMA_FROM_DEVICE.
    // DMA_FROM_DEVICE mapping cannot be written as DMA_TO_DEVICE.
    // ------------------------------------------------------------------
    protected function bit check_permission(dma_dir_e mapped_dir,
                                            dma_dir_e access_dir);
        if (mapped_dir == DMA_BIDIRECTIONAL || access_dir == DMA_BIDIRECTIONAL)
            return 1;
        return (mapped_dir == access_dir);
    endfunction

    // ------------------------------------------------------------------
    // reset -- Clear all state (for device reset)
    // ------------------------------------------------------------------
    function void reset();
        mapping_table.delete();
        unmap_history.delete();
        fault_rules.delete();
        dirty_bitmap.delete();
        dirty_page_snapshot.delete();
        dirty_tracking_enable = 0;
        dirty_generation_counter = 0;
        active_dirty_generation = 0;
        next_iova          = IOVA_BASE;
        total_maps         = 0;
        total_unmaps       = 0;
        total_translates   = 0;
        total_faults       = 0;
        `uvm_info("IOMMU_RESET", "IOMMU model reset", UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // print_stats -- Display summary statistics
    // ------------------------------------------------------------------
    function void print_stats();
        `uvm_info("IOMMU_STATS",
            $sformatf("Maps=%0d Unmaps=%0d Translates=%0d Faults=%0d Active=%0d History=%0d",
                      total_maps, total_unmaps, total_translates, total_faults,
                      mapping_table.size(), unmap_history.size()),
            UVM_LOW)
    endfunction

endclass : virtio_iommu_model

`endif // VIRTIO_IOMMU_MODEL_SV
