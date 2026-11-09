/*
 * 所属层次：integration/aip；验证原配置类通过真实 AIP 参数源加载的契约。
 * 依赖：canonical aip_core_pkg、virtio_net_pkg、dpu_resource_pkg 和 UVM；不创建 DUT 或总线。
 * 所有权：测试拥有临时配置对象；仅保存/恢复自己写入的 override 键，不清空全局参数表。
 * 生命周期：所有配置在 run_phase 同步构造和读取；service 缓存通过真实 get_service_config 检查。
 * 负例：+PARAM_NEGATIVE=<mode> 每项单独运行，必须在对应解析点 fatal；不可并入正常汇总。
 * 正例只验证 authoring、值复制和服务消费，不代替真实 PCIe/DMA 或寄存器执行验证。
 * external 的关闭/零队列模板必须允许精确 Host/service 再启用，不能在加载全局值时丢失覆盖能力。
 */
`ifndef VIRTIO_AIP_PARAMS_TEST_SV
`define VIRTIO_AIP_PARAMS_TEST_SV
import uvm_pkg::*;
import aip_core_pkg::*;
import virtio_net_pkg::*;
import dpu_resource_pkg::*;
`include "uvm_macros.svh"

// 把参数源与原类消费点放在同一测试中，避免只验证 parser 或手工构造出的期望对象。
class virtio_aip_params_test extends uvm_test;
	`uvm_component_utils(virtio_aip_params_test)
	bit	prior_present[string];
	string	prior_values[string];
	int unsigned	checks;

	// 构造仅登记 UVM 组件，不读参数、不改变随机流或全局配置。
	function new(string	name = "virtio_aip_params_test", uvm_component	parent = null);
		super.new(name, parent);
		checks = 0;
	endfunction

	// 写入与 Tcl set_param 相同的表；第一次写某键时保存旧值，供正例结束后恢复。
	function void put(string	key, string	value);
		if (!prior_present.exists(key)) begin
			prior_present[key] = aip_cmdline_override::has(key);
			if (prior_present[key]) prior_values[key] = aip_cmdline_override::get_val(key);
		end
		aip_cmdline_override::set_val(key, value);
	endfunction

	// 恢复本测试碰过的键；保留调用方的其他 override，避免跨测试污染。
	function void restore_overrides();
		foreach (prior_present[key]) begin
			if (prior_present[key]) aip_cmdline_override::set_val(key, prior_values[key]);
			else aip_cmdline_override::clear(key);
		end
		prior_present.delete();
		prior_values.delete();
	endfunction

	// 使用四态比较确保 X 不被当作通过；失败记录 UVM_ERROR，正常路径不降级或捕获错误。
	function void check_param(logic	condition, string	detail);
		checks++;
		if (condition !== 1'b1) `uvm_error("AIP_PARAMS_TEST", detail)
	endfunction

	// 构造一个合法的 authoring Host，拓扑由测试显式声明，load_params 不负责创建。
	function dpu_host_cfg make_host(string	name);
		dpu_host_cfg	host_cfg;
		dpu_pcie_domain_cfg	domain_cfg;
		dpu_mmio_window_cfg	window_cfg;
		dpu_bdf_range_t	bdf_range;
		host_cfg = new(name);
		host_cfg.has_gpa_aperture = 1;
		host_cfg.gpa_base = 64'h1_0000_0000;
		host_cfg.gpa_limit = 64'h1_1000_0000;
		domain_cfg = new({name, "_domain"});
		domain_cfg.key = '{host_id:0, segment_id:0};
		bdf_range = '{first_bdf:16'h100, last_bdf:16'h1ff};
		domain_cfg.bdf_ranges.push_back(bdf_range);
		domain_cfg.reserved_bdfs.push_back(16'h101);
		window_cfg = new({name, "_window"});
		window_cfg.base = 64'h2_0000_0000;
		window_cfg.limit = 64'h2_1000_0000;
		window_cfg.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
		domain_cfg.mmio_windows.push_back(window_cfg);
		host_cfg.pcie_domains.push_back(domain_cfg);
		return host_cfg;
	endfunction

	// 无覆盖时保留调用方现值，包括 64 位地址/feature、队列大小和策略子对象。
	function void test_defaults();
		virtio_net_env_config	cfg;
		dpu_host_cfg	host_cfg;
		dpu_env_cfg	policy;
		cfg = new("default_cfg");
		cfg.default_queue_size = 1024;
		cfg.default_driver_features = 64'hfedc_ba98_7654_3210;
		cfg.iova_base = 64'h1234_0000_0000;
		cfg.iova_limit = 64'h1234_0100_0000;
		cfg.wait_policy_cfg.default_timeout_ns = 12345;
		cfg.load_params("params.absent");
		check_param(cfg.default_queue_size == 1024, "无参数不得恢复为构造器 queue_size");
		check_param(cfg.default_driver_features == 64'hfedc_ba98_7654_3210, "features 默认值必须保持全部 64 位");
		check_param(cfg.iova_base == 64'h1234_0000_0000 && cfg.iova_limit == 64'h1234_0100_0000,
		      "IOVA 默认区间必须保留");
		check_param(cfg.wait_policy_cfg.default_timeout_ns == 12345, "wait 当前默认值必须保留");
		host_cfg = make_host("default_host");
		host_cfg.load_params("params.absent_dpu");
		check_param(host_cfg.pcie_domains.size() == 1 && host_cfg.pcie_domains[0].reserved_bdfs.size() == 1,
		      "无参数不得创建拓扑或清空保留列表");
		check_param(host_cfg.pcie_domains[0].reserved_bdfs[0] == 16'h101, "保留 BDF 的原值必须保留");

	endfunction

	// 根参数只采样一次，然后复制成 Host 模板；真实 service 查询应用精确路径并缓存结果。
	function void test_vio_layers_and_service();
		virtio_net_env_config	root_cfg;
		virtio_net_env_config	host0;
		virtio_net_env_config	host1;
		virtio_driver_config_t	first_cfg;
		virtio_driver_config_t	again_cfg;
		virtio_driver_config_t	other_cfg;
		dpu_priv_driver_config	late_private;
		dpu_service_key_t	key;
		dpu_service_key_t	other_key;
		string	why;
		bit	ok;
		put("params.vio.queue_size", "512");
		put("params.vio.pairs", "4");
		put("params.vio.features", "64'h80000001000000aa");
		put("params.vio.iova_base", "64'h123456780000");
		put("params.vio.iova_size", "0x200000");
		put("params.vio.wait.timeout_ns", "17000");
		root_cfg = new("root_cfg");
		root_cfg.load_params("params.vio");
		host0 = new("host0_cfg");
		host1 = new("host1_cfg");
		host0.copy_defaults_from(root_cfg);
		host1.copy_defaults_from(root_cfg);
		put("params.vio.h0.queue_size", "1024");
		host0.load_params("params.vio.h0");
		host1.load_params("params.vio.h1");
		check_param(root_cfg.default_queue_size == 512 && host1.default_queue_size == 512 &&
		      host0.default_queue_size == 1024, "Host 覆盖不能串改模板或另一个 Host");
		check_param(host0.default_driver_features == 64'h8000_0001_0000_00aa &&
		      host0.iova_base == 64'h1234_5678_0000 && host0.iova_limit == 64'h1234_5698_0000,
		      "64 位 features 与 IOVA base+size 必须完整继承");
		host0.wait_policy_cfg.default_timeout_ns = 18000;
		check_param(root_cfg.wait_policy_cfg.default_timeout_ns == 17000 &&
		      host1.wait_policy_cfg.default_timeout_ns == 17000, "等待策略模板必须深复制");
		key.function_key = '{host_id:0, pf_id:2, kind:DPU_FUNCTION_VF, vf_id:3};
		key.service_kind = DPU_SERVICE_VIO_NET;
		key.service_instance_id = 7;
		check_param(virtio_net_env_config::service_param_path(key, "params.vio") == "params.vio.h0.pf2.vf3.i7",
		      "service 参数路径必须使用完整 host/PF/VF/instance 身份");
		put("params.vio.h0.pf2.vf3.i7.queue_size", "2048");
		put("params.vio.h0.pf2.vf3.i7.pairs", "3");
		put("params.vio.h0.pf2.vf3.i7.features", "64'hfedcba9876543210");
		host0.enable_service_params("params.vio");
		ok = host0.get_service_config(key, 4, first_cfg, why);
		check_param(ok, {"首次真实 service 查询失败：", why});
		check_param(first_cfg.queue_size == 2048 && first_cfg.num_queue_pairs == 3 &&
		      first_cfg.driver_features == 64'hfedc_ba98_7654_3210, "service 覆盖必须到达 get_service_config 的返回配置");
		// 一旦首次消费已生成缓存，不允许在另一入口把标准服务改成私有协议。
		late_private = new("late_private");
		ok = host0.add_dpu_private_config(key, late_private, why);
		check_param(!ok && why != "", "已缓存 service 必须拒绝后续 private 登记，并返回失败原因");
		put("params.vio.h0.pf2.vf3.i7.queue_size", "4096");
		put("params.vio.h0.pf2.vf3.i7.pairs", "1");
		ok = host0.get_service_config(key, 2, again_cfg, why);
		check_param(ok && again_cfg.queue_size == 2048 && again_cfg.num_queue_pairs == 2,
		      "已缓存 service 不得因后续 set_param 重采样，仍须服从资源上限");
		ok = host0.get_service_config(key, 4, again_cfg, why);
		check_param(ok && again_cfg.num_queue_pairs == 3 && again_cfg.driver_features == first_cfg.driver_features,
		      "查询时的资源截断不得破坏缓存的原始行为配置");
		other_key = key;
		other_key.service_instance_id = 8;
		// 首次以较小限额消费未覆盖服务，缓存仍须保存 default_num_pairs=4 的原始意图。
		ok = host0.get_service_config(other_key, 1, other_cfg, why);
		check_param(ok && other_cfg.queue_size == 1024 && other_cfg.num_queue_pairs == 1,
		      "未覆盖 service 继承 Host 默认值，首次返回仍须服从一对队列的资源限额");
		ok = host0.get_service_config(other_key, 4, other_cfg, why);
		check_param(ok && other_cfg.queue_size == 1024 && other_cfg.num_queue_pairs == 4,
		      "首次资源限额不得永久截短未覆盖 service 的默认四对队列意图");
	endfunction

	// 私有字段使用位宽边界值并通过真实 resolve_queue/validate 消费，检查默认与单队列隔离。
	function void test_private();
		dpu_priv_driver_config	cfg;
		dpu_priv_queue_config	q0;
		dpu_priv_queue_config	q1;
		string	why;
		bit	ok;
		cfg = new("private_cfg");
		cfg.queues[1] = new("private_q1");
		put("params.private.queue_size", "1024");
		put("params.private.rx_buf_size", "4096");
		put("params.private.local_qid_base", "8");
		put("params.private.dport_info", "4095");
		put("params.private.dport_id", "1023");
		put("params.private.dport_type", "7");
		put("params.private.cpu_tx_cos", "7");
		put("params.private.fwd", "3");
		put("params.private.rss_lag", "1");
		put("params.private.l3_cs", "1");
		put("params.private.l4_cs", "1");
		put("params.private.notify_bar", "4");
		put("params.private.notify_offset", "0xfffffffc");
		put("params.private.q1.local_qid", "9");
		put("params.private.q1.dport_id", "17");
		cfg.load_params("params.private");
		ok = cfg.validate(1, why);
		check_param(ok, {"私有队列配置未通过真实几何校验：", why});
		q0 = cfg.resolve_queue(0);
		q1 = cfg.resolve_queue(1);
		check_param(cfg.default_queue_size == 1024 && cfg.rx_buf_size == 4096 && q0.local_qid == 8 && q1.local_qid == 9,
		      "私有 ring 几何和 RX/TX 本地号必须正确应用");
		check_param(q0.dport_info == 12'hfff && q0.dport_id == 10'h3ff && q0.dport_type == 7 &&
		      q0.cpu_tx_cos == 7 && q0.fwd == 3 && q0.rss_lag && q0.l3_cs && q0.l4_cs,
		      "私有路由/校验和字段不得截断边界值");
		check_param(q0.notify_offset == 32'hffff_fffc && q0.notify_bar == 4 && q1.dport_id == 17,
		      "私有通知宽度及 q1 独立覆盖必须保留");
		q0.dport_id = 0;
		check_param(cfg.defaults.dport_id == 1023, "resolve_queue 必须返回冻结副本，不能借用默认对象");
	endfunction

	// DPU 根模板与 Host 覆盖使用既有 domain/window，检验半开区间和深复制语义。
	function void test_dpu_hosts();
		dpu_host_cfg	root_cfg;
		dpu_host_cfg	host0;
		dpu_host_cfg	host1;
		root_cfg = make_host("dpu_template");
		put("params.dpu.mem_base", "0x123400000000");
		put("params.dpu.mem_size", "0x10000000");
		put("params.dpu.mmio_base", "0x223400000000");
		put("params.dpu.mmio_size", "0x20000000");
		put("params.dpu.bdf_first", "0x200");
		put("params.dpu.bdf_last", "0x2ff");
		put("params.dpu.reserved_bdfs", "0x201,0x202");
		put("params.dpu.bar_policy", "DPU_BAR_PLACEMENT_RANDOM");
		root_cfg.load_params("params.dpu");
		host0 = new("dpu_h0");
		host1 = new("dpu_h1");
		host0.copy_from(root_cfg);
		host1.copy_from(root_cfg);
		host1.host_id = 1;
		put("params.dpu.h0.mem_base", "0x123500000000");
		put("params.dpu.h0.mmio_size", "0x30000000");
		host0.load_params("params.dpu.h0");
		host1.load_params("params.dpu.h1");
		check_param(host0.gpa_base == 64'h1235_0000_0000 && host0.gpa_limit == 64'h1235_1000_0000,
		      "Host mem_base 覆盖必须继承模板 size 并计算半开 limit");
		check_param(host1.gpa_base == 64'h1234_0000_0000 && root_cfg.gpa_base == host1.gpa_base,
		      "DPU Host 覆盖不得串改根模板和其他 Host");
		check_param(host0.pcie_domains[0].mmio_windows[0].limit == 64'h2234_3000_0000 &&
		      host1.pcie_domains[0].mmio_windows[0].limit == 64'h2234_2000_0000,
		      "MMIO 窗口必须深复制且使用 base+size");
		check_param(host0.pcie_domains[0].bdf_ranges[0].first_bdf == 16'h200 &&
		      host0.pcie_domains[0].bdf_ranges[0].last_bdf == 16'h2ff &&
		      host0.pcie_domains[0].reserved_bdfs.size() == 2 &&
		      host0.pcie_domains[0].reserved_bdfs[1] == 16'h202 &&
		      host0.pcie_domains[0].bar_placement_policy == DPU_BAR_PLACEMENT_RANDOM,
		      "BDF 区间、保留集合和 BAR policy 必须继承模板");
	endfunction

	// placement、notify、QSCH 和 AF/caps 均使用原类入口，集合值由真实 AIP schema 解析。
	function void test_dpu_policies();
		dpu_resource_placement_cfg	placement_cfg;
		dpu_resource_pool_config_t	profile;
		dpu_vio_placement_request	request_cfg;
		dpu_env_cfg	policy;
		dpu_qsch_topology_generator	qsch;
		dpu_device_cfg	device_cfg;
		string	why;
		bit	ok;
		placement_cfg = new("placement_cfg");
		profile = '{name:"virtio.qpair", class_id:0, kind:DPU_RESOURCE_KIND_QUEUE, capacity:64, max_per_function:8};
		placement_cfg.profiles.push_back(profile);
		placement_cfg.reserved_global_qpair_ids.push_back(7);
		request_cfg = new("request_cfg");
		placement_cfg.vio_requests.push_back(request_cfg);
		put("params.place.qpairs", "6");
		put("params.place.qpair_capacity", "96");
		put("params.place.qpair_per_func", "16");
		put("params.place.reserved_qpairs", "1,3,5");
		put("params.place.lan_msix", "2");
		put("params.place.placement_seed", "123");
		put("params.place.candidate_kind", "DPU_VIO_CANDIDATE_PF_ONLY");
		put("params.place.device_policy", "DPU_VIO_DEVICE_FIXED");
		put("params.place.ordering", "DPU_PLACEMENT_SEEDED_RANDOM");
		put("params.place.host_ids", "0,1");
		put("params.place.vf_ids", "2,3");
		put("params.place.parent_pfs.size", "1");
		put("params.place.parent_pfs[0].host_id", "1");
		put("params.place.parent_pfs[0].pf_id", "2");
		put("params.place.fixed_devices.size", "1");
		put("params.place.fixed_devices[0].host_id", "1");
		put("params.place.fixed_devices[0].pf_id", "2");
		placement_cfg.load_params("params.place");
		check_param(placement_cfg.profiles[0].capacity == 96 && placement_cfg.profiles[0].max_per_function == 16 &&
		      placement_cfg.reserved_global_qpair_ids.size() == 3 && placement_cfg.reserved_global_qpair_ids[2] == 5,
		      "资源 capacity/per-function/reserved 必须映射到既有 profile");
		check_param(request_cfg.total_qpairs == 6 && request_cfg.lan_msix_vectors == 2 && request_cfg.seed == 123 &&
		      request_cfg.device_policy == DPU_VIO_DEVICE_FIXED && request_cfg.ordering == DPU_PLACEMENT_SEEDED_RANDOM,
		      "placement request 短名必须映射原字段");
		check_param(request_cfg.candidate_filter.host_ids.size() == 2 && request_cfg.candidate_filter.host_ids[1] == 1 &&
		      request_cfg.candidate_filter.vf_ids[1] == 3 && request_cfg.candidate_filter.parent_pf_keys.size() == 1 &&
		      request_cfg.candidate_filter.parent_pf_keys[0].pf_id == 2 && request_cfg.fixed_devices.size() == 1 &&
		      request_cfg.fixed_devices[0].host_id == 1 && request_cfg.fixed_devices[0].kind == DPU_FUNCTION_PF,
		      "候选与固定设备必须经过真实列表/schema API");
		policy = new("dut_policy");
		put("dpu.msix.interval_rate", "65535");
		put("dpu.msix.interval_packets", "32768");
		policy.load_params();
		check_param(policy.msix_policies[dpu_function_key_name('{0, 0, DPU_FUNCTION_PF, 0})].interval_entry == 32'h8000ffff,
		      "公共 MSI-X interval 必须使用图片定义的两个16位域");
		aip_cmdline_override::clear_all();
		qsch = new("qsch_generator");
		put("params.qsch.mode", "DPU_QSCH_TOPOLOGY_RANDOM_STRESS");
		put("params.qsch.max_groups", "3");
		put("params.qsch.max_ports", "2");
		put("params.qsch.max_tc", "4");
		put("params.qsch.shared_group", "1");
		put("params.qsch.include_af", "0");
		qsch.load_params("params.qsch");
		check_param(qsch.mode == DPU_QSCH_TOPOLOGY_RANDOM_STRESS && qsch.max_group_nodes == 3 &&
		      qsch.max_port_nodes == 2 && qsch.max_tc_id == 4 && qsch.require_shared_group && !qsch.include_af_extra_queues,
		      "QSCH 参数应只修改 generator 约束");
		device_cfg = new("device_cfg");
		device_cfg.af_request.requester = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
		put("params.device.af_host", "1");
		put("params.device.af_pf", "2");
		put("params.device.caps.max_hosts", "3");
		put("params.device.caps.vio_global_qpair_count", "128");
		device_cfg.load_params("params.device");
		check_param(device_cfg.af_request.requester.host_id == 1 && device_cfg.af_request.requester.pf_id == 2 &&
		      device_cfg.dut_caps.max_hosts == 3 && device_cfg.dut_caps.vio_global_qpair_count == 128 && device_cfg.hosts.size() == 0,
		      "AF/caps 加载不得顺带创建 Host 拓扑");
	endfunction

	// 每个非法输入必须在原加载入口终止；返回即失败。外部回归须核对具体错误文本和非零退出。
	function void run_negative(string	mode);
		virtio_net_env_config	vio_cfg;
		dpu_priv_driver_config	private_cfg;
		dpu_host_cfg	host_cfg;
		dpu_env_cfg	policy;
		vio_cfg = new("negative_vio");
		private_cfg = new("negative_private");
		host_cfg = make_host("negative_host");
		policy = new("negative_policy");
		`uvm_info("PARAM_NEGATIVE", {"expect rejection: ", mode}, UVM_NONE)
		case (mode)
			"features_width": begin put("params.bad.features", "65'h10000000000000000"); vio_cfg.load_params("params.bad"); end
			"iova_overflow": begin put("params.bad.iova_base", "0xfffffffffffff000"); put("params.bad.iova_size", "0x2000"); vio_cfg.load_params("params.bad"); end
			"queue_nonpower2": begin put("params.bad.queue_size", "3"); vio_cfg.load_params("params.bad"); end
			"queue_range": begin put("params.bad.queue_size", "65536"); vio_cfg.load_params("params.bad"); end
			"queue_wrap_negative": begin put("params.bad.queue_size", "-18446744073709551614"); vio_cfg.load_params("params.bad"); end
			"wait_wrap_negative": begin put("params.bad.wait.timeout_ns", "-18446744073709551615"); vio_cfg.load_params("params.bad"); end
			"pairs_range": begin put("params.bad.pairs", "33"); vio_cfg.load_params("params.bad"); end
			"pairs_zero": begin put("params.bad.pairs", "0"); vio_cfg.load_params("params.bad"); end
			"private_width": begin put("params.bad.dport_info", "4096"); private_cfg.load_params("params.bad"); end
			"private_geometry": begin put("params.bad.queue_size", "8192"); private_cfg.load_params("params.bad"); end
			"private_qid": begin put("params.bad.local_qid_base", "3"); private_cfg.load_params("params.bad"); end
			"gpa_overflow": begin put("params.bad.mem_base", "0xfffffffffffff000"); put("params.bad.mem_size", "0x2000"); host_cfg.load_params("params.bad"); end
			"mmio_overflow": begin put("params.bad.mmio_base", "0xfffffffffffff000"); put("params.bad.mmio_size", "0x2000"); host_cfg.load_params("params.bad"); end
			"bdf_width": begin put("params.bad.bdf_first", "0x10000"); host_cfg.load_params("params.bad"); end
			"unsigned_list": begin put("params.bad.reserved_bdfs", "-1"); host_cfg.load_params("params.bad"); end
			"notify_width": begin put("vio.vtx.dma_info", "16"); policy.load_params(); end
			"msix_width": begin put("dpu.msix.interval_rate", "65536"); policy.load_params(); end
			default: `uvm_fatal("PARAM_NEGATIVE_UNKNOWN", {"unknown mode: ", mode})
		endcase
		`uvm_fatal("PARAM_NEGATIVE_MISSED", {"illegal parameter was accepted: ", mode})
	endfunction


	// 全局和 Host 随机参数只采样一次；service 缓存及重载候选必须复用该结果。
	// 同时保留精确 service 覆盖、未提供字段的旧值和 Host 独立等待策略。
	extern function void test_external_sampling();

	// Custom 默认随机控制在每个 service 内共享，重载也先合并默认值再应用单队列覆盖。
	// 缺失的新参数保留当前队列值；不创建 ring 或访问 DUT。
	extern function void test_private_sampling();

	// 关闭、零对和双方向关闭在最终 service 才生效；Host/service 覆盖可独立重新启用。
	extern function void test_external_enables();

	// 正例顺序执行后恢复参数并报告计数；负例进程在对应入口 fatal，不伪造正常 PASS。
	extern virtual task run_phase(uvm_phase	phase);
endclass

// 运行参数合同检查；外部使能只在最终需求归一化，旧驱动的非法零对仍单独作为负例执行。
task virtio_aip_params_test::run_phase(uvm_phase	phase);
	string	negative_mode;

	phase.raise_objection(this);
	if ($value$plusargs("PARAM_NEGATIVE=%s", negative_mode)) run_negative(negative_mode);
	test_defaults();
	test_vio_layers_and_service();
	test_external_sampling();
	test_private_sampling();
	test_external_enables();
	test_private();
	test_dpu_hosts();
	test_dpu_policies();
	restore_overrides();
	`uvm_info("AIP_PARAMS_TEST", $sformatf("completed %0d parameter contract checks", checks), UVM_NONE)
	phase.drop_objection(this);
endtask

// 使用真实分层参数加载验证 Packed/Custom 的关闭语义，覆盖只改变目标 Host/Function。
// 不创建 ring；随后集成测试从实际 MMIO 验证这些最终需求控制了哪些表。
function void virtio_aip_params_test::test_external_enables();
	for (int unsigned	custom = 0; custom < 2; custom++) begin
		for (int unsigned	mode = 0; mode < 3; mode++) begin
			virtio_net_env_config	root_cfg;
			string					why;

			put("params.gates.enabled", mode == 0 ? "0" : "1");
			put("params.gates.pairs", mode == 1 ? "0" : "2");
			put("params.gates.tx_enable", mode == 2 ? "0" : "1");
			put("params.gates.rx_enable", mode == 2 ? "0" : "1");
			put("params.gates.queue_type", custom ? "VQ_CUSTOM" : "VQ_PACKED");
			put("params.gates.queue_size", "256");
			put("params.gates.completion_mode", "VIRTIO_COMPLETION_POLLING");
			put("params.gates.notify_base", "0");
			put("params.gates.notify_encoding", "VIO_NOTIFY_DPU32");
			put("params.gates.h0.pf1.i0.enabled", "1");
			put("params.gates.h0.pf1.i0.pairs", "1");
			put("params.gates.h0.pf1.i0.tx_enable", "1");
			put("params.gates.h1.enabled", "1");
			put("params.gates.h1.pairs", "1");
			put("params.gates.h1.rx_enable", "1");
			root_cfg = new("gate_template");
			root_cfg.external_configuration = 1;
			root_cfg.load_params("params.gates");
			check_param(root_cfg.enabled == (mode != 0), "全局加载不得提前改变 enabled 模板");

			for (int unsigned	h = 0; h < 2; h++) begin
				virtio_net_env_config		host_cfg;
				vio_service_requirement_t	requirement;
				dpu_service_key_t			key;

				host_cfg = new("gate_host");
				host_cfg.copy_defaults_from(root_cfg);
				host_cfg.load_params($sformatf("params.gates.h%0d", h));
				host_cfg.enable_service_params("params.gates");
				key = '{function_key:'{host_id:h, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0},
					service_kind:DPU_SERVICE_VIO_NET, service_instance_id:0};
				for (int unsigned	pf = 0; pf < 2; pf++) begin
					key.function_key.pf_id = pf;
					check_param(host_cfg.resolve_final_service_requirement(key, requirement, why), why);
					check_param(requirement.enabled == (h != 0 || pf != 0),
						"关闭模板或 Host/service 独立启用结果错误");
					if (requirement.enabled)
						check_param(requirement.behavior.num_queue_pairs == 1,
							"重新启用必须使用更精确层的队列数");
				end
			end
		end
	end
endfunction

// 每轮使用真实 AIP 列表/范围，比较不同 service 和候选的消费值，避免仅验证解析器。
function void virtio_aip_params_test::test_external_sampling();
	put("params.sample.queue_type", "VQ_PACKED");
	put("params.sample.queue_size", "256,512,1024");
	put("params.sample.napi_budget", "[32:4096]");
	put("params.sample.notify_base", "0,128,256");
	put("params.sample.completion_mode", "VIRTIO_COMPLETION_POLLING");
	put("params.sample.wait.poll_ns", "[1:127]");
	put("params.sample.h0.queue_size", "128,256,512");
	put("params.sample.h0.wait.reset_ns", "73");

	for (int unsigned	iteration = 0; iteration < 12; iteration++) begin
		virtio_net_env_config	root_cfg;
		virtio_net_env_config	root_candidate;
		virtio_net_env_config	host_cfg;
		virtio_net_env_config	host_candidate;
		vio_service_requirement_t	value;
		dpu_service_key_t	key;
		string	path;
		string	why;

		root_cfg = new("sample_root");
		root_cfg.external_configuration = 1;
		root_cfg.load_params("params.sample");
		check_param(root_cfg.make_runtime_candidate(null, "params.sample", root_candidate, why), why);

		for (int unsigned	h = 0; h < 2; h++) begin
			path = $sformatf("params.sample.h%0d", h);
			host_cfg = new("sample_host");
			host_cfg.copy_defaults_from(root_cfg);
			host_cfg.host_id = h;
			host_cfg.load_params(path);
			host_cfg.enable_service_params("params.sample");
			put({path, ".pf2.i0.rx_refill"}, "29");
			key.function_key = '{host_id:h, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
			key.service_kind = DPU_SERVICE_VIO_NET;
			key.service_instance_id = 0;
			for (int unsigned	pf = 0; pf < 3; pf++) begin
				key.function_key.pf_id = pf;
				check_param(host_cfg.resolve_final_service_requirement(key, value, why), why);
				check_param(value.behavior.queue_size == host_cfg.default_queue_size &&
					value.behavior.napi_budget == root_cfg.default_napi_budget &&
					value.notify_base == root_cfg.notify_base,
					"service must reuse sampled global and Host values");
				if (pf == 2) check_param(value.behavior.rx_refill_threshold == 29,
					"exact service override must win over inherited defaults");
			end
			aip_cmdline_override::clear({path, ".pf2.i0.rx_refill"});
			check_param(host_cfg.make_runtime_candidate(root_candidate, path, host_candidate, why), why);
			for (int unsigned	pf = 0; pf < 3; pf++) begin
				key.function_key.pf_id = pf;
				check_param(host_cfg.validate_runtime_service(host_candidate, key, why), why);
				check_param(host_candidate.resolve_final_service_requirement(key, value, why), why);
				check_param(value.behavior.queue_size == host_candidate.default_queue_size &&
					value.behavior.napi_budget == root_candidate.default_napi_budget &&
					value.notify_base == root_candidate.notify_base,
					"runtime Host/service must reuse the global candidate sample");
				if (pf == 2) check_param(value.behavior.rx_refill_threshold == 29,
					"missing runtime override must preserve the current service value");
			end
			check_param(host_candidate.wait_policy_cfg.default_poll_interval_ns ==
				root_candidate.wait_policy_cfg.default_poll_interval_ns,
				"runtime wait parameters must reuse the global sample");
			if (h == 0)
				check_param(host_candidate.wait_policy_cfg.reset_timeout_ns == 73,
					"Host wait override must remain independent");
		end
	end
endfunction

// 用不相交数值范围检查默认继承和 qN 优先级，避免依赖随机巧合判定重复采样。
function void virtio_aip_params_test::test_private_sampling();
	virtio_net_env_config	cfg;
	virtio_net_env_config	candidate;
	dpu_priv_driver_config	private_cfg;
	vio_service_requirement_t	requirement;
	dpu_service_key_t	key;
	string	why;

	put("params.custom.queue_type", "VQ_CUSTOM");
	put("params.custom.features", "0");
	put("params.custom.pairs", "2");
	put("params.custom.completion_mode", "VIRTIO_COMPLETION_POLLING");
	put("params.custom.private.dport_id", "[16:31]");
	put("params.custom.h0.private.dport_id", "[64:127]");
	put("params.custom.private.q1.dport_id", "7");
	put("params.custom.private.q3.cpu_tx_cos", "3");
	cfg = new("custom_sampling");
	cfg.external_configuration = 1;
	cfg.load_params("params.custom");
	cfg.load_params("params.custom.h0");
	cfg.enable_service_params("params.custom");
	key.function_key = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
	key.service_kind = DPU_SERVICE_VIO_NET;
	key.service_instance_id = 0;
	check_param(cfg.resolve_final_service_requirement(key, requirement, why), why);

	for (int unsigned	iteration = 0; iteration < 4; iteration++) begin
		private_cfg = cfg.get_dpu_private_config(key);
		check_param(private_cfg != null, "Custom service must own its generated private config");
		if (private_cfg == null) return;
		foreach (private_cfg.queues[q]) begin
			check_param(private_cfg.queues[q].dport_id ==
				(q == 1 ? 7 : private_cfg.defaults.dport_id),
				"Custom queues must share sampled defaults and preserve qN precedence");
		end
		check_param(private_cfg.queues[3].cpu_tx_cos == 3,
			"missing runtime parameter must preserve the current private queue value");
		if (iteration == 3) break;
		aip_cmdline_override::clear("params.custom.private.q3.cpu_tx_cos");
		check_param(cfg.make_runtime_candidate(null, "params.custom.h0", candidate, why), why);
		check_param(cfg.validate_runtime_service(candidate, key, why), why);
		cfg.apply_runtime_candidate(candidate);
	end
endfunction
`endif // VIRTIO_AIP_PARAMS_TEST_SV
