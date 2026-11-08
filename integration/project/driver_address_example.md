# 按上传驱动填写 DUT 配置地址

本文件是可移植到已有 `env_cfg` / 配置 seq 的参考代码，不加入任何 filelist 或 package。
参考 `prj1_v2_dpu_kernel_eth_driver.tar.gz`，SHA-256 为
`97d8422424354c53c8ca7155a1b769e35b120c1d7a77d2be0faed642eb407ac7`。
字段仍采用图片版 `project_*_entry_t`；这里补充地址和写法，不切换成驱动的另一版位域。

**你只需调整寄存器偏移，不需要填写 PF/VF 的 BAR 物理地址。**

单 Host/PF0、一对 Packed VTX 的固定联调入口见
[project_single_queue_config_seq.sv](project_single_queue_config_seq.sv)。该 seq 自带 BDF/Notify/QSCH/VTX
地址和策略，覆盖对应的输入/冻结布局；实际 BAR/ring 地址仍从环境获取。
原 `project_dut_config_seq` 继续使用下文的平台布局机制。

```text
访问 DUT 的地址 = registry 查询到的 h0.pf0.bar0.base + 寄存器偏移
BAR 映射表的内容 = item.members 中环境已分配的 base / size / limit
VTX/VRX 的 ring 地址 = prepare 导出的 item.entry.desc_addr / dsc_addr
```

下面先用你当前的一个 Host、PF0 管理窗口。表项属于 VF 时，仍由 PF0 管理窗口写全局表。
多 Host 的管理窗口和表索引要按实际 RTL 选择；驱动 PFVF 索引为 `host*16+pf`，
当前图片版 helper 使用所选窗口内的 `intel_pf`，不能把这两套规则混为一谈。
`dpu.print_bar_map=1` 会打印环境实际分配的地址；不要把打印值抄回代码固定下来。

## 驱动地址对照

以下均为 BAR0 内偏移。`i` 是对应表的硬件索引，不一定是 local qid 或数组循环下标。
驱动依据为 `register.h`，RDMA 两项另见 `rdma_register.h`。

| 表或端口 | BAR 内地址 | 每项字节 | 索引来源 / 说明 |
| --- | --- | ---: | --- |
| AF 声明 | Host0 PF0 BAR0 `0x1010` | 4 | 默认 seq 首笔写 `32'h5555_aaaa`，随后单次读要求状态8；独立于可选 `PROJECT_AF` 表 |
| PFVF map | `0x088000 + i*4` | 4 | 驱动 `host*16+pf`；本例 Host0 |
| BDF map | `0x108000 + i*4` | 4 | Function 对应的全局表索引 |
| Completion BDF | `0x098000 + i*4` | 4 | 驱动用 srcid；当前由 `completion_index` 显式声明 |
| TLP prefix | `0x118000 + i*8` | 8 | `prefix_index`；不从 BDF 或 qid 猜测 |
| VIO notify lookup | `0x0a0000 + i*16` | 16 | 当前单 bank；i 是按 Host/BAR/pair 排序后的行号，global_qid 存在表项中 |
| MSI-X linear | `0x0c0000 + i*8` | 8 | 单 bank；i为Host/PFVF/local-vector排序行号，global-vector存在表项中 |
| MSI-X message table | `0x120000 + i*16` | 16 | 管理窗口全局 vector；与 Function 本地 BAR4 窗口区分 |
| MSI-X interval | `0x140000 + i*4` | 4 | 全局 vector |
| MSI-X info | `0x150000 + i*4` | 4 | 全局 vector |
| MSI-X PBA | `0x110000` 起 | 按已确认读宽 | 只读；图片与驱动容量不一致，不在这里推断容量 |
| RDMA notify lookup | `0x08c000 + i*8` | 8 | 可选，当前单 bank；字段地址来自实际 VF BAR 租约 |
| QSCH Q2TC | `0xb10000 + i*4` | 4 | 全局 qpair |
| QSCH N2G | `0xb12000 + i*4` | 4 | net_id |
| QSCH G2P | `0xb14000 + i*4` | 4 | group_id |
| QSCH RNET | `0xb15000 + i*4` | 4 | 可选 RDMA VF 索引 |
| QSCH SP/WRR | `0xb16000 + i*4` | 4 | net_id，每 TC 一个选择位 |
| QSCH TC weight | `0xb18000 + i*4` | 4 | net_id，8 个 4-bit weight |
| VTX 间接 control | `0x880130` | 4 | index `[10:0]`，selector bit12=0，trigger bit13 |
| VTX 间接 data | `0x880134` 起 | 16 | 四个 DWORD 共用端口，不加 `qid*16` |
| VTX 参数表读回 | `0x890000 + qpair*16` | 16 | 写入走间接端口，读回走此窗口 |
| VRX 间接 control | `0x900200` | 4 | index `[15:0]`，wr_en 高16位写1，即 bit16 |
| VRX 间接 data | `0x900204` 起 | 16 | 四个 DWORD 共用端口，不加 `qid*16` |
| VRX 参数表读回 | `0x910000 + qpair*16` | 16 | 同上 |
| MSI-X mask/rearm | 对应 Function 的 `bar0+0x1004` | 4 | bit0 mask，`[13:1]` global vector；独立运行期操作 |

