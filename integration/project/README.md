# 一个 env 和一个 env_cfg：Intel PCIe bind 接入参考

把 [project_env_cfg.sv](project_env_cfg.sv) 的成员和方法合入你的大 cfg，把
[project_env.sv](project_env.sv) 的成员和方法合入你的大 env 即可。
示例中的 `project_` 只是占位命名，可以统一换成项目自己的类名；已有 env/test
不需要再包一层 `project_env`，也不需要继承 `dpu_device_env`。

**[完整代码展示](../../docs/project_env_full_code.md)** 按 cfg、env、test、package
顺序展开全部函数体。实际维护的源码在本目录，二者保持一致。

env 和 env_cfg 均采用类内 `extern` 声明、类外实现；实现在各自同一个 `.sv` 文件中，
编译入口不变。合入已有工程时，声明与实现要一起保留；修改类名时，也要同步修改
类外实现的 `project_env::` / `project_env_cfg::` 限定名。

固定使用 Intel PCIe 和 `REAL_DUT`，默认规模为 **1 Host、1 PF、0 VF**。
每 Host 一个 PCIe segment 0，同 Host 的 PF/VF 共用物理端口。
**真实 DUT 为 EP 应用逻辑，每 Host 只创建一个 RC，接口方向为 `HARD_IP`。** 项目层只创建
`pcie_tl_env_config`，采用 PCIe TL 的 cfg-only 路径。
不构造 PCIe global/topology 对象，不使用 SVT、Serial VIP 或链路训练。

`integration/` 始终是可选参考目录，只由独立 filelist 显式编译；原生产
filelist/package 不导入本目录。已有工程按需合入代码和缺少的依赖，避免重复编译包。

唯一入口是 [filelists/project_integration.f](../../filelists/project_integration.f)，
直接编译 Intel interface 和 adapter，无需定义接口选择宏。
`SV_IF_MODE` 表示引脚传输；Intel adapter 由 factory instance override 选择。
env/cfg 已去掉普通 TL VIF、EP 配对和 MODEL 接入分支，可以直接参考当前代码。

## 组件与配置关系

```text
你的 test
  cfg : 你的 env_cfg extends uvm_object
    dpu_cfg : dpu_device_env_config
      device_cfg / placement_cfg / vio_policy / executor
    vio_cfg : virtio_net_env_config                全局行为模板
    vio_cfg_by_host[h] : virtio_net_env_config     每 Host 的独立行为配置
    pcie_cfg : pcie_tl_env_config                  原生 TL 配置
    tl_slot_by_host[h]                            Host → 物理 RC slot
    host_mem_pool_binding / protocol_vifs
    intel_rc_vifs / intel_cfg_by_slot              每个物理端口的接口和配置

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
| 大 env build | 准备共享内存 → 填写 PCIe slot/内存绑定 → 安装默认 executor/backend → 创建 DPU → 取得或发布 Intel cfg/VIF 并调用 setup → 创建 PCIe、DPU 下的 VIO |
| DPU build | resolver 解析并冻结 device/resource snapshots，发布到子树，给 executor 绑定 snapshot |
| VIO build | 按 Host scope 消费同一份 snapshot/resource manager，创建对应 PF/VF 服务 |
| PCIe build | 消费同一个 `pcie_cfg`，创建原生 TL agents、adapters、manager |
| 大 env connect | 校验 Intel build 时的绑定 → 绑定协议 VIF、寄存器 backend → 逐 Function 绑定 PCIe endpoint |
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
| PCIe TL 配置 | `intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env")` 在创建 PCIe 前下发 |
| Intel 接口 | `cfg.intel_rc_vifs[slot]` / `intel_cfg_by_slot[slot]`，或借用 bind wrapper 在 adapter 路径发布的相同句柄；build 前完成 |
| 协议观察接口 | 优先使用 Host VIO cfg 的完整身份映射；否则用 `cfg.protocol_vifs`，最后查 top 的 `protocol_event_vif_N` |
| 寄存器 executor | `cfg.dpu_cfg.executor`；为空才创建默认 `dpu_pcie_reg_executor + pcie_tl_dpu_reg_backend` |

