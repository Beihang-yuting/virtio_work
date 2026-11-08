# 外部配置 VIO：一个 env、一个 cfg

把本目录的 [project_env_cfg.sv](project_env_cfg.sv) 与
[project_env.sv](project_env.sv) 合入已有大 cfg/env，保留类内 `extern` 声明和类外实现。
已有 env 仍 `extends uvm_env`，不需要再包一层项目 env，也不继承 DPU env。
[完整源码导出](../../docs/project_env_full_code.md) 包含依赖类型、BAR registry、RC driver、
cfg、env、配置 seq 与 base_test；修改源码后运行 `python3 scripts/render_project_code.py` 更新。
[驱动地址与逐表写入示例](driver_address_example.md) 给出 VTX/VRX、QSCH、公共映射、
MSI-X 和 BAR 窗口的可替换偏移。BAR 物理地址由环境分配、解析，不需要用户手填。

每 Host 一个 segment 0、一个 RC 与 Intel `HARD_IP` wrapper；同 Host 的 PF/VF 共用端口。
DPU 快照拥有 BDF/BAR/队列资源身份，VIO 拥有 ring/DMA，平台拥有 RTL 配置与停机判断。
项目配置只发 Memory Read/Write，不发现 capability、不协商、不自动执行 Virtio reset/init。
准备和软件确认不访问 DUT。Packed 使用标准 12B `virtio_net_hdr`，512B 报文另计；
Custom 使用私有 descriptor/CQ，512B 报文不带 Virtio header。

## 最短接入顺序

1. 编译参考入口 [project_integration.f](../../filelists/project_integration.f)，或者按
   [project_env_pkg.sv](project_env_pkg.sv) 顺序包含到已有 package。`project_dut_config_seq.sv`
   放在 cfg 后、base_test 前；普通 `.sv` include 不要再次单独编译。
   生产 VIO filelist/package 保持独立，integration 只作项目参考。
2. base_test 创建 cfg，`cfg.load_params()` 自动准备驱动参考 VIO/QSCH 布局、无 IP 的 PF0 软件路由；随后绑定 VIF，
   将同一对象 `set(this, "env", "cfg", cfg)`，再创建 env。Intel bind 接法见后文。
3. env 构建 DPU、PCIe、VIO；connect 将 `cfg.dpu_setup`、`cfg.bar_registry`、
   `cfg.rc_sequencers[slot]`、`cfg.vio_envs[h]` 填好，并把同一个 cfg 以 `env_cfg` 键
   发布到 `pcie_env.*`。config_db 传递句柄，seq 能看到 connect 后生成的资源。
   合入你自己的 cfg 类型时，同步替换 seq 与 `config_db` 中的类型名，get/set 使用同一类型。
4. 平台等待 DUT 复位释放、Intel 接口可用后，启动一个配置 seq。
   默认 body 执行 AF 声明→BDF→按完成模式配置 MSI-X→准备 ring→排序并初始化单 bank Notify→QSCH→VTX/VRX→使能→确认。
   AF 声明固定经 Host0 RC 向环境分配的 `h0.pf0.bar0.base + 0x1010` 写 `32'h5555_aaaa`，
   使用 `pcie_tl_reg_seq` 发送一个 4B Memory Write，随后从同地址读一次并等待 Completion，要求状态为8；任一步失败立即停止，不遍历 Host。
   之后每成功发送100次完整 DWORD 配置写，再执行一次相同状态读；计数属于本次 seq，不补尾读、不轮询。
   `dpu.verify_readback=1` 才增加普通表项读回；默认0跳过普通表项读回，AF同步读始终执行。
   `dpu.configure_public=1` 才额外执行 BAR/PFVF/Completion BDF/Prefix 等配置；默认关闭。
   AF 声明、默认开启的 BDF 和 MSI-X 中断模式均不依赖这个公共开关。
   `declare_af()` 与可选的 `PROJECT_AF` 表 hook 独立；此处仅检查固定状态8，不执行额外的 Host-ID 协商。AF状态读不受 `dpu.verify_readback` 控制，关闭的只是SCB历史RAM写值比较，Completion错误及状态值仍检查。
   任何一步失败在 sequence 的 `post_start()` 报告 fatal，直接通过 AIP 启动也不会静默 done。
