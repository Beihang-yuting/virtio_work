# 项目 env / env_cfg 完整集成

这套参考代码把已经存在的 DPU、PCIe 和 VIO 能力接到一个项目环境中。
默认 `REAL_DUT`，每 Host 一个 PCIe segment 和一条 RC→EP 链路；
默认规模为 **1 Host、1 PF、0 VF**，因此不传规模参数也会创建一个 PF VIO 服务。
代码可直接编译，真实 DUT 的接口、复位、链路和 DMA 服务接入现有平台。

`integration/` 是可选参考目录。`project_env_pkg`、`virtio_aip_pkg` 及其测试只由
新增的独立 filelist 显式编译，不加入原有 filelist，也不被原生产 package 导入或包含。
原配置类中的条件式 AIP 导入仅服务于 `load_params()`，不依赖本参考组装层。

**逐文件、不省略函数体的代码展示：[完整集成代码](../../docs/project_env_full_code.md)。**

## 文件和职责

| 文件 | 做什么 |
| --- | --- |
| [project_env_cfg.sv](project_env_cfg.sv) | 大 cfg，组合 `dpu_cfg/vio_cfg/pcie_cfg`；一个 `load_params()` 读取参数并创建 Host/PF/VF 输入 |
| [project_device_env.sv](project_device_env.sv) | 继承 `dpu_device_env`；先解析冻结，再投影 PCIe、创建和连接每 Host 的 VIO |
| [project_env.sv](project_env.sv) | 顶层共享 pool、默认寄存器 executor/backend 的创建与传递 |
| [project_base_test.sv](project_base_test.sv) | base test 的 build/run 顺序，以及必须由平台实现的三个接口 |
| [project_env_pkg.sv](project_env_pkg.sv) | 唯一 package 编译入口，不重复编译 include 源文件 |
| [project_integration.f](../../filelists/project_integration.f) | 包括所有依赖的示例 filelist；已有工程仅补缺失项 |
| [project_env_smoke_test.sv](tests/project_env_smoke_test.sv) | 参数、共享句柄、快照、endpoint、协议 VIF 的结构回归 |
| [project_env_tb.sv](tests/project_env_tb.sv) | 结构回归使用的空闲接口 top，没有 DUT/数据面应答 |

参数仍在原来的配置类注册：DPU 的 `dpu_device_cfg/placement_cfg`、VIO 的
`virtio_net_env_config`、PCIe 的 `pcie_tl_env_config`。新增大 cfg 负责调用这些入口，
只额外定义场景规模与公共内存创建策略，不复制它们的所有参数实现。

## 组件与配置关系

```text
project_base_test 的具体派生 test
  cfg : project_env_cfg
    dpu_cfg : dpu_device_env_config
      device_cfg / placement_cfg / vio_policy / executor
    vio_cfg : virtio_net_env_config              全局行为模板
    vio_cfg_by_host[h] : virtio_net_env_config   各 Host 独立行为对象
    pcie_cfg : pcie_tl_env_config                PCIe TL 行为
    pcie_hw_cfg / root_bindings / attachments   物理拓扑与显式映射
    host_mem_pool_binding / VIF / backend       平台公共句柄

  env : project_env
    shared_pool
    device_env : project_device_env extends dpu_device_env
      DPU device snapshot / resource snapshot / resource manager
      pcie_env : pcie_tl_env
      vio_h0 : virtio_net_env
      vio_h1 : virtio_net_env                   多 Host 时创建
```

`virtio_net_env` 自身保持业务环境类型。公共属性通过配置、只读快照与共享句柄取得；
继承 DPU 的是项目的组装层 `project_device_env`，这样它能在 `super.build_phase()`
返回后立即使用已冻结的结果，再创建消费者。不要依赖同级组件名字排序来赌 build 顺序。

