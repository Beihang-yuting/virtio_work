# DUT Capability and VIO Qpair Limit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a single real-DUT capability object and enforce that every PF or VF VIO-net device owns one notify-address domain with at most 32 local queue pairs numbered `0..31`.

**Architecture:** `dpu_dut_caps` becomes the immutable capability source passed from `virtio_net_env_config` through `dpu_fabric_env_config` into the generic resource manager and VIO client. Compile-time `DPU_MAX_*` constants remain model/encoding ceilings, while the default capability profile is the real DUT (`2 hosts × 4 PFs × 16 VFs`, 2048 encoded global qpairs, 32 qpairs/device). Validation occurs at topology construction, driver configuration, dynamic MQ resize, and the final Fabric lease boundary; the existing generic `max_per_function` quota remains defense in depth.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS on `10.11.10.53`, GNU Make, Bash/rsync/SSH.

---

## Scope boundaries

This plan implements only subproject 1 from the umbrella design.  It does not
add PINNED/PREFERRED global ID allocation, change the existing RX/TX global-ID
derivation, program DUT register tables, or fix PCIe Memory Write payload
propagation.  Those belong to later subprojects.

All simulations run on `10.11.10.53` in a Bash login shell.  Each command below
copies the current uncommitted worktree into a fresh remote staging directory,
so RED tests are executed before production changes are committed.

### Task 1: Add the DUT capability source and enforce it in Fabric topology

**Files:**
- Modify: `dpu_common/src/dpu_resource_types.sv`
- Create: `dpu_common/src/dpu_dut_caps.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/src/dpu_fabric_env.sv`
- Modify: `dpu_common/src/dpu_resource_manager.sv`
- Create: `virtio_net_vip/tests/virtio_dut_caps_test.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`
- Modify: `dpu_common/tests/dpu_resource_manager_test.sv`

- [ ] **Step 1: Add the focused capability test before the capability type exists**

Add `virtio_net_vip/tests/virtio_dut_caps_test.sv` with the initial topology
contract:

```systemverilog
`ifndef VIRTIO_DUT_CAPS_TEST_SV
`define VIRTIO_DUT_CAPS_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

class virtio_dut_caps_test extends uvm_test;
    `uvm_component_utils(virtio_dut_caps_test)

    dpu_fabric_env fabric;
    dpu_fabric_env_config fabric_cfg;
    dpu_resource_manager manager;
    dpu_function_key_t valid_pf;
    dpu_function_key_t valid_vf;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_key(
        int unsigned host_id,
        int unsigned pf_id,
        dpu_function_kind_e kind,
        int unsigned vf_id
    );
        dpu_function_key_t key;
        key.host_id = host_id;
        key.pf_id = pf_id;
        key.kind = kind;
        key.vf_id = vf_id;
        return key;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        fabric_cfg = dpu_fabric_env_config::type_id::create("fabric_cfg");
        fabric = dpu_fabric_env::type_id::create("fabric", this);
    endfunction

    task assert_real_dut_capability_defaults();
        dpu_dut_caps invalid_caps;
        string why;

        if ((fabric_cfg.dut_caps.max_hosts != 2) ||
            (fabric_cfg.dut_caps.max_pfs_per_host != 4) ||
            (fabric_cfg.dut_caps.max_vfs_per_pf != 16) ||
            (fabric_cfg.dut_caps.vio_global_qpair_count != 2048) ||
            (fabric_cfg.dut_caps.max_vio_net_qpairs_per_device != 32)) begin
            `uvm_fatal("DUT_CAPS", "default real-DUT capability profile is incorrect")
        end

        invalid_caps = dpu_dut_caps::type_id::create("invalid_caps");
        invalid_caps.max_vio_net_qpairs_per_device = 33;
        if (invalid_caps.validate(why)) begin
            `uvm_fatal("DUT_CAPS", "capability profile accepted 33 VIO qpairs/device")
        end
    endtask

    task configure_fabric();
        dpu_resource_pool_config_t qpair_profile;
        string why;

        fabric_cfg.mmio_aperture_base = 64'h0001_0000_0000_0000;
        fabric_cfg.mmio_aperture_limit = 64'h0001_0100_0000_0000;
        qpair_profile.name = "virtio.qpair";
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = fabric_cfg.dut_caps.vio_global_qpair_count;
        qpair_profile.max_per_function =
            fabric_cfg.dut_caps.max_vio_net_qpairs_per_device;
        fabric_cfg.resource_profiles.push_back(qpair_profile);
        if (!fabric.apply_resource_profiles(fabric_cfg, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf("Fabric configuration failed: %s", why))
        end
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "fabric", "dpu_resource_manager", manager
        )) begin
            `uvm_fatal("DUT_CAPS", "Fabric did not publish its resource manager")
        end
    endtask

    task assert_manager_topology_limits();
        dpu_function_key_t invalid_key;
        string why;

        valid_pf = make_key(0, 0, DPU_FUNCTION_PF, 0);
        if (!manager.register_function(valid_pf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid PF rejected: %s", why))

        invalid_key = make_key(2, 0, DPU_FUNCTION_PF, 0);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "host_id 2 exceeded the real-DUT capability")

        invalid_key = make_key(0, 4, DPU_FUNCTION_PF, 0);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "pf_id 4 exceeded the real-DUT capability")

        valid_vf = make_key(0, 0, DPU_FUNCTION_VF, 15);
        if (!manager.register_function(valid_vf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid VF15 rejected: %s", why))

        invalid_key = make_key(0, 0, DPU_FUNCTION_VF, 16);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "vf_id 16 exceeded the real-DUT capability")
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        assert_real_dut_capability_defaults();
        configure_fabric();
        assert_manager_topology_limits();
        phase.drop_objection(this);
    endtask
endclass : virtio_dut_caps_test

`endif // VIRTIO_DUT_CAPS_TEST_SV
```

Add the test before `virtio_tb_top.sv` in `filelists/tests.f`:

```text
virtio_net_vip/tests/virtio_dut_caps_test.sv
```

Add it to `VIRTIO_MAINTAINED_TESTS` in `scripts/test_manifest.sh`:

```bash
  virtio_dut_caps_test
