`ifndef VIRTIO_NET_TYPES_SV
`define VIRTIO_NET_TYPES_SV

// ============================================================================
// virtio_net_types (types)
//
// VIP 的类型地基:virtio(-net) 规范常量(feature 位号、net_hdr 标志、
// 描述符 flag、ctrl-VQ 命令码)、全部公共枚举(事务/错误/状态机/中断
// 模式等)与跨层共享的结构体(SG 链、IOMMU 映射、驱动配置、RSS、迁移
// snapshot 家族),外加 Admin VQ 的上下文类。位于包编译顺序最前端,
// 被 shared/iommu/virtqueue/transport/agent/env 各层依赖;本文件自身
// 只依赖 UVM 与少量前向声明,不 include 其他实现文件。
// 约束:常量取值/枚举编码对齐 virtio 规范,不可随意改动;新枚举成员
// 只能追加,避免破坏已编译测试的 name()/序号假设。
// 无组件、无进程:除 Admin VQ 上下文对象(由 Fabric/调用方创建并注入
// 资源)外,这里的一切都是纯类型,不涉及所有权与生命周期管理。
// ============================================================================

// Forward declarations keep the Admin-VQ context at the type boundary while
// its transport and virtqueue implementations remain in their normal package
// order below this include.
typedef class virtio_iommu_model;
typedef class virtqueue_base;
typedef class virtio_pci_transport;
typedef class virtio_wait_policy;

// ============================================================================
// Feature Bit Parameters (per virtio spec numbering)
// ============================================================================

parameter int VIRTIO_NET_F_CSUM                = 0;
parameter int VIRTIO_NET_F_GUEST_CSUM          = 1;
parameter int VIRTIO_NET_F_CTRL_GUEST_OFFLOADS = 2;
parameter int VIRTIO_NET_F_MTU                 = 3;
parameter int VIRTIO_NET_F_MAC                 = 5;
parameter int VIRTIO_NET_F_GSO                 = 6;
parameter int VIRTIO_NET_F_GUEST_TSO4          = 7;
parameter int VIRTIO_NET_F_GUEST_TSO6          = 8;
parameter int VIRTIO_NET_F_GUEST_ECN           = 9;
parameter int VIRTIO_NET_F_GUEST_UFO           = 10;
parameter int VIRTIO_NET_F_HOST_TSO4           = 11;
parameter int VIRTIO_NET_F_HOST_TSO6           = 12;
parameter int VIRTIO_NET_F_HOST_ECN            = 13;
parameter int VIRTIO_NET_F_HOST_UFO            = 14;
parameter int VIRTIO_NET_F_MRG_RXBUF           = 15;
parameter int VIRTIO_NET_F_STATUS              = 16;
parameter int VIRTIO_NET_F_CTRL_VQ             = 17;
parameter int VIRTIO_NET_F_CTRL_RX             = 18;
parameter int VIRTIO_NET_F_CTRL_VLAN           = 19;
parameter int VIRTIO_NET_F_CTRL_RX_EXTRA       = 20;
parameter int VIRTIO_NET_F_GUEST_ANNOUNCE      = 21;
parameter int VIRTIO_NET_F_MQ                  = 22;
parameter int VIRTIO_NET_F_CTRL_MAC_ADDR       = 23;
parameter int VIRTIO_NET_F_GUEST_USO4          = 54;
parameter int VIRTIO_NET_F_GUEST_USO6          = 55;
parameter int VIRTIO_NET_F_HOST_USO            = 56;
parameter int VIRTIO_NET_F_HASH_REPORT         = 57;
parameter int VIRTIO_NET_F_GUEST_HDRLEN        = 59;
parameter int VIRTIO_NET_F_RSS                 = 60;
parameter int VIRTIO_NET_F_RSC_EXT             = 61;
parameter int VIRTIO_NET_F_STANDBY             = 62;
parameter int VIRTIO_NET_F_SPEED_DUPLEX        = 63;

