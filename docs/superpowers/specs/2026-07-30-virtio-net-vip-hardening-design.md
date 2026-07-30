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
| virtio client QP profile/DPU | 2048 | virtio client 注册 queue class 时使用的容量，不是 DPU 类型 enum/常数 |
| virtio client QP profile/device | 32 | 同一注册 profile 的每-function 上限，不是 DPU 类型 enum/常数 |

64 个 PF（4 host × 16 PF）本身已占用 64 个 function slot。因此全部 PF 激活时，DPU 最多再激活 960 个 VF；`16 VF/PF` 是局部能力而非可在全部 64 个 PF 同时达到的全局保证。配置验证在创建任何 function 前检查 `active_pf_count + active_vf_count <= 1024`。

Fabric 使用层次 function key：`(host_id, pf_id, function_kind={PF,VF}, vf_id_or_none)`。每个 PF 和 VF 都是独立的 function，拥有自己的 virtio device、BAR binding、transport、agent、virtqueue manager 和 dataplane。PCIe function manager 提供 BDF/config-space 访问；DPU manager 是 BAR 地址分配与唯一性检查的权威。

资源服务只管理身份、容量、配额、亲和性、状态和 lease，不理解协议报文。core 仅定义 `dpu_resource_kind_e={FUNCTION,BAR,QUEUE,INTERRUPT_VECTOR,DMA_WINDOW}` 与 opaque `dpu_resource_class_id_t`。`dpu_fabric_env` 是唯一的 resource-class 注册 owner：它在 build/configuration 阶段、任何 function activation 前读取 `dpu_resource_pool_config_t` profile，逐个调用 `register_resource_class(string name, dpu_resource_kind_e kind, int unsigned capacity, int unsigned max_per_function, output dpu_resource_class_id_t class_id, output string why)`，将返回 ID 写回/inject 到 client，并在所有 profile 完成后封存 registry。`name` 是 Fabric 配置提供的 opaque label，manager 不内置、不匹配也不从中推导 virtio/RDMA/block 语义；相同 name+kind+capacity+quota 的注册幂等返回同一 ID，同 name 的冲突 profile 失败，封存后未知 profile 失败。client 只能 `lookup_resource_class(name, class_id, why)` 或接收 Fabric 注入的 ID；`acquire_leases` 与 `release_leases` 只接收该 ID。virtio-net 将其 queue-class lease 映射为 RX/TX 逻辑队列；RDMA 和 virtio-blk 将来只增加 profile data，而无需修改通用生命周期逻辑。

### BAR-first function activation

每个激活的 PF/VF function 先在由配置给出的 64-bit MMIO aperture 中获得三个 64-bit BAR pair。一个 pair 的偶数 BAR 保存 64-bit base/size，奇数 BAR 仅为该 BAR 的高 32 位 config-space slot，不能作为独立 aperture 分配。所有 base 必须按自身 size 对齐，任何 pair 不得重叠。资源管理器只将 BAR role 标为 `FUNCTION_DEVICE`、`RESERVED` 或 `MSIX`；当前 virtio client 在 `FUNCTION_DEVICE` window 内发现 virtio capability。

| Function | BAR0/1 | BAR2/3 | BAR4/5 |
|---|---:|---:|---:|
| PF | virtio device, 32 MiB | reserved, 64 KiB | MSI-X table/PBA, 64 KiB |
| VF | virtio device, 16 KiB | reserved, 16 KiB | MSI-X table/PBA, 32 KiB |

`dpu_resource_manager::activate_function()` 顺序为：验证 function 容量与层次 → 分配并记录三个 BAR pair → 将 BAR 值写入 PCI config space → 将 BAR0/1 绑定为该 function 唯一的 device window、BAR4/5 绑定为该 function 的 MSI-X table/PBA aperture → client 在 BAR0/1 内完成 device capability discovery → 允许该 function 的动态资源 lease。对于本次 virtio client，动态资源是 QP 与 MSI-X vector。