```

- [ ] **Step 2: Run the new test on 53 and verify RED**

Run from the repository worktree:

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-dut-caps-red-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test'"
```

Expected: compile fails because `dpu_dut_caps` and
`dpu_fabric_env_config::dut_caps` do not exist.  This is the intended RED
failure, not a VCS setup or licensing failure.

- [ ] **Step 3: Define encoding ceilings and the real-DUT capability object**

Append these model ceilings to `dpu_common/src/dpu_resource_types.sv` after the
existing function-count constants:

```systemverilog
localparam int unsigned DPU_VIO_GLOBAL_QPAIR_ID_WIDTH = 11;
localparam int unsigned DPU_MAX_VIO_GLOBAL_QPAIRS =
    (1 << DPU_VIO_GLOBAL_QPAIR_ID_WIDTH);
localparam int unsigned DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE = 32;
localparam int unsigned DPU_MAX_GLOBAL_MSIX_VECTORS = 256;
localparam int unsigned DPU_MAX_VIO_NOTIFY_ENTRIES_PER_BANK = 1024;
```

Create `dpu_common/src/dpu_dut_caps.sv`:

```systemverilog
`ifndef DPU_DUT_CAPS_SV
`define DPU_DUT_CAPS_SV

class dpu_dut_caps extends uvm_object;
    `uvm_object_utils(dpu_dut_caps)

    int unsigned max_hosts;
    int unsigned max_pfs_per_host;
    int unsigned max_vfs_per_pf;
    int unsigned max_functions;
    int unsigned global_msix_vector_count;
    int unsigned vio_global_qpair_count;
    int unsigned max_vio_net_qpairs_per_device;
    int unsigned vio_notify_entries_per_bank;

    function new(string name = "dpu_dut_caps");
        super.new(name);
        max_hosts = 2;
        max_pfs_per_host = 4;
        max_vfs_per_pf = 16;
        max_functions = DPU_MAX_FUNCTIONS;
        global_msix_vector_count = DPU_MAX_GLOBAL_MSIX_VECTORS;
        vio_global_qpair_count = DPU_MAX_VIO_GLOBAL_QPAIRS;
        max_vio_net_qpairs_per_device = DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        vio_notify_entries_per_bank = DPU_MAX_VIO_NOTIFY_ENTRIES_PER_BANK;
    endfunction

    function void copy_from(input dpu_dut_caps rhs);
        max_hosts = rhs.max_hosts;
        max_pfs_per_host = rhs.max_pfs_per_host;
        max_vfs_per_pf = rhs.max_vfs_per_pf;
        max_functions = rhs.max_functions;
        global_msix_vector_count = rhs.global_msix_vector_count;
        vio_global_qpair_count = rhs.vio_global_qpair_count;
        max_vio_net_qpairs_per_device = rhs.max_vio_net_qpairs_per_device;
        vio_notify_entries_per_bank = rhs.vio_notify_entries_per_bank;
    endfunction

    function bit validate(output string why);
        why = "";
        if ((max_hosts == 0) || (max_hosts > DPU_MAX_HOSTS)) begin
            why = "DUT host capability exceeds the model ceiling";
            return 0;
        end
        if ((max_pfs_per_host == 0) ||
            (max_pfs_per_host > DPU_MAX_PFS_PER_HOST)) begin
            why = "DUT PF capability exceeds the model ceiling";
            return 0;
        end
        if ((max_vfs_per_pf == 0) ||
            (max_vfs_per_pf > DPU_MAX_VFS_PER_PF)) begin
            why = "DUT VF capability exceeds the model ceiling";
            return 0;
        end
        if ((max_functions == 0) || (max_functions > DPU_MAX_FUNCTIONS)) begin
            why = "DUT function capability exceeds the model ceiling";
            return 0;
        end
        if ((global_msix_vector_count == 0) ||
            (global_msix_vector_count > DPU_MAX_GLOBAL_MSIX_VECTORS)) begin
            why = "DUT global MSI-X capability exceeds the model ceiling";
            return 0;
        end
        if ((vio_global_qpair_count == 0) ||
            (vio_global_qpair_count > DPU_MAX_VIO_GLOBAL_QPAIRS)) begin
            why = "DUT VIO global qpair capability exceeds the 11-bit ID domain";
            return 0;
        end
        if ((max_vio_net_qpairs_per_device == 0) ||
            (max_vio_net_qpairs_per_device >
             DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE)) begin
            why = "DUT VIO-net device capability exceeds 32 qpairs";
            return 0;
        end
        if ((vio_notify_entries_per_bank == 0) ||
            (vio_notify_entries_per_bank >
             DPU_MAX_VIO_NOTIFY_ENTRIES_PER_BANK)) begin
            why = "DUT VIO notify capability exceeds the model ceiling";
            return 0;
        end
        return 1;
    endfunction