`tl_slot_by_host[h]` 默认 `h → h`，可以在 load 后、env build 前交换映射。例如：

```systemverilog
cfg.load_params();
cfg.tl_slot_by_host[0] = 1;
cfg.tl_slot_by_host[1] = 0;
// VIF 和 Intel cfg 始终按接口 slot 填写，不随 Host 编号重新解释。
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

1. build 中在 load 后接入 Intel VIF、协议 VIF，以及已有 pool/IOMMU；再把大 cfg
   以 `"cfg"` 下发给自己的 env。使用 bind 时 Intel cfg/VIF 已由 wrapper 发布，
   不需要再创建一套。单 Host 默认使用 slot 0。
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

## Intel 配置放在哪里

参考 env/cfg 直接使用 Intel。`cfg.load_params()` 和
`env.prepare_pcie_config()` 设置的关键组合为：

```systemverilog
cfg.pcie_cfg.if_mode          = SV_IF_MODE;
cfg.pcie_cfg.rc_agent_enable  = 1;
cfg.pcie_cfg.rc_is_active     = UVM_ACTIVE;
cfg.pcie_cfg.num_rc           = cfg.tl_slot_by_host.num();
cfg.pcie_cfg.ep_agent_enable  = 0;
cfg.pcie_cfg.num_ep           = 0;
cfg.pcie_cfg.ep_auto_response = 0;
cfg.pcie_cfg.use_unified_mem  = 1;
cfg.pcie_cfg.infinite_credit  = 1;
```

Intel adapter 自身会驱引脚，所以这里关闭 EP 组件，不能仅将 EP 标为 passive。
每个 Host manager 用 `bind_host_memory(slot, host_id, manager, why)` 交给对应 RC，
不生成 EP→Root 绑定；每个 Function 的 endpoint 使用 RC monitor，EP monitor 为 null。

`env.build_phase()` 在创建 PCIe 子环境前执行：

```systemverilog
prepare_intel_bindings();
intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env");
pcie_env = pcie_tl_env::type_id::create("pcie_env", this);
```

`prepare_intel_bindings()` 完整实现见 [env 源码](project_env.sv)；它在以下实际路径
设置 `intel_cfg` 与 `vif`，然后 Intel adapter 在自己的 build 中读取：

```text
uvm_test_top.env.pcie_env.rc_adapter_0
uvm_test_top.env.pcie_env.rc_adapter_1
```

单 RC 仍叫 `rc_adapter_0`，不能用标量句柄名字 `rc_adapter` 当组件路径。
如果你的大 env 不叫 `env`，更新 top/bind 中的实际路径；env 内使用相对路径不变。

setup 函数安装当前 PCIe env 子树的 factory instance override，设置 `SV_IF_MODE`、
公共无限 FC 和 `pcie_svt_bridge_required=1`。这个历史字段名在这里表示外部引脚
bridge，不会创建 SVT、global_cfg、topology adapter 或链路训练。

### 已经使用 Intel bind wrapper

沿用 `pcie_intel/bind/intel_pcie_bind_wrapper.sv` 的
`intel_pcie_bind_wrapper_inout`。当前一个 Host 时只绑定一个物理端口，例如：

```systemverilog
// 放在项目自己的 bind 文件中；路径替换成实际 DUT 实例。
// .* 仅适用于绑定点包含与 wrapper 同名、同宽度的全部 wire/tri 网络。
bind tb_top.u_dut.u_pcie0 intel_pcie_bind_wrapper_inout #(
    .ADAPTER_PATH("uvm_test_top.env.pcie_env.rc_adapter_0"),
    .SIDE("HARD_IP")
) u_pcie_bind (.*);
```

wrapper 在 time-0 已发布 cfg/VIF；大 cfg 中可以留空 `intel_cfg_by_slot` 和
`intel_rc_vifs`，env 会从 config_db 取得并保留同一个对象。两个入口同时有值时，
要求它们是同一 cfg/VIF；冲突立即报错，不静默替换 wrapper 配置。

top 需在 wrapper 初始化之后调用一次 `run_test()`：

```systemverilog
initial begin
    #0;
    // 本 initial 位于 tb_top；可选地修改 wrapper 持有的同一 cfg。
    // 不修改 cfg.side：引脚方向已由 bind 参数 SIDE 在展开时决定。
    u_dut.u_pcie0.u_pcie_bind.cfg.check_parity = 1;
    u_dut.u_pcie0.u_pcie_bind.cfg.rx_gap_cycles = 0;
    run_test();
