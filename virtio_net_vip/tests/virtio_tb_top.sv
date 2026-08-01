// ============================================================================
// virtio_tb_top
//
// Top-level testbench module for the virtio-net VIP. Provides clock and
// reset generation, launches the UVM test via run_test(), and includes a
// simulation timeout safety net.
//
// Clock: 250 MHz (4ns period)
// Reset: active-low, asserted for 100ns at start
// Timeout: 10ms (uvm_fatal if reached -- safety net only)
//
// For TLM_MODE (loopback), no physical interface is needed.
// For SV_IF_MODE, instantiate pcie_tl_if and set it via config_db.
// ============================================================================

`timescale 1ns/1ps

module virtio_tb_top;

    import uvm_pkg::*;
    import dpu_resource_pkg::*;
    `include "uvm_macros.svh"

    // Clock and reset
    logic clk;
    logic rst_n;
    // Protocol assertions retain per-function history, so every possible
    // Fabric function gets its own clocked event channel.  The environment
    // assigns active PFs/VFs distinct channels during bind_pcie().
    localparam int unsigned PROTOCOL_EVENT_VIF_COUNT = DPU_MAX_FUNCTIONS;
    virtio_protocol_event_if protocol_event_ifs [PROTOCOL_EVENT_VIF_COUNT](
        .clk(clk), .rst_n(rst_n));
    for (genvar function_index = 0;
         function_index < PROTOCOL_EVENT_VIF_COUNT;
         function_index++) begin : g_protocol_event_vif
        virtio_protocol_assertions protocol_assertions_i(
            .events(protocol_event_ifs[function_index]));
        initial begin
            uvm_config_db#(virtual virtio_protocol_event_if)::set(
                null, "uvm_test_top",
                $sformatf("protocol_event_vif_%0d", function_index),
                protocol_event_ifs[function_index]);
        end
    end

    // Clock generation: 250MHz (4ns period)
    initial begin
        clk = 0;
        forever #2 clk = ~clk;
    end

    // Reset generation
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
    end

    // PCIe TL interface instantiation
    // (If using SV_IF_MODE, instantiate pcie_tl_if here)
    // For TLM_MODE (loopback), no interface needed

    // UVM test launch
    initial begin
        // Let the generated interface registrations run before UVM starts.
        #0;
        // Set interface in config_db if using SV_IF mode
        // uvm_config_db #(virtual pcie_tl_if)::set(
        //     null, "uvm_test_top.env.pcie_env", "vif", pcie_if);

        run_test();
    end

    // Simulation timeout (safety net -- not a wait-for-condition)
    initial begin
        #30s;
        `uvm_fatal("TB_TOP", "Simulation timeout at 30s")
    end

endmodule : virtio_tb_top
