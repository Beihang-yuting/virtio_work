`ifndef VIRTIO_TRANSACTION_SV
`define VIRTIO_TRANSACTION_SV

class virtio_transaction extends uvm_sequence_item;
    `uvm_object_utils(virtio_transaction)

    // ===== Transaction type discriminator =====
    rand virtio_txn_type_e   txn_type;

    // ===== Data plane fields =====
    rand int unsigned        queue_id;
    uvm_object               packets[$];       // packet_item list (TX input)
    uvm_object               received_pkts[$]; // packet_item list (RX output)
    int unsigned             expected_count;
    int unsigned             timeout_ns;       // for wait operations

    // ===== Control plane fields =====
    rand virtio_ctrl_class_e ctrl_class;
    rand bit [7:0]           ctrl_cmd;
    byte unsigned            ctrl_data[];
    virtio_ctrl_ack_e        ctrl_ack;         // output: device ack status

    // ===== Queue management =====
    rand int unsigned        queue_size;
    rand virtqueue_type_e    vq_type;

    // ===== Feature/Status =====
    bit [63:0]               features;
    bit [7:0]                status_val;

    // ===== MQ/RSS =====
    int unsigned             num_pairs;
    virtio_rss_config_t      rss_cfg;

    // ===== Hot migration =====
    virtio_device_snapshot_t snapshot;

    // ===== Atomic operation (MANUAL mode) =====
    rand virtio_atomic_op_e  atomic_op;

    // ===== Error injection =====
    rand virtqueue_error_e   vq_error_type;
    rand status_error_e      status_error;
    rand feature_error_e     feature_error;

    // ===== TX-specific =====
    virtio_net_hdr_t         net_hdr;
    uvm_object               pkt;              // single packet_item
    bit                      indirect;
    int unsigned             desc_id;          // output: assigned descriptor
    int unsigned             budget;           // NAPI budget
    int unsigned             num_bufs;         // RX refill count
    uvm_object               completed_pkts[$]; // TX complete output

    // ===== Result =====
    bit                      success;          // operation outcome

    function new(string name = "virtio_transaction");
        super.new(name);
        txn_type = VIO_TXN_INIT;
        queue_id = 0;
        expected_count = 0;
        timeout_ns = 50000;  // 50us default
        queue_size = 256;
        vq_type = VQ_SPLIT;
        num_pairs = 1;
        indirect = 0;
        budget = 64;
        num_bufs = 0;
        success = 0;
    endfunction

    // ===== UVM methods =====

    virtual function void do_copy(uvm_object rhs);
        virtio_transaction rhs_t;
        super.do_copy(rhs);
        if ($cast(rhs_t, rhs)) begin
            txn_type       = rhs_t.txn_type;
            queue_id       = rhs_t.queue_id;
            packets        = rhs_t.packets;
            received_pkts  = rhs_t.received_pkts;
            expected_count = rhs_t.expected_count;
            timeout_ns     = rhs_t.timeout_ns;
            ctrl_class     = rhs_t.ctrl_class;
            ctrl_cmd       = rhs_t.ctrl_cmd;
            ctrl_data      = rhs_t.ctrl_data;
            ctrl_ack       = rhs_t.ctrl_ack;
            queue_size     = rhs_t.queue_size;
            vq_type        = rhs_t.vq_type;
            features       = rhs_t.features;
            status_val     = rhs_t.status_val;
            num_pairs      = rhs_t.num_pairs;
            rss_cfg        = rhs_t.rss_cfg;
            snapshot       = rhs_t.snapshot;
            atomic_op      = rhs_t.atomic_op;
            vq_error_type  = rhs_t.vq_error_type;
            status_error   = rhs_t.status_error;
            feature_error  = rhs_t.feature_error;
            net_hdr        = rhs_t.net_hdr;
            pkt            = rhs_t.pkt;
            indirect       = rhs_t.indirect;
            desc_id        = rhs_t.desc_id;
            budget         = rhs_t.budget;
            num_bufs       = rhs_t.num_bufs;
            completed_pkts = rhs_t.completed_pkts;
            success        = rhs_t.success;
        end
    endfunction

    virtual function string convert2string();
        return $sformatf("virtio_txn: type=%s queue=%0d", txn_type.name(), queue_id);
    endfunction

    virtual function void do_print(uvm_printer printer);
        super.do_print(printer);
        printer.print_string("txn_type", txn_type.name());
        printer.print_int("queue_id", queue_id, 32);
        case (txn_type)
            VIO_TXN_SEND_PKTS:  printer.print_int("num_packets", packets.size(), 32);
            VIO_TXN_WAIT_PKTS:  printer.print_int("expected", expected_count, 32);
            VIO_TXN_CTRL_CMD:   begin
                printer.print_string("ctrl_class", ctrl_class.name());
                printer.print_int("ctrl_cmd", ctrl_cmd, 8);
            end
            VIO_TXN_ATOMIC_OP:  printer.print_string("atomic_op", atomic_op.name());
            VIO_TXN_INJECT_ERROR: printer.print_string("vq_error", vq_error_type.name());
            default: ;
        endcase
    endfunction

endclass

`endif
