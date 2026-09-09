`ifndef VIRTIO_TRANSACTION_SV
`define VIRTIO_TRANSACTION_SV

// ============================================================================
// virtio_transaction (types)
//
// 全 VIP 唯一的 sequence item:序列 <-> driver 的命令通道和 monitor 广播
// 复用同一个类,由 txn_type / is_monitor_event 区分语义。取舍:字段按
// "各事务类型字段并集"平铺(数据面、控制面、队列管理、迁移、错误注入、
// monitor 元数据),而不是拆成事务子类——代价是单类偏大,换来 sequencer/
// FIFO 类型统一和公共 API 稳定(monitor 元数据即以"只增字段"方式演进,
// 见字段旁英文说明)。
// 双向约定:packets/ctrl_* 等由序列填入;received_pkts/ctrl_ack/desc_id/
// snapshot/success 等由 driver 在同一对象上回填,序列在 finish_item 后读取。
// 报文用 uvm_object 句柄携带(packet_item 定义在更晚的编译层),事务不
// 拥有报文对象,只传引用。
// 生命周期:序列/monitor create,经 sequencer/analysis FIFO 传递,UVM
// 引用计数回收。依赖:virtio_net_types.sv 的全部枚举/结构定义。
// ============================================================================

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
    // Raw MMIO payload/offset and function identity are retained for device
    // responders.  Older monitor consumers only use the fields above, so the
    // metadata is additive and keeps the transaction FIFO as the public API.
    bit [63:0]               monitor_data;
    int unsigned             monitor_bar_offset;
    // BAR number owning monitor_bar_offset.  32'hffff_ffff means the caller
    // did not provide a BAR identity (legacy/unit-test path).
    int unsigned             monitor_bar_id;
    bit [15:0]               monitor_bdf;
    int unsigned             monitor_host_id;
    int unsigned             monitor_segment_id;
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

    // 构造函数:给全部标量字段确定的默认值(INIT 类型、非 monitor 事件、
    // 50us 超时、256 队列深度、split ring、NAPI budget 64),避免未赋值
    // 字段以 X/随机残留进入 driver;monitor_bar_id 用全 F 表示"未提供
    // BAR 身份"的哨兵值。
    function new(string name = "virtio_transaction");
        super.new(name);
        txn_type = VIO_TXN_INIT;
        is_monitor_event = 0;
        monitor_event = VIRTIO_MON_BAR_ACCESS;
        monitor_error = 0;
        monitor_addr = '0;
        monitor_length = 0;
        monitor_is_write = 0;
        monitor_data = '0;
        monitor_bar_offset = 0;
        monitor_bar_id = 32'hffff_ffff;
        monitor_bdf = '0;
        monitor_host_id = 0;
        monitor_segment_id = 0;
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

    // 字段级浅拷贝:标量/结构按值复制,packets 等对象队列只复制句柄
    // (与"事务不拥有报文对象"的约定一致)。cast 失败时静默跳过本类字段,
    // 仅保留 super 拷贝的基类部分。新增字段必须同步维护此列表。
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
            monitor_data = rhs_t.monitor_data;
            monitor_bar_offset = rhs_t.monitor_bar_offset;
            monitor_bar_id = rhs_t.monitor_bar_id;
            monitor_bdf = rhs_t.monitor_bdf;
            monitor_host_id = rhs_t.monitor_host_id;
            monitor_segment_id = rhs_t.monitor_segment_id;
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

    // 单行摘要:monitor 事件打事件/地址/错误位,命令事务只打类型+队列,
    // 供日志快速定位;详细字段展开走 do_print。
    virtual function string convert2string();
        if (is_monitor_event) begin
            return $sformatf("virtio_monitor_txn: event=%s addr=0x%016h queue=%0d error=%0b",
                             monitor_event.name(), monitor_addr, queue_id, monitor_error);
        end
        return $sformatf("virtio_txn: type=%s queue=%0d", txn_type.name(), queue_id);
    endfunction

    // uvm_printer 展开:公共字段(类型/队列)之外,按 txn_type 只补打与
    // 该事务语义相关的字段,避免无关字段刷屏。
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
