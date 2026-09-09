`ifndef VIRTIO_BAD_PACKET_SEQ_SV
`define VIRTIO_BAD_PACKET_SEQ_SV

// ============================================================================
// virtio_bad_packet_seq (seq/scenario/error)
//
// 畸形报文注入场景:正常 init/启动数据面后,发送一条 net_hdr 字段自相
// 矛盾的 TX 事务,验证设备/driver 对坏包的容错(不挂死、正确丢弃或报错)。
// 四种畸形:假 DATA_VALID + 越界 csum 偏移、hdr_len=0xFFFF 超 MTU、
// hdr_len=0 零长、声明 TSO 却无对应 payload 的截断包。
// 注意:这里的"坏"全部编码在 net_hdr 里,不动描述符结构——描述符级
// 错误由 virtio_desc_error_seq 覆盖,两者互补。
// ============================================================================

class virtio_bad_packet_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_bad_packet_seq)

    typedef enum {
        BAD_PKT_CHECKSUM, BAD_PKT_OVER_MTU,
        BAD_PKT_ZERO_LENGTH, BAD_PKT_TRUNCATED
    } bad_pkt_type_e;

    rand bad_pkt_type_e pkt_error;

    // 构造函数:畸形类型不给默认值,由随机化或调用方指定。
    function new(string name = "virtio_bad_packet_seq");
        super.new(name);
    endfunction

    // 正常启动后按 pkt_error 组装对应的畸形 net_hdr 并发送;设备的丢弃/
    // 报错行为由 scoreboard/driver 检查,本序列只保证激励发出。
    virtual task body();
        virtio_transaction req;

        do_init();
        send_txn(VIO_TXN_START_DP);

        `uvm_info(get_type_name(), $sformatf(
            "Sending bad packet: %s", pkt_error.name()), UVM_MEDIUM)

        req = virtio_transaction::type_id::create("req");
        req.txn_type = VIO_TXN_SEND_PKTS;
        req.queue_id = 0;

        case (pkt_error)
            BAD_PKT_CHECKSUM: begin
                req.net_hdr.flags       = VIRTIO_NET_HDR_F_DATA_VALID;
                req.net_hdr.csum_start  = 16'hFFFF;
                req.net_hdr.csum_offset = 16'hFFFF;
            end
            BAD_PKT_OVER_MTU: begin
                req.net_hdr.gso_type = VIRTIO_NET_HDR_GSO_NONE;
                req.net_hdr.hdr_len  = 16'hFFFF;
            end
            BAD_PKT_ZERO_LENGTH: begin
                req.net_hdr.gso_type = VIRTIO_NET_HDR_GSO_NONE;
                req.net_hdr.hdr_len  = 16'h0000;
            end
            BAD_PKT_TRUNCATED: begin
                req.net_hdr.gso_type = VIRTIO_NET_HDR_GSO_TCPV4;
                req.net_hdr.gso_size = 16'd1460;
                req.net_hdr.hdr_len  = 16'd54;
            end
        endcase

        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "Bad packet test complete: %s", pkt_error.name()), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_BAD_PACKET_SEQ_SV