parameter int VIRTIO_F_RING_INDIRECT_DESC  = 28;
parameter int VIRTIO_F_RING_EVENT_IDX      = 29;
parameter int VIRTIO_F_VERSION_1           = 32;
parameter int VIRTIO_F_ACCESS_PLATFORM     = 33;
parameter int VIRTIO_F_RING_PACKED         = 34;
parameter int VIRTIO_F_IN_ORDER            = 35;
parameter int VIRTIO_F_ORDER_PLATFORM      = 36;
parameter int VIRTIO_F_SR_IOV              = 37;
parameter int VIRTIO_F_NOTIFICATION_DATA   = 38;
parameter int VIRTIO_F_RING_RESET          = 40;
parameter int VIRTIO_F_ADMIN_VQ            = 41;

// ============================================================================
// Net HDR Constants
// ============================================================================

parameter bit [7:0] VIRTIO_NET_HDR_F_NEEDS_CSUM = 8'h01;
parameter bit [7:0] VIRTIO_NET_HDR_F_DATA_VALID  = 8'h02;
parameter bit [7:0] VIRTIO_NET_HDR_F_RSC_INFO    = 8'h04;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_NONE      = 8'h00;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_TCPV4     = 8'h01;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_UDP       = 8'h03;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_TCPV6     = 8'h04;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_UDP_L4    = 8'h05;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_ECN       = 8'h80;

// ============================================================================
// Descriptor Flags
// ============================================================================

parameter bit [15:0] VIRTQ_DESC_F_NEXT            = 16'h0001;
parameter bit [15:0] VIRTQ_DESC_F_WRITE           = 16'h0002;
parameter bit [15:0] VIRTQ_DESC_F_INDIRECT        = 16'h0004;
parameter bit [15:0] VIRTQ_AVAIL_F_NO_INTERRUPT   = 16'h0001;
parameter bit [15:0] VIRTQ_USED_F_NO_NOTIFY       = 16'h0001;
parameter bit [15:0] VIRTQ_DESC_F_AVAIL           = 16'h0080;
parameter bit [15:0] VIRTQ_DESC_F_USED            = 16'h8000;

// ============================================================================
// Control VQ Constants
// ============================================================================

parameter bit [7:0] VIRTIO_NET_CTRL_RX              = 8'h00;
parameter bit [7:0] VIRTIO_NET_CTRL_MAC             = 8'h01;
parameter bit [7:0] VIRTIO_NET_CTRL_VLAN            = 8'h02;
parameter bit [7:0] VIRTIO_NET_CTRL_ANNOUNCE        = 8'h03;
parameter bit [7:0] VIRTIO_NET_CTRL_MQ              = 8'h04;
parameter bit [7:0] VIRTIO_NET_CTRL_RX_PROMISC      = 8'h00;
parameter bit [7:0] VIRTIO_NET_CTRL_RX_ALLMULTI     = 8'h01;
parameter bit [7:0] VIRTIO_NET_CTRL_MAC_TABLE_SET   = 8'h00;
parameter bit [7:0] VIRTIO_NET_CTRL_MAC_ADDR_SET    = 8'h01;
parameter bit [7:0] VIRTIO_NET_CTRL_VLAN_ADD        = 8'h00;
parameter bit [7:0] VIRTIO_NET_CTRL_VLAN_DEL        = 8'h01;
parameter bit [7:0] VIRTIO_NET_CTRL_ANNOUNCE_ACK    = 8'h00;
parameter bit [7:0] VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET = 8'h00;
parameter bit [7:0] VIRTIO_NET_OK                   = 8'h00;
parameter bit [7:0] VIRTIO_NET_ERR                  = 8'h01;

// ============================================================================
// Enumerations
// ============================================================================

typedef enum { VQ_SPLIT, VQ_PACKED, VQ_CUSTOM } virtqueue_type_e;
typedef enum { VQ_RESET, VQ_CONFIGURE, VQ_ENABLED } virtqueue_state_e;

typedef enum bit [7:0] {
    DEV_STATUS_RESET              = 8'h00,
    DEV_STATUS_ACKNOWLEDGE        = 8'h01,
    DEV_STATUS_DRIVER             = 8'h02,
    DEV_STATUS_FEATURES_OK        = 8'h08,
    DEV_STATUS_DRIVER_OK          = 8'h04,
    DEV_STATUS_DEVICE_NEEDS_RESET = 8'h40,
    DEV_STATUS_FAILED             = 8'h80
} device_status_e;