endclass : dpu_dut_caps

`endif // DPU_DUT_CAPS_SV
```

Include it in `dpu_common/src/dpu_resource_pkg.sv` between resource types and
the resource manager:

```systemverilog
  `include "dpu_resource_types.sv"
  `include "dpu_dut_caps.sv"
  `include "dpu_resource_manager.sv"
```

- [ ] **Step 4: Pass capabilities through Fabric and enforce them in the manager**

Add `dpu_dut_caps dut_caps;` to `dpu_fabric_env_config` and construct it in
`new()`:

```systemverilog
    dpu_dut_caps dut_caps;

    function new(string name = "dpu_fabric_env_config");
        super.new(name);
        dut_caps = dpu_dut_caps::type_id::create("dut_caps");
    endfunction
```

In `dpu_resource_manager`, add a protected snapshot, initialize it in `new()`,
and add Fabric-authorized configuration plus a read-only snapshot method:

```systemverilog
    protected dpu_dut_caps dut_caps;

    function new(string name = "dpu_resource_manager");
        super.new(name);
        dut_caps = dpu_dut_caps::type_id::create("dut_caps");
        // retain the existing constructor initialization below
    endfunction

    function bit fabric_configure_dut_caps(
        input dpu_resource_fabric_authority authority,
        input dpu_dut_caps cfg,
        output string why
    );
        if (!fabric_registry_authority_claimed || (authority == null) ||
            (authority != fabric_registry_authority)) begin
            why = "DUT capability configuration requires the Fabric authority";
            return 0;
        end
        if (cfg == null) begin
            why = "DUT capability configuration is null";
            return 0;
        end
        if (function_states.num() != 0) begin
            why = "DUT capabilities cannot change after function registration";
            return 0;
        end
        if (!cfg.validate(why))
            return 0;
        dut_caps.copy_from(cfg);
        why = "";
        return 1;
    endfunction

    function dpu_dut_caps snapshot_dut_caps();
        dpu_dut_caps snapshot;
        snapshot = dpu_dut_caps::type_id::create("dut_caps_snapshot");
        snapshot.copy_from(dut_caps);
        return snapshot;
    endfunction