5. 配置成功后 `env.register_aip_commands()`，进入 `aip_tcl_bridge::run_loop()`。
   业务结束后平台停止 DUT DMA，再用 `cfg.release_vio_resources()` 释放 ring。

[project_base_test.sv](project_base_test.sv) 已包含创建/启动配置 seq 的代码。
平台仍实现 `bind_platform_handles()`、`prepare_platform()`、`finish_platform()` 三个方法，
负责真实接口、复位等待和业务结束检查。当前单 PF0、轮询场景可直接启动
`project_dut_config_seq`，基类已经实现 VIO/QSCH 写表和读回，不必再派生一层只转调 helper。
平台寄存器存在只写/自清零等特殊行为时，仍可覆写对应单项 hook 或验证 task。

如果直接使用已有 base_test，run_phase 中的平台等待之后写：

```systemverilog
project_dut_config_seq	config_seq;
int unsigned				host;

config_seq = project_dut_config_seq::type_id::create("config_seq");
if (!cfg.tl_slot_by_host.first(host)) begin
	`uvm_fatal("CONFIG", "no PCIe Host configured")
end
config_seq.start(cfg.rc_sequencers[cfg.tl_slot_by_host[host]]);
if (!config_seq.success) begin
	`uvm_fatal("CONFIG", config_seq.error_msg)
end

// 到这里再注册命令、启动 VTX/VRX 业务。
env.register_aip_commands();
aip_tcl_bridge::run_loop();
```

seq 自动从启动用的 PCIe sequencer 取得 `env_cfg`，无需另外传 context 或逐项传地址。
多个 Host 仍由同一个配置 seq 顺序处理；每笔 Memory 请求根据实际 BAR 目标选择
`cfg.rc_sequencers[target.rc_slot]`，不把所有 Host 都发到启动用的那个 RC。
`cfg.vio_setups[h]` 保存导出的队列，`config_seq.selection` 可用于测试结束后的释放。

## cfg、env、seq 各放什么

| 文件 | 内容 |
| --- | --- |
| `project_env_cfg.sv` | 参数、表布局、Function/队列策略，以及 env 生成的 BAR、BDF、队列视图和 sequencer 句柄 |
| `project_env.sv` | 创建 DPU/PCIe/VIO，绑定内存和 Intel 接口，将资源填入 cfg |
| `project_dut_config_seq.sv` | 配置顺序、每项 `user_configure_*` hook、32-bit 写表和 PCIe Memory 访问 |
| `project_base_test.sv` | 构建 cfg/env，等待平台就绪，启动配置 seq，成功后运行测试 |

按单个配置 seq 的正常顺序运行，不维护跨 seq 的并发锁、写版本、重写撤销或恢复状态机。
地址范围、字段合法性和 PCIe 返回结果仍会检查；配置成功后才确认 VIO 并允许业务发包。
`cfg.records` 是按硬件项整理的配置数据，供 hook/使能复用，不是另一套执行状态机。

从旧参考代码迁移时，调用位置对应如下：

| 原调用 | 现在的位置 |
| --- | --- |
| `env.configure_*()` / `env.write_*()` / `env.pcie_bar_*()` | 配置 seq 内的同名 task |
| `env.prepare_vio_configuration()` / `env.commit_vio_configuration()` | `cfg` 的同名方法，默认 seq body 已调用 |
| `env.release_vio_resources()` | `cfg.release_vio_resources()`，平台收尾时调用 |
| `env.dpu_setup` / `env.bar_registry` / `env.vio_setups` | `cfg` 中的同名字段 |


## 当前一对 VTX 的可执行配置

如果先用写死的单队列基线调通真实 DUT，启动独立的
[project_single_queue_config_seq](project_single_queue_config_seq.sv)。它在 seq 内固定
BDF、Notify、QSCH、VTX 的驱动地址与策略，不要求 `table_layouts/frozen_layouts` 已提供；
`dpu.driver_layouts=0` 也可使用。原 `project_dut_config_seq` 保持原来的平台布局要求。

这一入口固定只配置 Host0/PF0、一对队列中的 VTX：Packed、深度256、Polling，
不启用 VRX、不写 MSI-X/BAR/PFVF 公共表、不做普通表项读回；AF状态读仍执行。
顺序为 AF→BDF→Notify→QSCH→VTX初始化→VTX使能，共24笔32bit Memory Write、1笔AF状态 Memory Read。
表地址和策略覆盖 cfg 中的相应输入/冻结值；BAR基址、global qid、ring IOVA仍取环境实际分配值。
后续改硬件地址或固定字段，直接修改新 seq 的 `prepare_fixed_configuration()`。

