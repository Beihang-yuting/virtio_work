# DPU Fabric and Virtio-Net VIP Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a reproducible virtio-net VIP with a protocol-neutral DPU Fabric resource authority, multi-host/PF/VF function topology, public PCIe integration, passive verification closure, and the specified virtio feature completions.

**Architecture:** `dpu_resource_pkg` owns function, 64-bit BAR-pair and protocol-neutral resource leases. A function is activated by allocating/programming BAR0/1 (the sole function-device window), BAR2/3 (reserved) and BAR4/5 (MSI-X table/PBA) before client capability discovery. The manager exposes only generic resource-pool and lease APIs; the virtio client turns an acquired QP lease into atomic TX/RX logical queues. `dpu_fabric_env` owns one manager and protocol environments use it as clients. PCIe adapters translate external VIP traffic into the existing virtio transaction/monitor flow.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS, `pcie_tl_vip`, `host_mem`, `net_packet`, GNU Make, Bash, Git submodules.

---

## File Structure

- Create: `dpu_common/src/dpu_resource_types.sv` — neutral identities, resource classes, topology and lease records.
- Create: `dpu_common/src/dpu_resource_manager.sv` — capacity validation, allocation, release, freeze and lookup authority.
- Create: `dpu_common/src/dpu_resource_pkg.sv` — package entry point for shared resource code.
- Create: `dpu_common/src/dpu_fabric_env.sv` — root UVM environment owning the shared manager.
- Create: `dpu_common/tests/dpu_resource_manager_test.sv` — unit coverage for all hard resource limits.
- Create: `virtio_net_vip/src/sriov/virtio_function_instance.sv` — common PF/VF device wrapper.
- Create: `virtio_net_vip/src/sriov/virtio_pf_instance.sv` — PF function, PF manager and subordinate VF array.
- Create: `virtio_net_vip/src/sriov/virtio_resource_client.sv` — virtio local-q/QP to DPU lease adapter.
- Create: `virtio_net_vip/src/transport/virtio_tlm_completion_adapter.sv` — reusable TLM completion bridge and sequence overrides.
- Create: `virtio_net_vip/src/transport/virtio_pcie_observer_adapter.sv` — PCIe TLP to monitor-event adapter.
- Create: `virtio_net_vip/src/agent/virtio_protocol_event_if.sv` — abstract event interface for TLM and SV-interface modes.
- Create: `virtio_net_vip/src/agent/virtio_protocol_assertions.sv` — SVA checker module.
- Create: `virtio_net_vip/tests/virtio_fabric_resource_test.sv`, `virtio_net_vip/tests/virtio_monitor_test.sv`, `virtio_net_vip/tests/virtio_indirect_desc_test.sv`, `virtio_net_vip/tests/virtio_admin_vq_test.sv`, `virtio_net_vip/tests/virtio_migration_dirty_test.sv`, `virtio_net_vip/tests/virtio_coverage_test.sv` — focused regressions.
- Modify: `.gitmodules`, `README.md`, `virtio_net_vip/src/virtio_net_pkg.sv`, type/config/env/SR-IOV/transport/monitor/queue source files, existing integration tests and test top.
- Create: `Makefile`, `scripts/bootstrap.sh`, `scripts/check_deps.sh`, `scripts/vcs.sh`, `filelists/dpu_common.f`, `filelists/virtio_net.f`, `filelists/tests.f`.

### Task 1: Replace machine-local links with reproducible dependencies and build entry points

**Files:**
- Create: `.gitmodules`, `Makefile`, `scripts/bootstrap.sh`, `scripts/check_deps.sh`, `scripts/vcs.sh`, `filelists/dpu_common.f`, `filelists/virtio_net.f`, `filelists/tests.f`
- Modify: `virtio_net_vip/ext/host_mem`, `virtio_net_vip/ext/net_packet`, `virtio_net_vip/ext/pcie_tl_vip`, `README.md`
- Test: `scripts/check_deps.sh`

- [ ] **Step 1: Write the dependency failure test**

Create `scripts/check_deps.sh` with this pre-implementation behavior and run it before adding submodules:

```bash
#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for path in virtio_net_vip/ext/pcie_tl_vip virtio_net_vip/ext/host_mem virtio_net_vip/ext/net_packet; do
  test -d "$root_dir/$path" || { echo "missing submodule: $path" >&2; exit 2; }
done
test -n "${VCS_HOME:-}" || { echo "VCS_HOME is required" >&2; exit 3; }
test -x "$VCS_HOME/bin/vcs" || { echo "vcs not found: $VCS_HOME/bin/vcs" >&2; exit 4; }
```

- [ ] **Step 2: Run the failure test**

Run: `bash scripts/check_deps.sh`

Expected: exit code `2` and `missing submodule` while the old deleted links are still absent.

- [ ] **Step 3: Add fixed-SHA submodules and bootstrap implementation**

Replace the three legacy links with gitlinks. Use token-free URLs and pin exactly these commits:

```bash
git submodule add -b main https://github.com/Beihang-yuting/pcie_work.git virtio_net_vip/ext/pcie_tl_vip
git -C virtio_net_vip/ext/pcie_tl_vip checkout 6913793a42dc58873935f802fab50a395ab56ff3
git submodule add -b master https://github.com/Beihang-yuting/host_mem.git virtio_net_vip/ext/host_mem
git -C virtio_net_vip/ext/host_mem checkout 3b9e000d5df4d10efbb3029f43605e0362e0caca
git submodule add -b main https://github.com/Beihang-yuting/net_packet.git virtio_net_vip/ext/net_packet
git -C virtio_net_vip/ext/net_packet checkout e2af70204f53ede65e366c7a65f695c59acdbbc5
```

