`ifndef DPU_REG_PLAN_TEST_SV
`define DPU_REG_PLAN_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_reg_plan_test extends uvm_test;
    `uvm_component_utils(dpu_reg_plan_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_reg_op make_mmio_write(
        input string op_id,
        input dpu_reg_phase_e phase,
        input bit [63:0] address,
        input bit [63:0] payload
    );
        dpu_reg_op op;
        op = dpu_reg_op::type_id::create(op_id);
        op.op_id = op_id;
        op.owner = "test.module";
        op.kind = DPU_REG_OP_MMIO_WRITE;
        op.target_space = DPU_REG_TARGET_AF_BAR0;
        op.target_scope = DPU_REG_SCOPE_SINGLE;
        op.phase = phase;
        op.host_id = 0;
        op.segment_id = 0;
        op.bdf_valid = 1;
        op.bdf = 16'h0000;
        op.bar_id = 0;
        op.target_block = "test_block";
        op.address = address;
        op.width_bytes = 4;
        op.payload = payload;
        op.write_mask = 64'h0000_0000_ffff_ffff;
        return op;
    endfunction

    task assert_operation_contract();
        dpu_reg_op op;
        string why;

        op = make_mmio_write(
            "valid_write", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0000_0000_1122_3344
        );
        if (!op.validate(why))
            `uvm_fatal("REG_OP", $sformatf("valid operation rejected: %s", why))

        op = make_mmio_write(
            "bad_width", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.width_bytes = 3;
        if (op.validate(why) ||
            (why != "operation bad_width has unsupported MMIO access width 3")) begin
            `uvm_fatal("REG_OP", $sformatf(
                "bad width was not rejected precisely: %s", why))
        end

        op = make_mmio_write(
            "bad_target", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0000_0040, 64'h0
        );
        op.target_space = DPU_REG_TARGET_PCI_CONFIG;
        if (op.validate(why) ||
            (why != "operation bad_target MMIO write/commit requires an MMIO target")) begin
            `uvm_fatal("REG_OP", $sformatf(
                "bad target was not rejected precisely: %s", why))
        end

        op = make_mmio_write(
            "bad_mask", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.width_bytes = 1;
        op.write_mask = 64'h0000_0000_0000_0100;
        if (op.validate(why) ||
            (why != "operation bad_mask write mask exceeds its access width")) begin
            `uvm_fatal("REG_OP", $sformatf(
                "bad write mask was not rejected precisely: %s", why))
        end

        op = make_mmio_write(
            "bad_poll", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.kind = DPU_REG_OP_POLL_UNTIL;
        op.write_mask = '0;
        op.read_mask = 64'h0000_0000_ffff_ffff;
        op.max_attempts = 0;
        if (op.validate(why) ||
            (why != "operation bad_poll poll attempt count must be nonzero")) begin
            `uvm_fatal("REG_OP", $sformatf(
                "zero-attempt poll was not rejected precisely: %s", why))
        end
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        assert_operation_contract();
        `uvm_info("REG_PLAN_TEST", "register operation contract passed", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass : dpu_reg_plan_test

`endif // DPU_REG_PLAN_TEST_SV
