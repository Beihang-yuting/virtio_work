// 目录层次：examples/dpu_priv_ring；验证 src 私有驱动在双 Host 顶层环境中的使用流程。
// 每个 Host 的私有 VF 面对独立设备模型 vdev_dpu_priv（回环端口：寄存器访问直达设备，设备 DMA 经该
// Host 的 IOMMU）。数据/ring 生命周期完全交给生产 ops，测试只从设备事件观察描述符、帧字节与通知字。
import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;
import net_packet_pkg::*;
import dpu_resource_pkg::*;
import pcie_tl_pkg::*;

// 只捕获当前指定的一次预期错误，其他 ERROR 保持失败，防止负向测试掩盖真实问题。
class dpu_priv_expected_error extends uvm_report_catcher;
    string expected;
    int unsigned matched;
    // 诊断匹配器无外部资源；测试负责注册和移除。
    function new(string name = "dpu_priv_expected_error");
        super.new(name);
    endfunction
    // 按 ID/严重度/完整消息匹配；命中一次后清空期望，不吞第二条或无关错误。
    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "ATOMIC_OPS") &&
            (expected != "") && (get_message() == expected)) begin
            expected = "";
            matched++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

// 复用用户已有顶层 env/env_cfg 示例：两个 Host 各有两个 VF，VF0 私有、VF1 标准。
// 这样测试覆盖 env_cfg→Function→ops/FSM 的真实选择路径，并保留每 Host 一个内存域。
class dpu_priv_driver_flow_test extends virtio_system_env_example_test;
    `uvm_component_utils(dpu_priv_driver_flow_test)
    vdev_dpu_priv      devices[2];
    vdev_loopback_port ports[2];
    vdev_event_log     logs[2];
    virtio_function_instance private_functions[2];
    virtio_atomic_ops private_ops[2];
    uvm_sequencer #(pcie_tl_tlp) unused_rc;

    // 创建测试组件；所有配置仍在 build 阶段交给父示例生成。
    function new(string name = "dpu_priv_driver_flow_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 在 UVM 构建子环境前给每 Host 的 VF0 注册私有配置，VF1 沿用标准驱动。
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        unused_rc = new("unused_rc", this);
        for (int unsigned host_id = 0; host_id < 2; host_id++) begin
            dpu_service_key_t key;
            dpu_priv_driver_config private_cfg;
            string why;
            devices[host_id] = vdev_dpu_priv::type_id::create($sformatf("host%0d_vdev", host_id), this);
            logs[host_id] = vdev_event_log::type_id::create($sformatf("host%0d_vdev_log", host_id), this);
            ports[host_id] = vdev_loopback_port::type_id::create($sformatf("host%0d_vdev_port", host_id));
            private_cfg = new($sformatf("host%0d_private", host_id));
            private_cfg.local_qid_base = 8*host_id;
            key.function_key.host_id = host_id;
            key.function_key.pf_id = 0;
            key.function_key.kind = DPU_FUNCTION_VF;
            key.function_key.vf_id = 0;
            key.service_kind = DPU_SERVICE_VIO_NET;
            key.service_instance_id = 0;
            if (!system_cfg.vio_cfg_by_host[host_id].add_dpu_private_config(
                    key, private_cfg, why))
                `uvm_fatal("DPU_FLOW", why)
        end
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        foreach (devices[h])
            devices[h].event_ap.connect(logs[h].analysis_export);
    endfunction

    // 私有 VF 面对 vdev_dpu_priv：设备按该 VF 的 BDF 初始化（qinfo 报告 host=h、pfvf=0），挂到本 Host 的
    // 回环端口；VF 的 BAR accessor 换成回环 accessor，必须在 Function 绑定（把 accessor 接进 notify_mgr/
    // cap_mgr）之前完成。BAR 由测试按设备尺寸放置（VF 租约 BAR0 只有 16 KiB，私有设备寄存器窗 32 MiB），
    // 写进设备配置空间并同步给 accessor；回环 accessor 无 Fabric 布局，不受租约约束。
    function void attach_private_device(int unsigned h, virtio_function_instance f);
        vdev_loopback_bar_accessor acc;
        bit [63:0] bases[3];

        devices[h].bdf = f.bdf;
        devices[h].host_id = h;
        devices[h].init();
        ports[h].attach(devices[h]);
        acc = vdev_loopback_bar_accessor::type_id::create($sformatf("host%0d_priv_bar", h));
        acc.port = ports[h];
        acc.target_bdf = f.bdf;
        bases[0] = 64'h0000_0080_0000_0000 + h * 64'h0000_0000_1000_0000;
        bases[1] = bases[0] + 64'h0000_0000_0400_0000;
        bases[2] = bases[0] + 64'h0000_0000_0500_0000;
        for (int unsigned i = 0; i < 3; i++) begin
            acc.bar_base[2*i] = bases[i];
            ports[h].host_cfg_write(f.bdf, 12'h010 + 8*i, bases[i][31:0]);
            ports[h].host_cfg_write(f.bdf, 12'h014 + 8*i, bases[i][63:32]);
        end
        f.transport.bar = acc;
    endfunction

    function bit same_bytes(bit [7:0] a[$], byte unsigned b[$]);
        if (a.size() != b.size())
            return 0;
        foreach (a[i])
            if (a[i] != b[i])
                return 0;
        return 1;
    endfunction

    // 通过生产 Function 接线方法选取 ops/FSM；私有设备经回环端口访问，不使用 RC sequencer，
    // 标准和私有 Function 均检查类型，避免全局 factory override 污染其他 VF。
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        for (int unsigned h = 0; h < 2; h++) begin
            virtio_net_env env;
            env = system_env.get_virtio_env(h);
            ports[h].mem = system_env.get_host_mem(h);
            ports[h].iommu = env.iommu;
            ports[h].host_id = h;
            foreach (env.function_instances[i]) begin
                virtio_function_instance f;
                dpu_priv_config_backend check_private;
                f = env.function_instances[i];
                if (f.function_key.vf_id == 0)
                    attach_private_device(h, f);
                if (!(f.preflight_bind_pcie(unused_rc) &&
                      f.commit_bind_pcie(env.host_mem, env.iommu,
                          env.barrier, env.err_inj, env.wait_pol, unused_rc)))
                    `uvm_fatal("DPU_FLOW", "Function binding failed")
                // 私有与标准 VF 共用通用 ops/FSM；选择结果体现在配置后端与协议上。
                if (f.function_key.vf_id == 0) begin
                    private_ops[h] = f.driver_agent.ops;
                    if (f.private_cfg == null || private_ops[h] == null ||
                        !$cast(check_private, private_ops[h].config_backend) ||
                        check_private == null || f.protocol == null ||
                        private_ops[h].protocol != f.protocol ||
                        f.protocol.protocol_name() != "dpu_priv")
                        `uvm_fatal("DPU_FLOW", "env private configuration did not reach ops")
                    private_functions[h] = f;
                end else if (($cast(check_private, f.driver_agent.ops.config_backend) &&
                              check_private != null) ||
                             f.protocol.protocol_name() != "standard")
                    `uvm_fatal("DPU_FLOW", "private selection changed a standard VF")
            end
            if (private_functions[h] == null)
                `uvm_fatal("DPU_FLOW", "private VF was not instantiated")
        end
    endfunction

    // 创建真实 net_packet 帧；payload 字节应原样进入私有 DMA，不含 UVM/virtio framing。
    function packet_item make_frame(string name, int unsigned length);
        packet_item pkt;
        pkt = packet_item::type_id::create(name);
        if (!pkt.pkt.randomize() with {pkt_kind == ETH_IPV4_TCP; pkt_len == length;})
            `uvm_fatal("DPU_FLOW", "packet randomization failed")
        pkt.pkt.do_pack();
        return pkt;
    endfunction

    // 生产 ops/引擎走一次 TX/RX：设备按 qid map 与 VTX/VRX 参数表经 IOMMU 读帧、写 CQ，TX 帧回环到
    // 同队列对的 RX。从设备事件核对描述符长度（不含 header）、原始字节、通知字与 RX buffer 容量，
    // 并核对 token、完成长度与单帧 DMA 回收数量。
    task check_traffic(int unsigned h);
        virtio_queue_program_t tx_prog, rx_prog;
        packet_item frame;
        virtio_net_hdr_t hdr;
        uvm_object completed[$], received[$];
        byte unsigned raw[$];
        vdev_event ev[$];
        int unsigned id, before_count, tx_notifies;
        bit [31:0] tx_word;
        int unsigned budget = 8;
        frame = make_frame($sformatf("host%0d_frame", h), 128+64*h);
        hdr = '{default:0};
        if (!private_ops[h].get_queue_program(1, tx_prog) ||
            !private_ops[h].get_queue_program(0, rx_prog) ||
            tx_prog.host_id != h || tx_prog.local_qid != h*8+1)
            `uvm_fatal("DPU_FLOW", "private queue context/host routing mismatch")
        if (!virtio_net_packet_adapter::pack(frame, raw))
            `uvm_fatal("DPU_FLOW", "frame could not be packed")
        logs[h].events.delete();
        if (h == 0) private_ops[h].tx_submit(1, hdr, frame, 0, id);
        else private_functions[h].dataplane.tx_engine.submit_packet(1, frame, 0, id);
        if (id != 0) `uvm_fatal("DPU_FLOW", "private TX submission failed")
        #1us;
        logs[h].select(VDEV_DESC_CHAIN, ev);
        if ((ev.size() != 1) || (ev[0].q != tx_prog.local_qid) || (ev[0].seg_len.size() != 1) ||
            (ev[0].seg_len[0] != raw.size()))
            `uvm_fatal("DPU_FLOW", "TX descriptor contains a header or wrong length")
        logs[h].select(VDEV_PKT, ev);
        if ((ev.size() == 0) || (ev[0].dir != "tx") || !same_bytes(ev[0].bytes, raw))
            `uvm_fatal("DPU_FLOW", "TX DMA bytes differ from raw Ethernet frame")
        logs[h].select(VDEV_NOTIFY, ev);
        tx_notifies = 0;
        foreach (ev[i])
            if (ev[i].q == tx_prog.local_qid) begin
                tx_notifies++;
                tx_word = {ev[i].wrap, ev[i].next_idx[14:0], 16'(ev[i].q)};
            end
        if ((tx_notifies != 1) || (tx_word != (32'h8001_0000 | tx_prog.local_qid)))
            `uvm_fatal("DPU_FLOW", "TX notification did not carry tail/wrap/local_qid")
        before_count = ports[h].iommu.total_unmaps;
        if (h == 0) private_ops[h].tx_complete(1, completed, budget);
        else private_functions[h].dataplane.tx_engine.complete_tx(1, 8, completed);
        if (completed.size() != 1 || completed[0] != frame ||
            ports[h].iommu.total_unmaps != before_count+1)
            `uvm_fatal("DPU_FLOW", "TX completion ownership did not retire exactly once")

        logs[h].events.delete();
        if (h == 0) private_ops[h].rx_refill(0, 2);
        else begin
            if (private_functions[h].dataplane.rx_engine.get_rx_buf_size() != 2048)
                `uvm_fatal("DPU_FLOW", "private engine buffer query includes a header")
            private_functions[h].dataplane.rx_engine.refill_buffers(0, 2);
        end
        #1us;
        logs[h].select(VDEV_DESC_CHAIN, ev);
        if ((ev.size() != 1) || (ev[0].q != rx_prog.local_qid) || (ev[0].seg_len[0] != 2048))
            `uvm_fatal("DPU_FLOW", "RX buffer size not taken from config")
        if (h == 0) private_ops[h].rx_receive(0, received, budget);
        else private_functions[h].dataplane.rx_engine.receive_packets(0, 8, received);
        if (received.size() != 1 || !virtio_net_packet_adapter::compare(frame, received[0]))
            `uvm_fatal("DPU_FLOW", "RX did not return the exact Ethernet frame")
    endtask

    // 设备旋钮 stall_queue_stop 让停队/复位永不完成（DMA 不停）：确认 Host/DMA 资源原封保留，再恢复后
    // 重试释放。随后跑公共 FSM 后台补 RX，再从 Function.shutdown 停机；检查失败保护和成功后必须重新初始化
    // 的状态，确保不会进入标准寄存器路径，也不留下可误启动的 FSM。
    task check_lifecycle(int unsigned h);
        dpu_priv_expected_error catcher;
        virtio_queue_program_t prog;
        int unsigned maps_before;
        bit ok;
        catcher = new();
        uvm_report_cb::add(null, catcher);
        maps_before = ports[h].iommu.total_unmaps;
        devices[h].stall_queue_stop = 1;
        catcher.expected = "teardown_queue: config backend did not confirm queue_id=0 stopped; retaining queue DMA";
        private_ops[h].teardown_queue(0);
        if (catcher.matched != 1 || ports[h].iommu.total_unmaps != maps_before ||
            !private_ops[h].get_queue_program(0, prog))
            `uvm_fatal("DPU_FLOW", "failed stop released live DMA")
        catcher.expected = "device_reset: transport reset did not complete; retaining PF DMA";
        private_ops[h].device_reset_verified(ok);
        if (ok || catcher.matched != 2 || ports[h].iommu.total_unmaps != maps_before)
            `uvm_fatal("DPU_FLOW", "failed reset released live DMA")
        devices[h].stall_queue_stop = 0;
        private_ops[h].teardown_queue(0);
        if (private_ops[h].get_queue_program(0, prog) ||
            private_functions[h].vq_mgr.has_queue(0) ||
            devices[h].queue_enabled(0, 4*h) || ports[h].iommu.total_unmaps <= maps_before)
            `uvm_fatal("DPU_FLOW", "successful stop did not retire RX queue ownership")
        private_ops[h].device_reset_verified(ok);
        if (!ok || private_functions[h].vq_mgr.get_queue_count() != 0)
            `uvm_fatal("DPU_FLOW", "successful reset did not destroy private queues")
        private_functions[h].driver_agent.fsm.full_init();
        private_functions[h].driver_agent.fsm.start_dataplane();
        #100ns;
        maps_before = ports[h].iommu.total_unmaps;
        devices[h].stall_queue_stop = 1;
        catcher.expected = "device_reset: transport reset did not complete; retaining PF DMA";
        private_functions[h].shutdown();
        if (catcher.matched != 3 || ports[h].iommu.total_unmaps != maps_before ||
            private_functions[h].state != VF_RESET_FAILED ||
            private_functions[h].driver_agent.fsm.state != FSM_ERROR ||
            !private_ops[h].get_queue_program(0, prog))
            `uvm_fatal("DPU_FLOW", "failed Function shutdown lost resources or failure state")
        devices[h].stall_queue_stop = 0;
        private_functions[h].shutdown();
        if (private_functions[h].state != VF_DISABLED ||
            private_functions[h].driver_agent.fsm.state != FSM_REINIT_REQUIRED ||
            private_functions[h].vq_mgr.get_queue_count() != 0 ||
            ports[h].iommu.total_maps != ports[h].iommu.total_unmaps)
            `uvm_fatal("DPU_FLOW", "successful shutdown leaked DMA or left a restartable FSM")
        uvm_report_cb::delete(null, catcher);
    endtask

    // 全流程限定仿真时间：两个 Host 同时拥有活动队列，分别收发后清理并检查隔离。
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        fork : bounded_flow
            begin
                if (ports[0].mem == ports[1].mem)
                    `uvm_fatal("DPU_FLOW", "Hosts share the same memory manager")
                for (int unsigned h = 0; h < 2; h++) begin
                    private_functions[h].driver_agent.fsm.full_init();
                    if (private_functions[h].driver_agent.fsm.state != FSM_READY)
                        `uvm_fatal("DPU_FLOW", "private FSM initialization failed")
                end
                for (int unsigned h = 0; h < 2; h++) check_traffic(h);
                for (int unsigned h = 0; h < 2; h++) check_lifecycle(h);
                `uvm_info("DPU_FLOW", "DPU private src driver flow PASSED: two Hosts, raw TX/RX, DMA lifecycle", UVM_NONE)
            end
            begin
                #100us;
                `uvm_fatal("DPU_FLOW", "private flow timeout (unexpected standard MMIO or worker hang)")
            end
        join_any
        disable bounded_flow;
        phase.drop_objection(this);
    endtask
endclass
