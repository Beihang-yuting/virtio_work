# VIO 项目参考集成简化：一个 env、一个 env_cfg、原生 PCIe TL

历史设计：配置 task 的归属与运行期组织已由 [单 seq 方案](2026-11-07-project-dut-config-sequence-design.md) 更新。当前集成代码以 integration/project 为准。

日期：2026-11-06

状态：已按用户补充的“不要继承 dpu_device_env，直接创建”更新结构并实现参考代码。
完整源码见 `integration/project/`；本文件取代最初的 DPU 继承方案。
组合结构与 AIP 定向 VCS 回归已通过，结果见 `integration/project/README.md`。

## 1. 用户需求与范围

当前项目已经有自己的 UVM env 和 test，只需要复用 `pcie_work/pcie_tl_vip`。
项目不使用 SVT、Serial VIP、链路训练或 PCIe 物理拓扑编排。
参考集成应只有一个项目 env 和一个大 env_cfg，保留 `dpu.*`、`vio.*`、
`pcie_cfg.*` 参数入口以及已有 Tcl sequence 命令。

本次改动限于 `integration/project` 参考实现、对应独立 filelist、测试与文档。
原生产 filelist 和 package 不引入 integration，DPU、PCIe、VIO 原组件保持各自职责。
不因简化集成而删除 `pcie_work` 中其他用户可能使用的 SVT 或 topology 能力。

本方案沿用现有参考场景：每 Host 一个 PCIe segment、一组原生 RC/EP TL 接口，
同 Host 的 PF/VF 通过 BDF 区分并共用这组接口。Host 数量与 Function 数量独立。
多 segment、Switch 和多个物理端点属于另行集成范围，不在这里引入对应抽象。

## 2. 结构选择

采用 `project_env extends uvm_env`，由它直接创建原有 `dpu_device_env`、
`pcie_tl_env` 和 `virtio_net_env`。用户可以将成员和方法合入已有 env，
无需改变现有继承关系或另包一层项目 env。

VIO 创建时使用 `parent=dpu_env`：UVM 先执行 DPU build，向其子树发布冻结快照，
再执行 VIO build。项目 env 保留 VIO 句柄并在 connect 中完成跨组件连接。
这同时满足直接创建与快照发布时间要求，不依赖同级名字顺序、不手调子组件 build，
也不增加 DPU 子类或修改 DPU 库 API。

目标组件结构：

```text
现有 test
└── 现有大 env extends uvm_env（合入 project_env 的成员和方法）
    ├── dpu_env : dpu_device_env
    │   └── vio_hN : virtio_net_env（句柄保存在大 env 的 vio_envs[host_id]）
    ├── pcie_env : pcie_tl_env
    └── shared_pool / reg_backend
```

`project_base_test` 继续是可选运行顺序参考；已有 test 不必改变继承关系。
package、base_test 和 HDL top 仍是各自的编译/运行入口，“一个 env + cfg”指项目
组件与配置职责，不要求将 package、test、interface 合并进两个文件。

## 3. 大 cfg 保留和删除的成员

保留：

| 成员 | 职责 |
| --- | --- |
| `dpu_cfg` | Host/PF/VF、BAR/BDF、资源 placement、DPU 寄存器策略与 executor |
| `vio_cfg` | 全局 VIO 行为模板 |
| `vio_cfg_by_host[h]` | 各 Host 的 VIO 行为、IOMMU 及实际共享句柄 |
| `pcie_cfg` | 原生 `pcie_tl_env_config`，直接交给唯一 PCIe TL 子环境 |
| `host_mem_pool_binding` | 外部已有的 Host pool；为空时才创建 |
| `tl_slot_by_host[h]` | Host 到原生 TL RC/EP 配对槽位的简单对应表 |
| `rc_vifs[slot]` / `ep_vifs[slot]` | 平台已有的两个方向 TL interface |
| `protocol_vifs` | VIO Function 协议观察接口；继续保持跨 Host 唯一性 |
| `completion_adapter` | 原有 MODEL 场景的可选接入；REAL_DUT 下必须为空 |

删除项目层成员与逻辑：

- `pcie_hw_cfg`、`projected_pcie_cfg` 及 `pcie_global_cfg` 的创建和下发。
- `root_bindings`、`attachments` 两个复杂映射对象，以及图节点/链路 ID 查找。
- `backend_factory`、SVT/provider 选择、HDL slot/Serial bridge 相关分支。
- `build_physical_config()`、`project_pcie_config()` 和 topology adapter 依赖。
- 项目自定义的 `project_device_env` 类；改用原有 `dpu_device_env` 的 `env.dpu_env` 句柄。

`tl_slot_by_host` 缺省按参考场景的 Host 编号绑定；用户可在子 env 构建前整体覆盖。
校验要求：每个 Host 有且只有一个 slot，slot 为连续的 `0..hosts-1` 且不重复。
通过该表明确设置 `pcie_cfg.num_rc/num_ep`、`bind_host_memory()` 和
`bind_ep_root(slot, slot)`。不再从 Function 数量或 `device_cfgs` 的排列推测接口归属。

