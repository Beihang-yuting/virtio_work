# 外部配置 VIO：直接组合一个 env 和 env_cfg

把 [project_env_cfg.sv](project_env_cfg.sv) 和 [project_env.sv](project_env.sv) 的组装部分
合入自己的 cfg/env 即可；不要求继承参考 cfg，也不继承 `dpu_device_env`。
公共配置已移到 `dpu_common`，无需复制整套表定义或配置 seq。
[完整源码](../../docs/project_env_full_code.md) 由实际文件生成，包含 filelist、package、
env_cfg、env、base_test 和固定单队列示例。

每 Host 一个 RC、一个 Intel HARD_IP wrapper、一份 Host memory manager；同 Host 的
PF/VF 共用端口。DPU 分配 Function/BDF/BAR/qpair/vector，VIO 分配实际 ring/IOVA，
PCIe 使用同一份 BAR 和内存结果。设备配置只走 Memory Read/Write，不执行 PCI capability
发现、feature 协商或 Virtio reset/init。

## 文件职责与编译顺序

| 实现位置 | 职责 |
| --- | --- |
| `dpu_common/src/dpu_env_cfg.sv` | 拓扑输入、布局、表策略、资源查询及实际队列的表项生成 |
| `dpu_common/src/dpu_table_types.sv`、`dpu_vio_table_types.sv` | 当前图片版本的 packed 字段、布局、上下文和中性队列导出 |
| `dpu_common/src/dpu_bar_map.sv` | 查询真实 BAR 租约、范围检查和分组打印 |
| `dpu_common/integration/pcie/dpu_pcie_bar_map.sv` | 在同一 BAR 对象上增加 Host→RC/Intel 路由 |
| 同目录 `dpu_cfg_seq.sv`、`dpu_bar_reg_seq.sv` | 写表、AF 同步、独立 BAR 相对寄存器访问 |
| `integration/dpu/vio_dpu_cfg_seq.sv` | 准备/导出/确认/释放实际 VIO ring，复用公共写表 |
| `integration/dpu/vio_pcie_rc_driver.sv` | 复用 PCIe RC，补齐 Function IOMMU、DMA 和 MSI-X 接收 |
| `project_env_cfg.sv`、`project_env.sv` | 组合三个 cfg，创建组件、绑定接口和发布句柄 |
| `project_base_test.sv` | 平台就绪后启动配置，再运行 Tcl 业务 |

[project_integration.f](../../filelists/project_integration.f) 是可选完整入口。
已有工程按依赖顺序增补缺少的包，不能重复编译 package 或其中 include 的 `.sv`：

```text
AIP → DPU / host_mem / net_packet / PCIe TL → VIO / VIO AIP
    → Intel interface / adapter
    → $DPU_COMMON_ROOT/filelists/dpu_pcie.f
    → integration/dpu/virtio_dpu_pkg.sv
    → 用户 env package（或参考 project_env_pkg）
```

DPU 核心不 import PCIe/VIO；DPU PCIe 集成也不依赖 VIO。
生产核心 filelist/package 不自动引入参考 project，模型测试另加 `project_tests.f`。

## 构建和句柄传递

1. base_test 创建自己的 cfg，调用一次组合入口 `cfg.load_params()`；它加载 DPU 输入，
   缓存各 Host 的最终 VIO service 需求，再交给 DPU placement，最后加载 PCIe 传输参数。
   首次加载幂等，env 再调用不会重复随机采样。全局、Host 模板先各自采样，service
   继承已加载值，只读取精确 service 覆盖；运行期 Host 候选也复用同一份全局采样结果。
2. 平台绑定现有 Intel/protocol VIF 和可选 Host pool，将同一 cfg 传给自己的 env。
   env 创建 `dpu_device_env`、`pcie_tl_env` 和每 Host 的 `virtio_net_env`；VIO 放在 DPU
   子树以读取已解析的快照，整个过程不写 DUT。
3. connect 建立一份 `dpu_pcie_bar_map`，交给 `cfg.dpu_cfg.bar_map` 和 RC driver；
   PCIe 与 VIO 绑定同一个 Host manager。BAR 不在 `pcie_cfg` 中再分配一次。
