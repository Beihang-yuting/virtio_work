# Dual Bandwidth Logical-Time Acceleration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the maintained 1,000-packet-per-direction dual bandwidth test preserve its rate, throttle, fairness, and elapsed-order checks while completing under the existing 180-second wall-clock limit.

**Architecture:** Keep the production performance monitor and all packet/queue paths unchanged.  The test-local `virtio_perf_monitor_ext` uses a 100 microsecond burst and advances token refill in logical nanoseconds; the bandwidth test adds logical wait to measured phase time instead of scheduling millions of unrelated clock edges.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1, Bash.

---

### Task 1: Accelerate the bounded dual bandwidth model

**Files:**
- Modify: `virtio_net_vip/tests/virtio_dual_test.sv:31-66,1320-1615`
- Test evidence: `build/strict/task8-review/`

- [ ] **Step 1: Preserve and check both failing behaviors**

Use the existing pre-fix logs:

```bash
rg -n "Test 5|Phase [123]|UVM_(WARNING|ERROR|FATAL)|UVM Report Summary" \
  build/strict/task8-review/dual-default.log \
  build/strict/task8-review/dual-256.log
```

Expected default RED: Tests 1-4 and the first two 2,000-packet bandwidth phases complete, Phase 3 starts, the 180-second wrapper kills the run, and no UVM summary exists.

Expected 256 RED: every phase handles 512 balanced packets, but Phase 2 reports zero throttles and equal time to unlimited; the final summary contains four UVM errors.

- [ ] **Step 2: Keep the bounded workload interface**

In `test_bandwidth_control()`, retain the already tested bounded interface:

```systemverilog
        int unsigned pkts_per_dir = 1000;
        int unsigned pkt_size     = 1500;
        int unsigned queue_size   = 256;

        int unsigned phase_mbps[3] = '{0, 10000, 1000};

        tests_run++;
        void'($value$plusargs("DUAL_BW_PKTS_PER_DIR=%d", pkts_per_dir));
        if (pkts_per_dir < 256)
            `uvm_fatal("DUAL_TEST",
                "DUAL_BW_PKTS_PER_DIR must be at least 256")

        `uvm_info("DUAL_TEST", $sformatf(
            "--- Test 5: Bandwidth Control with %0d packets/direction ---",
            pkts_per_dir), UVM_LOW)
```

Keep `pkts_per_dir` as the only per-direction workload count in the phase loops and result checks.  Update the file header and phase comments to describe a bounded default and the actual unlimited/10Gbps/1Gbps phases; do not claim real-DUT performance.

- [ ] **Step 3: Configure a bounded test-local burst**

Add the burst-window constant to `virtio_perf_monitor_ext` and replace its runtime bucket initialization with 64-bit intermediate arithmetic:

```systemverilog
    localparam int unsigned BW_BURST_WINDOW_NS = 100_000;

    function void configure_bw(int unsigned mbps);
        longint unsigned scaled_bucket_bytes;

        bw_limit_mbps = mbps;
        if (mbps > 0) begin
            bw_limit_enable = 1;
            scaled_bucket_bytes = mbps;
            scaled_bucket_bytes *= BW_BURST_WINDOW_NS;
            scaled_bucket_bytes /= 8000;
            bucket_size = scaled_bucket_bytes;
            token_bucket = bucket_size;
            last_refill_time = $realtime;
        end else begin
            bw_limit_enable = 0;
            bucket_size = 0;
            token_bucket = 0;
        end
    endfunction
```

Expected buckets are 125,000 bytes at 10Gbps and 12,500 bytes at 1Gbps.  Do not modify `virtio_perf_monitor.sv`.

- [ ] **Step 4: Add the test-local logical refill helper**

Add this method to `virtio_perf_monitor_ext`:

