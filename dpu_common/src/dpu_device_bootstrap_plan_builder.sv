`ifndef DPU_DEVICE_BOOTSTRAP_PLAN_BUILDER_SV
`define DPU_DEVICE_BOOTSTRAP_PLAN_BUILDER_SV

class dpu_device_bootstrap_plan_builder extends uvm_object;
    `uvm_object_utils(dpu_device_bootstrap_plan_builder)

    function new(string name = "dpu_device_bootstrap_plan_builder");
        super.new(name);
    endfunction

    local function dpu_reg_op make_target_op(
        input string op_id,
        input dpu_reg_op_kind_e kind,
        input dpu_reg_target_space_e target_space,
        input dpu_pcie_function_id_t pcie_id,
        input int unsigned bar_id,
        input string target_block,
        input bit [63:0] address
    );
        dpu_reg_op op;

        op = dpu_reg_op::type_id::create(op_id);
        op.op_id = op_id;
        op.owner = "dpu.bootstrap";
        op.kind = kind;
        op.target_space = target_space;
        op.target_scope = DPU_REG_SCOPE_SINGLE;
        op.phase = DPU_REG_PHASE_BOOTSTRAP;
        op.host_id = pcie_id.domain.host_id;
        op.segment_id = pcie_id.domain.segment_id;
        op.bdf_valid = 1;
        op.bdf = pcie_id.bdf;
        op.bar_id = bar_id;
        op.target_block = target_block;
        op.address = address;
        op.width_bytes = 4;
        return op;
    endfunction

    local function bit add_bar_pair(
        input dpu_reg_plan candidate,
        input dpu_pcie_function_id_t pcie_id,
        input dpu_bar_pair_lease_t bar,
        ref string previous_id,
        output string why
    );
        dpu_reg_op op;
        string low_id;
        string high_id;

        low_id = $sformatf("pci.h%0d.s%0d.b%04h.bar%0d.low",
            pcie_id.domain.host_id, pcie_id.domain.segment_id,
            pcie_id.bdf, bar.even_bar_id);
        op = make_target_op(
            low_id, DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_TARGET_PCI_CONFIG,
            pcie_id, bar.even_bar_id, "pci_config",
            64'h10 + (bar.even_bar_id * 4));
        op.payload = {bar.base[31:4], 4'b0100};
        op.write_mask = 64'h0000_0000_ffff_ffff;
        if (previous_id != "")
            op.add_dependency(previous_id);
        if (!candidate.add_operation(op, why))
            return 0;

        high_id = $sformatf("pci.h%0d.s%0d.b%04h.bar%0d.high",
            pcie_id.domain.host_id, pcie_id.domain.segment_id,
            pcie_id.bdf, bar.even_bar_id);
        op = make_target_op(
            high_id, DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_TARGET_PCI_CONFIG,
            pcie_id, bar.even_bar_id, "pci_config",
            64'h14 + (bar.even_bar_id * 4));
        op.payload = bar.base[63:32];
        op.write_mask = 64'h0000_0000_ffff_ffff;
        op.add_dependency(low_id);
        if (!candidate.add_operation(op, why))
            return 0;
        previous_id = high_id;
        return 1;
    endfunction

    local function bit add_af_sequence(
        input dpu_reg_plan candidate,
        input dpu_function_key_t af_key,
        input dpu_pcie_function_id_t af_pcie_id,
        input dpu_bar_pair_lease_t af_bar0,
        input string bars_complete_id,
        output string why
    );
        dpu_reg_op op;
        bit [63:0] selected_host_value;

        if ((af_key.kind != DPU_FUNCTION_PF) || (af_key.pf_id != 0) ||
            (af_key.vf_id != 0) ||
            (af_pcie_id.domain.host_id != af_key.host_id)) begin
            why = "snapshot AF selection is not a domain-qualified PF0";
            return 0;
        end
        if ((af_bar0.role != DPU_BAR_DEVICE_MEMORY) ||
            (af_bar0.even_bar_id != 0)) begin
            why = "snapshot AF selection has no device-memory BAR0 lease";
            return 0;
        end
        if (bars_complete_id == "") begin
            why = "snapshot AF BAR0 was not programmed by the bootstrap plan";
            return 0;
        end
        selected_host_value = 64'h8 | af_key.host_id;

        op = make_target_op(
            "af.valid.pre_read", DPU_REG_OP_READ_VERIFY,
            DPU_REG_TARGET_AF_BAR0, af_pcie_id, 0, "af_bar0", 64'h1010);
        op.expected_value = 64'h0;
        op.read_mask = 64'h8;
        op.add_dependency(bars_complete_id);
        if (!candidate.add_operation(op, why))
            return 0;

        op = make_target_op(
            "af.declare.write", DPU_REG_OP_MMIO_WRITE,
            DPU_REG_TARGET_AF_BAR0, af_pcie_id, 0, "af_bar0", 64'h1010);
        op.payload = 64'h5555_aaaa;
        op.write_mask = 64'h0000_0000_ffff_ffff;
        op.add_dependency("af.valid.pre_read");
        if (!candidate.add_operation(op, why))
            return 0;

        op = make_target_op(
            "af.winner.read", DPU_REG_OP_READ_VERIFY,
            DPU_REG_TARGET_AF_BAR0, af_pcie_id, 0, "af_bar0", 64'h1010);
        op.expected_value = selected_host_value;
        op.read_mask = 64'hf;
        op.add_dependency("af.declare.write");
        if (!candidate.add_operation(op, why))
            return 0;

        op = make_target_op(
            "af.host_id.write", DPU_REG_OP_MMIO_WRITE,
            DPU_REG_TARGET_AF_BAR0, af_pcie_id, 0, "af_bar0", 64'h60040);
        op.payload = selected_host_value;
        op.write_mask = 64'h0000_0000_ffff_ffff;
        op.add_dependency("af.winner.read");
        if (!candidate.add_operation(op, why))
            return 0;

        op = make_target_op(
            "af.host_id.readback", DPU_REG_OP_READ_VERIFY,
            DPU_REG_TARGET_AF_BAR0, af_pcie_id, 0, "af_bar0", 64'h60040);
        op.expected_value = selected_host_value;
        op.read_mask = 64'hf;
        op.add_dependency("af.host_id.write");
        if (!candidate.add_operation(op, why))
            return 0;

        op = dpu_reg_op::type_id::create("bootstrap.final_barrier");
        op.op_id = "bootstrap.final_barrier";
        op.owner = "dpu.bootstrap";
        op.kind = DPU_REG_OP_BARRIER;
        op.target_space = DPU_REG_TARGET_NONE;
        op.target_scope = DPU_REG_SCOPE_SINGLE;
        op.phase = DPU_REG_PHASE_BOOTSTRAP;
        op.host_id = af_pcie_id.domain.host_id;
        op.segment_id = af_pcie_id.domain.segment_id;
        op.add_dependency("af.host_id.readback");
        if (!candidate.add_operation(op, why))
            return 0;
        return 1;
    endfunction

    function bit build(
        input dpu_device_snapshot snapshot,
        output dpu_reg_plan plan,
        output string why
    );
        dpu_reg_plan candidate;
        dpu_function_key_t functions[$];
        dpu_function_key_t af_key;
        dpu_pcie_function_id_t pcie_id;
        dpu_pcie_function_id_t af_pcie_id;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t af_bar0;
        string previous_id;

        plan = null;
        why = "";
        if (snapshot == null) begin
            why = "bootstrap plan builder received a null snapshot";
            return 0;
        end
        if (!snapshot.is_frozen()) begin
            why = "bootstrap plan builder requires a frozen snapshot";
            return 0;
        end
        if (!snapshot.get_expected_af(af_key, af_bar0, why) ||
            !snapshot.get_pcie_id(af_key, af_pcie_id, why))
            return 0;

        candidate = dpu_reg_plan::type_id::create("dpu_bootstrap_plan");
        previous_id = "";
        snapshot.list_functions(functions);
        foreach (functions[function_index]) begin
            if (!snapshot.get_pcie_id(
                    functions[function_index], pcie_id, why) ||
                !snapshot.list_bars(
                    functions[function_index], bars, why)) begin
                return 0;
            end
            foreach (bars[bar_index]) begin
                if (!add_bar_pair(
                        candidate, pcie_id, bars[bar_index],
                        previous_id, why)) begin
                    return 0;
                end
            end
        end
        if (!add_af_sequence(
                candidate, af_key, af_pcie_id, af_bar0,
                previous_id, why)) begin
            return 0;
        end
        plan = candidate;
        return 1;
    endfunction
endclass : dpu_device_bootstrap_plan_builder

`endif // DPU_DEVICE_BOOTSTRAP_PLAN_BUILDER_SV