typedef enum { DRV_MODE_AUTO, DRV_MODE_MANUAL, DRV_MODE_HYBRID } driver_mode_e;
typedef enum { RX_MODE_MERGEABLE, RX_MODE_BIG, RX_MODE_SMALL } rx_buf_mode_e;
typedef enum { IRQ_MSIX_PER_QUEUE, IRQ_MSIX_SHARED, IRQ_INTX, IRQ_POLLING } interrupt_mode_e;
typedef enum { DMA_TO_DEVICE, DMA_FROM_DEVICE, DMA_BIDIRECTIONAL } dma_dir_e;
// 设备执行主体和完成通知机制分开建模，避免两种设备行为同时驱动队列。
typedef enum bit [1:0] {
    VIRTIO_EXEC_MODEL    = 2'd0,
    VIRTIO_EXEC_REAL_DUT = 2'd1
} virtio_execution_mode_e;
typedef enum bit [1:0] {
    VIRTIO_COMPLETION_MSIX    = 2'd0,
    VIRTIO_COMPLETION_POLLING = 2'd1
} virtio_completion_mode_e;
// IOVA allocation policy is independent from Host-GPA allocation.  RANDOM is
// the verification default; FIRST_FIT remains available for deterministic
// debug and characterization runs.
typedef enum { IOMMU_IOVA_RANDOM, IOMMU_IOVA_FIRST_FIT } iommu_iova_alloc_policy_e;
typedef enum {
    VIRTIO_MON_BAR_ACCESS,
    VIRTIO_MON_DMA,
    VIRTIO_MON_INTERRUPT,
    VIRTIO_MON_QUEUE_STATE
} virtio_monitor_event_e;

typedef enum {
    FSM_IDLE, FSM_RESETTING, FSM_DISCOVERING, FSM_NEGOTIATING,
    FSM_QUEUE_SETUP, FSM_MSIX_SETUP, FSM_READY, FSM_RUNNING,
    FSM_SUSPENDING, FSM_FROZEN, FSM_ERROR, FSM_RECOVERING,
    FSM_REINIT_REQUIRED
} fsm_state_e;

typedef enum {
    VF_CREATED, VF_CONFIGURED, VF_ACTIVE, VF_FLR, VF_DISABLED,
    VF_REINIT_REQUIRED, VF_RESET_FAILED
} vf_state_e;
typedef enum { FO_NORMAL, FO_PRIMARY_DOWN, FO_SWITCHING, FO_STANDBY_ACTIVE, FO_FAILBACK } failover_state_e;

typedef enum {
    IOMMU_NO_FAULT, IOMMU_FAULT_UNMAPPED, IOMMU_FAULT_PERMISSION,
    IOMMU_FAULT_OUT_OF_RANGE, IOMMU_FAULT_DEVICE_ABORT, IOMMU_FAULT_PAGE_NOT_PRESENT
} iommu_fault_e;

typedef enum {
    VQ_ERR_CIRCULAR_CHAIN, VQ_ERR_OOB_INDEX, VQ_ERR_ZERO_LEN_BUF,
    VQ_ERR_KICK_BEFORE_ENABLE, VQ_ERR_AVAIL_IDX_SKIP, VQ_ERR_WRONG_FLAGS,
    VQ_ERR_INDIRECT_IN_INDIRECT, VQ_ERR_DESC_UNALIGNED,
    VQ_ERR_SKIP_WMB_BEFORE_AVAIL, VQ_ERR_SKIP_RMB_BEFORE_USED, VQ_ERR_SKIP_MB_BEFORE_KICK,
    VQ_ERR_DOUBLE_FREE_DESC, VQ_ERR_USE_AFTER_FREE_DESC, VQ_ERR_STALE_DESC,
    VQ_ERR_DETACH_WHILE_ACTIVE,
    VQ_ERR_AVAIL_RING_OVERFLOW, VQ_ERR_USED_RING_CORRUPT, VQ_ERR_WRONG_USED_LEN,
    VQ_ERR_USE_AFTER_UNMAP, VQ_ERR_WRONG_DMA_DIR,
    VQ_ERR_IOMMU_FAULT_ON_DESC, VQ_ERR_IOMMU_FAULT_ON_DATA,
    VQ_ERR_WRONG_WRAP_COUNTER, VQ_ERR_AVAIL_USED_FLAG_CORRUPT,
    VQ_ERR_KICK_AFTER_DISABLE, VQ_ERR_SPURIOUS_INTERRUPT, VQ_ERR_EVENT_IDX_BACKWARD
} virtqueue_error_e;

