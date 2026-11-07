// integration/project/tests：结构回归 top，仅提供空闲接口与协议断言时钟。
// 没有 DUT、没有 Completion responder；不能用这个 top 声称真实收发测试通过。
// 接口由 HDL 持有；UVM 借用 VIF。生成块先登记，再用 #0 启动 UVM 避免 time-0 竞争。
// 仅验证 Intel 配置发布契约；PROJECT_INTEL_WRAPPER 模拟 wrapper 的 config_db 入口，
// 不实例化 DUT/bind wrapper，因此不能据此声称 RTL 引脚映射或信用握手验证通过。
`timescale 1ns/1ps
module project_env_tb;
    import uvm_pkg::*;
    import project_env_test_pkg::*;
    import intel_pcie_adapter_pkg::*;
    `include "uvm_macros.svh"

    logic			clk = 0;
    logic			rst_n = 0;
    intel_pcie_if #(INTEL_DATA_WIDTH, INTEL_SEGMENTS)	intel_ifs[2](clk, rst_n);
    virtio_protocol_event_if	protocol_ifs[32](clk, rst_n);

    always #2ns clk = ~clk;
    initial #20ns rst_n = 1;

    for (genvar	h = 0; h < 2; h++) begin : g_intel
        initial begin
            intel_pcie_adapter_config	port_cfg;
            string				path;

            // 只驱应用侧的空闲输入；HARD_IP 侧信号完全由 UVM Intel adapter 驱动。
            intel_ifs[h].tx_data = '0;
            intel_ifs[h].tx_hdr = '0;
            intel_ifs[h].tx_prefix = '0;
            intel_ifs[h].tx_sop = '0;
            intel_ifs[h].tx_eop = '0;
            intel_ifs[h].tx_dvalid = '0;
            intel_ifs[h].tx_hvalid = '0;
            intel_ifs[h].tx_pvalid = '0;
            intel_ifs[h].tx_data_par = '0;
            intel_ifs[h].tx_hdr_par = '0;
            intel_ifs[h].tx_prefix_par = '0;
            intel_ifs[h].rx_ready = 1;
            intel_ifs[h].rx_hcrdt_init = '0;
            intel_ifs[h].rx_hcrdt_update = '0;
            intel_ifs[h].rx_hcrdt_update_cnt = '0;
            intel_ifs[h].rx_dcrdt_init = '0;
            intel_ifs[h].rx_dcrdt_update = '0;
            intel_ifs[h].rx_dcrdt_update_cnt = '0;
            intel_ifs[h].tx_hcrdt_init_ack = '0;
            intel_ifs[h].tx_dcrdt_init_ack = '0;
            uvm_config_db#(intel_pcie_vif_t)::set(null, "uvm_test_top",
                $sformatf("intel_vif_%0d", h), intel_ifs[h]);
            if ($test$plusargs("PROJECT_INTEL_WRAPPER")) begin
                port_cfg = intel_pcie_adapter_config::type_id::create($sformatf("wrapper_port_%0d", h));
                port_cfg.side = INTEL_PCIE_HARD_IP;
                port_cfg.rx_gap_cycles = 3;
                port_cfg.check_parity = 1;
                path = $sformatf("uvm_test_top.env.pcie_env.rc_adapter_%0d", h);
                uvm_config_db#(intel_pcie_adapter_config)::set(null, path, "intel_cfg", port_cfg);
                uvm_config_db#(intel_pcie_vif_t)::set(null, path, "vif", intel_ifs[h]);
                uvm_config_db#(intel_pcie_adapter_config)::set(null, "uvm_test_top",
                    $sformatf("wrapper_cfg_%0d", h), port_cfg);
            end
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
        #1ms;
        `uvm_fatal("PROJECT_TOP", "assembly test timeout")
    end
endmodule
