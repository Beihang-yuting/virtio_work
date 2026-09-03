`ifndef DPU_VIO_REG_PLAN_TYPES_SV
`define DPU_VIO_REG_PLAN_TYPES_SV

// Register locations are offsets in the selected AF's device-memory BAR0.
// These values mirror the tables used by the real DPU driver (register.h).
localparam bit [63:0] DPU_VIO_BDF_MAP_BASE       = 64'h0000_0000_0005_6000;
localparam bit [63:0] DPU_VIO_MSIX_TABLE_BASE    = 64'h0000_0000_0004_8000;
localparam bit [63:0] DPU_VIO_MSIX_PBA_BASE      = 64'h0000_0000_0005_0000;
localparam bit [63:0] DPU_VIO_MSIX_INTERVAL_BASE = 64'h0000_0000_0005_2000;
localparam bit [63:0] DPU_VIO_MSIX_INFO_BASE    = 64'h0000_0000_0005_4000;
localparam bit [63:0] DPU_VIO_MSIX_LINEAR_BASE  = 64'h0000_0000_000C_0000;
localparam bit [63:0] DPU_VIO_NOTIFY_BANK0_BASE = 64'h0000_0000_0002_8000;
localparam bit [63:0] DPU_VIO_NOTIFY_BANK1_BASE = 64'h0000_0000_0002_C000;
localparam bit [63:0] DPU_VIO_NOTIFY_COMMIT_ADDR = 64'h0000_0000_0002_0044;
// Function-side notify BAR offset is a policy value.  The AF table itself is
// at DPU_VIO_NOTIFY_BANK{0,1}_BASE.  VIO_NOTIFY_BASE(0) is normally zero.
localparam bit [63:0] DPU_VIO_DEFAULT_FUNCTION_NOTIFY_OFFSET = '0;
localparam bit [63:0] DPU_VIO_NOTIFY_REGION_SIZE = 64'h0000_1000;
localparam int unsigned DPU_VIO_NOTIFY_ENTRY_STRIDE = 16;
localparam int unsigned DPU_VIO_NOTIFY_BANK_STRIDE = 'h4000;
localparam int unsigned DPU_VIO_MSIX_ENTRY_STRIDE = 16;
localparam int unsigned DPU_VIO_TABLE_WORD_STRIDE = 4;
localparam bit [31:0] DPU_VIO_NOTIFY_COMMIT_RDY_MASK = 32'h0000_0001;
localparam bit [31:0] DPU_VIO_NOTIFY_COMMIT_SEL_MASK = 32'h0000_0002;
localparam int unsigned DPU_VIO_NOTIFY_VERIFY_ATTEMPTS = 5;
localparam time DPU_VIO_NOTIFY_VERIFY_INTERVAL = 5us;

typedef struct {
    bit local_qid_net;
    int unsigned local_qid;
    bit local_qid_blk;
    bit [63:0] notify_address;
    int unsigned host_id;
    int unsigned global_qid;
    int unsigned notify_type;
} dpu_vio_notify_entry_cfg_t;

typedef struct {
    int unsigned global_msix_idx;
    bit valid;
} dpu_vio_msix_linear_cfg_t;

typedef struct {
    int unsigned function_id;
    int unsigned host_id;
    bit self_mask;
    bit valid;
} dpu_vio_msix_info_cfg_t;

typedef struct {
    bit [15:0] bdf;
    bit valid;
} dpu_vio_bdf_cfg_t;

