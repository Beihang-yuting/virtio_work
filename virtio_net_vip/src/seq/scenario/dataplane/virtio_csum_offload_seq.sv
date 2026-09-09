`ifndef VIRTIO_CSUM_OFFLOAD_SEQ_SV
`define VIRTIO_CSUM_OFFLOAD_SEQ_SV

// ============================================================================
// virtio_csum_offload_seq (seq/scenario/dataplane)
//
// 校验和卸载场景:连发若干带 NEEDS_CSUM 标志的 TX 报文,net_hdr 的
// csum_start/csum_offset 指示设备从何处起算、结果写回何处;设备是否正确
// 补算校验和由 scoreboard/设备模型核对,本序列只负责构造激励。
// 约束意图:csum_start 覆盖 L3/L4 头典型偏移(14..54),并保证
// csum_offset >= csum_start 以构成合法组合;gso_type 固定 GSO_NONE,
// 把 CSUM 与 TSO 场景解耦。
// ============================================================================

class virtio_csum_offload_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_csum_offload_seq)

    rand int unsigned num_packets;
    rand bit [15:0]   csum_start;
    rand bit [15:0]   csum_offset;

    constraint c_defaults {
        num_packets inside {[1:32]};
        csum_start  inside {[14:54]};
        csum_offset inside {[16:40]};
        csum_offset >= csum_start;
    }

    // 构造函数:默认 4 包,csum_start/offset 取 IPv4+TCP 校验和的典型位置。
    function new(string name = "virtio_csum_offload_seq");
        super.new(name);
        num_packets = 4;
        csum_start  = 34;
        csum_offset = 40;
    endfunction

    // init + 启动数据面后逐包发送带 CSUM 卸载头的事务;每包独立构造,
    // 全部报文共用同一组 csum 参数。
    virtual task body();
        do_init();
        send_txn(VIO_TXN_START_DP);

        repeat (num_packets) begin
            virtio_transaction req = virtio_transaction::type_id::create("req");
            req.txn_type            = VIO_TXN_SEND_PKTS;
            req.queue_id            = 0;
            req.net_hdr.flags       = VIRTIO_NET_HDR_F_NEEDS_CSUM;
            req.net_hdr.csum_start  = csum_start;
            req.net_hdr.csum_offset = csum_offset;
            req.net_hdr.gso_type    = VIRTIO_NET_HDR_GSO_NONE;
            send_configured_txn(req);
        end

        `uvm_info(get_type_name(), $sformatf(
            "CSUM offload: %0d packets, start=%0d offset=%0d",
            num_packets, csum_start, csum_offset), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_CSUM_OFFLOAD_SEQ_SV
