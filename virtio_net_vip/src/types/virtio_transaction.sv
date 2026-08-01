`ifndef VIRTIO_TRANSACTION_SV
`define VIRTIO_TRANSACTION_SV

class virtio_transaction extends uvm_sequence_item;
    `uvm_object_utils(virtio_transaction)

    // ===== Transaction type discriminator =====
    rand virtio_txn_type_e   txn_type;

    // ===== Passive monitor event metadata =====
    bit                      is_monitor_event;
    virtio_monitor_event_e   monitor_event;
    bit                      monitor_error;
    bit [63:0]               monitor_addr;
    int unsigned             monitor_length;
    bit                      monitor_is_write;
    bit [7:0]                status_old;
    int unsigned             interrupt_vector;
    interrupt_mode_e         irq_mode;
    int unsigned             num_vfs;

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
        is_monitor_event = 0;
        monitor_event = VIRTIO_MON_BAR_ACCESS;
        monitor_error = 0;
        monitor_addr = '0;
        monitor_length = 0;
        monitor_is_write = 0;
        status_old = '0;
        interrupt_vector = 0;
        irq_mode = IRQ_MSIX_PER_QUEUE;
        num_vfs = 0;
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
            is_monitor_event = rhs_t.is_monitor_event;
            monitor_event  = rhs_t.monitor_event;
            monitor_error  = rhs_t.monitor_error;
            monitor_addr   = rhs_t.monitor_addr;
            monitor_length = rhs_t.monitor_length;
            monitor_is_write = rhs_t.monitor_is_write;
            status_old     = rhs_t.status_old;
            interrupt_vector = rhs_t.interrupt_vector;
            irq_mode       = rhs_t.irq_mode;
            num_vfs        = rhs_t.num_vfs;
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
        if (is_monitor_event) begin
            return $sformatf("virtio_monitor_txn: event=%s addr=0x%016h queue=%0d error=%0b",
                             monitor_event.name(), monitor_addr, queue_id, monitor_error);
        end
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
