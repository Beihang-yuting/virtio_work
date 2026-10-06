// 目录层次：src/dpu_priv；生产私有环操作入口，继承统一 sequence/agent 的 ops 接口。
// 依赖通用 atomic_ops、私有回调/配置、packet adapter、Host memory 与 IOMMU。
// 本对象拥有 ring IOVA 与原始帧 DMA 的生命周期；Host manager、transport、control
// 为借用引用。只有设备确认停 DMA 后才解绑/释放；配置和回调按 Function/queue 隔离。
`ifndef DPU_PRIV_ATOMIC_OPS_SV
`define DPU_PRIV_ATOMIC_OPS_SV

// 使用派生 ops 隔离 DPU 私有流程：不能把标准三段环映射、Virtio-net header、
// common-config 或 control VQ 带入驱动的私有数据路径。继承的统一 API 仍可被序列调用。
class dpu_priv_atomic_ops extends virtio_atomic_ops;
    `uvm_object_utils(dpu_priv_atomic_ops)
    // 私有控制面后端：包装 env_cfg 注入的 dpu_priv_device_control，同时作为本 ops
    // 的 config_backend；doorbell 也经它发出。
    protected dpu_priv_config_backend private_backend;
    protected dpu_priv_queue_config queue_cfg[int unsigned];
    protected dpu_priv_queue_context_t contexts[int unsigned];
    protected int unsigned configured_pairs, default_size, rx_size;

    // 初始化空配置；configure_private 必须先于建队，构造时不分配 Host/DMA 资源。
    function new(string name = "dpu_priv_atomic_ops");
        super.new(name);
    endfunction

    // 冻结一份 Function 配置，避免运行时修改共享 env_cfg 改变活跃队列；有队列时
    // 拒绝重配。control 仍借用，上层须保证其有效到所有 DMA 完成并销毁队列。
    function bit configure_private(dpu_priv_driver_config cfg,
                                    int unsigned pairs, output string why);
        if ((cfg == null) || (contexts.num() != 0)) begin
            why = "private 配置为空或仍有活动队列";
            return 0;
        end
        if (!cfg.validate(pairs, why)) return 0;
        private_backend = dpu_priv_config_backend::type_id::create(
            {get_name(), "_private_backend"});
        private_backend.control = cfg.control;
        config_backend = private_backend;
        configured_pairs = pairs;
        default_size = cfg.default_queue_size;
        rx_size = cfg.rx_buf_size;
        queue_cfg.delete();
        for (int unsigned qid = 0; qid < pairs*2; qid++)
            queue_cfg[qid] = cfg.resolve_queue(qid);
        negotiated_features = 0;
        return 1;
    endfunction

    // 只读导出已编程的设备视角地址，供集成/诊断使用；未建队返回 0 并清输出。
    function bit get_queue_context(int unsigned qid,
                                   output dpu_priv_queue_context_t ctx);
        ctx = '{default:0};
        if (!contexts.exists(qid)) return 0;
        ctx = contexts[qid];
        return 1;
    endfunction

    // 统一检查配置和 Host/BDF 所有权；不允许一个 Function 的 ops 错接另一 Host 内存。
    protected function bit context_ready();
        if ((private_backend == null) || (private_backend.control == null) || (transport == null) || (mem == null) ||
            (iommu == null) || (vq_mgr == null) || (vq_mgr.barrier == null) ||
            (vq_mgr.mem != mem) || (vq_mgr.iommu != iommu) ||
            (vq_mgr.host_id != get_iommu_host_id(transport)) ||
            (vq_mgr.bdf != transport.bdf)) begin
            `uvm_error("DPU_PRIV_OPS", "private 配置未绑定或 Host/BDF/共享资源不一致")
            return 0;
        end
        return 1;
    endfunction

    // 注入独立回调后分配连续 desc+CQ，整块只映射一次，再交控制后端配置启动。
    // 失败无半条队列；control.configure_queue 返回失败必须保证设备不再访问该队列。
    virtual task setup_queue(int unsigned queue_id, int unsigned queue_size,
                              virtqueue_type_e vq_type, output bit ok);
        custom_virtqueue vq;
        virtqueue_base base_vq;
        dpu_priv_ring_callback cb;
        dpu_priv_queue_config q;
        dpu_priv_queue_context_t ctx;
        int unsigned size;
        bit configured;
        virtio_config_backend backend;

        ok = 0;
        if (!context_ready()) return;
        size = (queue_size == 0) ? default_size : queue_size;
        if ((vq_type != VQ_CUSTOM) || !queue_cfg.exists(queue_id) ||
            vq_mgr.has_queue(queue_id) || (size < 2) || (size > 4096) ||
            ((size & (size-1)) != 0)) begin
            `uvm_error("DPU_PRIV_OPS", "setup_queue: 类型/编号/大小非法或队列已存在")
            return;
        end
        q = queue_cfg[queue_id];
        base_vq = vq_mgr.create_queue(queue_id, size, VQ_CUSTOM);
        if (!$cast(vq, base_vq)) begin
            `uvm_error("DPU_PRIV_OPS", "setup_queue: 工厂未返回 custom_virtqueue")
            return;
        end
        cb = new($sformatf("private_cb_%0d", queue_id), queue_id%2, q.local_qid);
        cb.dport_info = q.dport_info;
        cb.dport_id = q.dport_id;
        cb.dport_type = q.dport_type;
        cb.cpu_tx_cos = q.cpu_tx_cos;
        cb.rss_lag = q.rss_lag;
        cb.l3_cs = q.l3_cs;
        cb.l4_cs = q.l4_cs;
        cb.fwd = q.fwd;
        vq.custom_cb = cb;
        vq.alloc_rings();
        if (cb.ring_alloc_bytes == 0) begin
            vq_mgr.destroy_queue(queue_id);
            return;
        end
        ctx = '{default:0};
        ctx.host_id = get_iommu_host_id(transport);
        ctx.bdf = transport.bdf;
        ctx.queue_id = queue_id;
        ctx.local_qid = q.local_qid;
        ctx.queue_size = size;
        ctx.rx_buf_size = rx_size;
        ctx.tx_mode = queue_id%2;
        ctx.ring_bytes = cb.ring_alloc_bytes;
        ctx.notify_bar = q.notify_bar;
        ctx.notify_offset = q.notify_offset;
        ctx.ring_iova = iommu.map_for_host(ctx.host_id, ctx.bdf,
            vq.desc_table_addr, ctx.ring_bytes, DMA_BIDIRECTIONAL);
        if ((ctx.ring_iova == '1) || (ctx.ring_iova == 0)) begin
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("DPU_PRIV_OPS", "setup_queue: 连续 ring DMA 映射失败")
            return;
        end
        ctx.cq_iova = ctx.ring_iova + size*16;
        backend = cfg_backend();
        backend.configure_queue(dpu_priv_config_backend::from_context(ctx), configured);
        if (!configured) begin
            iommu.unmap_for_host(ctx.host_id, ctx.bdf, ctx.ring_iova);
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("DPU_PRIV_OPS", "setup_queue: 设备拒绝私有队列配置")
            return;
        end
        contexts[queue_id] = ctx;
        ring_iovas[queue_id] = '{ctx.ring_iova};
        vq.state = VQ_ENABLED;
        vq.queue_enable = 1;
        ok = 1;
    endtask

    // 整组建队前检查私有配置与调用参数；只建 RX/TX，不生成标准 control VQ。
    // 基类的逐队列回滚复用本类 teardown，因此失败时仍遵守停 DMA 确认边界。
    virtual task setup_all_queues(int unsigned num_pairs, virtqueue_type_e vq_type,
                                   int unsigned queue_size, output bit ok);
        ok = 0;
        if ((num_pairs != configured_pairs) || (vq_type != VQ_CUSTOM)) begin
            `uvm_error("DPU_PRIV_OPS", "setup_all_queues: 与绑定私有配置不一致")
            return;
        end
        negotiated_features = 0;
        super.setup_all_queues(num_pairs, vq_type, queue_size, ok);
    endtask

    // 设备确认静止后的唯一释放入口：归还 token、数据 DMA、ring IOVA 与 Host 内存。
    // 只供 teardown/reset 调用；不得在仍可能有 DMA 的队列上调用。
    protected function void release_stopped_queue(int unsigned qid);
        uvm_object tokens[$];
        virtqueue_base vq;
        if (!contexts.exists(qid)) return;
        vq = vq_mgr.get_queue(qid);
        if (vq != null) vq.detach_all_unused(tokens);
        if (tx_dma_map.exists(qid)) begin
            retire_normal_dma_records(tx_dma_map[qid]);
            tx_dma_map.delete(qid);
        end
        if (rx_dma_map.exists(qid)) begin
            retire_normal_dma_records(rx_dma_map[qid]);
            rx_dma_map.delete(qid);
        end
        iommu.unmap_for_host(contexts[qid].host_id, contexts[qid].bdf,
                             contexts[qid].ring_iova);
        ring_iovas.delete(qid);
        vq_mgr.destroy_queue(qid);
        contexts.delete(qid);
    endfunction

    // 停队成功才回收；后端超时/失败保留队列和全部 DMA，允许诊断或稍后重试。
    virtual task teardown_queue(int unsigned queue_id);
        virtio_config_backend backend;
        bit stopped;
        if (!contexts.exists(queue_id)) return;
        backend = cfg_backend();
        backend.disable_queue(dpu_priv_config_backend::from_context(contexts[queue_id]),
                              stopped);
        if (!stopped) begin
            `uvm_error("DPU_PRIV_OPS", "teardown: 未确认 DMA 停止，保留队列资源")
            return;
        end
        release_stopped_queue(queue_id);
    endtask

    // 私有队列复位是停止并销毁，再由 setup_queue 重建；不写标准 Q_RESET。
    virtual task reset_queue(int unsigned queue_id);
        teardown_queue(queue_id);
    endtask

    // Function 级复位由真实控制后端确认；失败保持资源，成功逐队列回收。
    virtual task device_reset_verified(ref bit reset_complete);
        virtio_config_backend backend;
        int unsigned qids[$];
        reset_complete = 0;
        if (!context_ready()) return;
        backend = cfg_backend();
        backend.reset(reset_complete);
        if (!reset_complete) begin
            `uvm_error("DPU_PRIV_OPS", "reset: 未确认 Function 停止 DMA，保留资源")
            return;
        end
        foreach (contexts[qid]) qids.push_back(qid);
        foreach (qids[i]) release_stopped_queue(qids[i]);
        negotiated_features = 0;
    endtask

    // 发布内存屏障后发送实际私有 32-bit doorbell；手工序列也应使用此入口。
    virtual task kick_queue(int unsigned queue_id);
        custom_virtqueue vq;
        dpu_priv_ring_callback cb;
        if (!contexts.exists(queue_id) ||
            !$cast(vq, vq_mgr.get_queue(queue_id)) ||
            !$cast(cb, vq.custom_cb)) begin
            `uvm_error("DPU_PRIV_OPS", "kick: 私有队列尚未创建")
            return;
        end
        vq.kick();
        private_backend.bind_transport(transport);
        private_backend.notify_queue(contexts[queue_id], cb.last_notify_word);
    endtask

    // 将 packet_item 的原始 Ethernet 字节映射成一个 SG；回调负责 64KiB 分片。
    // 不携带 Virtio-net header；TSO/间接与标准 header offload 请求显式拒绝。
    virtual task tx_submit(int unsigned queue_id, virtio_net_hdr_t net_hdr,
                             uvm_object pkt, bit use_indirect,
                             ref int unsigned desc_id);
        byte unsigned raw[$];
        byte data[];
        normal_dma_record_t rec;
        virtio_sg_list sgs[1];
        virtio_sg_entry entry;
        virtqueue_base vq;
        int unsigned dma_size;
        desc_id = '1;
        if (!contexts.exists(queue_id) || !contexts[queue_id].tx_mode ||
            use_indirect || (net_hdr.gso_type != VIRTIO_NET_HDR_GSO_NONE) ||
            (net_hdr.flags != 0) || !virtio_net_packet_adapter::pack(pkt, raw)) begin
            `uvm_error("DPU_PRIV_OPS", "tx_submit: 队列/packet 非法或请求不支持的 offload")
            return;
        end
        if (raw.size() > 7*65536) begin
            `uvm_error("DPU_PRIV_OPS", "tx_submit: 原始帧超过 7 条 data desc")
            return;
        end
        vq = vq_mgr.get_queue(queue_id);
        if (vq.get_free_count() < ((raw.size()+65535)/65536)) return;
        dma_size = (raw.size()+3) & 32'hffff_fffc;
        rec.host_id = contexts[queue_id].host_id;
        rec.bdf = contexts[queue_id].bdf;
        rec.gpa = mem.alloc(dma_size, .align(4));
        if (rec.gpa == '1) return;
        mem.mem_set(rec.gpa, 0, dma_size);
        data = new[raw.size()];
        foreach (raw[i]) data[i] = raw[i];
        mem.write_mem(rec.gpa, data);
        rec.iova = iommu.map_for_host(rec.host_id, rec.bdf, rec.gpa,
                                      dma_size, DMA_TO_DEVICE);
        if ((rec.iova == '1) || (rec.iova == 0)) begin
            mem.free(rec.gpa);
            return;
        end
        entry = '{addr:rec.iova, len:raw.size(), is_indirect:0};
        sgs[0].entries.push_back(entry);
        desc_id = vq.add_buf(sgs, 1, 0, pkt, 0);
        if (desc_id == '1) begin
            retire_normal_dma_record(rec);
            return;
        end
        tx_dma_map[queue_id].push_back(rec);
        if (vq.needs_notification()) kick_queue(queue_id);
    endtask

    // 私有 TX 每包只有一个原始帧 DMA 记录；按 CQ 回收 token 后退休该映射。
    // 一包即使拆为多个 desc 也只释放一次，不能复用标准路径的每包两条映射规则。
    virtual task tx_complete(int unsigned queue_id,
                              ref uvm_object completed_pkts[$], int unsigned max_budget);
        virtqueue_base vq;
        uvm_object token;
        int unsigned len;
        normal_dma_record_t rec;
        if (!contexts.exists(queue_id) || !contexts[queue_id].tx_mode) return;
        vq = vq_mgr.get_queue(queue_id);
        for (int unsigned n = 0; n < max_budget; n++) begin
            if (!vq.poll_used(token, len)) break;
            if (!tx_dma_map.exists(queue_id) || tx_dma_map[queue_id].size() == 0) begin
                `uvm_fatal("DPU_PRIV_OPS", "TX 完成缺少 DMA 所有权记录")
                return;
            end
            rec = tx_dma_map[queue_id].pop_front();
            retire_normal_dma_record(rec);
            completed_pkts.push_back(token);
        end
        if (tx_dma_map.exists(queue_id) && tx_dma_map[queue_id].size() == 0)
            tx_dma_map.delete(queue_id);
    endtask

    // 按配置容量投递零初始化 RX buffer，无 Virtio header 预留；申请失败停止补充，
    // 已投递部分仍保持有效，随后用私有 doorbell 发布。容量固定取私有配置
    // rx_size，忽略 buf_size（参数仅为保持统一 ops 签名）。
    virtual task rx_refill(int unsigned queue_id, int unsigned num_bufs,
                           int unsigned buf_size = 0);
        virtqueue_base vq;
        int unsigned dma_size, result, filled;
        if (!contexts.exists(queue_id) || contexts[queue_id].tx_mode) return;
        vq = vq_mgr.get_queue(queue_id);
        dma_size = (rx_size+3) & 32'hffff_fffc;
        filled = 0;
        while ((filled < num_bufs) && (vq.get_free_count() != 0)) begin
            normal_dma_record_t rec;
            virtio_sg_list sgs[1];
            virtio_sg_entry entry;
            rec.host_id = contexts[queue_id].host_id;
            rec.bdf = contexts[queue_id].bdf;
            rec.gpa = mem.alloc(dma_size, .align(4));
            if (rec.gpa == '1) break;
            mem.mem_set(rec.gpa, 0, dma_size);
            rec.iova = iommu.map_for_host(rec.host_id, rec.bdf, rec.gpa,
                                          dma_size, DMA_FROM_DEVICE);
            if ((rec.iova == '1) || (rec.iova == 0)) begin
                mem.free(rec.gpa);
                break;
            end
            entry = '{addr:rec.iova, len:rx_size, is_indirect:0};
            sgs[0].entries.push_back(entry);
            result = vq.add_buf(sgs, 0, 1, null, 0);
            if (result == '1) begin
                retire_normal_dma_record(rec);
                break;
            end
            rx_dma_map[queue_id].push_back(rec);
            filled++;
        end
        if ((filled != 0) && vq.needs_notification()) kick_queue(queue_id);
    endtask

    // 按 RX CQ pkt_len 读取整个原始帧；私有 ring 不带 Virtio-net header，帧本身即
    // payload，net_hdr 置零、num_buffers=1。单 buffer 所有权在复制后回收。回调拒绝
    // 非法/多 buffer CQ 时保持索引与 DMA 记录不变。dataplane 引擎经此入口收包。
    virtual task rx_receive_frames(int unsigned queue_id, int unsigned max_budget,
                                    ref virtio_rx_frame_t frames[$]);
        virtqueue_base vq;
        uvm_object token;
        int unsigned len;
        if (!contexts.exists(queue_id) || contexts[queue_id].tx_mode) return;
        vq = vq_mgr.get_queue(queue_id);
        for (int unsigned n = 0; n < max_budget; n++) begin
            normal_dma_record_t rec;
            byte data[];
            virtio_rx_frame_t frame;
            if (!vq.poll_used(token, len)) break;
            if (!rx_dma_map.exists(queue_id) || rx_dma_map[queue_id].size() == 0) begin
                `uvm_fatal("DPU_PRIV_OPS", "RX 完成缺少 DMA 所有权记录")
                return;
            end
            rec = rx_dma_map[queue_id].pop_front();
            mem.read_mem(rec.gpa, len, data);
            foreach (data[i]) frame.payload.push_back(data[i]);
            retire_normal_dma_record(rec);
            frame.net_hdr = '{default:0};
            frame.token = token;
            frame.num_buffers = 1;
            frames.push_back(frame);
        end
        if (rx_dma_map.exists(queue_id) && rx_dma_map[queue_id].size() == 0)
            rx_dma_map.delete(queue_id);
    endtask

    // 原始帧解析为 packet_item；私有 ring 只承载以太网帧，无法解析时报错丢弃。
    virtual task rx_receive(int unsigned queue_id,
                             ref uvm_object received_pkts[$], int unsigned max_budget);
        virtio_rx_frame_t frames[$];
        rx_receive_frames(queue_id, max_budget, frames);
        foreach (frames[i]) begin
            packet_item pkt;
            if (virtio_net_packet_adapter::unpack(frames[i].payload, pkt))
                received_pkts.push_back(pkt);
            else
                `uvm_error("DPU_PRIV_OPS", "RX 原始帧无法解析")
        end
    endtask

    // 标准控制命令不能发到私有 data ring；返回错误 ACK，不改队列或设备。
    virtual task ctrl_send(virtio_ctrl_class_e ctrl_class, bit [7:0] cmd,
                            byte unsigned data[], ref virtio_ctrl_ack_e ack);
        ack = VIRTIO_NET_CTRL_ACK_ERR;
        `uvm_error("DPU_PRIV_OPS", "私有驱动不支持标准 Virtio control VQ")
    endtask

    // 直接调用标准生命周期 API 也必须拒绝，避免手工序列绕过私有 FSM 误写 MMIO。
    // 此 helper 只报告诊断；私有初始化统一走 control.reset/configure_queue。
    protected function void reject_standard_control(string operation);
        `uvm_error("DPU_PRIV_OPS", {operation, ": 私有驱动不使用标准 Virtio 控制寄存器"})
    endfunction
    // 不读取标准 features；输出零并报告不支持。
    virtual task read_device_features(ref bit [63:0] features);
        features = 0;
        reject_standard_control("read_device_features");
    endtask
    // 不写标准 features，保持私有配置。
    virtual task write_driver_features(bit [63:0] features);
        reject_standard_control("write_driver_features");
    endtask
    // 不执行标准协商；输出零，不宣称设备接受任何标准特性。
    virtual task negotiate_features(bit [63:0] driver_caps, ref bit [63:0] result);
        result = 0;
        reject_standard_control("negotiate_features");
    endtask
    // 拒绝标准 ACKNOWLEDGE 写入，不访问设备。
    virtual task set_acknowledge();
        reject_standard_control("set_acknowledge");
    endtask
    // 拒绝标准 DRIVER 写入，不访问设备。
    virtual task set_driver();
        reject_standard_control("set_driver");
    endtask
    // 私有初始化无 FEATURES_OK 阶段，输出失败并报告不支持。
    virtual task set_features_ok(ref bit ok);
        ok = 0;
        reject_standard_control("set_features_ok");
    endtask
    // 不读取标准 feature 状态；输出失败并保持设备现场。
    virtual task verify_features_ok(ref bit ok);
        ok = 0;
        reject_standard_control("verify_features_ok");
    endtask
    // 私有启动已由 configure_queue 完成，禁止再写标准 DRIVER_OK。
    virtual task set_driver_ok();
        reject_standard_control("set_driver_ok");
    endtask
    // 私有错误状态由控制后端/上层处理，不写标准 FAILED 位。
    virtual task set_failed();
        reject_standard_control("set_failed");
    endtask
    // 当前私有模式固定 polling，不执行标准 Virtio MSI-X common-config 配置。
    virtual task setup_msix(int unsigned num_queues);
        reject_standard_control("setup_msix");
    endtask
endclass
`endif
