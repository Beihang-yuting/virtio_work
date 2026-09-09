`ifndef VIRTIO_EXECUTION_MODE_TEST_SV
`define VIRTIO_EXECUTION_MODE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// 配置契约测试：验证执行主体选择，不主动产生设备 DMA。
class virtio_execution_mode_test extends uvm_test;
    `uvm_component_utils(virtio_execution_mode_test)

    virtio_net_env_config cfg;

    function new(string name = "virtio_execution_mode_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        string why;
        super.build_phase(phase);
        cfg = virtio_net_env_config::type_id::create("cfg");
        if (!cfg.apply_plusargs(why))
            `uvm_fatal("MODE", why)
    endfunction

    virtual task run_phase(uvm_phase phase);
        string why;
        virtio_net_env_config probe;

        phase.raise_objection(this);
        if (!cfg.validate_execution_mode(why))
            `uvm_error("MODE", why)
        if ((cfg.execution_mode != VIRTIO_EXEC_MODEL) &&
            (cfg.execution_mode != VIRTIO_EXEC_REAL_DUT))
            `uvm_error("MODE", "execution mode is outside the supported enum")

        // 独立探针验证保留值不会被静默接受，同时不污染正在运行的 cfg。
        probe = virtio_net_env_config::type_id::create("mode_probe");
        probe.execution_mode = virtio_execution_mode_e'(2'b11);
        if (probe.validate_execution_mode(why))
            `uvm_error("MODE", "reserved execution mode was accepted")

        probe.execution_mode = VIRTIO_EXEC_MODEL;
        probe.completion_mode = virtio_completion_mode_e'(2'b10);
        if (probe.validate_execution_mode(why))
            `uvm_error("MODE", "unknown completion mode was accepted")
        phase.drop_objection(this);
    endtask
endclass

`endif
