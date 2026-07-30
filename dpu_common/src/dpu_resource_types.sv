// =============================================================================
// DPU Fabric resource identities and leases
//
// This file is an include fragment for dpu_resource_pkg.  It remains listed
// before the package in dpu_common.f so shared declarations have an explicit
// dependency order for tools that consume the filelist directly.
// =============================================================================

localparam int unsigned DPU_MAX_HOSTS = 4;
localparam int unsigned DPU_MAX_PFS_PER_HOST = 16;
localparam int unsigned DPU_MAX_VFS_PER_PF = 16;
localparam int unsigned DPU_MAX_FUNCTIONS = 1024;
localparam int unsigned DPU_MAX_VIRTIO_QPAIRS = 2048;
localparam int unsigned DPU_MAX_VIRTIO_QPAIRS_PER_DEVICE = 32;

typedef enum int unsigned {
  DPU_FUNCTION_PF,
  DPU_FUNCTION_VF
} dpu_function_kind_e;

typedef enum int unsigned {
  DPU_RES_FUNCTION,
  DPU_RES_BAR,
  DPU_RES_VIRTIO_QPAIR,
  DPU_RES_VIRTIO_SPECIAL_VQ,
  DPU_RES_RDMA_QP,
  DPU_RES_RDMA_CQ,
  DPU_RES_BLOCK_QUEUE,
  DPU_RES_MSIX_VECTOR,
  DPU_RES_DMA_WINDOW
} dpu_resource_class_e;

typedef enum int unsigned {
  // These roles describe generic function BAR placement, not protocol roles.
  DPU_BAR_FUNCTION_DEVICE,
  DPU_BAR_RESERVED,
  DPU_BAR_MSIX
} dpu_bar_role_e;

// A PF and every VF each identify an independent DPU function.
typedef struct {
  int unsigned host_id;
  int unsigned pf_id;
  dpu_function_kind_e kind;
  int unsigned vf_id;
} dpu_function_key_t;

typedef struct {
  dpu_function_key_t owner;
  int unsigned local_id;
  dpu_resource_class_e class_id;
  int unsigned global_id;
  bit frozen;
} dpu_resource_lease_t;

typedef struct {
  dpu_resource_class_e class_id;
  int unsigned capacity;
  int unsigned max_per_function;
} dpu_resource_pool_config_t;

typedef struct {
  dpu_bar_role_e role;
  int unsigned even_bar_id;
  bit [63:0] base;
  bit [63:0] size;
} dpu_bar_pair_lease_t;
