`ifndef DPU_REG_PLAN_TEST_SV
`define DPU_REG_PLAN_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_test_reg_op extends dpu_reg_op;
    `uvm_object_utils(dpu_test_reg_op)

    int unsigned extension_value;

    function new(string name = "dpu_test_reg_op");
        super.new(name);
        extension_value = 0;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_test_reg_op typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("REG_OP_COPY",
                "dpu_test_reg_op::do_copy received an incompatible object")
            return;
        end
        extension_value = typed_rhs.extension_value;
    endfunction
endclass : dpu_test_reg_op

class dpu_reg_plan_test extends uvm_test;
    `uvm_component_utils(dpu_reg_plan_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic void configure_mmio_write(
        input dpu_reg_op op,
        input string op_id,
        input dpu_reg_phase_e phase,
        input bit [63:0] address,
        input bit [63:0] payload
    );
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
    endfunction

    function automatic dpu_reg_op make_mmio_write(
        input string op_id,
        input dpu_reg_phase_e phase,
        input bit [63:0] address,
        input bit [63:0] payload
    );
        dpu_reg_op op;

        op = dpu_reg_op::type_id::create(op_id);
        configure_mmio_write(op, op_id, phase, address, payload);
        return op;
    endfunction

    function automatic dpu_reg_op make_mmio_read(
        input string op_id,
        input dpu_reg_op_kind_e kind
    );
        dpu_reg_op op;

        op = make_mmio_write(
            op_id, DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.kind = kind;
        op.payload = '0;
        op.write_mask = '0;
        op.expected_value = 64'h0000_0000_a5a5_5a5a;
        op.read_mask = 64'h0000_0000_ffff_ffff;
        if (kind == DPU_REG_OP_POLL_UNTIL) begin
            op.max_attempts = 3;
            op.retry_interval = 100ns;
        end
        return op;
    endfunction

    function automatic dpu_reg_op make_pci_write(
        input string op_id,
        input bit [63:0] address,
        input int unsigned width_bytes
    );
        dpu_reg_op op;

        op = make_mmio_write(op_id, DPU_REG_PHASE_BOOTSTRAP, address, 64'h5a);
        op.kind = DPU_REG_OP_PCI_CFG_WRITE;
        op.target_space = DPU_REG_TARGET_PCI_CONFIG;
        op.bar_id = 0;
        op.width_bytes = width_bytes;
        case (width_bytes)
            1: op.write_mask = 64'h0000_0000_0000_00ff;
            2: op.write_mask = 64'h0000_0000_0000_ffff;
            default: op.write_mask = 64'h0000_0000_ffff_ffff;
        endcase
        return op;
    endfunction

    function automatic dpu_reg_op make_barrier(input string op_id);
        dpu_reg_op op;

        op = dpu_reg_op::type_id::create(op_id);
        op.op_id = op_id;
        op.owner = "test.module";
        op.kind = DPU_REG_OP_BARRIER;
        op.target_space = DPU_REG_TARGET_NONE;
        op.target_scope = DPU_REG_SCOPE_PER_HOST;
        op.phase = DPU_REG_PHASE_TABLE;
        op.host_id = 1;
        op.segment_id = 2;
        return op;
    endfunction

    task assert_original_operation_contract();
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

        op = make_mmio_read("bad_poll", DPU_REG_OP_POLL_UNTIL);
        op.max_attempts = 0;
        if (op.validate(why) ||
            (why != "operation bad_poll poll attempt count must be nonzero")) begin
            `uvm_fatal("REG_OP", $sformatf(
                "zero-attempt poll was not rejected precisely: %s", why))
        end
    endtask

    task assert_barrier_canonicalization();
        dpu_reg_op op;
        string why;

        op = make_barrier("valid_barrier");
        if (!op.validate(why))
            `uvm_fatal("REG_OP", $sformatf("canonical barrier rejected: %s", why))

        op = make_barrier("barrier_address");
        op.address = 64'h4;
        if (op.validate(why) ||
            (why != "operation barrier_address barrier must be canonical"))
            `uvm_fatal("REG_OP", $sformatf("dirty barrier address accepted: %s", why))

        op = make_barrier("barrier_expected");
        op.expected_value = 64'h1;
        if (op.validate(why) ||
            (why != "operation barrier_expected barrier must be canonical"))
            `uvm_fatal("REG_OP", $sformatf("dirty barrier expected value accepted: %s", why))

        op = make_barrier("barrier_poll");
        op.max_attempts = 1;
        op.retry_interval = 1ns;
        if (op.validate(why) ||
            (why != "operation barrier_poll barrier must be canonical"))
            `uvm_fatal("REG_OP", $sformatf("dirty barrier poll metadata accepted: %s", why))

        op = make_barrier("barrier_target");
        op.target_block = "stale";
        op.bdf_valid = 1;
        op.bdf = 16'h0100;
        op.bar_id = 1;
        if (op.validate(why) ||
            (why != "operation barrier_target barrier must be canonical"))
            `uvm_fatal("REG_OP", $sformatf("dirty barrier target metadata accepted: %s", why))

        op = make_barrier("barrier_commit");
        op.commit_group = "stale";
        if (op.validate(why) ||
            (why != "operation barrier_commit barrier must be canonical"))
            `uvm_fatal("REG_OP", $sformatf("dirty barrier commit metadata accepted: %s", why))
    endtask

    task assert_kind_specific_fields();
        dpu_reg_op op;
        string why;

        op = make_mmio_read("valid_read", DPU_REG_OP_READ_VERIFY);
        if (!op.validate(why))
            `uvm_fatal("REG_OP", $sformatf("canonical read rejected: %s", why))

        op = make_mmio_read("valid_poll", DPU_REG_OP_POLL_UNTIL);
        if (!op.validate(why))
            `uvm_fatal("REG_OP", $sformatf("canonical poll rejected: %s", why))

        op = make_mmio_write(
            "valid_commit", DPU_REG_PHASE_COMMIT,
            64'h0000_0000_0002_8000, 64'h1234_5678
        );
        op.kind = DPU_REG_OP_COMMIT;
        if (!op.validate(why))
            `uvm_fatal("REG_OP", $sformatf("canonical commit rejected: %s", why))

        op = make_mmio_write(
            "write_with_read_stale", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h1
        );
        op.read_mask = 64'h1;
        if (op.validate(why) ||
            (why != "operation write_with_read_stale write has read/poll fields set"))
            `uvm_fatal("REG_OP", $sformatf("write accepted stale read field: %s", why))

        op = make_mmio_read("read_with_write_stale", DPU_REG_OP_READ_VERIFY);
        op.payload = 64'h1;
        if (op.validate(why) ||
            (why != "operation read_with_write_stale read has write fields set"))
            `uvm_fatal("REG_OP", $sformatf("read accepted stale write field: %s", why))

        op = make_mmio_read("read_with_poll_stale", DPU_REG_OP_READ_VERIFY);
        op.max_attempts = 1;
        if (op.validate(why) ||
            (why != "operation read_with_poll_stale read-verify has poll fields set"))
            `uvm_fatal("REG_OP", $sformatf("read accepted stale poll field: %s", why))

        op = make_mmio_read("poll_unknown_interval", DPU_REG_OP_POLL_UNTIL);
        op.retry_interval = 'x;
        if (op.validate(why) ||
            (why != "operation poll_unknown_interval retry interval must be known"))
            `uvm_fatal("REG_OP", $sformatf("poll accepted unknown interval: %s", why))
    endtask

    task assert_pci_boundaries_and_invalid_enum();
        dpu_reg_op op;
        string why;

        op = make_pci_write("pci_last_dword", 64'd4092, 4);
        if (!op.validate(why))
            `uvm_fatal("REG_OP", $sformatf("last PCI dword rejected: %s", why))

        op = make_pci_write("pci_4093", 64'd4093, 4);
        if (op.validate(why) ||
            (why != "operation pci_4093 address is not width-aligned"))
            `uvm_fatal("REG_OP", $sformatf("PCI 4093 rejection order changed: %s", why))

        op = make_pci_write("pci_4094", 64'd4094, 4);
        if (op.validate(why) ||
            (why != "operation pci_4094 address is not width-aligned"))
            `uvm_fatal("REG_OP", $sformatf("PCI 4094 rejection order changed: %s", why))

        op = make_pci_write("pci_past_end", 64'd4096, 4);
        if (op.validate(why) ||
            (why != "operation pci_past_end PCI config access exceeds 4KB space"))
            `uvm_fatal("REG_OP", $sformatf("aligned PCI overflow not rejected: %s", why))

        op = make_mmio_write(
            "invalid_kind", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.kind = dpu_reg_op_kind_e'(32'hffff_ffff);
        if (op.validate(why) ||
            (why != "operation invalid_kind has unsupported operation kind"))
            `uvm_fatal("REG_OP", $sformatf("invalid kind accepted: %s", why))
    endtask

    task assert_copy_contract();
        dpu_test_reg_op source;
        dpu_test_reg_op copied;
        dpu_reg_op base_copy;
        dpu_reg_op cloned;
        uvm_object cloned_object;

        source = dpu_test_reg_op::type_id::create("source");
        configure_mmio_write(
            source, "copy_source", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'hfeed_face
        );
        source.add_dependency("first_dependency");
        source.extension_value = 32'hcafe_beef;

        if (!$cast(copied, source.copy_op("copied")))
            `uvm_fatal("REG_OP_COPY", "copy_op sliced the dynamic operation type")
        if ((copied.get_name() != "copied") ||
            (copied.op_id != source.op_id) ||
            (copied.payload != source.payload) ||
            (copied.extension_value != source.extension_value) ||
            (copied.dependencies.size() != 1) ||
            (copied.dependencies[0] != "first_dependency")) begin
            `uvm_fatal("REG_OP_COPY", "copy_op did not preserve all operation fields")
        end
        copied.dependencies.push_back("copy_only");
        if ((source.dependencies.size() != 1) ||
            (copied.dependencies.size() != 2))
            `uvm_fatal("REG_OP_COPY", "copy_op aliased the dependency queue")

        cloned_object = source.clone();
        if (!$cast(cloned, cloned_object) ||
            (cloned.op_id != source.op_id) ||
            (cloned.dependencies.size() != 1))
            `uvm_fatal("REG_OP_COPY", "standard clone did not copy base fields")

        base_copy = dpu_reg_op::type_id::create("base_copy");
        base_copy.copy(source);
        if ((base_copy.op_id != source.op_id) ||
            (base_copy.payload != source.payload) ||
            (base_copy.dependencies.size() != 1))
            `uvm_fatal("REG_OP_COPY", "standard copy did not copy base fields")
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        assert_original_operation_contract();
        assert_barrier_canonicalization();
        assert_kind_specific_fields();
        assert_pci_boundaries_and_invalid_enum();
        assert_copy_contract();
        `uvm_info("REG_PLAN_TEST", "register operation contract passed", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass : dpu_reg_plan_test

`endif // DPU_REG_PLAN_TEST_SV
