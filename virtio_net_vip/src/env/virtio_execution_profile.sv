`ifndef VIRTIO_EXECUTION_PROFILE_SV
`define VIRTIO_EXECUTION_PROFILE_SV

// ============================================================================
// virtio_execution_profile
//
// 目录层次：src/env；MODEL / REAL_DUT 执行主体的唯一选择点。fixture 与环境只向
// 策略询问"是否有本地设备模型、PCIe 接口模式、EP 是否主动、是否需要物理链路"，
// 不再比较 virtio_execution_mode_e。策略是无状态只读对象，不创建也不持有任何
// PCIe/Host memory 组件；组件的创建与绑定仍由调用方完成。
// ============================================================================

virtual class virtio_execution_profile extends uvm_object;
    // 无状态；构造不访问配置或设备。
    function new(string name = "virtio_execution_profile");
        super.new(name);
    endfunction

    // 对应的配置枚举，仅供日志与配置回显使用。
    pure virtual function virtio_execution_mode_e mode();
    // 是否由本地 MODEL 扮演设备：创建 TLM completion adapter、EP responder，
    // 安装端点配置镜像并用 MODEL DMA adapter 产生设备侧 DMA。
    pure virtual function bit has_model_device();
    // 是否允许创建 RC 侧 Host-memory DMA responder（只服务 EP 发起的 MemRd/MemWr）。
    pure virtual function bit supports_host_mem_responder();
    // 是否必须绑定 RC->EP 与 EP->RC 两条物理 VIF 才能运行驱动流程。
    pure virtual function bit needs_physical_link();
    // pcie_tl_env_config.if_mode 的取值。
    pure virtual function pcie_tl_if_mode_e pcie_if_mode();
    // pcie_tl_env_config.ep_is_active 的取值。
    pure virtual function uvm_active_passive_enum ep_is_active();
    // pcie_tl_env_config.ep_auto_response 的取值。
    pure virtual function bit ep_auto_response();
    // 端点尚未准备好时给调用方的诊断文本。
    pure virtual function string endpoint_unready_reason();
endclass

// 无 RTL DUT：VIP 的 responder 扮演设备，PCIe 走 TLM 回环。
class virtio_model_execution_profile extends virtio_execution_profile;
    `uvm_object_utils(virtio_model_execution_profile)

    // 无状态；构造不访问配置或设备。
    function new(string name = "virtio_model_execution_profile");
        super.new(name);
    endfunction

    virtual function virtio_execution_mode_e mode();
        return VIRTIO_EXEC_MODEL;
    endfunction
    virtual function bit has_model_device();
        return 1'b1;
    endfunction
    virtual function bit supports_host_mem_responder();
        return 1'b0;
    endfunction
    virtual function bit needs_physical_link();
        return 1'b0;
    endfunction
    virtual function pcie_tl_if_mode_e pcie_if_mode();
        return TLM_MODE;
    endfunction
    virtual function uvm_active_passive_enum ep_is_active();
        return UVM_ACTIVE;
    endfunction
    virtual function bit ep_auto_response();
        return 1'b1;
    endfunction
    virtual function string endpoint_unready_reason();
        return "endpoint image was not derived from the frozen snapshot";
    endfunction
endclass

// 真实 DUT：端点配置与 BAR 响应来自 RTL，VIP 只保留被动观察与可选 RC 服务。
class virtio_real_dut_execution_profile extends virtio_execution_profile;
    `uvm_object_utils(virtio_real_dut_execution_profile)

    // 无状态；构造不访问配置或设备。
    function new(string name = "virtio_real_dut_execution_profile");
        super.new(name);
    endfunction

    virtual function virtio_execution_mode_e mode();
        return VIRTIO_EXEC_REAL_DUT;
    endfunction
    virtual function bit has_model_device();
        return 1'b0;
    endfunction
    virtual function bit supports_host_mem_responder();
        return 1'b1;
    endfunction
    virtual function bit needs_physical_link();
        return 1'b1;
    endfunction
    virtual function pcie_tl_if_mode_e pcie_if_mode();
        return SV_IF_MODE;
    endfunction
    virtual function uvm_active_passive_enum ep_is_active();
        return UVM_PASSIVE;
    endfunction
    virtual function bit ep_auto_response();
        return 1'b0;
    endfunction
    virtual function string endpoint_unready_reason();
        return "REAL_DUT endpoint identity/interface was not prepared";
    endfunction
endclass

// 唯一的枚举→策略映射；保留/未知编码返回 null，由调用方报告非法配置。
function automatic virtio_execution_profile virtio_select_execution_profile(
    virtio_execution_mode_e mode
);
    virtio_model_execution_profile model_profile;
    virtio_real_dut_execution_profile real_dut_profile;

    case (mode)
        VIRTIO_EXEC_MODEL: begin
            model_profile = virtio_model_execution_profile::type_id::create(
                "model_execution_profile");
            return model_profile;
        end
        VIRTIO_EXEC_REAL_DUT: begin
            real_dut_profile = virtio_real_dut_execution_profile::type_id::create(
                "real_dut_execution_profile");
            return real_dut_profile;
        end
        default: return null;
    endcase
endfunction

`endif // VIRTIO_EXECUTION_PROFILE_SV
