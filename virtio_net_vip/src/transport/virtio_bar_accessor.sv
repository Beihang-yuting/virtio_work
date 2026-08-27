// ============================================================================
// virtio_bar_accessor.sv
//
// Translates BAR MMIO register reads/writes into PCIe TLP sequences and
// dispatches them to the pcie_tl_vip's RC Agent sequencer.
//
// Provides:
//   - read_reg / write_reg:   MMIO via Memory Read/Write TLPs
//   - config_read / config_write: PCI config space via Config TLPs (Type 0)
//   - enumerate_bars:         Standard PCI BAR enumeration
//   - Error-injection variants for poisoned TLP testing
//
// ============================================================================

`ifndef VIRTIO_BAR_ACCESSOR_SV
`define VIRTIO_BAR_ACCESSOR_SV

// ============================================================================
// Helper sequence: Memory Read with response extraction
// ============================================================================

class virtio_bar_mem_rd_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(virtio_bar_mem_rd_seq)

    // Request fields
    bit [63:0]  addr;
    bit [3:0]   first_be;
    bit [3:0]   last_be;
    bit         is_64bit;

    // Response data
    bit [31:0]  rdata;
    bit         cpl_ok;

    // An endpoint-aware accessor supplies these per sequence.  The base
    // sequences ignore them; the TLM factory overrides use them to keep
    // completions from equal tag/BDF values in independent domains distinct.
    virtio_tlm_completion_adapter endpoint_completion_adapter;
    dpu_pcie_function_id_t        endpoint_pcie_id;
    bit                           endpoint_pcie_id_valid;

    function new(string name = "virtio_bar_mem_rd_seq");
        super.new(name);
        first_be  = 4'hF;
        last_be   = 4'h0;
        is_64bit  = 0;
        rdata     = '0;
        cpl_ok    = 0;
        endpoint_completion_adapter = null;
        endpoint_pcie_id_valid = 0;
    endfunction

    virtual task body();
        pcie_tl_mem_rd_seq rd_seq;
        rd_seq = pcie_tl_mem_rd_seq::type_id::create("rd_seq");
        rd_seq.addr     = addr;
        rd_seq.length   = 10'h1;   // 1 DW
        rd_seq.first_be = first_be;
        rd_seq.last_be  = last_be;
        rd_seq.is_64bit = is_64bit;
        rd_seq.start(m_sequencer);

        // Extract completion data from the sequence response.
        // The pcie_tl_vip stores the completion payload in the TLP item
        // accessible via the response queue after the sequence completes.
        begin
            pcie_tl_tlp rsp;
            get_response(rsp);
            if (rsp != null) begin
                cpl_ok = 1;
                rdata = '0;
                if (rsp.payload.size() >= 4) begin
                    // Little-endian assembly from payload bytes
                    rdata = {rsp.payload[3], rsp.payload[2],
                             rsp.payload[1], rsp.payload[0]};
                end else begin
                    for (int i = 0; i < rsp.payload.size(); i++)
                        rdata[i*8 +: 8] = rsp.payload[i];
                end
            end else begin
                cpl_ok = 0;
                rdata  = '0;
            end
        end
    endtask

endclass : virtio_bar_mem_rd_seq

// ============================================================================
// Helper sequence: Memory Write
// ============================================================================

class virtio_bar_mem_wr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(virtio_bar_mem_wr_seq)

    bit [63:0]  addr;
    bit [31:0]  wdata;
    bit [3:0]   first_be;
    bit [3:0]   last_be;
    bit         is_64bit;
    virtio_tlm_completion_adapter endpoint_completion_adapter;
    dpu_pcie_function_id_t        endpoint_pcie_id;
    bit                           endpoint_pcie_id_valid;

    function new(string name = "virtio_bar_mem_wr_seq");
        super.new(name);
        first_be = 4'hF;
        last_be  = 4'h0;
        is_64bit = 0;
        wdata    = '0;
        endpoint_completion_adapter = null;
        endpoint_pcie_id_valid = 0;
    endfunction

    virtual task body();
        pcie_tl_mem_wr_seq wr_seq;
        wr_seq = pcie_tl_mem_wr_seq::type_id::create("wr_seq");
        wr_seq.addr     = addr;
        wr_seq.length   = 10'h1;
        wr_seq.first_be = first_be;
        wr_seq.last_be  = last_be;
        wr_seq.is_64bit = is_64bit;
        wr_seq.start(m_sequencer);
    endtask

endclass : virtio_bar_mem_wr_seq

// ============================================================================
// Helper sequence: Config Read (Type 0)
// ============================================================================

