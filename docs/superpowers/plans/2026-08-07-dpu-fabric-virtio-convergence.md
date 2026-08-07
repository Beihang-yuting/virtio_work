# DPU Fabric Virtio Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the remote `d939f08`-based Virtio VIP branch into a warning-clean, leak-free VCS/TLM build whose 17 maintained tests all finish within 180 seconds.

**Architecture:** Keep the existing DPU Fabric and Virtio architecture intact. Add one canonical test manifest and a strict compile/simulation log gate, then fix each observed warning or failure at its ownership boundary: event sampling, agent lifecycle, PCIe completion metadata, host-memory teardown, and bounded bandwidth stress.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1, Bash, GNU Make, Git submodules.

---

## Execution context

Work only in:

```text
/home/ryan/workspace/ryan/virtio_work/.worktrees/dpu-fabric-virtio-hardening
```

Run all VCS verification on `ubuntu@10.11.10.53` through a bash login shell. Keep the simulation password outside the repository in `VCS_SIM_PASSWORD`, and use `SSHPASS="$VCS_SIM_PASSWORD" sshpass -e` for non-interactive SSH/rsync.

For intermediate VCS runs, synchronize tracked source into the already initialized remote validation copy without deleting its Git metadata or build cache:

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e rsync -a \
  --exclude='.git' --exclude='build' --exclude='csrc' \
  ./ ubuntu@10.11.10.53:/home/ubuntu/test_cosim/virtio-remote.Ku3iG3/
```

The PCIe submodule task includes an explicit Git bundle transfer so the final remote `check-deps` sees the exact new submodule commit rather than only copied working-tree bytes.

## File map

- `scripts/test_manifest.sh`: sole maintained-test name list.
- `scripts/strict_log_check.sh`: deterministic compile/simulation log policy.
- `scripts/tests/strict_log_check_test.sh`: shell-level tests for the log policy.
- `scripts/strict_regression.sh`: compile-once, run-many strict regression driver.
- `scripts/vcs.sh`, `Makefile`, `filelists/tests.f`: consume the manifest and complete filelist.
- `virtio_net_vip/src/shared/virtio_wait_policy.sv`: timeout result isolation from forked processes.
- `virtio_net_vip/src/env/virtio_concurrency_controller.sv`: worker-owned parallel result arrays.
- `virtio_net_vip/src/env/virtio_dynamic_reconfig.sv`: correctly typed control-class values.
- `virtio_net_vip/src/agent/virtio_driver_agent.sv`: active/passive lifecycle validation.
- `virtio_net_vip/src/env/virtio_net_env.sv`: optional TLM adapter binding.
- `virtio_net_vip/tests/virtio_monitor_routing_test.sv`: optional-adapter and deterministic-SVA coverage.
- `virtio_net_vip/ext/pcie_tl_vip/.../pcie_tl_ep_driver.sv`: completion metadata owner.
- `virtio_net_vip/tests/virtio_e2e_test.sv`: PCIe metadata regression and explicit allocation teardown.
- `virtio_net_vip/tests/virtio_smoke_test.sv`: maintained TLM smoke flow.
- `virtio_net_vip/tests/virtio_dual_test.sv`: bounded default bandwidth workload and opt-in long stress.
- `README.md`, `docs/virtio_net_vip_manual.md`: accurate support and acceptance documentation.

---

### Task 1: Canonical 17-test manifest and strict log gate

**Files:**
- Create: `scripts/test_manifest.sh`
- Create: `scripts/strict_log_check.sh`
- Create: `scripts/tests/strict_log_check_test.sh`
- Create: `scripts/strict_regression.sh`
- Modify: `scripts/vcs.sh:34-64`
- Modify: `filelists/tests.f:1-17`
- Modify: `Makefile:1-22`

- [ ] **Step 1: Write the failing shell test for strict log parsing**

Create `scripts/tests/strict_log_check_test.sh` with executable mode and this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$script_dir/../strict_log_check.sh"

pass_sim=$'--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
warn_sim=$'--- UVM Report Summary ---\nUVM_WARNING : 1\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
runtime_warn=$'Warning-[DT-MCEQ] Method called on empty queue\n--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
leak_sim=$'UVM_WARNING [HOST_MEM] Leak check: 2 blocks not freed (total 128 bytes)\n--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
scoreboard_sim=$'========== Scoreboard Report ==========\n  Mismatched:   2\n--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'

printf '%s' "$pass_sim" | "$checker" sim -

if printf '%s' "$warn_sim" | "$checker" sim -; then
  echo "warning summary was accepted" >&2
  exit 1
fi
if printf '%s' "$runtime_warn" | "$checker" sim -; then
  echo "runtime VCS warning was accepted" >&2
  exit 1
fi
if printf '%s' "$leak_sim" | "$checker" sim -; then
  echo "host-memory leak was accepted" >&2
  exit 1
fi
if printf '%s' "$scoreboard_sim" | "$checker" sim -; then
  echo "nonzero scoreboard mismatch count was accepted" >&2
  exit 1
fi
if printf '%s' 'compile Warning-[ENUMASSIGN]' | "$checker" compile -; then
  echo "compile warning was accepted" >&2
  exit 1
fi
if printf '%s' 'simulation ended without summary' | "$checker" sim -; then
  echo "missing UVM summary was accepted" >&2
  exit 1
fi

echo "strict_log_check tests PASSED"
```

- [ ] **Step 2: Run the parser test and verify RED**

Run:

```bash
chmod +x scripts/tests/strict_log_check_test.sh
scripts/tests/strict_log_check_test.sh
```

Expected: FAIL because `scripts/strict_log_check.sh` does not exist.

