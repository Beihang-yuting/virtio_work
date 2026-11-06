# 一个 env 和一个 env_cfg：原生 PCIe TL 集成参考

把 [project_env_cfg.sv](project_env_cfg.sv) 的成员和方法合入你的大 cfg，把
[project_env.sv](project_env.sv) 的成员和方法合入你的大 env 即可。
示例中的 `project_` 只是占位命名，可以统一换成项目自己的类名；已有 env/test
不需要再包一层 `project_env`，也不需要继承 `dpu_device_env`。

**[完整代码展示](../../docs/project_env_full_code.md)** 按 cfg、env、test、package
顺序展开全部函数体。实际维护的源码在本目录，二者保持一致。

默认 `REAL_DUT`，规模为 **1 Host、1 PF、0 VF**。每 Host 一个 segment 0 和一组
原生 RC/EP TL 接口，同 Host 的 PF/VF 共用接口。项目层只创建
`pcie_tl_env_config`，采用 PCIe TL 的 cfg-only 路径。
不构造 PCIe global/topology 对象，不使用 SVT、Serial VIP 或链路训练。

`integration/` 始终是可选参考目录，只由独立 filelist 显式编译；原生产
filelist/package 不导入本目录。已有工程按需合入代码和缺少的依赖，避免重复编译包。

## 组件与配置关系

```text
你的 test
  cfg : 你的 env_cfg extends uvm_object
    dpu_cfg : dpu_device_env_config
      device_cfg / placement_cfg / vio_policy / executor
    vio_cfg : virtio_net_env_config                全局行为模板
    vio_cfg_by_host[h] : virtio_net_env_config     每 Host 的独立行为配置
    pcie_cfg : pcie_tl_env_config                  原生 TL 配置
    tl_slot_by_host[h]                            Host → RC/EP 配对接口下标
    host_mem_pool_binding / rc_vifs / ep_vifs / protocol_vifs

  env : 你的 env extends uvm_env
    dpu_env : dpu_device_env                      直接创建原类
      vio_h0 : virtio_net_env
      vio_h1 : virtio_net_env                     多 Host 时创建
    pcie_env : pcie_tl_env
    shared_pool / reg_backend
```

关键是 `virtio_net_env::type_id::create(child_name, dpu_env)` 的第二个参数。
VIO 由你的大 env 创建、句柄保存在 `env.vio_envs[h]`，但在 UVM 树中属于 DPU 子树。
DPU 会先执行 build 并向自己的子树发布快照，随后 VIO build 才读取它们。
这利用 UVM 的父子构建顺序，不需要手动调用子组件的 `build_phase()`。
PCIe 的 cfg-only build 只需要 TL 配置和 Host 内存，可以和 DPU 并列。

| 文件 | 可合入现有项目的内容 |
| --- | --- |
| [project_env_cfg.sv](project_env_cfg.sv) | 配置成员、构造函数、Host/Function 默认输入生成、`load_params()`、Host→slot 校验 |
| [project_env.sv](project_env.sv) | 共享内存、PCIe 配置、build/connect、VIF/endpoint 绑定、DPU 初始化、Tcl 命令注册 |
| [project_base_test.sv](project_base_test.sv) | 可选的 test 接入顺序；已有 test 可直接移植方法内容 |
| [project_env_pkg.sv](project_env_pkg.sv) | 所需 import 和 include 顺序 |
| [project_integration.f](../../filelists/project_integration.f) | 独立编译入口，已有工程只补缺失项 |
| [project_env_smoke_test.sv](tests/project_env_smoke_test.sv) | 组合结构、参数和共享对象的验证 |
| [project_env_tb.sv](tests/project_env_tb.sv) | 结构测试 top，仅有空闲接口，没有 DUT 应答 |

## 构建与运行顺序

| 阶段 | 操作 |
| --- | --- |
| test build | 创建/获取 cfg → `load_params()` → 注入平台句柄 → 下发 cfg → 创建你的 env |
| 大 env build | 准备共享内存 → 填写 PCIe slot/内存绑定 → 安装默认 executor/backend → 直接创建 DPU、PCIe、DPU 下的 VIO |
| DPU build | resolver 解析并冻结 device/resource snapshots，发布到子树，给 executor 绑定 snapshot |
| VIO build | 按 Host scope 消费同一份 snapshot/resource manager，创建对应 PF/VF 服务 |
| PCIe build | 消费同一个 `pcie_cfg`，创建原生 TL agents、adapters、manager |
| 大 env connect | 绑定 native VIF 和协议 VIF → 绑定寄存器 backend → 逐 Function 绑定 PCIe endpoint |
| test run | 复位/TL/DMA 服务就绪 → `env.configure_device()` → 注册 AIP → Tcl loop → 业务完成检查 |

