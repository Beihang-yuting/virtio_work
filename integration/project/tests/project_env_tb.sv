// integration/project/tests：结构回归 top，仅提供空闲接口与协议断言时钟。
// 没有 DUT、没有 Completion responder；不能用这个 top 声称真实收发测试通过。
// 接口由 HDL 持有；UVM 借用 VIF。生成块先登记，再用 #0 启动 UVM 避免 time-0 竞争。
`timescale 1ns/1ps
module project_env_tb;
    import uvm_pkg::*;
    import project_env_test_pkg::*;
    `include "uvm_macros.svh"

    logic			clk = 0;
    logic			rst_n = 0;
    pcie_tl_if			rc_ifs[2](clk, rst_n);
    pcie_tl_if			ep_ifs[2](clk, rst_n);
    virtio_protocol_event_if	protocol_ifs[32](clk, rst_n);

    always #2ns clk = ~clk;
    initial #20ns rst_n = 1;

    for (genvar	h = 0; h < 2; h++) begin : g_native
        initial begin
            // 保持两条方向接口空闲，不伪造任何协议应答或信用返还。
            rc_ifs[h].tlp_valid = 0;
            rc_ifs[h].tlp_ready = 1;
            rc_ifs[h].fc_update = 0;
            ep_ifs[h].tlp_valid = 0;
            ep_ifs[h].tlp_ready = 1;
            ep_ifs[h].fc_update = 0;
            uvm_config_db#(virtual pcie_tl_if)::set(null, "uvm_test_top",
                $sformatf("rc_vif_%0d", h), rc_ifs[h]);
            uvm_config_db#(virtual pcie_tl_if)::set(null, "uvm_test_top",
                $sformatf("ep_vif_%0d", h), ep_ifs[h]);
        end
    end
    for (genvar	i = 0; i < 32; i++) begin : g_protocol
        virtio_protocol_assertions	checks(protocol_ifs[i]);
        initial uvm_config_db#(virtual virtio_protocol_event_if)::set(null, "uvm_test_top",
            $sformatf("protocol_event_vif_%0d", i), protocol_ifs[i]);
    end

    initial begin
        #0;
        run_test();
    end
    initial begin
        #10us;
        `uvm_fatal("PROJECT_TOP", "assembly test timeout")
    end
endmodule
