# DPU Register Plan and Executor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic, dependency-ordered DPU register-plan DAG plus an injectable executor boundary that can validate and inspect configuration work without claiming that a real DUT was programmed.

**Architecture:** Configuration modules contribute `dpu_reg_op` objects to one `dpu_reg_plan`; the plan takes defensive copies, performs complete structural and semantic validation, freezes its private graph, and produces a deterministic phase-then-ID topological order. `dpu_config_orchestrator` always freezes the plan first, then either reports `NOT_EXECUTED` when no executor is installed or calls one executor's complete preflight and execute contract. The initial `dpu_spy_reg_executor` records exact ordered operations and injected failures, while later PCIe/model executors can subclass the same interface without changing plans, services, or scenarios.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS on `10.11.10.53`, Bash, rsync, SSH.

---

## Scope and contract

This is subproject 1 from
`docs/superpowers/specs/2026-08-25-real-dut-service-configuration-design.md`.
It intentionally implements only:

- register-operation metadata for PCI config, AF/function MMIO, read/verify,
  polling, commit, and barrier operations;
- duplicate-ID, dependency, target, width, mask, phase, commit-producer, and
  cycle validation;
- deterministic topological ordering by lifecycle phase and then operation ID;
- plan freezing and defensive operation copies;
- an abstract executor, a spy executor, and orchestrator handoff;
- explicit plan-invalid, not-executed, preflight-failed, execution-failed, and
  succeeded outcomes.

It does not implement `dpu_device_cfg`, per-host PCIe domains, BDF/BAR/MSI-X
tables, notify/QSCH/DSCH/VIO/RDMA/VBLK builders, real PCIe access, scenario
enums, or the `virtio_bar_mem_wr_seq` payload fix. Those later features add
operations or executors through the interfaces established here. There is no
user-facing `PLAN_ONLY`, `MODEL`, or `REAL` enum.

Dependency edges are authoritative. Lifecycle phase is only the deterministic
priority among operations that are ready at the same time; it is not a global
phase barrier. This deliberately permits a later table image to depend on an
earlier commit, which is required for multi-stage DUT bring-up.

In this subproject, `owner` is an opaque canonical module/function/service path
because `dpu_device_cfg` and `dpu_service_key_t` arrive in subproject 2. Routing
is nevertheless execution-ready: every PCI config or BAR operation carries a
resolved `{host_id, segment_id, BDF, BAR}` target. Later typed builders format
the canonical owner path but do not change the plan or executor signatures.

All VCS runs must execute on `ubuntu@10.11.10.53` in a Bash login shell. Set
the password in an environment variable for each implementation session; do
not put it in Git configuration, URLs, scripts, or committed files:

```bash
export VCS_SIM_PASSWORD=123
```

Each RED/GREEN command below stages the current worktree, including
uncommitted test changes, in a fresh directory on the simulation host. The
stage includes local Git metadata because `scripts/check_deps.sh` verifies the
three pinned submodule revisions with `git -C ... rev-parse`; `build/` remains
excluded. Before staging, confirm that remote URLs contain no credentials.

## File responsibilities

- Create `dpu_common/src/dpu_reg_plan_types.sv`: generic operation, target,
  scope, lifecycle, operation-result, and configuration-result enums.
- Create `dpu_common/src/dpu_reg_op.sv`: one defensively copyable operation
  with resolved host/segment/BDF/BAR routing and target/access validation.
- Create `dpu_common/src/dpu_reg_plan.sv`: operation ownership, full DAG
  validation, freeze, and deterministic ordering.
- Create `dpu_common/src/dpu_reg_executor.sv`: executor extension contract and
  common last-error handling.
- Create `dpu_common/src/dpu_spy_reg_executor.sv`: ordered operation/result
  recording plus preflight and per-operation failure injection.
- Create `dpu_common/src/dpu_config_orchestrator.sv`: unconditional plan
  validation followed by optional executor dispatch.
- Modify `dpu_common/src/dpu_resource_pkg.sv`: include the new declarations in
  dependency order.
- Create `dpu_common/tests/dpu_reg_plan_test.sv`: focused operation, DAG,
  executor, failure, and extension-contract tests.
- Modify `filelists/tests.f` and `scripts/test_manifest.sh`: compile and run the
  focused test in maintained regressions.

### Task 1: Define and validate a complete register operation

