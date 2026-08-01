`ifndef VIRTIO_TLM_COMPLETION_ADAPTER_SV
`define VIRTIO_TLM_COMPLETION_ADAPTER_SV

// Reusable completion path for TLM PCIe tests.  PCIe RC drivers own the
// response route, while virtio BAR helper sequences consume completions from
// this adapter instead of waiting on a sequence response that the TLM driver
// does not return.
class virtio_tlm_completion_adapter extends uvm_object;
    `uvm_object_utils(virtio_tlm_completion_adapter)

    // A completion can arrive before the sequence that owns its tag reaches
    // the wait.  Keep every accepted completion until its {tag, requester_id}
    // owner claims it; never let an unrelated waiter consume it from a FIFO.
    protected pcie_tl_cpl_tlp retained_cpls[$];
    protected uvm_event cpl_available;
    protected static virtio_tlm_completion_adapter factory_owner;
    protected pcie_tl_base_driver registered_rc_driver;
    int unsigned completions_received;
    int unsigned completions_consumed;

    function new(string name = "virtio_tlm_completion_adapter");
        super.new(name);
        cpl_available = new("tlm_completion_available");
    endfunction

    extern virtual function void install_factory_overrides();

    extern virtual function void register_rc_driver(pcie_tl_base_driver rc_driver);

    extern virtual function void bind_registered_rc_driver();

    extern virtual function void bind_rc_driver(pcie_tl_base_driver rc_driver);

    static function virtio_tlm_completion_adapter get_factory_owner();
        return factory_owner;
    endfunction

    virtual function void drain();
        retained_cpls.delete();
    endfunction

    virtual task wait_matching_completion(
        input int unsigned timeout_ns,
        input bit [9:0] expected_tag,
        input bit [15:0] expected_requester_id,
        ref pcie_tl_cpl_tlp cpl,
        ref bit ok
    );
        time deadline;
        time remaining;

        ok = 0;
        cpl = null;
        deadline = $time + (timeout_ns * 1ns);
        forever begin
            foreach (retained_cpls[index]) begin
                if (retained_cpls[index].tag == expected_tag &&
                    retained_cpls[index].requester_id == expected_requester_id) begin
                    cpl = retained_cpls[index];
                    retained_cpls.delete(index);
                    completions_consumed++;
                    ok = 1;
                    return;
                end
            end

            if ($time >= deadline)
                return;

            remaining = deadline - $time;
            fork : wait_matching_completion_blk
                cpl_available.wait_trigger();
                #(remaining);
            join_any
            disable wait_matching_completion_blk;
        end
    endtask

    virtual function void put_completion(pcie_tl_cpl_tlp cpl);
        retained_cpls.push_back(cpl);
        completions_received++;
        cpl_available.trigger();
    endfunction
endclass : virtio_tlm_completion_adapter

class virtio_tlm_rc_driver_shim extends pcie_tl_rc_driver;
    `uvm_component_utils(virtio_tlm_rc_driver_shim)

    virtio_tlm_completion_adapter adapter;

    function new(string name = "virtio_tlm_rc_driver_shim",
                 uvm_component parent = null);
        virtio_tlm_completion_adapter owner;
        super.new(name, parent);
        owner = virtio_tlm_completion_adapter::get_factory_owner();
        if (owner != null)
            owner.register_rc_driver(this);
    endfunction

    virtual function bit handle_completion(pcie_tl_cpl_tlp cpl);
        bit result;
        result = super.handle_completion(cpl);
        if (result && adapter != null)
            adapter.put_completion(cpl);
        return result;
    endfunction
endclass : virtio_tlm_rc_driver_shim

