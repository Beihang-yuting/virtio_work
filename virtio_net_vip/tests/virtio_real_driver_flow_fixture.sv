`ifndef VIRTIO_REAL_DRIVER_FLOW_FIXTURE_SV
`define VIRTIO_REAL_DRIVER_FLOW_FIXTURE_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// Shared construction for tests which claim the real virtio-pci flow.  The
// fixture deliberately has no BAR or BDF constants: those values are read
// from the frozen dpu-common snapshot after the DPU environment resolves it.
class virtio_real_driver_flow_fixture extends uvm_component;
    `uvm_component_utils(virtio_real_driver_flow_fixture)

    dpu_device_env             device_env;
    virtio_net_env             m_virtio_env;
    pcie_tl_env                m_pcie_env;
    virtio_test_device_builder device_builder;
    dpu_device_env_config      device_cfg;
    virtio_net_env_config      virtio_cfg;
    pcie_tl_env_config         pcie_cfg;
    host_mem_pool              host_mem_owners;
    virtio_tlm_completion_adapter tlm_adapter;
    virtio_pcie_dut_responder  responder;
    // Optional REAL_DUT RC service.  This is not a device model: it only
    // services EP-originated MemRd/MemWr against shared Host memory.
    virtio_pcie_real_dut_host_mem_responder host_mem_responder;
    bit                         real_dut_host_mem_responder_enable;

    // 真实 DUT 模式的物理 PCIe 传输接口。该句柄由真实 DUT 顶层通过
    // config_db 发布，fixture 只负责把它显式交给外部 pcie_work adapter；
    // pcie_tl_if_adapter 本身不会自动从 config_db 获取 VIF。
    virtual pcie_tl_if         pcie_vif;
    // The plain TL interface has one physical direction.  A real endpoint
    // that originates DMA/completions needs a separate return-direction link,
    // or a pcie_work FULL_VIP/backend provider that supplies both adapters.
    // Never bind one signal bundle to both active directions silently.
    virtual pcie_tl_if         pcie_ep_vif;

    protected dpu_device_snapshot  m_device_snapshot;
    protected dpu_resource_snapshot m_resource_snapshot;
    protected host_mem_manager      m_host_mem;
    protected dpu_function_key_t    m_function_key;
    protected dpu_pcie_function_id_t m_pcie_id;
    protected dpu_bar_pair_lease_t  m_bars[$];
    protected virtio_function_instance m_selected_function;
    protected bit                    m_endpoint_ready;
    protected bit                    m_flow_ready;
    protected bit                    m_driver_flow_started;
    protected bit                    m_responder_bound;
    protected bit                    m_host_mem_responder_bound;
    protected bit                    m_pcie_vif_bound;
    // PCIe/virtio bind is a separate readiness condition from snapshot
    // freezing.  In REAL_DUT mode a missing bind must fail at build_flow(),
    // rather than letting a later queue operation look like a DUT failure.
    protected bit                    m_pcie_path_bound;
    protected bit                    m_host_mem_responder_conflict;
    protected int unsigned            m_poll_timeout_ns;

    // pcie_work's plain pcie_tl_if is a single valid/ready direction.  The
    // fixture therefore treats a REAL_DUT physical link as explicitly bound
    // only after both RC->EP and EP->RC interfaces have been supplied.  Do
    // not infer a backend-provider capability from pcie_tl_env: the remote
    // pcie_work API has no such field, and silently accepting one interface
    // would lose endpoint-originated DMA/completion traffic.

    localparam bit [7:0] COMMON_CAP_OFFSET = 8'h50;
    localparam bit [7:0] NOTIFY_CAP_OFFSET = 8'h64;
    localparam bit [7:0] ISR_CAP_OFFSET    = 8'h7c;
    localparam bit [7:0] DEVICE_CAP_OFFSET = 8'h8c;
    localparam bit [7:0] MSIX_CAP_OFFSET   = 8'h9c;
    localparam bit [31:0] COMMON_OFFSET = 32'h0;
    localparam bit [31:0] COMMON_LENGTH = 32'h40;
    localparam bit [31:0] NOTIFY_OFFSET = 32'h0;
    localparam bit [31:0] NOTIFY_LENGTH = 32'h1000;
    localparam bit [31:0] ISR_OFFSET = 32'h1000;
    localparam bit [31:0] DEVICE_OFFSET = 32'h2000;
    localparam bit [31:0] DEVICE_LENGTH = 32'h100;
    localparam bit [31:0] MSIX_TABLE_OFFSET = 32'h0;
    localparam bit [31:0] MSIX_PBA_OFFSET = 32'h8000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        m_endpoint_ready = 0;
        m_flow_ready = 0;
        m_driver_flow_started = 0;
        m_responder_bound = 0;
        m_host_mem_responder_bound = 0;
        m_pcie_vif_bound = 0;
        m_pcie_path_bound = 0;
        m_host_mem_responder_conflict = 0;
        m_poll_timeout_ns = 1000;
        m_selected_function = null;
        real_dut_host_mem_responder_enable = 0;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_function_cfg pf_cfg;
        dpu_function_key_t vio_devices[$];
        int responder_enable_arg;

        super.build_phase(phase);

        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        void'(device_builder.add_host_domain(0, 0));
        pf_cfg = device_builder.add_pf(0, 0, 0);
        device_builder.add_real_dut_bars(pf_cfg);
        void'(device_builder.allow_vio_service(pf_cfg));
        vio_devices.push_back(pf_cfg.key);
        // The shared real-flow fixture provisions two queue pairs so callers
        // can exercise the normal RX0/TX1 and RX2/TX3 layout.  Individual
        // tests may still set up only the queues they need.
        void'(device_builder.add_fixed_vio_request(0, vio_devices, 2));
        device_builder.select_af(pf_cfg);

        virtio_cfg = virtio_net_env_config::type_id::create("virtio_cfg");
        virtio_cfg.default_num_pairs = 2;
        virtio_cfg.default_queue_size = 256;
        virtio_cfg.default_vq_type = VQ_SPLIT;
        virtio_cfg.default_driver_features = '1;
        virtio_cfg.default_rx_mode = RX_MODE_MERGEABLE;
        virtio_cfg.default_irq_mode = IRQ_MSIX_PER_QUEUE;
        virtio_cfg.default_napi_budget = 64;
        virtio_cfg.mem_base = 64'h0000_0001_0000_0000;
        virtio_cfg.mem_end = 64'h0000_0001_FFFF_FFFF;
        virtio_cfg.host_mem_policy = HOST_MEM_RANDOM;
        virtio_cfg.iommu_strict = 1;
        virtio_cfg.scb_enable = 1;
        virtio_cfg.cov_enable = 0;
        begin
            string mode_why;
            if (!virtio_cfg.apply_plusargs(mode_why)) begin
                `uvm_fatal("REAL_FLOW", {"invalid virtio execution mode: ",
                                           mode_why})
                return;
            end
        end

        // The RC-side Host-memory service is opt-in.  A platform with a
        // complete PCIe RC/FULL-VIP backend must keep it disabled to avoid
        // duplicate Completions; a plain two-link pcie_tl_if integration can
        // enable it with +VIRTIO_REAL_DUT_HOST_MEM_RESPONDER=1.
        responder_enable_arg = 0;
        if ($value$plusargs("VIRTIO_REAL_DUT_HOST_MEM_RESPONDER=%d",
                           responder_enable_arg))
            real_dut_host_mem_responder_enable = (responder_enable_arg != 0);
        void'($value$plusargs("VIRTIO_FLOW_TIMEOUT_NS=%d", m_poll_timeout_ns));
        if (m_poll_timeout_ns == 0)
            m_poll_timeout_ns = 1;

        // REAL_DUT 的 VIF 由外部 DUT 顶层发布。兼容两个约定名称：新的
        // ``pcie_tl_vif`` 是本 fixture 的明确契约，``vif`` 便于接入已有
        // pcie_work testbench。注意 pcie_work 的基础 adapter 不会自行执行
        // config_db get，后续仍须在 connect/end-of-elaboration 显式赋值。
        pcie_vif = null;
        pcie_ep_vif = null;
        void'(uvm_config_db#(virtual pcie_tl_if)::get(
            this, "", "pcie_tl_rc_vif", pcie_vif));
        void'(uvm_config_db#(virtual pcie_tl_if)::get(
            this, "", "pcie_tl_vif", pcie_vif));
        if (pcie_vif == null)
            void'(uvm_config_db#(virtual pcie_tl_if)::get(
                this, "", "vif", pcie_vif));
        void'(uvm_config_db#(virtual pcie_tl_if)::get(
            this, "", "pcie_tl_ep_vif", pcie_ep_vif));

        host_mem_owners = host_mem_pool::type_id::create("host_mem_owners");
        if (!host_mem_owners.create_host(
                virtio_cfg.host_id, virtio_cfg.mem_base, virtio_cfg.mem_end,
                MODE_BUDDY, DEFAULT_MIN_GRANULE,
                virtio_cfg.host_mem_policy)) begin
            `uvm_fatal("REAL_FLOW", "could not create shared Host 0 memory")
            return;
        end
        virtio_cfg.host_mem_pool_binding = host_mem_owners;

        device_cfg = device_builder.make_env_config();
        device_cfg.host_mem_pool_ref = host_mem_owners;
        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "device_env.virtio_env", "cfg", virtio_cfg);
        m_virtio_env = virtio_net_env::type_id::create(
            "virtio_env", device_env);

        // Completion adapter and endpoint responder are MODEL-only.  Keeping
        // them out of the REAL_DUT hierarchy prevents a passive PCIe monitor
        // from accidentally creating a second device-side implementation.
        if (virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) begin
            tlm_adapter = virtio_tlm_completion_adapter::type_id::create(
                "tlm_adapter");
            tlm_adapter.install_factory_overrides();
        end else begin
            tlm_adapter = null;
            host_mem_responder =
                virtio_pcie_real_dut_host_mem_responder::type_id::create(
                    "host_mem_responder", this);
        end
        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_cfg.if_mode = (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ?
                            SV_IF_MODE : TLM_MODE;
        pcie_cfg.rc_agent_enable = 1;
        pcie_cfg.ep_agent_enable = 1;
        pcie_cfg.rc_is_active = UVM_ACTIVE;
        pcie_cfg.ep_is_active = (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ?
                                UVM_PASSIVE : UVM_ACTIVE;
        pcie_cfg.ep_auto_response =
            (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ? 1'b0 : 1'b1;
        pcie_cfg.infinite_credit = 1;
        pcie_cfg.scb_enable = 1;
        pcie_cfg.cov_enable = 0;
        pcie_cfg.response_delay_min = 0;
        pcie_cfg.response_delay_max = 0;
        pcie_cfg.cpl_timeout_ns = 100000;
        pcie_cfg.use_unified_mem = 1;
        pcie_cfg.mem_access_mode = PCIE_TL_MEM_PER_BUFFER;
        begin
            string mem_why;
            host_mem_manager root_mem;
            root_mem = host_mem_owners.get_host(virtio_cfg.host_id);
            if ((root_mem == null) || !pcie_cfg.bind_host_memory(
                    0, virtio_cfg.host_id, root_mem, mem_why)) begin
                `uvm_fatal("REAL_FLOW", {"could not bind PCIe Host memory: ", mem_why})
            end
            uvm_config_db#(host_mem_api)::set(
                this, "pcie_env", "dev_mem_0", root_mem);
        end
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "pcie_env", "cfg", pcie_cfg);
        m_pcie_env = pcie_tl_env::type_id::create("pcie_env", this);
        // REAL_DUT 模式只保留 PCIe/virtio 观察路径，绝不创建主动模型。
        if (virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL)
            responder = virtio_pcie_dut_responder::type_id::create(
                "responder", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if ((m_virtio_env == null) || (m_pcie_env == null) ||
            (m_pcie_env.rc_agent == null) ||
            (m_pcie_env.ep_agent == null) ||
            (m_pcie_env.rc_agent.monitor == null) ||
            (m_pcie_env.ep_agent.monitor == null) ||
            (m_pcie_env.rc_agent.sequencer == null)) begin
            `uvm_error("REAL_FLOW",
                       "fixture PCIe RC/EP agents or monitors are unavailable")
            return;
        end

        // The remote pcie_work adapter exposes ``vif`` as a public field but
        // does not fetch it from uvm_config_db.  Bind every adapter explicitly
        // before any SV_IF run-phase task can sample or drive the interface.
        if (pcie_cfg.if_mode == SV_IF_MODE) begin
            if (!bind_pcie_vif()) begin
                `uvm_error("REAL_FLOW",
                           "REAL_DUT requires separate RC->EP and EP->RC VIFs")
                return;
            end
        end
        if (!m_virtio_env.bind_pcie(
            m_pcie_env.rc_agent.sequencer, tlm_adapter,
            m_pcie_env.rc_agent.monitor, m_pcie_env.ep_agent.monitor))
            `uvm_error("REAL_FLOW", "failed to bind virtio PCIe path")
        else
            m_pcie_path_bound = 1;

        // Analysis connections must be established during connect_phase.  The
        // endpoint image itself is installed later from the frozen snapshot,
        // but all identity/shared handles needed by the responder already
        // exist here.
        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) &&
            (responder != null) && (host_mem_owners != null) &&
            (m_virtio_env.iommu != null) &&
            (m_pcie_env.ep_agent.ep_driver != null) &&
            (m_virtio_env.function_instances.size() != 0)) begin
            string responder_why;
            m_host_mem = host_mem_owners.get_host(virtio_cfg.host_id);
            m_selected_function = m_virtio_env.function_instances[0];
            if ((m_host_mem != null) && (m_selected_function != null) &&
                responder.bind_function(
                    m_selected_function.driver_agent.monitor,
                    m_selected_function.transport,
                    m_selected_function.vq_mgr,
                    m_host_mem,
                    m_virtio_env.iommu,
                    m_pcie_env.ep_agent.ep_driver,
                    responder_why)) begin
                m_responder_bound = 1;
            end else begin
                `uvm_error("REAL_FLOW", {"early responder bind failed: ",
                                          responder_why})
            end
        end

        // REAL_DUT Host-memory responder must wait for the frozen snapshot's
        // authoritative BDF; it is bound in end_of_elaboration_phase.
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        string why;
        dpu_bar_pair_lease_t af_bar0;
        dpu_function_key_t af_key;
        super.end_of_elaboration_phase(phase);
        if ((device_env == null) || (m_pcie_env == null) ||
            (m_pcie_env.ep_agent == null) ||
            (m_pcie_env.cfg_mgr == null)) begin
            `uvm_error("REAL_FLOW",
                       "fixture DPU/PCIe endpoint handles are unavailable")
            return;
        end
        m_device_snapshot = device_env.get_snapshot();
        m_resource_snapshot = device_env.get_resource_snapshot();
        if ((m_device_snapshot == null) || (m_resource_snapshot == null) ||
            !m_device_snapshot.is_frozen() || !m_resource_snapshot.is_frozen())
            return;
        if (!m_device_snapshot.get_expected_af(af_key, af_bar0, why))
            return;
        m_function_key = af_key;
        if (!m_device_snapshot.get_pcie_id(m_function_key, m_pcie_id, why))
            return;
        // Resolve the function identity from the frozen snapshot for every
        // execution mode.  Previously this handle was populated only while
        // binding the MODEL responder (or the optional local REAL_DUT
        // responder), so a REAL_DUT run using an external pcie_work bridge
        // had a valid PCIe path but no semantic monitor/resource client.
        // Queue mapping helpers and passive observers must use the same BDF
        // selected by the DPU snapshot, never function_instances[0].
        m_selected_function = null;
        foreach (m_virtio_env.function_instances[index]) begin
            if ((m_virtio_env.function_instances[index] != null) &&
                (m_virtio_env.function_instances[index].bdf == m_pcie_id.bdf)) begin
                m_selected_function = m_virtio_env.function_instances[index];
                break;
            end
        end
        if (m_selected_function == null) begin
            `uvm_error("REAL_FLOW", {
                "no virtio function resolved for frozen BDF 0x",
                $sformatf("%04h", m_pcie_id.bdf)})
            return;
        end
        m_bars.delete();
        if (!m_device_snapshot.list_bars(m_function_key, m_bars, why) ||
            (m_bars.size() != 3))
            return;
        // MODEL mode owns a local endpoint image.  In REAL_DUT the endpoint
        // driver is passive/absent and all config/BAR responses come from RTL.
        if (virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) begin
            if ((m_pcie_env.ep_agent.ep_driver == null) ||
                !install_endpoint_image(why)) begin
                `uvm_error("REAL_FLOW", {"endpoint image setup failed: ", why})
                return;
            end
        end
        if (host_mem_owners == null) begin
            `uvm_error("REAL_FLOW", "shared Host memory pool is unavailable")
            return;
        end
        m_host_mem = host_mem_owners.get_host(virtio_cfg.host_id);
        if (m_host_mem == null) begin
            `uvm_error("REAL_FLOW", "Host 0 manager was not published")
            return;
        end
        // Optional RC service.  The proxy receives the same IOMMU object used
        // by the driver when it authored descriptors, so PCIe IOVA accesses
        // resolve to the shared Host GPA backing without a second allocator.
        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) &&
            real_dut_host_mem_responder_enable &&
            (host_mem_responder != null)) begin
            string host_responder_why;
            bit [15:0] responder_bdf;
            if (m_pcie_env.bridge_required) begin
                m_host_mem_responder_conflict = 1;
                `uvm_error("REAL_FLOW",
                    {"REAL_DUT Host-memory responder conflicts with the ",
                     "pcie_work backend bridge; disable the plusarg"})
            end else begin
                responder_bdf = '0;
                if ((m_selected_function != null) &&
                    (m_selected_function.transport != null) &&
                    m_selected_function.transport.pcie_id_valid)
                    responder_bdf = m_selected_function.transport.bdf;
                if ((m_pcie_env.rc_agent.monitor == null) ||
                    (m_pcie_env.rc_agent.rc_driver == null) ||
                    (m_virtio_env.iommu == null) ||
                    (responder_bdf == 16'h0) ||
                    !host_mem_responder.bind_function(
                        m_pcie_env.rc_agent.monitor,
                        m_pcie_env.rc_agent.rc_driver,
                        m_host_mem,
                        host_responder_why,
                        m_virtio_env.iommu,
                        virtio_cfg.host_id,
                        responder_bdf)) begin
                    `uvm_error("REAL_FLOW", {
                        "REAL_DUT Host-memory responder bind failed: ",
                        host_responder_why})
                end else begin
                    host_mem_responder.set_requester_filter(1'b1, responder_bdf);
                    host_mem_responder.enable();
                    m_host_mem_responder_bound = 1;
                end
            end
        end
        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) &&
            (responder != null)) begin
            virtio_function_instance selected_function;
            foreach (m_virtio_env.function_instances[index]) begin
                if ((m_virtio_env.function_instances[index] != null) &&
                    (m_virtio_env.function_instances[index].bdf == m_pcie_id.bdf)) begin
                    selected_function = m_virtio_env.function_instances[index];
                    break;
                end
            end
            m_selected_function = selected_function;
            if ((selected_function == null) ||
                (!m_responder_bound && !responder.bind_function(
                    selected_function.driver_agent.monitor,
                    selected_function.transport,
                    selected_function.vq_mgr,
                    m_host_mem,
                    m_virtio_env.iommu,
                    m_pcie_env.ep_agent.ep_driver,
                    why))) begin
                `uvm_error("REAL_FLOW", {"responder bind failed: ", why})
                return;
            end
        end
        if (m_pcie_env.ep_agent.ep_driver != null)
            uvm_config_db#(uvm_object)::set(null, "", "ep_driver_ref",
                m_pcie_env.ep_agent.ep_driver);
        uvm_config_db#(uvm_object)::set(null, "", "cfg_mgr_ref",
            m_pcie_env.cfg_mgr);
        m_endpoint_ready = 1;
    endfunction

    function bit build_flow(output string why);
        why = "";
        if (!m_endpoint_ready) begin
            why = (virtio_cfg != null) &&
                  (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ?
                  "REAL_DUT endpoint identity/interface was not prepared" :
                  "endpoint image was not derived from the frozen snapshot";
            return 0;
        end
        if (!snapshot_is_frozen()) begin
            why = "fixture snapshots are not frozen";
            return 0;
        end
        if (!m_pcie_path_bound) begin
            why = "virtio PCIe path was not bound";
            return 0;
        end
        if ((virtio_cfg != null) &&
            (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT)) begin
            if (m_host_mem_responder_conflict) begin
                why = "REAL_DUT Host-memory responder conflicts with pcie_work backend bridge";
                return 0;
            end
            if (!m_pcie_vif_bound) begin
                why = "REAL_DUT requires separate RC->EP and EP->RC VIFs";
                return 0;
            end
            // A plain two-link pcie_work setup has no automatic EP->RC
            // unified-memory responder.  Either the explicit shared-memory
            // responder or an external FULL-VIP/backend bridge must be
            // present before a real driver flow is considered runnable.
            if (!m_host_mem_responder_bound &&
                ((m_pcie_env == null) || !m_pcie_env.bridge_required)) begin
                why = {"REAL_DUT has no EP->RC Host-memory responder; enable ",
                       "+VIRTIO_REAL_DUT_HOST_MEM_RESPONDER=1 or provide a ",
                       "pcie_work backend bridge"};
                return 0;
            end
        end
        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) &&
            real_dut_host_mem_responder_enable &&
            !m_host_mem_responder_bound) begin
            why = "REAL_DUT Host-memory responder was enabled but not bound";
            return 0;
        end
        if ((m_host_mem == null) || (m_virtio_env == null) ||
            (m_pcie_env == null)) begin
            why = "fixture shared handles are incomplete";
            return 0;
        end
        m_flow_ready = 1;
        return 1;
    endfunction

    function bit snapshot_is_frozen();
        return (m_device_snapshot != null) &&
               (m_resource_snapshot != null) &&
               m_device_snapshot.is_frozen() &&
               m_resource_snapshot.is_frozen() &&
               m_resource_snapshot.references_device_snapshot(m_device_snapshot);
    endfunction

    function bit [15:0] function_bdf();
        return m_pcie_id.bdf;
    endfunction

    function int unsigned bar_count();
        return m_bars.size();
    endfunction

    function host_mem_manager host_mem();
        return m_host_mem;
    endfunction

    function virtio_net_env virtio_env();
        return m_virtio_env;
    endfunction

    function pcie_tl_env pcie_env();
        return m_pcie_env;
    endfunction

    function dpu_device_snapshot device_snapshot();
        return m_device_snapshot;
    endfunction

    function dpu_resource_snapshot resource_snapshot();
        return m_resource_snapshot;
    endfunction

    function virtio_pcie_dut_responder dut_responder();
        return responder;
    endfunction

    function virtio_pcie_real_dut_host_mem_responder host_mem_dma_responder();
        return host_mem_responder;
    endfunction

    // Read-only accessors used by mode-aware contract tests.  The monitor is
    // the semantic observer connected to both PCIe directions; callers must
    // not use a MODEL responder counter as evidence for REAL_DUT traffic.
    function virtio_monitor function_monitor();
        if (m_selected_function != null &&
            m_selected_function.driver_agent != null)
            return m_selected_function.driver_agent.monitor;
        return null;
    endfunction

    // Resolve direction-specific local queue IDs from the imported frozen
    // service binding.  Tests must not infer TX=1/TX=3 when a future DPU
    // placement deliberately assigns arbitrary local IDs.
    function bit tx_queue_id_for_pair(
        input int unsigned pair_index,
        output int unsigned queue_id,
        output string why
    );
        virtio_qpair_mapping_t mappings[$];
        queue_id = '1;
        why = "";
        if ((m_selected_function == null) ||
            (m_selected_function.resource_client == null)) begin
            why = "selected function has no resource client";
            return 0;
        end
        m_selected_function.resource_client.list_qpair_mappings(mappings);
        if (pair_index >= mappings.size()) begin
            why = $sformatf("TX qpair index %0d is outside mapping count %0d",
                           pair_index, mappings.size());
            return 0;
        end
        queue_id = mappings[pair_index].tx_virtqueue_id;
        return 1;
    endfunction

    function bit rx_queue_id_for_pair(
        input int unsigned pair_index,
        output int unsigned queue_id,
        output string why
    );
        virtio_qpair_mapping_t mappings[$];
        queue_id = '1;
        why = "";
        if ((m_selected_function == null) ||
            (m_selected_function.resource_client == null)) begin
            why = "selected function has no resource client";
            return 0;
        end
        m_selected_function.resource_client.list_qpair_mappings(mappings);
        if (pair_index >= mappings.size()) begin
            why = $sformatf("RX qpair index %0d is outside mapping count %0d",
                           pair_index, mappings.size());
            return 0;
        end
        queue_id = mappings[pair_index].rx_virtqueue_id;
        return 1;
    endfunction

    function bit real_dut_link_ready();
        return (virtio_cfg != null) &&
               (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) &&
               m_pcie_vif_bound && m_pcie_path_bound;
    endfunction

    function bit host_mem_responder_bound();
        return m_host_mem_responder_bound;
    endfunction

    // Explicit opt-in hook for wrappers that cannot pass the plusarg before
    // build_phase.  Binding is idempotent for the same monitor/driver/memory
    // tuple and never creates a virtio device responder.
    function bit enable_real_dut_host_mem_responder(output string why);
        why = "";
        if ((virtio_cfg == null) ||
            (virtio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT)) begin
            why = "Host-memory responder can only be enabled in REAL_DUT mode";
            return 0;
        end
        if (host_mem_responder == null) begin
            why = "REAL_DUT Host-memory responder component is unavailable";
            return 0;
        end
        if (!m_host_mem_responder_bound) begin
            if ((m_pcie_env == null) || (m_pcie_env.rc_agent == null) ||
                (m_pcie_env.rc_agent.monitor == null) ||
                (m_pcie_env.rc_agent == null) ||
                (m_pcie_env.rc_agent.rc_driver == null) ||
                (host_mem_owners == null)) begin
                why = "REAL_DUT PCIe monitor/RC/memory handles are unavailable";
                return 0;
            end
            m_host_mem = host_mem_owners.get_host(virtio_cfg.host_id);
            if ((m_selected_function == null) &&
                (m_virtio_env != null) &&
                (m_virtio_env.function_instances.size() != 0))
                m_selected_function = m_virtio_env.function_instances[0];
            if ((m_selected_function == null) ||
                (m_selected_function.transport == null) ||
                !m_selected_function.transport.pcie_id_valid) begin
                why = "REAL_DUT function has no resolved PCIe identity";
                return 0;
            end
            if (m_selected_function.transport.bdf == 16'h0000) begin
                why = "REAL_DUT function resolved the invalid endpoint BDF 0";
                return 0;
            end
            if (!host_mem_responder.bind_function(
                    m_pcie_env.rc_agent.monitor,
                    m_pcie_env.rc_agent.rc_driver,
                    m_host_mem, why,
                    m_virtio_env.iommu,
                    virtio_cfg.host_id,
                    m_selected_function.transport.bdf))
                return 0;
            m_host_mem_responder_bound = 1;
        end
        if (snapshot_is_frozen())
            host_mem_responder.set_requester_filter(1'b1, m_pcie_id.bdf);
        host_mem_responder.enable();
        real_dut_host_mem_responder_enable = 1;
        return 1;
    endfunction

    task disable_real_dut_host_mem_responder();
        real_dut_host_mem_responder_enable = 0;
        if (host_mem_responder != null)
            host_mem_responder.shutdown();
    endtask

    function virtio_execution_mode_e execution_mode();
        return virtio_cfg.execution_mode;
    endfunction

    // Optional direct setter for a top-level test/wrapper that obtains the
    // interface after this component's build_phase.  Normal integrations
    // should publish ``pcie_tl_vif`` before run_test() instead.
    function void set_pcie_vif(virtual pcie_tl_if vif);
        pcie_vif = vif;
        // A wrapper may obtain the VIF after build_phase.  If the PCIe env
        // already exists, bind immediately; otherwise connect_phase will
        // perform the normal binding once both directions are available.
        if ((m_pcie_env != null) && (pcie_cfg != null) &&
            (pcie_cfg.if_mode == SV_IF_MODE))
            void'(bind_pcie_vif());
    endfunction

    function void set_pcie_vifs(
        virtual pcie_tl_if rc_vif,
        virtual pcie_tl_if ep_vif
    );
        pcie_vif = rc_vif;
        pcie_ep_vif = ep_vif;
        if ((m_pcie_env != null) && (pcie_cfg != null) &&
            (pcie_cfg.if_mode == SV_IF_MODE))
            void'(bind_pcie_vif());
    endfunction

    function bit model_responder_active();
        return (responder != null) && responder.running();
    endfunction

    protected function bit bind_pcie_vif();
        if ((pcie_vif == null) || (pcie_ep_vif == null))
            return 0;

        // Non-switch configurations use the scalar aliases.  Arrays are also
        // assigned so the same fixture remains safe if pcie_work is later
        // configured with multiple RC/EP links.
        if (m_pcie_env.rc_adapter != null)
            m_pcie_env.rc_adapter.vif = pcie_vif;
        foreach (m_pcie_env.rc_adapters[index]) begin
            if (m_pcie_env.rc_adapters[index] != null)
                m_pcie_env.rc_adapters[index].vif = pcie_vif;
        end
        if (m_pcie_env.ep_adapter != null)
            m_pcie_env.ep_adapter.vif = pcie_ep_vif;
        foreach (m_pcie_env.ep_adapters[index]) begin
            if (m_pcie_env.ep_adapters[index] != null)
                m_pcie_env.ep_adapters[index].vif = pcie_ep_vif;
        end
        m_pcie_vif_bound = (m_pcie_env.rc_adapter != null) &&
                           (m_pcie_env.ep_adapter != null);
        return m_pcie_vif_bound;
    endfunction

    // Resolve the one snapshot function represented by this fixture.  The
    // identity comes from the frozen DPU snapshot/BDF, never from a test
    // supplied array index or raw PCIe address.
    protected function virtio_function_instance selected_function(
        output string why
    );
        why = "";
        if (m_selected_function != null)
            return m_selected_function;
        if ((m_virtio_env == null) ||
            (m_virtio_env.function_instances.size() == 0)) begin
            why = "virtio environment has no function instances";
            return null;
        end
        foreach (m_virtio_env.function_instances[index]) begin
            if ((m_virtio_env.function_instances[index] != null) &&
                (m_virtio_env.function_instances[index].bdf == m_pcie_id.bdf)) begin
                m_selected_function = m_virtio_env.function_instances[index];
                return m_selected_function;
            end
        end
        why = $sformatf("no virtio function resolved for BDF 0x%04h",
                       m_pcie_id.bdf);
        return null;
    endfunction

    // Run the production PCI transport initialization through capability
    // discovery, reset/ACK/DRIVER, feature negotiation, queue discovery,
    // MSI-X setup, and DRIVER_OK.  Ring allocation is intentionally deferred
    // to setup_queue(), which is the sole atomic-op queue allocator.
    virtual task start_driver_flow(ref bit ok);
        virtio_function_instance function_instance;
        virtio_driver_config_t driver_cfg;
        bit init_ok;
        bit [7:0] status;
        string why;

        ok = 0;
        if (!m_flow_ready) begin
            `uvm_error("REAL_FLOW", "start_driver_flow called before build_flow")
            return;
        end
        if (m_driver_flow_started) begin
            `uvm_error("REAL_FLOW",
                       "start_driver_flow called while a flow is already active")
            return;
        end
        function_instance = selected_function(why);
        if (function_instance == null) begin
            `uvm_error("REAL_FLOW", why)
            return;
        end
        if ((function_instance.transport == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null)) begin
            `uvm_error("REAL_FLOW",
                       "selected function has no bound transport/driver ops")
            return;
        end

        driver_cfg = function_instance.drv_cfg;
        if (driver_cfg.num_queue_pairs == 0) begin
            `uvm_error("REAL_FLOW", "driver configuration requests zero queue pairs")
            return;
        end

        function_instance.transport.discover_and_init_bars();
        function_instance.transport.full_init_sequence(
            driver_cfg.driver_features, driver_cfg.num_queue_pairs, init_ok);
        if (!init_ok) begin
            `uvm_error("REAL_FLOW", "PCI transport full_init_sequence failed")
            return;
        end
        function_instance.transport.read_device_status(status);
        if (!(status & DEV_STATUS_DRIVER_OK)) begin
            `uvm_error("REAL_FLOW", $sformatf(
                "transport did not reach DRIVER_OK (status=0x%02h)", status))
            return;
        end
        // Keep the shared FSM's lifecycle view consistent for callers that
        // inspect it, without invoking virtio_auto_fsm.full_init(), whose
        // queue-setup stage would allocate rings a second time.
        if (function_instance.driver_agent.fsm != null)
            function_instance.driver_agent.fsm.state = FSM_READY;
        m_driver_flow_started = 1;
        ok = 1;
    endtask

    // Allocate/map/program one queue using the normal atomic operation.  This
    // method never writes descriptor, avail, used, or completion bytes itself;
    // the responder observes the resulting common-config writes and owns all
    // device-side completion work.
    virtual task setup_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        virtqueue_type_e vq_type,
        ref bit ok
    );
        virtio_function_instance function_instance;
        bit enabled;
        string why;

        ok = 0;
        if (!m_flow_ready || !m_driver_flow_started) begin
            `uvm_error("REAL_FLOW",
                       "setup_queue called before start_driver_flow")
            return;
        end
        function_instance = selected_function(why);
        if (function_instance == null) begin
            `uvm_error("REAL_FLOW", why)
            return;
        end
        if ((function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null) ||
            (function_instance.transport == null) ||
            (function_instance.vq_mgr == null)) begin
            `uvm_error("REAL_FLOW", "selected function queue context is incomplete")
            return;
        end

        function_instance.driver_agent.ops.setup_queue(
            queue_id, queue_size, vq_type, ok);
        if (!ok)
            return;

        // Read back the transport enable bit as a lightweight contract check;
        // all writes and ring ownership still came from setup_queue().
        function_instance.transport.select_queue(queue_id);
        function_instance.transport.read_queue_enable(enabled);
        if (!enabled) begin
            `uvm_error("REAL_FLOW", $sformatf(
                "queue %0d setup returned success but is not enabled", queue_id))
            ok = 0;
            return;
        end
    endtask

    // Submit one TX packet through the production driver operation.  The
    // atomic operation owns packet/header allocation, IOMMU mapping,
    // descriptor construction, and the real PCIe notify; the fixture only
    // exposes that lifecycle boundary to golden-flow tests.
    virtual task submit_tx(
        int unsigned queue_id,
        virtio_net_hdr_t net_hdr,
        uvm_object pkt,
        bit use_indirect,
        ref int unsigned desc_id,
        ref bit ok
    );
        virtio_function_instance function_instance;
        string why;

        ok = 0;
        desc_id = '1;
        if (!m_flow_ready || !m_driver_flow_started) begin
            `uvm_error("REAL_FLOW", "submit_tx called before start_driver_flow")
            return;
        end
        if (pkt == null) begin
            `uvm_error("REAL_FLOW", "submit_tx called with null packet")
            return;
        end
        function_instance = selected_function(why);
        if ((function_instance == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null)) begin
            `uvm_error("REAL_FLOW", (why == "") ?
                       "selected function TX ops are unavailable" : why)
            return;
        end
        function_instance.driver_agent.ops.tx_submit(
            queue_id, net_hdr, pkt, use_indirect, desc_id);
        ok = (desc_id != '1);
    endtask

    // Poll the production used-ring completion operation until the responder
    // has processed the notify or the bounded wait expires.  This keeps the
    // test synchronized through the driver API rather than reading ring bytes
    // directly from the fixture.
    virtual task complete_tx(
        input int unsigned queue_id,
        ref uvm_object completed[$],
        input int unsigned max_budget,
        output int unsigned completed_count,
        ref bit ok
    );
        virtio_function_instance function_instance;
        int unsigned attempts;
        int unsigned prior_count;
        string why;

        ok = 0;
        completed.delete();
        completed_count = 0;
        if (!m_flow_ready || !m_driver_flow_started) begin
            `uvm_error("REAL_FLOW", "complete_tx called before start_driver_flow")
            return;
        end
        function_instance = selected_function(why);
        if ((function_instance == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null)) begin
            `uvm_error("REAL_FLOW", (why == "") ?
                       "selected function TX ops are unavailable" : why)
            return;
        end
        for (attempts = 0; attempts < m_poll_timeout_ns; attempts++) begin
            prior_count = completed.size();
            function_instance.driver_agent.ops.tx_complete(
                queue_id, completed, max_budget);
            if (completed.size() > prior_count)
                break;
            #1ns;
        end
        completed_count = completed.size();
        ok = (completed.size() != 0);
    endtask

    // Queue one RX packet at the DUT boundary.  The test supplies only a
    // packet object; responder-side header encoding and all PCIe writes remain
    // outside the driver fixture.
    virtual task inject_rx(
        input int unsigned queue_id,
        input virtio_net_hdr_t net_hdr,
        input uvm_object pkt,
        ref bit ok
    );
        ok = 0;
        if ((responder == null) || (pkt == null)) begin
            `uvm_error("REAL_FLOW", "inject_rx requires responder and packet")
            return;
        end
        responder.inject_rx_packet(queue_id, net_hdr, pkt, ok);
    endtask

    // Production RX refill owns Host-memory allocation, IOVA mapping, ring
    // construction and notify.  No descriptor bytes are authored by tests.
    virtual task refill_rx(
        input int unsigned queue_id,
        input int unsigned count,
        ref bit ok
    );
        virtio_function_instance function_instance;
        string why;
        ok = 0;
        function_instance = selected_function(why);
        if ((function_instance == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null)) begin
            `uvm_error("REAL_FLOW", (why == "") ?
                       "selected function RX ops are unavailable" : why)
            return;
        end
        function_instance.driver_agent.ops.rx_refill(queue_id, count);
        ok = 1;
    endtask

    // Wait for the responder's PCIe used-ring write, then consume packets via
    // the production RX operation.  The bounded retry also covers asynchronous
    // posted-write delivery in the PCIe TL VIP.
    virtual task receive_rx(
        input int unsigned queue_id,
        input int unsigned budget,
        ref uvm_object received[$],
        output int unsigned received_count,
        ref bit ok
    );
        virtio_function_instance function_instance;
        string why;
        int unsigned attempts;
        int unsigned prior_count;
        ok = 0;
        received.delete();
        received_count = 0;
        function_instance = selected_function(why);
        if ((function_instance == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null)) begin
            `uvm_error("REAL_FLOW", (why == "") ?
                       "selected function RX ops are unavailable" : why)
            return;
        end
        for (attempts = 0; attempts < m_poll_timeout_ns; attempts++) begin
            prior_count = received.size();
            function_instance.driver_agent.ops.rx_receive(
                queue_id, received, budget);
            if (received.size() >= budget)
                break;
            if (received.size() == prior_count)
                #1ns;
        end
        received_count = received.size();
        ok = (received_count != 0);
    endtask

    // Quiesce responder/FSM workers first, then perform the verified normal
    // driver reset.  The atomic reset path detaches queues, unmaps ring IOVAs,
    // retires any normal DMA records, and destroys queue objects.
    virtual task reset_and_teardown(ref bit ok);
        virtio_function_instance function_instance;
        bit reset_complete;
        string why;

        ok = 0;
        function_instance = selected_function(why);
        if (function_instance == null) begin
            `uvm_error("REAL_FLOW", why)
            return;
        end

        if (host_mem_responder != null)
            host_mem_responder.shutdown();
        if (responder != null)
            responder.stop();
        if (responder != null)
            responder.wait_stopped();
        if ((responder != null) && responder.running()) begin
            `uvm_error("REAL_FLOW", "responder workers remain after stop")
            return;
        end
        if ((function_instance.driver_agent != null) &&
            (function_instance.driver_agent.fsm != null) &&
            (function_instance.driver_agent.fsm.state == FSM_RUNNING))
            function_instance.driver_agent.fsm.stop_dataplane();

        if ((function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null)) begin
            `uvm_error("REAL_FLOW", "selected function reset ops are unavailable")
            return;
        end
        function_instance.driver_agent.ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            `uvm_error("REAL_FLOW", "verified device reset did not complete")
            return;
        end
        function_instance.vq_mgr.leak_check();
        if (function_instance.vq_mgr.get_queue_count() != 0) begin
            `uvm_error("REAL_FLOW", $sformatf(
                "queue manager retained %0d queues after reset",
                function_instance.vq_mgr.get_queue_count()))
            return;
        end
        if ((m_virtio_env != null) && (m_virtio_env.iommu != null))
            m_virtio_env.iommu.leak_check();
        if (m_host_mem != null)
            m_host_mem.leak_check();
        if (function_instance.driver_agent.fsm != null)
            function_instance.driver_agent.fsm.state = FSM_IDLE;
        m_driver_flow_started = 0;
        ok = 1;
    endtask

    protected function bit install_endpoint_image(output string why);
        dpu_bar_pair_lease_t common_bar;
        dpu_bar_pair_lease_t notify_bar;
        dpu_bar_pair_lease_t msix_bar;
        pcie_tl_cfg_space_manager cfg_mgr;
        pcie_tl_ep_driver ep_drv;

        why = "";
        if ((m_device_snapshot == null) || (m_pcie_env == null) ||
            (m_pcie_env.ep_agent == null)) begin
            why = "snapshot or PCIe endpoint agent is unavailable";
            return 0;
        end
        if (!m_device_snapshot.get_bar(m_function_key,
                DPU_BAR_DEVICE_MEMORY, common_bar, why) ||
            !m_device_snapshot.get_bar(m_function_key,
                DPU_BAR_MAILBOX, notify_bar, why) ||
            !m_device_snapshot.get_bar(m_function_key,
                DPU_BAR_MSIX, msix_bar, why))
            return 0;
        if ((common_bar.size < (DEVICE_OFFSET + DEVICE_LENGTH)) ||
            (common_bar.size <= ISR_OFFSET) ||
            (notify_bar.size < NOTIFY_LENGTH) ||
            (msix_bar.size < (MSIX_PBA_OFFSET + 8))) begin
            why = "snapshot BAR lease is too small for the virtio image";
            return 0;
        end
        cfg_mgr = m_pcie_env.cfg_mgr;
        ep_drv = m_pcie_env.ep_agent.ep_driver;
        if ((cfg_mgr == null) || (ep_drv == null)) begin
            why = "PCIe endpoint driver/config manager is unavailable";
            return 0;
        end
        cfg_mgr.init_type0_header(16'h1AF4, 16'h1041, 8'h01, 24'h020000);
        // The PCIe environment initializes its standard PCIe capability during
        // build_phase.  Reinitializing the Type-0 header above clears the
        // config bytes but does not clear cfg_mgr.cap_list; leaving that stale
        // list makes the first virtio capability link from a capability whose
        // pointer byte was just erased, so the advertised pointer at 0x34
        // becomes zero.  Rebuild the list and restore the standard PCIe
        // capability before adding the virtio vendor capabilities.
        cfg_mgr.cap_list.delete();
        cfg_mgr.ext_cap_list.delete();
        cfg_mgr.init_pcie_capability(8'h40);
        cfg_mgr.cfg_space[6] = cfg_mgr.cfg_space[6] | 8'h10;
        write_bar(cfg_mgr, common_bar);
        write_bar(cfg_mgr, notify_bar);
        write_bar(cfg_mgr, msix_bar);
        register_virtio_caps(cfg_mgr, common_bar, notify_bar, msix_bar);
        write_common_defaults(ep_drv, common_bar.base,
                              virtio_cfg.default_num_pairs * 2);
        ep_drv.mem_space[common_bar.base + ISR_OFFSET] = 8'h00;
        return 1;
    endfunction

    protected function void write_bar(
        input pcie_tl_cfg_space_manager cfg_mgr,
        input dpu_bar_pair_lease_t bar
    );
        int unsigned offset;
        bit [31:0] low;
        offset = 16'h10 + (bar.even_bar_id * 4);
        low = bar.base[31:0] & 32'hfffffff0;
        low[2:1] = 2'b10;
        cfg_mgr.cfg_space[offset] = low[7:0];
        cfg_mgr.cfg_space[offset + 1] = low[15:8];
        cfg_mgr.cfg_space[offset + 2] = low[23:16];
        cfg_mgr.cfg_space[offset + 3] = low[31:24];
        cfg_mgr.cfg_space[offset + 4] = bar.base[39:32];
        cfg_mgr.cfg_space[offset + 5] = bar.base[47:40];
        cfg_mgr.cfg_space[offset + 6] = bar.base[55:48];
        cfg_mgr.cfg_space[offset + 7] = bar.base[63:56];
    endfunction

    protected function void register_virtio_caps(
        input pcie_tl_cfg_space_manager cfg_mgr,
        input dpu_bar_pair_lease_t common_bar,
        input dpu_bar_pair_lease_t notify_bar,
        input dpu_bar_pair_lease_t msix_bar
    );
        bit [7:0] cap_data[];
        pcie_capability msix;
        cap_data = new[14];
        foreach (cap_data[index]) cap_data[index] = 8'h00;
        cap_data[0] = 8'h10; cap_data[1] = VIRTIO_PCI_CAP_COMMON_CFG;
        cap_data[2] = common_bar.even_bar_id;
        cap_data[6] = COMMON_OFFSET[7:0]; cap_data[7] = COMMON_OFFSET[15:8];
        cap_data[8] = COMMON_OFFSET[23:16]; cap_data[9] = COMMON_OFFSET[31:24];
        cap_data[10] = COMMON_LENGTH[7:0]; cap_data[11] = COMMON_LENGTH[15:8];
        cap_data[12] = COMMON_LENGTH[23:16]; cap_data[13] = COMMON_LENGTH[31:24];
        cfg_mgr.register_vendor_specific(cap_data, COMMON_CAP_OFFSET);
        cap_data = new[18];
        foreach (cap_data[index]) cap_data[index] = 8'h00;
        cap_data[0] = 8'h14; cap_data[1] = VIRTIO_PCI_CAP_NOTIFY_CFG;
        cap_data[2] = notify_bar.even_bar_id;
        cap_data[6] = NOTIFY_OFFSET[7:0]; cap_data[7] = NOTIFY_OFFSET[15:8];
        cap_data[8] = NOTIFY_OFFSET[23:16]; cap_data[9] = NOTIFY_OFFSET[31:24];
        cap_data[10] = NOTIFY_LENGTH[7:0]; cap_data[11] = NOTIFY_LENGTH[15:8];
        cap_data[12] = NOTIFY_LENGTH[23:16]; cap_data[13] = NOTIFY_LENGTH[31:24];
        cap_data[14] = 8'h02; cap_data[15] = 8'h00;
        cap_data[16] = 8'h00; cap_data[17] = 8'h00;
        cfg_mgr.register_vendor_specific(cap_data, NOTIFY_CAP_OFFSET);
        cap_data = new[14];
        foreach (cap_data[index]) cap_data[index] = 8'h00;
        cap_data[0] = 8'h10; cap_data[1] = VIRTIO_PCI_CAP_ISR_CFG;
        cap_data[2] = common_bar.even_bar_id;
        cap_data[6] = ISR_OFFSET[7:0]; cap_data[7] = ISR_OFFSET[15:8];
        cap_data[8] = ISR_OFFSET[23:16]; cap_data[9] = ISR_OFFSET[31:24];
        cap_data[10] = 8'h04;
        cfg_mgr.register_vendor_specific(cap_data, ISR_CAP_OFFSET);
        cap_data = new[14];
        foreach (cap_data[index]) cap_data[index] = 8'h00;
        cap_data[0] = 8'h10; cap_data[1] = VIRTIO_PCI_CAP_DEVICE_CFG;
        cap_data[2] = common_bar.even_bar_id;
        cap_data[6] = DEVICE_OFFSET[7:0]; cap_data[7] = DEVICE_OFFSET[15:8];
        cap_data[8] = DEVICE_OFFSET[23:16]; cap_data[9] = DEVICE_OFFSET[31:24];
        cap_data[10] = DEVICE_LENGTH[7:0]; cap_data[11] = DEVICE_LENGTH[15:8];
        cap_data[12] = DEVICE_LENGTH[23:16]; cap_data[13] = DEVICE_LENGTH[31:24];
        cfg_mgr.register_vendor_specific(cap_data, DEVICE_CAP_OFFSET);
        msix = pcie_capability::type_id::create("real_flow_msix_cap");
        msix.cap_id = CAP_ID_MSIX; msix.offset = MSIX_CAP_OFFSET;
        msix.data = new[10];
        foreach (msix.data[index]) msix.data[index] = 8'h00;
        msix.data[0] = 8'h00; msix.data[1] = 8'h00;
        msix.data[2] = MSIX_TABLE_OFFSET[7:0] | msix_bar.even_bar_id;
        msix.data[3] = MSIX_TABLE_OFFSET[15:8];
        msix.data[4] = MSIX_TABLE_OFFSET[23:16];
        msix.data[5] = MSIX_TABLE_OFFSET[31:24];
        msix.data[6] = MSIX_PBA_OFFSET[7:0] | msix_bar.even_bar_id;
        msix.data[7] = MSIX_PBA_OFFSET[15:8];
        msix.data[8] = MSIX_PBA_OFFSET[23:16];
        msix.data[9] = MSIX_PBA_OFFSET[31:24];
        cfg_mgr.register_capability(msix);
    endfunction

    protected function void write_common_defaults(
        input pcie_tl_ep_driver ep_drv,
        input bit [63:0] base,
        input int unsigned total_queues
    );
        write_ep32(ep_drv, base + COMMON_OFFSET + 32'h04, 32'h0000_0001);
        write_ep16(ep_drv, base + COMMON_OFFSET + 32'h10, 16'hffff);
        write_ep16(ep_drv, base + COMMON_OFFSET + 32'h12,
                   total_queues[15:0]);
        write_ep16(ep_drv, base + COMMON_OFFSET + 32'h18, 16'h0100);
        write_ep16(ep_drv, base + COMMON_OFFSET + 32'h1a, 16'hffff);
    endfunction

    protected function void write_ep16(pcie_tl_ep_driver ep_drv,
                                       bit [63:0] addr, bit [15:0] data);
        ep_drv.mem_space[addr] = data[7:0];
        ep_drv.mem_space[addr + 1] = data[15:8];
    endfunction

    protected function void write_ep32(pcie_tl_ep_driver ep_drv,
                                       bit [63:0] addr, bit [31:0] data);
        ep_drv.mem_space[addr] = data[7:0];
        ep_drv.mem_space[addr + 1] = data[15:8];
        ep_drv.mem_space[addr + 2] = data[23:16];
        ep_drv.mem_space[addr + 3] = data[31:24];
    endfunction
endclass

`endif
