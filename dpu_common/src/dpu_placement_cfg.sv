`ifndef DPU_PLACEMENT_CFG_SV
`define DPU_PLACEMENT_CFG_SV

class dpu_vio_candidate_filter extends uvm_object;
    `uvm_object_utils(dpu_vio_candidate_filter)

    int unsigned host_ids[$];
    dpu_function_key_t parent_pf_keys[$];
    int unsigned vf_ids[$];
    dpu_function_key_t function_keys[$];

    function new(string name = "dpu_vio_candidate_filter");
        super.new(name);
    endfunction

    function void copy_from(input dpu_vio_candidate_filter rhs);
        host_ids = rhs.host_ids;
        parent_pf_keys = rhs.parent_pf_keys;
        vf_ids = rhs.vf_ids;
        function_keys = rhs.function_keys;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_candidate_filter typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "candidate filter copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_vio_candidate_filter


class dpu_vio_device_constraint extends uvm_object;
    `uvm_object_utils(dpu_vio_device_constraint)

    dpu_function_key_t function_key;
    dpu_count_constraint_mode_e mode;
    int unsigned qpair_count;

    function new(string name = "dpu_vio_device_constraint");
        super.new(name);
        mode = DPU_COUNT_EXACT;
        qpair_count = 0;
    endfunction

    function void copy_from(input dpu_vio_device_constraint rhs);
        function_key = rhs.function_key;
        mode = rhs.mode;
        qpair_count = rhs.qpair_count;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_device_constraint typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "device constraint copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_vio_device_constraint


class dpu_vio_qpair_override extends uvm_object;
    `uvm_object_utils(dpu_vio_qpair_override)

    int unsigned request_pair_index;
    dpu_assignment_mode_e owner_mode;
    dpu_function_key_t requested_owner;
    dpu_assignment_mode_e local_mode;
    int unsigned requested_local_pair_id;
    dpu_assignment_mode_e global_mode;
    int unsigned requested_global_qpair_id;

    function new(string name = "dpu_vio_qpair_override");
        super.new(name);
        request_pair_index = 0;
        owner_mode = DPU_ASSIGN_AUTO;
        local_mode = DPU_ASSIGN_AUTO;
        global_mode = DPU_ASSIGN_AUTO;
        requested_local_pair_id = 0;
        requested_global_qpair_id = 0;
    endfunction

    function void copy_from(input dpu_vio_qpair_override rhs);
        request_pair_index = rhs.request_pair_index;
        owner_mode = rhs.owner_mode;
        requested_owner = rhs.requested_owner;
        local_mode = rhs.local_mode;
        requested_local_pair_id = rhs.requested_local_pair_id;
        global_mode = rhs.global_mode;
        requested_global_qpair_id = rhs.requested_global_qpair_id;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_qpair_override typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "qpair override copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_vio_qpair_override


class dpu_vio_placement_request extends uvm_object;
    `uvm_object_utils(dpu_vio_placement_request)

    int unsigned request_id;
    int unsigned service_instance_id;
    int unsigned total_qpairs;
    // Number of LAN MSI-X vectors requested for this function.  Zero keeps
    // the driver default (one vector per qpair in this model); a smaller
    // value models the real driver's min(online_cpus, rxq) sharing policy.
    int unsigned lan_msix_vectors;
    int unsigned seed;
    dpu_vio_candidate_kind_e candidate_kind;
    dpu_vio_device_policy_e device_policy;
    dpu_placement_order_e ordering;
    dpu_vio_candidate_filter candidate_filter;
    dpu_function_key_t fixed_devices[$];
    dpu_vio_device_constraint device_constraints[$];
    dpu_vio_qpair_override qpair_overrides[$];

    function new(string name = "dpu_vio_placement_request");
        super.new(name);
        request_id = 0;
        service_instance_id = 0;
        total_qpairs = 0;
        lan_msix_vectors = 0;
        seed = 0;
        candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
        device_policy = DPU_VIO_DEVICE_AUTO_MINIMUM;
        ordering = DPU_PLACEMENT_CANONICAL;
        candidate_filter = dpu_vio_candidate_filter::type_id::create(
            {name, "_candidate_filter"});
    endfunction

    function void copy_from(input dpu_vio_placement_request rhs);
        dpu_vio_device_constraint constraint_copy;
        dpu_vio_qpair_override override_copy;

        request_id = rhs.request_id;
        service_instance_id = rhs.service_instance_id;
        total_qpairs = rhs.total_qpairs;
        lan_msix_vectors = rhs.lan_msix_vectors;
        seed = rhs.seed;
        candidate_kind = rhs.candidate_kind;
        device_policy = rhs.device_policy;
        ordering = rhs.ordering;
        fixed_devices = rhs.fixed_devices;
        if (rhs.candidate_filter == null) begin
            candidate_filter = null;
        end else begin
            candidate_filter = dpu_vio_candidate_filter::type_id::create(
                {get_name(), "_candidate_filter"});
            candidate_filter.copy_from(rhs.candidate_filter);
        end
        device_constraints.delete();
        foreach (rhs.device_constraints[index]) begin
            if (rhs.device_constraints[index] == null) begin
                device_constraints.push_back(null);
            end else begin
                constraint_copy = dpu_vio_device_constraint::type_id::create(
                    $sformatf("%s_constraint_%0d", get_name(), index));
                constraint_copy.copy_from(rhs.device_constraints[index]);
                device_constraints.push_back(constraint_copy);
            end
        end
        qpair_overrides.delete();
        foreach (rhs.qpair_overrides[index]) begin
            if (rhs.qpair_overrides[index] == null) begin
                qpair_overrides.push_back(null);
            end else begin
                override_copy = dpu_vio_qpair_override::type_id::create(
                    $sformatf("%s_override_%0d", get_name(), index));
                override_copy.copy_from(rhs.qpair_overrides[index]);
                qpair_overrides.push_back(override_copy);
            end
        end
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_placement_request typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement request copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_vio_placement_request