```

Replace constant checks in `validate_function_key()` with the capability
snapshot and replace the registration-count check:

```systemverilog
        if (key.host_id >= dut_caps.max_hosts) begin
            why = $sformatf("host_id %0d exceeds DUT max_hosts %0d",
                            key.host_id, dut_caps.max_hosts);
            return 0;
        end
        if (key.pf_id >= dut_caps.max_pfs_per_host) begin
            why = $sformatf("pf_id %0d exceeds DUT max_pfs_per_host %0d",
                            key.pf_id, dut_caps.max_pfs_per_host);
            return 0;
        end
        // Keep the existing PF vf_id==0 rule.
        if ((key.kind == DPU_FUNCTION_VF) &&
            (key.vf_id >= dut_caps.max_vfs_per_pf)) begin
            why = $sformatf("vf_id %0d exceeds DUT max_vfs_per_pf %0d",
                            key.vf_id, dut_caps.max_vfs_per_pf);
            return 0;
        end
```

```systemverilog
        if (function_states.num() >= dut_caps.max_functions) begin
            why = "DUT function registrations have been exhausted";
            return 0;
        end
```

In `dpu_fabric_env::apply_resource_profiles()`, configure capabilities after
the null/ordering guards and before MMIO/resource setup:

```systemverilog
        if (!resource_manager.fabric_configure_dut_caps(
            registry_authority, cfg.dut_caps, why
        ))
            return 0;
```

The existing `dpu_resource_manager_test` intentionally validates the larger
generic model envelope.  Before it calls `apply_resource_profiles()`, override
its test-only capability snapshot explicitly:

```systemverilog
        fabric_cfg.dut_caps.max_hosts = DPU_MAX_HOSTS;
        fabric_cfg.dut_caps.max_pfs_per_host = DPU_MAX_PFS_PER_HOST;
        fabric_cfg.dut_caps.max_vfs_per_pf = DPU_MAX_VFS_PER_PF;
        fabric_cfg.dut_caps.max_functions = DPU_MAX_FUNCTIONS;
```

- [ ] **Step 5: Run capability and manager tests on 53 and verify GREEN**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-dut-caps-green-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test && make TEST=dpu_resource_manager_test test'"
```

Expected: both tests finish with `UVM_ERROR : 0` and `UVM_FATAL : 0`.

- [ ] **Step 6: Commit the capability boundary**

```bash
git add dpu_common/src/dpu_resource_types.sv \
  dpu_common/src/dpu_dut_caps.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/src/dpu_fabric_env.sv \
  dpu_common/src/dpu_resource_manager.sv \
  dpu_common/tests/dpu_resource_manager_test.sv \
  virtio_net_vip/tests/virtio_dut_caps_test.sv \
  filelists/tests.f scripts/test_manifest.sh
git commit -m "feat: model real DUT capabilities"
```

### Task 2: Make virtio topology and initial queue configuration use DUT capabilities

