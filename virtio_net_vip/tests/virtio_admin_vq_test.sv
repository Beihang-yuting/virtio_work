`ifndef VIRTIO_ADMIN_VQ_TEST_SV
`define VIRTIO_ADMIN_VQ_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

// This transport keeps the Admin VQ test in-process: it records the notify
// while exposing a controlled device status through the public transport API.
class virtio_admin_vq_test_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_admin_vq_test_transport)

    int unsigned kick_count;
    int unsigned reset_count;
    int unsigned device_reset_count;
    int unsigned last_reset_queue_id;
    bit [7:0]    mock_status;
    bit          queue_reset_complete;
    bit          device_reset_complete;
    uvm_event    kick_event;

    function new(string name = "virtio_admin_vq_test_transport");
        super.new(name);
        kick_count = 0;
        reset_count = 0;
        device_reset_count = 0;
        last_reset_queue_id = '1;
        mock_status = DEV_STATUS_DRIVER_OK;
        queue_reset_complete = 1;
        device_reset_complete = 1;
        kick_event = new("admin_vq_kick_event");
    endfunction

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
        kick_count++;
        kick_event.trigger();
    endtask

    virtual task read_device_status(ref bit [7:0] status);
        status = mock_status;
    endtask

    virtual task write_queue_reset(int unsigned queue_id);
        reset_count++;
        last_reset_queue_id = queue_id;
    endtask

    virtual task write_queue_reset_verified(int unsigned queue_id,
                                            ref bit reset_complete);
        reset_count++;
        last_reset_queue_id = queue_id;
        reset_complete = queue_reset_complete;
    endtask

    virtual task reset_device();
        device_reset_count++;
    endtask

    virtual task reset_device_verified(ref bit reset_complete);
        device_reset_count++;
        reset_complete = device_reset_complete;
    endtask
endclass : virtio_admin_vq_test_transport

// The production IOMMU normally always allocates an IOVA. This test double
// makes a selected allocation fail so Admin-VQ cleanup is exercised at the
// same map-return boundary as the virtqueue indirect-table path.
class virtio_admin_vq_test_iommu extends virtio_iommu_model;
    `uvm_object_utils(virtio_admin_vq_test_iommu)

    int unsigned map_attempts;
    int unsigned fail_on_map_attempt;
    virtio_admin_vq_test_transport transport_for_unmap;
    bit observe_unmap_order;
    bit saw_unmap;
    bit queue_reset_requested_before_first_unmap;
    bit device_reset_requested_before_first_unmap;

    function new(string name = "virtio_admin_vq_test_iommu");
        super.new(name);
        map_attempts = 0;
        fail_on_map_attempt = 0;
        observe_unmap_order = 0;
        saw_unmap = 0;
        queue_reset_requested_before_first_unmap = 0;
        device_reset_requested_before_first_unmap = 0;
    endfunction

    function bit [63:0] map(bit [15:0] bdf,
                             bit [63:0] gpa,
                             int unsigned size,
                             dma_dir_e dir,
                             string file = "",
                             int line = 0);
        map_attempts++;
        if (fail_on_map_attempt != 0 && map_attempts == fail_on_map_attempt)
            return '1;
        return super.map(bdf, gpa, size, dir, file, line);
    endfunction

    function void unmap(bit [15:0] bdf,
                        bit [63:0] iova,
                        string file = "",
                        int line = 0);
        if (observe_unmap_order && !saw_unmap) begin
            saw_unmap = 1;
            queue_reset_requested_before_first_unmap =
                (transport_for_unmap != null && transport_for_unmap.reset_count != 0);
            device_reset_requested_before_first_unmap =
                (transport_for_unmap != null && transport_for_unmap.device_reset_count != 0);
        end
        super.unmap(bdf, iova, file, line);
    endfunction
endclass : virtio_admin_vq_test_iommu

// A full device reset is owned by the PF lifecycle, not by Admin-VQ cleanup.
// The mock records that it invalidated normal PF state before reporting reset
// completion to the Admin command path.
class virtio_admin_vq_test_reset_owner extends virtio_admin_full_reset_owner;
    `uvm_object_utils(virtio_admin_vq_test_reset_owner)

    virtio_admin_vq_test_transport transport;
    int unsigned reset_count;
    bit reset_succeeds;
    bit normal_pf_state_invalidated;

    function new(string name = "virtio_admin_vq_test_reset_owner");
        super.new(name);
        reset_count = 0;
        reset_succeeds = 1;
        normal_pf_state_invalidated = 0;
    endfunction

    virtual task reset_pf_lifecycle(ref bit reset_complete);
        bit transport_reset_complete;

        reset_count++;
        reset_complete = 0;
        if (transport != null) begin
            transport.reset_device_verified(transport_reset_complete);
            reset_complete = reset_succeeds && transport_reset_complete;
        end else begin
            reset_complete = reset_succeeds;
        end
        if (reset_complete)
            normal_pf_state_invalidated = 1;
    endtask
endclass : virtio_admin_vq_test_reset_owner

// Admin command failures are intentional in the negative cases below.  Catch
// only the lifecycle diagnostics the test explicitly expects, so unrelated
// reports remain visible to the UVM test result.
class virtio_admin_vq_expected_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;
    string       expected_ids[$];
    string       expected_message_fragments[$];

    function new(string name,
                 string ids[$],
                 string message_fragments[$]);
        super.new(name);
        caught_count = 0;
        expected_ids = ids;
        expected_message_fragments = message_fragments;
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR) begin
            foreach (expected_ids[index]) begin
                if ((get_id() == expected_ids[index]) &&
                    uvm_is_match({"*", expected_message_fragments[index], "*"},
                                 get_message())) begin
                    caught_count++;
                    return CAUGHT;
                end
            end
        end
        return THROW;
    endfunction
endclass : virtio_admin_vq_expected_error_catcher

