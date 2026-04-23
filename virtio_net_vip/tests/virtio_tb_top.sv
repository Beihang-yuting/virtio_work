`timescale 1ns/1ps

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

module virtio_tb_top;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Clock and reset
    logic clk;
    logic rst_n;

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
        // Set interface in config_db if using SV_IF mode
        // uvm_config_db #(virtual pcie_tl_if)::set(
        //     null, "uvm_test_top.env.pcie_env", "vif", pcie_if);

        run_test();
    end

    // Simulation timeout (safety net -- not a wait-for-condition)
    initial begin
        #10ms;
        `uvm_fatal("TB_TOP", "Simulation timeout at 10ms")
    end

endmodule : virtio_tb_top
