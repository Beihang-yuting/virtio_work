# AIP 参数与 Tcl sequence 接入

参数加载定义在原配置类的 `load_params()` 中，公开路径使用 `dpu.*`、`vio.*` 与 `pcie_cfg.*`。
`load_params()` 执行读取和赋值；它不是 Tcl 参数到 SV 字段的持续绑定。
构造函数、复制和普通 `get` 不会重新读取全局参数。

## 编译与文件定位

可选完整编译入口为 `filelists/aip_integration.f`，顺序是 AIP、DPU、
net_packet/host_mem/PCIe、Virtio，最后是 `integration/aip/virtio_aip_pkg.sv`。
使用 AIP update 的 `src/sv/aip_core_pkg.sv`，同一个 package 只编译一次。
这里沿用 net_packet 的 `AIP_CMDLINE_SV` 可见性约定：在同一编译调用中先编译
AIP，后编译各配置类。不要手工预定义这个 include guard 再编译 AIP 自身。
不启用 AIP 时，原配置类的 `load_params()` 保留为空操作。

| 参数所属文件 | 加载入口与内容 |
| --- | --- |
| `virtio_net_vip/src/env/virtio_net_env_config.sv` | `load_params` 加载 Host 默认；`load_driver_params` 定义驱动短名映射；`load_service_params` 应用精确 service 覆盖 |
| `virtio_net_vip/src/shared/virtio_wait_policy.sv` | `load_params` 加载 `vio.wait.*`；env 在 build 时复制到实际使用的 wait policy |
| `virtio_net_vip/src/dpu_priv/dpu_priv_driver_config.sv` | 私有 Function 与单队列各自 `load_params` |
| 外部 `dpu_common/src/dpu_device_cfg.sv` | Host/domain/MMIO/function/BAR/AF 等原类加载；不根据数量创建拓扑 |
| 外部 `dpu_common/src/dpu_placement_cfg.sv` | 资源池、候选过滤与 placement request 加载 |
| 外部 `dpu_common/src/dpu_vio_reg_plan_types.sv` | notify/MSI-X policy 加载 |
| 外部 `dpu_common/src/dpu_vio_qsch_topology.sv` | QSCH generator 加载；生成结果仍需接入实际 dataplane plan extension |
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
| `vio.exec_mode` | `VIRTIO_EXEC_MODEL` 或 `VIRTIO_EXEC_REAL_DUT` |
| `vio.completion_mode` | `VIRTIO_COMPLETION_MSIX` 或 `VIRTIO_COMPLETION_POLLING` |
| `vio.scb` / `vio.coverage` | 默认 1 / 0，属于 Host env，不能按 VF 创建另一份验证组件 |
| `vio.iova_base` / `vio.iova_size` | 设备可见地址范围，4KiB 对齐、非零且 base+size 不溢出；与 GPA/MMIO 独立 |
| `vio.iova_policy` / `vio.iommu_strict` | 默认 `IOMMU_IOVA_RANDOM` / 1 |
| `vio.wait.poll_ns` / `timeout_ns` | 默认 10 / 10000 ns |
| `vio.wait.reset_ns` / `queue_reset_ns` | 默认 5000 / 5000 ns |
| `vio.wait.vf_ready_ns` / `flr_ns` | 默认 10000 / 10000 ns |
| `vio.wait.multiplier` / `max_polls` | 默认 1 / 10000，正整数 |

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
service 只允许覆盖 pairs、queue_size、queue_type、features、napi_budget、rx_refill。

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

桥进入运行阶段后执行 `set_param pcie_cfg.* ...` 只修改 AIP 参数表，不会重新加载
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
| `dpu.notify.bank/auto_bank/type/offset/verify/retries/interval_ns/full_bank` | register-plan policy；`retries` 表示包含首次操作的总尝试次数 |
| `dpu.msix.rate/packets/self_mask/emit_interval` | MSI-X 寄存器计划策略 |
| `dpu.qsch.mode/max_groups/max_ports/max_tc/shared_group/include_af` | QSCH generator 约束，需显式调用 generator.load_params 后再生成拓扑 |
| `dpu.caps.*` | DUT 能力边界；不能把声明上限当成实际已创建数量 |

