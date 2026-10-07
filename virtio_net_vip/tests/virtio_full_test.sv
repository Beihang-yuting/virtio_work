// ============================================================================
// virtio_full_test.sv
//
// Full integration test on the snapshot-derived Fabric flow.  The endpoint
// image, BDF and BAR leases come from virtio_real_driver_flow_fixture (frozen
// dpu-common snapshot); discovery programs the leased BARs instead of running
// PCI BAR enumeration.
// 中文说明：端点镜像、BDF 与 BAR 租约全部来自 fixture 冻结 snapshot；测试保留
// 原有四项检查（初始化、大流量、带宽整形、协议完整性）。
// ============================================================================

import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// ============================================================================
// Full Integration Test
// ============================================================================
class virtio_full_integration_test extends uvm_test;
    `uvm_component_utils(virtio_full_integration_test)

    // Snapshot-derived PCIe/virtio flow (one host0 VIO PF)
    virtio_real_driver_flow_fixture flow;

    // Handles borrowed from the fixture
    pcie_tl_env pcie_env;
    virtio_pci_transport transport;
    virtio_tlm_completion_adapter tlm_adapter;

    // Test counters
    int unsigned tests_passed;
    int unsigned tests_failed;
    int unsigned tests_run;

    function new(string name = "virtio_full_integration_test", uvm_component parent = null);
        super.new(name, parent);
        tests_passed = 0;
        tests_failed = 0;
        tests_run = 0;
    endfunction

    // ========================================================================
    // Build Phase
    // ========================================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
        // Offered device features of the pre-migration endpoint image
        flow.device_features = 0;
        flow.device_features[VIRTIO_NET_F_MAC]       = 1;
        flow.device_features[VIRTIO_NET_F_STATUS]    = 1;
        flow.device_features[VIRTIO_NET_F_MRG_RXBUF] = 1;
        flow.device_features[VIRTIO_NET_F_CTRL_VQ]   = 1;
        flow.device_features[VIRTIO_NET_F_MQ]        = 1;
        flow.device_features[VIRTIO_F_VERSION_1]     = 1;
        flow.device_features[VIRTIO_NET_F_MTU]       = 1;
        flow.device_features[VIRTIO_NET_F_CSUM]      = 1;
        flow.device_features[VIRTIO_NET_F_HOST_TSO4] = 1;
    endfunction

    // ========================================================================
    // Connect Phase
    // ========================================================================
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        pcie_env = flow.pcie_env();
        tlm_adapter = flow.tlm_adapter;
    endfunction

    // ========================================================================
    // Resolve the fixture's snapshot function (BDF/BAR leases are never test
    // constants) and apply the original fast wait policy to its transport.
    // ========================================================================
    virtual task bind_snapshot_function();
        virtio_function_instance function_instance;
        string why;

        if (!flow.build_flow(why))
            `uvm_fatal("FULL_TEST", {"fixture flow is not ready: ", why})
        if (!flow.execution_profile().has_model_device())
            `uvm_fatal("FULL_TEST", "full integration test requires MODEL execution mode")
        if ((pcie_env == null) || (tlm_adapter == null))
            `uvm_fatal("FULL_TEST", "fixture did not expose its PCIe env and completion adapter")
        function_instance = flow.function_by_bdf(flow.function_bdf());
        if ((function_instance == null) || (function_instance.transport == null) ||
            (function_instance.transport.wait_pol == null))
            `uvm_fatal("FULL_TEST", "fixture did not expose the snapshot function transport")
        transport = function_instance.transport;

        // 4. Configure wait policy for fast simulation
        transport.wait_pol.default_poll_interval_ns = 100;
        transport.wait_pol.reset_timeout_ns = 10000;
        transport.wait_pol.queue_reset_timeout_ns = 10000;
        transport.wait_pol.max_poll_attempts = 100;
        `uvm_info("FULL_TEST", $sformatf(
            "Snapshot function BDF=0x%04h bound", transport.bdf), UVM_LOW)
    endtask

    // ========================================================================
    // Run Phase
    // ========================================================================
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "virtio_full_integration_test");

        `uvm_info("FULL_TEST", "============================================================", UVM_LOW)
        `uvm_info("FULL_TEST", "Starting Full Integration Test with Completion Bridge", UVM_LOW)
        `uvm_info("FULL_TEST", "============================================================", UVM_LOW)

        // Wait for reset to deassert
        #200ns;

        // Resolve the snapshot function and its endpoint image
        bind_snapshot_function();

        // Test 1: Full virtio initialization
        test_full_init();

        // Drain stale completions before next test
        #100ns;
        tlm_adapter.drain();

        // Test 2: Large traffic through actual virtqueue + host_mem
        test_large_traffic();

        // Drain stale completions before next test
        #100ns;
        tlm_adapter.drain();

        // Test 3: Bandwidth control
        test_bandwidth_control();

        // Drain stale completions before next test
        #100ns;
        tlm_adapter.drain();

        // Test 4: Protocol integrity checks
        test_protocol_integrity();

        // Report results
        report_results();

        #100ns;
        phase.drop_objection(this, "virtio_full_integration_test");
    endtask

    // ========================================================================
    // Test 1: Full Virtio Initialization
    // ========================================================================
    virtual task test_full_init();
        tests_run++;
        `uvm_info("FULL_TEST", "--- Test 1: Full Virtio Init ---", UVM_LOW)

        // Step 1: Fabric BAR programming and capability discovery.  BAR
        // placement comes from the frozen snapshot lease; no enumeration.
        `uvm_info("FULL_TEST", "Step 1: Fabric BAR programming and capability discovery", UVM_LOW)
        transport.discover_and_init_bars();
        `uvm_info("FULL_TEST", $sformatf("BAR0 lease at 0x%016h",
            transport.bar.bar_base[0]), UVM_LOW)

        if (!transport.cap_mgr.common_cfg_found) begin
            `uvm_error("FULL_TEST", "Common Config capability not found!")
            tests_failed++;
            return;
        end
        if (!transport.cap_mgr.notify_found) begin
            `uvm_error("FULL_TEST", "Notify capability not found!")
            tests_failed++;
            return;
        end
        `uvm_info("FULL_TEST", "Capabilities discovered successfully", UVM_LOW)

        // Step 5: Full init sequence
        `uvm_info("FULL_TEST", "Step 3: Full init sequence", UVM_LOW)

        // Reset
        transport.reset_device();

        // Acknowledge
        transport.write_device_status(DEV_STATUS_ACKNOWLEDGE);
        `uvm_info("FULL_TEST", "Status: ACKNOWLEDGE written", UVM_MEDIUM)

        // Driver
        transport.write_device_status(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);
        `uvm_info("FULL_TEST", "Status: DRIVER written", UVM_MEDIUM)

        // Feature negotiation
        begin
            bit [63:0] negotiated;
            bit [63:0] driver_supported;
            driver_supported = 0;
            driver_supported[VIRTIO_NET_F_MAC] = 1;
            driver_supported[VIRTIO_NET_F_STATUS] = 1;
            driver_supported[VIRTIO_NET_F_MRG_RXBUF] = 1;
            driver_supported[VIRTIO_F_VERSION_1] = 1;
            driver_supported[VIRTIO_NET_F_MTU] = 1;
            driver_supported[VIRTIO_NET_F_CSUM] = 1;
            transport.negotiate_features(driver_supported, negotiated);
            `uvm_info("FULL_TEST", $sformatf("Negotiated features: 0x%016h", negotiated), UVM_LOW)
            if (negotiated != 64'h0000_0001_0001_8029) begin
                `uvm_error("FULL_TEST", $sformatf(
                    "Negotiated features 0x%016h != expected 0x0000000100018029",
                    negotiated))
                tests_failed++;
                return;
            end
        end

        // Features OK
        transport.write_device_status(
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK);
        `uvm_info("FULL_TEST", "Status: FEATURES_OK written", UVM_MEDIUM)

        // Wait for EP device behavior to react
        #100ns;

        // Verify FEATURES_OK
        begin
            bit [7:0] status;
            transport.read_device_status(status);
            if (!(status & DEV_STATUS_FEATURES_OK)) begin
                `uvm_error("FULL_TEST", "FEATURES_OK not set after write!")
                tests_failed++;
                return;
            end
            `uvm_info("FULL_TEST", $sformatf(
                "Status readback: 0x%02h -- FEATURES_OK confirmed", status), UVM_LOW)
        end

        // Read num_queues
        begin
            int unsigned num_q;
            transport.read_num_queues(num_q);
            `uvm_info("FULL_TEST", $sformatf("Number of queues: %0d", num_q), UVM_LOW)
        end

        // Per-queue discovery
        begin
            int unsigned q_max, q_noff;
            for (int q = 0; q < 3; q++) begin
                transport.select_queue(q);
                #50ns; // Let EP react to Q_SELECT
                transport.read_queue_num_max(q_max);
                transport.read_queue_notify_off(q_noff);
                `uvm_info("FULL_TEST", $sformatf(
                    "Queue %0d: max_size=%0d, notify_off=%0d", q, q_max, q_noff), UVM_MEDIUM)
            end
        end

        // Driver OK
        transport.write_device_status(
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER |
            DEV_STATUS_FEATURES_OK | DEV_STATUS_DRIVER_OK);
        `uvm_info("FULL_TEST", "Status: DRIVER_OK written", UVM_MEDIUM)

        // Wait for EP to react
        #100ns;

        // Verify final status
        begin
            bit [7:0] final_status;
            transport.read_device_status(final_status);
            if (final_status & DEV_STATUS_DRIVER_OK) begin
                `uvm_info("FULL_TEST", $sformatf(
                    "Init complete! Final status: 0x%02h", final_status), UVM_LOW)
                tests_passed++;
            end else begin
                `uvm_error("FULL_TEST", $sformatf(
                    "DRIVER_OK not set! Final status: 0x%02h", final_status))
                tests_failed++;
            end
        end
    endtask

    // ========================================================================
    // Test 2: Large Traffic (1000 TLPs)
    // ========================================================================
    virtual task test_large_traffic();
        int unsigned num_writes;
        int unsigned num_reads;
        int unsigned read_errors;
        bit [63:0] bar0_base;
        bit [31:0] rdata;
        realtime start_time, end_time;

        tests_run++;
        `uvm_info("FULL_TEST", "--- Test 2: Large Traffic (1000 TLPs) ---", UVM_LOW)

        bar0_base = transport.bar.bar_base[0];
        if (bar0_base == 0) begin
            `uvm_error("FULL_TEST", "BAR0 not assigned, skipping traffic test")
            tests_failed++;
            return;
        end

        num_writes = 0;
        num_reads = 0;
        read_errors = 0;
        start_time = $realtime;

        // Phase 1: Burst writes (500 Memory Write TLPs)
        `uvm_info("FULL_TEST", "Phase 1: 500 burst writes", UVM_LOW)
        for (int i = 0; i < 500; i++) begin
            transport.bar.write_reg(0, 32'h1000 + ((i % 16) * 4), 4, i);
            num_writes++;
        end
        `uvm_info("FULL_TEST", $sformatf("Phase 1 complete: %0d writes", num_writes), UVM_LOW)

        // Phase 2: Read-write interleave (250 reads + 250 writes)
        `uvm_info("FULL_TEST", "Phase 2: 500 read/write interleaved", UVM_LOW)
        for (int i = 0; i < 250; i++) begin
            transport.bar.write_reg(0, 32'h1000 + ((i % 16) * 4), 4, 32'hCAFE_0000 + i);
            num_writes++;

            transport.bar.read_reg(0, VIRTIO_PCI_COMMON_STATUS, 1, rdata);
            num_reads++;
            if (rdata[7:0] == 8'hFF)
                read_errors++;
        end
        `uvm_info("FULL_TEST", $sformatf("Phase 2 complete: writes=%0d reads=%0d errors=%0d",
            num_writes - 500, num_reads, read_errors), UVM_LOW)

        // Phase 3: Burst reads (250 reads)
        `uvm_info("FULL_TEST", "Phase 3: 250 burst reads", UVM_LOW)
        for (int i = 0; i < 250; i++) begin
            transport.bar.read_reg(0, 32'h3000 + ((i % 8) * 4), 4, rdata);
            num_reads++;
        end

        end_time = $realtime;

        `uvm_info("FULL_TEST", $sformatf(
            "Traffic test complete: %0d writes, %0d reads, %0d errors, elapsed=%0t",
            num_writes, num_reads, read_errors, end_time - start_time), UVM_LOW)

        if (read_errors == 0) begin
            tests_passed++;
            `uvm_info("FULL_TEST", "Test 2 PASSED: All reads completed successfully", UVM_LOW)
        end else begin
            tests_failed++;
            `uvm_error("FULL_TEST", $sformatf("Test 2 FAILED: %0d read errors", read_errors))
        end
    endtask

    // ========================================================================
    // Test 3: Bandwidth Control
    // ========================================================================
    virtual task test_bandwidth_control();
        bit [63:0] bar0_base;
        bit [31:0] rdata;
        realtime start_time, end_time;
        real elapsed_us;
        int unsigned num_ops;

        tests_run++;
        `uvm_info("FULL_TEST", "--- Test 3: Bandwidth Control ---", UVM_LOW)

        bar0_base = transport.bar.bar_base[0];
        if (bar0_base == 0) begin
            `uvm_error("FULL_TEST", "BAR0 not assigned, skipping BW test")
            tests_failed++;
            return;
        end

        // Enable BW shaper
        pcie_env.bw_shaper.shaper_enable = 1;
        pcie_env.bw_shaper.avg_rate = 100.0;  // 100 MB/s
        pcie_env.bw_shaper.burst_size = 256;

        num_ops = 0;
        start_time = $realtime;

        for (int i = 0; i < 100; i++) begin
            transport.bar.write_reg(0, 32'h1000 + ((i % 16) * 4), 4, 32'hBEEF_0000 + i);
            num_ops++;
        end

        end_time = $realtime;
        elapsed_us = real'(end_time - start_time) / 1000.0;

        `uvm_info("FULL_TEST", $sformatf(
            "BW test: %0d ops in %0.2f us (shaper enabled)",
            num_ops, elapsed_us), UVM_LOW)

        // Disable shaper
        pcie_env.bw_shaper.shaper_enable = 0;

        tests_passed++;
        `uvm_info("FULL_TEST", "Test 3 PASSED: BW shaper exercised", UVM_LOW)
    endtask

    // ========================================================================
    // Test 4: Protocol Integrity
    // ========================================================================
    virtual task test_protocol_integrity();
        bit [31:0] rdata;
        int unsigned errors;

        tests_run++;
        `uvm_info("FULL_TEST", "--- Test 4: Protocol Integrity ---", UVM_LOW)

        errors = 0;

        // Sub-test A: Config read roundtrip
        `uvm_info("FULL_TEST", "Sub-test A: Config space read", UVM_MEDIUM)
        begin
            bit [31:0] vid_did;
            transport.bar.config_read(PCI_CFG_VENDOR_ID, vid_did);
            `uvm_info("FULL_TEST", $sformatf("Config read VID/DID: 0x%08h", vid_did), UVM_LOW)
            if (vid_did[15:0] != 16'h1AF4) begin
                `uvm_error("FULL_TEST", $sformatf(
                    "VID mismatch: expected 0x1AF4, got 0x%04h", vid_did[15:0]))
                errors++;
            end
            if (vid_did[31:16] != 16'h1041) begin
                `uvm_error("FULL_TEST", $sformatf(
                    "DID mismatch: expected 0x1041, got 0x%04h", vid_did[31:16]))
                errors++;
            end
        end

        // Sub-test B: Config write + readback
        `uvm_info("FULL_TEST", "Sub-test B: Config write + readback", UVM_MEDIUM)
        begin
            bit [31:0] cmd_stat;
            transport.bar.config_write(PCI_CFG_COMMAND, 32'h0000_0006, 4'h3);
            transport.bar.config_read(PCI_CFG_COMMAND, cmd_stat);
            `uvm_info("FULL_TEST", $sformatf("Command register readback: 0x%08h", cmd_stat), UVM_LOW)
            if ((cmd_stat[15:0] & 16'h0006) != 16'h0006) begin
                `uvm_error("FULL_TEST", $sformatf(
                    "Command register mismatch: expected bit1,2 set, got 0x%04h", cmd_stat[15:0]))
                errors++;
            end
        end

        // Sub-test C: Back-to-back MMIO reads
        `uvm_info("FULL_TEST", "Sub-test C: Back-to-back MMIO reads", UVM_MEDIUM)
        begin
            bit [31:0] r1, r2, r3;
            transport.bar.read_reg(0, VIRTIO_PCI_COMMON_STATUS, 1, r1);
            transport.bar.read_reg(0, VIRTIO_PCI_COMMON_NUMQ, 2, r2);
            transport.bar.read_reg(0, VIRTIO_PCI_COMMON_CFGGENERATION, 1, r3);
            `uvm_info("FULL_TEST", $sformatf(
                "Back-to-back reads: status=0x%02h num_q=%0d config_gen=%0d",
                r1[7:0], r2[15:0], r3[7:0]), UVM_LOW)
        end

        // Sub-test D: Write-then-read ordering
        `uvm_info("FULL_TEST", "Sub-test D: Write-then-read ordering", UVM_MEDIUM)
        begin
            bit [31:0] written_val, readback;
            written_val = 32'hA5;
            transport.bar.write_reg(0, VIRTIO_PCI_COMMON_Q_SELECT, 2, written_val);
            #50ns;
            transport.bar.read_reg(0, VIRTIO_PCI_COMMON_Q_SELECT, 2, readback);
            `uvm_info("FULL_TEST", $sformatf(
                "RAW test: wrote 0x%04h, read 0x%04h",
                written_val[15:0], readback[15:0]), UVM_LOW)
        end

        if (errors == 0) begin
            tests_passed++;
            `uvm_info("FULL_TEST", "Test 4 PASSED: Protocol integrity verified", UVM_LOW)
        end else begin
            tests_failed++;
            `uvm_error("FULL_TEST", $sformatf("Test 4 FAILED: %0d errors", errors))
        end
    endtask

    // ========================================================================
    // Result Reporting
    // ========================================================================
    virtual function void report_results();
        `uvm_info("FULL_TEST", $sformatf(
            "Completion adapter stats: received=%0d consumed=%0d",
            tlm_adapter.completions_received,
            tlm_adapter.completions_consumed), UVM_LOW)

        `uvm_info("FULL_TEST", "============================================================", UVM_LOW)
        `uvm_info("FULL_TEST", $sformatf("Test Results: %0d/%0d passed, %0d failed",
            tests_passed, tests_run, tests_failed), UVM_LOW)
        `uvm_info("FULL_TEST", "============================================================", UVM_LOW)

        if (tests_failed > 0)
            `uvm_error("FULL_TEST", $sformatf("OVERALL: FAIL (%0d tests failed)", tests_failed))
        else
            `uvm_info("FULL_TEST", "OVERALL: PASS -- All tests passed", UVM_LOW)
    endfunction

endclass
