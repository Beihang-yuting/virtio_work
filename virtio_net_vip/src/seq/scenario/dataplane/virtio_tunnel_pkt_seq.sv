`ifndef VIRTIO_TUNNEL_PKT_SEQ_SV
`define VIRTIO_TUNNEL_PKT_SEQ_SV

// ============================================================================
// virtio_tunnel_pkt_seq (seq/scenario/dataplane)
//
// 隧道报文场景:模拟 VXLAN/GRE/GENEVE 封装报文的发送,差异体现在 net_hdr
// 的 hdr_len 上——按各隧道外层头长(Eth+IP+UDP+VXLAN 等)给出,配合
// NEEDS_CSUM 验证设备对内层报文的 csum 处理是否正确越过外层封装。
// 取舍:VIP 不真正构造封装 payload,只用 hdr_len 表达"外层头有多长",
// 足以覆盖 driver/设备对隧道头偏移的处理路径。
// 约束意图:三种隧道类型均匀覆盖,1..16 包。
// ============================================================================

class virtio_tunnel_pkt_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_tunnel_pkt_seq)

    rand int unsigned tunnel_type; // 0=VXLAN, 1=GRE, 2=GENEVE
    rand int unsigned num_packets;

    constraint c_defaults {
        tunnel_type inside {[0:2]};
        num_packets inside {[1:16]};
    }

    // 构造函数:默认 VXLAN、4 包。
    function new(string name = "virtio_tunnel_pkt_seq");
        super.new(name);
        tunnel_type = 0;
        num_packets = 4;
    endfunction

    // init + 启动数据面后,按隧道类型选定 hdr_len 逐包发送;GSO 关闭,
    // 只验证 csum 越过外层头的路径。
    virtual task body();
        string tunnel_name;

        do_init();
        send_txn(VIO_TXN_START_DP);

        case (tunnel_type)
            0: tunnel_name = "VXLAN";
            1: tunnel_name = "GRE";
            2: tunnel_name = "GENEVE";
        endcase

        repeat (num_packets) begin
            virtio_transaction req = virtio_transaction::type_id::create("req");
            req.txn_type         = VIO_TXN_SEND_PKTS;
            req.queue_id         = 0;
            req.net_hdr.flags    = VIRTIO_NET_HDR_F_NEEDS_CSUM;
            req.net_hdr.gso_type = VIRTIO_NET_HDR_GSO_NONE;
            // Outer header length varies by tunnel type
            case (tunnel_type)
                0: req.net_hdr.hdr_len = 16'd50; // VXLAN: 14+20+8+8
                1: req.net_hdr.hdr_len = 16'd38; // GRE: 14+20+4
                2: req.net_hdr.hdr_len = 16'd50; // GENEVE: 14+20+8+8
            endcase
            send_configured_txn(req);
        end

        `uvm_info(get_type_name(), $sformatf(
            "Tunnel: type=%s pkts=%0d", tunnel_name, num_packets), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_TUNNEL_PKT_SEQ_SV
