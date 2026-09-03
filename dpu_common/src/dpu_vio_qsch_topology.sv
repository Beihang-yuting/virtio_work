`ifndef DPU_VIO_QSCH_TOPOLOGY_SV
`define DPU_VIO_QSCH_TOPOLOGY_SV

// Logical QSCH topology generation is intentionally separate from register
// lowering.  The topology describes the relationships that verification wants
// to explore; the driver extension later converts it to the audited Q2TC,
// N2G, G2P, and SP/WRR table writes.
typedef enum int unsigned {
    DPU_QSCH_TOPOLOGY_EXPLICIT,
    DPU_QSCH_TOPOLOGY_RANDOM_VALID,
    DPU_QSCH_TOPOLOGY_RANDOM_STRESS
} dpu_qsch_topology_mode_e;

typedef struct {
    int unsigned port_id;
    bit valid;
} dpu_qsch_port_node_cfg_t;

typedef struct {
    int unsigned group_id;
    int unsigned port_id;
    bit valid;
} dpu_qsch_group_node_cfg_t;

typedef struct {
    int unsigned tc_id;
    bit valid;
} dpu_qsch_tc_node_cfg_t;

typedef struct {
    dpu_function_key_t function_key;
    int unsigned net_id;
    int unsigned group_id;
    int unsigned src_port;
    int unsigned dst_port;
    int unsigned spwrr;
    int unsigned tc_weight[8];
    bit weight_valid;
    bit valid;
} dpu_qsch_net_node_cfg_t;

typedef struct {
    dpu_function_key_t owner_function_key;
    int unsigned global_qpair_id;
    int unsigned net_id;
    int unsigned tc_id;
    bit valid;
} dpu_qsch_queue_attachment_cfg_t;