Implement `scripts/bootstrap.sh` as:

```bash
#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
git -C "$root_dir" submodule sync --recursive
git -C "$root_dir" submodule update --init --recursive
git -C "$root_dir" submodule status --recursive
```

Add Make targets `bootstrap`, `check-deps`, `compile`, `test`, and `regression`; `compile` and `test` call `scripts/vcs.sh` with `TEST`, while `regression` invokes the focused test names from Tasks 2–10.

- [ ] **Step 4: Implement deterministic VCS command generation**

`scripts/vcs.sh` must derive `root_dir`, reject an unknown `TEST`, and invoke VCS using filelists in this order:

```bash
"$VCS_HOME/bin/vcs" -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f "$root_dir/filelists/dpu_common.f" \
  -f "$root_dir/filelists/virtio_net.f" \
  -f "$root_dir/filelists/tests.f" \
  -top virtio_tb_top -o "$root_dir/build/simv"
"$root_dir/build/simv" +UVM_TESTNAME="$TEST" +UVM_VERBOSITY="${UVM_VERBOSITY:-UVM_LOW}"
```

When `TEST=dpu_resource_manager_test`, append `-f "$root_dir/filelists/dpu_red_tests.f"` before `tests.f`; no other TEST receives that red-only source. The external dependency preflight remains before every VCS invocation.

Use paths relative to `root_dir` in the filelists and update README to use `make bootstrap`, `make check-deps`, and `make test TEST=virtio_unit_test`.

- [ ] **Step 5: Verify and commit**

Run: `make bootstrap && git submodule status --recursive && make check-deps`

Expected: three pinned SHA lines; `make check-deps` either succeeds with VCS installed or exits `3` with the explicit missing `VCS_HOME` diagnostic.

```bash
git add .gitmodules Makefile scripts filelists README.md virtio_net_vip/ext
git commit -m "build: add pinned external VIP dependencies"
```

### Task 2: Define protocol-neutral DPU topology and leases

**Files:**
- Create: `dpu_common/src/dpu_resource_types.sv`, `dpu_common/src/dpu_resource_pkg.sv`
- Create: `filelists/dpu_red_tests.f`
- Modify: `filelists/dpu_common.f`, `filelists/tests.f`, `scripts/vcs.sh`
- Test: `dpu_common/tests/dpu_resource_manager_test.sv` (red-only until Task 3 implements the manager)

- [ ] **Step 1: Write topology boundary tests**

Add a UVM test class that factory-creates `dpu_resource_manager` and asserts: 64 active PFs plus 960 VFs succeeds, a 961st VF fails, and VF index 16 fails. Keep it only in `dpu_red_tests.f` until Task 3 implements `uvm_object_utils` and the manager methods, so ordinary virtio compilations do not compile an intentional red test. QP quota is tested only after Task 3 has registered its generic resource class.

```systemverilog
function automatic dpu_function_key_t make_pf_key(int unsigned host_id, int unsigned pf_id);
  dpu_function_key_t key;
  key = '{host_id, pf_id, DPU_FUNCTION_PF, 0};
  return key;
endfunction
function automatic dpu_function_key_t make_vf_key(
  int unsigned host_id, int unsigned pf_id, int unsigned vf_id);
  dpu_function_key_t key;
  key = '{host_id, pf_id, DPU_FUNCTION_VF, vf_id};
  return key;
endfunction
for (int host_id = 0; host_id < 4; host_id++)
  for (int pf_id = 0; pf_id < 16; pf_id++)
    assert(rm.register_function(make_pf_key(host_id, pf_id), why))
      else `uvm_fatal("DPU_TEST", why)
for (int flat_pf = 0; flat_pf < 60; flat_pf++)
  for (int vf_id = 0; vf_id < 16; vf_id++)
    assert(rm.register_function(make_vf_key(flat_pf / 16, flat_pf % 16, vf_id), why))
      else `uvm_fatal("DPU_TEST", why)
assert(!rm.register_function(make_vf_key(3, 12, 0), why))
  else `uvm_error("DPU_TEST", "1024-function limit was not enforced")
assert(!rm.validate_vf_key(vf_key_with_id_16, why))
  else `uvm_error("DPU_TEST", "VF/PF limit was not enforced")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test TEST=dpu_resource_manager_test`

Expected: compile failure because `dpu_resource_manager` and its types do not exist.

- [ ] **Step 3: Define stable shared types**

Create `dpu_resource_types.sv` with the following API, before any protocol import:

```systemverilog
typedef enum int unsigned { DPU_FUNCTION_PF, DPU_FUNCTION_VF } dpu_function_kind_e;
typedef enum int unsigned {
  DPU_RESOURCE_KIND_FUNCTION, DPU_RESOURCE_KIND_BAR,
  DPU_RESOURCE_KIND_QUEUE, DPU_RESOURCE_KIND_INTERRUPT_VECTOR,
  DPU_RESOURCE_KIND_DMA_WINDOW
} dpu_resource_kind_e;
typedef int unsigned dpu_resource_class_id_t;
typedef enum int unsigned { DPU_BAR_FUNCTION_DEVICE, DPU_BAR_RESERVED, DPU_BAR_MSIX } dpu_bar_role_e;

typedef struct {
  int unsigned host_id;
  int unsigned pf_id;
  dpu_function_kind_e kind;
  int unsigned vf_id;
} dpu_function_key_t;

typedef struct {
  dpu_function_key_t owner;
  int unsigned local_id;
  dpu_resource_class_id_t class_id;
  int unsigned global_id;
  bit frozen;
} dpu_resource_lease_t;
typedef struct {
  string name;
  dpu_resource_class_id_t class_id;
  dpu_resource_kind_e kind;
  int unsigned capacity;
  int unsigned max_per_function;
} dpu_resource_pool_config_t;
typedef struct {
  dpu_bar_role_e role;
  int unsigned even_bar_id;
  bit [63:0] base;
  bit [63:0] size;
} dpu_bar_pair_lease_t;
```