4. 发布以下句柄，配置 seq 就不需要知道用户自己的 env_cfg 类名：

```systemverilog
// 在用户 env 中，pcie_env 是实际 PCIe 子环境名。
uvm_config_db#(dpu_env_cfg)::set(this, "pcie_env.*", "dpu_cfg", cfg.dpu_cfg);

foreach (vio_envs[h]) begin
    uvm_config_db#(virtio_net_env)::set(
        this, "pcie_env.*", $sformatf("vio_env_h%0d", h), vio_envs[h]
    );
end
```

`dpu_cfg` 是公共对象，不是包住三个子 cfg 的新容器。最终资源查询用
`cfg.dpu_cfg.device_snapshot/resource_snapshot/bar_map`；实际 VIO setup 由
`env.vio_envs[h].get_external_setup()` 取得，DPU 写表使用其导出的
`cfg.dpu_cfg.queues_by_host[h]`。导出不再分配 ring，也不重新采样参数。

## base_test 与默认配置流程

[project_base_test.sv](project_base_test.sv) 给出完整构建和运行顺序。平台需要实现
`bind_platform_handles()`、`prepare_platform()`、`finish_platform()`，分别负责现有
接口、复位就绪和业务检查/停机；不能把真实 DUT 等待写成空 task。
自己的 base_test 在平台就绪后启动：

```systemverilog
vio_dpu_cfg_seq	config_seq;
int unsigned	host;

config_seq = vio_dpu_cfg_seq::type_id::create("config_seq");
if (!cfg.tl_slot_by_host.first(host)) begin
    `uvm_fatal("CONFIG", "no PCIe Host configured")
end

config_seq.start(env.pcie_env.rc_agents[cfg.tl_slot_by_host[host]].sequencer);
if (!config_seq.success) begin
    `uvm_fatal("CONFIG", config_seq.error_msg)
end

env.register_aip_commands();
aip_tcl_bridge::run_loop();
```

默认顺序为：

```text
选择需要 MSI-X 的 Function
    → Host0/PF0 BAR0+0x1010 写 0x5555aaaa、读回状态8
    → BDF、所选 MSI-X（configure_public=1 时另写公共表）
    → VIO 准备实际 ring 并导出
    → Notify 有效项 → 管理 BAR+0x80044 写1
    → QSCH → VTX/VRX 初始化 → 队列使能
    → 可选普通表读回 → 确认 VIO 可发包
```

之后每成功发送 100 次完整 DWORD 配置写，插入一次 AF 状态读；不补尾读、不轮询。
AF 读关闭 SCB 的历史 RAM 写值比较，但仍检查 Completion 和返回值8。
`dpu.verify_readback=0` 只省去普通表读回，不关闭 AF 同步。posted 写成功表示已发送，
真实 DUT 的应用结果还要由业务检查确认。配置失败立即停止，不确认 READY 或释放 DMA 资源。

每批 VIO/RDMA Notify 全部表项成功后，每个不同管理 BAR 写一次 `+0x80044=1`。
空批次不写；表写失败不使能；使能失败返回失败。这个偏移不再叠加模块地址，也没有 bank 位。
RDMA 仍通过独立 `configure_rdma_notify(scope, ok, why)` 使用，不自动加入 VIO 默认流程。

平台停止 DMA 后可调用同一 `vio_dpu_cfg_seq` 的
`release_vio_resources(config_seq.selection, 1, ok, why)`；先确认停机，再释放。
仅当 `config_seq.selection != null` 时需要释放 VIO 资源。

## 不启用 VIO 或仅启用 VRX

不使用 VIO 时设置 `+vio.enabled=0` 即可；external 集成也支持 `+vio.pairs=0`
或同时 `+vio.tx_enable=0 +vio.rx_enable=0`。这些条件按每个 service 最终覆盖后的值判断：
不分配 ring，不要求 VIO Notify/MSI-X 消息配置，不写 VTX、VRX、Notify 表及其使能寄存器、
QSCH 表和模式寄存器。公共 AF/BDF 等仍按原流程执行。
全局/Host 参数作为模板，精确 service 覆盖仍可单独启用某个 Function。