BAR 映射地址来自 `register.h:292` 起；下面的 base/limit 是**寄存器地址**，不是你要手填的 BAR 地址。

| BAR 对 | PF base / limit | VF group base / limit / size-code |
| --- | --- | --- |
| BAR0/1 | `0x090000 / 0x091000` | `0x092000 / 0x092c00 / 0x093800` |
| BAR2/3 | `0x090400 / 0x091400` | `0x092400 / 0x093000 / 0x093a00` |
| BAR4/5 | `0x090800 / 0x091800` | `0x092800 / 0x093400 / 0x093c00` |

base/limit 表每项8B，size-code 每项4B。归档中找到了这些寄存器定义，未找到其实际写入调用；
因此下文的 BAR 示例把硬件 index 和 VF size-code 显式传入，limit 暂按包含式末地址。
这三项应对照最终 RTL 确认；BAR base/size 本身始终由环境提供。

## cfg：集中填写偏移

`project_env_cfg::load_params()` 默认调用已有 `use_driver_reference_layouts()`，
补齐 BDF/MSI-X/Notify/QSCH/VTX/VRX 地址。显式 `provided` 布局优先，关闭默认地址可设置
`+dpu.driver_layouts=0`。修改现有地址只需在 env 构建前修改 `cfg.table_layouts`，
无需复制这些方法或手填 BAR 物理地址。

当前默认先写 AF magic，再单次读同址并要求状态8，然后独立下发 BDF；MSI-X 按完成模式选择。
其后每100次完整DWORD配置写再读一次AF状态；无轮询、无尾部补读，不执行额外Host-ID协商。
AF读写不受 `dpu.configure_public`、`dpu.driver_layouts` 或 `dpu.verify_readback` 控制。
基类已在 `declare_af()` 中实现以下完整步骤；使用默认 body 时不要再调用一遍：

```systemverilog
// 已复用真实BAR和RC：magic写→等待同址4B读Completion→验证8；任一步失败立即停止。
declare_af(ok, why);
```

以下其余公共地址仅在需要时添加；可在已有 cfg 中增加
这个可选方法；它复用源码已有 `set_driver_layout()`，仍需提供真实身份、BAR 分组及公共验证。
这里 capacity 是参考上限，最终按 DUT 规格调整。

<!-- cfg-declarations -->
```systemverilog
// 仅公共表模式需要；在 load_params 后、env 创建前由平台显式调用。
extern function void use_public_driver_reference_layouts();
```

<!-- cfg-implementations -->
```systemverilog
// 补充公共硬件表地址；不下发配置，不设置 BAR 分组或猜测 PFVF 身份编码。
function void project_env_cfg::use_public_driver_reference_layouts();
	set_driver_layout(PROJECT_PFVF, 'h080000, 'h08000, 4, 4, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_COMPLETION_BDF, 'h080000, 'h18000, 4, 4096, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_PREFIX, 'h100000, 'h18000, 8, 256, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_RDMA_NOTIFY, 'h080000, 'h0c000, 8, 256, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_RNET, 'hb00000, 'h15000, 4, 256, PROJECT_INDEX_EXPLICIT);
	table_layouts[PROJECT_RDMA_NOTIFY].required = 0;
	table_layouts[PROJECT_RNET].required        = 0;
endfunction
```

