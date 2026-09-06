# Virtio 模拟设备与真实 DUT 双模式设计

## 1. 目标

本设计为 virtio-net 验证环境定义两种互斥的执行模式：

- `VIRTIO_EXEC_MODEL`：没有真实 RTL DUT 时，由环境内的 virtio 设备模拟器完成队列处理、DMA、used ring、报文和中断行为，保证完整回归可以独立运行。
- `VIRTIO_EXEC_REAL_DUT`：接入真实 PCIe DUT 后，环境不主动模拟设备 DMA；真实 DUT 接收 notify、读取 descriptor、发起 PCIe DMA，并由外部 `pcie_work` 与共享 `host_mem` 提供 PCIe 传输和内存响应。

两种模式必须共享 Host memory、PCIe 配置、virtio driver 和测试场景，区别只限于“谁执行设备侧队列和 DMA 行为”。

## 2. 范围与非目标

### 范围

- 保留现有设备行为模拟器，并明确标记为 MODEL 专用。
- 增加统一的执行模式枚举和配置校验。
- MODEL 模式继续覆盖 TX/RX、多队列、满队列、描述符、used ring、MSI-X、轮询、reset、内存回收和大流量。
- REAL_DUT 模式旁路模拟器，由真实 DUT 产生 PCIe TLP。
- PCIe TL VIP 只从外部 `PCIE_WORK_ROOT` 引入，不再依赖本项目内的 PCIe VIP 副本。
- 所有模式复用外部 `host_mem` 对象；每个 Host 使用自己的 manager，多 Root 可以按配置共享同一个 Host manager。

### 非目标

- 不在 virtio 工程中重新实现 PCIe 协议、Completion、Tag、Root routing 或 Host memory manager。
- 不把 MODEL 模式中环境模拟的 IOVA/GPA 转换当作真实 DUT IOMMU 验证结果。
- 本阶段不实现 RDMA、VBLK 或真实 DUT 的生产寄存器 executor。

## 3. 执行模式模型

```systemverilog
typedef enum bit [1:0] {
    VIRTIO_EXEC_MODEL    = 2'd0,
    VIRTIO_EXEC_REAL_DUT = 2'd1
} virtio_execution_mode_e;
```

全局 virtio 环境配置持有：

```systemverilog
virtio_execution_mode_e execution_mode = VIRTIO_EXEC_MODEL;
```

命令行可以覆盖配置：

```text
+VIRTIO_EXEC_MODE=MODEL
+VIRTIO_EXEC_MODE=REAL_DUT
```

未知模式必须在 build/configure 阶段报 fatal；REAL_DUT 模式下如果仍绑定或启动主动设备模拟器，也必须报 fatal，避免两套设备同时驱动同一队列。

## 4. 组件边界

### 4.1 公共层

以下组件在两种模式中都存在并复用：

- virtio PCI capability/configuration transport；
- Host driver、virtqueue 管理器和共享 `host_mem_manager`；
- 外部 `pcie_work/pcie_tl_vip`；
- PCIe topology、BDF、BAR 和 MSI-X 配置；
- virtio monitor、PCIe monitor、scoreboard 和 packet adapter；
- `net_packet` 报文生成和检查。

### 4.2 MODEL 专用层

现有 `virtio_pcie_dut_responder` 作为行为模型保留，后续可由新的 `virtio_device_model` 包装，职责为：

1. 消费 monitor 接受的 virtio notify；
2. 读取和解析 split/packed virtqueue descriptor；
3. 通过 MODEL 专用 PCIe DMA adapter 产生合法 EP-originated MemRd/MemWr；
4. 通过共享 Host memory 完成 TX 数据读取和 RX 数据写入；
5. 更新 used ring；
6. 发送 MSI-X 或支持 polling 完成；
7. 处理队列 reset、取消和 worker 回收。

MODEL DMA adapter 是测试组件，只能生成 PCIe TLP 以模拟设备行为，不能被描述为真实 DUT DMA 验证。

### 4.3 REAL_DUT 专用层

REAL_DUT 模式不启动 MODEL responder 的 notify consumer 和 DMA worker。真实 DUT 通过 PCIe 接口产生 TLP，外部 `pcie_work` 负责：

- 接收和解码 DUT 的 Memory Read/Write；
- 生成 Completion；
- 根据 Root/Host 绑定访问共享 `host_mem`；
- 提供 PCIe monitor、completion 和 ordering 观察接口。

