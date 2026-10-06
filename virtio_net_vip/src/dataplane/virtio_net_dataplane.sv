`ifndef VIRTIO_NET_DATAPLANE_SV
`define VIRTIO_NET_DATAPLANE_SV

// ============================================================================
// virtio_net_dataplane
//
// Top-level dataplane wrapper that aggregates TX engine, RX engine and
// offload engine into a single manageable unit.
//
// Provides a unified configure() entry point that wires sub-component
// references (virtqueue_manager, host_mem_manager, IOMMU, etc.) and
// propagates negotiated features, MTU, and buffer parameters.
//
// Depends on:
//   - virtio_tx_engine (packet transmission)
//   - virtio_rx_engine (packet reception)
//   - virtio_offload_engine (checksum, GSO, RSS offloads)
//   - virtqueue_manager, host_mem_manager, virtio_iommu_model
// ============================================================================

class virtio_net_dataplane extends uvm_object;
    `uvm_object_utils(virtio_net_dataplane)

    // ===== Sub-components =====
    virtio_tx_engine          tx_engine;
    virtio_rx_engine          rx_engine;
    virtio_offload_engine     offload;

    // ===== Configuration =====
    bit [63:0]       negotiated_features;
    int unsigned     mtu = 1500;
    int unsigned     mss = 1460;
    rx_buf_mode_e    rx_buf_mode = RX_MODE_MERGEABLE;
    int unsigned     rx_buf_size = 1526;
    int unsigned     rx_refill_threshold = 16;

    // 构造函数：创建下属 TX/RX/offload 三个子引擎；
    // 特性与队列引用由外部在初始化阶段注入。
    function new(string name = "virtio_net_dataplane");
        super.new(name);
        tx_engine    = virtio_tx_engine::type_id::create("tx_engine");
        rx_engine    = virtio_rx_engine::type_id::create("rx_engine");
        offload      = virtio_offload_engine::type_id::create("offload");
    endfunction

    // ========================================================================
    // configure -- Wire all sub-components with shared resources
    // ========================================================================
    virtual function void configure(
        bit [63:0]          features,
        int unsigned        mtu_val,
        int unsigned        mss_val,
        rx_buf_mode_e       rx_mode,
        int unsigned        rx_buf_sz,
        int unsigned        rx_refill_thresh,
        virtqueue_manager   vq_mgr,
        host_mem_manager    hmem,
        virtio_iommu_model  iommu_mdl,
        bit [15:0]          device_bdf,
        int unsigned        device_host_id = 0
    );
        negotiated_features = features;
        mtu = mtu_val;
        mss = mss_val;
        rx_buf_mode = rx_mode;
        rx_buf_size = rx_buf_sz;
        rx_refill_threshold = rx_refill_thresh;

        // Configure offload engine
        offload.negotiated_features = features;
        offload.mtu = mtu_val;
        offload.mss = mss_val;

        // Configure TX engine
        tx_engine.vq_mgr   = vq_mgr;
        tx_engine.mem      = hmem;
        tx_engine.iommu    = iommu_mdl;
        tx_engine.offload  = offload;
        tx_engine.bdf      = device_bdf;
        tx_engine.host_id  = device_host_id;
        tx_engine.negotiated_features = features;
        tx_engine.mtu      = mtu_val;

        // Configure RX engine
        rx_engine.vq_mgr   = vq_mgr;
        rx_engine.mem      = hmem;
        rx_engine.iommu    = iommu_mdl;
        rx_engine.offload  = offload;
        rx_engine.bdf      = device_bdf;
        rx_engine.host_id  = device_host_id;
        rx_engine.negotiated_features = features;
        rx_engine.buf_mode = rx_mode;
        rx_engine.buf_size = rx_buf_sz;
        rx_engine.refill_threshold = rx_refill_thresh;
    endfunction

    // ========================================================================
    // bind_ops -- 绑定规范数据路径
    //
    // 引擎只做 header 构造与统计；DMA、描述符、通知与回收全部委托 ops。ops 由
    // Function 或测试持有，这里只借用；须在首次收发前调用。
    // ========================================================================
    virtual function void bind_ops(virtio_atomic_ops ops);
        tx_engine.ops = ops;
        rx_engine.ops = ops;
    endfunction

    // ========================================================================
    // cleanup_all -- Called during reset / FLR / shutdown
    // ========================================================================
    virtual function void cleanup_all();
        `uvm_info("DATAPLANE", "cleanup_all: performing leak checks and cleanup", UVM_MEDIUM)

        // Leak check on TX engine
        tx_engine.leak_check();

        // Leak check on RX engine
        rx_engine.leak_check();
    endfunction

    // ========================================================================
    // print_stats -- Log statistics from all sub-components
    // ========================================================================
    virtual function void print_stats();
        tx_engine.print_stats();
        rx_engine.print_stats();

        `uvm_info("DATAPLANE", $sformatf(
            "Config: features=0x%016h mtu=%0d mss=%0d rx_mode=%s rx_buf=%0d refill_thresh=%0d",
            negotiated_features, mtu, mss, rx_buf_mode.name(),
            rx_buf_size, rx_refill_threshold), UVM_LOW)
    endfunction

endclass : virtio_net_dataplane

`endif // VIRTIO_NET_DATAPLANE_SV
