`ifndef DPU_DEVICE_SNAPSHOT_SV
`define DPU_DEVICE_SNAPSHOT_SV

class dpu_device_snapshot extends uvm_object;
    `uvm_object_utils(dpu_device_snapshot)

    protected bit m_frozen;
    protected bit m_has_caps;
    protected bit m_has_expected_af;
    protected dpu_dut_caps m_dut_caps;
    protected dpu_function_key_t m_functions[string];
    protected dpu_pcie_function_id_t m_pcie_ids[string];
    // The real AF allocates a global function slot before programming the
    // pre-requester tables.  Freeze assigns the same deterministic first-fit
    // namespace to the canonical function order so later register builders
    // never invent an ID while lowering a plan.
    protected int unsigned m_global_function_ids[string];
    protected dpu_function_key_t m_reverse_functions[string];
    protected dpu_bar_pair_lease_t m_bars[string];
    protected dpu_pcie_domain_key_t m_bar_domains[string];
    protected dpu_function_key_t m_bar_functions[string];
    protected dpu_service_key_t m_services[string];
    protected dpu_function_key_t m_service_owners[string];
    protected dpu_function_key_t m_expected_af;
    protected string m_function_order[$];
    protected string m_bar_order[$];
    protected string m_service_order[$];

    function new(string name = "dpu_device_snapshot");
        super.new(name);
        m_frozen = 0;
        m_has_caps = 0;
        m_has_expected_af = 0;
        m_global_function_ids.delete();
    endfunction

    protected function bit function_less(
        input dpu_function_key_t lhs,
        input dpu_function_key_t rhs
    );
        if (lhs.host_id != rhs.host_id)
            return lhs.host_id < rhs.host_id;
        if (lhs.pf_id != rhs.pf_id)
            return lhs.pf_id < rhs.pf_id;
        if (lhs.kind != rhs.kind)
            return lhs.kind < rhs.kind;
        return lhs.vf_id < rhs.vf_id;
    endfunction

    protected function bit service_less(
        input dpu_service_key_t lhs,
        input dpu_service_key_t rhs
    );
        if (function_less(lhs.function_key, rhs.function_key))
            return 1;
        if (function_less(rhs.function_key, lhs.function_key))
            return 0;
        if (lhs.service_kind != rhs.service_kind)
            return lhs.service_kind < rhs.service_kind;
        return lhs.service_instance_id < rhs.service_instance_id;
    endfunction

    protected function bit mutable(output string why);
        if (m_frozen) begin
            why = "snapshot is frozen";
            return 0;
        end
        why = "";
        return 1;
    endfunction

    protected function bit queryable(output string why);
        if (!m_frozen) begin
            why = "snapshot is not frozen";
            return 0;
        end
        why = "";
        return 1;
    endfunction

    protected function bit lookup_bar_address(
        input dpu_pcie_domain_key_t domain,
        input bit [63:0] address,
        output dpu_bar_address_match_t match
    );
        foreach (m_bar_order[index]) begin
            string bar_name;

            bar_name = m_bar_order[index];
            if (m_bars.exists(bar_name) &&
                m_bar_domains.exists(bar_name) &&
                m_bar_functions.exists(bar_name) &&
                dpu_same_domain_key(m_bar_domains[bar_name], domain) &&
                (address >= m_bars[bar_name].base) &&
                ((address - m_bars[bar_name].base) < m_bars[bar_name].size)) begin
                match.function_key = m_bar_functions[bar_name];
                match.role = m_bars[bar_name].role;
                match.bar_base = m_bars[bar_name].base;
                match.bar_size = m_bars[bar_name].size;
                match.offset = address - m_bars[bar_name].base;
                return 1;
            end
        end
        return 0;
    endfunction

    function bit is_frozen();
        return m_frozen;
    endfunction

    function bit set_dut_caps(input dpu_dut_caps caps, output string why);
        if (!mutable(why))
            return 0;
        if (caps == null) begin
            why = "snapshot DUT capabilities are null";
            return 0;
        end
        m_dut_caps = dpu_dut_caps::type_id::create({get_name(), "_caps"});
        m_dut_caps.copy_from(caps);
        m_has_caps = 1;
        return 1;
    endfunction

    function bit add_function(
        input dpu_function_key_t key,
        input dpu_pcie_function_id_t pcie_id,
        output string why
    );
        string function_name;
        string pcie_name;

        if (!mutable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        pcie_name = dpu_pcie_function_id_name(pcie_id);
        if (m_functions.exists(function_name)) begin
            why = {"snapshot duplicate function ", function_name};
            return 0;
        end
        if (m_reverse_functions.exists(pcie_name)) begin
            why = {"snapshot duplicate PCIe ID ", pcie_name};
            return 0;
        end
        if (key.host_id != pcie_id.domain.host_id) begin
            why = {"snapshot function/domain host mismatch ", function_name};
            return 0;
        end
        m_functions[function_name] = key;
        m_pcie_ids[function_name] = pcie_id;
        m_reverse_functions[pcie_name] = key;
        m_function_order.push_back(function_name);
        return 1;
    endfunction

    function bit add_bar(
        input dpu_function_key_t key,
        input dpu_bar_pair_lease_t bar,
        output string why
    );
        string function_name;
        string bar_name;
        bit [63:0] bar_end;

        if (!mutable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        bar_name = dpu_function_bar_key_name(key, bar.role);
        if (!m_functions.exists(function_name)) begin
            why = {"snapshot BAR has unknown function ", function_name};
            return 0;
        end
        if (m_bars.exists(bar_name)) begin
            why = {"snapshot duplicate BAR ", bar_name};
            return 0;
        end
        if ((bar.size == 0) || (bar.base > (64'hffff_ffff_ffff_ffff - bar.size))) begin
            why = {"snapshot BAR has invalid interval ", bar_name};
            return 0;
        end
        bar_end = bar.base + bar.size;
        foreach (m_bar_order[index]) begin
            string other_name;
            bit [63:0] other_end;

            other_name = m_bar_order[index];
            if (dpu_same_domain_key(m_bar_domains[other_name],
                                    m_pcie_ids[function_name].domain)) begin
                other_end = m_bars[other_name].base + m_bars[other_name].size;
                if ((bar.base < other_end) &&
                    (m_bars[other_name].base < bar_end)) begin
                    why = {"snapshot same-domain BAR overlap ", bar_name};
                    return 0;
                end
            end
        end
        m_bars[bar_name] = bar;
        m_bar_domains[bar_name] = m_pcie_ids[function_name].domain;
        m_bar_functions[bar_name] = key;
        m_bar_order.push_back(bar_name);
        return 1;
    endfunction

    function bit add_service(
        input dpu_service_key_t service,
        output string why
    );
        string function_name;
        string service_name;

        if (!mutable(why))
            return 0;
        function_name = dpu_function_key_name(service.function_key);
        service_name = dpu_service_key_name(service);
        if (!m_functions.exists(function_name)) begin
            why = {"snapshot service has unknown function ", service_name};
            return 0;
        end
        if (m_services.exists(service_name)) begin
            why = {"snapshot duplicate service ", service_name};
            return 0;
        end
        m_services[service_name] = service;
        m_service_owners[service_name] = service.function_key;
        m_service_order.push_back(service_name);
        return 1;
    endfunction

    function bit set_expected_af(
        input dpu_function_key_t key,
        output string why
    );
        if (!mutable(why))
            return 0;
        if (!m_functions.exists(dpu_function_key_name(key))) begin
            why = {"snapshot AF has unknown function ",
                   dpu_function_key_name(key)};
            return 0;
        end
        m_expected_af = key;
        m_has_expected_af = 1;
        return 1;
    endfunction

    protected function void sort_indexes();
        string swap_name;

        for (int left = 0; left < m_function_order.size(); left++) begin
            for (int right = left + 1; right < m_function_order.size(); right++) begin
                if (function_less(m_functions[m_function_order[right]],
                                  m_functions[m_function_order[left]])) begin
                    swap_name = m_function_order[left];
                    m_function_order[left] = m_function_order[right];
                    m_function_order[right] = swap_name;
                end
            end
        end
        for (int left = 0; left < m_bar_order.size(); left++) begin
            for (int right = left + 1; right < m_bar_order.size(); right++) begin
                dpu_function_key_t left_key;
                dpu_function_key_t right_key;
                bit should_swap;

                left_key = m_bar_functions[m_bar_order[left]];
                right_key = m_bar_functions[m_bar_order[right]];
                should_swap = function_less(right_key, left_key) ||
                    (!function_less(left_key, right_key) &&
                     !function_less(right_key, left_key) &&
                     (m_bars[m_bar_order[right]].role <
                      m_bars[m_bar_order[left]].role));
                if (should_swap) begin
                    swap_name = m_bar_order[left];
                    m_bar_order[left] = m_bar_order[right];
                    m_bar_order[right] = swap_name;
                end
            end
        end
        for (int left = 0; left < m_service_order.size(); left++) begin
            for (int right = left + 1; right < m_service_order.size(); right++) begin
                if (service_less(m_services[m_service_order[right]],
                                 m_services[m_service_order[left]])) begin
                    swap_name = m_service_order[left];
                    m_service_order[left] = m_service_order[right];
                    m_service_order[right] = swap_name;
                end
            end
        end
    endfunction

    function bit freeze(output string why);
        bit function_names[string];
        bit bar_names[string];
        bit service_names[string];
        string af_name;
        string af_bar_name;

        if (!mutable(why))
            return 0;
        if (!m_has_caps || (m_dut_caps == null)) begin
            why = "snapshot has no DUT capabilities";
            return 0;
        end
        if (!m_has_expected_af) begin
            why = "snapshot has no expected AF";
            return 0;
        end
        if ((m_function_order.size() != m_functions.num()) ||
            (m_pcie_ids.num() != m_functions.num()) ||
            (m_reverse_functions.num() != m_functions.num())) begin
            why = "snapshot PCIe index cardinality mismatch";
            return 0;
        end
        foreach (m_function_order[index]) begin
            string function_name;
            string pcie_name;

            function_name = m_function_order[index];
            if (function_names.exists(function_name) ||
                !m_functions.exists(function_name) ||
                !m_pcie_ids.exists(function_name)) begin
                why = {"snapshot function has no PCIe ID ", function_name};
                return 0;
            end
            function_names[function_name] = 1;
            if (dpu_function_key_name(m_functions[function_name]) !=
                function_name) begin
                why = {"snapshot function index key mismatch ", function_name};
                return 0;
            end
            pcie_name = dpu_pcie_function_id_name(m_pcie_ids[function_name]);
            if (!m_reverse_functions.exists(pcie_name) ||
                !dpu_same_function_key(m_reverse_functions[pcie_name],
                                       m_functions[function_name])) begin
                why = {"snapshot PCIe indexes disagree ", function_name};
                return 0;
            end
        end
        if ((m_bar_order.size() != m_bars.num()) ||
            (m_bar_domains.num() != m_bars.num()) ||
            (m_bar_functions.num() != m_bars.num())) begin
            why = "snapshot BAR index cardinality mismatch";
            return 0;
        end
        foreach (m_bar_order[index]) begin
            string bar_name;
            string owner_name;
            bit owner_matches_key;

            bar_name = m_bar_order[index];
            if (bar_names.exists(bar_name) || !m_bars.exists(bar_name) ||
                !m_bar_domains.exists(bar_name) ||
                !m_bar_functions.exists(bar_name)) begin
                why = {"snapshot BAR index cardinality mismatch ", bar_name};
                return 0;
            end
            bar_names[bar_name] = 1;
            owner_name = dpu_function_key_name(m_bar_functions[bar_name]);
            if (!m_functions.exists(owner_name) ||
                !m_pcie_ids.exists(owner_name)) begin
                why = {"snapshot BAR owning function mismatch ", bar_name};
                return 0;
            end
            owner_matches_key = 0;
            foreach (m_function_order[function_index]) begin
                string candidate_owner_name;

                candidate_owner_name = m_function_order[function_index];
                if (dpu_function_bar_key_name(
                        m_functions[candidate_owner_name],
                        m_bars[bar_name].role) == bar_name) begin
                    owner_matches_key = 1;
                    if (!dpu_same_function_key(
                            m_bar_functions[bar_name],
                            m_functions[candidate_owner_name])) begin
                        why = {"snapshot BAR owning function mismatch ",
                               bar_name};
                        return 0;
                    end
                    break;
                end
            end
            if (!owner_matches_key) begin
                why = {"snapshot BAR key identity mismatch ", bar_name};
                return 0;
            end
            if (!dpu_same_domain_key(m_bar_domains[bar_name],
                                     m_pcie_ids[owner_name].domain)) begin
                why = {"snapshot BAR owning domain mismatch ", bar_name};
                return 0;
            end
            if ((m_bars[bar_name].size == 0) ||
                (m_bars[bar_name].base >
                 (64'hffff_ffff_ffff_ffff - m_bars[bar_name].size))) begin
                why = {"snapshot BAR interval is invalid ", bar_name};
                return 0;
            end
        end
        for (int left = 0; left < m_bar_order.size(); left++) begin
            string left_name;
            bit [63:0] left_end;

            left_name = m_bar_order[left];
            left_end = m_bars[left_name].base + m_bars[left_name].size;
            for (int right = left + 1; right < m_bar_order.size(); right++) begin
                string right_name;
                bit [63:0] right_end;

                right_name = m_bar_order[right];
                right_end = m_bars[right_name].base +
                    m_bars[right_name].size;
                if (dpu_same_domain_key(m_bar_domains[left_name],
                                        m_bar_domains[right_name]) &&
                    (m_bars[left_name].base < right_end) &&
                    (m_bars[right_name].base < left_end)) begin
                    why = {"snapshot BAR interval overlap ", left_name,
                           " and ", right_name};
                    return 0;
                end
            end
        end
        foreach (m_bar_order[index]) begin
            string bar_name;
            bit [63:0] bar_last;
            dpu_bar_address_match_t match;

            bar_name = m_bar_order[index];
            bar_last = m_bars[bar_name].base + m_bars[bar_name].size - 1;
            if (!lookup_bar_address(m_bar_domains[bar_name],
                                    m_bars[bar_name].base, match)) begin
                why = {"snapshot BAR base address round-trip missing ",
                       bar_name};
                return 0;
            end
            if (
                !dpu_same_function_key(match.function_key,
                                       m_bar_functions[bar_name]) ||
                (match.role != m_bars[bar_name].role) ||
                (match.bar_base != m_bars[bar_name].base) ||
                (match.bar_size != m_bars[bar_name].size) ||
                (match.offset != 0)) begin
                why = {"snapshot BAR base address round-trip mismatch ",
                       bar_name};
                return 0;
            end
            if (!lookup_bar_address(m_bar_domains[bar_name], bar_last,
                                    match)) begin
                why = {"snapshot BAR last address round-trip missing ",
                       bar_name};
                return 0;
            end
            if (
                !dpu_same_function_key(match.function_key,
                                       m_bar_functions[bar_name]) ||
                (match.role != m_bars[bar_name].role) ||
                (match.bar_base != m_bars[bar_name].base) ||
                (match.bar_size != m_bars[bar_name].size) ||
                (match.offset != (m_bars[bar_name].size - 1))) begin
                why = {"snapshot BAR last address round-trip mismatch ",
                       bar_name};
                return 0;
            end
        end
        if ((m_service_order.size() != m_services.num()) ||
            (m_service_owners.num() != m_services.num())) begin
            why = "snapshot service index cardinality mismatch";
            return 0;
        end
        foreach (m_service_order[index]) begin
            string service_name;

            service_name = m_service_order[index];
            if (service_names.exists(service_name) ||
                !m_services.exists(service_name) ||
                !m_service_owners.exists(service_name) ||
                !m_functions.exists(dpu_function_key_name(
                    m_services[service_name].function_key)) ||
                (dpu_service_key_name(m_services[service_name]) !=
                 service_name) ||
                !dpu_same_function_key(m_service_owners[service_name],
                                       m_services[service_name].function_key)) begin
                why = {"snapshot service indexes disagree ", service_name};
                return 0;
            end
            service_names[service_name] = 1;
        end
        af_name = dpu_function_key_name(m_expected_af);
        af_bar_name = dpu_function_bar_key_name(m_expected_af,
                                                DPU_BAR_DEVICE_MEMORY);
        if ((m_expected_af.host_id > 7) ||
            (m_expected_af.kind != DPU_FUNCTION_PF) ||
            (m_expected_af.pf_id != 0) || (m_expected_af.vf_id != 0) ||
            !m_functions.exists(af_name)) begin
            why = {"snapshot expected AF is not an eligible PF0 ", af_name};
            return 0;
        end
        if (!m_bars.exists(af_bar_name) ||
            (m_bars[af_bar_name].role != DPU_BAR_DEVICE_MEMORY) ||
            (m_bars[af_bar_name].even_bar_id != 0)) begin
            why = {"selected AF requires resolved BAR0 device memory ", af_name};
            return 0;
        end
        sort_indexes();
        m_global_function_ids.delete();
        foreach (m_function_order[index])
            m_global_function_ids[m_function_order[index]] = index;
        m_frozen = 1;
        why = "";
        return 1;
    endfunction

    function bit get_pcie_id(
        input dpu_function_key_t key,
        output dpu_pcie_function_id_t pcie_id,
        output string why
    );
        string function_name;

        pcie_id = '{default:'0};
        if (!queryable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        if (!m_pcie_ids.exists(function_name)) begin
            why = {"unknown snapshot function ", function_name};
            return 0;
        end
        pcie_id = m_pcie_ids[function_name];
        return 1;
    endfunction

    function bit get_global_function_id(
        input dpu_function_key_t key,
        output int unsigned global_function_id,
        output string why
    );
        string function_name;

        global_function_id = 0;
        if (!queryable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        if (!m_global_function_ids.exists(function_name)) begin
            why = {"unknown snapshot global function ID ", function_name};
            return 0;
        end
        global_function_id = m_global_function_ids[function_name];
        why = "";
        return 1;
    endfunction

    function bit find_function(
        input dpu_pcie_function_id_t pcie_id,
        output dpu_function_key_t key,
        output string why
    );
        string pcie_name;

        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_PF;
        key.vf_id = 0;
        if (!queryable(why))
            return 0;
        pcie_name = dpu_pcie_function_id_name(pcie_id);
        if (!m_reverse_functions.exists(pcie_name)) begin
            why = {"unknown snapshot PCIe ID ", pcie_name};
            return 0;
        end
        key = m_reverse_functions[pcie_name];
        return 1;
    endfunction

    function bit get_bar(
        input dpu_function_key_t key,
        input dpu_bar_role_e role,
        output dpu_bar_pair_lease_t bar,
        output string why
    );
        string bar_name;

        bar.role = DPU_BAR_DEVICE_MEMORY;
        bar.even_bar_id = 0;
        bar.base = '0;
        bar.size = '0;
        if (!queryable(why))
            return 0;
        bar_name = dpu_function_bar_key_name(key, role);
        if (!m_bars.exists(bar_name)) begin
            why = {"unknown snapshot BAR ", bar_name};
            return 0;
        end
        bar = m_bars[bar_name];
        return 1;
    endfunction

    function bit list_bars(
        input dpu_function_key_t key,
        ref dpu_bar_pair_lease_t bars[$],
        output string why
    );
        bars.delete();
        if (!queryable(why))
            return 0;
        if (!m_functions.exists(dpu_function_key_name(key))) begin
            why = {"unknown snapshot function ", dpu_function_key_name(key)};
            return 0;
        end
        foreach (m_bar_order[index]) begin
            string bar_name;

            bar_name = m_bar_order[index];
            if (dpu_same_function_key(m_bar_functions[bar_name], key))
                bars.push_back(m_bars[bar_name]);
        end
        return 1;
    endfunction

    function bit resolve_bar_address(
        input dpu_pcie_domain_key_t domain,
        input bit [63:0] address,
        output dpu_bar_address_match_t match,
        output string why
    );
        match.function_key.host_id = 0;
        match.function_key.pf_id = 0;
        match.function_key.kind = DPU_FUNCTION_PF;
        match.function_key.vf_id = 0;
        match.role = DPU_BAR_DEVICE_MEMORY;
        match.bar_base = '0;
        match.bar_size = '0;
        match.offset = '0;
        if (!queryable(why))
            return 0;
        if (lookup_bar_address(domain, address, match))
            return 1;
        why = $sformatf("no BAR contains %s address %016h",
                        dpu_pcie_domain_key_name(domain), address);
        return 0;
    endfunction

    function bit get_service_owner(
        input dpu_service_key_t service,
        output dpu_function_key_t owner,
        output string why
    );
        string service_name;

        owner.host_id = 0;
        owner.pf_id = 0;
        owner.kind = DPU_FUNCTION_PF;
        owner.vf_id = 0;
        if (!queryable(why))
            return 0;
        service_name = dpu_service_key_name(service);
        if (!m_service_owners.exists(service_name)) begin
            why = {"unknown snapshot service ", service_name};
            return 0;
        end
        owner = m_service_owners[service_name];
        return 1;
    endfunction

    function void list_functions(ref dpu_function_key_t keys[$]);
        keys.delete();
        if (!m_frozen)
            return;
        foreach (m_function_order[index])
            keys.push_back(m_functions[m_function_order[index]]);
    endfunction

    function void list_services(
        input dpu_service_kind_e kind,
        ref dpu_service_key_t keys[$]
    );
        keys.delete();
        if (!m_frozen)
            return;
        foreach (m_service_order[index]) begin
            if (m_services[m_service_order[index]].service_kind == kind)
                keys.push_back(m_services[m_service_order[index]]);
        end
    endfunction

    function bit get_expected_af(
        output dpu_function_key_t key,
        output dpu_bar_pair_lease_t bar0,
        output string why
    );
        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_PF;
        key.vf_id = 0;
        bar0.role = DPU_BAR_DEVICE_MEMORY;
        bar0.even_bar_id = 0;
        bar0.base = '0;
        bar0.size = '0;
        if (!queryable(why))
            return 0;
        key = m_expected_af;
        bar0 = m_bars[dpu_function_bar_key_name(
            m_expected_af, DPU_BAR_DEVICE_MEMORY)];
        return 1;
    endfunction

    function dpu_dut_caps snapshot_dut_caps();
        dpu_dut_caps caps_copy;

        if (!m_frozen || (m_dut_caps == null))
            return null;
        caps_copy = dpu_dut_caps::type_id::create({get_name(), "_caps_copy"});
        caps_copy.copy_from(m_dut_caps);
        return caps_copy;
    endfunction
endclass : dpu_device_snapshot

`endif // DPU_DEVICE_SNAPSHOT_SV