Define only core topology constants `DPU_MAX_HOSTS=4`, `DPU_MAX_PFS_PER_HOST=16`, `DPU_MAX_VFS_PER_PF=16`, and `DPU_MAX_FUNCTIONS=1024`. `dpu_resource_types.sv` is an include fragment, and `dpu_common.f` compiles only `dpu_resource_pkg.sv`, which includes that fragment exactly once. Package the types with `package dpu_resource_pkg; import uvm_pkg::*;`; manager implementation remains deferred to Task 3. The core never declares protocol QP constants or resource-name enums.

- [ ] **Step 4: Run the type compile check**

Run: `make compile TEST=dpu_resource_manager_test`

Expected: once the external dependency blocker is resolved, the red-only test advances from missing-type errors to missing factory-capable manager/method errors.

- [ ] **Step 5: Commit the type boundary**

```bash
git add dpu_common/src/dpu_resource_types.sv dpu_common/src/dpu_resource_pkg.sv dpu_common/tests/dpu_resource_manager_test.sv filelists/dpu_common.f filelists/dpu_red_tests.f filelists/tests.f scripts/vcs.sh
git commit -m "feat: define shared DPU resource identities"
```

### Task 3: Implement the DPU resource manager and Fabric environment

**Files:**
- Create: `dpu_common/src/dpu_resource_manager.sv`, `dpu_common/src/dpu_fabric_env.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Test: `dpu_common/tests/dpu_resource_manager_test.sv`

- [ ] **Step 1: Add failing BAR-first activation and QP-lease tests**

Extend the test with these expectations:

```systemverilog
dpu_fabric_env_config fabric_cfg;
dpu_fabric_env fabric;
dpu_resource_manager rm;
dpu_resource_pool_config_t virtio_qpair_profile;
dpu_resource_class_id_t virtio_qpair_class_id;
dpu_resource_class_id_t rejected_class_id;
fabric_cfg = dpu_fabric_env_config::type_id::create("fabric_cfg");
fabric = dpu_fabric_env::type_id::create("fabric", this);
virtio_qpair_profile.name = "virtio.qpair";
virtio_qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
virtio_qpair_profile.capacity = 2048;
virtio_qpair_profile.max_per_function = 32;
fabric_cfg.resource_profiles.push_back(virtio_qpair_profile);
assert(fabric.apply_resource_profiles(fabric_cfg, why))
  else `uvm_fatal("DPU_TEST", why)
assert(fabric.lookup_resource_class("virtio.qpair", virtio_qpair_class_id, why))
  else `uvm_fatal("DPU_TEST", why)
assert(uvm_config_db#(dpu_resource_manager)::get(
  this, "fabric", "dpu_resource_manager", rm))
  else `uvm_fatal("DPU_TEST", why)
assert(!rm.register_resource_class(virtio_qpair_profile.name, virtio_qpair_profile.kind,
                                   virtio_qpair_profile.capacity,
                                   virtio_qpair_profile.max_per_function,
                                   rejected_class_id, why))
  else `uvm_error("DPU_TEST", "sealed Fabric registry accepted direct QP registration")
rm.configure_mmio_aperture(64'h0001_0000_0000_0000, 64'h0001_0010_0000_0000);
assert(rm.activate_function(pf_key, pf_bars, why)) else `uvm_fatal("DPU_TEST", why)
assert(pf_bars[0].role == DPU_BAR_FUNCTION_DEVICE && pf_bars[0].even_bar_id == 0 && pf_bars[0].size == 32*1024*1024)
  else `uvm_error("DPU_TEST", "PF BAR0/1 layout is wrong")
assert(pf_bars[1].role == DPU_BAR_RESERVED && pf_bars[1].even_bar_id == 2 && pf_bars[1].size == 64*1024)
  else `uvm_error("DPU_TEST", "PF BAR2/3 layout is wrong")
assert(pf_bars[2].role == DPU_BAR_MSIX && pf_bars[2].even_bar_id == 4 && pf_bars[2].size == 64*1024)
  else `uvm_error("DPU_TEST", "PF BAR4/5 layout is wrong")
assert(!rm.acquire_leases(pf_key, virtio_qpair_class_id, 0, 1, leases_a, why))
  else `uvm_error("DPU_TEST", "QP allocation succeeded before function readiness")
assert(rm.mark_function_device_ready(pf_key, why)) else `uvm_fatal("DPU_TEST", why)
assert(rm.acquire_leases(pf_key, virtio_qpair_class_id, 0, 32, leases_a, why)) else `uvm_fatal("DPU_TEST", why)
assert(!rm.acquire_leases(pf_key, virtio_qpair_class_id, 32, 33, leases_b, why))
  else `uvm_error("DPU_TEST", "per-device QP limit accepted")