// Descriptor/virtqueue fault timing.  The first two points are owned by the
// driver-side queue object; PRE_DEVICE_READ and BEFORE_USED are exposed for a
// model responder or a REAL_DUT Host-memory fault provider.  ANY preserves a
// convenient opt-in mode for users that do not care which boundary consumes
// the configured fault.
typedef enum {
    VQ_FAULT_PRE_NOTIFY,
    VQ_FAULT_POST_NOTIFY,
    VQ_FAULT_PRE_DEVICE_READ,
    VQ_FAULT_BEFORE_USED,
    VQ_FAULT_ANY
} virtqueue_error_phase_e;

// Fields that may be overwritten after a descriptor has been published.  This
// is deliberately separate from virtqueue_error_e: the latter describes the
// semantic fault expected by a test, while this enum describes the exact wire
// bytes changed in shared Host memory.  The split and packed layouts support
// different fields (split has NEXT; packed has ID), and unsupported requests
// are rejected instead of silently changing an unrelated byte.
typedef enum {
    VQ_DESC_FIELD_ADDR,
    VQ_DESC_FIELD_LEN,
    VQ_DESC_FIELD_FLAGS,
    VQ_DESC_FIELD_NEXT,
    VQ_DESC_FIELD_ID
} virtio_desc_corruption_field_e;

typedef enum {
    VIO_TXN_INIT, VIO_TXN_RESET, VIO_TXN_SHUTDOWN,
    VIO_TXN_SEND_PKTS, VIO_TXN_WAIT_PKTS, VIO_TXN_START_DP, VIO_TXN_STOP_DP,
    VIO_TXN_CTRL_CMD, VIO_TXN_SET_MQ, VIO_TXN_SET_RSS,
    VIO_TXN_ATOMIC_OP,
    VIO_TXN_FREEZE, VIO_TXN_RESTORE,
    VIO_TXN_RESET_QUEUE, VIO_TXN_SETUP_QUEUE,
    VIO_TXN_INJECT_ERROR
} virtio_txn_type_e;

typedef enum {
    ATOMIC_SET_STATUS, ATOMIC_READ_STATUS, ATOMIC_SETUP_QUEUE,
    ATOMIC_TX_SUBMIT, ATOMIC_TX_COMPLETE, ATOMIC_RX_REFILL, ATOMIC_RX_RECEIVE,
    ATOMIC_KICK, ATOMIC_POLL_USED, ATOMIC_CTRL_SEND
} virtio_atomic_op_e;

typedef enum {
    SCB_ERR_DATA_MISMATCH, SCB_ERR_CSUM_MISMATCH, SCB_ERR_GSO_SIZE_EXCEED,
    SCB_ERR_FEATURE_VIOLATION, SCB_ERR_SPURIOUS_NOTIFY, SCB_ERR_MISSED_NOTIFY,
    SCB_ERR_DMA_OOB, SCB_ERR_DMA_DIR_MISMATCH, SCB_ERR_DMA_AFTER_UNMAP,
    SCB_ERR_ORDERING_VIOLATION, SCB_ERR_CONFIG_INCONSISTENT, SCB_ERR_UNEXPECTED_RX
} scb_error_e;

typedef enum {
    RACE_BETWEEN_KICK_AND_IRQ, RACE_DURING_QUEUE_RESET,
    RACE_BETWEEN_AVAIL_AND_KICK, RACE_DURING_CONFIG_CHANGE,
    RACE_BETWEEN_MAP_AND_DESC, RACE_DURING_FEATURE_NEGOTIATION, RACE_DURING_FLR
} race_point_e;

typedef enum {
    FAULT_PHASE_DESC_READ, FAULT_PHASE_DATA_READ,
    FAULT_PHASE_DATA_WRITE, FAULT_PHASE_USED_WRITE
} iommu_fault_phase_e;