- [ ] **Step 3: Implement the strict log checker**

Create executable `scripts/strict_log_check.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
log_path="${2:-}"

if [[ "$mode" != "compile" && "$mode" != "sim" ]]; then
  echo "usage: $0 compile|sim LOG_PATH|-" >&2
  exit 2
fi
if [[ -z "$log_path" ]]; then
  echo "missing log path" >&2
  exit 2
fi

if [[ "$log_path" == "-" ]]; then
  log_text="$(cat)"
else
  if [[ ! -f "$log_path" ]]; then
    echo "missing log: $log_path" >&2
    exit 1
  fi
  log_text="$(<"$log_path")"
fi

reject_fixed() {
  local needle="$1"
  local label="$2"
  if grep -Fq "$needle" <<<"$log_text"; then
    echo "$label found" >&2
    return 1
  fi
}

reject_fixed 'Warning-[' 'VCS warning'
reject_fixed 'Error-[' 'VCS error'

if [[ "$mode" == "compile" ]]; then
  exit 0
fi

summary_count="$(grep -c 'UVM Report Summary' <<<"$log_text" || true)"
if [[ "$summary_count" -ne 1 ]]; then
  echo "expected one UVM Report Summary, found $summary_count" >&2
  exit 1
fi

for severity in UVM_WARNING UVM_ERROR UVM_FATAL; do
  count="$(awk -v key="$severity" '$1 == key && $2 == ":" {value=$3} END {print value}' <<<"$log_text")"
  if [[ -z "$count" || "$count" != "0" ]]; then
    echo "$severity count is ${count:-missing}" >&2
    exit 1
  fi
done

if grep -Eq 'Leak check: [1-9][0-9]* blocks not freed' <<<"$log_text"; then
  echo "host-memory leak found" >&2
  exit 1
fi
if grep -Eq 'Completion (byte_count|lower_addr|requester_id) mismatch' <<<"$log_text"; then
  echo "PCIe completion mismatch found" >&2
  exit 1
fi
if grep -Eq '(Mismatched|TX mismatched|RX mismatched):[[:space:]]*[1-9][0-9]*' \
    <<<"$log_text"; then
  echo "nonzero scoreboard mismatch count found" >&2
  exit 1
fi

exit 0
```

- [ ] **Step 4: Run the parser test and verify GREEN**

Run:

```bash
chmod +x scripts/strict_log_check.sh
scripts/tests/strict_log_check_test.sh
```

Expected: `strict_log_check tests PASSED`.

- [ ] **Step 5: Add the canonical manifest**

Create `scripts/test_manifest.sh`:

```bash
#!/usr/bin/env bash

VIRTIO_MAINTAINED_TESTS=(
  dpu_resource_manager_test
  virtio_fabric_resource_test
  virtio_unit_test
  virtio_stress_unit_test
  virtio_protocol_test
  virtio_indirect_desc_test
  virtio_admin_vq_test
  virtio_migration_dirty_test
  virtio_monitor_test
  virtio_coverage_test
  virtio_e2e_test
  virtio_full_integration_test
  virtio_pf_lifecycle_reset_test
  virtio_monitor_routing_test
  virtio_dual_test
  virtio_smoke_test
  virtio_traffic_test
)

is_virtio_maintained_test() {
  local requested="$1"
  local maintained
  for maintained in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
    [[ "$requested" == "$maintained" ]] && return 0
  done
  return 1
}
```

Change `scripts/vcs.sh` to source the manifest after `root_dir` is defined and replace the case statement with:

```bash
source "$root_dir/scripts/test_manifest.sh"

TEST="${TEST:-}"
if ! is_virtio_maintained_test "$TEST"; then
  echo "unsupported TEST: $TEST" >&2
  exit 2
fi
```

Remove the `TEST == dpu_resource_manager_test` conditional filelist block. The DPU test will be compiled unconditionally through `tests.f`.

- [ ] **Step 6: Complete the test filelist**

Replace `filelists/tests.f` with this ordered list:

```text
// All maintained test classes followed by the shared top.
+incdir+virtio_net_vip/tests
dpu_common/tests/dpu_resource_manager_test.sv
virtio_net_vip/tests/virtio_unit_test.sv
virtio_net_vip/tests/virtio_fabric_resource_test.sv
virtio_net_vip/tests/virtio_stress_unit_test.sv
virtio_net_vip/tests/virtio_protocol_test.sv
virtio_net_vip/tests/virtio_indirect_desc_test.sv
virtio_net_vip/tests/virtio_admin_vq_test.sv
virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv
virtio_net_vip/tests/virtio_monitor_test.sv
virtio_net_vip/tests/virtio_coverage_test.sv
virtio_net_vip/tests/virtio_monitor_routing_test.sv
virtio_net_vip/tests/virtio_migration_dirty_test.sv
virtio_net_vip/tests/virtio_e2e_test.sv
virtio_net_vip/tests/virtio_full_test.sv
virtio_net_vip/tests/virtio_dual_test.sv
virtio_net_vip/tests/virtio_smoke_test.sv
virtio_net_vip/tests/virtio_traffic_test.sv
virtio_net_vip/tests/virtio_tb_top.sv
```

- [ ] **Step 7: Implement compile-once strict regression**

