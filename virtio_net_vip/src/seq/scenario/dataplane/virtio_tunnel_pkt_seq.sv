`ifndef VIRTIO_TUNNEL_PKT_SEQ_SV
`define VIRTIO_TUNNEL_PKT_SEQ_SV

class virtio_tunnel_pkt_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_tunnel_pkt_seq)

    rand int unsigned tunnel_type; // 0=VXLAN, 1=GRE, 2=GENEVE
    rand int unsigned num_packets;

    constraint c_defaults {
        tunnel_type inside {[0:2]};
        num_packets inside {[1:16]};
    }

    function new(string name = "virtio_tunnel_pkt_seq");
        super.new(name);
        tunnel_type = 0;
        num_packets = 4;
    endfunction

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
