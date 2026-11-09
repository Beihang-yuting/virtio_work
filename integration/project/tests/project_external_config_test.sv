// integration/project/tests：截图线格式独立常量检查；仅项目测试入口包含。
// 测试不创建 DUT、不拥有 DMA；黄金位值不复用产品打包函数。
`include "uvm_macros.svh"
import uvm_pkg::*;
import project_env_pkg::*;
	import virtio_dpu_pkg::*;
	import dpu_pcie_pkg::*;
	import dpu_resource_pkg::*;
class project_external_config_test extends uvm_test;
	`uvm_component_utils(project_external_config_test)
	// 构造测试；类型缺失时 RED 应在编译阶段明确失败。
	extern function new(string name, uvm_component parent);
	// 独立向量验证高位、保留位及 13-bit 中断字段。
	extern virtual task run_phase(uvm_phase phase);
endclass
function project_external_config_test::new(string name, uvm_component parent);
	super.new(name, parent);
endfunction
task project_external_config_test::run_phase(uvm_phase phase);
	dpu_vtx_entry_t	vtx;
	dpu_vrx_entry_t	vrx;
	dpu_qsch_q2tc_entry_t	q2tc;
	dpu_qsch_n2g_entry_t	n2g;
	phase.raise_objection(this);
	vtx = '0;
	vtx.high_speed_mode = 1;
	vtx.dma_msix = 13'h1fff;
	if ($bits(vtx) != 128 || vtx !== 128'h0000_0000_0fff_8100_0000_0000_0000_0000)
		`uvm_fatal("PROJECT_EXTERNAL", "VTX bit72/vector golden mismatch")
	vrx = '0;
	vrx.dsc_pre_read_ram_addr = 15'h4000;
	vrx.dma_msix_en = 1;
	vrx.dma_msix = 13'h1fff;
	if ($bits(vrx) != 128 || vrx !== 128'h4000_0001_fff8_0000_0000_0000_0000_0000)
		`uvm_fatal("PROJECT_EXTERNAL", "VRX fourth DWORD golden mismatch")
	q2tc = '0;
	q2tc.valid = 1;
	q2tc.net_id = 10'h3ff;
	q2tc.cos = 7;
	n2g = '0;
	n2g.valid = 1;
	n2g.group_id = 10'h3ff;
	if (q2tc !== 32'h80001fff || n2g !== 32'h800003ff)
		`uvm_fatal("PROJECT_EXTERNAL", "QSCH ten-bit golden mismatch")
	begin
		dpu_vtx_entry_t	e;
		if ($bits(e) != 128) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry width")
		e = '0; e.sport_id = '1;
		if (e !== 128'h000003ff000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.sport_id golden")
		e = '0; e.dma_info = '1;
		if (e !== 128'h00000000f00000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.dma_info golden")
		e = '0; e.dma_msix = '1;
		if (e !== 128'h000000000fff80000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.dma_msix golden")
		e = '0; e.sport = '1;
		if (e !== 128'h00000000000070000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.sport golden")
		e = '0; e.queue_stop = '1;
		if (e !== 128'h00000000000008000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.queue_stop golden")
		e = '0; e.tail_buf_id_dis = '1;
		if (e !== 128'h00000000000004000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.tail_buf_id_dis golden")
		e = '0; e.redraw_en = '1;
		if (e !== 128'h00000000000002000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.redraw_en golden")
		e = '0; e.high_speed_mode = '1;
		if (e !== 128'h00000000000001000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.high_speed_mode golden")
		e = '0; e.seg_en = '1;
		if (e !== 128'h00000000000000800000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.seg_en golden")
		e = '0; e.interl_seg_en = '1;
		if (e !== 128'h00000000000000400000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.interl_seg_en golden")
		e = '0; e.virtio_mode = '1;
		if (e !== 128'h00000000000000200000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.virtio_mode golden")
		e = '0; e.queue_en = '1;
		if (e !== 128'h00000000000000100000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.queue_en golden")
		e = '0; e.q_depth = '1;
		if (e !== 128'h000000000000000f0000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.q_depth golden")
		e = '0; e.desc_addr = '1;
		if (e !== 128'h0000000000000000ffffffffffffffff) `uvm_fatal("PROJECT_EXTERNAL", "vtx_entry.desc_addr golden")
	end
	begin
		dpu_vrx_entry_t	e;
		if ($bits(e) != 128) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry width")
		e = '0; e.dsc_pre_read_ram_addr = '1;
		if (e !== 128'h7fff0000000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dsc_pre_read_ram_addr golden")
		e = '0; e.dsc_pre_max_num = '1;
		if (e !== 128'h0000e000000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dsc_pre_max_num golden")
		e = '0; e.dsc_pre_read_threshold = '1;
		if (e !== 128'h00000c00000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dsc_pre_read_threshold golden")
		e = '0; e.dsc_dma_num = '1;
		if (e !== 128'h00000300000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dsc_dma_num golden")
		e = '0; e.dsc_mode = '1;
		if (e !== 128'h000000c0000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dsc_mode golden")
		e = '0; e.payload_dsc_len = '1;
		if (e !== 128'h00000038000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.payload_dsc_len golden")
		e = '0; e.head_dsc_len = '1;
		if (e !== 128'h00000006000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.head_dsc_len golden")
		e = '0; e.dma_msix_en = '1;
		if (e !== 128'h00000001000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dma_msix_en golden")
		e = '0; e.dma_msix = '1;
		if (e !== 128'h00000000fff800000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dma_msix golden")
		e = '0; e.dport_id = '1;
		if (e !== 128'h000000000007fe000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dport_id golden")
		e = '0; e.dport = '1;
		if (e !== 128'h00000000000001c00000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dport golden")
		e = '0; e.virtio_mode = '1;
		if (e !== 128'h00000000000000200000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.virtio_mode golden")
		e = '0; e.queue_en = '1;
		if (e !== 128'h00000000000000100000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.queue_en golden")
		e = '0; e.q_depth = '1;
		if (e !== 128'h000000000000000f0000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.q_depth golden")
		e = '0; e.dsc_addr = '1;
		if (e !== 128'h0000000000000000ffffffffffffffff) `uvm_fatal("PROJECT_EXTERNAL", "vrx_entry.dsc_addr golden")
	end
	begin
		dpu_vio_notify_entry_t	e;
		if ($bits(e) != 128) `uvm_fatal("PROJECT_EXTERNAL", "vio_notify_entry width")
		e = '0; e.notify_type = '1;
		if (e !== 128'h00000000000018000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vio_notify_entry.notify_type golden")
		e = '0; e.global_qid = '1;
		if (e !== 128'h00000000000007ff0000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vio_notify_entry.global_qid golden")
		e = '0; e.host_id = '1;
		if (e !== 128'h0000000000000000e000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "vio_notify_entry.host_id golden")
		e = '0; e.base_addr_60_7 = '1;
		if (e !== 128'h00000000000000001fffffffffffff80) `uvm_fatal("PROJECT_EXTERNAL", "vio_notify_entry.base_addr_60_7 golden")
		e = '0; e.local_qid_encoding = '1;
		if (e !== 128'h0000000000000000000000000000007f) `uvm_fatal("PROJECT_EXTERNAL", "vio_notify_entry.local_qid_encoding golden")
	end
	begin
		dpu_bdf_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "bdf_entry width")
		e = '0; e.vdpa_en = '1;
		if (e !== 32'h00040000) `uvm_fatal("PROJECT_EXTERNAL", "bdf_entry.vdpa_en golden")
		e = '0; e.ecrc_en = '1;
		if (e !== 32'h00020000) `uvm_fatal("PROJECT_EXTERNAL", "bdf_entry.ecrc_en golden")
		e = '0; e.valid = '1;
		if (e !== 32'h00010000) `uvm_fatal("PROJECT_EXTERNAL", "bdf_entry.valid golden")
		e = '0; e.requester_id = '1;
		if (e !== 32'h0000ffff) `uvm_fatal("PROJECT_EXTERNAL", "bdf_entry.requester_id golden")
	end
	begin
		dpu_ep_requester_id_t	e;
		if ($bits(e) != 16) `uvm_fatal("PROJECT_EXTERNAL", "ep_requester_id width")
		e = '0; e.vf_valid = '1;
		if (e !== 16'h8000) `uvm_fatal("PROJECT_EXTERNAL", "ep_requester_id.vf_valid golden")
		e = '0; e.vf_num = '1;
		if (e !== 16'h7ff0) `uvm_fatal("PROJECT_EXTERNAL", "ep_requester_id.vf_num golden")
		e = '0; e.pf_num = '1;
		if (e !== 16'h000f) `uvm_fatal("PROJECT_EXTERNAL", "ep_requester_id.pf_num golden")
	end
	begin
		dpu_completion_bdf_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "completion_bdf_entry width")
		e = '0; e.ecrc_en = '1;
		if (e !== 32'h00020000) `uvm_fatal("PROJECT_EXTERNAL", "completion_bdf_entry.ecrc_en golden")
		e = '0; e.valid = '1;
		if (e !== 32'h00010000) `uvm_fatal("PROJECT_EXTERNAL", "completion_bdf_entry.valid golden")
		e = '0; e.completion_id = '1;
		if (e !== 32'h0000ffff) `uvm_fatal("PROJECT_EXTERNAL", "completion_bdf_entry.completion_id golden")
	end
	begin
		dpu_pfvf_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "pfvf_entry width")
		e = '0; e.first_vf_offset = '1;
		if (e !== 32'h000007fe) `uvm_fatal("PROJECT_EXTERNAL", "pfvf_entry.first_vf_offset golden")
		e = '0; e.valid = '1;
		if (e !== 32'h00000001) `uvm_fatal("PROJECT_EXTERNAL", "pfvf_entry.valid golden")
	end
	begin
		dpu_tlp_prefix_entry_t	e;
		if ($bits(e) != 64) `uvm_fatal("PROJECT_EXTERNAL", "tlp_prefix_entry width")
		e = '0; e.vdpa_en = '1;
		if (e !== 64'h0000000200000000) `uvm_fatal("PROJECT_EXTERNAL", "tlp_prefix_entry.vdpa_en golden")
		e = '0; e.valid = '1;
		if (e !== 64'h0000000100000000) `uvm_fatal("PROJECT_EXTERNAL", "tlp_prefix_entry.valid golden")
		e = '0; e.tlp_prefix = '1;
		if (e !== 64'h00000000ffffffff) `uvm_fatal("PROJECT_EXTERNAL", "tlp_prefix_entry.tlp_prefix golden")
	end
	begin
		dpu_msix_linear_entry_t	e;
		if ($bits(e) != 64) `uvm_fatal("PROJECT_EXTERNAL", "msix_linear_entry width")
		e = '0; e.global_msix_idx = '1;
		if (e !== 64'h00000007ffc00000) `uvm_fatal("PROJECT_EXTERNAL", "msix_linear_entry.global_msix_idx golden")
		e = '0; e.host_id = '1;
		if (e !== 64'h0000000000380000) `uvm_fatal("PROJECT_EXTERNAL", "msix_linear_entry.host_id golden")
		e = '0; e.pfvf_id = '1;
		if (e !== 64'h000000000007fe00) `uvm_fatal("PROJECT_EXTERNAL", "msix_linear_entry.pfvf_id golden")
		e = '0; e.local_msix_idx = '1;
		if (e !== 64'h00000000000001ff) `uvm_fatal("PROJECT_EXTERNAL", "msix_linear_entry.local_msix_idx golden")
	end
	begin
		dpu_msix_info_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "msix_info_entry width")
		e = '0; e.valid = '1;
		if (e !== 32'h00004000) `uvm_fatal("PROJECT_EXTERNAL", "msix_info_entry.valid golden")
		e = '0; e.self_mask = '1;
		if (e !== 32'h00002000) `uvm_fatal("PROJECT_EXTERNAL", "msix_info_entry.self_mask golden")
		e = '0; e.host_id = '1;
		if (e !== 32'h00001c00) `uvm_fatal("PROJECT_EXTERNAL", "msix_info_entry.host_id golden")
		e = '0; e.function_id = '1;
		if (e !== 32'h000003ff) `uvm_fatal("PROJECT_EXTERNAL", "msix_info_entry.function_id golden")
	end
	begin
		dpu_msix_interval_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "msix_interval_entry width")
		e = '0; e.intrl_pnum = '1;
		if (e !== 32'hffff0000) `uvm_fatal("PROJECT_EXTERNAL", "msix_interval_entry.intrl_pnum golden")
		e = '0; e.intrl_rate = '1;
		if (e !== 32'h0000ffff) `uvm_fatal("PROJECT_EXTERNAL", "msix_interval_entry.intrl_rate golden")
	end
	begin
		dpu_msix_table_entry_t	e;
		if ($bits(e) != 128) `uvm_fatal("PROJECT_EXTERNAL", "msix_table_entry width")
		e = '0; e.msix_mask = '1;
		if (e !== 128'h00000001000000000000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "msix_table_entry.msix_mask golden")
		e = '0; e.msix_data = '1;
		if (e !== 128'h00000000ffffffff0000000000000000) `uvm_fatal("PROJECT_EXTERNAL", "msix_table_entry.msix_data golden")
		e = '0; e.msix_addr = '1;
		if (e !== 128'h0000000000000000ffffffffffffffff) `uvm_fatal("PROJECT_EXTERNAL", "msix_table_entry.msix_addr golden")
	end
	begin
		dpu_qsch_q2tc_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "qsch_q2tc_entry width")
		e = '0; e.valid = '1;
		if (e !== 32'h80000000) `uvm_fatal("PROJECT_EXTERNAL", "qsch_q2tc_entry.valid golden")
		e = '0; e.net_id = '1;
		if (e !== 32'h00001ff8) `uvm_fatal("PROJECT_EXTERNAL", "qsch_q2tc_entry.net_id golden")
		e = '0; e.cos = '1;
		if (e !== 32'h00000007) `uvm_fatal("PROJECT_EXTERNAL", "qsch_q2tc_entry.cos golden")
	end
	begin
		dpu_qsch_n2g_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "qsch_n2g_entry width")
		e = '0; e.valid = '1;
		if (e !== 32'h80000000) `uvm_fatal("PROJECT_EXTERNAL", "qsch_n2g_entry.valid golden")
		e = '0; e.group_id = '1;
		if (e !== 32'h000003ff) `uvm_fatal("PROJECT_EXTERNAL", "qsch_n2g_entry.group_id golden")
	end
	begin
		dpu_qsch_g2p_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "qsch_g2p_entry width")
		e = '0; e.valid = '1;
		if (e !== 32'h80000000) `uvm_fatal("PROJECT_EXTERNAL", "qsch_g2p_entry.valid golden")
		e = '0; e.dpt = '1;
		if (e !== 32'h000f0000) `uvm_fatal("PROJECT_EXTERNAL", "qsch_g2p_entry.dpt golden")
		e = '0; e.lvl2_id = '1;
		if (e !== 32'h0000000f) `uvm_fatal("PROJECT_EXTERNAL", "qsch_g2p_entry.lvl2_id golden")
	end
	begin
		dpu_qsch_rnet_entry_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "qsch_rnet_entry width")
		e = '0; e.host_id = '1;
		if (e !== 32'h0000000e) `uvm_fatal("PROJECT_EXTERNAL", "qsch_rnet_entry.host_id golden")
		e = '0; e.enable = '1;
		if (e !== 32'h00000001) `uvm_fatal("PROJECT_EXTERNAL", "qsch_rnet_entry.enable golden")
	end
	begin
		dpu_rdma_notify_entry_t	e;
		if ($bits(e) != 64) `uvm_fatal("PROJECT_EXTERNAL", "rdma_notify_entry width")
		e = '0; e.vf_id = '1;
		if (e !== 64'h07f8000000000000) `uvm_fatal("PROJECT_EXTERNAL", "rdma_notify_entry.vf_id golden")
		e = '0; e.host_id = '1;
		if (e !== 64'h0007000000000000) `uvm_fatal("PROJECT_EXTERNAL", "rdma_notify_entry.host_id golden")
		e = '0; e.base_addr_60_13 = '1;
		if (e !== 64'h0000ffffffffffff) `uvm_fatal("PROJECT_EXTERNAL", "rdma_notify_entry.base_addr_60_13 golden")
	end
	begin
		dpu_msix_pba_word_t	e;
		if ($bits(e) != 64) `uvm_fatal("PROJECT_EXTERNAL", "msix_pba_word width")
		e = '0; e.pending = '1;
		if (e !== 64'hffffffffffffffff) `uvm_fatal("PROJECT_EXTERNAL", "msix_pba_word.pending golden")
	end
	begin
		dpu_msix_stat_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "msix_stat width")
		e = '0; e.intrl_pnum_stat = '1;
		if (e !== 32'hffff0000) `uvm_fatal("PROJECT_EXTERNAL", "msix_stat.intrl_pnum_stat golden")
		e = '0; e.intrl_rate_timer = '1;
		if (e !== 32'h0000ffff) `uvm_fatal("PROJECT_EXTERNAL", "msix_stat.intrl_rate_timer golden")
	end
	begin
		dpu_pfvf_drop_status_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "pfvf_drop_status width")
		e = '0; e.status = '1;
		if (e !== 32'hffffffff) `uvm_fatal("PROJECT_EXTERNAL", "pfvf_drop_status.status golden")
	end
	begin
		dpu_pfvf_drop_clear_t	e;
		if ($bits(e) != 32) `uvm_fatal("PROJECT_EXTERNAL", "pfvf_drop_clear width")
		e = '0; e.clear_mask = '1;
		if (e !== 32'hffffffff) `uvm_fatal("PROJECT_EXTERNAL", "pfvf_drop_clear.clear_mask golden")
	end
	`uvm_info("PROJECT_EXTERNAL", "PROJECT_EXTERNAL_TYPES_PASS", UVM_LOW)
	phase.drop_objection(this);
endtask