若使用默认管理窗口全局 MSI-X message table，应将相应 `msix_policies[name].table_present`
设为0，让环境使用 `table_layouts[PROJECT_MSIX_TABLE]`。`table_present=1` 会优先选择
Function 自己的 BAR/本地 vector 布局。Host MSI-X 消息目的地址来自 message policy，
它是 Host 地址，与这里的 DUT BAR 地址不同。

## 配置 seq：各类别使用同一份 cfg 生成的 item

下列 typed 写法已由 `project_dut_config_seq` 基类实现；沿用这些写法时直接启动基类即可。
若平台需要覆写单项时序，在 `my_dut_config_seq extends project_dut_config_seq` 中使用相应 `extern virtual task` 声明和以下实现。只改地址时修改 cfg 布局即可。
`item.entry` 包含冻结的 Function/ring/vector 关联，字段策略应在 prepare 前填写。

<!-- seq-typed-implementations -->
```systemverilog
// BDF 表：保留冻结 requester/owner 关联；4B 单次写，失败返回给外围批次。
task my_dut_config_seq::user_configure_bdf_entry(
	input project_bdf_cfg_t	item, output bit	ok, output string	why);
	write_bdf(item, ok, why);
endtask

// Completion BDF：按平台已声明索引发送，不能把 PF/VF 编号直接当 srcid。
task my_dut_config_seq::user_configure_completion_bdf_entry(
	input project_completion_bdf_cfg_t	item, output bit	ok, output string	why);
	write_completion_bdf(item, ok, why);
endtask

// PFVF：完整 PF family 已由环境校验；只写本次传入的一项。
task my_dut_config_seq::user_configure_pf_vf_entry(
	input project_pfvf_cfg_t	item, output bit	ok, output string	why);
	write_pfvf(item, ok, why);
endtask

// Prefix：8B 按高 DWORD、低 DWORD 两次发送，保留 byte order。
task my_dut_config_seq::user_configure_tlp_prefix_entry(
	input project_tlp_prefix_cfg_t	item, output bit	ok, output string	why);
	write_tlp_prefix(item, ok, why);
endtask

// MSI-X linear：单 bank 单项写；不搬移其他条目或切换 bank。
task my_dut_config_seq::user_configure_msix_linear_entry(
	input project_msix_linear_cfg_t	item, output bit	ok, output string	why);
	write_msix_linear(item, ok, why);
endtask

// MSI-X info：Function/Host/global-vector 来自同一冻结配置。
task my_dut_config_seq::user_configure_msix_info_entry(
	input project_msix_info_cfg_t	item, output bit	ok, output string	why);
	write_msix_info(item, ok, why);
endtask

// MSI-X interval：rate/packet 策略来自 cfg，错误不会伪装成成功。
task my_dut_config_seq::user_configure_msix_interval_entry(
	input project_msix_interval_cfg_t	item, output bit	ok, output string	why);
	write_msix_interval(item, ok, why);
endtask

// MSI-X message：16B 四次 DWORD 写；Host 消息地址/data 不由 DUT BAR 推算。
task my_dut_config_seq::user_configure_msix_table_entry(
	input project_msix_table_cfg_t	item, output bit	ok, output string	why);
	write_msix_table(item, ok, why);
endtask

// QSCH 三层映射各自遍历、共享项去重；用户不需要重复循环所有队列。
task my_dut_config_seq::user_configure_qsch_q2tc(
	input project_qsch_q2tc_cfg_t	item, output bit	ok, output string	why);
	write_qsch_q2tc(item, ok, why);
endtask

// N2G：索引来自 net_id，不能用 global qpair 代替。
task my_dut_config_seq::user_configure_qsch_n2g(
	input project_qsch_n2g_cfg_t	item, output bit	ok, output string	why);
	write_qsch_n2g(item, ok, why);
endtask

// G2P：Host 目的端口按实际 ETH 数量生成，不沿用驱动固定加8。
task my_dut_config_seq::user_configure_qsch_g2p(
	input project_qsch_g2p_cfg_t	item, output bit	ok, output string	why);
	write_qsch_g2p(item, ok, why);
endtask

// VTX：依次发送四笔高到低 data，再发 clear/trigger，任一笔失败立即停止。
task my_dut_config_seq::user_configure_vtx_queue(
	input project_vtx_cfg_t	item, output bit	ok, output string	why);
	write_vtx(item, ok, why);
endtask

// VRX：与 VTX 同样的六笔流程，使用独立 VRX 端口及触发位。
task my_dut_config_seq::user_configure_vrx_queue(
	input project_vrx_cfg_t	item, output bit	ok, output string	why);
	write_vrx(item, ok, why);
endtask

// Notify lookup：item 中 BAR base 已由环境关联，不需要用户填写物理地址。
task my_dut_config_seq::user_configure_vio_notify_entry(
	input project_vio_notify_cfg_t	item, output bit	ok, output string	why);
	write_vio_notify(item, ok, why);
endtask

// 可选 RDMA notify：只使用显式 catalog，不自动开始 RDMA 业务。
task my_dut_config_seq::user_configure_rdma_notify_entry(
	input project_rdma_notify_cfg_t	item, output bit	ok, output string	why);
	write_rdma_notify(item, ok, why);
endtask

// 可选 RNET：依赖的 Host/owner 和完整消费者由环境保留。
task my_dut_config_seq::user_configure_qsch_rnet_entry(
	input project_qsch_rnet_cfg_t	item, output bit	ok, output string	why);
	write_qsch_rnet(item, ok, why);
endtask

// SP/WRR：发送用户显式登记的 raw/mask，失败原样返回给配置流程。
task my_dut_config_seq::user_configure_qsch_spwrr(
	input project_control_cfg_t	item, output bit	ok, output string	why);
	write_control(item, ok, why);
endtask

// TC weight：同样通过受检查的控制项入口；不能把软件成功当作硬件读回。
task my_dut_config_seq::user_configure_qsch_tc_weight(
	input project_control_cfg_t	item, output bit	ok, output string	why);
	write_control(item, ok, why);
endtask

// 单独使能：仅允许改变冻结时声明的 enable 位，不绕过依赖就绪检查。
task my_dut_config_seq::user_enable_queue(
	input project_queue_control_cfg_t	item, output bit	ok, output string	why);
	write_enabled_queue(item, ok, why);
endtask
```

