// 中文说明：dpu_common 是项目外独立版本库；调用方必须先设置
// DPU_COMMON_ROOT，filelist 不允许回退到本仓库内的同名源码副本。
// dpu_common is an external, independently versioned repository.  The
// caller must export DPU_COMMON_ROOT to its checked-out fixed revision.
+incdir+$DPU_COMMON_ROOT/src
$DPU_COMMON_ROOT/src/dpu_resource_pkg.sv
