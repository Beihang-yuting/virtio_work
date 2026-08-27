// =============================================================================
// DPU Fabric resource identities and leases
//
// This file is included only by dpu_resource_pkg so the package owns one
// canonical set of shared declarations.
// =============================================================================

localparam int unsigned DPU_MAX_HOSTS = 4;
localparam int unsigned DPU_MAX_PFS_PER_HOST = 16;
localparam int unsigned DPU_MAX_VFS_PER_PF = 16;
localparam int unsigned DPU_MAX_FUNCTIONS = 1024;
localparam int unsigned DPU_VIO_GLOBAL_QPAIR_ID_WIDTH = 11;
localparam int unsigned DPU_MAX_VIO_GLOBAL_QPAIRS =
    (1 << DPU_VIO_GLOBAL_QPAIR_ID_WIDTH);
localparam int unsigned DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE = 32;
localparam int unsigned DPU_MAX_GLOBAL_MSIX_VECTORS = 256;
localparam int unsigned DPU_MAX_VIO_NOTIFY_ENTRIES_PER_BANK = 1024;

typedef enum int unsigned {
  DPU_RESOURCE_KIND_FUNCTION,
  DPU_RESOURCE_KIND_BAR,
  DPU_RESOURCE_KIND_QUEUE,
  DPU_RESOURCE_KIND_INTERRUPT_VECTOR,
  DPU_RESOURCE_KIND_DMA_WINDOW
} dpu_resource_kind_e;

typedef int unsigned dpu_resource_class_id_t;

typedef struct {
  dpu_function_key_t owner;
  int unsigned local_id;
  dpu_resource_class_id_t class_id;
  int unsigned global_id;
  bit frozen;
} dpu_resource_lease_t;

typedef struct {
  string name;
  dpu_resource_class_id_t class_id;
  dpu_resource_kind_e kind;
  int unsigned capacity;
  int unsigned max_per_function;
} dpu_resource_pool_config_t;

typedef struct {
  dpu_bar_role_e role;
  int unsigned even_bar_id;
  bit [63:0] base;
  bit [63:0] size;
} dpu_bar_pair_lease_t;