```

`dpu_fabric_env` alone applies `resource_profiles[$]` before any function activation; the unit test calls the same manager contract to verify its semantics. For `host_id in [0:3]` and `pf_id in [0:15]`, activate and mark each of the 64 PF functions ready, then acquire local QP IDs `[0:31]` using the one returned `virtio_qpair_class_id`. This exactly consumes the global 2,048-QP profile. Activate and ready a registered VF, verify its next lease fails, release the PF at `(0,0)`, then verify the VF can acquire a lease. This proves global exhaustion and recovery without a manager-side virtio-specific API or an invalid request for more than 1,024 functions.

- [ ] **Step 2: Run the new test to verify it fails**

Run: `make test TEST=dpu_resource_manager_test`

Expected: failure because no lease methods exist.

- [ ] **Step 3: Implement allocation, lookup and lifecycle methods**

Implement these public methods on `dpu_resource_manager`:

```systemverilog
class dpu_resource_manager extends uvm_object;
  `uvm_object_utils(dpu_resource_manager)

  function bit register_function(dpu_function_key_t key, output string why);
  function void configure_mmio_aperture(bit [63:0] base, bit [63:0] limit);
  function bit register_resource_class(
    string name, dpu_resource_kind_e kind,
    int unsigned capacity, int unsigned max_per_function,
    output dpu_resource_class_id_t class_id, output string why);
  function bit lookup_resource_class(string name,
                                     output dpu_resource_class_id_t class_id,
                                     output string why);
  function bit seal_resource_classes(output string why);
  function bit activate_function(dpu_function_key_t key, ref dpu_bar_pair_lease_t bars[$], output string why);
  function bit mark_function_device_ready(dpu_function_key_t key, output string why);
  function bit acquire_leases(
    dpu_function_key_t key, dpu_resource_class_id_t class_id,
    int unsigned first_local_id, int unsigned count,
    ref dpu_resource_lease_t leases[$], output string why);
  function bit release_leases(dpu_function_key_t key, dpu_resource_class_id_t class_id,
                              output string why);
  function bit freeze_function(dpu_function_key_t key, output string why);
  function bit restore_function(dpu_function_key_t key, output string why);
  function bit local_to_global(dpu_function_key_t key, dpu_resource_class_id_t class_id,
                               int unsigned local_id, output int unsigned global_id);
endclass : dpu_resource_manager

class dpu_fabric_env_config extends uvm_object;
  `uvm_object_utils(dpu_fabric_env_config)
  dpu_resource_pool_config_t resource_profiles[$];
endclass : dpu_fabric_env_config

class dpu_fabric_env extends uvm_env;
  function bit apply_resource_profiles(
    dpu_fabric_env_config cfg, output string why);
  function bit lookup_resource_class(
    string name, output dpu_resource_class_id_t class_id, output string why);
endclass : dpu_fabric_env
```

`activate_function()` first validates the hierarchy/function count, then allocates three aligned non-overlapping 64-bit BAR pairs from the configured MMIO aperture: PF `{BAR0/1:32 MiB function-device, BAR2/3:64 KiB reserved, BAR4/5:64 KiB MSI-X}` and VF `{BAR0/1:16 KiB function-device, BAR2/3:16 KiB reserved, BAR4/5:32 KiB MSI-X}`. It emits only even BAR leases; the caller writes each base low/high to its even/odd PCI config slots. BAR2/3 is a consumed but unbound reservation: its lease is retained solely for config programming and ownership tracking, and is never exposed through a functional MMIO accessor. `mark_function_device_ready()` is called only after the client has completed BAR0/1 discovery.

`register_resource_class()` validates and records a Fabric-supplied opaque label, generic kind, capacity and per-function quota, then returns an opaque ID. Equal name+kind+capacity+quota registration is idempotent and returns the existing ID before sealing; a reused name with any different profile fails. `lookup_resource_class()` returns an existing ID by name. `seal_resource_classes()` rejects every subsequent direct registration, including an otherwise identical profile, after Fabric has applied all profiles. The manager never branches on a label or derives protocol behavior from an ID. `acquire_leases()` accepts only a registered ID, assigns unique global IDs, rejects duplicate local IDs, and is unavailable before device readiness or while frozen. `dpu_fabric_env::apply_resource_profiles()` is the only registration path: it applies `dpu_fabric_env_config.resource_profiles[$]`, registers the `"virtio.qpair"` profile once with kind `DPU_RESOURCE_KIND_QUEUE`, capacity 2048 and per-function limit 32, then seals and exposes lookup/injected IDs. Clients only lookup/inherit that ID, acquire one lease per QP, and derive RX/TX IDs as `2*global_id` and `2*global_id+1`. The manager registration path belongs solely to Fabric. RDMA and block support adds Fabric profile data and client lookup only. Reject a duplicate function key, invalid hierarchy, insufficient aperture, an unregistered ID, an unready/frozen function, count zero, quota violation and exhausted capacity. `release_leases()` removes only the requesting function/class leases. `freeze_function` retains BAR/resource ownership and blocks new allocation; `restore_function` unfreezes it.

`dpu_fabric_env` creates exactly one manager in `build_phase`, and its public `apply_resource_profiles(dpu_fabric_env_config cfg, output string why)` reads generic `cfg.resource_profiles[$]`, calls `register_resource_class()` for every profile before any function activation, stores each returned `class_id`, seals the registry only after all profiles are registered, and then places the manager plus injected/lookupable IDs into `uvm_config_db#(dpu_resource_manager)` for child protocol environments. Its public `lookup_resource_class(name, class_id, why)` delegates to the registered registry for clients. It is the sole registration owner; manager registration is reachable only through this Fabric environment.

- [ ] **Step 4: Run focused tests**

Run: `make test TEST=dpu_resource_manager_test`

