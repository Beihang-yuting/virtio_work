`ifndef VIRTIO_TX_ENGINE_SV
`define VIRTIO_TX_ENGINE_SV

// 原始字节队列类型；scoreboard 的 get_pkt_data 也使用它。
typedef byte unsigned virtio_byte_queue_t[$];

// ============================================================================
// virtio_tx_engine
//
// Function.dataplane 的 TX 薄适配层：
//   1. 从 packet 取线速字节，经 virtio_net_hdr_util::build_tx_hdr 推导 header；
//   2. DMA、描述符发布与 PCIe notify 委托 virtio_atomic_ops.tx_submit
//      （经 virtio_net_dataplane.bind_ops 绑定）；
//   3. 完成与 DMA 回收委托 virtio_atomic_ops.tx_complete。
// 引擎不持有 DMA 缓冲，只维护统计。私有 Function 同样注入通用 ops，同一引擎类即可。
// host_id/bdf 记录 Function 的 DMA 身份，供 fabric 测试断言，收发不读取。
// ============================================================================

class virtio_tx_engine extends uvm_object;
    `uvm_object_utils(virtio_tx_engine)

    // ===== External references (set by parent before use) =====
    // ops 是规范 TX 路径（借用）：DMA、描述符发布、通知与完成回收都由它执行。
    virtio_atomic_ops           ops;
    virtio_offload_engine       offload;
    bit [15:0]                  bdf;
    int unsigned                host_id;

    // ===== Configuration =====
    bit [63:0]       negotiated_features;

    // ===== Statistics =====
    longint unsigned total_tx_packets  = 0;
    longint unsigned total_tx_bytes    = 0;
    longint unsigned total_tx_errors   = 0;
    longint unsigned total_tx_sg_count = 0;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtio_tx_engine");
        super.new(name);
        negotiated_features = 64'h0;
    endfunction

    // ==================================================================
    // submit_packet
    //
    // Parameters:
    //   queue_id     -- Target TX virtqueue ID
    //   pkt          -- packet_item handle (as uvm_object)
    //   use_indirect -- Use indirect descriptors if supported
    //   desc_id      -- [output] Descriptor ID returned by add_buf
    // ==================================================================
    virtual task submit_packet(
        int unsigned     queue_id,
        uvm_object       pkt,
        bit              use_indirect,
        ref int unsigned desc_id
    );
        byte unsigned    pkt_data[$];
        virtio_net_hdr_t hdr;

        desc_id = '1;
        if (use_indirect &&
            !negotiated_features[VIRTIO_F_RING_INDIRECT_DESC]) begin
            `uvm_error("TX_ENG", $sformatf(
                "submit_packet: queue %0d requested indirect descriptors without negotiating VIRTIO_F_RING_INDIRECT_DESC",
                queue_id))
            return;
        end
        if ((ops == null) || (ops.vq_mgr == null)) begin
            `uvm_error("TX_ENG", $sformatf(
                "submit_packet: queue %0d has no bound atomic ops", queue_id))
            total_tx_errors++;
            return;
        end

        // ---- 1. Extract raw packet bytes ----
        pkt_data = extract_pkt_data(pkt);
        if (pkt_data.size() == 0) begin
            `uvm_error("TX_ENG",
                $sformatf("submit_packet: empty packet data on queue %0d", queue_id))
            total_tx_errors++;
            return;
        end
        if (ops.vq_mgr.get_queue(queue_id) == null) begin
            `uvm_error("TX_ENG",
                $sformatf("submit_packet: queue %0d not found", queue_id))
            total_tx_errors++;
            return;
        end

        // ---- 2. Build virtio_net_hdr (device performs GSO segmentation) ----
        virtio_net_hdr_util::build_tx_hdr(pkt_data, negotiated_features,
                                          offload, hdr);

        // ---- 3. ops 拥有 DMA、描述符发布与真实 notify；拒绝时已自行回滚 ----
        ops.tx_submit(queue_id, hdr, pkt, use_indirect, desc_id);
        if (desc_id == '1)
            return;

        total_tx_packets++;
        total_tx_bytes    += pkt_data.size();
        total_tx_sg_count += 2;   // [net_hdr] + [payload]

        `uvm_info("TX_ENG",
            $sformatf("submit_packet: queue=%0d desc_id=%0d pkt_size=%0d",
                      queue_id, desc_id, pkt_data.size()),
            UVM_HIGH)
    endtask : submit_packet

    // ==================================================================
    // complete_tx -- ops 按提交顺序回收每包的 header/payload DMA 所有权
    // ==================================================================
    virtual task complete_tx(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    completed[$]
    );
        int unsigned before_count;

        if ((ops == null) || (ops.vq_mgr == null) ||
            (ops.vq_mgr.get_queue(queue_id) == null)) begin
            `uvm_error("TX_ENG",
                $sformatf("complete_tx: queue %0d not found", queue_id))
            return;
        end

        // ops 按提交顺序回收每包的 header/payload DMA 所有权。
        before_count = completed.size();
        ops.tx_complete(queue_id, completed, budget);

        `uvm_info("TX_ENG",
            $sformatf("complete_tx: queue=%0d completed=%0d",
                      queue_id, completed.size() - before_count),
            UVM_HIGH)
    endtask : complete_tx

    // ==================================================================
    // extract_pkt_data (protected)
    //
    // net_packet::packet_item goes through virtio_net_packet_adapter so
    // the UVM length prefix is never sent; other objects keep the legacy
    // do_pack() bitstream conversion.
    // ==================================================================
    protected virtual function virtio_byte_queue_t extract_pkt_data(uvm_object pkt);
        byte unsigned data[$];
        uvm_packer packer;
        int unsigned pack_size;

        if (pkt == null) begin
            `uvm_error("TX_ENG", "extract_pkt_data: null packet handle")
            return data;
        end

        // net_packet::packet_item.do_pack() is a UVM object serialization
        // format ([size][raw bytes]), not a wire packet.  Use the explicit
        // adapter first to send only packet.pkt.raw_data.
        if (virtio_net_packet_adapter::pack(pkt, data))
            return data;

        packer = new();
        pkt.do_pack(packer);
        pack_size = packer.get_packed_size();

        if (pack_size > 0) begin
            bit bitstream[];
            byte unsigned byte_val;
            int unsigned num_bytes;

            packer.get_bits(bitstream);
            num_bytes = bitstream.size() / 8;
            for (int i = 0; i < num_bytes; i++) begin
                byte_val = 0;
                for (int b = 0; b < 8; b++)
                    byte_val = {byte_val[6:0], bitstream[i*8 + b]};
                data.push_back(byte_val);
            end
        end

        return data;
    endfunction : extract_pkt_data

    // ==================================================================
    // print_stats -- Log TX engine statistics
    // ==================================================================
    function void print_stats();
        `uvm_info("TX_ENG_STATS",
            $sformatf("TX Stats: packets=%0d bytes=%0d errors=%0d sg_chains=%0d",
                      total_tx_packets, total_tx_bytes, total_tx_errors,
                      total_tx_sg_count),
            UVM_LOW)
    endfunction : print_stats

endclass : virtio_tx_engine

`endif // VIRTIO_TX_ENGINE_SV