仅启用 VRX 时，在下方 Packed 参数基础上设置：

```text
+vio.enabled=1 +vio.pairs=1 +vio.tx_enable=0 +vio.rx_enable=1
+vio.vrx.dsc_pre_max_num=3
+vio.prefetch_ram=ram_h0 +vio.prefetch_start=0 +vio.prefetch_slots=32
```

保留实际平台的 Notify 和 completion 参数。这里预取区示例为32槽，需与 DUT RAM 分配一致。
只配置 VRX 和 Notify，不需要提供 QSCH/VTX 布局或调度参数；多 Function 混合 TX/RX 时，
仅有 TX 的队列生成 QSCH。以上是首次构建的使能选择，快照恢复仍不改变已冻结的队列数量和启用集合。

## 一对 Packed VTX 的启动参数

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=0
+dpu.configure_public=0 +dpu.configure_bdf=1 +dpu.driver_layouts=1
+dpu.verify_readback=0 +dpu.reg_target=h0.pf0.bar0 +dpu.print_bar_map=1
+vio.enabled=1 +vio.pairs=1 +vio.tx_enable=1 +vio.rx_enable=0
+vio.queue_type=VQ_PACKED +vio.queue_size=256
+vio.features=0x0000000500000000
+vio.completion_mode=VIRTIO_COMPLETION_POLLING
+vio.notify_bar=0 +vio.notify_base=0 +vio.notify_stride=0
+vio.notify_encoding=VIO_NOTIFY_DPU32
+vio.notify_net_pair5=1
+dpu.qsch.topology=DPU_QSCH_AUTO +dpu.qsch.mode=0
+dpu.qsch.cos=0 +dpu.qsch.dpt=0 +dpu.qsch.print=1
```

该配置共 **25 笔 32-bit 配置写和 1 笔 AF 读**，包含新增 Notify 使能，不包含后续业务 DB。
单 PF0 软件路由默认 `requester=0/intel_pf=0/intel_vf=-1/vport=0`；其他 Function
需要实际硬件身份。BDF 表默认 `BAR+0x108000+bdf_index*4`，PF0 的值为 `0x00010000`。

改 Custom 使用 `+vio.queue_type=VQ_CUSTOM +vio.features=0`，其他关联仍来自同一资源。
Packed 使用标准12B `virtio_net_hdr`，512B 报文长度另计；Custom 使用私有 descriptor/CQ。

多个 PF/VF 可分别指定队列数。以下片段只展示业务选择；真实平台的 Function 路由、
接口绑定及公共参数沿用自己的配置：

```text
+dpu.hosts=1 +dpu.pfs_per_host=2 +dpu.vfs_per_pf=1
+vio.enabled=0 +vio.tx_enable=1 +vio.rx_enable=0
+vio.h0.pf0.i0.enabled=1 +vio.h0.pf0.i0.pairs=2
+vio.h0.pf1.i0.enabled=1 +vio.h0.pf1.i0.pairs=3
+vio.h0.pf0.vf0.i0.enabled=1 +vio.h0.pf0.vf0.i0.pairs=4
+dpu.qsch.net_id=[100:400] +dpu.qsch.group_id=random
+dpu.qsch.dpt=0 +dpu.qsch.print=1
```

这会为三个启用 TX 的 Function 生成三个唯一随机 net_id；PF0 的两对队列共用
一个 net，PF1 的三对共用另一个，VF0 的四对共用第三个。这里 `pairs` 是队列对数，
TX 的 Q2TC 表使用实际 `global_qpair_id`，不能把本地 virtqueue_id 或 PF 编号当索引。
同源 Host、同目的 dpt 共享一个 group；Q2TC、N2G、G2P、SPWRR 和 TC_WEIGHT 自动保持关联。
net/group 随机值只生成一次，查询和写表不重复采样，使用仿真器种子复现。

固定值直接生效，不需要随机开关。一个 PF 的示例：

```text
+dpu.qsch.net_id=100 +dpu.qsch.group_id=20
+dpu.qsch.eth_ports=8 +dpu.qsch.dpt=8 +dpu.qsch.cos=3
+dpu.qsch.spwrr=0x55 +dpu.qsch.tc_weight=0x87654321
+dpu.qsch.print=1
```

此处 `dpt=8` 是 HOST0；默认 `dpt=0` 是 ETH0。按图片定义，ETHn=n，
HOSTh=`eth_ports+h`；ETH数要与真实 DUT 一致，目的 Host 必须已创建，13..15保留。
两个 ETH 时 HOST0/1 编码为2/3。`dpt` 也支持 rand/random 或有限范围，选择当前有效节点。

多个 Function 可用精确路径分别覆盖，例如：

```text
+vio.h0.pf0.i0.qsch.net_id=100 +vio.h0.pf0.i0.qsch.group_id=20
+vio.h0.pf0.i0.qsch.dpt=0
+vio.h0.pf1.i0.qsch.net_id=200 +vio.h0.pf1.i0.qsch.group_id=30
+vio.h0.pf1.i0.qsch.dpt=8
```

先用 `vio.h0.pfP[.vfV].i0.pairs` 指定该 Function 队列对数；每组队列都进入对应 net。
同源 Host+dpt 的 Function 共享 group，其显式 group 参数需一致；不同 route 需不同 group。
固定值优先保留，随机候选不足或冲突会报出具体 Function/route，seq 不继续写 QSCH。

`env`/`env_cfg` 和 base_test 沿用原接线。`dut_config` 对应 `vio_dpu_cfg_seq`，启动后：

```text
VIO 准备实际队列 → dpu_cfg.set_queues() 生成唯一映射
    → dpu_cfg_seq.configure_qsch() → pcie_tl_reg_seq → DUT
