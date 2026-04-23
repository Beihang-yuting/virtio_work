`ifndef VIRTIO_PCI_REGS_SV
`define VIRTIO_PCI_REGS_SV

// ============================================================================
// Virtio PCI Common Configuration Structure offsets
// Per virtio spec Section 4.1.4.3
// ============================================================================

parameter bit [11:0] VIRTIO_PCI_COMMON_DFSELECT      = 12'h00;  // 32-bit, device feature select
parameter bit [11:0] VIRTIO_PCI_COMMON_DF             = 12'h04;  // 32-bit, device feature (RO)
parameter bit [11:0] VIRTIO_PCI_COMMON_GFSELECT       = 12'h08;  // 32-bit, driver(guest) feature select
parameter bit [11:0] VIRTIO_PCI_COMMON_GF             = 12'h0C;  // 32-bit, driver(guest) feature
parameter bit [11:0] VIRTIO_PCI_COMMON_MSIX           = 12'h10;  // 16-bit, config MSI-X vector
parameter bit [11:0] VIRTIO_PCI_COMMON_NUMQ           = 12'h12;  // 16-bit, num_queues (RO)
parameter bit [11:0] VIRTIO_PCI_COMMON_STATUS         = 12'h14;  // 8-bit, device_status
parameter bit [11:0] VIRTIO_PCI_COMMON_CFGGENERATION  = 12'h15;  // 8-bit, config_generation (RO)
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_SELECT       = 12'h16;  // 16-bit, queue_select
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_SIZE         = 12'h18;  // 16-bit, queue_size
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_MSIX         = 12'h1A;  // 16-bit, queue MSI-X vector
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_ENABLE       = 12'h1C;  // 16-bit, queue_enable
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_NOFF         = 12'h1E;  // 16-bit, queue_notify_off (RO)
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_DESCLO       = 12'h20;  // 32-bit, queue desc addr low
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_DESCHI       = 12'h24;  // 32-bit, queue desc addr high
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_AVAILLO      = 12'h28;  // 32-bit, queue avail addr low
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_AVAILHI      = 12'h2C;  // 32-bit, queue avail addr high
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_USEDLO       = 12'h30;  // 32-bit, queue used addr low
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_USEDHI       = 12'h34;  // 32-bit, queue used addr high
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_NDATA        = 12'h38;  // 16-bit, queue notify data (1.2+)
parameter bit [11:0] VIRTIO_PCI_COMMON_Q_RESET        = 12'h3A;  // 16-bit, queue reset (1.2+)

// ============================================================================
// Virtio PCI capability cfg_type values
// Per virtio spec Section 4.1.4
// ============================================================================

parameter bit [7:0] VIRTIO_PCI_CAP_COMMON_CFG    = 8'h01;
parameter bit [7:0] VIRTIO_PCI_CAP_NOTIFY_CFG    = 8'h02;
parameter bit [7:0] VIRTIO_PCI_CAP_ISR_CFG       = 8'h03;
parameter bit [7:0] VIRTIO_PCI_CAP_DEVICE_CFG    = 8'h04;
parameter bit [7:0] VIRTIO_PCI_CAP_PCI_CFG       = 8'h05;

// ============================================================================
// PCI Capability IDs
// ============================================================================

parameter bit [7:0] PCI_CAP_ID_VENDOR   = 8'h09;  // Vendor-Specific (used by virtio)
parameter bit [7:0] PCI_CAP_ID_MSIX     = 8'h11;  // MSI-X
parameter bit [7:0] PCI_CAP_ID_PCIE     = 8'h10;  // PCI Express

// ============================================================================
// MSI-X control register bits
// ============================================================================

parameter int MSIX_CTRL_ENABLE          = 15;
parameter int MSIX_CTRL_FUNC_MASK       = 14;
parameter int MSIX_CTRL_TABLE_SIZE_MASK = 16'h07FF;

// ============================================================================
// PCI Configuration Space offsets (Type 0 header)
// ============================================================================

parameter bit [11:0] PCI_CFG_VENDOR_ID      = 12'h00;  // 16-bit
parameter bit [11:0] PCI_CFG_DEVICE_ID      = 12'h02;  // 16-bit
parameter bit [11:0] PCI_CFG_COMMAND        = 12'h04;  // 16-bit
parameter bit [11:0] PCI_CFG_STATUS         = 12'h06;  // 16-bit
parameter bit [11:0] PCI_CFG_REVISION_ID    = 12'h08;  // 8-bit
parameter bit [11:0] PCI_CFG_CLASS_CODE     = 12'h09;  // 24-bit (prog_if, subclass, class)
parameter bit [11:0] PCI_CFG_CACHE_LINE     = 12'h0C;  // 8-bit
parameter bit [11:0] PCI_CFG_LATENCY_TIMER  = 12'h0D;  // 8-bit
parameter bit [11:0] PCI_CFG_HEADER_TYPE    = 12'h0E;  // 8-bit
parameter bit [11:0] PCI_CFG_BAR0           = 12'h10;  // 32-bit
parameter bit [11:0] PCI_CFG_BAR1           = 12'h14;  // 32-bit
parameter bit [11:0] PCI_CFG_BAR2           = 12'h18;  // 32-bit
parameter bit [11:0] PCI_CFG_BAR3           = 12'h1C;  // 32-bit
parameter bit [11:0] PCI_CFG_BAR4           = 12'h20;  // 32-bit
parameter bit [11:0] PCI_CFG_BAR5           = 12'h24;  // 32-bit
parameter bit [11:0] PCI_CFG_SUBSYS_VID     = 12'h2C;  // 16-bit
parameter bit [11:0] PCI_CFG_SUBSYS_ID      = 12'h2E;  // 16-bit
parameter bit [11:0] PCI_CFG_CAP_PTR        = 12'h34;  // 8-bit, Capabilities Pointer
parameter bit [11:0] PCI_CFG_INT_LINE       = 12'h3C;  // 8-bit
parameter bit [11:0] PCI_CFG_INT_PIN        = 12'h3D;  // 8-bit

// ============================================================================
// PCI Command register bits
// ============================================================================

parameter int PCI_CMD_IO_SPACE          = 0;
parameter int PCI_CMD_MEMORY_SPACE      = 1;
parameter int PCI_CMD_BUS_MASTER        = 2;
parameter int PCI_CMD_INTX_DISABLE      = 10;

// ============================================================================
// PCI Status register bits
// ============================================================================

parameter int PCI_STATUS_CAP_LIST       = 4;   // Capabilities List present

// ============================================================================
// Virtio PCI capability structure sizes (bytes)
// cap_vndr(1) + cap_next(1) + cap_len(1) + cfg_type(1) + bar(1) + id(1) +
// padding(2) + offset(4) + length(4) = 16 bytes
// For notify cap: additional 4 bytes for notify_off_multiplier = 20 bytes
// ============================================================================

parameter int VIRTIO_PCI_CAP_SIZE           = 16;
parameter int VIRTIO_PCI_NOTIFY_CAP_SIZE    = 20;

`endif // VIRTIO_PCI_REGS_SV
