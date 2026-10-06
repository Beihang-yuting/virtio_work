// 目录层次：examples/dpu_priv_ring；验证 src 私有驱动在双 Host 顶层环境中的使用流程。
// 依赖 virtio_system_env 示例与生产 virtio_net_pkg；配置/后端由测试持有，数据/ring
// 生命周期完全交给生产 ops。模拟后端仅处理设备控制和 IOVA DMA，不替代驱动实现。
import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;
import net_packet_pkg::*;
import dpu_resource_pkg::*;
import pcie_tl_pkg::*;

// 测试设备后端保存真正传入的队列配置，通过 IOMMU 读写 ring/帧/CQ。
// 故意不使用 vq 回调或 Host GPA，才能发现 ring 映射和 Host/BDF 路由错误。
class dpu_priv_example_control extends dpu_priv_device_control;
    `uvm_object_utils(dpu_priv_example_control)
    host_mem_manager mem;
    virtio_iommu_model iommu;
    dpu_priv_queue_context_t configured[int unsigned];
    bit [31:0] notifications[int unsigned];
    bit fail_disable, fail_reset;
    int unsigned reset_count;

    // 创建空设备模型；Host 内存/IOMMU 在环境解析后注入，均为借用引用。
    function new(string name = "dpu_priv_example_control");
        super.new(name);
    endfunction

    // 成功复位清设备队列，失败保留设备状态；Host/DMA 资源仍由生产 ops 持有。
    virtual task reset_device(int unsigned host_id, bit [15:0] bdf, output bit ok);
        ok = !fail_reset;
        if (ok) begin
            configured.delete();
            notifications.delete();
            reset_count++;
        end
    endtask

    // 核对私有 CQ 必须在同一 IOVA 连续区间；读最后一字节可发现映射长度不足。
    virtual task configure_queue(dpu_priv_queue_context_t ctx, output bit ok);
        byte check_data[];
        ok = 0;
        if (ctx.cq_iova != ctx.ring_iova + ctx.queue_size*16)
            `uvm_fatal("DPU_FLOW", "CQ IOVA is not contiguous with descriptors")
        read_dma(ctx, ctx.ring_iova + ctx.ring_bytes - 1, 1, check_data);
        if (configured.exists(ctx.queue_id))
            `uvm_fatal("DPU_FLOW", "device queue configured twice")
        configured[ctx.queue_id] = ctx;
        ok = 1;
    endtask

    // 支持停 DMA 失败注入；成功清设备队列，失败保持其可访问 DMA 的状态。
    virtual task disable_queue(dpu_priv_queue_context_t ctx, output bit ok);
        ok = !fail_disable;
        if (ok) configured.delete(ctx.queue_id);
    endtask

    // 模型记录实际通知值，不产生 PCIe 流量；低 16 位须匹配本地号而非全局资源号。
    virtual task notify_queue(virtio_pci_transport transport,
                              dpu_priv_queue_context_t ctx, bit [31:0] value);
        if (!configured.exists(ctx.queue_id) || value[15:0] != ctx.local_qid)
            `uvm_fatal("DPU_FLOW", "private notify uses wrong queue identity")
        notifications[ctx.queue_id] = value;
    endtask

    // 设备纯读经严格 IOMMU 翻译后读 Host 内存；非法地址/域立即中止测试。
    function void read_dma(dpu_priv_queue_context_t ctx, bit [63:0] iova,
                           int unsigned size, output byte data[]);
        bit [63:0] gpa;
        iommu_fault_e fault;
        if (!iommu.translate_for_host(ctx.host_id, ctx.bdf, iova, size,
                                       DMA_TO_DEVICE, gpa, fault))
            `uvm_fatal("DPU_FLOW", "device DMA read failed")
        mem.read_mem(gpa, size, data);
    endfunction

    // 设备写入必须经过生产完成写边界，覆盖方向权限与写后记录；不能直接改 GPA。
    function void write_dma(dpu_priv_queue_context_t ctx, bit [63:0] iova,
                            byte data[]);
        iommu_fault_e fault;
        if (!iommu.write_from_device_for_host(ctx.host_id, mem, ctx.bdf,
                                               iova, data, fault))
            `uvm_fatal("DPU_FLOW", "device DMA write failed")
    endfunction
