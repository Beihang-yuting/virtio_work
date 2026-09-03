// =============================================================================
// DPU Fabric resource identities and leases
//
// This file is included only by dpu_resource_pkg so the package owns one
// canonical set of shared declarations.
// =============================================================================

localparam int unsigned DPU_MAX_HOSTS = 4;
localparam int unsigned DPU_MAX_PFS_PER_HOST = 16;
localparam int unsigned DPU_MAX_VFS_PER_PF = 16;
// Lower ten-bit source-ID namespace used by the real driver.
localparam int unsigned DPU_DRIVER_MAX_PF_FUNC = 4;
localparam int unsigned DPU_DRIVER_MAX_VF_PER_PF = 16;
localparam int unsigned DPU_MAX_FUNCTIONS = 1024;
localparam int unsigned DPU_VIO_GLOBAL_QPAIR_ID_WIDTH = 11;
localparam int unsigned DPU_MAX_VIO_GLOBAL_QPAIRS =
    (1 << DPU_VIO_GLOBAL_QPAIR_ID_WIDTH);
localparam int unsigned DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE = 32;
localparam int unsigned DPU_MAX_GLOBAL_MSIX_VECTORS = 256;
localparam int unsigned DPU_MAX_VIO_NOTIFY_ENTRIES_PER_BANK = 1024;
// Driver profile audited on 10.11.10.53.  The hardware field can encode more
// global qids, but this build owns a 128-entry queue bitmap/shadow table and
// appends eleven AF queue resources in this exact layout.
localparam int unsigned DPU_DRIVER_VIO_NOTIFY_ENTRIES_PER_BANK = 128;
localparam int unsigned DPU_DRIVER_AF_EXTRA_QUEUE_COUNT = 11;
localparam int unsigned DPU_DRIVER_AF_ETH_PORT_COUNT = 2;
localparam int unsigned DPU_DRIVER_AF_ETH_QUEUES_PER_PORT = 4;

function automatic bit dpu_decode_af_extra_queue_offset(
    input int unsigned extra_queue_offset,
    output dpu_af_extra_queue_kind_e kind,
    output int unsigned eth_port_id,
    output int unsigned eth_queue_id
);
    kind = DPU_AF_EXTRA_QUEUE_FORWARD;
    eth_port_id = 0;
    eth_queue_id = 0;
    case (extra_queue_offset)
        0: kind = DPU_AF_EXTRA_QUEUE_FORWARD;
        1: kind = DPU_AF_EXTRA_QUEUE_BPDU;
        10: kind = DPU_AF_EXTRA_QUEUE_PTP;
        default: begin
            if ((extra_queue_offset < 2) || (extra_queue_offset > 9))
                return 0;
            kind = DPU_AF_EXTRA_QUEUE_ETH_PORT_NETDEV;
            eth_port_id = (extra_queue_offset - 2) /
                          DPU_DRIVER_AF_ETH_QUEUES_PER_PORT;
            eth_queue_id = (extra_queue_offset - 2) %
                           DPU_DRIVER_AF_ETH_QUEUES_PER_PORT;
            if (eth_port_id >= DPU_DRIVER_AF_ETH_PORT_COUNT)
                return 0;
        end
    endcase
    return 1;
endfunction

typedef enum int unsigned {
  DPU_RESOURCE_KIND_FUNCTION,
  DPU_RESOURCE_KIND_BAR,
  DPU_RESOURCE_KIND_QUEUE,
  DPU_RESOURCE_KIND_INTERRUPT_VECTOR,
  DPU_RESOURCE_KIND_DMA_WINDOW
} dpu_resource_kind_e;

typedef int unsigned dpu_resource_class_id_t;

typedef struct {
  dpu_resource_owner_t owner;
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
