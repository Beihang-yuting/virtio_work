`ifndef VIRTIO_TEST_DEVICE_BUILDER_SV
`define VIRTIO_TEST_DEVICE_BUILDER_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

// Test-only authoring support for explicit global device configurations.
// This helper creates public configuration objects only; resolution remains
// owned by dpu_device_env.
class virtio_test_device_builder extends uvm_object;
    `uvm_object_utils(virtio_test_device_builder)

    dpu_device_cfg device_cfg;

    function new(string name = "virtio_test_device_builder");
        super.new(name);
        device_cfg = dpu_device_cfg::type_id::create({name, "_device_cfg"});
    endfunction

    function dpu_pcie_domain_cfg add_host_domain(
        input int unsigned host_id,
        input int unsigned segment_id,
        input bit [15:0] first_bdf = 16'h0010,
        input bit [15:0] last_bdf = 16'h0fff,
        input bit [63:0] mmio_base = 64'h0000_0002_0000_0000,
        input bit [63:0] mmio_limit = 64'h0000_0003_0000_0000
    );
        dpu_host_cfg host;
        dpu_pcie_domain_cfg domain;
        dpu_bdf_range_t bdf_range;
        dpu_mmio_window_cfg window;

        host = null;
        foreach (device_cfg.hosts[index]) begin
            if ((device_cfg.hosts[index] != null) &&
                (device_cfg.hosts[index].host_id == host_id)) begin
                host = device_cfg.hosts[index];
                break;
            end
        end
        if (host == null) begin
            host = dpu_host_cfg::type_id::create(
                $sformatf("host_%0d", host_id));
            host.host_id = host_id;
            device_cfg.hosts.push_back(host);
        end

        domain = dpu_pcie_domain_cfg::type_id::create(
            $sformatf("host_%0d_domain_%0d", host_id, segment_id));
        domain.key.host_id = host_id;
        domain.key.segment_id = segment_id;
        bdf_range.first_bdf = first_bdf;
        bdf_range.last_bdf = last_bdf;
        domain.bdf_ranges.push_back(bdf_range);

        window = dpu_mmio_window_cfg::type_id::create(
            $sformatf("host_%0d_domain_%0d_window", host_id, segment_id));
        window.base = mmio_base;
        window.limit = mmio_limit;
        window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
        window.allowed_roles.push_back(DPU_BAR_MAILBOX);
        window.allowed_roles.push_back(DPU_BAR_MSIX);
        domain.mmio_windows.push_back(window);
        host.pcie_domains.push_back(domain);
        return domain;
    endfunction

    protected function dpu_function_cfg add_function(
        input int unsigned host_id,
        input int unsigned pf_id,
        input dpu_function_kind_e kind,
        input int unsigned vf_id,
        input int unsigned segment_id,
        input dpu_allocation_mode_e bdf_mode,
        input bit [15:0] pinned_bdf
    );
        dpu_function_cfg function_cfg;

        function_cfg = dpu_function_cfg::type_id::create(
            $sformatf("host_%0d_pf_%0d_kind_%0d_vf_%0d",
                      host_id, pf_id, kind, vf_id));
        function_cfg.key.host_id = host_id;
        function_cfg.key.pf_id = pf_id;
        function_cfg.key.kind = kind;
        function_cfg.key.vf_id = vf_id;
        function_cfg.domain_key.host_id = host_id;
        function_cfg.domain_key.segment_id = segment_id;
        function_cfg.bdf_mode = bdf_mode;
        function_cfg.pinned_bdf = pinned_bdf;
        device_cfg.functions.push_back(function_cfg);
        return function_cfg;
    endfunction

    function dpu_function_cfg add_pf(
        input int unsigned host_id,
        input int unsigned pf_id,
        input int unsigned segment_id,
        input dpu_allocation_mode_e bdf_mode = DPU_ALLOC_AUTO,
        input bit [15:0] pinned_bdf = '0
    );
        return add_function(host_id, pf_id, DPU_FUNCTION_PF, 0, segment_id,
                            bdf_mode, pinned_bdf);
    endfunction

    function dpu_function_cfg add_vf(
        input int unsigned host_id,
        input int unsigned pf_id,
        input int unsigned vf_id,
        input int unsigned segment_id,
        input dpu_allocation_mode_e bdf_mode = DPU_ALLOC_AUTO,
        input bit [15:0] pinned_bdf = '0
    );
        return add_function(host_id, pf_id, DPU_FUNCTION_VF, vf_id, segment_id,
                            bdf_mode, pinned_bdf);
    endfunction

    function dpu_service_key_t add_vio_service(
        input dpu_function_cfg function_cfg,
        input int unsigned service_instance_id = 0
    );
        dpu_service_decl service;
        dpu_service_key_t service_key;

        service = dpu_service_decl::type_id::create(
            $sformatf("%s_vio_%0d", function_cfg.get_name(),
                      service_instance_id));
        service.service_kind = DPU_SERVICE_VIO_NET;
        service.service_instance_id = service_instance_id;
        function_cfg.services.push_back(service);
        service_key.function_key = function_cfg.key;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = service_instance_id;
        return service_key;
    endfunction

    function void add_real_dut_bars(input dpu_function_cfg function_cfg);
        dpu_bar_role_e roles[$];
        dpu_bar_profile_t profile;
        dpu_bar_request request;
        string why;

        roles.push_back(DPU_BAR_DEVICE_MEMORY);
        roles.push_back(DPU_BAR_MAILBOX);
        roles.push_back(DPU_BAR_MSIX);
        foreach (roles[index]) begin
            if (!device_cfg.dut_caps.lookup_bar_profile(
                    function_cfg.key.kind, roles[index], profile, why)) begin
                `uvm_fatal("TEST_DEVICE_BUILDER", $sformatf(
                    "could not author real-DUT BAR profile: %s", why))
                return;
            end
            request = dpu_bar_request::type_id::create(
                $sformatf("%s_bar_%0d", function_cfg.get_name(), roles[index]));
            request.role = profile.role;
            request.even_bar_id = profile.even_bar_id;
            request.size = profile.size;
            request.alignment = profile.alignment;
            request.placement = DPU_ALLOC_AUTO;
            request.pinned_base = '0;
            function_cfg.bars.push_back(request);
        end
    endfunction

    function void select_af(input dpu_function_cfg function_cfg);
        device_cfg.af_request.mode = DPU_AF_SELECTED;
        device_cfg.af_request.requester = function_cfg.key;
    endfunction

    function dpu_device_env_config make_env_config();
        dpu_device_env_config env_cfg;
        dpu_resource_pool_config_t qpair_profile;

        env_cfg = dpu_device_env_config::type_id::create(
            {get_name(), "_env_cfg"});
        env_cfg.device_cfg.copy_from(device_cfg);
        qpair_profile.name = "virtio.qpair";
        qpair_profile.class_id = '0;
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = 2048;
        qpair_profile.max_per_function = 32;
        env_cfg.resource_profiles.push_back(qpair_profile);
        return env_cfg;
    endfunction
endclass : virtio_test_device_builder

`endif // VIRTIO_TEST_DEVICE_BUILDER_SV
