// Intel HARD_IP + 真实 EP 应用 DUT 的可选项目参考入口；从 virtio_work 根运行。
// 与 project_integration.f 二选一。复用公共依赖，不重复加入 Intel 的整份库 filelist。
// 调用方另提供 INTEL_PCIE_ROOT；接口几何宏必须对 interface、package 和 DUT top 一致。
+define+PROJECT_PCIE_INTEL
-f filelists/aip_integration.f
+incdir+$INTEL_PCIE_ROOT/src
$INTEL_PCIE_ROOT/src/interface/intel_pcie_if.sv
$INTEL_PCIE_ROOT/src/adapter/intel_pcie_adapter_pkg.sv
+incdir+integration/project
integration/project/project_env_pkg.sv
