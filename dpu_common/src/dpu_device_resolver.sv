`ifndef DPU_DEVICE_RESOLVER_SV
`define DPU_DEVICE_RESOLVER_SV

class dpu_device_resolver extends uvm_object;
    `uvm_object_utils(dpu_device_resolver)

    typedef struct {
        dpu_function_cfg function_cfg;
        dpu_bar_request request;
    } dpu_bar_work_item_t;

    typedef struct {
        dpu_pcie_domain_key_t domain;
        bit [63:0] base;
        bit [63:0] size;
    } dpu_used_bar_t;

    function new(string name = "dpu_device_resolver");
        super.new(name);
    endfunction

    protected function string host_key_name(input int unsigned host_id);
        return $sformatf("h%0d", host_id);
    endfunction

    protected function string domain_key_name(input dpu_pcie_domain_key_t key);
        return dpu_pcie_domain_key_name(key);
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

    protected function bit domain_less(
        input dpu_pcie_domain_key_t lhs,
        input dpu_pcie_domain_key_t rhs
    );
        if (lhs.host_id != rhs.host_id)
            return lhs.host_id < rhs.host_id;
        return lhs.segment_id < rhs.segment_id;
    endfunction

    protected function bit bar_item_less(
        input dpu_bar_work_item_t lhs,
        input dpu_bar_work_item_t rhs
    );
        if (domain_less(lhs.function_cfg.domain_key,
                        rhs.function_cfg.domain_key))
            return 1;
        if (domain_less(rhs.function_cfg.domain_key,
                        lhs.function_cfg.domain_key))
            return 0;
        if (function_less(lhs.function_cfg.key, rhs.function_cfg.key))
            return 1;
        if (function_less(rhs.function_cfg.key, lhs.function_cfg.key))
            return 0;
        return lhs.request.role < rhs.request.role;
    endfunction

    protected function void sort_functions(ref dpu_function_cfg functions[$]);
        dpu_function_cfg swap;

        for (int left = 0; left < functions.size(); left++) begin
            for (int right = left + 1; right < functions.size(); right++) begin
                if (function_less(functions[right].key, functions[left].key)) begin
                    swap = functions[left];
                    functions[left] = functions[right];
                    functions[right] = swap;
                end
            end
        end
    endfunction

    protected function void sort_bar_items(ref dpu_bar_work_item_t items[$]);
        dpu_bar_work_item_t swap;

        for (int left = 0; left < items.size(); left++) begin
            for (int right = left + 1; right < items.size(); right++) begin
                if (bar_item_less(items[right], items[left])) begin
                    swap = items[left];
                    items[left] = items[right];
                    items[right] = swap;
                end
            end
        end
    endfunction

    protected function void sort_windows(ref dpu_mmio_window_cfg windows[$]);
        dpu_mmio_window_cfg swap;

        for (int left = 0; left < windows.size(); left++) begin
            for (int right = left + 1; right < windows.size(); right++) begin
                if ((windows[right].base < windows[left].base) ||
                    ((windows[right].base == windows[left].base) &&
                     (windows[right].limit < windows[left].limit))) begin
                    swap = windows[left];
                    windows[left] = windows[right];
                    windows[right] = swap;
                end
            end
        end
    endfunction

    protected function void sort_bdf_ranges(ref dpu_bdf_range_t ranges[$]);
        dpu_bdf_range_t swap;

        for (int left = 0; left < ranges.size(); left++) begin
            for (int right = left + 1; right < ranges.size(); right++) begin
                if ((ranges[right].first_bdf < ranges[left].first_bdf) ||
                    ((ranges[right].first_bdf == ranges[left].first_bdf) &&
                     (ranges[right].last_bdf < ranges[left].last_bdf))) begin
                    swap = ranges[left];
                    ranges[left] = ranges[right];
                    ranges[right] = swap;
                end
            end
        end
    endfunction

    protected function bit find_domain(
        input dpu_device_cfg cfg,
        input dpu_pcie_domain_key_t key,
        output dpu_pcie_domain_cfg domain
    );
        foreach (cfg.hosts[host_index]) begin
            foreach (cfg.hosts[host_index].pcie_domains[domain_index]) begin
                if (dpu_same_domain_key(
                        cfg.hosts[host_index].pcie_domains[domain_index].key,
                        key)) begin
                    domain = cfg.hosts[host_index].pcie_domains[domain_index];
                    return 1;
                end
            end
        end
        domain = null;
        return 0;
    endfunction

    protected function bit bdf_in_ranges(
        input dpu_pcie_domain_cfg domain,
        input bit [15:0] bdf
    );
        foreach (domain.bdf_ranges[index]) begin
            if ((bdf >= domain.bdf_ranges[index].first_bdf) &&
                (bdf <= domain.bdf_ranges[index].last_bdf))
                return 1;
        end
        return 0;
    endfunction

    protected function bit bdf_reserved(
        input dpu_pcie_domain_cfg domain,
        input bit [15:0] bdf
    );
        foreach (domain.reserved_bdfs[index]) begin
            if (domain.reserved_bdfs[index] == bdf)
                return 1;
        end
        return 0;
    endfunction

    protected function bit bar_request_shape_valid(
        input dpu_function_cfg function_cfg,
        input dpu_bar_request request,
        output string why
    );
        string key_name;

        key_name = dpu_function_key_name(function_cfg.key);
        if ((request.even_bar_id > 4) || (request.even_bar_id[0] != 0)) begin
            why = {"BAR request has an odd or out-of-range pair ", key_name};
            return 0;
        end
        if ((request.size == 0) || (request.alignment == 0)) begin
            why = {"BAR size and alignment must be nonzero ", key_name};
            return 0;
        end
        if ((request.alignment & (request.alignment - 1)) != 0) begin
            why = {"BAR alignment must be a power of two ", key_name};
            return 0;
        end
        if ((request.size & (request.size - 1)) != 0) begin
            why = {"BAR size must be a power of two ", key_name};
            return 0;
        end
        why = "";
        return 1;
    endfunction

    protected function bit ranges_overlap(
        input bit [63:0] lhs_base,
        input bit [63:0] lhs_end,
        input bit [63:0] rhs_base,
        input bit [63:0] rhs_end
    );
        return (lhs_base < rhs_end) && (rhs_base < lhs_end);
    endfunction

    protected function bit compatible_window_contains(
        input dpu_pcie_domain_cfg domain,
        input dpu_bar_request request,
        input bit [63:0] base,
        input bit [63:0] bar_end
    );
        foreach (domain.mmio_windows[index]) begin
            if (domain.mmio_windows[index].allows_role(request.role) &&
                (base >= domain.mmio_windows[index].base) &&
                (bar_end <= domain.mmio_windows[index].limit))
                return 1;
        end
        return 0;
    endfunction

    protected function bit valid_function_key(
        input dpu_function_key_t key,
        input dpu_dut_caps caps,
        output string why
    );
        why = "";
        if (key.host_id >= caps.max_hosts) begin
            why = $sformatf("function key host exceeds DUT capability %s",
                            dpu_function_key_name(key));
            return 0;
        end
        if (key.pf_id >= caps.max_pfs_per_host) begin
            why = $sformatf("function key PF exceeds DUT capability %s",
                            dpu_function_key_name(key));
            return 0;
        end
        case (key.kind)
            DPU_FUNCTION_PF: begin
                if (key.vf_id != 0) begin
                    why = $sformatf("PF function key requires vf_id zero %s",
                                    dpu_function_key_name(key));
                    return 0;
                end
            end
            DPU_FUNCTION_VF: begin
                if (key.vf_id >= caps.max_vfs_per_pf) begin
                    why = $sformatf("VF function key exceeds DUT capability %s",
                                    dpu_function_key_name(key));
                    return 0;
                end
            end
            default: begin
                why = $sformatf("function key has unsupported kind %s",
                                dpu_function_key_name(key));
                return 0;
            end
        endcase
        return 1;
    endfunction

    function bit validate(input dpu_device_cfg cfg, output string why);
        bit host_keys[string];
        bit domain_keys[string];
        bit function_keys[string];
        bit service_keys[string];
        bit bar_roles[int unsigned];
        dpu_function_key_t parent_key;
        dpu_service_key_t service_key;
        dpu_bar_profile_t profile;
        string key_name;
        string lookup_why;
        int unsigned vio_service_count;

        why = "";
        if (cfg == null) begin
            why = "device configuration is null";
            return 0;
        end
        if (cfg.dut_caps == null) begin
            why = "device configuration has no DUT capabilities";
            return 0;
        end
        if (!cfg.dut_caps.validate(why))
            return 0;
        if (cfg.functions.size() > cfg.dut_caps.max_functions) begin
            why = $sformatf(
                "configured function count %0d exceeds DUT max_functions %0d",
                cfg.functions.size(), cfg.dut_caps.max_functions);
            return 0;
        end

        foreach (cfg.hosts[host_index]) begin
            if (cfg.hosts[host_index] == null) begin
                why = "device configuration has a null host";
                return 0;
            end
            key_name = host_key_name(cfg.hosts[host_index].host_id);
            if (host_keys.exists(key_name)) begin
                why = {"duplicate host key ", key_name};
                return 0;
            end
            host_keys[key_name] = 1;
            if (cfg.hosts[host_index].host_id >= cfg.dut_caps.max_hosts) begin
                why = $sformatf("host key exceeds DUT capability %s", key_name);
                return 0;
            end
            foreach (cfg.hosts[host_index].pcie_domains[domain_index]) begin
                dpu_pcie_domain_cfg domain;

                domain = cfg.hosts[host_index].pcie_domains[domain_index];
                if (domain == null) begin
                    why = {"host has a null PCIe domain ", key_name};
                    return 0;
                end
                key_name = domain_key_name(domain.key);
                if (domain_keys.exists(key_name)) begin
                    why = {"duplicate PCIe domain key ", key_name};
                    return 0;
                end
                domain_keys[key_name] = 1;
                if (domain.key.host_id != cfg.hosts[host_index].host_id) begin
                    why = {"PCIe domain key does not belong to host ", key_name};
                    return 0;
                end
                foreach (domain.bdf_ranges[range_index]) begin
                    if (domain.bdf_ranges[range_index].first_bdf >
                        domain.bdf_ranges[range_index].last_bdf) begin
                        why = {"PCIe domain has an invalid BDF range ", key_name};
                        return 0;
                    end
                end
                foreach (domain.mmio_windows[window_index]) begin
                    if (domain.mmio_windows[window_index] == null) begin
                        why = {"PCIe domain has a null MMIO window ", key_name};
                        return 0;
                    end
                    if (domain.mmio_windows[window_index].base >=
                        domain.mmio_windows[window_index].limit) begin
                        why = {"PCIe domain has an invalid MMIO window ", key_name};
                        return 0;
                    end
                end
                foreach (domain.reserved_mmio_ranges[range_index]) begin
                    if (domain.reserved_mmio_ranges[range_index].base >=
                        domain.reserved_mmio_ranges[range_index].limit) begin
                        why = {"PCIe domain has an invalid reserved MMIO range ",
                               key_name};
                        return 0;
                    end
                end
            end
        end

        foreach (cfg.functions[function_index]) begin
            if (cfg.functions[function_index] == null) begin
                why = "device configuration has a null function";
                return 0;
            end
            key_name = dpu_function_key_name(cfg.functions[function_index].key);
            if (function_keys.exists(key_name)) begin
                why = {"duplicate function key ", key_name};
                return 0;
            end
            if (!valid_function_key(cfg.functions[function_index].key,
                                    cfg.dut_caps, why))
                return 0;
            function_keys[key_name] = 1;
            if (cfg.functions[function_index].domain_key.host_id !=
                cfg.functions[function_index].key.host_id) begin
                why = {"function refers to a domain on another host ", key_name};
                return 0;
            end
            if (!domain_keys.exists(
                    domain_key_name(cfg.functions[function_index].domain_key))) begin
                why = {"function refers to an undeclared PCIe domain ", key_name};
                return 0;
            end
            if ((cfg.functions[function_index].bdf_mode != DPU_ALLOC_AUTO) &&
                (cfg.functions[function_index].bdf_mode != DPU_ALLOC_PINNED)) begin
                why = {"function has an unsupported BDF allocation mode ", key_name};
                return 0;
            end
        end

        foreach (cfg.functions[function_index]) begin
            if (cfg.functions[function_index].key.kind == DPU_FUNCTION_VF) begin
                parent_key.host_id = cfg.functions[function_index].key.host_id;
                parent_key.pf_id = cfg.functions[function_index].key.pf_id;
                parent_key.kind = DPU_FUNCTION_PF;
                parent_key.vf_id = 0;
                if (!function_keys.exists(dpu_function_key_name(parent_key))) begin
                    why = {"VF function requires its declared parent PF ",
                           dpu_function_key_name(cfg.functions[function_index].key)};
                    return 0;
                end
            end
        end

        foreach (cfg.functions[function_index]) begin
            vio_service_count = 0;
            bar_roles.delete();
            foreach (cfg.functions[function_index].services[service_index]) begin
                if (cfg.functions[function_index].services[service_index] == null) begin
                    why = {"function has a null service declaration ",
                           dpu_function_key_name(cfg.functions[function_index].key)};
                    return 0;
                end
                service_key.function_key = cfg.functions[function_index].key;
                service_key.service_kind =
                    cfg.functions[function_index].services[service_index].service_kind;
                service_key.service_instance_id =
                    cfg.functions[function_index].services[service_index].service_instance_id;
                key_name = dpu_service_key_name(service_key);
                if (service_keys.exists(key_name)) begin
                    why = {"duplicate service key ", key_name};
                    return 0;
                end
                service_keys[key_name] = 1;
                case (service_key.service_kind)
                    DPU_SERVICE_VIO_NET: begin
                        vio_service_count++;
                        if (vio_service_count > 1) begin
                            why = {
                                "current DUT profile permits one VIO-net instance per function ",
                                dpu_function_key_name(
                                    cfg.functions[function_index].key)};
                            return 0;
                        end
                    end
                    DPU_SERVICE_RDMA, DPU_SERVICE_VBLK: begin end
                    default: begin
                        why = {"service declaration has unsupported kind ", key_name};
                        return 0;
                    end
                endcase
            end
            foreach (cfg.functions[function_index].bars[bar_index]) begin
                dpu_bar_request bar;

                bar = cfg.functions[function_index].bars[bar_index];
                key_name = dpu_function_key_name(cfg.functions[function_index].key);
                if (bar == null) begin
                    why = {"function has a null BAR request ", key_name};
                    return 0;
                end
                case (bar.role)
                    DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX: begin end
                    default: begin
                        why = {"BAR request has unsupported role ", key_name};
                        return 0;
                    end
                endcase
                if (bar_roles.exists(bar.role)) begin
                    why = {"BAR request has duplicate role ", key_name};
                    return 0;
                end
                bar_roles[bar.role] = 1;
                if ((bar.placement != DPU_ALLOC_AUTO) &&
                    (bar.placement != DPU_ALLOC_PINNED)) begin
                    why = {"BAR request has unsupported placement mode ", key_name};
                    return 0;
                end
                if (!cfg.dut_caps.lookup_bar_profile(
                        cfg.functions[function_index].key.kind, bar.role,
                        profile, lookup_why)) begin
                    why = {"BAR request role is not available in the DUT profile ",
                           key_name};
                    return 0;
                end
                if ((bar.even_bar_id != profile.even_bar_id) ||
                    (bar.size != profile.size) ||
                    (bar.alignment != profile.alignment)) begin
                    why = {"BAR request role/pair does not match the DUT profile ",
                           key_name};
                    return 0;
                end
            end
        end

        if (cfg.af_request == null) begin
            why = "device configuration has no AF request";
            return 0;
        end
        if (cfg.af_request.mode != DPU_AF_SELECTED) begin
            why = "AF request has an unsupported selection mode";
            return 0;
        end
        key_name = dpu_function_key_name(cfg.af_request.requester);
        if ((cfg.af_request.requester.kind != DPU_FUNCTION_PF) ||
            (cfg.af_request.requester.pf_id != 0) ||
            (cfg.af_request.requester.vf_id != 0) ||
            !function_keys.exists(key_name)) begin
            why = {"AF requester must be a declared PF0 ", key_name};
            return 0;
        end
        return 1;
    endfunction

    function bit resolve(
        input dpu_device_cfg cfg,
        output dpu_device_snapshot snapshot,
        output string why
    );
        dpu_device_cfg workspace;
        dpu_function_cfg functions[$];
        dpu_bar_work_item_t bar_items[$];
        dpu_used_bar_t used_bars[$];
        dpu_pcie_function_id_t pcie_by_function[string];
        dpu_bar_pair_lease_t bars_by_name[string];
        bit used_bdfs[string];
        dpu_device_snapshot candidate_snapshot;

        snapshot = null;
        why = "";
        if (cfg == null) begin
            why = "device configuration is null";
            return 0;
        end

        workspace = dpu_device_cfg::type_id::create({get_name(), "_workspace"});
        workspace.copy_from(cfg);
        if (!validate(workspace, why))
            return 0;

        foreach (workspace.functions[index])
            functions.push_back(workspace.functions[index]);
        sort_functions(functions);

        // Exact BDFs reserve their domain-qualified identities before AUTO
        // requests are considered, regardless of canonical function order.
        foreach (functions[index]) begin
            dpu_pcie_domain_cfg domain;
            dpu_pcie_function_id_t pcie_id;
            string pcie_name;

            if (functions[index].bdf_mode != DPU_ALLOC_PINNED)
                continue;
            if (!find_domain(workspace, functions[index].domain_key, domain)) begin
                why = {"function refers to an undeclared PCIe domain ",
                       dpu_function_key_name(functions[index].key)};
                return 0;
            end
            if (!bdf_in_ranges(domain, functions[index].pinned_bdf)) begin
                why = {"pinned BDF is outside configured BDF ranges ",
                       dpu_function_key_name(functions[index].key)};
                return 0;
            end
            if (bdf_reserved(domain, functions[index].pinned_bdf)) begin
                why = {"pinned request uses a reserved BDF ",
                       dpu_function_key_name(functions[index].key)};
                return 0;
            end
            pcie_id.domain = functions[index].domain_key;
            pcie_id.bdf = functions[index].pinned_bdf;
            pcie_name = dpu_pcie_function_id_name(pcie_id);
            if (used_bdfs.exists(pcie_name)) begin
                why = {"same-domain duplicate BDF ", pcie_name};
                return 0;
            end
            used_bdfs[pcie_name] = 1;
            pcie_by_function[dpu_function_key_name(functions[index].key)] =
                pcie_id;
        end

        // Scan sorted authored ranges directly. The widened counter is stopped
        // explicitly after testing the inclusive endpoint, including 16'hffff.
        foreach (functions[index]) begin
            dpu_pcie_domain_cfg domain;
            dpu_pcie_function_id_t pcie_id;
            dpu_bdf_range_t sorted_ranges[$];
            bit found;

            if (functions[index].bdf_mode != DPU_ALLOC_AUTO)
                continue;
            if (!find_domain(workspace, functions[index].domain_key, domain)) begin
                why = {"function refers to an undeclared PCIe domain ",
                       dpu_function_key_name(functions[index].key)};
                return 0;
            end
            found = 0;
            foreach (domain.bdf_ranges[range_index])
                sorted_ranges.push_back(domain.bdf_ranges[range_index]);
            sort_bdf_ranges(sorted_ranges);
            foreach (sorted_ranges[range_index]) begin
                int unsigned candidate;

                candidate = sorted_ranges[range_index].first_bdf;
                forever begin
                    string pcie_name;

                    if (!bdf_reserved(domain, candidate[15:0])) begin
                        pcie_id.domain = functions[index].domain_key;
                        pcie_id.bdf = candidate[15:0];
                        pcie_name = dpu_pcie_function_id_name(pcie_id);
                        if (!used_bdfs.exists(pcie_name)) begin
                            used_bdfs[pcie_name] = 1;
                            pcie_by_function[dpu_function_key_name(
                                functions[index].key)] = pcie_id;
                            found = 1;
                            break;
                        end
                    end
                    if (candidate == sorted_ranges[range_index].last_bdf)
                        break;
                    candidate++;
                end
                if (found)
                    break;
            end
            if (!found) begin
                why = {"BDF space exhausted for ",
                       dpu_function_key_name(functions[index].key)};
                return 0;
            end
        end

        foreach (functions[function_index]) begin
            foreach (functions[function_index].bars[bar_index]) begin
                dpu_bar_work_item_t item;

                item.function_cfg = functions[function_index];
                item.request = functions[function_index].bars[bar_index];
                bar_items.push_back(item);
            end
        end
        sort_bar_items(bar_items);

        // As with BDFs, all exact BAR intervals are established before AUTO.
        foreach (bar_items[index]) begin
            dpu_pcie_domain_cfg domain;
            dpu_bar_pair_lease_t lease;
            dpu_used_bar_t used;
            bit [63:0] bar_end;

            if (bar_items[index].request.placement != DPU_ALLOC_PINNED)
                continue;
            if (!bar_request_shape_valid(bar_items[index].function_cfg,
                                         bar_items[index].request, why))
                return 0;
            if (!find_domain(workspace,
                             bar_items[index].function_cfg.domain_key, domain)) begin
                why = {"BAR request refers to an undeclared PCIe domain ",
                       dpu_function_key_name(bar_items[index].function_cfg.key)};
                return 0;
            end
            if ((bar_items[index].request.pinned_base &
                 (bar_items[index].request.alignment - 1)) != 0) begin
                why = {"misaligned BAR base ", dpu_function_key_name(
                    bar_items[index].function_cfg.key)};
                return 0;
            end
            if (bar_items[index].request.pinned_base >
                (64'hffff_ffff_ffff_ffff - bar_items[index].request.size)) begin
                why = {"BAR address overflow ", dpu_function_key_name(
                    bar_items[index].function_cfg.key)};
                return 0;
            end
            bar_end = bar_items[index].request.pinned_base +
                bar_items[index].request.size;
            if (!compatible_window_contains(domain, bar_items[index].request,
                                             bar_items[index].request.pinned_base,
                                             bar_end)) begin
                why = {"pinned BAR is outside a compatible MMIO window ",
                       dpu_function_key_name(bar_items[index].function_cfg.key)};
                return 0;
            end
            foreach (domain.reserved_mmio_ranges[range_index]) begin
                if (ranges_overlap(bar_items[index].request.pinned_base, bar_end,
                                   domain.reserved_mmio_ranges[range_index].base,
                                   domain.reserved_mmio_ranges[range_index].limit)) begin
                    why = {"pinned BAR overlaps reserved MMIO ",
                           dpu_function_key_name(
                               bar_items[index].function_cfg.key)};
                    return 0;
                end
            end
            foreach (used_bars[used_index]) begin
                bit [63:0] used_end;

                used_end = used_bars[used_index].base +
                    used_bars[used_index].size;
                if (dpu_same_domain_key(used_bars[used_index].domain,
                                        bar_items[index].function_cfg.domain_key) &&
                    ranges_overlap(bar_items[index].request.pinned_base, bar_end,
                                   used_bars[used_index].base, used_end)) begin
                    why = {"same-domain BAR overlap ", dpu_function_key_name(
                        bar_items[index].function_cfg.key)};
                    return 0;
                end
            end
            lease.role = bar_items[index].request.role;
            lease.even_bar_id = bar_items[index].request.even_bar_id;
            lease.base = bar_items[index].request.pinned_base;
            lease.size = bar_items[index].request.size;
            bars_by_name[dpu_function_bar_key_name(
                bar_items[index].function_cfg.key, lease.role)] = lease;
            used.domain = bar_items[index].function_cfg.domain_key;
            used.base = lease.base;
            used.size = lease.size;
            used_bars.push_back(used);
        end

        foreach (bar_items[index]) begin
            dpu_pcie_domain_cfg domain;
            dpu_mmio_window_cfg windows[$];
            dpu_bar_pair_lease_t lease;
            dpu_used_bar_t used;
            bit found;

            if (bar_items[index].request.placement != DPU_ALLOC_AUTO)
                continue;
            if (!bar_request_shape_valid(bar_items[index].function_cfg,
                                         bar_items[index].request, why))
                return 0;
            if (!find_domain(workspace,
                             bar_items[index].function_cfg.domain_key, domain)) begin
                why = {"BAR request refers to an undeclared PCIe domain ",
                       dpu_function_key_name(bar_items[index].function_cfg.key)};
                return 0;
            end
            foreach (domain.mmio_windows[window_index])
                windows.push_back(domain.mmio_windows[window_index]);
            sort_windows(windows);
            found = 0;
            foreach (windows[window_index]) begin
                bit [63:0] cursor;

                if (!windows[window_index].allows_role(
                        bar_items[index].request.role))
                    continue;
                cursor = windows[window_index].base;
                while (cursor < windows[window_index].limit) begin
                    bit [63:0] aligned_base;
                    bit [63:0] bar_end;
                    bit [63:0] blocker_limit;

                    if (cursor > (64'hffff_ffff_ffff_ffff -
                                  (bar_items[index].request.alignment - 1))) begin
                        why = {"BAR alignment arithmetic overflow ",
                               dpu_function_key_name(
                                   bar_items[index].function_cfg.key)};
                        return 0;
                    end
                    aligned_base = (cursor +
                        bar_items[index].request.alignment - 1) &
                        ~(bar_items[index].request.alignment - 1);
                    if ((aligned_base >= windows[window_index].limit) ||
                        (bar_items[index].request.size >
                         (windows[window_index].limit - aligned_base)))
                        break;
                    bar_end = aligned_base + bar_items[index].request.size;
                    blocker_limit = '0;
                    foreach (domain.reserved_mmio_ranges[range_index]) begin
                        if (ranges_overlap(
                                aligned_base, bar_end,
                                domain.reserved_mmio_ranges[range_index].base,
                                domain.reserved_mmio_ranges[range_index].limit) &&
                            (domain.reserved_mmio_ranges[range_index].limit >
                             blocker_limit))
                            blocker_limit =
                                domain.reserved_mmio_ranges[range_index].limit;
                    end
                    foreach (used_bars[used_index]) begin
                        bit [63:0] used_end;

                        used_end = used_bars[used_index].base +
                            used_bars[used_index].size;
                        if (dpu_same_domain_key(
                                used_bars[used_index].domain,
                                bar_items[index].function_cfg.domain_key) &&
                            ranges_overlap(aligned_base, bar_end,
                                           used_bars[used_index].base,
                                           used_end) &&
                            (used_end > blocker_limit))
                            blocker_limit = used_end;
                    end
                    if (blocker_limit != 0) begin
                        cursor = blocker_limit;
                        continue;
                    end
                    lease.role = bar_items[index].request.role;
                    lease.even_bar_id = bar_items[index].request.even_bar_id;
                    lease.base = aligned_base;
                    lease.size = bar_items[index].request.size;
                    bars_by_name[dpu_function_bar_key_name(
                        bar_items[index].function_cfg.key, lease.role)] = lease;
                    used.domain = bar_items[index].function_cfg.domain_key;
                    used.base = lease.base;
                    used.size = lease.size;
                    used_bars.push_back(used);
                    found = 1;
                    break;
                end
                if (found)
                    break;
            end
            if (!found) begin
                why = {"BAR space exhausted for ",
                       dpu_function_key_name(bar_items[index].function_cfg.key),
                       $sformatf(" role %0d", bar_items[index].request.role)};
                return 0;
            end
        end

        candidate_snapshot = dpu_device_snapshot::type_id::create(
            {get_name(), "_candidate_snapshot"});
        if (!candidate_snapshot.set_dut_caps(workspace.dut_caps, why))
            return 0;
        foreach (functions[index]) begin
            string function_name;

            function_name = dpu_function_key_name(functions[index].key);
            if (!pcie_by_function.exists(function_name)) begin
                why = {"internal resolver missing BDF ", function_name};
                return 0;
            end
            if (!candidate_snapshot.add_function(
                    functions[index].key, pcie_by_function[function_name], why))
                return 0;
        end
        foreach (bar_items[index]) begin
            string bar_name;

            bar_name = dpu_function_bar_key_name(
                bar_items[index].function_cfg.key,
                bar_items[index].request.role);
            if (!bars_by_name.exists(bar_name)) begin
                why = {"internal resolver missing BAR ", bar_name};
                return 0;
            end
            if (!candidate_snapshot.add_bar(
                    bar_items[index].function_cfg.key,
                    bars_by_name[bar_name], why))
                return 0;
        end
        foreach (functions[function_index]) begin
            foreach (functions[function_index].services[service_index]) begin
                dpu_service_key_t service;

                service.function_key = functions[function_index].key;
                service.service_kind = functions[function_index].services[
                    service_index].service_kind;
                service.service_instance_id = functions[function_index].services[
                    service_index].service_instance_id;
                if (!candidate_snapshot.add_service(service, why))
                    return 0;
            end
        end
        if (workspace.af_request.requester.host_id > 7) begin
            why = {"selected AF host ID exceeds three-bit hardware field ",
                   dpu_function_key_name(workspace.af_request.requester)};
            return 0;
        end
        if (!candidate_snapshot.set_expected_af(
                workspace.af_request.requester, why))
            return 0;
        if (!candidate_snapshot.freeze(why))
            return 0;

        snapshot = candidate_snapshot;
        why = "";
        return 1;
    endfunction
endclass : dpu_device_resolver

`endif // DPU_DEVICE_RESOLVER_SV