Expected: PASS with explicit log lines for function capacity, each BAR-pair layout, QP-before-readiness rejection, QP exhaustion, release and frozen-function rejection.

- [ ] **Step 5: Commit the resource authority**

```bash
git add dpu_common/src dpu_common/tests/dpu_resource_manager_test.sv
git commit -m "feat: add DPU fabric resource manager"
```

### Task 4: Model PF and VF as independent virtio functions

**Files:**
- Create: `virtio_net_vip/src/sriov/virtio_function_instance.sv`, `virtio_net_vip/src/sriov/virtio_pf_instance.sv`, `virtio_net_vip/src/sriov/virtio_resource_client.sv`
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv`, `virtio_net_vip/src/env/virtio_net_env_config.sv`, `virtio_net_vip/src/env/virtio_net_env.sv`, `virtio_net_vip/src/env/virtio_virtual_sequencer.sv`, `virtio_net_vip/src/sriov/virtio_pf_manager.sv`, `virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv`, `virtio_net_vip/src/virtio_net_pkg.sv`
- Test: `virtio_net_vip/tests/virtio_fabric_resource_test.sv`

- [ ] **Step 1: Write failing function-topology tests**

Create a test that configures two hosts, two PFs per host and different VF counts. Assert a PF `transport.is_vf == 0`, a VF `transport.is_vf == 1`, each active function has three distinct aligned BAR-pair bindings, BAR0/1 is the only function-device window (and the virtio client's capability-discovery window), BAR2/3 has role `DPU_BAR_RESERVED` with no transport binding, BAR4/5 is the only MSI-X table/PBA window, and local queue ID 0 maps to distinct global QPs for two VFs. Inject a raw PCIe memory transaction to BAR2/3 and require one reserved-BAR monitor error.

```systemverilog
assert(!env.pf_instances[0].pf_function.transport.is_vf)
  else `uvm_error("FABRIC_TEST", "PF was modeled as VF")
assert(env.pf_instances[0].vf_functions[0].transport.is_vf)
  else `uvm_error("FABRIC_TEST", "VF lost its function kind")
assert(qp_a.global_id != qp_b.global_id)
  else `uvm_error("FABRIC_TEST", "different functions share one QP lease")
```

- [ ] **Step 2: Run to verify the old single-PF model fails**

Run: `make test TEST=virtio_fabric_resource_test`

Expected: compile failure for `pf_instances`, then an assertion failure if temporarily adapted to the old `vf_instances` model.

- [ ] **Step 3: Implement topology and client mapping**

Add topology fields `num_hosts`, `max_hosts`, `num_pfs_per_host[]`, `num_vfs_per_pf[][]`, `max_pfs_per_host`, `max_vfs_per_pf`, and `max_functions` to `virtio_net_env_config`; `validate()` must reject values over the DPU limits and a requested active count over 1024.

`virtio_function_instance` owns one driver agent, transport, queue manager, dataplane, `dpu_function_key_t`, and three `dpu_bar_pair_lease_t` records; its `configure_function()` receives function kind, BDF, BAR leases and resource manager. Program BAR0/1, BAR2/3 and BAR4/5 into config space before transport discovery. Bind `transport.bar.bar_base[0]` only to BAR0/1 and add an MSI-X table/PBA aperture binding only to BAR4/5; BAR2/3 has no functional accessor and a direct TLP to it is classified as a reserved-BAR monitor error. `virtio_pf_instance` owns one PF function plus `vf_functions[]` and its PF manager. Preserve a compatibility `virtio_vf_instance` wrapper extending `virtio_function_instance` and forcing `DPU_FUNCTION_VF` until external users migrate.

During Fabric configuration, `dpu_fabric_env` pre-registers the `"virtio.qpair"` `DPU_RESOURCE_KIND_QUEUE` 2048/32 profile once, seals the registry, and injects its `virtio_qpair_class_id`; `virtio_resource_client` only looks up/inherits that existing ID during binding. After `transport.discover_and_init_bars()` validates BAR0/1 virtio capabilities, the client calls `mark_function_device_ready()` then `acquire_leases(key, virtio_qpair_class_id, ...)`. It stores `{local_pair, rx_global_qid, tx_global_qid}` and exposes `local_qid_to_global_qid()`. It alone derives RX/TX IDs from its generic lease IDs. Reserve at queue setup, release the saved class ID at teardown/FLR/disable, freeze before migration and restore after migration. Update `virtio_vf_resource_pool` to become a local view keyed by full function key and never increment `next_global_qid`.

- [ ] **Step 4: Run topology and existing unit tests**

Run: `make test TEST=virtio_fabric_resource_test && make test TEST=virtio_unit_test`

Expected: both PASS; resource logs show unique BAR/QP ownership and PF/VF function kinds.

- [ ] **Step 5: Commit function topology**

```bash
git add virtio_net_vip/src/types virtio_net_vip/src/env virtio_net_vip/src/sriov virtio_net_vip/src/virtio_net_pkg.sv virtio_net_vip/tests/virtio_fabric_resource_test.sv
git commit -m "feat: model DPU PF and VF virtio functions"
```