```

以一个 PF0、一对队列（global_qpair_id=0）和上面的 net100/group20/HOST0 固定参数为例，
默认驱动参考布局写出下表。所有地址都会加环境分配的管理 BAR base，无需用户手算 BAR。

| 表 | BAR 内偏移 | 32-bit 写入值 |
| --- | --- | --- |
| QSCH mode | `0xb001c0` | `0x00000000` |
| Q2TC[0] | `0xb10000` | `0x80000323`（net100、COS3） |
| N2G[100] | `0xb12190` | `0x80000014`（group20） |
| G2P[20] | `0xb14050` | `0x80080000`（HOST0，源Host0） |
| SPWRR[100] | `0xb16190` | `0x00000055` |
| TC_WEIGHT[100] | `0xb18190` | `0x87654321` |

这是完整配置流程中的 QSCH 部分；AF、BDF、Notify、VTX/VRX 仍按实际使能执行。
net_id 变化会同时改变 Q2TC 内容及三张 net 表的地址；group_id 变化会同时改变 N2G
内容和 G2P 地址。seq 直接消费 cfg 保存的结果，不再随机，也无需另传一份参数。
管理窗口可用 `dpu.qsch.reg_target=h0.pf0.bar0` 覆盖，不改变队列自身的 PF/VF 归属。

原 `net_base/net_stride/group_id/eth_ports/ets` 策略使用 `DPU_QSCH_MANUAL`。
自动生成当前覆盖 VNET (`dpu.qsch.mode=0`)；不提供业务运行中的动态改配。
参数重载后，需重新启动配置 seq 才写 DUT；已运行的 VIO 队列需先停机并释放。

若从未配置的快照进入 Tcl，可先覆盖参数，再沿已有入口加载并配置：

```tcl
set_param path=dpu.qsch.net_id value=100
set_param path=dpu.qsch.group_id value=20
set_param path=dpu.qsch.dpt value=8
load_params
dut_config
```

随机范围用 Tcl 花括号保留方括号，例如
`set_param path=dpu.qsch.net_id {value=[100:400]}`。

Notify 表的查找基址默认取实际 doorbell 地址的 `[60:7]`，无需再重复指定
`vio.notify_table_bar/notify_table_offset`。显式提供任一项时，另一项沿用当前值
（初始为0），环境检查 BAR 范围、128B 对齐以及与实际 doorbell 高位一致；低7位可不同。
这些参数描述业务地址，写表使用的管理 BAR 仍由 `vio.notify_table.reg_target` 控制。

改 MSI-X 时提供真实 Host 消息地址/data，例如：

```text
+vio.completion_mode=VIRTIO_COMPLETION_MSIX
+dpu.msix.msg_addr_base=0x900000000000 +dpu.msix.msg_addr_stride=4
+dpu.msix.msg_data_base=0x13572468 +dpu.msix.msg_data_stride=0x100
```

消息地址不是 DUT BAR 地址；MSI-X 完成必须收到匹配消息，没有轮询兜底。
VRX 还需要打开 `vio.rx_enable`，设置实际 prefetch RAM/范围，并从平台网络侧送包。

单 PF0 开 32 对时设置 `+vio.pairs=32 +dpu.caps.af_extra_queue_count=0`。
当前核心 caps 的 AF 额外队列默认仍为11，会计入每 Function 的32对上限；本次迁移没有改默认能力。
一个 PF 的32对是32项 Notify，TX/RX 共用每对的一项；不是每个 BAR 仅一项。
Notify 按 `{Host, BAR匹配基址, pair编号}` 排行，global qid 写入内容。
首次配置前 DUT 未使用项须已复位为无效；环境不写满512行无效 Notify。

固定联调可使用 [project_single_queue_config_seq](project_single_queue_config_seq.sv)，
它继承 `vio_dpu_cfg_seq`，固定 Host0/PF0、Packed/256/Polling/TX-only 及驱动参考地址；
BAR 和 ring 地址仍取实际分配值。参数化测试使用 `vio_dpu_cfg_seq`。

## 修改表地址和单项写法

地址/位域对照见 [driver_address_example.md](driver_address_example.md)。
`cfg.dpu_cfg.use_driver_reference_layouts()` 默认补齐未提供的 BDF/MSI-X/VIO/QSCH 布局。
修改地址在 `cfg.load_params()` 后、env 创建前设置 `cfg.dpu_cfg.table_layouts[kind]`。
`dpu.driver_layouts=0` 表示完全由平台提供；`reg_target` 只选择 BAR，不能代替布局。

普通表按高 DWORD→低 DWORD 写，DWORD 内保持 little-endian。
VTX/VRX 先四次32-bit数据写，再清触发、置触发；不会每个 DWORD 触发一次。
公共 `dpu_cfg_seq` 保留独立 `configure_*`、virtual `write_*` 和 MMIO helper，
只在访问行为确有差异时覆盖 `write_bdf/write_vtx/...`；无须增加一层同名转发 task。
平台自定义 BAR 分组/控制项也保留，默认 `configure_public=0` 不依赖这些布局。

## AIP 命令注册和寄存器访问

在已有命令注册 package 中替换类型即可，RC 表达式沿用项目已有句柄：

```systemverilog
`aip_cmd_user_seq(dut_config, vio_dpu_cfg_seq, virtual_sqr::pcie_rc_sqr)
`aip_cmd_reg(reg_acc, dpu_bar_reg_seq, virtual_sqr::pcie_rc_sqr, seq.error_msg, seq.check_read_data)
```

需要 import `dpu_pcie_pkg::*`、`virtio_dpu_pkg::*`。`reg_acc.addr` 是 Host0/PF0 BAR0
内偏移，seq 自动查询实际 base 和 Host0 RC，不把传入 addr 原地加成绝对地址：

```tcl
reg_acc write 0x1010 4 0x5555aaaa
reg_acc read 0x1010 check_read_data=0
```

`check_read_data=0` 仅关闭 SCB RAM 历史值比较，适用于寄存器状态读；`reg_acc read` 返回原始值，不自动判断是否等于8。普通内存默认保留比较；完整 `len/mask/wdata/rdata` 沿用原生 `pcie_tl_reg_seq`。

在派生配置 seq 内访问其他 Function/BAR，使用：

```systemverilog
pcie_bar_write_by_name("h0.pf0.vf3.bar2", 'h40, 4, 128'h1234, 0, ok, why);
```

环境按该 Function 的真实 BAR 和 Intel sideband 路由。多 Host 手动访问必须写完整 `hH`。
`dpu.print_bar_map=1` 分组打印真实地址；无需把打印值重新抄回用例。

## 快照恢复后重新加载配置

参考 env 用一个顶层 task 注册一次命令：

```systemverilog
`aip_cmd_task(load_params, project_load_params)
```

