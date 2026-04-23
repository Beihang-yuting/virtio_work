`ifndef VIRTIO_TX_SEQ_SV
`define VIRTIO_TX_SEQ_SV

class virtio_tx_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_tx_seq)

    rand int unsigned num_packets;
    rand int unsigned queue_id;
    rand bit          use_indirect;

    // Packet items to send (populated externally or via pre_body)
    uvm_object packet_items[$];

    constraint c_defaults {
        num_packets inside {[1:64]};
        queue_id    inside {[0:15]};
        use_indirect == 0;
    }

    function new(string name = "virtio_tx_seq");
        super.new(name);
        num_packets  = 1;
        queue_id     = 0;
        use_indirect = 0;
    endfunction

    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type = VIO_TXN_SEND_PKTS;
        req.queue_id = queue_id;
        req.indirect = use_indirect;

        foreach (packet_items[i])
            req.packets.push_back(packet_items[i]);

        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "TX: sent %0d packets on queue %0d (indirect=%0b)",
            req.packets.size(), queue_id, use_indirect), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_TX_SEQ_SV
