`ifndef VIRTIO_REAL_DUT_IOVA_DMA_TEST_SV
`define VIRTIO_REAL_DUT_IOVA_DMA_TEST_SV

// 中文说明：这个测试只验证 REAL_DUT RC 侧的地址契约，不创建 virtio
// 设备 responder。RC 收到的 PCIe Memory Read/Write 地址是 IOVA，必须由
// IOVA-aware Host-memory proxy 翻译到共享 host_mem_manager 的 GPA。
import uvm_pkg::*;
`include "uvm_macros.svh"
import host_mem_pkg::*;
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// 中文说明：测试专用 RC driver 不启动独立 sequencer，只复用生产
// handle_request()/统一内存字段，避免这个地址契约测试意外产生 PCIe 激励。
class virtio_iova_contract_rc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(virtio_iova_contract_rc_driver)

    function new(string name = "virtio_iova_contract_rc_driver",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        // 本测试通过 responder.write() 的绑定契约验证，不启动 sequencer。
    endtask
endclass

// 中文说明：探针 driver 只记录 responder 交给它的 TLP，并暂停处理，
// 用于验证分析端异步 fork 前必须复制对象，而不是仅复制 class handle。
class virtio_iova_probe_rc_driver extends virtio_iova_contract_rc_driver;
    `uvm_component_utils(virtio_iova_probe_rc_driver)

    pcie_tl_mem_tlp seen_request;
    // 每个 worker 都保存独立的 TLP handle；测试用它覆盖多个 write() 在
    // 同一时间片内返回的场景，避免只验证单个慢 worker。
    pcie_tl_mem_tlp seen_requests[$];
    bit          request_entered;
    bit          release_request;

    function new(string name = "virtio_iova_probe_rc_driver",
                 uvm_component parent = null);
        super.new(name, parent);
        seen_request = null;
        seen_requests.delete();
        request_entered = 1'b0;
        release_request = 1'b0;
    endfunction

    virtual task handle_request(pcie_tl_tlp req);
        if (!$cast(seen_request, req)) begin
            seen_request = null;
        end else begin
            seen_requests.push_back(seen_request);
        end
        request_entered = 1'b1;
        wait (release_request);
    endtask
endclass

