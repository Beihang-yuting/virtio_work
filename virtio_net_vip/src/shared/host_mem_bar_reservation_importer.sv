`ifndef HOST_MEM_BAR_RESERVATION_IMPORTER_SV
`define HOST_MEM_BAR_RESERVATION_IMPORTER_SV

// Lowers the immutable DPU BAR view into the Host-memory allocator's
// reservation metadata.  BARs outside a Host's configured RAM aperture are
// intentionally ignored: they live in a separate MMIO address space and do
// not consume host backing storage.  A BAR that partially intersects the
// aperture is rejected because silently reserving only part of it would hide
// an address-space collision.
class host_mem_bar_reservation_importer extends uvm_object;
    `uvm_object_utils(host_mem_bar_reservation_importer)

    function new(string name = "host_mem_bar_reservation_importer");
        super.new(name);
    endfunction

    function bit import_snapshot(
        input dpu_device_snapshot snapshot,
        input host_mem_manager manager,
        input int unsigned host_id,
        output string why
    );
        dpu_function_key_t functions[$];
        dpu_bar_pair_lease_t bars[$];
        string query_why;
        string owner;
        int unsigned granule;

        why = "";
        if (snapshot == null) begin
            why = "BAR reservation import received a null snapshot";
            return 0;
        end
        if (!snapshot.is_frozen()) begin
            why = "BAR reservation import requires a frozen snapshot";
            return 0;
        end
        if (manager == null) begin
            why = "BAR reservation import received a null Host manager";
            return 0;
        end
        if (manager.get_host_id() != host_id) begin
            why = $sformatf(
                "BAR reservation Host mismatch: manager=%0d requested=%0d",
                manager.get_host_id(), host_id);
            return 0;
        end
        if (!manager.is_initialized()) begin
            why = $sformatf("Host %0d manager is not initialized", host_id);
            return 0;
        end

        granule = manager.get_min_granule();
        snapshot.list_functions(functions);
        foreach (functions[function_index]) begin
            if (functions[function_index].host_id != host_id)
                continue;
            if (!snapshot.list_bars(functions[function_index], bars,
                                    query_why)) begin
                why = {"could not enumerate BARs for ",
                       dpu_function_key_name(functions[function_index]),
                       ": ", query_why};
                return 0;
            end
            foreach (bars[bar_index]) begin
                if (!manager.intersects_region(bars[bar_index].base,
                                               bars[bar_index].size))
                    continue;
                if (!manager.contains_range(bars[bar_index].base,
                                             bars[bar_index].size)) begin
                    why = $sformatf(
                        "BAR %s partially intersects Host %0d memory aperture",
                        dpu_function_bar_key_name(functions[function_index],
                                                   bars[bar_index].role),
                        host_id);
                    return 0;
                end
                if ((bars[bar_index].base % granule) != 0 ||
                    (bars[bar_index].size % granule) != 0) begin
                    why = $sformatf(
                        "BAR %s is not aligned to Host granule %0d",
                        dpu_function_bar_key_name(functions[function_index],
                                                   bars[bar_index].role),
                        granule);
                    return 0;
                end
                owner = dpu_function_bar_key_name(
                    functions[function_index], bars[bar_index].role);
                if (!manager.reserve_range(bars[bar_index].base,
                                            bars[bar_index].size, owner,
                                            `__FILE__, `__LINE__)) begin
                    why = {"could not reserve ", owner};
                    return 0;
                end
            end
        end
        return 1;
    endfunction
endclass

`endif