DPU 和 PCIe 两个同级组件谁先 build 不影响此方案。所有 build 完成后才进入 connect，
大 env 的 connect 又在子组件 connect 之后执行。

## 共享对象与身份映射

| 内容 | 来源与传递 |
| --- | --- |
| Host/PF/VF、BDF、BAR | `dpu_cfg` 输入经 resolver 冻结；VIO 和寄存器 backend 消费同一 snapshot |
| qpair、MSI-X、notify 资源 | 所有 Host 的 VIO 共享 DPU resource snapshot/manager，各自按 Host scope 选服务 |
| Host 内存 | `cfg.host_mem_pool_binding` 为空才创建；DPU 保存引用，VIO 和 PCIe RC driver 使用同一 Host manager |
| IOMMU | `cfg.vio_cfg_by_host[h].iommu_binding`；已有模型只校验策略，不重建已有映射 |
| PCIe TL 配置 | `uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "cfg", cfg.pcie_cfg)` |
| TL 接口 | `cfg.rc_vifs[slot]`、`cfg.ep_vifs[slot]`；两个方向独立，各 slot 不复用 VIF |
| 协议观察接口 | 优先使用 Host VIO cfg 的完整身份映射；否则用 `cfg.protocol_vifs`，最后查 top 的 `protocol_event_vif_N` |
| 寄存器 executor | `cfg.dpu_cfg.executor`；为空才创建默认 `dpu_pcie_reg_executor + pcie_tl_dpu_reg_backend` |

`tl_slot_by_host[h]` 默认 `h → h`，可以在 load 后、env build 前交换映射。例如：

```systemverilog
cfg.load_params();
cfg.tl_slot_by_host[0] = 1;
cfg.tl_slot_by_host[1] = 0;
// rc_vifs/ep_vifs 始终按接口 slot 填写，不随 Host 编号重新解释。
```

映射必须覆盖每个 Host，slot 唯一且恰好覆盖 `0..Host数-1`。
同 Host 的 PF/VF 共用该 slot；不能把 Function 数量作为 `num_ep`。
不同 Host 可以使用相同数值 BDF，路由时同时考虑 Host/segment。
此参考限制每 Host 一个 segment 0；多 segment、Switch 或同 Host 多物理端点需要另行适配。

REAL_DUT 下 BDF/BAR 直接来自 DPU snapshot，不必再镜像到 `pcie_cfg.device_cfgs`。
原生 TL 库内部仍编译其公共 topology 类型，这不要求项目创建 global/topology 配置。

外部 pool 已有 Host manager 时，代码只校验身份、初始化状态、GPA 覆盖与分配策略，
不会重调 `init_region()`。`dpu.mem_mode/mem_granule` 只影响新建 manager。
IOMMU 有状态，不通过 `copy_defaults_from()` 复制；应在 load 后逐 Host 注入。
已有 executor 的 backend 连接继续由平台负责，参考代码不会替换它。

## 现有 test 需要保留什么

常规标量由 `cfg.load_params()` 读取，base test 无须逐个设置 Host 数、queue_size、credit。
这里的大 cfg 对 load 做了单次保护，env 再调用不会重复采样或追加 Host。
平台对象和时序仍要接入：

1. build 中在 load 后注入 RC/EP VIF、协议 VIF，以及已有 pool/IOMMU；再把大 cfg
   以 `"cfg"` 下发给自己的 env。单 Host 默认使用 slot 0。
2. run 中等待平台复位释放、TL 接口和 requester-aware DMA 服务就绪，并设置超时。
3. 调用 `env.configure_device()`，随后调用 `env.register_aip_commands()`，启动一次
   `aip_tcl_bridge::run_loop()`。
4. Tcl 返回后等待业务真正完成，检查报文、DMA、PCIe/协议监测和资源回收，再结束 objection。

[project_base_test.sv](project_base_test.sv) 把平台步骤定义成三个 pure virtual hook：
`bind_platform_handles()`、`prepare_platform()`、`finish_platform()`。
它是运行顺序参考，不能直接作为 `UVM_TESTNAME`；你的 test 可以保持原有继承关系，
把这些操作合入已有 build/run，不必再继承这个示例。

`configure_device()` 调用 `build_vio_register_plan/apply_vio_register_plan`，其中已经包含
bootstrap。不要先单独调用 `apply_bootstrap()`，也不要重复初始化。
若平台已有完整初始化流程，应在一个地方统一负责寄存器计划。
额外 VTX/VRX/QSCH 数据面配置依然由平台适配；需要的扩展在 build 前放入
`cfg.dpu_cfg.vio_dataplane_extension`。本次组合调整不会补齐这些硬件配置。