class virtio_tlm_bar_mem_rd_seq extends virtio_bar_mem_rd_seq;
    `uvm_object_utils(virtio_tlm_bar_mem_rd_seq)

    static virtio_tlm_completion_adapter adapter;

    function new(string name = "virtio_tlm_bar_mem_rd_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_mem_tlp tlp;
        pcie_tl_cpl_tlp cpl;
        bit ok;

        tlp = pcie_tl_mem_tlp::type_id::create("mem_rd_tlp");
        start_item(tlp);
        tlp.kind = TLP_MEM_RD;
        // PCIe Memory Request addresses identify a DWord; the requested
        // bytes within it are selected by first_be.  Keep the accessor's
        // byte enables intact, but align this TLM request so the EP returns
        // the same DWord that read_reg() subsequently extracts from.
        tlp.addr = {addr[63:2], 2'b00};
        tlp.length = 10'h1;
        tlp.first_be = first_be;
        tlp.last_be = last_be;
        tlp.is_64bit = is_64bit || (addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
        tlp.type_f = TLP_TYPE_MEM_RD;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        finish_item(tlp);

        cpl_ok = 0;
        rdata = '0;
        if (adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Memory-read adapter is not bound")
            return;
        end
        adapter.wait_matching_completion(
            50000, tlp.tag, tlp.requester_id, cpl, ok);
        if (!ok || cpl == null) begin
            `uvm_warning("TLM_COMPLETION",
                         $sformatf("Completion timeout for addr=0x%016h", addr))
            return;
        end
        cpl_ok = 1;
        if (cpl.payload.size() >= 4)
            rdata = {cpl.payload[3], cpl.payload[2],
                     cpl.payload[1], cpl.payload[0]};
        else
            for (int i = 0; i < cpl.payload.size(); i++)
                rdata[i*8 +: 8] = cpl.payload[i];
    endtask
endclass : virtio_tlm_bar_mem_rd_seq

