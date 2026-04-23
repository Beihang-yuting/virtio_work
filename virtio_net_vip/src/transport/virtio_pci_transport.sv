// ============================================================================
// virtio_pci_transport.sv
//
// Top-level PCI transport wrapper that encapsulates:
//   - virtio_pci_cap_manager:       PCI capability discovery
//   - virtio_bar_accessor:          BAR MMIO register access via PCIe TLPs
//   - virtio_notification_manager:  MSI-X / INTx / polling interrupt control
//   - virtio_wait_policy:           Timeout and polling configuration
//
// Provides:
//   - Complete device initialization sequence (virtio spec Section 7.2)
//   - Device status read/write with polling
//   - 64-bit feature negotiation (two-phase select+read)
//   - Queue configuration (select, size, addresses, enable, reset)
//   - Config generation atomic read
//   - Kick with optional NOTIFICATION_DATA support
//   - MSI-X vector binding
//   - Error injection for status, feature, and queue setup errors
//
// Per virtio spec Section 4.1 (PCI Transport)
// ============================================================================

`ifndef VIRTIO_PCI_TRANSPORT_SV
`define VIRTIO_PCI_TRANSPORT_SV

class virtio_pci_transport extends uvm_object;
    `uvm_object_utils(virtio_pci_transport)

    // ===== Sub-components =====
    virtio_pci_cap_manager       cap_mgr;
    virtio_bar_accessor          bar;
    virtio_notification_manager  notify_mgr;
    virtio_wait_policy           wait_pol;

    // ===== Identity =====
    bit [15:0]    bdf;
    bit           is_vf = 0;
    int unsigned  vf_index = 0;

    // ===== Device info (populated after discovery) =====
    int unsigned  num_queues;
    int unsigned  queue_notify_off[];    // per-queue notify offset (read from device)
    bit [63:0]    device_features;
    bit [63:0]    driver_features;
    bit           notification_data_enable = 0;
    bit [7:0]     current_status = DEV_STATUS_RESET;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_pci_transport");
        super.new(name);
        cap_mgr    = virtio_pci_cap_manager::type_id::create("cap_mgr");
        bar        = virtio_bar_accessor::type_id::create("bar");
        notify_mgr = virtio_notification_manager::type_id::create("notify_mgr");
        wait_pol   = virtio_wait_policy::type_id::create("wait_pol");

        // Cross-wire references
        cap_mgr.bar_ref    = bar;
        notify_mgr.bar     = bar;

        num_queues      = 0;
        device_features = '0;
        driver_features = '0;
        bdf             = 16'h0;
    endfunction

    // ========================================================================
    // Helper: read from common config register
    // ========================================================================

    protected task cc_read(bit [31:0] offset, int unsigned size, ref bit [31:0] data);
        bar.read_reg(cap_mgr.get_common_cfg_bar(),
                     cap_mgr.get_common_cfg_bar_offset() + offset,
                     size, data);
    endtask

    // ========================================================================
    // Helper: write to common config register
    // ========================================================================

    protected task cc_write(bit [31:0] offset, int unsigned size, bit [31:0] data);
        bar.write_reg(cap_mgr.get_common_cfg_bar(),
                      cap_mgr.get_common_cfg_bar_offset() + offset,
                      size, data);
    endtask

    // ========================================================================
    // Device Status (with poll via wait_policy)
    // ========================================================================

    virtual task read_device_status(ref bit [7:0] status);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_STATUS, 1, data);
        status = data[7:0];
    endtask

    virtual task write_device_status(bit [7:0] status);
        cc_write(VIRTIO_PCI_COMMON_STATUS, 1, {24'h0, status});
        current_status = status;

        `uvm_info("TRANSPORT",
            $sformatf("Device status written: 0x%02h", status), UVM_HIGH)
    endtask

    // ========================================================================
    // reset_device
    //
    // Write status=0, then poll until status reads back as 0.
    // Uses wait_policy: loop reading status register with poll interval.
    // Timeout: wait_pol.reset_timeout_ns
    // ========================================================================

    virtual task reset_device();
        bit [31:0] read_val;
        bit success = 0;
        int unsigned elapsed = 0;
        int unsigned eff_timeout = wait_pol.effective_timeout(wait_pol.reset_timeout_ns);
        int unsigned interval = wait_pol.default_poll_interval_ns;
        int unsigned attempts = 0;
        int unsigned max_att = eff_timeout / ((interval > 0) ? interval : 1) + 1;

        if (max_att > wait_pol.max_poll_attempts)
            max_att = wait_pol.max_poll_attempts;

        // Write 0 to trigger reset
        cc_write(VIRTIO_PCI_COMMON_STATUS, 1, 32'h0);
        current_status = DEV_STATUS_RESET;

        // Poll until status reads 0
        while (attempts < max_att) begin
            cc_read(VIRTIO_PCI_COMMON_STATUS, 1, read_val);
            if (read_val[7:0] == 8'h0) begin
                success = 1;
                break;
            end
            #(interval * 1ns);
            elapsed += interval;
            attempts++;
        end

        if (!success)
            `uvm_error("TRANSPORT",
                $sformatf("Device reset timeout after %0dns", elapsed))
        else
            `uvm_info("TRANSPORT", "Device reset complete", UVM_HIGH)
    endtask

    // ========================================================================
    // Feature Negotiation (64-bit, two-phase select+read)
    // ========================================================================

    virtual task read_device_features(ref bit [63:0] features);
        bit [31:0] lo, hi;

        // Select low 32 bits (select=0)
        cc_write(VIRTIO_PCI_COMMON_DFSELECT, 4, 32'h0);
        cc_read(VIRTIO_PCI_COMMON_DF, 4, lo);

        // Select high 32 bits (select=1)
        cc_write(VIRTIO_PCI_COMMON_DFSELECT, 4, 32'h1);
        cc_read(VIRTIO_PCI_COMMON_DF, 4, hi);

        features = {hi, lo};

        `uvm_info("TRANSPORT",
            $sformatf("Device features read: 0x%016h", features), UVM_MEDIUM)
    endtask

    virtual task write_driver_features(bit [63:0] features);
        // Select low 32 bits (select=0)
        cc_write(VIRTIO_PCI_COMMON_GFSELECT, 4, 32'h0);
        cc_write(VIRTIO_PCI_COMMON_GF, 4, features[31:0]);

        // Select high 32 bits (select=1)
        cc_write(VIRTIO_PCI_COMMON_GFSELECT, 4, 32'h1);
        cc_write(VIRTIO_PCI_COMMON_GF, 4, features[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Driver features written: 0x%016h", features), UVM_MEDIUM)
    endtask

    virtual task negotiate_features(bit [63:0] driver_supported, ref bit [63:0] negotiated);
        bit [63:0] dev_feat;

        read_device_features(dev_feat);
        device_features = dev_feat;

        negotiated      = dev_feat & driver_supported;
        driver_features = negotiated;

        // Check for NOTIFICATION_DATA feature
        notification_data_enable = negotiated[VIRTIO_F_NOTIFICATION_DATA];

        write_driver_features(negotiated);

        `uvm_info("TRANSPORT",
            $sformatf("Feature negotiation: device=0x%016h driver_supported=0x%016h negotiated=0x%016h",
                      dev_feat, driver_supported, negotiated), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Config Generation Check
    // ========================================================================

    virtual task read_config_generation(ref bit [7:0] gen);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_CFGGENERATION, 1, data);
        gen = data[7:0];
    endtask

    // ========================================================================
    // read_net_config_atomic
    //
    // Atomically reads the device-specific net config by bracketing the read
    // with config generation checks. Retries if the generation changed.
    // ========================================================================

    virtual task read_net_config_atomic(ref virtio_net_device_config_t cfg);
        bit [7:0]  gen_before, gen_after;
        bit [31:0] data;
        int unsigned retry_count = 0;
        int unsigned max_retries = 16;
        int unsigned dev_cfg_bar;
        bit [31:0]  dev_cfg_off;

        dev_cfg_bar = cap_mgr.get_device_cfg_bar();
        dev_cfg_off = cap_mgr.get_device_cfg_bar_offset();

        forever begin
            if (retry_count >= max_retries) begin
                `uvm_error("TRANSPORT",
                    $sformatf("read_net_config_atomic: exceeded %0d retries", max_retries))
                return;
            end

            // Read generation before
            read_config_generation(gen_before);

            // Read MAC address (6 bytes: 4 + 2)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h00, 4, data);
            cfg.mac[47:16] = {data[7:0], data[15:8], data[23:16], data[31:24]};
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h04, 2, data);
            cfg.mac[15:0] = {data[7:0], data[15:8]};

            // Read status (2 bytes at offset 6)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h06, 2, data);
            cfg.status = data[15:0];

            // Read max_virtqueue_pairs (2 bytes at offset 8)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h08, 2, data);
            cfg.max_virtqueue_pairs = data[15:0];

            // Read MTU (2 bytes at offset 10)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h0A, 2, data);
            cfg.mtu = data[15:0];

            // Read speed (4 bytes at offset 12)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h0C, 4, data);
            cfg.speed = data;

            // Read duplex (1 byte at offset 16)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h10, 1, data);
            cfg.duplex = data[7:0];

            // Read rss_max_key_size (1 byte at offset 17)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h11, 1, data);
            cfg.rss_max_key_size = data[7:0];

            // Read rss_max_indirection_table_length (2 bytes at offset 18)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h12, 2, data);
            cfg.rss_max_indirection_table_length = data[15:0];

            // Read supported_hash_types (4 bytes at offset 20)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h14, 4, data);
            cfg.supported_hash_types = data;

            // Read generation after
            read_config_generation(gen_after);

            if (gen_before == gen_after) begin
                `uvm_info("TRANSPORT",
                    $sformatf("Net config read atomically (gen=%0d)", gen_before),
                    UVM_HIGH)
                return;
            end

            retry_count++;
            `uvm_info("TRANSPORT",
                $sformatf("Config generation changed (%0d -> %0d), retrying (%0d)",
                          gen_before, gen_after, retry_count), UVM_MEDIUM)
        end
    endtask

    // ========================================================================
    // Queue Configuration
    // ========================================================================

    virtual task select_queue(int unsigned queue_id);
        cc_write(VIRTIO_PCI_COMMON_Q_SELECT, 2, queue_id);

        `uvm_info("TRANSPORT",
            $sformatf("Queue selected: %0d", queue_id), UVM_HIGH)
    endtask

    virtual task read_queue_num_max(ref int unsigned max_size);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_Q_SIZE, 2, data);
        max_size = data[15:0];

        `uvm_info("TRANSPORT",
            $sformatf("Queue num_max: %0d", max_size), UVM_HIGH)
    endtask

    virtual task write_queue_size(int unsigned size);
        cc_write(VIRTIO_PCI_COMMON_Q_SIZE, 2, size[15:0]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue size written: %0d", size), UVM_HIGH)
    endtask

    virtual task read_queue_notify_off(ref int unsigned off);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_Q_NOFF, 2, data);
        off = data[15:0];

        `uvm_info("TRANSPORT",
            $sformatf("Queue notify_off: %0d", off), UVM_HIGH)
    endtask

    virtual task write_queue_desc_addr(bit [63:0] addr);
        cc_write(VIRTIO_PCI_COMMON_Q_DESCLO, 4, addr[31:0]);
        cc_write(VIRTIO_PCI_COMMON_Q_DESCHI, 4, addr[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue desc addr: 0x%016h", addr), UVM_HIGH)
    endtask

    virtual task write_queue_driver_addr(bit [63:0] addr);
        cc_write(VIRTIO_PCI_COMMON_Q_AVAILLO, 4, addr[31:0]);
        cc_write(VIRTIO_PCI_COMMON_Q_AVAILHI, 4, addr[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue driver (avail) addr: 0x%016h", addr), UVM_HIGH)
    endtask

    virtual task write_queue_device_addr(bit [63:0] addr);
        cc_write(VIRTIO_PCI_COMMON_Q_USEDLO, 4, addr[31:0]);
        cc_write(VIRTIO_PCI_COMMON_Q_USEDHI, 4, addr[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue device (used) addr: 0x%016h", addr), UVM_HIGH)
    endtask

    virtual task write_queue_enable(bit enable);
        cc_write(VIRTIO_PCI_COMMON_Q_ENABLE, 2, {31'h0, enable});

        `uvm_info("TRANSPORT",
            $sformatf("Queue enable: %0b", enable), UVM_HIGH)
    endtask

    virtual task read_queue_enable(ref bit enable);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_Q_ENABLE, 2, data);
        enable = data[0];
    endtask

    virtual task read_num_queues(ref int unsigned num);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_NUMQ, 2, data);
        num = data[15:0];

        `uvm_info("TRANSPORT",
            $sformatf("num_queues: %0d", num), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Queue Reset (virtio 1.2+)
    //
    // Select queue, write 1 to Q_RESET, then poll until Q_RESET reads back 0.
    // ========================================================================

    virtual task write_queue_reset(int unsigned queue_id);
        bit [31:0] read_val;
        bit success = 0;
        int unsigned elapsed = 0;
        int unsigned eff_timeout = wait_pol.effective_timeout(wait_pol.queue_reset_timeout_ns);
        int unsigned interval = wait_pol.default_poll_interval_ns;
        int unsigned attempts = 0;
        int unsigned max_att = eff_timeout / ((interval > 0) ? interval : 1) + 1;

        if (max_att > wait_pol.max_poll_attempts)
            max_att = wait_pol.max_poll_attempts;

        // Select queue and write reset
        select_queue(queue_id);
        cc_write(VIRTIO_PCI_COMMON_Q_RESET, 2, 32'h1);

        `uvm_info("TRANSPORT",
            $sformatf("Queue %0d reset initiated", queue_id), UVM_MEDIUM)

        // Poll until Q_RESET reads back 0
        while (attempts < max_att) begin
            cc_read(VIRTIO_PCI_COMMON_Q_RESET, 2, read_val);
            if (read_val[15:0] == 16'h0) begin
                success = 1;
                break;
            end
            #(interval * 1ns);
            elapsed += interval;
            attempts++;
        end

        if (!success)
            `uvm_error("TRANSPORT",
                $sformatf("Queue %0d reset timeout after %0dns", queue_id, elapsed))
        else
            `uvm_info("TRANSPORT",
                $sformatf("Queue %0d reset complete", queue_id), UVM_HIGH)
    endtask

    // ========================================================================
    // MSI-X Vector Binding
    // ========================================================================

    virtual task write_config_msix_vector(int unsigned vector);
        cc_write(VIRTIO_PCI_COMMON_MSIX, 2, vector[15:0]);

        `uvm_info("TRANSPORT",
            $sformatf("Config MSI-X vector: %0d", vector), UVM_HIGH)
    endtask

    virtual task write_queue_msix_vector(int unsigned queue_id, int unsigned vector);
        select_queue(queue_id);
        cc_write(VIRTIO_PCI_COMMON_Q_MSIX, 2, vector[15:0]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue %0d MSI-X vector: %0d", queue_id, vector), UVM_HIGH)
    endtask

    // ========================================================================
    // Device Config (with generation check)
    // ========================================================================

    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        read_net_config_atomic(cfg);
    endtask

    // ========================================================================
    // kick
    //
    // Notifies the device that new buffers are available in the specified queue.
    //
    // If NOTIFICATION_DATA is enabled:
    //   For split virtqueue: data = {next_avail_idx[15:0], queue_id[15:0]}
    //   For packed virtqueue: data = {wrap_counter, next_avail_idx[14:0], queue_id[15:0]}
    //   Write 32-bit data to notify offset.
    // Else:
    //   Write queue_id (16-bit) to notify offset.
    //
    // Notify offset = cap_mgr.get_notify_bar_offset(queue_notify_off[queue_id])
    // ========================================================================

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx, bit wrap_counter);
        bit [31:0] notify_data;
        bit [63:0] notify_offset;
        int unsigned notify_bar;
        bit is_packed;

        if (queue_id >= queue_notify_off.size()) begin
            `uvm_error("TRANSPORT",
                $sformatf("kick: queue_id %0d out of range (max %0d)",
                          queue_id, queue_notify_off.size() - 1))
            return;
        end

        notify_bar    = cap_mgr.get_notify_bar();
        notify_offset = cap_mgr.get_notify_bar_offset(queue_notify_off[queue_id]);

        if (notification_data_enable) begin
            is_packed = driver_features[VIRTIO_F_RING_PACKED];
            if (is_packed) begin
                // Packed: {wrap_counter[31], next_avail_idx[30:16], queue_id[15:0]}
                notify_data = {wrap_counter, next_avail_idx[14:0], queue_id[15:0]};
            end else begin
                // Split: {next_avail_idx[31:16], queue_id[15:0]}
                notify_data = {next_avail_idx[15:0], queue_id[15:0]};
            end
            bar.write_reg(notify_bar, notify_offset[31:0], 4, notify_data);

            `uvm_info("TRANSPORT",
                $sformatf("kick: queue=%0d notify_data=0x%08h (NOTIFICATION_DATA)",
                          queue_id, notify_data), UVM_HIGH)
        end else begin
            bar.write_reg(notify_bar, notify_offset[31:0], 2, {16'h0, queue_id[15:0]});

            `uvm_info("TRANSPORT",
                $sformatf("kick: queue=%0d (standard)", queue_id), UVM_HIGH)
        end
    endtask

    // ========================================================================
    // full_init_sequence
    //
    // Per virtio spec Section 7.2, steps 1-9:
    //   1. reset_device()
    //   2. write_device_status(ACKNOWLEDGE)
    //   3. write_device_status(current_status | DRIVER)
    //   4. negotiate_features()
    //   5. write_device_status(current_status | FEATURES_OK)
    //      -> poll to confirm FEATURES_OK still set
    //      -> if not set: write FAILED, init_success=0, return
    //   6. read_num_queues(), validate num_queue_pairs fits
    //   7. Per queue (2*num_queue_pairs + 1):
    //      select_queue -> read_queue_num_max ->
    //      read_queue_notify_off -> store in queue_notify_off[]
    //   8. Setup MSI-X via notify_mgr
    //   9. write_device_status(current_status | DRIVER_OK)
    //
    // Note: This method does NOT allocate rings or write ring addresses.
    // The caller handles ring allocation separately via setup_single_queue().
    // ========================================================================

    virtual task full_init_sequence(
        bit [63:0]    driver_supported_features,
        int unsigned  num_queue_pairs,
        ref bit       init_success
    );
        bit [63:0]    negotiated;
        bit [7:0]     status_readback;
        int unsigned  dev_num_queues;
        int unsigned  total_queues;
        int unsigned  q_max;
        int unsigned  q_noff;
        interrupt_mode_e actual_irq_mode;

        init_success = 0;

        `uvm_info("TRANSPORT",
            $sformatf("Starting full init sequence: features=0x%016h, queue_pairs=%0d",
                      driver_supported_features, num_queue_pairs), UVM_LOW)

        // Step 1: Reset
        reset_device();

        // Step 2: Acknowledge
        current_status = DEV_STATUS_ACKNOWLEDGE;
        write_device_status(current_status);

        // Step 3: Driver
        current_status = current_status | DEV_STATUS_DRIVER;
        write_device_status(current_status);

        // Step 4: Feature negotiation
        negotiate_features(driver_supported_features, negotiated);

        // Step 5: Features OK
        current_status = current_status | DEV_STATUS_FEATURES_OK;
        write_device_status(current_status);

        // Poll to confirm FEATURES_OK is still set
        read_device_status(status_readback);
        if (!(status_readback & DEV_STATUS_FEATURES_OK)) begin
            `uvm_error("TRANSPORT",
                "Device rejected features: FEATURES_OK not set after write")
            current_status = current_status | DEV_STATUS_FAILED;
            write_device_status(current_status);
            return;
        end
        current_status = status_readback;

        // Step 6: Read num_queues, validate
        read_num_queues(dev_num_queues);
        num_queues = dev_num_queues;

        // Total queues = 2 * num_queue_pairs (rx+tx) + 1 (control VQ if CTRL_VQ)
        total_queues = 2 * num_queue_pairs;
        if (negotiated[VIRTIO_NET_F_CTRL_VQ])
            total_queues = total_queues + 1;

        if (total_queues > dev_num_queues) begin
            `uvm_error("TRANSPORT",
                $sformatf("Requested %0d queues but device supports only %0d",
                          total_queues, dev_num_queues))
            current_status = current_status | DEV_STATUS_FAILED;
            write_device_status(current_status);
            return;
        end

        // Step 7: Per-queue discovery (read max size and notify offset)
        queue_notify_off = new[total_queues];

        for (int q = 0; q < total_queues; q++) begin
            select_queue(q);

            // Read max queue size (device advertised)
            read_queue_num_max(q_max);
            if (q_max == 0) begin
                `uvm_warning("TRANSPORT",
                    $sformatf("Queue %0d reports max_size=0 (not available)", q))
            end

            // Read queue notify offset
            read_queue_notify_off(q_noff);
            queue_notify_off[q] = q_noff;

            `uvm_info("TRANSPORT",
                $sformatf("Queue %0d discovery: max_size=%0d, notify_off=%0d",
                          q, q_max, q_noff), UVM_MEDIUM)
        end

        // Step 8: Setup MSI-X via notification manager
        if (cap_mgr.has_msix()) begin
            notify_mgr.setup_msix(cap_mgr.get_msix_table_size(),
                                  cap_mgr.msix_table_bir,
                                  cap_mgr.msix_table_offset);
            notify_mgr.allocate_irq_vectors(total_queues, actual_irq_mode);

            // Bind config change vector
            write_config_msix_vector(notify_mgr.config_vector);

            // Bind per-queue vectors
            for (int q = 0; q < total_queues; q++) begin
                write_queue_msix_vector(q, notify_mgr.queue_vectors[q]);
            end

            // Unmask all vectors after binding
            notify_mgr.unmask_all();
        end else begin
            `uvm_info("TRANSPORT",
                "MSI-X not available; using INTx/polling mode", UVM_MEDIUM)
            notify_mgr.irq_mode     = IRQ_INTX;
            notify_mgr.intx_enabled = 1;
        end

        // Step 9: Driver OK
        current_status = current_status | DEV_STATUS_DRIVER_OK;
        write_device_status(current_status);

        init_success = 1;

        `uvm_info("TRANSPORT",
            $sformatf("Full init sequence complete: status=0x%02h, irq_mode=%s, %0d queues",
                      current_status, notify_mgr.irq_mode.name(), total_queues), UVM_LOW)
    endtask

    // ========================================================================
    // setup_single_queue
    //
    // Per-queue setup helper for use after ring allocation:
    //   select_queue -> write_queue_size -> write desc/driver/device addr ->
    //   write_queue_msix_vector -> read_queue_notify_off -> write_queue_enable(1)
    // ========================================================================

    virtual task setup_single_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        bit [63:0]   desc_addr,
        bit [63:0]   driver_addr,
        bit [63:0]   device_addr,
        int unsigned msix_vector
    );
        int unsigned q_noff;

        select_queue(queue_id);
        write_queue_size(queue_size);
        write_queue_desc_addr(desc_addr);
        write_queue_driver_addr(driver_addr);
        write_queue_device_addr(device_addr);

        // Bind MSI-X vector
        cc_write(VIRTIO_PCI_COMMON_Q_MSIX, 2, msix_vector[15:0]);
        notify_mgr.bind_queue_vector(queue_id, msix_vector);

        // Read and store notify offset
        read_queue_notify_off(q_noff);
        if (queue_id < queue_notify_off.size()) begin
            queue_notify_off[queue_id] = q_noff;
        end else begin
            // Expand array if needed
            int unsigned old_size = queue_notify_off.size();
            int unsigned new_size = queue_id + 1;
            int unsigned temp_arr[];
            temp_arr = new[new_size];
            for (int i = 0; i < old_size; i++)
                temp_arr[i] = queue_notify_off[i];
            temp_arr[queue_id] = q_noff;
            queue_notify_off = temp_arr;
        end

        // Enable the queue
        write_queue_enable(1);

        `uvm_info("TRANSPORT",
            $sformatf("Queue %0d setup complete: size=%0d, desc=0x%016h, driver=0x%016h, device=0x%016h, msix=%0d, noff=%0d",
                      queue_id, queue_size, desc_addr, driver_addr, device_addr,
                      msix_vector, q_noff), UVM_MEDIUM)
    endtask

    // ========================================================================
    // discover_and_init_bars
    //
    //   1. bar.enumerate_bars()
    //   2. cap_mgr.bar_ref = bar
    //   3. cap_mgr.discover_capabilities()
    // ========================================================================

    virtual task discover_and_init_bars();
        `uvm_info("TRANSPORT", "Starting BAR discovery and capability enumeration", UVM_MEDIUM)

        // Set BDF on bar accessor
        bar.requester_id = bdf;

        // Step 1: Enumerate BARs
        bar.enumerate_bars();

        // Step 2: Wire bar reference into cap manager
        cap_mgr.bar_ref = bar;

        // Step 3: Discover virtio PCI capabilities
        cap_mgr.discover_capabilities();

        `uvm_info("TRANSPORT", "BAR discovery and capability enumeration complete", UVM_MEDIUM)
    endtask

    // ========================================================================
    // Error Injection
    // ========================================================================

    virtual task inject_status_error(status_error_e err);
        `uvm_info("TRANSPORT",
            $sformatf("Injecting status error: %s", err.name()), UVM_LOW)

        case (err)
            STATUS_ERR_SKIP_ACKNOWLEDGE: begin
                // Write DRIVER without ACKNOWLEDGE
                write_device_status(DEV_STATUS_DRIVER);
            end
            STATUS_ERR_SKIP_DRIVER: begin
                // Write FEATURES_OK without DRIVER
                write_device_status(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_FEATURES_OK);
            end
            STATUS_ERR_SKIP_FEATURES_OK: begin
                // Write DRIVER_OK without FEATURES_OK
                write_device_status(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_DRIVER_OK);
            end
            STATUS_ERR_DRIVER_OK_BEFORE_FEATURES_OK: begin
                // Write DRIVER_OK before FEATURES_OK in normal sequence
                write_device_status(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_DRIVER_OK);
            end
            STATUS_ERR_WRITE_AFTER_FAILED: begin
                // Write status after FAILED has been set
                write_device_status(current_status | DEV_STATUS_FAILED);
                write_device_status(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);
            end
            default: begin
                `uvm_warning("TRANSPORT",
                    $sformatf("Unknown status error type: %s", err.name()))
            end
        endcase
    endtask

    virtual task inject_feature_error(feature_error_e err);
        `uvm_info("TRANSPORT",
            $sformatf("Injecting feature error: %s", err.name()), UVM_LOW)

        case (err)
            FEAT_ERR_PARTIAL_WRITE_LO_ONLY: begin
                // Only write low 32 bits, skip high
                cc_write(VIRTIO_PCI_COMMON_GFSELECT, 4, 32'h0);
                cc_write(VIRTIO_PCI_COMMON_GF, 4, driver_features[31:0]);
                // Deliberately skip select=1 + write high
            end
            FEAT_ERR_PARTIAL_WRITE_HI_ONLY: begin
                // Only write high 32 bits, skip low
                cc_write(VIRTIO_PCI_COMMON_GFSELECT, 4, 32'h1);
                cc_write(VIRTIO_PCI_COMMON_GF, 4, driver_features[63:32]);
                // Deliberately skip select=0 + write low
            end
            FEAT_ERR_WRONG_SELECT_VALUE: begin
                // Write with wrong select value (2 instead of 0 or 1)
                cc_write(VIRTIO_PCI_COMMON_GFSELECT, 4, 32'h2);
                cc_write(VIRTIO_PCI_COMMON_GF, 4, driver_features[31:0]);
            end
            FEAT_ERR_USE_UNNEGOTIATED_FEATURE: begin
                // Write features that include bits not in device_features
                write_driver_features(64'hFFFF_FFFF_FFFF_FFFF);
            end
            FEAT_ERR_CHANGE_AFTER_FEATURES_OK: begin
                // Attempt to change features after FEATURES_OK
                write_driver_features(driver_features ^ 64'h0000_0000_0000_00FF);
            end
            default: begin
                `uvm_warning("TRANSPORT",
                    $sformatf("Unknown feature error type: %s", err.name()))
            end
        endcase
    endtask

    virtual task inject_queue_setup_error(queue_setup_error_e err);
        int unsigned max_sz;

        `uvm_info("TRANSPORT",
            $sformatf("Injecting queue setup error: %s", err.name()), UVM_LOW)

        case (err)
            QSETUP_ERR_ENABLE_BEFORE_ADDR: begin
                // Enable queue without writing addresses first
                select_queue(0);
                write_queue_enable(1);
            end
            QSETUP_ERR_SIZE_EXCEEDS_MAX: begin
                // Write queue size larger than device max
                select_queue(0);
                read_queue_num_max(max_sz);
                write_queue_size(max_sz + 1);
            end
            QSETUP_ERR_SIZE_NOT_POWER_OF_2: begin
                // Write non-power-of-2 queue size
                select_queue(0);
                write_queue_size(17);  // Not a power of 2
            end
            QSETUP_ERR_ADDR_UNALIGNED: begin
                // Write unaligned addresses
                select_queue(0);
                write_queue_desc_addr(64'h0000_0000_0000_0003);  // Not aligned
            end
            QSETUP_ERR_ENABLE_TWICE: begin
                // Enable an already-enabled queue
                select_queue(0);
                write_queue_enable(1);
                write_queue_enable(1);
            end
            QSETUP_ERR_SELECT_OOB_QUEUE: begin
                // Select a queue beyond num_queues
                select_queue(num_queues + 10);
            end
            default: begin
                `uvm_warning("TRANSPORT",
                    $sformatf("Unknown queue setup error type: %s", err.name()))
            end
        endcase
    endtask

endclass : virtio_pci_transport

`endif // VIRTIO_PCI_TRANSPORT_SV