typedef enum {
    STATUS_ERR_SKIP_ACKNOWLEDGE, STATUS_ERR_SKIP_DRIVER,
    STATUS_ERR_SKIP_FEATURES_OK, STATUS_ERR_DRIVER_OK_BEFORE_FEATURES_OK,
    STATUS_ERR_WRITE_AFTER_FAILED
} status_error_e;

typedef enum {
    FEAT_ERR_PARTIAL_WRITE_LO_ONLY, FEAT_ERR_PARTIAL_WRITE_HI_ONLY,
    FEAT_ERR_WRONG_SELECT_VALUE, FEAT_ERR_USE_UNNEGOTIATED_FEATURE,
    FEAT_ERR_CHANGE_AFTER_FEATURES_OK
} feature_error_e;

typedef enum {
    QSETUP_ERR_ENABLE_BEFORE_ADDR, QSETUP_ERR_SIZE_EXCEEDS_MAX,
    QSETUP_ERR_SIZE_NOT_POWER_OF_2, QSETUP_ERR_ADDR_UNALIGNED,
    QSETUP_ERR_ENABLE_TWICE, QSETUP_ERR_SELECT_OOB_QUEUE
} queue_setup_error_e;

typedef enum {
    VIRTIO_NET_CTRL_ACK_OK  = 0,
    VIRTIO_NET_CTRL_ACK_ERR = 1
} virtio_ctrl_ack_e;

typedef enum bit [7:0] {
    VIRTIO_NET_CTRL_CLS_RX       = 8'h00,
    VIRTIO_NET_CTRL_CLS_MAC      = 8'h01,
    VIRTIO_NET_CTRL_CLS_VLAN     = 8'h02,
    VIRTIO_NET_CTRL_CLS_ANNOUNCE = 8'h03,
    VIRTIO_NET_CTRL_CLS_MQ       = 8'h04
} virtio_ctrl_class_e;

// ============================================================================
// Structs
// ============================================================================

// is_indirect marks an SG entry that already denotes an indirect descriptor
// table.  An add_buf(..., indirect=1) request must reject such an entry rather
// than constructing a nested indirect table.
typedef struct { bit [63:0] addr; int unsigned len; bit is_indirect; } virtio_sg_entry;
typedef struct { virtio_sg_entry entries[$]; } virtio_sg_list;
typedef struct { int unsigned desc_id; int unsigned len; realtime submit_time; realtime complete_time; } virtio_used_info;

// A numeric BDF is scoped by the host/IOMMU requester domain.  Keep the
// domain in every externally visible mapping record so migration and cleanup
// cannot accidentally operate on an equal BDF belonging to another host.
typedef struct {
    int unsigned host_id;
    bit [15:0]   bdf;
    bit [63:0]   gpa, iova;
    int unsigned size;
    dma_dir_e   dir;
    int unsigned desc_id;
} iommu_mapping_t;

// Migration keeps the original VIP token handles so restored completions use
// the normal queue API and return the original request context.
typedef struct {
    int unsigned head_id;
    uvm_object   token;
} virtqueue_token_snapshot_t;

typedef struct {
    int unsigned    head_id;
    iommu_mapping_t mapping;
    int unsigned    byte_size;
    int unsigned    entry_count;
    uvm_object      token;
} virtqueue_indirect_snapshot_t;

typedef struct {
    int unsigned queue_id, queue_size;
    bit [63:0] desc_addr, driver_addr, device_addr;
    int unsigned last_avail_idx, last_used_idx;
    bit avail_wrap, used_wrap;
    byte unsigned ring_data[];
    virtqueue_token_snapshot_t pending_tokens[$];
    virtqueue_indirect_snapshot_t indirect_tables[$];
    // dma_map_buf() mappings are queue-owned independently of submitted
    // request DMA. Restore reattaches their recreated destination GPA while
    // retaining this descriptor-visible source IOVA.
    iommu_mapping_t queue_dma_mappings[$];
    int unsigned split_free_head, split_num_free;
    int unsigned packed_free_ids[$];
} virtqueue_snapshot_t;