endclass

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
        if ((get_severity() == UVM_ERROR) && (get_id() == "DPU_PRIV_OPS") &&
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
    dpu_priv_example_control controls[2];
    virtio_function_instance private_functions[2];
    dpu_priv_atomic_ops private_ops[2];
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
            controls[host_id] = new($sformatf("host%0d_control", host_id));
            private_cfg = new($sformatf("host%0d_private", host_id));
            private_cfg.control = controls[host_id];
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

    // 通过生产 Function 接线方法选取 ops/FSM；设备控制模型不使用 RC sequencer，
    // 标准和私有 Function 均检查类型，避免全局 factory override 污染其他 VF。
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        for (int unsigned h = 0; h < 2; h++) begin
            virtio_net_env env;
            env = system_env.get_virtio_env(h);
            controls[h].mem = system_env.get_host_mem(h);
            controls[h].iommu = env.iommu;
            foreach (env.function_instances[i]) begin
                virtio_function_instance f;
                dpu_priv_atomic_ops check_private;
                f = env.function_instances[i];
                if (!f.wire_shared(env.host_mem, env.iommu, env.barrier,
                                     env.err_inj, env.wait_pol, unused_rc))
                    `uvm_fatal("DPU_FLOW", "Function binding failed")
                if (f.function_key.vf_id == 0) begin
                    if (f.private_cfg == null || !$cast(private_ops[h], f.driver_agent.ops))
                        `uvm_fatal("DPU_FLOW", "env private configuration did not reach ops")
                    private_functions[h] = f;
                end else if ($cast(check_private, f.driver_agent.ops))
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

    // 从设备视角读一个 16B 描述符，独立按 C ABI 解析地址与 18-bit 长度。
    function void descriptor(dpu_priv_example_control c, dpu_priv_queue_context_t ctx,
                             int unsigned slot, output bit [63:0] addr,
                             output int unsigned len);
        byte data[];
        c.read_dma(ctx, ctx.ring_iova+16*slot, 16, data);
        addr = {data[7], data[6], data[5], data[4], data[3], data[2], data[1], data[0]};
        len = {data[10][1:0], data[9], data[8]};
    endfunction

    // 驱动原子 API 走一次 TX/RX；模拟设备只通过已配置 IOVA 读取帧和写 CQ。
    // 验证原始字节、token、完成长度、通知本地号及单帧 DMA 回收数量。
    task check_traffic(int unsigned h);
        dpu_priv_queue_context_t tx_ctx, rx_ctx;
        packet_item frame;
        virtio_net_hdr_t hdr;
        uvm_object completed[$], received[$];
        byte unsigned raw[$];
        byte data[], cq_tx[2], cq_rx[16];
        bit [63:0] addr;
        int unsigned len, id, before_count;
        int unsigned budget = 8;
        frame = make_frame($sformatf("host%0d_frame", h), 128+64*h);
        hdr = '{default:0};
        if (!private_ops[h].get_queue_context(1, tx_ctx) ||
            !private_ops[h].get_queue_context(0, rx_ctx) ||
            tx_ctx.host_id != h || tx_ctx.local_qid != h*8+1)
            `uvm_fatal("DPU_FLOW", "private queue context/host routing mismatch")
        if (h == 0) private_ops[h].tx_submit(1, hdr, frame, 0, id);
        else private_functions[h].dataplane.tx_engine.submit_packet(1, frame, 0, id);
        if (id != 0) `uvm_fatal("DPU_FLOW", "private TX submission failed")
        descriptor(controls[h], tx_ctx, id, addr, len);
        if (!virtio_net_packet_adapter::pack(frame, raw) || len != raw.size())
            `uvm_fatal("DPU_FLOW", "TX descriptor contains a header or wrong length")
        controls[h].read_dma(tx_ctx, addr, len, data);
        foreach (raw[i]) if (data[i] != raw[i])
            `uvm_fatal("DPU_FLOW", "TX DMA bytes differ from raw Ethernet frame")
        if (controls[h].notifications[1] != (32'h8001_0000 | tx_ctx.local_qid))
            `uvm_fatal("DPU_FLOW", "TX notification did not carry tail/wrap/local_qid")
        before_count = controls[h].iommu.total_unmaps;
        cq_tx = '{8'h01, 8'h80};
        controls[h].write_dma(tx_ctx, tx_ctx.cq_iova, cq_tx);
        if (h == 0) private_ops[h].tx_complete(1, completed, budget);
        else private_functions[h].dataplane.tx_engine.complete_tx(1, 8, completed);
        if (completed.size() != 1 || completed[0] != frame ||
            controls[h].iommu.total_unmaps != before_count+1)
            `uvm_fatal("DPU_FLOW", "TX completion ownership did not retire exactly once")

        if (h == 0) private_ops[h].rx_refill(0, 2);
        else begin
            if (private_functions[h].dataplane.rx_engine.get_rx_buf_size() != 2048)
                `uvm_fatal("DPU_FLOW", "private engine buffer query includes a header")
            private_functions[h].dataplane.rx_engine.refill_buffers(0, 2);
        end
        descriptor(controls[h], rx_ctx, 0, addr, len);
        if (len != 2048) `uvm_fatal("DPU_FLOW", "RX buffer size not taken from config")
        controls[h].write_dma(rx_ctx, addr, data);
        cq_rx = '{default:0};
        cq_rx[3] = 8'h10; // desc_num=1，head_idx=0。
        cq_rx[6] = raw.size() & 8'hff;
        cq_rx[7] = 8'h80 | ((raw.size() >> 8) & 8'h3f);
        controls[h].write_dma(rx_ctx, rx_ctx.cq_iova, cq_rx);
        if (h == 0) private_ops[h].rx_receive(0, received, budget);
        else private_functions[h].dataplane.rx_engine.receive_packets(0, 8, received);
        if (received.size() != 1 || !virtio_net_packet_adapter::compare(frame, received[0]))
            `uvm_fatal("DPU_FLOW", "RX did not return the exact Ethernet frame")
    endtask

    // 注入停队/复位失败，确认 Host/DMA 资源原封保留，再恢复后重试释放。
    // 随后跑公共 FSM 后台补 RX，再从 Function.shutdown 停机；检查失败保护和成功后
    // 必须重新初始化的状态，确保既不会进入标准寄存器路径，也不留下可误启动的 FSM。
    task check_lifecycle(int unsigned h);
        dpu_priv_expected_error catcher;
        dpu_priv_queue_context_t ctx;
        int unsigned maps_before;
        bit ok;
        catcher = new();
        uvm_report_cb::add(null, catcher);
        maps_before = controls[h].iommu.total_unmaps;
        controls[h].fail_disable = 1;
        catcher.expected = "teardown: 未确认 DMA 停止，保留队列资源";
        private_ops[h].teardown_queue(0);
        if (catcher.matched != 1 || controls[h].iommu.total_unmaps != maps_before ||
            !private_ops[h].get_queue_context(0, ctx))
            `uvm_fatal("DPU_FLOW", "failed stop released live DMA")
        controls[h].fail_disable = 0;
        controls[h].fail_reset = 1;
        catcher.expected = "reset: 未确认 Function 停止 DMA，保留资源";
        private_ops[h].device_reset_verified(ok);
        if (ok || catcher.matched != 2 || controls[h].iommu.total_unmaps != maps_before)
            `uvm_fatal("DPU_FLOW", "failed reset released live DMA")
        controls[h].fail_reset = 0;
        private_ops[h].teardown_queue(0);
        if (private_ops[h].get_queue_context(0, ctx) ||
            private_functions[h].vq_mgr.has_queue(0) ||
            controls[h].configured.exists(0) || controls[h].iommu.total_unmaps <= maps_before)
            `uvm_fatal("DPU_FLOW", "successful stop did not retire RX queue ownership")
        private_ops[h].device_reset_verified(ok);
        if (!ok || private_functions[h].vq_mgr.get_queue_count() != 0)
            `uvm_fatal("DPU_FLOW", "successful reset did not destroy private queues")
        private_functions[h].driver_agent.fsm.full_init();
        private_functions[h].driver_agent.fsm.start_dataplane();
        #100ns;
        maps_before = controls[h].iommu.total_unmaps;
        controls[h].fail_reset = 1;
        catcher.expected = "reset: 未确认 Function 停止 DMA，保留资源";
        private_functions[h].shutdown();
        if (catcher.matched != 3 || controls[h].iommu.total_unmaps != maps_before ||
            private_functions[h].state != VF_RESET_FAILED ||
            private_functions[h].driver_agent.fsm.state != FSM_ERROR ||
            !private_ops[h].get_queue_context(0, ctx))
            `uvm_fatal("DPU_FLOW", "failed Function shutdown lost resources or failure state")
        controls[h].fail_reset = 0;
        private_functions[h].shutdown();
        if (private_functions[h].state != VF_DISABLED ||
            private_functions[h].driver_agent.fsm.state != FSM_REINIT_REQUIRED ||
            private_functions[h].vq_mgr.get_queue_count() != 0 ||
            controls[h].iommu.total_maps != controls[h].iommu.total_unmaps)
            `uvm_fatal("DPU_FLOW", "successful shutdown leaked DMA or left a restartable FSM")
        uvm_report_cb::delete(null, catcher);
    endtask

    // 全流程限定仿真时间：两个 Host 同时拥有活动队列，分别收发后清理并检查隔离。
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        fork : bounded_flow
            begin
                if (controls[0].mem == controls[1].mem)
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