| 阶段 | 顺序与效果 |
| --- | --- |
| test build | 创建/获取 cfg → `cfg.load_params()` → 注入平台句柄 → 发布 cfg → 创建 env |
| project env build | 幂等确认参数已加载 → 准备唯一 Host pool → 安装默认 executor/backend → 创建 device_env |
| device env build | `super.build_phase()` 唯一执行 DPU resolver → 得到冻结结果 → PCIe 投影 → 创建 PCIe/VIO 子环境 |
| child build | PCIe 创建实际 agent/manager；VIO 消费 DPU 发布的同一 snapshot/resource manager |
| device env connect | 绑定 native VIF → 全局分配协议 VIF → 绑定寄存器 sequencer/Root → 逐 Function 绑定 PCIe endpoint |
| test run | 平台就绪 → `configure_device()` → 注册 AIP 命令 → Tcl loop → 等待并检查业务完成 |

## 公共资源如何传递

| 公共内容 | 来源 | 消费者与约束 |
| --- | --- | --- |
| Host/PF/VF、BDF、BAR | DPU resolver 的冻结 device snapshot | VIO 与 PCIe 投影消费同一结果；不能在 PCIe 中再分配另一套地址 |
| qpair、MSI-X、notify 资源 | DPU resource snapshot/manager | 所有 Host 子环境共享同一组对象，各自按 Host scope 过滤服务 |
| Host 内存 | `cfg.host_mem_pool_binding`；为空才创建 | DPU 保存中性引用；VIO 按 Host 取 manager；PCIe 按 Root 显式绑定同一个 manager |
| IOMMU | `cfg.vio_cfg_by_host[h].iommu_binding` | 可注入已有模型；策略须与加载的 VIO cfg 一致；build 不重配已有映射 |
| PCIe TL 策略 | `cfg.pcie_cfg` | 同一个对象同时发布为 `cfg` 与 `tl_policy_cfg`；拓扑翻译保留行为字段 |
| PCIe native 接口 | `cfg.rc_vifs[root]`、`cfg.ep_vifs[physical_node_id]` | 各方向独立；在 parent connect 中接实际 adapter |
| SVT/provider | `cfg.backend_factory` + `pcie_hw_cfg` 链路策略 | 创建与 HDL slot/VIF 配置沿用平台能力；不向 provider adapter 强塞 native VIF |
| 协议监测 VIF | `cfg.protocol_vifs` 或 top 的 `protocol_event_vif_N` | 所有 Host 统一分配；按完整 `{host,segment,BDF}` 绑定，每个 Function 独占接口 |
| 寄存器 executor | `cfg.dpu_cfg.executor` | 为空时创建现有 `dpu_pcie_reg_executor + pcie_tl_dpu_reg_backend`；已有 executor 原样保留，由平台连接其 backend |

外部 pool 已有 Host manager 时只校验 Host 身份、初始化状态、GPA 覆盖和分配策略，
不再调用 `init_region()`。`dpu.mem_mode/mem_granule` 只决定新建 manager 的算法；
不能通过构建参数改变已经初始化的外部分配器。

IOMMU 对象有状态，因此不会随 `copy_defaults_from()` 复制。先加载 Host cfg，
再在 `bind_platform_handles()` 中按 Host 注入。多个 Host 可以共享策略一致的模型，
但当前 IOMMU requester key 是 `{host,BDF}`，本模板仅建立每 Host 一个 segment；
同 Host 多 segment、相同 BDF 的 IOMMU 隔离需要平台额外适配。

## base_test 还需要设置什么

常规标量不需要在 base test 逐个赋值。`project_base_test.build_phase()` 已经完成
`cfg.load_params()` 和 config_db 下发；env 再调用时会幂等返回，不重复随机采样。

以下内容属于平台的对象/时序，必须接上，不能用标量参数代替：

1. `bind_platform_handles()`：注入已有 pool/IOMMU、native VIF 或 backend factory。
   top 若已把完整 `project_env_cfg` 作为 `project_cfg` 交给 test，该方法可显式为空。
2. `prepare_platform()`：确认 reset deassert、link ready、Host DMA 路由及检查器准备完成。
   平台提供超时和错误处理；此后才能执行 DPU 寄存器计划。
