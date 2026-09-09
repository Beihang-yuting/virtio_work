`ifndef VIRTIO_PF_INSTANCE_SV
`define VIRTIO_PF_INSTANCE_SV

// Bridges an Admin-VQ full-reset request to the owner of the real PF
// lifecycle.  Success means normal PF queue/DMA state was invalidated after a
// verified transport reset; Admin VQ does not own or infer this lifecycle.
// 中文文件头：
// 职责——本文件定义两个类：
//   1) virtio_pf_lifecycle_reset_owner：把 Admin-VQ 的 PF 全复位请求桥接到
//      真正持有 PF 生命周期的 virtio_function_instance（Admin VQ 自身不拥有
//      也不推断该生命周期）；
//   2) virtio_pf_instance：拥有一个 PF function 及其下属全部 VF function 的
//      容器组件，负责从冻结 snapshot 批量解析/创建 PF+VF 并接线 pf_manager。
// 依赖——dpu_device_snapshot/dpu_resource_snapshot（冻结对）、
//   dpu_resource_manager（须由同一对 snapshot 播种）、virtio_pf_manager。
// 所有权——PF/VF 实例组件由本类 create 并作为子组件持有；BDF/BAR/qpair
//   资源归 snapshot+manager；pf_manager 可外部预注入，否则本类懒创建。
class virtio_pf_lifecycle_reset_owner extends virtio_admin_full_reset_owner;
    `uvm_object_utils(virtio_pf_lifecycle_reset_owner)

    virtio_function_instance pf_function;

    // 构造函数：仅 UVM 注册；pf_function 由 virtio_pf_instance 在
    // connect_phase 绑定。
    function new(string name = "virtio_pf_lifecycle_reset_owner");
        super.new(name);
    endfunction

    // 执行 PF 全复位：委托被绑定的 pf_function.reset_pf_lifecycle；
    // 未绑定时报错并保持 reset_complete=0（调用方据此判定失败）。
    virtual task reset_pf_lifecycle(ref bit reset_complete);
        reset_complete = 0;
        if (pf_function == null) begin
            `uvm_error("PF_RESET_OWNER",
                "full PF reset owner has no bound normal PF lifecycle")
            return;
        end

        pf_function.reset_pf_lifecycle(reset_complete);
    endtask
endclass : virtio_pf_lifecycle_reset_owner

