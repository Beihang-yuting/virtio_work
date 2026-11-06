// integration/project：项目参考组装的唯一 package 编译入口。
// 顺序：AIP→DPU/Host memory/PCIe TL/VIO→AIP glue→本包。
// PROJECT_PCIE_INTEL 时，Intel interface/adapter package 也必须在本包之前编译。
// include 的普通 .sv 不可另行编译；本包只定义类型，不创建组件或取得外部资源。
package project_env_pkg;
    timeunit 1ns;
    timeprecision 1ps;

    import uvm_pkg::*;
    import aip_core_pkg::*;
    import host_mem_pkg::*;
    import dpu_resource_pkg::*;
    import pcie_tl_pkg::*;
    import virtio_net_pkg::*;
    import virtio_aip_pkg::*;
`ifdef PROJECT_PCIE_INTEL
    import intel_pcie_adapter_pkg::*;
`endif
    `include "uvm_macros.svh"

    `include "project_env_cfg.sv"
    `include "project_env.sv"
    `include "project_base_test.sv"
endpackage