3. `finish_platform()`：等业务完成，检查网络数据、DMA、PCIe SCB、协议断言与资源回收。
   `vio_tx` 返回只代表提交，不能只等待 Tcl 退出就宣告业务完成。

因此基类是 **virtual class**，无 factory 注册；现有具体 test 实现上述接口后再
使用 `uvm_component_utils` 注册。不能直接 `+UVM_TESTNAME=project_base_test`。
结构回归使用可直接运行的 `project_env_smoke_test`，其目的和范围不同。

`configure_device()` 内部调用 `build_vio_register_plan/apply_vio_register_plan`，
计划已经包含 bootstrap。不要提前调用 `apply_bootstrap()`，否则 DPU 状态会从
RESOLVED 进入 ACTIVE，无法再按该顺序应用 VIO 初始化计划。

实际 DUT 若需要 QSCH/数据面额外计划，在 build 前把已有的
`dpu_vio_dataplane_plan_extension` 放入 `cfg.dpu_cfg.vio_dataplane_extension`。
模板不会猜测硬件的端口、QSCH 或网络拓扑。

## 参数示例

```text
+dpu.hosts=2
+dpu.pfs_per_host=1
+dpu.vfs_per_pf=2
+dpu.qpairs=8
+vio.pairs=1
+vio.queue_size=512
+vio.h1.queue_size=1024
+vio.h1.pf0.vf1.i0.queue_size=256
+pcie_cfg.init_ph_credit=23
+pcie_cfg.cpl_timeout_ns=200000
```

这个场景创建 2 个 Host，每个 Host 有 PF0 和 VF0/VF1，VIO 服务默认放在 VF 上，
总计 4 个服务；PF 仍保留控制/AF 能力。`dpu.vfs_per_pf=0` 时服务改放 PF。
`dpu.qpairs` 是 DPU **预留总量**，`vio.pairs` 是服务 **初始活动量**；
后者不能增加资源，超过分配量会受现有 VIO 配置接口的上限约束。
未传 `dpu.qpairs` 时，模板按候选数 × 各 Host 最大初始 pairs 预留。

路径覆盖顺序由代码实现：`vio` 模板 → `vio.hN` → `vio.hN.pfN[.vfN].iN`。
Host 资源同样为 `dpu` 模板 → `dpu.hN`。Function 的 BDF/BAR 参数直接加载
`dpu.hN.pfN[.vfN]`。完整字段列表见 [AIP 参数说明](../../docs/aip_parameters.md)。

构建完成后的 `set_param dpu.*`、`set_param pcie_cfg.*` 不会自动重新解析/重配环境。
运行期可变的是每次 sequence 重新采样的 `vio.tx.*`、`vio.rx.*` 等参数：

```tcl
set_param vio.target h0.pf0.vf0.i0
set_param vio.tx.kind ETH_IPV4_UDP
set_param vio.tx.len 128
vio_init
vio_start
vio_tx count=100
```

在平台已完成 DPU 初始化并进入 AIP bridge 后执行上述命令；Tcl 的加载/控制入口
沿用 `aip_core/update`，参见现有 [AIP Tcl 示例](../../examples/aip/cases/tx_smoke.tcl)。
停止、复位前要等待实际业务完成，不能把 `count=100` 的提交完成当成设备已消费完成。

## 沿用现有物理拓扑 / 已有逻辑配置

默认 `load_params()` 自动建立直连图。自定义物理图时，在 load 前同时提供：

- `pcie_hw_cfg.topology` 及其 link/backend policy；
- `root_bindings`：明确 `{host,segment} → Root`；
- `attachments`：明确 `{host,pf,kind,vf} → physical EP node/link`。

这些映射保留原样，随后由 snapshot adapter 验证。也可在 load 后、env build 前
整体替换三者，但不能只改其中一张表。native VIF 的 EP key 是物理节点 ID，
不是 Function 下标。provider 需为被测试 Host 提供 VIP-owned RC sequencer；
只有真实 DUT RC、没有模拟 Host RC 的拓扑不能运行这套 Guest driver。

