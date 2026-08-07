`ifndef VIRTIO_PF_LIFECYCLE_RESET_TEST_SV
`define VIRTIO_PF_LIFECYCLE_RESET_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// This transport reports a chosen device-reset completion without requiring
// PCIe traffic.  The PF lifecycle API remains responsible for what completion
// permits it to invalidate.
class virtio_pf_lifecycle_test_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_pf_lifecycle_test_transport)

    bit          device_reset_complete;
    int unsigned device_reset_count;
    int unsigned kick_count;

    function new(string name = "virtio_pf_lifecycle_test_transport");
        super.new(name);
        device_reset_complete = 1;
        device_reset_count = 0;
        kick_count = 0;
    endfunction

    virtual task reset_device_verified(ref bit reset_complete);
        device_reset_count++;
        reset_complete = device_reset_complete;
    endtask

    // Pending-DMA lifecycle tests exercise real split virtqueues but do not
    // need a PCIe notification path.  Keep the transport side effect
    // observable without requiring a TLM sequencer.
    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
        kick_count++;
    endtask
endclass : virtio_pf_lifecycle_test_transport

// The production classes keep their allocation/mapping tables protected.
// These test-only views make reset ownership observable without widening the
// public dataplane API solely for a regression assertion.
class virtio_pf_lifecycle_tracking_mem extends host_mem_manager;
    `uvm_object_utils(virtio_pf_lifecycle_tracking_mem)

    function new(string name = "virtio_pf_lifecycle_tracking_mem");
        super.new(name);
    endfunction

    function int unsigned outstanding_allocations();
        return alloc_table.size();
    endfunction
endclass : virtio_pf_lifecycle_tracking_mem

class virtio_pf_lifecycle_tracking_iommu extends virtio_iommu_model;
    `uvm_object_utils(virtio_pf_lifecycle_tracking_iommu)

    function new(string name = "virtio_pf_lifecycle_tracking_iommu");
        super.new(name);
    endfunction

    function int unsigned active_mapping_count();
        return mapping_table.size();
    endfunction
endclass : virtio_pf_lifecycle_tracking_iommu

class virtio_pf_lifecycle_test_packet extends uvm_object;
    `uvm_object_utils(virtio_pf_lifecycle_test_packet)

    function new(string name = "virtio_pf_lifecycle_test_packet");
        super.new(name);
    endfunction
endclass : virtio_pf_lifecycle_test_packet

// The first refill belongs to start_dataplane().  The next invocation comes
// from the real background RX worker and remains in a shared dataplane call
// until the test releases it.  A PF reset must not start transport reset while
// that real worker is still active.
class virtio_pf_lifecycle_blocking_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_pf_lifecycle_blocking_ops)

    uvm_event    worker_entered;
    uvm_event    release_worker;
    int unsigned rx_refill_call_count;
    bit          worker_active;

    function new(string name = "virtio_pf_lifecycle_blocking_ops");
        super.new(name);
        worker_entered = new("worker_entered");
        release_worker = new("release_worker");
        rx_refill_call_count = 0;
        worker_active = 0;
    endfunction

    virtual task rx_refill(int unsigned queue_id, int unsigned num_bufs);
        rx_refill_call_count++;
        if (rx_refill_call_count == 1)
            return;
        worker_active = 1;
        worker_entered.trigger();
        release_worker.wait_trigger();
        worker_active = 0;
    endtask
endclass : virtio_pf_lifecycle_blocking_ops

// No background traffic is needed for this unit test.  The override records
// that the PF-owned reset path first asked the real FSM to quiesce it.
class virtio_pf_lifecycle_test_fsm extends virtio_auto_fsm;
    `uvm_object_utils(virtio_pf_lifecycle_test_fsm)

    int unsigned stop_count;

    function new(string name = "virtio_pf_lifecycle_test_fsm");
        super.new(name);
        stop_count = 0;
    endfunction

    virtual task stop_dataplane();
        stop_count++;
        state = FSM_READY;
    endtask
endclass : virtio_pf_lifecycle_test_fsm