宏使用 AIP 自身适配；没有额外的用户命令类，也不让多个 cfg 各注册同名命令。
合入自己的 env 时保留该 task、指向实际 env 的句柄及 EOE 绑定；只编译一个注册入口。
各子 cfg 使用 AIP 的 `aip_int/aip_enum/aip_string` 等能力读自己拥有的参数。
`dpu.*`、`vio.*`、`pcie_cfg.*` 外部路径不变。

```tcl
aip_restore base
source $::env(AIP_CORE)/dist/aip_init_so.tcl
load_params
dut_config
# 配置成功后按项目注册并执行 vio_start/vio_tx 等业务。
```

恢复不会自动修改已保存的 cfg；`load_params` 在现有对象上加载新 CLI 或 `set_param` 值，
不分配 ring、不写 DUT。只允许首次 prepare 前，或平台已停机并 release 当前代之后使用。
Host/PF/VF、BAR/BDF、pairs、queue_type、features 保持快照值；支持重载 queue_size、
TX/RX 方向、完成模式、Notify、MSI-X、QSCH/队列表策略和等待参数。当前不重载 PCIe 拓扑/传输配置。
失败返回非零 status 和简洁原因，原 cfg 保持不变；活动 ring 不隐含暂停或释放。
多 Host 准备中途失败时，配置 seq 保留已成功 Host 的 `selection`；平台确认 DUT
静止后可调用 `release_vio_resources(selection, 1, ok, why)`，再重载或重试。