Host/PF/队列模式已在 env 构建时形成合同，seq 不在运行期重建它们。仿真启动前提供：

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=0
+vio.enabled=1 +vio.pairs=1 +vio.tx_enable=1 +vio.rx_enable=0
+vio.queue_type=VQ_PACKED +vio.queue_size=256 +vio.features=0x0000000500000000
+vio.completion_mode=VIRTIO_COMPLETION_POLLING
+vio.notify_bar=0 +vio.notify_base=0 +vio.notify_stride=0 +vio.notify_encoding=VIO_NOTIFY_DPU32
```

PF0 EP 路由沿用环境默认 `requester=0/intel_pf=0/no-VF/vport=0`；新 seq 校验真实资源后才写寄存器。
EP requester 编码独立于环境分配的 PCI BDF，`dpu.bdf_first=16` 等起点无需改成0。
Notify查找表使用PF0的实际BAR0，`net_id/group_id/cos=0`、VNET、SP=`0xff`、TC weight=`0x11111111`
均由新 seq 固定，无需再提供 Notify table 或 QSCH 参数。接口 bind、等待复位仍由平台完成。

```systemverilog
// 放在 test 的 run_phase 中：平台复位就绪后，启动独立固定配置入口。
project_single_queue_config_seq	config_seq;

config_seq = project_single_queue_config_seq::type_id::create("config_seq");
config_seq.start(cfg.rc_sequencers[cfg.tl_slot_by_host[0]]);
```

已有 AIP 命令可只替换注册的 sequence 类型，沿用原来绑定的 RC sequencer 表达式。
例如原工程已有 `virtual_sqr::pcie_rc_sqr` 指向真实 RC 时：

```systemverilog
`aip_cmd_user_seq(dut_config_fixed, project_single_queue_config_seq, virtual_sqr::pcie_rc_sqr)
```

```tcl
dut_config_fixed
```

自建 package 时在 `project_dut_config_seq.sv` 后 include 新 `.sv`；参考 `project_env_pkg.sv`
已包含它。配置成功后再启动发包；实际发送失败继续报告 fatal，不会把错误当作配置成功。

以下为原通用 `project_dut_config_seq` 的参数化用法：