Create executable `scripts/strict_regression.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
source "$script_dir/test_manifest.sh"

timeout_seconds="${STRICT_TEST_TIMEOUT_SECONDS:-180}"
log_dir="$root_dir/build/strict"
mkdir -p "$log_dir"

compile_log="$log_dir/compile.log"
TEST="${VIRTIO_MAINTAINED_TESTS[0]}" "$script_dir/vcs.sh" --compile-only >"$compile_log" 2>&1
"$script_dir/strict_log_check.sh" compile "$compile_log"

failures=0
for test_name in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
  test_log="$log_dir/$test_name.log"
  set +e
  timeout "${timeout_seconds}s" "$root_dir/build/simv" \
    +UVM_TESTNAME="$test_name" +UVM_VERBOSITY=UVM_LOW +UVM_NO_RELNOTES \
    >"$test_log" 2>&1
  run_rc=$?
  set -e

  if [[ "$run_rc" -ne 0 ]]; then
    echo "STRICT_RESULT $test_name FAIL rc=$run_rc"
    failures=$((failures + 1))
    continue
  fi
  if ! "$script_dir/strict_log_check.sh" sim "$test_log"; then
    echo "STRICT_RESULT $test_name FAIL log-policy"
    failures=$((failures + 1))
    continue
  fi
  echo "STRICT_RESULT $test_name PASS"
done

if [[ "$failures" -ne 0 ]]; then
  echo "STRICT_REGRESSION FAIL failures=$failures" >&2
  exit 1
fi

echo "STRICT_REGRESSION PASS tests=${#VIRTIO_MAINTAINED_TESTS[@]}"
```

Replace the Makefile regression loop with:

```make
.PHONY: bootstrap check-deps compile test regression strict-regression

regression strict-regression:
	./scripts/strict_regression.sh
```

Keep the existing `bootstrap`, `check-deps`, `compile`, and `test` targets unchanged.

- [ ] **Step 8: Verify the infrastructure and observe the expected baseline RED**

Run locally:

```bash
bash -n scripts/test_manifest.sh scripts/strict_log_check.sh \
  scripts/tests/strict_log_check_test.sh scripts/strict_regression.sh scripts/vcs.sh
scripts/tests/strict_log_check_test.sh
git diff --check
```

Then sync to the VCS host and run:

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-remote.Ku3iG3 && make strict-regression'"
```

Expected: compilation succeeds but strict regression fails on the known compile warnings before simulations are accepted.

- [ ] **Step 9: Commit the regression infrastructure**

```bash
git add Makefile filelists/tests.f scripts/test_manifest.sh scripts/vcs.sh \
  scripts/strict_log_check.sh scripts/strict_regression.sh \
  scripts/tests/strict_log_check_test.sh
git commit -m "test: add strict virtio regression gate"
```

---

### Task 2: Remove compile-time enum and fork/ref warnings

**Files:**
- Modify: `virtio_net_vip/src/shared/virtio_wait_policy.sv:143-174`
- Modify: `virtio_net_vip/src/env/virtio_concurrency_controller.sv:57-125,139-194`
- Modify: `virtio_net_vip/src/env/virtio_dynamic_reconfig.sv:84-87,277-280,332-335`
- Modify: `virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv:250-257`
- Verify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:396`

- [ ] **Step 1: Capture the compile-warning RED**

Run the remote compile through `scripts/vcs.sh`, then check it with the strict parser:

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-remote.Ku3iG3 && TEST=dpu_resource_manager_test ./scripts/vcs.sh --compile-only > build/strict/compile-warning-red.log 2>&1; ./scripts/strict_log_check.sh compile build/strict/compile-warning-red.log'"
```

Expected: FAIL with `VCS warning found`; the log contains `ENUMASSIGN` and `SV-IATRA`.

- [ ] **Step 2: Isolate the wait-policy fork result**

In `wait_event_or_timeout`, add a task-local `bit event_triggered`, write only that local from the fork, and copy it to the caller after the fork is disabled:

```systemverilog
        int unsigned eff_timeout;
        bit          event_triggered;
        eff_timeout = effective_timeout(timeout_ns);
        event_triggered = 0;

        fork : wait_evt_blk
            begin : evt_arm
                evt.wait_trigger();
                event_triggered = 1;
            end
            begin : timeout_arm
                #(eff_timeout * 1ns);
            end
        join_any
        disable wait_evt_blk;
        triggered = event_triggered;
```

Keep the existing success/timeout reports after this assignment.

- [ ] **Step 3: Give concurrency workers internal result arrays**

For `parallel_vf_op`, declare and allocate `bit worker_results[]`, replace every forked `results[idx]` access with `worker_results[idx]`, and copy only after the wait block:

```systemverilog
        int unsigned num_vfs = vf_ids.size();
        bit worker_results[];
        worker_results = new[num_vfs];
```

After `disable parallel_vf_op_wait;` add:

```systemverilog
        results = worker_results;
```

Apply the same pattern to `parallel_traffic` using `int unsigned worker_actual_sent[]`; the fork writes `worker_actual_sent[idx]` and the task copies `actual_sent = worker_actual_sent` only after `disable parallel_traffic_wait;`.

- [ ] **Step 4: Use the declared control-class enum constants**

Replace the three class arguments:

```systemverilog
VIRTIO_NET_CTRL_MQ   -> VIRTIO_NET_CTRL_CLS_MQ
VIRTIO_NET_CTRL_MAC  -> VIRTIO_NET_CTRL_CLS_MAC
VIRTIO_NET_CTRL_VLAN -> VIRTIO_NET_CTRL_CLS_VLAN
```

Do not cast the command byte; only the first `ctrl_send` argument is `virtio_ctrl_class_e`.

- [ ] **Step 5: Initialize the lifecycle reset configuration field-by-field**

Replace `cfg = '{default: 0};` and the following partial assignments with explicit typed values:

```systemverilog
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 8;
        cfg.vq_type = VQ_SPLIT;
        cfg.driver_features = '0;
        cfg.rx_buf_mode = RX_MODE_MERGEABLE;
        cfg.rx_buf_size = 0;
        cfg.rx_refill_threshold = 1;
        cfg.irq_mode = IRQ_MSIX_PER_QUEUE;
        cfg.napi_budget = 0;
        cfg.coal_max_packets = 0;
        cfg.coal_max_usecs = 0;
        cfg.bw_limit_enable = 0;
        cfg.bw_limit_mbps = 0;
        cfg.mode = DRV_MODE_AUTO;
```

- [ ] **Step 6: Verify the existing empty-queue guard**

Confirm `restore_claimed_queue_mappings()` contains:

```systemverilog
        if (claim_indices.size() > 1)
            claim_indices.sort();
```

Do not create a second equivalent guard.

- [ ] **Step 7: Verify GREEN compile and focused runtime tests**

Sync to the VCS host and run:

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-remote.Ku3iG3 && TEST=dpu_resource_manager_test ./scripts/vcs.sh --compile-only > build/strict/compile-warning-green.log 2>&1 && ./scripts/strict_log_check.sh compile build/strict/compile-warning-green.log && timeout 180s build/simv +UVM_TESTNAME=virtio_unit_test +UVM_NO_RELNOTES > build/strict/warning-unit.log 2>&1 && timeout 180s build/simv +UVM_TESTNAME=virtio_pf_lifecycle_reset_test +UVM_NO_RELNOTES > build/strict/warning-pf.log 2>&1'"
```

Expected: compile log has zero `Warning-[...]`; both simulations finish with zero error/fatal. The unit warning is handled in Task 3.

- [ ] **Step 8: Commit compile-warning fixes**

```bash
git add virtio_net_vip/src/shared/virtio_wait_policy.sv \
  virtio_net_vip/src/env/virtio_concurrency_controller.sv \
  virtio_net_vip/src/env/virtio_dynamic_reconfig.sv \
  virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv
git commit -m "fix: remove virtio compile warnings"
```

---

### Task 3: Enforce active/passive binding without warning noise

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_driver_agent.sv:74-107`
- Modify: `virtio_net_vip/tests/virtio_fabric_resource_test.sv:620-651`
- Modify: `virtio_net_vip/tests/virtio_full_test.sv:55-90`
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv:9-92,391-450`

- [ ] **Step 1: Record warning RED for the affected tests**

Run `virtio_fabric_resource_test`, `virtio_unit_test`, and `virtio_full_integration_test` from the shared simv.

Expected warning counts: 54, 1, and 2 respectively. The unit warning is the deliberately rejected completion; the Fabric/full warnings are unbound active drivers.

- [ ] **Step 2: Make late binding validation authoritative**

In `connect_phase`, retain the assignments when `ops` or `fsm` is non-null but remove both warning branches. Add this phase method to `virtio_driver_agent`:

```systemverilog
    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        if (get_is_active() == UVM_ACTIVE) begin
            if (ops == null)
                `uvm_error("VIRTIO_AGENT",
                    "active driver has no virtio_atomic_ops binding")
            if (fsm == null)
                `uvm_error("VIRTIO_AGENT",
                    "active driver has no virtio_auto_fsm binding")
        end
    endfunction
```

This waits until all parent/test `connect_phase` binding is complete while still rejecting an active driver that would dereference null at runtime.

- [ ] **Step 3: Mark observation-only function agents passive**

Before creating `env` and `compatibility_vf` in `virtio_fabric_resource_test::build_phase`, add:

```systemverilog
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "env.*.driver_agent", "is_active", UVM_PASSIVE);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "compatibility_vf.driver_agent", "is_active", UVM_PASSIVE);
```

Before creating `binding_function` in `virtio_full_integration_test::build_phase`, add:

```systemverilog
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "binding_function.driver_agent", "is_active", UVM_PASSIVE);
```

- [ ] **Step 4: Catch and prove the expected rejected completion**

Add this catcher before `virtio_unit_test`:

```systemverilog
class virtio_expected_rc_completion_warning_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(
        string name = "virtio_expected_rc_completion_warning_catcher"
    );
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_WARNING) &&
            (get_id() == "RC_DRV") &&
            uvm_is_match("Unexpected Completion:*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_expected_rc_completion_warning_catcher
```

Declare `virtio_expected_rc_completion_warning_catcher catcher;` in
`test_tlm_completion_reject_filter`, and wrap only the rejected completion:

```systemverilog
        catcher = new("expected_rejected_completion");
        uvm_report_cb::add(null, catcher);
        accepted = shim.handle_completion(rejected_cpl);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count == 1)
            else `uvm_error("TEST", $sformatf(
                "expected one rejected-completion warning, caught %0d",
                catcher.caught_count))
```

Keep the existing `assert(!accepted)` and adapter-queue assertions immediately
after this block. Because the catcher is removed before the matched completion,
no unrelated completion warning can be hidden.

- [ ] **Step 5: Verify warning-clean GREEN for the three tests**

Run all three tests and check each log with:

```bash
./scripts/strict_log_check.sh sim build/strict/virtio_fabric_resource_test.log
./scripts/strict_log_check.sh sim build/strict/virtio_unit_test.log
./scripts/strict_log_check.sh sim build/strict/virtio_full_integration_test.log
```

Expected: all three pass with warning/error/fatal count zero.

- [ ] **Step 6: Commit agent lifecycle fixes**

```bash
git add virtio_net_vip/src/agent/virtio_driver_agent.sv \
  virtio_net_vip/tests/virtio_fabric_resource_test.sv \
  virtio_net_vip/tests/virtio_full_test.sv \
  virtio_net_vip/tests/virtio_unit_test.sv
git commit -m "fix: validate virtio agent bindings by mode"
```

