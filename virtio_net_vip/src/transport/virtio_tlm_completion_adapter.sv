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
    protected pcie_tl_base_driver retained_cpl_sources[$];
    protected uvm_event cpl_available;
    protected static virtio_tlm_completion_adapter factory_owner;
    protected pcie_tl_base_driver registered_rc_driver;
    protected pcie_tl_base_driver factory_rc_drivers[$];
    protected dpu_pcie_domain_key_t bound_domains[$];
    protected pcie_tl_base_driver bound_domain_drivers[$];
    local bit rc_driver_registration_failed;
    int unsigned completions_received;
    int unsigned completions_consumed;

    function new(string name = "virtio_tlm_completion_adapter");
        super.new(name);
        cpl_available = new("tlm_completion_available");
        rc_driver_registration_failed = 0;
    endfunction

    extern virtual function void install_factory_overrides();

    extern function bit register_rc_driver(pcie_tl_base_driver rc_driver);

    extern function bit bind_registered_rc_driver();

    extern function bit bind_rc_driver(pcie_tl_base_driver rc_driver);

    // Factory discovery is deliberately separate from the legacy one-driver
    // registration contract.  A shared adapter may discover several shims,
    // while register_rc_driver()/bind_rc_driver() continue to reject a second
    // driver exactly as their public compatibility API always has.
    extern function void note_factory_rc_driver(
        pcie_tl_base_driver rc_driver
    );

    extern function bit domain_rc_driver_binding_supported(
        input dpu_pcie_domain_key_t domain,
        input pcie_tl_base_driver rc_driver,
        output string why
    );

    extern function bit bind_domain_rc_driver(
        input dpu_pcie_domain_key_t domain,
        input pcie_tl_base_driver rc_driver
    );

    static function virtio_tlm_completion_adapter get_factory_owner();
        return factory_owner;
    endfunction

    virtual function void drain();
        retained_cpls.delete();
        retained_cpl_sources.delete();
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
                    retained_cpl_sources.delete(index);
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

    virtual task wait_matching_domain_completion(
        input int unsigned timeout_ns,
        input dpu_pcie_function_id_t expected_pcie_id,
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
                bit source_matches_domain;

                source_matches_domain = 0;
                foreach (bound_domains[domain_index]) begin
                    if ((retained_cpl_sources[index] ==
                         bound_domain_drivers[domain_index]) &&
                        dpu_same_domain_key(
                            bound_domains[domain_index],
                            expected_pcie_id.domain)) begin
                        source_matches_domain = 1;
                        break;
                    end
                end
                if (source_matches_domain &&
                    retained_cpls[index].tag == expected_tag &&
                    retained_cpls[index].requester_id ==
                        expected_requester_id) begin
                    cpl = retained_cpls[index];
                    retained_cpls.delete(index);
                    retained_cpl_sources.delete(index);
                    completions_consumed++;
                    ok = 1;
                    return;
                end
            end

            if ($time >= deadline)
                return;

            remaining = deadline - $time;
            fork : wait_matching_domain_completion_blk
                cpl_available.wait_trigger();
                #(remaining);
            join_any
            disable wait_matching_domain_completion_blk;
        end
    endtask

    virtual function void put_completion(pcie_tl_cpl_tlp cpl);
        retained_cpls.push_back(cpl);
        retained_cpl_sources.push_back(null);
        completions_received++;
        cpl_available.trigger();
    endfunction

    virtual function void put_completion_from_driver(
        input pcie_tl_base_driver source_driver,
        input pcie_tl_cpl_tlp cpl
    );
        retained_cpls.push_back(cpl);
        retained_cpl_sources.push_back(source_driver);
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
            owner.note_factory_rc_driver(this);
    endfunction

    virtual function bit handle_completion(pcie_tl_cpl_tlp cpl);
        bit result;
        result = super.handle_completion(cpl);
        if (result && adapter != null)
            adapter.put_completion_from_driver(this, cpl);
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
        virtio_tlm_completion_adapter selected_adapter;
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
        selected_adapter = (endpoint_completion_adapter != null) ?
            endpoint_completion_adapter : adapter;
        if (selected_adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Memory-read adapter is not bound")
            return;
        end
        if ((endpoint_completion_adapter != null) &&
            endpoint_pcie_id_valid) begin
            selected_adapter.wait_matching_domain_completion(
                50000, endpoint_pcie_id, tlp.tag, tlp.requester_id,
                cpl, ok);
        end
        else begin
            selected_adapter.wait_matching_completion(
                50000, tlp.tag, tlp.requester_id, cpl, ok);
        end
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
        virtio_tlm_completion_adapter selected_adapter;
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
        selected_adapter = (endpoint_completion_adapter != null) ?
            endpoint_completion_adapter : adapter;
        if (selected_adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Config-read adapter is not bound")
            return;
        end
        if ((endpoint_completion_adapter != null) &&
            endpoint_pcie_id_valid) begin
            selected_adapter.wait_matching_domain_completion(
                50000, endpoint_pcie_id, tlp.tag, tlp.requester_id,
                cpl, ok);
        end
        else begin
            selected_adapter.wait_matching_completion(
                50000, tlp.tag, tlp.requester_id, cpl, ok);
        end
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
        virtio_tlm_completion_adapter selected_adapter;
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

        selected_adapter = (endpoint_completion_adapter != null) ?
            endpoint_completion_adapter : adapter;
        if (selected_adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Config-write adapter is not bound")
            return;
        end
        if ((endpoint_completion_adapter != null) &&
            endpoint_pcie_id_valid) begin
            selected_adapter.wait_matching_domain_completion(
                50000, endpoint_pcie_id, tlp.tag, tlp.requester_id,
                cpl, ok);
        end
        else begin
            selected_adapter.wait_matching_completion(
                50000, tlp.tag, tlp.requester_id, cpl, ok);
        end
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

function void virtio_tlm_completion_adapter::note_factory_rc_driver(
    pcie_tl_base_driver rc_driver
);
    virtio_tlm_rc_driver_shim shim;

    if (rc_driver == null)
        return;
    foreach (factory_rc_drivers[index]) begin
        if (factory_rc_drivers[index] == rc_driver)
            return;
    end
    factory_rc_drivers.push_back(rc_driver);
    // Preserve the legacy single-driver discovery behavior when exactly one
    // shim exists.  Discovering later shims does not call the public legacy
    // registration API and therefore does not poison multi-domain setup.
    if (registered_rc_driver == null) begin
        registered_rc_driver = rc_driver;
        if ($cast(shim, rc_driver))
            shim.adapter = this;
    end
endfunction

function bit virtio_tlm_completion_adapter::domain_rc_driver_binding_supported(
    input dpu_pcie_domain_key_t domain,
    input pcie_tl_base_driver rc_driver,
    output string why
);
    virtio_tlm_rc_driver_shim shim;

    why = "";
    if (rc_driver == null) begin
        why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
               " has a null RC driver"};
        return 0;
    end
    if (!$cast(shim, rc_driver)) begin
        why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
               " RC driver was not created as virtio_tlm_rc_driver_shim"};
        return 0;
    end
    if ((shim.adapter != null) && (shim.adapter != this)) begin
        why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
               " RC driver is already bound to a distinct completion adapter"};
        return 0;
    end
    foreach (bound_domains[index]) begin
        if (dpu_same_domain_key(bound_domains[index], domain)) begin
            if (bound_domain_drivers[index] != rc_driver) begin
                why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
                       " is already bound to a distinct RC driver"};
                return 0;
            end
            return 1;
        end
        if (bound_domain_drivers[index] == rc_driver) begin
            why = {"RC driver is already bound to distinct PCIe domain ",
                   dpu_pcie_domain_key_name(bound_domains[index])};
            return 0;
        end
    end
    return 1;
