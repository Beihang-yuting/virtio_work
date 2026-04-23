`ifndef VIRTIO_COVERAGE_SV
`define VIRTIO_COVERAGE_SV

// ============================================================================
// virtio_coverage
//
// 8-covergroup functional coverage collector for virtio-net transactions.
// Receives transactions via uvm_analysis_imp, extracts sampling state, and
// samples enabled covergroups.
//
// Covergroup categories (each independently enable/disable, master switch):
//   1. features      -- negotiated feature combinations
//   2. queue_ops     -- queue types, sizes, depths, operation mix
//   3. dataplane     -- packet sizes, burst lengths, queue utilization
//   4. offload       -- checksum, GSO type, segment size crosses
//   5. notification  -- interrupt modes, coalescing, suppression
//   6. errors        -- error injection types, fault categories
//   7. lifecycle     -- device status transitions, reset types
//   8. sriov         -- VF count, FLR, concurrent VF operations
//
// All covergroups default OFF (cov_enable = 0). Construct all in build_phase
// but only sample when the corresponding enable flag is set.
//
// Supports custom coverage callbacks (virtio_coverage_callback).
//
// Depends on:
//   - virtio_transaction, virtio_coverage_callback
//   - virtio_net_types.sv (all enums and structs)
// ============================================================================

