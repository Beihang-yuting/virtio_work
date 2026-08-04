# Task 9 Empty-Queue Migration Sort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the VCS empty-queue sort diagnostic from migration restore without altering ownership transfer behavior.

**Architecture:** `claim_restored_queue_ownership()` collects temporary migration-record indexes and deletes them from highest to lowest. Sorting is necessary only with two or more indexes. Guarding the sort preserves multi-record order and prevents an empty queue method warning.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1, remote simulation host `ubuntu@10.11.10.53`.

---

### Task 1: Capture the red simulator diagnostic

**Files:**
- Test: remote `/tmp/task9-owner-red-run.log`

- [ ] **Step 1: Rebuild the focused migration test on the simulation host**

Run from `/home/ubuntu/virtio-dpu-fabric.sStEXW/project` in a VCS-enabled login shell:

```bash
"$VCS_HOME/bin/vcs" -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f filelists/dpu_common.f -f filelists/virtio_net.f +incdir+virtio_net_vip/tests virtio_net_vip/tests/virtio_migration_dirty_test.sv virtio_net_vip/tests/virtio_tb_top.sv -top virtio_tb_top -o /tmp/task9-owner-red-simv
```

- [ ] **Step 2: Run the focused migration test and verify the red condition**

```bash
setarch x86_64 -R /tmp/task9-owner-red-simv -no_save +UVM_TESTNAME=virtio_migration_dirty_test +UVM_VERBOSITY=UVM_LOW > /tmp/task9-owner-red-run.log 2>&1
test "$(grep -c 'Warning-\[DT-MCEQ\]' /tmp/task9-owner-red-run.log)" -gt 0
```

Expected: simulation exits zero but the log contains one or more `Warning-[DT-MCEQ]` messages at the unconditional empty-queue sort.

### Task 2: Guard the no-op sort

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:396`
- Test: remote `/tmp/task9-owner-green-run.log`

- [ ] **Step 1: Make the minimal implementation change**

Replace the unconditional sort with:

```systemverilog
        if (claim_indices.size() > 1)
            claim_indices.sort();
```

Keep the existing highest-to-lowest deletion loop unchanged. It prevents index shifts when multiple queue-owned mappings transfer.

- [ ] **Step 2: Rebuild and rerun the migration test**

Run the Task 1 build command with output `/tmp/task9-owner-green-simv`, then:

```bash
setarch x86_64 -R /tmp/task9-owner-green-simv -no_save +UVM_TESTNAME=virtio_migration_dirty_test +UVM_VERBOSITY=UVM_LOW > /tmp/task9-owner-green-run.log 2>&1
test "$(grep -c 'Warning-\[DT-MCEQ\]' /tmp/task9-owner-green-run.log)" -eq 0
grep -E 'UVM_(WARNING|ERROR|FATAL) *:' /tmp/task9-owner-green-run.log
```

Expected: simulation and no-warning check exit zero; the final UVM summary reports warning/error/fatal counts all zero.

- [ ] **Step 3: Rebuild and run the focused protocol regression**

```bash
"$VCS_HOME/bin/vcs" -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f filelists/dpu_common.f -f filelists/virtio_net.f +incdir+virtio_net_vip/tests virtio_net_vip/tests/virtio_protocol_test.sv virtio_net_vip/tests/virtio_tb_top.sv -top virtio_tb_top -o /tmp/task9-protocol-green-simv
setarch x86_64 -R /tmp/task9-protocol-green-simv -no_save +UVM_TESTNAME=virtio_protocol_test +UVM_VERBOSITY=UVM_LOW > /tmp/task9-protocol-green-run.log 2>&1
grep -E 'UVM_(WARNING|ERROR|FATAL) *:' /tmp/task9-protocol-green-run.log
```

Expected: exit zero and final UVM warning/error/fatal counts all zero. The test intentionally catches SVA failures while validating report routing; caught reports must not enter final severity counts.

- [ ] **Step 4: Run local repository checks**

```bash
git diff --check
bash -n scripts/vcs.sh
git status --short
```

Expected: no whitespace or shell-syntax error. `git status --short` lists only the intentional source change and the design/plan documents. Do not create a commit unless the user explicitly requests one.
