# Dual Bandwidth Logical-Time Acceleration Design

## Context

`virtio_dual_test` exercises a direct-memory bandwidth model after its four
functional dual-VIP tests.  The original 10,000-packet workload could not
finish within the strict 180-second wall-clock limit.  Reducing the maintained
default to 1,000 packets per direction preserves the intended packet count,
but the physical `#wait_ns` token-refill delays still drive millions of 5 ns
testbench clock edges.

The unchanged 1,000-packet test is functionally correct when allowed to run:
it finishes in 380.38 seconds, all five tests pass, the three bandwidth phases
are balanced, throttle and elapsed-time ordering pass, and UVM W/E/F are zero.
This establishes that the remaining failure is simulation cost rather than a
traffic, ownership, or scoreboard defect.

The existing 1 ms initial burst also conflicts with the required 256-packet
configuration check.  A 10 Gbps bucket starts with 1,250,000 bytes, which is
larger than the complete 768,000-byte workload, so that phase cannot throttle
or take longer than the unlimited phase.

## Decision

Keep bandwidth control test-local and replace physical token-refill delays
with equivalent logical-time accounting.

`virtio_perf_monitor_ext`, which already exists only in
`virtio_dual_test.sv`, will use a 100 microsecond initial burst window:

```text
bucket_size_bytes = mbps * 100,000 ns / 8,000
```

This gives 125,000 bytes at 10 Gbps and 12,500 bytes at 1 Gbps.  Both the
1,000-packet maintained workload and the 256-packet configurability workload
therefore exercise throttling, while the lower-rate phase retains the smaller
burst and higher throttle count.

When a packet lacks tokens, a new test-local helper will:

1. calculate the same per-packet wait used by the current test,
   `bytes * 8000 / mbps + 1` nanoseconds;
2. credit the corresponding tokens directly, capped at the configured bucket;
3. synchronize the monitor's refill timestamp to the current physical
   simulation time; and
4. return the logical wait to the caller.

The packet loop will add that returned value to a per-phase logical-wait
counter instead of executing `#wait_ns`.  Reported `phase_time` will be the
actual direct-memory processing time plus accumulated logical wait.  The
throughput calculation and elapsed-time comparisons therefore continue to use
rate-derived time, without scheduling irrelevant clock edges during a
model-only delay.

## Preserved Semantics and Boundaries

- The configured phases remain unlimited, 10 Gbps, and 1 Gbps.
- The maintained default remains 1,000 packets per direction.
- `+DUAL_BW_PKTS_PER_DIR=10000` remains the opt-in long packet workload.
- Values below 256 remain fatal.
- Tests 1-4, packet construction, queue operation, bidirectional forwarding,
  fairness checks, packet-count checks, throttle checks, and elapsed-time
  ordering remain unchanged.
- Production `virtio_perf_monitor`, PCIe/TLM components, and the testbench
  clock generator remain unchanged.
- This is VCS/TLM and direct-memory model verification, not real-DUT traffic
  or real-time performance validation.

## Error Handling

The logical-refill helper is called only when bandwidth limiting is enabled
and `can_send()` has returned false.  A zero configured rate in that path is a
test programming error and must produce a `DUAL_TEST` fatal rather than a
divide-by-zero or a silently fabricated delay.  Token addition is capped at
the configured burst size, matching the production monitor's saturation
behavior.

## Verification

Verification remains on `ubuntu@10.11.10.53` through a bash login shell:

1. fresh strict compile with no VCS warning/error;
2. default 1,000-packet dual run under the original 180-second hard timeout,
   all three phases present, one UVM summary, W/E/F zero, strict checker pass;
3. 256-packet run under 180 seconds, 512 total packets per phase, nonzero
   throttles for both limited phases, correct ordering, W/E/F zero;
4. 255-packet negative run with the exact minimum-value fatal;
5. no leak, completion mismatch, scoreboard mismatch, or timeout; and
6. independent specification and code-quality review before proceeding.

The previous 380.38-second physical-time run remains diagnostic evidence; it
does not change the 180-second maintained regression contract.
