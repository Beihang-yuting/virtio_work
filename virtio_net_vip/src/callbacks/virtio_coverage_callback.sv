`ifndef VIRTIO_COVERAGE_CALLBACK_SV
`define VIRTIO_COVERAGE_CALLBACK_SV

virtual class virtio_coverage_callback extends uvm_object;

    function new(string name = "virtio_coverage_callback");
        super.new(name);
    endfunction

    // Called on each transaction completion for custom covergroup sampling
    // txn is a virtio_transaction (forward reference, cast at runtime)
    pure virtual function void custom_sample(uvm_object txn);

endclass

`endif
