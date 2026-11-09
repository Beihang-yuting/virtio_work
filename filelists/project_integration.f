// Intel HARD_IP + 真实 EP 应用 DUT 的唯一项目参考入口；从 virtio_work 根运行。
// 依赖根由调用方提供；Intel interface、adapter 和 DUT 的接口几何必须一致。
// 已有统一工程 filelist 时，按此顺序增补缺失包，禁止把已有包再次编译。
-f filelists/aip_integration.f
+incdir+$INTEL_PCIE_ROOT/src
$INTEL_PCIE_ROOT/src/interface/intel_pcie_if.sv
$INTEL_PCIE_ROOT/src/adapter/intel_pcie_adapter_pkg.sv
-f $DPU_COMMON_ROOT/filelists/dpu_pcie.f
+incdir+integration/dpu
integration/dpu/virtio_dpu_pkg.sv
+incdir+integration/project
integration/project/project_env_pkg.sv
