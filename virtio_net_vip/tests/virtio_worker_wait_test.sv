// tests：两个普通 FSM 各运行两对队列，验证等待互不取消且 stop 等到所有 worker 退出。
import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// Split 的 total_poll_used_ops 只统计成功回收；另计调用以观测空队列的真实轮询。
class virtio_worker_wait_ops extends virtio_atomic_ops;
	`uvm_object_utils(virtio_worker_wait_ops)
	longint unsigned	attempts[int unsigned];
	extern function new(string name = "virtio_worker_wait_ops");
	extern virtual task tx_complete(input int unsigned queue_id, ref uvm_object completed_pkts[$],
		input int unsigned max_budget);
endclass

// 观察器保留原 ops 行为，不产生完成或改变等待。
function virtio_worker_wait_ops::new(string name = "virtio_worker_wait_ops");
	super.new(name);
endfunction

// 每次 worker 调用仍执行真实空队列检查，计数不依赖设备产生完成。
task virtio_worker_wait_ops::tx_complete(input int unsigned queue_id, ref uvm_object completed_pkts[$],
	input int unsigned max_budget);
	attempts[queue_id]++;
	super.tx_complete(queue_id, completed_pkts, max_budget);
endtask

class virtio_worker_wait_fsm extends virtio_auto_fsm;
	`uvm_object_utils(virtio_worker_wait_fsm)
	// 单元夹具只预置已经完成设备配置的状态，不替代任何运行 worker。
	extern function new(string name = "virtio_worker_wait_fsm");
	extern function void set_ready();
endclass

function virtio_worker_wait_fsm::new(string name = "virtio_worker_wait_fsm");
	super.new(name);
endfunction

// 预置两对队列的已确认状态；本夹具不执行设备初始化。
function void virtio_worker_wait_fsm::set_ready();
	active_num_pairs = 2;
	num_total_queues = 4;
	mq_pairs_committed = 1;
	state = FSM_READY;
endfunction

class virtio_worker_wait_test extends uvm_test;
	`uvm_component_utils(virtio_worker_wait_test)
	// 使用真实队列和普通协议 worker，计数器检查停止后没有后台轮询残留。
	extern function new(string name, uvm_component parent);
	extern virtual task run_phase(uvm_phase phase);
endclass

function virtio_worker_wait_test::new(string name, uvm_component parent);
	super.new(name, parent);
endfunction

// 两个 Function 同时运行真实 worker；检查定时进展、停止应答和停止后静默。
task virtio_worker_wait_test::run_phase(uvm_phase phase);
	virtio_worker_wait_fsm	fsms[2];
	virtio_vq_test_kit	kits[2];
	virtio_worker_wait_ops	ops[2];
	longint unsigned	polls[2][2];

	phase.raise_objection(this);
	foreach (fsms[f]) begin
		virtio_mock_transport	transport;
		host_mem_manager	mem;
		virtio_iommu_model	iommu;
		virtio_net_env_config	defaults;

		transport = new($sformatf("transport%0d", f));
		transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h30 + f));
		mem = new($sformatf("mem%0d", f));
		mem.init_region(64'h61000000 + f*64'h100000, 64'h610fffff + f*64'h100000);
		iommu = new($sformatf("iommu%0d", f));
		kits[f] = virtio_vq_test_kit::create_kit($sformatf("worker%0d", f), mem, iommu, transport.bdf);
		kits[f].wait_pol.default_poll_interval_ns = 10;
		for (int q = 0; q < 4; q++) void'(kits[f].add_split(q, 8));

		fsms[f] = new($sformatf("fsm%0d", f));
		ops[f] = new($sformatf("ops%0d", f));
		fsms[f].ops = kits[f].make_ops(transport, "", ops[f]);
		defaults = new($sformatf("defaults%0d", f));
		defaults.default_num_pairs = 2;
		fsms[f].drv_cfg = defaults.make_default_driver_config(2);
		fsms[f].drv_cfg.queue_size = 8;
		fsms[f].drv_cfg.rx_buf_size = 64;
		fsms[f].drv_cfg.irq_mode = IRQ_POLLING;
		fsms[f].set_ready();
		fsms[f].start_dataplane();
	end

	#300ns;
	foreach (fsms[f]) for (int pair_id = 0; pair_id < 2; pair_id++) begin
		if (ops[f].attempts[pair_id*2+1] == 0)
			`uvm_fatal("WORKER_WAIT", "a queue worker did not make timed progress")
		polls[f][pair_id] = ops[f].attempts[pair_id*2+1];
	end

	#100ns;
	foreach (fsms[f]) begin
		for (int pair_id = 0; pair_id < 2; pair_id++)
			if (ops[f].attempts[pair_id*2+1] <= polls[f][pair_id])
				`uvm_fatal("WORKER_WAIT", "a queue worker stopped progressing in the next window")
		fsms[f].stop_dataplane();
		if (!fsms[f].external_workers_stopped() || fsms[f].state != FSM_READY)
			`uvm_fatal("WORKER_WAIT", "stop returned before all workers acknowledged")
		for (int pair_id = 0; pair_id < 2; pair_id++)
			polls[f][pair_id] = ops[f].attempts[pair_id*2+1];
	end

	#100ns;
	foreach (fsms[f]) for (int pair_id = 0; pair_id < 2; pair_id++)
		if (polls[f][pair_id] != ops[f].attempts[pair_id*2+1])
			`uvm_fatal("WORKER_WAIT", "stopped worker continued polling")

	`uvm_info("WORKER_WAIT_PASS", "two ordinary FSMs/two pairs progress and stop independently", UVM_NONE)
	phase.drop_objection(this);
endtask
