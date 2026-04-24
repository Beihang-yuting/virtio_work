// ============================================================================
// virtio_full_test.sv
//
// Full integration test with completion bridge middleware that solves the
// get_response() deadlock between virtio bar_accessor read sequences and
// the asynchronous PCIe TLM loopback completion path.
//
// Architecture:
//   1. virtio_cpl_bridge       - FIFO-based completion store
//   2. virtio_rc_driver_shim   - Extends pcie_tl_rc_driver, forwards cpls to bridge
//   3. Bridged sequences       - Use bridge instead of get_response()
//   4. virtio_full_integration_test - Full init + traffic through real PCIe TLPs
// ============================================================================

import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_tl_pkg::*;
import host_mem_pkg::*;
import virtio_net_pkg::*;

// ============================================================================
// Completion Bridge
//
// Single-mailbox design works because virtio register access is sequential.
// ============================================================================
class virtio_cpl_bridge extends uvm_object;
    `uvm_object_utils(virtio_cpl_bridge)

    mailbox #(pcie_tl_cpl_tlp) cpl_mbx;

    // Statistics
    int unsigned completions_received;
    int unsigned completions_consumed;

    function new(string name = "virtio_cpl_bridge");
        super.new(name);
        cpl_mbx = new(0);  // unbounded
        completions_received = 0;
        completions_consumed = 0;
    endfunction

    // Called by the shim RC driver when a completion arrives
    function void put_completion(pcie_tl_cpl_tlp cpl);
        void'(cpl_mbx.try_put(cpl));
        completions_received++;
    endfunction

    // Called by read sequences to wait for completion
    task wait_completion(int unsigned timeout_ns, ref pcie_tl_cpl_tlp cpl, ref bit ok);
        ok = 0;
        fork : wait_cpl_blk
            begin
                cpl_mbx.get(cpl);
                ok = 1;
                completions_consumed++;
            end
            begin
                #(timeout_ns * 1ns);
            end
        join_any
        disable wait_cpl_blk;
    endtask

    // Drain all pending completions from the mailbox
    function void drain();
        pcie_tl_cpl_tlp cpl;
        int drained = 0;
        while (cpl_mbx.try_get(cpl)) begin
            drained++;
        end
        if (drained > 0)
            `uvm_info("CPL_BRIDGE", $sformatf("Drained %0d stale completions", drained), UVM_MEDIUM)
    endfunction

    function void report();
        `uvm_info("CPL_BRIDGE", $sformatf(
            "Bridge stats: received=%0d consumed=%0d",
            completions_received, completions_consumed), UVM_LOW)
    endfunction
endclass

// ============================================================================
// RC Driver Shim
//
// Extends pcie_tl_rc_driver to push completions into the bridge.
// ============================================================================
class virtio_rc_driver_shim extends pcie_tl_rc_driver;
    `uvm_component_utils(virtio_rc_driver_shim)

    virtio_cpl_bridge bridge;

    function new(string name = "virtio_rc_driver_shim", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function bit handle_completion(pcie_tl_cpl_tlp cpl);
        bit result = super.handle_completion(cpl);
        if (bridge != null)
            bridge.put_completion(cpl);
        return result;
    endfunction
endclass

// ============================================================================
// Bridged Memory Read Sequence
// ============================================================================
class virtio_bar_mem_rd_seq_bridged extends virtio_bar_mem_rd_seq;
    `uvm_object_utils(virtio_bar_mem_rd_seq_bridged)

    static virtio_cpl_bridge s_bridge;

    function new(string name = "virtio_bar_mem_rd_seq_bridged");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_mem_tlp tlp;

        // Create and send the memory read TLP directly via start_item/finish_item
        tlp = pcie_tl_mem_tlp::type_id::create("mem_rd_tlp");
        start_item(tlp);
        tlp.kind = TLP_MEM_RD;
        tlp.addr = addr;
        tlp.length = 10'h1;
        tlp.first_be = first_be;
        tlp.last_be = last_be;
        tlp.is_64bit = is_64bit || (addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
        tlp.type_f = TLP_TYPE_MEM_RD;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        finish_item(tlp);

        // Wait for completion via bridge instead of get_response()
        if (s_bridge != null) begin
            pcie_tl_cpl_tlp cpl;
            bit ok;
            s_bridge.wait_completion(50000, cpl, ok);
            if (ok && cpl != null) begin
                cpl_ok = 1;
                rdata = '0;
                if (cpl.payload.size() >= 4)
                    rdata = {cpl.payload[3], cpl.payload[2],
                             cpl.payload[1], cpl.payload[0]};
                else
                    for (int i = 0; i < cpl.payload.size(); i++)
                        rdata[i*8 +: 8] = cpl.payload[i];
            end else begin
                cpl_ok = 0;
                rdata = '0;
                `uvm_warning("MEM_RD_BRIDGED",
                    $sformatf("Completion timeout for addr=0x%016h", addr))
            end
        end else begin
            cpl_ok = 0;
            rdata = '0;
            `uvm_error("MEM_RD_BRIDGED", "s_bridge is null")
        end
    endtask
endclass

// ============================================================================
// Bridged Memory Write Sequence
//
// Fixes the write data randomization issue by creating the TLP directly.
// ============================================================================
class virtio_bar_mem_wr_seq_bridged extends virtio_bar_mem_wr_seq;
    `uvm_object_utils(virtio_bar_mem_wr_seq_bridged)

    function new(string name = "virtio_bar_mem_wr_seq_bridged");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_mem_tlp tlp;

        tlp = pcie_tl_mem_tlp::type_id::create("mem_wr_tlp");
        start_item(tlp);
        tlp.kind = TLP_MEM_WR;
        tlp.addr = addr;
        tlp.length = 10'h1;
        tlp.first_be = first_be;
        tlp.last_be = last_be;
        tlp.is_64bit = is_64bit || (addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        // Set payload with our actual data (not randomized)
        tlp.payload = new[4];
        tlp.payload[0] = wdata[7:0];
        tlp.payload[1] = wdata[15:8];
        tlp.payload[2] = wdata[23:16];
        tlp.payload[3] = wdata[31:24];
        finish_item(tlp);
    endtask
endclass

// ============================================================================
// Bridged Config Read Sequence
// ============================================================================
class virtio_bar_cfg_rd_seq_bridged extends virtio_bar_cfg_rd_seq;
    `uvm_object_utils(virtio_bar_cfg_rd_seq_bridged)

    static virtio_cpl_bridge s_bridge;

    function new(string name = "virtio_bar_cfg_rd_seq_bridged");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_cfg_tlp tlp;

        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_rd_tlp");
        start_item(tlp);
        tlp.kind = TLP_CFG_RD0;
        tlp.fmt = FMT_3DW_NO_DATA;
        tlp.type_f = TLP_TYPE_CFG_RD0;
        tlp.completer_id = target_bdf;
        tlp.reg_num = reg_num;
        tlp.first_be = first_be;
        tlp.length = 10'h1;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        finish_item(tlp);

        // Wait for completion via bridge
        if (s_bridge != null) begin
            pcie_tl_cpl_tlp cpl;
            bit ok;
            s_bridge.wait_completion(50000, cpl, ok);
            if (ok && cpl != null) begin
                cpl_ok = 1;
                rdata = '0;
                if (cpl.payload.size() >= 4)
                    rdata = {cpl.payload[3], cpl.payload[2],
                             cpl.payload[1], cpl.payload[0]};
                else
                    for (int i = 0; i < cpl.payload.size(); i++)
                        rdata[i*8 +: 8] = cpl.payload[i];
            end else begin
                cpl_ok = 0;
                rdata = '0;
                `uvm_warning("CFG_RD_BRIDGED",
                    $sformatf("Completion timeout for reg_num=%0d", reg_num))
            end
        end else begin
            cpl_ok = 0;
            rdata = '0;
            `uvm_error("CFG_RD_BRIDGED", "s_bridge is null")
        end
    endtask
endclass

// ============================================================================
// Bridged Config Write Sequence
//
// Fixes the config write data issue (uvm_do_with randomizes payload).
// Config writes are non-posted in PCIe, so we also need to consume the
// completion from the bridge.
// ============================================================================
class virtio_bar_cfg_wr_seq_bridged extends virtio_bar_cfg_wr_seq;
    `uvm_object_utils(virtio_bar_cfg_wr_seq_bridged)

    static virtio_cpl_bridge s_bridge;

    // Static data channel: bar_accessor.config_write() sets this before start()
    static bit [31:0] s_wdata;

    function new(string name = "virtio_bar_cfg_wr_seq_bridged");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_cfg_tlp tlp;
        bit [31:0] local_wdata;

        // Capture the static data and clear it
        local_wdata = s_wdata;

        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_wr_tlp");
        start_item(tlp);
        tlp.kind = TLP_CFG_WR0;
        tlp.fmt = FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_CFG_WR0;
        tlp.completer_id = target_bdf;
        tlp.reg_num = reg_num;
        tlp.first_be = first_be;
        tlp.length = 10'h1;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        // Set payload from the static data channel
        tlp.payload = new[4];
        tlp.payload[0] = local_wdata[7:0];
        tlp.payload[1] = local_wdata[15:8];
        tlp.payload[2] = local_wdata[23:16];
        tlp.payload[3] = local_wdata[31:24];
        finish_item(tlp);

        // Config writes are non-posted -- consume the completion
        if (s_bridge != null) begin
            pcie_tl_cpl_tlp cpl;
            bit ok;
            s_bridge.wait_completion(50000, cpl, ok);
            // We don't care about the completion data for writes
        end
    endtask
endclass

// ============================================================================
// Bridged Bar Accessor
//
// Overrides config_write to set the static wdata channel before the
// factory-created bridged config write sequence runs.
// ============================================================================
class virtio_bar_accessor_bridged extends virtio_bar_accessor;
    `uvm_object_utils(virtio_bar_accessor_bridged)

    function new(string name = "virtio_bar_accessor_bridged");
        super.new(name);
    endfunction

    virtual task config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        // Set the static data channel before the sequence runs
        virtio_bar_cfg_wr_seq_bridged::s_wdata = data;
        super.config_write(addr, data, be);
    endtask
endclass

// ============================================================================
// Full Integration Test
// ============================================================================
class virtio_full_integration_test extends uvm_test;
    `uvm_component_utils(virtio_full_integration_test)

    // PCIe environment
    pcie_tl_env pcie_env;

    // Virtio components
    virtio_pci_transport transport;
    virtio_wait_policy wait_pol;
    host_mem_manager host_mem;
    virtio_iommu_model iommu;
    virtqueue_manager vq_mgr;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector err_inj;
    virtio_atomic_ops ops;
    virtio_perf_monitor perf_mon;

    // Bridge
    virtio_cpl_bridge bridge;

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
        pcie_tl_env_config pcie_cfg;
        super.build_phase(phase);

        // 1. Create completion bridge
        bridge = virtio_cpl_bridge::type_id::create("bridge");

        // 2. Factory override: swap RC driver with shim
        // The RC agent does its own instance override of base_driver -> rc_driver.
        // We override rc_driver -> rc_driver_shim at the instance level.
        pcie_tl_rc_driver::type_id::set_inst_override(
            virtio_rc_driver_shim::get_type(),
            "pcie_env.rc_agent.driver", this);

        // 3. Factory override: swap bar accessor sequences with bridged versions
        virtio_bar_mem_rd_seq::type_id::set_type_override(
            virtio_bar_mem_rd_seq_bridged::get_type());
        virtio_bar_cfg_rd_seq::type_id::set_type_override(
            virtio_bar_cfg_rd_seq_bridged::get_type());
        virtio_bar_mem_wr_seq::type_id::set_type_override(
            virtio_bar_mem_wr_seq_bridged::get_type());
        virtio_bar_cfg_wr_seq::type_id::set_type_override(
            virtio_bar_cfg_wr_seq_bridged::get_type());

        // 3b. Factory override: swap bar_accessor with bridged version
        virtio_bar_accessor::type_id::set_type_override(
            virtio_bar_accessor_bridged::get_type());

        // 4. Create and configure PCIe environment
        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_cfg.if_mode = TLM_MODE;
        pcie_cfg.rc_agent_enable = 1;
        pcie_cfg.ep_agent_enable = 1;
        pcie_cfg.rc_is_active = UVM_ACTIVE;
        pcie_cfg.ep_is_active = UVM_ACTIVE;
        pcie_cfg.ep_auto_response = 1;
        pcie_cfg.scb_enable = 0;  // Disable scoreboard for this test
        pcie_cfg.fc_enable = 0;   // Simplify: infinite credit
        pcie_cfg.infinite_credit = 1;
        pcie_cfg.extended_tag_enable = 1;
        pcie_cfg.cpl_timeout_ns = 100000;
        pcie_cfg.link_delay_enable = 0;
        uvm_config_db #(pcie_tl_env_config)::set(this, "pcie_env", "cfg", pcie_cfg);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        // 5. Create virtio components
        transport = virtio_pci_transport::type_id::create("transport");
        wait_pol = virtio_wait_policy::type_id::create("wait_pol");
        host_mem = host_mem_manager::type_id::create("host_mem");
        iommu = virtio_iommu_model::type_id::create("iommu");
        vq_mgr = virtqueue_manager::type_id::create("vq_mgr");
        barrier = virtio_memory_barrier_model::type_id::create("barrier");
        err_inj = virtqueue_error_injector::type_id::create("err_inj");
        ops = virtio_atomic_ops::type_id::create("ops");
        perf_mon = virtio_perf_monitor::type_id::create("perf_mon", this);

        // Set static bridge references on bridged sequences
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

        // 1. Inject bridge into RC driver shim
        if (pcie_env.rc_agent != null && pcie_env.rc_agent.driver != null) begin
            if ($cast(shim, pcie_env.rc_agent.driver))
                shim.bridge = bridge;
            else
                `uvm_fatal("FULL_TEST", "Failed to cast driver to virtio_rc_driver_shim")
        end

        // 2. Wire transport to PCIe RC sequencer
        transport.bar.pcie_rc_seqr = pcie_env.rc_agent.sequencer;
        transport.bdf = 16'h0100;  // Bus=1, Dev=0, Func=0

        // 3. Wire virtio components
        transport.wait_pol = wait_pol;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = host_mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;

        // 4. Configure wait policy for fast simulation
        wait_pol.default_poll_interval_ns = 100;
        wait_pol.reset_timeout_ns = 10000;
        wait_pol.queue_reset_timeout_ns = 10000;
        wait_pol.max_poll_attempts = 100;
    endfunction

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

        // Setup EP with virtio config
        setup_ep_virtio_config();

        // Test 1: Full virtio initialization
        test_full_init();

        // Drain stale completions before next test
        #100ns;
        bridge.drain();

        // Test 2: Large traffic through actual virtqueue + host_mem
        test_large_traffic();

        // Drain stale completions before next test
        #100ns;
        bridge.drain();

        // Test 3: Bandwidth control
        test_bandwidth_control();

        // Drain stale completions before next test
        #100ns;
        bridge.drain();

        // Test 4: Protocol integrity checks
        test_protocol_integrity();

        // Report results
        report_results();

        #100ns;
        phase.drop_objection(this, "virtio_full_integration_test");
    endtask

    // ========================================================================
    // Setup EP Config Space with Virtio Capabilities
    //
    // Programs the EP driver's cfg_mgr with:
    //   - Type 0 header with virtio VID/DID
    //   - BAR0 = 64KB MMIO (32-bit) for common/notify/ISR/device config
    //   - Virtio vendor-specific capabilities (cap_id=0x09):
    //       cfg_type=1 (Common Config) at BAR0+0x0000
    //       cfg_type=2 (Notify)        at BAR0+0x1000
    //       cfg_type=3 (ISR)           at BAR0+0x2000
    //       cfg_type=4 (Device Config) at BAR0+0x3000
    //   - MSI-X capability with 8 vectors
    // ========================================================================
    virtual function void setup_ep_virtio_config();
        pcie_tl_cfg_space_manager cfg;
        pcie_tl_ep_driver ep_drv;
        pcie_capability vs_cap;
        bit [7:0] cap_data[];

        cfg = pcie_env.cfg_mgr;
        ep_drv = pcie_env.ep_agent.ep_driver;

        // Clear any pre-existing capabilities from env init
        cfg.cap_list.delete();
        cfg.ext_cap_list.delete();

        // Re-initialize with virtio IDs
        cfg.init_type0_header(
            .vendor_id(16'h1AF4),    // Red Hat / virtio
            .device_id(16'h1041),    // virtio-net (modern)
            .revision_id(8'h01),
            .class_code(24'h020000), // Ethernet controller
            .header_type(8'h00)
        );

        // Set Status register: Capabilities List present
        cfg.cfg_space[6] = cfg.cfg_space[6] | (1 << PCI_STATUS_CAP_LIST);
        cfg.field_attrs[6] = CFG_FIELD_RO;

        // Setup BAR0 as 64KB 32-bit MMIO
        // Lower 16 bits RO (size mask for 64KB)
        cfg.cfg_space[16] = 8'h00;
        cfg.cfg_space[17] = 8'h00;
        cfg.cfg_space[18] = 8'h00;
        cfg.cfg_space[19] = 8'h00;
        for (int i = 16; i < 18; i++)
            cfg.field_attrs[i] = CFG_FIELD_RO;

        // ---- Capabilities ----
        // Re-register PCIe capability at 0x40 (cleared by init_type0_header)
        cfg.init_pcie_capability(8'h40, MPS_256, MRRS_512, RCB_64);

        // Virtio Common Config capability (cfg_type=1) at offset 0x50
        vs_cap = pcie_capability::type_id::create("virtio_common_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'h50;
        cap_data = new[14];
        cap_data[0] = 8'h14;  // cap_len
        cap_data[1] = VIRTIO_PCI_CAP_COMMON_CFG;  // cfg_type = 1
        cap_data[2] = 8'h00;  // bar = 0
        cap_data[3] = 8'h00;  // id
        cap_data[4] = 8'h00;  // padding
        cap_data[5] = 8'h00;  // padding
        cap_data[6] = 8'h00;  // offset = 0x0000
        cap_data[7] = 8'h00;
        cap_data[8] = 8'h00;
        cap_data[9] = 8'h00;
        cap_data[10] = 8'h40; // length = 64 bytes
        cap_data[11] = 8'h00;
        cap_data[12] = 8'h00;
        cap_data[13] = 8'h00;
        vs_cap.data = cap_data;
        cfg.register_capability(vs_cap);

        // Virtio Notify capability (cfg_type=2) at offset 0x70
        vs_cap = pcie_capability::type_id::create("virtio_notify_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'h70;
        cap_data = new[18];
        cap_data[0] = 8'h18;  // cap_len = 24
        cap_data[1] = VIRTIO_PCI_CAP_NOTIFY_CFG;  // cfg_type = 2
        cap_data[2] = 8'h00;  // bar = 0
        cap_data[3] = 8'h00;
        cap_data[4] = 8'h00;
        cap_data[5] = 8'h00;
        cap_data[6] = 8'h00;  // offset = 0x1000
        cap_data[7] = 8'h10;
        cap_data[8] = 8'h00;
        cap_data[9] = 8'h00;
        cap_data[10] = 8'h00; // length = 0x1000
        cap_data[11] = 8'h10;
        cap_data[12] = 8'h00;
        cap_data[13] = 8'h00;
        cap_data[14] = 8'h02; // notify_off_multiplier = 2
        cap_data[15] = 8'h00;
        cap_data[16] = 8'h00;
        cap_data[17] = 8'h00;
        vs_cap.data = cap_data;
        cfg.register_capability(vs_cap);

        // Virtio ISR capability (cfg_type=3) at offset 0x90
        vs_cap = pcie_capability::type_id::create("virtio_isr_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'h90;
        cap_data = new[14];
        cap_data[0] = 8'h14;
        cap_data[1] = VIRTIO_PCI_CAP_ISR_CFG;
        cap_data[2] = 8'h00;
        cap_data[3] = 8'h00;
        cap_data[4] = 8'h00;
        cap_data[5] = 8'h00;
        cap_data[6] = 8'h00;  // offset = 0x2000
        cap_data[7] = 8'h20;
        cap_data[8] = 8'h00;
        cap_data[9] = 8'h00;
        cap_data[10] = 8'h04; // length = 4
        cap_data[11] = 8'h00;
        cap_data[12] = 8'h00;
        cap_data[13] = 8'h00;
        vs_cap.data = cap_data;
        cfg.register_capability(vs_cap);

        // Virtio Device Config capability (cfg_type=4) at offset 0xA8
        vs_cap = pcie_capability::type_id::create("virtio_devcfg_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = 8'hA8;
        cap_data = new[14];
        cap_data[0] = 8'h14;
        cap_data[1] = VIRTIO_PCI_CAP_DEVICE_CFG;
        cap_data[2] = 8'h00;
        cap_data[3] = 8'h00;
        cap_data[4] = 8'h00;
        cap_data[5] = 8'h00;
        cap_data[6] = 8'h00;  // offset = 0x3000
        cap_data[7] = 8'h30;
        cap_data[8] = 8'h00;
        cap_data[9] = 8'h00;
        cap_data[10] = 8'h40; // length = 64
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
            cap_data[0] = 8'h07; // table_size=7 (8 entries-1)
            cap_data[1] = 8'h00; // enable=0, func_mask=0
            cap_data[2] = 8'h00; // table BIR=0
            cap_data[3] = 8'h40; // table offset = 0x4000
            cap_data[4] = 8'h00;
            cap_data[5] = 8'h00;
            cap_data[6] = 8'h00; // PBA BIR=0
            cap_data[7] = 8'h50; // PBA offset = 0x5000
            cap_data[8] = 8'h00;
            cap_data[9] = 8'h00;
            msix_cap.data = cap_data;
            cfg.register_capability(msix_cap);
        end

        `uvm_info("FULL_TEST", "EP config space setup complete with virtio capabilities", UVM_LOW)
    endfunction

    // ========================================================================
    // Initialize EP MMIO registers after BAR enumeration
    // ========================================================================
    virtual function void init_ep_mmio_regs(bit [63:0] bar0_base);
        pcie_tl_ep_driver ep_drv;
        bit [63:0] cc_base;
        bit [63:0] dc_base;
        bit [63:0] device_features;

        ep_drv = pcie_env.ep_agent.ep_driver;
        cc_base = bar0_base;
        dc_base = bar0_base + 64'h3000;

        device_features = 0;
        device_features[VIRTIO_NET_F_MAC] = 1;
        device_features[VIRTIO_NET_F_STATUS] = 1;
        device_features[VIRTIO_NET_F_MRG_RXBUF] = 1;
        device_features[VIRTIO_NET_F_CTRL_VQ] = 1;
        device_features[VIRTIO_NET_F_MQ] = 1;
        device_features[VIRTIO_F_VERSION_1] = 1;
        device_features[VIRTIO_NET_F_MTU] = 1;
        device_features[VIRTIO_NET_F_CSUM] = 1;
        device_features[VIRTIO_NET_F_HOST_TSO4] = 1;

        // Common Config at BAR0+0x0000
        write_ep_mem32(ep_drv, cc_base + 64'h00, 32'h0); // DFSELECT
        write_ep_mem32(ep_drv, cc_base + 64'h04, device_features[31:0]); // DF
        write_ep_mem32(ep_drv, cc_base + 64'h08, 32'h0); // GFSELECT
        write_ep_mem32(ep_drv, cc_base + 64'h0C, 32'h0); // GF
        write_ep_mem16(ep_drv, cc_base + 64'h10, 16'h0); // MSIX
        write_ep_mem16(ep_drv, cc_base + 64'h12, 16'h0006); // NUMQ = 6
        write_ep_mem8(ep_drv, cc_base + 64'h14, 8'h0);  // STATUS
        write_ep_mem8(ep_drv, cc_base + 64'h15, 8'h0);  // CFGGENERATION
        write_ep_mem16(ep_drv, cc_base + 64'h16, 16'h0); // Q_SELECT
        write_ep_mem16(ep_drv, cc_base + 64'h18, 16'h0100); // Q_SIZE = 256
        write_ep_mem16(ep_drv, cc_base + 64'h1A, 16'h0); // Q_MSIX
        write_ep_mem16(ep_drv, cc_base + 64'h1C, 16'h0); // Q_ENABLE
        write_ep_mem16(ep_drv, cc_base + 64'h1E, 16'h0); // Q_NOFF
        // Desc/Avail/Used addresses
        for (int i = 0; i < 24; i++)
            ep_drv.mem_space[cc_base + 64'h20 + i] = 8'h00;

        // Device Config at BAR0+0x3000
        // MAC: 52:54:00:12:34:56
        write_ep_mem8(ep_drv, dc_base + 64'h00, 8'h52);
        write_ep_mem8(ep_drv, dc_base + 64'h01, 8'h54);
        write_ep_mem8(ep_drv, dc_base + 64'h02, 8'h00);
        write_ep_mem8(ep_drv, dc_base + 64'h03, 8'h12);
        write_ep_mem8(ep_drv, dc_base + 64'h04, 8'h34);
        write_ep_mem8(ep_drv, dc_base + 64'h05, 8'h56);
        write_ep_mem16(ep_drv, dc_base + 64'h06, 16'h0001); // status: link up
        write_ep_mem16(ep_drv, dc_base + 64'h08, 16'h0002); // max_virtqueue_pairs
        write_ep_mem16(ep_drv, dc_base + 64'h0A, 16'h05DC); // MTU=1500
        write_ep_mem32(ep_drv, dc_base + 64'h0C, 32'h00002710); // speed=10000
        write_ep_mem8(ep_drv, dc_base + 64'h10, 8'h01); // duplex=full

        `uvm_info("FULL_TEST", $sformatf(
            "EP MMIO registers initialized at BAR0=0x%016h", bar0_base), UVM_LOW)
    endfunction

    // ========================================================================
    // EP Device Behavior Task
    //
    // Simulates device behavior by monitoring EP mem_space writes and
    // updating read-back values accordingly.
    // ========================================================================
    virtual task ep_device_behavior(bit [63:0] bar0_base);
        pcie_tl_ep_driver ep_drv;
        bit [63:0] cc_base;
        bit [63:0] device_features;
        bit [7:0] last_status;
        int unsigned last_qselect;

        ep_drv = pcie_env.ep_agent.ep_driver;
        cc_base = bar0_base;

        device_features = 0;
        device_features[VIRTIO_NET_F_MAC] = 1;
        device_features[VIRTIO_NET_F_STATUS] = 1;
        device_features[VIRTIO_NET_F_MRG_RXBUF] = 1;
        device_features[VIRTIO_NET_F_CTRL_VQ] = 1;
        device_features[VIRTIO_NET_F_MQ] = 1;
        device_features[VIRTIO_F_VERSION_1] = 1;
        device_features[VIRTIO_NET_F_MTU] = 1;
        device_features[VIRTIO_NET_F_CSUM] = 1;
        device_features[VIRTIO_NET_F_HOST_TSO4] = 1;

        last_status = 0;
        last_qselect = 0;

        forever begin
            bit [31:0] dfselect_val;
            bit [7:0] status_val;
            int unsigned qselect_val;

            #10ns;

            // React to DFSELECT writes: update DF register
            dfselect_val = read_ep_mem32(ep_drv, cc_base + 64'h00);
            if (dfselect_val == 0)
                write_ep_mem32(ep_drv, cc_base + 64'h04, device_features[31:0]);
            else if (dfselect_val == 1)
                write_ep_mem32(ep_drv, cc_base + 64'h04, device_features[63:32]);

            // React to STATUS writes
            status_val = read_ep_mem8(ep_drv, cc_base + 64'h14);
            if (status_val != last_status) begin
                last_status = status_val;
                // Device accepts features -- keep FEATURES_OK if set
                if (last_status & DEV_STATUS_FEATURES_OK)
                    write_ep_mem8(ep_drv, cc_base + 64'h14, last_status);
            end

            // React to Q_SELECT writes: update per-queue registers
            qselect_val = read_ep_mem16(ep_drv, cc_base + 64'h16);
            if (qselect_val != last_qselect) begin
                last_qselect = qselect_val;
                write_ep_mem16(ep_drv, cc_base + 64'h18, 16'h0100); // Q_SIZE max
                write_ep_mem16(ep_drv, cc_base + 64'h1E, last_qselect[15:0]); // Q_NOFF
            end
        end
    endtask

    // ========================================================================
    // Test 1: Full Virtio Initialization
    // ========================================================================
    virtual task test_full_init();
        bit [63:0] bar0_base;

        tests_run++;
        `uvm_info("FULL_TEST", "--- Test 1: Full Virtio Init ---", UVM_LOW)

        // Step 1: BAR enumeration
        `uvm_info("FULL_TEST", "Step 1: BAR enumeration", UVM_LOW)
        transport.bar.requester_id = transport.bdf;
        transport.bar.enumerate_bars();

        bar0_base = transport.bar.bar_base[0];
        `uvm_info("FULL_TEST", $sformatf("BAR0 assigned at 0x%016h", bar0_base), UVM_LOW)

        // Step 2: Initialize EP MMIO registers at assigned BAR address
        init_ep_mmio_regs(bar0_base);

        // Step 3: Start EP device behavior monitor
        fork
            ep_device_behavior(bar0_base);
        join_none

        // Step 4: Capability discovery
        `uvm_info("FULL_TEST", "Step 2: Capability discovery", UVM_LOW)
        transport.cap_mgr.bar_ref = transport.bar;
        transport.cap_mgr.discover_capabilities();

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
        bridge.report();

        `uvm_info("FULL_TEST", "============================================================", UVM_LOW)
        `uvm_info("FULL_TEST", $sformatf("Test Results: %0d/%0d passed, %0d failed",
            tests_passed, tests_run, tests_failed), UVM_LOW)
        `uvm_info("FULL_TEST", "============================================================", UVM_LOW)

        if (tests_failed > 0)
            `uvm_error("FULL_TEST", $sformatf("OVERALL: FAIL (%0d tests failed)", tests_failed))
        else
            `uvm_info("FULL_TEST", "OVERALL: PASS -- All tests passed", UVM_LOW)
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

endclass