上述 posted 写成功仅表示发送完成。`dpu.verify_readback=1` 时，`user_verify_vio_configuration()`
读回 Notify 有效项、QSCH、VTX/VRX 参数表；默认0时跳过这些配置读回。
公共 `user_verify_dpu_configuration()` 仍由平台实现，在同时开启公共配置与读回时调用。
独立 BDF/MSI-X 的内建读回由 `verify_function_configuration()` 完成，不依赖公共验证 hook；
MSI-X linear 无效尾部也只在开启读回时检查。
VTX/VRX 读回位置为 `item.ctx.byte_offset`，与 data staging 端口分别处理。

## Notify 表项排序

驱动 `af_mng.c:1632–1640` 取表项低64位并清除低7位作为 Function 查找 key；
`:1676–1685` 按 `host_id` 和 Notify 基址的组合升序插入，`:1717–1734` 在组内按 pair 编号填入。
`global_qid` 只作为查找结果写入表项，不能用它直接计算 Notify 表行号。
当前 cfg 按同一规则生成 `notify_records`，排序后行号为 `0..N-1`，RX/TX 共用一行。
seq 仅写实际队列对的有效项，开启读回也仅访问这些项；同 PF 32对队列对应32行，TX/RX共用一行。
首次配置前，DUT 须已按 `05.png` 复位为无效项：type=3，Host/base/local/global qid域全1，reserved=0。
未用项保留复位值；图片版本仍为512行单 bank，不执行双 bank 切换或 ready 寄存器写入。

