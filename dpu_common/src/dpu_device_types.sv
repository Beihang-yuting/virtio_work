// =============================================================================
// Canonical DPU device identities, placement records, and BAR roles
// =============================================================================

`ifndef DPU_DEVICE_TYPES_SV
`define DPU_DEVICE_TYPES_SV

typedef enum int unsigned { DPU_FUNCTION_PF, DPU_FUNCTION_VF }
    dpu_function_kind_e;
typedef enum int unsigned { DPU_ALLOC_AUTO, DPU_ALLOC_PINNED }
    dpu_allocation_mode_e;
typedef enum int unsigned {
    DPU_SERVICE_VIO_NET, DPU_SERVICE_RDMA, DPU_SERVICE_VBLK
} dpu_service_kind_e;
typedef enum int unsigned { DPU_AF_SELECTED } dpu_af_selection_mode_e;
typedef enum int unsigned {
    DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX
} dpu_bar_role_e;
typedef enum int unsigned {
    DPU_DEVICE_UNRESOLVED, DPU_DEVICE_RESOLVED,
    DPU_DEVICE_APPLYING, DPU_DEVICE_ACTIVE, DPU_DEVICE_FAILED
} dpu_device_state_e;

typedef struct {
    int unsigned host_id;
    int unsigned pf_id;
    dpu_function_kind_e kind;
    int unsigned vf_id;
} dpu_function_key_t;

typedef struct { int unsigned host_id; int unsigned segment_id; }
    dpu_pcie_domain_key_t;
typedef struct { dpu_pcie_domain_key_t domain; bit [15:0] bdf; }
    dpu_pcie_function_id_t;
typedef struct {
    dpu_function_key_t function_key;
    dpu_service_kind_e service_kind;
    int unsigned service_instance_id;
} dpu_service_key_t;
typedef struct { bit [15:0] first_bdf; bit [15:0] last_bdf; }
    dpu_bdf_range_t;
typedef struct { bit [63:0] base; bit [63:0] limit; }
    dpu_address_range_t;
typedef struct {
    dpu_function_kind_e kind;
    dpu_bar_role_e role;
    int unsigned even_bar_id;
    bit [63:0] size;
    bit [63:0] alignment;
} dpu_bar_profile_t;

function automatic string dpu_function_key_name(input dpu_function_key_t key);
    return $sformatf("h%0d.pf%0d.k%0d.vf%0d", key.host_id, key.pf_id,
                     key.kind, key.vf_id);
endfunction

function automatic string dpu_service_key_name(input dpu_service_key_t key);
    return $sformatf("%s.svc%0d.i%0d", dpu_function_key_name(key.function_key),
                     key.service_kind, key.service_instance_id);
endfunction

function automatic bit dpu_same_function_key(
    input dpu_function_key_t lhs,
    input dpu_function_key_t rhs
);
    return (lhs.host_id == rhs.host_id) && (lhs.pf_id == rhs.pf_id) &&
           (lhs.kind == rhs.kind) && (lhs.vf_id == rhs.vf_id);
endfunction

function automatic bit dpu_same_domain_key(
    input dpu_pcie_domain_key_t lhs,
    input dpu_pcie_domain_key_t rhs
);
    return (lhs.host_id == rhs.host_id) &&
           (lhs.segment_id == rhs.segment_id);
endfunction

`endif // DPU_DEVICE_TYPES_SV
