`ifndef DPU_DEVICE_RESOLVER_SV
`define DPU_DEVICE_RESOLVER_SV

class dpu_device_resolver extends uvm_object;
    `uvm_object_utils(dpu_device_resolver)

    function new(string name = "dpu_device_resolver");
        super.new(name);
    endfunction

    protected function string host_key_name(input int unsigned host_id);
        return $sformatf("h%0d", host_id);
    endfunction

    protected function string domain_key_name(input dpu_pcie_domain_key_t key);
        return $sformatf("h%0d.s%0d", key.host_id, key.segment_id);
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
endclass : dpu_device_resolver

`endif // DPU_DEVICE_RESOLVER_SV
