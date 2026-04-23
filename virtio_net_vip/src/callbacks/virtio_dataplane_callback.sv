`ifndef VIRTIO_DATAPLANE_CALLBACK_SV
`define VIRTIO_DATAPLANE_CALLBACK_SV

virtual class virtio_dataplane_callback extends uvm_object;

    function new(string name = "virtio_dataplane_callback");
        super.new(name);
    endfunction

    // TX: custom descriptor chain assembly
    // Called instead of standard_tx_build_chain when custom_cb is set
    // pkt: the packet to send (from net_packet component)
    // hdr: virtio_net_hdr already built
    // sgs: output scatter-gather lists to fill
    pure virtual function void custom_tx_build_chain(
        uvm_object       pkt,          // packet_item from net_packet
        virtio_net_hdr_t hdr,
        ref virtio_sg_list sgs[$]
    );

    // RX: custom buffer parsing
    // Called instead of standard RX parse when custom_cb is set
    // raw_data: raw bytes from used buffer
    // hdr: output parsed net_hdr
    // pkt: output parsed packet
    pure virtual function void custom_rx_parse_buf(
        byte unsigned    raw_data[$],
        ref virtio_net_hdr_t hdr,
        ref uvm_object   pkt            // packet_item
    );

    // Header: custom net_hdr size (may differ from standard 10/12/20)
    pure virtual function int unsigned custom_hdr_size();

    // Header: custom pack
    pure virtual function void custom_hdr_pack(
        virtio_net_hdr_t hdr,
        ref byte unsigned data[$]
    );

    // Header: custom unpack
    pure virtual function void custom_hdr_unpack(
        byte unsigned data[$],
        ref virtio_net_hdr_t hdr
    );

endclass

`endif
