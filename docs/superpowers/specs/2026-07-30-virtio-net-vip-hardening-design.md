# Virtio-Net VIP 工程化与功能补齐设计

## 目标

将当前 virtio-net UVM VIP 从依赖机器本地绝对符号链接、需测试自行接线的 TLM 自测工程，提升为可复现构建、可复用集成、具备被动检查闭环的验证 IP。实现既有功能缺口：间接描述符、Admin VQ、热迁移 dirty-page 校验和 SVA 协议断言。

本设计不实现或伪造 virtio DUT RTL。真实 DUT 验证仍通过现有 SV-interface 模式进行。

## 外部依赖与安全

`virtio_net_vip/ext/` 使用 Git submodule 固定以下公开仓库的当前 `main` 提交：

| 路径 | 仓库 | 固定提交 |
|---|---|---|
| `ext/pcie_tl_vip` | `https://github.com/Beihang-yuting/pcie_work.git` | `6913793a42dc58873935f802fab50a395ab56ff3` |
| `ext/host_mem` | `https://github.com/Beihang-yuting/host_mem.git` | `ef056b331047f51125c2aaf248a8767b9b84862a` |
| `ext/net_packet` | `https://github.com/Beihang-yuting/net_packet.git` | `e2af70204f53ede65e366c7a65f695c59acdbbc5` |

失效的绝对符号链接将被 submodule gitlink 替代。所有 remote URL、`.gitmodules` 和脚本只使用无令牌 HTTPS URL。构建不修改外部仓库，submodule SHA 是唯一的依赖锁定记录。

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

1. `virtio_vf_instance::wire_shared()` 与虚拟 sequencer 使用实际的 `uvm_sequencer #(pcie_tl_tlp)` 类型。
2. `virtio_net_env::bind_pcie()` 接收 RC sequencer 和可选 TLM adapter，向每个 VF 一次性注入 host memory、IOMMU、barrier、queue manager、transport、atomic ops、FSM、driver 和 monitor 引用。
3. 现有 TLM completion shim、bridge 和 bridged BAR sequences 移入 transport 源码，作为 `virtio_tlm_completion_adapter`。TLM 测试通过 adapter 启用它；SV-interface/DUT 模式不启用它。
4. 所有集成测试改为调用公共 binding 与 adapter API，不再复制实现细节。

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

完成条件为：`make check-deps`、全部可用的 VCS 回归、git diff 检查和 submodule 状态检查通过；若执行环境没有 VCS，则必须明确报告该外部限制，并完成所有无需 VCS 的静态与依赖验证。

## 非目标

- 不修改或 vendor 三个外部仓库。
- 不提交访问令牌，不推送远端，也不改变外部仓库分支。
- 不提供 DUT RTL，也不将 TLM 回环结果表述为真实 DUT 合规性证明。
