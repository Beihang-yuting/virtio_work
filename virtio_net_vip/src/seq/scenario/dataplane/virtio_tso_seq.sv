`ifndef VIRTIO_TSO_SEQ_SV
`define VIRTIO_TSO_SEQ_SV

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

    function new(string name = "virtio_tso_seq");
        super.new(name);
        payload_size = 8000;
        mss          = 1460;
        is_ipv6      = 0;
    endfunction

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