REAL_DUT 的 IOVA→GPA DMA 路由沿用平台现有服务。多 Function 共用 RC 时，
不能反复给同一个 `rc_driver.mem` 赋单 requester proxy；需要按 requester BDF
选正确的 IOMMU 域。本参考不新增 DMA 路由器。

## 参数与 Tcl 示例

参数路径与 env 的组件名、层次无关，仍为 `dpu.*`、`vio.*`、`pcie_cfg.*`。
注册实现保留在原配置类，大 cfg 只负责按构建顺序调用和生成场景输入。

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

该场景有 2 个 Host，每个 Host 的 PF0 下有 VF0/VF1，VIO 默认放在 VF，共 4 个服务。
`dpu.vfs_per_pf=0` 时服务放在 PF。`dpu.qpairs` 是预留总量，`vio.pairs` 是每个服务
初始活动量；未指定前者时按候选数 × 各 Host 最大初始 pairs 预留。
Function 级 pairs 覆盖仍受分配容量限制，增加初始量时要同时确保预留足够。

覆盖顺序为 `vio` → `vio.hN` → `vio.hN.pfN[.vfN].iN`；
Host 输入为 `dpu` → `dpu.hN`，Function 参数在 `dpu.hN.pfN[.vfN]` 加载。
详细字段见 [AIP 参数说明](../../docs/aip_parameters.md)。

平台完成 DPU 初始化、进入 AIP bridge 后，默认单 PF 场景可以执行：

```tcl
set_param vio.target h0.pf0.i0
set_param vio.tx.kind ETH_IPV4_UDP
set_param vio.tx.len 128
vio_init
vio_start
vio_tx count=100
```

VF 场景把 target 改成如 `h0.pf0.vf0.i0`。`vio_tx` 返回表示提交完成，设备消费和
报文完成还要由平台等待检查。构建后的 `set_param dpu.*`、`vio.queue_size`、
`pcie_cfg.*` 不自动重建环境；运行期只更新下一条 sequence 会重新采样的参数。

## 已经有 Host/PF/VF 输入的项目

示例 `load_params()` 默认负责创建一套 `hosts/functions/placement`。
若你的 cfg 已经建立这些对象，应把原配置类的 `load_params()` 调用合入已有的
输入构造代码，省去示例的重复生成循环。不要先填满 DPU 输入再调用这个默认生成器，
它会明确拒绝覆盖非空输入。保留单次加载标志、`vio_cfg_by_host`、Host→slot 映射和
执行 profile 对 PCIe 字段的设置即可；不必为此增加一个 cfg 派生层。

默认 REAL_DUT 对应 `SV_IF_MODE`、RC active、EP passive、`ep_auto_response=0`。
保留的 MODEL 入口需要平台提供真实 Virtio 模型和共享 completion adapter；
普通 EP 自动应答不等价于 Virtio 设备模型。

## 编译与验证

在 `10.11.10.53` 的 VCS 环境运行；从仓库根目录使用独立 filelist。
设置五个依赖根：`AIP_CORE_ROOT`、`DPU_COMMON_ROOT`、`NET_PACKET_ROOT`、
`HOST_MEM_ROOT`、`PCIE_WORK_ROOT`。AIP 使用含 `src/sv` 的 update 分支布局。

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

结构测试不执行 DUT 寄存器计划、不发送报文；它检查对象构建、参数、接口和身份绑定。
真实收发使用项目自己的 top、DUT、DMA 服务和 test 收尾检查。

2026-11-06 在 `10.11.10.53` 的组合式参考结构回归结果：

| 场景 | 结果 |
| --- | --- |
| 默认 1 Host / 1 PF 服务 | 32 项检查通过 |
| 2 Host / 每 Host 2 VF 服务，queue=512、PH credit=23 | 66 项检查通过 |
| 2 Host / 每 Host 2 PF 服务 | 61 项检查通过 |
| 2 Host 使用同值 BDF、交换 RC/EP slot | 48 项检查通过 |
| IOMMU 策略冲突、缺 Host 映射、重复/越界 slot、缺/复用 native VIF、空/复用协议 VIF | 8 个负例均命中预期生产 fatal，无超时 |
| 既有 AIP 参数 / command 兼容测试 | 参数 34 项检查通过；命令测试通过 |

项目和 AIP 编译均通过，VCS warning/error 为 0；所有正例和兼容测试的 UVM
warning/error/fatal 均为 0。检查包含快照和共享内存句柄、
原生 cfg-only 路径、实际 RC sequencer/VIF、Host 隔离以及 AIP 目标注册。