BAR2/3 始终消耗地址空间，但没有 function、transport 或 MSI-X binding；它既不是 device window，也不是 MSI-X window，不能经由功能性 accessor 读写。直接到达 BAR2/3 的 PCIe memory transaction 由 monitor 作为 reserved-BAR violation 报错；BAR0/1 的普通 device MMIO 与 BAR4/5 的 MSI-X table/PBA MMIO 必须分别按其角色解码和检查。FLR 保留 function/BAR ownership，SR-IOV disable 或 function destroy 才释放 BAR lease；迁移 freeze/restore 保留原地址。

MMIO aperture 的 `base` 与 `limit` 是 `dpu_fabric_env_config` 的必填 64-bit 配置，且不得与 host DMA memory region 重叠。全部 64 PF 和 960 VF 激活时，三组 BAR window 共需要 2,116 MiB：PF 为 2,056 MiB，VF 为 60 MiB；配置验证需在激活前确认 aperture 容量充足。

### virtio QP allocation after BAR discovery

virtio 数据队列以 QP 原子租约分配：

`(function_key, virtio_device, local_pair_id[0..31]) -> (global_qpair_id[0..2047], global_rx_qid, global_tx_qid)`。

`global_rx_qid` 和 `global_tx_qid` 是由同一 QP lease 派生的方向性逻辑标识，不能分配给不同 device。创建 function 时不预留 QP；`dpu_fabric_env` 在 activation 前一次性从 profile data 注册 `name="virtio.qpair"`, `kind=DPU_RESOURCE_KIND_QUEUE`, `capacity=2048`, `max_per_function=32`，封存 registry，并把唯一的 `virtio_qpair_class_id` 注入或供 client lookup。2048 与 32 是这个 client profile 的数值，不属于 DPU core 类型。BAR0/1 分配、写入 config space 并成功发现 virtio capability 后，virtio client 只能使用该同一 opaque ID 调用通用 lease API；它不得注册 resource class。因而 64 个已就绪 function 可以各申请 32 QP，恰好耗尽全局 2048 池。FLR、device reset、迁移和 SR-IOV disable 必须执行相应的冻结、恢复或释放操作。Control VQ 与 Admin VQ 也由 Fabric 配置注册为独立 class 与容量，绝不隐式消耗或绕开数据 QP 池。

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
3. `virtio_net_env::bind_pcie()` 接收 RC sequencer、DPU resource manager 和可选 TLM adapter，激活每个 function 的 BAR layout 后，一次性注入 host memory、IOMMU、barrier、queue manager、transport、atomic ops、FSM、driver 和 monitor 引用。
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
- BAR allocator 测试：PF/VF 的三组 pair size、64-bit paired-BAR config encoding、对齐与不重叠、2,116 MiB 最大激活布局；验证 BAR0/1 仅为 device window、BAR4/5 仅为 MSI-X table/PBA、BAR2/3 虽已分配但无 binding 且功能性访问被拒绝；并验证 BAR0/1 discovery 早于动态资源 lease。
- QP allocator 测试：Fabric 对同 profile 的幂等注册返回一个 ID、冲突 profile 被拒绝、封存后未知 profile 被拒绝、64 个已就绪 function 各申请 32 QP 后耗尽全局 2048 池、不同 function 的 local-q 重名、RX/TX 不可拆分、FLR/迁移后的 lease 回收与 BAR 唯一性。
- 跨协议 client contract 测试：Fabric 为 virtio 与模拟 RDMA/block client 预注册不同 profile；各 client 仅 lookup/inject 相应 ID 并申请 lease，验证不发生 ID 或配额串扰。

完成条件为：`make check-deps`、全部可用的 VCS 回归、git diff 检查和 submodule 状态检查通过；若执行环境没有 VCS，则必须明确报告该外部限制，并完成所有无需 VCS 的静态与依赖验证。

## 非目标

- 不修改或 vendor 三个外部仓库。
- 不提交访问令牌，不推送远端，也不改变外部仓库分支。
- 不提供 DUT RTL，也不将 TLM 回环结果表述为真实 DUT 合规性证明。
- 不创建伪造的 RDMA 或 virtio-blk 驱动；本次只交付它们所需的协议无关 Fabric 接口及 virtio-net client 实现。