保存未配置快照时，自己的 base_test 在平台就绪后进入 Tcl，由 Tcl 启动 `dut_config`；
参考 base_test 默认先自动配置再进入业务 Tcl，两种流程任选其一，不能重复配置同一代。
修改源码或 package 后要重新编译并保存快照，旧二进制快照不能换成新类布局。

## 实际组件与接收路径

```text
my_env extends uvm_env
  dpu_env : dpu_device_env
    vio_hH : virtio_net_env
  pcie_env : pcie_tl_env
    rc_agents[slot] : 使用 vio_pcie_rc_driver
    rc_adapter_slot : Intel HARD_IP
```

`vio_pcie_rc_driver` 继承原生 RC，依据相同 BAR/Function 视图处理 IOVA、DMA 和 MSI-X；
不是第二个 PCIe responder。RC monitor 观察入站，driver.tx_ap 观察实际发出的 DB。
`tl_slot_by_host[h]` 默认 h→h，load 后/build 前可交换；VIF 始终按物理 slot 填写。
配置日志按 Host/PF/VF/BAR 分组；布局缺失逐行显示表、Function、目标和缺失项。
RX 空轮询不逐次打印，结束时用每 Function 一行 `RX_STATS` 汇总。

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
`intel_pcie_bind_wrapper_inout`。在 `filelists/project_integration.f` 之外，
还需将 `$INTEL_PCIE_ROOT/bind/intel_pcie_bind_wrapper.sv` 和项目自己的 bind 文件
按此顺序加入编译，并放在 Intel 接口与 adapter package 之后；这些依赖已由
`project_integration.f` 提供，不要重复编译 package。该参考 filelist 不包含
wrapper 或项目绑定。
当前一个 Host 时只绑定一个物理端口，例如：

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
// 类内声明；package 需 import intel_pcie_adapter_pkg::*。
// top 在 run_test 前把已有 interface 发布为 uvm_test_top 的 intel_vif_0。
extern virtual function void bind_platform_handles();

// 类外定义；只绑定已有平台句柄，不创建第二个接口或env。
function void my_test::bind_platform_handles();
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

## 验证与范围

运行时使用匹配依赖和用户 DUT top；模型参考测试才添加 `filelists/project_tests.f`。
生产 `filelists/virtio_net.f` / `virtio_net_pkg` 不导入 integration。
当前单 seq 验证与历史证据、匹配依赖和未覆盖边界见
[外部配置验证记录](../../docs/vio_external_configuration_validation.md)。
