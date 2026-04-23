`ifndef VIRTIO_IOMMU_FAULT_SEQ_SV
`define VIRTIO_IOMMU_FAULT_SEQ_SV

class virtio_iommu_fault_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_iommu_fault_seq)

    rand iommu_fault_e       fault_type;
    rand iommu_fault_phase_e fault_phase;

    function new(string name = "virtio_iommu_fault_seq");
        super.new(name);
    endfunction

    virtual task body();
        virtio_transaction req;

        negotiated_features[VIRTIO_F_ACCESS_PLATFORM] = 1'b1;
        do_init();
        send_txn(VIO_TXN_START_DP);

        `uvm_info(get_type_name(), $sformatf(
            "IOMMU fault: type=%s phase=%s",
            fault_type.name(), fault_phase.name()), UVM_MEDIUM)

        // Inject IOMMU fault rule
        req = virtio_transaction::type_id::create("req");
        req.txn_type      = VIO_TXN_INJECT_ERROR;
        req.vq_error_type = (fault_phase == FAULT_PHASE_DESC_READ)
                            ? VQ_ERR_IOMMU_FAULT_ON_DESC
                            : VQ_ERR_IOMMU_FAULT_ON_DATA;
        req.queue_id      = 0;
        send_configured_txn(req);

        // Trigger DMA operation
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_fault");
            tx_s.num_packets         = 1;
            tx_s.queue_id            = 0;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), "IOMMU fault injection complete", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_IOMMU_FAULT_SEQ_SV