MSI-X linear 同样按查找键排列：驱动 `af_mng.c:1068–1191` 使用
`(host_id<<19)|(pfvf_id<<9)` 确定 Function 顺序，再按 local vector 递增。
`cfg.msix_linear_records` 保存完整排序目录；global vector仅保留为映射结果。
参考流程在选择 MSI-X 时初始化2048行单 bank，空行有效字段全1、reserved=0。

## VTX/VRX 的六次写入

驱动 `common.h:1493` 的 `wr32_for_each` 从低地址写向高地址；
`af_mng.c:2999` 和 `:3058` 配置队列使用这个宏。驱动另有
`wr32_for_high_order`，notify/MSI-X linear 等表使用它。
**本环境按你要求统一高 DWORD→低 DWORD，因此队列数据写序与该驱动不同。**
每个 DWORD 内仍按 PCIe little-endian，不倒置字节。

以全局 qpair=5、128-bit 表项 `entry` 为例，实际地址由 registry 自动加 BAR base：

| 次序 | VTX 偏移 / 数据 | VRX 偏移 / 数据 |
| ---: | --- | --- |
| 1 | `0x880140 ← entry[127:96]` | `0x900210 ← entry[127:96]` |
| 2 | `0x88013c ← entry[95:64]` | `0x90020c ← entry[95:64]` |
| 3 | `0x880138 ← entry[63:32]` | `0x900208 ← entry[63:32]` |
| 4 | `0x880134 ← entry[31:0]` | `0x900204 ← entry[31:0]` |
| 5 | `0x880130 ← 0x00000005` | `0x900200 ← 0x00000005` |
| 6 | `0x880130 ← 0x00002005` | `0x900200 ← 0x00010005` |

第五次是保留 index、清 trigger；第六次才提交。不能每写一个 DWORD 就触发一次。
VTX `wr_ram_content[6]` 还可服务其他表，但本次 queue parameter entry 仅16B，只写四个 DWORD。

## BAR 映射：从环境取得数据再写表

PF 使用一个 Function 的一个 BAR 租约作为一组；VF 使用同一 Host/PF 下同一个 BAR ID 的
**完整 VF 集合**作为一组。使用 `cfg.bar_group_policies` 声明逻辑成员，发布时环境自动
解析租约。VF 窗口不能用 `bar_mapping_per_lease=1` 逐 VF 重写同一条 family 窗口。

例如一个 PF、两个 VF 的 BAR0 分组只需要身份，没有物理地址：

```systemverilog
// cfg.load_params 和 Function 策略填好后、env 创建前。
// 同样为实际存在的 BAR2、BAR4 建组；其他 PF/Host 按其真实 Function 列表生成。
project_bar_group_policy_t	pf_group;
project_bar_group_policy_t	vf_group;

pf_group.name      = "h0.pf0.bar0";
pf_group.functions = '{'{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0}};
pf_group.bar_ids   = '{0};

vf_group.name      = "h0.pf0.vfs.bar0";
vf_group.functions = '{
	'{host_id:0, pf_id:0, kind:DPU_FUNCTION_VF, vf_id:0},
	'{host_id:0, pf_id:0, kind:DPU_FUNCTION_VF, vf_id:1}
};
vf_group.bar_ids = '{0, 0};

cfg.bar_mapping_per_lease = 0;
cfg.bar_group_policies.push_back(pf_group);
cfg.bar_group_policies.push_back(vf_group);
```

下列 task 放在配置 seq 中，从 `item.members` 计算实际 base/limit。只支持能由一个窗口表达的
连续、等长 VF BAR；若随机分配结果不满足，明确返回失败。此时应调整 DPU 的 BAR placement
约束，或按实际硬件增加可表达的窗口，不能把中间空洞也映射成该 PF 的 VF。

`hw_index` 是 BAR 硬件表的行号，不是环境的 `item.ctx.table_index`；后者只是软件组编号。
VF 的 `vf_size_code` 是硬件 SIZE 寄存器编码，归档未给出写入实现，故没有擅自选用
`size`、`size-1` 或 `log2(size)`。你只需按 DUT 的编码规则从租约 size 计算该值，
无需提供 BAR base。PF 不使用这个输入。

