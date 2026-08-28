`ifndef DPU_CONFIGURATION_RESOLVER_SV
`define DPU_CONFIGURATION_RESOLVER_SV

// Candidate-only coordinator for the declarative device/resource pipeline.
// Caller-owned configurations and previously published snapshots are never
// modified; output handles are assigned only after both snapshots freeze.
class dpu_configuration_resolver extends uvm_object;
    `uvm_object_utils(dpu_configuration_resolver)

    dpu_placement_normalizer placement_normalizer;
    dpu_device_resolver device_resolver;
    dpu_resource_resolver resource_resolver;

    function new(string name = "dpu_configuration_resolver");
        super.new(name);
        placement_normalizer = dpu_placement_normalizer::type_id::create(
            {name, "_normalizer"});
        device_resolver = dpu_device_resolver::type_id::create(
            {name, "_device_resolver"});
        resource_resolver = dpu_resource_resolver::type_id::create(
            {name, "_resource_resolver"});
    endfunction

    function bit resolve(
        input dpu_device_cfg device_cfg,
        input dpu_resource_placement_cfg placement_cfg,
        output dpu_device_snapshot device_snapshot,
        output dpu_resource_snapshot resource_snapshot,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_device_cfg normalized_cfg;
        dpu_normalized_placement_plan normalized_plan;
        dpu_device_snapshot candidate_device;
        dpu_resource_snapshot candidate_resource;
        string why;

        device_snapshot = null;
        resource_snapshot = null;
        diagnostic = dpu_placement_diagnostic::type_id::create(
            {get_name(), "_diagnostic"});
        diagnostic.clear();

        if (!placement_normalizer.normalize(device_cfg, placement_cfg,
                                            normalized_cfg, normalized_plan,
                                            diagnostic)) begin
            return 0;
        end
        if (!device_resolver.resolve(normalized_cfg, candidate_device, why)) begin
            diagnostic.set_device_resolution_failure(why);
            return 0;
        end
        if (!resource_resolver.resolve(candidate_device, normalized_plan,
                                       candidate_resource, diagnostic)) begin
            return 0;
        end
        if ((candidate_device == null) || !candidate_device.is_frozen() ||
            (candidate_resource == null) || !candidate_resource.is_frozen()) begin
            diagnostic.set(DPU_PLACE_STAGE_CROSS_SNAPSHOT,
                           DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                           "coordinator produced an unfrozen snapshot");
            return 0;
        end
        if (!candidate_resource.references_device_snapshot(candidate_device)) begin
            diagnostic.set(DPU_PLACE_STAGE_CROSS_SNAPSHOT,
                           DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                           "resource snapshot does not reference candidate device snapshot");
            return 0;
        end
        device_snapshot = candidate_device;
        resource_snapshot = candidate_resource;
        diagnostic.clear();
        return 1;
    endfunction
endclass : dpu_configuration_resolver

`endif // DPU_CONFIGURATION_RESOLVER_SV
