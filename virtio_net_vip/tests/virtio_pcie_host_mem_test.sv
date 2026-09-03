`ifndef VIRTIO_PCIE_HOST_MEM_TEST_SV
`define VIRTIO_PCIE_HOST_MEM_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import host_mem_pkg::*;
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// Suppress only the deliberately induced PREMAP allocation failure.  The
// test checks both reports explicitly so an allocator failure cannot be
// mistaken for a successfully configured PCIe environment.
class virtio_pcie_premap_failure_catcher extends uvm_report_catcher;
    int unsigned allocator_errors;
    int unsigned env_fatals;

    function new(string name = "virtio_pcie_premap_failure_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == "HOST_MEM" &&
            uvm_is_match(
                "*alloc: insufficient space for size=8388608 align=16*",
                get_message())) begin
            allocator_errors++;
            return CAUGHT;
        end
        if (get_severity() == UVM_FATAL &&
            get_id() == "PCIE_TL_HOST_MEM" &&
            get_message() ==
                "Root 0 Host 3 PREMAP allocation failed: size=8388608 align=16") begin
            env_fatals++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

// Proves that the PCIe DMA responder and VIO consume the same top-level,
// Host-scoped memory manager, while another PCIe Root uses an independent
// manager even when both Hosts expose the same numerical GPA aperture.
class virtio_pcie_host_mem_test extends uvm_test;
    `uvm_component_utils(virtio_pcie_host_mem_test)

    localparam bit [63:0] SHARED_GPA_BASE = 64'h0000_1234_0000_0000;
    localparam bit [63:0] SHARED_GPA_END  = 64'h0000_1234_00FF_FFFF;
    localparam bit [63:0] PREMAP_GPA_BASE = 64'h0000_5678_0000_0000;
    localparam int unsigned PREMAP_BYTES  = 32'h0100_0000;
    localparam bit [63:0] PREMAP_GPA_END  =
        PREMAP_GPA_BASE + PREMAP_BYTES - 1;
    localparam bit [63:0] SMALL_GPA_BASE  = 64'h0000_6789_0000_0000;
    localparam int unsigned SMALL_BYTES   = 32'h0040_0000;
    localparam bit [63:0] SMALL_GPA_END   =
        SMALL_GPA_BASE + SMALL_BYTES - 1;
    localparam int unsigned TOO_LARGE_PREMAP_BYTES = 32'h0080_0000;
    localparam int unsigned DMA_BYTES = 64;

    virtio_test_device_builder device_builder;
    dpu_device_env_config      device_cfg;
    dpu_device_env             device_env;
    virtio_net_env_config      vio_cfg;
    virtio_net_env             vio_env;

    host_mem_pool              host_mem_owners;
    host_mem_manager           host0_mem;
    host_mem_manager           host1_mem;
    host_mem_manager           host2_mem;
    host_mem_manager           host3_mem;
    bit [63:0]                 shared_dma_addr;

    pcie_tl_env_config         pcie_cfg;
    pcie_tl_env                pcie_env;
    pcie_tl_env_config         pcie_premap_cfg;
    pcie_tl_env                pcie_premap_env;
    pcie_tl_env_config         pcie_failed_premap_cfg;
    pcie_tl_env                pcie_failed_premap_env;
    virtio_pcie_premap_failure_catcher premap_failure_catcher;

    byte host0_pattern[];
    byte host1_pattern[];

    function new(string name = "virtio_pcie_host_mem_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    protected function void make_pattern(ref byte data[], input byte first);
        data = new[DMA_BYTES];
        foreach (data[index])
            data[index] = byte'(first + index);
    endfunction

    protected function void require_bytes(
        input byte actual[],
        input byte expected[],
        input string check_name
    );
        if (actual.size() != expected.size()) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST", $sformatf(
                "%s size=%0d, expected %0d", check_name,
                actual.size(), expected.size()))
            return;
        end
        foreach (expected[index]) begin
            if (actual[index] !== expected[index]) begin
                `uvm_fatal("PCIE_HOST_MEM_TEST", $sformatf(
                    "%s byte[%0d]=0x%02h, expected 0x%02h",
                    check_name, index, actual[index], expected[index]))
                return;
            end
        end
    endfunction

    protected function void verify_binding_api();
        pcie_tl_env_config probe_cfg;
        host_mem_manager mismatch_mem;
        host_mem_api selected_mem;
        int unsigned selected_host_id;
        string why;

        probe_cfg = pcie_tl_env_config::type_id::create("binding_probe_cfg");
        mismatch_mem = host_mem_manager::type_id::create("mismatch_mem");
        mismatch_mem.set_host_id(9);

        if (probe_cfg.bind_host_memory(0, 0, null, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", "null Host-memory binding was accepted")
        if (probe_cfg.bind_host_memory(0, 0, mismatch_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", "Host-ID mismatch was accepted")
        if (!probe_cfg.bind_host_memory(0, 0, host0_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"valid root0 binding failed: ", why})
        if (probe_cfg.bind_host_memory(0, 1, host1_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", "duplicate root binding was accepted")
        if (!probe_cfg.get_host_memory(
                0, selected_host_id, selected_mem, why) ||
            selected_host_id != 0 || selected_mem != host0_mem) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                "rejected duplicate binding corrupted the root0 mapping")
        end
        if (probe_cfg.get_host_memory(
                1, selected_host_id, selected_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", "missing root binding was returned")
        if (probe_cfg.validate_host_memory_bindings(2, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", "incomplete binding set was accepted")
        if (!probe_cfg.bind_host_memory(1, 1, host1_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"valid root1 binding failed: ", why})
        if (!probe_cfg.validate_host_memory_bindings(2, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"complete binding set failed: ", why})
        if (!probe_cfg.bind_host_memory(2, 0, host0_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"probe root2 binding failed: ", why})
        if (probe_cfg.validate_host_memory_bindings(2, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", "out-of-range root binding was accepted")
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_function_cfg pf_cfg;
        dpu_function_key_t vio_devices[$];
        bit [63:0] host0_addr;
        bit [63:0] host1_addr;
        string why;

        super.build_phase(phase);

        premap_failure_catcher = new("premap_failure_catcher");
        uvm_report_cb::add(null, premap_failure_catcher);

        host_mem_owners = host_mem_pool::type_id::create("host_mem_owners");
        if (!host_mem_owners.create_host(
                0, SHARED_GPA_BASE, SHARED_GPA_END, MODE_BUDDY,
                DEFAULT_MIN_GRANULE, HOST_MEM_FIRST_FIT) ||
            !host_mem_owners.create_host(
                1, SHARED_GPA_BASE, SHARED_GPA_END, MODE_BUDDY,
                DEFAULT_MIN_GRANULE, HOST_MEM_FIRST_FIT) ||
            !host_mem_owners.create_host(
                2, PREMAP_GPA_BASE, PREMAP_GPA_END, MODE_BUDDY,
                DEFAULT_MIN_GRANULE, HOST_MEM_FIRST_FIT) ||
            !host_mem_owners.create_host(
                3, SMALL_GPA_BASE, SMALL_GPA_END, MODE_BUDDY,
                DEFAULT_MIN_GRANULE, HOST_MEM_FIRST_FIT)) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "could not create the Host-memory managers")
            return;
        end
        host0_mem = host_mem_owners.get_host(0);
        host1_mem = host_mem_owners.get_host(1);
        host2_mem = host_mem_owners.get_host(2);
        host3_mem = host_mem_owners.get_host(3);
        host0_addr = host0_mem.alloc(DMA_BYTES, 64);
        host1_addr = host1_mem.alloc(DMA_BYTES, 64);
        if (host0_addr != host1_addr || host0_addr == '1) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST", $sformatf(
                "same-aperture Hosts did not allocate the same GPA: host0=0x%016h host1=0x%016h",
                host0_addr, host1_addr))
            return;
        end
        shared_dma_addr = host0_addr;
        make_pattern(host0_pattern, 8'h10);
        make_pattern(host1_pattern, 8'h80);
        host0_mem.write_mem(shared_dma_addr, host0_pattern);
        host1_mem.write_mem(shared_dma_addr, host1_pattern);

        verify_binding_api();

        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        void'(device_builder.add_host_domain(0, 0));
        void'(device_builder.add_host_domain(1, 0));
        pf_cfg = device_builder.add_pf(0, 0, 0);
        device_builder.add_real_dut_bars(pf_cfg);
        void'(device_builder.allow_vio_service(pf_cfg));
        vio_devices.push_back(pf_cfg.key);
        void'(device_builder.add_fixed_vio_request(0, vio_devices, 1));
        device_builder.select_af(pf_cfg);

        vio_cfg = virtio_net_env_config::type_id::create("vio_cfg");
        vio_cfg.host_id = 0;
        vio_cfg.mem_base = SHARED_GPA_BASE;
        vio_cfg.mem_end = SHARED_GPA_END;
        vio_cfg.host_mem_policy = HOST_MEM_FIRST_FIT;
        // IOVA policy is an environment-level input, independent from the
        // Host GPA aperture.  Use a compact aperture here so the test also
        // proves that the environment forwards it to its IOMMU instance.
        vio_cfg.iova_base = 64'h0000_0000_4000_0000;
        vio_cfg.iova_limit = 64'h0000_0000_4002_0000;
        vio_cfg.iova_alloc_policy = IOMMU_IOVA_FIRST_FIT;
        vio_cfg.default_num_pairs = 1;
        vio_cfg.default_queue_size = 64;
        vio_cfg.default_vq_type = VQ_SPLIT;
        vio_cfg.default_driver_features = '1;
        vio_cfg.scb_enable = 1;
        vio_cfg.cov_enable = 0;

        device_cfg = device_builder.make_env_config();
        device_cfg.host_mem_pool_ref = host_mem_owners;
        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_cfg);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "device_env.vio_env", "cfg", vio_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);
        vio_env = virtio_net_env::type_id::create("vio_env", device_env);

        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_cfg.if_mode = TLM_MODE;
        pcie_cfg.num_rc = 2;
        pcie_cfg.num_ep = 2;
        pcie_cfg.use_unified_mem = 1;
        pcie_cfg.mem_access_mode = PCIE_TL_MEM_PER_BUFFER;
        pcie_cfg.fc_enable = 1;
        pcie_cfg.infinite_credit = 1;
        pcie_cfg.cpl_timeout_ns = 100000;
        pcie_cfg.scb_enable = 1;
        if (!pcie_cfg.bind_host_memory(0, 0, host0_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"root0 bind failed: ", why})
        if (!pcie_cfg.bind_host_memory(1, 1, host1_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"root1 bind failed: ", why})
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "pcie_env", "cfg", pcie_cfg);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        // A Host may expose the same memory manager through multiple Root
        // ports.  PREMAP is Host-memory ownership state, so it must consume
        // this exact-size aperture once rather than once per Root.
        pcie_premap_cfg = pcie_tl_env_config::type_id::create(
            "pcie_premap_cfg");
        pcie_premap_cfg.if_mode = TLM_MODE;
        pcie_premap_cfg.num_rc = 2;
        pcie_premap_cfg.ep_agent_enable = 0;
        pcie_premap_cfg.num_ep = 0;
        pcie_premap_cfg.use_unified_mem = 1;
        pcie_premap_cfg.mem_access_mode = PCIE_TL_MEM_PREMAP;
        pcie_premap_cfg.premap_base = PREMAP_GPA_BASE;
        pcie_premap_cfg.premap_size = PREMAP_BYTES;
        pcie_premap_cfg.mem_granule = DEFAULT_MIN_GRANULE;
        pcie_premap_cfg.scb_enable = 0;
        if (!pcie_premap_cfg.bind_host_memory(0, 2, host2_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"premap root0 bind failed: ", why})
        if (!pcie_premap_cfg.bind_host_memory(1, 2, host2_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST", {"premap root1 bind failed: ", why})
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "pcie_premap_env", "cfg", pcie_premap_cfg);
        pcie_premap_env = pcie_tl_env::type_id::create(
            "pcie_premap_env", this);

        // This configuration cannot satisfy its PREMAP request.  The
        // allocator reports the resource failure, and the PCIe environment
        // must additionally reject the unusable configuration.
        pcie_failed_premap_cfg = pcie_tl_env_config::type_id::create(
            "pcie_failed_premap_cfg");
        pcie_failed_premap_cfg.if_mode = TLM_MODE;
        pcie_failed_premap_cfg.num_rc = 1;
        pcie_failed_premap_cfg.ep_agent_enable = 0;
        pcie_failed_premap_cfg.num_ep = 0;
        pcie_failed_premap_cfg.use_unified_mem = 1;
        pcie_failed_premap_cfg.mem_access_mode = PCIE_TL_MEM_PREMAP;
        pcie_failed_premap_cfg.premap_base = SMALL_GPA_BASE;
        pcie_failed_premap_cfg.premap_size = TOO_LARGE_PREMAP_BYTES;
        pcie_failed_premap_cfg.mem_granule = DEFAULT_MIN_GRANULE;
        pcie_failed_premap_cfg.scb_enable = 0;
        if (!pcie_failed_premap_cfg.bind_host_memory(0, 3, host3_mem, why))
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       {"failed-premap root0 bind failed: ", why})
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "pcie_failed_premap_env", "cfg", pcie_failed_premap_cfg);
        pcie_failed_premap_env = pcie_tl_env::type_id::create(
            "pcie_failed_premap_env", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!vio_env.bind_pcie(pcie_env.rc_agents[0].sequencer)) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "could not bind the Host0 VIO function to PCIe Root0")
            return;
        end
    endfunction

    protected task issue_dma_write(input int unsigned root_index,
                                   input byte data[]);
        pcie_tl_rw_seq write_seq;

        write_seq = pcie_tl_rw_seq::type_id::create(
            $sformatf("host%0d_dma_write", root_index));
        write_seq.op = PCIE_RW_WRITE;
        write_seq.addr = shared_dma_addr;
        write_seq.byte_len = data.size();
        write_seq.is_64bit = 1;
        write_seq.wdata = new[data.size()];
        foreach (data[index])
            write_seq.wdata[index] = data[index];
        write_seq.start(pcie_env.ep_agents[root_index].sequencer);
    endtask

    protected task issue_dma_read(input int unsigned root_index,
                                  input byte expected[]);
        pcie_tl_rw_seq read_seq;
        byte actual[];

        read_seq = pcie_tl_rw_seq::type_id::create(
            $sformatf("host%0d_dma_read", root_index));
        read_seq.op = PCIE_RW_READ;
        read_seq.addr = shared_dma_addr;
        read_seq.byte_len = expected.size();
        read_seq.is_64bit = 1;
        read_seq.rb_timeout_ns = 100000;
        read_seq.start(pcie_env.ep_agents[root_index].sequencer);
        if (read_seq.status != PCIE_RW_OK) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST", $sformatf(
                "Host %0d DMA read status=%s", root_index,
                read_seq.status.name()))
            return;
        end
        actual = new[read_seq.rdata.size()];
        foreach (read_seq.rdata[index])
            actual[index] = byte'(read_seq.rdata[index]);
        require_bytes(actual, expected,
                      $sformatf("Host %0d DMA readback", root_index));
    endtask

    virtual task run_phase(uvm_phase phase);
        byte host0_write[];
        byte host1_write[];
        byte host0_backing[];
        byte host1_backing[];
        byte premap_write[];
        byte premap_read[];

        phase.raise_objection(this);
        #100ns;

        uvm_report_cb::delete(null, premap_failure_catcher);
        if (premap_failure_catcher.allocator_errors != 1 ||
            premap_failure_catcher.env_fatals != 1) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST", $sformatf(
                "failed PREMAP reports allocator_errors=%0d env_fatals=%0d, expected 1/1",
                premap_failure_catcher.allocator_errors,
                premap_failure_catcher.env_fatals))
        end

        if (vio_env.host_mem != host0_mem)
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "VIO did not retain the pool-owned Host0 manager")
        if ((vio_env.iommu == null) ||
            (vio_env.iommu.iova_base != vio_cfg.iova_base) ||
            (vio_env.iommu.iova_limit != vio_cfg.iova_limit) ||
            (vio_env.iommu.get_iova_alloc_policy() !=
             IOMMU_IOVA_FIRST_FIT))
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "VIO environment did not apply configured IOVA aperture/policy")
        if (pcie_env.host_mem_by_root.size() != 2 ||
            pcie_env.host_mem_by_root[0] != host0_mem ||
            pcie_env.host_mem_by_root[1] != host1_mem ||
            pcie_env.host_mem != host0_mem) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "PCIe per-Root Host-memory distribution is incorrect")
        end
        if (pcie_env.rc_agents[0].rc_driver.mem != host0_mem ||
            pcie_env.rc_agents[1].rc_driver.mem != host1_mem)
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "RC responder memory handles do not match Root ownership")
        if (host0_mem.intersects_region(64'h0, 64'h1_0000_0000) ||
            host1_mem.intersects_region(64'h0, 64'h1_0000_0000))
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "PCIe environment added the legacy low 4-GiB aperture")
        if (pcie_premap_env.host_mem_by_root.size() != 2 ||
            pcie_premap_env.host_mem_by_root[0] != host2_mem ||
            pcie_premap_env.host_mem_by_root[1] != host2_mem ||
            pcie_premap_env.rc_agents[0].rc_driver.mem != host2_mem ||
            pcie_premap_env.rc_agents[1].rc_driver.mem != host2_mem) begin
            `uvm_fatal("PCIE_HOST_MEM_TEST",
                       "shared Host PREMAP bindings are incorrect")
        end

        // The write proves PREMAP created one real allocation.  Because the
        // aperture is exactly PREMAP_BYTES, a duplicate allocation reports an
        // allocator error and makes this strict test fail.
        premap_write = new[1];
        premap_write[0] = 8'hC3;
        host2_mem.write_mem(PREMAP_GPA_BASE, premap_write);
        host2_mem.read_mem(PREMAP_GPA_BASE, 1, premap_read);
        require_bytes(premap_read, premap_write,
                      "shared Host PREMAP backing");

        make_pattern(host0_write, 8'h31);
        make_pattern(host1_write, 8'hA1);
        issue_dma_write(0, host0_write);
        issue_dma_write(1, host1_write);
        #2us;

        host0_mem.read_mem(shared_dma_addr, DMA_BYTES, host0_backing);
        host1_mem.read_mem(shared_dma_addr, DMA_BYTES, host1_backing);
        require_bytes(host0_backing, host0_write,
                      "Host0 backing after EP0 MWr");
        require_bytes(host1_backing, host1_write,
                      "Host1 backing after EP1 MWr");
        issue_dma_read(0, host0_write);
        issue_dma_read(1, host1_write);

        host0_mem.free(shared_dma_addr);
        host1_mem.free(shared_dma_addr);
        host2_mem.free(PREMAP_GPA_BASE);
        `uvm_info("PCIE_HOST_MEM_TEST",
            "per-Root shared Host-memory DMA binding verified", UVM_LOW)
        phase.drop_objection(this);
    endtask

endclass : virtio_pcie_host_mem_test

`endif // VIRTIO_PCIE_HOST_MEM_TEST_SV