class virtio_bar_cfg_rd_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(virtio_bar_cfg_rd_seq)

    bit [15:0]  target_bdf;
    bit [9:0]   reg_num;
    bit [3:0]   first_be;

    // Response
    bit [31:0]  rdata;
    bit         cpl_ok;
    virtio_tlm_completion_adapter endpoint_completion_adapter;
    dpu_pcie_function_id_t        endpoint_pcie_id;
    bit                           endpoint_pcie_id_valid;

    function new(string name = "virtio_bar_cfg_rd_seq");
        super.new(name);
        first_be = 4'hF;
        rdata    = '0;
        cpl_ok   = 0;
        endpoint_completion_adapter = null;
        endpoint_pcie_id_valid = 0;
    endfunction

    virtual task body();
        pcie_tl_cfg_rd_seq rd_seq;
        rd_seq = pcie_tl_cfg_rd_seq::type_id::create("cfg_rd_seq");
        rd_seq.target_bdf = target_bdf;
        rd_seq.reg_num    = reg_num;
        rd_seq.first_be   = first_be;
        rd_seq.is_type1   = 0;   // Type 0 for local device
        rd_seq.start(m_sequencer);

        begin
            pcie_tl_tlp rsp;
            get_response(rsp);
            if (rsp != null) begin
                cpl_ok = 1;
                rdata = '0;
                if (rsp.payload.size() >= 4) begin
                    rdata = {rsp.payload[3], rsp.payload[2],
                             rsp.payload[1], rsp.payload[0]};
                end else begin
                    for (int i = 0; i < rsp.payload.size(); i++)
                        rdata[i*8 +: 8] = rsp.payload[i];
                end
            end else begin
                cpl_ok = 0;
                rdata  = '0;
            end
        end
    endtask

endclass : virtio_bar_cfg_rd_seq

// ============================================================================
// Helper sequence: Config Write (Type 0)
// ============================================================================

