// =============================================================================
// DPU Fabric shared resource package
// =============================================================================

`ifndef DPU_RESOURCE_PKG_SV
`define DPU_RESOURCE_PKG_SV

package dpu_resource_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "dpu_resource_types.sv"
  `include "dpu_reg_plan_types.sv"
  `include "dpu_reg_op.sv"
  `include "dpu_reg_plan.sv"
  `include "dpu_reg_executor.sv"
  `include "dpu_spy_reg_executor.sv"
  `include "dpu_dut_caps.sv"
  `include "dpu_resource_manager.sv"
  `include "dpu_fabric_env.sv"

endpackage : dpu_resource_pkg

`endif // DPU_RESOURCE_PKG_SV
