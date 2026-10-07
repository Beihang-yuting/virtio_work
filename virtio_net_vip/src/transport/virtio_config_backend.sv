`ifndef VIRTIO_CONFIG_BACKEND_SV
`define VIRTIO_CONFIG_BACKEND_SV

// ============================================================================
// virtio_config_backend
//
// 目录层次：src/transport；atomic ops 的设备配置副作用（status、feature、队列编程、
// 队列启停/复位、MSI-X、Function 复位）的唯一出口。ops 负责 Host memory、IOMMU 与
// ring 所有权，后端只负责"把已经准备好的参数写进设备"。后端借用 transport，
// 由 ops 在每次调用前重新绑定；后端不持有 DMA 资源。
//   virtio_common_cfg_backend : 标准 virtio-pci common-config（现行行为）。
//   dpu_priv_config_backend   : DPU 私有环控制面（dpu_priv_device_control）。
//   后续 virtio_af_direct_backend：VIP 扮演 AF 直接写 DPU 队列/特性/中断表。
// 失败约定：configure/enable 返回 ok=0 时设备不得访问该队列；disable/reset 返回
// ok=0 时调用方保留全部 ring 与数据 DMA，不得释放。
// ============================================================================

// 一条队列的设备视角编程参数。标准环使用 desc/driver/device 三个 IOVA；私有环
// (VQ_CUSTOM) 的 desc_iova 为整块 desc+CQ 起点、device_iova 为 CQ、ring_bytes 为
// 整块长度。local_qid 为 Function 内队列号（标准 virtio 即 queue_id）。
typedef struct {
    int unsigned     host_id;
    bit [15:0]       bdf;
    int unsigned     queue_id;
    int unsigned     queue_size;
    virtqueue_type_e vq_type;
    bit [63:0]       desc_iova;
    bit [63:0]       driver_iova;
    bit [63:0]       device_iova;
    int unsigned     ring_bytes;
    int unsigned     msix_vector;
    int unsigned     local_qid;
    int unsigned     rx_buf_size;
    bit              tx_mode;
    int unsigned     notify_bar;
    bit [31:0]       notify_offset;
} virtio_queue_program_t;

// 全零的队列编程参数（环类型取 VQ_SPLIT）；避免对含枚举成员的结构使用 '{default:0}。
function automatic virtio_queue_program_t virtio_empty_queue_program();
    virtio_queue_program_t qprog;

    qprog.host_id       = 0;
    qprog.bdf           = '0;
    qprog.queue_id      = 0;
    qprog.queue_size    = 0;
    qprog.vq_type       = VQ_SPLIT;
    qprog.desc_iova     = '0;
    qprog.driver_iova   = '0;
    qprog.device_iova   = '0;
    qprog.ring_bytes    = 0;
    qprog.msix_vector   = 0;
    qprog.local_qid     = 0;
    qprog.rx_buf_size   = 0;
    qprog.tx_mode       = 0;
    qprog.notify_bar    = 0;
    qprog.notify_offset = '0;
    return qprog;
endfunction

virtual class virtio_config_backend extends uvm_object;
    // 当前绑定的 Function transport（借用）；ops 每次取后端时重新绑定。
    protected virtio_pci_transport transport;

    // 构造不访问设备；transport 由 bind_transport 注入。
    function new(string name = "virtio_config_backend");
        super.new(name);
        transport = null;
    endfunction

    // 绑定执行配置的 Function；只保存引用，不发起访问。
    function void bind_transport(virtio_pci_transport transport_ref);
        transport = transport_ref;
    endfunction

    // 返回当前绑定的 transport，供诊断与测试。
    function virtio_pci_transport bound_transport();
        return transport;
    endfunction

    // Function 级复位；ok=1 表示设备已确认停止全部 DMA。
    pure virtual task reset(output bit ok);
    // 设备 status 读/写（标准 virtio 生命周期）。
    pure virtual task read_status(output bit [7:0] status);
    pure virtual task write_status(bit [7:0] status);
    // 设备特性读取与驱动特性写入。
    pure virtual task read_device_features(output bit [63:0] features);
    pure virtual task write_driver_features(bit [63:0] features);
    // 完整协商：与设备能力取交集并写回，accepted 为最终生效的特性。
    pure virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
    // 查询指定队列的设备最大深度；0 表示队列不可用。
    pure virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
    // 编程一条队列（地址、深度、向量、环类型）。
    pure virtual task configure_queue(virtio_queue_program_t q, output bit ok);
    // 允许设备开始访问已编程的队列。
    pure virtual task enable_queue(virtio_queue_program_t q, output bit ok);
    // 停止队列并等待其 DMA 排空。
    pure virtual task disable_queue(virtio_queue_program_t q, output bit ok);
    // 单队列复位（virtio 1.2 Q_RESET 语义）。
    pure virtual task reset_queue(int unsigned queue_id, output bit ok);
    // 为 queue_ids 中的每条队列（升序的实际队列号）与 config change 建立 MSI-X
    // （或回退 INTx）。队列号可以不连续（control VQ 位于 2*max_virtqueue_pairs）。
    pure virtual task set_msix(int unsigned queue_ids[$], output bit ok);
    // 屏蔽全部 MSI-X 向量。
    pure virtual task clear_msix(output bit ok);