class virtio_coverage extends uvm_component;
    `uvm_component_utils(virtio_coverage)

    // ===== Master + per-group switches (all default OFF) =====
    bit cov_enable              = 0;
    bit cov_feature_enable      = 0;
    bit cov_queue_enable        = 0;
    bit cov_dataplane_enable    = 0;
    bit cov_offload_enable      = 0;
    bit cov_notification_enable = 0;
    bit cov_error_enable        = 0;
    bit cov_lifecycle_enable    = 0;
    bit cov_sriov_enable        = 0;

    // ===== Custom callbacks =====
    virtio_coverage_callback custom_cov_cbs[$];

    // ===== Analysis import =====
    uvm_analysis_imp #(virtio_transaction, virtio_coverage) analysis_imp;

    // ===== Sampling state (set before sampling covergroups) =====
    protected bit [63:0]        sampled_features;
    protected virtqueue_type_e  sampled_vq_type;
    protected int unsigned      sampled_pkt_size;
    protected int unsigned      sampled_outstanding;
    protected int unsigned      sampled_queue_id;
    protected int unsigned      sampled_queue_size;
    protected int unsigned      sampled_burst_len;
    protected bit [7:0]         sampled_gso_type;
    protected bit [15:0]        sampled_gso_size;
    protected bit [7:0]         sampled_hdr_flags;
    protected interrupt_mode_e  sampled_irq_mode;
    protected virtio_txn_type_e sampled_txn_type;
    protected device_status_e   sampled_dev_status;
    protected int unsigned      sampled_vf_count;
    protected virtqueue_error_e sampled_err_type;

    // ===== Covergroups =====

    covergroup cg_features;
        cp_vq_type: coverpoint sampled_vq_type {
            bins split  = {VQ_SPLIT};
            bins packed = {VQ_PACKED};
            bins custom = {VQ_CUSTOM};
        }
        cp_csum: coverpoint sampled_features[VIRTIO_NET_F_CSUM] {
            bins off = {0};
            bins on  = {1};
        }
        cp_mrg_rxbuf: coverpoint sampled_features[VIRTIO_NET_F_MRG_RXBUF] {
            bins off = {0};
            bins on  = {1};
        }
        cp_ctrl_vq: coverpoint sampled_features[VIRTIO_NET_F_CTRL_VQ] {
            bins off = {0};
            bins on  = {1};
        }
        cp_mq: coverpoint sampled_features[VIRTIO_NET_F_MQ] {
            bins off = {0};
            bins on  = {1};
        }
        cp_rss: coverpoint sampled_features[VIRTIO_NET_F_RSS] {
            bins off = {0};
            bins on  = {1};
        }
        cp_packed_ring: coverpoint sampled_features[VIRTIO_F_RING_PACKED] {
            bins off = {0};
            bins on  = {1};
        }
        cp_in_order: coverpoint sampled_features[VIRTIO_F_IN_ORDER] {
            bins off = {0};
            bins on  = {1};
        }
        cp_sriov: coverpoint sampled_features[VIRTIO_F_SR_IOV] {
            bins off = {0};
            bins on  = {1};
        }
        cx_vq_csum: cross cp_vq_type, cp_csum;
        cx_vq_mrg:  cross cp_vq_type, cp_mrg_rxbuf;
    endgroup

    covergroup cg_queue_ops;
        cp_queue_id: coverpoint sampled_queue_id {
            bins low[]  = {[0:3]};
            bins mid    = {[4:15]};
            bins high   = {[16:$]};
        }
        cp_queue_size: coverpoint sampled_queue_size {
            bins tiny   = {[1:32]};
            bins small  = {[33:128]};
            bins medium = {[129:512]};
            bins large  = {[513:1024]};
            bins huge   = {[1025:$]};
        }
        cp_vq_type: coverpoint sampled_vq_type {
            bins split  = {VQ_SPLIT};
            bins packed = {VQ_PACKED};
        }
        cx_qid_type: cross cp_queue_id, cp_vq_type;
    endgroup

    covergroup cg_dataplane;
        cp_pkt_size: coverpoint sampled_pkt_size {
            bins tiny    = {[0:63]};
            bins small   = {[64:127]};
            bins medium  = {[128:511]};
            bins normal  = {[512:1514]};
            bins jumbo   = {[1515:9000]};
            bins huge    = {[9001:$]};
        }
        cp_burst_len: coverpoint sampled_burst_len {
            bins single  = {1};
            bins small   = {[2:8]};
            bins medium  = {[9:32]};
            bins large   = {[33:64]};
            bins huge    = {[65:$]};
        }
        cp_txn_type: coverpoint sampled_txn_type {
            bins send    = {VIO_TXN_SEND_PKTS};
            bins wait_rx = {VIO_TXN_WAIT_PKTS};
            bins ctrl    = {VIO_TXN_CTRL_CMD};
            bins atomic  = {VIO_TXN_ATOMIC_OP};
        }
        cx_size_type: cross cp_pkt_size, cp_txn_type;
    endgroup

    covergroup cg_offload;
        cp_gso_type: coverpoint sampled_gso_type {
            bins none     = {VIRTIO_NET_HDR_GSO_NONE};
            bins tcpv4    = {VIRTIO_NET_HDR_GSO_TCPV4};
            bins udp      = {VIRTIO_NET_HDR_GSO_UDP};
            bins tcpv6    = {VIRTIO_NET_HDR_GSO_TCPV6};
            bins udp_l4   = {VIRTIO_NET_HDR_GSO_UDP_L4};
        }
        cp_gso_size: coverpoint sampled_gso_size {
            bins zero     = {0};
            bins small    = {[1:536]};
            bins normal   = {[537:1460]};
            bins large    = {[1461:$]};
        }
        cp_needs_csum: coverpoint sampled_hdr_flags[0] {
            bins off = {0};
            bins on  = {1};
        }
        cp_data_valid: coverpoint sampled_hdr_flags[1] {
            bins off = {0};
            bins on  = {1};
        }
        cx_gso_csum: cross cp_gso_type, cp_needs_csum;
    endgroup

    covergroup cg_notification;
        cp_irq_mode: coverpoint sampled_irq_mode {
            bins msix_per_q = {IRQ_MSIX_PER_QUEUE};
            bins msix_share = {IRQ_MSIX_SHARED};
            bins intx       = {IRQ_INTX};
            bins polling    = {IRQ_POLLING};
        }
    endgroup

    covergroup cg_errors;
        cp_err_type: coverpoint sampled_err_type {
            bins circ_chain     = {VQ_ERR_CIRCULAR_CHAIN};
            bins oob_index      = {VQ_ERR_OOB_INDEX};
            bins zero_len       = {VQ_ERR_ZERO_LEN_BUF};
            bins kick_before    = {VQ_ERR_KICK_BEFORE_ENABLE};
            bins avail_skip     = {VQ_ERR_AVAIL_IDX_SKIP};
            bins wrong_flags    = {VQ_ERR_WRONG_FLAGS};
            bins ind_in_ind     = {VQ_ERR_INDIRECT_IN_INDIRECT};
            bins skip_wmb       = {VQ_ERR_SKIP_WMB_BEFORE_AVAIL};
            bins skip_rmb       = {VQ_ERR_SKIP_RMB_BEFORE_USED};
            bins skip_mb        = {VQ_ERR_SKIP_MB_BEFORE_KICK};
            bins double_free    = {VQ_ERR_DOUBLE_FREE_DESC};
            bins use_after_free = {VQ_ERR_USE_AFTER_FREE_DESC};
            bins use_after_umap = {VQ_ERR_USE_AFTER_UNMAP};
            bins iommu_desc     = {VQ_ERR_IOMMU_FAULT_ON_DESC};
            bins iommu_data     = {VQ_ERR_IOMMU_FAULT_ON_DATA};
        }
    endgroup

    covergroup cg_lifecycle;
        cp_dev_status: coverpoint sampled_dev_status {
            bins reset     = {DEV_STATUS_RESET};
            bins ack       = {DEV_STATUS_ACKNOWLEDGE};
            bins driver    = {DEV_STATUS_DRIVER};
            bins feat_ok   = {DEV_STATUS_FEATURES_OK};
            bins driver_ok = {DEV_STATUS_DRIVER_OK};
            bins needs_rst = {DEV_STATUS_DEVICE_NEEDS_RESET};
            bins failed    = {DEV_STATUS_FAILED};
        }
        cp_txn_lifecycle: coverpoint sampled_txn_type {
            bins init     = {VIO_TXN_INIT};
            bins reset    = {VIO_TXN_RESET};
            bins shutdown = {VIO_TXN_SHUTDOWN};
            bins freeze   = {VIO_TXN_FREEZE};
            bins restore  = {VIO_TXN_RESTORE};
        }
    endgroup

    covergroup cg_sriov;
        cp_vf_count: coverpoint sampled_vf_count {
            bins none   = {0};
            bins single = {1};
            bins few    = {[2:8]};
            bins many   = {[9:64]};
            bins max    = {[65:$]};
        }
    endgroup

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_features     = new();
        cg_queue_ops    = new();
        cg_dataplane    = new();
        cg_offload      = new();
        cg_notification = new();
        cg_errors       = new();
        cg_lifecycle    = new();
        cg_sriov        = new();
    endfunction

    // ========================================================================
    // Build Phase
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_imp = new("analysis_imp", this);
    endfunction

    // ========================================================================
    // enable_all / disable_all
    // ========================================================================

    function void enable_all();
        cov_enable              = 1;
        cov_feature_enable      = 1;
        cov_queue_enable        = 1;
        cov_dataplane_enable    = 1;
        cov_offload_enable      = 1;
        cov_notification_enable = 1;
        cov_error_enable        = 1;
        cov_lifecycle_enable    = 1;
        cov_sriov_enable        = 1;
    endfunction

    function void disable_all();
        cov_enable              = 0;
        cov_feature_enable      = 0;
        cov_queue_enable        = 0;
        cov_dataplane_enable    = 0;
        cov_offload_enable      = 0;
        cov_notification_enable = 0;
        cov_error_enable        = 0;
        cov_lifecycle_enable    = 0;
        cov_sriov_enable        = 0;
    endfunction

    // ========================================================================
    // register_custom_coverage
    // ========================================================================

    function void register_custom_coverage(virtio_coverage_callback cb);
        custom_cov_cbs.push_back(cb);
    endfunction

    // ========================================================================
    // write -- Analysis port callback
    //
    // Extract sampling state from each transaction and sample enabled
    // covergroups. Also invokes custom coverage callbacks.
    // ========================================================================

    virtual function void write(virtio_transaction txn);
        if (!cov_enable) return;

        // Extract common sampling state
        sampled_txn_type = txn.txn_type;
        sampled_queue_id = txn.queue_id;
        sampled_vq_type  = txn.vq_type;
        sampled_features = txn.features;

        // Extract transaction-specific state
        case (txn.txn_type)
            VIO_TXN_SEND_PKTS: begin
                sampled_burst_len  = txn.packets.size();
                sampled_hdr_flags  = txn.net_hdr.flags;
                sampled_gso_type   = txn.net_hdr.gso_type;
                sampled_gso_size   = txn.net_hdr.gso_size;
            end
            VIO_TXN_WAIT_PKTS: begin
                sampled_burst_len = txn.received_pkts.size();
            end
            VIO_TXN_INIT: begin
                sampled_dev_status = device_status_e'(txn.status_val);
                sampled_queue_size = txn.queue_size;
            end
            VIO_TXN_INJECT_ERROR: begin
                sampled_err_type = txn.vq_error_type;
            end
            VIO_TXN_SETUP_QUEUE: begin
                sampled_queue_size = txn.queue_size;
            end
            default: ;
        endcase

        // Sample enabled covergroups
        if (cov_feature_enable && sampled_features != '0)
            cg_features.sample();

        if (cov_queue_enable)
            cg_queue_ops.sample();

        if (cov_dataplane_enable &&
            (txn.txn_type == VIO_TXN_SEND_PKTS || txn.txn_type == VIO_TXN_WAIT_PKTS))
            cg_dataplane.sample();

        if (cov_offload_enable && txn.txn_type == VIO_TXN_SEND_PKTS)
            cg_offload.sample();

        if (cov_notification_enable)
            cg_notification.sample();

        if (cov_error_enable && txn.txn_type == VIO_TXN_INJECT_ERROR)
            cg_errors.sample();

        if (cov_lifecycle_enable &&
            (txn.txn_type inside {VIO_TXN_INIT, VIO_TXN_RESET, VIO_TXN_SHUTDOWN,
                                   VIO_TXN_FREEZE, VIO_TXN_RESTORE}))
            cg_lifecycle.sample();

        if (cov_sriov_enable)
            cg_sriov.sample();

        // Custom callbacks
        foreach (custom_cov_cbs[i])
            custom_cov_cbs[i].custom_sample(txn);
    endfunction

    // ========================================================================
    // report_phase -- Report coverage percentages
    // ========================================================================

    virtual function void report_phase(uvm_phase phase);
        string report;
        super.report_phase(phase);

        if (!cov_enable) begin
            `uvm_info("COV", "Coverage collection was disabled", UVM_LOW)
            return;
        end

        report = "\n========== Virtio Coverage Report ==========\n";
        if (cov_feature_enable)
            report = {report, $sformatf("  features:     %.1f%%\n", cg_features.get_coverage())};
        if (cov_queue_enable)
            report = {report, $sformatf("  queue_ops:    %.1f%%\n", cg_queue_ops.get_coverage())};
        if (cov_dataplane_enable)
            report = {report, $sformatf("  dataplane:    %.1f%%\n", cg_dataplane.get_coverage())};
        if (cov_offload_enable)
            report = {report, $sformatf("  offload:      %.1f%%\n", cg_offload.get_coverage())};
        if (cov_notification_enable)
            report = {report, $sformatf("  notification: %.1f%%\n", cg_notification.get_coverage())};
        if (cov_error_enable)
            report = {report, $sformatf("  errors:       %.1f%%\n", cg_errors.get_coverage())};
        if (cov_lifecycle_enable)
            report = {report, $sformatf("  lifecycle:    %.1f%%\n", cg_lifecycle.get_coverage())};
        if (cov_sriov_enable)
            report = {report, $sformatf("  sriov:        %.1f%%\n", cg_sriov.get_coverage())};
        report = {report, "============================================="};

        `uvm_info("COV", report, UVM_LOW)
    endfunction

endclass : virtio_coverage

`endif // VIRTIO_COVERAGE_SV
