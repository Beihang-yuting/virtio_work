`ifndef VIRTIO_CSUM_OFFLOAD_SEQ_SV
`define VIRTIO_CSUM_OFFLOAD_SEQ_SV

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

    function new(string name = "virtio_csum_offload_seq");
        super.new(name);
        num_packets = 4;
        csum_start  = 34;
        csum_offset = 40;
    endfunction

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
