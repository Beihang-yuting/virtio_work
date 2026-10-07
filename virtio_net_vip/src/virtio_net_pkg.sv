// =============================================================================
// virtio_net_pkg.sv
// 目录层次：virtio_net_vip/src，virtio-net UVM VIP 的唯一 package 入口。
// 先导入 net_packet_pkg、host_mem_pkg、PCIe 和资源包，再按类型、共享模型、
// 队列、传输、agent、数据面、SR-IOV 和环境的依赖顺序纳入本地源码。
// 外部 packet 与 Host memory 类只在各自 package 定义一次；本包复导出这些
// 类型以兼容已使用 virtio_net_pkg::* 的调用端。对象仍由环境或调用者创建，
// 本 package 不接管 packet、Host memory 或 PCIe 资源的生命周期。
// =============================================================================

`ifndef VIRTIO_NET_PKG_SV
`define VIRTIO_NET_PKG_SV

package virtio_net_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import net_packet_pkg::*;
  import host_mem_pkg::*;
  import pcie_tl_pkg::*;
  import dpu_resource_pkg::*;

  // 既有外部测试只导入本包；复导出保持其类型名可见，类型身份仍由原包所有。
  // 新接入项目也可直接 import net_packet_pkg::* 和 host_mem_pkg::*。
  export net_packet_pkg::*;
  export host_mem_pkg::*;

  `include "shared/host_mem_bar_reservation_importer.sv"
  `include "pcie/pcie_tl_dpu_reg_backend.sv"

  // ---------------------------------------------------------------------------
  // 第 1 层 – 类型与共享基础（types/、shared/）
  // ---------------------------------------------------------------------------
  `include "types/virtio_net_types.sv"
  `include "types/virtio_net_hdr.sv"
  `include "shared/virtio_wait_policy.sv"
  `include "shared/virtio_memory_barrier_model.sv"

  // ---------------------------------------------------------------------------
  // 第 2 层 – IOMMU 地址翻译模型（iommu/）
  // ---------------------------------------------------------------------------
  `include "iommu/virtio_iommu_model.sv"

  // ---------------------------------------------------------------------------
  // 第 3 层 – Virtqueue 队列引擎（virtqueue/：Split/Packed/Custom）
  // ---------------------------------------------------------------------------
  `include "virtqueue/virtqueue_error_injector.sv"
  `include "virtqueue/virtqueue_base.sv"
  `include "virtqueue/split_virtqueue.sv"
  `include "virtqueue/packed_virtqueue.sv"
  `include "virtqueue/custom_virtqueue.sv"
  `include "virtqueue/virtqueue_manager.sv"

  // Resource clients are transport discovery callbacks and need to be
  // complete before the PCI transport class is compiled.  The snapshot
  // context they consume is compiled first.
  `include "sriov/vio_snapshot_ctx.sv"
  `include "sriov/virtio_resource_client.sv"

  // ---------------------------------------------------------------------------
  // 第 4 层 – virtio-pci 传输层（transport/：BAR 访问/cap 解析/中断）
  // ---------------------------------------------------------------------------
  `include "transport/virtio_pci_regs.sv"
  typedef class virtio_tlm_completion_adapter;
  `include "transport/fabric_bar_layout.sv"
  `include "transport/virtio_bar_accessor.sv"
  `include "transport/virtio_tlm_completion_adapter.sv"
  `include "transport/virtio_pcie_function_endpoint.sv"
  `include "transport/virtio_pci_cap_manager.sv"
  `include "transport/virtio_notification_manager.sv"
  `include "transport/virtio_discovery_strategy.sv"
  `include "transport/virtio_pci_transport.sv"
  `include "dpu_priv/dpu_priv_driver_config.sv"
  `include "transport/virtio_config_backend.sv"
  `include "dpu_priv/dpu_priv_config_backend.sv"

  // ---------------------------------------------------------------------------
  // 第 5 层 – 事务与驱动 agent（types/、agent/）
  // ---------------------------------------------------------------------------
  `include "types/virtio_transaction.sv"
  // The RX responder accepts external net_packet objects, so the byte-stream
  // adapter must be visible before the agent/responder classes are compiled.
  `include "dataplane/virtio_net_packet_adapter.sv"
  `include "agent/virtio_dma_buffer_set.sv"
  `include "agent/virtio_atomic_ops.sv"
  `include "agent/virtio_migration_engine.sv"
  `include "agent/virtio_auto_fsm.sv"
  `include "agent/virtio_driver_protocol.sv"
  `include "agent/virtio_driver.sv"
  `include "agent/virtio_monitor.sv"
  `include "pcie/virtio_pcie_model_dma_adapter.sv"
  `include "pcie/virtio_pcie_iova_host_mem_proxy.sv"
  // 独立设备模型（devmodel/）：只依据 PCIe 请求维护状态，不引用驱动侧对象。
  `include "devmodel/vdev_port.sv"
  `include "devmodel/vdev_base.sv"
  `include "devmodel/vdev_uvm_ep_port.sv"
  `include "devmodel/vdev_virtio_pci.sv"
  `include "pcie/virtio_pcie_dut_responder.sv"
  // REAL_DUT 可选的 RC 侧 Host-memory DMA responder；不生成 virtio
  // 设备行为，只把 EP-originated MemRd/MemWr 交给 RC driver/backend。
  `include "pcie/virtio_pcie_real_dut_host_mem_responder.sv"
  `include "transport/virtio_pcie_observer_adapter.sv"
  `include "agent/virtio_sequencer.sv"
  `include "agent/virtio_driver_agent.sv"

  // ---------------------------------------------------------------------------
  // 第 6 层 – 数据面（dataplane/：TX/RX 引擎与 offload）
  // ---------------------------------------------------------------------------
  `include "dataplane/virtio_csum_engine.sv"
  `include "dataplane/virtio_tso_engine.sv"
  `include "dataplane/virtio_rss_engine.sv"
  `include "dataplane/virtio_offload_engine.sv"
  `include "dataplane/virtio_tx_engine.sv"
  `include "dataplane/virtio_rx_engine.sv"
  `include "dataplane/virtio_net_dataplane.sv"
  // 私有驱动协议安装 dataplane 引擎参数，须在 dataplane 之后编译。
  `include "dpu_priv/dpu_priv_driver_protocol.sv"

  // ---------------------------------------------------------------------------
  // 第 7 层 – SR-IOV PF/VF 编排（sriov/）
  // ---------------------------------------------------------------------------
  `include "sriov/virtio_vf_resource_pool.sv"
  `include "sriov/virtio_function_instance.sv"
  `include "sriov/virtio_vf_instance.sv"
  `include "sriov/virtio_pf_manager.sv"
  `include "sriov/virtio_pf_instance.sv"

  // ---------------------------------------------------------------------------
  // 第 8 层 – 顶层环境（env/）
  // ---------------------------------------------------------------------------
  `include "env/virtio_execution_profile.sv"
  `include "env/virtio_net_env_config.sv"
  `include "env/virtio_scoreboard.sv"
  `include "env/virtio_coverage.sv"
  `include "env/virtio_perf_monitor.sv"
  `include "env/virtio_concurrency_controller.sv"
  `include "env/virtio_dynamic_reconfig.sv"
  `include "env/virtio_net_env.sv"

endpackage : virtio_net_pkg

`endif // VIRTIO_NET_PKG_SV