### Task 5: Make PCIe binding and TLM completion public infrastructure

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_tlm_completion_adapter.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`, `virtio_net_vip/src/env/virtio_net_env.sv`, `virtio_net_vip/src/env/virtio_virtual_sequencer.sv`, `virtio_net_vip/src/transport/virtio_bar_accessor.sv`, `virtio_net_vip/src/virtio_net_pkg.sv`, `virtio_net_vip/tests/virtio_e2e_test.sv`, `virtio_net_vip/tests/virtio_full_test.sv`, `virtio_net_vip/tests/virtio_dual_test.sv`
- Test: `virtio_net_vip/tests/virtio_e2e_test.sv`, `virtio_net_vip/tests/virtio_full_test.sv`

- [ ] **Step 1: Add a failing no-copy binding test**

Replace the manual wiring block in `virtio_e2e_test` with one call:

```systemverilog
virtio_env.bind_pcie(pcie_env.rc_agent.sequencer, tlm_adapter);
```

Build the test before adding the method.

- [ ] **Step 2: Verify failure**

Run: `make compile TEST=virtio_e2e_test`

Expected: method-not-found error for `bind_pcie`.

- [ ] **Step 3: Implement typed binding and bridge**

Use `uvm_sequencer #(pcie_tl_tlp)` throughout the virtual sequencer and function binding API. `bind_pcie()` must create/wire ops and FSM for every active function, assign `driver.ops`, `driver.fsm`, `monitor.transport`, and `monitor.vq_mgr` directly, and raise UVM fatal on a null sequencer.

Move `virtio_cpl_bridge`, RC driver shim and bridged BAR sequence implementations from `virtio_full_test.sv` into `virtio_tlm_completion_adapter.sv`. The adapter exposes `install_factory_overrides()`, `bind_rc_driver()`, `drain()`, and `wait_completion()`. Tests create one adapter, install it before `pcie_tl_env` construction, then call `bind_pcie`; no test may redefine bridge classes.

- [ ] **Step 4: Run integration checks**

Run: `make test TEST=virtio_e2e_test && make test TEST=virtio_full_integration_test`

Expected: PASS; no test source contains `replicate wire_shared logic`, `class virtio_cpl_bridge`, or a direct assignment to `pcie_rc_seqr` outside the binding API.

- [ ] **Step 5: Commit public integration layer**

```bash
git add virtio_net_vip/src/transport virtio_net_vip/src/sriov virtio_net_vip/src/env virtio_net_vip/tests/virtio_e2e_test.sv virtio_net_vip/tests/virtio_full_test.sv virtio_net_vip/tests/virtio_dual_test.sv
git commit -m "feat: centralize virtio PCIe and TLM binding"
```

### Task 6: Complete passive monitor, scoreboard, coverage and SVA closure

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_pcie_observer_adapter.sv`, `virtio_net_vip/src/agent/virtio_protocol_event_if.sv`, `virtio_net_vip/src/agent/virtio_protocol_assertions.sv`, `virtio_net_vip/tests/virtio_monitor_test.sv`, `virtio_net_vip/tests/virtio_coverage_test.sv`
- Modify: `virtio_net_vip/src/agent/virtio_monitor.sv`, `virtio_net_vip/src/agent/virtio_driver_agent.sv`, `virtio_net_vip/src/env/virtio_net_env.sv`, `virtio_net_vip/src/env/virtio_scoreboard.sv`, `virtio_net_vip/src/env/virtio_coverage.sv`, `virtio_net_vip/src/virtio_net_pkg.sv`, `virtio_net_vip/tests/virtio_tb_top.sv`

- [ ] **Step 1: Write monitor and assertion failure tests**

Inject synthetic decoded BAR events for `RESET -> DRIVER_OK`, a DMA event outside a mapped range, and a notify for an unconfigured queue. Expect three monitor errors. Inject `RESET -> ACKNOWLEDGE -> DRIVER -> FEATURES_OK -> DRIVER_OK` and expect one broadcast transaction per event plus zero protocol errors.

```systemverilog
mon.observe_status_write(DEV_STATUS_RESET, DEV_STATUS_DRIVER_OK);
assert(error_count == 1) else `uvm_error("MON_TEST", "illegal status accepted")
mon.observe_queue_notify(99);
assert(error_count == 2) else `uvm_error("MON_TEST", "invalid queue notify accepted")
```

- [ ] **Step 2: Run the failure test**

Run: `make test TEST=virtio_monitor_test`

Expected: compile failure because observation API and protocol event interface do not exist.

- [ ] **Step 3: Implement event-driven observation and SVA**

`virtio_pcie_observer_adapter` decodes external PCIe monitor transactions into `observe_bar_access`, `observe_dma`, `observe_interrupt`, and `observe_queue_state` calls. `virtio_monitor` owns analysis FIFOs/events instead of four empty tasks and broadcasts a populated `virtio_transaction` for every decoded event.

Define `virtio_protocol_event_if` with clocked booleans `status_write`, `features_ok`, `driver_ok`, `queue_configured`, `queue_enabled`, `notify`, and `completion`, with queue/status payloads. Add properties equivalent to:

```systemverilog
property p_driver_ok_requires_features_ok;
  @(posedge clk) driver_ok |-> features_ok_seen;
endproperty
assert property (p_driver_ok_requires_features_ok);
property p_notify_requires_enabled_queue;
  @(posedge clk) notify |-> queue_enabled;
