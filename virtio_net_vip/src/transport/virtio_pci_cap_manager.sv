// ============================================================================
// virtio_pci_cap_manager.sv
//
// Discovers and parses virtio PCI capabilities by traversing the PCI
// configuration space capability linked list. Extracts virtio vendor-specific
// capabilities (common_cfg, notify, ISR, device_cfg, pci_cfg) and MSI-X
// capability information.
//
// Per virtio spec Section 4.1.4
// ============================================================================

`ifndef VIRTIO_PCI_CAP_MANAGER_SV
`define VIRTIO_PCI_CAP_MANAGER_SV

class virtio_pci_cap_manager extends uvm_object;
    `uvm_object_utils(virtio_pci_cap_manager)

    // ========================================================================
    // Discovered virtio capabilities
    // ========================================================================

    virtio_pci_cap_t  common_cfg_cap;       // cfg_type = 1
    virtio_pci_cap_t  notify_cap;           // cfg_type = 2
    virtio_pci_cap_t  isr_cap;              // cfg_type = 3
    virtio_pci_cap_t  device_cfg_cap;       // cfg_type = 4
    virtio_pci_cap_t  pci_cfg_cap;          // cfg_type = 5 (optional)
    int unsigned      notify_off_multiplier;

    // ========================================================================
    // MSI-X capability info
    // ========================================================================

    bit [7:0]         msix_cap_offset;
    int unsigned      msix_table_size;      // number of vectors (table_size + 1)
    int unsigned      msix_table_bir;       // BAR indicator for table
    bit [31:0]        msix_table_offset;
    int unsigned      msix_pba_bir;
    bit [31:0]        msix_pba_offset;

    // ========================================================================
    // Discovery status flags
    // ========================================================================

    bit               common_cfg_found;
    bit               notify_found;
    bit               isr_found;
    bit               device_cfg_found;
    bit               pci_cfg_found;
    bit               msix_found;

    // ========================================================================
    // Bar accessor reference (stored as uvm_object, cast at runtime)
    // ========================================================================

    uvm_object        bar_ref;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_pci_cap_manager");
        super.new(name);
        common_cfg_found      = 0;
        notify_found          = 0;
        isr_found             = 0;
        device_cfg_found      = 0;
        pci_cfg_found         = 0;
        msix_found            = 0;
        notify_off_multiplier = 0;
    endfunction

    // ========================================================================
    // Protected helper: config read via bar_accessor
    //
    // The bar_accessor class (Task 11) provides:
    //   task config_read(bit [11:0] addr, ref bit [31:0] data);
    //
    // We store it as uvm_object and $cast at runtime. This works because
    // bar_accessor is compiled before this class is instantiated.
    // ========================================================================

    protected task do_config_read(bit [11:0] addr, ref bit [31:0] data);
        virtio_bar_accessor accessor;
        if (!$cast(accessor, bar_ref)) begin
            `uvm_fatal("PCI_CAP_MGR",
                $sformatf("Failed to cast bar_ref to virtio_bar_accessor (bar_ref type: %s)",
                          bar_ref != null ? bar_ref.get_type_name() : "null"))
        end
        accessor.config_read(addr, data);
    endtask

    // ========================================================================
    // discover_capabilities
    //
    // Traverses the PCI configuration space capability linked list starting
    // from the Capabilities Pointer at offset 0x34. For each capability:
    //   - Vendor-specific (0x09): parse as virtio capability structure
    //   - MSI-X (0x11): parse MSI-X table/PBA info
    //
    // Must be called after bar_ref is set to a valid bar_accessor instance.
    // ========================================================================

    virtual task discover_capabilities();
        bit [31:0] dword;
        bit [7:0]  cap_ptr;
        bit [7:0]  cap_id;
        bit [7:0]  cap_next;
        int        cap_count;

        if (bar_ref == null) begin
            `uvm_fatal("PCI_CAP_MGR",
                "bar_ref is null; set it before calling discover_capabilities()")
        end

        // Reset discovery status
        common_cfg_found = 0;
        notify_found     = 0;
        isr_found        = 0;
        device_cfg_found = 0;
        pci_cfg_found    = 0;
        msix_found       = 0;

        // Step 1: Read Capabilities Pointer at config offset 0x34
        // The pointer is in the low byte of the DWord at 0x34
        do_config_read(PCI_CFG_CAP_PTR, dword);
        cap_ptr = dword[7:0];

        // Mask low 2 bits per PCI spec (DWORD-aligned)
        cap_ptr = {cap_ptr[7:2], 2'b00};

        `uvm_info("PCI_CAP_MGR",
            $sformatf("Starting capability walk from cap_ptr=0x%02h", cap_ptr),
            UVM_MEDIUM)

        // Step 2: Walk the linked list
        cap_count = 0;
        while (cap_ptr != 8'h00 && cap_count < 48) begin
            cap_count++;

            // Read capability header DWord: [7:0]=cap_id, [15:8]=cap_next
            do_config_read({4'h0, cap_ptr}, dword);
            cap_id   = dword[7:0];
            cap_next = dword[15:8];

            `uvm_info("PCI_CAP_MGR",
                $sformatf("Cap #%0d at offset 0x%02h: cap_id=0x%02h, cap_next=0x%02h",
                          cap_count, cap_ptr, cap_id, cap_next), UVM_HIGH)

            // Step 3: Parse based on cap_id
            case (cap_id)
                PCI_CAP_ID_VENDOR: begin
                    parse_virtio_cap(cap_ptr);
                end

                PCI_CAP_ID_MSIX: begin
                    parse_msix_cap(cap_ptr);
                end

                PCI_CAP_ID_PCIE: begin
                    `uvm_info("PCI_CAP_MGR",
                        $sformatf("PCIe capability found at offset 0x%02h (skipping)",
                                  cap_ptr), UVM_HIGH)
                end

                default: begin
                    `uvm_info("PCI_CAP_MGR",
                        $sformatf("Unknown capability 0x%02h at offset 0x%02h (skipping)",
                                  cap_id, cap_ptr), UVM_HIGH)
                end
            endcase

            // Step 4: Follow cap_next
            cap_ptr = {cap_next[7:2], 2'b00};
        end

        if (cap_count >= 48) begin
            `uvm_error("PCI_CAP_MGR",
                "Capability linked list exceeded 48 entries; possible circular list")
        end

        // Report discovery results
        report_discovery_status();
    endtask

    // ========================================================================
    // parse_virtio_cap
    //
    // Parse a virtio vendor-specific capability at the given config offset.
    //
    // Virtio capability layout (all fields little-endian):
    //   Byte  0: cap_vndr  (0x09)
    //   Byte  1: cap_next
    //   Byte  2: cap_len
    //   Byte  3: cfg_type  (1-5)
    //   Byte  4: bar
    //   Byte  5: id
    //   Byte  6-7: padding
    //   Byte  8-11: offset  (32-bit)
    //   Byte 12-15: length  (32-bit)
    //   Byte 16-19: notify_off_multiplier (only for cfg_type == 2)
    // ========================================================================

    protected task parse_virtio_cap(bit [7:0] cap_offset);
        bit [31:0] dw0, dw1, dw2, dw3, dw4;
        bit [7:0]  cfg_type;
        bit [7:0]  bar_num;
        bit [31:0] region_offset;
        bit [31:0] region_length;
        virtio_pci_cap_t cap;

        // DWord 0: cap_vndr(7:0), cap_next(15:8), cap_len(23:16), cfg_type(31:24)
        do_config_read({4'h0, cap_offset}, dw0);
        cfg_type = dw0[31:24];

        // DWord 1: bar(7:0), id(15:8), padding(31:16)
        do_config_read({4'h0, cap_offset} + 12'h04, dw1);
        bar_num = dw1[7:0];

        // DWord 2: offset(31:0)
        do_config_read({4'h0, cap_offset} + 12'h08, dw2);
        region_offset = dw2;

        // DWord 3: length(31:0)
        do_config_read({4'h0, cap_offset} + 12'h0C, dw3);
        region_length = dw3;

        // Build the capability struct
        cap.cap_id   = PCI_CAP_ID_VENDOR;
        cap.cap_next = dw0[15:8];
        cap.cfg_type = cfg_type;
        cap.bar      = bar_num;
        cap.offset   = region_offset;
        cap.length   = region_length;

        `uvm_info("PCI_CAP_MGR",
            $sformatf("Virtio cap at 0x%02h: cfg_type=%0d, bar=%0d, offset=0x%08h, length=0x%08h",
                      cap_offset, cfg_type, bar_num, region_offset, region_length),
            UVM_MEDIUM)

        // Store in the appropriate field based on cfg_type
        case (cfg_type)
            VIRTIO_PCI_CAP_COMMON_CFG: begin
                common_cfg_cap   = cap;
                common_cfg_found = 1;
                `uvm_info("PCI_CAP_MGR",
                    "  -> Common Configuration capability", UVM_MEDIUM)
            end

            VIRTIO_PCI_CAP_NOTIFY_CFG: begin
                notify_cap   = cap;
                notify_found = 1;
                // Read notify_off_multiplier at cap_offset + 16
                do_config_read({4'h0, cap_offset} + 12'h10, dw4);
                notify_off_multiplier = dw4;
                `uvm_info("PCI_CAP_MGR",
                    $sformatf("  -> Notification capability (notify_off_multiplier=%0d)",
                              notify_off_multiplier), UVM_MEDIUM)
            end

            VIRTIO_PCI_CAP_ISR_CFG: begin
                isr_cap   = cap;
                isr_found = 1;
                `uvm_info("PCI_CAP_MGR",
                    "  -> ISR Status capability", UVM_MEDIUM)
            end

            VIRTIO_PCI_CAP_DEVICE_CFG: begin
                device_cfg_cap   = cap;
                device_cfg_found = 1;
                `uvm_info("PCI_CAP_MGR",
                    "  -> Device-specific Configuration capability", UVM_MEDIUM)
            end

            VIRTIO_PCI_CAP_PCI_CFG: begin
                pci_cfg_cap   = cap;
                pci_cfg_found = 1;
                `uvm_info("PCI_CAP_MGR",
                    "  -> PCI Configuration Access capability", UVM_MEDIUM)
            end

            default: begin
                `uvm_warning("PCI_CAP_MGR",
                    $sformatf("Unknown virtio cfg_type %0d at offset 0x%02h",
                              cfg_type, cap_offset))
            end
        endcase
    endtask

    // ========================================================================
    // parse_msix_cap
    //
    // Parse an MSI-X capability at the given config offset.
    //
    // MSI-X capability layout:
    //   Byte  0:   cap_id (0x11)
    //   Byte  1:   cap_next
    //   Byte  2-3: Message Control (table_size bits 10:0, enable bit 15,
    //              func_mask bit 14)
    //   Byte  4-7: Table Offset/BIR (BIR bits 2:0, offset bits 31:3)
    //   Byte  8-11: PBA Offset/BIR  (BIR bits 2:0, offset bits 31:3)
    // ========================================================================

    protected task parse_msix_cap(bit [7:0] cap_offset);
        bit [31:0] dw0, dw1, dw2;

        msix_cap_offset = cap_offset;
        msix_found      = 1;

        // DWord 0: cap_id(7:0), cap_next(15:8), message_control(31:16)
        do_config_read({4'h0, cap_offset}, dw0);
        msix_table_size = (dw0[26:16] & MSIX_CTRL_TABLE_SIZE_MASK[10:0]) + 1;

        `uvm_info("PCI_CAP_MGR",
            $sformatf("MSI-X cap at 0x%02h: table_size=%0d vectors, enable=%0b, func_mask=%0b",
                      cap_offset, msix_table_size, dw0[31], dw0[30]),
            UVM_MEDIUM)

        // DWord 1: Table Offset/BIR
        do_config_read({4'h0, cap_offset} + 12'h04, dw1);
        msix_table_bir    = dw1[2:0];
        msix_table_offset = {dw1[31:3], 3'b000};

        `uvm_info("PCI_CAP_MGR",
            $sformatf("  -> Table: BAR%0d, offset=0x%08h",
                      msix_table_bir, msix_table_offset), UVM_MEDIUM)

        // DWord 2: PBA Offset/BIR
        do_config_read({4'h0, cap_offset} + 12'h08, dw2);
        msix_pba_bir    = dw2[2:0];
        msix_pba_offset = {dw2[31:3], 3'b000};

        `uvm_info("PCI_CAP_MGR",
            $sformatf("  -> PBA:   BAR%0d, offset=0x%08h",
                      msix_pba_bir, msix_pba_offset), UVM_MEDIUM)
    endtask

    // ========================================================================
    // report_discovery_status
    // ========================================================================

    protected function void report_discovery_status();
        string report;
        report = "\n========== PCI Capability Discovery Summary ==========\n";
        report = {report, $sformatf("  Common Config (type 1): %s\n",
                  common_cfg_found ? "FOUND" : "NOT FOUND")};
        report = {report, $sformatf("  Notification  (type 2): %s\n",
                  notify_found ? "FOUND" : "NOT FOUND")};
        report = {report, $sformatf("  ISR Status    (type 3): %s\n",
                  isr_found ? "FOUND" : "NOT FOUND")};
        report = {report, $sformatf("  Device Config (type 4): %s\n",
                  device_cfg_found ? "FOUND" : "NOT FOUND")};
        report = {report, $sformatf("  PCI Config    (type 5): %s\n",
                  pci_cfg_found ? "FOUND" : "NOT FOUND (optional)")};
        report = {report, $sformatf("  MSI-X:                  %s\n",
                  msix_found ? "FOUND" : "NOT FOUND")};
        report = {report, "======================================================="};

        `uvm_info("PCI_CAP_MGR", report, UVM_LOW)

        // Mandatory capabilities check
        if (!common_cfg_found)
            `uvm_error("PCI_CAP_MGR",
                "Mandatory Common Configuration capability not found")
        if (!notify_found)
            `uvm_error("PCI_CAP_MGR",
                "Mandatory Notification capability not found")
        if (!isr_found)
            `uvm_error("PCI_CAP_MGR",
                "Mandatory ISR Status capability not found")
        if (!device_cfg_found)
            `uvm_warning("PCI_CAP_MGR",
                "Device-specific Configuration capability not found")
    endfunction

    // ========================================================================
    // Convenience accessors: get BAR number and offset for each region
    // ========================================================================

    function bit [63:0] get_common_cfg_bar_offset();
        return {32'h0, common_cfg_cap.offset};
    endfunction

    function int unsigned get_common_cfg_bar();
        return common_cfg_cap.bar;
    endfunction

    function bit [63:0] get_notify_bar_offset(int unsigned queue_notify_off);
        return {32'h0, notify_cap.offset} +
               queue_notify_off * notify_off_multiplier;
    endfunction

    function int unsigned get_notify_bar();
        return notify_cap.bar;
    endfunction

    function bit [63:0] get_isr_bar_offset();
        return {32'h0, isr_cap.offset};
    endfunction

    function int unsigned get_isr_bar();
        return isr_cap.bar;
    endfunction

    function bit [63:0] get_device_cfg_bar_offset();
        return {32'h0, device_cfg_cap.offset};
    endfunction

    function int unsigned get_device_cfg_bar();
        return device_cfg_cap.bar;
    endfunction

    // ========================================================================
    // Validation helpers
    // ========================================================================

    // Check that all mandatory capabilities were discovered
    function bit all_mandatory_caps_found();
        return common_cfg_found && notify_found && isr_found;
    endfunction

    // Check that MSI-X is available
    function bit has_msix();
        return msix_found;
    endfunction

    // Get the total number of MSI-X vectors
    function int unsigned get_msix_table_size();
        return msix_table_size;
    endfunction

    // ========================================================================
    // Error injection: corrupt discovered capability info (for testing)
    // ========================================================================

    function void inject_cap_error(string target = "common_cfg");
        case (target)
            "common_cfg": begin
                common_cfg_cap.offset = common_cfg_cap.offset ^ 32'hDEAD_0000;
                `uvm_info("PCI_CAP_MGR",
                    $sformatf("Injected error: common_cfg offset corrupted to 0x%08h",
                              common_cfg_cap.offset), UVM_LOW)
            end
            "notify": begin
                notify_cap.bar = notify_cap.bar ^ 8'h07;
                `uvm_info("PCI_CAP_MGR",
                    $sformatf("Injected error: notify bar corrupted to %0d",
                              notify_cap.bar), UVM_LOW)
            end
            "isr": begin
                isr_cap.offset = isr_cap.offset ^ 32'hBAAD_0000;
                `uvm_info("PCI_CAP_MGR",
                    $sformatf("Injected error: ISR offset corrupted to 0x%08h",
                              isr_cap.offset), UVM_LOW)
            end
            "device_cfg": begin
                device_cfg_cap.length = 0;
                `uvm_info("PCI_CAP_MGR",
                    "Injected error: device_cfg length set to 0", UVM_LOW)
            end
            "msix": begin
                msix_table_size = 0;
                `uvm_info("PCI_CAP_MGR",
                    "Injected error: msix_table_size set to 0", UVM_LOW)
            end
            default: begin
                `uvm_warning("PCI_CAP_MGR",
                    $sformatf("Unknown inject_cap_error target: %s", target))
            end
        endcase
    endfunction

endclass : virtio_pci_cap_manager

`endif // VIRTIO_PCI_CAP_MANAGER_SV