class virtio_pf_lifecycle_expected_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_pf_lifecycle_expected_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "ATOMIC_OPS") &&
            uvm_is_match("*transport reset did not complete; retaining PF DMA*",
                         get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_pf_lifecycle_expected_error_catcher

class virtio_pf_lifecycle_set_active_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_pf_lifecycle_set_active_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "FUNCTION_INSTANCE") &&
            uvm_is_match("*set_active: function * requires reinitialization before activation*",
                         get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_pf_lifecycle_set_active_error_catcher

class virtio_pf_lifecycle_tx_alloc_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_pf_lifecycle_tx_alloc_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (((get_id() == "HOST_MEM") &&
              uvm_is_match("*alloc: insufficient space*", get_message())) ||
             ((get_id() == "ATOMIC_OPS") &&
              uvm_is_match("*tx_submit: host_mem alloc failed*", get_message())))) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_pf_lifecycle_tx_alloc_error_catcher

class virtio_pf_lifecycle_blocking_vf extends virtio_vf_instance;
    `uvm_component_utils(virtio_pf_lifecycle_blocking_vf)

    uvm_event release_init;
    bit       init_entered;
    bit       init_completed;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        release_init = new("release_init");
        init_entered = 0;
        init_completed = 0;
    endfunction

    virtual task init(virtio_driver_config_t cfg);
        init_entered = 1;
        release_init.wait_trigger();
        init_completed = 1;
        super.init(cfg);
    endtask
endclass : virtio_pf_lifecycle_blocking_vf

class virtio_pf_lifecycle_conc_timeout_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_pf_lifecycle_conc_timeout_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_WARNING) && (get_id() == "CONC_CTRL") &&
            uvm_is_match("*parallel_vf_op: timeout after 20ns*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_pf_lifecycle_conc_timeout_catcher

class virtio_pf_lifecycle_reset_test extends uvm_test;
    `uvm_component_utils(virtio_pf_lifecycle_reset_test)

    virtio_function_instance          pf_function;
    virtio_pf_lifecycle_blocking_vf   concurrency_normal_vf;
    virtio_pf_lifecycle_blocking_vf   concurrency_timeout_vf;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "pf_function.driver_agent", "is_active", UVM_PASSIVE
        );
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "concurrency_normal_vf.driver_agent", "is_active", UVM_PASSIVE
        );
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "concurrency_timeout_vf.driver_agent", "is_active", UVM_PASSIVE
        );
        pf_function = virtio_function_instance::type_id::create(
            "pf_function", this
        );
        concurrency_normal_vf = virtio_pf_lifecycle_blocking_vf::type_id::create(
            "concurrency_normal_vf", this
        );
        concurrency_timeout_vf = virtio_pf_lifecycle_blocking_vf::type_id::create(
            "concurrency_timeout_vf", this
        );
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_verified_reset_quiesces_and_requires_reinitialization();
        test_verified_reset_retires_pending_normal_dma();
        test_tx_second_allocation_failure_releases_header();
        test_pf_reset_waits_for_real_dataplane_worker();
        test_parallel_vf_op_waits_and_cancels_workers();
        test_failed_reset_retains_pf_runtime();
        test_set_active_rejects_reinit_required();
        test_set_active_rejects_reset_failed();

        `uvm_info("PF_LIFECYCLE", "PF lifecycle reset tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    task test_parallel_vf_op_waits_and_cancels_workers();
        virtio_concurrency_controller                 controller;
        virtio_pf_lifecycle_conc_timeout_catcher      catcher;
        virtio_driver_config_t                         cfg;
        int unsigned                                   vf_ids[$];
        int unsigned                                   no_vf_ids[$];
        bit                                            results[];
        int unsigned                                   actual_sent[];
        bit                                            normal_returned;
        bit                                            timeout_returned;

        controller = virtio_concurrency_controller::type_id::create(
            "pf_lifecycle_concurrency_controller");
        controller.vf_instances = new[1];
        controller.vf_instances[0] = concurrency_normal_vf;
        vf_ids.push_back(0);
        cfg.num_queue_pairs = 0;
        cfg.queue_size = 0;
        cfg.vq_type = VQ_SPLIT;
        cfg.driver_features = '0;
        cfg.rx_buf_mode = RX_MODE_MERGEABLE;
        cfg.rx_buf_size = 0;
        cfg.rx_refill_threshold = 0;
        cfg.irq_mode = IRQ_MSIX_PER_QUEUE;
        cfg.napi_budget = 0;
        cfg.coal_max_packets = 0;
        cfg.coal_max_usecs = 0;
        cfg.bw_limit_enable = 0;
        cfg.bw_limit_mbps = 0;
        cfg.mode = DRV_MODE_AUTO;
        concurrency_normal_vf.drv_cfg = cfg;
        concurrency_timeout_vf.drv_cfg = cfg;
        normal_returned = 0;

        fork
            begin
                controller.parallel_vf_op(vf_ids, VIO_TXN_INIT, 100, results);
                normal_returned = 1;
            end
        join_none

        wait (concurrency_normal_vf.init_entered);
        #(1ns);
        assert(!normal_returned)
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_vf_op returned before its blocking worker completed")
        concurrency_normal_vf.release_init.trigger();
        wait (normal_returned);
        assert((results.size() == 1) && results[0] && concurrency_normal_vf.init_completed)
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_vf_op did not await and return the completed worker result")

        controller.vf_instances[0] = concurrency_timeout_vf;
        catcher = new("parallel_vf_op_timeout_catcher");
        uvm_report_cb::add(null, catcher);
        timeout_returned = 0;

        fork
            begin
                controller.parallel_vf_op(vf_ids, VIO_TXN_INIT, 20, results);
                timeout_returned = 1;
            end
        join_none

        wait (concurrency_timeout_vf.init_entered);
        #(1ns);
        assert(!timeout_returned)
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_vf_op returned before its configured timeout")
        wait (timeout_returned);
        assert((results.size() == 1) && !results[0] && !concurrency_timeout_vf.init_completed &&
               catcher.caught_count == 1)
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_vf_op timeout did not preserve an incomplete worker result")
        concurrency_timeout_vf.release_init.trigger();
        #(1ns);
        uvm_report_cb::delete(null, catcher);
        assert(!concurrency_timeout_vf.init_completed)
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_vf_op timeout left its worker alive after return")

        controller.parallel_vf_op(no_vf_ids, VIO_TXN_INIT, 20, results);
        assert(results.size() == 0)
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_vf_op did not return an empty result for zero workers")
        controller.parallel_traffic(vf_ids, 2, actual_sent);
        assert((actual_sent.size() == 1) && (actual_sent[0] == 2))
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_traffic did not await and return the worker count")
        controller.parallel_traffic(no_vf_ids, 2, actual_sent);
        assert(actual_sent.size() == 0)
            else `uvm_fatal("PF_LIFECYCLE",
                "parallel_traffic did not return an empty result for zero workers")
    endtask

    // This deliberately uses the production FSM's start/stop implementation,
    // not the counter-only test override used by the simpler lifecycle tests.
    // The old fixed two-interval stop returned while this worker was blocked,
    // allowing PF reset to detach queues and DMA concurrently.
    task test_pf_reset_waits_for_real_dataplane_worker();
        virtio_pf_lifecycle_reset_owner   reset_owner;
        virtio_pf_lifecycle_test_transport transport;
        virtio_auto_fsm                    fsm;
        virtio_pf_lifecycle_blocking_ops   ops;
        virtio_iommu_model                  iommu;
        host_mem_manager                    mem;
        virtio_memory_barrier_model         barrier;
        virtqueue_error_injector            err_inj;
        virtio_wait_policy                  wait_pol;
        virtio_driver_config_t              cfg;
        bit                                 reset_complete;
        bit                                 reset_returned;

        transport = virtio_pf_lifecycle_test_transport::type_id::create(
            "real_worker_reset_transport");
        fsm = virtio_auto_fsm::type_id::create("real_worker_reset_fsm");
        ops = virtio_pf_lifecycle_blocking_ops::type_id::create(
            "real_worker_reset_ops");
        iommu = virtio_iommu_model::type_id::create("real_worker_reset_iommu");
        mem = host_mem_manager::type_id::create("real_worker_reset_mem");
        barrier = virtio_memory_barrier_model::type_id::create(
            "real_worker_reset_barrier");
        err_inj = virtqueue_error_injector::type_id::create(
            "real_worker_reset_err_inj");
        wait_pol = virtio_wait_policy::type_id::create(
            "real_worker_reset_wait_pol");
        reset_owner = virtio_pf_lifecycle_reset_owner::type_id::create(
            "real_worker_reset_owner");

        mem.init_region(64'h6100_0000, 64'h6100_FFFF);
        wait_pol.default_poll_interval_ns = 10;
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 8;
        cfg.vq_type = VQ_SPLIT;
        cfg.driver_features = '0;
        cfg.rx_buf_mode = RX_MODE_MERGEABLE;
        cfg.rx_buf_size = 0;
        cfg.rx_refill_threshold = 1;
        cfg.irq_mode = IRQ_MSIX_PER_QUEUE;
        cfg.napi_budget = 0;
        cfg.coal_max_packets = 0;
        cfg.coal_max_usecs = 0;
        cfg.bw_limit_enable = 0;
        cfg.bw_limit_mbps = 0;
        cfg.mode = DRV_MODE_AUTO;

        pf_function.function_kind = DPU_FUNCTION_PF;
        pf_function.state = VF_ACTIVE;
        pf_function.transport = transport;
        transport.bdf = 16'h0030;
        pf_function.vq_mgr.mem = mem;
        pf_function.vq_mgr.iommu = iommu;
        pf_function.vq_mgr.barrier = barrier;
        pf_function.vq_mgr.err_inj = err_inj;
        pf_function.vq_mgr.wait_pol = wait_pol;
        pf_function.vq_mgr.bdf = transport.bdf;
        pf_function.vq_mgr.create_queue(0, cfg.queue_size, VQ_SPLIT).alloc_rings();
        pf_function.vq_mgr.create_queue(1, cfg.queue_size, VQ_SPLIT).alloc_rings();
        ops.transport = transport;
        ops.vq_mgr = pf_function.vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.state = FSM_READY;
        pf_function.driver_agent.ops = ops;
        pf_function.driver_agent.fsm = fsm;
        reset_owner.pf_function = pf_function;
        reset_complete = 0;
        reset_returned = 0;

        fsm.start_dataplane();
        ops.worker_entered.wait_trigger();
        assert(ops.worker_active)
            else `uvm_fatal("PF_LIFECYCLE", "real dataplane worker did not enter its shared operation")

        fork
            begin
                reset_owner.reset_pf_lifecycle(reset_complete);
                reset_returned = 1;
            end
        join_none

        // The legacy stop implementation waited exactly two 10ns intervals.
        // By 25ns it has incorrectly reset the PF while the worker is still
        // blocked.  A definitive quiesce must instead hold the reset caller.
        #(25ns);
        assert(ops.worker_active && !reset_returned &&
               transport.device_reset_count == 0)
            else `uvm_fatal("PF_LIFECYCLE",
                "PF reset ran before the real dataplane worker had exited")

        ops.release_worker.trigger();
        wait (reset_returned);

        assert(reset_complete && !ops.worker_active &&
               transport.device_reset_count == 1 &&
               pf_function.get_state() == VF_REINIT_REQUIRED &&
               fsm.state == FSM_REINIT_REQUIRED)
            else `uvm_fatal("PF_LIFECYCLE",
                "PF reset did not resume only after real dataplane quiesce")

        pf_function.vq_mgr.destroy_all();
    endtask

    task test_verified_reset_quiesces_and_requires_reinitialization();
        virtio_pf_lifecycle_reset_owner  reset_owner;
        virtio_pf_lifecycle_test_transport transport;
        virtio_pf_lifecycle_test_fsm    fsm;
        virtio_atomic_ops                ops;
        virtio_iommu_model               iommu;
        bit                              reset_complete;

        transport = virtio_pf_lifecycle_test_transport::type_id::create(
            "verified_reset_transport");
        fsm = virtio_pf_lifecycle_test_fsm::type_id::create("verified_reset_fsm");
        ops = virtio_atomic_ops::type_id::create("verified_reset_ops");
        iommu = virtio_iommu_model::type_id::create("verified_reset_iommu");
        reset_owner = virtio_pf_lifecycle_reset_owner::type_id::create(
            "verified_reset_owner");

        pf_function.function_kind = DPU_FUNCTION_PF;
        pf_function.state = VF_ACTIVE;
        pf_function.transport = transport;
        ops.transport = transport;
        ops.vq_mgr = pf_function.vq_mgr;
        ops.iommu = iommu;
        ops.negotiated_features = 64'h0000_0300_0000_0000;
        fsm.ops = ops;
        fsm.state = FSM_RUNNING;
        pf_function.driver_agent.ops = ops;
        pf_function.driver_agent.fsm = fsm;
        reset_owner.pf_function = pf_function;

        reset_owner.reset_pf_lifecycle(reset_complete);

        assert(reset_complete && transport.device_reset_count == 1 &&
               fsm.stop_count == 1 &&
               pf_function.get_state() == VF_REINIT_REQUIRED &&
               fsm.state == FSM_REINIT_REQUIRED &&
               ops.negotiated_features == '0)
            else `uvm_fatal("PF_LIFECYCLE",
                "verified PF reset did not quiesce runtime and require reinitialization")
    endtask

    // A verified PF reset is the sole point at which outstanding normal TX
    // and RX DMA becomes safe to retire.  Exercise the public submit/refill
    // paths so the regression covers both IOMMU mappings and host allocations
    // rather than inspecting internal bookkeeping alone.
    task test_verified_reset_retires_pending_normal_dma();
        virtio_pf_lifecycle_reset_owner   reset_owner;
        virtio_pf_lifecycle_test_transport transport;
        virtio_pf_lifecycle_test_fsm       fsm;
        virtio_atomic_ops                   ops;
        virtio_pf_lifecycle_tracking_mem    mem;
        virtio_pf_lifecycle_tracking_iommu  iommu;
        virtio_memory_barrier_model         barrier;
        virtqueue_error_injector            err_inj;
        virtio_wait_policy                  wait_pol;
        virtqueue_base                      rx_vq;
        virtqueue_base                      tx_vq;
        virtio_net_hdr_t                    hdr;
        virtio_pf_lifecycle_test_packet     pkt;
        int unsigned                        desc_id;
        int unsigned                        allocation_baseline;
        int unsigned                        ring_allocation_count;
        bit                                 reset_complete;

        transport = virtio_pf_lifecycle_test_transport::type_id::create(
            "pending_dma_reset_transport");
        fsm = virtio_pf_lifecycle_test_fsm::type_id::create(
            "pending_dma_reset_fsm");
        ops = virtio_atomic_ops::type_id::create("pending_dma_reset_ops");
        mem = virtio_pf_lifecycle_tracking_mem::type_id::create(
            "pending_dma_reset_mem");
        iommu = virtio_pf_lifecycle_tracking_iommu::type_id::create(
            "pending_dma_reset_iommu");
        barrier = virtio_memory_barrier_model::type_id::create(
            "pending_dma_reset_barrier");
        err_inj = virtqueue_error_injector::type_id::create(
            "pending_dma_reset_err_inj");
        wait_pol = virtio_wait_policy::type_id::create(
            "pending_dma_reset_wait_pol");
        reset_owner = virtio_pf_lifecycle_reset_owner::type_id::create(
            "pending_dma_reset_owner");

        mem.init_region(64'h6000_0000, 64'h600F_FFFF);
        allocation_baseline = mem.outstanding_allocations();
        transport.bdf = 16'h0020;
        pf_function.function_kind = DPU_FUNCTION_PF;
        pf_function.state = VF_ACTIVE;
        pf_function.transport = transport;
        pf_function.vq_mgr.mem = mem;
        pf_function.vq_mgr.iommu = iommu;
        pf_function.vq_mgr.barrier = barrier;
        pf_function.vq_mgr.err_inj = err_inj;
        pf_function.vq_mgr.wait_pol = wait_pol;
        pf_function.vq_mgr.bdf = transport.bdf;

        rx_vq = pf_function.vq_mgr.create_queue(0, 8, VQ_SPLIT);
        tx_vq = pf_function.vq_mgr.create_queue(1, 8, VQ_SPLIT);
        assert((rx_vq != null) && (tx_vq != null))
            else `uvm_fatal("PF_LIFECYCLE", "failed to create pending-DMA test queues")
        rx_vq.alloc_rings();
        tx_vq.alloc_rings();
        ring_allocation_count = mem.outstanding_allocations();

        ops.transport = transport;
        ops.vq_mgr = pf_function.vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        fsm.ops = ops;
        fsm.state = FSM_RUNNING;
        pf_function.driver_agent.ops = ops;
        pf_function.driver_agent.fsm = fsm;
        reset_owner.pf_function = pf_function;

        hdr.flags = 0;
        hdr.gso_type = VIRTIO_NET_HDR_GSO_NONE;
        hdr.hdr_len = 0;
        hdr.gso_size = 0;
        hdr.csum_start = 0;
        hdr.csum_offset = 0;
        hdr.num_buffers = 0;
        hdr.hash_value = 0;
        hdr.hash_report = 0;
        pkt = virtio_pf_lifecycle_test_packet::type_id::create(
            "pending_dma_tx_packet");
        ops.rx_refill(0, 1);
        ops.tx_submit(1, hdr, pkt, 0, desc_id);

        assert(desc_id != '1 && iommu.active_mapping_count() == 3 &&
               mem.outstanding_allocations() == ring_allocation_count + 3)
            else `uvm_fatal("PF_LIFECYCLE",
                "pending normal TX/RX DMA was not established for reset regression")

        reset_owner.reset_pf_lifecycle(reset_complete);

        assert(reset_complete && iommu.active_mapping_count() == 0 &&
               iommu.total_maps == 3 && iommu.total_unmaps == 3 &&
               mem.outstanding_allocations() == allocation_baseline &&
               pf_function.vq_mgr.get_queue_count() == 0)
            else `uvm_fatal("PF_LIFECYCLE",
                "verified reset did not retire normal DMA, free rings, and destroy queues")
    endtask

    // Allocate exactly one minimum-sized header block, then force the packet
    // allocation to fail.  The TX submission must roll back that header
    // allocation without attempting any DMA map or queue notification.
    task test_tx_second_allocation_failure_releases_header();
        virtio_pf_lifecycle_test_transport  transport;
        virtio_atomic_ops                    ops;
        virtqueue_manager                    vq_mgr;
        virtio_pf_lifecycle_tracking_mem     mem;
        virtio_pf_lifecycle_tracking_iommu   iommu;
        virtio_memory_barrier_model          barrier;
        virtqueue_error_injector             err_inj;
        virtio_wait_policy                   wait_pol;
        virtio_net_hdr_t                     hdr;
        virtio_pf_lifecycle_test_packet      pkt;
        virtio_pf_lifecycle_tx_alloc_error_catcher catcher;
        int unsigned                         desc_id;
        int unsigned                         allocation_baseline;

        transport = virtio_pf_lifecycle_test_transport::type_id::create(
            "tx_second_alloc_fail_transport");
        ops = virtio_atomic_ops::type_id::create("tx_second_alloc_fail_ops");
        vq_mgr = virtqueue_manager::type_id::create("tx_second_alloc_fail_vq_mgr");
        mem = virtio_pf_lifecycle_tracking_mem::type_id::create(
            "tx_second_alloc_fail_mem");
        iommu = virtio_pf_lifecycle_tracking_iommu::type_id::create(
            "tx_second_alloc_fail_iommu");
        barrier = virtio_memory_barrier_model::type_id::create(
            "tx_second_alloc_fail_barrier");
        err_inj = virtqueue_error_injector::type_id::create(
            "tx_second_alloc_fail_err_inj");
        wait_pol = virtio_wait_policy::type_id::create(
            "tx_second_alloc_fail_wait_pol");

        // The basic 10-byte virtio header rounds to this manager's 16-byte
        // minimum block.  No space remains for the minimum 64-byte packet.
        mem.init_region(64'h6200_0000, 64'h6200_000F);
        allocation_baseline = mem.outstanding_allocations();
        transport.bdf = 16'h0040;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = transport.bdf;
        assert(vq_mgr.create_queue(0, 8, VQ_SPLIT) != null)
            else `uvm_fatal("PF_LIFECYCLE", "failed to create TX allocation rollback queue")
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        hdr = '{default: 0};
        pkt = virtio_pf_lifecycle_test_packet::type_id::create(
            "tx_second_alloc_fail_packet");

        catcher = new("tx_second_alloc_fail_catcher");
        uvm_report_cb::add(null, catcher);
        ops.tx_submit(0, hdr, pkt, 0, desc_id);
        uvm_report_cb::delete(null, catcher);

        assert(desc_id == '1 && catcher.caught_count == 2 &&
               mem.outstanding_allocations() == allocation_baseline &&
               iommu.active_mapping_count() == 0 && transport.kick_count == 0)
            else `uvm_fatal("PF_LIFECYCLE",
                "TX second-allocation failure leaked the header or submitted DMA work")
    endtask

    task test_failed_reset_retains_pf_runtime();
        virtio_pf_lifecycle_reset_owner          reset_owner;
        virtio_pf_lifecycle_test_transport       transport;
        virtio_pf_lifecycle_test_fsm             fsm;
        virtio_atomic_ops                        ops;
        virtio_iommu_model                       iommu;
        virtio_pf_lifecycle_expected_error_catcher catcher;
        bit                                      reset_complete;
        bit [63:0]                               features_before;

        transport = virtio_pf_lifecycle_test_transport::type_id::create(
            "failed_reset_transport");
        transport.device_reset_complete = 0;
        fsm = virtio_pf_lifecycle_test_fsm::type_id::create("failed_reset_fsm");
        ops = virtio_atomic_ops::type_id::create("failed_reset_ops");
        iommu = virtio_iommu_model::type_id::create("failed_reset_iommu");
        reset_owner = virtio_pf_lifecycle_reset_owner::type_id::create(
            "failed_reset_owner");

        pf_function.function_kind = DPU_FUNCTION_PF;
        pf_function.state = VF_ACTIVE;
        pf_function.transport = transport;
        ops.transport = transport;
        ops.vq_mgr = pf_function.vq_mgr;
        ops.iommu = iommu;
        features_before = 64'h0000_0060_0000_0000;
        ops.negotiated_features = features_before;
        fsm.ops = ops;
        fsm.state = FSM_RUNNING;
        pf_function.driver_agent.ops = ops;
        pf_function.driver_agent.fsm = fsm;
        reset_owner.pf_function = pf_function;

        catcher = new("failed_reset_catcher");
        uvm_report_cb::add(null, catcher);
        reset_owner.reset_pf_lifecycle(reset_complete);
        uvm_report_cb::delete(null, catcher);

        assert(!reset_complete && transport.device_reset_count == 1 &&
               fsm.stop_count == 1 && catcher.caught_count == 1 &&
               pf_function.get_state() == VF_RESET_FAILED &&
               fsm.state == FSM_ERROR &&
               ops.negotiated_features == features_before)
            else `uvm_fatal("PF_LIFECYCLE",
                "failed PF reset released runtime state or reported lifecycle success")
    endtask

    task test_set_active_rejects_reinit_required();
        virtio_pf_lifecycle_set_active_error_catcher catcher;

        catcher = new("reinit_required_set_active_catcher");
        pf_function.state = VF_REINIT_REQUIRED;
        uvm_report_cb::add(null, catcher);
        pf_function.set_active();
        uvm_report_cb::delete(null, catcher);

        assert(catcher.caught_count == 1 &&
               pf_function.get_state() == VF_REINIT_REQUIRED)
            else `uvm_fatal("PF_LIFECYCLE",
                "set_active bypassed the PF reinitialization requirement")
    endtask

    task test_set_active_rejects_reset_failed();
        virtio_pf_lifecycle_set_active_error_catcher catcher;

        catcher = new("reset_failed_set_active_catcher");
        pf_function.state = VF_RESET_FAILED;
        uvm_report_cb::add(null, catcher);
        pf_function.set_active();
        uvm_report_cb::delete(null, catcher);

        assert(catcher.caught_count == 1 &&
               pf_function.get_state() == VF_RESET_FAILED)
            else `uvm_fatal("PF_LIFECYCLE",
                "set_active bypassed the failed PF reset state")
    endtask
endclass : virtio_pf_lifecycle_reset_test

`endif // VIRTIO_PF_LIFECYCLE_RESET_TEST_SV