endclass

// 标准 virtio-pci common-config 后端：逐字保留 atomic ops 在 HEAD 中的寄存器序列。
class virtio_common_cfg_backend extends virtio_config_backend;
    `uvm_object_utils(virtio_common_cfg_backend)

    // 构造不访问设备。
    function new(string name = "virtio_common_cfg_backend");
        super.new(name);
    endfunction

    // 写 status=0 并轮询回读 0；超时由 transport 报告。
    virtual task reset(output bit ok);
        bit reset_complete;

        transport.reset_device_verified(reset_complete);
        ok = reset_complete;
    endtask

    virtual task read_status(output bit [7:0] status);
        bit [7:0] value;

        transport.read_device_status(value);
        status = value;
    endtask

    virtual task write_status(bit [7:0] status);
        transport.write_device_status(status);
    endtask

    virtual task read_device_features(output bit [63:0] features);
        bit [63:0] value;

        transport.read_device_features(value);
        features = value;
    endtask

    virtual task write_driver_features(bit [63:0] features);
        transport.write_driver_features(features);
    endtask

    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        bit [63:0] value;

        transport.negotiate_features(driver_caps, value);
        accepted = value;
    endtask

    // Q_SELECT 后读 Q_SIZE。
    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        int unsigned value;

        transport.select_queue(queue_id);
        transport.read_queue_num_max(value);
        max_size = value;
    endtask

    // setup_single_queue 写大小/三个地址/向量/notify_off 并在末尾置 Q_ENABLE=1。
    virtual task configure_queue(virtio_queue_program_t q, output bit ok);
        transport.setup_single_queue(q.queue_id, q.queue_size,
                                     q.desc_iova, q.driver_iova, q.device_iova,
                                     q.msix_vector);
        ok = 1;
    endtask

    // common-config 的使能已在 configure_queue 末尾完成，这里不再发 TLP。
    virtual task enable_queue(virtio_queue_program_t q, output bit ok);
        ok = 1;
    endtask

    // Q_SELECT 后写 Q_ENABLE=0；标准设备无停止确认，按已停止处理。
    virtual task disable_queue(virtio_queue_program_t q, output bit ok);
        transport.select_queue(q.queue_id);
        transport.write_queue_enable(0);
        ok = 1;
    endtask

    // 写 Q_RESET 并轮询完成；超时由 transport 报告（与 HEAD 的无返回包装一致）。
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        transport.write_queue_reset(queue_id);
        ok = 1;
    endtask

    // 有 MSI-X capability 时建表、分配向量并绑定 config/队列向量；否则回退 INTx。
    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        interrupt_mode_e actual_mode;

        if (transport.cap_mgr.has_msix()) begin
            transport.notify_mgr.setup_msix(
                transport.cap_mgr.get_msix_table_size(),
                transport.cap_mgr.msix_table_bir,
                transport.cap_mgr.msix_table_offset
            );
            transport.notify_mgr.allocate_irq_vectors(queue_ids.size(), actual_mode);
            transport.notify_mgr.remap_queue_vectors(queue_ids);

            // Bind config change vector
            transport.write_config_msix_vector(transport.notify_mgr.config_vector);

            // Bind per-queue vectors：只写实际存在的队列号（control VQ 可不连续）
            foreach (queue_ids[i]) begin
                transport.write_queue_msix_vector(
                    queue_ids[i], transport.notify_mgr.queue_vectors[queue_ids[i]]);
            end

            // Unmask all vectors
            transport.notify_mgr.unmask_all();
        end else begin
            transport.notify_mgr.irq_mode = IRQ_INTX;
            transport.notify_mgr.intx_enabled = 1;
        end
        ok = 1;
    endtask

    virtual task clear_msix(output bit ok);
        transport.notify_mgr.mask_all();
        ok = 1;
    endtask
endclass

`endif // VIRTIO_CONFIG_BACKEND_SV