typedef struct {
    int unsigned host_id;
    bit [15:0] bdf; bit [63:0] gpa, iova; int unsigned size; dma_dir_e dir; bit valid;
    realtime map_time; string caller_file; int caller_line;
} iommu_mapping_entry_t;

typedef struct {
    // host_id_valid=0 keeps the legacy wildcard behavior for all hosts.
    int unsigned host_id;
    bit host_id_valid;
    bit [15:0] bdf_mask; bit [63:0] iova_start, iova_end;
    dma_dir_e dir; iommu_fault_e fault_type;
    int unsigned trigger_count, triggered;
} iommu_fault_rule_t;

typedef struct {
    bit [7:0] flags, gso_type;
    bit [15:0] hdr_len, gso_size, csum_start, csum_offset;
    bit [15:0] num_buffers;
    bit [31:0] hash_value; bit [15:0] hash_report;
} virtio_net_hdr_t;

typedef struct {
    bit [47:0] mac; bit [15:0] status, max_virtqueue_pairs, mtu;
    bit [31:0] speed; bit [7:0] duplex, rss_max_key_size;
    bit [15:0] rss_max_indirection_table_length; bit [31:0] supported_hash_types;
} virtio_net_device_config_t;

typedef struct { bit [7:0] cap_id, cap_next, cfg_type, bar; bit [31:0] offset, length; } virtio_pci_cap_t;
typedef struct { bit [63:0] msg_addr; bit [31:0] msg_data; bit masked; } msix_entry_t;

typedef struct {
    // Dense software-side Virtio pair ordinal within the function/service.
    // It is intentionally distinct from local_pair, which is the DUT
    // hardware qpair index.
    int unsigned virtio_pair_index;
    int unsigned local_pair;
    int unsigned rx_virtqueue_id;
    int unsigned tx_virtqueue_id;
    // Both directions use the same real-DUT global qpair resource.  The
    // directional field names are retained for compatibility with existing
    // callers; they must always carry equal values.
    int unsigned rx_global_qid;
    int unsigned tx_global_qid;
} virtio_qpair_mapping_t;

typedef struct {
    int unsigned hash_key_size; byte unsigned hash_key[];
    int unsigned indirection_table[]; bit [31:0] hash_types;
} virtio_rss_config_t;

typedef struct {
    int unsigned num_queue_pairs, queue_size;
    int unsigned max_vio_net_qpairs_per_device;
    virtqueue_type_e vq_type; bit [63:0] driver_features;
    rx_buf_mode_e rx_buf_mode; int unsigned rx_buf_size, rx_refill_threshold;
    interrupt_mode_e irq_mode; int unsigned napi_budget, coal_max_packets, coal_max_usecs;
    bit bw_limit_enable; int unsigned bw_limit_mbps; driver_mode_e mode;
} virtio_driver_config_t;

typedef struct {
    realtime desc_fill_time, kick_time, device_start_time, device_done_time;
    realtime interrupt_time, poll_time, complete_time;
} pkt_latency_t;

typedef struct {
    longint unsigned tx_packets, tx_bytes, rx_packets, rx_bytes;
    realtime start_time, end_time;
} perf_stats_t;

typedef struct {
    int unsigned tx_sent, tx_matched, tx_mismatched;
    int unsigned rx_received, rx_matched, rx_mismatched;
    int unsigned csum_errors, gso_errors, feature_errors, notify_errors;
    int unsigned dma_errors, ordering_errors, unexpected_rx;
} scoreboard_stats_t;

typedef struct { int unsigned vf_id; int unsigned local_qid; int unsigned global_qid; string queue_name; } queue_mapping_t;

// A migration record is anchored by its 4 KiB guest page ID.  It carries an
// exact copy of the mapping span within that page, rather than assuming the
// entire page belongs to one host allocation.  The checksum protects that
// transferred payload and lets restore reject a changed mapped byte or
// translation without treating unmapped page bytes (or an allocation tail
// outside the mapping) as migration-owned state.
typedef struct {
    bit [63:0]    page_id;
    iommu_mapping_t mapping;
    bit [63:0]    mapped_gpa;
    int unsigned  mapped_size;
    bit [63:0]    checksum;
    byte          payload[];
} virtio_dirty_page_snapshot_t;