virtio 工程只准备 descriptor、发送 notify、注入或检查 packet、观察 TLP/used ring/MSI-X，并不替代 DUT 执行队列。

## 5. Host memory 规则

- Host memory manager 来自外部 `host_mem` 工程，本工程不创建第二套独立内存模型。
- 每个 `host_id` 对应一个共享 `host_mem_api` 对象。
- 同一个 Host 下的多个 PF/VF、多个业务环境和多个 PCIe Root 可以按显式映射共享该对象。
- 不同 Host 必须使用不同 manager。
- MODEL 与 REAL_DUT 必须使用完全相同的 Host memory binding，保证切换模式不会改变 GPA 分配和数据可见性。

## 6. 完成方式

增加统一的完成方式枚举：

```systemverilog
typedef enum bit {
    VIRTIO_COMPLETION_MSIX    = 1'b0,
    VIRTIO_COMPLETION_POLLING = 1'b1
} virtio_completion_mode_e;
```

- MSI-X 模式：检查 MSI-X table/PBA、向量、used ring 更新顺序和中断 TLP。
- polling 模式：不要求 MSI-X，driver 通过 used index/status 轮询确认完成。
- 两种模式共享同一队列和内存实现，只替换完成通知机制。

## 7. MODEL 回归覆盖

MODEL 模式必须保留并扩展以下场景：

- 单队列和多队列 TX/RX；
- 每个 PF/VF 最大 32 对 virtio queue；
- 队列填满、持续 notify、used ring wraparound；
- split descriptor chain、indirect descriptor、packed virtqueue；
- 随机 packet size、随机 descriptor 链和多队列交错；
- MSI-X 和 polling 收发包；
- RX refill、TX reclaim、reset 后资源回收；
- 几万报文大流量和 Host memory 长时间复用；
- 多 PF/VF 共享 Host memory 以及多 Host 隔离。

每个场景必须检查：PCIe request/completion 配对、DMA 数据一致性、used ring、interrupt/polling 完成、内存分配与释放计数，以及 UVM error/fatal 为零。

## 8. REAL_DUT 验证覆盖

REAL_DUT 模式至少覆盖：

- PCI capability discovery、feature negotiation、queue setup 和 notify；
- 真实 DUT 发起的 descriptor/data DMA Read/Write；
- TX/RX 单队列、多队列和满队列；
- MSI-X 与 polling；
- used ring、reset、reclaim 和大流量；
- PCIe TLP 与 host_mem 数据一致性；
- BDF、BAR、MSI-X vector、Root/Host 映射。

REAL_DUT 测试不能通过 MODEL responder 补发缺失的 DMA，否则测试结果必须标记为失败或配置错误。

## 9. 外部 pcie_work 依赖

- 使用 `PCIE_WORK_ROOT` 指向外部 `pcie_work/pcie_tl_vip`。
- filelist 只能从 `$PCIE_WORK_ROOT/pcie_tl_vip/src` 编译 PCIe VIP。
- `bootstrap.sh` 和 `check_deps.sh` 检查远程仓库 origin、提交和关键源文件。
- 移除本工程对 `virtio_net_vip/ext/pcie_tl_vip` 的编译依赖；保留已有 dirty 子模块的可恢复备份，不直接覆盖用户修改。
- 如果 REAL_DUT 所需的 TLP-to-Host-memory target 接口尚未出现在远程版本，应在 `pcie_work` 增加该能力，而不是复制到 virtio 工程。
- MODEL 专用 DMA 适配接口可以位于 virtio 工程测试层，但不得修改远程 PCIe VIP 的协议语义。

## 10. 验收标准

1. 默认 MODEL 模式下现有真实 driver flow、RX、multiqueue、queue、indirect descriptor、memory reclaim 和大流量测试保持通过。
2. MODEL 模式下 MSI-X 和 polling 测试均能完成，并且满队列运行期间无 descriptor、used ring 或 Host memory 泄漏。
3. REAL_DUT 模式下不会创建或启动主动 MODEL responder；真实 DUT 发出的 TLP 能被外部 `pcie_work` 接收并访问共享 Host memory。
4. 两种模式使用相同 Host memory binding，且不同 Host 的地址空间不会串扰。
5. 主工程不再从本地 PCIe VIP 副本编译源文件，依赖检查能明确报告外部 `pcie_work` 缺失、版本不符或接口不完整。
6. 53 机 VCS 回归中，目标测试无 UVM_ERROR/UVM_FATAL，PCIe request/completion 和数据 mismatch 统计符合预期。