**Files:**
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`

- [ ] **Step 1: Add failing topology and initial queue-count cases**

Add this catcher before `virtio_dut_caps_test` so deliberate `ENV_CFG` errors
do not fail the regression:

```systemverilog
class virtio_dut_caps_expected_cfg_error extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_dut_caps_expected_cfg_error");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "ENV_CFG")) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass
```

Add this task to the test and call it after
`assert_real_dut_capability_defaults()`:

```systemverilog
    task assert_virtio_config_uses_dut_caps();
        virtio_net_env_config cfg;
        virtio_dut_caps_expected_cfg_error catcher;

        catcher = new();
        uvm_report_cb::add(null, catcher);

        cfg = virtio_net_env_config::type_id::create("valid_32_qpair_cfg");
        cfg.default_num_pairs = 32;
        if (!cfg.validate())
            `uvm_fatal("DUT_CAPS", "32-qpair default configuration was rejected")

        cfg = virtio_net_env_config::type_id::create("invalid_33_qpair_cfg");
        cfg.default_num_pairs = 33;
        if (cfg.validate())
            `uvm_fatal("DUT_CAPS", "33-qpair default configuration was accepted")

        cfg = virtio_net_env_config::type_id::create("invalid_vf_qpair_cfg");
        cfg.vf_configs = new[1];
        cfg.vf_configs[0] = cfg.get_default_driver_config();
        cfg.vf_configs[0].num_queue_pairs = 33;
        if (cfg.validate())
            `uvm_fatal("DUT_CAPS", "VF configuration accepted 33 qpairs")

        cfg = virtio_net_env_config::type_id::create("invalid_host_cfg");
        cfg.num_hosts = 3;
        cfg.num_pfs_per_host = new[3];
        cfg.num_vfs_per_pf = new[3];
        foreach (cfg.num_pfs_per_host[host_id]) begin
            cfg.num_pfs_per_host[host_id] = 1;
            cfg.num_vfs_per_pf[host_id] = new[1];
        end
        if (cfg.validate())
            `uvm_fatal("DUT_CAPS", "three-host topology exceeded real-DUT caps")

        cfg = virtio_net_env_config::type_id::create("invalid_pf_cfg");
        cfg.num_hosts = 1;
        cfg.num_pfs_per_host = new[1];
        cfg.num_pfs_per_host[0] = 5;
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[5];
        if (cfg.validate())
            `uvm_fatal("DUT_CAPS", "five-PF topology exceeded real-DUT caps")

        cfg = virtio_net_env_config::type_id::create("invalid_vf_cfg");
        cfg.num_hosts = 1;
        cfg.num_pfs_per_host = new[1];
        cfg.num_pfs_per_host[0] = 1;
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[1];
        cfg.num_vfs_per_pf[0][0] = 17;
        if (cfg.validate())
            `uvm_fatal("DUT_CAPS", "17-VF topology exceeded real-DUT caps")

        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_count < 5)
            `uvm_fatal("DUT_CAPS", "expected invalid configurations were not reported")
    endtask
```

- [ ] **Step 2: Run the focused test on 53 and verify RED**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-env-caps-red-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test'"
```

Expected: the test reaches a fatal saying the 33-qpair configuration or a
topology above the real-DUT capability was accepted.

- [ ] **Step 3: Replace duplicated topology maxima with `dpu_dut_caps`**

In `virtio_net_env_config`, replace `max_hosts`, `max_pfs_per_host`,
`max_vfs_per_pf`, and `max_functions` with one field and initialize it:

```systemverilog
    dpu_dut_caps dut_caps;

    function new(string name = "virtio_net_env_config");
        super.new(name);
        dut_caps = dpu_dut_caps::type_id::create("dut_caps");
    endfunction
```

At the beginning of `validate()`, reject invalid capabilities and queue counts:

```systemverilog
        string caps_why;

        if ((dut_caps == null) || !dut_caps.validate(caps_why)) begin
            `uvm_error("ENV_CFG", $sformatf("invalid DUT capabilities: %s", caps_why))
            ok = 0;
        end
        else begin
            if ((default_num_pairs == 0) ||
                (default_num_pairs > dut_caps.max_vio_net_qpairs_per_device)) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "default_num_pairs=%0d exceeds VIO-net device limit %0d",
                    default_num_pairs,
                    dut_caps.max_vio_net_qpairs_per_device))
                ok = 0;
            end
            foreach (vf_configs[vf_id]) begin
                if ((vf_configs[vf_id].num_queue_pairs == 0) ||
                    (vf_configs[vf_id].num_queue_pairs >
                     dut_caps.max_vio_net_qpairs_per_device)) begin
                    `uvm_error("ENV_CFG", $sformatf(
                        "VF%0d num_queue_pairs=%0d exceeds VIO-net device limit %0d",
                        vf_id, vf_configs[vf_id].num_queue_pairs,
                        dut_caps.max_vio_net_qpairs_per_device))
                    ok = 0;
                end
            end
        end