class dpu_resource_placement_cfg extends uvm_object;
    `uvm_object_utils(dpu_resource_placement_cfg)

    dpu_resource_pool_config_t profiles[$];
    dpu_vio_placement_request vio_requests[$];
    int unsigned reserved_global_qpair_ids[$];
    dpu_global_id_range_t reserved_global_qpair_ranges[$];

    function new(string name = "dpu_resource_placement_cfg");
        super.new(name);
    endfunction

    function void copy_from(input dpu_resource_placement_cfg rhs);
        dpu_vio_placement_request request_copy;

        profiles = rhs.profiles;
        reserved_global_qpair_ids = rhs.reserved_global_qpair_ids;
        reserved_global_qpair_ranges = rhs.reserved_global_qpair_ranges;
        vio_requests.delete();
        foreach (rhs.vio_requests[index]) begin
            if (rhs.vio_requests[index] == null) begin
                vio_requests.push_back(null);
            end else begin
                request_copy = dpu_vio_placement_request::type_id::create(
                    $sformatf("%s_request_%0d", get_name(), index));
                request_copy.copy_from(rhs.vio_requests[index]);
                vio_requests.push_back(request_copy);
            end
        end
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_resource_placement_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement config copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_resource_placement_cfg


class dpu_placement_diagnostic extends uvm_object;
    `uvm_object_utils(dpu_placement_diagnostic)

    dpu_placement_stage_e stage;
    dpu_placement_error_e error_code;
    bit has_request_id;
    bit has_function_key;
    bit has_service_key;
    bit has_pair_index;
    int unsigned request_id;
    int unsigned request_pair_index;
    dpu_function_key_t function_key;
    dpu_service_key_t service_key;
    string message;

    function new(string name = "dpu_placement_diagnostic");
        super.new(name);
        clear();
    endfunction

    function void clear();
        stage = DPU_PLACE_STAGE_NONE;
        error_code = DPU_PLACE_ERR_NONE;
        has_request_id = 0;
        has_function_key = 0;
        has_service_key = 0;
        has_pair_index = 0;
        request_id = 0;
        request_pair_index = 0;
        function_key.host_id = 0;
        function_key.pf_id = 0;
        function_key.kind = DPU_FUNCTION_PF;
        function_key.vf_id = 0;
        service_key.function_key.host_id = 0;
        service_key.function_key.pf_id = 0;
        service_key.function_key.kind = DPU_FUNCTION_PF;
        service_key.function_key.vf_id = 0;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = 0;
        message = "";
    endfunction

    function void set(
        input dpu_placement_stage_e new_stage,
        input dpu_placement_error_e new_error_code,
        input string new_message
    );
        clear();
        stage = new_stage;
        error_code = new_error_code;
        message = new_message;
    endfunction

    function void set_request_context(input int unsigned value);
        has_request_id = 1;
        request_id = value;
    endfunction

    function void set_function_context(input dpu_function_key_t value);
        has_function_key = 1;
        function_key = value;
    endfunction

    function void set_service_context(input dpu_service_key_t value);
        has_service_key = 1;
        service_key = value;
    endfunction

    function void set_pair_context(input int unsigned value);
        has_pair_index = 1;
        request_pair_index = value;
    endfunction

    function void set_device_resolution_failure(input string detail);
        set(DPU_PLACE_STAGE_DEVICE_RESOLUTION,
            DPU_PLACE_ERR_DEVICE_RESOLUTION_FAILED, detail);
    endfunction

    function void copy_from(input dpu_placement_diagnostic rhs);
        stage = rhs.stage;
        error_code = rhs.error_code;
        has_request_id = rhs.has_request_id;
        has_function_key = rhs.has_function_key;
        has_service_key = rhs.has_service_key;
        has_pair_index = rhs.has_pair_index;
        request_id = rhs.request_id;
        request_pair_index = rhs.request_pair_index;
        function_key = rhs.function_key;
        service_key = rhs.service_key;
        message = rhs.message;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_placement_diagnostic typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement diagnostic copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_placement_diagnostic

`endif // DPU_PLACEMENT_CFG_SV
