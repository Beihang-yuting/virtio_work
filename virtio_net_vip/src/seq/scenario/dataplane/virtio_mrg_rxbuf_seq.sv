`ifndef VIRTIO_MRG_RXBUF_SEQ_SV
`define VIRTIO_MRG_RXBUF_SEQ_SV

class virtio_mrg_rxbuf_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_mrg_rxbuf_seq)

    rand int unsigned large_pkt_size;
    rand int unsigned rx_buf_size;
    rand int unsigned expected_buffers;

    constraint c_defaults {
        rx_buf_size    inside {[256:1024]};
        large_pkt_size inside {[2000:9000]};
        large_pkt_size > rx_buf_size;
        expected_buffers == (large_pkt_size + rx_buf_size - 1) / rx_buf_size;
    }

    function new(string name = "virtio_mrg_rxbuf_seq");
        super.new(name);
        large_pkt_size   = 4096;
        rx_buf_size      = 1024;
        expected_buffers = 4;
    endfunction

    virtual task body();
        virtio_rx_seq rx_s;

        do_init();
        send_txn(VIO_TXN_START_DP);

        // Wait for large packets needing multi-buffer merge
        rx_s = virtio_rx_seq::type_id::create("rx_s");
        rx_s.expected_count      = 1;
        rx_s.timeout_ns          = 100000;
        rx_s.drv_cfg             = drv_cfg;
        rx_s.negotiated_features = negotiated_features;
        rx_s.start(m_sequencer);

        `uvm_info(get_type_name(), $sformatf(
            "MRG_RXBUF: pkt_size=%0d buf_size=%0d expected_bufs=%0d received=%0d",
            large_pkt_size, rx_buf_size, expected_buffers,
            rx_s.received.size()), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_MRG_RXBUF_SEQ_SV