endproperty
assert property (p_notify_requires_enabled_queue);
```

Connect monitor `txn_ap` to scoreboard and coverage for every active PF/VF function. Coverage tests must enable all 8 existing covergroups and call `get_inst_coverage()` in report phase; fail the test if any targeted group remains at zero.

- [ ] **Step 4: Run monitor and coverage tests**

Run: `make test TEST=virtio_monitor_test && make test TEST=virtio_coverage_test`

Expected: PASS; legal trace has no errors, illegal trace produces the three expected errors, and every targeted covergroup has nonzero sampled coverage.

- [ ] **Step 5: Commit verification closure**

```bash
git add virtio_net_vip/src/agent virtio_net_vip/src/transport virtio_net_vip/src/env virtio_net_vip/tests/virtio_monitor_test.sv virtio_net_vip/tests/virtio_coverage_test.sv virtio_net_vip/tests/virtio_tb_top.sv
git commit -m "feat: add virtio passive monitoring and protocol assertions"
```

### Task 7: Implement split and packed indirect descriptors

**Files:**
- Modify: `virtio_net_vip/src/virtqueue/virtqueue_base.sv`, `virtio_net_vip/src/virtqueue/split_virtqueue.sv`, `virtio_net_vip/src/virtqueue/packed_virtqueue.sv`, `virtio_net_vip/src/virtqueue/virtqueue_error_injector.sv`
- Create: `virtio_net_vip/tests/virtio_indirect_desc_test.sv`

- [ ] **Step 1: Write failing split and packed tests**

For each queue type submit three SG entries with `indirect=1`. Verify one main-ring descriptor is consumed, indirect-table memory is nonzero, its head flags include `VIRTQ_DESC_F_INDIRECT`, completion restores all resources, and a nested-indirect request is rejected.

```systemverilog
head = vq.add_buf(sgs, 1, 1, token, 1'b1);
assert(head != '1) else `uvm_fatal("INDIRECT", "indirect submit failed")
assert(vq.get_free_count() == queue_size - 1)
  else `uvm_error("INDIRECT", "main ring consumed more than one descriptor")
```

- [ ] **Step 2: Run to verify failure**

Run: `make test TEST=virtio_indirect_desc_test`

Expected: assertion failure because current `add_buf()` ignores `indirect` and consumes one descriptor per SG entry.

- [ ] **Step 3: Implement indirect-table ownership**

Add an `indirect_table_record_t` keyed by main descriptor/head ID: GPA, IOVA, byte size, entry count and token. For `indirect=1`, allocate `total_sgs * 16` bytes aligned to 16, map it for the device, write SG descriptors with `NEXT`/`WRITE`, then create one main descriptor with address=indirect IOVA, len=table byte size and flags=`VIRTQ_DESC_F_INDIRECT` plus packed availability bits where required. Reject `total_sgs==0`, an indirect request whose SG entry already uses indirect semantics, unaligned/overflow table size, and allocation/map failure.

On `poll_used`, `reset_queue`, `detach_all_unused` and `free_rings`, unmap/free the matching table and delete its record. Retain the main descriptor token map only at the head.

- [ ] **Step 4: Run indirect regression**

Run: `make test TEST=virtio_indirect_desc_test && make test TEST=virtio_stress_unit_test`

Expected: PASS; split and packed queues return to their original free count and leak checks report no table/IOMMU mappings.

- [ ] **Step 5: Commit indirect descriptor support**

```bash
git add virtio_net_vip/src/virtqueue virtio_net_vip/tests/virtio_indirect_desc_test.sv
git commit -m "feat: implement indirect virtqueue descriptors"
```

### Task 8: Implement Admin VQ request/completion lifecycle

**Files:**
- Modify: `virtio_net_vip/src/sriov/virtio_pf_manager.sv`, `virtio_net_vip/src/agent/virtio_atomic_ops.sv`, `virtio_net_vip/src/types/virtio_net_types.sv`
- Create: `virtio_net_vip/tests/virtio_admin_vq_test.sv`

- [ ] **Step 1: Write Admin VQ success and error tests**

Test a configured PF Admin VQ with a request payload and a mock used-ring completion. Verify returned status/payload. Add separate checks for inactive target VF, missing negotiated Admin-VQ feature, missing special-VQ lease, device failure status and completion timeout.

```systemverilog
pf_mgr.admin_cmd(valid_vf, request, response, ok);
assert(ok && response.size() == 2 && response[0] == 8'h00)
  else `uvm_error("ADMIN_VQ", "admin completion was not decoded")
```

- [ ] **Step 2: Run to verify failure**

Run: `make test TEST=virtio_admin_vq_test`

Expected: failure because the current stubbed success result performs no queue submission or timeout behavior.

- [ ] **Step 3: Implement real submission**

Extend `admin_cmd()` to return `bit ok`. It must validate PF Admin-VQ feature/lease and target function, allocate request and response buffers, construct one output plus one input SG descriptor chain, call `add_buf`, kick, and use `wait_pol` to poll completion. Decode the first response byte as device status and copy the remaining bytes to the caller. Always unmap/free request/response buffers and release descriptor ownership in success, device-error and timeout paths.

- [ ] **Step 4: Run Admin VQ regression**

Run: `make test TEST=virtio_admin_vq_test`

Expected: PASS; timeout and device rejection return `ok==0`, while the successful path returns the exact mock result payload.

- [ ] **Step 5: Commit Admin VQ implementation**

```bash
git add virtio_net_vip/src/sriov/virtio_pf_manager.sv virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/types/virtio_net_types.sv virtio_net_vip/tests/virtio_admin_vq_test.sv
git commit -m "feat: implement virtio Admin VQ commands"
```

### Task 9: Snapshot dirty pages and validate migration restore

**Files:**
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv`, `virtio_net_vip/src/iommu/virtio_iommu_model.sv`, `virtio_net_vip/src/agent/virtio_auto_fsm.sv`, `virtio_net_vip/src/sriov/virtio_function_instance.sv`
- Create: `virtio_net_vip/tests/virtio_migration_dirty_test.sv`

- [ ] **Step 1: Write dirty-page migration tests**

Write bytes on both sides of a 4 KiB boundary after enabling tracking, freeze, and assert two page IDs are captured. Restore unchanged backing memory and expect success. Corrupt one captured page before restore and expect a UVM error plus failed restore status.

```systemverilog
assert(snapshot.dirty_pages.size() == 2)
  else `uvm_error("MIGRATION", "cross-page dirty set was not saved")
assert(!restore_ok_after_corruption)
  else `uvm_error("MIGRATION", "corrupted dirty page was accepted")
```

- [ ] **Step 2: Run to verify failure**

Run: `make test TEST=virtio_migration_dirty_test`

Expected: compile failure for snapshot dirty-page fields, then failure because freeze ignores dirty tracking.

- [ ] **Step 3: Implement snapshot generation and validation**

Add `dirty_generation`, `bit [63:0] dirty_pages[$]`, and per-page checksum records to `virtio_device_snapshot_t`. Add IOMMU methods `begin_dirty_generation()` and `capture_dirty_generation()` so capture atomically returns only pages dirtied after the begin call. `freeze_for_migration()` enables the generation before stopping data plane, saves queues, captures dirty pages, reads each 4 KiB page from host memory and stores checksum. `restore_from_migration()` verifies mapping and checksum for every saved dirty page before restoring queues; it returns `bit ok` and does not restart dataplane on mismatch.

- [ ] **Step 4: Run migration tests**

Run: `make test TEST=virtio_migration_dirty_test && make test TEST=virtio_protocol_test`

Expected: PASS; clean restore resumes, corrupted-page restore fails deterministically, and existing protocol tests stay green.

- [ ] **Step 5: Commit migration validation**

```bash
git add virtio_net_vip/src/types/virtio_net_types.sv virtio_net_vip/src/iommu/virtio_iommu_model.sv virtio_net_vip/src/agent/virtio_auto_fsm.sv virtio_net_vip/src/sriov/virtio_function_instance.sv virtio_net_vip/tests/virtio_migration_dirty_test.sv
git commit -m "feat: validate dirty pages across virtio migration"
```

### Task 10: Run the complete regression and document supported deployment

**Files:**
- Modify: `README.md`, `docs/virtio_net_vip_manual.md`, `Makefile`, `scripts/vcs.sh`
- Test: all tests listed by `make regression`

- [ ] **Step 1: Add regression manifest checks**

Make `regression` enumerate these exact test names: `dpu_resource_manager_test`, `virtio_fabric_resource_test`, `virtio_unit_test`, `virtio_stress_unit_test`, `virtio_protocol_test`, `virtio_indirect_desc_test`, `virtio_admin_vq_test`, `virtio_migration_dirty_test`, `virtio_monitor_test`, `virtio_coverage_test`, `virtio_e2e_test`, and `virtio_full_integration_test`.

- [ ] **Step 2: Run before final documentation update**

Run: `make regression`

Expected: all listed tests PASS when VCS is available. If VCS is unavailable, `make check-deps` must fail before compilation with exit code `3` and the documentation must state that dynamic simulation was not executed in that environment.

- [ ] **Step 3: Document exact operating model**

Update README/manual with the 4-host/16-PF/16-VF-local/1024-function-global limits, the Fabric-owned virtio QP profile of 2048 global QPs and 32 QPs/function (not DPU enum constants), the fact that full-PF activation leaves 960 active VF slots, and the BAR-first mapping: PF `BAR0/1=32 MiB function-device`, `BAR2/3=64 KiB reserved`, `BAR4/5=64 KiB MSI-X table/PBA`; VF `BAR0/1=16 KiB function-device`, `BAR2/3=16 KiB reserved`, `BAR4/5=32 KiB MSI-X table/PBA`. State that current virtio capability discovery is only in BAR0/1, BAR2/3 consumes address space but has no binding and all functional accesses are violations, and BAR4/5 is only MSI-X table/PBA. Document 64-bit MMIO aperture configuration, alignment/no-overlap checks, Fabric pre-registration and sealing of opaque class IDs before function activation, capability discovery before dynamic-resource acquisition, the generic resource-pool/lease API as the future RDMA/virtio-blk integration point, and special-VQ capacity as a separate Fabric profile.

- [ ] **Step 4: Run final repository verification**

Run:

```bash
git diff --check
git submodule status --recursive
make check-deps
make regression
git status --short
```

Expected: no whitespace errors, exactly three pinned submodule SHAs, successful dependency validation, successful regression when VCS is installed, and only intentional tracked changes before the final commit.

- [ ] **Step 5: Commit regression/docs**

```bash
git add README.md docs/virtio_net_vip_manual.md Makefile scripts/vcs.sh
git commit -m "docs: document DPU fabric virtio validation flow"
```

## Plan Self-Review

- Spec coverage: Tasks 1 and 10 cover reproducible dependencies/build; Tasks 2–4 cover DPU Fabric, PF/VF function isolation, BAR and global QP mapping; Task 5 covers PCIe binding and TLM bridge; Task 6 covers monitor, scoreboard, coverage and SVA; Tasks 7–9 cover indirect descriptors, Admin VQ and dirty-page migration.
- Deferred-work scan: no deferred implementation markers are present; each task names files, APIs, test cases and commands.
- Type consistency: Tasks 2–4 define `dpu_function_key_t`, `dpu_resource_lease_t`, `dpu_resource_pool_config_t`, `dpu_resource_manager`, `dpu_resource_pkg`, `dpu_fabric_env`, and the generic resource-pool/lease APIs before the virtio client consumes them.