---

### Task 4: Make TLM completion optional and fix routing SVA timing

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv:312-349`
- Modify: `virtio_net_vip/tests/virtio_monitor_routing_test.sv:55-130,132-160,391-401`

- [ ] **Step 1: Change the routing test to exercise no-adapter binding**

Remove the `tlm_adapter` field, creation, and `install_factory_overrides()` calls. Pass `null` as the second argument to `virtio_env.bind_pcie()`.

After assigning `pf` and `vf` in `run_phase`, add a focused binding exit:

```systemverilog
        if ($test$plusargs("ROUTING_BIND_ONLY")) begin
            assert((pf.driver_agent.ops != null) &&
                   (pf.driver_agent.fsm != null) &&
                   (vf.driver_agent.ops != null) &&
                   (vf.driver_agent.fsm != null))
                else `uvm_fatal("ROUTING_TEST",
                    "no-adapter binding left an active function unbound")
            phase.drop_objection(this);
            return;
        end
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
timeout 180s build/simv +UVM_TESTNAME=virtio_monitor_routing_test \
  +ROUTING_BIND_ONLY +UVM_NO_RELNOTES
```

Expected: one fatal, `bind_pcie() received a null TLM completion adapter`.

- [ ] **Step 3: Implement optional adapter binding**

Change the function header to:

```systemverilog
    virtual function void bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_tlm_completion_adapter tlm_adapter = null,
        input pcie_tl_base_monitor pcie_rc_monitor = null,
        input pcie_tl_base_monitor pcie_ep_monitor = null
    );
```

Replace the null-adapter fatal plus unconditional bind with:

```systemverilog
        if (tlm_adapter != null)
            tlm_adapter.bind_registered_rc_driver();
```

Keep the null RC sequencer fatal and all function/monitor binding unchanged.

- [ ] **Step 4: Run the focused test and verify GREEN**

Expected: `ROUTING_BIND_ONLY` produces one UVM summary with zero warning/error/fatal.

- [ ] **Step 5: Reproduce the remaining routing timing RED**

Run the normal `virtio_monitor_routing_test` without `ROUTING_BIND_ONLY`.

Expected: the existing fatal at `VF DRIVER_OK without VF FEATURES_OK did not trip its SVA`.

- [ ] **Step 6: Wait through the actual SVA sample boundary**

Replace the end of `emit_status_and_advance` with:

```systemverilog
        // The callback can enqueue on the same negedge at which the interface
        // drains its queue.  Cross the next release edge and then the following
        // SVA sample; #1step leaves the observed/reactive regions before checking.
        @(posedge virtio_tb_top.clk);
        @(negedge virtio_tb_top.clk);
        @(posedge virtio_tb_top.clk);
        #1step;
```

- [ ] **Step 7: Verify normal routing GREEN**

Run the normal test twice to exclude an edge-order fluke, then check both logs with `strict_log_check.sh sim`.

Expected: both runs have zero warning/error/fatal and retain the PF/VF isolation assertions.

- [ ] **Step 8: Commit optional binding and routing timing**

```bash
git add virtio_net_vip/src/env/virtio_net_env.sv \
  virtio_net_vip/tests/virtio_monitor_routing_test.sv
git commit -m "fix: support DUT binding without TLM adapter"
```

---

### Task 5: Correct PCIe config-read completion metadata

**Files:**
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv`
- Modify and commit in submodule: `virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv:375-395`
- Modify: `scripts/check_deps.sh:12-15`
- Update submodule pointer: `virtio_net_vip/ext/pcie_tl_vip`

- [ ] **Step 1: Add a focused completion metadata test**

Add a test-only driver subclass before `virtio_unit_test` so the standalone
component does not enter the traffic-serving loop:

```systemverilog
class virtio_completion_ep_driver_test_shim extends pcie_tl_ep_driver;
    `uvm_component_utils(virtio_completion_ep_driver_test_shim)

    function new(string name = "virtio_completion_ep_driver_test_shim",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
    endtask
endclass : virtio_completion_ep_driver_test_shim
```

Add this field to `virtio_unit_test`:

```systemverilog
    virtio_completion_ep_driver_test_shim completion_ep_driver;
```

Construct it in `build_phase`:

```systemverilog
        completion_ep_driver =
            virtio_completion_ep_driver_test_shim::type_id::create(
                "completion_ep_driver", this);
```

Call `test_ep_config_read_completion_metadata();` after
`test_pcie_scoreboard_byte_enables();` in `run_phase`, and add:

```systemverilog
    task test_ep_config_read_completion_metadata();
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_cfg_tlp::type_id::create("cfg_read_metadata_req");
        req.kind = TLP_CFG_RD0;
        req.fmt = FMT_3DW_NO_DATA;
        req.type_f = TLP_TYPE_CFG_RD0;
        req.length = 10'd1;
        req.requester_id = 16'h0100;
        req.tag = 10'h055;
        req.first_be = 4'hF;

        cpl = completion_ep_driver.generate_completion(req, CPL_STATUS_SC);
        assert(cpl.byte_count == 12'd4)
            else `uvm_error("TEST", $sformatf(
                "config-read completion byte_count expected 4 got %0d",
                cpl.byte_count))
    endtask
