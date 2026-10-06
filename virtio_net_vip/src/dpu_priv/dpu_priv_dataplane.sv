// 目录层次：src/dpu_priv；把 Function.dataplane 的公共引擎 API 委托给私有 ops。
// 依赖已定义的 TX/RX engine 与 dpu_priv_atomic_ops；适配器借用 ops，不单独持有
// DMA 缓冲，避免 engine/FSM 混用时创建两份所有权或重新添加 Virtio-net header。
`ifndef DPU_PRIV_DATAPLANE_SV
`define DPU_PRIV_DATAPLANE_SV

// 私有 TX 引擎仅提供 API 兼容；队列发布、通知与完成回收始终由同一个 ops 执行。
class dpu_priv_tx_engine extends virtio_tx_engine;
    `uvm_object_utils(dpu_priv_tx_engine)
    dpu_priv_atomic_ops private_ops;
    // 构造空适配器；Function 提交绑定时注入 ops。
    function new(string name = "dpu_priv_tx_engine");
        super.new(name);
    endfunction
    // 原始帧交给私有 ops；间接请求由 ops 拒绝，成功时只更新引擎统计。
    virtual task submit_packet(int unsigned queue_id, uvm_object pkt,
                                bit use_indirect, ref int unsigned desc_id);
        virtio_net_hdr_t hdr;
        byte unsigned raw[$];
        desc_id = '1;
        if (private_ops == null) begin
            `uvm_error("DPU_PRIV_DP", "TX engine 未绑定 private ops")
            return;
        end
        hdr = '{default:0};
        private_ops.tx_submit(queue_id, hdr, pkt, use_indirect, desc_id);
        if (desc_id != '1 && virtio_net_packet_adapter::pack(pkt, raw)) begin
            total_tx_packets++;
            total_tx_bytes += raw.size();
            total_tx_sg_count++;
        end else total_tx_errors++;
    endtask
    // 完成与 DMA 回收由 ops 统一执行；不访问基类标准 tracker。
    virtual task complete_tx(int unsigned queue_id, int unsigned budget,
                              ref uvm_object completed[$]);
        if (private_ops == null) begin
            `uvm_error("DPU_PRIV_DP", "TX completion 未绑定 private ops")
            return;
        end
        private_ops.tx_complete(queue_id, completed, budget);
    endtask
endclass

// 私有 RX 引擎复用公共 refill/receive API，但从私有 CQ 取包长并返回原始帧。
class dpu_priv_rx_engine extends virtio_rx_engine;
    `uvm_object_utils(dpu_priv_rx_engine)
    dpu_priv_atomic_ops private_ops;
    // 初始化适配层；buffer 大小在 Function 配置阶段设置。
    function new(string name = "dpu_priv_rx_engine");
        super.new(name);
    endfunction
    // 返回私有 buffer 容量，不增加 Virtio-net header；只是配置查询，不分配内存。
    virtual function int unsigned get_rx_buf_size();
        return buf_size;
    endfunction
    // 统一交给 ops 分配、登记与通知；多个入口共享同一 DMA 所有权表。
    virtual task refill_buffers(int unsigned queue_id, int unsigned count);
        if (private_ops == null) begin
            `uvm_error("DPU_PRIV_DP", "RX refill 未绑定 private ops")
            return;
        end
        private_ops.rx_refill(queue_id, count);
    endtask
    // CQ 回收与解析由 ops 完成；仅对本次新增输出更新统计，缓冲补充由调用方/FSM 控制。
    virtual task receive_packets(int unsigned queue_id, int unsigned budget,
                                  ref uvm_object received[$]);
        int unsigned before_count;
        byte unsigned raw[$];
        if (private_ops == null) begin
            `uvm_error("DPU_PRIV_DP", "RX receive 未绑定 private ops")
            return;
        end
        before_count = received.size();
        private_ops.rx_receive(queue_id, received, budget);
        for (int unsigned i = before_count; i < received.size(); i++) begin
            total_rx_packets++;
            if (virtio_net_packet_adapter::pack(received[i], raw))
                total_rx_bytes += raw.size();
        end
    endtask
endclass
`endif
