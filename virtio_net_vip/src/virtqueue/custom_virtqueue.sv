`ifndef CUSTOM_VIRTQUEUE_SV
`define CUSTOM_VIRTQUEUE_SV

// ============================================================================
// virtqueue_custom_callback
//
// Abstract callback class that users must extend to provide custom virtqueue
// behavior. Each method corresponds to a virtqueue_base pure virtual method.
// ============================================================================

virtual class virtqueue_custom_callback extends uvm_object;

    function new(string name = "virtqueue_custom_callback");
        super.new(name);
    endfunction

    // Lifecycle
    pure virtual function void cb_alloc_rings(virtqueue_base vq);
    pure virtual function void cb_free_rings(virtqueue_base vq);
    pure virtual function void cb_reset_queue(virtqueue_base vq);
    pure virtual function void cb_detach_all_unused(virtqueue_base vq, ref uvm_object tokens[$]);

    // Driver operations
    pure virtual function int unsigned cb_add_buf(virtqueue_base vq,
                                                   virtio_sg_list sgs[],
                                                   int unsigned n_out_sgs,
                                                   int unsigned n_in_sgs,
                                                   uvm_object token,
                                                   bit indirect);
    pure virtual task cb_kick(virtqueue_base vq);
    pure virtual function bit cb_poll_used(virtqueue_base vq,
                                            ref uvm_object token,
                                            ref int unsigned len);

    // Notification control
    pure virtual function void cb_disable_cb(virtqueue_base vq);
    pure virtual function void cb_enable_cb(virtqueue_base vq);
    pure virtual function void cb_enable_cb_delayed(virtqueue_base vq);
    pure virtual function bit  cb_vq_poll(virtqueue_base vq, int unsigned last_used);

    // Query
    pure virtual function int unsigned cb_get_free_count(virtqueue_base vq);
    pure virtual function int unsigned cb_get_pending_count(virtqueue_base vq);
    pure virtual function bit          cb_needs_notification(virtqueue_base vq);

    // Error injection
    pure virtual function void cb_inject_desc_error(virtqueue_base vq, virtqueue_error_e err_type);

    // Migration
    pure virtual function void cb_save_state(virtqueue_base vq, ref virtqueue_snapshot_t snap);
    pure virtual function void cb_restore_state(virtqueue_base vq, virtqueue_snapshot_t snap);

endclass : virtqueue_custom_callback

// ============================================================================
// custom_virtqueue
//
// Extends virtqueue_base. Delegates all ring operations to user-provided
// callbacks via virtqueue_custom_callback. Provides helper methods for
// generic descriptor field access based on configurable field definitions.
//
// Users must:
//   1. Extend virtqueue_custom_callback with their implementation
//   2. Create a custom_virtqueue instance
//   3. Set custom_cb before calling alloc_rings()
//   4. Optionally configure desc_entry_size and desc_field_defs
//
// Depends on:
//   - virtqueue_base (base class)
//   - host_mem_manager (memory backend)
//   - virtio_iommu_model (DMA address translation)
//   - virtio_memory_barrier_model (memory ordering)
//   - virtqueue_error_injector (fault injection)
//   - virtio_net_types.sv (all type definitions)
// ============================================================================

