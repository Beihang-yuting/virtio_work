# 用户提供的 VTX、VRX 与接口配置截图核对

日期：2026-11-07

来源：本机 `/home/ryan/Download/00.png`、`02.png`、`1.png`、`03.png`、`05.png`、`94.png`。
以下为直接查看原图及放大图后的字段记录，不表示已经修改源码或完成 RTL 验证。
图片未复制进仓库。模块名称、模块基址、部分旁注和完整间接访问寄存器未全部出现在截图中；
表中地址保留为图示地址，不直接当成 PCIe BAR 内的绝对偏移。

## 1. VTX：00.png

`queue_para_table`：图示地址 `0x0001_0000`，2048 项，每项 128 位。
访问方式为读直接寻址、写间接寻址。

| 位段 | 字段 | 图示含义 |
| --- | --- | --- |
| [127:112]、[111:106] | rsv2、rsv1 | RO 保留字段 |
| [105:96] | sport_id | from host/cpu 时为 vport_id[9:0] |
| [95:92] | dma_info | [3]=ro_en，[2]=th_en，[1:0]=ph_en |
| [91:79] | dma_msix | 13 位中断字段 |
| [78:76] | sport | 0..6 分别为 host0..host6，其余保留 |
| [75] | queue_stop | 1 暂停队列，初始为 0 |
| [74] | tail_buf_id_dis | 0 时需把尾描述符 buffer ID 写到首描述符位置；不能仅按名字猜极性 |
| [73] | redraw_en | 末报文描述符中间态回撤处理开关 |
| [72] | high_speed_mode | 1 高速模式，影响一次读 descriptor 数量和队列最小深度 |
| [71] | seg_en | 切片使能 |
| [70] | interl_seg_en | 交织切片使能 |
| [69] | virtio_mode | 1 Virtio，0 自定义 |
| [68] | queue_en | 队列使能 |
| [67:64] | q_depth | 5..15 对应 32..32K；高速模式为 7..15，对应 128..32K |
| [63:0] | desc_addr | descriptor ring 基址 |

高速模式下，截图说明 `descrd_num` 的编码 0..7 分别为 16、32、48、64、80、96、112、128。
非高速模式引用 `0x0000_0114 vtx_descrdnum_cfg`，但该寄存器完整定义未提供。
`virtio_mode=1` 只说明 Virtio/自定义选择，不能仅凭这一位断言 Packed 与 Split 的选择规则。

## 2. VRX：02.png + 1.png

`queue_para_table`：图示地址 `0x0001_0000`，ASIC 2048 项 / FPGA 512 项，每项 128 位。
访问方式为写间接寻址、读直接寻址。`02.png` 的低部与 `1.png` 的高部在 dsc_dma_num 处重叠。

| 位段 | 字段 | 图示含义 |
| --- | --- | --- |
| ASIC [126:112] / FPGA [125:112] | dsc_pre_read_ram_addr | 预取 descriptor RAM 的起始索引；不是 Host DMA 地址 |
| [127] | rsv | 保留；FPGA 未使用的 [126] 不能自行赋予意义 |
| [111:109] | dsc_pre_max_num | 0=256、1=128、2=64、3=32、4 或其他=16 个预取 descriptor |
| [108] | rsv | 保留 |
| [107:106] | dsc_pre_read_threshold | 预取触发水线编码，含义随预取容量变化 |
| [105:104] | dsc_dma_num | 一次 DMA 读取 descriptor 数量的编码 |
| [103:102] | dsc_mode | 自定义模式下 0 普通，1 head_split，其余保留 |
| [101:99] | payload_dsc_len | head_split 模式下 0=2K、1=4K、2=6K、3=8K，其余保留；旁注标明 20250930 之后代码 |
| [98:97] | head_dsc_len | head_split 模式下 0=256、1=512、2=1K、3=2K 字节 |
| [96] | dma_msix_en | 0 不上报中断，1 上报中断；由轮询/中断模式配置 |
| [95:83] | dma_msix | 13 位中断字段 |
| [82:73] | dport_id | 图中未给出与 PF/VF、global function ID 的完整换算规则 |
| [72:70] | dport | 0..3 分别为 host0..host3，其余保留 |
| [69] | virtio_mode | 1 Virtio，0 自定义 |
| [68] | queue_en | 队列使能 |
| [67:64] | q_depth | 5..15 对应 32..32K |
| [63:0] | dsc_addr | descriptor ring 基址 |