// Owns one independently addressable PF function and its subordinate VFs.
class virtio_pf_instance extends uvm_component;
    `uvm_component_utils(virtio_pf_instance)

    int unsigned                host_id;
    int unsigned                pf_id;
    dpu_function_key_t          pf_key;
    dpu_function_key_t          vf_keys[];
    virtio_function_instance    pf_function;
    virtio_vf_instance          vf_functions[];
    virtio_pf_manager           pf_manager;
    virtio_pf_lifecycle_reset_owner lifecycle_reset_owner;
    protected bit               configuration_valid;
    protected bit               services_configured;

    // 构造函数：初始化为"未配置"状态；实际拓扑必须经 configure_services
    // 从冻结 snapshot 注入，build_phase 会对未配置实例直接 fatal。
    function new(string name, uvm_component parent);
        super.new(name, parent);
        configuration_valid = 0;
        services_configured = 0;
    endfunction

    // 从冻结 snapshot 一次性解析并创建整个 PF 服务组（PF + 全部 VF）。
    // 前置校验（全部通过前不改动任何成员，保证失败无副作用）：
    //   - 只允许配置一次；parent 必须是 PF key（vf_id==0）；
    //   - device/resource snapshot 均冻结、互相引用，且 manager 由同一对
    //     snapshot 播种；能查到 virtio.qpair 资源类；
    //   - manager 与 snapshot 的 DUT 能力（host/PF/VF/队列/MSI-X/BAR profile）
    //     逐项一致；
    //   - 每个 service：必须是 VIO_NET、有 qpair 绑定、owner 属于本 PF 组、
    //     owner 不重复、PCIe id 可解析、三个 BAR 角色齐全且顺序正确、
    //     manager 包含该 function。
    // 通过后：记录 pf_key/host_id/pf_id，按 owner 类型创建 pf_function 或
    // vf_functions[]（各自 configure_from_service），并把每个 service 的
    // qpair 绑定导入 pf_manager.resource_pool；成功返回 1，失败 why 说明。
    function bit configure_services(
        input dpu_function_key_t parent_pf_key,
        input dpu_device_snapshot snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_keys[$],
        input dpu_resource_manager manager,
        output string why
    );
        dpu_function_key_t owner;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_role_e required_roles[$];
        dpu_function_key_t seen_owners[$];
        dpu_function_key_t resolved_owners[$];
        dpu_resource_class_id_t qpair_class_id;
        dpu_dut_caps snapshot_caps;
        dpu_dut_caps manager_caps;
        bit owner_seen;
        int unsigned vf_count;
        dpu_vio_qpair_binding_t service_bindings[$];

        why = "";
        if (services_configured) begin
            why = "PF service group is already configured";
            return 0;
        end
        if ((parent_pf_key.kind != DPU_FUNCTION_PF) ||
            (parent_pf_key.vf_id != 0)) begin
            why = "VIO service group requires a PF parent key";
            return 0;
        end
        if ((snapshot == null) || !snapshot.is_frozen()) begin
            why = "VIO service group requires a frozen device snapshot";
            return 0;
        end
        if (manager == null) begin
            why = "VIO service group requires a device resource manager";
            return 0;
        end
        if (!manager.is_snapshot_seeded()) begin
            why = "VIO service group requires a snapshot-seeded device manager";
            return 0;
        end
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(snapshot) ||
            !manager.is_seeded_from_snapshots(snapshot, resource_snapshot)) begin
            why = "VIO service group requires its exact frozen resource snapshot";
            return 0;
        end
        if (!manager.lookup_resource_class(
                "virtio.qpair", qpair_class_id, why)) begin
            why = {"VIO service group requires virtio.qpair: ", why};
            return 0;
        end
        snapshot_caps = snapshot.snapshot_dut_caps();
        manager_caps = manager.snapshot_dut_caps();
        if ((snapshot_caps == null) || !snapshot_caps.validate(why)) begin
            why = {"VIO service group snapshot capabilities are invalid: ", why};
            return 0;
        end
        if ((manager_caps == null) || !manager_caps.validate(why)) begin
            why = {"VIO service group manager capabilities are invalid: ", why};
            return 0;
        end
        if ((manager_caps.max_hosts != snapshot_caps.max_hosts) ||
            (manager_caps.max_pfs_per_host != snapshot_caps.max_pfs_per_host) ||
            (manager_caps.max_vfs_per_pf != snapshot_caps.max_vfs_per_pf) ||
            (manager_caps.max_functions != snapshot_caps.max_functions) ||
            (manager_caps.global_msix_vector_count !=
             snapshot_caps.global_msix_vector_count) ||
            (manager_caps.vio_global_qpair_count !=
             snapshot_caps.vio_global_qpair_count) ||
            (manager_caps.max_vio_net_qpairs_per_device !=
             snapshot_caps.max_vio_net_qpairs_per_device) ||
            (manager_caps.vio_notify_entries_per_bank !=
             snapshot_caps.vio_notify_entries_per_bank) ||
            (manager_caps.bar_profiles.size() !=
             snapshot_caps.bar_profiles.size())) begin
            why = "VIO service group manager capabilities differ from snapshot";
            return 0;
        end
        foreach (snapshot_caps.bar_profiles[index]) begin
            dpu_bar_profile_t manager_profile;
            dpu_bar_profile_t snapshot_profile;

            snapshot_profile = snapshot_caps.bar_profiles[index];
            if (!manager_caps.lookup_bar_profile(
                    snapshot_profile.kind, snapshot_profile.role,
                    manager_profile, why) ||
                (manager_profile.even_bar_id != snapshot_profile.even_bar_id) ||
                (manager_profile.size != snapshot_profile.size) ||
                (manager_profile.alignment != snapshot_profile.alignment)) begin
                why = "VIO service group manager BAR capabilities differ from snapshot";
                return 0;
            end
        end
        if (service_keys.size() == 0) begin
            why = "VIO service group is empty";
            return 0;
        end
        required_roles.push_back(DPU_BAR_DEVICE_MEMORY);
        required_roles.push_back(DPU_BAR_MAILBOX);
        required_roles.push_back(DPU_BAR_MSIX);

        foreach (service_keys[index]) begin
            if (service_keys[index].service_kind != DPU_SERVICE_VIO_NET) begin
                why = "VIO service group contains a non-VIO service";
                return 0;
            end
            if (!snapshot.get_service_owner(service_keys[index], owner, why))
                return 0;
            resource_snapshot.list_vio_bindings_for_service(
                service_keys[index], service_bindings);
            if (service_bindings.size() == 0) begin
                why = "VIO service has no resource-snapshot qpair bindings";
                return 0;
            end
            if ((owner.host_id != parent_pf_key.host_id) ||
                (owner.pf_id != parent_pf_key.pf_id) ||
                ((owner.kind != DPU_FUNCTION_PF) &&
                 (owner.kind != DPU_FUNCTION_VF))) begin
                why = "VIO service owner does not belong to its PF group";
                return 0;
            end
            owner_seen = 0;
            foreach (seen_owners[seen_index]) begin
                if (dpu_same_function_key(seen_owners[seen_index], owner))
                    owner_seen = 1;
            end
            if (owner_seen) begin
                why = "VIO service group declares duplicate function ownership";
                return 0;
            end
            seen_owners.push_back(owner);
            if (!snapshot.get_pcie_id(owner, pcie_id, why))
                return 0;
            bars.delete();
            foreach (required_roles[role_index]) begin
                dpu_bar_pair_lease_t bar;

                if (!snapshot.get_bar(owner, required_roles[role_index], bar, why))
                    return 0;
                bars.push_back(bar);
            end
            if ((bars[0].role != DPU_BAR_DEVICE_MEMORY) ||
                (bars[1].role != DPU_BAR_MAILBOX) ||
                (bars[2].role != DPU_BAR_MSIX)) begin
                why = "VIO service owner BAR roles are not device-memory, mailbox, MSI-X";
                return 0;
            end
            if (!manager.contains_function(owner)) begin
                why = "snapshot-seeded manager does not contain VIO service owner";
                return 0;
            end
            resolved_owners.push_back(owner);
        end

        // No component or topology-view state is mutated before every service
        // dependency above has passed preflight.
        pf_key = parent_pf_key;
        host_id = parent_pf_key.host_id;
        pf_id = parent_pf_key.pf_id;
        vf_count = 0;
        foreach (seen_owners[index]) begin
            if (seen_owners[index].kind == DPU_FUNCTION_VF)
                vf_count++;
        end
        vf_keys = new[vf_count];
        vf_functions = new[vf_count];
        if (pf_manager == null)
            pf_manager = virtio_pf_manager::type_id::create("pf_manager");

        foreach (service_keys[index]) begin
            owner = resolved_owners[index];
            if (owner.kind == DPU_FUNCTION_PF) begin
                if (pf_function != null) begin
                    why = "VIO service group declares duplicate PF service";
                    return 0;
                end
                pf_function = virtio_function_instance::type_id::create(
                    "pf_function", this);
                if (!pf_function.configure_from_service(
                        snapshot, resource_snapshot,
                        service_keys[index], manager)) begin
                    why = "could not configure resolved PF VIO function";
                    return 0;
                end
            end
            else begin
                int unsigned vf_index;

                vf_index = 0;
                while ((vf_index < vf_functions.size()) &&
                       (vf_functions[vf_index] != null))
                    vf_index++;
                vf_keys[vf_index] = owner;
                vf_functions[vf_index] = virtio_vf_instance::type_id::create(
                    $sformatf("vf_function_%0d", owner.vf_id), this);
                if (!vf_functions[vf_index].configure_from_service(
                        snapshot, resource_snapshot,
                        service_keys[index], manager)) begin
                    why = "could not configure resolved VF VIO function";
                    return 0;
                end
            end
        end
        foreach (service_keys[index]) begin
            if (!pf_manager.resource_pool.import_service_bindings(
                    service_keys[index], resource_snapshot, why)) begin
                why = {"could not import VIO service queue view: ", why};
                return 0;
            end
        end
        services_configured = 1;
        configuration_valid = 1;
        return 1;
    endfunction

    // 收集本 PF 组内全部已创建的 function 实例（PF 在前、VF 按序在后），
    // 输出前先清空调用方队列；null 槽位（未配置的 VF）被跳过。
    function void collect_functions(ref virtio_function_instance functions[$]);
        functions.delete();
        if (pf_function != null)
            functions.push_back(pf_function);
        foreach (vf_functions[index]) begin
            if (vf_functions[index] != null)
                functions.push_back(vf_functions[index]);
        end
    endfunction

    // build 阶段守卫：未经 configure_services 的实例直接 fatal——PF 组
    // 不允许脱离 snapshot 声明凭空构建；补建缺失的 pf_manager 并赋 pf_index。
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!services_configured) begin
            `uvm_fatal("PF_INSTANCE",
                "PF instance requires snapshot-declared VIO services")
            return;
        end
        if (pf_manager == null)
            pf_manager = virtio_pf_manager::type_id::create("pf_manager");
        pf_manager.pf_index = pf_id;
        configuration_valid = 1;
    endfunction

    // connect 阶段接线：把 VF 实例数组与 PF transport 交给 pf_manager，
    // 并创建 lifecycle_reset_owner 绑定 pf_function，使 Admin-VQ 全复位
    // 请求能路由到真实 PF 生命周期；配置无效时静默跳过（build 已报 fatal）。
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!configuration_valid)
            return;
        pf_manager.vf_instances = new[vf_functions.size()];
        foreach (vf_functions[vf_id])
            pf_manager.vf_instances[vf_id] = vf_functions[vf_id];
        if (pf_function != null) begin
            pf_manager.pf_transport = pf_function.transport;
            lifecycle_reset_owner = virtio_pf_lifecycle_reset_owner::type_id::create(
                "lifecycle_reset_owner"
            );
            lifecycle_reset_owner.pf_function = pf_function;
            pf_manager.configure_pf_lifecycle_reset_owner(lifecycle_reset_owner);
        end
    endfunction

endclass : virtio_pf_instance

`endif // VIRTIO_PF_INSTANCE_SV
