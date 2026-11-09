// integration/dpu：可选 VIO/DPU/PCIe 接入，晚于三个生产包编译。
// 只提供生命周期连接和带 DMA/MSI-X 接收能力的 RC driver，不创建资源或引用 project。
package virtio_dpu_pkg;
	timeunit 1ns;
	timeprecision 1ps;

	import uvm_pkg::*;
	import host_mem_pkg::*;
	import dpu_resource_pkg::*;
	import dpu_pcie_pkg::*;
	import pcie_tl_pkg::*;
	import virtio_net_pkg::*;
	`include "uvm_macros.svh"
	`include "vio_pcie_rc_driver.sv"
	`include "vio_dpu_cfg_seq.sv"
endpackage