// User-selectable lowering policy.  The policy changes how a valid snapshot
// is represented; it never changes topology or allocates IDs.
class dpu_vio_register_plan_policy extends uvm_object;
    `uvm_object_utils(dpu_vio_register_plan_policy)

    int unsigned notify_bank;
    // When set, notify_bank is ignored and the bank opposite the observed
    // active shadow bank is selected.  The explicit mode remains available
    // for bring-up when the caller already knows the inactive bank.
    bit select_inactive_notify_bank;
    int unsigned active_notify_bank;
    int unsigned notify_type;
    int unsigned msix_interval_rate;
    int unsigned msix_interval_packets;
    bit [63:0] notify_address_offset;
    bit msix_self_mask;
    bit emit_msix_interval;
    bit verify_notify_writes;
    int unsigned notify_verify_attempts;
    time notify_verify_interval;
    // When enabled, lower a complete shadow bank image: active entries are
    // followed by driver-compatible invalid entries.  The real driver always
    // programs its complete 128-entry shadow before switching banks, so this
    // is the default; focused plan tests may explicitly request a compact
    // image when stale hardware state is outside their scope.
    bit emit_full_notify_bank;

    function new(string name = "dpu_vio_register_plan_policy");
        super.new(name);
        notify_bank = 0;
        select_inactive_notify_bank = 1;
        active_notify_bank = 0;
        notify_type = 0;
        msix_interval_rate = 0;
        msix_interval_packets = 0;
        notify_address_offset = DPU_VIO_DEFAULT_FUNCTION_NOTIFY_OFFSET;
        msix_self_mask = 0;
        emit_msix_interval = 1;
        verify_notify_writes = 1;
        notify_verify_attempts = DPU_VIO_NOTIFY_VERIFY_ATTEMPTS;
        notify_verify_interval = DPU_VIO_NOTIFY_VERIFY_INTERVAL;
        emit_full_notify_bank = 1;
    endfunction

    function bit validate(output string why);
        why = "";
        if (notify_bank > 1) begin
            why = "VIO notify bank must be 0 or 1";
            return 0;
        end
        if (active_notify_bank > 1) begin
            why = "active VIO notify bank must be 0 or 1";
            return 0;
        end
        if (notify_type > 3) begin
            why = "VIO notify type exceeds the two-bit driver field";
            return 0;
        end
        if (notify_address_offset[6:0] != '0) begin
            why = "function notify address offset must be 128-byte aligned";
            return 0;
        end
        if (notify_address_offset >= DPU_VIO_NOTIFY_REGION_SIZE) begin
            why = "function notify address offset escapes the driver's VIO aperture";
            return 0;
        end
        if (verify_notify_writes && (notify_verify_attempts == 0)) begin
            why = "VIO notify write verification requires a nonzero attempt count";
            return 0;
        end
        if (verify_notify_writes && $isunknown(notify_verify_interval)) begin
            why = "VIO notify write verification interval must be known";
            return 0;
        end
        return 1;
    endfunction

    function bit selected_notify_bank(output int unsigned selected,
                                      output string why);
        if (!validate(why)) begin
            selected = 0;
            return 0;
        end
        selected = select_inactive_notify_bank ?
                   (active_notify_bank ^ 1) : notify_bank;
        why = "";
        return 1;
    endfunction
endclass : dpu_vio_register_plan_policy

// Short name retained for callers that use the plan-oriented terminology.
typedef dpu_vio_register_plan_policy dpu_vio_reg_plan_policy;

function automatic bit dpu_vio_pack_source_id(
    input dpu_function_key_t key,
    output bit [9:0] source_id,
    output string why
);
    int unsigned pfvf_id;

    source_id = '0;
    why = "";
    if (key.host_id > 7) begin
        why = "VIO source ID host_id exceeds the three-bit driver field";
        return 0;
    end
    if (key.kind == DPU_FUNCTION_PF) begin
        if ((key.pf_id >= DPU_DRIVER_MAX_PF_FUNC) || (key.vf_id != 0)) begin
            why = "PF source ID is outside the driver PF namespace";
            return 0;
        end
        pfvf_id = key.pf_id;
    end else if (key.kind == DPU_FUNCTION_VF) begin
        if ((key.pf_id >= DPU_DRIVER_MAX_PF_FUNC) ||
            (key.vf_id >= DPU_DRIVER_MAX_VF_PER_PF)) begin
            why = "VF source ID is outside the driver VF namespace";
            return 0;
        end
        pfvf_id = DPU_DRIVER_MAX_PF_FUNC +
            key.pf_id * DPU_DRIVER_MAX_VF_PER_PF + key.vf_id;
    end else begin
        why = "VIO source ID has an invalid function kind";
        return 0;
    end
    if (pfvf_id > 10'h3ff) begin
        why = "VIO source ID exceeds the ten-bit driver namespace";
        return 0;
    end
    source_id = pfvf_id[9:0];
    return 1;
endfunction

function automatic bit dpu_vio_compute_srcid(
    input dpu_function_key_t key,
    output int unsigned srcid,
    output string why
);
    bit [9:0] pfvf_id;

    srcid = 0;
    if (!dpu_vio_pack_source_id(key, pfvf_id, why))
        return 0;
    srcid = (key.host_id << 10) | pfvf_id;
    return 1;
endfunction

function automatic bit dpu_vio_pack_bdf_entry(
    input dpu_vio_bdf_cfg_t cfg,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    payload[15:0] = cfg.bdf;
    payload[31:16] = cfg.valid ? 16'h0001 : 16'h0000;
    return 1;
endfunction

function automatic bit dpu_vio_pack_msix_linear_entry(
    input dpu_vio_msix_linear_cfg_t cfg,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if (cfg.global_msix_idx > 11'h7ff) begin
        why = "global MSI-X index exceeds the eleven-bit driver field";
        return 0;
    end
    payload[10:0] = cfg.global_msix_idx[10:0];
    payload[11] = cfg.valid;
    return 1;
endfunction

function automatic bit dpu_vio_pack_msix_info_entry(
    input dpu_vio_msix_info_cfg_t cfg,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if (cfg.function_id > 8'hff) begin
        why = "MSI-X function ID exceeds the eight-bit driver field";
        return 0;
    end
    if (cfg.host_id > 3'h7) begin
        why = "MSI-X host ID exceeds the three-bit driver field";
        return 0;
    end
    payload[7:0] = cfg.function_id[7:0];
    payload[10:8] = cfg.host_id[2:0];
    payload[11] = cfg.self_mask;
    payload[12] = cfg.valid;
    return 1;
endfunction

function automatic bit dpu_vio_pack_msix_interval(
    input int unsigned rate,
    input int unsigned packet_count,
    output bit [31:0] payload,
    output string why
);
    payload = '0;
    why = "";
    if ((rate > 16'hffff) || (packet_count > 16'hffff)) begin
        why = "MSI-X interval rate/packet count exceeds the 16-bit fields";
        return 0;
    end
    payload[15:0] = rate[15:0];
    payload[31:16] = packet_count[15:0];
    return 1;
endfunction

function automatic bit dpu_vio_pack_notify_entry(
    input dpu_vio_notify_entry_cfg_t cfg,
    output bit [63:0] low_word,
    output bit [63:0] high_word,
    output string why
);
    bit [63:0] addr;

    low_word = '0;
    high_word = '0;
    why = "";
    if (cfg.local_qid > 5'h1f) begin
        why = "VIO notify local qid exceeds the five-bit driver field";
        return 0;
    end
    if (cfg.host_id > 3'h7) begin
        why = "VIO notify host ID exceeds the three-bit driver field";
        return 0;
    end
    if (cfg.global_qid > 11'h7ff) begin
        why = "VIO notify global qid exceeds the eleven-bit driver field";
        return 0;
    end
    if (cfg.notify_type > 2'h3) begin
        why = "VIO notify type exceeds the two-bit driver field";
        return 0;
    end
    addr = cfg.notify_address;
    if ((addr[6:0] != '0) || (addr[63:61] != '0)) begin
        why = "VIO notify address must be 128-byte aligned and fit bits 60:7";
        return 0;
    end
    low_word[0] = cfg.local_qid_net;
    low_word[5:1] = cfg.local_qid[4:0];
    low_word[6] = cfg.local_qid_blk;
    low_word[31:7] = addr[31:7];
    // dpu_vio_notify_tbl is four DWORDs.  The first 64-bit write contains
    // DWORD0 (local/address-low) and DWORD1 (address-high/host); the second
    // contains DWORD2 (global/type) and reserved DWORD3.
    low_word[60:32] = addr[60:32];
    low_word[63:61] = cfg.host_id[2:0];
    high_word[10:0] = cfg.global_qid[10:0];
    high_word[12:11] = cfg.notify_type[1:0];
    return 1;
endfunction

// The driver initializes every unused shadow-bank entry to this exact image
// (all ones except type/reserved fields).  Keeping a pure packer here allows
// a caller that wants a complete bank image to clear stale entries without
// fabricating a valid queue binding.
function automatic bit dpu_vio_pack_invalid_notify_entry(
    output bit [63:0] low_word,
    output bit [63:0] high_word,
    output string why
);
    low_word = 64'hffff_ffff_ffff_ffff;
    high_word = 64'h0000_0000_0000_07ff;
    why = "";
    return 1;
endfunction

`endif // DPU_VIO_REG_PLAN_TYPES_SV
