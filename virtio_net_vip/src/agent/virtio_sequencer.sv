`ifndef VIRTIO_SEQUENCER_SV
`define VIRTIO_SEQUENCER_SV

// ============================================================================
// virtio_sequencer
//
// UVM sequencer parameterized for virtio_transaction items.
// Sequences targeting the virtio driver agent use this sequencer to deliver
// transaction items to the virtio_driver.
// ============================================================================

class virtio_sequencer extends uvm_sequencer #(virtio_transaction);
    `uvm_component_utils(virtio_sequencer)

    // 构造函数：标准 uvm_sequencer 参数化特化，无额外状态。
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

endclass : virtio_sequencer

`endif // VIRTIO_SEQUENCER_SV