预取 RAM 为 ASIC 32K / FPGA 16K **descriptor 槽**，不能理解成字节容量。
同一 RAM 域内各队列区间不得重叠；起始索引按本队列实际预取容量对齐；
预取容量必须严格小于该队列 ring 深度。分配范围覆盖共享该硬件 RAM 的所有队列，
不能每个 Host 或每次局部配置都重新从零分配。

当预取容量为 256/128/64 时，watermark 编码对应：

| 编码 | 256 | 128 | 64 |
| --- | --- | --- | --- |
| 0 | 248 | 120 | 56 |
| 1 | 240 | 112 | 48 |
| 2 | 232 | 104 | 40 |
| 3 | 224 | 96 | 32 |

容量 32 时编码 0 为 24，其余为 16；容量 16 时编码 0 为 12，其余为 8。
容量为 256/128/64 时，`dsc_dma_num` 编码 0/1/2/3 对应一次读 32/24/16/8 个 descriptor；
容量为 32/16 时，截图分别说明默认一次读 16/8 个。

队列深度 512 的 `q_depth` 编码是 9。若 32 条 RX 各预留 256 个预取槽，总计占 8192 槽；
这只是给定配置的算例，仍需与同 RAM 域其他队列一起检查容量和重叠。
当前 VIP 自定义数据面尚不支持 head_split，不能因为表项有该字段就声称数据路径已支持。

## 3. 接口表：03.png

| 表 | 图示地址 | 深度 / 位宽 | 字段与行为 |
| --- | --- | --- | --- |
| bdf_map_table | 0x0000_8000 | 128 / 32 | [18] vdpa_en，[17] ecrc_en，[16] valid，[15:0] requester_id；直接访问 |
| pba_table | 0x0001_0000 | 16 / 64 | pending_bit_array，RO；表头与说明的总位数冲突，见下文 |
| prefx_map_table | 0x0001_8000 | 256 / 64 | [33] vdpa_en，[32] valid，[31:0] TLP_prefixes；其余保留 |
| msix_table | 0x0002_0000 | 1024 / 128 | [96] msix_mask，[95:64] msix_data，[63:0] msix_addr；[127:97] 保留 |
| msix_intrl_table | 0x0004_0000 | 1024 / 32 | [31:16] intrl_pnum，[15:0] intrl_rate；中断计数/间隔控制 |
| msix_stat_table | 0x0004_8000 | 1024 / 32 | [31:16] intrl_pnum_stat，[15:0] intrl_rate_timer，RO |
| msix_info_table | 0x0005_0000 | 1024 / 32 | [14] valid，[13] self_mask，[12:10] host_id，[9:0] function_id |

`bdf_map_table.requester_id` 根据对应 Host 的模式编码：

- EP：bit15 为 Vfunc_num_vld，bits14:4 为 Vfunc_num，bits3:0 为 Func_num/PF。
- SW：截图浅色说明为 bits15:0 BDF ID。

因此该表字段不能无条件填传统 BDF；`sv_if_mode=Intel` 只选择 VIP 的接口传输方式，
不能代替 DUT Host 的 EP/SW 配置。导出记录应分别保留逻辑 Function、PCIe BDF、
实际 requester_id 编码及 host 模式。

`msix_info_table.function_id` 的旁注称为全局 vport_id，并注明 [9:7] 保留、
[6:0] function_id。关联规则应由平台说明，不能直接把所有 10 位都作为自由 function ID。

PBA 表头的 16×64 等于 1024 bit，但旁注写共 8192 bit。截图不能消除这个冲突；
实际 PBA 长度和可用向量数量要由对应 RTL/完整规格确定，不能猜测或沿用最大值。

## 4. 接口表：05.png