Host 模板加载 `dpu` 一次，复制后加载 `dpu.hN`。示例沿用原来的 GPA/MMIO
每 Host 地址间距；需要精确地址时设置 `dpu.hN.mem_base/mmio_base`。
单 domain/window 直接使用短名，多 domain/window 使用 `.domainN/.mmioN`。
多个 placement request 的路径是 `dpu.requestN.*`；每个 request 的 qpairs
是该 request 的总量。完整 DPU 字段/集合映射见外部 `dpu_common/README.md`。

修改 notify/MSI-X/QSCH 输入并不会自动重写已运行硬件。平台应在相应计划生成前
加载、校验并应用；配置示例只验证对象与快照，不执行这些寄存器计划。

### 私有队列

在原有私有配置创建之后、`add_dpu_private_config`/Function 绑定之前调用
`private_cfg.load_params("vio.private")`。这不会把标准协议自动切换为私有协议。

支持 `queue_size`（2..4096 的 2 的幂）、`rx_buf_size`（64..16383）、
`local_qid_base`（偶数、范围受最终队列数约束）、`notify_bar/notify_offset`、
`dport_info/dport_id/dport_type/cpu_tx_cos/rss_lag/l3_cs/l4_cs/fwd`。
已有单队列覆盖对象使用 `vio.private.qN.*`，并可指定该队列 `local_qid`。
不会通过这些参数自动创建覆盖对象，最终还须调用 `validate(pairs, why)`。

## 在现有 base_test 注册命令

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
默认命令是 `vio_init/vio_start/vio_tx/vio_wait_rx/vio_set_mq/vio_set_rss/vio_stop/vio_reset`。

| 运行参数 | 语义 |
| --- | --- |
| `vio.target` | 完整服务身份，如 `h0.pf0.vf1.i0`；只有一个目标时可省略 |
| `vio.tx.target` / `vio.rx.target` | 本次 TX/RX 目标，缺省继承 `vio.target` |
| `vio.tx.pair` | 活动队列对下标，默认 0，禁止当 raw queue ID 使用 |
| `vio.tx.kind` | `packet_template_e` 名称，默认 `ETH_IPV4_TCP`，每次命令采样一次 |
| `vio.tx.len` / `len_min` / `len_max` | 默认 64 字节，含协议头；min/max 指定时逐包选长度，必须容纳完整头和尾 |
| `vio.tx.gap_ns` | 包间隔，默认 0 |
| `vio.tx.hdr.*` | 交给已有 packet.load_params，例如 `eth.dst_mac/ipv4.src_addr/udp.dst_port`，逐包读取后重新 pack |
| `vio.rx.expected/timeout_ns` | 默认 1 / 50000 ns；只等待，不产生网络侧激励 |
| `vio.mq.target/pairs` | 动态 MQ 命令，必须服从当前已分配资源上限 |
| `vio.rss.target/hash_types/hash_key_size/hash_key[i]/table_size/indirection_table[i]` | RSS 控制输入；设备须已协商对应功能 |

```tcl
set_param vio.target h0.pf0.i0
set_param vio.tx.kind ETH_IPV4_UDP
set_param vio.tx.len 128
set_param vio.tx.hdr.eth.dst_mac 0x001122334455
vio_init
vio_start
vio_tx count=100
# 下一次调用使用新参数；已运行的构建配置不会因此改变。
set_param vio.tx.kind ETH_IPV4_TCP
set_param vio.tx.len 512
vio_tx count=20
vio_stop
vio_reset
end_test
```

计数只用 `count=`，不另设 `vio.tx.count`。当前适配器拒绝 `time=`，以免把强制
杀 seq 当成完成；结束按平台的 monitor/scoreboard 检查器判断。TX 返回成功只说明
提交完成，RX 还需要网络侧送包。运行中的整数 `set_param` 使用字面值；随机长度
使用 len_min/len_max，随机整数表达式可放在启动 plusargs 中。

独立发包流可调用 `register_tx_command("vio_tx0", "vio.tx0", why)` 注册别名。
同名命令由 AIP 检查 BUSY；同一 service 上允许 TX/TX 逐事务仲裁，控制/RX 命令
与其它命令互斥。取消后目标需要 reset，driver 已接收事务不会自动回滚。
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
