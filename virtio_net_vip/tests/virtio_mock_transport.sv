`ifndef VIRTIO_MOCK_TRANSPORT_SV
`define VIRTIO_MOCK_TRANSPORT_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// 目录层次：tests。无 PCIe 的 transport 测试替身：记录 kick 次数与最后一次参数；
// 设备状态、net config、设备/队列复位结果可编程；队列编程（setup_single_queue）
// 记录为可查询的寄存器模型。未覆写的方法仍走真实 PCIe 路径（无 sequencer 时
// UVM_FATAL），因此只用于不访问这些寄存器的用例。
class virtio_mock_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_mock_transport)

    int unsigned kick_count;
    int unsigned last_kick_queue_id;
    int unsigned last_kick_next_avail_idx;
    bit          last_kick_wrap_counter;
    int unsigned kicks_per_queue[int unsigned];
    bit [7:0]    mock_status;
    int unsigned device_reset_count;
    bit          device_reset_complete;
    int unsigned queue_reset_count;
    int unsigned last_reset_queue_id;
    bit          queue_reset_complete;
    virtio_net_device_config_t mock_net_config;
    int unsigned net_config_reads;
    int unsigned queue_num_max;
    int unsigned programmed_qids[$];
    bit          programmed_queue_valid[int unsigned];
    bit [63:0]   programmed_queue_desc[int unsigned];
    bit [63:0]   programmed_queue_driver[int unsigned];
    bit [63:0]   programmed_queue_device[int unsigned];
    int unsigned programmed_queue_size[int unsigned];

    // 默认：设备处于 DRIVER_OK，设备复位与队列复位都能完成，net config 报告
    // 1 个队列对，队列最大长度 8。
    function new(string name = "virtio_mock_transport");
        super.new(name);
        kick_count = 0;
        last_kick_queue_id = 0;
        last_kick_next_avail_idx = 0;
        last_kick_wrap_counter = 0;
        mock_status = DEV_STATUS_DRIVER_OK;
        device_reset_count = 0;
        device_reset_complete = 1;
        queue_reset_count = 0;
        last_reset_queue_id = '1;
        queue_reset_complete = 1;
        mock_net_config = '{default: 0};
        mock_net_config.max_virtqueue_pairs = 1;
        net_config_reads = 0;
        queue_num_max = 8;
    endfunction

    // 记录通知而不发 TLP，便于检查生产调用方给出的游标与每个队列的通知次数。
    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
        kick_count++;
        last_kick_queue_id       = queue_id;
        last_kick_next_avail_idx = next_avail_idx;
        last_kick_wrap_counter   = wrap_counter;
        if (!kicks_per_queue.exists(queue_id))
            kicks_per_queue[queue_id] = 0;
        kicks_per_queue[queue_id]++;
    endtask

    // 返回某个队列收到的通知次数；从未通知过返回 0。
    function int unsigned kicks(int unsigned queue_id);
        return kicks_per_queue.exists(queue_id) ? kicks_per_queue[queue_id] : 0;
    endfunction

    // 设备状态读写只作用于 mock_status。
    virtual task read_device_status(ref bit [7:0] status);
        status = mock_status;
    endtask

    virtual task write_device_status(bit [7:0] status);
        mock_status = status;
    endtask

    // 设备复位：计数并返回可编程的完成结果；不改变 mock_status。
    virtual task reset_device_verified(ref bit reset_complete);
        device_reset_count++;
        reset_complete = device_reset_complete;
    endtask

    // 队列复位：计数、记录队列号，返回可编程的完成结果。
    virtual task write_queue_reset_verified(int unsigned queue_id,
                                            ref bit reset_complete);
        queue_reset_count++;
        last_reset_queue_id = queue_id;
        reset_complete = queue_reset_complete;
    endtask

    // 设备配置空间读回 mock_net_config，并计数。
    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        net_config_reads++;
        cfg = mock_net_config;
    endtask

    // 队列寄存器模型：select/enable 不产生访问，num_max 可编程，setup 记录编程值。
    virtual task select_queue(int unsigned queue_id);
    endtask

    virtual task write_queue_enable(bit enable);
    endtask

    virtual task read_queue_num_max(ref int unsigned max_size);
        max_size = queue_num_max;
    endtask

    virtual task setup_single_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        bit [63:0]   desc_addr,
        bit [63:0]   driver_addr,
        bit [63:0]   device_addr,
        int unsigned msix_vector
    );
        programmed_qids.push_back(queue_id);
        programmed_queue_valid[queue_id]  = 1;
        programmed_queue_desc[queue_id]   = desc_addr;
        programmed_queue_driver[queue_id] = driver_addr;
        programmed_queue_device[queue_id] = device_addr;
        programmed_queue_size[queue_id]   = queue_size;
    endtask

    // 返回 setup_single_queue 记录的编程值；该队列未编程时返回 0 且输出清零。
    function bit get_programmed_queue(
        int unsigned queue_id,
        ref bit [63:0] desc_addr,
        ref bit [63:0] driver_addr,
        ref bit [63:0] device_addr,
        ref int unsigned queue_size
    );
        desc_addr = '0;
        driver_addr = '0;
        device_addr = '0;
        queue_size = 0;
        if (!programmed_queue_valid.exists(queue_id) ||
            !programmed_queue_valid[queue_id])
            return 0;
        desc_addr = programmed_queue_desc[queue_id];
        driver_addr = programmed_queue_driver[queue_id];
        device_addr = programmed_queue_device[queue_id];
        queue_size = programmed_queue_size[queue_id];
        return 1;
    endfunction
endclass : virtio_mock_transport

`endif // VIRTIO_MOCK_TRANSPORT_SV
