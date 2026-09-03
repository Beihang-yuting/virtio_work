`ifndef DPU_PCIE_REG_EXECUTOR_TEST_SV
`define DPU_PCIE_REG_EXECUTOR_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_executor_test_backend extends dpu_pcie_reg_backend;
    `uvm_object_utils(dpu_executor_test_backend)

    string calls[$];
    bit fail_write;
    bit fail_read;
    bit [63:0] read_value;

    function new(string name = "dpu_executor_test_backend");
        super.new(name);
        fail_write = 0;
        fail_read = 0;
        read_value = '0;
    endfunction

    virtual task write(input dpu_reg_op operation,
                       output bit ok, output string why);
        calls.push_back({"write:", operation.op_id});
        ok = !fail_write;
        why = ok ? "" : "backend write failure";
    endtask

    virtual task read(input dpu_reg_op operation,
                      output bit [63:0] value,
                      output bit ok, output string why);
        calls.push_back({"read:", operation.op_id});
        value = read_value;
        ok = !fail_read;
        why = ok ? "" : "backend read failure";
    endtask

    virtual task barrier(input dpu_reg_op operation,
                         output bit ok, output string why);
        calls.push_back({"barrier:", operation.op_id});
        ok = 1;
        why = "";
    endtask
endclass

class dpu_pcie_reg_executor_test extends uvm_test;
    `uvm_component_utils(dpu_pcie_reg_executor_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_reg_op make_op(string id,
                                           dpu_reg_op_kind_e kind,
                                           dpu_reg_phase_e phase,
                                           bit [63:0] address);
        dpu_reg_op op;
        op = dpu_reg_op::type_id::create(id);
        op.op_id = id;
        op.owner = "test.pcie";
        op.kind = kind;
        op.target_scope = DPU_REG_SCOPE_SINGLE;
        op.phase = phase;
        op.host_id = 0;
        op.segment_id = 0;
        op.bdf_valid = 1;
        op.bdf = 16'h0010;
        op.bar_id = (kind == DPU_REG_OP_PCI_CFG_WRITE) ? 0 : 0;
        op.target_space = (kind == DPU_REG_OP_PCI_CFG_WRITE) ?
                          DPU_REG_TARGET_PCI_CONFIG : DPU_REG_TARGET_AF_BAR0;
        op.target_block = "test";
        op.address = address;
        op.width_bytes = 4;
        if (kind inside {DPU_REG_OP_PCI_CFG_WRITE,
                         DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_OP_COMMIT}) begin
            op.payload = 64'h1234;
            op.write_mask = 64'hffff_ffff;
        end else if (kind inside {DPU_REG_OP_READ_VERIFY,
                                  DPU_REG_OP_POLL_UNTIL}) begin
            op.expected_value = 64'h1234;
            op.read_mask = 64'hffff_ffff;
        end
        return op;
    endfunction

    task run_phase(uvm_phase phase);
        dpu_reg_plan plan;
        dpu_pcie_reg_executor executor;
        dpu_executor_test_backend backend;
        dpu_reg_op write_op;
        dpu_reg_op read_op;
        dpu_execution_report report;
        dpu_cfg_status_e status;
        dpu_config_orchestrator orchestrator;
        string why;

        phase.raise_objection(this);
        plan = dpu_reg_plan::type_id::create("executor_plan");
        write_op = make_op("cfg.write", DPU_REG_OP_PCI_CFG_WRITE,
                           DPU_REG_PHASE_BOOTSTRAP, 64'h10);
        read_op = make_op("bar.read", DPU_REG_OP_READ_VERIFY,
                          DPU_REG_PHASE_TABLE, 64'h2000);
        read_op.add_dependency(write_op.op_id);
        if (!plan.add_operation(write_op, why) ||
            !plan.add_operation(read_op, why))
            `uvm_fatal("PCIE_EXECUTOR", {"could not build plan: ", why})

        backend = dpu_executor_test_backend::type_id::create("backend");
        backend.read_value = 64'h1234;
        executor = dpu_pcie_reg_executor::type_id::create("executor");
        executor.set_backend(backend);
        orchestrator = dpu_config_orchestrator::type_id::create("orchestrator");
        orchestrator.set_executor(executor);
        orchestrator.apply_with_report(plan, report);
        if ((report == null) || (report.status() != DPU_CFG_STATUS_SUCCEEDED) ||
            (backend.calls.size() != 2) ||
            (backend.calls[0] != "write:cfg.write") ||
            (backend.calls[1] != "read:bar.read"))
            `uvm_fatal("PCIE_EXECUTOR", "backend did not receive ordered operations")

        backend.fail_write = 1;
        plan = dpu_reg_plan::type_id::create("failed_executor_plan");
        write_op = make_op("failing.write", DPU_REG_OP_MMIO_WRITE,
                           DPU_REG_PHASE_TABLE, 64'h2000);
        if (!plan.add_operation(write_op, why))
            `uvm_fatal("PCIE_EXECUTOR", {"could not build failure plan: ", why})
        executor.reset_backend_state();
        orchestrator.apply(plan, status, why);
        if ((status != DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why != "backend write failure"))
            `uvm_fatal("PCIE_EXECUTOR", {"backend failure was not reported: ", why})

        backend.fail_write = 0;
        backend.fail_read = 1;
        backend.read_value = 64'h0;
        plan = dpu_reg_plan::type_id::create("mismatch_plan");
        read_op = make_op("mismatched.read", DPU_REG_OP_READ_VERIFY,
                          DPU_REG_PHASE_TABLE, 64'h2000);
        if (!plan.add_operation(read_op, why))
            `uvm_fatal("PCIE_EXECUTOR", {"could not build mismatch plan: ", why})
        orchestrator.apply(plan, status, why);
        if ((status != DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why != "backend read failure"))
            `uvm_fatal("PCIE_EXECUTOR", {"backend read failure was not reported: ", why})

        `uvm_info("PCIE_EXECUTOR", "PCIe register executor contract PASSED", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

`endif // DPU_PCIE_REG_EXECUTOR_TEST_SV
