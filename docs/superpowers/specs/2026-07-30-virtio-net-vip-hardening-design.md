# Virtio-Net VIP 工程化与功能补齐设计

## 目标

将当前 virtio-net UVM VIP 从依赖机器本地绝对符号链接、需测试自行接线的 TLM 自测工程，提升为可复现构建、可复用集成、具备被动检查闭环的验证 IP。实现既有功能缺口：间接描述符、Admin VQ、热迁移 dirty-page 校验和 SVA 协议断言。

同时交付协议无关的 DPU Fabric 资源管理层。virtio-net 是第一个 client；后续 RDMA 与 virtio-blk 通过同一资源租约接口接入，不将它们的语义硬编码进 virtio package。

本设计不实现或伪造 virtio DUT RTL。真实 DUT 验证仍通过现有 SV-interface 模式进行。

## 外部依赖与安全

`virtio_net_vip/ext/` 使用 Git submodule 固定以下公开仓库的当前 `main` 提交：

| 路径 | 仓库 | 固定提交 |
|---|---|---|
| `ext/pcie_tl_vip` | `https://github.com/Beihang-yuting/pcie_work.git` | `6913793a42dc58873935f802fab50a395ab56ff3` |
| `ext/host_mem` | `https://github.com/Beihang-yuting/host_mem.git` | `ef056b331047f51125c2aaf248a8767b9b84862a` |
| `ext/net_packet` | `https://github.com/Beihang-yuting/net_packet.git` | `e2af70204f53ede65e366c7a65f695c59acdbbc5` |

失效的绝对符号链接将被 submodule gitlink 替代。所有 remote URL、`.gitmodules` 和脚本只使用无令牌 HTTPS URL。构建不修改外部仓库，submodule SHA 是唯一的依赖锁定记录。

## DPU Fabric 拓扑与全局资源权威

新增不依赖 virtio、RDMA 或 block package 的 `dpu_resource_pkg`，以及拥有它的 `dpu_fabric_env`。资源管理器是共享 `uvm_object` 服务，不是主动传输 TLP 的 UVM agent；协议环境以 client 方式向它申请和释放租约。

硬件拓扑与硬性上限如下：

| 资源 | 上限 | 含义 |
|---|---:|---|
| Host | 4 | 独立 host/root-complex 域 |
| PF/Host | 16 | 每个 host 可枚举的 PF 数 |
| VF/PF | 16 | 单 PF 的局部 VF 能力上限 |
| Function/DPU | 1024 | PF 与 VF 合并计数的激活 function 上限 |
| virtio QP/DPU | 2048 | 每个 QP 固定包含一个 RX 与一个 TX 队列 |
| virtio QP/device | 32 | 单 virtio device 最多申请的 TX/RX queue pair 数 |

64 个 PF（4 host × 16 PF）本身已占用 64 个 function slot。因此全部 PF 激活时，DPU 最多再激活 960 个 VF；`16 VF/PF` 是局部能力而非可在全部 64 个 PF 同时达到的全局保证。配置验证在创建任何 function 前检查 `active_pf_count + active_vf_count <= 1024`。

Fabric 使用层次 function key：`(host_id, pf_id, function_kind={PF,VF}, vf_id_or_none)`。每个 PF 和 VF 都是独立的 function，拥有自己的 virtio device、BAR binding、transport、agent、virtqueue manager 和 dataplane。每个 virtio device 恰好绑定一个 BAR lease；PCIe function manager 提供 BDF/BAR 信息，DPU manager 记录并验证唯一性。

资源服务只管理身份、容量、配额、亲和性、状态和 lease，不理解协议报文。通用资源类型包括 function、BAR、queue、interrupt vector 和 DMA window；协议以 resource-class 注册其特定资源。virtio-net 的 global QP allocator 是该服务上的协议 adapter，RDMA 和 virtio-blk 将来注册各自的 QP/CQ 或 block queue class，而无需修改 allocator 的通用生命周期逻辑。

virtio 数据队列以 QP 原子租约分配：

`(function_key, virtio_device, local_pair_id[0..31]) -> (global_qpair_id[0..2047], global_rx_qid, global_tx_qid)`。

`global_rx_qid` 和 `global_tx_qid` 是由同一 QP lease 派生的方向性逻辑标识，不能分配给不同 device。创建 function 时不预留 QP；device 在协商和 queue setup 时按需申请。因而 64 个 device 可以各开满 32 QP，或 2048 个 device 各申请 1 QP。FLR、device reset、迁移和 SR-IOV disable 必须执行相应的冻结、恢复或释放操作。Control VQ 与 Admin VQ 使用明确的 special-VQ resource class 和独立容量配置，绝不隐式消耗或绕开数据 QP 池。

当前 `virtio_vf_resource_pool` 仅为 virtio client 的本地映射视图；它不再分配全局 ID。其 mapping key 扩展为完整 function key 与 `local_qid`，global QP allocator 才是 global ID 的唯一来源。

## 构建与运行接口

新增根目录 `Makefile` 与 `scripts/`：

- `make bootstrap`：初始化、同步并校验所有 submodule。
- `make check-deps`：验证依赖源文件、VCS 安装路径和 UVM 配置，失败时给出修复命令。
- `make compile`：按确定性 filelist 编译 package 与指定测试。
- `make test TEST=<uvm_test>`：编译后运行单个 UVM 测试。
- `make regression`：运行单元、协议、监控、队列、迁移、TLM 集成和覆盖率回归。

脚本根据当前仓库根目录生成路径，不持久化绝对工作区路径。filelist 明确外部 package、interface、VIP package 和测试的依赖顺序；README 只引用这些入口，不再维护一份会漂移的超长 VCS 命令。