end
```

完整 pin 连接和每个信号方向见外部
[Intel bind 文档](https://github.com/Beihang-yuting/pcie_intel/blob/main/docs/integration/bind.md)。
wrapper 的 inout actual 必须是 `wire/tri` net；DUT 内部为 `logic` 变量时，可选取父层
实际连接 DUT 端口的网络作为绑定点。`HARD_IP` 驱 RX、TX ready/credit，采样 DUT 的 TX；
它与 RC/EP 协议角色分开。wrapper 自带的默认 ADAPTER_PATH 少了本项目的 `pcie_env`
一层，必须显式填写完整路径；ADAPTER_NAME 仅影响 cfg 对象名，无须另设。

### 从一个 Host 扩展到多个 Host

本参考采用一 Host 一物理端口，因此 Host、RC adapter 和 wrapper 数量一致；
增加同一 Host 内的 PF/VF 不增加 wrapper。默认映射如下：

| DPU Host | TL slot | 物理绑定点示例 | ADAPTER_PATH |
| --- | --- | --- | --- |
| Host0 | 0 | `tb_top.u_dut.u_pcie0` | `uvm_test_top.env.pcie_env.rc_adapter_0` |
| Host1 | 1 | `tb_top.u_dut.u_pcie1` | `uvm_test_top.env.pcie_env.rc_adapter_1` |

当前单 Host 仅保留上面的 port0 bind，运行参数为默认值：

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=0
```

以后接入第二个物理端口时，再将下面的实例级 bind 加入工程并重新编译，运行设
`+dpu.hosts=2`。env/cfg 不需要新增第二套类，默认自动生成 `tl_slot_by_host[1]=1`：

```systemverilog
bind tb_top.u_dut.u_pcie1 intel_pcie_bind_wrapper_inout #(
    .ADAPTER_PATH("uvm_test_top.env.pcie_env.rc_adapter_1"),
    .SIDE("HARD_IP")
) u_pcie_bind (.*);
```

每个 wrapper 独立持有一个 interface 和一个 cfg，并独立发布；不能多个端口使用同一个
ADAPTER_PATH，也不应使用固定路径的模块类型 bind 覆盖该类型的所有 DUT 实例。
env 会拒绝已用 slot 间复用 cfg/VIF，但不会清点所有 HDL wrapper，也无法追溯同一路径
在 time-0 被重复发布覆盖。使用实例级 bind 和唯一完整路径可以明确对应关系。

bind 的存在和数量在 elaboration 时确定；`dpu.hosts` 在 UVM build 前加载，不能生成
HDL wrapper。只绑定一个端口却设置两个 Host，会因缺 `rc_adapter_1` 的 VIF 立即 fatal。
也不要在当前不用的端口上预绑仍接着有效 DUT 网络的 wrapper：它持续驱动所拥有的网络，
没有 UVM adapter 初始化的接口可能把 X 送入 DUT。按本次需要的端口选择 bind 文件即可，
无需额外接口选择宏。

需要交换 Host 与物理端口时，只在 build 前调整 `tl_slot_by_host`；wrapper 的路径始终
表示物理 slot。接口中的 4×256 bit 是同一端口的四个 AVST segment，与 Host 数无关。
多 Host 还需满足 DPU caps、Function 数和 queue 资源上限，并提供各活动 Function 的协议 VIF。

### 平台直接持有 Intel interface

不使用 wrapper 时，可在已有 test 的 `bind_platform_handles()` 中注入 HDL top
发布的 VIF；下面是完整的单 Host 注入方法，`project_base_test` 已先调用 load：