class virtio_real_dut_iova_dma_test extends uvm_test;
    `uvm_component_utils(virtio_real_dut_iova_dma_test)

    // 这些组件只用于验证 REAL_DUT responder 的 RC monitor 绑定边界。
    // 它们不创建设备 responder，也不伪造真实 DUT 的 DMA。
    pcie_tl_base_monitor                    rc_monitor;
    pcie_tl_if_adapter                      rc_adapter;
    virtio_iova_probe_rc_driver            rc_driver;
    virtio_pcie_real_dut_host_mem_responder real_responder;

    function new(string name = "virtio_real_dut_iova_dma_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        rc_monitor = pcie_tl_base_monitor::type_id::create("rc_monitor", this);
        rc_adapter = pcie_tl_if_adapter::type_id::create("rc_adapter", this);
        rc_driver = virtio_iova_probe_rc_driver::type_id::create(
            "rc_driver", this);
        real_responder = virtio_pcie_real_dut_host_mem_responder::type_id::create(
            "real_responder", this);
        // 监视器即使没有真实 TLP 也会启动轮询；显式绑定空闲的 TLM
        // adapter，使测试只等待 FIFO 而不会触发空句柄访问。
        rc_monitor.adapter = rc_adapter;
    endfunction

    virtual task run_phase(uvm_phase phase);
        host_mem_manager mem;
        virtio_iommu_model iommu;
        virtio_pcie_iova_host_mem_proxy proxy;
        bit [63:0] gpa_read;
        bit [63:0] gpa_write;
        bit [63:0] iova_read;
        bit [63:0] iova_write;
        bit [63:0] original_request_addr;
        bit [7:0]  original_request_byte;
        pcie_tl_mem_tlp request_orig;
        virtio_pcie_iova_host_mem_proxy proxy_before;
        byte read_data[];
        byte write_data[];
        byte backing_data[];
        pcie_tl_mem_tlp fast_request_a;
        pcie_tl_mem_tlp fast_request_b;
        bit fast_a_found;
        bit fast_b_found;
        string why;
        bit bind_ok;

        phase.raise_objection(this);

        mem = host_mem_manager::type_id::create("iova_test_mem");
        mem.set_host_id(0);
        mem.init_region(64'h0000_0001_0000_0000,
                        64'h0000_0001_0000_ffff,
                        MODE_LINEAR, 16, 8'h00);
        gpa_read = mem.alloc(64, 16);
        gpa_write = mem.alloc(64, 16);
        if ((gpa_read == '1) || (gpa_write == '1))
            `uvm_fatal("IOVA_PROXY", "Host memory allocation failed")

        iommu = virtio_iommu_model::type_id::create("iova_test_iommu");
        if (!iommu.configure_iova_aperture(
                64'h0000_0000_8000_0000,
                64'h0000_0000_8001_0000,
                IOMMU_IOVA_FIRST_FIT, why))
            `uvm_fatal("IOVA_PROXY", {"IOVA aperture setup failed: ", why})

        // BDF 0 is the PCIe root-complex identity, not a resolved endpoint
        // function.  The responder must reject it before installing an IOVA
        // requester domain.
        rc_driver.adapter = rc_adapter;
        bind_ok = real_responder.bind_function(
            rc_monitor, rc_driver, mem, why, iommu, 0, 16'h0000);
        if (bind_ok)
            `uvm_fatal("IOVA_PROXY",
                       "REAL_DUT responder accepted endpoint BDF 0")
        bind_ok = real_responder.bind_function(
            rc_monitor, rc_driver, mem, why, iommu, 0, 16'h0100);
        if (!bind_ok)
            `uvm_fatal("IOVA_PROXY", {"valid REAL_DUT bind failed: ", why})
        if (!real_responder.using_iova_translation())
            `uvm_fatal("IOVA_PROXY", "valid REAL_DUT bind did not install IOVA proxy")
        proxy_before = real_responder.iova_mem_proxy();
        bind_ok = real_responder.bind_function(
            rc_monitor, rc_driver, mem, why, iommu, 0, 16'h0100);
        if (!bind_ok || (real_responder.iova_mem_proxy() != proxy_before))
            `uvm_fatal("IOVA_PROXY",
                       "identical REAL_DUT bind was not idempotent")
        // A responder is a single-function service.  Rebinding the same
        // monitor/driver/memory with a different endpoint BDF must be
        // rejected; otherwise the IOVA requester domain can be silently
        // replaced while outstanding DMA still refers to the old function.
        bind_ok = real_responder.bind_function(
            rc_monitor, rc_driver, mem, why, iommu, 0, 16'h0101);
        if (bind_ok)
            `uvm_fatal("IOVA_PROXY",
                       "REAL_DUT responder accepted a different BDF after binding")
        // The analysis callback is asynchronous.  Mutating the monitor-owned
        // TLP after write() returns must not alter the request delivered to
        // the RC driver; a handle-only copy would fail this assertion.
        real_responder.enable();
        request_orig = pcie_tl_mem_tlp::type_id::create("request_orig");
        request_orig.kind = TLP_MEM_WR;
        request_orig.addr = 64'h0000_0000_8000_0040;
        request_orig.length = 1;
        request_orig.first_be = 4'hF;
        request_orig.last_be = 4'h0;
        request_orig.requester_id = 16'h0100;
        request_orig.payload = new[4];
        request_orig.payload = '{8'h12, 8'h34, 8'h56, 8'h78};
        original_request_addr = request_orig.addr;
        original_request_byte = request_orig.payload[0];
        real_responder.write(request_orig);
        // A join_none worker may not start until this function yields.  Yield
        // once, then mutate the monitor-owned object before the driver is
        // released; the cloned request must retain the original fields.
        #0;
        request_orig.addr = 64'h0000_0000_8000_0080;
        request_orig.payload[0] = 8'hEE;
        for (int unsigned poll = 0;
             (poll < 1000) && !rc_driver.request_entered;
             poll++)
            #1ns;
        if (!rc_driver.request_entered)
            `uvm_fatal("IOVA_PROXY",
                       $sformatf("REAL_DUT responder did not dispatch Memory Write (requests=%0d)",
                                 real_responder.request_count()))
        rc_driver.release_request = 1'b1;
        for (int unsigned poll = 0;
             (poll < 1000) && (real_responder.inflight_count() != 0);
             poll++)
            #1ns;
        if (real_responder.inflight_count() != 0)
            `uvm_fatal("IOVA_PROXY", "REAL_DUT responder did not quiesce probe request")
        if ((rc_driver.seen_request == request_orig) ||
            (rc_driver.seen_request == null) ||
            (rc_driver.seen_request.addr != original_request_addr) ||
            (rc_driver.seen_request.payload[0] != original_request_byte))
            `uvm_fatal("IOVA_PROXY",
                       "REAL_DUT responder did not clone asynchronous DMA TLP")

        // 两个请求都在 write() 返回前完成 clone，随后原始 monitor handle
        // 立即被修改。#0 只让 join_none worker 获得执行机会；断言必须仍能
        // 找到两个原始地址/载荷，覆盖“快速返回 + 多个异步 worker”的边界。
        rc_driver.seen_requests.delete();
        rc_driver.release_request = 1'b1;
        fast_request_a = pcie_tl_mem_tlp::type_id::create("fast_request_a");
        fast_request_b = pcie_tl_mem_tlp::type_id::create("fast_request_b");
        fast_request_a.kind = TLP_MEM_WR;
        fast_request_b.kind = TLP_MEM_WR;
        fast_request_a.addr = 64'h0000_0000_8000_0100;
        fast_request_b.addr = 64'h0000_0000_8000_0120;
        fast_request_a.length = 1;
        fast_request_b.length = 1;
        fast_request_a.first_be = 4'hF;
        fast_request_b.first_be = 4'hF;
        fast_request_a.last_be = 4'h0;
        fast_request_b.last_be = 4'h0;
        fast_request_a.requester_id = 16'h0100;
        fast_request_b.requester_id = 16'h0100;
        fast_request_a.payload = new[4];
        fast_request_b.payload = new[4];
        fast_request_a.payload = '{8'hA1, 8'hA2, 8'hA3, 8'hA4};
        fast_request_b.payload = '{8'hB1, 8'hB2, 8'hB3, 8'hB4};
        real_responder.write(fast_request_a);
        real_responder.write(fast_request_b);
        fast_request_a.addr = 64'h0000_0000_8000_0180;
        fast_request_b.addr = 64'h0000_0000_8000_01A0;
        fast_request_a.payload[0] = 8'hEE;
        fast_request_b.payload[0] = 8'hDD;
        #0;
        for (int unsigned poll = 0;
             (poll < 1000) && (real_responder.inflight_count() != 0);
             poll++)
            #1ns;
        if (real_responder.inflight_count() != 0 ||
            rc_driver.seen_requests.size() != 2)
            `uvm_fatal("IOVA_PROXY",
                       "fast asynchronous requests were not fully dispatched")
        fast_a_found = 1'b0;
        fast_b_found = 1'b0;
        foreach (rc_driver.seen_requests[index]) begin
            if ((rc_driver.seen_requests[index].addr ==
                 64'h0000_0000_8000_0100) &&
                (rc_driver.seen_requests[index].payload[0] == 8'hA1))
                fast_a_found = 1'b1;
            if ((rc_driver.seen_requests[index].addr ==
                 64'h0000_0000_8000_0120) &&
                (rc_driver.seen_requests[index].payload[0] == 8'hB1))
                fast_b_found = 1'b1;
        end
        if (!fast_a_found || !fast_b_found)
            `uvm_fatal("IOVA_PROXY",
                       "fast worker observed a mutated or aliased TLP handle")
        real_responder.disable_responder();

        iova_read = iommu.map_for_host(0, 16'h0100, gpa_read, 64,
                                       DMA_TO_DEVICE);
        iova_write = iommu.map_for_host(0, 16'h0100, gpa_write, 64,
                                        DMA_FROM_DEVICE);
        if ((iova_read == '1) || (iova_write == '1) ||
            (iova_read == gpa_read) || (iova_write == gpa_write))
            `uvm_fatal("IOVA_PROXY", "test did not obtain distinct IOVA mappings")

        proxy = virtio_pcie_iova_host_mem_proxy::type_id::create("iova_proxy");
        if (!proxy.configure(mem, iommu, 0, 16'h0100, why))
            `uvm_fatal("IOVA_PROXY", {"proxy setup failed: ", why})

        write_data = new[4];
        write_data = '{8'h11, 8'h22, 8'h33, 8'h44};
        mem.write_mem(gpa_read, write_data);
        proxy.read_mem(iova_read, 4, read_data);
        if ((read_data.size() != 4) || (read_data[0] != 8'h11) ||
            (read_data[1] != 8'h22) || (read_data[2] != 8'h33) ||
            (read_data[3] != 8'h44))
            `uvm_fatal("IOVA_PROXY", "IOVA read did not return GPA backing bytes")

        write_data = '{8'ha5, 8'h5a, 8'hc3, 8'h3c};
        proxy.write_mem(iova_write, write_data);
        mem.read_mem(gpa_write, 4, backing_data);
        if ((backing_data.size() != 4) || (backing_data[0] != 8'ha5) ||
            (backing_data[1] != 8'h5a) || (backing_data[2] != 8'hc3) ||
            (backing_data[3] != 8'h3c))
            `uvm_fatal("IOVA_PROXY", "IOVA write did not update GPA backing bytes")

        if ((proxy.read_count() != 1) || (proxy.write_count() != 1) ||
            (proxy.translation_fault_count() != 0))
            `uvm_fatal("IOVA_PROXY", "proxy translation statistics are incorrect")

        iommu.unmap_for_host(0, 16'h0100, iova_read);
        iommu.unmap_for_host(0, 16'h0100, iova_write);
        mem.free(gpa_read);
        mem.free(gpa_write);
        mem.leak_check();
        iommu.leak_check();
        `uvm_info("IOVA_PROXY", "REAL_DUT IOVA/GPA proxy test PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass

`endif