class virtio_admin_vq_test extends uvm_test;
    `uvm_component_utils(virtio_admin_vq_test)

    dpu_device_env             device_env;
    virtio_test_device_builder device_builder;
    dpu_device_env_config      device_cfg;
    virtio_net_env_config      cfg;
    virtio_net_env             env;
    virtio_vf_instance         vf;
    virtio_pf_manager          pf_mgr;
    virtio_admin_vq_test_reset_owner last_reset_owner;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_function_cfg pf_cfg;
        dpu_function_cfg vf_cfg;

        super.build_phase(phase);
        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        void'(device_builder.add_host_domain(0, 0));
        pf_cfg = device_builder.add_pf(0, 0, 0);
        vf_cfg = device_builder.add_vf(0, 0, 0, 0);
        device_builder.add_real_dut_bars(pf_cfg);
        device_builder.add_real_dut_bars(vf_cfg);
        void'(device_builder.add_vio_service(pf_cfg, 0));
        void'(device_builder.add_vio_service(vf_cfg, 0));
        device_builder.select_af(pf_cfg);
        device_cfg = device_builder.make_env_config();

        cfg = virtio_net_env_config::type_id::create("cfg");
        cfg.scb_enable = 0;
        cfg.cov_enable = 0;
        // The snapshot VF is only an Admin-command target.  Keep both
        // declared function agents passive; this unit test supplies its own
        // controlled Admin transport rather than a PCIe environment.
        uvm_config_db#(uvm_active_passive_enum)::set(
            this,
            "device_env.env.pf_0_0.pf_function.driver_agent",
            "is_active", UVM_PASSIVE);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this,
            "device_env.env.pf_0_0.vf_function_0.driver_agent",
            "is_active", UVM_PASSIVE);
        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "device_env.env", "cfg", cfg);
        env = virtio_net_env::type_id::create("env", device_env);
        pf_mgr = virtio_pf_manager::type_id::create("admin_pf_mgr");
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        vf = env.pf_instances[0].vf_functions[0];

        test_success_completion_and_cleanup();
        test_admin_transport_mismatch_has_no_submission();
        test_configure_rejects_inconsistent_admin_context();
        test_direct_submit_rechecks_admin_context_bindings();
        test_admin_context_binding_mismatches_have_no_submission();
        test_recovery_rechecks_admin_context_bindings();
        test_concurrent_admin_commands_are_serialized();
        test_queued_command_revalidates_target_state();
        test_saturated_timeout_polls_until_completion();
        test_inactive_target_has_no_submission();
        test_feature_absent_has_no_submission();
        test_missing_full_reset_owner_has_no_submission();
        test_missing_special_vq_lease_has_no_submission();
        test_frozen_special_vq_lease_has_no_submission();
        test_missing_configuration_has_no_submission();
        test_failed_device_has_no_submission();
        test_device_needs_reset_has_no_submission();
        test_device_error_completion_cleans_up();
        test_submission_failure_cleans_up();
        test_response_map_failure_cleans_up_request_resources();
        test_timeout_without_ring_reset_uses_device_reset();
        test_malformed_completion_without_ring_reset_uses_device_reset();
        test_timeout_with_ring_reset_uses_queue_reset();
        test_verified_recovery_releases_quarantined_dma();
        test_failed_recovery_retains_quarantined_dma();
        test_unconfirmed_queue_reset_quarantines_dma();

        `uvm_info("ADMIN_VQ", "All Admin VQ lifecycle tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    function void read_split_desc(host_mem_manager mem,
                                  split_virtqueue vq,
                                  int unsigned index,
                                  ref bit [63:0] addr,
                                  ref bit [31:0] len,
                                  ref bit [15:0] flags,
                                  ref bit [15:0] next);
        byte data[];

        mem.read_mem(vq.desc_table_addr + index * 16, 16, data);
        addr  = {data[7], data[6], data[5], data[4],
                 data[3], data[2], data[1], data[0]};
        len   = {data[11], data[10], data[9], data[8]};
        flags = {data[13], data[12]};
        next  = {data[15], data[14]};
    endfunction

    function void complete_split(host_mem_manager mem,
                                 split_virtqueue vq,
                                 int unsigned head,
                                 int unsigned used_len);
        complete_split_at(mem, vq, 0, head, used_len);
    endfunction

    function void complete_split_at(host_mem_manager mem,
                                    split_virtqueue vq,
                                    int unsigned used_slot,
                                    int unsigned head,
                                    int unsigned used_len);
        byte used_entry[];
        byte used_idx[];
        int unsigned next_used_idx;

        used_entry = new[8];
        for (int unsigned i = 0; i < 4; i++) begin
            used_entry[i] = head[i * 8 +: 8];
            used_entry[i + 4] = used_len[i * 8 +: 8];
        end
        used_idx = new[2];
        next_used_idx = used_slot + 1;
        used_idx[0] = next_used_idx[7:0];
        used_idx[1] = 8'h00;
        mem.write_mem(vq.device_ring_addr + 4 + used_slot * 8, used_entry);
        mem.write_mem(vq.device_ring_addr + 2, used_idx);
    endfunction

    task complete_admin_response(
        host_mem_manager       mem,
        virtio_iommu_model     iommu,
        split_virtqueue        vq,
        int unsigned           expected_command,
        int unsigned           response_byte,
        int unsigned           used_slot
    );
        bit [63:0] out_addr;
        bit [63:0] in_addr;
        bit [63:0] request_gpa;
        bit [31:0] out_len;
        bit [31:0] in_len;
        bit [15:0] out_flags;
        bit [15:0] in_flags;
        bit [15:0] out_next;
        bit [15:0] in_next;
        int unsigned head;
        bit found_chain;
        iommu_fault_e fault;
        byte request_data[];
        byte device_response[];

        found_chain = 0;
        for (int unsigned desc_index = 0;
             desc_index < vq.queue_size && !found_chain;
             desc_index++) begin
            read_split_desc(mem, vq, desc_index,
                            out_addr, out_len, out_flags, out_next);
            if ((out_flags & VIRTQ_DESC_F_NEXT) && out_next < vq.queue_size) begin
                read_split_desc(mem, vq, out_next,
                                in_addr, in_len, in_flags, in_next);
                if (in_flags & VIRTQ_DESC_F_WRITE) begin
                    head = desc_index;
                    found_chain = 1;
                end
            end
        end
        assert(found_chain)
            else `uvm_fatal("ADMIN_VQ", "concurrent Admin command has no OUT plus IN descriptor chain")
        assert(iommu.translate(vq.bdf, out_addr, out_len, DMA_TO_DEVICE,
                               request_gpa, fault))
            else `uvm_fatal("ADMIN_VQ", "concurrent Admin request descriptor is not DMA mapped")
        mem.read_mem(request_gpa, out_len, request_data);
        assert(request_data.size() == 1 && request_data[0] == expected_command)
            else `uvm_fatal("ADMIN_VQ", "concurrent Admin request reached the wrong completion")
        device_response = '{VIRTIO_NET_OK, response_byte[7:0]};
        assert(iommu.write_from_device(mem, vq.bdf, in_addr,
                                       device_response, fault))
            else `uvm_fatal("ADMIN_VQ", "concurrent Admin response DMA write failed")
        complete_split_at(mem, vq, used_slot, head, device_response.size());
    endtask

    // This is the only test setup path.  It creates a queue independent of
    // the normal PF/VF queue managers and injects a caller/Fabric-owned
    // special-VQ lease into the PF manager's Admin-VQ context.
    task configure_admin_context(
        ref virtio_admin_vq_context      ctx,
        ref host_mem_manager              mem,
        ref virtio_iommu_model            iommu,
        ref virtio_admin_vq_test_transport transport,
        ref split_virtqueue               vq
    );
        virtio_memory_barrier_model barrier;
        virtqueue_error_injector    err_inj;
        virtio_wait_policy          wait_pol;

        mem = host_mem_manager::type_id::create("admin_mem");
        iommu = virtio_admin_vq_test_iommu::type_id::create("admin_iommu");
        barrier = virtio_memory_barrier_model::type_id::create("admin_barrier");
        err_inj = virtqueue_error_injector::type_id::create("admin_err_inj");
        wait_pol = virtio_wait_policy::type_id::create("admin_wait_pol");
        transport = virtio_admin_vq_test_transport::type_id::create("admin_transport");
        vq = split_virtqueue::type_id::create("admin_split_vq");

        mem.init_region(64'h7100_0000, 64'h7103_FFFF);
        wait_pol.default_poll_interval_ns = 1;
        wait_pol.default_timeout_ns = 8;
        wait_pol.max_poll_attempts = 16;
        transport.bdf = 16'h0708;
        vq.setup(7, 8, mem, iommu, barrier, err_inj, wait_pol, 16'h0708);
        vq.alloc_rings();

        ctx = virtio_admin_vq_context::type_id::create("admin_vq_context");
        ctx.transport = transport;
        ctx.vq = vq;
        ctx.mem = mem;
        ctx.iommu = iommu;
        ctx.wait_pol = wait_pol;
        ctx.queue_id = 7;
        ctx.response_capacity = 16;
        ctx.negotiated_features = '0;
        ctx.negotiated_features[VIRTIO_F_ADMIN_VQ] = 1'b1;
        ctx.configured = 1;
        ctx.special_vq_lease_valid = 1;
        ctx.special_vq_lease.owner.kind = DPU_FUNCTION_PF;
        ctx.special_vq_lease.class_id = 91;
        ctx.special_vq_lease.local_id = 0;
        ctx.special_vq_lease.global_id = 4;
        ctx.special_vq_lease.frozen = 0;
        last_reset_owner = virtio_admin_vq_test_reset_owner::type_id::create(
            "admin_pf_reset_owner"
        );
        last_reset_owner.transport = transport;
        ctx.full_reset_owner = last_reset_owner;

        pf_mgr.vf_instances = new[1];
        pf_mgr.vf_instances[0] = vf;
        pf_mgr.active_vf_count = 1;
        pf_mgr.pf_transport = transport;
        vf.state = VF_ACTIVE;
        pf_mgr.configure_admin_vq(ctx);
    endtask

    task finish_context(split_virtqueue vq);
        if (vq != null && vq.desc_table_addr != 0)
            vq.free_rings();
        pf_mgr.clear_admin_vq();
    endtask

    task assert_no_submission(string scenario,
                              virtio_admin_vq_test_transport transport,
                              split_virtqueue vq,
                              virtio_iommu_model iommu,
                              int unsigned add_before);
        assert(transport.kick_count == 0 &&
               vq.total_add_buf_ops == add_before &&
               vq.get_free_count() == 8 &&
               iommu.total_maps == 0 && iommu.total_unmaps == 0)
            else `uvm_fatal("ADMIN_VQ", $sformatf(
                "%s had queue, DMA, or notification side effects", scenario))
    endtask

    task test_success_completion_and_cleanup();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        request = '{8'h10, 8'h20, 8'h30};

        fork : admin_success_completion
            begin
                bit [63:0] out_addr;
                bit [63:0] in_addr;
                bit [63:0] response_gpa;
                bit [31:0] out_len;
                bit [31:0] in_len;
                bit [15:0] out_flags;
                bit [15:0] in_flags;
                bit [15:0] out_next;
                bit [15:0] in_next;
                iommu_fault_e fault;
                byte expected_request[];
                byte device_response[];

                // The completion fork can begin after kick() has returned in
                // the same simulation time slot.  Use the recorded notify as
                // a level condition, rather than an edge-triggered event,
                // so the mock cannot miss that kick.
                wait (transport.kick_count != 0);
                read_split_desc(mem, vq, 0, out_addr, out_len, out_flags, out_next);
                read_split_desc(mem, vq, 1, in_addr, in_len, in_flags, in_next);
                assert(out_len == request.size() &&
                       out_flags == VIRTQ_DESC_F_NEXT && out_next == 1 &&
                       in_len == ctx.response_capacity &&
                       in_flags == VIRTQ_DESC_F_WRITE && in_next == 0)
                    else `uvm_fatal("ADMIN_VQ", "Admin VQ did not build one OUT plus one IN chain")
                assert(iommu.translate(vq.bdf, out_addr, out_len, DMA_TO_DEVICE,
                                       response_gpa, fault))
                    else `uvm_fatal("ADMIN_VQ", "Admin request descriptor is not DMA mapped")
                mem.read_mem(response_gpa, out_len, expected_request);
                foreach (request[i])
                    assert(expected_request[i] == request[i])
                        else `uvm_fatal("ADMIN_VQ", "Admin request payload was not preserved")
                device_response = '{VIRTIO_NET_OK, 8'hA5, 8'h5A};
                assert(iommu.write_from_device(mem, vq.bdf, in_addr,
                                               device_response, fault))
                    else `uvm_fatal("ADMIN_VQ", "Admin response DMA write failed")
                complete_split(mem, vq, 0, device_response.size());
            end
        join_none

        pf_mgr.admin_cmd(0, request, response, ok);
        disable admin_success_completion;

        assert(ok && response.size() == 2 &&
               response[0] == 8'hA5 && response[1] == 8'h5A &&
               transport.kick_count == 1 && vq.get_free_count() == 8 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "successful Admin VQ completion was not decoded or cleaned up")
        finish_context(vq);
    endtask

    // Full-PF recovery is safe only when the Admin VQ and lifecycle owner
    // address the same transport.  A stale/wrong PF transport must be
    // rejected before it can allocate, map, describe, or notify work.
    task test_admin_transport_mismatch_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        virtio_admin_vq_test_transport wrong_transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        wrong_transport = virtio_admin_vq_test_transport::type_id::create(
            "wrong_admin_pf_transport"
        );
        wrong_transport.bdf = 16'h0808;
        pf_mgr.pf_transport = wrong_transport;
        request = '{8'h36};
        catcher = new("admin_transport_mismatch_catcher", '{"PF_MGR"},
                      '{"admin_cmd: Admin VQ transport does not match PF transport"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);

        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "mismatched Admin transport was not explicitly rejected")
        assert_no_submission("mismatched Admin transport", transport, vq, iommu, 0);
        pf_mgr.pf_transport = transport;
        finish_context(vq);
    endtask

    task test_configure_rejects_inconsistent_admin_context();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        pf_mgr.clear_admin_vq();
        ctx.queue_id = vq.queue_id + 1;
        catcher = new("configure_context_binding_catcher", '{"PF_MGR"},
                      '{"configure_admin_vq: Admin VQ binding is inconsistent"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.configure_admin_vq(ctx);
        uvm_report_cb::delete(null, catcher);

        assert(catcher.caught_count == 1 && pf_mgr.admin_vq != ctx &&
               transport.kick_count == 0 && vq.total_add_buf_ops == 0 &&
               iommu.total_maps == 0 && iommu.total_unmaps == 0)
            else `uvm_fatal("ADMIN_VQ",
                "configure_admin_vq accepted inconsistent Admin VQ bindings")
        ctx.queue_id = vq.queue_id;
        finish_context(vq);
    endtask

    // admin_vq_submit() is public and can be called without the PF manager.
    // It must therefore validate the VQ-owned queue/requester/DMA bindings
    // again after taking the context submission lock, before it allocates,
    // maps, describes, notifies, or initiates reset work.
    task test_direct_submit_rechecks_admin_context_bindings();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        host_mem_manager               foreign_mem;
        virtio_iommu_model             iommu;
        virtio_iommu_model             foreign_iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        virtio_atomic_ops              ops;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;
        int unsigned                   original_queue_id;
        bit [15:0]                     original_bdf;

        for (int unsigned mismatch = 0; mismatch < 4; mismatch++) begin
            configure_admin_context(ctx, mem, iommu, transport, vq);
            ops = virtio_atomic_ops::type_id::create(
                $sformatf("direct_binding_ops_%0d", mismatch)
            );
            request = '{8'h65 + mismatch};
            original_queue_id = ctx.queue_id;
            original_bdf = vq.bdf;
            foreign_mem = null;
            foreign_iommu = null;
            case (mismatch)
                0: ctx.queue_id = vq.queue_id + 1;
                1: vq.bdf = transport.bdf + 1;
                2: begin
                    foreign_mem = host_mem_manager::type_id::create(
                        "direct_foreign_admin_vq_mem"
                    );
                    foreign_mem.init_region(64'h7300_0000, 64'h7303_FFFF);
                    vq.mem = foreign_mem;
                end
                default: begin
                    foreign_iommu = virtio_iommu_model::type_id::create(
                        "direct_foreign_admin_vq_iommu"
                    );
                    vq.iommu = foreign_iommu;
                end
            endcase

            catcher = new($sformatf("direct_binding_catcher_%0d", mismatch),
                          '{"ATOMIC_OPS"},
                          '{"admin_vq_submit: Admin VQ binding is inconsistent"});
            uvm_report_cb::add(null, catcher);
            ops.admin_vq_submit(ctx, request, response, ok);
            uvm_report_cb::delete(null, catcher);

            assert(!ok && catcher.caught_count == 1)
                else `uvm_fatal("ADMIN_VQ", $sformatf(
                    "Direct Admin VQ submit accepted binding mismatch %0d", mismatch))
            assert_no_submission($sformatf("direct Admin VQ binding mismatch %0d", mismatch),
                                 transport, vq, iommu, 0);

            ctx.queue_id = original_queue_id;
            vq.bdf = original_bdf;
            vq.mem = mem;
            vq.iommu = iommu;
            finish_context(vq);
        end
    endtask

    task test_admin_context_binding_mismatches_have_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        host_mem_manager               foreign_mem;
        virtio_iommu_model             iommu;
        virtio_iommu_model             foreign_iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;
        int unsigned                   original_queue_id;
        bit [15:0]                     original_bdf;

        for (int unsigned mismatch = 0; mismatch < 4; mismatch++) begin
            configure_admin_context(ctx, mem, iommu, transport, vq);
            request = '{8'h61 + mismatch};
            original_queue_id = ctx.queue_id;
            original_bdf = vq.bdf;
            foreign_mem = null;
            foreign_iommu = null;
            case (mismatch)
                0: ctx.queue_id = vq.queue_id + 1;
                1: vq.bdf = transport.bdf + 1;
                2: begin
                    foreign_mem = host_mem_manager::type_id::create(
                        "foreign_admin_vq_mem"
                    );
                    foreign_mem.init_region(64'h7200_0000, 64'h7203_FFFF);
                    vq.mem = foreign_mem;
                end
                default: begin
                    foreign_iommu = virtio_iommu_model::type_id::create(
                        "foreign_admin_vq_iommu"
                    );
                    vq.iommu = foreign_iommu;
                end
            endcase

            catcher = new($sformatf("admin_context_binding_catcher_%0d", mismatch),
                          '{"PF_MGR"},
                          '{"admin_cmd: Admin VQ binding is inconsistent"});
            uvm_report_cb::add(null, catcher);
            pf_mgr.admin_cmd(0, request, response, ok);
            uvm_report_cb::delete(null, catcher);

            assert(!ok && catcher.caught_count == 1)
                else `uvm_fatal("ADMIN_VQ", $sformatf(
                    "Admin VQ binding mismatch %0d was not explicitly rejected", mismatch))
            assert_no_submission($sformatf("Admin VQ binding mismatch %0d", mismatch),
                                 transport, vq, iommu, 0);

            ctx.queue_id = original_queue_id;
            vq.bdf = original_bdf;
            vq.mem = mem;
            vq.iommu = iommu;
            finish_context(vq);
        end
    endtask

    task test_recovery_rechecks_admin_context_bindings();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        bit                            recovery_complete;
        virtio_admin_vq_expected_error_catcher catcher;
        int unsigned                   original_queue_id;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        original_queue_id = ctx.queue_id;
        ctx.dma_quarantined = 1;
        ctx.recovery_required = 1;
        ctx.quarantined_iovas.push_back(64'h0000_0000_1000_0000);
        ctx.quarantined_gpas.push_back(64'h0000_0000_7100_1000);
        ctx.queue_id = vq.queue_id + 1;
        catcher = new("recover_context_binding_catcher", '{"PF_MGR"},
                      '{"recover_admin_vq: Admin VQ binding is inconsistent"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.recover_admin_vq(recovery_complete);
        uvm_report_cb::delete(null, catcher);

        assert(!recovery_complete && catcher.caught_count == 1 &&
               last_reset_owner.reset_count == 0 && transport.device_reset_count == 0 &&
               transport.reset_count == 0 && iommu.total_maps == 0 &&
               iommu.total_unmaps == 0 && ctx.dma_quarantined &&
               ctx.quarantined_iovas.size() == 1 && ctx.quarantined_gpas.size() == 1)
            else `uvm_fatal("ADMIN_VQ",
                "recover_admin_vq reset or released an inconsistently bound Admin VQ")

        ctx.queue_id = original_queue_id;
        ctx.dma_quarantined = 0;
        ctx.recovery_required = 0;
        ctx.quarantined_iovas.delete();
        ctx.quarantined_gpas.delete();
        finish_context(vq);
    endtask

    // Both callers share one Admin VQ.  The completion scheduler is capable
    // of completing either request, but command two must not become visible
    // until command one has completed and released all of its DMA ownership.
    task test_concurrent_admin_commands_are_serialized();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request_one[];
        byte unsigned                  request_two[];
        byte unsigned                  response_one[];
        byte unsigned                  response_two[];
        bit                            ok_one;
        bit                            ok_two;
        bit                            second_started;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        request_one = '{8'h61};
        request_two = '{8'h62};
        second_started = 0;

        fork : concurrent_admin_commands
            begin
                wait (transport.kick_count == 1);
                wait (second_started);
                assert(transport.kick_count == 1)
                    else `uvm_fatal("ADMIN_VQ", "second Admin command submitted before first completion")
                complete_admin_response(mem, iommu, vq, 8'h61, 8'hA1, 0);
                wait (transport.kick_count == 2);
                complete_admin_response(mem, iommu, vq, 8'h62, 8'hB2, 1);
            end
            begin
                pf_mgr.admin_cmd(0, request_one, response_one, ok_one);
            end
            begin
                wait (transport.kick_count == 1);
                second_started = 1;
                pf_mgr.admin_cmd(0, request_two, response_two, ok_two);
            end
        join

        assert(ok_one && ok_two && response_one.size() == 1 &&
               response_two.size() == 1 && response_one[0] == 8'hA1 &&
               response_two[0] == 8'hB2 && transport.kick_count == 2 &&
               iommu.total_maps == iommu.total_unmaps && vq.get_free_count() == 8)
            else `uvm_fatal("ADMIN_VQ", "concurrent Admin commands crossed responses or released DMA incorrectly")
        finish_context(vq);
    endtask

    // A caller may wait behind an earlier Admin command.  Its VF state must
    // be checked only after it owns the shared submission lock: an FLR or
    // disable while queued must not reach add_buf(), DMA mapping, or kick().
    task test_queued_command_revalidates_target_state();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request_one[];
        byte unsigned                  request_two[];
        byte unsigned                  response_one[];
        byte unsigned                  response_two[];
        bit                            ok_one;
        bit                            ok_two;
        bit                            second_started;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        request_one = '{8'h63};
        request_two = '{8'h64};
        second_started = 0;
        catcher = new("queued_target_state_catcher", '{"PF_MGR", "ATOMIC_OPS"},
                      '{"admin_cmd: target VF0 is not active",
                        "admin_vq_submit: timeout waiting for Admin VQ 7 completion"});
        uvm_report_cb::add(null, catcher);

        fork : queued_target_state
            begin
                wait (transport.kick_count == 1);
                wait (second_started);
                vf.state = VF_DISABLED;
                complete_admin_response(mem, iommu, vq, 8'h63, 8'hC4, 0);
            end
            begin
                pf_mgr.admin_cmd(0, request_one, response_one, ok_one);
            end
            begin
                wait (transport.kick_count == 1);
                second_started = 1;
                pf_mgr.admin_cmd(0, request_two, response_two, ok_two);
            end
        join
        uvm_report_cb::delete(null, catcher);

        assert(ok_one && !ok_two && response_one.size() == 1 &&
               response_one[0] == 8'hC4 && response_two.size() == 0 &&
               transport.kick_count == 1 && catcher.caught_count == 1 &&
               iommu.total_maps == iommu.total_unmaps && vq.get_free_count() == 8)
            else `uvm_fatal("ADMIN_VQ", "queued command submitted after its target VF left ACTIVE state")
        vf.state = VF_ACTIVE;
        finish_context(vq);
    endtask

    // A saturated effective timeout must still honor max_poll_attempts.  With
    // interval=1, UINT_MAX / 1 + 1 used to wrap to zero and reset before a
    // completion that arrives one poll interval after the kick.
    task test_saturated_timeout_polls_until_completion();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.wait_pol.default_timeout_ns = 32'hFFFF_FFFF;
        ctx.wait_pol.timeout_multiplier = 1;
        ctx.wait_pol.default_poll_interval_ns = 1;
        ctx.wait_pol.max_poll_attempts = 4;
        request = '{8'h71};

        fork : saturated_timeout_completion
            begin
                wait (transport.kick_count == 1);
                #(1 * 1ns);
                complete_admin_response(mem, iommu, vq, 8'h71, 8'hC3, 0);
            end
        join_none

        pf_mgr.admin_cmd(0, request, response, ok);
        disable saturated_timeout_completion;

        assert(ok && response.size() == 1 && response[0] == 8'hC3 &&
               transport.kick_count == 1 && transport.reset_count == 0 &&
               last_reset_owner.reset_count == 0 &&
               iommu.total_maps == iommu.total_unmaps && vq.get_free_count() == 8)
            else `uvm_fatal("ADMIN_VQ", "saturated Admin timeout did not poll through delayed completion")
        finish_context(vq);
    endtask

    task test_inactive_target_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        vf.state = VF_DISABLED;
        request = '{8'h44};
        catcher = new("inactive_target_catcher", '{"PF_MGR"},
                      '{"admin_cmd: target VF0 is not active"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "inactive target did not return explicit failure")
        assert_no_submission("inactive target", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_feature_absent_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.negotiated_features[VIRTIO_F_ADMIN_VQ] = 0;
        request = '{8'h45};
        catcher = new("feature_absent_catcher", '{"PF_MGR"},
                      '{"admin_cmd: VIRTIO_F_ADMIN_VQ is not negotiated"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "missing Admin-VQ feature did not return explicit failure")
        assert_no_submission("missing feature", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_missing_full_reset_owner_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.full_reset_owner = null;
        request = '{8'h51};
        catcher = new("missing_full_reset_owner_catcher", '{"PF_MGR"},
                      '{"admin_cmd: Admin VQ has no PF lifecycle reset owner"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "missing PF reset owner did not reject Admin command")
        assert_no_submission("missing PF reset owner", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_missing_special_vq_lease_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.special_vq_lease_valid = 0;
        request = '{8'h46};
        catcher = new("missing_lease_catcher", '{"PF_MGR"},
                      '{"admin_cmd: Admin VQ has no usable special-VQ lease"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "missing special-VQ lease did not return explicit failure")
        assert_no_submission("missing special-VQ lease", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_frozen_special_vq_lease_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.special_vq_lease.frozen = 1;
        request = '{8'h46};
        catcher = new("frozen_special_vq_lease_catcher", '{"PF_MGR"},
                      '{"admin_cmd: Admin VQ has no usable special-VQ lease"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && response.size() == 0 && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "frozen special-VQ lease did not return explicit failure")
        assert_no_submission("frozen special-VQ lease", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_missing_configuration_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.configured = 0;
        request = '{8'h47};
        catcher = new("missing_config_catcher", '{"PF_MGR"},
                      '{"admin_cmd: Admin VQ is not configured"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "unconfigured Admin VQ did not return explicit failure")
        assert_no_submission("unconfigured Admin VQ", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_failed_device_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        transport.mock_status = DEV_STATUS_FAILED;
        request = '{8'h48};
        catcher = new("failed_device_catcher", '{"PF_MGR"},
                      '{"admin_cmd: device is FAILED or needs reset"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "failed device did not return explicit failure")
        assert_no_submission("failed device", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_device_needs_reset_has_no_submission();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        transport.mock_status = DEV_STATUS_DEVICE_NEEDS_RESET;
        request = '{8'h4D};
        catcher = new("device_needs_reset_catcher", '{"PF_MGR"},
                      '{"admin_cmd: device is FAILED or needs reset"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 1)
            else `uvm_fatal("ADMIN_VQ", "device-needs-reset did not return explicit failure")
        assert_no_submission("device-needs-reset", transport, vq, iommu, 0);
        finish_context(vq);
    endtask

    task test_device_error_completion_cleans_up();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        request = '{8'h49};
        catcher = new("device_error_catcher", '{"ATOMIC_OPS"},
                      '{"admin_vq_submit: device rejected Admin VQ request"});
        uvm_report_cb::add(null, catcher);
        fork : admin_error_completion
            begin
                bit [63:0] in_addr;
                bit [63:0] unused_addr;
                bit [31:0] in_len;
                bit [31:0] unused_len;
                bit [15:0] unused_flags;
                bit [15:0] unused_next;
                bit [15:0] in_flags;
                bit [15:0] in_next;
                iommu_fault_e fault;
                byte device_response[];

                wait (transport.kick_count != 0);
                read_split_desc(mem, vq, 0, unused_addr, unused_len,
                                unused_flags, unused_next);
                read_split_desc(mem, vq, 1, in_addr, in_len, in_flags, in_next);
                device_response = '{VIRTIO_NET_ERR, 8'hE1};
                assert(iommu.write_from_device(mem, vq.bdf, in_addr,
                                               device_response, fault))
                    else `uvm_fatal("ADMIN_VQ", "error response DMA write failed")
                complete_split(mem, vq, 0, device_response.size());
            end
        join_none
        pf_mgr.admin_cmd(0, request, response, ok);
        disable admin_error_completion;
        uvm_report_cb::delete(null, catcher);

        assert(!ok && response.size() == 1 && response[0] == 8'hE1 &&
               catcher.caught_count == 1 && transport.kick_count == 1 &&
               vq.get_free_count() == 8 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "device-error completion was not decoded and cleaned up")
        finish_context(vq);
    endtask

    task test_submission_failure_cleans_up();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        virtio_sg_list                 filler_sgs[];
        virtio_sg_entry                filler_entry;
        bit [63:0]                     filler_gpa;
        bit                            ok;
        int unsigned                   add_before;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        filler_gpa = mem.alloc(8, .align(8));
        filler_entry.addr = filler_gpa;
        filler_entry.len = 8;
        filler_sgs = new[1];
        filler_sgs[0].entries.push_back(filler_entry);
        for (int unsigned i = 0; i < 8; i++) begin
            assert(vq.add_buf(filler_sgs, 1, 0, null, 0) != '1)
                else `uvm_fatal("ADMIN_VQ", "could not fill Admin VQ for submission-failure test")
        end
        add_before = vq.total_add_buf_ops;
        request = '{8'h4A};
        catcher = new("submission_failure_catcher", '{"SPLIT_VQ", "ATOMIC_OPS"},
                      '{"add_buf: queue_id=7 need 2 descriptors", "admin_vq_submit: queue 7 rejected"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);

        assert(!ok && catcher.caught_count == 2 && transport.kick_count == 0 &&
               vq.total_add_buf_ops == add_before && vq.get_free_count() == 0 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "failed Admin VQ submission leaked resources or kicked")
        mem.free(filler_gpa);
        finish_context(vq);
    endtask

    task test_response_map_failure_cleans_up_request_resources();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_iommu    test_iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        assert($cast(test_iommu, iommu))
            else `uvm_fatal("ADMIN_VQ", "Admin context did not create the map-failure IOMMU")
        test_iommu.fail_on_map_attempt = 2;
        request = '{8'h4C};
        catcher = new("response_map_failure_catcher", '{"ATOMIC_OPS"},
                      '{"admin_vq_submit: response DMA map failed"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);

        assert(!ok && response.size() == 0 && catcher.caught_count == 1 &&
               transport.kick_count == 0 && vq.total_add_buf_ops == 0 &&
               vq.get_free_count() == 8 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "response-map failure submitted work or leaked request resources")
        finish_context(vq);
    endtask

    task test_timeout_without_ring_reset_uses_device_reset();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_iommu    test_iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        assert($cast(test_iommu, iommu))
            else `uvm_fatal("ADMIN_VQ", "Admin context did not create the timeout IOMMU")
        assert(!ctx.negotiated_features[VIRTIO_F_RING_RESET])
            else `uvm_fatal("ADMIN_VQ", "Admin-only timeout test negotiated VIRTIO_F_RING_RESET")
        test_iommu.transport_for_unmap = transport;
        test_iommu.observe_unmap_order = 1;
        request = '{8'h4B};
        catcher = new("admin_only_timeout_catcher", '{"ATOMIC_OPS"},
                      '{"admin_vq_submit: timeout waiting for Admin VQ 7 completion"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);

        assert(!ok && catcher.caught_count >= 1 && transport.kick_count == 1 &&
               transport.reset_count == 0 && transport.device_reset_count == 1 &&
               last_reset_owner.reset_count == 1 &&
               last_reset_owner.normal_pf_state_invalidated &&
               !ctx.configured && test_iommu.saw_unmap &&
               test_iommu.device_reset_requested_before_first_unmap &&
               vq.get_free_count() == 8 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "Admin-only timeout did not reset device before releasing DMA")
        finish_context(vq);
    endtask

    task test_malformed_completion_without_ring_reset_uses_device_reset();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_iommu    test_iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        assert($cast(test_iommu, iommu))
            else `uvm_fatal("ADMIN_VQ", "Admin context did not create the malformed-response IOMMU")
        assert(!ctx.negotiated_features[VIRTIO_F_RING_RESET])
            else `uvm_fatal("ADMIN_VQ", "Admin-only malformed-response test negotiated VIRTIO_F_RING_RESET")
        test_iommu.transport_for_unmap = transport;
        test_iommu.observe_unmap_order = 1;
        request = '{8'h4E};
        catcher = new("admin_only_malformed_completion_catcher", '{"ATOMIC_OPS"},
                      '{"admin_vq_submit: invalid Admin VQ response length 0"});
        uvm_report_cb::add(null, catcher);
        fork : admin_malformed_completion
            begin
                wait (transport.kick_count != 0);
                complete_split(mem, vq, 0, 0);
            end
        join_none
        pf_mgr.admin_cmd(0, request, response, ok);
        disable admin_malformed_completion;
        uvm_report_cb::delete(null, catcher);

        assert(!ok && catcher.caught_count >= 1 && transport.kick_count == 1 &&
               transport.reset_count == 0 && transport.device_reset_count == 1 &&
               last_reset_owner.reset_count == 1 &&
               last_reset_owner.normal_pf_state_invalidated &&
               !ctx.configured && test_iommu.saw_unmap &&
               test_iommu.device_reset_requested_before_first_unmap &&
               vq.get_free_count() == 8 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "Admin-only malformed completion did not reset device before releasing DMA")
        finish_context(vq);
    endtask

    task test_timeout_with_ring_reset_uses_queue_reset();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_iommu    test_iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        assert($cast(test_iommu, iommu))
            else `uvm_fatal("ADMIN_VQ", "Admin context did not create the ring-reset IOMMU")
        ctx.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        test_iommu.transport_for_unmap = transport;
        test_iommu.observe_unmap_order = 1;
        request = '{8'h4F};
        catcher = new("ring_reset_timeout_catcher", '{"ATOMIC_OPS"},
                      '{"admin_vq_submit: timeout waiting for Admin VQ 7 completion"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);

        assert(!ok && catcher.caught_count >= 1 && transport.kick_count == 1 &&
               transport.reset_count == 1 && transport.device_reset_count == 0 &&
               transport.last_reset_queue_id == ctx.queue_id && !ctx.configured &&
               test_iommu.saw_unmap &&
               test_iommu.queue_reset_requested_before_first_unmap &&
               vq.get_free_count() == 8 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "Ring-reset timeout did not reset queue before releasing DMA")
        finish_context(vq);
    endtask

    // A reset request alone is not permission to release Admin DMA.  This
    // transport advertises that Q_RESET never completed; recovery must retain
    // both request and response mappings and leave the context unusable.
    task test_unconfirmed_queue_reset_quarantines_dma();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        virtio_admin_vq_expected_error_catcher catcher;
        virtio_admin_vq_expected_error_catcher clear_catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        transport.queue_reset_complete = 0;
        request = '{8'h50};
        catcher = new("unconfirmed_queue_reset_catcher", '{"ATOMIC_OPS", "ATOMIC_OPS"},
                      '{"admin_vq_submit: timeout waiting for Admin VQ 7 completion",
                        "admin_vq_submit: Admin VQ 7 reset did not complete"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);

        assert(!ok && catcher.caught_count >= 1 && transport.kick_count == 1 &&
               transport.reset_count == 1 && !ctx.configured &&
               iommu.total_maps == 2 && iommu.total_unmaps == 0 &&
               vq.desc_table_addr != 0 && ctx.recovery_required &&
               ctx.dma_quarantined && ctx.quarantined_iovas.size() == 2 &&
               ctx.quarantined_gpas.size() == 2)
            else `uvm_fatal("ADMIN_VQ", "unconfirmed queue reset released Admin DMA or left it usable")

        // Teardown must not discard the only ownership record for DMA that
        // remains reachable by the device.  A verified recovery is required
        // before this context can be cleared.
        clear_catcher = new("quarantined_clear_catcher", '{"PF_MGR"},
                            '{"clear_admin_vq: Admin VQ has quarantined DMA"});
        uvm_report_cb::add(null, clear_catcher);
        pf_mgr.clear_admin_vq();
        uvm_report_cb::delete(null, clear_catcher);
        assert(clear_catcher.caught_count == 1 && pf_mgr.admin_vq == ctx)
            else `uvm_fatal("ADMIN_VQ", "clear_admin_vq discarded quarantined Admin DMA")
    endtask

    // A failed Q_RESET leaves the two Admin buffers device-reachable.  Only a
    // subsequently verified full-PF lifecycle reset may retire that record,
    // after which teardown is safe and requires explicit reconfiguration.
    task test_verified_recovery_releases_quarantined_dma();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        bit                            recovery_complete;
        virtio_admin_vq_expected_error_catcher catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        transport.queue_reset_complete = 0;
        request = '{8'h51};
        catcher = new("verified_recovery_quarantine_catcher", '{"ATOMIC_OPS", "ATOMIC_OPS"},
                      '{"admin_vq_submit: timeout waiting for Admin VQ 7 completion",
                        "admin_vq_submit: Admin VQ 7 reset did not complete"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 2 && ctx.dma_quarantined &&
               iommu.total_maps == 2 && iommu.total_unmaps == 0)
            else `uvm_fatal("ADMIN_VQ", "recovery test did not first quarantine Admin DMA")

        pf_mgr.recover_admin_vq(recovery_complete);

        assert(recovery_complete && last_reset_owner.reset_count == 1 &&
               last_reset_owner.normal_pf_state_invalidated &&
               transport.device_reset_count == 1 && !ctx.configured &&
               !ctx.recovery_required && !ctx.dma_quarantined &&
               ctx.quarantined_iovas.size() == 0 && ctx.quarantined_gpas.size() == 0 &&
               iommu.total_maps == iommu.total_unmaps && vq.desc_table_addr != 0)
            else `uvm_fatal("ADMIN_VQ", "verified recovery did not retire quarantined Admin DMA")

        finish_context(vq);
        assert(pf_mgr.admin_vq != ctx)
            else `uvm_fatal("ADMIN_VQ", "recovered Admin VQ context could not be cleared")
    endtask

    // A reset request which cannot be verified still grants no permission to
    // unmap or free the Admin buffers.  Recovery must retain every ownership
    // record so a later verified reset can repeat the release attempt.
    task test_failed_recovery_retains_quarantined_dma();
        virtio_admin_vq_context       ctx;
        host_mem_manager               mem;
        virtio_iommu_model             iommu;
        virtio_admin_vq_test_transport transport;
        split_virtqueue                vq;
        byte unsigned                  request[];
        byte unsigned                  response[];
        bit                            ok;
        bit                            recovery_complete;
        virtio_admin_vq_expected_error_catcher catcher;
        virtio_admin_vq_expected_error_catcher recovery_catcher;

        configure_admin_context(ctx, mem, iommu, transport, vq);
        ctx.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
        transport.queue_reset_complete = 0;
        request = '{8'h52};
        catcher = new("failed_recovery_quarantine_catcher", '{"ATOMIC_OPS", "ATOMIC_OPS"},
                      '{"admin_vq_submit: timeout waiting for Admin VQ 7 completion",
                        "admin_vq_submit: Admin VQ 7 reset did not complete"});
        uvm_report_cb::add(null, catcher);
        pf_mgr.admin_cmd(0, request, response, ok);
        uvm_report_cb::delete(null, catcher);
        assert(!ok && catcher.caught_count == 2 && ctx.dma_quarantined)
            else `uvm_fatal("ADMIN_VQ", "failed-recovery test did not quarantine Admin DMA")

        last_reset_owner.reset_succeeds = 0;
        recovery_catcher = new("failed_recovery_catcher", '{"PF_MGR"},
                               '{"recover_admin_vq: PF lifecycle reset did not complete"});
        uvm_report_cb::add(null, recovery_catcher);
        pf_mgr.recover_admin_vq(recovery_complete);
        uvm_report_cb::delete(null, recovery_catcher);

        assert(!recovery_complete && recovery_catcher.caught_count == 1 &&
               last_reset_owner.reset_count == 1 && transport.device_reset_count == 1 &&
               ctx.dma_quarantined && ctx.recovery_required &&
               ctx.quarantined_iovas.size() == 2 && ctx.quarantined_gpas.size() == 2 &&
               iommu.total_maps == 2 && iommu.total_unmaps == 0 && pf_mgr.admin_vq == ctx)
            else `uvm_fatal("ADMIN_VQ", "failed recovery released or lost quarantined Admin DMA")

        // The retained record must support a later retry; leave the shared
        // PF manager clean so the final teardown-is-rejected case remains
        // independently observable.
        last_reset_owner.reset_succeeds = 1;
        pf_mgr.recover_admin_vq(recovery_complete);
        assert(recovery_complete && !ctx.dma_quarantined &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("ADMIN_VQ", "retained quarantine could not be recovered later")
        finish_context(vq);
    endtask
endclass : virtio_admin_vq_test

`endif // VIRTIO_ADMIN_VQ_TEST_SV
