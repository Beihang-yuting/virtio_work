`ifndef VIRTIO_LIVE_MIGRATION_SEQ_SV
`define VIRTIO_LIVE_MIGRATION_SEQ_SV

// Keep migration traffic self-contained: virtio_tx_seq transmits the objects
// present in packet_items, not its num_packets knob.  A concrete packet makes
// the scenario exercise the normal DMA/TX path instead of silently freezing
// an idle queue.
class virtio_live_migration_packet extends uvm_object;
    `uvm_object_utils(virtio_live_migration_packet)

    byte unsigned payload[];

    function new(string name = "virtio_live_migration_packet");
        super.new(name);
    endfunction

    virtual function void do_pack(uvm_packer packer);
        super.do_pack(packer);
        foreach (payload[i])
            packer.pack_field_int(payload[i], 8);
    endfunction
endclass : virtio_live_migration_packet

class virtio_live_migration_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_live_migration_seq)

    rand int unsigned pre_freeze_pkts;
    rand int unsigned post_restore_pkts;

    constraint c_defaults {
        pre_freeze_pkts   inside {[1:16]};
        post_restore_pkts inside {[1:16]};
    }

    function new(string name = "virtio_live_migration_seq");
        super.new(name);
        pre_freeze_pkts   = 4;
        post_restore_pkts = 4;
    endfunction

    protected function void populate_packet_items(
        virtio_tx_seq tx_s,
        int unsigned count,
        string prefix
    );
        tx_s.packet_items.delete();
        for (int unsigned packet_index = 0; packet_index < count; packet_index++) begin
            virtio_live_migration_packet packet;

            packet = virtio_live_migration_packet::type_id::create(
                $sformatf("%s_packet_%0d", prefix, packet_index));
            packet.payload = new[64];
            foreach (packet.payload[byte_index])
                packet.payload[byte_index] = byte'((packet_index + byte_index) & 8'hff);
            tx_s.packet_items.push_back(packet);
        end
    endfunction

    virtual task body();
        virtio_transaction freeze_req;
        virtio_transaction restore_req;
        virtio_tx_seq tx_direct;
        virtio_tx_seq tx_indirect;
        virtio_tx_seq tx_post;
        int unsigned direct_count;
        int unsigned indirect_count;

        // Init and start dataplane
        do_init();
        send_txn(VIO_TXN_START_DP);

        // Inject traffic before migration
        direct_count = (pre_freeze_pkts + 1) / 2;
        indirect_count = pre_freeze_pkts - direct_count;
        tx_direct = virtio_tx_seq::type_id::create("tx_pre_direct");
        tx_direct.num_packets         = direct_count;
        tx_direct.drv_cfg             = drv_cfg;
        tx_direct.negotiated_features = negotiated_features;
        tx_direct.use_indirect        = 0;
        populate_packet_items(tx_direct, direct_count, "pre_direct");
        tx_direct.start(m_sequencer);

        if (indirect_count != 0) begin
            tx_indirect = virtio_tx_seq::type_id::create("tx_pre_indirect");
            tx_indirect.num_packets         = indirect_count;
            tx_indirect.drv_cfg             = drv_cfg;
            tx_indirect.negotiated_features = negotiated_features;
            tx_indirect.use_indirect        = 1;
            populate_packet_items(tx_indirect, indirect_count, "pre_indirect");
            tx_indirect.start(m_sequencer);
        end

        // Freeze device
        `uvm_info(get_type_name(), "Freezing device for migration", UVM_MEDIUM)
        freeze_req = virtio_transaction::type_id::create("freeze_req");
        freeze_req.txn_type = VIO_TXN_FREEZE;
        send_configured_txn(freeze_req);

        // Reset (simulate migration to new host)
        `uvm_info(get_type_name(), "Resetting for restore", UVM_MEDIUM)
        do_reset();

        // Restore
        `uvm_info(get_type_name(), "Restoring device state", UVM_MEDIUM)
        restore_req = virtio_transaction::type_id::create("restore_req");
        restore_req.txn_type = VIO_TXN_RESTORE;
        restore_req.snapshot = freeze_req.snapshot;
        send_configured_txn(restore_req);
        if (!restore_req.success) begin
            `uvm_error(get_type_name(), "Live migration restore rejected saved snapshot")
            return;
        end

        // Verify continued operation
        tx_post = virtio_tx_seq::type_id::create("tx_post");
        tx_post.num_packets         = post_restore_pkts;
        tx_post.drv_cfg             = drv_cfg;
        tx_post.negotiated_features = negotiated_features;
        tx_post.use_indirect        = 0;
        populate_packet_items(tx_post, post_restore_pkts, "post_restore");
        tx_post.start(m_sequencer);

        `uvm_info(get_type_name(), $sformatf(
            "Live migration: pre=%0d post=%0d packets",
            pre_freeze_pkts, post_restore_pkts), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_LIVE_MIGRATION_SEQ_SV
