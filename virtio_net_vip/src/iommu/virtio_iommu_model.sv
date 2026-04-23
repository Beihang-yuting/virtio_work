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
    function bit [63:0] map(bit [15:0] bdf,
                            bit [63:0] gpa,
                            int unsigned size,
                            dma_dir_e dir,
                            string file = "",
                            int line = 0);
        bit [63:0] iova;
        bit [79:0] key;
        iommu_mapping_entry_t entry;
        int unsigned aligned_size;

        // Page-align the allocation size (round up)
        aligned_size = ((size + PAGE_SIZE - 1) / PAGE_SIZE) * PAGE_SIZE;

        // Allocate from bump allocator
        iova = next_iova;
        next_iova = next_iova + aligned_size;

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
    // unmap -- Remove a mapping from the table
    //
    // Moves the entry to unmap_history for use-after-unmap detection.
    // Reports an error if the mapping is not found.
    // ------------------------------------------------------------------
    function void unmap(bit [15:0] bdf,
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
    // Check order: fault injection -> use-after-unmap -> mapping lookup
    //   -> range check -> permission check -> compute GPA.
    // ------------------------------------------------------------------
    function bit translate(bit [15:0] bdf,
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

        // 2. Check use-after-unmap
        if (check_use_after_unmap(bdf, iova)) begin
            fault = IOMMU_FAULT_UNMAPPED;
            total_faults++;
            return 0;
        end

        // 3. Find mapping covering this IOVA
        key = find_mapping_for_iova(bdf, iova);
        if (key == '1) begin
            fault = IOMMU_FAULT_UNMAPPED;
            total_faults++;
            `uvm_info("IOMMU_FAULT",
                $sformatf("No mapping found: BDF=0x%04x IOVA=0x%016x size=%0d",
                          bdf, iova, size),
                UVM_MEDIUM)
            return 0;
        end

        entry = mapping_table[key];

        // 4. Range check: (iova + size) <= (entry.iova + entry.size)
        if ((iova + size) > (entry.iova + entry.size)) begin
            fault = IOMMU_FAULT_OUT_OF_RANGE;
            total_faults++;
            `uvm_info("IOMMU_FAULT",
                $sformatf("Out of range: BDF=0x%04x IOVA=0x%016x+%0d exceeds mapping [0x%016x..0x%016x)",
                          bdf, iova, size, entry.iova, entry.iova + entry.size),
                UVM_MEDIUM)
            return 0;
        end

        // 5. Permission check
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

        // 6. Compute GPA
        gpa = entry.gpa + (iova - entry.iova);

        // 7. Mark dirty if tracking enabled
        if (dirty_tracking_enable) begin
            mark_dirty(gpa, size);
        end

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

    // Mark pages covered by [gpa, gpa+size) as dirty (4KB granularity).
    function void mark_dirty(bit [63:0] gpa, int unsigned size);
        bit [63:0] page_start;
        bit [63:0] page_end;

        page_start = gpa >> PAGE_SHIFT;
        page_end   = (gpa + size - 1) >> PAGE_SHIFT;

        for (bit [63:0] p = page_start; p <= page_end; p++) begin
            dirty_bitmap[p] = 1;
        end
    endfunction

    // Return and clear all dirty pages.
    function void get_and_clear_dirty(ref bit [63:0] dirty_pages[$]);
        dirty_pages.delete();
        foreach (dirty_bitmap[page]) begin
            dirty_pages.push_back(page);
        end
        dirty_bitmap.delete();
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