```systemverilog
// 放在你的 test 类内；package 需 import intel_pcie_adapter_pkg::*。
// top 在 run_test 前把已有 interface 发布为 uvm_test_top 的 intel_vif_0。
virtual function void bind_platform_handles();
    intel_pcie_vif_t	vif;

    if (!uvm_config_db#(intel_pcie_vif_t)::get(this, "", "intel_vif_0", vif) || vif == null)
        `uvm_fatal("MY_TEST", "Intel port 0 interface is missing")
    cfg.intel_rc_vifs[0] = vif;
    cfg.intel_cfg_by_slot[0] = intel_pcie_adapter_config::type_id::create("intel_port0");
    cfg.intel_cfg_by_slot[0].side = INTEL_PCIE_HARD_IP;
    cfg.intel_cfg_by_slot[0].check_parity = 1;
    cfg.intel_cfg_by_slot[0].credit_enable = 1;
    cfg.intel_cfg_by_slot[0].rx_gap_cycles = 0;
    cfg.intel_cfg_by_slot[0].validate();
endfunction
```

top 的对应发布语句（`pcie_port0` 为已连接 DUT 的真实 interface）为：

```systemverilog
uvm_config_db#(intel_pcie_vif_t)::set(
    null, "uvm_test_top", "intel_vif_0", pcie_port0);
```

没有注入 Intel cfg 时，env 创建独立的 HARD_IP 默认配置；没有 VIF 则立即失败。
多 Host 按物理 slot 循环注入，不得多个端口共用同一个可变 cfg 或 VIF。
`protocol_vifs` 仍要按活动 Function 提供，它是 Virtio 协议观察接口，不能用 Intel
PCIe VIF 替代；也可沿用 top 的 `protocol_event_vif_N` 发布方式。

| Intel cfg 字段 | 默认值与含义 |
| --- | --- |
| `side` | 本参考要求显式 `INTEL_PCIE_HARD_IP`；库类原默认 AUTO 不用于本参考的外部注入 |
| `header_big_endian` / `check_parity` | 默认 1 / 0，匹配 DUT 的 header 字节顺序与 parity 契约 |
| `credit_enable` | 默认 1，控制本地 AVST credits |
| `header_capacity[3]` / `data_capacity[3]` | `{16,16,16}` / `{512,512,512}`；索引 P/NP/CPL，data 单位 16 B |
| `infinite_header[3]` / `infinite_data[3]` | 默认全 0；每类独立选择有限/无限 AVST credit |
| `tx_stop_latency` | 默认 1，合法 1..16 |
| `rx_gap_cycles` / `rx_start_segment` | 默认 0 / 0；4 段独立起包只支持 st0/st1 |
| `x16_single_width` | 默认 0，只适用于 2×256 几何 |

这些是 `intel_pcie_adapter_config` 的原有 SV 字段，目前没有 `load_params()`，
所以 `+pcie_cfg.intel.rx_gap_cycles=...` **不会自动生效**。先在 build 前设置对象字段。
已有 `pcie_cfg.*` 仍用于公共 TL 策略；Intel 接入要求 `infinite_credit=1`，
`init_*_credit` 不控制 AVST 的有限 credit，不能用它们测试 Intel 引脚背压。

### 接通引脚以后仍由平台完成的部分

Intel codec 从 `tlp.cq_route.bar_id/pf_index/is_vf/vf_index` 生成 RX 的
BAR/PF/VF sideband。当前组合层不会根据 DPU snapshot 自动填写这些 TLP 字段；
平台的发送路径需要把冻结身份和 MMIO BAR 匹配结果传给 `cq_route`，尤其是多 PF/VF。

bridge 已把 RC 收到的 DMA 请求交给 `rc_driver.handle_request()`，不要再启用
`virtio_pcie_real_dut_host_mem_responder` 订阅同一请求，避免双重响应。
共享 `host_mem_manager` 提供 GPA 存储；如果 DUT 发 IOVA，还需要平台将
requester BDF 对应的翻译接入这条 bridge 响应路径。只共享 pool 不等于完成 IOMMU 路由。

这套参考覆盖 env/cfg 的构建与连接；真实发包前还需完成平台已有的 DMA 翻译、
BAR/PF/VF sideband、协议观察及 VTX/VRX/QSCH 硬件配置。

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
Intel 的 `SV_IF_MODE`、RC active、关闭 EP 和公共无限 FC 设置即可；
不必为此增加一个 cfg 派生层。本参考限定 REAL_DUT，不再保留 MODEL completion adapter。

## 编译与验证

在 `10.11.10.53` 的 VCS 环境运行；从仓库根目录使用独立 filelist。
设置五个依赖根：`AIP_CORE_ROOT`、`DPU_COMMON_ROOT`、`NET_PACKET_ROOT`、
`HOST_MEM_ROOT`、`PCIE_WORK_ROOT`。AIP 使用含 `src/sv` 的 update 分支布局。

同时设置 `INTEL_PCIE_ROOT`，使用下面的独立入口。默认几何为 **4×256 bit**，
即每段 256 bit、4 段；不同接口几何必须对 interface/package/top 使用同样的宏。
若采用 bind wrapper，在自己的工程入口中再加入
`$INTEL_PCIE_ROOT/bind/intel_pcie_bind_wrapper.sv` 和项目的 bind 文件；
不要叠加 Intel 的整份 `sim/filelist_lib.f`，否则公共依赖会重复编译。

```bash
mkdir -p build/project_intel
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f filelists/project_integration.f -f filelists/project_tests.f \
  -top project_env_tb -Mdir=build/project_intel/csrc -o build/project_intel/simv \
  -l build/project_intel/compile.log