endfunction

function bit virtio_tlm_completion_adapter::bind_domain_rc_driver(
    input dpu_pcie_domain_key_t domain,
    input pcie_tl_base_driver rc_driver
);
    virtio_tlm_rc_driver_shim shim;
    string why;

    if (!domain_rc_driver_binding_supported(domain, rc_driver, why)) begin
        `uvm_fatal("TLM_COMPLETION", why)
        return 0;
    end
    foreach (bound_domains[index]) begin
        if (dpu_same_domain_key(bound_domains[index], domain))
            return 1;
    end
    if (!$cast(shim, rc_driver)) begin
        `uvm_fatal("TLM_COMPLETION",
            "validated domain RC driver could not be cast during commit")
        return 0;
    end
    bound_domains.push_back(domain);
    bound_domain_drivers.push_back(rc_driver);
    shim.adapter = this;
    return 1;
endfunction

function bit virtio_tlm_completion_adapter::bind_rc_driver(
    pcie_tl_base_driver rc_driver
);
    virtio_tlm_rc_driver_shim shim;
    if (rc_driver_registration_failed) begin
        `uvm_fatal("TLM_COMPLETION",
                   "Completion adapter RC driver registration previously failed")
        return 0;
    end
    if (rc_driver == null) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION", "RC driver is null")
        return 0;
    end
    if (!$cast(shim, rc_driver)) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION",
                   "RC driver was not created as virtio_tlm_rc_driver_shim")
        return 0;
    end
    if (shim.adapter != null && shim.adapter != this) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION",
                   "RC driver is already bound to a distinct completion adapter")
        return 0;
    end
    if (registered_rc_driver != null && registered_rc_driver != rc_driver) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION",
                   "A distinct RC driver is already registered with this completion adapter")
        return 0;
    end
    registered_rc_driver = rc_driver;
    shim.adapter = this;
    return 1;
endfunction

function bit virtio_tlm_completion_adapter::register_rc_driver(
    pcie_tl_base_driver rc_driver
);
    if (rc_driver_registration_failed) begin
        `uvm_fatal("TLM_COMPLETION",
                   "Completion adapter RC driver registration previously failed")
        return 0;
    end
    if (!bind_rc_driver(rc_driver)) begin
        rc_driver_registration_failed = 1;
        return 0;
    end
    return 1;
endfunction

function bit virtio_tlm_completion_adapter::bind_registered_rc_driver();
    if (rc_driver_registration_failed) begin
        `uvm_fatal("TLM_COMPLETION",
                   "Completion adapter RC driver registration previously failed")
        return 0;
    end
    if (registered_rc_driver == null) begin
        `uvm_fatal("TLM_COMPLETION",
                   "No factory-created RC driver registered with completion adapter")
        return 0;
    end
    return bind_rc_driver(registered_rc_driver);
endfunction

`endif // VIRTIO_TLM_COMPLETION_ADAPTER_SV
