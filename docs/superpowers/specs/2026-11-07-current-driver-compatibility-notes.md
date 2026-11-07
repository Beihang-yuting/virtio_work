# 当前上传驱动与 VIO 外部配置的对照

来源：用户于 2026-11-07 上传的 `prj1_v2_dpu_kernel_eth_driver.tar.gz`。
SHA-256：`97d8422424354c53c8ca7155a1b769e35b120c1d7a77d2be0faed642eb407ac7`。
解包仅用于阅读，不执行驱动安装/构建脚本，不把整个驱动复制进 VIP 仓库。
下文行号对应此归档中的源码，不对应旧版 `icpu-kernel-driver f2c9cd6`。

用户已要求参考该驱动改进实现，尤其是自定义模式。本记录补充外部配置设计，
保留用户之前明确要求的标准 Packed `virtio_net_hdr`，不把驱动中名为 virtio 的
设备专用路径自动认作完整标准 virtio-net 驱动。

## 自定义数据面

| 对照项 | 当前驱动证据 | 实现要求 |
| --- | --- | --- |
| TX 数据描述符 | `txrx.h:171`，16B addr + 两个32位控制字 | 保留现有18位长度、跨字10位 dport_id、next/avail/used布局 |
| TX 内层校验 | `txrx.h:188`；`txrx.c:1409` | 增加 `i_l3_cs`、`i_l4_cs` 参数/复制/冻结/编码，分别位于第二控制字 bit24/25，即完整描述符 bit120/121 |
| TX 每包 data desc 上限 | `txrx.h:592`，8总项减1扩展项；`txrx.c:2983` | 普通发送最多7条 data desc，超过时明确失败；不在队列层假造 Linux skb linearize |
| 单项拆分 | `txrx.c:1672` | 64KiB 分段，剩余长度和地址逐项推进；现有做法保留 |
| 普通 RX desc | `txrx.h:268`；`txrx.c:1093` | 16B；addr/len/avail/used与现有实现相符 |
| RX CQ | `txrx.h:51` | 16B全部字段按下表导出；第二 DWORD 低16位不是 head_idx |
| TX CQ | `txrx.h:74`；`txrx.c:1974` | 2B head[14:0]/wrap[15]；完整包消费后回收，保留VIP的范围/所有权保护 |
| ring 几何 | `txrx.c:3059`、`:3149` | TX有效长度16N+2；RX32N；连续块按页对齐，CQ紧随descriptor；TX CQ初值0x8000，RX CQ清零，软件wrap初值1 |
| 可用槽数 | `txrx.h:610` | N-1，不能按N预投递导致满/空歧义 |
| 通知 | `txrx.h:637` | 32位 `{wrap,tail[14:0],local_qid[15:0]}`；使用写屏障后更新notify |
| local qid | `txrx.c:185`、`:259` | TX=2*pair+1，RX=2*pair；硬件global qpair仍取实际分配，不取qid>>1代替 |
| RX多buffer | `txrx.c:2600` | 驱动根据pkt_len消耗多个buffer；本轮已确认的普通单buffer路径需明确拒绝超buffer完成，不能声称已覆盖驱动全部RX能力 |

RX CQ 的新typed视图必须保持以下位宽；使用独立黄金字节检查，而不是用相同
SV struct 同时生成和解析期望值：

| DWORD | 位域（低位到高位） |
| --- | --- |
| DW0 | sport_type[2:0]，sport_id[12:3]，offload_vlan_vld[13]，vlan_tpid_type[15:14]，ptype[23:16]，profile[27:24]，desc_num[31:28] |
| DW1 | pkt_num[4:0]，reserved[5]，csum_check_status[7:6]，pkt_head_split_len[15:8]，pkt_len[29:16]，tnl_pkt_flag[30]，cq_wrapper[31] |
| DW2 | timestamp_index[11:0]，reserved[15:12]，hash_value[31:16] |
| DW3 | offload_ovlan[15:0]，vsid[27:16]，reserved[31:28] |

新增完整 CQ 查询，普通RX完成仍通过wrapper和包长推进；不能用DW1低16位作为
队列索引。旧 `decode_rx_cq` 的兼容入口若保留，应把最后输出明确命名为原始低16位，
注明其仅为旧调用兼容，内部使用typed解析。旧设备模型描述的是原驱动版本，
应明确版本；新版本测试不能用它生成的旧head_idx来充当新CQ黄金值。

驱动的TX清理宏对部分内层校验位给出2位mask，但 `dpu_tx_desc` 的实际成员是
两个1位字段，正常发送通过成员赋值。VIP数据描述符以该结构与发送语句为准；
不把清理宏的较宽覆盖范围解释成另一个线格式。

