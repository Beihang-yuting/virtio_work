// ============================================================================
// virtio_dual_test.sv
//
// Dual VIP peer-to-peer traffic test: two virtio-net VIP instances (A and B)
// communicate bidirectionally through a virtual network bridge. Both VIPs
// perform full virtio init through real PCIe TLPs using the completion bridge
// from virtio_full_test.sv, then exchange packets simultaneously.
//
// Architecture:
//   VIP A (BDF=0x0100) <---> Virtual Network Bridge <---> VIP B (BDF=0x0200)
//   Both share a single pcie_tl_env with TLM loopback.
//
// Tests:
//   1. Bidirectional large traffic (2000 packets total)
//   2. Asymmetric traffic (2000 + 200)
//   3. Variable packet sizes
//   4. Stress with queue wrap (small queue, many packets)
//   5. Bandwidth control with 20K packets (unlimited vs 10Gbps vs 1Gbps)
// ============================================================================

`ifndef VIRTIO_DUAL_TEST_SV
`define VIRTIO_DUAL_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_tl_pkg::*;
import host_mem_pkg::*;
import virtio_net_pkg::*;

// ============================================================================
// Extended perf monitor: exposes configure_bw() to reinitialize token bucket
// at runtime (the base class only initializes in build_phase).
// ============================================================================
class virtio_perf_monitor_ext extends virtio_perf_monitor;
    `uvm_component_utils(virtio_perf_monitor_ext)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // Reconfigure bandwidth limit at runtime, reinitializing the token bucket.
    function void configure_bw(int unsigned mbps);
        bw_limit_mbps = mbps;
        if (mbps > 0) begin
            bw_limit_enable = 1;
            // bucket_size = 1ms worth of bytes at configured rate (mbps * 125)
            bucket_size  = mbps * 125;
            token_bucket = bucket_size;  // start full
            last_refill_time = $realtime;
        end else begin
            bw_limit_enable = 0;
            bucket_size  = 0;
            token_bucket = 0;
        end
    endfunction

    // Reset all stats for a fresh measurement phase
    function void reset_stats();
        global_stats = '{default: 0, start_time: 0, end_time: 0};
        vf_stats.delete();
        latency_samples.delete();
        last_refill_time = $realtime;
        if (bw_limit_enable)
            token_bucket = bucket_size;
    endfunction
endclass : virtio_perf_monitor_ext

// ============================================================================
// Dual VIP Test
// ============================================================================
class virtio_dual_test extends uvm_test;
    `uvm_component_utils(virtio_dual_test)

    // PCIe environment (shared)
    pcie_tl_env pcie_env;

    // Completion bridge (shared)
    virtio_cpl_bridge bridge;

    // ---- VIP A components ----
    virtio_pci_transport  transport_a;
    virtio_wait_policy    wait_pol_a;
    host_mem_manager      mem_a;
    virtio_iommu_model    iommu_a;
    virtqueue_manager     vq_mgr_a;
    virtio_memory_barrier_model barrier_a;
    virtqueue_error_injector    err_inj_a;
    virtio_atomic_ops     ops_a;

    // ---- VIP B components ----
    virtio_pci_transport  transport_b;
    virtio_wait_policy    wait_pol_b;
    host_mem_manager      mem_b;
    virtio_iommu_model    iommu_b;
    virtqueue_manager     vq_mgr_b;
    virtio_memory_barrier_model barrier_b;
    virtqueue_error_injector    err_inj_b;
    virtio_atomic_ops     ops_b;

    // Perf monitors
    virtio_perf_monitor   perf_a, perf_b;

    // Extended perf monitor for bandwidth control test (Test 5)
    virtio_perf_monitor_ext bw_mon;

    // Test counters
    int unsigned tests_passed;
    int unsigned tests_failed;
    int unsigned tests_run;

    function new(string name = "virtio_dual_test", uvm_component parent = null);
        super.new(name, parent);
        tests_passed = 0;
        tests_failed = 0;
        tests_run = 0;
    endfunction

    // ========================================================================
    // Build Phase
    // ========================================================================
    virtual function void build_phase(uvm_phase phase);
        pcie_tl_env_config pcie_cfg;
        super.build_phase(phase);

        // 1. Create completion bridge
        bridge = virtio_cpl_bridge::type_id::create("bridge");

        // 2. Factory override: swap RC driver with shim
        pcie_tl_rc_driver::type_id::set_inst_override(
            virtio_rc_driver_shim::get_type(),
            "pcie_env.rc_agent.driver", this);

        // 3. Factory overrides for bridged sequences
        virtio_bar_mem_rd_seq::type_id::set_type_override(
            virtio_bar_mem_rd_seq_bridged::get_type());
        virtio_bar_cfg_rd_seq::type_id::set_type_override(
            virtio_bar_cfg_rd_seq_bridged::get_type());
        virtio_bar_mem_wr_seq::type_id::set_type_override(
            virtio_bar_mem_wr_seq_bridged::get_type());
        virtio_bar_cfg_wr_seq::type_id::set_type_override(
            virtio_bar_cfg_wr_seq_bridged::get_type());
        virtio_bar_accessor::type_id::set_type_override(
            virtio_bar_accessor_bridged::get_type());

        // 4. Create PCIe environment
        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_cfg.if_mode = TLM_MODE;
        pcie_cfg.rc_agent_enable = 1;
        pcie_cfg.ep_agent_enable = 1;
        pcie_cfg.rc_is_active = UVM_ACTIVE;
        pcie_cfg.ep_is_active = UVM_ACTIVE;
        pcie_cfg.ep_auto_response = 1;
        pcie_cfg.scb_enable = 0;
        pcie_cfg.fc_enable = 0;
        pcie_cfg.infinite_credit = 1;
        pcie_cfg.extended_tag_enable = 1;
        pcie_cfg.cpl_timeout_ns = 500_000_000;  // 500ms: accommodate bandwidth test time advances
        pcie_cfg.link_delay_enable = 0;
        uvm_config_db #(pcie_tl_env_config)::set(this, "pcie_env", "cfg", pcie_cfg);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        // 5. Create VIP A components
        transport_a = virtio_pci_transport::type_id::create("transport_a");
        wait_pol_a  = virtio_wait_policy::type_id::create("wait_pol_a");
        mem_a       = host_mem_manager::type_id::create("mem_a");
        iommu_a     = virtio_iommu_model::type_id::create("iommu_a");
        vq_mgr_a    = virtqueue_manager::type_id::create("vq_mgr_a");
        barrier_a   = virtio_memory_barrier_model::type_id::create("barrier_a");
        err_inj_a   = virtqueue_error_injector::type_id::create("err_inj_a");
        ops_a       = virtio_atomic_ops::type_id::create("ops_a");

        // 6. Create VIP B components
        transport_b = virtio_pci_transport::type_id::create("transport_b");
        wait_pol_b  = virtio_wait_policy::type_id::create("wait_pol_b");
        mem_b       = host_mem_manager::type_id::create("mem_b");
        iommu_b     = virtio_iommu_model::type_id::create("iommu_b");
        vq_mgr_b    = virtqueue_manager::type_id::create("vq_mgr_b");
        barrier_b   = virtio_memory_barrier_model::type_id::create("barrier_b");
        err_inj_b   = virtqueue_error_injector::type_id::create("err_inj_b");
        ops_b       = virtio_atomic_ops::type_id::create("ops_b");

        // 7. Perf monitors
        perf_a = virtio_perf_monitor::type_id::create("perf_a", this);
        perf_b = virtio_perf_monitor::type_id::create("perf_b", this);

        // 7b. Extended perf monitor for bandwidth control test
        bw_mon = virtio_perf_monitor_ext::type_id::create("bw_mon", this);

        // 8. Set static bridge references
        virtio_bar_mem_rd_seq_bridged::s_bridge = bridge;
        virtio_bar_cfg_rd_seq_bridged::s_bridge = bridge;
        virtio_bar_cfg_wr_seq_bridged::s_bridge = bridge;
    endfunction

    // ========================================================================
    // Connect Phase
    // ========================================================================
    virtual function void connect_phase(uvm_phase phase);
        virtio_rc_driver_shim shim;
        super.connect_phase(phase);

        // Inject bridge into RC driver shim
        if (pcie_env.rc_agent != null && pcie_env.rc_agent.driver != null) begin
            if ($cast(shim, pcie_env.rc_agent.driver))
                shim.bridge = bridge;
            else
                `uvm_fatal("DUAL_TEST", "Failed to cast driver to virtio_rc_driver_shim")
        end

        // ---- Wire VIP A ----
        transport_a.bar.pcie_rc_seqr = pcie_env.rc_agent.sequencer;
        transport_a.bdf = 16'h0100;
        transport_a.wait_pol = wait_pol_a;
        ops_a.transport = transport_a;
        ops_a.vq_mgr = vq_mgr_a;
        ops_a.mem = mem_a;
        ops_a.iommu = iommu_a;
        ops_a.wait_pol = wait_pol_a;

        wait_pol_a.default_poll_interval_ns = 100;
        wait_pol_a.reset_timeout_ns = 10000;
        wait_pol_a.queue_reset_timeout_ns = 10000;
        wait_pol_a.max_poll_attempts = 100;

        // ---- Wire VIP B ----
        transport_b.bar.pcie_rc_seqr = pcie_env.rc_agent.sequencer;
        transport_b.bdf = 16'h0200;
        transport_b.wait_pol = wait_pol_b;
        ops_b.transport = transport_b;
        ops_b.vq_mgr = vq_mgr_b;
        ops_b.mem = mem_b;
        ops_b.iommu = iommu_b;
        ops_b.wait_pol = wait_pol_b;

        wait_pol_b.default_poll_interval_ns = 100;
        wait_pol_b.reset_timeout_ns = 10000;
        wait_pol_b.queue_reset_timeout_ns = 10000;
        wait_pol_b.max_poll_attempts = 100;
    endfunction

    // ========================================================================
    // Run Phase
    // ========================================================================
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "virtio_dual_test");

        `uvm_info("DUAL_TEST", "============================================================", UVM_LOW)
        `uvm_info("DUAL_TEST", "Starting Dual VIP Peer-to-Peer Traffic Test", UVM_LOW)
        `uvm_info("DUAL_TEST", "============================================================", UVM_LOW)

        #200ns;

        // Setup EP and run full init for both VIPs
        setup_ep_virtio_config();
        init_both_vips();

        // Drain bridge between phases
        #100ns;
        bridge.drain();

        // Test 1: Bidirectional large traffic
        test_bidirectional_traffic(1000, 1000, 256, 256, "Test 1: Bidirectional 2000 packets");

        #100ns;
        bridge.drain();

        // Test 2: Asymmetric traffic
        test_bidirectional_traffic(2000, 200, 256, 256, "Test 2: Asymmetric 2200 packets");

        #100ns;
        bridge.drain();

        // Test 3: Variable packet sizes
        test_variable_sizes();

        #100ns;
        bridge.drain();

        // Test 4: Queue wrap stress
        test_queue_wrap_stress();

        #100ns;
        bridge.drain();

        // Test 5: Bandwidth control with 20K packets
        test_bandwidth_control();

        // Report results
        report_results();

        #100ns;
        phase.drop_objection(this, "virtio_dual_test");
    endtask

    // ========================================================================
    // Setup EP Config Space
    // ========================================================================
    virtual function void setup_ep_virtio_config();
        pcie_tl_cfg_space_manager cfg;
        pcie_tl_ep_driver ep_drv;
        pcie_capability vs_cap;
        bit [7:0] cap_data[];

        cfg = pcie_env.cfg_mgr;
        ep_drv = pcie_env.ep_agent.ep_driver;

        cfg.cap_list.delete();
        cfg.ext_cap_list.delete();

        cfg.init_type0_header(
            .vendor_id(16'h1AF4),
            .device_id(16'h1041),
            .revision_id(8'h01),
            .class_code(24'h020000),
            .header_type(8'h00)
        );

        cfg.cfg_space[6] = cfg.cfg_space[6] | (1 << PCI_STATUS_CAP_LIST);
        cfg.field_attrs[6] = CFG_FIELD_RO;

        cfg.cfg_space[16] = 8'h00;
        cfg.cfg_space[17] = 8'h00;
        cfg.cfg_space[18] = 8'h00;
        cfg.cfg_space[19] = 8'h00;
        for (int i = 16; i < 18; i++)
            cfg.field_attrs[i] = CFG_FIELD_RO;

        cfg.init_pcie_capability(8'h40, MPS_256, MRRS_512, RCB_64);

        // Common Config capability (cfg_type=1) at offset 0x50
        vs_cap = pcie_capability::type_id::create("virtio_common_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'h50;
        cap_data = new[14];
        cap_data[0]  = 8'h14;
        cap_data[1]  = VIRTIO_PCI_CAP_COMMON_CFG;
        cap_data[2]  = 8'h00;
        cap_data[3]  = 8'h00;
        cap_data[4]  = 8'h00;
        cap_data[5]  = 8'h00;
        cap_data[6]  = 8'h00;
        cap_data[7]  = 8'h00;
        cap_data[8]  = 8'h00;
        cap_data[9]  = 8'h00;
        cap_data[10] = 8'h40;
        cap_data[11] = 8'h00;
        cap_data[12] = 8'h00;
        cap_data[13] = 8'h00;
        vs_cap.data = cap_data;
        cfg.register_capability(vs_cap);

        // Notify capability (cfg_type=2) at offset 0x70
        vs_cap = pcie_capability::type_id::create("virtio_notify_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'h70;
        cap_data = new[18];
        cap_data[0]  = 8'h18;
        cap_data[1]  = VIRTIO_PCI_CAP_NOTIFY_CFG;
        cap_data[2]  = 8'h00;
        cap_data[3]  = 8'h00;
        cap_data[4]  = 8'h00;
        cap_data[5]  = 8'h00;
        cap_data[6]  = 8'h00;
        cap_data[7]  = 8'h10;
        cap_data[8]  = 8'h00;
        cap_data[9]  = 8'h00;
        cap_data[10] = 8'h00;
        cap_data[11] = 8'h10;
        cap_data[12] = 8'h00;
        cap_data[13] = 8'h00;
        cap_data[14] = 8'h02;
        cap_data[15] = 8'h00;
        cap_data[16] = 8'h00;
        cap_data[17] = 8'h00;
        vs_cap.data = cap_data;
        cfg.register_capability(vs_cap);

        // ISR capability (cfg_type=3) at offset 0x90
        vs_cap = pcie_capability::type_id::create("virtio_isr_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'h90;
        cap_data = new[14];
        cap_data[0]  = 8'h14;
        cap_data[1]  = VIRTIO_PCI_CAP_ISR_CFG;
        cap_data[2]  = 8'h00;
        cap_data[3]  = 8'h00;
        cap_data[4]  = 8'h00;
        cap_data[5]  = 8'h00;
        cap_data[6]  = 8'h00;
        cap_data[7]  = 8'h20;
        cap_data[8]  = 8'h00;
        cap_data[9]  = 8'h00;
        cap_data[10] = 8'h04;
        cap_data[11] = 8'h00;
        cap_data[12] = 8'h00;
        cap_data[13] = 8'h00;
        vs_cap.data = cap_data;
        cfg.register_capability(vs_cap);

        // Device Config capability (cfg_type=4) at offset 0xA8
        vs_cap = pcie_capability::type_id::create("virtio_devcfg_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'hA8;
        cap_data = new[14];
        cap_data[0]  = 8'h14;
        cap_data[1]  = VIRTIO_PCI_CAP_DEVICE_CFG;
        cap_data[2]  = 8'h00;
        cap_data[3]  = 8'h00;
        cap_data[4]  = 8'h00;
        cap_data[5]  = 8'h00;
        cap_data[6]  = 8'h00;
        cap_data[7]  = 8'h30;
        cap_data[8]  = 8'h00;
        cap_data[9]  = 8'h00;
        cap_data[10] = 8'h40;
        cap_data[11] = 8'h00;
        cap_data[12] = 8'h00;
        cap_data[13] = 8'h00;
        vs_cap.data = cap_data;
        cfg.register_capability(vs_cap);

        // MSI-X capability at offset 0xC0
        begin
            pcie_capability msix_cap;
            msix_cap = pcie_capability::type_id::create("msix_cap");
            msix_cap.cap_id = CAP_ID_MSIX;
            msix_cap.offset = 8'hC0;
            cap_data = new[10];
            cap_data[0] = 8'h07;
            cap_data[1] = 8'h00;
            cap_data[2] = 8'h00;
            cap_data[3] = 8'h40;
            cap_data[4] = 8'h00;
            cap_data[5] = 8'h00;
            cap_data[6] = 8'h00;
            cap_data[7] = 8'h50;
            cap_data[8] = 8'h00;
            cap_data[9] = 8'h00;
            msix_cap.data = cap_data;
            cfg.register_capability(msix_cap);
        end

        `uvm_info("DUAL_TEST", "EP config space setup complete", UVM_LOW)
    endfunction

    // ========================================================================
    // Init EP MMIO registers
    // ========================================================================
    virtual function void init_ep_mmio_regs(bit [63:0] bar0_base);
        pcie_tl_ep_driver ep_drv;
        bit [63:0] cc_base, dc_base;
        bit [63:0] device_features;

        ep_drv  = pcie_env.ep_agent.ep_driver;
        cc_base = bar0_base;
        dc_base = bar0_base + 64'h3000;

        device_features = 0;
        device_features[VIRTIO_NET_F_MAC]     = 1;
        device_features[VIRTIO_NET_F_STATUS]  = 1;
        device_features[VIRTIO_NET_F_MRG_RXBUF] = 1;
        device_features[VIRTIO_NET_F_CTRL_VQ] = 1;
        device_features[VIRTIO_NET_F_MQ]      = 1;
        device_features[VIRTIO_F_VERSION_1]   = 1;
        device_features[VIRTIO_NET_F_MTU]     = 1;
        device_features[VIRTIO_NET_F_CSUM]    = 1;
        device_features[VIRTIO_NET_F_HOST_TSO4] = 1;

        write_ep_mem32(ep_drv, cc_base + 64'h00, 32'h0);
        write_ep_mem32(ep_drv, cc_base + 64'h04, device_features[31:0]);
        write_ep_mem32(ep_drv, cc_base + 64'h08, 32'h0);
        write_ep_mem32(ep_drv, cc_base + 64'h0C, 32'h0);
        write_ep_mem16(ep_drv, cc_base + 64'h10, 16'h0);
        write_ep_mem16(ep_drv, cc_base + 64'h12, 16'h0006);
        write_ep_mem8(ep_drv,  cc_base + 64'h14, 8'h0);
        write_ep_mem8(ep_drv,  cc_base + 64'h15, 8'h0);
        write_ep_mem16(ep_drv, cc_base + 64'h16, 16'h0);
        write_ep_mem16(ep_drv, cc_base + 64'h18, 16'h0100);
        write_ep_mem16(ep_drv, cc_base + 64'h1A, 16'h0);
        write_ep_mem16(ep_drv, cc_base + 64'h1C, 16'h0);
        write_ep_mem16(ep_drv, cc_base + 64'h1E, 16'h0);
        for (int i = 0; i < 24; i++)
            ep_drv.mem_space[cc_base + 64'h20 + i] = 8'h00;

        // Device Config: MAC, status, etc.
        write_ep_mem8(ep_drv, dc_base + 64'h00, 8'h52);
        write_ep_mem8(ep_drv, dc_base + 64'h01, 8'h54);
        write_ep_mem8(ep_drv, dc_base + 64'h02, 8'h00);
        write_ep_mem8(ep_drv, dc_base + 64'h03, 8'h12);
        write_ep_mem8(ep_drv, dc_base + 64'h04, 8'h34);
        write_ep_mem8(ep_drv, dc_base + 64'h05, 8'h56);
        write_ep_mem16(ep_drv, dc_base + 64'h06, 16'h0001);
        write_ep_mem16(ep_drv, dc_base + 64'h08, 16'h0002);
        write_ep_mem16(ep_drv, dc_base + 64'h0A, 16'h05DC);
        write_ep_mem32(ep_drv, dc_base + 64'h0C, 32'h00002710);
        write_ep_mem8(ep_drv,  dc_base + 64'h10, 8'h01);
    endfunction

    // ========================================================================
    // EP Device Behavior
    // ========================================================================
    virtual task ep_device_behavior(bit [63:0] bar0_base);
        pcie_tl_ep_driver ep_drv;
        bit [63:0] cc_base;
        bit [63:0] device_features;
        bit [7:0] last_status;
        int unsigned last_qselect;

        ep_drv  = pcie_env.ep_agent.ep_driver;
        cc_base = bar0_base;

        device_features = 0;
        device_features[VIRTIO_NET_F_MAC]     = 1;
        device_features[VIRTIO_NET_F_STATUS]  = 1;
        device_features[VIRTIO_NET_F_MRG_RXBUF] = 1;
        device_features[VIRTIO_NET_F_CTRL_VQ] = 1;
        device_features[VIRTIO_NET_F_MQ]      = 1;
        device_features[VIRTIO_F_VERSION_1]   = 1;
        device_features[VIRTIO_NET_F_MTU]     = 1;
        device_features[VIRTIO_NET_F_CSUM]    = 1;
        device_features[VIRTIO_NET_F_HOST_TSO4] = 1;

        last_status  = 0;
        last_qselect = 0;

        forever begin
            bit [31:0] dfselect_val;
            bit [7:0] status_val;
            int unsigned qselect_val;

            #10ns;

            dfselect_val = read_ep_mem32(ep_drv, cc_base + 64'h00);
            if (dfselect_val == 0)
                write_ep_mem32(ep_drv, cc_base + 64'h04, device_features[31:0]);
            else if (dfselect_val == 1)
                write_ep_mem32(ep_drv, cc_base + 64'h04, device_features[63:32]);

            status_val = read_ep_mem8(ep_drv, cc_base + 64'h14);
            if (status_val != last_status) begin
                last_status = status_val;
                if (last_status & DEV_STATUS_FEATURES_OK)
                    write_ep_mem8(ep_drv, cc_base + 64'h14, last_status);
            end

            qselect_val = read_ep_mem16(ep_drv, cc_base + 64'h16);
            if (qselect_val != last_qselect) begin
                last_qselect = qselect_val;
                write_ep_mem16(ep_drv, cc_base + 64'h18, 16'h0100);
                write_ep_mem16(ep_drv, cc_base + 64'h1E, last_qselect[15:0]);
            end
        end
    endtask

    // ========================================================================
    // Init Both VIPs (sequentially through shared PCIe)
    // ========================================================================
    virtual task init_both_vips();
        bit [63:0] bar0_base;

        `uvm_info("DUAL_TEST", "--- Initializing VIP A ---", UVM_LOW)

        // BAR enumeration (VIP A)
        transport_a.bar.requester_id = transport_a.bdf;
        transport_a.bar.enumerate_bars();
        bar0_base = transport_a.bar.bar_base[0];
        `uvm_info("DUAL_TEST", $sformatf("VIP A: BAR0=0x%016h", bar0_base), UVM_LOW)

        // Init EP MMIO
        init_ep_mmio_regs(bar0_base);

        // Start EP device behavior
        fork
            ep_device_behavior(bar0_base);
        join_none

        // Capability discovery
        transport_a.cap_mgr.bar_ref = transport_a.bar;
        transport_a.cap_mgr.discover_capabilities();

        if (!transport_a.cap_mgr.common_cfg_found) begin
            `uvm_fatal("DUAL_TEST", "VIP A: Common Config capability not found")
        end

        // Full virtio init for VIP A
        run_virtio_init(transport_a, "VIP_A");

        #100ns;
        bridge.drain();

        // VIP B uses same EP config space and BAR (shared device)
        `uvm_info("DUAL_TEST", "--- Initializing VIP B ---", UVM_LOW)

        transport_b.bar.requester_id = transport_b.bdf;
        // Copy BAR assignment from VIP A (same device)
        transport_b.bar.bar_base[0] = bar0_base;
        transport_b.bar.bar_size[0] = transport_a.bar.bar_size[0];
        transport_b.bar.bar_type[0] = transport_a.bar.bar_type[0];

        transport_b.cap_mgr.bar_ref = transport_b.bar;
        transport_b.cap_mgr.discover_capabilities();

        if (!transport_b.cap_mgr.common_cfg_found) begin
            `uvm_fatal("DUAL_TEST", "VIP B: Common Config capability not found")
        end

        // Full virtio init for VIP B
        run_virtio_init(transport_b, "VIP_B");

        #100ns;
        bridge.drain();

        // Initialize host memory regions (separate for A and B)
        mem_a.init_region(64'hA000_0000, 64'hAFFF_FFFF);  // 256MB for A
        mem_b.init_region(64'hB000_0000, 64'hBFFF_FFFF);  // 256MB for B
        iommu_a.strict_permission_check = 0;
        iommu_b.strict_permission_check = 0;

        `uvm_info("DUAL_TEST", "Both VIPs initialized successfully", UVM_LOW)
    endtask

    // ========================================================================
    // Run virtio init sequence for one transport
    // ========================================================================
    virtual task run_virtio_init(virtio_pci_transport transport, string label);
        bit [63:0] driver_supported, negotiated;

        transport.reset_device();

        transport.write_device_status(DEV_STATUS_ACKNOWLEDGE);
        transport.write_device_status(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);

        driver_supported = 0;
        driver_supported[VIRTIO_NET_F_MAC]     = 1;
        driver_supported[VIRTIO_NET_F_STATUS]  = 1;
        driver_supported[VIRTIO_NET_F_MRG_RXBUF] = 1;
        driver_supported[VIRTIO_F_VERSION_1]   = 1;
        driver_supported[VIRTIO_NET_F_MTU]     = 1;
        driver_supported[VIRTIO_NET_F_CSUM]    = 1;
        transport.negotiate_features(driver_supported, negotiated);
        `uvm_info("DUAL_TEST", $sformatf("%s: Negotiated features: 0x%016h", label, negotiated), UVM_LOW)

        transport.write_device_status(
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK);
        #100ns;

        begin
            bit [7:0] status;
            transport.read_device_status(status);
            if (!(status & DEV_STATUS_FEATURES_OK))
                `uvm_error("DUAL_TEST", $sformatf("%s: FEATURES_OK not set", label))
            else
                `uvm_info("DUAL_TEST", $sformatf("%s: FEATURES_OK confirmed", label), UVM_LOW)
        end

        transport.write_device_status(
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER |
            DEV_STATUS_FEATURES_OK | DEV_STATUS_DRIVER_OK);
        #100ns;

        begin
            bit [7:0] fstatus;
            transport.read_device_status(fstatus);
            if (fstatus & DEV_STATUS_DRIVER_OK)
                `uvm_info("DUAL_TEST", $sformatf("%s: Init complete, status=0x%02h", label, fstatus), UVM_LOW)
            else
                `uvm_error("DUAL_TEST", $sformatf("%s: DRIVER_OK not set, status=0x%02h", label, fstatus))
        end
    endtask

    // ========================================================================
    // Packet Generation
    // ========================================================================
    function void build_directed_packet(
        int unsigned pkt_idx,
        int unsigned total_size,
        bit [7:0]    direction,   // 0=A->B, 1=B->A
        ref byte unsigned pkt_data[$]
    );
        int unsigned payload_size;
        int unsigned ip_total_len;

        pkt_data = {};

        // Ethernet header (14 bytes)
        if (direction == 0) begin
            // A->B: dst=BB:..., src=AA:...
            pkt_data.push_back(8'hBB); pkt_data.push_back(8'hBB);
            pkt_data.push_back(8'hBB); pkt_data.push_back(8'hBB);
            pkt_data.push_back(8'hBB); pkt_data.push_back(8'hBB);
            pkt_data.push_back(8'hAA); pkt_data.push_back(8'hAA);
            pkt_data.push_back(8'hAA); pkt_data.push_back(8'hAA);
            pkt_data.push_back(8'hAA); pkt_data.push_back(8'hAA);
        end else begin
            // B->A: dst=AA:..., src=BB:...
            pkt_data.push_back(8'hAA); pkt_data.push_back(8'hAA);
            pkt_data.push_back(8'hAA); pkt_data.push_back(8'hAA);
            pkt_data.push_back(8'hAA); pkt_data.push_back(8'hAA);
            pkt_data.push_back(8'hBB); pkt_data.push_back(8'hBB);
            pkt_data.push_back(8'hBB); pkt_data.push_back(8'hBB);
            pkt_data.push_back(8'hBB); pkt_data.push_back(8'hBB);
        end
        // EtherType: IPv4
        pkt_data.push_back(8'h08); pkt_data.push_back(8'h00);

        // IPv4 header (20 bytes)
        ip_total_len = total_size - 14;
        pkt_data.push_back(8'h45);
        pkt_data.push_back(8'h00);
        pkt_data.push_back(ip_total_len[15:8]);
        pkt_data.push_back(ip_total_len[7:0]);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h40);
        pkt_data.push_back(8'h06);  // TCP
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        if (direction == 0) begin
            // src 10.0.1.1, dst 10.0.2.1
            pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
            pkt_data.push_back(8'h01); pkt_data.push_back(8'h01);
            pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
            pkt_data.push_back(8'h02); pkt_data.push_back(8'h01);
        end else begin
            // src 10.0.2.1, dst 10.0.1.1
            pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
            pkt_data.push_back(8'h02); pkt_data.push_back(8'h01);
            pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
            pkt_data.push_back(8'h01); pkt_data.push_back(8'h01);
        end

        // TCP header (20 bytes)
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h50);
        pkt_data.push_back(8'h10); pkt_data.push_back(8'h00);
        pkt_data.push_back(pkt_idx[31:24]); pkt_data.push_back(pkt_idx[23:16]);
        pkt_data.push_back(pkt_idx[15:8]);  pkt_data.push_back(pkt_idx[7:0]);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h50); pkt_data.push_back(8'h10);
        pkt_data.push_back(8'hFF); pkt_data.push_back(8'hFF);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);

        // Payload: direction marker + index + sequential
        payload_size = total_size - 54;
        for (int unsigned i = 0; i < payload_size; i++) begin
            pkt_data.push_back((direction ^ pkt_idx[7:0] ^ i[7:0]) & 8'hFF);
        end
    endfunction

    // ========================================================================
    // Test 1/2: Bidirectional Traffic
    // ========================================================================
    virtual task test_bidirectional_traffic(
        int unsigned a_to_b_count,
        int unsigned b_to_a_count,
        int unsigned queue_size_a,
        int unsigned queue_size_b,
        string       test_name
    );
        // Queues
        split_virtqueue txq_a, rxq_a, txq_b, rxq_b;

        // Counters
        int unsigned a_tx_submitted, b_tx_submitted;
        int unsigned a_rx_received, b_rx_received;
        int unsigned a_to_b_forwarded, b_to_a_forwarded;
        int unsigned a_to_b_data_ok, b_to_a_data_ok;
        int unsigned a_to_b_data_err, b_to_a_data_err;

        // Stored packet data for verification
        byte unsigned a_tx_packets[int unsigned][$];  // pkt_idx -> data
        byte unsigned b_tx_packets[int unsigned][$];

        realtime start_time, end_time;

        tests_run++;
        `uvm_info("DUAL_TEST", $sformatf("--- %s ---", test_name), UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf("  A->B: %0d packets, B->A: %0d packets",
                                          a_to_b_count, b_to_a_count), UVM_LOW)

        // Initialize counters
        a_tx_submitted   = 0;
        b_tx_submitted   = 0;
        a_rx_received    = 0;
        b_rx_received    = 0;
        a_to_b_forwarded = 0;
        b_to_a_forwarded = 0;
        a_to_b_data_ok   = 0;
        b_to_a_data_ok   = 0;
        a_to_b_data_err  = 0;
        b_to_a_data_err  = 0;

        start_time = $realtime;

        // Run traffic in batches to handle queue size limits
        begin
            int unsigned a_remaining = a_to_b_count;
            int unsigned b_remaining = b_to_a_count;
            int unsigned batch_num = 0;

            while (a_remaining > 0 || b_remaining > 0) begin
                int unsigned a_batch, b_batch;
                int unsigned a_desc_ids[$], b_desc_ids[$];
                int unsigned tx_used_idx_a = 0, tx_used_idx_b = 0;
                int unsigned rx_used_idx_a = 0, rx_used_idx_b = 0;
                int unsigned rx_avail_consumed_a = 0, rx_avail_consumed_b = 0;

                a_batch = (a_remaining > queue_size_a) ? queue_size_a : a_remaining;
                b_batch = (b_remaining > queue_size_b) ? queue_size_b : b_remaining;

                // Create fresh queues for each batch
                txq_a = split_virtqueue::type_id::create("txq_a");
                txq_a.setup(1, queue_size_a, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                txq_a.alloc_rings();

                rxq_a = split_virtqueue::type_id::create("rxq_a");
                rxq_a.setup(0, queue_size_a, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                rxq_a.alloc_rings();

                txq_b = split_virtqueue::type_id::create("txq_b");
                txq_b.setup(1, queue_size_b, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                txq_b.alloc_rings();

                rxq_b = split_virtqueue::type_id::create("rxq_b");
                rxq_b.setup(0, queue_size_b, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                rxq_b.alloc_rings();

                a_desc_ids = {};
                b_desc_ids = {};

                // Pre-fill RX buffers for both sides
                // A's RX (to receive B->A packets)
                for (int unsigned i = 0; i < b_batch; i++) begin
                    prefill_rx_buffer(rxq_a, mem_a, 1600);
                end

                // B's RX (to receive A->B packets)
                for (int unsigned i = 0; i < a_batch; i++) begin
                    prefill_rx_buffer(rxq_b, mem_b, 1600);
                end

                // Submit A->B TX packets
                for (int unsigned i = 0; i < a_batch; i++) begin
                    int unsigned pkt_idx = a_tx_submitted;
                    int unsigned pkt_size = 256;
                    byte unsigned pkt_data[$];
                    int unsigned desc_id;

                    build_directed_packet(pkt_idx, pkt_size, 0, pkt_data);
                    desc_id = submit_tx_packet(txq_a, mem_a, pkt_data, pkt_size);
                    if (desc_id != '1) begin
                        a_desc_ids.push_back(desc_id);
                        a_tx_packets[pkt_idx] = pkt_data;
                        a_tx_submitted++;
                    end
                end

                // Submit B->A TX packets
                for (int unsigned i = 0; i < b_batch; i++) begin
                    int unsigned pkt_idx = b_tx_submitted;
                    int unsigned pkt_size = 256;
                    byte unsigned pkt_data[$];
                    int unsigned desc_id;

                    build_directed_packet(pkt_idx, pkt_size, 1, pkt_data);
                    desc_id = submit_tx_packet(txq_b, mem_b, pkt_data, pkt_size);
                    if (desc_id != '1) begin
                        b_desc_ids.push_back(desc_id);
                        b_tx_packets[pkt_idx] = pkt_data;
                        b_tx_submitted++;
                    end
                end

                // Virtual network bridge: forward A->B
                for (int unsigned i = 0; i < a_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_a, mem_b,
                        txq_a.desc_table_addr, txq_a.device_ring_addr, queue_size_a, tx_used_idx_a,
                        rxq_b.desc_table_addr, rxq_b.driver_ring_addr, rxq_b.device_ring_addr,
                        queue_size_b, rx_avail_consumed_b, rx_used_idx_b,
                        a_desc_ids[i]
                    );
                    a_to_b_forwarded++;
                end

                // Virtual network bridge: forward B->A
                for (int unsigned i = 0; i < b_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_b, mem_a,
                        txq_b.desc_table_addr, txq_b.device_ring_addr, queue_size_b, tx_used_idx_b,
                        rxq_a.desc_table_addr, rxq_a.driver_ring_addr, rxq_a.device_ring_addr,
                        queue_size_a, rx_avail_consumed_a, rx_used_idx_a,
                        b_desc_ids[i]
                    );
                    b_to_a_forwarded++;
                end

                // Poll TX used rings to reclaim descriptors
                begin
                    uvm_object token;
                    int unsigned used_len;
                    while (txq_a.poll_used(token, used_len)) begin end
                    while (txq_b.poll_used(token, used_len)) begin end
                end

                // Poll RX used rings and verify data
                // VIP B receives A->B packets
                begin
                    uvm_object token;
                    int unsigned used_len;

                    while (rxq_b.poll_used(token, used_len)) begin
                        int unsigned pkt_idx = b_rx_received;
                        if (used_len == 256 && a_tx_packets.exists(pkt_idx)) begin
                            a_to_b_data_ok++;
                        end else begin
                            a_to_b_data_err++;
                        end
                        b_rx_received++;
                    end
                end

                // VIP A receives B->A packets
                begin
                    uvm_object token;
                    int unsigned used_len;

                    while (rxq_a.poll_used(token, used_len)) begin
                        int unsigned pkt_idx = a_rx_received;
                        if (used_len == 256 && b_tx_packets.exists(pkt_idx)) begin
                            b_to_a_data_ok++;
                        end else begin
                            b_to_a_data_err++;
                        end
                        a_rx_received++;
                    end
                end

                // Cleanup batch queues
                txq_a.free_rings();
                rxq_a.free_rings();
                txq_b.free_rings();
                rxq_b.free_rings();

                a_remaining -= a_batch;
                b_remaining -= b_batch;
                batch_num++;
                #10ns;
            end
        end

        end_time = $realtime;

        // Report
        `uvm_info("DUAL_TEST", $sformatf(
            "  VIP A->B: %0d TX, %0d forwarded, %0d RX by B, %0d/%0d data OK",
            a_tx_submitted, a_to_b_forwarded, b_rx_received, a_to_b_data_ok, a_to_b_count), UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf(
            "  VIP B->A: %0d TX, %0d forwarded, %0d RX by A, %0d/%0d data OK",
            b_tx_submitted, b_to_a_forwarded, a_rx_received, b_to_a_data_ok, b_to_a_count), UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf(
            "  Total throughput: %0d packets in %0t",
            a_tx_submitted + b_tx_submitted, end_time - start_time), UVM_LOW)

        if (a_tx_submitted == a_to_b_count && b_tx_submitted == b_to_a_count &&
            b_rx_received == a_to_b_count && a_rx_received == b_to_a_count &&
            a_to_b_data_err == 0 && b_to_a_data_err == 0) begin
            tests_passed++;
            `uvm_info("DUAL_TEST", $sformatf("  %s PASSED", test_name), UVM_LOW)
        end else begin
            tests_failed++;
            `uvm_error("DUAL_TEST", $sformatf(
                "  %s FAILED: a_tx=%0d b_tx=%0d b_rx=%0d a_rx=%0d a2b_err=%0d b2a_err=%0d",
                test_name, a_tx_submitted, b_tx_submitted,
                b_rx_received, a_rx_received, a_to_b_data_err, b_to_a_data_err))
        end

        // Cleanup stored packets
        a_tx_packets.delete();
        b_tx_packets.delete();
    endtask

    // ========================================================================
    // Test 3: Variable Packet Sizes
    // ========================================================================
    virtual task test_variable_sizes();
        int unsigned pkt_sizes[] = '{64, 128, 256, 512, 1024, 1500};
        int unsigned pkts_per_size = 80;
        int unsigned total_pkts;
        int unsigned queue_size = 256;

        int unsigned a_tx_submitted, b_rx_received;
        int unsigned b_tx_submitted, a_rx_received;
        int unsigned a_to_b_data_ok, b_to_a_data_ok;
        int unsigned a_to_b_data_err, b_to_a_data_err;

        byte unsigned a_tx_packets[int unsigned][$];
        byte unsigned b_tx_packets[int unsigned][$];

        realtime start_time, end_time;

        tests_run++;
        total_pkts = pkts_per_size * pkt_sizes.size();
        `uvm_info("DUAL_TEST", $sformatf("--- Test 3: Variable sizes (%0d packets/direction) ---",
                                          total_pkts), UVM_LOW)

        a_tx_submitted = 0; b_tx_submitted = 0;
        b_rx_received  = 0; a_rx_received  = 0;
        a_to_b_data_ok = 0; b_to_a_data_ok = 0;
        a_to_b_data_err = 0; b_to_a_data_err = 0;

        start_time = $realtime;

        // Process each size in batches
        foreach (pkt_sizes[si]) begin
            int unsigned pkt_size = pkt_sizes[si];
            int unsigned remaining = pkts_per_size;

            `uvm_info("DUAL_TEST", $sformatf("  Testing size: %0d bytes", pkt_size), UVM_MEDIUM)

            while (remaining > 0) begin
                split_virtqueue txq_a, rxq_a, txq_b, rxq_b;
                int unsigned batch_size;
                int unsigned a_desc_ids[$], b_desc_ids[$];
                int unsigned tx_used_idx_a = 0, tx_used_idx_b = 0;
                int unsigned rx_used_idx_a = 0, rx_used_idx_b = 0;
                int unsigned rx_avail_consumed_a = 0, rx_avail_consumed_b = 0;

                batch_size = (remaining > queue_size) ? queue_size : remaining;

                // Create fresh queues for each batch
                txq_a = split_virtqueue::type_id::create("txq_a_vs");
                txq_a.setup(1, queue_size, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                txq_a.alloc_rings();

                rxq_a = split_virtqueue::type_id::create("rxq_a_vs");
                rxq_a.setup(0, queue_size, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                rxq_a.alloc_rings();

                txq_b = split_virtqueue::type_id::create("txq_b_vs");
                txq_b.setup(1, queue_size, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                txq_b.alloc_rings();

                rxq_b = split_virtqueue::type_id::create("rxq_b_vs");
                rxq_b.setup(0, queue_size, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                rxq_b.alloc_rings();

                a_desc_ids = {};
                b_desc_ids = {};

                // Pre-fill RX
                for (int unsigned i = 0; i < batch_size; i++) begin
                    prefill_rx_buffer(rxq_a, mem_a, 1600);
                    prefill_rx_buffer(rxq_b, mem_b, 1600);
                end

                // Submit TX both directions
                for (int unsigned i = 0; i < batch_size; i++) begin
                    byte unsigned pkt_data_a[$], pkt_data_b[$];
                    int unsigned desc_id;

                    build_directed_packet(a_tx_submitted, pkt_size, 0, pkt_data_a);
                    desc_id = submit_tx_packet(txq_a, mem_a, pkt_data_a, pkt_size);
                    if (desc_id != '1) begin
                        a_desc_ids.push_back(desc_id);
                        a_tx_packets[a_tx_submitted] = pkt_data_a;
                        a_tx_submitted++;
                    end

                    build_directed_packet(b_tx_submitted, pkt_size, 1, pkt_data_b);
                    desc_id = submit_tx_packet(txq_b, mem_b, pkt_data_b, pkt_size);
                    if (desc_id != '1) begin
                        b_desc_ids.push_back(desc_id);
                        b_tx_packets[b_tx_submitted] = pkt_data_b;
                        b_tx_submitted++;
                    end
                end

                // Forward A->B
                for (int unsigned i = 0; i < a_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_a, mem_b,
                        txq_a.desc_table_addr, txq_a.device_ring_addr, queue_size, tx_used_idx_a,
                        rxq_b.desc_table_addr, rxq_b.driver_ring_addr, rxq_b.device_ring_addr,
                        queue_size, rx_avail_consumed_b, rx_used_idx_b,
                        a_desc_ids[i]
                    );
                end

                // Forward B->A
                for (int unsigned i = 0; i < b_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_b, mem_a,
                        txq_b.desc_table_addr, txq_b.device_ring_addr, queue_size, tx_used_idx_b,
                        rxq_a.desc_table_addr, rxq_a.driver_ring_addr, rxq_a.device_ring_addr,
                        queue_size, rx_avail_consumed_a, rx_used_idx_a,
                        b_desc_ids[i]
                    );
                end

                // Poll and verify
                begin
                    uvm_object token;
                    int unsigned used_len;
                    while (txq_a.poll_used(token, used_len)) begin end
                    while (txq_b.poll_used(token, used_len)) begin end

                    while (rxq_b.poll_used(token, used_len)) begin
                        if (used_len == pkt_size) a_to_b_data_ok++;
                        else a_to_b_data_err++;
                        b_rx_received++;
                    end

                    while (rxq_a.poll_used(token, used_len)) begin
                        if (used_len == pkt_size) b_to_a_data_ok++;
                        else b_to_a_data_err++;
                        a_rx_received++;
                    end
                end

                txq_a.free_rings();
                rxq_a.free_rings();
                txq_b.free_rings();
                rxq_b.free_rings();

                remaining -= batch_size;
                #10ns;
            end
        end

        end_time = $realtime;

        `uvm_info("DUAL_TEST", "  Sizes tested: 64,128,256,512,1024,1500", UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf(
            "  A->B: %0d/%0d data OK, B->A: %0d/%0d data OK",
            a_to_b_data_ok, total_pkts, b_to_a_data_ok, total_pkts), UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf(
            "  All data integrity verified"), UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf(
            "  Elapsed: %0t", end_time - start_time), UVM_LOW)

        if (a_to_b_data_err == 0 && b_to_a_data_err == 0 &&
            a_tx_submitted == total_pkts && b_tx_submitted == total_pkts &&
            b_rx_received == total_pkts && a_rx_received == total_pkts) begin
            tests_passed++;
            `uvm_info("DUAL_TEST", "  Test 3 PASSED", UVM_LOW)
        end else begin
            tests_failed++;
            `uvm_error("DUAL_TEST", $sformatf(
                "  Test 3 FAILED: a_tx=%0d b_tx=%0d b_rx=%0d a_rx=%0d errs=%0d+%0d",
                a_tx_submitted, b_tx_submitted, b_rx_received, a_rx_received,
                a_to_b_data_err, b_to_a_data_err))
        end

        a_tx_packets.delete();
        b_tx_packets.delete();
    endtask

    // ========================================================================
    // Test 4: Queue Wrap Stress
    // ========================================================================
    virtual task test_queue_wrap_stress();
        int unsigned queue_size = 32;  // Small queue for frequent wraps
        int unsigned pkts_per_dir = 500;
        int unsigned a_tx_submitted, b_tx_submitted;
        int unsigned b_rx_received, a_rx_received;
        int unsigned a_to_b_data_ok, b_to_a_data_ok;
        int unsigned a_to_b_data_err, b_to_a_data_err;
        int unsigned total_cycles;
        int unsigned desc_leak_count;
        realtime start_time, end_time;

        tests_run++;
        `uvm_info("DUAL_TEST", $sformatf(
            "--- Test 4: Queue wrap stress (qsize=%0d, %0d pkts/dir) ---",
            queue_size, pkts_per_dir), UVM_LOW)

        a_tx_submitted = 0; b_tx_submitted = 0;
        b_rx_received  = 0; a_rx_received  = 0;
        a_to_b_data_ok = 0; b_to_a_data_ok = 0;
        a_to_b_data_err = 0; b_to_a_data_err = 0;
        total_cycles = 0;
        desc_leak_count = 0;

        start_time = $realtime;

        begin
            int unsigned a_remaining = pkts_per_dir;
            int unsigned b_remaining = pkts_per_dir;

            while (a_remaining > 0 || b_remaining > 0) begin
                split_virtqueue txq_a, rxq_a, txq_b, rxq_b;
                int unsigned a_batch, b_batch;
                int unsigned a_desc_ids[$], b_desc_ids[$];
                int unsigned tx_used_idx_a = 0, tx_used_idx_b = 0;
                int unsigned rx_used_idx_a = 0, rx_used_idx_b = 0;
                int unsigned rx_avail_consumed_a = 0, rx_avail_consumed_b = 0;

                a_batch = (a_remaining > queue_size) ? queue_size : a_remaining;
                b_batch = (b_remaining > queue_size) ? queue_size : b_remaining;

                txq_a = split_virtqueue::type_id::create("txq_a_ws");
                txq_a.setup(1, queue_size, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                txq_a.alloc_rings();

                rxq_a = split_virtqueue::type_id::create("rxq_a_ws");
                rxq_a.setup(0, queue_size, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                rxq_a.alloc_rings();

                txq_b = split_virtqueue::type_id::create("txq_b_ws");
                txq_b.setup(1, queue_size, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                txq_b.alloc_rings();

                rxq_b = split_virtqueue::type_id::create("rxq_b_ws");
                rxq_b.setup(0, queue_size, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                rxq_b.alloc_rings();

                a_desc_ids = {};
                b_desc_ids = {};

                // Pre-fill RX
                for (int unsigned i = 0; i < b_batch; i++)
                    prefill_rx_buffer(rxq_a, mem_a, 300);
                for (int unsigned i = 0; i < a_batch; i++)
                    prefill_rx_buffer(rxq_b, mem_b, 300);

                // Submit TX
                for (int unsigned i = 0; i < a_batch; i++) begin
                    byte unsigned pkt_data[$];
                    int unsigned desc_id;
                    build_directed_packet(a_tx_submitted, 128, 0, pkt_data);
                    desc_id = submit_tx_packet(txq_a, mem_a, pkt_data, 128);
                    if (desc_id != '1) begin
                        a_desc_ids.push_back(desc_id);
                        a_tx_submitted++;
                    end
                end

                for (int unsigned i = 0; i < b_batch; i++) begin
                    byte unsigned pkt_data[$];
                    int unsigned desc_id;
                    build_directed_packet(b_tx_submitted, 128, 1, pkt_data);
                    desc_id = submit_tx_packet(txq_b, mem_b, pkt_data, 128);
                    if (desc_id != '1) begin
                        b_desc_ids.push_back(desc_id);
                        b_tx_submitted++;
                    end
                end

                // Forward
                for (int unsigned i = 0; i < a_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_a, mem_b,
                        txq_a.desc_table_addr, txq_a.device_ring_addr, queue_size, tx_used_idx_a,
                        rxq_b.desc_table_addr, rxq_b.driver_ring_addr, rxq_b.device_ring_addr,
                        queue_size, rx_avail_consumed_b, rx_used_idx_b,
                        a_desc_ids[i]
                    );
                end

                for (int unsigned i = 0; i < b_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_b, mem_a,
                        txq_b.desc_table_addr, txq_b.device_ring_addr, queue_size, tx_used_idx_b,
                        rxq_a.desc_table_addr, rxq_a.driver_ring_addr, rxq_a.device_ring_addr,
                        queue_size, rx_avail_consumed_a, rx_used_idx_a,
                        b_desc_ids[i]
                    );
                end

                // Poll and verify
                begin
                    uvm_object token;
                    int unsigned used_len;

                    while (txq_a.poll_used(token, used_len)) begin end
                    while (txq_b.poll_used(token, used_len)) begin end

                    while (rxq_b.poll_used(token, used_len)) begin
                        if (used_len == 128) a_to_b_data_ok++;
                        else a_to_b_data_err++;
                        b_rx_received++;
                    end

                    while (rxq_a.poll_used(token, used_len)) begin
                        if (used_len == 128) b_to_a_data_ok++;
                        else b_to_a_data_err++;
                        a_rx_received++;
                    end
                end

                // Check for descriptor leaks
                begin
                    int unsigned a_tx_free = txq_a.get_free_count();
                    int unsigned a_rx_free = rxq_a.get_free_count();
                    int unsigned b_tx_free = txq_b.get_free_count();
                    int unsigned b_rx_free = rxq_b.get_free_count();

                    if (a_tx_free != queue_size || a_rx_free != queue_size ||
                        b_tx_free != queue_size || b_rx_free != queue_size) begin
                        `uvm_error("DUAL_TEST", $sformatf(
                            "  Descriptor leak at cycle %0d: a_tx=%0d a_rx=%0d b_tx=%0d b_rx=%0d (expected %0d)",
                            total_cycles, a_tx_free, a_rx_free, b_tx_free, b_rx_free, queue_size))
                        desc_leak_count++;
                    end
                end

                txq_a.free_rings();
                rxq_a.free_rings();
                txq_b.free_rings();
                rxq_b.free_rings();

                a_remaining -= a_batch;
                b_remaining -= b_batch;
                total_cycles++;
                #5ns;
            end
        end

        end_time = $realtime;

        `uvm_info("DUAL_TEST", $sformatf(
            "  Queue size: %0d, cycles: %0d", queue_size, total_cycles), UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf(
            "  A->B: %0d OK, B->A: %0d OK", a_to_b_data_ok, b_to_a_data_ok), UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf(
            "  %0d descriptor leaks", desc_leak_count), UVM_LOW)

        if (a_tx_submitted == pkts_per_dir && b_tx_submitted == pkts_per_dir &&
            b_rx_received == pkts_per_dir && a_rx_received == pkts_per_dir &&
            a_to_b_data_err == 0 && b_to_a_data_err == 0 && desc_leak_count == 0) begin
            tests_passed++;
            `uvm_info("DUAL_TEST", "  Test 4 PASSED", UVM_LOW)
        end else begin
            tests_failed++;
            `uvm_error("DUAL_TEST", $sformatf(
                "  Test 4 FAILED: a_tx=%0d b_tx=%0d b_rx=%0d a_rx=%0d errs=%0d leaks=%0d",
                a_tx_submitted, b_tx_submitted, b_rx_received, a_rx_received,
                a_to_b_data_err + b_to_a_data_err, desc_leak_count))
        end
    endtask

    // ========================================================================
    // Test 5: Bandwidth Control with 20K Packets
    //
    // Runs three phases comparing unlimited, 1Gbps, and 100Mbps bandwidth
    // limiting using the perf_monitor's token-bucket rate limiter.
    // ========================================================================
    virtual task test_bandwidth_control();
        // Phase results
        realtime phase_time[3];
        real     phase_throughput_mbps[3];
        int unsigned phase_throttle_count[3];
        int unsigned phase_total_pkts[3];
        string   phase_label[3];

        int unsigned pkts_per_dir = 10000;
        int unsigned pkt_size     = 1500;
        int unsigned queue_size   = 256;

        // Phase configs: {mbps}  0 = unlimited
        int unsigned phase_mbps[3] = '{0, 10000, 1000};

        tests_run++;
        `uvm_info("DUAL_TEST", "--- Test 5: Bandwidth Control with 20K packets ---", UVM_LOW)

        phase_label[0] = "unlimited";
        phase_label[1] = "10Gbps";
        phase_label[2] = "1Gbps";

        for (int phase_idx = 0; phase_idx < 3; phase_idx++) begin
            int unsigned a_tx_submitted, b_tx_submitted;
            int unsigned b_rx_received, a_rx_received;
            int unsigned throttle_count;
            int unsigned a_remaining, b_remaining;
            realtime start_time, end_time;
            real elapsed_ns_real;

            // Configure bandwidth for this phase
            if (phase_mbps[phase_idx] == 0) begin
                bw_mon.bw_limit_enable = 0;
                bw_mon.bw_limit_mbps = 0;
            end else begin
                bw_mon.configure_bw(phase_mbps[phase_idx]);
            end
            bw_mon.reset_stats();

            `uvm_info("DUAL_TEST", $sformatf(
                "  Phase %0d (%s): %0d pkts/dir, pkt_size=%0d",
                phase_idx + 1, phase_label[phase_idx], pkts_per_dir, pkt_size), UVM_LOW)

            a_tx_submitted = 0;
            b_tx_submitted = 0;
            b_rx_received  = 0;
            a_rx_received  = 0;
            throttle_count = 0;
            a_remaining    = pkts_per_dir;
            b_remaining    = pkts_per_dir;

            start_time = $realtime;

            while (a_remaining > 0 || b_remaining > 0) begin
                split_virtqueue txq_a, rxq_a, txq_b, rxq_b;
                int unsigned a_batch, b_batch;
                int unsigned a_desc_ids[$], b_desc_ids[$];
                int unsigned tx_used_idx_a = 0, tx_used_idx_b = 0;
                int unsigned rx_used_idx_a = 0, rx_used_idx_b = 0;
                int unsigned rx_avail_consumed_a = 0, rx_avail_consumed_b = 0;

                a_batch = (a_remaining > queue_size) ? queue_size : a_remaining;
                b_batch = (b_remaining > queue_size) ? queue_size : b_remaining;

                // Create fresh queues
                txq_a = split_virtqueue::type_id::create("txq_a_bw");
                txq_a.setup(1, queue_size, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                txq_a.alloc_rings();

                rxq_a = split_virtqueue::type_id::create("rxq_a_bw");
                rxq_a.setup(0, queue_size, mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a, 16'h0100);
                rxq_a.alloc_rings();

                txq_b = split_virtqueue::type_id::create("txq_b_bw");
                txq_b.setup(1, queue_size, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                txq_b.alloc_rings();

                rxq_b = split_virtqueue::type_id::create("rxq_b_bw");
                rxq_b.setup(0, queue_size, mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b, 16'h0200);
                rxq_b.alloc_rings();

                a_desc_ids = {};
                b_desc_ids = {};

                // Pre-fill RX buffers
                for (int unsigned i = 0; i < b_batch; i++)
                    prefill_rx_buffer(rxq_a, mem_a, pkt_size + 100);
                for (int unsigned i = 0; i < a_batch; i++)
                    prefill_rx_buffer(rxq_b, mem_b, pkt_size + 100);

                // Submit A->B TX packets with bandwidth control
                for (int unsigned i = 0; i < a_batch; i++) begin
                    byte unsigned pkt_data[$];
                    int unsigned desc_id;

                    // Bandwidth gate: calculate exact wait time for token refill
                    if (bw_mon.bw_limit_enable && !bw_mon.can_send(pkt_size)) begin
                        int unsigned wait_ns;
                        // bytes_needed / rate_bytes_per_ns = bytes_needed * 8000 / bw_limit_mbps
                        wait_ns = (pkt_size * 8000) / bw_mon.bw_limit_mbps + 1;
                        throttle_count++;
                        #(wait_ns * 1ns);
                    end
                    if (bw_mon.bw_limit_enable)
                        bw_mon.on_sent(pkt_size);

                    build_directed_packet(a_tx_submitted, pkt_size, 0, pkt_data);
                    desc_id = submit_tx_packet(txq_a, mem_a, pkt_data, pkt_size);
                    if (desc_id != '1) begin
                        a_desc_ids.push_back(desc_id);
                        a_tx_submitted++;
                    end
                end

                // Submit B->A TX packets with bandwidth control
                for (int unsigned i = 0; i < b_batch; i++) begin
                    byte unsigned pkt_data[$];
                    int unsigned desc_id;

                    // Bandwidth gate: calculate exact wait time for token refill
                    if (bw_mon.bw_limit_enable && !bw_mon.can_send(pkt_size)) begin
                        int unsigned wait_ns;
                        wait_ns = (pkt_size * 8000) / bw_mon.bw_limit_mbps + 1;
                        throttle_count++;
                        #(wait_ns * 1ns);
                    end
                    if (bw_mon.bw_limit_enable)
                        bw_mon.on_sent(pkt_size);

                    build_directed_packet(b_tx_submitted, pkt_size, 1, pkt_data);
                    desc_id = submit_tx_packet(txq_b, mem_b, pkt_data, pkt_size);
                    if (desc_id != '1) begin
                        b_desc_ids.push_back(desc_id);
                        b_tx_submitted++;
                    end
                end

                // Forward A->B
                for (int unsigned i = 0; i < a_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_a, mem_b,
                        txq_a.desc_table_addr, txq_a.device_ring_addr, queue_size, tx_used_idx_a,
                        rxq_b.desc_table_addr, rxq_b.driver_ring_addr, rxq_b.device_ring_addr,
                        queue_size, rx_avail_consumed_b, rx_used_idx_b,
                        a_desc_ids[i]
                    );
                end

                // Forward B->A
                for (int unsigned i = 0; i < b_desc_ids.size(); i++) begin
                    forward_packet(
                        mem_b, mem_a,
                        txq_b.desc_table_addr, txq_b.device_ring_addr, queue_size, tx_used_idx_b,
                        rxq_a.desc_table_addr, rxq_a.driver_ring_addr, rxq_a.device_ring_addr,
                        queue_size, rx_avail_consumed_a, rx_used_idx_a,
                        b_desc_ids[i]
                    );
                end

                // Poll used rings
                begin
                    uvm_object token;
                    int unsigned used_len;
                    while (txq_a.poll_used(token, used_len)) begin end
                    while (txq_b.poll_used(token, used_len)) begin end

                    while (rxq_b.poll_used(token, used_len)) begin
                        b_rx_received++;
                    end
                    while (rxq_a.poll_used(token, used_len)) begin
                        a_rx_received++;
                    end
                end

                txq_a.free_rings();
                rxq_a.free_rings();
                txq_b.free_rings();
                rxq_b.free_rings();

                a_remaining -= a_batch;
                b_remaining -= b_batch;
                #10ns;
            end

            end_time = $realtime;

            // Calculate results for this phase
            phase_time[phase_idx] = end_time - start_time;
            phase_throttle_count[phase_idx] = throttle_count;
            phase_total_pkts[phase_idx] = a_tx_submitted + b_tx_submitted;

            // Throughput in Mbps: (total_bytes * 8) / elapsed_ns * 1000
            elapsed_ns_real = $rtoi(phase_time[phase_idx]);
            if (elapsed_ns_real > 0) begin
                real total_bytes;
                total_bytes = real'(phase_total_pkts[phase_idx]) * real'(pkt_size);
                phase_throughput_mbps[phase_idx] = (total_bytes * 8.0) / (elapsed_ns_real / 1000.0);
            end else begin
                phase_throughput_mbps[phase_idx] = 0.0;
            end

            `uvm_info("DUAL_TEST", $sformatf(
                "  Phase %0d (%s): %0d pkts in %0t, %.2f Mbps, %0d throttle events",
                phase_idx + 1, phase_label[phase_idx],
                phase_total_pkts[phase_idx], phase_time[phase_idx],
                phase_throughput_mbps[phase_idx], throttle_count), UVM_LOW)
            `uvm_info("DUAL_TEST", $sformatf(
                "    A->B: %0d TX, %0d RX | B->A: %0d TX, %0d RX",
                a_tx_submitted, b_rx_received, b_tx_submitted, a_rx_received), UVM_LOW)

            #100ns;
            bridge.drain();
        end

        // Verify results
        begin
            bit pass = 1;

            // All phases must have sent/received all 20K packets
            for (int i = 0; i < 3; i++) begin
                if (phase_total_pkts[i] != pkts_per_dir * 2) begin
                    `uvm_error("DUAL_TEST", $sformatf(
                        "  Phase %0d: expected %0d total packets, got %0d",
                        i + 1, pkts_per_dir * 2, phase_total_pkts[i]))
                    pass = 0;
                end
            end

            // Unlimited should have 0 throttle events
            if (phase_throttle_count[0] != 0) begin
                `uvm_error("DUAL_TEST", $sformatf(
                    "  Phase 1 (unlimited): expected 0 throttle events, got %0d",
                    phase_throttle_count[0]))
                pass = 0;
            end

            // Rate-limited phases should have throttle events
            if (phase_throttle_count[1] == 0) begin
                `uvm_error("DUAL_TEST",
                    "  Phase 2 (10Gbps): expected throttle events, got 0")
                pass = 0;
            end
            if (phase_throttle_count[2] == 0) begin
                `uvm_error("DUAL_TEST",
                    "  Phase 3 (1Gbps): expected throttle events, got 0")
                pass = 0;
            end

            // 1Gbps should have more throttle events than 10Gbps
            if (phase_throttle_count[2] <= phase_throttle_count[1]) begin
                `uvm_error("DUAL_TEST", $sformatf(
                    "  1Gbps throttle (%0d) should exceed 10Gbps throttle (%0d)",
                    phase_throttle_count[2], phase_throttle_count[1]))
                pass = 0;
            end

            // Elapsed time ordering: unlimited < 10Gbps < 1Gbps
            if (phase_time[0] >= phase_time[1]) begin
                `uvm_error("DUAL_TEST", $sformatf(
                    "  Unlimited time (%0t) should be less than 10Gbps time (%0t)",
                    phase_time[0], phase_time[1]))
                pass = 0;
            end
            if (phase_time[1] >= phase_time[2]) begin
                `uvm_error("DUAL_TEST", $sformatf(
                    "  10Gbps time (%0t) should be less than 1Gbps time (%0t)",
                    phase_time[1], phase_time[2]))
                pass = 0;
            end

            `uvm_info("DUAL_TEST", $sformatf(
                "  Throughput comparison: unlimited(%.1f) > 10Gbps(%.1f) > 1Gbps(%.1f) Mbps",
                phase_throughput_mbps[0], phase_throughput_mbps[1], phase_throughput_mbps[2]), UVM_LOW)

            if (pass) begin
                tests_passed++;
                `uvm_info("DUAL_TEST", "  Test 5 PASSED", UVM_LOW)
            end else begin
                tests_failed++;
                `uvm_error("DUAL_TEST", "  Test 5 FAILED")
            end
        end
    endtask

    // ========================================================================
    // Helper: Pre-fill an RX buffer in a queue
    // ========================================================================
    function void prefill_rx_buffer(
        split_virtqueue rxq,
        host_mem_manager mem,
        int unsigned buf_size
    );
        virtio_sg_list sgs[];
        virtio_sg_entry e;
        virtio_sg_list sg;
        bit [63:0] buf_addr;
        int unsigned desc_id;

        buf_addr = mem.alloc(buf_size, .align(64));
        if (buf_addr == '1) begin
            `uvm_error("DUAL_TEST", "RX buffer alloc failed")
            return;
        end

        e.addr = buf_addr;
        e.len  = buf_size;
        sg.entries.push_back(e);
        sgs    = new[1];
        sgs[0] = sg;

        desc_id = rxq.add_buf(sgs, 0, 1, null, 0);
        if (desc_id == '1) begin
            `uvm_error("DUAL_TEST", "RX add_buf failed")
        end
    endfunction

    // ========================================================================
    // Helper: Submit a TX packet to a queue
    // ========================================================================
    function int unsigned submit_tx_packet(
        split_virtqueue txq,
        host_mem_manager mem,
        byte unsigned pkt_data[$],
        int unsigned pkt_size
    );
        virtio_sg_list sgs[];
        virtio_sg_entry e;
        virtio_sg_list sg;
        bit [63:0] buf_addr;
        byte pkt_bytes[];
        int unsigned desc_id;

        buf_addr = mem.alloc(pkt_size, .align(64));
        if (buf_addr == '1) begin
            `uvm_error("DUAL_TEST", "TX buffer alloc failed")
            return '1;
        end

        pkt_bytes = new[pkt_data.size()];
        foreach (pkt_data[j]) pkt_bytes[j] = pkt_data[j];
        mem.write_mem(buf_addr, pkt_bytes);

        e.addr = buf_addr;
        e.len  = pkt_size;
        sg.entries.push_back(e);
        sgs    = new[1];
        sgs[0] = sg;

        desc_id = txq.add_buf(sgs, 1, 0, null, 0);
        if (desc_id == '1)
            `uvm_error("DUAL_TEST", "TX add_buf failed")

        return desc_id;
    endfunction

    // ========================================================================
    // Virtual Network Bridge: Forward one packet from src TX to dst RX
    //
    // Reads TX descriptor from src_mem, writes data into dst_mem RX buffer,
    // updates both used rings.
    // ========================================================================
    function void forward_packet(
        host_mem_manager    src_mem,
        host_mem_manager    dst_mem,
        // TX side (source)
        bit [63:0]          tx_desc_table_addr,
        bit [63:0]          tx_used_ring_addr,
        int unsigned        tx_queue_size,
        ref int unsigned    tx_used_idx,
        // RX side (destination)
        bit [63:0]          rx_desc_table_addr,
        bit [63:0]          rx_avail_ring_addr,
        bit [63:0]          rx_used_ring_addr,
        int unsigned        rx_queue_size,
        ref int unsigned    rx_avail_consumed_idx,
        ref int unsigned    rx_used_idx,
        // TX descriptor to process
        int unsigned        tx_desc_id
    );
        // Read TX descriptor
        byte tx_desc_data[];
        bit [63:0] tx_buf_addr;
        bit [31:0] tx_buf_len;

        src_mem.read_mem(tx_desc_table_addr + tx_desc_id * 16, 16, tx_desc_data);
        tx_buf_addr = {tx_desc_data[7], tx_desc_data[6], tx_desc_data[5], tx_desc_data[4],
                       tx_desc_data[3], tx_desc_data[2], tx_desc_data[1], tx_desc_data[0]};
        tx_buf_len  = {tx_desc_data[11], tx_desc_data[10], tx_desc_data[9], tx_desc_data[8]};

        // Read TX packet data from source host memory
        begin
            byte pkt_data[];
            src_mem.read_mem(tx_buf_addr, tx_buf_len, pkt_data);

            // Get RX buffer from destination's avail ring
            begin
                byte rx_avail_entry[];
                bit [15:0] rx_desc_id_16;
                int unsigned rx_desc_id;
                byte rx_desc_data[];
                bit [63:0] rx_buf_addr;
                bit [31:0] rx_buf_len;

                dst_mem.read_mem(rx_avail_ring_addr + 4 +
                    (rx_avail_consumed_idx % rx_queue_size) * 2, 2, rx_avail_entry);
                rx_desc_id_16 = {rx_avail_entry[1], rx_avail_entry[0]};
                rx_desc_id = rx_desc_id_16;

                // Read RX descriptor
                dst_mem.read_mem(rx_desc_table_addr + rx_desc_id * 16, 16, rx_desc_data);
                rx_buf_addr = {rx_desc_data[7], rx_desc_data[6], rx_desc_data[5], rx_desc_data[4],
                               rx_desc_data[3], rx_desc_data[2], rx_desc_data[1], rx_desc_data[0]};
                rx_buf_len  = {rx_desc_data[11], rx_desc_data[10], rx_desc_data[9], rx_desc_data[8]};

                // Copy data from source to destination host memory
                if (tx_buf_len <= rx_buf_len) begin
                    dst_mem.write_mem(rx_buf_addr, pkt_data);
                end

                // Write RX used ring entry
                begin
                    byte used_entry[8];
                    byte used_idx_data[2];
                    int unsigned rx_ring_offset;

                    rx_ring_offset = 4 + (rx_used_idx % rx_queue_size) * 8;
                    used_entry[0] = rx_desc_id[7:0];
                    used_entry[1] = rx_desc_id[15:8];
                    used_entry[2] = rx_desc_id[23:16];
                    used_entry[3] = rx_desc_id[31:24];
                    used_entry[4] = tx_buf_len[7:0];
                    used_entry[5] = tx_buf_len[15:8];
                    used_entry[6] = tx_buf_len[23:16];
                    used_entry[7] = tx_buf_len[31:24];
                    dst_mem.write_mem(rx_used_ring_addr + rx_ring_offset, used_entry);

                    rx_used_idx++;
                    used_idx_data[0] = rx_used_idx[7:0];
                    used_idx_data[1] = rx_used_idx[15:8];
                    dst_mem.write_mem(rx_used_ring_addr + 2, used_idx_data);
                end

                rx_avail_consumed_idx++;
            end
        end

        // Write TX used ring entry
        begin
            byte used_entry[8];
            byte used_idx_data[2];
            int unsigned tx_ring_offset;

            tx_ring_offset = 4 + (tx_used_idx % tx_queue_size) * 8;
            used_entry[0] = tx_desc_id[7:0];
            used_entry[1] = tx_desc_id[15:8];
            used_entry[2] = tx_desc_id[23:16];
            used_entry[3] = tx_desc_id[31:24];
            used_entry[4] = 8'h00;
            used_entry[5] = 8'h00;
            used_entry[6] = 8'h00;
            used_entry[7] = 8'h00;
            src_mem.write_mem(tx_used_ring_addr + tx_ring_offset, used_entry);

            tx_used_idx++;
            used_idx_data[0] = tx_used_idx[7:0];
            used_idx_data[1] = tx_used_idx[15:8];
            src_mem.write_mem(tx_used_ring_addr + 2, used_idx_data);
        end
    endfunction

    // ========================================================================
    // Result Reporting
    // ========================================================================
    virtual function void report_results();
        bridge.report();

        `uvm_info("DUAL_TEST", "============================================================", UVM_LOW)
        `uvm_info("DUAL_TEST", $sformatf("Test Results: %0d/%0d passed, %0d failed",
            tests_passed, tests_run, tests_failed), UVM_LOW)
        `uvm_info("DUAL_TEST", "============================================================", UVM_LOW)

        if (tests_failed > 0)
            `uvm_error("DUAL_TEST", $sformatf("OVERALL: FAIL (%0d tests failed)", tests_failed))
        else
            `uvm_info("DUAL_TEST", "OVERALL: PASS -- All dual VIP tests passed", UVM_LOW)
    endfunction

    // ========================================================================
    // EP Memory Helpers
    // ========================================================================
    function void write_ep_mem8(pcie_tl_ep_driver drv, bit [63:0] addr, bit [7:0] data);
        drv.mem_space[addr] = data;
    endfunction

    function void write_ep_mem16(pcie_tl_ep_driver drv, bit [63:0] addr, bit [15:0] data);
        drv.mem_space[addr]     = data[7:0];
        drv.mem_space[addr + 1] = data[15:8];
    endfunction

    function void write_ep_mem32(pcie_tl_ep_driver drv, bit [63:0] addr, bit [31:0] data);
        drv.mem_space[addr]     = data[7:0];
        drv.mem_space[addr + 1] = data[15:8];
        drv.mem_space[addr + 2] = data[23:16];
        drv.mem_space[addr + 3] = data[31:24];
    endfunction

    function bit [7:0] read_ep_mem8(pcie_tl_ep_driver drv, bit [63:0] addr);
        return drv.mem_space.exists(addr) ? drv.mem_space[addr] : 8'h00;
    endfunction

    function bit [15:0] read_ep_mem16(pcie_tl_ep_driver drv, bit [63:0] addr);
        bit [15:0] val;
        val[7:0]  = drv.mem_space.exists(addr)     ? drv.mem_space[addr]     : 8'h00;
        val[15:8] = drv.mem_space.exists(addr + 1) ? drv.mem_space[addr + 1] : 8'h00;
        return val;
    endfunction

    function bit [31:0] read_ep_mem32(pcie_tl_ep_driver drv, bit [63:0] addr);
        bit [31:0] val;
        val[7:0]   = drv.mem_space.exists(addr)     ? drv.mem_space[addr]     : 8'h00;
        val[15:8]  = drv.mem_space.exists(addr + 1) ? drv.mem_space[addr + 1] : 8'h00;
        val[23:16] = drv.mem_space.exists(addr + 2) ? drv.mem_space[addr + 2] : 8'h00;
        val[31:24] = drv.mem_space.exists(addr + 3) ? drv.mem_space[addr + 3] : 8'h00;
        return val;
    endfunction

endclass : virtio_dual_test

`endif // VIRTIO_DUAL_TEST_SV
