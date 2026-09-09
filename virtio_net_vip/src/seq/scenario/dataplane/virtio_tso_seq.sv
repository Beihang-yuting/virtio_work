`ifndef VIRTIO_TSO_SEQ_SV
`define VIRTIO_TSO_SEQ_SV

// ============================================================================
// virtio_tso_seq (seq/scenario/dataplane)
//
// TSO(TCP 分段卸载)场景:发送一条 gso_type=TCPV4/TCPV6、gso_size=MSS 的
// TX 事务,期望设备按 MSS 把大包切成多段。hdr_len 按 v4(54)/v6(74) 的
// Eth+IP+TCP 头长给定,并置 NEEDS_CSUM(TSO 语义上要求配套 csum 卸载)。
// 说明(观察事实):payload_size 只用于约束和日志中的分段数估算,body
// 未将其写入事务——实际 payload 由 driver/设备侧路径决定。
// 约束意图:payload > MSS 保证必然分段;MSS 覆盖 536..1460 常见范围。
// ============================================================================

class virtio_tso_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_tso_seq)

    rand int unsigned payload_size;
    rand int unsigned mss;
    rand bit          is_ipv6;

    constraint c_defaults {
        payload_size inside {[2000:65535]};
        mss          inside {[536:1460]};
        payload_size > mss;
    }

    // 构造函数:默认 8KB payload / 1460 MSS / IPv4,约 6 段。
    function new(string name = "virtio_tso_seq");
        super.new(name);
        payload_size = 8000;
        mss          = 1460;
        is_ipv6      = 0;
    endfunction

    // init + 启动数据面后发送一条 TSO 头事务;分段正确性由设备模型/
    // scoreboard 核对。
    virtual task body();
        virtio_transaction req;

        do_init();
        send_txn(VIO_TXN_START_DP);

        req = virtio_transaction::type_id::create("req");
        req.txn_type         = VIO_TXN_SEND_PKTS;
        req.queue_id         = 0;
        req.net_hdr.gso_type = is_ipv6 ? VIRTIO_NET_HDR_GSO_TCPV6
                                       : VIRTIO_NET_HDR_GSO_TCPV4;
        req.net_hdr.gso_size = mss[15:0];
        req.net_hdr.hdr_len  = is_ipv6 ? 16'd74 : 16'd54;
        req.net_hdr.flags    = VIRTIO_NET_HDR_F_NEEDS_CSUM;
        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "TSO: payload=%0d mss=%0d ipv6=%0b segments~%0d",
            payload_size, mss, is_ipv6, (payload_size + mss - 1) / mss), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_TSO_SEQ_SV
