`ifndef VIRTIO_SCOREBOARD_CALLBACK_SV
`define VIRTIO_SCOREBOARD_CALLBACK_SV

virtual class virtio_scoreboard_callback extends uvm_object;

    function new(string name = "virtio_scoreboard_callback");
        super.new(name);
    endfunction

    // Custom packet comparison (replaces standard do_compare)
    pure virtual function bit custom_compare(
        uvm_object expected,    // packet_item
        uvm_object actual       // packet_item
    );

    // Custom field extraction from raw descriptor data
    // Used for vendor-specific descriptor format debugging
    pure virtual function void custom_extract_fields(
        byte unsigned raw_desc[],
        ref string field_values[string]   // field_name -> value_string
    );

endclass

`endif
