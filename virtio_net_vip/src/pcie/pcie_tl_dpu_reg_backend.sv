`ifndef PCIE_TL_DPU_REG_BACKEND_SV
`define PCIE_TL_DPU_REG_BACKEND_SV

// PCIe-TL implementation of the dpu-common register backend.  It translates
// a generic operation into the existing RC config/MMIO sequences, waits for a
// real Completion on reads/writes, and leaves root selection injectable for
// multi-host/multi-segment environments.
class pcie_tl_dpu_reg_backend extends dpu_pcie_reg_backend;
    `uvm_object_utils(pcie_tl_dpu_reg_backend)

    pcie_tl_virtual_sequencer virtual_sequencer;
    // Register plans carry BAR-relative offsets.  The frozen device snapshot
    // is the authoritative BDF -> BAR lease mapping used to turn those
    // offsets into PCIe memory addresses at execution time.
    dpu_device_snapshot device_snapshot;
    int unsigned default_root_index;
    int unsigned root_by_host[int unsigned];
    // A Host can expose more than one independent PCIe segment/root.  Keep
    // the legacy host-only map as a fallback, but prefer an exact domain map
    // whenever a caller has bound one.
    int unsigned root_by_domain[longint unsigned];
    int unsigned completion_poll_limit;

    function new(string name = "pcie_tl_dpu_reg_backend");
        super.new(name);
        virtual_sequencer = null;
        device_snapshot = null;
        default_root_index = 0;
        completion_poll_limit = 50000;
    endfunction

    function void bind_virtual_sequencer(
        input pcie_tl_virtual_sequencer sequencer
    );
        virtual_sequencer = sequencer;
    endfunction

    virtual function void bind_topology(input uvm_object topology);
        dpu_device_snapshot snapshot;

        if (!$cast(snapshot, topology)) begin
            device_snapshot = null;
            return;
        end
        device_snapshot = snapshot;
    endfunction

    function void bind_device_snapshot(
        input dpu_device_snapshot snapshot
    );
        bind_topology(snapshot);
    endfunction

    protected function bit resolve_mmio_address(
        input dpu_reg_op operation,
        output bit [63:0] absolute_address,
        output string why
    );
        dpu_pcie_function_id_t pcie_id;
        dpu_function_key_t function_key;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t selected_bar;
        bit found;

        absolute_address = '0;
        why = "";
        if (device_snapshot == null) begin
            why = $sformatf(
                "PCIe backend has no device snapshot for MMIO operation %s",
                operation.op_id);
            return 0;
        end
        if (!device_snapshot.is_frozen()) begin
            why = "PCIe backend requires a frozen device snapshot";
            return 0;
        end
        pcie_id.domain.host_id = operation.host_id;
        pcie_id.domain.segment_id = operation.segment_id;
        pcie_id.bdf = operation.bdf;
        if (!device_snapshot.find_function(pcie_id, function_key, why))
            return 0;
        if (!device_snapshot.list_bars(function_key, bars, why))
            return 0;
        found = 0;
        foreach (bars[index]) begin
            if (bars[index].even_bar_id == operation.bar_id) begin
                selected_bar = bars[index];
                found = 1;
                break;
            end
        end
        if (!found) begin
            why = $sformatf(
                "PCIe backend cannot resolve BAR%0d for %s",
                operation.bar_id, operation.op_id);
            return 0;
        end
        if (operation.address > selected_bar.size ||
            operation.width_bytes > (selected_bar.size - operation.address)) begin
            why = $sformatf(
                "operation %s offset 0x%016x width %0d exceeds BAR%0d size 0x%016x",
                operation.op_id, operation.address, operation.width_bytes,
                operation.bar_id, selected_bar.size);
            return 0;
        end
        if (selected_bar.base >
            (64'hffff_ffff_ffff_ffff - operation.address)) begin
            why = $sformatf(
                "operation %s BAR%0d address overflows 64-bit PCIe space",
                operation.op_id, operation.bar_id);
            return 0;
        end
        absolute_address = selected_bar.base + operation.address;
        return 1;
    endfunction

    function void bind_host_root(input int unsigned host_id,
                                 input int unsigned root_index);
        root_by_host[host_id] = root_index;
    endfunction

    protected function longint unsigned domain_map_key(
        input int unsigned host_id,
        input int unsigned segment_id
    );
        return (longint'(host_id) << 32) | longint'(segment_id);
    endfunction

    function void bind_domain_root(input int unsigned host_id,
                                   input int unsigned segment_id,
                                   input int unsigned root_index);
        root_by_domain[domain_map_key(host_id, segment_id)] = root_index;
    endfunction

    protected function bit get_root_sequencer(
        input int unsigned host_id,
        input int unsigned segment_id,
        output uvm_sequencer #(pcie_tl_tlp) sequencer,
        output string why
    );
        int unsigned root_index;

        sequencer = null;
        why = "";
        if (virtual_sequencer == null) begin
            why = "PCIe-TL backend has no virtual sequencer";
            return 0;
        end
        root_index = default_root_index;
        if (root_by_domain.exists(domain_map_key(host_id, segment_id)))
            root_index = root_by_domain[domain_map_key(host_id, segment_id)];
        else if (root_by_host.exists(host_id))
            root_index = root_by_host[host_id];
        if (virtual_sequencer.rc_seqr_arr.size() != 0) begin
            if (root_index >= virtual_sequencer.rc_seqr_arr.size()) begin
                why = $sformatf(
                    "Host %0d maps to unavailable PCIe RC root %0d",
                    host_id, root_index);
                return 0;
            end
            sequencer = virtual_sequencer.rc_seqr_arr[root_index];
        end else begin
            sequencer = virtual_sequencer.rc_seqr;
        end
        if (sequencer == null) begin
            why = $sformatf("PCIe RC root %0d sequencer is null", root_index);
            return 0;
        end
        return 1;
    endfunction

    protected function bit [3:0] byte_enable_at_address(
        input bit [63:0] address,
        input int unsigned width_bytes
    );
        bit [3:0] enable;
        int unsigned lane;

        enable = '0;
        lane = address[1:0];
        for (int unsigned index = 0; index < 4; index++) begin
            if ((index >= lane) && ((index - lane) < width_bytes))
                enable[index] = 1'b1;
        end
        return enable;
    endfunction

    // Derive the DWORD-aligned PCIe request shape from a byte-granular
    // operation.  BAR-relative offsets are validated by dpu_reg_op, while
    // the actual TLP must use the absolute BAR address (important when a
    // randomized BAR is not page-aligned).
    protected function void calc_mem_transfer(
        input bit [63:0] absolute_address,
        input int unsigned width_bytes,
        output bit [63:0] aligned_address,
        output int unsigned length_dw,
        output bit [3:0] first_be,
        output bit [3:0] last_be
    );
        int unsigned lane;
        int unsigned total_bytes;

        lane = absolute_address[1:0];
        total_bytes = lane + width_bytes;
        length_dw = (total_bytes + 3) / 4;
        aligned_address = {absolute_address[63:2], 2'b00};
        first_be = byte_enable_at_address(absolute_address, width_bytes);
        last_be = '0;
        if (length_dw > 1) begin
            for (int unsigned index = 0; index < 4; index++) begin
                int signed source_index;
                source_index = ((length_dw - 1) * 4) + index - lane;
                if ((source_index >= 0) &&
                    (source_index < int'(width_bytes)))
                    last_be[index] = 1'b1;
            end
        end
    endfunction

    protected function bit [31:0] config_payload(input dpu_reg_op operation);
        bit [31:0] value;
        value = operation.payload[31:0];
        value = value << (8 * operation.address[1:0]);
        return value;
    endfunction

    protected function bit [63:0] payload_value(
        input bit [7:0] bytes[],
        input int unsigned width,
        input int unsigned start_lane
    );
        bit [63:0] value;
        value = '0;
        for (int unsigned index = 0;
             index < width && (start_lane + index) < bytes.size() && index < 8;
             index++)
            value[index * 8 +: 8] = bytes[start_lane + index];
        return value;
    endfunction

    protected task wait_for_completion(
        input pcie_tl_tlp issued_tlp,
        output bit ok,
        output string why
    );
        ok = 0;
        why = "";
        if (issued_tlp == null) begin
            why = "PCIe sequence did not publish its issued TLP";
            return;
        end
        for (int unsigned poll = 0; poll < completion_poll_limit; poll++) begin
            if (issued_tlp.rb_done) begin
                if (issued_tlp.rb_status != CPL_STATUS_SC) begin
                    why = $sformatf(
                        "PCIe Completion returned status %s",
                        issued_tlp.rb_status.name());
                    return;
                end
                ok = 1;
                return;
            end
            #1ns;
        end
        why = $sformatf(
            "PCIe Completion timeout after %0d polls",
            completion_poll_limit);
    endtask

    virtual task write(input dpu_reg_op operation,
                       output bit ok, output string why);
        uvm_sequencer #(pcie_tl_tlp) sequencer;

        ok = 0;
        why = "";
        if (!get_root_sequencer(operation.host_id, operation.segment_id,
                                sequencer, why))
            return;
        if (operation.kind == DPU_REG_OP_PCI_CFG_WRITE) begin
            pcie_tl_cfg_wr_seq seq_obj;
            if ((operation.address[11:0] + operation.width_bytes) > 4096) begin
                why = $sformatf(
                    "PCIe register write %s crosses a 4KB TLP boundary",
                    operation.op_id);
                return;
            end
            seq_obj = pcie_tl_cfg_wr_seq::type_id::create(
                {operation.op_id, ".cfg_wr"});
            seq_obj.target_bdf = operation.bdf;
            seq_obj.reg_num = operation.address[11:2];
            seq_obj.first_be = byte_enable_at_address(
                operation.address, operation.width_bytes);
            seq_obj.wr_data = config_payload(operation);
            seq_obj.is_type1 = 0;
            seq_obj.mode = CONSTRAINT_LEGAL;
            seq_obj.start(sequencer);
            wait_for_completion(seq_obj.issued_tlp, ok, why);
            return;
        end

        if (!(operation.kind inside {
                DPU_REG_OP_MMIO_WRITE, DPU_REG_OP_COMMIT
            })) begin
            why = $sformatf("PCIe backend cannot write operation kind for %s",
                            operation.op_id);
            return;
        end
        begin
            pcie_tl_mem_wr_seq seq_obj;
            int unsigned length_dw;
            bit [7:0] data[];
            bit [63:0] absolute_address;
            bit [63:0] aligned_address;
            bit [3:0] first_be;
            bit [3:0] last_be;

            if (!resolve_mmio_address(operation, absolute_address, why))
                return;

            calc_mem_transfer(absolute_address, operation.width_bytes,
                              aligned_address, length_dw, first_be, last_be);
            if ((aligned_address[11:0] + (length_dw * 4)) > 4096) begin
                why = $sformatf(
                    "PCIe register write %s crosses a 4KB TLP boundary",
                    operation.op_id);
                return;
            end
            seq_obj = pcie_tl_mem_wr_seq::type_id::create(
                {operation.op_id, ".mmio_wr"});
            seq_obj.addr = aligned_address;
            seq_obj.length = length_dw;
            seq_obj.first_be = first_be;
            seq_obj.last_be = last_be;
            seq_obj.is_64bit = (absolute_address[63:32] != 0);
            seq_obj.mode = CONSTRAINT_LEGAL;
            data = new[length_dw * 4];
            foreach (data[index]) begin
                data[index] = 8'h00;
                if ((index >= absolute_address[1:0]) &&
                    ((index - absolute_address[1:0]) < operation.width_bytes))
                    data[index] = operation.payload[
                        (index - absolute_address[1:0]) * 8 +: 8];
            end
            seq_obj.write_data = data;
            seq_obj.start(sequencer);
            // Memory writes are posted PCIe transactions and therefore do
            // not carry a Completion.  finish_item() means the TLP has been
            // accepted by the RC sequencer; delivery ordering is established
            // by a subsequent readback or an explicit barrier operation.
            ok = (seq_obj.issued_tlp != null);
            if (!ok)
                why = "PCIe memory write sequence did not publish its TLP";
        end
    endtask

    virtual task read(input dpu_reg_op operation,
                      output bit [63:0] value,
                      output bit ok, output string why);
        uvm_sequencer #(pcie_tl_tlp) sequencer;

        value = '0;
        ok = 0;
        why = "";
        if (!get_root_sequencer(operation.host_id, operation.segment_id,
                                sequencer, why))
            return;
        if (operation.target_space == DPU_REG_TARGET_PCI_CONFIG) begin
            pcie_tl_cfg_rd_seq seq_obj;
            if ((operation.address[11:0] + operation.width_bytes) > 4096) begin
                why = $sformatf(
                    "PCIe register read %s crosses a 4KB TLP boundary",
                    operation.op_id);
                return;
            end
            seq_obj = pcie_tl_cfg_rd_seq::type_id::create(
                {operation.op_id, ".cfg_rd"});
            seq_obj.target_bdf = operation.bdf;
            seq_obj.completer_id = operation.bdf;
            seq_obj.reg_num = operation.address[11:2];
            seq_obj.first_be = byte_enable_at_address(
                operation.address, operation.width_bytes);
            seq_obj.is_type1 = 0;
            seq_obj.mode = CONSTRAINT_LEGAL;
            seq_obj.start(sequencer);
            wait_for_completion(seq_obj.issued_tlp, ok, why);
            if (ok)
                value = payload_value(seq_obj.issued_tlp.rb_data,
                                      operation.width_bytes,
                                      operation.address[1:0]);
            return;
        end
        begin
            pcie_tl_mem_rd_seq seq_obj;
            int unsigned length_dw;
            bit [63:0] absolute_address;
            bit [63:0] aligned_address;
            bit [3:0] first_be;
            bit [3:0] last_be;

            if (!resolve_mmio_address(operation, absolute_address, why))
                return;

            calc_mem_transfer(absolute_address, operation.width_bytes,
                              aligned_address, length_dw, first_be, last_be);
            if ((aligned_address[11:0] + (length_dw * 4)) > 4096) begin
                why = $sformatf(
                    "PCIe register read %s crosses a 4KB TLP boundary",
                    operation.op_id);
                return;
            end
            seq_obj = pcie_tl_mem_rd_seq::type_id::create(
                {operation.op_id, ".mmio_rd"});
            seq_obj.addr = aligned_address;
            seq_obj.length = length_dw;
            seq_obj.first_be = first_be;
            seq_obj.last_be = last_be;
            seq_obj.is_64bit = (absolute_address[63:32] != 0);
            seq_obj.mode = CONSTRAINT_LEGAL;
            seq_obj.start(sequencer);
            wait_for_completion(seq_obj.issued_tlp, ok, why);
            if (ok)
                value = payload_value(seq_obj.issued_tlp.rb_data,
                                      operation.width_bytes,
                                      absolute_address[1:0]);
        end
    endtask

    virtual task barrier(input dpu_reg_op operation,
                         output bit ok, output string why);
        ok = 1;
        why = "";
    endtask
endclass : pcie_tl_dpu_reg_backend

// The concrete executor is named separately so callers can inject a backend
// and still use the generic executor contract.  This alias keeps construction
// concise in user tests without coupling dpu-common to PCIe-TL types.
class pcie_tl_dpu_reg_executor extends dpu_pcie_reg_executor;
    `uvm_object_utils(pcie_tl_dpu_reg_executor)

    function new(string name = "pcie_tl_dpu_reg_executor");
        super.new(name);
    endfunction
endclass : pcie_tl_dpu_reg_executor

`endif // PCIE_TL_DPU_REG_BACKEND_SV