```

- [ ] **Step 2: Run `virtio_unit_test` and verify RED**

Expected: one UVM error reporting `expected 4 got 0`.

- [ ] **Step 3: Set read-completion metadata at the PCIe owner**

In `pcie_tl_ep_driver::generate_completion`, retain zero defaults and add the
config-read case immediately before `return cpl;`:

```systemverilog
        case (req.kind)
            TLP_CFG_RD0, TLP_CFG_RD1: begin
                cpl.byte_count = 12'd4;
            end
            default: begin
            end
        endcase
```

Configuration reads are one DWord by the pinned package constraint and the
maintained config-read sequence uses `first_be == 4'hF`. The existing
`handle_mem_read()` remains the owner for memory-read length, split-fragment
remaining byte count, and lower address; do not duplicate that logic in this
generic constructor.

- [ ] **Step 4: Verify unit GREEN and E2E mismatch removal**

Run `virtio_unit_test` and `virtio_e2e_test`.

Expected: unit is warning/error/fatal clean; E2E contains zero `Completion byte_count mismatch`. E2E still reports the two host-memory leak warnings until Task 6.

- [ ] **Step 5: Commit the PCIe submodule change**

```bash
git -C virtio_net_vip/ext/pcie_tl_vip add \
  pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv
git -C virtio_net_vip/ext/pcie_tl_vip commit -m \
  "fix: report config read completion byte count"
git -C virtio_net_vip/ext/pcie_tl_vip rev-parse HEAD
```

Replace the old PCIe SHA `3e2d8c972f1baa78e073f98e8a38ad2f04db6e1a` in `scripts/check_deps.sh` with the exact SHA printed by the final command.

- [ ] **Step 6: Transfer the exact submodule commit to the VCS host**

Create and transfer a Git bundle, then detach the remote submodule at that exact commit:

```bash
pcie_bundle_dir="$(mktemp -d /tmp/virtio-pcie-convergence.XXXXXX)"
pcie_bundle="$pcie_bundle_dir/commit.bundle"
git -C virtio_net_vip/ext/pcie_tl_vip bundle create "$pcie_bundle" HEAD ^HEAD^
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e scp "$pcie_bundle" \
  ubuntu@10.11.10.53:/tmp/virtio-pcie-convergence.bundle
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'git -C /home/ubuntu/test_cosim/virtio-remote.Ku3iG3/virtio_net_vip/ext/pcie_tl_vip fetch /tmp/virtio-pcie-convergence.bundle HEAD && git -C /home/ubuntu/test_cosim/virtio-remote.Ku3iG3/virtio_net_vip/ext/pcie_tl_vip checkout --force --detach FETCH_HEAD'"
rm "$pcie_bundle"
rmdir "$pcie_bundle_dir"
```

- [ ] **Step 7: Commit the parent pointer, test, and pin**

```bash
git add virtio_net_vip/tests/virtio_unit_test.sv \
  virtio_net_vip/ext/pcie_tl_vip scripts/check_deps.sh
git commit -m "fix: validate PCIe completion metadata"
```

---

### Task 6: Free every E2E-owned host-memory allocation

**Files:**
- Modify: `virtio_net_vip/tests/virtio_e2e_test.sv:231-282,717-741,1171-1206,1278-1310`

- [ ] **Step 1: Verify the leak RED**

Run `virtio_e2e_test` after Task 5.

Expected: `UVM_WARNING=2`; both warnings report 19 blocks and 20,764 bytes not freed.

- [ ] **Step 2: Track allocations owned directly by the E2E test**

Add this field and helpers to `virtio_e2e_test`:

```systemverilog
    protected bit [63:0] e2e_host_allocations[$];

    protected function void track_e2e_allocation(bit [63:0] addr);
        if (addr != '1)
            e2e_host_allocations.push_back(addr);
    endfunction

    protected function void release_e2e_allocations();
        for (int index = e2e_host_allocations.size(); index > 0; index--)
            virtio_env.host_mem.free(e2e_host_allocations[index - 1]);
        e2e_host_allocations.delete();
    endfunction
```

Immediately after the ring-allocation fatal guard, record all three successful
allocations:

```systemverilog
                track_e2e_allocation(desc_addr);
                track_e2e_allocation(avail_addr);
                track_e2e_allocation(used_addr);
```

Immediately after the failed-`buf_addr` branch and before writing packet data,
record each successful TX packet allocation:

```systemverilog
                track_e2e_allocation(buf_addr);
```

- [ ] **Step 3: Release allocations before verification/reporting**

In `run_phase`, change the phase order to:

```systemverilog
        phase3_dataplane();
        release_e2e_allocations();
        phase4_verify();
```

Do not free transport-owned or IOMMU-owned addresses through this list.

- [ ] **Step 4: Verify leak-free GREEN**

Run E2E twice and pass both logs through `strict_log_check.sh sim`.

Expected: warning/error/fatal zero, no completion mismatch, no nonzero host-memory leak, and IOMMU reports no outstanding mappings.

- [ ] **Step 5: Commit E2E teardown**

```bash
git add virtio_net_vip/tests/virtio_e2e_test.sv
git commit -m "fix: release E2E host memory allocations"
```

---

### Task 7: Make smoke and traffic maintained runnable tests

**Files:**
- Modify: `virtio_net_vip/tests/virtio_smoke_test.sv`
- Modify: `virtio_net_vip/tests/virtio_traffic_test.sv:8-20`

- [ ] **Step 1: Preserve the smoke RED and traffic GREEN evidence**

Run both tests from the complete simv.

Expected: `virtio_smoke_test` exits with VCS `Error-[NOA]` because the old base test never binds ops/FSM; `virtio_traffic_test` completes with warning/error/fatal zero.

- [ ] **Step 2: Rewrite smoke as a bounded TLM integration smoke**

