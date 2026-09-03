`ifndef DPU_VIO_REGISTER_PLAN_BUILDER_SV
`define DPU_VIO_REGISTER_PLAN_BUILDER_SV

class dpu_vio_register_plan_builder extends uvm_object;
    `uvm_object_utils(dpu_vio_register_plan_builder)

    dpu_vio_register_plan_policy policy;
    dpu_vio_dataplane_plan_extension dataplane_extension;

    function new(string name = "dpu_vio_register_plan_builder");
        super.new(name);
        policy = dpu_vio_register_plan_policy::type_id::create(
            {name, "_policy"});
        dataplane_extension = null;
    endfunction

    function void set_dataplane_extension(
        input dpu_vio_dataplane_plan_extension new_extension
    );
        dataplane_extension = new_extension;
    endfunction

    function void set_policy(input dpu_vio_register_plan_policy new_policy);
        if (new_policy == null)
            policy = dpu_vio_register_plan_policy::type_id::create(
                {get_name(), "_default_policy"});
        else
            policy = new_policy;
    endfunction

    local function dpu_reg_op make_af_op(
        input string op_id,
        input dpu_reg_op_kind_e kind,
        input dpu_pcie_function_id_t af_pcie_id,
        input dpu_reg_phase_e phase,
        input dpu_reg_target_scope_e scope,
        input string target_block,
        input bit [63:0] address,
        input int unsigned width_bytes
    );
        dpu_reg_op op;

        op = dpu_reg_op::type_id::create(op_id);
        op.op_id = op_id;
        op.owner = "dpu.vio";
        op.kind = kind;
        op.target_space = (kind == DPU_REG_OP_PCI_CFG_WRITE) ?
            DPU_REG_TARGET_PCI_CONFIG : DPU_REG_TARGET_AF_BAR0;
        op.target_scope = scope;
        op.phase = phase;
        op.host_id = af_pcie_id.domain.host_id;
        op.segment_id = af_pcie_id.domain.segment_id;
        op.bdf_valid = 1;
        op.bdf = af_pcie_id.bdf;
        op.bar_id = 0;
        op.target_block = target_block;
        op.address = address;
        op.width_bytes = width_bytes;
        return op;
    endfunction

    local function bit add_op(
        input dpu_reg_plan candidate,
        input dpu_reg_op op,
        output string why
    );
        if (!candidate.add_operation(op, why))
            return 0;
        return 1;
    endfunction

    local function bit add_notify_verify_op(
        input dpu_reg_plan candidate,
        input string op_id,
        input dpu_pcie_function_id_t af_pcie_id,
        input dpu_reg_target_scope_e scope,
        input string target_block,
        input bit [63:0] address,
        input bit [63:0] expected_value,
        input string dependency_id,
        output string why
    );
        dpu_reg_op op;

        op = make_af_op(op_id, DPU_REG_OP_POLL_UNTIL, af_pcie_id,
                        DPU_REG_PHASE_TABLE, scope, target_block, address, 8);
        op.owner = "dpu.vio.notify.verify";
        op.expected_value = expected_value;
        op.read_mask = 64'hffff_ffff_ffff_ffff;
        op.max_attempts = policy.notify_verify_attempts;
        op.retry_interval = policy.notify_verify_interval;
        op.add_dependency(dependency_id);
        return add_op(candidate, op, why);
    endfunction

    local function bit check_af_bar0_aperture(
        input dpu_bar_pair_lease_t af_bar0,
        input bit [63:0] offset,
        input int unsigned width_bytes,
        input string table_name,
        output string why
    );
        why = "";
        if ((width_bytes == 0) || (offset > af_bar0.size) ||
            (width_bytes > (af_bar0.size - offset))) begin
            why = $sformatf(
                "AF BAR0 aperture does not cover %s offset 0x%016h width %0d (size 0x%016h)",
                table_name, offset, width_bytes, af_bar0.size);
            return 0;
        end
        return 1;
    endfunction

    local function string function_bdf_op_id(
        input dpu_function_key_t function_key,
        input dpu_pcie_function_id_t pcie_id,
        input int unsigned global_function_id
    );
        return $sformatf("vio.h%0d.s%0d.b%04h.f%0d.bdf",
            pcie_id.domain.host_id, pcie_id.domain.segment_id,
            pcie_id.bdf, global_function_id);
    endfunction

    local function string binding_prefix(
        input dpu_vio_qpair_binding_t binding,
        input dpu_pcie_function_id_t pcie_id,
        input int unsigned ordinal
    );
        return $sformatf("vio.h%0d.s%0d.b%04h.q%0d.g%0d",
            pcie_id.domain.host_id, pcie_id.domain.segment_id,
            pcie_id.bdf, ordinal, binding.global_qpair_id);
    endfunction

    local function string af_extra_binding_prefix(
        input dpu_af_extra_queue_binding_t binding,
        input dpu_pcie_function_id_t pcie_id
    );
        return $sformatf("vio.h%0d.s%0d.b%04h.afq%0d.g%0d",
            pcie_id.domain.host_id, pcie_id.domain.segment_id,
            pcie_id.bdf, binding.extra_queue_offset,
            binding.global_qpair_id);
    endfunction

    function bit build(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        output dpu_reg_plan plan,
        output string why
    );
        dpu_reg_plan candidate;
        dpu_function_key_t af_key;
        dpu_pcie_function_id_t af_pcie_id;
        dpu_bar_pair_lease_t af_bar0;
        dpu_function_key_t functions[$];
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t af_extra_bindings[$];
        bit binding_is_af_extra[$];
        int unsigned binding_extra_offset[$];
        bit [63:0] binding_notify_addr[$];
        dpu_dut_caps caps;
        string bdf_ids[string];
        bit owned_function_names[string];
        string linear_ids[string];
        string info_ids[string];
        string interval_ids[string];
        int unsigned global_function_id;
        int unsigned notify_ordinal;
        int unsigned notify_bank;
        string bootstrap_barrier_id;
        string notify_producer_ids[$];

        plan = null;
        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            why = "VIO register-plan builder requires a frozen device snapshot";
            return 0;
        end
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "VIO register-plan builder requires a frozen resource snapshot";
            return 0;
        end
        if (!resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "resource snapshot does not reference the supplied device snapshot";
            return 0;
        end
        if ((policy == null) || !policy.validate(why))
            return 0;
        if (!policy.selected_notify_bank(notify_bank, why))
            return 0;
        if (!device_snapshot.get_expected_af(af_key, af_bar0, why) ||
            !device_snapshot.get_pcie_id(af_key, af_pcie_id, why))
            return 0;
        candidate = dpu_reg_plan::type_id::create(
            {get_name(), "_register_plan"});
        bootstrap_barrier_id = "bootstrap.final_barrier";
        // Bootstrap is intentionally added to the same DAG so a caller can
        // pass one frozen plan to one executor and preserve ordering.
        begin
            dpu_reg_plan bootstrap_plan;
            dpu_device_bootstrap_plan_builder bootstrap_builder;
            dpu_reg_op bootstrap_ops[$];
            dpu_reg_op bootstrap_op;

            bootstrap_builder = dpu_device_bootstrap_plan_builder::type_id::create(
                {get_name(), "_bootstrap_builder_copy"});
            if (!bootstrap_builder.build(device_snapshot, bootstrap_plan, why))
                return 0;
            if (!bootstrap_plan.list_operations(bootstrap_ops, why))
                return 0;
            foreach (bootstrap_ops[index]) begin
                bootstrap_op = bootstrap_ops[index];
                if ((bootstrap_op.target_space == DPU_REG_TARGET_AF_BAR0) &&
                    !check_af_bar0_aperture(af_bar0, bootstrap_op.address,
                                            bootstrap_op.width_bytes,
                                            bootstrap_op.target_block, why))
                    return 0;
                if (!candidate.add_operation(bootstrap_op, why))
                    return 0;
            end
        end

        caps = device_snapshot.snapshot_dut_caps();
        if (caps == null) begin
            why = "VIO register-plan builder cannot read DUT capabilities";
            return 0;
        end
        resource_snapshot.list_vio_bindings(bindings);
        resource_snapshot.list_af_extra_queue_bindings(af_extra_bindings);
        foreach (bindings[index])
            owned_function_names[dpu_function_key_name(
                bindings[index].service_key.function_key)] = 1;
        foreach (af_extra_bindings[index])
            owned_function_names[dpu_function_key_name(
                af_extra_bindings[index].af_function_key)] = 1;
        device_snapshot.list_functions(functions);
        foreach (functions[index]) begin
            dpu_pcie_function_id_t pcie_id;
            dpu_vio_bdf_cfg_t bdf_cfg;
            bit [31:0] payload;
            dpu_reg_op op;
            string op_id;

            if (!owned_function_names.exists(
                    dpu_function_key_name(functions[index])))
                continue;

            if (!device_snapshot.get_pcie_id(functions[index], pcie_id, why) ||
                !device_snapshot.get_global_function_id(
                    functions[index], global_function_id, why))
                return 0;
            if (global_function_id >= caps.max_functions) begin
                why = $sformatf(
                    "global function ID %0d exceeds DUT capability %0d",
                    global_function_id, caps.max_functions);
                return 0;
            end
            bdf_cfg.bdf = pcie_id.bdf;
            bdf_cfg.valid = 1;
            if (!dpu_vio_pack_bdf_entry(bdf_cfg, payload, why))
                return 0;
            if (!check_af_bar0_aperture(
                    af_bar0, DPU_VIO_BDF_MAP_BASE + global_function_id * 4,
                    4, "preq_bdf_map", why))
                return 0;
            op_id = function_bdf_op_id(functions[index], pcie_id,
                                        global_function_id);
            op = make_af_op(op_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                            DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_FUNCTION,
                            "preq_bdf_map",
                            DPU_VIO_BDF_MAP_BASE + global_function_id * 4, 4);
            op.owner = {"dpu.vio.bdf.", dpu_function_key_name(functions[index])};
            op.payload = payload;
            op.write_mask = 64'h0000_0000_ffff_ffff;
            op.add_dependency(bootstrap_barrier_id);
            if (!add_op(candidate, op, why))
                return 0;
            bdf_ids[dpu_function_key_name(functions[index])] = op_id;
        end

        binding_notify_addr.delete();
        binding_is_af_extra.delete();
        binding_extra_offset.delete();
        foreach (bindings[index]) begin
            dpu_bar_pair_lease_t binding_bar0;
            if (!device_snapshot.get_bar(
                    bindings[index].service_key.function_key,
                    DPU_BAR_DEVICE_MEMORY, binding_bar0, why))
                return 0;
            if ((binding_bar0.size < 64'h80) ||
                (policy.notify_address_offset > (binding_bar0.size - 64'h80))) begin
                why = "VIO function notify 128-byte aperture is outside BAR0";
                return 0;
            end
            binding_notify_addr.push_back(binding_bar0.base +
                                          policy.notify_address_offset);
            binding_is_af_extra.push_back(0);
            binding_extra_offset.push_back(0);
        end
        foreach (af_extra_bindings[index]) begin
            dpu_vio_qpair_binding_t synthetic_binding;

            synthetic_binding.request_id = 0;
            synthetic_binding.request_pair_index = 0;
            synthetic_binding.service_key.function_key =
                af_extra_bindings[index].af_function_key;
            synthetic_binding.service_key.service_kind = DPU_SERVICE_VIO_NET;
            synthetic_binding.service_key.service_instance_id = 0;
            synthetic_binding.virtio_pair_index =
                af_extra_bindings[index].local_queue_index;
            synthetic_binding.local_pair_id =
                af_extra_bindings[index].local_queue_index;
            synthetic_binding.rx_local_virtqueue_id = 0;
            synthetic_binding.tx_local_virtqueue_id = 0;
            synthetic_binding.global_qpair_id =
                af_extra_bindings[index].global_qpair_id;
            synthetic_binding.local_msix_vector_id =
                af_extra_bindings[index].local_msix_vector_id;
            synthetic_binding.global_msix_vector_id =
                af_extra_bindings[index].global_msix_vector_id;
            bindings.push_back(synthetic_binding);
            binding_notify_addr.push_back(af_bar0.base +
                                          policy.notify_address_offset);
            binding_is_af_extra.push_back(1);
            binding_extra_offset.push_back(
                af_extra_bindings[index].extra_queue_offset);
        end
        // dpu_af_fill_qid_map_table() keeps entries ordered by
        // {host_id, notify_addr[60:7]}; preserve software pair order for
        // entries sharing one key and only then use local ID as a tie-breaker.
        for (int left = 0; left < bindings.size(); left++) begin
            for (int right = left + 1; right < bindings.size(); right++) begin
                bit swap_binding;
                swap_binding = (bindings[right].service_key.function_key.host_id <
                                bindings[left].service_key.function_key.host_id) ||
                    ((bindings[right].service_key.function_key.host_id ==
                      bindings[left].service_key.function_key.host_id) &&
                     (((binding_notify_addr[right] &
                        64'h1fff_ffff_ffff_ff80) <
                       (binding_notify_addr[left] &
                        64'h1fff_ffff_ffff_ff80)) ||
                      (((binding_notify_addr[right] &
                         64'h1fff_ffff_ffff_ff80) ==
                        (binding_notify_addr[left] &
                         64'h1fff_ffff_ffff_ff80)) &&
                       ((bindings[right].virtio_pair_index <
                         bindings[left].virtio_pair_index) ||
                        ((bindings[right].virtio_pair_index ==
                          bindings[left].virtio_pair_index) &&
                         (bindings[right].local_pair_id <
                          bindings[left].local_pair_id))))));
                if (swap_binding) begin
                    dpu_vio_qpair_binding_t binding_swap;
                    bit [63:0] address_swap;
                    bit extra_swap;
                    int unsigned extra_offset_swap;
                    binding_swap = bindings[left];
                    bindings[left] = bindings[right];
                    bindings[right] = binding_swap;
                    address_swap = binding_notify_addr[left];
                    binding_notify_addr[left] = binding_notify_addr[right];
                    binding_notify_addr[right] = address_swap;
                    extra_swap = binding_is_af_extra[left];
                    binding_is_af_extra[left] = binding_is_af_extra[right];
                    binding_is_af_extra[right] = extra_swap;
                    extra_offset_swap = binding_extra_offset[left];
                    binding_extra_offset[left] = binding_extra_offset[right];
                    binding_extra_offset[right] = extra_offset_swap;
                end
            end
        end
        notify_ordinal = 0;
        foreach (bindings[index]) begin
            dpu_function_key_t owner_key;
            dpu_pcie_function_id_t owner_pcie_id;
            dpu_bar_pair_lease_t owner_bar0;
            int unsigned owner_global_function_id;
            int unsigned source_id;
            int unsigned global_msix_idx;
            int unsigned local_vector;
            dpu_vio_msix_linear_cfg_t linear_cfg;
            dpu_vio_msix_info_cfg_t info_cfg;
            dpu_vio_notify_entry_cfg_t notify_cfg;
            bit [31:0] linear_payload;
            bit [31:0] info_payload;
            bit [31:0] interval_payload;
            bit [63:0] notify_low;
            bit [63:0] notify_high;
            dpu_reg_op op;
            string prefix;
            string bdf_id;
            string linear_id;
            string info_id;
            string interval_id;
            string notify_low_id;
            string notify_high_id;
            string notify_low_verify_id;
            string notify_high_verify_id;
            string commit_group;
            string linear_key;
            string info_key;
            string interval_key;
            string operation_owner;
            bit is_af_extra;
            dpu_af_extra_queue_binding_t extra_binding;

            is_af_extra = binding_is_af_extra[index];
            if (is_af_extra)
                extra_binding = af_extra_bindings[binding_extra_offset[index]];
            if (bindings[index].service_key.service_kind != DPU_SERVICE_VIO_NET) begin
                why = "resource snapshot contains a non-VIO binding";
                return 0;
            end
            owner_key = bindings[index].service_key.function_key;
            if (!device_snapshot.get_pcie_id(owner_key, owner_pcie_id, why) ||
                !device_snapshot.get_global_function_id(
                    owner_key, owner_global_function_id, why) ||
                !device_snapshot.get_bar(owner_key, DPU_BAR_DEVICE_MEMORY,
                                         owner_bar0, why))
                return 0;
            if (!dpu_vio_compute_srcid(owner_key, source_id, why))
                return 0;
            if (owner_global_function_id > 8'hff) begin
                why = "MSI-X info table cannot encode a function ID above 255";
                return 0;
            end
            if (bindings[index].global_msix_vector_id >=
                caps.global_msix_vector_count) begin
                why = "VIO qpair count exceeds DUT MSI-X vector capacity";
                return 0;
            end
            if (notify_ordinal >= caps.vio_notify_entries_per_bank) begin
                why = "VIO qpair count exceeds the selected notify bank capacity";
                return 0;
            end
            if (bindings[index].local_pair_id >=
                caps.max_vio_net_qpairs_per_device) begin
                why = "VIO local qpair exceeds DUT per-device capability";
                return 0;
            end
            global_msix_idx = bindings[index].global_msix_vector_id;
            local_vector = bindings[index].local_msix_vector_id;
            if (local_vector > 7'h7f) begin
                why = "VIO local MSI-X vector exceeds the linear table field";
                return 0;
            end
            if ((owner_bar0.base + policy.notify_address_offset) < owner_bar0.base ||
                (owner_bar0.base + policy.notify_address_offset) >
                 (64'hffff_ffff_ffff_ffff - 64'h7f)) begin
                why = "VIO function BAR0 produces an invalid notify address";
                return 0;
            end
            if ((owner_bar0.size < 64'h80) ||
                (policy.notify_address_offset > (owner_bar0.size - 64'h80))) begin
                why = "VIO function notify 128-byte aperture is outside BAR0";
                return 0;
            end

            if (!check_af_bar0_aperture(
                    af_bar0,
                    DPU_VIO_MSIX_LINEAR_BASE +
                    ((source_id << 7) + local_vector) * 4,
                    4, "msix_linear", why) ||
                !check_af_bar0_aperture(
                    af_bar0, DPU_VIO_MSIX_INFO_BASE + global_msix_idx * 4,
                    4, "msix_info", why) ||
                !check_af_bar0_aperture(
                    af_bar0, DPU_VIO_MSIX_INTERVAL_BASE + global_msix_idx * 4,
                    4, "msix_interval", why))
                return 0;

            bdf_id = bdf_ids[dpu_function_key_name(owner_key)];
            prefix = is_af_extra ?
                af_extra_binding_prefix(extra_binding, af_pcie_id) :
                binding_prefix(bindings[index], af_pcie_id, notify_ordinal);
            operation_owner = is_af_extra ?
                $sformatf("dpu.vio.af_extra.%s.%0d",
                    dpu_function_key_name(owner_key),
                    extra_binding.extra_queue_offset) :
                {"dpu.vio.", dpu_service_key_name(
                    bindings[index].service_key)};
            linear_cfg.global_msix_idx = global_msix_idx;
            linear_cfg.valid = 1;
            info_cfg.function_id = owner_global_function_id;
            info_cfg.host_id = owner_key.host_id;
            info_cfg.self_mask = policy.msix_self_mask;
            info_cfg.valid = 1;
            if (!dpu_vio_pack_msix_linear_entry(linear_cfg, linear_payload, why) ||
                !dpu_vio_pack_msix_info_entry(info_cfg, info_payload, why) ||
                !dpu_vio_pack_msix_interval(policy.msix_interval_rate,
                                            policy.msix_interval_packets,
                                            interval_payload, why))
                return 0;
            linear_key = {dpu_function_key_name(owner_key), ":",
                          $sformatf("%0d", local_vector)};
            if (linear_ids.exists(linear_key)) begin
                linear_id = linear_ids[linear_key];
            end else begin
                linear_id = {prefix, ".msix_linear"};
                op = make_af_op(linear_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                                DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                                "msix_linear",
                                DPU_VIO_MSIX_LINEAR_BASE +
                                ((source_id << 7) + local_vector) * 4, 4);
                op.owner = {"dpu.vio.msix.", operation_owner};
                op.payload = linear_payload;
                op.write_mask = 64'h0000_0000_ffff_ffff;
                op.add_dependency(bdf_id);
                if (!add_op(candidate, op, why))
                    return 0;
                linear_ids[linear_key] = linear_id;
            end

            info_key = $sformatf("%0d", global_msix_idx);
            if (info_ids.exists(info_key)) begin
                info_id = info_ids[info_key];
            end else begin
                info_id = {prefix, ".msix_info"};
                op = make_af_op(info_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                                DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                                "msix_info",
                                DPU_VIO_MSIX_INFO_BASE + global_msix_idx * 4, 4);
                op.owner = {"dpu.vio.msix.", operation_owner};
                op.payload = info_payload;
                op.write_mask = 64'h0000_0000_ffff_ffff;
                op.add_dependency(bdf_id);
                if (!add_op(candidate, op, why))
                    return 0;
                info_ids[info_key] = info_id;
            end

            interval_key = info_key;
            if (policy.emit_msix_interval) begin
                if (interval_ids.exists(interval_key)) begin
                    interval_id = interval_ids[interval_key];
                end else begin
                    interval_id = {prefix, ".msix_interval"};
                    op = make_af_op(interval_id, DPU_REG_OP_MMIO_WRITE,
                                    af_pcie_id, DPU_REG_PHASE_TABLE,
                                    DPU_REG_SCOPE_PER_SERVICE, "msix_interval",
                                    DPU_VIO_MSIX_INTERVAL_BASE +
                                    global_msix_idx * 4, 4);
                    op.owner = {"dpu.vio.msix.", operation_owner};
                    op.payload = interval_payload;
                    op.write_mask = 64'h0000_0000_ffff_ffff;
                    op.add_dependency(bdf_id);
                    if (!add_op(candidate, op, why))
                        return 0;
                    interval_ids[interval_key] = interval_id;
                end
            end else
                interval_id = bdf_id;

            notify_cfg.local_qid_net = 1;
            // The driver emits local_qid from the function's contiguous
            // txrx_queues[] index (i), not from the placement-local resource
            // label.  Keep sparse local_pair_id available to clients while
            // matching the real-DUT notify table encoding here.
            notify_cfg.local_qid = bindings[index].virtio_pair_index & 5'h1f;
            notify_cfg.local_qid_blk =
                (bindings[index].virtio_pair_index & 6'h20) >> 5;
            notify_cfg.notify_address = owner_bar0.base +
                policy.notify_address_offset;
            notify_cfg.host_id = owner_key.host_id;
            notify_cfg.global_qid = bindings[index].global_qpair_id;
            notify_cfg.notify_type = policy.notify_type;
            if (!dpu_vio_pack_notify_entry(
                    notify_cfg, notify_low, notify_high, why))
                return 0;
            if (!check_af_bar0_aperture(
                    af_bar0,
                    ((notify_bank == 0) ? DPU_VIO_NOTIFY_BANK0_BASE :
                                         DPU_VIO_NOTIFY_BANK1_BASE) +
                    notify_ordinal * DPU_VIO_NOTIFY_ENTRY_STRIDE,
                    16, "vio_notify", why) ||
                !check_af_bar0_aperture(
                    af_bar0,
                    ((notify_bank == 0) ? DPU_VIO_NOTIFY_BANK0_BASE :
                                         DPU_VIO_NOTIFY_BANK1_BASE) +
                    notify_ordinal * DPU_VIO_NOTIFY_ENTRY_STRIDE + 8,
                    8, "vio_notify", why))
                return 0;
            commit_group = $sformatf("vio.notify.bank%0d", notify_bank);
            notify_low_id = {prefix, ".notify.low"};
            op = make_af_op(notify_low_id, DPU_REG_OP_MMIO_WRITE,
                            af_pcie_id, DPU_REG_PHASE_TABLE,
                            DPU_REG_SCOPE_PER_SERVICE,
                            $sformatf("vio_notify_bank%0d", notify_bank),
                            ((notify_bank == 0) ?
                             DPU_VIO_NOTIFY_BANK0_BASE :
                             DPU_VIO_NOTIFY_BANK1_BASE) +
                            notify_ordinal * DPU_VIO_NOTIFY_ENTRY_STRIDE, 8);
            op.owner = {"dpu.vio.notify.", operation_owner};
            op.payload = notify_low;
            op.write_mask = 64'hffff_ffff_ffff_ffff;
            op.commit_group = commit_group;
            op.add_dependency(linear_id);
            op.add_dependency(info_id);
            op.add_dependency(interval_id);
            if (!add_op(candidate, op, why))
                return 0;
            notify_producer_ids.push_back(notify_low_id);

            notify_high_id = {prefix, ".notify.high"};
            op = make_af_op(notify_high_id, DPU_REG_OP_MMIO_WRITE,
                            af_pcie_id, DPU_REG_PHASE_TABLE,
                            DPU_REG_SCOPE_PER_SERVICE,
                            $sformatf("vio_notify_bank%0d", notify_bank),
                            ((notify_bank == 0) ?
                             DPU_VIO_NOTIFY_BANK0_BASE :
                             DPU_VIO_NOTIFY_BANK1_BASE) +
                            notify_ordinal * DPU_VIO_NOTIFY_ENTRY_STRIDE + 8, 8);
            op.owner = {"dpu.vio.notify.", operation_owner};
            op.payload = notify_high;
            op.write_mask = 64'hffff_ffff_ffff_ffff;
            op.commit_group = commit_group;
            op.add_dependency(notify_low_id);
            if (!add_op(candidate, op, why))
                return 0;
            notify_producer_ids.push_back(notify_high_id);
            if (policy.verify_notify_writes) begin
                notify_low_verify_id = {notify_low_id, ".verify"};
                if (!add_notify_verify_op(
                        candidate, notify_low_verify_id, af_pcie_id,
                        DPU_REG_SCOPE_PER_SERVICE,
                        $sformatf("vio_notify_bank%0d", notify_bank),
                        ((notify_bank == 0) ?
                         DPU_VIO_NOTIFY_BANK0_BASE :
                         DPU_VIO_NOTIFY_BANK1_BASE) +
                        notify_ordinal * DPU_VIO_NOTIFY_ENTRY_STRIDE,
                        notify_low, notify_high_id, why))
                    return 0;
                notify_high_verify_id = {notify_high_id, ".verify"};
                if (!add_notify_verify_op(
                        candidate, notify_high_verify_id, af_pcie_id,
                        DPU_REG_SCOPE_PER_SERVICE,
                        $sformatf("vio_notify_bank%0d", notify_bank),
                        ((notify_bank == 0) ?
                         DPU_VIO_NOTIFY_BANK0_BASE :
                         DPU_VIO_NOTIFY_BANK1_BASE) +
                        notify_ordinal * DPU_VIO_NOTIFY_ENTRY_STRIDE + 8,
                        notify_high, notify_low_verify_id, why))
                    return 0;
                notify_producer_ids.push_back(notify_high_verify_id);
            end
            notify_ordinal++;
        end

        if (policy.emit_full_notify_bank) begin
            bit [63:0] invalid_low;
            bit [63:0] invalid_high;
            string clear_group;

            if (!dpu_vio_pack_invalid_notify_entry(
                    invalid_low, invalid_high, why))
                return 0;
            clear_group = $sformatf("vio.notify.bank%0d", notify_bank);
            for (int unsigned clear_index = notify_ordinal;
                 clear_index < caps.vio_notify_entries_per_bank;
                 clear_index++) begin
                bit [63:0] clear_offset;
                dpu_reg_op clear_op;
                string clear_id;
                string clear_low_id;
                string clear_low_verify_id;
                string clear_high_verify_id;

                clear_offset = ((notify_bank == 0) ?
                                DPU_VIO_NOTIFY_BANK0_BASE :
                                DPU_VIO_NOTIFY_BANK1_BASE) +
                               clear_index * DPU_VIO_NOTIFY_ENTRY_STRIDE;
                if (!check_af_bar0_aperture(
                        af_bar0, clear_offset, 16,
                        "vio_notify_invalid", why))
                    return 0;
                clear_id = $sformatf(
                    "vio.notify.bank%0d.entry%0d.clear.low",
                    notify_bank, clear_index);
                clear_low_id = clear_id;
                clear_op = make_af_op(
                    clear_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                    DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_HOST,
                    $sformatf("vio_notify_bank%0d", notify_bank),
                    clear_offset, 8);
                clear_op.owner = "dpu.vio.notify.clear";
                clear_op.payload = invalid_low;
                clear_op.write_mask = 64'hffff_ffff_ffff_ffff;
                clear_op.commit_group = clear_group;
                clear_op.add_dependency(bootstrap_barrier_id);
                if (!add_op(candidate, clear_op, why))
                    return 0;
                notify_producer_ids.push_back(clear_id);

                clear_id = $sformatf(
                    "vio.notify.bank%0d.entry%0d.clear.high",
                    notify_bank, clear_index);
                clear_op = make_af_op(
                    clear_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                    DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_HOST,
                    $sformatf("vio_notify_bank%0d", notify_bank),
                    clear_offset + 8, 8);
                clear_op.owner = "dpu.vio.notify.clear";
                clear_op.payload = invalid_high;
                clear_op.write_mask = 64'hffff_ffff_ffff_ffff;
                clear_op.commit_group = clear_group;
                clear_op.add_dependency(clear_low_id);
                if (!add_op(candidate, clear_op, why))
                    return 0;
                notify_producer_ids.push_back(clear_id);
                if (policy.verify_notify_writes) begin
                    clear_low_verify_id = {clear_low_id, ".verify"};
                    if (!add_notify_verify_op(
                            candidate, clear_low_verify_id, af_pcie_id,
                            DPU_REG_SCOPE_PER_HOST,
                            $sformatf("vio_notify_bank%0d", notify_bank),
                            clear_offset, invalid_low, clear_id, why))
                        return 0;
                    clear_high_verify_id = {clear_id, ".verify"};
                    if (!add_notify_verify_op(
                            candidate, clear_high_verify_id, af_pcie_id,
                            DPU_REG_SCOPE_PER_HOST,
                            $sformatf("vio_notify_bank%0d", notify_bank),
                            clear_offset + 8, invalid_high,
                            clear_low_verify_id, why))
                        return 0;
                    notify_producer_ids.push_back(clear_high_verify_id);
                end
            end
        end

        if ((notify_ordinal != 0) || policy.emit_full_notify_bank) begin
            dpu_reg_op commit_op;
            string commit_id;
            string commit_group;
            commit_group = $sformatf("vio.notify.bank%0d", notify_bank);
            commit_id = $sformatf("vio.notify.commit.bank%0d", notify_bank);
            commit_op = make_af_op(commit_id, DPU_REG_OP_COMMIT,
                                   af_pcie_id, DPU_REG_PHASE_COMMIT,
                                   DPU_REG_SCOPE_PER_HOST, "vio_notify_commit",
                                   DPU_VIO_NOTIFY_COMMIT_ADDR, 4);
            commit_op.owner = "dpu.vio.notify.commit";
            commit_op.payload = DPU_VIO_NOTIFY_COMMIT_RDY_MASK |
                (notify_bank ? DPU_VIO_NOTIFY_COMMIT_SEL_MASK : 0);
            commit_op.write_mask = DPU_VIO_NOTIFY_COMMIT_RDY_MASK |
                DPU_VIO_NOTIFY_COMMIT_SEL_MASK;
            if (!check_af_bar0_aperture(
                    af_bar0, DPU_VIO_NOTIFY_COMMIT_ADDR, 4,
                    "vio_notify_commit", why))
                return 0;
            commit_op.commit_group = commit_group;
            foreach (notify_producer_ids[producer_index])
                commit_op.add_dependency(notify_producer_ids[producer_index]);
            if (!add_op(candidate, commit_op, why))
                return 0;
        end
        if ((dataplane_extension != null) &&
            !dataplane_extension.contribute(
                device_snapshot, resource_snapshot, candidate, why))
            return 0;
        plan = candidate;
        return 1;
    endfunction

    function bit build_teardown(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        output dpu_reg_plan plan,
        output string why
    );
        dpu_reg_plan candidate;
        dpu_function_key_t af_key;
        dpu_pcie_function_id_t af_pcie_id;
        dpu_bar_pair_lease_t af_bar0;
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t af_extra_bindings[$];
        dpu_function_key_t vector_owners[$];
        int unsigned local_vectors[$];
        int unsigned global_vectors[$];
        dpu_function_key_t owned_functions[$];
        bit owned_function_seen[string];
        string info_ids[string];
        string linear_ids[string];
        dpu_dut_caps caps;
        int unsigned notify_bank;
        bit [63:0] notify_base;
        bit [63:0] invalid_low;
        bit [63:0] invalid_high;
        string notify_group;
        string notify_commit_dependencies[$];
        string notify_commit_id;

        plan = null;
        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            why = "VIO teardown-plan builder requires a frozen device snapshot";
            return 0;
        end
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "VIO teardown-plan builder requires a frozen resource snapshot";
            return 0;
        end
        if (!resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "resource snapshot does not reference the supplied device snapshot";
            return 0;
        end
        if ((policy == null) || !policy.validate(why) ||
            !policy.selected_notify_bank(notify_bank, why))
            return 0;
        if (!device_snapshot.get_expected_af(af_key, af_bar0, why) ||
            !device_snapshot.get_pcie_id(af_key, af_pcie_id, why))
            return 0;
        caps = device_snapshot.snapshot_dut_caps();
        if (caps == null) begin
            why = "VIO teardown-plan builder cannot read DUT capabilities";
            return 0;
        end

        candidate = dpu_reg_plan::type_id::create(
            {get_name(), "_teardown_register_plan"});
        notify_base = (notify_bank == 0) ? DPU_VIO_NOTIFY_BANK0_BASE :
                                           DPU_VIO_NOTIFY_BANK1_BASE;
        notify_group = $sformatf(
            "vio.teardown.notify.bank%0d", notify_bank);
        if (!dpu_vio_pack_invalid_notify_entry(
                invalid_low, invalid_high, why))
            return 0;

        for (int unsigned clear_index = 0;
             clear_index < caps.vio_notify_entries_per_bank;
             clear_index++) begin
            bit [63:0] clear_offset;
            dpu_reg_op op;
            string low_id;
            string high_id;
            string low_verify_id;
            string high_verify_id;

            clear_offset = notify_base +
                clear_index * DPU_VIO_NOTIFY_ENTRY_STRIDE;
            if (!check_af_bar0_aperture(
                    af_bar0, clear_offset, 16,
                    "vio_notify_teardown", why))
                return 0;
            low_id = $sformatf(
                "vio.teardown.notify.bank%0d.entry%0d.clear.low",
                notify_bank, clear_index);
            op = make_af_op(
                low_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_HOST,
                $sformatf("vio_notify_bank%0d", notify_bank),
                clear_offset, 8);
            op.owner = "dpu.vio.teardown.notify";
            op.payload = invalid_low;
            op.write_mask = 64'hffff_ffff_ffff_ffff;
            op.commit_group = notify_group;
            if (!add_op(candidate, op, why))
                return 0;
            notify_commit_dependencies.push_back(low_id);

            high_id = $sformatf(
                "vio.teardown.notify.bank%0d.entry%0d.clear.high",
                notify_bank, clear_index);
            op = make_af_op(
                high_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_HOST,
                $sformatf("vio_notify_bank%0d", notify_bank),
                clear_offset + 8, 8);
            op.owner = "dpu.vio.teardown.notify";
            op.payload = invalid_high;
            op.write_mask = 64'hffff_ffff_ffff_ffff;
            op.commit_group = notify_group;
            op.add_dependency(low_id);
            if (!add_op(candidate, op, why))
                return 0;
            notify_commit_dependencies.push_back(high_id);

            if (policy.verify_notify_writes) begin
                low_verify_id = {low_id, ".verify"};
                if (!add_notify_verify_op(
                        candidate, low_verify_id, af_pcie_id,
                        DPU_REG_SCOPE_PER_HOST,
                        $sformatf("vio_notify_bank%0d", notify_bank),
                        clear_offset, invalid_low, high_id, why))
                    return 0;
                high_verify_id = {high_id, ".verify"};
                if (!add_notify_verify_op(
                        candidate, high_verify_id, af_pcie_id,
                        DPU_REG_SCOPE_PER_HOST,
                        $sformatf("vio_notify_bank%0d", notify_bank),
                        clear_offset + 8, invalid_high,
                        low_verify_id, why))
                    return 0;
                notify_commit_dependencies.push_back(high_verify_id);
            end
        end

        begin
            dpu_reg_op commit_op;

            notify_commit_id = $sformatf(
                "vio.teardown.notify.commit.bank%0d", notify_bank);
            commit_op = make_af_op(
                notify_commit_id, DPU_REG_OP_COMMIT, af_pcie_id,
                DPU_REG_PHASE_COMMIT, DPU_REG_SCOPE_PER_HOST,
                "vio_notify_commit", DPU_VIO_NOTIFY_COMMIT_ADDR, 4);
            commit_op.owner = "dpu.vio.teardown.notify.commit";
            commit_op.payload = notify_bank ?
                DPU_VIO_NOTIFY_COMMIT_SEL_MASK : 0;
            commit_op.write_mask = DPU_VIO_NOTIFY_COMMIT_RDY_MASK |
                                   DPU_VIO_NOTIFY_COMMIT_SEL_MASK;
            commit_op.commit_group = notify_group;
            foreach (notify_commit_dependencies[index])
                commit_op.add_dependency(
                    notify_commit_dependencies[index]);
            if (!check_af_bar0_aperture(
                    af_bar0, DPU_VIO_NOTIFY_COMMIT_ADDR, 4,
                    "vio_notify_teardown_commit", why) ||
                !add_op(candidate, commit_op, why))
                return 0;
        end

        resource_snapshot.list_vio_bindings(bindings);
        resource_snapshot.list_af_extra_queue_bindings(af_extra_bindings);
        foreach (bindings[index]) begin
            vector_owners.push_back(
                bindings[index].service_key.function_key);
            local_vectors.push_back(bindings[index].local_msix_vector_id);
            global_vectors.push_back(bindings[index].global_msix_vector_id);
        end
        foreach (af_extra_bindings[index]) begin
            vector_owners.push_back(af_extra_bindings[index].af_function_key);
            local_vectors.push_back(
                af_extra_bindings[index].local_msix_vector_id);
            global_vectors.push_back(
                af_extra_bindings[index].global_msix_vector_id);
        end

        foreach (vector_owners[index]) begin
            dpu_function_key_t owner_key;
            dpu_pcie_function_id_t owner_pcie_id;
            int unsigned source_id;
            string owner_name;
            string info_key;
            string linear_key;
            string info_id;
            string linear_id;
            string prefix;
            dpu_reg_op op;

            owner_key = vector_owners[index];
            owner_name = dpu_function_key_name(owner_key);
            if (!owned_function_seen.exists(owner_name)) begin
                owned_function_seen[owner_name] = 1;
                owned_functions.push_back(owner_key);
            end
            if (!device_snapshot.get_pcie_id(
                    owner_key, owner_pcie_id, why) ||
                !dpu_vio_compute_srcid(owner_key, source_id, why))
                return 0;
            if ((local_vectors[index] > 7'h7f) ||
                (global_vectors[index] >= caps.global_msix_vector_count)) begin
                why = "VIO teardown MSI-X binding exceeds DUT capability";
                return 0;
            end
            if (!check_af_bar0_aperture(
                    af_bar0,
                    DPU_VIO_MSIX_INFO_BASE + global_vectors[index] * 4,
                    4, "msix_info_teardown", why) ||
                !check_af_bar0_aperture(
                    af_bar0,
                    DPU_VIO_MSIX_LINEAR_BASE +
                    ((source_id << 7) + local_vectors[index]) * 4,
                    4, "msix_linear_teardown", why))
                return 0;

            prefix = $sformatf(
                "vio.teardown.h%0d.s%0d.b%04h.lv%0d.gv%0d",
                owner_pcie_id.domain.host_id,
                owner_pcie_id.domain.segment_id, owner_pcie_id.bdf,
                local_vectors[index], global_vectors[index]);
            info_key = $sformatf("%0d", global_vectors[index]);
            if (info_ids.exists(info_key)) begin
                info_id = info_ids[info_key];
            end else begin
                info_id = {prefix, ".msix_info.invalidate"};
                op = make_af_op(
                    info_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                    DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                    "msix_info",
                    DPU_VIO_MSIX_INFO_BASE + global_vectors[index] * 4,
                    4);
                op.owner = {"dpu.vio.teardown.msix.", owner_name};
                op.payload = 0;
                op.write_mask = 64'h0000_0000_ffff_ffff;
                op.add_dependency(notify_commit_id);
                if (!add_op(candidate, op, why))
                    return 0;
                info_ids[info_key] = info_id;
            end

            linear_key = {owner_name, ":",
                          $sformatf("%0d", local_vectors[index])};
            if (!linear_ids.exists(linear_key)) begin
                linear_id = {prefix, ".msix_linear.invalidate"};
                op = make_af_op(
                    linear_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                    DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                    "msix_linear",
                    DPU_VIO_MSIX_LINEAR_BASE +
                    ((source_id << 7) + local_vectors[index]) * 4,
                    4);
                op.owner = {"dpu.vio.teardown.msix.", owner_name};
                op.payload = 0;
                op.write_mask = 64'h0000_0000_ffff_ffff;
                op.add_dependency(info_id);
                if (!add_op(candidate, op, why))
                    return 0;
                linear_ids[linear_key] = linear_id;
            end
        end

        foreach (owned_functions[index]) begin
            dpu_function_key_t owner_key;
            dpu_pcie_function_id_t owner_pcie_id;
            int unsigned global_function_id;
            string owner_name;
            string bdf_id;
            bit dependency_seen[string];
            dpu_reg_op op;

            owner_key = owned_functions[index];
            owner_name = dpu_function_key_name(owner_key);
            if (!device_snapshot.get_pcie_id(
                    owner_key, owner_pcie_id, why) ||
                !device_snapshot.get_global_function_id(
                    owner_key, global_function_id, why))
                return 0;
            if (global_function_id >= caps.max_functions) begin
                why = "VIO teardown global function ID exceeds DUT capability";
                return 0;
            end
            if (!check_af_bar0_aperture(
                    af_bar0,
                    DPU_VIO_BDF_MAP_BASE + global_function_id * 4,
                    4, "preq_bdf_map_teardown", why))
                return 0;
            bdf_id = $sformatf(
                "vio.teardown.h%0d.s%0d.b%04h.f%0d.bdf.invalidate",
                owner_pcie_id.domain.host_id,
                owner_pcie_id.domain.segment_id, owner_pcie_id.bdf,
                global_function_id);
            op = make_af_op(
                bdf_id, DPU_REG_OP_MMIO_WRITE, af_pcie_id,
                DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_FUNCTION,
                "preq_bdf_map",
                DPU_VIO_BDF_MAP_BASE + global_function_id * 4, 4);
            op.owner = {"dpu.vio.teardown.bdf.", owner_name};
            op.payload = 0;
            op.write_mask = 64'h0000_0000_ffff_ffff;
            foreach (vector_owners[vector_index]) begin
                string linear_key;
                string dependency_id;

                if (!dpu_same_function_key(
                        vector_owners[vector_index], owner_key))
                    continue;
                linear_key = {owner_name, ":",
                    $sformatf("%0d", local_vectors[vector_index])};
                dependency_id = linear_ids[linear_key];
                if (!dependency_seen.exists(dependency_id)) begin
                    dependency_seen[dependency_id] = 1;
                    op.add_dependency(dependency_id);
                end
            end
            if (op.dependencies.size() == 0)
                op.add_dependency(notify_commit_id);
            if (!add_op(candidate, op, why))
                return 0;
        end

        plan = candidate;
        return 1;
    endfunction
endclass : dpu_vio_register_plan_builder

`endif // DPU_VIO_REGISTER_PLAN_BUILDER_SV