```systemverilog
    function int unsigned advance_logical_refill(int unsigned bytes);
        longint unsigned wait_numerator;
        longint unsigned wait_ns;
        longint unsigned refill_tokens;
        longint unsigned refill_total;

        if (!bw_limit_enable || (bw_limit_mbps == 0)) begin
            `uvm_fatal("DUAL_TEST",
                "logical bandwidth refill requires a nonzero enabled rate")
            return 0;
        end

        wait_numerator = bytes;
        wait_numerator *= 8000;
        wait_ns = (wait_numerator / bw_limit_mbps) + 1;
        refill_tokens = wait_ns;
        refill_tokens *= bw_limit_mbps;
        refill_tokens /= 8000;
        refill_total = token_bucket;
        refill_total += refill_tokens;
        token_bucket = (refill_total > bucket_size) ?
            bucket_size : refill_total;
        last_refill_time = $realtime;
        return wait_ns;
    endfunction
```

This helper reproduces the existing per-packet wait/refill calculation but does not advance physical simulation time.  Saturation remains identical to the production token bucket.

- [ ] **Step 5: Replace physical waits with logical elapsed accounting**

For each phase declare and initialize logical wait:

```systemverilog
            realtime logical_wait_ns;
            // ... existing declarations ...
            logical_wait_ns = 0.0;
```

Replace both A-to-B and B-to-A physical throttle blocks with:

```systemverilog
                    if (bw_mon.bw_limit_enable && !bw_mon.can_send(pkt_size)) begin
                        throttle_count++;
                        logical_wait_ns +=
                            bw_mon.advance_logical_refill(pkt_size);
                        assert(bw_mon.can_send(pkt_size))
                            else `uvm_fatal("DUAL_TEST",
                                "logical refill did not make one packet sendable")
                    end
```

Keep the existing `bw_mon.on_sent(pkt_size)` call immediately afterward.  Calculate phase time with the logical wait included:

```systemverilog
            phase_time[phase_idx] =
                (end_time - start_time) + logical_wait_ns;
```

Do not change packet construction, queue processing, phase rates, throttle counters, packet/fairness assertions, throughput formula, or elapsed-order assertions.

- [ ] **Step 6: Run a fresh strict compile**

Synchronize source to the initialized VCS host copy and run compilation through `bash -lic`.

Expected: compile exit 0 and:

```bash
scripts/strict_log_check.sh compile build/strict/task8-review/logical-compile.log
```

returns 0 with no `Warning-[...]` or `Error-[...]`.

- [ ] **Step 7: Verify the maintained default under 180 seconds**

Run:

```bash
/usr/bin/time -f 'DUAL_WALL_SECONDS=%e' \
  timeout --signal=KILL 180s build/simv \
  +UVM_TESTNAME=virtio_dual_test +UVM_NO_RELNOTES \
  >build/strict/task8-review/logical-default.log 2>&1
scripts/strict_log_check.sh sim \
  build/strict/task8-review/logical-default.log
```

Expected: exit 0, wall time below 180 seconds, three phases of 2,000 packets, balanced 1,000 TX/RX in each direction, throttle ordering `0 < 10Gbps < 1Gbps`, elapsed ordering `unlimited < 10Gbps < 1Gbps`, one UVM summary, and W/E/F zero.

- [ ] **Step 8: Verify the 256-packet and invalid boundaries**

Run the same 180-second command with `+DUAL_BW_PKTS_PER_DIR=256`.

Expected: exit 0; each phase reports 512 packets and balanced 256 TX/RX per direction; both limited phases throttle; time/throttle ordering passes; one summary and W/E/F zero; strict checker passes.

Run with `+DUAL_BW_PKTS_PER_DIR=255`.

Expected: quick intentional negative with exactly one `UVM_FATAL` whose message is `DUAL_BW_PKTS_PER_DIR must be at least 256`.  Do not pass this negative log to the strict checker.

- [ ] **Step 9: Audit and commit**

Run:

```bash
git diff --check
git diff --stat 7ec9280..HEAD
git status --short
```

The implementation commit must change only `virtio_net_vip/tests/virtio_dual_test.sv`; the separately approved design and plan documents are already committed.

Commit:

```bash
git add virtio_net_vip/tests/virtio_dual_test.sv
git commit -m "test: bound dual bandwidth regression workload"
```

Preserve all RED, diagnostic 380.38-second, and logical-time GREEN logs under the locally excluded `build/strict/task8-review/` directory for independent review.