## 4. BDF、BAR 与设备配置的传递

删除 global 配置不会删除 DPU 分配能力。现有实现已有两条直接通路：

1. `virtio_function_instance.configure_from_ctx()` 从冻结 snapshot 取得完整
   `{host, segment, BDF}`、BAR 租约和资源绑定；之后配置 VIO transport。
2. `pcie_tl_dpu_reg_backend` 直接持有同一份 device snapshot，将 BAR offset
   转换为 MMIO 绝对地址，并通过 `{host, segment} → RC slot` 选择 sequencer。

因此 REAL_DUT 集成无需再创建一套 PCIe global/device 配置镜像才能访问 DUT。
本参考实现不自动填充 `pcie_cfg.device_cfgs`，不把它当成第二套 Function 分配结果。
真实配置空间和 MMIO 应答由 DUT 提供；`configure_device()` 仍负责实际寄存器计划。

原生 TL 类保留 `device_cfgs` 能力。若平台已有需要这种镜像的 MODEL 接入，
由平台建立并检查它与 DPU snapshot 的一致性；本次不新增设备模型或自动响应实现。
原生 cfg-only 路径的 EP 上下文选择有历史顺序约定，不能把多个 PF/VF 记录
直接当成多个物理 EP 槽位。本参考实现不依赖这一回退来决定 Function 路由。

## 5. build 与 connect 顺序

`project_env.build_phase()`：

1. 获取 `project_env_cfg`，幂等执行 `load_params()`。
2. 准备或借用唯一 Host pool；注入每 Host VIO 配置，校验已存在 manager 的范围和策略。
3. 校验 Host→slot 映射，给 `pcie_cfg` 填入 TL 组件数量、Root 内存及 EP→Root 绑定。
4. 准备默认 `dpu_pcie_reg_executor + pcie_tl_dpu_reg_backend`，或保留平台 executor。
   必须先安装 backend，后续 DPU 子组件 build 才能给它绑定 snapshot。
5. 将 `cfg.dpu_cfg` 发布到 `"dpu_env"`，直接创建原类 `dpu_device_env`。
6. 只用 `uvm_config_db#(pcie_tl_env_config)` 的 `"cfg"` 入口创建 `pcie_env`。
   不下发 `global_cfg`、`topology_cfg` 或 `tl_policy_cfg`。
7. 给 `dpu_env` 下的 `vio_hN` 发布各 Host VIO cfg，并以 `dpu_env` 为 parent 创建 VIO。

项目 env 的 `super.build_phase()` 仅调用 UVM 基类；返回后不代表 DPU 子组件已构建。
项目 build 不查询 snapshot。UVM 随后执行 DPU build，resolver 唯一解析一次并发布
device/resource snapshot 和 manager，VIO 子组件在自己的 build 中消费这些对象。
PCIe build 不需要该快照，因此与 DPU 并列不会引入构建顺序依赖。

`project_env.connect_phase()`：

1. 根据 slot 绑定实际 RC/EP TL VIF；采用原生 `SV_IF_MODE` 接 DUT，无建链状态机。
2. 按完整 Function 身份绑定协议 VIF，拒绝空句柄和跨 Function 复用。
3. 将 `pcie_env.v_seqr` 交给寄存器 backend，显式绑定每个 Host 的 segment 0 到 RC slot。
4. 遍历 VIO Function，用其 Host 查表选择 RC sequencer/driver/monitor 和 EP monitor，
   建立 `virtio_pcie_function_endpoint` 并调用既有 `bind_pcie_endpoints()`。

同一个 Host 的所有 PF/VF 共用 TL 传输句柄，Function 身份仍使用完整域限定 BDF。
不同 Host 的相同数值 BDF 不得混用 RC、Host memory 或 IOMMU 域。

## 6. 执行模式与 test 入口

默认仍为 `REAL_DUT`：`SV_IF_MODE`、RC active、EP passive、`ep_auto_response=0`。
沿用既有执行模式策略生成这些相互关联的字段，普通 `pcie_cfg.*` 行为参数在其后加载。
请求与响应接口由现有平台提供；不配置 LTSSM、速率协商、lane training 或 SVT。

原有 MODEL 接入口可保留，但设备模型和 completion adapter 必须由平台提供；
普通 PCIe EP 自动应答不能替代 Virtio 设备模型。

test 运行入口调整为直接调用项目 env：

```text
等待平台复位释放、TL 接口和 DMA 服务可用
env.configure_device()
env.register_aip_commands()
aip_tcl_bridge::run_loop()
等待实际业务完成并检查结果
```

现有 `prepare_platform()` 钩子保留，但其职责改述为检查 TL 接口与服务就绪，
不要求等待本项目不存在的 PCIe 链路训练。Tcl loop 每个仿真只启动一次。

