// env：外部配置只读值视图与 service scope。环境拥有唯一已交付句柄和代号；
// 查询返回副本，不允许通过修改视图接管 ring，伪造对象不能通过环境的句柄校验。
`ifndef VIO_EXTERNAL_SETUP_SV
`define VIO_EXTERNAL_SETUP_SV
class vio_external_setup extends uvm_object;
    local uvm_object	origin;
    local dpu_device_snapshot	device;
    local dpu_resource_snapshot	resources;
    local longint unsigned	generation;
    local vio_queue_setup_t	queues[$];

    // 构造只读视图，所有值由已成功准备的环境提供；不分配或释放任何 DMA。
    extern function new(string name, uvm_object source_env, dpu_device_snapshot device_snapshot,
        dpu_resource_snapshot resource_snapshot, longint unsigned prepare_generation,
        vio_queue_setup_t records[$]);

    // 精确身份查询；环境同时校验对象句柄，构造相同内容仍不能冒充本代导出。
    extern function bit belongs_to(input uvm_object source_env,
        input dpu_device_snapshot device_snapshot, input dpu_resource_snapshot resource_snapshot,
        input longint unsigned prepare_generation);

    // 准备代号只用于诊断/项目账本，不授予确认权。
    extern function longint unsigned get_generation();

    // 导出完整队列值副本，GPA/IOVA/格式/向量来自真实准备结果。
    extern function void list_queues(output vio_queue_setup_t records[$]);

    // 查询一条准确 service+local_qid，未知键返回 0。
    extern function bit get_queue(input dpu_service_key_t key, input int unsigned qid,
        output vio_queue_setup_t record);
endclass

function vio_external_setup::new(string name, uvm_object source_env, dpu_device_snapshot device_snapshot,
        dpu_resource_snapshot resource_snapshot, longint unsigned prepare_generation,
        vio_queue_setup_t records[$]);
    super.new(name);
    origin = source_env;
    device = device_snapshot;
    resources = resource_snapshot;
    generation = prepare_generation;
    queues = records;
endfunction

function bit vio_external_setup::belongs_to(input uvm_object source_env,
        input dpu_device_snapshot device_snapshot, input dpu_resource_snapshot resource_snapshot,
        input longint unsigned prepare_generation);
    return origin == source_env && device == device_snapshot && resources == resource_snapshot &&
           generation == prepare_generation;
endfunction

function longint unsigned vio_external_setup::get_generation();
    return generation;
endfunction

function void vio_external_setup::list_queues(output vio_queue_setup_t records[$]);
    records = queues;
endfunction

function bit vio_external_setup::get_queue(input dpu_service_key_t key, input int unsigned qid,
        output vio_queue_setup_t record);
    foreach (queues[i]) begin
        if (dpu_service_key_name(queues[i].service_key) == dpu_service_key_name(key) &&
            queues[i].notification.local_qid == qid) begin
            record = queues[i];
            return 1;
        end
    end
    return 0;
endfunction


// scope 仅选择已交付 service，不改变编号；空 keys 表示本 setup 的全部 service。
class vio_config_scope extends uvm_object;
    local vio_external_setup	setup_ref;
    local dpu_service_key_t	service_keys[$];

    // 保存选择值，是否未知/重复由 validate 完整检查，不把错误 scope 扩大为全部。
    extern function new(string name, vio_external_setup setup,
        dpu_service_key_t keys[$]);

    // 完整校验来源和全部键；失败不修改 scope 或 setup。
    extern function bit validate(input vio_external_setup setup, output string why);

    // 对已校验 scope 的准确 service 选择查询。
    extern function bit selects(input dpu_service_key_t key);
endclass

function vio_config_scope::new(string name, vio_external_setup setup,
        dpu_service_key_t keys[$]);
    super.new(name);
    setup_ref = setup;
    service_keys = keys;
endfunction

function bit vio_config_scope::validate(input vio_external_setup setup, output string why);
    vio_queue_setup_t	records[$];
    bit	found;
    bit	seen[string];
    string	key;

    why = "";
    if (setup == null || setup != setup_ref) begin
        why = "scope belongs to another setup";
        return 0;
    end
    setup.list_queues(records);
    foreach (service_keys[i]) begin
        key = dpu_service_key_name(service_keys[i]);
        found = 0;
        foreach (records[q])
            if (dpu_service_key_name(records[q].service_key) == key) found = 1;
        if (!found || seen.exists(key)) begin
            why = {"scope contains unknown/duplicate service: ", key};
            return 0;
        end
        seen[key] = 1;
    end
    return 1;
endfunction

function bit vio_config_scope::selects(input dpu_service_key_t key);
    if (service_keys.size() == 0) return 1;
    foreach (service_keys[i])
        if (dpu_service_key_name(service_keys[i]) == dpu_service_key_name(key)) return 1;
    return 0;
endfunction

`endif
