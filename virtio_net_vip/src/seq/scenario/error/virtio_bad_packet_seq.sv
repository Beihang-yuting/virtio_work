`ifndef VIRTIO_BAD_PACKET_SEQ_SV
`define VIRTIO_BAD_PACKET_SEQ_SV

class virtio_bad_packet_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_bad_packet_seq)

    typedef enum {
        BAD_PKT_CHECKSUM, BAD_PKT_OVER_MTU,
        BAD_PKT_ZERO_LENGTH, BAD_PKT_TRUNCATED
    } bad_pkt_type_e;

    rand bad_pkt_type_e pkt_error;

    function new(string name = "virtio_bad_packet_seq");
        super.new(name);
    endfunction

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
