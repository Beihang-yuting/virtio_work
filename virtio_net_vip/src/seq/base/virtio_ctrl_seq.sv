`ifndef VIRTIO_CTRL_SEQ_SV
`define VIRTIO_CTRL_SEQ_SV

class virtio_ctrl_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_ctrl_seq)

    rand virtio_ctrl_class_e ctrl_class;
    rand bit [7:0]           ctrl_cmd;
    byte unsigned            ctrl_data[];

    // Output
    virtio_ctrl_ack_e ack_result;

    function new(string name = "virtio_ctrl_seq");
        super.new(name);
    endfunction

    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type   = VIO_TXN_CTRL_CMD;
        req.ctrl_class = ctrl_class;
        req.ctrl_cmd   = ctrl_cmd;
        req.ctrl_data  = ctrl_data;
        send_configured_txn(req);

        ack_result = req.ctrl_ack;

        `uvm_info(get_type_name(), $sformatf(
            "CTRL: class=%s cmd=0x%02h ack=%s",
            ctrl_class.name(), ctrl_cmd, ack_result.name()), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_CTRL_SEQ_SV