| 表 | 图示地址 | 深度 / 位宽 | 字段与行为 |
| --- | --- | --- | --- |
| pfvf_map_table | 0x0000_8000 | 4 / 32 | [10:1] First_vf_offset，[0] Valid；按 PF 提供首个 VF Routing ID offset |
| pfvf_drop_status_table | 0x0000_A000 | 4 / 32 | pfvf_drop_status，W1C；状态查询和明确写一清除需分开 |
| rdma_notify_table | 0x0000_C000 | 256 / 64 | [58:51] vf_id，[50:48] host_id，[47:0] base_addr[60:13]；高位先写，低位最后写 |
| completion_bdf_table | 0x0001_8000 | 4096 / 32 | [17] ecrc_en，[16] valid，[15:0] completion_id；Host SW 模式下需配置 BDF ID |
| vio_notify_table | 0x0002_0000 | 512 / 128 | [76:75] type，[74:64] global_qid，[63:61] host_id，[60:7] base_addr，低 7 位 local qid 编码 |
| msix_linear_table | 0x0004_0000 | 2048 / 64 | [34:22] global_msix_idx，[21:19] Host_id，[18:9] Pfvf_id，[8:0] Local_msix_idx |

VIO notify 的 type 为 0 net / 1 ctrlq / 2 blk / 3 reserved。对 net：
bit6 取 Local_qid[6]，bits5:1 取 Local_qid[6:1] 所描述的队列对编码，bit0 固定 1。
截图对 bit6 与 bits5:1 的说明存在位数表述不一致：5 位目的域不可能保存 6 位
`Local_qid[6:1]`，不能据此静默截断。实际 32 对队列加 ctrlq 的编码需按完整规格核对。
导出时仍分别保留 local virtqueue ID、pair index 和最终表编码，不能将它们混为一项。

`vio_notify_table` 要从高 DWORD 开始配置，最后写 [31:0]；`msix_linear_table`
要先写 [63:32]，最后写 [31:0]。截图没有说明 notify 双 bank/commit 寄存器，
因此不得把旧驱动的 shadow-bank 提交流程当作这些新地址的既定操作。

`Pfvf_id` 的注释要求通过 `pfvf_map_table` 计算；仅有 PF/VF 数量不足以推导它，
还需真实 Routing ID 规则。`First_vf_offset` 应与父 PF 及对应 VF 的实际路由分配一致；
未显示的 VF stride 或编号换算不能自行假定为固定值。

MSI-X linear 的 Local_msix_idx 旁注明确 [8:6] 保留、[5:0] 每 Function 最多 64 个向量。
global_msix_idx 旁注又出现 Local_msix_idx 的文字，需以完整规范确认其确切意义。
这里记录可见位域，不把这段旁注推断为新的全局编号分配算法。

`03.png` 与 `05.png` 中地址重复，但没有相同模块基址的证据；不能把两图的
0x8000 或 0x20000 合并为同一张表。需要分别绑定实际接口模块及访问窗口。

## 5. QSCH：94.png

图中各表为直接寻址；未显示模块基址。VIO 调度关系为队列 → net/COS → group → port。

| 表 | 图示地址 | 深度 / 位宽 | 字段 |
| --- | --- | --- | --- |
| vn_q2tc_cfg_tbl | 0x0001_0000 | 1024 / 32 | [31] vld，[12:3] net_id，[2:0] COS；中间字段名合称 tcid[12:0] |
| n2g_cfg_tbl | 0x0001_2000 | 2048 / 32 | [31] vld，[9:0] grpid |
| g2p_cfg_tbl | 0x0001_4000 | 1024 / 32 | [31] vld，[19:16] dpt，[3:0] lvl2_id |
| rnet_cfg_tbl | 0x0001_5000 | 256 / 32 | [3:1] host_id，[0] en；RDMA VF 调度使能 |

Q2TC 的 net_id 为 10 位，VIO 使用前 1024 个 net。qid 表索引、net_id、group_id、
PF/VF/global function ID 分别导出并由平台绑定，不假定这些编号互相相等。
多个队列可以引用同一个 net/group：Q2TC 按队列写，N2G 按唯一 net 写，G2P 按唯一 group 写。

G2P `dpt` 在 8 ETH 的版本中，0..7 为 ETH，8..12 为 Host；截图特别说明，
实际 ETH 数量不足 8 时 Host 紧跟最后一个 ETH 编码。例：2 ETH + 2 Host，
ETH0/1 为 0/1，Host0/1 为 2/3。因此不能无条件使用 `8 + host_id`。