// A complete, mapping-scoped migration copy.  Dirty page records preserve
// device-write generation semantics; this companion record preserves clean
// live DMA mappings still reachable from saved raw queue state (for example,
// outstanding TX and indirect descriptors) across the reset boundary.
typedef struct {
    iommu_mapping_t mapping;
    bit [63:0]      checksum;
    byte            payload[];
} virtio_mapping_snapshot_t;

// One record per normal data-DMA mapping preserves the existing FIFO order
// used by tx_complete()/rx_receive(). Ring and indirect-table state belongs
// to the queue snapshot.
typedef struct {
    int unsigned    queue_id;
    bit             is_tx;
    iommu_mapping_t mapping;
} virtio_normal_dma_snapshot_t;

typedef struct {
    bit [63:0] negotiated_features; bit [7:0] device_status;
    virtio_net_device_config_t net_config;
    virtqueue_snapshot_t queue_snapshots[];
    int unsigned num_queue_pairs;
    int unsigned queue_count;
    bit [63:0] dirty_generation;
    bit [63:0] dirty_pages[$];
    virtio_dirty_page_snapshot_t dirty_page_records[$];
    virtio_mapping_snapshot_t mapping_records[$];
    virtio_normal_dma_snapshot_t normal_dma_records[$];
    // Covers the complete migration-owned state below, including queue bytes,
    // device configuration, generation identity, and dirty payload records.
    // It is intentionally not a security primitive; it detects accidental or
    // test-injected corruption before reset/queue restore can consume it.
    bit [63:0] integrity_checksum;
} virtio_device_snapshot_t;

// A bit-41-only recovery must be delegated to the authoritative PF lifecycle.
// Implementations must invalidate or coordinate normal PF queues and DMA
// before returning reset_complete=1; Admin VQ never assumes that ownership.
virtual class virtio_admin_full_reset_owner extends uvm_object;
    // 构造函数:仅透传名称,无状态可初始化。
    function new(string name = "virtio_admin_full_reset_owner");
        super.new(name);
    endfunction

    // 执行完整 PF 生命周期复位;实现方在完成(含普通队列/DMA 的失效或
    // 协调,见类头英文契约)后置 reset_complete=1。阻塞 task,无超时
    // 约定——挂起与否由实现负责。
    pure virtual task reset_pf_lifecycle(ref bit reset_complete);
endclass : virtio_admin_full_reset_owner

// Admin VQ is deliberately separate from normal PF/VF queue managers.  The
// caller/Fabric injects the special-VQ lease and full-reset owner after
// configuring the device capability; this type does not acquire either.
class virtio_admin_vq_context extends uvm_object;
    `uvm_object_utils(virtio_admin_vq_context)

    virtio_pci_transport  transport;
    virtqueue_base        vq;
    host_mem_manager      mem;
    virtio_iommu_model    iommu;
    virtio_wait_policy    wait_pol;
    bit [63:0]            negotiated_features;
    int unsigned          queue_id;
    int unsigned          response_capacity;
    bit                   configured;
    bit                   special_vq_lease_valid;
    dpu_resource_lease_t  special_vq_lease;
    virtio_admin_full_reset_owner full_reset_owner;
    // Admin commands share one virtqueue, so they must retain exclusive
    // ownership from descriptor construction through completion/recovery.
    semaphore             submit_lock;
    bit                   recovery_required;
    bit                   dma_quarantined;
    bit [63:0]            quarantined_iovas[$];
    bit [63:0]            quarantined_gpas[$];

    // 构造函数:标记为未配置、无 lease、无恢复/隔离状态,并创建容量为 1
    // 的 submit_lock(串行化 Admin 命令);transport/vq/mem 等句柄由
    // 调用方随后注入,本类不创建它们。
    function new(string name = "virtio_admin_vq_context");
        super.new(name);
        queue_id = 0;
        response_capacity = 0;
        configured = 0;
        special_vq_lease_valid = 0;
        negotiated_features = '0;
        submit_lock = new(1);
        recovery_required = 0;
        dma_quarantined = 0;
    endfunction
endclass : virtio_admin_vq_context

`endif // VIRTIO_NET_TYPES_SV
