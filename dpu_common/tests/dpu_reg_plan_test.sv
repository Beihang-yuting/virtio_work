`ifndef DPU_REG_PLAN_TEST_SV
`define DPU_REG_PLAN_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_test_custom_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_test_custom_executor)

    int unsigned preflight_count;
    int unsigned execute_count;
    bit preflight_saw_frozen_plan;

    function new(string name = "dpu_test_custom_executor");
        super.new(name);
        preflight_count = 0;
        execute_count = 0;
        preflight_saw_frozen_plan = 0;
    endfunction

    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        preflight_count++;
        preflight_saw_frozen_plan = (plan != null) && plan.is_frozen();
        why = preflight_saw_frozen_plan ?
            "" : "custom executor needs frozen plan";
        return preflight_saw_frozen_plan;
    endfunction

    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        dpu_reg_op ordered[$];
        string why;

        execute_count++;
        if (!plan.ordered_operations(ordered, why)) begin
            set_last_error(why);
            status = DPU_CFG_STATUS_EXECUTION_FAILED;
            return;
        end
        set_last_error("");
        status = DPU_CFG_STATUS_SUCCEEDED;
    endtask
endclass : dpu_test_custom_executor

class dpu_test_controlled_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_test_controlled_executor)

    bit preflight_result;
    string preflight_why;
    string preflight_error;
    dpu_cfg_status_e execute_status;
    string execute_error;
    int unsigned preflight_count;
    int unsigned execute_count;
    bit preflight_saw_frozen_plan;
    bit execute_saw_preflight_plan;

    protected dpu_reg_plan preflight_plan;

    function new(string name = "dpu_test_controlled_executor");
        super.new(name);
        preflight_result = 1;
        preflight_why = "";
        preflight_error = "";
        execute_status = DPU_CFG_STATUS_SUCCEEDED;
        execute_error = "";
        preflight_count = 0;
        execute_count = 0;
        preflight_saw_frozen_plan = 0;
        execute_saw_preflight_plan = 0;
        preflight_plan = null;
    endfunction

    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        preflight_count++;
        preflight_plan = plan;
        preflight_saw_frozen_plan =
            (plan != null) && plan.is_frozen();
        why = preflight_why;
        set_last_error(preflight_error);
        return preflight_result;
    endfunction

    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        execute_count++;
        execute_saw_preflight_plan =
            (plan != null) && plan.is_frozen() &&
            (plan == preflight_plan);
        set_last_error(execute_error);
        status = execute_status;
    endtask

    function void prime_last_error(input string why);
        set_last_error(why);
    endfunction
endclass : dpu_test_controlled_executor

class dpu_test_blocking_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_test_blocking_executor)

    int unsigned preflight_count;
    int unsigned execute_count;
    string failure_text;
    uvm_event execute_started;
    uvm_event execute_release;

    protected dpu_reg_plan preflight_plan;

    function new(string name = "dpu_test_blocking_executor");
        super.new(name);
        preflight_count = 0;
        execute_count = 0;
        failure_text = "blocking executor active handoff failure";
        execute_started = new({name, "_execute_started"});
        execute_release = new({name, "_execute_release"});
        preflight_plan = null;
    endfunction

    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        preflight_count++;
        preflight_plan = null;
        why = "";
        set_last_error("");
        if (plan == null) begin
            why = "blocking executor received a null register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.is_frozen()) begin
            why = "blocking executor requires a frozen register plan";
            set_last_error(why);
            return 0;
        end
        preflight_plan = plan;
        return 1;
    endfunction

    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        execute_count++;
        if ((plan == null) || (plan != preflight_plan)) begin
            set_last_error(
                "blocking executor execute plan does not match preflight plan");
            status = DPU_CFG_STATUS_EXECUTION_FAILED;
            return;
        end
        execute_started.trigger();
        execute_release.wait_ptrigger();
        set_last_error(failure_text);
        status = DPU_CFG_STATUS_EXECUTION_FAILED;
    endtask
endclass : dpu_test_blocking_executor

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

class dpu_bad_copy_reg_op extends dpu_reg_op;
    `uvm_object_utils(dpu_bad_copy_reg_op)

    static bit tamper_copies;

    function new(string name = "dpu_bad_copy_reg_op");
        super.new(name);
    endfunction

    virtual function void do_copy(uvm_object rhs);
        super.do_copy(rhs);
        if (tamper_copies)
            op_id = "tampered_copy_id";
    endfunction
endclass : dpu_bad_copy_reg_op

class dpu_counted_copy_reg_op extends dpu_reg_op;
    `uvm_object_utils(dpu_counted_copy_reg_op)

    static int unsigned copy_count;
    static int unsigned tamper_on_copy;

    function new(string name = "dpu_counted_copy_reg_op");
        super.new(name);
    endfunction

    virtual function void do_copy(uvm_object rhs);
        super.do_copy(rhs);
        copy_count++;
        if ((tamper_on_copy != 0) && (copy_count == tamper_on_copy))
            op_id = "tampered_execute_copy_id";
    endfunction
endclass : dpu_counted_copy_reg_op