**Files:**
- Create: `dpu_common/src/dpu_reg_plan_types.sv`
- Create: `dpu_common/src/dpu_reg_op.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Create: `dpu_common/tests/dpu_reg_plan_test.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`

- [ ] **Step 1: Add the focused test and its first failing operation contract**

Create `dpu_common/tests/dpu_reg_plan_test.sv`:

```systemverilog
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
```

Add the test immediately after the existing DPU manager test in
`filelists/tests.f`:

```text
dpu_common/tests/dpu_resource_manager_test.sv
dpu_common/tests/dpu_reg_plan_test.sv
```

Add it immediately after `dpu_resource_manager_test` in
`scripts/test_manifest.sh`:

```bash
VIRTIO_MAINTAINED_TESTS=(
  dpu_resource_manager_test
  dpu_reg_plan_test
  virtio_dut_caps_test
```

- [ ] **Step 2: Run the focused test on 53 and verify RED**

Run from the repository root:

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-op-red-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && TEST=dpu_reg_plan_test ./scripts/vcs.sh'"
```

Expected: VCS compilation fails because `dpu_reg_op`, `dpu_reg_phase_e`, and
the `DPU_REG_*` enum values do not exist. This is the intended RED failure.

- [ ] **Step 3: Add the generic plan/execution enums**

Create `dpu_common/src/dpu_reg_plan_types.sv`:

```systemverilog
`ifndef DPU_REG_PLAN_TYPES_SV
`define DPU_REG_PLAN_TYPES_SV

typedef enum int unsigned {
    DPU_REG_OP_INVALID = 0,
    DPU_REG_OP_PCI_CFG_WRITE,
    DPU_REG_OP_MMIO_WRITE,
    DPU_REG_OP_READ_VERIFY,
    DPU_REG_OP_POLL_UNTIL,
    DPU_REG_OP_COMMIT,
    DPU_REG_OP_BARRIER
} dpu_reg_op_kind_e;

typedef enum int unsigned {
    DPU_REG_TARGET_INVALID = 0,
    DPU_REG_TARGET_NONE,
    DPU_REG_TARGET_PCI_CONFIG,
    DPU_REG_TARGET_AF_BAR0,
    DPU_REG_TARGET_FUNCTION_BAR
} dpu_reg_target_space_e;

typedef enum int unsigned {
    DPU_REG_SCOPE_INVALID = 0,
    DPU_REG_SCOPE_SINGLE,
    DPU_REG_SCOPE_PER_HOST,
    DPU_REG_SCOPE_PER_FUNCTION,
    DPU_REG_SCOPE_PER_SERVICE
} dpu_reg_target_scope_e;

typedef enum int unsigned {
    DPU_REG_PHASE_INVALID = 0,
    DPU_REG_PHASE_BOOTSTRAP,
    DPU_REG_PHASE_TABLE,
    DPU_REG_PHASE_COMMIT,
    DPU_REG_PHASE_ENABLE
} dpu_reg_phase_e;

typedef enum int unsigned {
    DPU_REG_OP_RESULT_NOT_RUN = 0,
    DPU_REG_OP_RESULT_SUCCEEDED,
    DPU_REG_OP_RESULT_FAILED
} dpu_reg_op_result_e;

typedef enum int unsigned {
    DPU_CFG_STATUS_NOT_EXECUTED = 0,
    DPU_CFG_STATUS_PLAN_INVALID,
    DPU_CFG_STATUS_PREFLIGHT_FAILED,
    DPU_CFG_STATUS_EXECUTION_FAILED,
    DPU_CFG_STATUS_SUCCEEDED
} dpu_cfg_status_e;

`endif // DPU_REG_PLAN_TYPES_SV
```

- [ ] **Step 4: Implement the complete operation object and validation**

Create `dpu_common/src/dpu_reg_op.sv`:

```systemverilog
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

    function void copy_from(input dpu_reg_op rhs);
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

    function dpu_reg_op copy_op(input string copy_name = "dpu_reg_op_copy");
        dpu_reg_op copied;
        copied = new(copy_name);
        copied.copy_from(this);
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
            if ((target_space != DPU_REG_TARGET_NONE) ||
                (width_bytes != 0) || (payload != '0) ||
                (write_mask != '0) || (read_mask != '0)) begin
                why = $sformatf(
                    "operation %s barrier must not describe a register access", op_id);
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
        if ((target_space == DPU_REG_TARGET_PCI_CONFIG) &&
            (address > (64'd4096 - width_bytes))) begin
            why = $sformatf(
                "operation %s PCI config access exceeds 4KB space", op_id);
            return 0;
        end
        if (is_mmio_target() && !(width_bytes inside {1, 2, 4, 8})) begin
            why = $sformatf(
                "operation %s has unsupported MMIO access width %0d",
                op_id, width_bytes);
            return 0;
        end
        if ((address % width_bytes) != 0) begin
            why = $sformatf("operation %s address is not width-aligned", op_id);
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
        if (kind inside {
            DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_OP_MMIO_WRITE, DPU_REG_OP_COMMIT
        }) begin
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
        end
        else begin
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
        end
        if ((kind == DPU_REG_OP_POLL_UNTIL) && (max_attempts == 0)) begin
            why = $sformatf(
                "operation %s poll attempt count must be nonzero", op_id);
            return 0;
        end
        if ((kind == DPU_REG_OP_COMMIT) &&
            (phase != DPU_REG_PHASE_COMMIT)) begin
            why = $sformatf(
                "operation %s commit must use the commit phase", op_id);
            return 0;
        end
        return 1;
    endfunction
endclass : dpu_reg_op

`endif // DPU_REG_OP_SV
```

Update `dpu_common/src/dpu_resource_pkg.sv` so the new declarations appear
immediately after the existing resource types:

```systemverilog
  `include "dpu_resource_types.sv"
  `include "dpu_reg_plan_types.sv"
  `include "dpu_reg_op.sv"
  `include "dpu_dut_caps.sv"
```

- [ ] **Step 5: Run the focused test on 53 and verify GREEN**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-op-green-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && mkdir -p build && TEST=dpu_reg_plan_test ./scripts/vcs.sh > build/dpu_reg_plan_test.log 2>&1 && ./scripts/strict_log_check.sh sim build/dpu_reg_plan_test.log'"
```

Expected: exit status 0; the log contains `register operation contract passed`
and exactly one UVM summary with zero warnings, errors, and fatals.

- [ ] **Step 6: Commit the operation contract**

```bash
git add dpu_common/src/dpu_reg_plan_types.sv \
  dpu_common/src/dpu_reg_op.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_reg_plan_test.sv \
  filelists/tests.f scripts/test_manifest.sh
git commit -m "feat: define DPU register operations"
```

### Task 2: Add full DAG validation, freeze, and deterministic ordering

**Files:**
- Create: `dpu_common/src/dpu_reg_plan.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_reg_plan_test.sv`

- [ ] **Step 1: Add failing DAG and freeze tests**

Add these helpers and checks inside `dpu_reg_plan_test`, immediately before
`run_phase`:

```systemverilog
    function automatic dpu_reg_plan build_valid_plan();
        dpu_reg_plan plan;
        dpu_reg_op op;
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

        op = make_mmio_write(
            "notify_verify", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.kind = DPU_REG_OP_READ_VERIFY;
        op.write_mask = '0;
        op.expected_value = 64'h0000_0000_1122_3344;
        op.read_mask = 64'h0000_0000_ffff_ffff;
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

        op = make_mmio_write(
            "bootstrap", DPU_REG_PHASE_BOOTSTRAP,
            64'h0000_0000_0000_1010, 64'h0000_0000_5555_aaaa
        );
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)

        return plan;
    endfunction

    task assert_plan_validation_and_order();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op ordered[$];
        string expected_ids[$] = '{
            "bootstrap", "notify_table", "notify_verify",
            "notify_commit", "enable"
        };
        string why;

        plan = build_valid_plan();
        if (!plan.freeze(why))
            `uvm_fatal("REG_PLAN", $sformatf("valid plan rejected: %s", why))
        if (!plan.is_frozen())
            `uvm_fatal("REG_PLAN", "successful freeze did not freeze the plan")
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

        plan = dpu_reg_plan::type_id::create("duplicate_plan");
        op = make_mmio_write(
            "duplicate", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.add_operation(op, why) ||
            (why != "duplicate register operation ID duplicate")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "duplicate ID was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("missing_dependency_plan");
        op = make_mmio_write(
            "missing_user", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.add_dependency("does_not_exist");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation missing_user depends on unknown operation does_not_exist")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "missing dependency was not rejected precisely: %s", why))
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
            (why != "register plan contains a dependency cycle")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "cycle was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("commit_without_producer");
        op = make_mmio_write(
            "bootstrap", DPU_REG_PHASE_BOOTSTRAP,
            64'h0000_0000_0000_1010, 64'h0
        );
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "orphan_commit", DPU_REG_PHASE_COMMIT,
            64'h0000_0000_0002_0044, 64'h1
        );
        op.kind = DPU_REG_OP_COMMIT;
        op.commit_group = "vio.notify";
        op.add_dependency("bootstrap");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        if (plan.freeze(why) ||
            (why != "operation orphan_commit has no table producer in commit group vio.notify")) begin
            `uvm_fatal("REG_PLAN", $sformatf(
                "orphan commit was not rejected precisely: %s", why))
        end

        plan = dpu_reg_plan::type_id::create("partial_commit_plan");
        op = make_mmio_write(
            "table_a", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h1
        );
        op.commit_group = "vio.notify";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "table_b", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8004, 64'h2
        );
        op.commit_group = "vio.notify";
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "partial_commit", DPU_REG_PHASE_COMMIT,
            64'h0000_0000_0002_0044, 64'h1
        );
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
    endtask

    task assert_deterministic_ready_order();
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op ordered[$];
        string expected_ids[$] = '{"bootstrap", "a_table", "z_table"};
        string why;

        plan = dpu_reg_plan::type_id::create("deterministic_plan");
        op = make_mmio_write(
            "z_table", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8010, 64'h0
        );
        op.add_dependency("bootstrap");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "a_table", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.add_dependency("bootstrap");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_PLAN", why)
        op = make_mmio_write(
            "bootstrap", DPU_REG_PHASE_BOOTSTRAP,
            64'h0000_0000_0000_1010, 64'h0
        );
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
```

Update `run_phase` to call both new checks after the operation check:

```systemverilog
        assert_operation_contract();
        assert_plan_validation_and_order();
        assert_deterministic_ready_order();
```

- [ ] **Step 2: Run the focused test on 53 and verify RED**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-plan-red-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && TEST=dpu_reg_plan_test ./scripts/vcs.sh'"
```

Expected: VCS compilation fails because `dpu_reg_plan` is undefined.

- [ ] **Step 3: Implement the register-plan DAG**

Create `dpu_common/src/dpu_reg_plan.sv`:

```systemverilog
`ifndef DPU_REG_PLAN_SV
`define DPU_REG_PLAN_SV

class dpu_reg_plan extends uvm_object;
    `uvm_object_utils(dpu_reg_plan)

    protected dpu_reg_op operations_by_id[string];
    protected string ordered_ids[$];
    protected bit frozen;

    function new(string name = "dpu_reg_plan");
        super.new(name);
        frozen = 0;
    endfunction

    function int unsigned operation_count();
        return operations_by_id.num();
    endfunction

    function bit is_frozen();
        return frozen;
    endfunction

    function bit add_operation(input dpu_reg_op operation, output string why);
        why = "";
        if (frozen) begin
            why = "register plan is frozen";
            return 0;
        end
        if (operation == null) begin
            why = "cannot add a null register operation";
            return 0;
        end
        if (operation.op_id == "") begin
            why = "register operation ID must not be empty";
            return 0;
        end
        if (operations_by_id.exists(operation.op_id)) begin
            why = $sformatf(
                "duplicate register operation ID %s", operation.op_id);
            return 0;
        end
        operations_by_id[operation.op_id] = operation.copy_op(operation.op_id);
        return 1;
    endfunction

    function bit find_operation(
        input string op_id,
        output dpu_reg_op operation
    );
        if (!operations_by_id.exists(op_id)) begin
            operation = null;
            return 0;
        end
        operation = operations_by_id[op_id].copy_op(op_id);
        return 1;
    endfunction

    protected function bit validate_operations(output string why);
        bit seen_dependency[string];
        bit producer_found;
        string dependency_id;

        why = "";
        if (operations_by_id.num() == 0) begin
            why = "register plan contains no operations";
            return 0;
        end
        foreach (operations_by_id[op_id]) begin
            if (!operations_by_id[op_id].validate(why))
                return 0;

            seen_dependency.delete();
            foreach (operations_by_id[op_id].dependencies[index]) begin
                dependency_id = operations_by_id[op_id].dependencies[index];
                if (seen_dependency.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s repeats dependency %s",
                        op_id, dependency_id);
                    return 0;
                end
                seen_dependency[dependency_id] = 1;
                if (!operations_by_id.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s depends on unknown operation %s",
                        op_id, dependency_id);
                    return 0;
                end
            end

            if (operations_by_id[op_id].kind == DPU_REG_OP_COMMIT) begin
                if (operations_by_id[op_id].commit_group == "") begin
                    why = $sformatf(
                        "operation %s commit group must not be empty", op_id);
                    return 0;
                end
                producer_found = 0;
                foreach (operations_by_id[producer_id]) begin
                    if ((operations_by_id[producer_id].phase ==
                         DPU_REG_PHASE_TABLE) &&
                        (operations_by_id[producer_id].kind ==
                         DPU_REG_OP_MMIO_WRITE) &&
                        (operations_by_id[producer_id].commit_group ==
                         operations_by_id[op_id].commit_group)) begin
                        producer_found = 1;
                        if (!seen_dependency.exists(producer_id)) begin
                            why = $sformatf(
                                "operation %s does not depend on commit-group producer %s",
                                op_id, producer_id);
                            return 0;
                        end
                    end
                end
                if (!producer_found) begin
                    why = $sformatf(
                        "operation %s has no table producer in commit group %s",
                        op_id, operations_by_id[op_id].commit_group);
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    protected function bit build_topological_order(
        ref string result[$],
        output string why
    );
        int unsigned indegree[string];
        bit emitted[string];
        string candidate_id;
        string dependency_id;

        result.delete();
        why = "";
        foreach (operations_by_id[op_id]) begin
            indegree[op_id] = operations_by_id[op_id].dependencies.size();
            emitted[op_id] = 0;
        end

        while (result.size() < operations_by_id.num()) begin
            candidate_id = "";
            foreach (operations_by_id[op_id]) begin
                if (!emitted[op_id] && (indegree[op_id] == 0)) begin
                    if (candidate_id == "") begin
                        candidate_id = op_id;
                    end
                    else if ((operations_by_id[op_id].phase <
                              operations_by_id[candidate_id].phase) ||
                             ((operations_by_id[op_id].phase ==
                               operations_by_id[candidate_id].phase) &&
                              (op_id.compare(candidate_id) < 0))) begin
                        candidate_id = op_id;
                    end
                end
            end
            if (candidate_id == "") begin
                why = "register plan contains a dependency cycle";
                return 0;
            end

            emitted[candidate_id] = 1;
            result.push_back(candidate_id);
            foreach (operations_by_id[op_id]) begin
                if (!emitted[op_id]) begin
                    foreach (operations_by_id[op_id].dependencies[index]) begin
                        dependency_id =
                            operations_by_id[op_id].dependencies[index];
                        if (dependency_id == candidate_id)
                            indegree[op_id]--;
                    end
                end
            end
        end
        return 1;
    endfunction

    function bit validate(output string why);
        string ignored_order[$];
        if (!validate_operations(why))
            return 0;
        return build_topological_order(ignored_order, why);
    endfunction

    function bit freeze(output string why);
        string new_order[$];
        why = "";
        if (frozen)
            return 1;
        if (!validate_operations(why))
            return 0;
        if (!build_topological_order(new_order, why))
            return 0;
        ordered_ids = new_order;
        frozen = 1;
        return 1;
    endfunction

    function bit ordered_operations(
        ref dpu_reg_op operations[$],
        output string why
    );
        operations.delete();
        why = "";
        if (!frozen) begin
            why = "register plan must be frozen before retrieving order";
            return 0;
        end
        foreach (ordered_ids[index]) begin
            operations.push_back(
                operations_by_id[ordered_ids[index]].copy_op(ordered_ids[index])
            );
        end
        return 1;
    endfunction
endclass : dpu_reg_plan

`endif // DPU_REG_PLAN_SV
```

Add the plan after the operation in `dpu_common/src/dpu_resource_pkg.sv`:

```systemverilog
  `include "dpu_reg_plan_types.sv"
  `include "dpu_reg_op.sv"
  `include "dpu_reg_plan.sv"
```

- [ ] **Step 4: Run the focused test on 53 and verify GREEN**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-plan-green-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && mkdir -p build && TEST=dpu_reg_plan_test ./scripts/vcs.sh > build/dpu_reg_plan_test.log 2>&1 && ./scripts/strict_log_check.sh sim build/dpu_reg_plan_test.log'"
```

Expected: exit status 0. The valid graph orders as bootstrap → table → verify
→ commit → enable; duplicate IDs, missing dependencies, orphan/partial
commits, and a cycle are rejected; the strict log checker reports no
warning/error/fatal.

- [ ] **Step 5: Commit the DAG implementation**

```bash
git add dpu_common/src/dpu_reg_plan.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_reg_plan_test.sv
git commit -m "feat: validate DPU register plan DAGs"
```

### Task 3: Add the executor interface and failure-aware spy

**Files:**
- Create: `dpu_common/src/dpu_reg_executor.sv`
- Create: `dpu_common/src/dpu_spy_reg_executor.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_reg_plan_test.sv`

- [ ] **Step 1: Add failing spy ordering and failure tests**

Add this method inside `dpu_reg_plan_test`, before `run_phase`:

```systemverilog
    task assert_spy_executor_contract();
        dpu_reg_plan plan;
        dpu_spy_reg_executor spy;
        dpu_reg_op recorded;
        dpu_reg_op_result_e result;
        dpu_cfg_status_e status;
        string why;

        plan = build_valid_plan();
        if (!plan.freeze(why))
            `uvm_fatal("REG_EXEC", why)
        spy = dpu_spy_reg_executor::type_id::create("spy");
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", $sformatf("spy preflight failed: %s", why))
        if (!spy.preflight_history_was_empty())
            `uvm_fatal("REG_EXEC", "spy recorded an operation before preflight")
        spy.execute(plan, status);
        if (status != DPU_CFG_STATUS_SUCCEEDED)
            `uvm_fatal("REG_EXEC", $sformatf(
                "spy execution failed: %s", spy.last_error()))
        if (spy.record_count() != 5)
            `uvm_fatal("REG_EXEC", "spy did not record all five operations")
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
            `uvm_fatal("REG_EXEC", "spy did not preserve table target/payload/result")
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

        spy.reset_history();
        spy.fail_operation("notify_table");
        if (!spy.preflight(plan, why))
            `uvm_fatal("REG_EXEC", why)
        spy.execute(plan, status);
        if (status != DPU_CFG_STATUS_EXECUTION_FAILED)
            `uvm_fatal("REG_EXEC", "injected operation failure did not fail execution")
        if (spy.record_count() != 2)
            `uvm_fatal("REG_EXEC", "spy executed commit/enable after table failure")
        if (!spy.record_at(1, recorded, result, why))
            `uvm_fatal("REG_EXEC", why)
        if ((recorded.op_id != "notify_table") ||
            (result != DPU_REG_OP_RESULT_FAILED)) begin
            `uvm_fatal("REG_EXEC", "spy did not record the injected table failure")
        end
        if (spy.last_error() !=
            "injected execution failure at operation notify_table") begin
            `uvm_fatal("REG_EXEC", $sformatf(
                "unexpected spy failure text: %s", spy.last_error()))
        end
    endtask
```

Call it from `run_phase` after the plan ordering checks:

```systemverilog
        assert_spy_executor_contract();
```

- [ ] **Step 2: Run the focused test on 53 and verify RED**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-spy-red-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && TEST=dpu_reg_plan_test ./scripts/vcs.sh'"
```

Expected: VCS compilation fails because `dpu_spy_reg_executor` and the
executor contract are undefined.

- [ ] **Step 3: Define the subclassable executor contract**

Create `dpu_common/src/dpu_reg_executor.sv`:

```systemverilog
`ifndef DPU_REG_EXECUTOR_SV
`define DPU_REG_EXECUTOR_SV

virtual class dpu_reg_executor extends uvm_object;
    protected string last_error_text;

    function new(string name = "dpu_reg_executor");
        super.new(name);
        last_error_text = "";
    endfunction

    protected function void set_last_error(input string why);
        last_error_text = why;
    endfunction

    function string last_error();
        return last_error_text;
    endfunction

    pure virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );

    pure virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
endclass : dpu_reg_executor

`endif // DPU_REG_EXECUTOR_SV
```

- [ ] **Step 4: Implement the spy executor**

Create `dpu_common/src/dpu_spy_reg_executor.sv`:

```systemverilog
`ifndef DPU_SPY_REG_EXECUTOR_SV
`define DPU_SPY_REG_EXECUTOR_SV

class dpu_spy_reg_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_spy_reg_executor)

    protected dpu_reg_op recorded_operations[$];
    protected dpu_reg_op_result_e recorded_results[$];
    protected string failed_operation_id;
    protected string preflight_failure_text;
    protected bit preflight_called;
    protected bit preflight_empty_history;

    function new(string name = "dpu_spy_reg_executor");
        super.new(name);
        recorded_operations.delete();
        recorded_results.delete();
        failed_operation_id = "";
        preflight_failure_text = "";
        preflight_called = 0;
        preflight_empty_history = 0;
    endfunction

    function void reset_history();
        recorded_operations.delete();
        recorded_results.delete();
        preflight_called = 0;
        preflight_empty_history = 0;
        failed_operation_id = "";
        preflight_failure_text = "";
        set_last_error("");
    endfunction

    function void fail_operation(input string op_id);
        failed_operation_id = op_id;
    endfunction

    function void fail_preflight(input string why);
        preflight_failure_text = why;
    endfunction

    function int unsigned record_count();
        return recorded_operations.size();
    endfunction

    function bit preflight_history_was_empty();
        return preflight_empty_history;
    endfunction

    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        dpu_reg_op injected_failure_operation;

        preflight_called = 1;
        preflight_empty_history = (recorded_operations.size() == 0);
        set_last_error("");
        if (plan == null) begin
            why = "spy executor received a null register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.is_frozen()) begin
            why = "spy executor requires a frozen register plan";
            set_last_error(why);
            return 0;
        end
        if (preflight_failure_text != "") begin
            why = preflight_failure_text;
            set_last_error(why);
            return 0;
        end
        if ((failed_operation_id != "") &&
            !plan.find_operation(failed_operation_id,
                                 injected_failure_operation)) begin
            why = $sformatf(
                "spy failure operation %s is not in the register plan",
                failed_operation_id);
            set_last_error(why);
            return 0;
        end
        why = "";
        return 1;
    endfunction

    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        dpu_reg_op ordered[$];
        string why;

        status = DPU_CFG_STATUS_EXECUTION_FAILED;
        if (!preflight_called) begin
            set_last_error("spy executor execute called before preflight");
            return;
        end
        if (!plan.ordered_operations(ordered, why)) begin
            set_last_error(why);
            return;
        end

        foreach (ordered[index]) begin
            recorded_operations.push_back(
                ordered[index].copy_op(ordered[index].op_id)
            );
            if (ordered[index].op_id == failed_operation_id) begin
                recorded_results.push_back(DPU_REG_OP_RESULT_FAILED);
                set_last_error($sformatf(
                    "injected execution failure at operation %s",
                    ordered[index].op_id));
                return;
            end
            recorded_results.push_back(DPU_REG_OP_RESULT_SUCCEEDED);
        end
        set_last_error("");
        status = DPU_CFG_STATUS_SUCCEEDED;
    endtask

    function bit record_at(
        input int unsigned index,
        output dpu_reg_op operation,
        output dpu_reg_op_result_e result,
        output string why
    );
        if (index >= recorded_operations.size()) begin
            operation = null;
            result = DPU_REG_OP_RESULT_NOT_RUN;
            why = $sformatf("spy record index %0d is out of range", index);
            return 0;
        end
        operation = recorded_operations[index].copy_op(
            recorded_operations[index].op_id
        );
        result = recorded_results[index];
        why = "";
        return 1;
    endfunction
endclass : dpu_spy_reg_executor

`endif // DPU_SPY_REG_EXECUTOR_SV
```

Include both files after `dpu_reg_plan.sv` in
`dpu_common/src/dpu_resource_pkg.sv`:

```systemverilog
  `include "dpu_reg_plan.sv"
  `include "dpu_reg_executor.sv"
  `include "dpu_spy_reg_executor.sv"
  `include "dpu_dut_caps.sv"
```

- [ ] **Step 5: Run the focused test on 53 and verify GREEN**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-spy-green-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && mkdir -p build && TEST=dpu_reg_plan_test ./scripts/vcs.sh > build/dpu_reg_plan_test.log 2>&1 && ./scripts/strict_log_check.sh sim build/dpu_reg_plan_test.log'"
```

Expected: the spy preflight observes an empty history, all five operation
targets/payloads/results are recorded in exact order, and an injected table
failure prevents both commit and enable from executing. Strict checking exits
0.

- [ ] **Step 6: Commit the executor seam and spy**

```bash
git add dpu_common/src/dpu_reg_executor.sv \
  dpu_common/src/dpu_spy_reg_executor.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_reg_plan_test.sv
git commit -m "feat: add spy DPU register executor"
```

### Task 4: Add orchestrator handoff and prove custom-executor extensibility

**Files:**
- Create: `dpu_common/src/dpu_config_orchestrator.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_reg_plan_test.sv`

- [ ] **Step 1: Add a user-defined executor in the test**

Add this class between the package imports and `dpu_reg_plan_test`. It uses
only the public executor/plan contracts:

```systemverilog
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
        why = preflight_saw_frozen_plan ? "" : "custom executor needs frozen plan";
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
```

- [ ] **Step 2: Add failing orchestrator outcome tests**

Add this method inside `dpu_reg_plan_test`, before `run_phase`:

```systemverilog
    task assert_orchestrator_contract();
        dpu_config_orchestrator orchestrator;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_spy_reg_executor spy;
        dpu_test_custom_executor custom;
        dpu_cfg_status_e status;
        string why;

        orchestrator = dpu_config_orchestrator::type_id::create("orchestrator");

        plan = build_valid_plan();
        orchestrator.clear_executor();
        orchestrator.apply(plan, status, why);
        if ((status != DPU_CFG_STATUS_NOT_EXECUTED) || !plan.is_frozen() ||
            (why != "validated register plan was not executed because no executor is installed")) begin
            `uvm_fatal("REG_ORCH", $sformatf(
                "plan-only handoff reported the wrong result: status=%0d why=%s",
                status, why))
        end

        spy = dpu_spy_reg_executor::type_id::create("invalid_plan_spy");
        orchestrator.set_executor(spy);
        plan = dpu_reg_plan::type_id::create("invalid_plan");
        op = make_mmio_write(
            "invalid", DPU_REG_PHASE_TABLE,
            64'h0000_0000_0002_8000, 64'h0
        );
        op.add_dependency("missing");
        if (!plan.add_operation(op, why))
            `uvm_fatal("REG_ORCH", why)
        orchestrator.apply(plan, status, why);
        if ((status != DPU_CFG_STATUS_PLAN_INVALID) ||
            (spy.record_count() != 0) ||
            (why != "operation invalid depends on unknown operation missing")) begin
            `uvm_fatal("REG_ORCH", "invalid plan reached executor dispatch")
        end

        spy = dpu_spy_reg_executor::type_id::create("preflight_spy");
        spy.fail_preflight("injected preflight rejection");
        orchestrator.set_executor(spy);
        plan = build_valid_plan();
        orchestrator.apply(plan, status, why);
        if ((status != DPU_CFG_STATUS_PREFLIGHT_FAILED) ||
            (spy.record_count() != 0) ||
            (why != "injected preflight rejection")) begin
            `uvm_fatal("REG_ORCH", "preflight rejection did not block execution")
        end

        spy = dpu_spy_reg_executor::type_id::create("execution_spy");
        spy.fail_operation("notify_table");
        orchestrator.set_executor(spy);
        plan = build_valid_plan();
        orchestrator.apply(plan, status, why);
        if ((status != DPU_CFG_STATUS_EXECUTION_FAILED) ||
            (spy.record_count() != 2) ||
            (why != "injected execution failure at operation notify_table")) begin
            `uvm_fatal("REG_ORCH", "executor failure was not propagated precisely")
        end

        custom = dpu_test_custom_executor::type_id::create("custom");
        orchestrator.set_executor(custom);
        plan = build_valid_plan();
        orchestrator.apply(plan, status, why);
        if ((status != DPU_CFG_STATUS_SUCCEEDED) || (why != "") ||
            (custom.preflight_count != 1) || (custom.execute_count != 1) ||
            !custom.preflight_saw_frozen_plan) begin
            `uvm_fatal("REG_ORCH", "custom executor did not plug into orchestrator")
        end
    endtask
```

Call it from `run_phase` after the spy check:

```systemverilog
        assert_orchestrator_contract();
```

- [ ] **Step 3: Run the focused test on 53 and verify RED**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-orchestrator-red-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && TEST=dpu_reg_plan_test ./scripts/vcs.sh'"
```

Expected: VCS compilation fails because `dpu_config_orchestrator` is
undefined. The custom executor itself must compile against the public abstract
interface before the orchestrator is added.

- [ ] **Step 4: Implement unconditional validation and optional dispatch**

Create `dpu_common/src/dpu_config_orchestrator.sv`:

```systemverilog
`ifndef DPU_CONFIG_ORCHESTRATOR_SV
`define DPU_CONFIG_ORCHESTRATOR_SV

class dpu_config_orchestrator extends uvm_object;
    `uvm_object_utils(dpu_config_orchestrator)

    protected dpu_reg_executor executor;

    function new(string name = "dpu_config_orchestrator");
        super.new(name);
        executor = null;
    endfunction

    function void set_executor(input dpu_reg_executor new_executor);
        executor = new_executor;
    endfunction

    function void clear_executor();
        executor = null;
    endfunction

    function bit has_executor();
        return executor != null;
    endfunction

    task apply(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status,
        output string why
    );
        status = DPU_CFG_STATUS_PLAN_INVALID;
        why = "";
        if (plan == null) begin
            why = "configuration orchestrator received a null register plan";
            return;
        end
        if (!plan.freeze(why))
            return;

        if (executor == null) begin
            status = DPU_CFG_STATUS_NOT_EXECUTED;
            why = "validated register plan was not executed because no executor is installed";
            return;
        end
        if (!executor.preflight(plan, why)) begin
            status = DPU_CFG_STATUS_PREFLIGHT_FAILED;
            if (why == "")
                why = executor.last_error();
            if (why == "")
                why = "register executor preflight failed without an error message";
            return;
        end

        executor.execute(plan, status);
        case (status)
            DPU_CFG_STATUS_SUCCEEDED: why = "";
            DPU_CFG_STATUS_EXECUTION_FAILED: begin
                why = executor.last_error();
                if (why == "")
                    why = "register executor failed without an error message";
            end
            default: begin
                status = DPU_CFG_STATUS_EXECUTION_FAILED;
                why = "register executor returned an invalid terminal status";
            end
        endcase
    endtask
endclass : dpu_config_orchestrator

`endif // DPU_CONFIG_ORCHESTRATOR_SV
```

Include it after the spy executor in `dpu_common/src/dpu_resource_pkg.sv`:

```systemverilog
  `include "dpu_reg_executor.sv"
  `include "dpu_spy_reg_executor.sv"
  `include "dpu_config_orchestrator.sv"
  `include "dpu_dut_caps.sv"
```

- [ ] **Step 5: Run the focused and existing DPU tests on 53 and verify GREEN**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-orchestrator-green-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && mkdir -p build && TEST=dpu_reg_plan_test ./scripts/vcs.sh > build/dpu_reg_plan_test.log 2>&1 && ./scripts/strict_log_check.sh sim build/dpu_reg_plan_test.log && TEST=dpu_resource_manager_test ./scripts/vcs.sh > build/dpu_resource_manager_test.log 2>&1 && ./scripts/strict_log_check.sh sim build/dpu_resource_manager_test.log'"
```

Expected: both tests exit 0 with one clean UVM summary each. A missing executor
returns `NOT_EXECUTED`; invalid plans and failed preflight execute zero
operations; an executor failure is preserved; the independent custom subclass
succeeds without changes to plan or orchestrator code.

- [ ] **Step 6: Commit the orchestrator**

```bash
git add dpu_common/src/dpu_config_orchestrator.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_reg_plan_test.sv
git commit -m "feat: add DPU configuration orchestrator"
```

### Task 5: Verify the complete first-stage boundary

**Files:**
- Verify: `dpu_common/src/dpu_reg_plan_types.sv`
- Verify: `dpu_common/src/dpu_reg_op.sv`
- Verify: `dpu_common/src/dpu_reg_plan.sv`
- Verify: `dpu_common/src/dpu_reg_executor.sv`
- Verify: `dpu_common/src/dpu_spy_reg_executor.sv`
- Verify: `dpu_common/src/dpu_config_orchestrator.sv`
- Verify: `dpu_common/tests/dpu_reg_plan_test.sv`
- Verify: `filelists/tests.f`
- Verify: `scripts/test_manifest.sh`

- [ ] **Step 1: Run local structural and shell checks**

```bash
git diff --check
bash scripts/tests/strict_log_check_test.sh
bash scripts/tests/strict_regression_test.sh
source scripts/test_manifest.sh
test "${#VIRTIO_MAINTAINED_TESTS[@]}" -eq 19
test "${VIRTIO_MAINTAINED_TESTS[1]}" = dpu_reg_plan_test
```

Expected: `git diff --check` is silent; both shell test scripts print `PASSED`;
the manifest assertions exit 0.

- [ ] **Step 2: Audit the public boundary for forbidden first-stage coupling**

```bash
rg -n "PLAN_ONLY|DPU_.*MODEL|DPU_.*REAL|virtio_bar_mem_wr_seq|cosim_control|notify|QSCH|DSCH|RDMA|VBLK" \
  dpu_common/src/dpu_reg_plan_types.sv \
  dpu_common/src/dpu_reg_op.sv \
  dpu_common/src/dpu_reg_plan.sv \
  dpu_common/src/dpu_reg_executor.sv \
  dpu_common/src/dpu_spy_reg_executor.sv \
  dpu_common/src/dpu_config_orchestrator.sv
```

Expected: no matches. The generic layer knows operation semantics and targets,
not business scenarios, service kinds, concrete tables, or transport sequences.

- [ ] **Step 3: Stage the final committed tree on 53**

```bash
sim_stage=$(SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/dpu-reg-plan-final-XXXXXX")
SSHPASS="$VCS_SIM_PASSWORD" rsync -a --exclude=build \
  -e "sshpass -e ssh" ./ "ubuntu@10.11.10.53:${sim_stage}/"
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && ./scripts/check_deps.sh'"
```

Expected: dependency checking exits 0 in the clean staging directory.

- [ ] **Step 4: Run the full strict regression on 53**

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && mkdir -p build/strict && ./scripts/strict_regression.sh | tee build/strict/final-summary.log; test \${PIPESTATUS[0]} -eq 0'"
```

Expected final line:

```text
STRICT_REGRESSION PASS tests=19
```

- [ ] **Step 5: Independently inspect focused and final logs**

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && ./scripts/strict_log_check.sh compile build/strict/compile.log && ./scripts/strict_log_check.sh sim build/strict/dpu_reg_plan_test.log && grep -F \"STRICT_RESULT dpu_reg_plan_test PASS\" build/strict/final-summary.log'"
```

Expected: both strict log checks exit 0 and grep prints exactly:

```text
STRICT_RESULT dpu_reg_plan_test PASS
```

- [ ] **Step 6: Confirm final history and worktree state**

```bash
git log -5 --oneline
git status --short
git diff --check HEAD~4..HEAD
```

Expected: history contains the four task commits, `git status --short` is
empty, and the final diff check is silent. No real-DUT execution claim is made:
this stage proves only plan correctness and executor extensibility.