已由项目完整构建 DPU `hosts/functions/placement` 时，派生 `project_env_cfg`
并覆盖 `load_params()`，在项目自己的 authoring 点调用原类加载入口。默认模板
会拒绝覆盖非空逻辑配置，避免重复追加 Host/PF/VF。派生实现也应保持单次加载，
并填好 `vio_cfg_by_host`、物理映射和 PCIe 行为策略。

MODEL 模式还需要真正的 Virtio 设备模型和一个共享 `completion_adapter`。
模板在 PCIe build 前安装该 adapter 的 factory overrides；设备模型/EP port
由平台根据冻结快照准备。普通 PCIe EP 自动应答不等价于 Virtio 设备。

REAL_DUT 的 IOVA→GPA DMA 路由沿用平台现有服务。多 Function 共用 Root 时，
不能反复把单 requester 的 `virtio_pcie_iova_host_mem_proxy` 赋给同一个 `rc_driver.mem`；
这样最后一次会覆盖前面的配置。必须由平台按 requester BDF 路由到对应的 IOMMU 域。

## 编译和结构验证

在 `10.11.10.53` 加载 VCS 环境，从 virtio_work 根目录运行，设置五个依赖根：
`AIP_CORE_ROOT`、`DPU_COMMON_ROOT`、`NET_PACKET_ROOT`、`HOST_MEM_ROOT`、`PCIE_WORK_ROOT`。
AIP 必须是 update 分支含 `src/sv` 的布局；本地旧 flat layout 不匹配。
已有大工程按 filelist 顺序补包即可，不能重复编译 UVM/Host memory/PCIe/VIO package。

```bash
mkdir -p build/project
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f filelists/project_integration.f -f filelists/project_tests.f \
  -top project_env_tb -Mdir=build/project/csrc -o build/project/simv \
  -l build/project/compile.log
./build/project/simv -exitstatus +UVM_TESTNAME=project_env_smoke_test \
  +dpu.hosts=2 +dpu.vfs_per_pf=2 +vio.queue_size=512 \
  +PROJECT_EXPECT_HOSTS=2 +PROJECT_EXPECT_FUNCTIONS=4 +PROJECT_EXPECT_QUEUE=512 \
  -l build/project/smoke.log
```

这个测试不执行寄存器计划、不发送数据；它验证环境已正确组装。
真实用例应切换到已有平台 top 和 `project_base_test` 的具体派生 test。

## 本次验证结果（2026-11-06）

在 `10.11.10.53` 使用 VCS W-2024.09-SP1 验证，未在本机运行仿真。
最终结构回归和既有 AIP 回归编译均无 VCS warning/error。

| 场景 | 结果 |
| --- | --- |
| 默认 1 Host / 1 PF 服务 | 25 项检查通过 |
| 2 Host / 各 2 VF 服务，queue=512、PH credit=23 | 52 项检查通过，共 4 个活动服务 |
| 2 Host / 各 1 PF 服务 | 36 项检查通过 |
| IOMMU 策略不匹配、缺 Root 映射、空 VIF、跨 Host 复用 VIF | 各自命中预期生产 fatal，无 timeout |
| 既有 `virtio_aip_params_test` | 34 项检查通过 |
| 既有 `virtio_aip_command_test` | 通过 |
| 既有 MODEL `virtio_aip_driver_test` + Tcl `tx_smoke` | init/start/tx4/stop/reset 通过；PCIe matched/completions=111/111，pending/trackers/dedup=0 |

所有正例的 UVM warning/error/fatal 均为 0，严格日志检查通过。
MODEL 兼容回归复用原有 fixture，用于确认旧 IOMMU 创建和协议 VIF slot 路径继续可用；
它不是新项目组装层连接真实 RTL 的证明。本次未验证平台真实 RTL、Serial/SVT 链路、
多 requester DMA 数据面及项目业务检查器。