G2P `lvl2_id` 的解释依赖调度模式：

- VNET，区分业务：0..4 为 Host0..4 的 VIO，8..12 为 Host0..4 的 RDMA。
- VNET，不区分业务：0..4 为 Host0..4。
- ETS：低 3 位为优先级，bit3 必须为零。

旁注将 lvl2_id 的含义称为 spt；不另造一个独立的物理 spt 字段。
RDMA 的 rnet host_id 必须与对应 G2P 中的 Host 部分一致，且 en 生效后其 DB 才能进入调度器。
该图没有提供 SPWRR 和 TC weight 的新布局，不能拿旧偏移直接补进本版配置。

## 6. 与现有代码及接入设计的关系

| 核对项 | 现有源码 | 截图 |
| --- | --- | --- |
| VTX bit72 | `dpu_vio_pack_vtx_queue_para` 由 inorder 填入 | high_speed_mode |
| VTX 中断字段 | 11 位，检查最大 0x7ff，填总位 [89:79] | 13 位 [91:79] |
| VRX 表宽 | `dpu_vio_pack_vrx_queue_para` 输出 3 个 DWORD | 4 个 DWORD，含中断使能及预取控制 |
| VRX 中断字段 | 11 位，总位 [93:83] | 13 位 [95:83]，bit96 独立 enable |
| notify 配置 | 旧 plan 生成 shadow bank 和 commit | 此图为直接访问，并规定从高位到低位写入 |
| MSI-X linear | 旧 plan 按 source/local 推算地址，写 32 位 payload | 图示 64 位项内含 Host/Pfvf/local key 和 13 位结果 |
| BDF 表 payload | 旧 `dpu_vio_pack_bdf_entry` 仅写 BDF/valid | requester_id 依 EP/SW 模式变化，另有 ecrc/vdpa |
| QSCH net / group | 旧打包为 6 位 net、5 位 group | 10 位 net、10 位 group |
| QSCH G2P | 旧 source 1 位、destination 2 位 | lvl2_id 4 位、dpt 4 位，且编码与调度模式/端口数量相关 |
| QSCH 地址 | 旧 N2G=0x11000、G2P=0x12000、TC weight=0x14000 | 图中 N2G=0x12000、G2P=0x14000；不能混用 |

源码参照：`dpu_common/src/dpu_vio_dataplane_plan_extension.sv` 的
`dpu_vio_pack_vtx_queue_para` / `dpu_vio_pack_vrx_queue_para`，以及
`dpu_vio_reg_plan_types.sv`、`dpu_vio_register_plan_builder.sv`。
这些差异说明应使用明确的平台字段/访问布局，不能把旧编码器当作截图版本的完整实现。
旧平台回归继续按旧契约验证，不能全局替换含义而使两种布局混用。

项目配置仍按职责分开：PF/VF 路由、BAR、requester/completion BDF、MSI-X、TLP prefix
作为独立公共配置入口；VTX/VRX/notify 属于 VIO 入口；RDMA 表只预留独立输入/方法，
不因运行 VIO 自动配置或增加 RDMA 数据面。每类用户方法接收一个 cfg，环境在所选
范围内遍历。只读状态和 W1C 清除接口与常规初始化分开。

队列配置中分别导出 Function key、BDF、global function ID、平台 vport/Pfvf ID、
local/global qid、向量及实际 ring 地址。项目声明必要的转换关系后统一校验，
不靠两个字段数值刚好相等来建立身份关联。

## 7. 按表定义结构体的设计示例