Change `virtio_smoke_test` to extend `virtio_e2e_test`, remove the old virtual-sequence dependency, and use this run phase:

```systemverilog
    virtual task run_phase(uvm_phase phase);
        virtio_pci_transport xport;
        bit [7:0] status;

        phase.raise_objection(this, "virtio smoke running");
        #200ns;

        phase1_setup_transport();
        phase2_virtio_init();

        xport = virtio_env.vf_instances[0].transport;
        xport.write_device_status(DEV_STATUS_RESET);
        xport.read_device_status(status);
        assert(status == DEV_STATUS_RESET)
            else `uvm_fatal("SMOKE_TEST", $sformatf(
                "device reset did not clear status: 0x%02h", status))

        release_e2e_allocations();
        phase4_verify();
        phase.drop_objection(this, "virtio smoke done");
    endtask
```

Keep `virtio_e2e_test.sv` before `virtio_smoke_test.sv` in `tests.f` so the base class is declared first.

- [ ] **Step 3: Correct the traffic-test maintenance comment**

Replace the four-line temporary-file paragraph with:

```systemverilog
// Maintained bounded direct-memory traffic regression. It uses host-memory
// models and device simulation to exercise traffic behavior; it does not
// represent traffic through a real DUT.
```

- [ ] **Step 4: Verify both tests GREEN**

Run smoke and traffic with 180-second timeouts and check each log through `strict_log_check.sh sim`.

Expected: both finish with warning/error/fatal zero and one UVM summary.

- [ ] **Step 5: Commit maintained smoke/traffic support**

```bash
git add virtio_net_vip/tests/virtio_smoke_test.sv \
  virtio_net_vip/tests/virtio_traffic_test.sv
git commit -m "test: maintain smoke and traffic regressions"
```

---

### Task 8: Bound the dual bandwidth workload

**Files:**
- Modify: `virtio_net_vip/tests/virtio_dual_test.sv:1320-1350`

- [ ] **Step 1: Confirm the 180-second RED**

Run default `virtio_dual_test` under `timeout 180s`.

Expected: exit 124 after Tests 1-4 and the unlimited bandwidth phase, while entering Phase 2 (10Gbps), with no UVM summary.

- [ ] **Step 2: Add a bounded default and explicit long-stress plusarg**

Change the task heading comment to `Test 5: Bandwidth Control`, replace the
fixed packet count declaration with:

```systemverilog
        int unsigned pkts_per_dir = 1000;
```

Before using it, add:

```systemverilog
        void'($value$plusargs("DUAL_BW_PKTS_PER_DIR=%d", pkts_per_dir));
        if (pkts_per_dir < 256)
            `uvm_fatal("DUAL_TEST",
                "DUAL_BW_PKTS_PER_DIR must be at least 256")
```

Replace the fixed `20K packets` start report with a count derived from the
selected workload:

```systemverilog
        `uvm_info("DUAL_TEST", $sformatf(
            "--- Test 5: Bandwidth Control with %0d packets/direction ---",
            pkts_per_dir), UVM_LOW)
```

Change `All phases must have sent/received all 20K packets` to `All phases
must send and receive the selected bounded workload`.

Do not change the three phase limits (`0`, `10000`, `1000` Mbps), throttle accounting, elapsed-time ordering, fairness checks, or Tests 1-4. The previous long workload remains available with `+DUAL_BW_PKTS_PER_DIR=10000`.

- [ ] **Step 3: Verify default dual GREEN within 180 seconds**

Run with `/usr/bin/time` and timeout:

```bash
/usr/bin/time -f 'DUAL_WALL_SECONDS=%e' timeout 180s build/simv \
  +UVM_TESTNAME=virtio_dual_test +UVM_NO_RELNOTES \
  > build/strict/virtio_dual_test.log 2>&1
./scripts/strict_log_check.sh sim build/strict/virtio_dual_test.log
```

Expected: exit 0, all three bandwidth phases reported, final UVM summary present, and wall time below 180 seconds.

- [ ] **Step 4: Verify the opt-in workload is parsed**

Run with `+DUAL_BW_PKTS_PER_DIR=256` and confirm the Phase 1 log reports `512 pkts`. This is a quick configurability check, not the long stress acceptance run.

- [ ] **Step 5: Commit bounded dual regression**

```bash
git add virtio_net_vip/tests/virtio_dual_test.sv
git commit -m "test: bound dual bandwidth regression workload"
```

---

### Task 9: Update support and regression documentation

**Files:**
- Modify: `README.md:260-300,370-470`
- Modify: `docs/virtio_net_vip_manual.md:1480-1510,1640-1700`

- [ ] **Step 1: Run the stale-document RED scan**

Run:

```bash
rg -n "未完整实现|Admin VQ 完整实现|dirty page bitmap|将 monitor 的协议检查提取为 SVA|dpu_resource_manager_test.*virtio_full_integration_test" \
  README.md docs/virtio_net_vip_manual.md
```

Expected: the manual still describes Indirect, Admin VQ, dirty-page verification, and SVA as incomplete, and the regression list omits five maintained tests.

- [ ] **Step 2: Document the strict regression contract**

Replace each old 12-test regression paragraph with this exact contract and the
same ordered list from `scripts/test_manifest.sh`:

```markdown
`make strict-regression`（`make regression` 为同一严格入口）只编译一次，随后复用
同一个 `simv` 运行 17 项维护测试。每项测试默认有 180 秒墙钟上限；进程非零退出、
超时、缺少或重复 UVM Report Summary、任何非零 UVM severity、VCS
`Warning-[...]`/`Error-[...]`、PCIe scoreboard mismatch 或资源泄漏都会使回归失败。

