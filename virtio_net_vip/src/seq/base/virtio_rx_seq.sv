`ifndef VIRTIO_RX_SEQ_SV
`define VIRTIO_RX_SEQ_SV

class virtio_rx_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_rx_seq)

    rand int unsigned expected_count;
    int unsigned      timeout_ns;

    // Output: received packets
    uvm_object received[$];

    constraint c_defaults {
        expected_count inside {[1:64]};
    }

    function new(string name = "virtio_rx_seq");
        super.new(name);
        expected_count = 1;
        timeout_ns     = 50000;
    endfunction

    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type       = VIO_TXN_WAIT_PKTS;
        req.expected_count = expected_count;
        req.timeout_ns     = timeout_ns;
        send_configured_txn(req);

        received = req.received_pkts;

        `uvm_info(get_type_name(), $sformatf(
            "RX: received %0d/%0d packets (timeout=%0dns)",
            received.size(), expected_count, timeout_ns), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_RX_SEQ_SV
