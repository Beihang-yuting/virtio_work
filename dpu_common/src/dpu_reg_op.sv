`ifndef DPU_REG_OP_SV
`define DPU_REG_OP_SV

class dpu_reg_op extends uvm_object;
    `uvm_object_utils(dpu_reg_op)

    string op_id;
    string dependencies[$];
    string owner;
    dpu_reg_op_kind_e kind;
    dpu_reg_target_space_e target_space;
    dpu_reg_target_scope_e target_scope;
    dpu_reg_phase_e phase;
    int unsigned host_id;
    int unsigned segment_id;
    bit bdf_valid;
    bit [15:0] bdf;
    int unsigned bar_id;
    string target_block;
    bit [63:0] address;
    int unsigned width_bytes;
    bit [63:0] payload;
    bit [63:0] write_mask;
    bit [63:0] expected_value;
    bit [63:0] read_mask;
    int unsigned max_attempts;
    time retry_interval;
    string commit_group;

    function new(string name = "dpu_reg_op");
        super.new(name);
        op_id = "";
        dependencies.delete();
        owner = "";
        kind = DPU_REG_OP_INVALID;
        target_space = DPU_REG_TARGET_INVALID;
        target_scope = DPU_REG_SCOPE_INVALID;
        phase = DPU_REG_PHASE_INVALID;
        host_id = 0;
        segment_id = 0;
        bdf_valid = 0;
        bdf = '0;
        bar_id = 0;
        target_block = "";
        address = '0;
        width_bytes = 0;
        payload = '0;
        write_mask = '0;
        expected_value = '0;
        read_mask = '0;
        max_attempts = 0;
        retry_interval = 0;
        commit_group = "";
    endfunction

    function void add_dependency(input string dependency_id);
        dependencies.push_back(dependency_id);
    endfunction

    protected function void copy_fields_from(input dpu_reg_op rhs);
        op_id = rhs.op_id;
        dependencies = rhs.dependencies;
        owner = rhs.owner;
        kind = rhs.kind;
        target_space = rhs.target_space;
        target_scope = rhs.target_scope;
        phase = rhs.phase;
        host_id = rhs.host_id;
        segment_id = rhs.segment_id;
        bdf_valid = rhs.bdf_valid;
        bdf = rhs.bdf;
        bar_id = rhs.bar_id;
        target_block = rhs.target_block;
        address = rhs.address;
        width_bytes = rhs.width_bytes;
        payload = rhs.payload;
        write_mask = rhs.write_mask;
        expected_value = rhs.expected_value;
        read_mask = rhs.read_mask;
        max_attempts = rhs.max_attempts;
        retry_interval = rhs.retry_interval;
        commit_group = rhs.commit_group;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_reg_op typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("REG_OP_COPY",
                "dpu_reg_op::do_copy received an incompatible object")
            return;
        end
        copy_fields_from(typed_rhs);
    endfunction

    function void copy_from(input dpu_reg_op rhs);
        if (rhs == null) begin
            `uvm_error("REG_OP_COPY", "dpu_reg_op::copy_from received null")
            return;
        end
        copy(rhs);
    endfunction

    function dpu_reg_op copy_op(input string copy_name = "dpu_reg_op_copy");
        uvm_object cloned_object;
        dpu_reg_op copied;

        cloned_object = clone();
        if (!$cast(copied, cloned_object)) begin
            `uvm_error("REG_OP_COPY",
                "dpu_reg_op::copy_op clone returned an incompatible object")
            return null;
        end
        copied.set_name(copy_name);
        return copied;
    endfunction

    protected function bit [63:0] access_mask();
        case (width_bytes)
            1: return 64'h0000_0000_0000_00ff;
            2: return 64'h0000_0000_0000_ffff;
            4: return 64'h0000_0000_ffff_ffff;
            8: return 64'hffff_ffff_ffff_ffff;
            default: return '0;
        endcase
    endfunction

    protected function bit is_mmio_target();
        return (target_space == DPU_REG_TARGET_AF_BAR0) ||
               (target_space == DPU_REG_TARGET_FUNCTION_BAR);
    endfunction

    protected function bit is_canonical_barrier();
        return (target_space == DPU_REG_TARGET_NONE) &&
               (target_block == "") &&
               !bdf_valid && (bdf == '0) &&
               (bar_id == 0) && (address == '0) &&
               (width_bytes == 0) && (payload == '0) &&
               (write_mask == '0) && (expected_value == '0) &&
               (read_mask == '0) && (max_attempts == 0) &&
               (retry_interval === 0) && (commit_group == "");
    endfunction

    protected function bit validate_write_values(
        input bit [63:0] valid_mask,
        output string why
    );
        if (write_mask == '0) begin
            why = $sformatf("operation %s write mask must not be zero", op_id);
            return 0;
        end
        if ((write_mask & ~valid_mask) != '0) begin
            why = $sformatf(
                "operation %s write mask exceeds its access width", op_id);
            return 0;
        end
        if ((payload & ~valid_mask) != '0) begin
            why = $sformatf(
                "operation %s payload exceeds its access width", op_id);
            return 0;
        end
        return 1;
    endfunction

    protected function bit validate_read_values(
        input bit [63:0] valid_mask,
        output string why
    );
        if (read_mask == '0) begin
            why = $sformatf("operation %s read mask must not be zero", op_id);
            return 0;
        end
        if ((expected_value & ~valid_mask) != '0) begin
            why = $sformatf(
                "operation %s expected value exceeds its access width", op_id);
            return 0;
        end
        if ((read_mask & ~valid_mask) != '0) begin
            why = $sformatf(
                "operation %s read mask exceeds its access width", op_id);
            return 0;
        end
        return 1;
    endfunction

    function bit validate(output string why);
        bit [63:0] valid_mask;

        why = "";
        if (op_id == "") begin
            why = "register operation ID must not be empty";
            return 0;
        end
        if (owner == "") begin
            why = $sformatf("operation %s owner must not be empty", op_id);
            return 0;
        end
        if (!(kind inside {
            DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_OP_MMIO_WRITE,
            DPU_REG_OP_READ_VERIFY, DPU_REG_OP_POLL_UNTIL,
            DPU_REG_OP_COMMIT, DPU_REG_OP_BARRIER
        })) begin
            why = $sformatf("operation %s has unsupported operation kind", op_id);
            return 0;
        end
        if (!(phase inside {
            DPU_REG_PHASE_BOOTSTRAP, DPU_REG_PHASE_TABLE,
            DPU_REG_PHASE_COMMIT, DPU_REG_PHASE_ENABLE
        })) begin
            why = $sformatf("operation %s has invalid lifecycle phase", op_id);
            return 0;
        end
        if (!(target_scope inside {
            DPU_REG_SCOPE_SINGLE, DPU_REG_SCOPE_PER_HOST,
            DPU_REG_SCOPE_PER_FUNCTION, DPU_REG_SCOPE_PER_SERVICE
        })) begin
            why = $sformatf("operation %s has invalid target scope", op_id);
            return 0;
        end
        if ((phase == DPU_REG_PHASE_ENABLE) &&
            (dependencies.size() == 0)) begin
            why = $sformatf(
                "operation %s enable phase requires a dependency", op_id);
            return 0;
        end

        if (kind == DPU_REG_OP_BARRIER) begin
            if (!is_canonical_barrier()) begin
                why = $sformatf("operation %s barrier must be canonical", op_id);
                return 0;
            end
            return 1;
        end

        if (!(target_space inside {
            DPU_REG_TARGET_PCI_CONFIG,
            DPU_REG_TARGET_AF_BAR0,
            DPU_REG_TARGET_FUNCTION_BAR
        })) begin
            why = $sformatf("operation %s has unsupported target space", op_id);
            return 0;
        end
        if (target_block == "") begin
            why = $sformatf("operation %s target block must not be empty", op_id);
            return 0;
        end
        if (!bdf_valid) begin
            why = $sformatf("operation %s target BDF is unresolved", op_id);
            return 0;
        end
        if ((kind == DPU_REG_OP_PCI_CFG_WRITE) &&
            (target_space != DPU_REG_TARGET_PCI_CONFIG)) begin
            why = $sformatf(
                "operation %s PCI config write requires PCI config target", op_id);
            return 0;
        end
        if ((kind inside {DPU_REG_OP_MMIO_WRITE, DPU_REG_OP_COMMIT}) &&
            !is_mmio_target()) begin
            why = $sformatf(
                "operation %s MMIO write/commit requires an MMIO target", op_id);
            return 0;
        end
        if ((target_space == DPU_REG_TARGET_PCI_CONFIG) &&
            !(width_bytes inside {1, 2, 4})) begin
            why = $sformatf(
                "operation %s has unsupported PCI config access width %0d",
                op_id, width_bytes);
            return 0;
        end
        if (is_mmio_target() && !(width_bytes inside {1, 2, 4, 8})) begin
            why = $sformatf(
                "operation %s has unsupported MMIO access width %0d",
                op_id, width_bytes);
            return 0;
        end
        if ((width_bytes == 0) || ((address % width_bytes) != 0)) begin
            why = $sformatf("operation %s address is not width-aligned", op_id);
            return 0;
        end
        if ((target_space == DPU_REG_TARGET_PCI_CONFIG) &&
            (address > (64'd4096 - width_bytes))) begin
            why = $sformatf(
                "operation %s PCI config access exceeds 4KB space", op_id);
            return 0;
        end
        if ((target_space == DPU_REG_TARGET_AF_BAR0) && (bar_id != 0)) begin
            why = $sformatf("operation %s AF BAR target must use BAR0", op_id);
            return 0;
        end
        if ((target_space == DPU_REG_TARGET_FUNCTION_BAR) && (bar_id > 5)) begin
            why = $sformatf("operation %s function BAR ID is out of range", op_id);
            return 0;
        end

        valid_mask = access_mask();
        case (kind)
            DPU_REG_OP_PCI_CFG_WRITE,
            DPU_REG_OP_MMIO_WRITE,
            DPU_REG_OP_COMMIT: begin
                if (!validate_write_values(valid_mask, why))
                    return 0;
                if ((expected_value != '0) || (read_mask != '0) ||
                    (max_attempts != 0) || (retry_interval !== 0)) begin
                    why = $sformatf(
                        "operation %s write has read/poll fields set", op_id);
                    return 0;
                end
                if ((kind == DPU_REG_OP_COMMIT) &&
                    (phase != DPU_REG_PHASE_COMMIT)) begin
                    why = $sformatf(
                        "operation %s commit must use the commit phase", op_id);
                    return 0;
                end
            end

            DPU_REG_OP_READ_VERIFY: begin
                if (!validate_read_values(valid_mask, why))
                    return 0;
                if ((payload != '0) || (write_mask != '0)) begin
                    why = $sformatf(
                        "operation %s read has write fields set", op_id);
                    return 0;
                end
                if ((max_attempts != 0) || (retry_interval !== 0)) begin
                    why = $sformatf(
                        "operation %s read-verify has poll fields set", op_id);
                    return 0;
                end
            end

            DPU_REG_OP_POLL_UNTIL: begin
                if (!validate_read_values(valid_mask, why))
                    return 0;
                if ((payload != '0) || (write_mask != '0)) begin
                    why = $sformatf(
                        "operation %s poll has write fields set", op_id);
                    return 0;
                end
                if (max_attempts == 0) begin
                    why = $sformatf(
                        "operation %s poll attempt count must be nonzero", op_id);
                    return 0;
                end
                if ($isunknown(retry_interval)) begin
                    why = $sformatf(
                        "operation %s retry interval must be known", op_id);
                    return 0;
                end
            end

            default: begin
                why = $sformatf(
                    "operation %s has unsupported operation kind", op_id);
                return 0;
            end
        endcase
        return 1;
    endfunction
endclass : dpu_reg_op

`endif // DPU_REG_OP_SV