`load_params()` 不访问 DUT；构建参数与运行期 sequence 参数的采样时机保持现状。
`dpu.*`、`vio.*`、`pcie_cfg.*` 路径不随组件层次变化。

## 7. 文件调整

| 文件 | 调整 |
| --- | --- |
| `integration/project/project_env.sv` | 组合共享资源、原有 DPU、PCIe/VIO 构建连接及运行方法，仅继承 uvm_env |
| `integration/project/project_env_cfg.sv` | 删除 global/topology/provider 配置，增加简单 Host→slot 映射 |
| `integration/project/project_device_env.sv` | 职责合并后删除 |
| `integration/project/project_base_test.sv` | 使用直接 env 方法，更新平台准备说明 |
| `integration/project/project_env_pkg.sv` | 删除中间 env include 和 PCIe-DPU 编排包导入 |
| `filelists/project_integration.f` | 去掉 `pcie_dpu_integration_pkg`，继续引用原 TL/AIP/VIO 依赖 |
| `integration/project/tests/*` | 更新组件路径、VIF 下标及 Host/slot 校验 |
| `integration/project/README.md` | 以 TL 接口方式说明配置与集成 |
| `docs/project_env_full_code.md` | 与最终参考源码同步 |
| `docs/aip_parameters.md` | 只更新涉及参考集成入口的说明，保持参数定义 |

`pcie_tl_vip` 自身仍需要其 topology 目录中的部分公共类型/package；
本次去掉的是项目的图编排及 global 对象使用，不拆改 TL 库内部类型依赖。
原生产 filelist/package 保持不引入 integration，参考入口继续由项目显式选择。

## 8. 验证与验收

在 `ubuntu@10.11.10.53` 的 VCS 环境进行，使用配置好 VCS/license 的 bash 环境。

- 原有单 Host/多 Host、PF/VF 结构测试通过，普通参数覆盖确实到达实际 TL/VIO 组件。
- 增加或调整 Host→slot 交换的验证：同 Host 多 PF/VF 共用一组接口，两个 Host
  使用相同数值 BDF 时仍各自选择正确 sequencer、Host memory 和 IOMMU 域。
- 验证 DPU resolver 结果只产生一次，VIO 与寄存器 backend 使用相同 snapshot。
- 验证直接创建的 DPU 类型和父组件，VIO 位于 DPU 快照发布子树。
- 验证原生 cfg-only 生效：没有 global/topology/provider 活动对象；保留用户
  `pcie_cfg` 行为设置，尤其 SCB、Completion timeout 和信用配置。
- 缺 Host 映射、重复/越界 slot、缺 native VIF、协议 VIF 复用和 IOMMU 策略不匹配
  应明确失败，不能静默退回 Root0 或创建替代内存。
- 运行既有 AIP 参数/命令相关回归，验证注册入口扁平化后没有重复注册或重复 loop。
- 静态核对原生产 filelist/package 未增加 integration 依赖。

结构测试不能证明真实 DUT 报文收发通过；真实数据面由用户项目的 DUT、DMA 和
网络激励共同验证。本次简化也不补齐上一轮核对出的 VTX/VRX/QSCH 自动配置缺口，
不改变当前私有后端支持范围或寄存器编码。


## 9. 后续 Intel 接口需求

用户随后明确选择 `pcie_intel` 接口，并要求完整 env/cfg。沿用本方案已有的一套
组合式 env/cfg，在独立 `project_intel_integration.f` 中定义 `PROJECT_PCIE_INTEL`。
该分支用于真实 EP 应用 DUT，每 Host 一个 HARD_IP 方向的 RC adapter；关闭
EP agent/adapter，保留 Host→RC slot、共享内存、快照和原 AIP 参数路径。

Intel 专用 cfg/VIF 必须在 adapter build 前发布。大 cfg 显式句柄与 top 的 bind
wrapper 发布值允许指向相同对象，冲突或跨端口复用立即失败；缺 cfg 可建立默认
HARD_IP 对象，缺 VIF 立即失败。通过 `intel_pcie_configure_env()` 安装实例覆盖，
开启外部引脚 bridge 与公共无限 FC；本地有限 AVST credits 由 Intel cfg 管理。
connect 只核对实际 adapter，不补绑迟到接口。

没有新增项目 env/DPU 子类，没有启用 SVT/global/topology，也没有改变生产
filelist/package。结构回归复用原测试并按宏切换空闲 VIF，覆盖 Host slot 交换、
wrapper 句柄借用、配置冲突、缺接口/跨端口复用及普通 TL 兼容性。

Intel cfg 原类尚无 `load_params()`，私有字段仍由平台在 build 前赋值。
`cq_route`→RX BAR/PF/VF 边带、requester-aware DMA 翻译、协议观察、VTX/VRX/QSCH
硬件设置继续由实际平台接入；env/cfg 结构测试不能替代真实 DUT 收发验证。