维护测试为：`dpu_resource_manager_test`、`virtio_fabric_resource_test`、
`virtio_unit_test`、`virtio_stress_unit_test`、`virtio_protocol_test`、
`virtio_indirect_desc_test`、`virtio_admin_vq_test`、
`virtio_migration_dirty_test`、`virtio_monitor_test`、`virtio_coverage_test`、
`virtio_e2e_test`、`virtio_full_integration_test`、
`virtio_pf_lifecycle_reset_test`、`virtio_monitor_routing_test`、
`virtio_dual_test`、`virtio_smoke_test` 和 `virtio_traffic_test`。
```

- [ ] **Step 3: Correct the capability status**

Replace the obsolete Indirect/Admin/migration/SVA limitation and future-work
entries with:

```markdown
- Split/Packed 间接描述符表已实现，由 `virtio_indirect_desc_test` 覆盖。
- Admin VQ 生命周期、恢复和绑定校验已实现，由 `virtio_admin_vq_test` 覆盖。
- 迁移 dirty-page payload/checksum 校验已实现，由 `virtio_migration_dirty_test` 覆盖。
- monitor 协议 SVA 与 PF/VF 隔离已实现，由 `virtio_monitor_test` 和
  `virtio_monitor_routing_test` 覆盖。
```

Add this binding boundary beside each TLM/SV-interface description:

```markdown
`virtio_net_env::bind_pcie()` 始终要求有效的 RC sequencer。非空 TLM completion
adapter 启用 TLM 回环 completion bridge；空 adapter 跳过 bridge，用于
SV-interface/DUT 公共绑定路径。本分支仅完成 VCS/TLM 自测收敛，尚未连接或验证
真实 DUT，因此结果不构成真实 DUT 的 virtio/PCIe 合规性证明。
```

- [ ] **Step 4: Verify documentation GREEN**

Run the stale-document scan again.

Expected: no obsolete status text; the new sections contain `17`, `180`, `strict-regression`, and the real-DUT limitation.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md docs/virtio_net_vip_manual.md
git commit -m "docs: document strict virtio convergence"
```

---

### Task 10: Exact-commit full verification on the VCS host

**Files:**
- Verify only; do not change code unless a focused RED-GREEN cycle is added to the owning task.

- [ ] **Step 1: Run local static checks**

```bash
git diff origin/feat/dpu-fabric-virtio-hardening...HEAD --check
bash -n scripts/*.sh scripts/tests/*.sh
scripts/tests/strict_log_check_test.sh
git status --short --branch
git submodule status --recursive
```

Expected: no whitespace/shell failures; only intended commits are ahead of the remote branch; all submodules are pinned without a dirty marker.

- [ ] **Step 2: Transfer the exact parent branch commit**

Create a parent Git bundle and fetch it in the initialized remote validation repository:

```bash
parent_bundle_dir="$(mktemp -d /tmp/virtio-convergence.XXXXXX)"
parent_bundle="$parent_bundle_dir/branch.bundle"
git bundle create "$parent_bundle" HEAD \
  ^origin/feat/dpu-fabric-virtio-hardening
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e scp "$parent_bundle" \
  ubuntu@10.11.10.53:/tmp/virtio-convergence.bundle
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-remote.Ku3iG3 && git fetch /tmp/virtio-convergence.bundle HEAD && git checkout --force --detach FETCH_HEAD && git submodule update --init --recursive --force'"
rm "$parent_bundle"
rmdir "$parent_bundle_dir"
```

The forced checkout is limited to the dedicated remote validation copy. It
replaces the earlier rsync staging bytes with the identical committed tree so
the final simulation cannot accidentally validate an uncommitted source file.

- [ ] **Step 3: Verify exact identities and dependencies**

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-remote.Ku3iG3 && git rev-parse HEAD && git submodule status --recursive && make check-deps'"
```

Expected: remote HEAD equals local `git rev-parse HEAD`; all three submodule SHAs equal the local status; `make check-deps` exits 0.

- [ ] **Step 4: Run the complete strict suite**

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-remote.Ku3iG3 && make strict-regression | tee build/strict/final-summary.log; test \${PIPESTATUS[0]} -eq 0'"
```

Expected final line: `STRICT_REGRESSION PASS tests=17`.

- [ ] **Step 5: Independently audit final logs**

```bash
SSHPASS="$VCS_SIM_PASSWORD" sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-remote.Ku3iG3 && source scripts/test_manifest.sh && logs=(build/strict/compile.log); for test_name in \"\${VIRTIO_MAINTAINED_TESTS[@]}\"; do logs+=(\"build/strict/\${test_name}.log\"); done; grep -n -E \"(Warning|Error)-\\[|UVM_(WARNING|ERROR|FATAL)[[:space:]]*:[[:space:]]*[1-9]|Leak check: [1-9]|Completion .*mismatch|(Mismatched|TX mismatched|RX mismatched):[[:space:]]*[1-9]\" \"\${logs[@]}\"; test \${PIPESTATUS[0]} -eq 1'"
```

Expected: grep audits only the canonical final compile log and 17 final test
logs, finds no forbidden diagnostics, and returns 1, which the final `test`
accepts. Intermediate RED evidence logs are intentionally outside this final
audit set.

- [ ] **Step 6: Record final repository state**

```bash
git status --short --branch
git log --oneline --decorate \
  origin/feat/dpu-fabric-virtio-hardening..HEAD
git diff --stat origin/feat/dpu-fabric-virtio-hardening...HEAD
```

Expected: clean worktree; commits are limited to the design, plan, regression infrastructure, focused fixes, submodule pin, bounded tests, and documentation.