TSO/VLAN/1588等扩展描述符在该驱动中存在，属于独立数据格式。当前普通TX
不允许把dtype切成扩展格式却仍按普通addr/len打包。保留明确的能力检查。

## 配置表与访问顺序

该驱动补齐了一批此前截图缺少的**版本化参考**信息；项目实际布局仍由用户
cfg选择/声明，准备阶段不会因知道地址就自动写设备。

| 项目 | 驱动证据与值 | 对实现的影响 |
| --- | --- | --- |
| 模块基址 | `register.h:12`、`:62`、`:90`：VTX=0x880000，VRX=0x900000，QSCH=0xb00000 | 可提供此驱动版本的显式布局示例，不把它们当成BAR物理地址 |
| VTX间接写 | `register.h:2187`、`:2211`、`:2246`；`af_mng.c:3020` | 控制offset=VTX+0x130，数据=VTX+0x134；ram_addr11位，selector bit12，enable bit13；先数据，再enable0，再enable1，同端口串行 |
| VRX间接写 | `register.h:2380`；`af_mng.c:2930` | 控制=VRX+0x200，四个数据DWORD=VRX+0x204；addr低16位、wr_en高16位；先数据，再0→1使能 |
| 队列深度 | `af_mng.c:2983`、`:3044` | q_depth=ilog2(desc_num)，不把N或N-1直接写入4位域 |
| VRX预取 | `af_mng.c:2957` | 默认32槽，实际RAM分配按容量对齐并保存，不能每次局部配置都从0开始 |
| QSCH | `register.h:1884`..`:1995` | Q2TC/N2G/G2P=模块内0x10000/0x12000/0x14000；SPWRR=0x16000；TC weight=0x18000 |
| MSI-X self-mask重开 | `interrupt.c:296` | 通过Function窗口offset0x1004写mask_en bit0、global vector[13:1]；该运行期写由用户task控制 |
| MSI-X信息表 | `interrupt.c:396` | Function/Host/global vector来自真实资源；驱动显式开启self-mask，VIP不得自动代替用户重开 |
| notify局部编码 | `common.h:517`、`af_mng.c:1718` | net条目低7位=`{pair[5],pair[4:0],1'b1}`；不要与doorbell低16位RX/TX local qid混淆 |
| notify双bank | `register.h:185`、`:403`；`af_mng.c:1737` | 驱动明确有双bank，写完整目标bank并高DWORD先写，最后通过PCOMPLETER+0x44选择bank/ready；仅选择此版本布局时启用，截图版仍无隐式bank |
| BAR分配表 | `register.h:270`..`:386` | PF逐项、VF窗口组base/limit/size都有定义；需结合实际成员验证能否编码，不能仅按VF数量推算连续地址 |

版本差异不能合并为一个自称通用的线格式：

- 截图VTX bit72叫high_speed_mode，驱动成员仍叫inorder。当前普通初始化中该位为0；非零语义按所选RTL布局明确处理。
- 截图ASIC VRX的预取地址为15位、bit127保留；驱动C成员是16位。截图profile坚持15位和容量检查，不能因C字段较宽而允许越界。
- 驱动的notify具有显式bank/ready，而截图未说明；两种布局必须显式区分。
- 驱动的PBA结构仍是64个DWORD，不能单凭它推断完整硬件覆盖的向量数。

## Packed分支的边界

`txrx.c:1790` 的 `dpu_virtio_tx_map` 使用packed描述符，但直接映射skb数据，未在
该发送路径插入标准 `virtio_net_hdr`；整个归档也未发现该类型的使用。该路径还
经同一个DPU32 doorbell通知（`:1935`），没有标准PCI协商流程。

因此本次继续满足用户已明确的标准Packed报文要求。数据格式、通知格式、设备
配置所有权是三个独立选择：外部Packed默认仍按明确标准notify合约，允许平台
显式选择DPU32通知以匹配该设备接口，但不能据此省略virtio_net_hdr。Custom
仍无该header。完整复制驱动的非标准Packed发送行为不在当前已确认需求中。

## 补充验证

1. TX i_l3_cs/i_l4_cs逐位黄金字节、参数越界、逐队列覆盖与冻结复制。
2. RX CQ四个DWORD黄金向量、非零低16位metadata不被当作索引、128位长度与wrap校验。
3. 保留普通Custom 512B TX/RX、SG跨环、CQ初始值和N-1容量测试；unsupported完成不能提前回收。
4. 显式DPU32通知的Packed和Custom分别核对编码，同时检查Packed仍带标准header。
5. 参考间接端口写序、notify bank完整范围、MSI-X重开行为与截图profile隔离。