class virtio_tlm_bar_mem_wr_seq extends virtio_bar_mem_wr_seq;
    `uvm_object_utils(virtio_tlm_bar_mem_wr_seq)

    function new(string name = "virtio_tlm_bar_mem_wr_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_mem_tlp tlp;

        tlp = pcie_tl_mem_tlp::type_id::create("mem_wr_tlp");
        start_item(tlp);
        tlp.kind = TLP_MEM_WR;
        // A PCIe Memory Write address identifies its containing DWord; byte
        // enables select payload lanes in that DWord.  BAR writes pass their
        // input data right-justified, so pack sequential source bytes into
        // the enabled lanes (for example offset 2 / BE=C uses lanes 2 and 3).
        tlp.addr = {addr[63:2], 2'b00};
        tlp.length = 10'h1;
        tlp.first_be = first_be;
        tlp.last_be = last_be;
        tlp.is_64bit = is_64bit || (addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        tlp.payload = new[4];
        begin
            int source_byte;
            source_byte = 0;
            for (int lane = 0; lane < 4; lane++) begin
                tlp.payload[lane] = '0;
                if (first_be[lane]) begin
                    tlp.payload[lane] = wdata[source_byte*8 +: 8];
                    source_byte++;
                end
            end
        end
        finish_item(tlp);
    endtask
endclass : virtio_tlm_bar_mem_wr_seq

class virtio_tlm_bar_cfg_rd_seq extends virtio_bar_cfg_rd_seq;
    `uvm_object_utils(virtio_tlm_bar_cfg_rd_seq)

    static virtio_tlm_completion_adapter adapter;

    function new(string name = "virtio_tlm_bar_cfg_rd_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_cfg_tlp tlp;
        pcie_tl_cpl_tlp cpl;
        bit ok;

        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_rd_tlp");
        start_item(tlp);
        tlp.kind = TLP_CFG_RD0;
        tlp.fmt = FMT_3DW_NO_DATA;
        tlp.type_f = TLP_TYPE_CFG_RD0;
        tlp.completer_id = target_bdf;
        tlp.reg_num = reg_num;
        tlp.first_be = first_be;
        tlp.length = 10'h1;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        finish_item(tlp);

        cpl_ok = 0;
        rdata = '0;
        if (adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Config-read adapter is not bound")
            return;
        end
        adapter.wait_matching_completion(
            50000, tlp.tag, tlp.requester_id, cpl, ok);
        if (!ok || cpl == null) begin
            `uvm_warning("TLM_COMPLETION",
                         $sformatf("Completion timeout for config register %0d", reg_num))
            return;
        end
        cpl_ok = 1;
        if (cpl.payload.size() >= 4)
            rdata = {cpl.payload[3], cpl.payload[2],
                     cpl.payload[1], cpl.payload[0]};
        else
            for (int i = 0; i < cpl.payload.size(); i++)
                rdata[i*8 +: 8] = cpl.payload[i];
    endtask
endclass : virtio_tlm_bar_cfg_rd_seq

class virtio_tlm_bar_cfg_wr_seq extends virtio_bar_cfg_wr_seq;
    `uvm_object_utils(virtio_tlm_bar_cfg_wr_seq)

    static virtio_tlm_completion_adapter adapter;

    function new(string name = "virtio_tlm_bar_cfg_wr_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tl_cfg_tlp tlp;
        pcie_tl_cpl_tlp cpl;
        bit ok;

        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_wr_tlp");
        start_item(tlp);
        tlp.kind = TLP_CFG_WR0;
        tlp.fmt = FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_CFG_WR0;
        tlp.completer_id = target_bdf;
        tlp.reg_num = reg_num;
        tlp.first_be = first_be;
        tlp.length = 10'h1;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        tlp.payload = new[4];
        tlp.payload[0] = wdata[7:0];
        tlp.payload[1] = wdata[15:8];
        tlp.payload[2] = wdata[23:16];
        tlp.payload[3] = wdata[31:24];
        finish_item(tlp);

        if (adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Config-write adapter is not bound")
            return;
        end
        adapter.wait_matching_completion(
            50000, tlp.tag, tlp.requester_id, cpl, ok);
    endtask
endclass : virtio_tlm_bar_cfg_wr_seq

function void virtio_tlm_completion_adapter::install_factory_overrides();
    if (factory_owner != null && factory_owner != this) begin
        `uvm_fatal("TLM_COMPLETION",
                   "A distinct completion adapter already owns the factory overrides")
        return;
    end
    factory_owner = this;
    pcie_tl_rc_driver::type_id::set_type_override(
        virtio_tlm_rc_driver_shim::get_type());
    virtio_bar_mem_rd_seq::type_id::set_type_override(
        virtio_tlm_bar_mem_rd_seq::get_type());
    virtio_bar_mem_wr_seq::type_id::set_type_override(
        virtio_tlm_bar_mem_wr_seq::get_type());
    virtio_bar_cfg_rd_seq::type_id::set_type_override(
        virtio_tlm_bar_cfg_rd_seq::get_type());
    virtio_bar_cfg_wr_seq::type_id::set_type_override(
        virtio_tlm_bar_cfg_wr_seq::get_type());
    virtio_tlm_bar_mem_rd_seq::adapter = this;
    virtio_tlm_bar_cfg_rd_seq::adapter = this;
    virtio_tlm_bar_cfg_wr_seq::adapter = this;
endfunction

function void virtio_tlm_completion_adapter::bind_rc_driver(
    pcie_tl_base_driver rc_driver
);
    virtio_tlm_rc_driver_shim shim;
    if (rc_driver == null) begin
        `uvm_fatal("TLM_COMPLETION", "RC driver is null")
    end
    if (!$cast(shim, rc_driver)) begin
        `uvm_fatal("TLM_COMPLETION",
                   "RC driver was not created as virtio_tlm_rc_driver_shim")
    end
    if (shim.adapter != null && shim.adapter != this) begin
        `uvm_fatal("TLM_COMPLETION",
                   "RC driver is already bound to a distinct completion adapter")
        return;
    end
    if (registered_rc_driver != null && registered_rc_driver != rc_driver) begin
        `uvm_fatal("TLM_COMPLETION",
                   "A distinct RC driver is already registered with this completion adapter")
        return;
    end
    registered_rc_driver = rc_driver;
    shim.adapter = this;
endfunction

function void virtio_tlm_completion_adapter::register_rc_driver(
    pcie_tl_base_driver rc_driver
);
    bind_rc_driver(rc_driver);
endfunction

function void virtio_tlm_completion_adapter::bind_registered_rc_driver();
    if (registered_rc_driver == null) begin
        `uvm_fatal("TLM_COMPLETION",
                   "No factory-created RC driver registered with completion adapter")
        return;
    end
    bind_rc_driver(registered_rc_driver);
endfunction

`endif // VIRTIO_TLM_COMPLETION_ADAPTER_SV