```

Delete the old `configured topology maxima exceed DPU limits` block.  Replace
the runtime topology conditions in `validate()` with the following exact
capability checks while retaining the existing array-shape, BDF-overflow, and
total-count accumulation logic:

```systemverilog
            if ((num_hosts == 0) ||
                (num_hosts > dut_caps.max_hosts)) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "num_hosts=%0d exceeds DUT limit %0d",
                    num_hosts, dut_caps.max_hosts))
                ok = 0;
            end

            // Inside the host loop:
            if ((num_pfs_per_host[host_id] == 0) ||
                (num_pfs_per_host[host_id] >
                 dut_caps.max_pfs_per_host)) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "host %0d PF count %0d exceeds DUT limit %0d",
                    host_id, num_pfs_per_host[host_id],
                    dut_caps.max_pfs_per_host))
                ok = 0;
            end

            // Inside the PF loop:
            if (num_vfs_per_pf[host_id][pf_id] >
                dut_caps.max_vfs_per_pf) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "host %0d PF %0d VF count %0d exceeds DUT limit %0d",
                    host_id, pf_id,
                    num_vfs_per_pf[host_id][pf_id],
                    dut_caps.max_vfs_per_pf))
                ok = 0;
            end

            // After accumulating every PF and VF:
            if (total_functions > dut_caps.max_functions) begin
                `uvm_error("ENV_CFG", $sformatf(
                    "requested %0d functions exceeds DUT limit %0d",
                    total_functions, dut_caps.max_functions))
                ok = 0;
            end
```

Keep `DPU_MAX_PFS_PER_HOST` and `DPU_MAX_VFS_PER_PF` only in the BDF-stride
calculation; there they are model address-layout strides, not DUT runtime
limits.

- [ ] **Step 4: Derive the Fabric qpair profile from the same capability object**

In `virtio_net_env::configure_fabric_resources()`, replace the literal qpair
profile and pass a capability copy:

```systemverilog
        fabric_cfg.dut_caps.copy_from(cfg.dut_caps);
        qpair_profile.name = "virtio.qpair";
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = cfg.dut_caps.vio_global_qpair_count;
        qpair_profile.max_per_function =
            cfg.dut_caps.max_vio_net_qpairs_per_device;
```

- [ ] **Step 5: Run config and existing Fabric tests on 53 and verify GREEN**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-env-caps-green-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test && make TEST=virtio_fabric_resource_test test'"
```

Expected: both tests finish with zero UVM errors/fatals; the existing 2-host,
2-PF-per-host Fabric topology remains valid.

- [ ] **Step 6: Commit capability-driven virtio configuration**

```bash
git add virtio_net_vip/tests/virtio_dut_caps_test.sv \
  virtio_net_vip/src/env/virtio_net_env_config.sv \
  virtio_net_vip/src/env/virtio_net_env.sv
git commit -m "feat: validate virtio config against DUT caps"
```

### Task 3: Enforce local pair IDs `0..31` at the Fabric lease boundary

**Files:**
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_resource_client.sv`

- [ ] **Step 1: Add failing PF/VF lease-boundary cases**

Add this task to `virtio_dut_caps_test` and call it after
`assert_manager_topology_limits()`:

```systemverilog
    task assert_vio_local_qpair_limit();
        dpu_bar_pair_lease_t bars[$];
        virtio_resource_client pf_client;
        virtio_resource_client vf_client;
        string why;

        if (!manager.activate_function(valid_pf, bars, why) ||
            !manager.mark_function_device_ready(valid_pf, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf("PF readiness failed: %s", why))
        end
        if (!manager.activate_function(valid_vf, bars, why) ||
            !manager.mark_function_device_ready(valid_vf, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf("VF readiness failed: %s", why))
        end

        pf_client = virtio_resource_client::type_id::create("pf_client");
        vf_client = virtio_resource_client::type_id::create("vf_client");
        if (!pf_client.bind_to_fabric(manager, valid_pf, why) ||
            !pf_client.mark_device_ready(why) ||
            !vf_client.bind_to_fabric(manager, valid_vf, why) ||
            !vf_client.mark_device_ready(why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf("VIO client binding failed: %s", why))
        end

        if (!pf_client.reserve_qpairs(0, 32, why))
            `uvm_fatal("DUT_CAPS", $sformatf("PF rejected local pairs 0..31: %s", why))

        if (vf_client.reserve_qpairs(32, 1, why))
            `uvm_fatal("DUT_CAPS", "VF accepted local pair 32")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf("wrong pair-32 rejection: %s", why))

        if (vf_client.reserve_qpairs(31, 2, why))
            `uvm_fatal("DUT_CAPS", "VF accepted local pair range 31..32")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf("wrong range rejection: %s", why))

        if (!vf_client.reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf("VF local pair zero rejected: %s", why))
    endtask
```

The PF and VF both owning local pair zero proves local IDs are per-device, not
global.

- [ ] **Step 2: Run on 53 and verify RED**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-qpair-limit-red-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test'"
```

Expected: fatal `VF accepted local pair 32`; the current generic manager only
counts leases and does not constrain the local ID domain.

- [ ] **Step 3: Snapshot the capability in the VIO resource client and reject out-of-range IDs**

Add a capability snapshot to `virtio_resource_client`:

```systemverilog
    dpu_dut_caps dut_caps;
```

In `bind_to_fabric()`, after the qpair class lookup, snapshot the manager's
configured capabilities:

```systemverilog
        dut_caps = manager.snapshot_dut_caps();
        if (dut_caps == null) begin
            why = "virtio resource client requires DUT capabilities";
            return 0;
        end
```

In `reserve_qpairs()`, after readiness/freeze checks and before
`acquire_leases()`, add overflow-safe local-domain validation:

```systemverilog
        if ((first_local_pair >= dut_caps.max_vio_net_qpairs_per_device) ||
            (count > (dut_caps.max_vio_net_qpairs_per_device -
                      first_local_pair))) begin
            why = $sformatf(
                "VIO-net local qpair range exceeds device limit 0..%0d",
                dut_caps.max_vio_net_qpairs_per_device - 1);
            return 0;
        end
```

Do not special-case `count==0`; an in-range zero count continues to the generic
manager and retains its existing `lease count must be nonzero` error.

- [ ] **Step 4: Run focused and Fabric lifecycle tests on 53 and verify GREEN**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-qpair-limit-green-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test && make TEST=virtio_fabric_resource_test test'"
```

Expected: both tests finish with zero UVM errors/fatals.  Existing freeze,
restore, FLR, and shutdown lease cleanup remains green.

- [ ] **Step 5: Commit the final lease-boundary guard**

```bash
git add virtio_net_vip/tests/virtio_dut_caps_test.sv \
  virtio_net_vip/src/sriov/virtio_resource_client.sv
git commit -m "fix: bound VIO local qpairs per device"
```

### Task 4: Prevent dynamic MQ resize from bypassing the device limit

**Files:**
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv`
- Modify: `virtio_net_vip/src/env/virtio_dynamic_reconfig.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`

- [ ] **Step 1: Add a failing dynamic-resize capability test**

Add this task to `virtio_dut_caps_test` and call it before Fabric activation:

```systemverilog
    task assert_dynamic_resize_limit();
        virtio_dynamic_reconfig reconfig;

        reconfig = virtio_dynamic_reconfig::type_id::create("reconfig");
        if (!reconfig.qpair_count_supported(32))
            `uvm_fatal("DUT_CAPS", "dynamic resize rejected 32 qpairs")
        if (reconfig.qpair_count_supported(33))
            `uvm_fatal("DUT_CAPS", "dynamic resize accepted 33 qpairs")
        if (reconfig.qpair_count_supported(0))
            `uvm_fatal("DUT_CAPS", "dynamic resize accepted zero qpairs")
    endtask
```

- [ ] **Step 2: Run on 53 and verify RED**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-resize-limit-red-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test'"
```

Expected: compile fails because `qpair_count_supported()` does not exist.