<!-- seq-bar-declarations -->
```systemverilog
// 类内声明；仅从 user_configure_bar_mapping_entry 调用，配置 seq 负责外围遍历和错误处理。
extern task write_driver_bar_window(
	input project_bar_mapping_cfg_t	item,
	input int unsigned				hw_index,
	input bit						vf_size_code_valid,
	input logic [31:0]				vf_size_code,
	output bit						ok,
	output string					why
);
```

<!-- seq-bar-implementations -->
```systemverilog
// 按驱动寄存器位置写 base/包含式 limit/可选 VF size-code；所有物理地址取真实租约。
// 第一笔前验证完整成员集合、连续性和所有寄存器范围；失败不继续发送后续字段。
// 管理访问仍走 PF0 BAR0；hw_index/limit 语义和 VF size-code 由最终 RTL 规格确认。
task my_dut_config_seq::write_driver_bar_window(
	input project_bar_mapping_cfg_t	item,
	input int unsigned				hw_index,
	input bit						vf_size_code_valid,
	input logic [31:0]				vf_size_code,
	output bit						ok,
	output string					why
);
	project_bar_target_t			members[$];
	project_bar_target_t			access;
	project_function_record_t	functions[$];
	dpu_function_key_t			first;
	logic [63:0]				base_offset;
	logic [63:0]				limit_offset;
	logic [63:0]				size_offset;
	bit [63:0]					base;
	bit [63:0]					last;
	bit [63:0]					span;
	bit [63:0]					address;
	int unsigned				bar_pair;
	int unsigned				family_count;
	bit							vf;

	ok  = 0;
	why = "BAR group is empty, has no registry, or index exceeds the register window";

	if (item.members.size() == 0 || cfg.bar_registry == null || cfg.dpu_setup == null || hw_index >= 128) begin
		return;
	end

	members = item.members;
	members.sort() with (item.function_key.vf_id);
	first    = members[0].function_key;
	vf       = first.kind == DPU_FUNCTION_VF;
	bar_pair = members[0].bar_lease.even_bar_id / 2;
	base     = members[0].bar_lease.base;
	span     = members[0].bar_lease.size;
	last     = base;

	if ((!vf && members.size() != 1) ||
		(vf && (!vf_size_code_valid || $isunknown(vf_size_code)))) begin
		why = "PF group needs one lease; VF group needs an explicit hardware size-code";
		return;
	end

	foreach (members[m]) begin
		if (!cfg.bar_registry.check_range(members[m], 0, members[m].bar_lease.size, address, why)) begin
			return;
		end

		if (members[m].function_key.host_id != first.host_id ||
			members[m].function_key.pf_id != first.pf_id ||
			members[m].function_key.kind != first.kind ||
			members[m].bar_lease.even_bar_id != members[0].bar_lease.even_bar_id ||
			members[m].bar_lease.size != span ||
			(vf && (members[m].function_key.vf_id != m || address != base + 64'(m) * span))) begin
			why = "BAR window needs one family/BAR and equal contiguous leases in VF0..VF(N-1) order";
			return;
		end

		last = address + span - 1;
	end

	// 不能让用户误把完整 family 的一部分当成整个窗口。
	if (vf) begin
		family_count = 0;
		cfg.dpu_setup.list_functions(functions);

		foreach (functions[f]) begin
			if (functions[f].key.host_id == first.host_id && functions[f].key.pf_id == first.pf_id &&
				functions[f].key.kind == DPU_FUNCTION_VF) begin
				family_count++;
			end
		end

		if (family_count != members.size()) begin
			why = "VF BAR window omits actual Function members";
			return;
		end
	end

	// 以下是后续按 RTL 修改的寄存器偏移；右侧 base/last/span 从未由用户手填。
	base_offset  = (vf ? 64'h092000 : 64'h090000) + bar_pair * 'h400 + hw_index * 8;
	limit_offset = (vf ? 64'h092c00 : 64'h091000) + bar_pair * 'h400 + hw_index * 8;
	size_offset  = 64'h093800 + bar_pair * 'h200 + hw_index * 4;

	if (!cfg.bar_registry.resolve_name("h0.pf0.bar0", access, why)) begin
		return;
	end

	if (!cfg.bar_registry.check_range(access, base_offset, 8, address, why) ||
		!cfg.bar_registry.check_range(access, limit_offset, 8, address, why)) begin
		return;
	end

	if (vf && !cfg.bar_registry.check_range(access, size_offset, 4, address, why)) begin
		return;
	end

	pcie_table_write_by_name("h0.pf0.bar0", base_offset, 8, 128'(base), ok, why);
	if (!ok) return;

	pcie_table_write_by_name("h0.pf0.bar0", limit_offset, 8, 128'(last), ok, why);
	if (!ok) return;

	if (vf) begin
		pcie_table_write_by_name("h0.pf0.bar0", size_offset, 4, 128'(vf_size_code), ok, why);
	end
endtask
```