启动参数在 `cfg.load_params()` 时读取；Host/PF/队列/布局参数应在仿真启动前提供。
默认先声明 Host0/PF0 为 AF，再配置 BDF 和 VIO/QSCH，其他公共表不下发；采用驱动参考地址、QSCH VNET 模式，
SP/WRR=`0xff`、TC weight=`0x11111111`。
单 Host PF0/no-VF 的软件接口约定为 `intel_pf=0, intel_vf=-1, requester=0, vport=0`。
若 DUT 的 Intel sideband/Requester 约定不同，使用 `dpu.h0.pf0.requester/intel_pf/intel_vf/vport` 覆盖。
启动配置 seq 后会按这些身份写 BDF 表；BAR 映射表仍不自动下发。

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=0
+dpu.configure_public=0 +dpu.configure_bdf=1 +dpu.driver_layouts=1 +dpu.verify_readback=0
+dpu.reg_target=h0.pf0.bar0 +dpu.print_bar_map=1
+vio.enabled=1 +vio.pairs=1 +vio.tx_enable=1 +vio.rx_enable=0
+vio.queue_type=VQ_PACKED +vio.queue_size=256
+vio.features=0x0000000500000000
+vio.completion_mode=VIRTIO_COMPLETION_POLLING
+vio.notify_bar=0 +vio.notify_base=0 +vio.notify_stride=0
+vio.notify_encoding=VIO_NOTIFY_DPU32
+vio.notify_table_bar=0 +vio.notify_table_offset=0 +vio.notify_net_pair5=1
+dpu.qsch.net_base=0 +dpu.qsch.net_stride=1 +dpu.qsch.group_id=0
+dpu.qsch.cos=0 +dpu.qsch.eth_ports=8 +dpu.qsch.ets=0
```

QSCH 控制参数可显式修改为 `dpu.qsch.mode`（0=VNET、1=ETS）、`mode_offset`（默认 `0xb001c0`）、
`spwrr`、`tc_weight`；`configure_controls=0` 关闭自动模式写入及缺省 SP/WRR、TC weight 生成，
显式 `platform_controls` 仍会执行。`mode` 必须与所选 service 的 `qsch.ets` 一致。

cfg 的 `use_driver_reference_layouts()` 只补缺少的 VIO/QSCH 布局，保留已有 `provided` 布局。
需要改地址时，在 `cfg.load_params()` 后、env 构建前修改 `cfg.table_layouts[kind]`。
`dpu.driver_layouts=0` 则完全由平台提供布局。默认布局包含 BDF、MSI-X 和 VIO/QSCH，
其余公共表布局仍由平台声明。

日常测试默认 `dpu.verify_readback=0`：保留完整写表、使能、参数检查和写请求结果检查，
省去 BDF、所选 MSI-X、QSCH 模式、VIO/QSCH 有效表项及 MSI-X 查找表无效尾部的配置读回。
调试时使用 `+dpu.verify_readback=1` 恢复上述验证，也启用公共配置已选时的平台验证 hook。
关闭读回后的 READY 表示配置写入流程完成；DUT 实际应用结果由业务检查确认。
显式调用 `verify_function_configuration()`、`verify_vio_configuration()` 或
`verify_dpu_configuration()` 仍执行验证，不受此开关跳过。

BDF 默认每个 Function 配置一项，地址为管理 BAR.base + `0x108000 + bdf_index*4`。
PF0 默认 index=0、requester=0、valid=1，对应32位值 `0x00010000`。
新生成的 Function policy 默认 `bdf_index=vport`，可用 `dpu.h0.pf0.bdf_index` 等精确路径覆盖。
若平台已配置 BDF，设置 `dpu.configure_bdf=0`；不影响 VIO/QSCH 下发。

改为 MSI-X 模式时，在上面参数基础上增加以下示例；消息地址/data 应替换为项目实际约定，
它们是 Host 侧中断目的，不是 DUT BAR 物理地址：

```text
+vio.completion_mode=VIRTIO_COMPLETION_MSIX
+dpu.msix.msg_addr_base=0x900000000000
+dpu.msix.msg_addr_stride=4
+dpu.msix.msg_data_base=0x13572468
+dpu.msix.msg_data_stride=0x100
```

默认初始化 MSI-X linear（`0x0c0000`）、message（`0x120000`）、interval（`0x140000`）、
info（`0x150000`）四张表。interval=0、self_mask=0、table_only_enable=1；
真实平台需要额外 Function/control 寄存器时，显式提供控制项并关闭 table_only_enable。
消息地址/data 未提供时在第一笔配置写之前失败。普通轮询用例不写 MSI-X；
显式公共配置仍可包含 AF 等非 VIO 消息。

MSI-X linear 按 `{host_id, pfvf_id, local_vector}` 排序，global vector 仅作为映射结果；
完整流程初始化2048行单 bank，无效尾项的有效字段全1、reserved=0，不写 bank-select/ready。
`cfg.msix_linear_records` 可查看实际行号，统一管理窗口可由 `dpu.msix_linear.reg_target` 覆盖。

Notify 依照上传驱动 `af_mng.c:1632–1734` 排序：

```text
Function 查找 key = (host_id << 61) | (notify_base_address & 0x1fffffffffffff80)
先按 key 升序，再按 Function 内 pair 编号升序
Notify 表行号 = 排序后的位置 0..N-1
表项 global_qid = DPU 实际分配的 global qpair，不因排序而改变
配置写地址 = 管理 BAR.base + 0x0a0000 + 表行号 * 16
```

`cfg.notify_records` 可查看排序后的行、owner、BAR 匹配基址和 global qid。RX/TX 共用一条 pair 项。
Notify 只写实际有效项：同 PF 开32对队列就写32项，TX/RX共用每对的一项；开启读回也只验证这些有效项。
首次配置前，DUT 必须已按 `05.png` 复位：未用项 type=3、lookup key/global_qid 全1、reserved=0。
表容量仍为512行单 bank；环境不访问未用槽位，也不发送 bank-select/ready。
独立调用 `configure_vio_notify(selection,...)` 只写选中有效项，使用已发布行号，不重排其他 scope。
Notify 全局单 bank 必须使用统一管理窗口；参考布局的短目标默认选 Host0。
可显式设置 `vio.notify_table.reg_target=h0.pf0.bar0`，其他表仍可按各自 Host 访问。

## 按实际启用功能补充的输入

| 输入 | 当前使用条件 |
| --- | --- |
| `function_policies[Function名]` | 默认各 Host PF0/no-VF 已有软件路由；其他 PF/VF 显式给 requester、Intel PF/VF、vport。公共表索引仍按实际硬件提供 |
| `validate_pfvf_relationship()`、BAR 分组 | PFVF/MSI-X linear 校验 Function 关系，PF0/no-VF 已有默认规则；其他家族由平台提供。BAR 分组只在执行 BAR 配置时需要 |
| `table_layouts[kind]` | BDF/MSI-X/VIO/QSCH 已有驱动参考值；其他公共表及项目特有控制项自行声明 |
| `msix_policies` / `message_templates` | MSI-X 模式需要真实消息地址/data，参考 interval/self-mask/使能策略已有默认值，可显式覆盖 |
| `vio_policies[service名]` | 上述参数生成 VTX/QSCH/Notify 策略；启用 VRX 时还需实际 descriptor 预取 RAM 布局 |
| `user_configure_bar_mapping_entry` / `user_verify_dpu_configuration` | 启用公共配置时实现 BAR 编码；公共验证仅在同时开启读回时调用 |
| `user_verify_vio_configuration` | 开启读回时读取 Notify/QSCH/队列参数表并比较，项目特殊寄存器语义可覆写 |

公共 topology/routes/layout/messages 在 connect 时从 cfg 输入生成。
`dpu.print_bar_map=1` 打印实际 Host/Function/BDF/BAR base/size/end/RC slot；
用户不需要把打印的物理地址抄回代码。ring IOVA 在 `prepare_vio_configuration()` 后生成，
`item.binding`、`item.entry` 包含对应 qid、ring、Packed/Custom mode、depth、vector 等数据。

以下是**显式选择上传驱动地址的 VTX 布局示例**，不能据此认定最终 RTL 地址一致。
`0x880000` 是 BAR 内模块偏移，`0x10000` 是图片的参数表相对偏移，
data/control 是模块内共享端口偏移。表宽16B，每次4B；notify 仅单 bank。

```systemverilog
// cfg load 后、env 创建前填写；真实项目逐字段替换为其平台声明。
project_table_layout_t	vtx_layout;
vtx_layout = '{
	provided:1, reg_target:"h0.pf0.bar0",
	access_host_provided:1, access_host:0, access_uses_owner_host:0,
	module_offset:64'h0088_0000, table_offset:64'h10000,
	capacity:2048, entry_bytes:16, index_policy:PROJECT_INDEX_GLOBAL_QPAIR,
	indirect:1, data_port:64'h134, control_port:64'h130,
	index_mask:32'h000007ff, control_fixed:0, trigger_mask:32'h00002000,
	index_shift:0, required:1
};
cfg.table_layouts[PROJECT_VTX] = vtx_layout;
```

下面展示基类已有的 VTX 单项写法；只有需要改变平台访问时序时才在自己的 seq 中覆写。
它使用 cfg 中的实际布局，不负责外围循环。

```systemverilog
// 类内声明：传入绑定来自冻结 setup；失败原样返回给配置流程。
extern virtual task user_configure_vtx_queue(
	input project_vtx_cfg_t	item, output bit	ok, output string	why);

