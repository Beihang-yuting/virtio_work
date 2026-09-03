`ifndef DPU_VIO_DATAPLANE_PLAN_EXTENSION_SV
`define DPU_VIO_DATAPLANE_PLAN_EXTENSION_SV

// User extension seam for queue-scheduler and dataplane register lowering.
// The audited core builder deliberately owns no QSCH/VTX/VRX offsets yet.
// Subclasses receive immutable topology/resource snapshots and the still
// mutable core plan after BDF/MSI-X/notify operations have been assembled.
class dpu_vio_dataplane_plan_extension extends uvm_object;
    `uvm_object_utils(dpu_vio_dataplane_plan_extension)

    function new(string name = "dpu_vio_dataplane_plan_extension");
        super.new(name);
    endfunction

    virtual function bit contribute_qsch(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        why = "";
        return 1;
    endfunction

    virtual function bit contribute_vtx(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        why = "";
        return 1;
    endfunction

    virtual function bit contribute_vrx(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        why = "";
        return 1;
    endfunction

    virtual function bit contribute(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        why = "";
        if (!contribute_qsch(device_snapshot, resource_snapshot, plan, why))
            return 0;
        if (!contribute_vtx(device_snapshot, resource_snapshot, plan, why))
            return 0;
        if (!contribute_vrx(device_snapshot, resource_snapshot, plan, why))
            return 0;
        return 1;
    endfunction
endclass : dpu_vio_dataplane_plan_extension

// ---------------------------------------------------------------------------
// Evidence based lowering for the VIO dataplane tables used by the driver on
// 10.11.10.53.  The generic extension above remains deliberately empty so a
// platform can provide a different register map.  This implementation only
// emits writes whose offsets and bit layouts are present in register.h; it
// does not invent the driver's context/tail/list-table initialization.
// ---------------------------------------------------------------------------

localparam bit [63:0] DPU_VIO_QSCH_BASE       = 64'h00b0_0000;
localparam bit [63:0] DPU_VIO_VTX_CFG_START   = 64'h0088_0100;
localparam bit [63:0] DPU_VIO_VTX_CONTENT     = 64'h0088_0134;
localparam bit [63:0] DPU_VIO_VTX_RAM_CFG    = 64'h0088_0130;
localparam bit [63:0] DPU_VIO_VRX_CONTENT     = 64'h0090_0204;
localparam bit [63:0] DPU_VIO_VRX_RAM_CFG    = 64'h0090_0200;

localparam int unsigned DPU_VIO_QSCH_Q2TC_OFF = 'h10000;
localparam int unsigned DPU_VIO_QSCH_N2G_OFF  = 'h11000;
localparam int unsigned DPU_VIO_QSCH_G2P_OFF  = 'h12000;
localparam int unsigned DPU_VIO_QSCH_SPWRR_OFF = 'h13000;
localparam int unsigned DPU_VIO_QSCH_TC_WGT_OFF = 'h14000;

typedef struct {
    int unsigned global_qpair_id;
    int unsigned cos;
    int unsigned net_id;
    bit topology_valid;
    bit valid;
} dpu_vio_qsch_queue_cfg_t;

typedef struct {
    dpu_function_key_t function_key;
    int unsigned net_id;
    int unsigned group_id;
    int unsigned src_port;
    int unsigned dst_port;
    int unsigned spwrr;
    // Optional WRR weights for TC0..TC7.  The driver table stores four bits
    // per traffic class; keep the user-facing values wide enough to validate
    // truncation instead of silently accepting an out-of-range value.
    int unsigned tc_weight[8];
    bit weight_valid;
    bit topology_valid;
    bit valid;
} dpu_vio_qsch_function_cfg_t;

typedef struct {
    int unsigned global_qpair_id;
    bit [63:0] desc_addr;
    int unsigned q_depth;
    bit queue_en;
    bit virtio_mode;
    bit interl_seg_en;
    bit seg_en;
    bit inorder;
    bit redraw_en;
    bit tail_buf_id_dis;
    bit queue_stop;
} dpu_vio_vtx_queue_cfg_t;

typedef struct {
    int unsigned global_qpair_id;
    bit [63:0] desc_addr;
    int unsigned q_depth;
    bit queue_en;
    bit virtio_mode;
    int unsigned dport_type;
    int unsigned dport_id;
    int unsigned dma_msix;
} dpu_vio_vrx_queue_cfg_t;

function automatic bit dpu_vio_pack_qsch_q2tc(
    input int unsigned cos,
    input int unsigned net_id,
    input bit valid,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if (cos > 3'd7) begin
        why = "QSCH Q2TC COS exceeds the three-bit driver field";
        return 0;
    end
    if (net_id > 6'd63) begin
        why = "QSCH Q2TC net ID exceeds the six-bit driver field";
        return 0;
    end
    payload[2:0] = cos[2:0];
    payload[8:3] = net_id[5:0];
    payload[31] = valid;
    return 1;
endfunction

function automatic bit dpu_vio_pack_qsch_n2g(
    input int unsigned group_id,
    input bit valid,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if (group_id > 5'd31) begin
        why = "QSCH N2G group ID exceeds the five-bit driver field";
        return 0;
    end
    payload[4:0] = group_id[4:0];
    payload[31] = valid;
    return 1;
endfunction

function automatic bit dpu_vio_pack_qsch_g2p(
    input int unsigned src_port,
    input int unsigned dst_port,
    input bit valid,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    // register.h declares src_port as a one-bit field.  The driver computes
    // QSCH_PORT_HOST0 + host_id before assigning that field, so the compiled
    // dpu_snd1.ko exposes only the low bit of that logical port value.
    if (src_port > 1) begin
        why = "QSCH G2P source port exceeds the one-bit driver field";
        return 0;
    end
    if (dst_port > 2'd3) begin
        why = "QSCH G2P destination port exceeds the two-bit driver field";
        return 0;
    end
    payload[0] = src_port[0];
    payload[17:16] = dst_port[1:0];
    payload[31] = valid;
    return 1;
endfunction

function automatic bit dpu_vio_pack_qsch_spwrr(
    input int unsigned spwrr,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if (spwrr > 8'hff) begin
        why = "QSCH SP/WRR mask exceeds the eight-bit driver field";
        return 0;
    end
    payload[7:0] = spwrr[7:0];
    return 1;
endfunction

function automatic bit dpu_vio_pack_qsch_tc_weight(
    input int unsigned tc_weight[8],
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    foreach (tc_weight[index]) begin
        if (tc_weight[index] > 4'hf) begin
            why = $sformatf(
                "QSCH TC%0d WRR weight exceeds the four-bit driver field",
                index);
            return 0;
        end
        payload[index * 4 +: 4] = tc_weight[index][3:0];
    end
    return 1;
endfunction

function automatic bit dpu_vio_pack_vtx_queue_para(
    input dpu_vio_vtx_queue_cfg_t cfg,
    input int unsigned sport_type,
    input int unsigned sport_id,
    input int unsigned dma_msix,
    output bit [31:0] content[4],
    output string why
);
    content = '{default: '0};
    why = "";
    if (cfg.global_qpair_id > 11'h7ff) begin
        why = "VTX global qpair ID exceeds the eleven-bit driver field";
        return 0;
    end
    if (cfg.q_depth > 4'hf) begin
        why = "VTX queue depth exceeds the four-bit driver field";
        return 0;
    end
    if (sport_type > 3'd7) begin
        why = "VTX source port type exceeds the three-bit driver field";
        return 0;
    end
    if (dma_msix > 11'h7ff) begin
        why = "VTX MSI-X index exceeds the eleven-bit driver field";
        return 0;
    end
    if (sport_id > 10'h3ff) begin
        why = "VTX source function ID exceeds the ten-bit driver field";
        return 0;
    end
    content[0] = cfg.desc_addr[31:0];
    content[1] = cfg.desc_addr[63:32];
    content[2][3:0] = cfg.q_depth[3:0];
    content[2][4] = cfg.queue_en;
    content[2][5] = cfg.virtio_mode;
    content[2][6] = cfg.interl_seg_en;
    content[2][7] = cfg.seg_en;
    content[2][8] = cfg.inorder;
    content[2][9] = cfg.redraw_en;
    content[2][10] = cfg.tail_buf_id_dis;
    content[2][11] = cfg.queue_stop;
    content[2][14:12] = sport_type[2:0];
    content[2][25:15] = dma_msix[10:0];
    content[3][9:0] = sport_id[9:0];
    return 1;
endfunction

function automatic bit dpu_vio_pack_vrx_queue_para(
    input dpu_vio_vrx_queue_cfg_t cfg,
    output bit [31:0] content[3],
    output string why
);
    content = '{default: '0};
    why = "";
    if (cfg.global_qpair_id > 11'h7ff) begin
        why = "VRX global qpair ID exceeds the eleven-bit driver field";
        return 0;
    end
    if (cfg.q_depth > 4'hf) begin
        why = "VRX queue depth exceeds the four-bit driver field";
        return 0;
    end
    if (cfg.dport_type > 3'd7) begin
        why = "VRX destination port type exceeds the three-bit driver field";
        return 0;
    end
    if (cfg.dport_id > 10'h3ff) begin
        why = "VRX destination function ID exceeds the ten-bit driver field";
        return 0;
    end
    if (cfg.dma_msix > 11'h7ff) begin
        why = "VRX MSI-X index exceeds the eleven-bit driver field";
        return 0;
    end
    content[0] = cfg.desc_addr[31:0];
    content[1] = cfg.desc_addr[63:32];
    content[2][3:0] = cfg.q_depth[3:0];
    content[2][4] = cfg.queue_en;
    content[2][5] = cfg.virtio_mode;
    content[2][8:6] = cfg.dport_type[2:0];
    content[2][18:9] = cfg.dport_id[9:0];
    content[2][29:19] = cfg.dma_msix[10:0];
    return 1;
endfunction

function automatic bit dpu_vio_pack_vtx_ram_cfg(
    input int unsigned global_qpair_id,
    input bit write_enable,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if (global_qpair_id > 9'h1ff) begin
        why = "VTX RAM address exceeds the nine-bit driver field";
        return 0;
    end
    payload[8:0] = global_qpair_id[8:0];
    payload[13] = 1'b1; // W_RAM_QUEUE_PARA_TABLE
    payload[14] = write_enable;
    return 1;
endfunction

function automatic bit dpu_vio_pack_vrx_ram_cfg(
    input int unsigned global_qpair_id,
    input bit write_enable,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if (global_qpair_id > 16'hffff) begin
        why = "VRX RAM address exceeds the sixteen-bit driver field";
        return 0;
    end
    payload[15:0] = global_qpair_id[15:0];
    payload[31:16] = write_enable ? 16'h1 : 16'h0;
    return 1;
endfunction

class dpu_vio_driver_dataplane_extension extends
    dpu_vio_dataplane_plan_extension;
    `uvm_object_utils(dpu_vio_driver_dataplane_extension)

    bit emit_qsch_init;
    bit emit_qsch;
    bit emit_vtx;
    bit emit_vrx;
    // When enabled, every ordinary VIO binding must have one matching VTX
    // and VRX config.  The default is permissive so AF-only/control queues
    // and incremental bring-up can be represented by a partial plan.
    bit require_vtx_vrx_configs;
    int unsigned default_qsch_cos;
    int unsigned default_qsch_src_port_base;
    int unsigned default_qsch_dst_port;
    int unsigned default_qsch_spwrr;
    dpu_vio_qsch_queue_cfg_t qsch_queues[$];
    dpu_vio_qsch_function_cfg_t qsch_functions[$];
    // Optional logical topology generated by dpu-common.  When present it
    // is validated and lowered into the legacy qsch_* configuration arrays
    // immediately before register operations are emitted.
    dpu_qsch_topology_cfg qsch_topology;
    dpu_vio_vtx_queue_cfg_t vtx_queues[$];
    dpu_vio_vrx_queue_cfg_t vrx_queues[$];

    function new(string name = "dpu_vio_driver_dataplane_extension");
        super.new(name);
        emit_qsch_init = 1;
        emit_qsch = 1;
        emit_vtx = 1;
        emit_vrx = 1;
        require_vtx_vrx_configs = 0;
        default_qsch_cos = 0;
        default_qsch_src_port_base = 2; // QSCH_PORT_HOST0
        default_qsch_dst_port = 0;
        default_qsch_spwrr = 0;
        qsch_queues.delete();
        qsch_functions.delete();
        qsch_topology = null;
        vtx_queues.delete();
        vrx_queues.delete();
    endfunction

    function void set_qsch_topology(input dpu_qsch_topology_cfg topology);
        qsch_topology = topology;
    endfunction

    local function bit import_qsch_topology(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        output string why
    );
        dpu_vio_qsch_queue_cfg_t queue_cfg;
        dpu_vio_qsch_function_cfg_t function_cfg;

        why = "";
        if (qsch_topology == null)
            return 1;
        if (!qsch_topology.validate(device_snapshot, resource_snapshot, why))
            return 0;
        qsch_queues.delete();
        qsch_functions.delete();
        foreach (qsch_topology.queues[index]) begin
            queue_cfg.global_qpair_id =
                qsch_topology.queues[index].global_qpair_id;
            queue_cfg.cos = qsch_topology.queues[index].tc_id;
            queue_cfg.net_id = qsch_topology.queues[index].net_id;
            queue_cfg.topology_valid = 1;
            queue_cfg.valid = qsch_topology.queues[index].valid;
            qsch_queues.push_back(queue_cfg);
        end
        foreach (qsch_topology.nets[index]) begin
            function_cfg.function_key =
                qsch_topology.nets[index].function_key;
            function_cfg.net_id = qsch_topology.nets[index].net_id;
            function_cfg.group_id = qsch_topology.nets[index].group_id;
            function_cfg.src_port = qsch_topology.nets[index].src_port;
            function_cfg.dst_port = qsch_topology.nets[index].dst_port;
            function_cfg.spwrr = qsch_topology.nets[index].spwrr;
            function_cfg.weight_valid = qsch_topology.nets[index].weight_valid;
            function_cfg.topology_valid = 1;
            function_cfg.valid = qsch_topology.nets[index].valid;
            foreach (function_cfg.tc_weight[tc])
                function_cfg.tc_weight[tc] =
                    qsch_topology.nets[index].tc_weight[tc];
            qsch_functions.push_back(function_cfg);
        end
        return 1;
    endfunction

    local function dpu_reg_op make_op(
        input string op_id,
        input dpu_pcie_function_id_t af_pcie_id,
        input dpu_reg_op_kind_e kind,
        input dpu_reg_phase_e phase,
        input dpu_reg_target_scope_e scope,
        input string target_block,
        input bit [63:0] address,
        input int unsigned width_bytes
    );
        dpu_reg_op op;
        op = dpu_reg_op::type_id::create(op_id);
        op.op_id = op_id;
        op.owner = "dpu.vio.dataplane";
        op.kind = kind;
        op.target_space = DPU_REG_TARGET_AF_BAR0;
        op.target_scope = scope;
        op.phase = phase;
        op.host_id = af_pcie_id.domain.host_id;
        op.segment_id = af_pcie_id.domain.segment_id;
        op.bdf_valid = 1;
        op.bdf = af_pcie_id.bdf;
        op.bar_id = 0;
        op.target_block = target_block;
        op.address = address;
        op.width_bytes = width_bytes;
        return op;
    endfunction

    local function bit add_op(
        input dpu_reg_plan plan,
        input dpu_reg_op op,
        output string why
    );
        return plan.add_operation(op, why);
    endfunction

    local function bit get_context(
        input dpu_device_snapshot device_snapshot,
        output dpu_function_key_t af_key,
        output dpu_bar_pair_lease_t af_bar0,
        output dpu_pcie_function_id_t af_pcie_id,
        output string why
    );
        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            why = "driver dataplane extension requires a frozen device snapshot";
            return 0;
        end
        if (!device_snapshot.get_expected_af(af_key, af_bar0, why) ||
            !device_snapshot.get_pcie_id(af_key, af_pcie_id, why))
            return 0;
        return 1;
    endfunction

    // The core VIO builder commits the notify shadow before the AF dataplane
    // tables are touched.  Return that commit operation so the generated DAG
    // preserves the same ordering when a concrete PCIe executor is used.
    local function bit get_notify_commit_dependency(
        input dpu_reg_plan plan,
        output string dependency_id,
        output string why
    );
        dpu_reg_op bank0_op;
        dpu_reg_op bank1_op;
        bit has_bank0;
        bit has_bank1;

        dependency_id = "";
        why = "";
        if (plan == null)
            return 1;
        has_bank0 = plan.find_operation(
            "vio.notify.commit.bank0", bank0_op);
        has_bank1 = plan.find_operation(
            "vio.notify.commit.bank1", bank1_op);
        if (has_bank0 && has_bank1) begin
            why = "QSCH lowering found both notify-bank commit operations";
            return 0;
        end
        if (has_bank0)
            dependency_id = bank0_op.op_id;
        else if (has_bank1)
            dependency_id = bank1_op.op_id;
        return 1;
    endfunction

    local function bit check_aperture(
        input dpu_bar_pair_lease_t af_bar0,
        input bit [63:0] offset,
        input int unsigned width_bytes,
        input string table_name,
        output string why
    );
        why = "";
        if ((width_bytes == 0) || (offset > af_bar0.size) ||
            (width_bytes > (af_bar0.size - offset))) begin
            why = $sformatf(
                "AF BAR0 aperture does not cover %s offset 0x%016h width %0d (size 0x%016h)",
                table_name, offset, width_bytes, af_bar0.size);
            return 0;
        end
        return 1;
    endfunction

    local function bit find_binding(
        input dpu_resource_snapshot resource_snapshot,
        input int unsigned global_qpair_id,
        output dpu_vio_qpair_binding_t binding
    );
        dpu_vio_qpair_binding_t bindings[$];
        binding.global_qpair_id = 0;
        resource_snapshot.list_vio_bindings(bindings);
        foreach (bindings[index]) begin
            if (bindings[index].global_qpair_id == global_qpair_id) begin
                binding = bindings[index];
                return 1;
            end
        end
        return 0;
    endfunction

    local function bit qsch_queue_values(
        input int unsigned global_qpair_id,
        output int unsigned cos,
        output int unsigned net_id,
        output bit net_valid
    );
        cos = default_qsch_cos;
        net_id = 0;
        net_valid = 0;
        foreach (qsch_queues[index]) begin
            if (qsch_queues[index].global_qpair_id == global_qpair_id) begin
                cos = qsch_queues[index].cos;
                if (qsch_queues[index].topology_valid === 1'b1) begin
                    net_id = qsch_queues[index].net_id;
                    net_valid = 1;
                end
                return qsch_queues[index].valid;
            end
        end
        return 1;
    endfunction

    local function bit qsch_function_values(
        input dpu_function_key_t key,
        output int unsigned src_port,
        output int unsigned dst_port,
        output int unsigned spwrr,
        output int unsigned tc_weight[8],
        output bit weight_valid,
        output int unsigned group_id,
        output bit topology_valid
    );
        // Match the driver's assignment to the one-bit src_port bitfield:
        // logical QSCH_PORT_HOST0 + host_id is truncated by the register
        // layout before it reaches hardware.
        src_port = (default_qsch_src_port_base + key.host_id) & 1;
        dst_port = default_qsch_dst_port;
        spwrr = default_qsch_spwrr;
        group_id = 0;
        topology_valid = 0;
        weight_valid = 0;
        foreach (tc_weight[index])
            tc_weight[index] = 0;
        foreach (qsch_functions[index]) begin
            if (dpu_same_function_key(qsch_functions[index].function_key, key)) begin
                src_port = qsch_functions[index].src_port;
                dst_port = qsch_functions[index].dst_port;
                spwrr = qsch_functions[index].spwrr;
                if (qsch_functions[index].topology_valid === 1'b1) begin
                    group_id = qsch_functions[index].group_id;
                    topology_valid = 1;
                end
                weight_valid = qsch_functions[index].weight_valid;
                foreach (tc_weight[weight_index])
                    tc_weight[weight_index] =
                        qsch_functions[index].tc_weight[weight_index];
                return qsch_functions[index].valid;
            end
        end
        return 1;
    endfunction

    local function string qsch_prefix(input dpu_function_key_t key,
                                      input int unsigned qid);
        return {"vio.dataplane.qsch.", dpu_function_key_name(key),
               $sformatf(".q%0d", qid)};
    endfunction

    local function string qsch_function_prefix(input dpu_function_key_t key,
                                               input int unsigned qid);
        // Function tables are indexed by global function ID, so their
        // operation identity is function-scoped (unlike Q2TC, which is
        // queue-scoped).  Keep qid in the argument for a stable call site
        // and to document which binding supplied the function context.
        return {"vio.dataplane.qsch.", dpu_function_key_name(key)};
    endfunction

    virtual function bit contribute_qsch(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        dpu_function_key_t af_key;
        dpu_bar_pair_lease_t af_bar0;
        dpu_pcie_function_id_t af_pcie_id;
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t extras[$];
        dpu_function_key_t function_keys[$];
        int unsigned function_first_qid[$];
        string q2tc_ids[string];
        bit function_seen[string];
        string previous_id;
        string init_id;
        string qsch_dependency;
        string notify_dependency;
        bit [31:0] payload;
        int unsigned cos;
        int unsigned src_port;
        int unsigned dst_port;
        int unsigned spwrr;
        int unsigned tc_weight[8];
        bit weight_valid;

        why = "";
        if (!get_context(device_snapshot, af_key, af_bar0, af_pcie_id, why))
            return 0;
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "driver dataplane extension requires a frozen resource snapshot";
            return 0;
        end
        if (!import_qsch_topology(device_snapshot, resource_snapshot, why))
            return 0;
        init_id = "vio.dataplane.qsch.init";
        qsch_dependency = emit_qsch_init ? init_id :
                          "bootstrap.final_barrier";
        if (!get_notify_commit_dependency(plan, notify_dependency, why))
            return 0;
        if (emit_qsch_init) begin
            dpu_reg_op op;
            if (!check_aperture(af_bar0, DPU_VIO_QSCH_BASE + 'h100, 4,
                                "qsch.init", why)) return 0;
            op = make_op(init_id, af_pcie_id, DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_HOST,
                         "qsch.init", DPU_VIO_QSCH_BASE + 'h100, 4);
            op.payload = 32'h1;
            op.write_mask = 64'hffff_ffff;
            op.add_dependency("bootstrap.final_barrier");
            if (!add_op(plan, op, why)) return 0;
        end
        if (!emit_qsch)
            return 1;

        resource_snapshot.list_vio_bindings(bindings);
        resource_snapshot.list_af_extra_queue_bindings(extras);
        foreach (bindings[index]) begin
            dpu_function_key_t key;
            int unsigned qid;
            string key_name;
            string op_id;
            dpu_reg_op op;
            int unsigned function_id;
            int unsigned qsch_net_id;
            bit qsch_net_valid;
            key = bindings[index].service_key.function_key;
            qid = bindings[index].global_qpair_id;
            key_name = dpu_function_key_name(key);
            if (!qsch_queue_values(qid, cos, qsch_net_id, qsch_net_valid))
                return 0;
            if (!device_snapshot.get_global_function_id(key, function_id, why))
                return 0;
            if (!qsch_net_valid)
                qsch_net_id = function_id;
            if (!dpu_vio_pack_qsch_q2tc(cos, qsch_net_id, 1,
                                        payload, why)) return 0;
            op_id = {qsch_prefix(key, qid), ".q2tc"};
            if (q2tc_ids.exists($sformatf("%0d", qid))) begin
                why = $sformatf("duplicate QSCH Q2TC global qpair %0d", qid);
                return 0;
            end
            q2tc_ids[$sformatf("%0d", qid)] = op_id;
            op = make_op(op_id, af_pcie_id, DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                         "qsch_q2tc",
                         DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_Q2TC_OFF + qid * 4,
                         4);
            op.owner = {"dpu.vio.dataplane.qsch.", key_name};
            op.payload = payload;
            op.write_mask = 64'hffff_ffff;
            op.add_dependency(qsch_dependency);
            if (notify_dependency != "")
                op.add_dependency(notify_dependency);
            // The real driver establishes the function's G2P/N2G mapping
            // before enabling any queue-to-TC entry.  The function operation
            // is emitted later in this pass, but its ID is deterministic.
            op.add_dependency({qsch_function_prefix(key, qid), ".n2g"});
            if (!check_aperture(
                    af_bar0,
                    DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_Q2TC_OFF + qid * 4,
                    4, "qsch_q2tc", why)) return 0;
            if (!add_op(plan, op, why)) return 0;
            if (!function_seen.exists(key_name)) begin
                function_seen[key_name] = 1;
                function_keys.push_back(key);
                function_first_qid.push_back(qid);
            end
        end
        foreach (extras[index]) begin
            dpu_function_key_t key;
            int unsigned qid;
            string key_name;
            string op_id;
            dpu_reg_op op;
            int unsigned function_id;
            int unsigned qsch_net_id;
            bit qsch_net_valid;
            key = extras[index].af_function_key;
            qid = extras[index].global_qpair_id;
            key_name = dpu_function_key_name(key);
            if (!qsch_queue_values(qid, cos, qsch_net_id, qsch_net_valid))
                return 0;
            if (!device_snapshot.get_global_function_id(key, function_id, why))
                return 0;
            if (!qsch_net_valid)
                qsch_net_id = function_id;
            if (!dpu_vio_pack_qsch_q2tc(cos, qsch_net_id, 1,
                                        payload, why)) return 0;
            op_id = $sformatf("vio.dataplane.qsch.%s.afq%0d.g%0d.q2tc",
                             key_name, extras[index].extra_queue_offset, qid);
            if (q2tc_ids.exists($sformatf("%0d", qid))) begin
                why = $sformatf("duplicate QSCH Q2TC global qpair %0d", qid);
                return 0;
            end
            q2tc_ids[$sformatf("%0d", qid)] = op_id;
            op = make_op(op_id, af_pcie_id, DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                         "qsch_q2tc",
                         DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_Q2TC_OFF + qid * 4,
                         4);
            op.owner = {"dpu.vio.dataplane.qsch.", key_name};
            op.payload = payload;
            op.write_mask = 64'hffff_ffff;
            op.add_dependency(qsch_dependency);
            if (notify_dependency != "")
                op.add_dependency(notify_dependency);
            op.add_dependency({qsch_function_prefix(key, qid), ".n2g"});
            if (!check_aperture(
                    af_bar0,
                    DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_Q2TC_OFF + qid * 4,
                    4, "qsch_q2tc", why)) return 0;
            if (!add_op(plan, op, why)) return 0;
            if (!function_seen.exists(key_name)) begin
                function_seen[key_name] = 1;
                function_keys.push_back(key);
                function_first_qid.push_back(qid);
            end
        end
        foreach (function_keys[index]) begin
            dpu_function_key_t key;
            int unsigned function_id;
            int unsigned first_qid;
            string prefix;
            dpu_reg_op op;
            bit function_topology_valid;
            int unsigned group_id;
            key = function_keys[index];
            first_qid = function_first_qid[index];
            prefix = qsch_function_prefix(key, first_qid);
            if (!device_snapshot.get_global_function_id(key, function_id, why))
                return 0;
            if (!qsch_function_values(key, src_port, dst_port, spwrr,
                                      tc_weight, weight_valid, group_id,
                                      function_topology_valid)) return 0;
            if (!function_topology_valid)
                group_id = function_id;
            // The driver writes group-to-port before vport-to-group.  Both
            // entries are gated by the QSCH reset and the committed notify
            // map, but neither depends on Q2TC.
            if (!dpu_vio_pack_qsch_g2p(src_port, dst_port, 1, payload, why)) return 0;
            op = make_op({prefix, ".g2p"}, af_pcie_id, DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_FUNCTION,
                         "qsch_g2p",
                         DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_G2P_OFF +
                         function_id * 4, 4);
            op.payload = payload;
            op.write_mask = 64'hffff_ffff;
            op.add_dependency(qsch_dependency);
            if (notify_dependency != "")
                op.add_dependency(notify_dependency);
            if (!check_aperture(
                    af_bar0,
                    DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_G2P_OFF +
                    function_id * 4, 4, "qsch_g2p", why)) return 0;
            if (!add_op(plan, op, why)) return 0;

            if (!dpu_vio_pack_qsch_n2g(group_id, 1, payload, why)) return 0;
            op = make_op({prefix, ".n2g"}, af_pcie_id, DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_FUNCTION,
                         "qsch_n2g",
                         DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_N2G_OFF +
                         function_id * 4, 4);
            op.payload = payload;
            op.write_mask = 64'hffff_ffff;
            op.add_dependency({prefix, ".g2p"});
            if (!check_aperture(
                    af_bar0,
                    DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_N2G_OFF +
                    function_id * 4, 4, "qsch_n2g", why)) return 0;
            if (!add_op(plan, op, why)) return 0;

            if (!dpu_vio_pack_qsch_spwrr(spwrr, payload, why)) return 0;
            op = make_op({prefix, ".spwrr"}, af_pcie_id,
                         DPU_REG_OP_MMIO_WRITE, DPU_REG_PHASE_TABLE,
                         DPU_REG_SCOPE_PER_FUNCTION, "qsch_spwrr",
                         DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_SPWRR_OFF +
                         function_id * 4, 4);
            op.payload = payload;
            op.write_mask = 64'hffff_ffff;
            foreach (bindings[bindex]) begin
                if (dpu_same_function_key(
                        bindings[bindex].service_key.function_key, key)) begin
                    string qkey;
                    qkey = $sformatf("%0d", bindings[bindex].global_qpair_id);
                    if (q2tc_ids.exists(qkey))
                        op.add_dependency(q2tc_ids[qkey]);
                end
            end
            foreach (extras[eindex]) begin
                if (dpu_same_function_key(extras[eindex].af_function_key, key)) begin
                    string qkey;
                    qkey = $sformatf("%0d", extras[eindex].global_qpair_id);
                    if (q2tc_ids.exists(qkey))
                        op.add_dependency(q2tc_ids[qkey]);
                end
            end
            if (!check_aperture(
                    af_bar0,
                    DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_SPWRR_OFF +
                    function_id * 4, 4, "qsch_spwrr", why)) return 0;
            if (!add_op(plan, op, why)) return 0;

            if (weight_valid) begin
                if (!dpu_vio_pack_qsch_tc_weight(tc_weight, payload, why))
                    return 0;
                op = make_op({prefix, ".tc_weight"}, af_pcie_id,
                             DPU_REG_OP_MMIO_WRITE, DPU_REG_PHASE_TABLE,
                             DPU_REG_SCOPE_PER_FUNCTION, "qsch_tc_weight",
                             DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_TC_WGT_OFF +
                             function_id * 4, 4);
                op.payload = payload;
                op.write_mask = 64'hffff_ffff;
                op.add_dependency({prefix, ".spwrr"});
                if (!check_aperture(
                        af_bar0,
                        DPU_VIO_QSCH_BASE + DPU_VIO_QSCH_TC_WGT_OFF +
                        function_id * 4, 4, "qsch_tc_weight", why)) return 0;
                if (!add_op(plan, op, why)) return 0;
            end
        end
        return 1;
    endfunction

    local function bit add_vtx_one(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        input dpu_pcie_function_id_t af_pcie_id,
        input dpu_bar_pair_lease_t af_bar0,
        input dpu_vio_vtx_queue_cfg_t cfg,
        input string dependency_id,
        output string why
    );
        dpu_vio_qpair_binding_t binding;
        dpu_function_key_t key;
        int unsigned function_id;
        bit [31:0] content[4];
        bit [31:0] payload;
        string prefix;
        dpu_reg_op op;
        if (!find_binding(resource_snapshot, cfg.global_qpair_id, binding)) begin
            why = $sformatf("VTX qpair %0d has no resource binding", cfg.global_qpair_id);
            return 0;
        end
        key = binding.service_key.function_key;
        if (!device_snapshot.get_global_function_id(key, function_id, why)) return 0;
        if (!dpu_vio_pack_vtx_queue_para(
                cfg, key.host_id, function_id,
                binding.global_msix_vector_id, content, why)) return 0;
        prefix = $sformatf("vio.dataplane.vtx.q%0d", cfg.global_qpair_id);
        if (!check_aperture(af_bar0, DPU_VIO_VTX_CONTENT, 16,
                            "vtx_queue_para_content", why) ||
            !check_aperture(af_bar0, DPU_VIO_VTX_RAM_CFG, 4,
                            "vtx_queue_para_ram_cfg", why)) return 0;
        for (int unsigned word = 0; word < 4; word++) begin
            op = make_op($sformatf("%s.content%0d", prefix, word),
                         af_pcie_id, DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                         "vtx_queue_para_content", DPU_VIO_VTX_CONTENT +
                         word * 4, 4);
            op.payload = content[word];
            op.write_mask = 64'hffff_ffff;
            op.add_dependency(dependency_id);
            if (word != 0)
                op.add_dependency($sformatf("%s.content%0d", prefix, word - 1));
            if (!add_op(plan, op, why)) return 0;
        end
        if (!dpu_vio_pack_vtx_ram_cfg(cfg.global_qpair_id, 0, payload, why)) return 0;
        // The driver writes wr_enable=0 first to prepare the indirect RAM
        // entry, then wr_enable=1 to make it visible.  Keep operation IDs
        // aligned with those two actions so executors and diagnostics do not
        // mistake the prepare write for an enable.
        op = make_op({prefix, ".ram_prepare"}, af_pcie_id,
                     DPU_REG_OP_MMIO_WRITE, DPU_REG_PHASE_TABLE,
                     DPU_REG_SCOPE_PER_SERVICE, "vtx_queue_para_ram_cfg",
                     DPU_VIO_VTX_RAM_CFG, 4);
        op.payload = payload;
        op.write_mask = 64'hffff_ffff;
        op.add_dependency($sformatf("%s.content3", prefix));
        if (!add_op(plan, op, why)) return 0;
        if (!dpu_vio_pack_vtx_ram_cfg(cfg.global_qpair_id, 1, payload, why)) return 0;
        op = make_op({prefix, ".ram_enable"}, af_pcie_id,
                     DPU_REG_OP_MMIO_WRITE, DPU_REG_PHASE_TABLE,
                     DPU_REG_SCOPE_PER_SERVICE, "vtx_queue_para_ram_cfg",
                     DPU_VIO_VTX_RAM_CFG, 4);
        op.payload = payload;
        op.write_mask = 64'hffff_ffff;
        op.add_dependency({prefix, ".ram_prepare"});
        return add_op(plan, op, why);
    endfunction

    local function bit add_vrx_one(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        input dpu_pcie_function_id_t af_pcie_id,
        input dpu_bar_pair_lease_t af_bar0,
        input dpu_vio_vrx_queue_cfg_t cfg,
        input string dependency_id,
        output string why
    );
        dpu_vio_qpair_binding_t binding;
        bit [31:0] content[3];
        bit [31:0] payload;
        string prefix;
        dpu_reg_op op;
        if (!find_binding(resource_snapshot, cfg.global_qpair_id, binding)) begin
            why = $sformatf("VRX qpair %0d has no resource binding", cfg.global_qpair_id);
            return 0;
        end
        cfg.dport_type = binding.service_key.function_key.host_id;
        if (!device_snapshot.get_global_function_id(
                binding.service_key.function_key, cfg.dport_id, why)) return 0;
        cfg.dma_msix = binding.global_msix_vector_id;
        if (!dpu_vio_pack_vrx_queue_para(cfg, content, why)) return 0;
        prefix = $sformatf("vio.dataplane.vrx.q%0d", cfg.global_qpair_id);
        if (!check_aperture(af_bar0, DPU_VIO_VRX_CONTENT, 12,
                            "vrx_queue_para_content", why) ||
            !check_aperture(af_bar0, DPU_VIO_VRX_RAM_CFG, 4,
                            "vrx_queue_para_ram_cfg", why)) return 0;
        for (int unsigned word = 0; word < 3; word++) begin
            op = make_op($sformatf("%s.content%0d", prefix, word),
                         af_pcie_id, DPU_REG_OP_MMIO_WRITE,
                         DPU_REG_PHASE_TABLE, DPU_REG_SCOPE_PER_SERVICE,
                         "vrx_queue_para_content", DPU_VIO_VRX_CONTENT +
                         word * 4, 4);
            op.payload = content[word];
            op.write_mask = 64'hffff_ffff;
            op.add_dependency(dependency_id);
            if (word != 0)
                op.add_dependency($sformatf("%s.content%0d", prefix, word - 1));
            if (!add_op(plan, op, why)) return 0;
        end
        if (!dpu_vio_pack_vrx_ram_cfg(cfg.global_qpair_id, 0, payload, why)) return 0;
        op = make_op({prefix, ".ram_prepare"}, af_pcie_id,
                     DPU_REG_OP_MMIO_WRITE, DPU_REG_PHASE_TABLE,
                     DPU_REG_SCOPE_PER_SERVICE, "vrx_queue_para_ram_cfg",
                     DPU_VIO_VRX_RAM_CFG, 4);
        op.payload = payload;
        op.write_mask = 64'hffff_ffff;
        op.add_dependency($sformatf("%s.content2", prefix));
        if (!add_op(plan, op, why)) return 0;
        if (!dpu_vio_pack_vrx_ram_cfg(cfg.global_qpair_id, 1, payload, why)) return 0;
        op = make_op({prefix, ".ram_enable"}, af_pcie_id,
                     DPU_REG_OP_MMIO_WRITE, DPU_REG_PHASE_TABLE,
                     DPU_REG_SCOPE_PER_SERVICE, "vrx_queue_para_ram_cfg",
                     DPU_VIO_VRX_RAM_CFG, 4);
        op.payload = payload;
        op.write_mask = 64'hffff_ffff;
        op.add_dependency({prefix, ".ram_prepare"});
        return add_op(plan, op, why);
    endfunction

    virtual function bit contribute_vtx(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        dpu_function_key_t af_key;
        dpu_bar_pair_lease_t af_bar0;
        dpu_pcie_function_id_t af_pcie_id;
        dpu_reg_op qsch_op;
        string dependency_id;
        why = "";
        if (!emit_vtx) return 1;
        if (!get_context(device_snapshot, af_key, af_bar0, af_pcie_id, why)) return 0;
        dependency_id = "bootstrap.final_barrier";
        if (plan.find_operation("vio.dataplane.qsch.init", qsch_op))
            dependency_id = qsch_op.op_id;
        foreach (vtx_queues[index]) begin
            if (!add_vtx_one(device_snapshot, resource_snapshot, plan,
                             af_pcie_id, af_bar0, vtx_queues[index],
                             dependency_id, why))
                return 0;
        end
        if (require_vtx_vrx_configs) begin
            dpu_vio_qpair_binding_t bindings[$];
            resource_snapshot.list_vio_bindings(bindings);
            foreach (bindings[index]) begin
                bit found;
                found = 0;
                foreach (vtx_queues[qindex])
                    if (vtx_queues[qindex].global_qpair_id ==
                        bindings[index].global_qpair_id) found = 1;
                if (!found) begin
                    why = $sformatf("VTX config missing for qpair %0d",
                                   bindings[index].global_qpair_id);
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    virtual function bit contribute_vrx(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        dpu_function_key_t af_key;
        dpu_bar_pair_lease_t af_bar0;
        dpu_pcie_function_id_t af_pcie_id;
        dpu_reg_op qsch_op;
        string dependency_id;
        why = "";
        if (!emit_vrx) return 1;
        if (!get_context(device_snapshot, af_key, af_bar0, af_pcie_id, why)) return 0;
        dependency_id = "bootstrap.final_barrier";
        if (plan.find_operation("vio.dataplane.qsch.init", qsch_op))
            dependency_id = qsch_op.op_id;
        foreach (vrx_queues[index]) begin
            if (!add_vrx_one(device_snapshot, resource_snapshot, plan,
                             af_pcie_id, af_bar0, vrx_queues[index],
                             dependency_id, why))
                return 0;
        end
        if (require_vtx_vrx_configs) begin
            dpu_vio_qpair_binding_t bindings[$];
            resource_snapshot.list_vio_bindings(bindings);
            foreach (bindings[index]) begin
                bit found;
                found = 0;
                foreach (vrx_queues[qindex])
                    if (vrx_queues[qindex].global_qpair_id ==
                        bindings[index].global_qpair_id) found = 1;
                if (!found) begin
                    why = $sformatf("VRX config missing for qpair %0d",
                                   bindings[index].global_qpair_id);
                    return 0;
                end
            end
        end
        return 1;
    endfunction
endclass : dpu_vio_driver_dataplane_extension

`endif // DPU_VIO_DATAPLANE_PLAN_EXTENSION_SV