## PCIe 集成与 Completion Bridge

引入公共 PCIe binding 层，替代端到端测试复制共享对象、transport、driver 和 monitor 接线的做法。

1. `virtio_vf_instance` 重构为可同时表示 PF 与 VF 的 `virtio_function_instance`；PF 实例不再伪装为 VF。每个 `virtio_pf_instance` 持有独立 PF function、其 `virtio_pf_manager` 与所属 VF function array。
2. `virtio_vf_instance::wire_shared()` 的后继 API 与虚拟 sequencer 使用实际的 `uvm_sequencer #(pcie_tl_tlp)` 类型。
3. `virtio_net_env::bind_pcie()` 接收 RC sequencer、DPU resource manager 和可选 TLM adapter，向每个已激活 function 一次性注入 host memory、IOMMU、barrier、queue manager、transport、atomic ops、FSM、driver 和 monitor 引用。
4. 现有 TLM completion shim、bridge 和 bridged BAR sequences 移入 transport 源码，作为 `virtio_tlm_completion_adapter`。TLM 测试通过 adapter 启用它；SV-interface/DUT 模式不启用它。
5. 所有集成测试改为调用公共 binding、Fabric resource lease 与 adapter API，不再复制实现细节。

绑定缺失、类型不匹配或 completion 超时必须产生带上下文的 UVM fatal/error，不能静默继续。

## Monitor、Scoreboard、Coverage 与 SVA

新增 PCIe TLP observer adapter，将外部 PCIe VIP 的 RC/EP 事务流映射为以下抽象事件：BAR 读写、DMA 读写、notify、MSI-X 和 queue lifecycle。`virtio_monitor` 以 analysis FIFO 接收这些事件，完成现有四个空任务：状态迁移、feature 使用、队列协议、DMA 边界和中断/通知关联；每个已解码事件广播为 `virtio_transaction`。

`virtio_net_env` 将 monitor 主事务流连接到现有 scoreboard 与 coverage。新增覆盖率回归，明确启用 8 组 covergroup，并对状态、队列类型、通知、错误和 SR-IOV 交叉项采样。

新增抽象协议事件接口与 SVA checker。TLM adapter 与 SV-interface adapter 都驱动同一组事件；断言检查状态单调迁移、FEATURES_OK 在 DRIVER 后、DRIVER_OK 在 FEATURES_OK 后、queue 在 enable 前完成配置、notify 只针对有效队列，以及完成不早于提交。断言失败和 monitor 错误都被计入 UVM 报告。

## 功能补齐

### Indirect descriptors

Split 和 packed virtqueue 在 `add_buf(..., indirect=1)` 时分配独立的 DMA 对齐间接描述符表，按传入 SG 链构造描述符，并在主 ring 放置单个带 `VIRTQ_DESC_F_INDIRECT` 的描述符。完成、reset、detach 和 error path 都释放表、IOMMU 映射和 token 元数据。实现拒绝零项、嵌套间接、地址/长度溢出及队列资源不足。

### Admin VQ

PF manager 保存独立的 Admin VQ transport/queue 上下文。`admin_cmd()` 使用请求与响应 buffer 构造描述符链、提交、kick、带超时等待 completion，并解析设备返回状态；非法 VF、未协商 feature、未配置 Admin VQ、设备错误及超时均返回明确失败。Admin VQ 的创建、配置和生命周期遵从已协商 feature 与设备能力。

### 迁移 dirty pages

设备 snapshot 扩展为 dirty-page 集合及捕获世代。迁移 freeze 启用 dirty tracking、停止数据面、保存队列状态并原子获取 dirty pages；restore 在恢复队列后校验保存页的内容和 IOMMU 映射，再重启数据面。迁移测试写入跨页数据、验证页面集合、验证 clean restore，以及验证损坏/遗漏页必定报错。

## 测试策略与验收条件

每一项先添加失败测试，再实现功能：

- 依赖回归验证 submodule SHA、缺失依赖诊断和 token-free remote URL。
- PCIe 集成测试仅调用 `bind_pcie()`，不得包含复制的接线逻辑；TLM bridge 覆盖 read/write completion 与超时。
- monitor 单元测试用合成 TLP 覆盖 BAR、DMA、notify、MSI-X 与非法状态；scoreboard/coverage 集成测试确认事务可达。
- Split 与 packed indirect descriptor 正常、回收、错误注入和泄漏测试。
- Admin VQ 成功、设备拒绝、非法 VF 和 completion timeout 测试。
- 迁移 dirty-page 正反向测试及 SVA pass/fail 测试。
- Fabric 拓扑测试：4 host、16 PF/host、PF/VF 合并 1024 function 边界、16 VF/PF 局部上限和全局 960 VF 余量。
- QP allocator 测试：2048 QP 耗尽、32 QP/device 上限、不同 function 的 local-q 重名、RX/TX 不可拆分、FLR/迁移后的 lease 回收与 BAR 唯一性。
- 跨协议 client contract 测试：virtio client 与模拟 RDMA/block client 在同一 manager 下申请不同 resource class，验证不发生 ID 或配额串扰。

完成条件为：`make check-deps`、全部可用的 VCS 回归、git diff 检查和 submodule 状态检查通过；若执行环境没有 VCS，则必须明确报告该外部限制，并完成所有无需 VCS 的静态与依赖验证。

## 非目标

- 不修改或 vendor 三个外部仓库。
- 不提交访问令牌，不推送远端，也不改变外部仓库分支。
- 不提供 DUT RTL，也不将 TLM 回环结果表述为真实 DUT 合规性证明。
- 不创建伪造的 RDMA 或 virtio-blk 驱动；本次只交付它们所需的协议无关 Fabric 接口及 virtio-net client 实现。