./build/project_intel/simv -exitstatus +UVM_TESTNAME=project_env_smoke_test \
  +dpu.hosts=2 +dpu.vfs_per_pf=2 +vio.queue_size=512 \
  +PROJECT_EXPECT_HOSTS=2 +PROJECT_EXPECT_FUNCTIONS=4 +PROJECT_EXPECT_QUEUE=512 \
  -l build/project_intel/smoke.log
```

结构测试不执行 DUT 寄存器计划、不发送报文；它检查对象构建、参数、接口和身份绑定。
真实收发使用项目自己的 top、DUT、DMA 服务和 test 收尾检查。

当前版本的验证覆盖两类入口：结构 top 检查 cfg/VIF 的显式注入、参数和错误诊断；
真实 HDL bind 探针把库 wrapper 绑定到独立 wire 端口，在复位后检查接口方向、
单/双 Host 对应关系及 slot0 ready 切换时的端口隔离。探针端口不包含真实设备响应，
不把这些检查当作 PCIe/Virtio 报文业务验证。

2026-11-06 在 VCS 主机 `10.11.10.53` 对精简后的源码重新验证，所有编译均未定义接口选择宏：

| 验证项 | 结果 |
| --- | --- |
| 单端口 bind、双端口 bind、结构 top 三份独立编译 | 编译及严格日志检查全部通过 |
| 真实 bind：单 Host 单 PF、单 Host 双 PF、单 Host 双 VF、双 Host 多 VF、双 Host 交换 slot | 5 个正例通过，运行至 80ns，覆盖复位后采样与物理引脚 ready 隔离/恢复 |
| 只绑定一个 wrapper，却设置两个 Host | 精确报告缺 `uvm_test_top.env.pcie_env.rc_adapter_1` 的 Intel VIF |
| 显式注入：默认、双 Host 多 VF、交换 slot、自动创建默认 Intel cfg | 4 个正例通过 |
| 结构错误与参数冲突：缺失/复用接口、错误 SIDE、配置冲突、Host 映射、MODEL/EP 自动应答等 | 17 个负例均命中预期生产 fatal，无测试兜底 fatal 或超时 |

所有正例的仿真及严格日志检查返回码均为 0；负例均为单个预期 fatal，warning/error 为 0。
结构 top 在 1ns 结束；真实 bind 使用空闲应用端口，未验证用户实际 RTL 的报文与寄存器响应。

同日对 env/env_cfg 的 extern 格式调整另做一次结构编译和小范围回归：默认单 Host，
以及双 Host、每 PF 两个 VF、交换 slot、借用 wrapper 句柄的两个正例均通过；
缺失 Intel VIF、跨 slot 复用 Intel cfg 的两个负例均命中预期生产 fatal。
本次回归覆盖类外实现语法、对象装配与错误诊断，未重新执行真实 HDL bind 或报文测试。