例如 Host0/PF0 的 PF BAR 组，若 RTL 确认其硬件行号为0，用户 BAR hook 中直接调用：

```systemverilog
// item 由 configure_bar_table() 传入；不需要先查询或填写 PF0 的物理 BAR base。
write_driver_bar_window(item, 0, 0, '0, ok, why);
```

VF 组调用同一 task，传入对应 family 硬件行号和已确认的 size-code。
它不猜测 VF size 编码，也不会因未找到编码而跳过该项后返回成功。

## QSCH 可选项和其他显式控制

SP/WRR、TC weight 默认按实际 net_id 自动生成，值由 `dpu.qsch.spwrr/tc_weight` 指定；
QSCH 模式由 `dpu.qsch.mode/mode_offset` 控制，默认 0/0xb001c0。
需要逐项覆盖时，在 `cfg.platform_controls` 中登记 value/mask 和完整消费者，显式项优先。
下面展示 cfg 中已有 service 的一项登记；
共享同一 net_id 时应合并其全部 service 到 `consumers`，不能只写其中一个消费者。

```systemverilog
// 示例 service 身份必须已存在于本次拓扑；net_id 与该 service 的 vio_policies 一致。
project_control_cfg_t	control;
dpu_service_key_t		service;

service.function_key        = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_VF, vf_id:0};
service.service_kind        = DPU_SERVICE_VIO_NET;
service.service_instance_id = 0;

control.ctx.kind        = PROJECT_SPWRR;
control.ctx.table_index = cfg.vio_policies[dpu_service_key_name(service)].net_base;
control.owner           = service.function_key;
control.consumers       = '{service};
control.consumers_complete = 1;
control.value           = 128'hff;       // TC0..7 使用 SP。
control.writable_mask   = 128'hff;
cfg.platform_controls.push_back(control);

control.ctx.kind        = PROJECT_TC_WEIGHT;
control.value           = 128'h1111_1111; // 每 TC weight=1，按实际调度策略修改。
control.writable_mask   = 128'hffff_ffff;
cfg.platform_controls.push_back(control);
```

下面是用户主动控制的独立 Memory Write 示例。每次调用后均检查 `ok/why`，
不要把运行期 rearm 或队列 reset 混入普通表项循环。AF 声明已由默认 seq 执行，写法见前文。

```systemverilog
// QSCH 模式：默认 seq 已写入，读回由开关选择；下面仅展示平台独立控制时的写入。
pcie_bar_write_by_name("h0.pf0.bar0", 'hb001c0, 4, 128'h0, 0, ok, why);
if (!ok) `uvm_fatal("QSCH_MODE", why)

// MSI-X rearm：假定 global vector=7，bit0=0 表示解除 mask。
// 使用消息所属 Function 的 BAR0，registry 自动解析这个 VF 的实际 BAR 地址。
pcie_bar_write_by_name("h0.pf0.vf0.bar0", 'h1004, 4, 128'(7 << 1), 0, ok, why);
if (!ok) `uvm_fatal("MSIX_REARM", why)
```

PBA、MSI-X 统计是状态读取，不增加初始化写。PFVF drop 的清除地址在本归档中未核实，
继续使用你确认的图片/RTL 布局和独立 W1C mask；不填一个猜测地址。驱动中的 PP/转发/RDMA
业务表不属于当前 VIO 集成配置清单；需要这些表时仍可用 `pcie_table_write_by_name()` 写
4/8/12/16B 镜像，始终高 DWORD 先写。