以下为截图布局的拟用类型，尚未加入源码。所有成员从硬件高位向低位排列，
保留位显式占位；完整 VRX 类型、外层 cfg 和调用合同见
[集成设计第 4.5 节](2026-11-07-vio-external-device-configuration-design.md#45-按表定义-packed-entry按项传递普通-cfg)。
类型名只对应本文这版截图；后续不兼容布局使用独立类型/适配器，不能悄悄
改变同名成员的位义。表地址、索引、访问端口不属于 packed entry。

### 7.1 VTX 和 VIO notify

```systemverilog
// VTX：128 位写入镜像；bit72 按截图命名，不沿用旧版 inorder。
// sport_id 和 dma_msix 由平台映射生成，不能用窄位域赋值来掩盖越界。
typedef struct packed {
    logic [15:0]	reserved_127_112;
    logic [5:0]	reserved_111_106;
    logic [9:0]	sport_id;
    logic [3:0]	dma_info;
    logic [12:0]	dma_msix;
    logic [2:0]	sport;
    logic		queue_stop;
    logic		tail_buf_id_dis;
    logic		redraw_en;
    logic		high_speed_mode;
    logic		seg_en;
    logic		interl_seg_en;
    logic		virtio_mode;
    logic		queue_en;
    logic [3:0]	q_depth;
    logic [63:0]	desc_addr;
} project_vtx_entry_t;

// VIO notify：128 位镜像；base_addr 字段存放原始地址 [60:7]，不是完整字节地址。
// 低 7 位只保留已知物理范围。图中的局部 qid 编码冲突须由完整规格消除后才能生成。
// 本表没有图示 valid 位，也没有由此结构体推导出的 shadow-bank 提交机制。
typedef struct packed {
    logic [50:0]	reserved_127_77;
    logic [1:0]	notify_type;
    logic [10:0]	global_qid;
    logic [2:0]	host_id;
    logic [53:0]	base_addr_60_7;
    logic [6:0]	local_qid_encoding;
} project_vio_notify_entry_t;
```

### 7.2 公共身份与中断表

```systemverilog
// Requester 表：16 位 requester_id 根据 Host EP/SW 模式编码。
typedef struct packed {
    logic [12:0]	reserved_31_19;
    logic		vdpa_en;
    logic		ecrc_en;
    logic		valid;
    logic [15:0]	requester_id;
} project_bdf_entry_t;

// EP 模式下 requester_id 的子编码；SW 模式直接使用对应 PCIe BDF。
typedef struct packed {
    logic		vf_valid;
    logic [10:0]	vf_num;
    logic [3:0]	pf_num;
} project_ep_requester_id_t;

// Completion BDF 使用独立表和访问目标，不能复用 requester 表的地址。
typedef struct packed {
    logic [13:0]	reserved_31_18;
    logic		ecrc_en;
    logic		valid;
    logic [15:0]	completion_id;
} project_completion_bdf_entry_t;

// PFVF 路由表：offset 与实际父 PF/VF Routing ID 一致，不从 VF 数量猜测。
typedef struct packed {
    logic [20:0]	reserved_31_11;
    logic [9:0]	first_vf_offset;
    logic		valid;
} project_pfvf_entry_t;

// TLP prefix 是独立可选项，只在所选 Host/Function 需要时配置。
typedef struct packed {
    logic [29:0]	reserved_63_34;
    logic		vdpa_en;
    logic		valid;
    logic [31:0]	tlp_prefix;
} project_tlp_prefix_entry_t;

// MSI-X linear：包含完整查找 key 与结果，按高 DWORD、低 DWORD 顺序写入。
// 图注要求 local_msix_idx[8:6] 为零；global 字段语义仍需完整规格确认。
typedef struct packed {
    logic [28:0]	reserved_63_35;
    logic [12:0]	global_msix_idx;
    logic [2:0]	host_id;
    logic [9:0]	pfvf_id;
    logic [8:0]	local_msix_idx;
} project_msix_linear_entry_t;

// MSI-X info：按图保留 10 位字段范围，图注要求 function_id[9:7] 为零。
// 其 vport/Function 映射与 DPU global function ID 分别保存并校验。
typedef struct packed {
    logic [16:0]	reserved_31_15;
    logic		valid;
    logic		self_mask;
    logic [2:0]	host_id;
    logic [9:0]	function_id;
} project_msix_info_entry_t;

// 中断节流策略，计数和时间单位仍按对应硬件规格解释。
typedef struct packed {
    logic [15:0]	intrl_pnum;
    logic [15:0]	intrl_rate;
} project_msix_interval_entry_t;

// MSI-X 消息表：Address 是发往 Host 的目的地址，不是表本身的 BAR 地址。
// 修改时由用户 task 遵守 mask、消息写入、最终 mask/enable 的顺序。
typedef struct packed {
    logic [30:0]	reserved_127_97;
    logic		msix_mask;
    logic [31:0]	msix_data;
    logic [63:0]	msix_addr;
} project_msix_table_entry_t;
```

### 7.3 QSCH 和显式选择的 RDMA 表

```systemverilog
// Q2TC：每个实际 qid 表项；net_id/COS 联合对应图中的 tcid[12:0]。
typedef struct packed {
    logic		valid;
    logic [17:0]	reserved_30_13;
    logic [9:0]	net_id;
    logic [2:0]	cos;
} project_qsch_q2tc_entry_t;

// N2G：多个队列共享 net 时只配置同一个 net 项，不重复分配 group。
typedef struct packed {
    logic		valid;
    logic [20:0]	reserved_30_10;
    logic [9:0]	group_id;
} project_qsch_n2g_entry_t;

// G2P：端口编码和 lvl2_id 由实际端口数、VNET/ETS 模式决定。
typedef struct packed {
    logic		valid;
    logic [10:0]	reserved_30_20;
    logic [3:0]	dpt;
    logic [11:0]	reserved_15_4;
    logic [3:0]	lvl2_id;
} project_qsch_g2p_entry_t;

// RNET 只供独立 RDMA 配置，VIO 配置入口不生成此表项。
typedef struct packed {
    logic [27:0]	reserved_31_4;
    logic [2:0]	host_id;
    logic		enable;
} project_qsch_rnet_entry_t;

// RDMA notify：base 字段存原地址 [60:13]；先写高 DWORD，最后低 DWORD。
// 此类型只表达截图位域，不代表本次实现 RDMA 数据路径。
typedef struct packed {
    logic [4:0]	reserved_63_59;
    logic [7:0]	vf_id;
    logic [2:0]	host_id;
    logic [47:0]	base_addr_60_13;
} project_rdma_notify_entry_t;
```

### 7.4 只读和 W1C 类型

```systemverilog
// PBA 单个 64 位读取字；总字数不能从存在此类型推导，需先消除图文冲突。
typedef struct packed {
    logic [63:0]	pending;
} project_msix_pba_word_t;

// 中断运行状态只读；不能作为 interval 配置项回写。
typedef struct packed {
    logic [15:0]	intrl_pnum_stat;
    logic [15:0]	intrl_rate_timer;
} project_msix_stat_t;

// Drop 状态与明确清除的 mask 使用不同类型，便于区分读结果和清除意图。
// 截图未给出 32 位内部事件划分，先保留整个向量，不编造子字段名称。
typedef struct packed {
    logic [31:0]	status;
} project_pfvf_drop_status_t;

typedef struct packed {
    logic [31:0]	clear_mask;
} project_pfvf_drop_clear_t;
```

普通初始化不能接收状态类型；PBA/stat 通过读取接口返回，drop 清除通过独立用户
task 接收 clear mask。SV packed struct 可以发生隐式位转换，不能仅靠类型名
保证访问安全，环境调度还需检查表类别、访问权限和操作类型。

### 7.5 赋值与调用边界

用户可以在所属 env_cfg 中按字段设置策略模板；每项生成时先 `entry = '0`，
填策略，再由实际快照/ring 绑定填地址与身份，并进行统一校验。模板中的保留位
必须为零；窄域赋值之前检查原整数值，之后检查未知态和资源一致性。
已冻结 cfg 的副本只供用户配置 task 消费，不作为修改 VIP 分配的反向入口。

每种外层 cfg 都组合 `ctx + 该表所需关联记录 + entry`。例如 VRX 的关联记录
是 `binding`，BDF 是 Function 与 EP/SW 编码依据，MSI-X 是向量与消费者集合，
QSCH 是队列/net/group 的映射。一个用户 task 接收一个这种 cfg，环境按实际
scope 生成并遍历；32 对队列分别得到 32 份 VTX 和 32 份 VRX cfg。

用户不需要重新拼位移，也不需要把所有表塞进同一个 task。`packed` 仅使字段
对应硬件比特；VTX/VRX 间接端口、VIO notify/MSI-X linear 以及显式选择的
RDMA notify 高位先写、posted 写后
的生效确认仍由对应 task 明确实现。未知 BAR 表布局继续使用逻辑 BAR lease，
在完整位定义提供前不生成可发送的 packed payload。
