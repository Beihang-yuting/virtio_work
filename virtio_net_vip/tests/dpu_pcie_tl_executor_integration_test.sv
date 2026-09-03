`ifndef DPU_PCIE_TL_EXECUTOR_INTEGRATION_TEST_SV
`define DPU_PCIE_TL_EXECUTOR_INTEGRATION_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// Minimal real-DUT configuration path: dpu-common resolves the device,
// lowers BAR programming plus AF declaration into a frozen plan, and the
// concrete executor emits PCIe-TL config/MMIO transactions into a TLM RC/EP
// link.  No service-specific environment is needed for this boundary test.
class dpu_pcie_tl_executor_integration_test extends uvm_test;
    `uvm_component_utils(dpu_pcie_tl_executor_integration_test)

    virtio_test_device_builder device_builder;
    dpu_device_env_config      device_cfg;
    dpu_device_env             device_env;
    dpu_function_cfg           pf_seg0;
    dpu_function_cfg           pf_seg1;
    pcie_tl_env_config         pcie_cfg;
    pcie_tl_env                pcie_env;
    pcie_tl_dpu_reg_backend    backend;
    pcie_tl_dpu_reg_executor   executor;

    function new(string name = "dpu_pcie_tl_executor_integration_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    protected function dpu_reg_op make_op(
        input string op_id,
        input dpu_reg_op_kind_e kind,
        input dpu_reg_target_space_e target_space,
        input dpu_reg_phase_e phase,
        input bit [63:0] address,
        input int unsigned segment_id = 0,
        input bit [15:0] operation_bdf = 16'h0010,
        input int unsigned width = 4
    );
        dpu_reg_op op;

        op = dpu_reg_op::type_id::create(op_id);
        op.op_id = op_id;
        op.owner = "pcie.executor.e2e";
        op.kind = kind;
        op.target_space = target_space;
        op.target_scope = DPU_REG_SCOPE_SINGLE;
        op.phase = phase;
        op.host_id = 0;
        op.segment_id = segment_id;
        op.bdf_valid = 1;
        op.bdf = operation_bdf;
        op.bar_id = 0;
        op.target_block = (target_space == DPU_REG_TARGET_PCI_CONFIG) ?
                          "pci_config" : "af_bar0";
        op.address = address;
        op.width_bytes = width;
        return op;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_function_cfg pf_cfg;

        super.build_phase(phase);
        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        void'(device_builder.add_host_domain(0, 0));
        pf_seg0 = device_builder.add_pf(0, 0, 0);
        device_builder.add_real_dut_bars(pf_seg0);
        device_builder.select_af(pf_seg0);
        void'(device_builder.add_host_domain(0, 1));
        pf_seg1 = device_builder.add_pf(0, 1, 1);
        device_builder.add_real_dut_bars(pf_seg1);

        backend = pcie_tl_dpu_reg_backend::type_id::create("backend");
        executor = pcie_tl_dpu_reg_executor::type_id::create("executor");
        executor.set_backend(backend);

        device_cfg = device_builder.make_env_config();
        device_cfg.executor = executor;
        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);

        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_cfg.if_mode = TLM_MODE;
        pcie_cfg.num_rc = 2;
        pcie_cfg.num_ep = 2;
        pcie_cfg.fc_enable = 0;
        pcie_cfg.infinite_credit = 1;
        // The executor test checks TLP emission and endpoint state directly;
        // the generic scoreboard's byte-count policy is outside this scope.
        pcie_cfg.scb_enable = 0;
        pcie_cfg.cpl_timeout_ns = 100000;
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "pcie_env", "cfg", pcie_cfg);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        backend.bind_virtual_sequencer(pcie_env.v_seqr);
    endfunction

    virtual task run_phase(uvm_phase phase);
        dpu_reg_plan plan;
        dpu_execution_report report;
        dpu_function_key_t af_key;
        dpu_bar_pair_lease_t af_bar0;
        dpu_pcie_function_id_t af_pcie_id;
        dpu_bar_pair_lease_t seg1_bar0;
        dpu_pcie_function_id_t seg1_pcie_id;
        dpu_config_orchestrator orchestrator;
        dpu_reg_op cfg_write;
        dpu_reg_op cfg_high_write;
        dpu_reg_op cfg_narrow_read;
        dpu_reg_op mmio_write;
        dpu_reg_op mmio_read;
        dpu_reg_op seg1_narrow_read;
        dpu_reg_op seg1_narrow_write;
        bit [63:0] mmio_address;
        bit [31:0] cfg_bar_low;
        bit [7:0] observed;
        string why;

        phase.raise_objection(this);
        #100ns;
        if (device_env.get_state() != DPU_DEVICE_RESOLVED)
            `uvm_fatal("PCIE_EXECUTOR_E2E",
                       "device environment did not resolve before apply")
        if (!device_env.get_snapshot().get_expected_af(
                af_key, af_bar0, why) ||
            !device_env.get_snapshot().get_pcie_id(
                af_key, af_pcie_id, why))
            `uvm_fatal("PCIE_EXECUTOR_E2E", {"AF lookup failed: ", why})
        if (!device_env.get_snapshot().get_pcie_id(
                pf_seg1.key, seg1_pcie_id, why) ||
            !device_env.get_snapshot().get_bar(
                pf_seg1.key, DPU_BAR_DEVICE_MEMORY, seg1_bar0, why))
            `uvm_fatal("PCIE_EXECUTOR_E2E", {"segment-1 lookup failed: ", why})

        backend.bind_domain_root(0, 1, 1);

        // The generic endpoint cannot model the driver's AF winner register,
        // so use a focused plan that exercises exactly the PCIe executor
        // boundary: one config-space BAR write, one posted BAR MMIO write,
        // and one non-posted MMIO readback.
        plan = dpu_reg_plan::type_id::create("pcie_executor_e2e_plan");
        cfg_write = make_op("cfg.bar0", DPU_REG_OP_PCI_CFG_WRITE,
                            DPU_REG_TARGET_PCI_CONFIG,
                            DPU_REG_PHASE_BOOTSTRAP, 64'h10);
        cfg_bar_low = {af_bar0.base[31:4], 4'b0100};
        cfg_write.payload = cfg_bar_low;
        cfg_write.write_mask = 64'hffff_ffff;
        cfg_high_write = make_op("cfg.bar0.high", DPU_REG_OP_PCI_CFG_WRITE,
                                 DPU_REG_TARGET_PCI_CONFIG,
                                 DPU_REG_PHASE_BOOTSTRAP, 64'h14);
        cfg_high_write.payload = af_bar0.base[63:32];
        cfg_high_write.write_mask = 64'hffff_ffff;
        cfg_high_write.add_dependency(cfg_write.op_id);
        cfg_narrow_read = make_op("cfg.bar0.byte1", DPU_REG_OP_READ_VERIFY,
                                  DPU_REG_TARGET_PCI_CONFIG,
                                  DPU_REG_PHASE_TABLE, 64'h11, 0,
                                  af_pcie_id.bdf, 1);
        cfg_narrow_read.expected_value = cfg_bar_low[15:8];
        cfg_narrow_read.read_mask = 64'hff;
        cfg_narrow_read.add_dependency(cfg_high_write.op_id);
        mmio_write = make_op("mmio.write", DPU_REG_OP_MMIO_WRITE,
                             DPU_REG_TARGET_AF_BAR0,
                             DPU_REG_PHASE_TABLE, 64'h100);
        mmio_write.payload = 64'hA5A5_5A5A;
        mmio_write.write_mask = 64'hffff_ffff;
        mmio_write.add_dependency(cfg_narrow_read.op_id);
        mmio_read = make_op("mmio.read", DPU_REG_OP_READ_VERIFY,
                            DPU_REG_TARGET_AF_BAR0,
                            DPU_REG_PHASE_TABLE, 64'h100);
        mmio_read.expected_value = 64'hA5A5_5A5A;
        mmio_read.read_mask = 64'hffff_ffff;
        mmio_read.add_dependency(mmio_write.op_id);

        // A segment-qualified operation must use the Root mapped to that
        // {host,segment} domain, and a narrow write must preserve the
        // operation bytes in the selected PCIe byte lanes.
        seg1_narrow_write = make_op("segment1.mmio.byte2", DPU_REG_OP_MMIO_WRITE,
                                    DPU_REG_TARGET_FUNCTION_BAR,
                                    DPU_REG_PHASE_TABLE, 64'h102,
                                    1, seg1_pcie_id.bdf, 2);
        seg1_narrow_write.payload = 64'h0000_BBAA;
        seg1_narrow_write.write_mask = 64'h0000_FFFF;
        seg1_narrow_write.add_dependency(mmio_read.op_id);
        seg1_narrow_read = make_op("segment1.mmio.byte2.read",
                                   DPU_REG_OP_READ_VERIFY,
                                   DPU_REG_TARGET_FUNCTION_BAR,
                                   DPU_REG_PHASE_TABLE, 64'h102,
                                   1, seg1_pcie_id.bdf, 2);
        seg1_narrow_read.expected_value = 64'h0000_BBAA;
        seg1_narrow_read.read_mask = 64'h0000_FFFF;
        seg1_narrow_read.add_dependency(seg1_narrow_write.op_id);
        if (!plan.add_operation(cfg_write, why) ||
            !plan.add_operation(cfg_high_write, why) ||
            !plan.add_operation(cfg_narrow_read, why) ||
            !plan.add_operation(mmio_write, why) ||
            !plan.add_operation(mmio_read, why) ||
            !plan.add_operation(seg1_narrow_write, why) ||
            !plan.add_operation(seg1_narrow_read, why))
            `uvm_fatal("PCIE_EXECUTOR_E2E", {"plan build failed: ", why})
        orchestrator = dpu_config_orchestrator::type_id::create(
            "pcie_executor_e2e_orchestrator");
        orchestrator.set_executor(executor);
        orchestrator.apply_with_report(plan, report);
        if ((report == null) ||
            (report.status() != DPU_CFG_STATUS_SUCCEEDED)) begin
            `uvm_fatal("PCIE_EXECUTOR_E2E", $sformatf(
                "bootstrap execution failed status=%0d reason=%s",
                (report == null) ? DPU_CFG_STATUS_PLAN_INVALID : report.status(),
                (report == null) ? "<null-report>" : report.reason()))
        end
        mmio_address = af_bar0.base + 64'h100;
        if (!pcie_env.ep_agent.ep_driver.mem_space.exists(mmio_address))
            `uvm_fatal("PCIE_EXECUTOR_E2E", $sformatf(
                "BAR MMIO write was not delivered at absolute address 0x%016h",
                mmio_address))
        observed = pcie_env.ep_agent.ep_driver.mem_space[
            mmio_address];
        if (observed !== 8'h5A)
            `uvm_fatal("PCIE_EXECUTOR_E2E", $sformatf(
                "BAR MMIO payload byte mismatch at 0x%016h: got 0x%02h",
                mmio_address, observed))
        if (pcie_env.cfg_mgr.read(64'h10) != cfg_bar_low)
            `uvm_fatal("PCIE_EXECUTOR_E2E", $sformatf(
                "config BAR write did not reach endpoint: got 0x%08h expected 0x%08h",
                pcie_env.cfg_mgr.read(64'h10), cfg_bar_low))
        if (pcie_env.cfg_mgr.read(64'h14) != af_bar0.base[63:32])
            `uvm_fatal("PCIE_EXECUTOR_E2E", $sformatf(
                "config BAR high write did not reach endpoint: got 0x%08h expected 0x%08h",
                pcie_env.cfg_mgr.read(64'h14), af_bar0.base[63:32]))
        #20ns;
        if ((pcie_env.ep_agents.size() < 2) ||
            (pcie_env.ep_agents[1].ep_driver == null) ||
            (pcie_env.ep_agents[1].ep_driver.mem_space[seg1_bar0.base + 64'h100] !== 8'h00) ||
            (pcie_env.ep_agents[1].ep_driver.mem_space[seg1_bar0.base + 64'h102] !== 8'hAA) ||
            (pcie_env.ep_agents[1].ep_driver.mem_space[seg1_bar0.base + 64'h103] !== 8'hBB))
            `uvm_fatal("PCIE_EXECUTOR_E2E", $sformatf(
                "segment-1 narrow MMIO did not reach Root1/lane2: got=%02h %02h %02h",
                pcie_env.ep_agents[1].ep_driver.mem_space[seg1_bar0.base + 64'h100],
                pcie_env.ep_agents[1].ep_driver.mem_space[seg1_bar0.base + 64'h102],
                pcie_env.ep_agents[1].ep_driver.mem_space[seg1_bar0.base + 64'h103]))
        if (af_pcie_id.bdf != 16'h0010)
            `uvm_fatal("PCIE_EXECUTOR_E2E", $sformatf(
                "unexpected resolved AF BDF 0x%04h", af_pcie_id.bdf))

        `uvm_info("PCIE_EXECUTOR_E2E", $sformatf(
            "real PCIe-TL executor path PASSED: host=%0d BDF=0x%04h BAR0=0x%016h",
            af_pcie_id.domain.host_id, af_pcie_id.bdf, af_bar0.base), UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass : dpu_pcie_tl_executor_integration_test

`endif // DPU_PCIE_TL_EXECUTOR_INTEGRATION_TEST_SV
