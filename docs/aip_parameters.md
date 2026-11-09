# AIP 参数与 Tcl sequence 接入

参数加载定义在原配置类的 `load_params()` 中，公开路径使用 `dpu.*`、`vio.*` 与 `pcie_cfg.*`。
`load_params()` 执行读取和赋值；它不是 Tcl 参数到 SV 字段的持续绑定。
构造函数、复制和普通 `get` 不会重新读取全局参数。

本页同时保留普通标准驱动和项目外部配置入口。普通入口可执行 init/reset/MQ/RSS；
[项目外部配置](#项目外部配置参数)只注册 start/tx/wait_rx/stop，设备配置由 typed hook 承担。

## 编译与文件定位

可选完整编译入口为 `filelists/aip_integration.f`，顺序是 AIP、DPU、
net_packet/host_mem/PCIe、Virtio，最后是 `integration/aip/virtio_aip_pkg.sv`。
使用 AIP update 的 `src/sv/aip_core_pkg.sv`，同一个 package 只编译一次。
这里沿用 net_packet 的 `AIP_CMDLINE_SV` 可见性约定：在同一编译调用中先编译
AIP，后编译各配置类。不要手工预定义这个 include guard 再编译 AIP 自身。
不启用 AIP 时，低层配置类不读取命令行；组合入口仍根据默认值创建拓扑。

### `virtio_aip_pkg.sv` 找不到 `get_all_trailers_length`

TX 长度校验使用的正确表达式是：

```systemverilog
packet_handle.pkt.get_all_headers_length() +
packet_handle.pkt.get_all_trailers_length()
```

成员叫 `pkt`，方法叫 `get_all_trailers_length`。`packet_item.pkt` 的类型是
`net_packet_pkg::packet`，定义来自外部 `net_packet/src/core/packet.sv`，不是
Intel adapter 或 `pcie_cfg`。本地检查通过的版本为 `net_packet/main@b8a4c14`，
该方法由 `4dc2e08` 随 RoCEv2 ICRC 尾部支持引入。此前版本没有该 API。

在报错工程的实际构建环境中检查：

```bash
printf '%s\n' "$NET_PACKET_ROOT"
git -C "$NET_PACKET_ROOT" log -1 --oneline
rg -n 'get_all_trailers_length' "$NET_PACKET_ROOT/src/core/packet.sv"
rg -n 'get_trailer_length' "$NET_PACKET_ROOT/src/protocols/protocol_base.sv"
rg -n 'net_packet_pkg\.sv|core/packet\.sv' compile.log
```

找不到方法时，应同步包含上述提交的**完整 net_packet checkout**。有本地修改时
先保留修改；干净 checkout 可用 `git fetch origin main`、`git switch main`、
`git merge --ff-only origin/main` 更新。当前远程维护分支是 main；早期文档和
依赖脚本要求 master，现已同步更正，并在 bootstrap/check-deps 增加 trailer API 诊断。

若文件中有方法而 VCS 仍报找不到，检查日志是否实际编译了另一份路径、旧的 package
库，或 include 搜索路径先命中旧文件；用新的构建输出目录重新编译
`net_packet_pkg` 及依赖它的 VIO/AIP package。同一构建只编译一份 package 入口，
不同时混入旧 `net_packet/filelist.f`、旧 `packet_item.sv` 或预编译包。

不要将 trailer 长度改成 0，或仅复制一个空方法：RoCEv2 的 ICRC 位于 payload 后，
长度和打包语义必须与 `protocol_base`、`rocev2_header`、`packet::do_pack()` 一起更新。

| 参数所属文件 | 加载入口与内容 |
| --- | --- |
| `virtio_net_vip/src/env/virtio_net_env_config.sv` | `load_params` 加载 Host 默认；`load_driver_params` 定义驱动短名映射；`load_service_params` 应用精确 service 覆盖 |
| `virtio_net_vip/src/shared/virtio_wait_policy.sv` | `load_params` 加载 `vio.wait.*`；env 在 build 时复制到实际使用的 wait policy |
| `virtio_net_vip/src/dpu_priv/dpu_priv_driver_config.sv` | 私有 Function 与单队列各自 `load_params` |
| 外部 `dpu_common/src/dpu_device_cfg.sv` | Host/domain/MMIO/function/BAR/AF 等原类加载；不根据数量创建拓扑 |
| 外部 `dpu_common/src/dpu_placement_cfg.sv` | 资源池、候选过滤与 placement request 加载 |
| 外部 `dpu_common/src/dpu_env_cfg.sv` | 默认拓扑、公共布局/MSI-X、VIO/QSCH 硬件策略；接收核心 VIO 已缓存的 service 需求 |
| 外部 `dpu_common/src/dpu_vio_qsch_topology.sv` | 独立 QSCH topology generator 加载；不自动执行 DUT 配置 |
| 外部 `dpu_common/src/dpu_dut_caps.sv` | 可选能力上限加载 |
| 外部 `pcie_work/pcie_tl_vip/src/env/pcie_tl_env_config.sv` | 原配置类 `load_params("pcie_cfg")` 加载实际 TL 组件消费的行为策略，字段名保持不变 |
| `examples/virtio_system_env/virtio_system_env_example_test.sv` | `author_param_config` 创建拓扑，`virtio_system_env_config.load_params` 设置内存创建策略 |
| `integration/aip/virtio_aip_pkg.sv` | 每次命令创建的新 sequence 加载运行参数；动态命令类负责结果返回 |
| `examples/aip/virtio_aip_driver_test.sv` | `register_aip_commands` 集中绑定已集成 env 和注册 Tcl 命令 |

参数宏把变量名作为公开字段名，所以原类使用局部短名再赋给现有字段。
例如 `queue_size` 映射到 `default_queue_size`；不会要求用例写 `vio.default_queue_size`。
宏及显式读取调用携带源文件和行号，便于定位错误。

## 构建前参数

| 路径 | 缺省值/语义 |
| --- | --- |
| `vio.pairs` | 初始活动队列对数，默认 1；不增加 DPU 分配的资源 |
| `vio.queue_size` | 默认 256；0 表示设备最大值，其余要求 2..32768 的 2 的幂；实际还受设备/私有协议限制 |
| `vio.queue_type` | `VQ_SPLIT`，亦可选择实际支持的队列格式 |
| `vio.features` | 64 位 driver feature 掩码；默认全 1，最终仍需设备协商 |
| `vio.napi_budget` / `vio.rx_refill` | 默认 64 / 16，正整数 |
| `vio.rx_buf_size` | 标准 RX 单个 buffer 的报文容量，**不含 `virtio_net_hdr`**；环境按最终特性加头。未设置时保留原有总容量，当前 external Packed 默认 1526B |
| `vio.exec_mode` | `VIRTIO_EXEC_MODEL` 或 `VIRTIO_EXEC_REAL_DUT` |
| `vio.completion_mode` | `VIRTIO_COMPLETION_MSIX` 或 `VIRTIO_COMPLETION_POLLING` |
| `vio.scb` / `vio.coverage` | 默认 1 / 0，属于 Host env，不能按 VF 创建另一份验证组件 |
| `vio.iova_base` / `vio.iova_size` | 设备可见地址范围，4KiB 对齐、非零且 base+size 不溢出；与 GPA/MMIO 独立 |
| `vio.iova_policy` / `vio.iommu_strict` | 默认 `IOMMU_IOVA_RANDOM` / 1 |
| `vio.wait.poll_ns` / `timeout_ns` | 默认 10 / 10000 ns |
| `vio.wait.reset_ns` / `queue_reset_ns` | 默认 5000 / 5000 ns |
| `vio.wait.vf_ready_ns` / `flr_ns` | 默认 10000 / 10000 ns |
| `vio.wait.multiplier` / `max_polls` | 默认 1 / 10000，正整数 |

标准模式可以设置 `+vio.rx_buf_size=2048`，当前 external Packed 使用 12B 头，
实际描述符长度为 2060B。旧标准协议按最终协商特性使用 10/12/20B 头。
该值表示整个以太网报文的容量；以太网/IP/TCP 等报文头已经包含在参数值内。
RX DMA 的分配长度另按 DWORD 对齐，描述符长度不因对齐扩大。

同样支持 `vio.hN.rx_buf_size` 和 `vio.hN.pfN[.vfN].iN.rx_buf_size` 覆盖。
例如 `'+vio.rx_buf_size=[2048:4096]'` 使用 AIP 原有范围语法，随配置加载采样，
本次队列配置沿用该容量，不是每个接收 buffer 重新随机。显式 0、负值及会造成
32 位加头/对齐溢出的值在加载时报错；实际大包能力仍由 DUT 和 Host memory 决定。

Tcl 可以在配置加载前写入 `set_param path=vio.rx_buf_size value=2048`；
已加载的环境需沿用现有 `load_params` 重载入口，并满足其无活动队列的前提，
然后重新配置队列。该参数不会就地修改已经投递给 DUT 的描述符。
旧 SV 字段 `default_rx_buf_size`/`rx_buf_size` 仍表示含头总容量；新的原始报文容量
单独保存，避免继承、重复查询和恢复后重载时再次加头。Custom 继续使用
`vio.private.rx_buf_size`，不增加标准 Virtio 头。

全局配置只加载一次，然后复制出各 Host 的配置再覆盖，例如：

```systemverilog
// build 前：全局模板只采样一次，每个 Host 持有独立等待策略副本。
template_cfg.load_params("vio");
host_cfg.copy_defaults_from(template_cfg);
host_cfg.host_id = 0;
host_cfg.load_params("vio.h0");
host_cfg.enable_service_params("vio");
```

`enable_service_params` 用于 AUTO placement：第一次为实际解析出的 service
调用 `get_service_config` 时，读取实例参数并缓存，再服从该 service 的实际资源上限。
后续查询不会因为 Tcl 修改而重新采样。若调用方已经明确构造 service 配置，
也可在 `add_service_config` 前显式调用 `load_service_params`，不再启用延迟加载。

```text
+vio.queue_size=256
+vio.h0.queue_size=512
+vio.h0.pf0.vf1.i0.queue_size=1024
```

这里由调用顺序实现全局 → Host → service。AIP 本身没有自动的路径继承。
PF service 路径为 `vio.h0.pf0.i0`，VF 路径多一个 `.vfN`。
普通 service 行为覆盖 pairs、queue_size、queue_type、features、napi_budget、rx_refill；
external service 另外在 placement 前冻结 enabled、方向、completion 与 notify 合同，见下节。

### PCIe TL 策略

`pcie_tl_env_config.load_params("pcie_cfg")` 在调用方设好原默认值之后、创建
`pcie_tl_env` 之前调用；可传自定义路径。没有覆盖时保留当前值，AIP-off 时为空操作。
这次开放的是现有 TL manager/driver 确实消费的 39 个行为字段，沿用原字段名：

| `pcie_cfg.` 后的字段 | 语义与边界 |
| --- | --- |
| `fc_enable`、`infinite_credit`、`init_ph_credit/init_pd_credit/init_nph_credit/init_npd_credit/init_cplh_credit/init_cpld_credit` | FC 开关与初始 credit；credit 为非负整数 |
| `shaper_enable/avg_rate/burst_size` | `avg_rate` 为 bytes/ns，有限且非负；开启 shaper 时必须大于 0；burst_size 为正整数 |
| `extended_tag_enable/phantom_func_enable/max_outstanding` | outstanding 为正整数；extended tag 关闭时不超过 256，开启时不超过 1024 |
| `max_payload_size/max_read_request_size/read_completion_boundary` | 使用真实枚举名，例如 `MPS_128`、`MRRS_512`、`RCB_128`，不使用裸数字 |
| `relaxed_ordering_enable/id_based_ordering_enable/bypass_ordering` | Ordering engine 开关 |
| `cov_enable/tlp_basic_cov/fc_state_cov/tag_usage_cov/ordering_cov/error_inject_cov` | Coverage 总开关与分类开关 |
| `scb_enable/ordering_check_enable/completion_check_enable/data_integrity_enable/scb_strict_check` | Scoreboard 创建及检查策略 |
| `ep_auto_response`、`cpl_timeout_ns` | EP 自动应答；RC completion 超时为正整数，单位 ns |
| `link_delay_enable/rc2ep_latency_min_ns/rc2ep_latency_max_ns/ep2rc_latency_min_ns/ep2rc_latency_max_ns/link_delay_update_interval` | 每方向 0 ≤ min ≤ max；update_interval 为正整数 |

所有布尔值只接受 0/1，整数须在原 `int` 字段的 0..2147483647 范围内；
参数校验在转换前拒绝负数，避免巨大负数回绕。合法 AIP 表达式仍仅采样一次。
原有 `+TAG_BIT=8|10` 在 PCIe env build 中稍后执行，继续优先覆盖
`extended_tag_enable` 和 `max_outstanding`，分别得到 0/256 或 1/1024。

本次不开放 agent 数量、active/passive、接口模式、switch、SR-IOV、prefix、
`device_cfgs`、Host memory/allocator/premap 或 Root/EP 映射。这些仍由原平台配置决定。
`response_delay_min/response_delay_max/no_snoop_enable` 虽是原配置字段，当前 TL env
没有把它们传给消费组件，因此未加入参数入口。

参考 driver fixture 在设好 MODEL/REAL_DUT 默认值后、绑定 Host memory 与创建
PCIe env 前加载 `pcie_cfg`。该 fixture 另外要求 `ep_auto_response` 与执行 profile
一致，冲突明确报错；参数不能开启 REAL_DUT 的主动 EP 应答或关闭 MODEL 的既定应答路径。
这是此 fixture 的执行主体约束，原配置类和系统 wrapper 仍允许配置该字段。

系统 wrapper 仅在调用方设置 `create_pcie_env` 并提供 `pcie_cfg` 对象时加载，
再把**同一个对象**同时发布为子 env 的 `cfg` 和 `tl_policy_cfg`。平台已有的
`global_cfg` 或 `topology_cfg` 继续拥有 graph；拓扑翻译只覆盖其原有结构字段，
已加载的行为策略会到达实际 manager/driver。wrapper 不自行启用 PCIe 环境，也不创建 global_cfg 或 Root 映射；
是否创建 PCIe env 仍由 `create_pcie_env` 显式控制。

本仓库 fixture 和 system wrapper 已统一调用 `load_params`，使用它们时不需再次
手动加载，以免重复采样。下方显式调用片段供自行创建 `pcie_tl_env` 的 test 使用。

仅使用原生 TL 的项目可参考 [一个 env + env_cfg 集成](../integration/project/README.md)：
大 env 继承 `uvm_env`，直接创建原有 DPU/PCIe/VIO；只下发 `pcie_tl_env_config` 的
`cfg`，不创建 global/topology 对象。该参考的大 cfg 统一加载参数并保护重复调用，
默认规模是 1 Host / 1 PF / 0 VF；下方 DPU 表中的 2/1/2 是参数回归示例的默认规模。

Intel 项目使用独立的 `filelists/project_integration.f`，在同一 env/cfg 中
启用 RC-only、HARD_IP 和外部引脚 bridge。`pcie_cfg.infinite_credit` 必须保持 1；
实际 AVST credit 由 `intel_pcie_adapter_config` 控制。Intel cfg 原类尚未提供
`load_params()`，所以当前 `pcie_cfg.*` 不包含 Intel 私有字段。端口字段的设置和
VIF 下发位置见 [Intel 集成说明](../integration/project/README.md#intel-配置放在哪里)。

```systemverilog
pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
pcie_cfg.cpl_timeout_ns = 100000; // 用例原来的默认值
pcie_cfg.load_params("pcie_cfg"); // 此后再创建消费它的 PCIe env
```

```text
+pcie_cfg.cpl_timeout_ns=200000
+pcie_cfg.max_outstanding=32
+pcie_cfg.max_payload_size=MPS_128
+pcie_cfg.read_completion_boundary=RCB_128
```

桥进入运行阶段后执行 `set_param path=pcie_cfg.<字段> value=<值>` 只修改 AIP 参数表，不会重新加载
已构建的配置，也不会自动重配 manager、driver 或硬件。构建参数应通过启动 plusargs
或平台在 build 前的参数设置提供。

### DPU 与系统资源

| 路径 | 作用与调用位置 |
| --- | --- |
| `dpu.hosts/pfs_per_host/vfs_per_pf` | 示例默认 2/1/2，由 `author_param_config` 创建对象；VF 为 0 时选择 PF 服务 |
| `dpu.af_host` | AF 所在 Host；正常 AF 必须是该 Host 的 PF0 |
| `dpu.bdf_first/bdf_last/reserved_bdfs/bar_policy` | 单 PCIe domain 的输入分配策略 |
| `dpu.mmio_base/mmio_size` | MMIO 窗口，半开区间 |
| `dpu.mem_base/mem_size` | GPA 窗口，半开区间；交给 inclusive-end 的 host_mem 时转换为 base+size-1 |
| `dpu.mem_mode/mem_granule/mem_policy` | 示例内存创建策略，默认 BUDDY/16/RANDOM；已注入的外部内存池不会重建 |
| `dpu.qpairs` | 示例中唯一全局 request 的普通 qpair 总量；默认足够给每个候选 Function 分配 `vio.pairs` 对 |
| `dpu.qpair_capacity/qpair_per_func/reserved_qpairs` | 全局池容量、每 Function 上限、预留 ID |
| `dpu.candidate_kind/device_policy/ordering/placement_seed` | 选择 PF/VF、固定/自动放置、排序和候选 shuffle seed |
| `dpu.host_ids/vf_ids/parent_pfs/functions/fixed_devices` | 候选过滤/固定设备集合，按完整 Function 身份声明 |
| `dpu.lan_msix` | 每 Function LAN 向量数，0 表示按分配到的 qpair 数量 |
| `dpu.qsch.mode/max_groups/max_ports/max_tc/shared_group/include_af` | **legacy** QSCH generator 约束，需显式调用 generator.load_params 后再生成拓扑 |
| `dpu.caps.*` | DUT 能力边界；不能把声明上限当成实际已创建数量 |

Host 模板加载 `dpu` 一次，复制后加载 `dpu.hN`。示例沿用原来的 GPA/MMIO
每 Host 地址间距；需要精确地址时设置 `dpu.hN.mem_base/mmio_base`。
单 domain/window 直接使用短名，多 domain/window 使用 `.domainN/.mmioN`。
多个 placement request 的路径是 `dpu.requestN.*`；每个 request 的 qpairs
是该 request 的总量。完整 DPU 字段/集合映射见外部 `dpu_common/README.md`。

修改 MSI-X/QSCH 输入不会自动重写硬件。当前项目使用下节 `dpu_env_cfg` 和
`vio_dpu_cfg_seq`，加载配置后显式执行 sequence；独立 topology generator 仍只是数据构造工具。

### 私有队列

在原有私有配置创建之后、`add_dpu_private_config`/Function 绑定之前调用
`private_cfg.load_params("vio.private")`。这不会把标准协议自动切换为私有协议。

支持 `queue_size`（2..4096 的 2 的幂）、`rx_buf_size`（64..16383）、
`local_qid_base`（偶数、范围受最终队列数约束）、`notify_bar/notify_offset`、
`dport_info/dport_id/dport_type/cpu_tx_cos/rss_lag/l3_cs/l4_cs/i_l3_cs/i_l4_cs/fwd`。
四个 checksum 字段分别保留，均只接受 0/1；`i_l3_cs/i_l4_cs` 由
`dpu_priv_queue_config::load_params` 注册，不能用原 `l3_cs/l4_cs` 替代。
已有单队列覆盖对象使用 `vio.private.qN.*`，并可指定该队列 `local_qid`。
普通 legacy 调用不会通过这些参数自动创建覆盖对象，最终还须调用
`validate(pairs, why)`。项目 external Custom 在首次解析最终 service 需求时，
若未注入私有配置则创建它：先按全局 → Host → service 合并 `.private.*` 默认值，
再为实际 `2*pairs` 个队列创建独立副本，按同样顺序合并 `.private.qN.*`。
例如 `vio.h0.pf0.vf1.i0.private.q0.i_l3_cs=1` 只覆盖该 service 的队列0。
已有显式私有配置仍由调用方加载。`notify_bar_present/notify_offset_present`
是读取对应参数时设置的 SV 标志，不是另行注册的参数键。

## 项目外部配置参数

入口是 `project_env_cfg::load_params()`；它调用原配置类并在生成 topology/placement
前解析最终 service 需求，重复调用不再加载。默认1 Host/1 PF/0 VF、REAL_DUT、
`external_configuration=1`；默认 AF PF0 的额外资源仍占每 Function 容量。
`dpu.hosts/pfs_per_host/vfs_per_pf/reg_target/print_bar_map` 和公共表参数由
`dpu_common/src/dpu_env_cfg.sv` 加载；参考 cfg 仅组合对象，并加载 Host memory 的
`dpu.mem_mode/mem_granule/mem_policy`。PCIe/核心 VIO 字段仍由各自拥有类加载。
DPU 与 VIO 共用最终 service 采样值，不分别随机生成第二份队列要求。

| 参数 | 拥有类 / 确切行为 |
| --- | --- |
| `dpu.reg_target` | `dpu_env_cfg`；默认 `pf0.bar0`，只是访问窗口，不改变条目 owner |
| `dpu.print_bar_map` | `dpu_env_cfg`；默认1，发布后逐代打印真实 BAR，不发 TLP |
| `dpu.configure_public` | 默认0；1才额外执行 BAR/PFVF/Completion BDF/Prefix 等公共配置，保留显式非VIO消息；不控制软件BAR分配或VIO所需BDF/MSI-X |
| `dpu.configure_bdf` | 默认1；独立配置BDF请求身份表，地址为管理BAR+0x108000+bdf_index*4；0用于平台已配置的场景 |
| `dpu.driver_layouts` | 默认1；补齐 BDF/MSI-X/Notify/QSCH/VTX/VRX 驱动参考地址，已提供布局优先；0时自行声明 |
| `dpu.verify_readback` | 默认0；省略普通表读回，AF 首读及周期状态读仍执行。1时验证BDF、所选MSI-X、QSCH模式、Notify有效项/QSCH/队列表及MSI-X查找表尾部，以及已选择的其他公共配置 |
| `dpu.hH.pfP[.vfV].requester/intel_pf/intel_vf/vport` | 软件路由；每 Host 的 PF0/no-VF 默认0/0/-1/0，其余Function显式提供四项或完整 policy；不下发硬件表 |
| `dpu.hH.pfP[.vfV].bdf_index` | BDF表硬件索引0..127；新生成policy默认取vport，已有显式policy保持其索引；配置seq使用同一身份写表 |
| `dpu.qsch.configure_controls` | 默认1；配置模式并自动生成缺少的SP/WRR和TC weight项，显式catalog优先 |
| `dpu.qsch.mode/mode_offset` | 默认0/0xb001c0；mode为0=VNET、1=ETS，须与service的ets一致；offset为管理BAR内字节偏移 |
| `dpu.qsch.spwrr/tc_weight` | 默认0xff/0x11111111；分别8位SP/WRR选择、32位TC权重，每个实际net_id生成一项 |
| `dpu.<category>.reg_target` | `dpu_env_cfg::load_platform_params`；覆盖该类别访问窗口，类别见下表 |
| `dpu.bar_map.reg_target` / `dpu.msix.reg_target` / `dpu.qsch.reg_target` | 同类；BAR/MSI-X/QSCH 家族默认，详细类别覆盖家族 |
| `vio.vtx.reg_target` / `vio.vrx.reg_target` / `vio.notify_table.reg_target` | 同类；分别最后覆盖 `dpu.vtx/vrx/vio_notify.reg_target` |
| `vio.enabled` / `tx_enable` / `rx_enable` | `virtio_net_env_config::load_external_requirement`；0/1，默认均1。最终 enabled=0 或 TX/RX 均0时不分配 VIO 队列、不写 VIO/Notify/QSCH；公共 Function 保留。RX-only 跳过 VTX/QSCH |
| `vio.pairs/queue_size/queue_type` | 核心同类；先求最终需求再 placement，不静默减小。external 的 pairs=0 表示不启用该 service；旧驱动模式仍要求非零。项目使用 `VQ_PACKED` 或 `VQ_CUSTOM`；实际深度同时受VIP和图片约束 |
| `vio.features` | 核心同类；external Packed 默认 VERSION_1 与 RING_PACKED，二者必需；另允许 NOTIFICATION_DATA、IN_ORDER、RING_EVENT_IDX、ACCESS_PLATFORM、CSUM、HOST_TSO4/6、HOST_USO。TSO/USO依赖CSUM；声明能力不自动启用每包offload。Custom 强制0，显式非零拒绝，不执行设备协商 |
| `vio.completion_mode` | 核心同类；`VIRTIO_COMPLETION_POLLING` 或 `VIRTIO_COMPLETION_MSIX`，MSI-X 无轮询兜底 |
| `vio.notify_bar/notify_base/notify_stride/notify_encoding` | 核心同类；真实 doorbell 的偶数 BAR、BAR内offset/队列步长/`VIO_NOTIFY_QID16`、`VIO_NOTIFY_DATA32`、`VIO_NOTIFY_DPU32`。提供 notify_base 标记布局有效，不能拿 notify lookup 表偏移替代 |

核心 external 合同使用 `vio → vio.hH → vio.hH.pfP[.vfV].iI` 优先级；只采样一次，
以后 Tcl `set_param` 不会改变 placement/已准备 ring。`external_configuration`、
`notify_layout_valid` 是 SV 字段，没有同名注册参数；project 构造器设置前者，
提供 notify_base 或显式 SV 字段设置后者。

详细类别名（均在 `dpu.` 下，后接 `.reg_target`）：
`bar`、`af`、`pfvf`、`bdf`、`completion_bdf`、`tlp_prefix`、`msix_linear`、
`msix_info`、`msix_interval`、`msix_control`、`msix_table`、`msix_function`、
`vio_notify`、`qsch_q2tc`、`qsch_n2g`、`qsch_g2p`、`qsch_spwrr`、
`qsch_tc_weight`、`vtx`、`vrx`、`queue_aux`、`rdma_notify`、`qsch_rnet`。
默认驱动布局覆盖 BDF/MSI-X/VIO/QSCH；其他未提供的表布局在使用时仍失败，reg_target 只选访问窗口。完整 `hH.pfP[.vfV].barB`
自带访问 Host；多 Host 短路径必须由 typed layout 指定访问 Host 或明确采用 owner Host。

公共 MSI-X 参数由 `dpu_env_cfg::load_platform_params` 拥有，不依赖 VIO service。
路径依次为 `dpu.msix → dpu.hH.msix → dpu.hH.pfP[.vfV].msix`，后者覆盖前者：

| 相对该路径的字段 | 含义与校验 |
| --- | --- |
| `table_bar/table_offset/table_size` | 显式 table 偶数 BAR/offset/entry数；提供 offset 才标记存在，16B对齐，1..1024项 |
| `pba_bar/pba_offset/pba_words` | PBA 独立布局，显式64位word容量，8B对齐；不从 vector 数猜容量，不做初始化写 |
| `msg_addr_base/msg_addr_stride` | 64位 Message Address 模板，溢出拒绝，无APIC区域限制 |
| `msg_data_base/msg_data_stride` | 32位完整 Message Data 模板；不要求低位等于vector |
| `interval_rate/interval_packets` | 各16位，参考默认均0；对应图片 MSI-X interval 两字段 |
| `self_mask` | 参考默认0；设为1时实际RTL的再次使能由平台完成 |
| `table_only_enable` | 参考默认1，仅靠table mask使能；设为0时提供 Function control catalog/hook |
| `vN.msg_addr/vN.msg_data/vN.masked` | 按local vector N逐项覆盖模板；data32位，masked为0/1 |

项目队列表策略也在 `dpu_env_cfg::load_platform_params` 注册。
除 QSCH 额外先读 `dpu.qsch.*` 外，优先级是
`vio → vio.hH → vio.hH.pfP[.vfV].i0`。下表字段相对上述 VIO 路径：

| 字段 | 语义 |
| --- | --- |
| `vtx.dma_info` | 4位显式平台策略 |
| `vtx.tail_buf_id_dis/redraw_en/high_speed_mode/seg_en/interl_seg_en` | 各0/1，硬件/深度约束另行检查 |
| `vrx.dsc_pre_max_num/dsc_pre_read_threshold/dsc_dma_num/dsc_mode/payload_dsc_len/head_dsc_len` | 图片位宽分别3/2/2/2/3/2；目前非零dsc_mode/payload/head split 不支持并拒绝 |
| `qsch.net_base/net_stride/group_id/cos/eth_ports/ets/distinguish_business/ets_priority` | 生成实际Q2TC/N2G/G2P；net/group10位、cos3位、ETH加Host须容纳4位、ETS priority3位；不等同legacy generator参数 |
| `fpga` | 0/1，限制global qpair/VRX RAM高位容量 |
| `prefetch_ram/prefetch_start/prefetch_slots` | RAM名字表示真实共享域，起点/容量单位是descriptor槽；同名RAM跨Host也检查重叠 |
| `notify_net_pair5` | 0/1，明确采用单bank net pair5编码 |
| `notify_table_bar/notify_table_offset` | 可选的 Notify 查找基址覆盖；未提供时取实际 doorbell `[60:7]`。任一项显式提供即启用覆盖，并检查地址高位一致 |

以上整数在窄字段赋值前检查越界。VIO/QSCH 模块与间接端口由驱动参考布局提供，
可在env构建前修改typed cfg；公共PBA/Function表编码/BAR组仍按平台明确声明。
Notify 按 `{host_id, BAR匹配基址, pair编号}` 排序后分配物理行，global_qid保持实际资源编号。
Notify 保持512行单bank容量，但seq只写实际队列对的有效项；同PF 32对写32项，TX/RX共用每对的一项。
`dpu.verify_readback=1` 也只通过真实Memory Read验证有效项，不访问未用行。
首次配置前DUT须已按 `05.png` 复位，未用项type=3、lookup key/global_qid全1、reserved=0。
Notify目录使用统一管理BAR；参考布局短目标默认Host0，可用`vio.notify_table.reg_target`改为完整目标。
旧 `dpu.notify.bank/auto_bank/full_bank` 和旧 MSI-X plan policy 已随生产 builder 删除；
独立 QSCH generator 仍保留。每批 VIO/RDMA Notify 成功后，每个管理 BAR 写一次
`+0x80044=1`，无 bank 参数；空批次或表写失败不发使能。

运行期 `load_params` 用 `aip_cmd_task(load_params, project_load_params)` 在顶层注册一次，
不为每个 cfg 注册同名命令，也不手写命令适配类。seq 注册类型改为 `vio_dpu_cfg_seq`，
`reg_acc` 改为 `dpu_bar_reg_seq`；从 sequencer 取得公共 `dpu_cfg`，不依赖用户 env_cfg 类型。
恢复后先重新 source AIP loader，再 `load_params`、`dut_config`。重载边界和完整接入见
[项目参考](../integration/project/README.md#快照恢复后重新加载配置)。

项目运行时只调用 `env.register_aip_commands()`，内部使用
`virtio_aip_registry::register_business_commands()`；公共无VIO用途跳过注册。
不能在同一个项目流程另行调用下节 `register_commands()` 打开旧init/reset/MQ/RSS。
项目启动/停止并不自动配置硬件，必须先完成 typed 配置/使能/所选验证/确认。

## 普通标准驱动：在现有 base_test 注册命令

各 Host env 已创建并且真实 PCIe/driver 绑定完成后、进入 bridge 之前调用：

```systemverilog
// 此函数放在用户原有 base_test；my_vio_env 为已集成的环境句柄。
function void register_aip_commands();
    string why;
    if (!virtio_aip_registry::bind_env(my_vio_env, why))
        `uvm_fatal("AIP_BIND", why)
    // 多 Host 时先对各 env 调用 bind_env，再统一注册一次命令。
    if (!virtio_aip_registry::register_commands(why))
        `uvm_fatal("AIP_BIND", why)
endfunction
```

run_phase 持有 objection，完成注册后调用 `aip_tcl_bridge::run_loop()`；
Tcl `end_test` 使其返回，再释放 objection。参考 `virtio_aip_driver_test.sv`。
普通 legacy 注册的默认命令是 `vio_init/vio_start/vio_tx/vio_wait_rx/vio_set_mq/vio_set_rss/vio_stop/vio_reset`。

| 运行参数 | 语义 |
| --- | --- |
| `vio.target` | 完整服务身份，如 `h0.pf0.vf1.i0`；只有一个目标时可省略 |
| `vio.tx.target` / `vio.rx.target` | 本次 TX/RX 目标，缺省继承 `vio.target` |
| `vio.tx.pair` | 活动队列对下标，默认 0，禁止当 raw queue ID 使用 |
| `vio.tx.kind` | `packet_template_e` 名称或逗号候选列表，默认 `ETH_IPV4_TCP`；每包通过 `aip_enum` 重新读取并抽样 |
| `vio.tx.len` / `len_min` / `len_max` | 每包重新取值，默认64字节（含协议头）；支持候选/范围表达式，保留min/max用法，必须容纳完整头和尾 |
| `vio.tx.gap_ns` | 每包重新取值的包间隔，默认0；作用于本包提交到下一包生成之间 |
| `vio.tx.timeout_ns` | 本包因ring空间不足而等待的预算，默认10000ns，乘以`vio.wait.multiplier`；不限制整条多包命令总时长 |
| `vio.tx.notify_batch` | 每批抽样一次的目标包数，默认1；支持固定值/候选/范围。批末、命令尾包或空间不足时通知，不能为0 |
| `vio.tx.desc_count` | 每包通过 `aip_int` 抽样的总描述符数，包含标准 header 或 Custom TSO 扩展项；省略时取当前格式所需的最少数量，显式0非法 |
| `vio.tx.seg_mode` | `VIO_SEG_EQUAL`（默认）或 `VIO_SEG_RANDOM`，每包通过 `aip_enum` 取值；只切分报文数据，保持 header/扩展项完整 |
| `vio.tx.csum` / `gso` / `mss` | 每包通过 `aip_int` 重新读取，默认0/0/1460；GSO隐含checksum，payload超过MSS才产生分段请求。报文与请求按同一transaction提交，实际队列决定标准/Custom编码 |
| `vio.tx.hdr.*` | 复用packet.load_params，逐包读取协议头和payload；例如`eth.dst_mac/ipv4.src_addr/udp.dst_port/payload_mode/payload_fixed_val/payload_pattern` |
| `vio.rx.expected/timeout_ns` | 默认 1 / 50000 ns；只等待，不产生网络侧激励 |
| `vio.mq.target/pairs` | 动态 MQ 命令，必须服从当前已分配资源上限 |
| `vio.rss.target/hash_types/hash_key_size/hash_key[i]/table_size/indirection_table[i]` | RSS 控制输入；设备须已协商对应功能 |

单条设置使用 `set_param path=<参数路径> value=<值>`；直接写
`set_param <参数路径> <值>` 会因缺少命名字段 `path` 而报错。

VTX offload 的协议、头长和偏移来自本包最终字节，经现有 `net_packet` parser
解析；当前支持普通 IPv4/IPv6 TCP/UDP，包含 VLAN 和 IPv4/TCP options，暂不支持
隧道、IP分片及IPv6扩展头的offload。无offload的普通发包不受此限制。
三个键均未指定时，Custom继续使用 `vio.private.*` 的队列默认checksum控制；
指定任一键后采用本包请求，`csum=0,gso=0` 可显式关闭本包的checksum控制。
不同TX别名使用注册时的独立参数路径；不需要额外注册reload task。

上述参数也可在启动时通过命令行传入，随后直接执行 `vio_start`/`vio_tx`：

```bash
./simv \
  +vio.tx.kind=ETH_IPV4_TCP,ETH_IPV6_TCP \
  '+vio.tx.len=[2048:4096]' '+vio.tx.notify_batch=[16:32]' \
  +vio.tx.csum=1 +vio.tx.gso=1 +vio.tx.mss=512 \
  +vio.tx.timeout_ns=10000
```

`vio_tx count=100` 会在候选类型中逐包重新选择；列表使用逗号分隔，不加数组方括号。
同一路径的 `set_param` 优先于命令行，可在包间修改候选、包长、协议头、payload和offload。
无需额外调用load_params；等待ring空位时保留当前已生成包，不重新取参或随机化。
批大小在下一批开始时重新读取，当前批的目标保持不变。

标准Packed在准备队列前通过 `vio.features` 声明能力。例如
`+vio.features=0x500001801` 包含 VERSION_1/PACKED/CSUM/HOST_TSO4/HOST_TSO6；
若还需要UDP分段，使用 `0x100000500001801` 加上 HOST_USO。
保留原有其他feature位；恢复快照后只在已声明能力内改每包请求。
Custom的 `vio.features` 仍为0，checksum写入私有描述符，GSO额外占一个16B扩展槽；
MSS上限16383，头长还受驱动描述符的2B/4B单位和位宽约束。
私有 checksum 使能按驱动同时置 `l3_cs/l4_cs/i_l3_cs/i_l4_cs`，IPv4/IPv6一致。
GSO的校验控制仅放在扩展描述符；后续数据描述符保留路由和数据字段，四个校验位清零。

```tcl
# DUT已经完成配置并执行vio_start；以下开关同时适用于Packed和Custom。
set_param path=vio.tx.kind value=ETH_IPV4_TCP
set_param path=vio.tx.len value=4096
set_param path=vio.tx.csum value=1
set_param path=vio.tx.gso value=1
set_param path=vio.tx.mss value=512
vio_tx count=1

# 下一包关闭offload；不会改写已经提交的包或共享env_cfg。
set_param path=vio.tx.csum value=0
set_param path=vio.tx.gso value=0
set_param path=vio.tx.len value=512
vio_tx count=1
```

标准模式仍为 `[virtio_net_hdr][packet]` 两个直接描述符；Custom普通包为一个
data描述符，GSO大包为 `[TSO extension][data]`，扩展槽计入notify尾指针和完成回收。
只修改DMA发送副本中的partial-checksum初始值，保留原始net_packet报文供比对。

`count` 是累计提交包数，ring深度是描述符槽数。未指定`desc_count`时，常规包的
Packed路径占2槽，Custom普通包占1槽、GSO大包占2槽；Custom还需留1个空槽。完成回收后槽位
可重复使用，因此累计发包数可以超过ring深度。当前空闲槽不足时，先通知已提交部分，
再通过原完成路径等待和回收；有足够空位后提交
同一个包。等待不分配本包DMA，也不覆盖旧描述符。只有超过`vio.tx.timeout_ns`仍不足时
报告`VIO_TX_TIMEOUT`并停止后续发送。完成仍遵循配置的轮询/MSI-X机制，不绕过中断许可。
`vio_start`启动后台完成回收；受阻的发送也复用同一回收入口。

显式指定 `desc_count=N` 时，标准模式为 `[完整 virtio_net_hdr][N-1 条 data]`；
Custom 普通发送为 N 条 data，实际生成 TSO 扩展项时为 `[extension][N-1 条 data]`。
当前 Custom 最多7条 data，每条不超过65536B；标准数量还受实际 ring 容量约束，
接真实 DUT 时也要服从设备的链长度能力。当前参数控制直接描述符；MANUAL 调用中的
indirect 原有默认行为保留，但不与显式 `desc_count` 混用。

均分时将除法余数分给前几段，每段长度最多相差1B；随机时每段长度为正，且为后续段
保留合法长度。所有 data 长度之和严格等于本包长度。512B报文、标准总数9时，均分为
一条header加8条64B data。各data引用同一报文DMA的不同偏移，不额外复制或分配每段。
SG切分不改变报文内容；checksum/GSO仍按同一包的最终字节和原有offload参数生成。

参数每包采样后固定；等待 ring 空位不重抽数量/长度。抽到非法数量、超过格式或容量
上限、无法保证各段非零等情况，在本包DMA分配和描述符发布前报 `UVM_FATAL/VIO_TX_SEG`，
不裁剪、不重抽、不发送本包Notify。已发送的前序包不回撤。临时空位不足仍正常等待。

```bash
# Packed标准模式：每包8..10条总描述符、随机切分报文；启动参数无需先调用set_param。
./simv '+vio.tx.desc_count=[8:10]' +vio.tx.seg_mode=VIO_SEG_RANDOM +vio.tx.len=512
```

```tcl
set_param path=vio.tx.desc_count {value=[8:10]}
set_param path=vio.tx.seg_mode value=VIO_SEG_EQUAL
vio_tx count=200

# Custom普通包改为1..7；实际启用TSO扩展项时可选择2..8条总描述符。
set_param path=vio.tx.desc_count {value=[1:7]}
```

Packed链尾携带该包的Buffer ID；当前所有链槽写同一个ID，完成时使用本地记录释放
全部槽，不依赖设备保留NEXT。完成判断同时核对AVAIL/USED与当前wrap；链记录包含在
队列迁移快照及校验中。`send_packets count=1`逐事务信息降为`UVM_HIGH`，普通运行保留
AIP命令的提交数量汇总。

`notify_batch=32`时，1000包正常分成31个完整批次及最后8包，尾批同样通知。
ring空间不足会提前拆批，因此实际DB数可能多于32次；批大小超过ring容量也能继续运行。
Custom发出当前实际尾指针，Packed保留device event suppression规则。指针按实际描述符
槽数推进，GSO扩展槽也计数，跨ring末尾翻转wrap，用户不填写tail/wrap。
这里的批大小按送入VIP的包数计算；GSO大包按一个输入包计数，不按DUT分段后的包数计数。

```tcl
# 固定32包一次DB；最后8包也会通知。
set_param path=vio.tx.notify_batch value=32
vio_tx count=1000

# 每批在8/16/32中随机选目标；每包独立选择长度和payload字节。
set_param path=vio.tx.notify_batch value=8,16,32
set_param path=vio.tx.len {value=[512:1514]}
set_param path=vio.tx.hdr.payload_mode value=PAYLOAD_FIXED
set_param path=vio.tx.hdr.payload_fixed_val {value=[0:255]}
vio_tx count=1000

# 连续范围也可用；Tcl中用花括号保护方括号，避免触发Tcl命令替换。
set_param path=vio.tx.notify_batch {value=[16:32]}
```

对照上传的`prj1_v2_dpu_kernel_eth_driver`：`txrx.c`中自定义TX（1762行）和标准TX
（1935行）当前均逐包调用`dpu_update_tail_ptr`；RX补buffer（1132行）按批通知。
`txrx.h`的637行将`wrap<<31 | tail<<16 | local_qid`写到notify地址。
新增批量参数保留该编码和描述符发布顺序，只减少TX的DB次数；真实DUT批量消费仍需平台验证。

```tcl
set_param path=vio.target value=h0.pf0.i0
set_param path=vio.tx.kind value=ETH_IPV4_UDP
set_param path=vio.tx.len value=128
set_param path=vio.tx.hdr.eth.dst_mac value=0x001122334455
vio_init
vio_start
vio_tx count=100
# 下一次调用使用新参数；已运行的构建配置不会因此改变。
set_param path=vio.tx.kind value=ETH_IPV4_TCP
set_param path=vio.tx.len value=512
vio_tx count=20
vio_stop
vio_reset
end_test
```

计数只用 `count=`，不另设 `vio.tx.count`。当前适配器拒绝 `time=`，以免把强制
杀 seq 当成完成；结束按平台的 monitor/scoreboard 检查器判断。TX 返回成功只说明
提交完成，RX还需要网络侧送包。使用已支持运行期表达式的新版AIP后，命令行与
`set_param`均可使用候选、范围或权重表达式；VIO复用AIP的类型参数入口，不另写解析器。

独立发包流可调用 `register_tx_command("vio_tx0", "vio.tx0", why)` 注册别名。
同名命令由 AIP 检查 BUSY；同一 service 上允许 TX/TX 逐事务仲裁，控制/RX 命令
与其它命令互斥。普通 legacy 注册取消后目标需要 reset，driver 已接收事务不会自动回滚。
project external 注册不开放 reset；必须停机/quiesce/release，再准备、验证和确认新代。
命令采用保守错误判定：期间出现 UVM_ERROR/FATAL 即失败，并发其它流的错误也可能
使本次失败。严格退出应接入平台自己的 `aip_end_checker`，再使用
`end_test wait_done=1 timeout=2ms strict=1`。

## 运行验证

在 `10.11.10.53` 加载 VCS 环境，并设置实际依赖根目录后运行：

```bash
source ~/.bashrc
export AIP_CORE_ROOT=/path/to/aip_core_update
export DPU_COMMON_ROOT=/path/to/modified_dpu_common
export NET_PACKET_ROOT=/path/to/net_packet_with_package
export HOST_MEM_ROOT=/path/to/host_mem
export PCIE_WORK_ROOT=/path/to/pcie_work
TEST=virtio_aip_params_test scripts/run_aip.sh
TEST=virtio_aip_command_test scripts/run_aip.sh
TEST=pcie_aip_params_test scripts/run_aip.sh
TEST=pcie_aip_params_test scripts/run_aip.sh +TAG_BIT=10
TEST=pcie_aip_system_policy_test scripts/run_aip.sh
TEST=pcie_aip_system_policy_test scripts/run_aip.sh +PCIE_GRAPH_GLOBAL
TEST=virtio_system_env_example_test scripts/run_aip.sh \
  +dpu.hosts=1 +dpu.pfs_per_host=2 +dpu.vfs_per_pf=1 \
  +dpu.qpairs=4 +vio.pairs=2 +vio.queue_size=128
TEST=virtio_aip_driver_test TCL_CASE=examples/aip/cases/tx_smoke.tcl \
  scripts/run_aip.sh +PCIE_REQUIRE_DRAINED +vio.queue_size=128 \
  +vio.completion_mode=VIRTIO_COMPLETION_POLLING \
  +pcie_cfg.cpl_timeout_ns=200000 +pcie_cfg.max_outstanding=32 \
  +pcie_cfg.max_payload_size=MPS_128 +pcie_cfg.read_completion_boundary=RCB_128
```

`run_aip.sh` 明确使用指定工作树，保留 compile/sim 严格日志检查。它不修改旧
`scripts/check_deps.sh` 的固定 SHA 门；跨仓库改动提交后再更新正式依赖锁定。
PCIe 参数测试还提供独立 `+PCIE_PARAM_NEGATIVE=unsigned_wrap|enum|bool|outstanding|geometry|shaper_rate`
负例；每个进程必须在原参数解析/校验处 fatal，`PCIE_PARAM_NEGATIVE_UNKNOWN` 或
`PCIE_PARAM_NEGATIVE_MISSED` 不能计作通过。不要把预期 fatal 混入正常严格日志汇总。
配置测试使用真实配置消费接口；命令单元测试使用录制 driver；Tcl 示例使用
MODEL PCIe 设备流程。它们不代表真实 RTL DUT 已通过流量验证。

短 Tag 池回归可复用同一 Tcl，只传 `+pcie_cfg.max_outstanding=32 +PCIE_REQUIRE_DRAINED`，
并与仅传 `+PCIE_REQUIRE_DRAINED` 的默认配置对照。本次同时修复 PCIe TLM 的 EP DMA
观察顺序：single/pair/switch 回程在释放 EP Tag 前同步检查 Completion，延后 monitor
按同一 Completion 句柄去重，且不会重新登记已经完成的请求；不同 Completion 分片仍独立检查。
`PCIE_REQUIRE_DRAINED` 在 Tcl bridge 退出后保持 objection，按真实 SCB 跟踪表与
RC/EP adapter FIFO 的空状态等待 monitor 完成最后的观察，并等协议 SVA 的暂存事件及当前脉冲
全部消费，最多等待 10us，已有检查错误立即失败。示例在进入 Tcl bridge 前也会等待实际协议
接口的复位释放，避免初始化历史在平台复位期间被丢弃。
这不是固定时长 drain；状态收敛即结束。在 check phase 仍要求 strict/Completion 检查已启用、
pending 请求和分片跟踪表为空、unexpected/mismatch 为零，并在 TLM 模式检查去重标记全部回收；
它不会清理跟踪状态或改变 driver/monitor 的传输时序。

本次未开放标准 Virtio 数据路径尚未接通的 MTU/MSS、标准 RX buffer 大小、
Virtio 报文自动带宽限制（PCIe TL shaper 见上文）、
强制中断分配模式，也未增加多段资源范围/任意对象 schema 的自动构建。
这些配置仍按原来的程序化接口使用，不能仅通过传入同名参数期待新行为。