class dpu_qsch_topology_cfg extends uvm_object;
    `uvm_object_utils(dpu_qsch_topology_cfg)

    dpu_qsch_topology_mode_e mode;
    dpu_qsch_port_node_cfg_t ports[$];
    dpu_qsch_group_node_cfg_t groups[$];
    dpu_qsch_tc_node_cfg_t traffic_classes[$];
    dpu_qsch_net_node_cfg_t nets[$];
    dpu_qsch_queue_attachment_cfg_t queues[$];

    // A complete generated topology owns every ordinary VIO qpair.  Keeping
    // this switch explicit also permits a focused incremental plan to carry a
    // subset while still validating every entry that it does contain.
    bit require_all_resource_qpairs;
    bit include_af_extra_queues;

    function new(string name = "dpu_qsch_topology_cfg");
        super.new(name);
        mode = DPU_QSCH_TOPOLOGY_EXPLICIT;
        require_all_resource_qpairs = 1;
        include_af_extra_queues = 0;
        ports.delete();
        groups.delete();
        traffic_classes.delete();
        nets.delete();
        queues.delete();
    endfunction

    local function bit contains_port(input int unsigned port_id);
        foreach (ports[index]) begin
            if (ports[index].valid && (ports[index].port_id == port_id))
                return 1;
        end
        return 0;
    endfunction

    local function bit contains_group(input int unsigned group_id,
                                      output int unsigned group_index);
        group_index = 0;
        foreach (groups[index]) begin
            if (groups[index].valid && (groups[index].group_id == group_id)) begin
                group_index = index;
                return 1;
            end
        end
        return 0;
    endfunction

    local function bit find_net(input int unsigned net_id,
                                output int unsigned net_index);
        net_index = 0;
        foreach (nets[index]) begin
            if (nets[index].valid && (nets[index].net_id == net_id)) begin
                net_index = index;
                return 1;
            end
        end
        return 0;
    endfunction

    local function bit find_queue(input int unsigned global_qpair_id,
                                  output int unsigned queue_index);
        queue_index = 0;
        foreach (queues[index]) begin
            if (queues[index].valid &&
                (queues[index].global_qpair_id == global_qpair_id)) begin
                queue_index = index;
                return 1;
            end
        end
        return 0;
    endfunction

    function bit validate(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        output string why
    );
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t extras[$];
        bit used_groups[string];
        bit used_nets[string];
        int unsigned function_id;
        int unsigned group_index;
        int unsigned queue_index;
        int unsigned expected_qpairs;

        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            why = "QSCH topology requires a frozen device snapshot";
            return 0;
        end
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "QSCH topology requires a frozen resource snapshot";
            return 0;
        end
        if (!resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "QSCH topology snapshots do not reference the same device snapshot";
            return 0;
        end

        foreach (ports[index]) begin
            if (!ports[index].valid)
                continue;
            if (ports[index].port_id > 3) begin
                why = $sformatf("QSCH port ID %0d exceeds the two-bit field",
                               ports[index].port_id);
                return 0;
            end
            foreach (ports[other]) begin
                if ((other < index) && ports[other].valid &&
                    (ports[other].port_id == ports[index].port_id)) begin
                    why = $sformatf("duplicate QSCH port ID %0d",
                                   ports[index].port_id);
                    return 0;
                end
            end
        end

        foreach (groups[index]) begin
            if (!groups[index].valid)
                continue;
            if (groups[index].group_id > 31) begin
                why = $sformatf("QSCH group ID %0d exceeds the five-bit field",
                               groups[index].group_id);
                return 0;
            end
            if (!contains_port(groups[index].port_id)) begin
                why = $sformatf("QSCH group %0d references unknown port %0d",
                               groups[index].group_id, groups[index].port_id);
                return 0;
            end
            foreach (groups[other]) begin
                if ((other < index) && groups[other].valid &&
                    (groups[other].group_id == groups[index].group_id)) begin
                    why = $sformatf("duplicate QSCH group ID %0d",
                                   groups[index].group_id);
                    return 0;
                end
            end
        end

        foreach (traffic_classes[index]) begin
            if (!traffic_classes[index].valid)
                continue;
            if (traffic_classes[index].tc_id > 7) begin
                why = $sformatf("QSCH TC ID %0d exceeds the three-bit field",
                               traffic_classes[index].tc_id);
                return 0;
            end
            foreach (traffic_classes[other]) begin
                if ((other < index) && traffic_classes[other].valid &&
                    (traffic_classes[other].tc_id ==
                     traffic_classes[index].tc_id)) begin
                    why = $sformatf("duplicate QSCH TC ID %0d",
                                   traffic_classes[index].tc_id);
                    return 0;
                end
            end
        end

        resource_snapshot.list_vio_bindings(bindings);
        resource_snapshot.list_af_extra_queue_bindings(extras);
        expected_qpairs = include_af_extra_queues ?
                          bindings.size() + extras.size() : bindings.size();

        foreach (nets[index]) begin
            if (!nets[index].valid)
                continue;
            if (nets[index].net_id > 63) begin
                why = $sformatf("QSCH net ID %0d exceeds the six-bit field",
                               nets[index].net_id);
                return 0;
            end
            if (!device_snapshot.get_global_function_id(
                    nets[index].function_key, function_id, why))
                return 0;
            // A net node is a hardware vport/function identity.  Its ID is
            // therefore not freely random: it must be the function's global
            // ID.  Randomness belongs to its group/port/policy attachment.
            if (nets[index].net_id != function_id) begin
                why = $sformatf("QSCH net %0d is not global function ID %0d",
                               nets[index].net_id, function_id);
                return 0;
            end
            if (!contains_group(nets[index].group_id, group_index)) begin
                why = $sformatf("QSCH net %0d references unknown group %0d",
                               nets[index].net_id, nets[index].group_id);
                return 0;
            end
            if (nets[index].src_port > 1 || nets[index].dst_port > 3) begin
                why = $sformatf("QSCH net %0d has an out-of-range port",
                               nets[index].net_id);
                return 0;
            end
            if (nets[index].dst_port != groups[group_index].port_id) begin
                why = $sformatf("QSCH net %0d destination port does not match group %0d",
                               nets[index].net_id, nets[index].group_id);
                return 0;
            end
            if (nets[index].spwrr > 8'hff) begin
                why = $sformatf("QSCH net %0d SP/WRR value is out of range",
                               nets[index].net_id);
                return 0;
            end
            if (nets[index].weight_valid) begin
                foreach (nets[index].tc_weight[tc]) begin
                    if (nets[index].tc_weight[tc] > 4'hf) begin
                        why = $sformatf("QSCH net %0d TC%0d weight is out of range",
                                       nets[index].net_id, tc);
                        return 0;
                    end
                end
            end
            foreach (nets[other]) begin
                if ((other < index) && nets[other].valid &&
                    (nets[other].net_id == nets[index].net_id)) begin
                    why = $sformatf("duplicate QSCH net ID %0d",
                                   nets[index].net_id);
                    return 0;
                end
            end
            used_groups[$sformatf("%0d", nets[index].group_id)] = 1;
        end

        foreach (groups[index]) begin
            if (groups[index].valid &&
                !used_groups.exists($sformatf("%0d", groups[index].group_id))) begin
                why = $sformatf("QSCH group %0d has no net attachment",
                               groups[index].group_id);
                return 0;
            end
        end

        foreach (queues[index]) begin
            bit queue_is_resource;
            bit binding_owner_match;
            bit tc_declared;
            if (!queues[index].valid)
                continue;
            if (queues[index].global_qpair_id >= DPU_MAX_VIO_GLOBAL_QPAIRS) begin
                why = $sformatf("QSCH qpair ID %0d is out of range",
                               queues[index].global_qpair_id);
                return 0;
            end
            if (!find_net(queues[index].net_id, queue_index)) begin
                why = $sformatf("QSCH qpair %0d references unknown net %0d",
                               queues[index].global_qpair_id,
                               queues[index].net_id);
                return 0;
            end
            if (queues[index].tc_id > 7) begin
                why = $sformatf("QSCH qpair %0d TC ID is out of range",
                               queues[index].global_qpair_id);
                return 0;
            end
            tc_declared = 0;
            foreach (traffic_classes[tc_index]) begin
                if (traffic_classes[tc_index].valid &&
                    (traffic_classes[tc_index].tc_id == queues[index].tc_id))
                    tc_declared = 1;
            end
            if (!tc_declared) begin
                why = $sformatf("QSCH qpair %0d references undeclared TC %0d",
                               queues[index].global_qpair_id,
                               queues[index].tc_id);
                return 0;
            end
            if (!device_snapshot.get_global_function_id(
                    queues[index].owner_function_key, function_id, why))
                return 0;
            if (function_id != queues[index].net_id) begin
                why = $sformatf("QSCH qpair %0d owner does not match net %0d",
                               queues[index].global_qpair_id,
                               queues[index].net_id);
                return 0;
            end
            queue_is_resource = 0;
            binding_owner_match = 0;
            foreach (bindings[bindex]) begin
                if (bindings[bindex].global_qpair_id ==
                    queues[index].global_qpair_id) begin
                    queue_is_resource = 1;
                    if (dpu_same_function_key(
                            bindings[bindex].service_key.function_key,
                            queues[index].owner_function_key))
                        binding_owner_match = 1;
                end
            end
            if (include_af_extra_queues) begin
                foreach (extras[eindex]) begin
                    if (extras[eindex].global_qpair_id ==
                        queues[index].global_qpair_id) begin
                        queue_is_resource = 1;
                        if (dpu_same_function_key(
                                extras[eindex].af_function_key,
                                queues[index].owner_function_key))
                            binding_owner_match = 1;
                    end
                end
            end
            if (!queue_is_resource) begin
                why = $sformatf("QSCH qpair %0d is not a resource binding",
                               queues[index].global_qpair_id);
                return 0;
            end
            if (!binding_owner_match) begin
                why = $sformatf(
                    "QSCH qpair %0d owner does not match its resource binding",
                    queues[index].global_qpair_id);
                return 0;
            end
            used_nets[$sformatf("%0d", queues[index].net_id)] = 1;
            foreach (queues[other]) begin
                if ((other < index) && queues[other].valid &&
                    (queues[other].global_qpair_id ==
                     queues[index].global_qpair_id)) begin
                    why = $sformatf("duplicate QSCH qpair ID %0d",
                                   queues[index].global_qpair_id);
                    return 0;
                end
            end
        end

        foreach (nets[index]) begin
            if (nets[index].valid &&
                !used_nets.exists($sformatf("%0d", nets[index].net_id))) begin
                why = $sformatf("QSCH net %0d has no queue attachment",
                               nets[index].net_id);
                return 0;
            end
        end

        if (require_all_resource_qpairs) begin
            foreach (bindings[index]) begin
                if (!find_queue(bindings[index].global_qpair_id, queue_index)) begin
                    why = $sformatf("resource qpair %0d has no QSCH attachment",
                                   bindings[index].global_qpair_id);
                    return 0;
                end
            end
            if (include_af_extra_queues) begin
                foreach (extras[index]) begin
                    if (!find_queue(extras[index].global_qpair_id, queue_index)) begin
                        why = $sformatf("AF extra qpair %0d has no QSCH attachment",
                                       extras[index].global_qpair_id);
                        return 0;
                    end
                end
            end
        end
        if (nets.size() == 0 || groups.size() == 0 || ports.size() == 0) begin
            why = "QSCH topology must contain at least one port/group/net";
            return 0;
        end
        if (queues.size() < expected_qpairs && require_all_resource_qpairs) begin
            why = "QSCH topology queue attachment count is incomplete";
            return 0;
        end
        why = "";
        return 1;
    endfunction
endclass : dpu_qsch_topology_cfg

class dpu_qsch_topology_generator extends uvm_object;
    `uvm_object_utils(dpu_qsch_topology_generator)

    dpu_qsch_topology_mode_e mode;
    int unsigned max_group_nodes;
    int unsigned max_port_nodes;
    int unsigned max_tc_id;
    bit include_af_extra_queues;
    // Keep group/port/TC attachments random, but allow a scenario to demand
    // the legal fan-in case where multiple net devices share one scheduler
    // group.  This is a generation constraint, not a deterministic mapping:
    // once the group count is reduced below the net count, remaining nets are
    // still attached through the normal random selection path.
    bit require_shared_group;

    function new(string name = "dpu_qsch_topology_generator");
        super.new(name);
        mode = DPU_QSCH_TOPOLOGY_RANDOM_VALID;
        max_group_nodes = 8;
        max_port_nodes = 4;
        max_tc_id = 7;
        include_af_extra_queues = 0;
        require_shared_group = 0;
    endfunction

    local function bit has_id(input int unsigned ids[$],
                              input int unsigned candidate);
        foreach (ids[index])
            if (ids[index] == candidate)
                return 1;
        return 0;
    endfunction

    local function bit append_unique_id(
        ref int unsigned ids[$], input int unsigned limit
    );
        int unsigned candidate;
        int unsigned attempts;

        if (limit == 0)
            return 0;
        attempts = 0;
        do begin
            candidate = $urandom_range(limit - 1, 0);
            attempts++;
            if (!has_id(ids, candidate)) begin
                ids.push_back(candidate);
                return 1;
            end
        end while (attempts < (limit * 4));
        for (candidate = 0; candidate < limit; candidate++) begin
            if (!has_id(ids, candidate)) begin
                ids.push_back(candidate);
                return 1;
            end
        end
        return 0;
    endfunction

    local function int unsigned bounded_random(input int unsigned maximum);
        if (maximum == 0)
            return 0;
        return $urandom_range(maximum, 0);
    endfunction

    function bit build_random(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        output dpu_qsch_topology_cfg topology,
        output string why
    );
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t extras[$];
        dpu_function_key_t function_keys[$];
        int unsigned function_ids[$];
        int unsigned group_ids[$];
        int unsigned port_ids[$];
        int unsigned group_port_ids[$];
        int unsigned tc_ids[$];
        int unsigned group_count;
        int unsigned port_count;
        int unsigned net_index;
        bit function_names[string];

        topology = null;
        why = "";
        if (mode == DPU_QSCH_TOPOLOGY_EXPLICIT) begin
            why = "QSCH topology generator requires a random mode";
            return 0;
        end
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "QSCH topology generator requires frozen snapshots";
            return 0;
        end
        if (!resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "QSCH topology generator snapshots do not match";
            return 0;
        end
        resource_snapshot.list_vio_bindings(bindings);
        resource_snapshot.list_af_extra_queue_bindings(extras);
        foreach (bindings[index]) begin
            string function_name;
            function_name = dpu_function_key_name(
                bindings[index].service_key.function_key);
            if (!function_names.exists(function_name)) begin
                function_names[function_name] = 1;
                function_keys.push_back(bindings[index].service_key.function_key);
            end
        end
        if (include_af_extra_queues) begin
            foreach (extras[index]) begin
                string function_name;
                function_name = dpu_function_key_name(
                    extras[index].af_function_key);
                if (!function_names.exists(function_name)) begin
                    function_names[function_name] = 1;
                    function_keys.push_back(extras[index].af_function_key);
                end
            end
        end
        if (function_keys.size() == 0) begin
            why = "QSCH topology generator found no VIO queue owner";
            return 0;
        end

        foreach (function_keys[index]) begin
            int unsigned function_id;
            if (!device_snapshot.get_global_function_id(
                    function_keys[index], function_id, why))
                return 0;
            function_ids.push_back(function_id);
        end

        if (mode == DPU_QSCH_TOPOLOGY_RANDOM_STRESS) begin
            group_count = (max_group_nodes == 0) ? 32 : max_group_nodes;
            port_count = (max_port_nodes == 0) ? 4 : max_port_nodes;
        end else begin
            group_count = (max_group_nodes == 0) ? function_keys.size() :
                          $urandom_range(max_group_nodes, 1);
            port_count = (max_port_nodes == 0) ? 1 :
                         $urandom_range(max_port_nodes, 1);
        end
        if (group_count > function_keys.size())
            group_count = function_keys.size();
        if (group_count > 32)
            group_count = 32;
        if (require_shared_group && (function_keys.size() > 1) &&
            (group_count >= function_keys.size()))
            group_count = function_keys.size() - 1;
        if (port_count > 4)
            port_count = 4;
        if (group_count == 0 || port_count == 0) begin
            why = "QSCH topology generator produced no group or port";
            return 0;
        end
        repeat (group_count)
            if (!append_unique_id(group_ids, 32)) begin
                why = "QSCH topology generator could not allocate group IDs";
                return 0;
            end
        repeat (port_count)
            if (!append_unique_id(port_ids, 4)) begin
                why = "QSCH topology generator could not allocate port IDs";
                return 0;
            end

        topology = dpu_qsch_topology_cfg::type_id::create(
            {get_name(), "_topology"});
        topology.mode = mode;
        topology.include_af_extra_queues = include_af_extra_queues;
        topology.require_all_resource_qpairs = 1;
        foreach (port_ids[index])
            topology.ports.push_back('{port_id: port_ids[index], valid: 1});
        foreach (group_ids[index]) begin
            int unsigned port_id;
            port_id = port_ids[index % port_ids.size()];
            if (mode != DPU_QSCH_TOPOLOGY_RANDOM_STRESS)
                port_id = port_ids[bounded_random(port_ids.size() - 1)];
            topology.groups.push_back('{group_id: group_ids[index],
                                        port_id: port_id, valid: 1});
            group_port_ids.push_back(port_id);
        end
        foreach (function_keys[index]) begin
            dpu_qsch_net_node_cfg_t net;
            int unsigned selected_group_index;
            net.function_key = function_keys[index];
            net.net_id = function_ids[index];
            // Seed each generated group with one net before randomizing the
            // remaining attachments.  This preserves a fully connected
            // graph while still allowing many nets to share one group.
            selected_group_index = index % group_ids.size();
            if ((mode != DPU_QSCH_TOPOLOGY_RANDOM_STRESS) &&
                (index >= group_ids.size()))
                selected_group_index = bounded_random(group_ids.size() - 1);
            net.group_id = group_ids[selected_group_index];
            net.src_port = bounded_random(1);
            net.dst_port = group_port_ids[selected_group_index];
            net.spwrr = bounded_random(8'hff);
            net.weight_valid = bounded_random(1);
            net.valid = 1;
            foreach (net.tc_weight[tc])
                net.tc_weight[tc] = bounded_random(4'hf);
            topology.nets.push_back(net);
        end

        // Every resource qpair is represented in the graph; group coverage is
        // guaranteed by assigning the first nets to distinct generated groups.
        foreach (bindings[index]) begin
            dpu_qsch_queue_attachment_cfg_t queue;
            if (!device_snapshot.get_global_function_id(
                    bindings[index].service_key.function_key, net_index, why))
                return 0;
            queue.owner_function_key = bindings[index].service_key.function_key;
            queue.global_qpair_id = bindings[index].global_qpair_id;
            queue.net_id = net_index;
            queue.tc_id = bounded_random((max_tc_id > 7) ? 7 : max_tc_id);
            queue.valid = 1;
            topology.queues.push_back(queue);
            if (!has_id(tc_ids, queue.tc_id))
                tc_ids.push_back(queue.tc_id);
        end
        if (include_af_extra_queues) begin
            foreach (extras[index]) begin
                dpu_qsch_queue_attachment_cfg_t queue;
                if (!device_snapshot.get_global_function_id(
                        extras[index].af_function_key, net_index, why))
                    return 0;
                queue.owner_function_key = extras[index].af_function_key;
                queue.global_qpair_id = extras[index].global_qpair_id;
                queue.net_id = net_index;
                queue.tc_id = bounded_random((max_tc_id > 7) ? 7 : max_tc_id);
                queue.valid = 1;
                topology.queues.push_back(queue);
                if (!has_id(tc_ids, queue.tc_id))
                    tc_ids.push_back(queue.tc_id);
            end
        end
        foreach (tc_ids[index])
            topology.traffic_classes.push_back(
                '{tc_id: tc_ids[index], valid: 1});
        if (!topology.validate(device_snapshot, resource_snapshot, why)) begin
            topology = null;
            return 0;
        end
        return 1;
    endfunction
endclass : dpu_qsch_topology_generator

`endif // DPU_VIO_QSCH_TOPOLOGY_SV