// 类外定义：检查身份/IOVA/深度/mode/vector 后按声明端口序列化发送。
// posted 成功只表明发送完成；调试时可开启后续读回。
task my_dut_config_seq::user_configure_vtx_queue(
	input project_vtx_cfg_t	item, output bit	ok, output string	why);
	write_vtx(item, ok, why);
endtask
```

同一个 VF32 TX+RX 只实现一次 VTX/VRX hook，配置 seq 各调用32次；TX-only 不调用 VRX。
队列 owner、local pair/qid 和 global qpair 来自 `item.binding`，不能自行移位换算。
Notify 表行排序与 DWORD 写序分别处理。所有 checked 表项都按高 DWORD→低 DWORD写，
每次32 bit；VTX/VRX 顺序执行四笔 data→control-clear→control-trigger，共六笔。
驱动队列代码实际使用低到高的 `wr32_for_each`；这里明确按用户要求采用高位先写。
PBA/stat 没有初始化写；drop 清除使用独立显式 W1C mask API。

## 如何复用 PCIe 发起真实配置

发送链：`project_dut_config_seq.user_configure_vtx_queue(item)` → `write_vtx()` →
`checked_write()` → `pcie_tl_reg_seq` → `cfg.rc_sequencers[target.rc_slot]` → Intel bind → DUT。
BAR 物理地址从 `cfg.bar_registry` 解析；用户只设置 BAR 内寄存器偏移。

平台特有寄存器也放在配置 seq 的 task 中，例如：

```systemverilog
// 放在你的配置 seq task 内；替换为真实寄存器偏移和位域值。
logic [127:0]	readback;
bit					ok;
string				why;