class custom_virtqueue extends virtqueue_base;
    `uvm_object_utils(custom_virtqueue)

    // ===== User-configurable descriptor layout =====
    int unsigned desc_entry_size = 16;      // bytes per descriptor (default 16 like standard)
    string       desc_field_defs[];         // field definitions: {"name:width:offset", ...}

    // ===== User callback (set externally before alloc_rings) =====
    virtqueue_custom_callback custom_cb;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "custom_virtqueue");
        super.new(name);
        custom_cb = null;
    endfunction

    // =================================================================
    // Helper: check callback is set, log error if not
    // =================================================================
    protected function bit check_cb(string method_name);
        if (custom_cb == null) begin
            `uvm_error("CUSTOM_VQ",
                $sformatf("%s: queue_id=%0d custom_cb is null, cannot delegate",
                          method_name, queue_id))
            return 0;
        end
        return 1;
    endfunction

    // =================================================================
    // Lifecycle methods -- delegate to callback
    // =================================================================

    virtual function void alloc_rings();
        if (!check_cb("alloc_rings")) return;
        custom_cb.cb_alloc_rings(this);
    endfunction

    virtual function void free_rings();
        if (!check_cb("free_rings")) return;
        custom_cb.cb_free_rings(this);
    endfunction

    virtual function void reset_queue();
        if (!check_cb("reset_queue")) return;
        custom_cb.cb_reset_queue(this);
    endfunction

    virtual function void detach_all_unused(ref uvm_object tokens[$]);
        if (!check_cb("detach_all_unused")) return;
        custom_cb.cb_detach_all_unused(this, tokens);
    endfunction

    // =================================================================
    // Driver operations -- delegate to callback
    // =================================================================

    virtual function int unsigned add_buf(
        virtio_sg_list  sgs[],
        int unsigned    n_out_sgs,
        int unsigned    n_in_sgs,
        uvm_object      token,
        bit             indirect
    );
        if (!check_cb("add_buf")) return '1;
        return custom_cb.cb_add_buf(this, sgs, n_out_sgs, n_in_sgs, token, indirect);
    endfunction

    virtual task kick();
        if (!check_cb("kick")) return;
        custom_cb.cb_kick(this);
    endtask

    virtual function bit poll_used(
        ref uvm_object      token,
        ref int unsigned     len
    );
        if (!check_cb("poll_used")) return 0;
        return custom_cb.cb_poll_used(this, token, len);
    endfunction

    // =================================================================
    // Notification control -- delegate to callback
    // =================================================================

    virtual function void disable_cb();
        if (!check_cb("disable_cb")) return;
        custom_cb.cb_disable_cb(this);
    endfunction

    virtual function void enable_cb();
        if (!check_cb("enable_cb")) return;
        custom_cb.cb_enable_cb(this);
    endfunction

    virtual function void enable_cb_delayed();
        if (!check_cb("enable_cb_delayed")) return;
        custom_cb.cb_enable_cb_delayed(this);
    endfunction

    virtual function bit vq_poll(int unsigned last_used);
        if (!check_cb("vq_poll")) return 0;
        return custom_cb.cb_vq_poll(this, last_used);
    endfunction

    // =================================================================
    // Query -- delegate to callback
    // =================================================================

    virtual function int unsigned get_free_count();
        if (!check_cb("get_free_count")) return 0;
        return custom_cb.cb_get_free_count(this);
    endfunction

    virtual function int unsigned get_pending_count();
        if (!check_cb("get_pending_count")) return 0;
        return custom_cb.cb_get_pending_count(this);
    endfunction

    virtual function bit needs_notification();
        if (!check_cb("needs_notification")) return 1;
        return custom_cb.cb_needs_notification(this);
    endfunction

    // =================================================================
    // DMA helpers (transport-independent, same as split/packed)
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

        `uvm_info("CUSTOM_VQ",
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
            `uvm_info("CUSTOM_VQ",
                $sformatf("dma_unmap_buf: queue_id=%0d iova=0x%016x", queue_id, iova),
                UVM_HIGH)
        end else begin
            `uvm_error("CUSTOM_VQ",
                $sformatf("dma_unmap_buf: queue_id=%0d iova=0x%016x not found in dma_mappings",
                          queue_id, iova))
        end
    endfunction

    // =================================================================
    // Error injection -- delegate to callback
    // =================================================================

    virtual function void inject_desc_error(virtqueue_error_e err_type);
        if (!check_cb("inject_desc_error")) return;
        custom_cb.cb_inject_desc_error(this, err_type);
    endfunction

    // =================================================================
    // Migration -- delegate to callback
    // =================================================================

    virtual function void save_state(ref virtqueue_snapshot_t snap);
        if (!check_cb("save_state")) return;
        custom_cb.cb_save_state(this, snap);
    endfunction

    virtual function void restore_state(virtqueue_snapshot_t snap);
        if (!check_cb("restore_state")) return;
        custom_cb.cb_restore_state(this, snap);
    endfunction

    // =================================================================
    // Helper methods for callback implementations
    //
    // These allow user callbacks to access descriptor fields generically
    // using the desc_field_defs configuration.
    //
    // desc_field_defs format: {"name:width_bits:offset_bytes", ...}
    //   Example: {"addr:64:0", "len:32:8", "flags:16:12", "next:16:14"}
    // =================================================================

    // ------------------------------------------------------------------
    // write_desc_field -- Write a field value to a descriptor by name
    //
    // Looks up the field in desc_field_defs, computes the byte address,
    // and writes the value in little-endian format via host_mem.
    // ------------------------------------------------------------------
    function void write_desc_field(int unsigned idx, string field_name, bit [63:0] value);
        string name;
        int unsigned width_bits;
        int unsigned offset_bytes;
        int unsigned width_bytes;
        bit [63:0] base;

        if (!find_field_def(field_name, name, width_bits, offset_bytes)) begin
            `uvm_error("CUSTOM_VQ",
                $sformatf("write_desc_field: field '%s' not found in desc_field_defs",
                          field_name))
            return;
        end

        width_bytes = (width_bits + 7) / 8;
        base = desc_table_addr + idx * desc_entry_size + offset_bytes;

        begin
            byte data[];
            data = new[width_bytes];
            for (int unsigned i = 0; i < width_bytes; i++) begin
                data[i] = value[i*8 +: 8];
            end
            mem.write_mem(base, data);
        end
    endfunction

    // ------------------------------------------------------------------
    // read_desc_field -- Read a field value from a descriptor by name
    //
    // Looks up the field in desc_field_defs, reads bytes from host_mem,
    // and returns the value reconstructed from little-endian bytes.
    // ------------------------------------------------------------------
    function bit [63:0] read_desc_field(int unsigned idx, string field_name);
        string name;
        int unsigned width_bits;
        int unsigned offset_bytes;
        int unsigned width_bytes;
        bit [63:0] base;
        bit [63:0] result = 0;

        if (!find_field_def(field_name, name, width_bits, offset_bytes)) begin
            `uvm_error("CUSTOM_VQ",
                $sformatf("read_desc_field: field '%s' not found in desc_field_defs",
                          field_name))
            return 0;
        end

        width_bytes = (width_bits + 7) / 8;
        base = desc_table_addr + idx * desc_entry_size + offset_bytes;

        begin
            byte data[];
            mem.read_mem(base, width_bytes, data);
            for (int unsigned i = 0; i < width_bytes; i++) begin
                result[i*8 +: 8] = data[i];
            end
        end

        return result;
    endfunction

    // ------------------------------------------------------------------
    // find_field_def -- Parse desc_field_defs to find a named field
    //
    // Returns 1 if found, 0 if not. On success, populates name,
    // width_bits, and offset_bytes from the "name:width:offset" string.
    // ------------------------------------------------------------------
    protected function bit find_field_def(string field_name,
                                          ref string name,
                                          ref int unsigned width_bits,
                                          ref int unsigned offset_bytes);
        foreach (desc_field_defs[i]) begin
            string def_str = desc_field_defs[i];
            int unsigned colon1 = 0;
            int unsigned colon2 = 0;
            string s_name, s_width, s_offset;

            // Find first colon
            for (int unsigned c = 0; c < def_str.len(); c++) begin
                if (def_str[c] == ":") begin
                    colon1 = c;
                    break;
                end
            end

            // Find second colon
            for (int unsigned c = colon1 + 1; c < def_str.len(); c++) begin
                if (def_str[c] == ":") begin
                    colon2 = c;
                    break;
                end
            end

            if (colon1 == 0 || colon2 == 0) continue;

            s_name   = def_str.substr(0, colon1 - 1);
            s_width  = def_str.substr(colon1 + 1, colon2 - 1);
            s_offset = def_str.substr(colon2 + 1, def_str.len() - 1);

            if (s_name == field_name) begin
                name         = s_name;
                width_bits   = s_width.atoi();
                offset_bytes = s_offset.atoi();
                return 1;
            end
        end

        return 0;
    endfunction

endclass : custom_virtqueue

`endif // CUSTOM_VIRTQUEUE_SV