class dpu_spy_reg_executor_test_probe extends dpu_spy_reg_executor;
    `uvm_object_utils(dpu_spy_reg_executor_test_probe)

    function new(string name = "dpu_spy_reg_executor_test_probe");
        super.new(name);
    endfunction

    function bit history_is_aligned(input int unsigned expected_count);
        return (recorded_operations.size() == expected_count) &&
               (recorded_results.size() == expected_count);
    endfunction

endclass : dpu_spy_reg_executor_test_probe

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

    function automatic dpu_reg_plan build_valid_plan();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_test_reg_op bootstrap;
        string why;

        plan = dpu_reg_plan::type_id::create("valid_plan");

        op = make_mmio_write(
            "enable", DPU_REG_PHASE_ENABLE,
            64'h0000_0000_0002_0010, 64'h1
        );
        op.add_dependency("notify_commit");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)

        op = make_mmio_write(
            "notify_commit", DPU_REG_PHASE_COMMIT,
            64'h0000_0000_0002_0044, 64'h1
        );
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "vio.notify";
        op.add_dependency("notify_table");
        op.add_dependency("notify_verify");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)

        op = make_mmio_read("notify_verify", DPU_REG_OP_READ_VERIFY);
        op.expected_value = 64'h0000_0000_1122_3344;
        op.commit_group = "vio.notify";
        op.add_dependency("notify_table");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)

        op = make_mmio_write(
            "notify_table", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0000_0000_1122_3344
        );
        op.commit_group = "vio.notify";
        op.add_dependency("bootstrap");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)

        bootstrap = dpu_test_reg_op::type_id::create("bootstrap_source");
        configure_mmio_write(
            bootstrap, "bootstrap", DPU_REG_PHASE_BOOTSTRAP,
            64'h0000_0000_0000_1010, 64'h0000_0000_5555_aaaa
        );
        bootstrap.extension_value = 32'h1234_abcd;
        if (!plan.add_operation(bootstrap, why))
            `uvm_fatal("REG_PLAN", why)

        bootstrap.payload = 64'hdead_beef_dead_beef;
        bootstrap.extension_value = 0;
        return plan;
    endfunction

    task assert_plan_validation_and_order();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op found;
        dpu_reg_op ordered[$];
        dpu_test_reg_op typed_copy;
        string expected_ids[$] = '{
            "bootstrap", "notify_table", "notify_verify",
            "notify_commit", "enable"
        };
        string why;

        plan = build_valid_plan();
        if (plan.operation_count() != 5)
            `uvm_fatal("REG_PLAN", "valid plan stored the wrong operation count")
        if (!plan.validate(why))
            `uvm_fatal("REG_PLAN", $sformatf("valid plan rejected: %s", why))
        if (plan.is_frozen())
            `uvm_fatal("REG_PLAN", "validate unexpectedly froze the plan")
        if (!plan.find_operation("bootstrap", found))
            `uvm_fatal("REG_PLAN", "find_operation lost the bootstrap operation")
        if (!$cast(typed_copy, found) ||
            (typed_copy.extension_value != 32'h1234_abcd) ||
            (typed_copy.payload != 64'h0000_0000_5555_aaaa)) begin
            `uvm_fatal("REG_PLAN", "add/find sliced or aliased the operation copy")
        end
        typed_copy.payload = 64'hface_cafe_face_cafe;
        if (!plan.find_operation("bootstrap", found) ||
            (found.payload != 64'h0000_0000_5555_aaaa)) begin
            `uvm_fatal("REG_PLAN", "caller mutated the plan through find_operation")
        end
        found = make_mmio_write(
            "stale", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0);
        if (plan.find_operation("not_present", found) || (found != null))
            `uvm_fatal("REG_PLAN", "missing find_operation returned an object")

        ordered.push_back(make_mmio_write(
            "stale", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0));
        if (plan.ordered_operations(ordered, why) ||
            (why != "register plan must be frozen before retrieving order") ||
            (ordered.size() != 0)) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "unfrozen ordering contract changed: %s", why))
        end

        if (!plan.freeze(why))
            `uvm_fatal("REG_PLAN", $sformatf("valid plan rejected: %s", why))
        if (!plan.is_frozen())
            `uvm_fatal("REG_PLAN", "successful freeze did not freeze the plan")
        if (!plan.freeze(why))
            `uvm_fatal("REG_PLAN", $sformatf("idempotent freeze failed: %s", why))
        if (!plan.ordered_operations(ordered, why))
            `uvm_fatal("REG_PLAN", why)
        if (ordered.size() != expected_ids.size())
            `uvm_fatal("REG_PLAN", "valid plan returned the wrong operation count")
        foreach (expected_ids[index]) begin
            if (ordered[index].op_id != expected_ids[index]) begin
                `uvm_fatal("REG_PLAN", $sformatf(
                    "order[%0d]=%s expected %s", index,
                    ordered[index].op_id, expected_ids[index]))
            end
        end
        if (!$cast(typed_copy, ordered[0]) ||
            (typed_copy.extension_value != 32'h1234_abcd))
            `uvm_fatal("REG_PLAN", "ordered_operations sliced the dynamic type")
        ordered[0].payload = 64'hdead_beef_dead_beef;
        if (!plan.ordered_operations(ordered, why))
            `uvm_fatal("REG_PLAN", why)
        if (ordered[0].payload != 64'h0000_0000_5555_aaaa)
            `uvm_fatal("REG_PLAN", "caller mutated the frozen plan through a copy")

        op = make_mmio_write(
            "after_freeze", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8010, 64'h0
        );
        if (plan.add_operation(op, why) ||
            (why != "register plan is frozen")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "frozen plan accepted an operation: %s", why))
        end
    endtask

    task assert_plan_add_rejections();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_bad_copy_reg_op bad_copy;
        string why;

        plan = dpu_reg_plan::type_id::create("add_rejections");
        if (plan.add_operation(null, why) ||
            (why != "cannot add a null register operation") ||
            (plan.operation_count() != 0)) begin
            `uvm_fatal("REG_PLAN", $sformatf("null add contract changed: %s", why))
        end

        op = make_mmio_write(
            "", DPU_REG_PHASE_TABLE, 64'h0000_0000_0002_8000, 64'h0);
        if (plan.add_operation(op, why) ||
            (why != "register operation ID must not be empty") ||
            (plan.operation_count() != 0)) begin
            `uvm_fatal("REG_PLAN", $sformatf("empty ID add contract changed: %s", why))
        end

        op = make_mmio_write(
            "duplicate", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.add_operation(op, why) ||
            (why != "duplicate register operation ID duplicate") ||
            (plan.operation_count() != 1)) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "duplicate ID was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("bad_copy_plan");
        bad_copy = dpu_bad_copy_reg_op::type_id::create("bad_copy");
        configure_mmio_write(
            bad_copy, "bad_copy", DPU_REG_PHASE_TABLE, 64'h28000, 64'h0);
        dpu_bad_copy_reg_op::tamper_copies = 1;
        if (plan.add_operation(bad_copy, why) ||
            (plan.operation_count() != 0) || (why == "")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "mismatched copied ID was not rejected atomically: %s", why))
        end
        dpu_bad_copy_reg_op::tamper_copies = 0;
    endtask

    task assert_plan_copy_failure_outputs();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op found;
        dpu_reg_op ordered[$];
        dpu_bad_copy_reg_op bad_copy;
        string why;

        plan = dpu_reg_plan::type_id::create("find_bad_copy_plan");
        bad_copy = dpu_bad_copy_reg_op::type_id::create("find_bad_copy");
        configure_mmio_write(
            bad_copy, "find_bad_copy", DPU_REG_PHASE_TABLE,
            64'h28000, 64'h0);
        if (!plan.add_operation(bad_copy, why))
            `uvm_fatal("REG_PLAN", why)
        found = make_mmio_write(
            "stale_find", DPU_REG_PHASE_TABLE, 64'h28004, 64'h0);
        dpu_bad_copy_reg_op::tamper_copies = 1;
        if (plan.find_operation("find_bad_copy", found) || (found != null)) begin
            `uvm_fatal("REG_PLAN",
                "find_operation exposed a mismatched operation copy")
        end
        dpu_bad_copy_reg_op::tamper_copies = 0;

        plan = dpu_reg_plan::type_id::create("ordered_bad_copy_plan");
        op = make_mmio_write(
            "a_first", DPU_REG_PHASE_BOOTSTRAP, 64'h1010, 64'h0);
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        bad_copy = dpu_bad_copy_reg_op::type_id::create("z_bad");
        configure_mmio_write(
            bad_copy, "z_bad", DPU_REG_PHASE_TABLE, 64'h28000, 64'h0);
        bad_copy.add_dependency("a_first");
        if (!plan.add_operation(bad_copy, why))
            `uvm_fatal("REG_PLAN", why)
        if (!plan.freeze(why))
            `uvm_fatal("REG_PLAN", why)

        ordered.push_back(make_mmio_write(
            "stale_order", DPU_REG_PHASE_TABLE, 64'h28004, 64'h0));
        dpu_bad_copy_reg_op::tamper_copies = 1;
        if (plan.ordered_operations(ordered, why) ||
            (ordered.size() != 0) || (why == "")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "ordered copy failure leaked partial output: %s", why))
        end
        dpu_bad_copy_reg_op::tamper_copies = 0;
    endtask

    task assert_plan_structural_rejections();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op ordered[$];
        string why;

        plan = dpu_reg_plan::type_id::create("empty_plan");
        if (plan.freeze(why) ||
            (why != "register plan contains no operations") ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf("empty plan accepted: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("invalid_operation_plan");
        op = make_mmio_write(
            "invalid_width", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0);
        op.width_bytes = 3;
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation invalid_width has unsupported MMIO access width 3") ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "invalid operation result was not propagated: %s", why))
        end
        if (plan.ordered_operations(ordered, why) || (ordered.size() != 0))
            `uvm_fatal("REG_PLAN", "failed freeze retained a partial order")

        plan = dpu_reg_plan::type_id::create("missing_dependency_plan");
        op = make_mmio_write(
            "missing_user", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.add_dependency("does_not_exist");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation missing_user depends on unknown operation does_not_exist") ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "missing dependency was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("repeated_dependency_plan");
        op = make_mmio_write(
            "source", DPU_REG_PHASE_BOOTSTRAP, 64'h1010, 64'h0);
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "repeat_user", DPU_REG_PHASE_TABLE, 64'h28000, 64'h0);
        op.add_dependency("source");
        op.add_dependency("source");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation repeat_user repeats dependency source") ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "duplicate dependency was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("self_dependency_plan");
        op = make_mmio_write(
            "self_user", DPU_REG_PHASE_TABLE, 64'h28000, 64'h0);
        op.add_dependency("self_user");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation self_user depends on itself") ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "self dependency was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("cycle_plan");
        op = make_mmio_write(
            "cycle_a", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.add_dependency("cycle_b");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "cycle_b", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8004, 64'h0
        );
        op.add_dependency("cycle_a");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "register plan contains a dependency cycle") ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "cycle was not rejected precisely: %s", why))
        end
    endtask

    task assert_commit_rejections();
        dpu_reg_plan plan;
        dpu_reg_op op;
        string why;

        plan = dpu_reg_plan::type_id::create("empty_commit_group");
        op = make_mmio_write(
            "empty_group_commit", DPU_REG_PHASE_COMMIT, 64'h20044, 64'h1);
        op.kind = DPU_REG_OP_COMMIT;
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation empty_group_commit commit group must not be empty")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "empty commit group was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("commit_without_producer");
        op = make_mmio_read("group_verify", DPU_REG_OP_READ_VERIFY);
        op.commit_group = "vio.notify";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "orphan_commit", DPU_REG_PHASE_COMMIT,
            64'h0000_0000_0002_0044, 64'h1
        );
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "vio.notify";
        op.add_dependency("group_verify");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation orphan_commit has no table producer in commit group vio.notify")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "orphan commit was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("partial_commit_plan");
        op = make_mmio_write(
            "table_b", DPU_REG_PHASE_TABLE, 64'h28004, 64'h2);
        op.commit_group = "vio.notify";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "table_a", DPU_REG_PHASE_TABLE, 64'h28000, 64'h1);
        op.commit_group = "vio.notify";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "partial_commit", DPU_REG_PHASE_COMMIT, 64'h20044, 64'h1);
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "vio.notify";
        op.add_dependency("table_a");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation partial_commit does not depend on commit-group producer table_b")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "partial commit was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("duplicate_commit_group_plan");
        op = make_mmio_write(
            "shared_table", DPU_REG_PHASE_TABLE, 64'h28000, 64'h1);
        op.commit_group = "shared.batch";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "commit_b", DPU_REG_PHASE_COMMIT, 64'h20044, 64'h1);
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "shared.batch";
        op.add_dependency("shared_table");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "commit_a", DPU_REG_PHASE_COMMIT, 64'h20044, 64'h1);
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "shared.batch";
        op.add_dependency("shared_table");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != {"commit group shared.batch is used by multiple ",
                     "commit operations commit_a and commit_b"})) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "duplicate commit group was not rejected precisely: %s", why))
        end
    endtask

    task assert_producer_epoch_requires_commit();
        dpu_reg_plan plan;
        dpu_reg_op op;
        string why;

        plan = dpu_reg_plan::type_id::create("orphan_producer_plan");
        op = make_mmio_write(
            "table_a", DPU_REG_PHASE_TABLE, 64'h28000, 64'h1);
        op.commit_group = "epoch.a";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != {"commit group epoch.a has producer table_a ",
                     "but no commit operation"}) ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "orphan producer was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("enable_bypass_plan");
        op = make_mmio_write(
            "table_a", DPU_REG_PHASE_TABLE, 64'h28000, 64'h1);
        op.commit_group = "epoch.a";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "enable", DPU_REG_PHASE_ENABLE, 64'h20010, 64'h1);
        op.add_dependency("table_a");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != {"commit group epoch.a has producer table_a ",
                     "but no commit operation"}) ||
            plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "enable dependency bypassed the missing commit: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("ungrouped_table_plan");
        op = make_mmio_write(
            "ordinary_table", DPU_REG_PHASE_TABLE, 64'h28000, 64'h1);
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (!plan.freeze(why) || !plan.is_frozen()) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "ungrouped table write incorrectly required a commit: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("complete_epoch_plan");
        op = make_mmio_write(
            "table_b", DPU_REG_PHASE_TABLE, 64'h28004, 64'h2);
        op.commit_group = "epoch.complete";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "table_a", DPU_REG_PHASE_TABLE, 64'h28000, 64'h1);
        op.commit_group = "epoch.complete";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "complete_commit", DPU_REG_PHASE_COMMIT, 64'h20044, 64'h1);
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "epoch.complete";
        op.add_dependency("table_b");
        op.add_dependency("table_a");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (!plan.freeze(why))
            `uvm_fatal("REG_PLAN", $sformatf(
                "complete multi-producer epoch was rejected: %s", why))
    endtask

    task assert_deterministic_ready_order();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op ordered[$];
        string expected_ids[$] = '{"bootstrap", "a_table", "z_table"};
        string why;

        plan = dpu_reg_plan::type_id::create("deterministic_plan");
        op = make_mmio_write(
            "z_table", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0);
        op.add_dependency("bootstrap");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "a_table", DPU_REG_PHASE_TABLE, 64'h28000, 64'h0);
        op.add_dependency("bootstrap");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "bootstrap", DPU_REG_PHASE_BOOTSTRAP, 64'h1010, 64'h0);
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (!plan.freeze(why) || !plan.ordered_operations(ordered, why))
            `uvm_fatal("REG_PLAN", why)
        foreach (expected_ids[index]) begin
            if (ordered[index].op_id != expected_ids[index]) begin
                `uvm_fatal("REG_PLAN", $sformatf(
                    "deterministic order[%0d]=%s expected %s",
                    index, ordered[index].op_id, expected_ids[index]))
            end
        end
    endtask

    task assert_phase_is_ready_priority_only();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op ordered[$];
        string expected_ids[$] = '{
            "bootstrap", "table_a", "commit_a", "table_b", "commit_b"
        };
        string why;

        plan = dpu_reg_plan::type_id::create("multi_stage_plan");
        op = make_mmio_write(
            "commit_b", DPU_REG_PHASE_COMMIT, 64'h20044, 64'h2);
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "stage.b";
        op.add_dependency("table_b");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "table_b", DPU_REG_PHASE_TABLE, 64'h28000, 64'h2);
        op.commit_group = "stage.b";
        op.add_dependency("commit_a");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "commit_a", DPU_REG_PHASE_COMMIT, 64'h20044, 64'h1);
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "stage.a";
        op.add_dependency("table_a");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "table_a", DPU_REG_PHASE_TABLE, 64'h28000, 64'h1);
        op.commit_group = "stage.a";
        op.add_dependency("bootstrap");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "bootstrap", DPU_REG_PHASE_BOOTSTRAP, 64'h1010, 64'h0);
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)

        if (!plan.freeze(why) || !plan.ordered_operations(ordered, why))
            `uvm_fatal("REG_PLAN", $sformatf(
                "multi-stage plan rejected: %s", why))
        foreach (expected_ids[index]) begin
            if (ordered[index].op_id != expected_ids[index]) begin
                `uvm_fatal("REG_PLAN", $sformatf(
                    "multi-stage order[%0d]=%s expected %s",
                    index, ordered[index].op_id, expected_ids[index]))
            end
        end
    endtask

    task assert_large_plan_order();
        localparam int unsigned SCALE_OPERATION_COUNT = 1024;
        localparam int unsigned CHAIN_END = 511;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op ordered[$];
        string op_id;
        string dependency_id;
        string why;

        plan = dpu_reg_plan::type_id::create("scale_plan");
        for (int unsigned index = 0;
             index < SCALE_OPERATION_COUNT; index++) begin
            op_id = $sformatf("scale_%04d", index);
            op = make_mmio_write(
                op_id,
                (index == 0) ? DPU_REG_PHASE_BOOTSTRAP : DPU_REG_PHASE_TABLE,
                64'h0000_0000_0004_0000 + (index * 4), index
            );
            if (index != 0) begin
                if (index <= CHAIN_END)
                    dependency_id = $sformatf("scale_%04d", index - 1);
                else
                    dependency_id = $sformatf("scale_%04d", CHAIN_END);
                op.add_dependency(dependency_id);
            end
            if (!plan.add_operation(op, why))
                `uvm_fatal("REG_PLAN", why)
        end

        if (!plan.freeze(why) || !plan.ordered_operations(ordered, why))
            `uvm_fatal("REG_PLAN", $sformatf("scale plan rejected: %s", why))
        if (ordered.size() != SCALE_OPERATION_COUNT)
            `uvm_fatal("REG_PLAN", "scale plan returned the wrong operation count")
        foreach (ordered[index]) begin
            op_id = $sformatf("scale_%04d", index);
            if (ordered[index].op_id != op_id) begin
                `uvm_fatal("REG_PLAN", $sformatf(
                    "scale order[%0d]=%s expected %s",
                    index, ordered[index].op_id, op_id))
            end
        end
    endtask

    task assert_spy_executor_contract();
        dpu_reg_plan plan;
        dpu_reg_plan unfrozen_plan;
        dpu_reg_plan other_plan;
        dpu_reg_plan execute_copy_failure_plan;
        dpu_reg_plan copy_failure_plan;
        dpu_spy_reg_executor_test_probe spy;
        dpu_reg_op op;
        dpu_reg_op recorded;
        dpu_test_reg_op recorded_bootstrap;
        dpu_bad_copy_reg_op bad_copy;
        dpu_counted_copy_reg_op counted_copy;
        dpu_reg_op_result_e result;
        dpu_cfg_status_e status;
        int unsigned before_count;
        string snapshot_ids[$];
        dpu_reg_op_result_e snapshot_results[$];
        bit [63:0] snapshot_payloads[$];
        string expected_ids[$] = '{
            "bootstrap", "notify_table", "notify_verify",
            "notify_commit", "enable"
        };
        string why;

        plan = build_valid_plan();
        if (!plan.freeze(why))
            `uvm_fatal("REG_EXEC", why)
        spy = dpu_spy_reg_executor_test_probe::type_id::create("spy");
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", $sformatf("spy preflight failed: %s", why))
        if (!spy.preflight_history_was_empty() ||
            (spy.record_count() != 0)) begin
            `uvm_fatal("REG_EXEC", "spy recorded an operation before preflight")
        end
        spy.execute(plan, status);
        if (status !== DPU_CFG_STATUS_SUCCEEDED)
            `uvm_fatal("REG_EXEC", $sformatf(
                "spy execution failed: %s", spy.last_error()))
        if (spy.record_count() != 5)
            `uvm_fatal("REG_EXEC", "spy did not record all five operations")
        foreach (expected_ids[index]) begin
            if (!spy.record_at(index, recorded, result, why) ||
                (why != "") || (recorded.op_id != expected_ids[index]) ||
                (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
                `uvm_fatal("REG_EXEC", $sformatf(
                    "spy record[%0d] did not preserve ordered success %s: %s",
                    index, expected_ids[index], why))
            end
        end
        if (!spy.record_at(0, recorded, result, why) ||
            !$cast(recorded_bootstrap, recorded) ||
            (recorded_bootstrap.op_id != "bootstrap") ||
            (recorded_bootstrap.kind != DPU_REG_OP_MMIO_WRITE) ||
            (recorded_bootstrap.phase != DPU_REG_PHASE_BOOTSTRAP) ||
            (recorded_bootstrap.address != 64'h0000_0000_0000_1010) ||
            (recorded_bootstrap.payload != 64'h0000_0000_5555_aaaa) ||
            (recorded_bootstrap.extension_value != 32'h1234_abcd) ||
            (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
            `uvm_fatal("REG_EXEC",
                "spy did not preserve the exact successful bootstrap record")
        end
        if (!spy.record_at(1, recorded, result, why))
            `uvm_fatal("REG_EXEC", why)
        if ((recorded.op_id != "notify_table") ||
            (recorded.target_space != DPU_REG_TARGET_AF_BAR0) ||
            (recorded.target_scope != DPU_REG_SCOPE_SINGLE) ||
            (recorded.host_id != 0) || (recorded.segment_id != 0) ||
            !recorded.bdf_valid || (recorded.bdf != 16'h0000) ||
            (recorded.bar_id != 0) ||
            (recorded.address != 64'h0000_0000_0002_8000) ||
            (recorded.payload != 64'h0000_0000_1122_3344) ||
            (recorded.commit_group != "vio.notify") ||
            (recorded.dependencies.size() != 1) ||
            (recorded.dependencies[0] != "bootstrap") ||
            (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
            `uvm_fatal("REG_EXEC",
                "spy did not preserve table target/payload/result")
        end
        recorded.payload = '0;
        recorded.dependencies.push_back("caller_only");
        if (!spy.record_at(1, recorded, result, why) ||
            (recorded.payload != 64'h0000_0000_1122_3344) ||
            (recorded.dependencies.size() != 1)) begin
            `uvm_fatal("REG_EXEC", "caller mutated spy history through record_at")
        end
        if (!spy.record_at(2, recorded, result, why))
            `uvm_fatal("REG_EXEC", why)
        if ((recorded.op_id != "notify_verify") ||
            (recorded.kind != DPU_REG_OP_READ_VERIFY) ||
            (recorded.expected_value != 64'h0000_0000_1122_3344) ||
            (recorded.read_mask != 64'h0000_0000_ffff_ffff) ||
            (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
            `uvm_fatal("REG_EXEC", "spy did not preserve readback policy/result")
        end
        if (!spy.record_at(3, recorded, result, why))
            `uvm_fatal("REG_EXEC", why)
        if ((recorded.op_id != "notify_commit") ||
            (recorded.kind != DPU_REG_OP_COMMIT) ||
            (recorded.commit_group != "vio.notify") ||
            (recorded.dependencies.size() != 2) ||
            (recorded.dependencies[0] != "notify_table") ||
            (recorded.dependencies[1] != "notify_verify") ||
            (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
            `uvm_fatal("REG_EXEC", "spy did not preserve commit policy/result")
        end
        if (!spy.record_at(4, recorded, result, why))
            `uvm_fatal("REG_EXEC", why)
        if ((recorded.op_id != "enable") ||
            (recorded.phase != DPU_REG_PHASE_ENABLE) ||
            (recorded.dependencies.size() != 1) ||
            (recorded.dependencies[0] != "notify_commit") ||
            (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
            `uvm_fatal("REG_EXEC", "spy did not preserve enable dependency/result")
        end

        recorded = make_mmio_write(
            "stale_record", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0);
        result = DPU_REG_OP_RESULT_SUCCEEDED;
        if (spy.record_at(5, recorded, result, why) ||
            (recorded != null) || (result != DPU_REG_OP_RESULT_NOT_RUN) ||
            (why != "spy record index 5 is out of range")) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "out-of-range spy record contract changed: %s", why))
        end

        spy.reset_history();
        spy.fail_operation("notify_table");
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.execute(plan, status);
        if (status !== DPU_CFG_STATUS_EXECUTION_FAILED)
            `uvm_fatal("REG_EXEC",
                "injected operation failure did not fail execution")
        if (spy.record_count() != 2)
            `uvm_fatal("REG_EXEC", "spy executed commit/enable after table failure")
        if (!spy.record_at(0, recorded, result, why) ||
            (recorded.op_id != "bootstrap") ||
            (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
            `uvm_fatal("REG_EXEC",
                "spy did not record successful bootstrap before table failure")
        end
        if (!spy.record_at(1, recorded, result, why))
            `uvm_fatal("REG_EXEC", why)
        if ((recorded.op_id != "notify_table") ||
            (result != DPU_REG_OP_RESULT_FAILED)) begin
            `uvm_fatal("REG_EXEC", "spy did not record the injected table failure")
        end
        recorded = make_mmio_write(
            "stale_failure_record", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0);
        result = DPU_REG_OP_RESULT_SUCCEEDED;
        if (spy.record_at(2, recorded, result, why) ||
            (recorded != null) || (result != DPU_REG_OP_RESULT_NOT_RUN) ||
            (why != "spy record index 2 is out of range")) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "failure history exposed a third record: %s", why))
        end
        if (spy.last_error() !=
            "injected execution failure at operation notify_table") begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "unexpected spy failure text: %s", spy.last_error()))
        end

        spy.reset_history();
        if ((spy.record_count() != 0) ||
            spy.preflight_history_was_empty() || (spy.last_error() != "")) begin
            `uvm_fatal("REG_EXEC", "spy reset did not clear its complete state")
        end
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 0) ||
            (spy.last_error() !=
             "spy executor execute called before preflight")) begin
            `uvm_fatal("REG_EXEC", "execute-before-preflight contract changed")
        end
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_SUCCEEDED) ||
            (spy.record_count() != 5) || (spy.last_error() != "")) begin
            `uvm_fatal("REG_EXEC", "reset retained an injected operation failure")
        end

        spy.reset_history();
        if (spy.preflight(null, why) ||
            (why != "spy executor received a null register plan") ||
            (spy.last_error() != why)) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "null preflight contract changed: %s", why))
        end
        unfrozen_plan = build_valid_plan();
        if (spy.preflight(unfrozen_plan, why) ||
            (why != "spy executor requires a frozen register plan") ||
            (spy.last_error() != why)) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "unfrozen preflight contract changed: %s", why))
        end
        spy.reset_history();
        spy.fail_operation("not_present");
        if (spy.preflight(plan, why) ||
            (why !=
             "spy failure operation not_present is not in the register plan") ||
            (spy.last_error() != why)) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "unknown failure operation contract changed: %s", why))
        end
        spy.reset_history();
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.fail_preflight("injected preflight failure");
        if (spy.preflight(plan, why) ||
            (why != "injected preflight failure") ||
            (spy.last_error() != why) ||
            !spy.preflight_history_was_empty() ||
            (spy.record_count() != 0)) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "injected preflight failure contract changed: %s", why))
        end
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 0) ||
            (spy.last_error() !=
             "spy executor execute called without successful preflight")) begin
            `uvm_fatal("REG_EXEC",
                "failed preflight authorized register execution")
        end

        spy.reset_history();
        other_plan = build_valid_plan();
        if (!other_plan.freeze(why))
            `uvm_fatal("REG_EXEC", why)
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.execute(other_plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 0) ||
            (spy.last_error() !=
             "spy executor execute plan does not match preflight plan")) begin
            `uvm_fatal("REG_EXEC",
                "preflight for one plan authorized a different plan")
        end
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 0) ||
            (spy.last_error() !=
             "spy executor execute authorization was already consumed")) begin
            `uvm_fatal("REG_EXEC",
                "cross-plan execute did not consume its authorization")
        end

        spy.reset_history();
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_SUCCEEDED) ||
            (spy.record_count() != 5)) begin
            `uvm_fatal("REG_EXEC", "single-use authorization execution failed")
        end
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 5) ||
            (spy.last_error() !=
             "spy executor execute authorization was already consumed")) begin
            `uvm_fatal("REG_EXEC", "execute authorization was reusable")
        end

        execute_copy_failure_plan =
            dpu_reg_plan::type_id::create("execute_copy_failure_plan");
        op = make_mmio_write(
            "copy_prefix", DPU_REG_PHASE_BOOTSTRAP, 64'h1010, 64'h0);
        if (!execute_copy_failure_plan.add_operation(op, why))
            `uvm_fatal("REG_EXEC", why)
        counted_copy =
            dpu_counted_copy_reg_op::type_id::create("counted_copy_source");
        configure_mmio_write(
            counted_copy, "execute_copy_failure", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0);
        counted_copy.add_dependency("copy_prefix");
        dpu_counted_copy_reg_op::copy_count = 0;
        dpu_counted_copy_reg_op::tamper_on_copy = 3;
        if (!execute_copy_failure_plan.add_operation(counted_copy, why) ||
            (dpu_counted_copy_reg_op::copy_count != 1) ||
            !execute_copy_failure_plan.freeze(why)) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "could not build counted copy failure plan: %s", why))
        end
        before_count = spy.record_count();
        if ((before_count != 5) || !spy.history_is_aligned(before_count))
            `uvm_fatal("REG_EXEC", "copy failure test lost sentinel history")
        snapshot_ids.delete();
        snapshot_results.delete();
        snapshot_payloads.delete();
        for (int unsigned index = 0; index < before_count; index++) begin
            if (!spy.record_at(index, recorded, result, why))
                `uvm_fatal("REG_EXEC", why)
            snapshot_ids.push_back(recorded.op_id);
            snapshot_results.push_back(result);
            snapshot_payloads.push_back(recorded.payload);
        end
        if (!spy.preflight(execute_copy_failure_plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.execute(execute_copy_failure_plan, status);
        if ((dpu_counted_copy_reg_op::copy_count != 3) ||
            (status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != before_count) ||
            (spy.last_error() !=
             {"spy operation copy ID tampered_execute_copy_id does not match ",
              "expected ID execute_copy_failure"})) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "execute copy failure was not atomic: copies=%0d count=%0d error=%s",
                dpu_counted_copy_reg_op::copy_count,
                spy.record_count(), spy.last_error()))
        end
        if (!spy.history_is_aligned(before_count)) begin
            `uvm_fatal("REG_EXEC",
                "execute copy failure misaligned operation/result history")
        end
        foreach (snapshot_ids[index]) begin
            if (!spy.record_at(index, recorded, result, why) ||
                (why != "") || (recorded.op_id != snapshot_ids[index]) ||
                (result != snapshot_results[index]) ||
                (recorded.payload != snapshot_payloads[index])) begin
                `uvm_fatal("REG_EXEC", $sformatf(
                    "execute copy failure changed prior record %0d: %s",
                    index, why))
            end
        end
        recorded = make_mmio_write(
            "stale_partial_record", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0);
        result = DPU_REG_OP_RESULT_SUCCEEDED;
        if (spy.record_at(before_count, recorded, result, why) ||
            (recorded != null) || (result != DPU_REG_OP_RESULT_NOT_RUN) ||
            (why != $sformatf(
                "spy record index %0d is out of range", before_count))) begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "execute copy failure exposed a staged prefix: %s", why))
        end
        dpu_counted_copy_reg_op::tamper_on_copy = 0;

        copy_failure_plan = dpu_reg_plan::type_id::create("copy_failure_plan");
        bad_copy = dpu_bad_copy_reg_op::type_id::create("bad_spy_copy");
        configure_mmio_write(
            bad_copy, "bad_spy_copy", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0);
        if (!copy_failure_plan.add_operation(bad_copy, why) ||
            !copy_failure_plan.freeze(why)) begin
            `uvm_fatal("REG_EXEC", why)
        end
        spy.reset_history();
        if (!spy.preflight(copy_failure_plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.execute(copy_failure_plan, status);
        if ((status !== DPU_CFG_STATUS_SUCCEEDED) ||
            (spy.record_count() != 1)) begin
            `uvm_fatal("REG_EXEC", "spy could not record a dynamic operation subtype")
        end
        recorded = make_mmio_write(
            "stale_bad_copy", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0);
        result = DPU_REG_OP_RESULT_SUCCEEDED;
        dpu_bad_copy_reg_op::tamper_copies = 1;
        if (spy.record_at(0, recorded, result, why) ||
            (recorded != null) || (result != DPU_REG_OP_RESULT_NOT_RUN) ||
            (why != {"spy operation copy ID tampered_copy_id does not match ",
                     "expected ID bad_spy_copy"}) ||
            (spy.record_count() != 1)) begin
            `uvm_fatal("REG_EXEC", "spy exposed a corrupt dynamic operation copy")
        end
        dpu_bad_copy_reg_op::tamper_copies = 0;
    endtask

    task assert_spy_failure_configuration_snapshot();
        dpu_reg_plan plan;
        dpu_reg_plan other_plan;
        dpu_spy_reg_executor spy;
        dpu_reg_op recorded;
        dpu_reg_op_result_e result;
        dpu_cfg_status_e status;
        string why;

        plan = build_valid_plan();
        other_plan = build_valid_plan();
        if (!plan.freeze(why) || !other_plan.freeze(why))
            `uvm_fatal("REG_EXEC_SNAPSHOT", why)
        spy = dpu_spy_reg_executor::type_id::create("snapshot_spy");

        spy.fail_operation("notify_table");
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC_SNAPSHOT", why)
        spy.fail_operation("notify_verify");
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 2) ||
            (spy.last_error() !=
             "injected execution failure at operation notify_table")) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT", $sformatf(
                {"post-preflight failure mutation changed execution: ",
                 "status=%0d count=%0d error=%s"},
                status, spy.record_count(), spy.last_error()))
        end
        if (!spy.record_at(0, recorded, result, why) ||
            (recorded.op_id != "bootstrap") ||
            (result != DPU_REG_OP_RESULT_SUCCEEDED)) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT",
                "snapshot failure lost the successful bootstrap prefix")
        end
        if (!spy.record_at(1, recorded, result, why) ||
            (recorded.op_id != "notify_table") ||
            (result != DPU_REG_OP_RESULT_FAILED)) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT",
                "snapshot failure did not stop at notify_table")
        end
        recorded = make_mmio_write(
            "stale_snapshot_record", DPU_REG_PHASE_TABLE, 64'h28010, 64'h0);
        result = DPU_REG_OP_RESULT_SUCCEEDED;
        if (spy.record_at(2, recorded, result, why) ||
            (recorded != null) || (result != DPU_REG_OP_RESULT_NOT_RUN) ||
            (why != "spy record index 2 is out of range")) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT", $sformatf(
                "snapshot table failure exposed a third record: %s", why))
        end

        spy.reset_history();
        spy.fail_operation("notify_table");
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC_SNAPSHOT", why)
        spy.fail_operation("");
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 2) ||
            (spy.last_error() !=
             "injected execution failure at operation notify_table")) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT",
                "clearing configured failure changed authorized execution")
        end

        spy.reset_history();
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC_SNAPSHOT", why)
        spy.fail_operation("not_present");
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_SUCCEEDED) ||
            (spy.record_count() != 5) || (spy.last_error() != "")) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT",
                "post-preflight unknown failure changed current execution")
        end
        if (spy.preflight(plan, why) ||
            (why !=
             "spy failure operation not_present is not in the register plan") ||
            (spy.last_error() != why)) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT", $sformatf(
                "next preflight did not observe configured failure: %s", why))
        end
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 5) ||
            (spy.last_error() !=
             "spy executor execute called without successful preflight")) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT",
                "failed next preflight retained an execution authorization")
        end

        spy.reset_history();
        spy.fail_operation("notify_table");
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC_SNAPSHOT", why)
        spy.fail_operation("notify_verify");
        spy.execute(other_plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 0) ||
            (spy.last_error() !=
             "spy executor execute plan does not match preflight plan")) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT",
                "snapshot authorization bypassed cross-plan rejection")
        end
        spy.execute(plan, status);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 0) ||
            (spy.last_error() !=
             "spy executor execute authorization was already consumed")) begin
            `uvm_fatal("REG_EXEC_SNAPSHOT",
                "snapshot authorization was reusable after cross-plan rejection")
        end
    endtask

    task assert_orchestrator_contract();
        dpu_config_orchestrator orchestrator;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_spy_reg_executor spy;
        dpu_test_custom_executor custom;
        dpu_test_controlled_executor controlled;
        dpu_test_controlled_executor replaced;
        dpu_test_controlled_executor handoff_replacement;
        dpu_test_controlled_executor repeated;
        dpu_test_blocking_executor blocking;
        dpu_cfg_status_e status;
        int unsigned replaced_preflight_count;
        int unsigned replaced_execute_count;
        string why;

        orchestrator =
            dpu_config_orchestrator::type_id::create("orchestrator");
        if (orchestrator == null)
            `uvm_fatal("REG_ORCH", "could not create configuration orchestrator")

        orchestrator.clear_executor();
        if (orchestrator.has_executor())
            `uvm_fatal("REG_ORCH", "clear_executor retained an executor")
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale no-executor diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_NOT_EXECUTED) ||
            !plan.is_frozen() ||
            (why != {"validated register plan was not executed because no ",
                     "executor is installed"})) begin
            `uvm_fatal("REG_ORCH", $sformatf(
                "no-executor handoff reported status=%0d why=%s",
                status, why))
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "invalid_plan_executor");
        orchestrator.set_executor(controlled);
        if (!orchestrator.has_executor())
            `uvm_fatal("REG_ORCH",
                "set_executor did not install the invalid-plan executor")
        plan = dpu_reg_plan::type_id::create("invalid_orchestrator_plan");
        op = make_mmio_write(
            "invalid", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.add_dependency("missing");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_ORCH", why)
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale validation diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_PLAN_INVALID) ||
            (controlled.preflight_count != 0) ||
            (controlled.execute_count != 0) ||
            (why !=
             "operation invalid depends on unknown operation missing")) begin
            `uvm_fatal("REG_ORCH", $sformatf(
                {"invalid plan reached executor dispatch: status=%0d ",
                 "preflight_count=%0d execute_count=%0d why=%s"},
                status, controlled.preflight_count,
                controlled.execute_count, why))
        end

        spy = dpu_spy_reg_executor::type_id::create("preflight_spy");
        spy.fail_preflight("injected preflight rejection");
        orchestrator.set_executor(spy);
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale preflight diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_PREFLIGHT_FAILED) ||
            (spy.record_count() != 0) ||
            (why != "injected preflight rejection")) begin
            `uvm_fatal("REG_ORCH", $sformatf(
                "preflight rejection did not block execution: %s", why))
        end

        spy = dpu_spy_reg_executor::type_id::create("execution_spy");
        spy.fail_operation("notify_table");
        orchestrator.set_executor(spy);
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale execution diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 2) ||
            (why !=
             "injected execution failure at operation notify_table")) begin
            `uvm_fatal("REG_ORCH", $sformatf(
                "executor failure was not propagated precisely: %s", why))
        end

        custom = dpu_test_custom_executor::type_id::create("custom");
        orchestrator.set_executor(custom);
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_PLAN_INVALID;
        why = "stale custom diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_SUCCEEDED) || (why != "") ||
            (custom.preflight_count != 1) || (custom.execute_count != 1) ||
            !custom.preflight_saw_frozen_plan) begin
            `uvm_fatal("REG_ORCH", "custom executor did not plug into orchestrator")
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "null_plan_executor");
        orchestrator.set_executor(controlled);
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale null-plan diagnostic";
        orchestrator.apply(null, status, why);
        if ((status !== DPU_CFG_STATUS_PLAN_INVALID) ||
            (why !=
             "configuration orchestrator received a null register plan") ||
            (controlled.preflight_count != 0) ||
            (controlled.execute_count != 0)) begin
            `uvm_fatal("REG_ORCH", $sformatf(
                "null plan reached executor dispatch: status=%0d why=%s",
                status, why))
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "preflight_output_executor");
        controlled.preflight_result = 0;
        controlled.preflight_why = "executor preflight output diagnostic";
        controlled.preflight_error = "lower-priority executor last error";
        orchestrator.set_executor(controlled);
        plan = build_valid_plan();
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_PREFLIGHT_FAILED) ||
            (why != "executor preflight output diagnostic") ||
            (controlled.preflight_count != 1) ||
            (controlled.execute_count != 0) ||
            !controlled.preflight_saw_frozen_plan) begin
            `uvm_fatal("REG_ORCH",
                "preflight output did not take priority over last_error")
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "preflight_last_error_executor");
        controlled.preflight_result = 0;
        controlled.preflight_error = "executor preflight last error";
        orchestrator.set_executor(controlled);
        plan = build_valid_plan();
        why = "stale preflight-last-error diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_PREFLIGHT_FAILED) ||
            (why != "executor preflight last error") ||
            (controlled.preflight_count != 1) ||
            (controlled.execute_count != 0)) begin
            `uvm_fatal("REG_ORCH",
                "empty preflight output did not use executor last_error")
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "preflight_fallback_executor");
        controlled.preflight_result = 0;
        orchestrator.set_executor(controlled);
        plan = build_valid_plan();
        why = "stale preflight-fallback diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_PREFLIGHT_FAILED) ||
            (why !=
             "register executor preflight failed without an error message") ||
            (controlled.preflight_count != 1) ||
            (controlled.execute_count != 0)) begin
            `uvm_fatal("REG_ORCH", "preflight fallback diagnostic changed")
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "execution_fallback_executor");
        controlled.execute_status = DPU_CFG_STATUS_EXECUTION_FAILED;
        orchestrator.set_executor(controlled);
        plan = build_valid_plan();
        why = "stale execution-fallback diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why != "register executor failed without an error message") ||
            (controlled.preflight_count != 1) ||
            (controlled.execute_count != 1) ||
            !controlled.preflight_saw_frozen_plan ||
            !controlled.execute_saw_preflight_plan) begin
            `uvm_fatal("REG_ORCH", "execution fallback diagnostic changed")
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "nonterminal_status_executor");
        controlled.execute_status = DPU_CFG_STATUS_NOT_EXECUTED;
        orchestrator.set_executor(controlled);
        plan = build_valid_plan();
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why !=
             "register executor returned an invalid terminal status") ||
            (controlled.preflight_count != 1) ||
            (controlled.execute_count != 1) ||
            !controlled.execute_saw_preflight_plan) begin
            `uvm_fatal("REG_ORCH", "nonterminal executor status escaped")
        end

        controlled = dpu_test_controlled_executor::type_id::create(
            "invalid_status_executor");
        controlled.execute_status = dpu_cfg_status_e'(32'hffff_ffff);
        orchestrator.set_executor(controlled);
        plan = build_valid_plan();
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why !=
             "register executor returned an invalid terminal status") ||
            (controlled.preflight_count != 1) ||
            (controlled.execute_count != 1)) begin
            `uvm_fatal("REG_ORCH", "invalid enum executor status escaped")
        end

        replaced_preflight_count = controlled.preflight_count;
        replaced_execute_count = controlled.execute_count;
        orchestrator.clear_executor();
        if (orchestrator.has_executor())
            `uvm_fatal("REG_ORCH", "clear_executor leaked replaced executor")
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale cleared-executor diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_NOT_EXECUTED) ||
            (why != {"validated register plan was not executed because no ",
                     "executor is installed"}) ||
            (controlled.preflight_count != replaced_preflight_count) ||
            (controlled.execute_count != replaced_execute_count)) begin
            `uvm_fatal("REG_ORCH", "cleared executor retained dispatch state")
        end

        replaced = dpu_test_controlled_executor::type_id::create(
            "replacement_executor");
        orchestrator.set_executor(replaced);
        if (!orchestrator.has_executor())
            `uvm_fatal("REG_ORCH", "replacement executor was not installed")
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_PLAN_INVALID;
        why = "stale replacement diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_SUCCEEDED) || (why != "") ||
            (replaced.preflight_count != 1) ||
            (replaced.execute_count != 1) ||
            !replaced.preflight_saw_frozen_plan ||
            !replaced.execute_saw_preflight_plan ||
            (controlled.preflight_count != replaced_preflight_count) ||
            (controlled.execute_count != replaced_execute_count)) begin
            `uvm_fatal("REG_ORCH", "executor replacement leaked prior state")
        end

        blocking = dpu_test_blocking_executor::type_id::create(
            "blocking_executor");
        handoff_replacement = dpu_test_controlled_executor::type_id::create(
            "handoff_replacement");
        handoff_replacement.prime_last_error(
            "replacement executor idle diagnostic");
        handoff_replacement.execute_status =
            DPU_CFG_STATUS_EXECUTION_FAILED;
        handoff_replacement.execute_error =
            "replacement executor execution failure";
        orchestrator.set_executor(blocking);
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale blocking handoff diagnostic";
        fork
            begin
                orchestrator.apply(plan, status, why);
            end
            begin
                blocking.execute_started.wait_ptrigger();
                orchestrator.set_executor(handoff_replacement);
                blocking.execute_release.trigger();
            end
        join
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why != blocking.failure_text) ||
            (blocking.preflight_count != 1) ||
            (blocking.execute_count != 1) ||
            (handoff_replacement.preflight_count != 0) ||
            (handoff_replacement.execute_count != 0)) begin
            `uvm_fatal("REG_ORCH", $sformatf(
                {"active executor changed during execute: status=%0d ",
                 "blocking=%0d/%0d replacement=%0d/%0d why=%s"},
                status, blocking.preflight_count, blocking.execute_count,
                handoff_replacement.preflight_count,
                handoff_replacement.execute_count, why))
        end

        plan = build_valid_plan();
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale replacement-next-apply diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why != "replacement executor execution failure") ||
            (blocking.preflight_count != 1) ||
            (blocking.execute_count != 1) ||
            (handoff_replacement.preflight_count != 1) ||
            (handoff_replacement.execute_count != 1)) begin
            `uvm_fatal("REG_ORCH",
                "replacement executor was not deferred until the next apply")
        end

        repeated = dpu_test_controlled_executor::type_id::create(
            "repeated_executor");
        repeated.execute_status = DPU_CFG_STATUS_EXECUTION_FAILED;
        repeated.execute_error = "first repeated apply failure";
        orchestrator.set_executor(repeated);
        plan = build_valid_plan();
        status = DPU_CFG_STATUS_SUCCEEDED;
        why = "stale first repeated-apply diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (why != "first repeated apply failure") ||
            !plan.is_frozen() || (repeated.preflight_count != 1) ||
            (repeated.execute_count != 1)) begin
            `uvm_fatal("REG_ORCH", "first repeated apply result changed")
        end

        repeated.execute_status = DPU_CFG_STATUS_SUCCEEDED;
        repeated.execute_error = "";
        status = DPU_CFG_STATUS_PLAN_INVALID;
        why = "stale second repeated-apply diagnostic";
        orchestrator.apply(plan, status, why);
        if ((status !== DPU_CFG_STATUS_SUCCEEDED) || (why != "") ||
            !plan.is_frozen() || (repeated.preflight_count != 2) ||
            (repeated.execute_count != 2) ||
            !repeated.preflight_saw_frozen_plan ||
            !repeated.execute_saw_preflight_plan) begin
            `uvm_fatal("REG_ORCH",
                "same executor/plan repeated apply leaked prior state")
        end
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        assert_original_operation_contract();
        assert_barrier_canonicalization();
        assert_kind_specific_fields();
        assert_pci_boundaries_and_invalid_enum();
        assert_copy_contract();
        assert_plan_validation_and_order();
        assert_plan_add_rejections();
        assert_plan_copy_failure_outputs();
        assert_plan_structural_rejections();
        assert_commit_rejections();
        assert_producer_epoch_requires_commit();
        assert_deterministic_ready_order();
        assert_phase_is_ready_priority_only();
        assert_large_plan_order();
        assert_spy_executor_contract();
        assert_spy_failure_configuration_snapshot();
        assert_orchestrator_contract();
        `uvm_info("REG_PLAN_TEST", "register plan contract passed", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass : dpu_reg_plan_test

`endif // DPU_REG_PLAN_TEST_SV