pcie_bar_write_by_name("h0.pf0.bar0", 'h40, 4, 128'h1234, 0, ok, why);
if (!ok) return;
pcie_bar_read_by_name("h0.pf0.bar0", 'h40, 4, 0, readback, ok, why);
if (!ok) return;
```

`pcie_table_write_by_name(name, offset, length, data, ok, why)` 支持4/8/12/16B，
从最高 DWORD 向最低 DWORD，每次4B；失败立即停止，不自动 trigger/readback。
`pcie_bar_write*` 保留整宽及 byte skip-mask 语义。`dpu.verify_readback=1` 时默认验证执行实际读回；
覆写验证 hook 时按真实寄存器语义检查。posted 发送完成只表示请求已发出。

## Tcl reg_acc 使用 PF0 BAR0 偏移

[project_pcie_reg_seq](project_pcie_reg_seq.sv) 继承 `pcie_tl_reg_seq`，沿用 `is_write/addr/len/mask/wdata/rdata`
接口；这里 `addr` 是 **Host0/PF0 BAR0 内偏移**。实际地址由环境已分配的 BAR0.base 加偏移得到，
随后使用对应 Host 的原生 PCIe RC 发 Memory 请求，不启动 DUT 配置 seq。

把已有 `reg_acc` 注册中的类型换成新类，第四参数返回错误，第五参数映射逐次读比较开关。以下沿用工程已有的真实 RC 句柄：

```systemverilog
`aip_cmd_reg(reg_acc, project_pcie_reg_seq, virtual_sqr::pcie_rc_sqr, seq.error_msg, seq.check_read_data)
```

环境已经向 PCIe sequencer 发布 `env_cfg`，因此 Tcl 只需传偏移和值：

```tcl
reg_acc write 0x1010 4 0x5555aaaa
reg_acc read 0x1010 check_read_data=0  ;# AF状态寄存器返回8，不与magic写值比较
reg_acc op=write addr=0x3000 len=16 data=0x112233445566778899aabbccddeeff00
reg_acc op=read addr=0x3000 len=16
```

其中 `0x1010` 写对应 `h0.pf0.bar0.base+0x1010`；日志 `PROJECT_REG_ACC` 会打印实际
`base + offset = address`。`0x3000` 仅展示宽访问格式，使用时替换为 DUT 实际寄存器偏移。
`len` 支持4/8/12/16字节，默认4；`mask` 默认0，bit i为1表示跳过第i字节，稀疏mask沿用原生拆分逻辑。
范围或读写失败通过 `status/error_msg` 返回，第四参数使 Tcl 的 `aip_check_status` 非零。
posted写成功表示发送完成；是否读回由用户后续命令决定。
Tcl `reg_acc read` 返回原始读值，不自动判断是否等于8；自动配置seq的AF同步读才执行这个状态校验。
`check_read_data` 每条命令默认1，仅接受0/1；设置0只关闭本次读取的SCB历史RAM写值比较，
不关闭tag/长度/Completion状态/超时检查。下一条省略此参数自动恢复1。
旧三/四参数注册仍可编译；未映射第五参数时显式传此选项会在启动前报错。
所有寄存器请求固定TC0、attr=0（关闭RO/IDO），保证posted写与后续状态读遵循顺序。

也可在 SV 中显式传入已有 cfg；不赋值时自动从启动 sequencer 的 `env_cfg` 获取：

```systemverilog
project_pcie_reg_seq	access;

access = project_pcie_reg_seq::type_id::create("access");
access.cfg      = cfg;
access.is_write = 1;
access.addr     = 'h1010;
access.len      = 4;
access.wdata    = 'h5555aaaa;
access.start(cfg.rc_sequencers[cfg.tl_slot_by_host[0]]);
```

`access.addr` 执行后仍是偏移，重复启动同一对象不会再次累加 BAR 基址；`issued_tlps` 保存本次实际请求。
新文件在参考 `project_env_pkg.sv` 中位于 `project_env_cfg.sv` 后，复制到自己的 package 时保持该顺序。

## BAR 目标与32对队列

默认访问目标 `pf0.bar0` 指管理窗口；配置 VF3 的 VTX 表项仍以 PF0 sideband 发出。
显式访问 VF3 BAR 则用它的真实租约与 VF3 sideband。BAR ID 是真实偶数硬件 BAR
编号，不是 role 或数组下标；64位 BAR 的奇数高 DWORD不能单独访问。

```systemverilog
// 路径只选访问窗口；以下offset/data也是示例，不代表任何已验证RTL寄存器。
pcie_bar_write_by_name("h0.pf0.bar0", 'h40, 4, 128'h1234, 0, ok, why);
pcie_bar_write_by_name("h0.pf0.vf3.bar2", 'h40, 4, 128'h1234, 0, ok, why);
```

`pcie_bar_read_by_name` 返回128位数据和 `ok/why`；支持4/8/12/16B，mask 的1表示
跳过该字节，稀疏 mask 会拆成连续 Memory TLP 区间。posted 写不会自动读回；
读 Completion 错误向上传递。多 Host 短目标需显式 `access_host_provided` 或
`access_uses_owner_host`；手动 by-name 多 Host 访问必须写 `hH`，不静默回退。

单 VF32 的业务参数（布局/身份/MSI-X/notify 仍由平台提供）：

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=1
+vio.enabled=0 +vio.h0.pf0.vf0.i0.enabled=1
+vio.h0.pf0.vf0.i0.pairs=32 +vio.queue_size=512 +vio.queue_type=VQ_PACKED
+vio.completion_mode=VIRTIO_COMPLETION_POLLING
```

两个 VF 各16对则设 `dpu.vfs_per_pf=2`，分别使能两个精确 service 并各设 `pairs=16`。
AF PF0 的额外11对计入每 Function 上限，不能把32普通对直接放在默认 AF。
`vio.enabled` 只控制服务与队列需求，不删除公共 Function/BAR。完整参数和 legacy
边界见 [参数表](../../docs/aip_parameters.md#项目外部配置参数)。

```tcl
set_param path=vio.target value=h0.pf0.vf0.i0
vio_start
set_param path=vio.tx.len value=512
vio_tx count=10
# RX需要项目网络侧真实送包，vio_wait_rx只等待。
set_param path=vio.rx.expected value=10
set_param path=vio.rx.timeout_ns value=50000
vio_wait_rx
vio_stop
end_test
```

MSI-X 模式必须收到注册地址与完整 data 的真实消息后才处理完成，不能用 polling
兜底。共享 vector 的每条队列分别领取 pending；self-mask 的硬件重新使能由用户
平台流程负责。

## 实际组件与接收路径

```text
my_env extends uvm_env
  dpu_env : dpu_device_env
    vio_hH : virtio_net_env       每Host一个，构建时读取父DPU已冻结快照
  pcie_env : pcie_tl_env
    rc_agents[slot]               project_pcie_rc_driver factory override
    rc_adapter_slot              Intel HARD_IP，无主动EP
```

同一个 Host manager 交给 VIO 和 RC。项目 RC 根据冻结 wire Requester 映射选择
Host/Function IOMMU，完整权限预检后临时用原 IOVA proxy 调用父 RC responder；
保留原 wire Requester/Tag/Completion lower-address 和 Intel PF/VF sideband。
公共 MSI-X catalog 可在无 VIO 时独立 sink。RC RX monitor 提供 DMA/MSI-X 观察，
RC driver `tx_ap` 提供实际发出的 doorbell 观察。**不要再挂第二个 Host responder**。
完整 factory override、bridge、route API 均已在模型的真实 Intel 引脚路径验证；
用户 RTL 基址、端口语义与线侧收发仍需平台验收。

`tl_slot_by_host[h]` 默认 `h→h`，load 后/build 前可交换，例如
`cfg.tl_slot_by_host[0]=1; cfg.tl_slot_by_host[1]=0;`。VIF/cfg 始终按物理 slot 填写，
映射必须完整且一一对应。不同 Host 可有相同 BDF/数值 BAR 地址，访问域仍独立。

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