- [ ] **Step 3: Add the dynamic-resize guard and inject the configured cap**

Add to `virtio_dynamic_reconfig`:

```systemverilog
    int unsigned max_vio_net_qpairs_per_device;

    function new(string name = "virtio_dynamic_reconfig");
        super.new(name);
        max_vio_net_qpairs_per_device = DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
    endfunction

    function bit qpair_count_supported(input int unsigned count);
        return (count != 0) &&
               (count <= max_vio_net_qpairs_per_device);
    endfunction
```

At the beginning of `live_mq_resize()`, before building or sending a control
command, add:

```systemverilog
        if (!qpair_count_supported(new_pairs)) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                "live_mq_resize: %0d pairs exceeds device limit %0d",
                new_pairs, max_vio_net_qpairs_per_device))
            return;
        end
```

After creating `dyn_reconfig` in `virtio_net_env::build_phase()`, inject the
selected DUT limit:

```systemverilog
        dyn_reconfig.max_vio_net_qpairs_per_device =
            cfg.dut_caps.max_vio_net_qpairs_per_device;
```

- [ ] **Step 4: Run focused and unit tests on 53 and verify GREEN**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-resize-limit-green-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && make TEST=virtio_dut_caps_test test && make TEST=virtio_unit_test test'"
```

Expected: both tests finish with zero UVM errors/fatals.

- [ ] **Step 5: Commit dynamic enforcement**

```bash
git add virtio_net_vip/tests/virtio_dut_caps_test.sv \
  virtio_net_vip/src/env/virtio_dynamic_reconfig.sv \
  virtio_net_vip/src/env/virtio_net_env.sv
git commit -m "fix: enforce VIO qpair cap during resize"
```

### Task 5: Document and verify the complete first-stage contract

**Files:**
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`

- [ ] **Step 1: Update user-facing capability documentation**

Document these exact distinctions in both files:

```text
Default real-DUT topology capability: 2 hosts, 4 PFs/host, 16 VFs/PF.
Compile-time DPU_MAX_* values are model/encoding ceilings, not real-DUT defaults.
The VIO global qpair ID domain is 11 bits (0..2047).
Each PF/VF VIO-net device has one notify-address domain and at most 32 local
queue pairs numbered 0..31.  Different devices may reuse local IDs; their
resolved global qpair IDs remain exclusive.
Initial configuration, dynamic resize, and Fabric lease acquisition all reject
a 33rd pair or a local pair outside 0..31.
```

- [ ] **Step 2: Run static checks**

```bash
git diff --check
rg -n "2 hosts|4 PF|16 VF|32|0\.\.31|2047|DPU_MAX" \
  README.md docs/virtio_net_vip_manual.md
```

Expected: no whitespace errors; both documents contain the capability/local-ID
distinction.

- [ ] **Step 3: Run the complete relevant VCS matrix on 53**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-dut-caps-final-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && \
    make TEST=virtio_dut_caps_test test && \
    make TEST=dpu_resource_manager_test test && \
    make TEST=virtio_fabric_resource_test test && \
    make TEST=virtio_monitor_routing_test test && \
    make TEST=virtio_unit_test test'"
```

Expected: all five tests finish with `UVM_ERROR : 0` and `UVM_FATAL : 0`.

- [ ] **Step 4: Run the maintained strict regression on 53**

```bash
sim_stage=$(sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "mktemp -d /home/ubuntu/wn/virtio-dut-caps-regression-XXXXXX")
rsync -a --exclude=.git --exclude=build \
  -e "sshpass -p '123' ssh -o StrictHostKeyChecking=no" \
  ./ "ubuntu@10.11.10.53:${sim_stage}/"
sshpass -p '123' ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 \
  "bash -lic 'cd ${sim_stage} && ./scripts/strict_regression.sh'"
```

Expected: the script reports every maintained test passed and the strict log
checker finds no UVM errors, fatals, assertion failures, timeouts, or unknowns.

- [ ] **Step 5: Commit documentation and final verification state**

```bash
git add README.md docs/virtio_net_vip_manual.md
git commit -m "docs: describe real DUT VIO qpair limits"
git status --short
```

Expected: the worktree is clean after the documentation commit.