class virtio_bar_cfg_wr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(virtio_bar_cfg_wr_seq)

    bit [15:0]  target_bdf;
    bit [9:0]   reg_num;
    bit [3:0]   first_be;
    bit [31:0]  wdata;
    virtio_tlm_completion_adapter endpoint_completion_adapter;
    dpu_pcie_function_id_t        endpoint_pcie_id;
    bit                           endpoint_pcie_id_valid;

    function new(string name = "virtio_bar_cfg_wr_seq");
        super.new(name);
        first_be = 4'hF;
        wdata = '0;
        endpoint_completion_adapter = null;
        endpoint_pcie_id_valid = 0;
    endfunction

    virtual task body();
        pcie_tl_cfg_tlp wr_tlp;

        // Do not delegate this write to pcie_tl_cfg_wr_seq: its public
        // wr_data field is not copied into the Config TLP payload.  Program
        // the payload before finish_item() so the PCIe transport observes the
        // requested DWORD, including in TLM adapter mode.
        wr_tlp = pcie_tl_cfg_tlp::type_id::create("cfg_wr_tlp");
        start_item(wr_tlp);
        if (!wr_tlp.randomize() with {
            wr_tlp.kind == TLP_CFG_WR0;
            wr_tlp.completer_id == local::target_bdf;
            wr_tlp.reg_num == local::reg_num;
            wr_tlp.first_be == local::first_be;
            wr_tlp.constraint_mode_sel == CONSTRAINT_LEGAL;
        }) begin
            `uvm_fatal("BAR_ACCESSOR",
                "could not randomize a Type-0 PCI config write TLP")
        end
        wr_tlp.payload = new[4];
        wr_tlp.payload[0] = wdata[7:0];
        wr_tlp.payload[1] = wdata[15:8];
        wr_tlp.payload[2] = wdata[23:16];
        wr_tlp.payload[3] = wdata[31:24];
        finish_item(wr_tlp);
    endtask

endclass : virtio_bar_cfg_wr_seq

// ============================================================================
// virtio_bar_accessor
//
// Main accessor class. Not a uvm_sequence itself; it creates and starts
// helper sequences on the pcie_rc_seqr handle.
// ============================================================================

class virtio_bar_accessor extends uvm_object;
    `uvm_object_utils(virtio_bar_accessor)

    // ===== BAR configuration =====
    bit [63:0]  bar_base[6];        // BAR0-5 base addresses
    bit [63:0]  bar_size[6];        // BAR0-5 sizes (for enumeration)
    bit [2:0]   bar_type[6];        // PCI BAR bits [2:0]; 3'b100=64-bit MMIO
    bit         fabric_bar_layout_active;
    bit         fabric_bar_role_valid[6];
    dpu_bar_role_e fabric_bar_role[6];

    // ===== PCIe layer references =====
    uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr;   // RC Agent's sequencer
    bit [15:0]   requester_id;                     // This function's BDF
    dpu_pcie_function_id_t pcie_id;
    bit                    pcie_id_valid;
    virtio_tlm_completion_adapter endpoint_completion_adapter;

    // ===== BAR enumeration base address allocator =====
    bit [63:0]   next_bar_alloc_addr;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_bar_accessor");
        super.new(name);
        requester_id        = 16'h0;
        pcie_id_valid       = 0;
        endpoint_completion_adapter = null;
        next_bar_alloc_addr = 64'h0000_0000_C000_0000;  // Default MMIO window
        fabric_bar_layout_active = 0;
        for (int i = 0; i < 6; i++) begin
            bar_base[i] = '0;
            bar_size[i] = '0;
            bar_type[i] = '0;
            fabric_bar_role_valid[i] = 0;
            fabric_bar_role[i] = DPU_BAR_DEVICE_MEMORY;
        end
    endfunction

    // Preserve the complete Fabric identity at the point that owns request
    // generation.  requester_id remains the PCIe header's numeric BDF field;
    // it is never used to select an external domain.
    function void configure_pcie_identity(
        input dpu_pcie_function_id_t function_pcie_id
    );
        pcie_id = function_pcie_id;
        pcie_id_valid = 1;
        requester_id = function_pcie_id.bdf;
    endfunction

    function void bind_pcie_path(
        input dpu_pcie_function_id_t function_pcie_id,
        input uvm_sequencer #(pcie_tl_tlp) endpoint_rc_seqr,
        input virtio_tlm_completion_adapter completion_adapter = null
    );
        configure_pcie_identity(function_pcie_id);
        pcie_rc_seqr = endpoint_rc_seqr;
        endpoint_completion_adapter = completion_adapter;
    endfunction

    // Fabric owns physical BAR placement.  These pairs must therefore never
    // pass through PCI BAR sizing/enumeration or the local address allocator.
    virtual function void configure_fabric_bar_pairs(
        input dpu_bar_pair_lease_t bars[$]
    );
        bit lease_seen[3];

        if (bars.size() != 3) begin
            `uvm_error("BAR_ACCESSOR", $sformatf(
                "Fabric BAR lease set must contain exactly three unique pairs; got %0d",
                bars.size()))
            return;
        end
        foreach (bars[index]) begin
            int unsigned lease_slot;

            if ((bars[index].even_bar_id == 0) &&
                (bars[index].role == DPU_BAR_DEVICE_MEMORY)) begin
                lease_slot = 0;
            end
            else if ((bars[index].even_bar_id == 2) &&
                     (bars[index].role == DPU_BAR_MAILBOX)) begin
                lease_slot = 1;
            end
            else if ((bars[index].even_bar_id == 4) &&
                     (bars[index].role == DPU_BAR_MSIX)) begin
                lease_slot = 2;
            end
            else begin
                `uvm_error("BAR_ACCESSOR", $sformatf(
                    "Fabric BAR lease %0d has invalid role %0d for even BAR%0d; expected BAR0=device-memory, BAR2=mailbox, or BAR4=MSI-X",
                    index, bars[index].role, bars[index].even_bar_id))
                return;
            end
            if (lease_seen[lease_slot]) begin
                `uvm_error("BAR_ACCESSOR", $sformatf(
                    "Fabric BAR lease %0d duplicates the required BAR%0d role %0d pair",
                    index, bars[index].even_bar_id, bars[index].role))
                return;
            end
            lease_seen[lease_slot] = 1;
        end
        for (int unsigned lease_slot = 0; lease_slot < 3; lease_slot++) begin
            if (!lease_seen[lease_slot]) begin
                `uvm_error("BAR_ACCESSOR", $sformatf(
                    "Fabric BAR lease set is missing required pair slot %0d",
                    lease_slot))
                return;
            end
        end

        // Do not mutate an existing Fabric layout until the entire input set
        // has validated.  A malformed retry must not leave a partial layout
        // that can later be programmed into PCI config space.
        fabric_bar_layout_active = 1;
        for (int unsigned bar_id = 0; bar_id < 6; bar_id++) begin
            bar_base[bar_id] = '0;
            bar_size[bar_id] = '0;
            bar_type[bar_id] = '0;
            fabric_bar_role_valid[bar_id] = 0;
            fabric_bar_role[bar_id] = DPU_BAR_DEVICE_MEMORY;
        end
        foreach (bars[index]) begin
            bar_base[bars[index].even_bar_id] = bars[index].base;
            bar_size[bars[index].even_bar_id] = bars[index].size;
            bar_type[bars[index].even_bar_id] = 3'b100;
            fabric_bar_role_valid[bars[index].even_bar_id] = 1;
            fabric_bar_role[bars[index].even_bar_id] = bars[index].role;
            fabric_bar_role_valid[bars[index].even_bar_id + 1] = 1;
            fabric_bar_role[bars[index].even_bar_id + 1] = bars[index].role;
        end
    endfunction

    function bit fabric_bar_layout_is_active();
        return fabric_bar_layout_active;
    endfunction

    protected function bit fabric_bar_pair_is_programmable(
        input int unsigned even_bar_id,
        input dpu_bar_role_e expected_role,
        output string why
    );
        bit [63:0] pair_size;

        why = "";
        if ((even_bar_id > 4) || ((even_bar_id % 2) != 0)) begin
            why = $sformatf("invalid even BAR ID %0d", even_bar_id);
            return 0;
        end
        if (!fabric_bar_role_valid[even_bar_id] ||
            !fabric_bar_role_valid[even_bar_id + 1]) begin
            why = $sformatf("BAR%0d/%0d has no complete Fabric role lease",
                            even_bar_id, even_bar_id + 1);
            return 0;
        end
        if ((fabric_bar_role[even_bar_id] != expected_role) ||
            (fabric_bar_role[even_bar_id + 1] != expected_role)) begin
            why = $sformatf("BAR%0d/%0d role mismatch (expected %0d)",
                            even_bar_id, even_bar_id + 1, expected_role);
            return 0;
        end

        pair_size = bar_size[even_bar_id];
        // The low nibble encodes PCI BAR attributes, never Fabric address
        // bits.  Reject a lease that would be silently changed by attribute
        // insertion instead of masking its supplied base during programming.
        if ((bar_base[even_bar_id] & 64'hf) != 0) begin
            why = $sformatf(
                "BAR%0d base 0x%016h has nonzero low address nibble before PCI attribute bits",
                even_bar_id, bar_base[even_bar_id]);
            return 0;
        end
        if ((pair_size < 64'h10) ||
            ((pair_size & (pair_size - 1)) != 0)) begin
            why = $sformatf(
                "BAR%0d pair size 0x%016h must be a power of two and at least 0x10",
                even_bar_id, pair_size);
            return 0;
        end
        if ((bar_base[even_bar_id] & (pair_size - 1)) != 0) begin
            why = $sformatf("BAR%0d base 0x%016h is not aligned to size 0x%016h",
                            even_bar_id, bar_base[even_bar_id], pair_size);
            return 0;
        end
        if ((bar_base[even_bar_id + 1] != '0) ||
            (bar_size[even_bar_id + 1] != '0) ||
            (bar_type[even_bar_id + 1] != '0)) begin
            why = $sformatf("BAR%0d upper slot contains a second lease",
                            even_bar_id + 1);
            return 0;
        end
        if (bar_type[even_bar_id] != 3'b100) begin
            why = $sformatf("BAR%0d is not a 64-bit MMIO pair", even_bar_id);
            return 0;
        end
        return 1;
    endfunction

    // Program the Fabric-owned 64-bit BAR pairs through PCIe config space.
    virtual task program_fabric_bar_pairs();
        string why;
        bit [31:0] low_dword;
        bit [11:0] low_addr;

        if (!fabric_bar_layout_active) begin
            `uvm_fatal("BAR_FABRIC_PROGRAM",
                "cannot program Fabric BARs without an active Fabric layout")
            return;
        end
        if (!fabric_bar_pair_is_programmable(
            0, DPU_BAR_DEVICE_MEMORY, why
        ) || !fabric_bar_pair_is_programmable(
            2, DPU_BAR_MAILBOX, why
        ) || !fabric_bar_pair_is_programmable(
            4, DPU_BAR_MSIX, why
        )) begin
            `uvm_fatal("BAR_FABRIC_PROGRAM", $sformatf(
                "cannot program Fabric BAR pairs for BDF 0x%04h: %s",
                requester_id, why))
            return;
        end

        for (int unsigned even_bar_id = 0;
             even_bar_id < 6;
             even_bar_id += 2) begin
            low_addr = PCI_CFG_BAR0 + (even_bar_id * 4);
            // bar_base was prevalidated with zero address bits [3:0], so
            // this replaces only standard 64-bit MMIO attribute bits and
            // preserves every supplied base-address bit exactly.
            low_dword = {bar_base[even_bar_id][31:4], 4'b0100};
            config_write(low_addr, low_dword, 4'hf);
            config_write(low_addr + 12'h004,
                         bar_base[even_bar_id][63:32], 4'hf);
        end

        `uvm_info("BAR_FABRIC_PROGRAM", $sformatf(
            "programmed Fabric BAR0/1, BAR2/3, and BAR4/5 for BDF 0x%04h",
            requester_id), UVM_MEDIUM)
    endtask

    protected function bit allow_functional_bar_access(input int unsigned bar_id);
        if (!fabric_bar_layout_active)
            return 1;
        if ((bar_id > 5) || ((bar_id % 2) != 0)) begin
            `uvm_error("BAR_FUNCTION_WINDOW", $sformatf(
                "functional MMIO access must use an even Fabric BAR base, not BAR%0d",
                bar_id))
            return 0;
        end
        if (bar_id == 4) begin
            `uvm_error("BAR_MSIX_ONLY", $sformatf(
                "functional MMIO access to MSI-X-only BAR%0d was blocked", bar_id))
            return 0;
        end
        if ((bar_id == 0) && fabric_bar_role_valid[0] &&
            (fabric_bar_role[0] == DPU_BAR_DEVICE_MEMORY))
            return 1;
        if ((bar_id == 2) && fabric_bar_role_valid[2] &&
            (fabric_bar_role[2] == DPU_BAR_MAILBOX))
            return 1;
        if ((bar_id == 0) || (bar_id == 2)) begin
            `uvm_error("BAR_FUNCTION_WINDOW", $sformatf(
                "functional MMIO access to Fabric BAR%0d has an incompatible role",
                bar_id))
            return 0;
        end
        `uvm_error("BAR_FUNCTION_WINDOW", $sformatf(
            "functional MMIO access must use Fabric BAR0/1 or BAR2/3, not BAR%0d",
            bar_id))
        return 0;
    endfunction

    protected function bit allow_msix_bar_access(input int unsigned bar_id);
        if (!fabric_bar_layout_active)
            return 1;
        if (bar_id == 4)
            return 1;
        `uvm_error("BAR_MSIX_ONLY", $sformatf(
            "MSI-X access must use Fabric BAR4/5, not BAR%0d", bar_id))
        return 0;
    endfunction

    // ========================================================================
    // Byte enable computation
    //
    // Computes PCIe first_be based on access size and offset alignment within
    // a DWord boundary.
    // ========================================================================

    protected function bit [3:0] compute_first_be(int unsigned size,
                                                   bit [1:0] byte_offset);
        case (size)
            4: return 4'hF;
            2: begin
                case (byte_offset)
                    2'b00: return 4'b0011;
                    2'b10: return 4'b1100;
                    default: begin
                        `uvm_warning("BAR_ACCESSOR",
                            $sformatf("Unaligned 2-byte access at byte_offset=%0d, using BE=0xF",
                                      byte_offset))
                        return 4'hF;
                    end
                endcase
            end
            1: begin
                case (byte_offset)
                    2'b00: return 4'b0001;
                    2'b01: return 4'b0010;
                    2'b10: return 4'b0100;
                    2'b11: return 4'b1000;
                endcase
            end
            default: begin
                `uvm_error("BAR_ACCESSOR",
                    $sformatf("Unsupported access size: %0d bytes", size))
                return 4'hF;
            end
        endcase
    endfunction

    // ========================================================================
    // Extract register data from the raw DWord based on byte enables
    // ========================================================================

    protected function bit [31:0] extract_data_by_be(bit [31:0] raw_dw,
                                                      bit [3:0] be);
        bit [31:0] result;
        result = '0;
        case (be)
            4'b0001: result = {24'h0, raw_dw[7:0]};
            4'b0010: result = {24'h0, raw_dw[15:8]};
            4'b0100: result = {24'h0, raw_dw[23:16]};
            4'b1000: result = {24'h0, raw_dw[31:24]};
            4'b0011: result = {16'h0, raw_dw[15:0]};
            4'b1100: result = {16'h0, raw_dw[31:16]};
            4'b1111: result = raw_dw;
            default: result = raw_dw;
        endcase
        return result;
    endfunction

    // ========================================================================
    // read_reg
    //
    // MMIO register read via PCIe Memory Read TLP.
    //   bar_id:  which BAR (0-5)
    //   offset:  byte offset within BAR
    //   size:    1, 2, or 4 bytes
    //   data:    output -- register value (right-justified)
    // ========================================================================

    virtual task read_reg(int unsigned bar_id, bit [31:0] offset,
                          int unsigned size, ref bit [31:0] data);
        bit [63:0] addr;
        bit [3:0]  be;
        virtio_bar_mem_rd_seq rd_seq;

        if (bar_id > 5) begin
            `uvm_error("BAR_ACCESSOR",
                $sformatf("Invalid bar_id=%0d (must be 0-5)", bar_id))
            data = '0;
            return;
        end

        if (!allow_functional_bar_access(bar_id)) begin
            data = '0;
            return;
        end

        if (pcie_rc_seqr == null) begin
            `uvm_fatal("BAR_ACCESSOR",
                "pcie_rc_seqr is null; set it before calling read_reg()")
        end

        addr = bar_base[bar_id] + {32'h0, offset};
        be   = compute_first_be(size, offset[1:0]);

        rd_seq = virtio_bar_mem_rd_seq::type_id::create("bar_mem_rd");
        rd_seq.addr     = addr;
        rd_seq.first_be = be;
        rd_seq.last_be  = 4'h0;
        rd_seq.is_64bit = (addr[63:32] != 0);
        rd_seq.endpoint_completion_adapter = endpoint_completion_adapter;
        rd_seq.endpoint_pcie_id = pcie_id;
        rd_seq.endpoint_pcie_id_valid = pcie_id_valid;
        rd_seq.start(pcie_rc_seqr);

        if (!rd_seq.cpl_ok) begin
            `uvm_warning("BAR_ACCESSOR",
                $sformatf("No completion for MEM_RD @ BAR%0d+0x%08h", bar_id, offset))
        end

        data = extract_data_by_be(rd_seq.rdata, be);

        `uvm_info("BAR_ACCESSOR",
            $sformatf("read_reg: BAR%0d offset=0x%08h size=%0d addr=0x%016h be=0x%01h data=0x%08h",
                      bar_id, offset, size, addr, be, data), UVM_HIGH)
    endtask

    // ========================================================================
    // write_reg
    //
    // MMIO register write via PCIe Memory Write TLP.
    // ========================================================================

    protected task issue_write_reg(int unsigned bar_id, bit [31:0] offset,
                                   int unsigned size, bit [31:0] data);
        bit [63:0] addr;
        bit [3:0]  be;
        virtio_bar_mem_wr_seq wr_seq;

        if (pcie_rc_seqr == null) begin
            `uvm_fatal("BAR_ACCESSOR",
                "pcie_rc_seqr is null; set it before calling write_reg()")
        end

        addr = bar_base[bar_id] + {32'h0, offset};
        be   = compute_first_be(size, offset[1:0]);

        wr_seq = virtio_bar_mem_wr_seq::type_id::create("bar_mem_wr");
        wr_seq.addr     = addr;
        wr_seq.wdata    = data;
        wr_seq.first_be = be;
        wr_seq.last_be  = 4'h0;
        wr_seq.is_64bit = (addr[63:32] != 0);
        wr_seq.endpoint_completion_adapter = endpoint_completion_adapter;
        wr_seq.endpoint_pcie_id = pcie_id;
        wr_seq.endpoint_pcie_id_valid = pcie_id_valid;
        wr_seq.start(pcie_rc_seqr);

        `uvm_info("BAR_ACCESSOR",
            $sformatf("write_reg: BAR%0d offset=0x%08h size=%0d addr=0x%016h be=0x%01h data=0x%08h",
                      bar_id, offset, size, addr, be, data), UVM_HIGH)
    endtask

    virtual task write_reg(int unsigned bar_id, bit [31:0] offset,
                           int unsigned size, bit [31:0] data);
        if (bar_id > 5) begin
            `uvm_error("BAR_ACCESSOR",
                $sformatf("Invalid bar_id=%0d (must be 0-5)", bar_id))
            return;
        end
        if (!allow_functional_bar_access(bar_id))
            return;
        issue_write_reg(bar_id, offset, size, data);
    endtask

    // MSI-X table writes use an explicit path so Fabric can reserve BAR4/5
    // for interrupts while generic transport accesses remain on BAR0/1.
    virtual task write_msix_reg(int unsigned bar_id, bit [31:0] offset,
                                int unsigned size, bit [31:0] data);
        if (bar_id > 5) begin
            `uvm_error("BAR_ACCESSOR",
                $sformatf("Invalid bar_id=%0d (must be 0-5)", bar_id))
            return;
        end
        if (!allow_msix_bar_access(bar_id))
            return;
        issue_write_reg(bar_id, offset, size, data);
    endtask

    // ========================================================================
    // config_read
    //
    // PCI Config Space read via PCIe Config Read TLP (Type 0).
    //   addr: 12-bit config space byte address (0x000 - 0xFFF)
    //   data: output -- 32-bit DWord value at addr (DWord-aligned)
    // ========================================================================

    virtual task config_read(bit [11:0] addr, ref bit [31:0] data);
        virtio_bar_cfg_rd_seq rd_seq;
        bit [9:0] reg_num;

        if (pcie_rc_seqr == null) begin
            `uvm_fatal("BAR_ACCESSOR",
                "pcie_rc_seqr is null; set it before calling config_read()")
        end

        // DW offset: addr / 4
        reg_num = addr[11:2];

        rd_seq = virtio_bar_cfg_rd_seq::type_id::create("bar_cfg_rd");
        rd_seq.target_bdf = requester_id;
        rd_seq.reg_num    = reg_num;
        rd_seq.first_be   = 4'hF;
        rd_seq.endpoint_completion_adapter = endpoint_completion_adapter;
        rd_seq.endpoint_pcie_id = pcie_id;
        rd_seq.endpoint_pcie_id_valid = pcie_id_valid;
        rd_seq.start(pcie_rc_seqr);

        if (!rd_seq.cpl_ok) begin
            `uvm_warning("BAR_ACCESSOR",
                $sformatf("No completion for CFG_RD @ 0x%03h", addr))
        end

        data = rd_seq.rdata;

        `uvm_info("BAR_ACCESSOR",
            $sformatf("config_read: addr=0x%03h reg_num=%0d data=0x%08h",
                      addr, reg_num, data), UVM_HIGH)
    endtask

    // ========================================================================
    // config_write
    //
    // PCI Config Space write via PCIe Config Write TLP (Type 0).
    //   addr: 12-bit config space byte address
    //   data: 32-bit DWord value
    //   be:   byte enables
    // ========================================================================

    virtual task config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        virtio_bar_cfg_wr_seq wr_seq;
        bit [9:0] reg_num;

        if (pcie_rc_seqr == null) begin
            `uvm_fatal("BAR_ACCESSOR",
                "pcie_rc_seqr is null; set it before calling config_write()")
        end

        reg_num = addr[11:2];

        wr_seq = virtio_bar_cfg_wr_seq::type_id::create("bar_cfg_wr");
        wr_seq.target_bdf = requester_id;
        wr_seq.reg_num    = reg_num;
        wr_seq.first_be   = be;
        wr_seq.wdata      = data;
        wr_seq.endpoint_completion_adapter = endpoint_completion_adapter;
        wr_seq.endpoint_pcie_id = pcie_id;
        wr_seq.endpoint_pcie_id_valid = pcie_id_valid;
        wr_seq.start(pcie_rc_seqr);

        `uvm_info("BAR_ACCESSOR",
            $sformatf("config_write: addr=0x%03h reg_num=%0d data=0x%08h be=0x%01h",
                      addr, reg_num, data, be), UVM_HIGH)
    endtask

    // ========================================================================
    // enumerate_bars
    //
    // Standard PCI BAR enumeration sequence:
    //   1. Save original BAR value
    //   2. Write all-1s to the BAR register
    //   3. Read back to determine size (invert masked bits + 1)
    //   4. Assign address from allocation window
    //   5. Write the assigned address back to the BAR
    //   6. Handle 64-bit BARs (consumes two BAR slots)
    // ========================================================================

    virtual task enumerate_bars();
        bit [31:0] orig_val;
        bit [31:0] sizing_val;
        bit [63:0] size_mask;
        bit [11:0] bar_cfg_addr;
        int i;

        if (fabric_bar_layout_active) begin
            `uvm_error("BAR_FABRIC_OWNED",
                "BAR enumeration is forbidden for Fabric-owned BAR placements")
            return;
        end

        `uvm_info("BAR_ACCESSOR", "Starting BAR enumeration", UVM_MEDIUM)

        i = 0;
        while (i < 6) begin
            bar_cfg_addr = PCI_CFG_BAR0 + (i * 4);

            // Step 1: Save original
            config_read(bar_cfg_addr, orig_val);

            // Step 2: Write all-1s
            config_write(bar_cfg_addr, 32'hFFFF_FFFF, 4'hF);

            // Step 3: Read back sizing value
            config_read(bar_cfg_addr, sizing_val);

            // Restore original
            config_write(bar_cfg_addr, orig_val, 4'hF);

            // Check if BAR is implemented (sizing_val == 0 means not implemented)
            if (sizing_val == 0 || sizing_val == 32'hFFFF_FFFF) begin
                bar_base[i] = '0;
                bar_size[i] = '0;
                bar_type[i] = '0;
                `uvm_info("BAR_ACCESSOR",
                    $sformatf("BAR%0d: not implemented (sizing=0x%08h)", i, sizing_val),
                    UVM_MEDIUM)
                i++;
                continue;
            end

            // Determine BAR type from bits [2:1]
            // 00 = 32-bit, 10 = 64-bit
            bar_type[i] = sizing_val[2:0];

            if (sizing_val[2:1] == 2'b10) begin
                // 64-bit BAR: need to size the upper 32 bits too
                bit [31:0] upper_sizing;
                bit [31:0] upper_orig;
                bit [11:0] upper_bar_addr;

                if (i >= 5) begin
                    `uvm_error("BAR_ACCESSOR",
                        $sformatf("BAR%0d claims 64-bit but no room for upper BAR", i))
                    i++;
                    continue;
                end

                upper_bar_addr = PCI_CFG_BAR0 + ((i + 1) * 4);

                config_read(upper_bar_addr, upper_orig);
                config_write(upper_bar_addr, 32'hFFFF_FFFF, 4'hF);
                config_read(upper_bar_addr, upper_sizing);
                config_write(upper_bar_addr, upper_orig, 4'hF);

                // Compute size from combined 64-bit sizing value
                // Mask out lower 4 bits (type/prefetch) for lower 32
                size_mask = {upper_sizing, sizing_val & 32'hFFFF_FFF0};
                size_mask = (~size_mask) + 1;

                bar_size[i] = size_mask;

                // Align allocation address
                if (next_bar_alloc_addr % size_mask != 0) begin
                    next_bar_alloc_addr = ((next_bar_alloc_addr / size_mask) + 1) * size_mask;
                end

                bar_base[i] = next_bar_alloc_addr;

                // Write assigned address
                config_write(bar_cfg_addr,
                    (bar_base[i][31:0] & 32'hFFFF_FFF0) | {29'h0, bar_type[i]}, 4'hF);
                config_write(upper_bar_addr, bar_base[i][63:32], 4'hF);

                next_bar_alloc_addr = next_bar_alloc_addr + size_mask;

                // Upper BAR slot is consumed
                bar_base[i+1] = '0;
                bar_size[i+1] = '0;
                bar_type[i+1] = '0;

                `uvm_info("BAR_ACCESSOR",
                    $sformatf("BAR%0d: 64-bit, base=0x%016h, size=0x%016h",
                              i, bar_base[i], bar_size[i]), UVM_MEDIUM)
                i += 2;  // Skip upper half
            end else begin
                // 32-bit BAR
                size_mask = {32'h0, (~(sizing_val & 32'hFFFF_FFF0)) + 1};
                bar_size[i] = size_mask;

                // Align allocation address
                if (next_bar_alloc_addr[31:0] % size_mask[31:0] != 0) begin
                    next_bar_alloc_addr = (((next_bar_alloc_addr[31:0] / size_mask[31:0]) + 1)
                                           * size_mask[31:0]);
                end

                bar_base[i] = next_bar_alloc_addr;

                // Write assigned address
                config_write(bar_cfg_addr,
                    (bar_base[i][31:0] & 32'hFFFF_FFF0) | {29'h0, bar_type[i]}, 4'hF);

                next_bar_alloc_addr = next_bar_alloc_addr + size_mask;

                `uvm_info("BAR_ACCESSOR",
                    $sformatf("BAR%0d: 32-bit, base=0x%016h, size=0x%016h",
                              i, bar_base[i], bar_size[i]), UVM_MEDIUM)
                i++;
            end
        end

        `uvm_info("BAR_ACCESSOR", "BAR enumeration complete", UVM_MEDIUM)
    endtask

    // ========================================================================
    // read_reg_with_error
    //
    // Performs an MMIO read but injects a PCIe-level error. Uses zero byte
    // enables to trigger an Unsupported Request on the EP side.
    // ========================================================================

    virtual task read_reg_with_error(int unsigned bar_id, bit [31:0] offset,
                                     int unsigned size, ref bit [31:0] data);
        bit [63:0] addr;
        bit [3:0]  be;
        virtio_bar_mem_rd_seq rd_seq;

        if (bar_id > 5) begin
            `uvm_error("BAR_ACCESSOR",
                $sformatf("Invalid bar_id=%0d (must be 0-5)", bar_id))
            data = '0;
            return;
        end

        if (!allow_functional_bar_access(bar_id)) begin
            data = '0;
            return;
        end

        if (pcie_rc_seqr == null) begin
            `uvm_fatal("BAR_ACCESSOR",
                "pcie_rc_seqr is null; set it before calling read_reg_with_error()")
        end

        addr = bar_base[bar_id] + {32'h0, offset};
        be   = compute_first_be(size, offset[1:0]);

        rd_seq = virtio_bar_mem_rd_seq::type_id::create("bar_mem_rd_err");
        rd_seq.addr     = addr;
        rd_seq.first_be = 4'h0;   // Zero BE triggers UR in many EP models
        rd_seq.last_be  = 4'h0;
        rd_seq.is_64bit = (addr[63:32] != 0);
        rd_seq.endpoint_completion_adapter = endpoint_completion_adapter;
        rd_seq.endpoint_pcie_id = pcie_id;
        rd_seq.endpoint_pcie_id_valid = pcie_id_valid;

        `uvm_info("BAR_ACCESSOR",
            $sformatf("read_reg_with_error: BAR%0d offset=0x%08h (injecting error)",
                      bar_id, offset), UVM_MEDIUM)

        rd_seq.start(pcie_rc_seqr);

        data = rd_seq.cpl_ok ? extract_data_by_be(rd_seq.rdata, be) : '0;
    endtask

    // ========================================================================
    // write_reg_with_error
    //
    // Performs an MMIO write with PCIe-level error injection.
    // ========================================================================

    virtual task write_reg_with_error(int unsigned bar_id, bit [31:0] offset,
                                      int unsigned size, bit [31:0] data);
        bit [63:0] addr;
        bit [3:0]  be;
        virtio_bar_mem_wr_seq wr_seq;

        if (bar_id > 5) begin
            `uvm_error("BAR_ACCESSOR",
                $sformatf("Invalid bar_id=%0d (must be 0-5)", bar_id))
            return;
        end

        if (!allow_functional_bar_access(bar_id))
            return;

        if (pcie_rc_seqr == null) begin
            `uvm_fatal("BAR_ACCESSOR",
                "pcie_rc_seqr is null; set it before calling write_reg_with_error()")
        end

        addr = bar_base[bar_id] + {32'h0, offset};
        be   = compute_first_be(size, offset[1:0]);

        wr_seq = virtio_bar_mem_wr_seq::type_id::create("bar_mem_wr_err");
        wr_seq.addr     = addr;
        wr_seq.wdata    = data;
        wr_seq.first_be = 4'h0;  // Zero BE for error injection
        wr_seq.last_be  = 4'h0;
        wr_seq.is_64bit = (addr[63:32] != 0);
        wr_seq.endpoint_completion_adapter = endpoint_completion_adapter;
        wr_seq.endpoint_pcie_id = pcie_id;
        wr_seq.endpoint_pcie_id_valid = pcie_id_valid;

        `uvm_info("BAR_ACCESSOR",
            $sformatf("write_reg_with_error: BAR%0d offset=0x%08h data=0x%08h (injecting error)",
                      bar_id, offset, data), UVM_MEDIUM)

        wr_seq.start(pcie_rc_seqr);
    endtask

endclass : virtio_bar_accessor

`endif // VIRTIO_BAR_ACCESSOR_SV
