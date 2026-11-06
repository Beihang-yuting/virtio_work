// examples/aip：运行中的 Tcl/seq 接入示例，复用仓库真实 PCIe 驱动流程 fixture。
// 依赖 AIP、virtio_aip_pkg 和 fixture；默认 MODEL，REAL_DUT 需要平台提供真实连接。
// UVM 管理 fixture/driver；AIP registry 借用其 Function，命令对象常驻至仿真结束。
// 本例提供注册与执行入口；TX 命令成功只代表提交，不替代 DUT/scoreboard 完成判定。
// 定向回归可用 +PCIE_REQUIRE_DRAINED 保持 objection 等真实 PCIe 观察流收敛，
// 再在 check phase 检查请求跟踪；协议 SVA 的暂存事件和脉冲也必须消费完。
// 等待有界，不修改组件状态或替代平台业务完成判定。
`ifndef VIRTIO_AIP_DRIVER_TEST_SV
`define VIRTIO_AIP_DRIVER_TEST_SV
import uvm_pkg::*;
import aip_core_pkg::*;
import pcie_tl_pkg::*;
import virtio_net_pkg::*;
import virtio_aip_pkg::*;
`include "uvm_macros.svh"

// 用户 base_test 可复用 register_aip_commands 的三个调用，传入已集成的 env。
class virtio_aip_driver_test extends uvm_test;
    `uvm_component_utils(virtio_aip_driver_test)
    virtio_real_driver_flow_fixture	flow;

    // 只建立 UVM 对象；外部资源在 build/connect 完成后才交给命令层。
    function new(string	name = "virtio_aip_driver_test", uvm_component	parent = null);
        super.new(name, parent);
    endfunction

    // 首次默认一对队列，资源预留仍是两对；vio.* 在 fixture 创建配置后加载。
    virtual function void build_phase(uvm_phase	phase);
        super.build_phase(phase);
        flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
        flow.initial_num_pairs = 1;
    endfunction

    // 统一命令注册位置：先绑定真实完整 service 身份，再创建八个命令与独立TX别名。
    // 重名或空环境立即失败；多 Host 平台应在 register_commands 前逐个 bind_env。
    function void register_aip_commands();
        string	why;

        if (!virtio_aip_registry::bind_env(flow.virtio_env(), why) ||
            !virtio_aip_registry::register_commands(why) ||
            !virtio_aip_registry::register_tx_command("vio_tx0", "vio.tx0", why) ||
            !virtio_aip_registry::register_tx_command("vio_tx1", "vio.tx1", why))
            `uvm_fatal("VIO_AIP_EXAMPLE", why)
    endfunction

    // build_flow 完成 PCIe 路径绑定；保持 objection 到 Tcl end_test 退出 bridge。
    // 定向回归额外等真实观察流收敛，避免末笔同步完成后立即结束而取消迟到 monitor。
    // 队列初始化/启动/停止由 Tcl 显式控制；平台可在此注册自身 aip_end_checker。
    virtual task run_phase(uvm_phase	phase);
        string	why;
        virtio_monitor	monitor;

        phase.raise_objection(this);
        if (!flow.build_flow(why))
            `uvm_fatal("VIO_AIP_EXAMPLE", why)
        // 与 fixture.start_driver_flow 保持同一平台复位契约。AIP 不调用该 helper，
        // 因此必须在接收 vio_init 前等待，否则 SVA 会在复位期丢弃初始化历史。
        monitor = flow.function_monitor();
        if (monitor != null && monitor.protocol_vif != null)
            wait (monitor.protocol_vif.rst_n === 1'b1);
        register_aip_commands();
        aip_tcl_bridge::run_loop();
        if ($test$plusargs("PCIE_REQUIRE_DRAINED")) wait_for_pcie_drain();
        phase.drop_objection(this);
    endtask

    // 只读取真实 SCB 和 adapter 的状态：错误/缺失检查器是失败，不是尚未收敛。
    // FIFO 也须为空，防止 posted 请求没有 pending 标记时提前把观察流判为结束。
    // 返回 1 表示可结束；返回 0 时 failed 区分永久失败与仍待 monitor 消费的状态。
    function bit pcie_is_drained(output bit	failed, output string	detail);
        pcie_tl_env	pcie;
        virtio_monitor	monitor;
        virtual virtio_protocol_event_if	protocol_vif;
        int	checked_roots;

        failed = 0;
        detail = "";
        pcie = (flow == null) ? null : flow.pcie_env();
        if (pcie == null) begin
            failed = 1;
            detail = "PCIe environment is missing";
            return 0;
        end
        monitor = flow.function_monitor();
        protocol_vif = null;
        if (monitor != null) protocol_vif = monitor.protocol_vif;
        if (protocol_vif != null &&
            (!protocol_vif.assertions_enable || protocol_vif.protocol_error_count != 0)) begin
            failed = 1;
            detail = "protocol assertions are disabled or have reported an error";
            return 0;
        end
        checked_roots = 0;
        foreach (pcie.scbs[root]) begin
            if (pcie.scbs[root] == null) continue;
            checked_roots++;
            if (!pcie.scbs[root].completion_check_enable || !pcie.scbs[root].strict_check ||
                pcie.scbs[root].unexpected != 0 || pcie.scbs[root].mismatched != 0) begin
                failed = 1;
                detail = $sformatf("root=%0d has disabled strict/Completion checks or an SCB failure", root);
                return 0;
            end
        end
        if (checked_roots == 0) begin
            failed = 1;
            detail = "no enabled PCIe scoreboard was available";
            return 0;
        end
        foreach (pcie.scbs[root]) begin
            if (pcie.scbs[root] == null) continue;
            if (pcie.scbs[root].pending_requests.num() != 0 ||
                pcie.scbs[root].cpl_trackers.num() != 0 ||
                (!pcie.bridge_required && pcie.cfg.if_mode == TLM_MODE &&
                    pcie.scbs[root].cpl_processed.num() != 0)) begin
                detail = $sformatf("root=%0d pending=%0d trackers=%0d dedup=%0d",
                    root, pcie.scbs[root].pending_requests.num(),
                    pcie.scbs[root].cpl_trackers.num(), pcie.scbs[root].cpl_processed.num());
                return 0;
            end
        end
        // 标量与数组可能互为别名；重复读取无副作用，兼容两种原有环境布局。
        if (pcie.rc_adapter != null &&
            (pcie.rc_adapter.tlm_rx_fifo.used() != 0 || pcie.rc_adapter.tlm_tx_fifo.used() != 0)) begin
            detail = "RC adapter FIFO is not empty";
            return 0;
        end
        if (pcie.ep_adapter != null &&
            (pcie.ep_adapter.tlm_rx_fifo.used() != 0 || pcie.ep_adapter.tlm_tx_fifo.used() != 0)) begin
            detail = "EP adapter FIFO is not empty";
            return 0;
        end
        foreach (pcie.rc_adapters[index]) begin
            if (pcie.rc_adapters[index] == null) continue;
            if (pcie.rc_adapters[index].tlm_rx_fifo.used() != 0 ||
                pcie.rc_adapters[index].tlm_tx_fifo.used() != 0) begin
                detail = $sformatf("RC[%0d] adapter FIFO is not empty", index);
                return 0;
            end
        end
        foreach (pcie.ep_adapters[index]) begin
            if (pcie.ep_adapters[index] == null) continue;
            if (pcie.ep_adapters[index].tlm_rx_fifo.used() != 0 ||
                pcie.ep_adapters[index].tlm_tx_fifo.used() != 0) begin
                detail = $sformatf("EP[%0d] adapter FIFO is not empty", index);
                return 0;
            end
        end
        // PCIe monitor 已空并不代表 SVA 已检查：协议接口每拍仅释放一个暂存事件。
        // 只等事件和当前脉冲，不要求合法的未用 RX buffer submission 信用为零。
        if (protocol_vif != null &&
            (protocol_vif.staged_pulses.size() != 0 || protocol_vif.staged_queue_state_pending ||
                protocol_vif.staged_dma_pending || protocol_vif.staged_interrupt_pending ||
                protocol_vif.status_write || protocol_vif.features_ok || protocol_vif.driver_ok ||
                protocol_vif.notify || protocol_vif.verified_submission || protocol_vif.completion ||
                protocol_vif.queue_reset || protocol_vif.reset_all_queues)) begin
            detail = "Virtio protocol events are not fully sampled";
            return 0;
        end
        return 1;
    endfunction

    // 裸 end_test 可能在最后一次同步 Completion 返回的同一 tick 退出。
    // 先错开一个仿真精度步，避免与本 testbench 的整 ns 时钟边沿/NBA/SVA 采样竞争；
    // 随后每轮先检查完成条件，1ns 只让 monitor 获得调度。最多等待 10us，错误立即退出。
    // 不固定 drain 时长、不清表、不改变 driver/monitor，超时仍由严格日志检查判失败。
    task wait_for_pcie_drain();
        realtime	started;
        bit	failed;
        string	detail;

        started = $realtime;
        #1step;
        forever begin
            if (pcie_is_drained(failed, detail)) return;
            if (failed) begin
                `uvm_error("PCIE_AIP_DRAIN", detail)
                return;
            end
            if (($realtime - started) >= 10us) begin
                `uvm_error("PCIE_AIP_DRAIN", {"timeout waiting for PCIe observation drain: ", detail})
                return;
            end
            #1ns;
        end
    endtask

    // 可选的端到端回归收尾：直接检查真实环境的 pending 与分片表，防止迟到
    // monitor 将已完成的短 Tag 请求重新登记；TLM 还要求双观察去重标记全部回收。
    // 此处不清表、不补延时、不降低 strict。
    // 未创建 SCB 或关闭 Completion 检查不能证明请求已经完成，必须明确失败。
    virtual function void check_phase(uvm_phase	phase);
        pcie_tl_env	pcie;
        int	checked_roots;
        bit	failed;
        string	detail;

        super.check_phase(phase);
        if (!$test$plusargs("PCIE_REQUIRE_DRAINED")) return;
        if (flow == null) begin
            `uvm_error("PCIE_AIP_DRAIN", "flow fixture is missing")
            return;
        end
        pcie = flow.pcie_env();
        if (pcie == null) begin
            `uvm_error("PCIE_AIP_DRAIN", "PCIe environment is missing")
            return;
        end
        checked_roots = 0;
        foreach (pcie.scbs[root]) begin
            if (pcie.scbs[root] == null) continue;
            checked_roots++;
            if (!pcie.scbs[root].completion_check_enable ||
                !pcie.scbs[root].strict_check ||
                pcie.scbs[root].pending_requests.num() != 0 ||
                pcie.scbs[root].cpl_trackers.num() != 0 ||
                (!pcie.bridge_required && pcie.cfg.if_mode == TLM_MODE &&
                    pcie.scbs[root].cpl_processed.num() != 0) ||
                pcie.scbs[root].unexpected != 0 || pcie.scbs[root].mismatched != 0)
                `uvm_error("PCIE_AIP_DRAIN", $sformatf(
                    "root=%0d check=%0b strict=%0b pending=%0d trackers=%0d dedup=%0d unexpected=%0d mismatched=%0d",
                    root, pcie.scbs[root].completion_check_enable, pcie.scbs[root].strict_check,
                    pcie.scbs[root].pending_requests.num(), pcie.scbs[root].cpl_trackers.num(),
                    pcie.scbs[root].cpl_processed.num(),
                    pcie.scbs[root].unexpected, pcie.scbs[root].mismatched))
            else
                `uvm_info("PCIE_AIP_DRAIN", $sformatf(
                    "PASS root=%0d pending=0 trackers=0 dedup=%0d matched=%0d completions=%0d",
                    root, pcie.scbs[root].cpl_processed.num(),
                    pcie.scbs[root].matched, pcie.scbs[root].total_completions), UVM_LOW)
        end
        if (checked_roots == 0)
            `uvm_error("PCIE_AIP_DRAIN", "no enabled PCIe scoreboard was available")
        if (!pcie_is_drained(failed, detail))
            `uvm_error("PCIE_AIP_DRAIN", {"observation state is not drained at check phase: ", detail})
    endfunction
endclass
`endif
