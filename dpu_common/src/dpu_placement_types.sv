`ifndef DPU_PLACEMENT_TYPES_SV
`define DPU_PLACEMENT_TYPES_SV

typedef enum int unsigned {
    DPU_VIO_CANDIDATE_PF_ONLY, DPU_VIO_CANDIDATE_VF_ONLY,
    DPU_VIO_CANDIDATE_PF_AND_VF
} dpu_vio_candidate_kind_e;

typedef enum int unsigned {
    DPU_VIO_DEVICE_AUTO_MINIMUM, DPU_VIO_DEVICE_FIXED,
    DPU_VIO_DEVICE_ALL_ELIGIBLE
} dpu_vio_device_policy_e;

typedef enum int unsigned {
    DPU_PLACEMENT_CANONICAL, DPU_PLACEMENT_SEEDED_RANDOM
} dpu_placement_order_e;

typedef enum int unsigned { DPU_COUNT_EXACT, DPU_COUNT_AT_LEAST }
    dpu_count_constraint_mode_e;

typedef enum int unsigned {
    DPU_ASSIGN_AUTO, DPU_ASSIGN_PINNED, DPU_ASSIGN_PREFERRED
} dpu_assignment_mode_e;

typedef enum int unsigned {
    DPU_RESOURCE_OWNER_FUNCTION, DPU_RESOURCE_OWNER_SERVICE
} dpu_resource_owner_kind_e;

typedef enum int unsigned {
    DPU_PLACE_STAGE_NONE, DPU_PLACE_STAGE_INPUT, DPU_PLACE_STAGE_SELECTION,
    DPU_PLACE_STAGE_DEVICE_RESOLUTION, DPU_PLACE_STAGE_RESOURCE_RESOLUTION,
    DPU_PLACE_STAGE_CROSS_SNAPSHOT
} dpu_placement_stage_e;

typedef enum int unsigned {
    DPU_PLACE_ERR_NONE,
    DPU_PLACE_ERR_INVALID_PROFILE,
    DPU_PLACE_ERR_DUPLICATE_REQUEST,
    DPU_PLACE_ERR_INVALID_REQUEST,
    DPU_PLACE_ERR_INVALID_FILTER,
    DPU_PLACE_ERR_INVALID_VF_POOL,
    DPU_PLACE_ERR_SOURCE_VIO_SERVICE,
    DPU_PLACE_ERR_NO_ELIGIBLE_DEVICE,
    DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
    DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
    DPU_PLACE_ERR_DUPLICATE_SERVICE_OWNER,
    DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
    DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
    DPU_PLACE_ERR_INVALID_RESERVATION,
    DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
    DPU_PLACE_ERR_GLOBAL_QID_RESERVED,
    DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
    DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED,
    DPU_PLACE_ERR_DEVICE_RESOLUTION_FAILED,
    DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH
} dpu_placement_error_e;

typedef struct {
    dpu_resource_owner_kind_e kind;
    dpu_function_key_t function_key;
    dpu_service_key_t service_key;
} dpu_resource_owner_t;

typedef struct { int unsigned first_id; int unsigned last_id; }
    dpu_global_id_range_t;

typedef struct {
    int unsigned request_id;
    dpu_service_key_t service_key;
    int unsigned qpair_count;
} dpu_vio_participant_target_t;

typedef struct {
    int unsigned request_pair_index;
    dpu_service_key_t service_key;
    dpu_assignment_mode_e local_mode;
    int unsigned requested_local_pair_id;
    dpu_assignment_mode_e global_mode;
    int unsigned requested_global_qpair_id;
} dpu_normalized_vio_pair_t;

typedef struct {
    int unsigned request_id;
    int unsigned request_pair_index;
    dpu_service_key_t service_key;
    // Dense software-side pair ordinal within this VIO service.  This is
    // independent from local_pair_id, which is the placement/resource label.
    int unsigned virtio_pair_index;
    int unsigned local_pair_id;
    // Virtio-net protocol queue IDs.  RX/TX are the two directions of one
    // hardware qpair and are derived from virtio_pair_index in the standard
    // profile (2*p and 2*p+1).
    int unsigned rx_local_virtqueue_id;
    int unsigned tx_local_virtqueue_id;
    int unsigned global_qpair_id;
    // Local MSI-X vector index consumed by the driver's function interrupt
    // array.  It is kept explicit so a future shared-vector policy can map
    // several qpairs to one vector without changing the register builder.
    int unsigned local_msix_vector_id;
    // Resolved global MSI-X vector selected by the resource allocator.  The
    // register-plan builder consumes this binding and must never renumber it.
    int unsigned global_msix_vector_id;
} dpu_vio_qpair_binding_t;

// The real driver appends these AF-owned queue pairs after the ordinary LAN
// queue pairs in func_res->txrx_queues[].  They are control/dataplane
// resources, not guest-visible Virtio queues, so they use a separate binding
// type and are never published through virtio_resource_client.
typedef enum int unsigned {
    DPU_AF_EXTRA_QUEUE_FORWARD,
    DPU_AF_EXTRA_QUEUE_BPDU,
    DPU_AF_EXTRA_QUEUE_ETH_PORT_NETDEV,
    DPU_AF_EXTRA_QUEUE_PTP
} dpu_af_extra_queue_kind_e;

typedef struct {
    dpu_function_key_t af_function_key;
    dpu_af_extra_queue_kind_e kind;
    int unsigned extra_queue_offset;
    int unsigned local_queue_index;
    int unsigned global_qpair_id;
    int unsigned local_msix_vector_id;
    int unsigned global_msix_vector_id;
    int unsigned eth_port_id;
    int unsigned eth_queue_id;
} dpu_af_extra_queue_binding_t;

`endif // DPU_PLACEMENT_TYPES_SV
