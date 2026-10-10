# 2 从正式测试入口认识对象树

## 2.1 阅读基准与第一条调用链

本章到第5章以提交 `e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c` 为准，路径均相对仓库根。主线是 `virtio_net_vip/tests/virtio_real_driver_flow_test.sv` 和同目录的 `virtio_real_driver_flow_fixture.sv`，默认执行模式 MODEL。这里的“真实驱动流程”表示调用生产 transport/atomic ops 并经过 PCIe 设备模型完成业务，不表示连接真实 RTL。

测试的 [build_phase（第36行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_test.sv#L36) 只有一个关键动作：创建 `flow` fixture。配置、外部子环境和 MODEL 附件由 fixture 的 [build_phase（第99行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L99) 继续创建。`type_id::create` 先构造对象；UVM 随后的 build 遍历才调用子组件的 `build_phase`，不能把两件事视为同一时刻。

默认一个 PF 的组件层次如下。方括号表示普通对象或借用句柄，不一定出现在 UVM component 拓扑打印中。

```text
uvm_test_top : virtio_real_driver_flow_test
└─ flow : virtio_real_driver_flow_fixture
   ├─ [device_builder / device_cfg / virtio_cfg / pcie_cfg]
   ├─ [host_mem_owners : host_mem_pool → Host 0 manager]
   ├─ device_env : dpu_device_env
   │  └─ virtio_env : virtio_net_env
   │     ├─ pf_0_0 : virtio_pf_instance
   │     │  ├─ [pf_manager / lifecycle_reset_owner]
   │     │  └─ pf_function : virtio_function_instance
   │     │     ├─ driver_agent → driver / sequencer / monitor / observer
   │     │     └─ [transport / vq_mgr / dataplane / resource_client]
   │     ├─ perf_mon
   │     ├─ scb（默认创建）；cov（默认关闭）
   │     └─ [iommu / wait_pol / barrier / err_inj / conc_ctrl / dyn_reconfig]
   ├─ pcie_env : pcie_tl_env（RC/EP agent）
   ├─ vdev0 : vdev_virtio_pci
   └─ [tlm_adapter / device_port / m_profile]
```

`pcie_env` 是 fixture 的子组件，与 `device_env` 同级，不是 `virtio_env` 创建或拥有的子组件。设备模型 `vdev0` 也在 fixture 下；Virtio 驱动和设备模型不能因名字相近就归为同一个对象。env 的 `function_instances[]`、`vf_instances[]` 是访问视图，其中句柄指向 PF 容器已经创建的 Function，不是另建一份 Function。

## 2.2 fixture 先准备什么，为什么必须在 env 之前

fixture 构造函数（第81行）把就绪位清零，设置 `vio_pf_count=1`、PCIe completion 超时100000ns、轮询超时1000ns，以及 `device_features=64'h0000_0001_0000_0001`，即默认 CSUM 与 VERSION_1。构造期没有 ring、DMA 映射或 PCIe 请求。

build 首先创建 `virtio_test_device_builder`，声明 Host 0/domain、PF、三类 BAR 和 VIO service，并提交总数为 `2 * vio_pf_count` 的固定 qpair 请求；第一个 PF 被选为 AF。`vio_pf_count` 为0或超过 DUT能力时立即 fatal。这里写的是控制面输入，最终 BDF、BAR和资源绑定必须等 DPU 发布快照后读取；fixture 没有用常量代替快照里的 BDF。

第133行创建 `virtio_cfg`。正式主线把队列对数设为2、ring大小256、格式 `VQ_SPLIT`、driver支持特性全1、RX模式 MERGEABLE、每队列 MSI-X、NAPI预算64，开启 scoreboard、关闭 coverage。Host GPA范围与IOVA范围是两套不同地址域：前者交给共享 Host allocator，后者在 env 内配置 IOMMU。之后 `apply_plusargs(why)` 解析模式覆盖，失败 fatal；`execution_profile()` 返回模式策略，非法编码可能使其为null，也会阻止继续构建。

第189行创建 `host_mem_owners`，调用 `create_host(host_id, mem_base, mem_end, MODE_BUDDY, DEFAULT_MIN_GRANULE, policy)` 建立唯一 Host backing。失败 fatal。相同池随后同时交给 `device_cfg.host_mem_pool_ref` 和 `virtio_cfg.host_mem_pool_binding`；PCIe配置通过 `bind_host_memory(0, host_id, root_mem, why)` 借用池中的同一个 manager，并发布 `dev_mem_0`。这解释了之后驱动写ring、设备DMA读ring为何能够看见相同字节，而无需在几个环境之间复制内存。

实际创建次序的短节选如下；它展示父对象和配置路径之间的一一对应关系。

```systemverilog
device_env = dpu_device_env::type_id::create("device_env", this);
uvm_config_db#(virtio_net_env_config)::set(
    this, "device_env.virtio_env", "cfg", virtio_cfg);
m_virtio_env = virtio_net_env::type_id::create(
    "virtio_env", device_env);
```

出处：fixture 第203～207行。配置发布目标是 `device_env.virtio_env`，不是 `flow.virtio_env`；排查“No virtio_net_env_config”时先核对完整层次。

## 2.3 execution profile 与 MODEL 附件

策略定义见 [virtio_execution_profile.sv](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_execution_profile.sv)。`virtio_net_env_config.execution_profile()`（配置文件第256行）委托 `virtio_select_execution_profile`，MODEL与REAL_DUT各创建一种无状态策略对象。fixture把结果保存在 `m_profile`。因此 execution profile 不属于 `virtio_net_env` 的成员；是配置接口生成、fixture保存并用于选择附件的对象。

| 选择结果 | MODEL主线的实际作用 | REAL_DUT对照边界 |
| --- | --- | --- |
| `has_model_device()` | 创建completion adapter、EP设备port及每PF一个vdev | 不创建设备模型 |
| `pcie_if_mode()` | 选择TLM连接模式 | 选择SV接口模式 |
| `ep_is_active()` / `ep_auto_response()` | EP active、自动应答配置启用 | EP passive、禁用自动应答 |
| `needs_physical_link()` | 不要求物理VIF | 要求独立RC→EP和EP→RC接口 |
| `supports_host_mem_responder()` | 不走REAL_DUT responder分支 | 允许可选RC Host-memory服务 |

MODEL分支在创建PCIe env前先调用 `tlm_adapter.install_factory_overrides()`，再把 `pcie_env.*` 中的 `pcie_tl_ep_driver` 覆盖为 `vdev_ep_driver`（fixture第212～217行）。顺序重要：若已经创建driver再安装覆盖，现有对象不会自动变成新类型。第253行创建PCIe env，第256行创建普通对象 `device_port`，随后创建 `devices[]` 里的组件。`host_mem_responder` 是REAL_DUT分支对象，MODEL默认为空；不能把它写成MODEL完成DMA的核心。

连接时 `device_port.connect_ep(ep_driver, ep_monitor, iommu, host_id, why)` 借用PCIe EP驱动、监控及Virtio环境IOMMU；设备初始化留到 `end_of_elaboration_phase`。后者取得冻结快照、AF身份、三个BAR和共享内存，再调用 `configure_devices(why)`（第1124行）：逐Function检查PCIe身份及BAR租约容量，设置vdev的BDF、最大pair数、queue上限、特性和错误注入引用，执行 `init()`，最后 `device_port.attach(devices[k])`。port/env/snapshot为空、模型数量不足、BAR租约过小或没有有效Function都会失败。这个连接把驱动一侧的IOVA翻译与设备一侧的DMA接到相同上下文。

# 3 virtio_net_env 的每个成员从哪里来

## 3.1 配置与权威快照：借用外部，创建本地只读上下文

env定义及完整成员从 [virtio_net_env.sv第40行](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_net_env.sv#L40) 开始。`new(name,parent)`（第87行）仅初始化 `configuration_valid=0`、`effective_dut_caps=null`、`snapshot_ctx=null` 和协议接口索引0。名称与父组件用于UVM层次注册，不构造业务组件。

| 成员 | 谁创建或发布 | env做什么／所有权 |
| --- | --- | --- |
| `cfg` | fixture创建，通过config_db发布 | build取得同一配置句柄；借用 |
| `device_snapshot`、`resource_snapshot` | DPU控制面发布 | 借用冻结对象，不重分配BDF/BAR/qpair |
| `device_resource_manager` | DPU控制面播种并发布 | 借用；须对应同一快照对 |
| `snapshot_ctx` | env调用`vio_snapshot_ctx::create_checked` | 本地创建包装对象；内部保存三者引用 |
| `effective_dut_caps` | `device_snapshot.snapshot_dut_caps()`返回 | 保存能力副本；对外再复制 |
| `configuration_valid` | env内部状态 | build/绑定失败的后续phase守卫，不是设备ready |
| `protocol_event_vif_index` | env内部计数 | 成功提交绑定后记录已用协议接口槽数 |

`build_phase(phase)`（第255行）由UVM调用，先get cfg、验证执行模式，然后读取三个DPU句柄。`vio_snapshot_ctx::create_checked(device_snapshot, resource_snapshot, manager, why)` 位于 [vio_snapshot_ctx.sv第23行](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/sriov/vio_snapshot_ctx.sv#L23)：device快照非空且冻结，resource快照非空、冻结且引用该device快照，manager非空、已播种且来自同一对快照，全部成立才创建上下文；任一不符返回null和why。env将null转为fatal并返回。

这不是仅比较版本号。两份内容看似相同但并非发布时配对的快照也不能随意替换。随后 `cfg.validate_against_snapshot(device_snapshot,why)` 检查行为配置和权威拓扑关系，读取DUT能力。`snapshot_effective_dut_caps()`（第235行）在未取得能力时返回null，否则新建副本并copy，调用方修改返回对象不会改动env持有的能力。

## 3.2 Host memory、IOMMU与共享策略

env build 第304～397行决定共享基础设施。`host_mem`有三条合法来源，只有第三条在env内创建allocator。正式fixture走第二条。

| 分支 | 输入与结果 | 真实拒绝条件 |
| --- | --- | --- |
| 注入manager | `cfg.host_mem_binding`直接赋给`host_mem` | manager的Host ID与cfg不一致 |
| 注入pool | 从`cfg.host_mem_pool_binding`或`dpu_host_mem_pool`取池，再`get_host(cfg.host_id)` | 类型错误、两处池不是同对象、Host缺失或返回manager不匹配 |
| 无注入 | 创建`host_mem_manager`，设置Host、分配策略、GPA范围 | 后续BAR导入等校验仍必须通过 |

直接manager和pool不能同时提供。BAR importer是 `build_phase` 局部对象 `bar_importer`，不在env成员表里；其 `import_snapshot(device_snapshot,host_mem,host_id,why)` 在任何ring分配前预留与GPA范围相交的BAR，重复导入允许幂等。导入失败使配置无效并fatal。

`iommu`始终由此env创建，设置 `strict_permission_check` 并调用 `configure_iova_aperture(iova_base,iova_limit,iova_alloc_policy,why)`。失败意味着IOVA配置不可用，不应继续建队列。要特别区分：共享Host内存池的manager由外部拥有，并不自动意味着每个业务env也共享同一IOMMU对象。此源码中IOMMU是在每个env创建，再借给其Function和MODEL设备端口。

`wait_pol`、`barrier`、`err_inj`是env创建的普通对象，之后同一批引用注入Function、queue manager和ops。等待策略管超时；barrier表达ring发布/读取顺序并统计；err_inj提供故障注入上下文。它们不是每条队列单独创建。transport构造时自己的默认wait policy会在提交绑定时被这个共享 `wait_pol` 替换。

## 3.3 PF、Function、VF数组并不是三套设备

`build_snapshot_topology(output why)`（env第98行）由build调用。先按完整service key得到VIO服务集合：空白名单表示全部VIO service；非空白名单精确选择。若启用Host scope，必须先向快照解析service owner，再根据 `owner.host_id` 筛选，不能按数组下标推断Host。

全局无VIO service且没有scope时返回失败；有显式scope而筛选为空时允许空PF/Function/VF数组成功，保留共享基础设施。每个选中service必须有resource snapshot中的qpair binding。然后把owner转换成父PF key，按Host/PF归组，创建 `pf_instances[]` 并调用每个PF的 `configure_services_ctx(parent_key,snapshot_ctx,grouped_services,why)`。

PF容器再创建PF Function和VF Function。env两次调用 `collect_functions(ref queue)`：第一次计算总数，第二次把已有句柄放入 `function_instances[]`；最后筛选 `function_kind==DPU_FUNCTION_VF` 并 `$cast` 到 `vf_instances[]`。cast失败报错并返回0。默认fixture只声明PF，故一个PF容器、一个PF Function、VF数组为空是正常结果。

`pf_mgr`是兼容别名：env connect中赋值为 `pf_instances[0].pf_manager`，不是env另建的全局PF控制器。每个PF容器原本各有自己的manager；阅读多PF代码时不可把 `env.pf_mgr` 当成覆盖所有PF的权威对象。

## 3.4 验证、性能、并发与动态重配置成员

| 成员 | 创建位置 | 连接及主线使用边界 |
| --- | --- | --- |
| `perf_mon` | env build第390行，无条件创建组件 | 复制带宽开关和Mbps；自身build初始化token bucket；本env未把它自动接到每个TX调用 |
| `scb` | env build，`cfg.scb_enable`为1才创建 | 每Function monitor的`txn_ap`接`scb.txn_imp` |
| `cov` | env build，`cfg.cov_enable`为1才创建 | `txn_ap`接`cov.analysis_imp`；golden默认不创建 |
| `conc_ctrl` | env build创建普通对象 | connect借用VF数组和wait policy；默认无VF，golden不发并发调度 |
| `dyn_reconfig` | env build创建普通对象 | `bind_device_snapshot(device_snapshot,why)`绑定冻结拓扑，失败fatal；golden不调用动态重配置 |
| `pcie_env_ref` | env只声明`uvm_object`字段 | 本文件正式流程没有给它赋值；实际PCIe借用从`bind_pcie`参数进入 |

scoreboard的 `new`（`src/env/virtio_scoreboard.sv:57`）清统计，`build_phase:67`创建 `txn_imp`；coverage的 `new`（`src/env/virtio_coverage.sv:247`）创建8类covergroup，`build_phase:263`创建analysis入口。perf的 `build_phase`（`src/env/virtio_perf_monitor.sv:55`）在限速开启且速率大于0时，以 `Mbps*125` 初始化1ms容量的bucket。这些对象“已经创建”并不等价于golden TX必然触发所有高级校验或性能采样；应继续追真实调用和analysis事件。

# 4 UVM phase 如何把对象变成可执行流程

## 4.1 build：先有拓扑身份，再有Function内部对象

UVM build是父向子展开。fixture先创建DPU父环境和Virtio子环境；Virtio env消费已发布快照，创建PF容器并立即配置service；PF配置又创建Function、写入身份。之后UVM才进入Function的 `build_phase`，创建 transport/queue manager等。因此 `configure_from_ctx()` 第一次执行时内部子对象可以尚未存在，这正是 `apply_function_configuration()` 有空句柄早返回，并在Function build尾再调用一次的原因。

PF容器的 [configure_services_ctx（第98行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/sriov/virtio_pf_instance.sv#L98) 接收父PF key、上下文和service队列，先校验：只能配置一次，父key必须PF且vf_id=0，manager有 `virtio.qpair`，manager与snapshot能力一致，服务非空且为VIO，owner属于同一PF组且不重复，PCIe身份、三个BAR角色、资源manager中的Function都能解析。通过后才创建manager和PF/VF子组件、导入资源池视图。失败返回0和why；全部前置检查前不创建子组件，但后续创建/导入阶段失败不是删除已经创建的UVM组件。

PF的 `build_phase:318` 要求已经配置service，给manager设pf_index；`connect_phase:334` 把本PF的VF数组、PF transport交给manager，创建 `lifecycle_reset_owner`，使Admin-VQ全复位委托到普通PF Function的生命周期。这个owner只是复位路由桥，不拥有ring资源。

## 4.2 connect：先装行为和analysis，再由fixture接PCIe

env的 [connect_phase（第433行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_net_env.sv#L433) 在配置无效时直接返回。正常情况为每个Function列出该service的qpair bindings，以数量作为 `allocated_qpairs`，调用 `cfg.get_service_config(service_key,allocated_qpairs,driver_cfg,why)`，把结果赋给 `function.drv_cfg`。配置对象内部有显式service覆盖时取覆盖，否则取默认；请求pair数会收缩到分配上限，`max_vio_net_qpairs_per_device`同步为该上限。binding为0或配置解析失败都会停止连接。

随后按service取 `private_cfg`，连接monitor analysis端口，给 `conc_ctrl` 与兼容PF manager传VF句柄。这里没有寄存器访问，也没有ring创建。标准golden没有private配置，所以之后选标准协议。

UVM connect为子向父执行。agent自己的connect可能早于fixture最终PCIe绑定，此时ops/FSM尚未创建并不奇怪。Function提交绑定会直接更新driver引用，agent还在 `start_of_simulation_phase` 再执行 `apply_component_bindings()`，并检查active driver是否已有ops/FSM。agent文件头“before build注入”的旧概括不足以描述这条正式路径，应按函数体和UVM遍历次序理解。

fixture的 `connect_phase:263` 检查PCIe RC/EP agent、monitor、RC sequencer后调用：

```systemverilog
m_virtio_env.bind_pcie(
    m_pcie_env.rc_agent.sequencer, tlm_adapter,
    m_pcie_env.rc_agent.monitor, m_pcie_env.ep_agent.monitor)
```

成功后仅置 `m_pcie_path_bound=1`，设备还未初始化。MODEL设备port随后接EP驱动和IOMMU；至end_of_elaboration完成设备配置后才置 `m_endpoint_ready=1`。`build_flow(output why)`（fixture第412行）是测试run调用的就绪检查函数，检查endpoint、冻结快照、PCIe通路和共享句柄，成功置 `m_flow_ready`。名字含build不表示它再次创建环境。

## 4.3 PCIe绑定的预检、提交与失败边界

[bind_pcie（env第514行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_net_env.sv#L514) 接受一个必需RC sequencer、可选completion adapter和两侧monitor。它把相同外部通路加入每Function的绑定计划；只能描述同一个PCIe domain，不能把一条sequencer广播给多个独立domain。空sequencer、身份未解析、跨domain或monitor的analysis port为空都会失败。多domain应调用 `bind_pcie_endpoints(endpoints)`，按完整 `{host,segment,BDF}` 选择，要求一个Function恰好一个有效endpoint，无重复身份、无多余endpoint，且transport身份匹配。

两入口都进入 `bind_all(plan,legacy_adapter)`（第704行）。应按下表的副作用边界阅读。

| 内部函数 | 输入／动作 | 失败含义 |
| --- | --- | --- |
| `preflight_plan:754` | 每Function预检observer、协议VIF、ops/FSM候选 | 拒绝两个Function共享同一VIF/FSM/ops运行态 |
| `resolve_protocol_vif:894` | 从`uvm_test_top`取`protocol_event_vif_<slot>`，或复用暂存VIF | 槽号达到DPU_MAX_FUNCTIONS、配置缺失/null则fatal |
| `preflight_function_pcie:923` | observer强制绑定预检，再Function预检；成功推进暂存槽号 | 缺driver agent/monitor/observer或预检失败返回0 |
| `validate_plan_adapters:799` | 只读检查adapter/domain/RC driver关系 | 同driver喂不同adapter、同domain对应不同driver、同driver跨domain均拒绝 |
| `commit_plan_adapters:849` | 每个adapter/domain组合绑定一次RC driver | 底层绑定失败返回0 |
| `bind_function_pcie:954` | 注入共享基础设施，提交observer，装协议VIF，连接两侧monitor | Function提交失败则当前绑定失败 |
| `abort_bind:743` | 清计划内Function的pending候选，置env无效 | 返回0；不是析构或复位整套已发布运行状态 |

重要边界：源码注释强调“原子”绑定；函数体保证全部Function预检通过前不逐个提交，并在失败时清候选。但 `abort_bind` 实现只有 `cancel_bind_pcie()` 和 `configuration_valid=0`，没有遍历断开已连接的analysis端口或撤销已提交的adapter。因此不能把它夸大成任意提交中途失败都能完全恢复历史状态的通用事务系统。文档按可观察实现说明，而不沿用超出实现的保证。

`bind_function_pcie` 最后把RC、EP monitor的 `tlp_ap` 接到本Function observer的analysis入口；若两个monitor是同对象只接一次。observer完成身份过滤和语义解码，monitor再发布Virtio事务。协议VIF槽由testbench预先创建，env只借用；如果顶部没有发布该VIF，即使MODEL PCIe本身不需要物理VIF，协议检查连接仍会失败。

## 4.4 run与report：env没有自动初始化线程

本基线的 `virtio_net_env` 没有 `run_phase` override；`virtio_driver.run_phase`（`src/agent/virtio_driver.sv:50`）永远等待sequencer事务，取到后处理并 `item_done()`。`VIO_TXN_INIT` 才会分派 `fsm.full_init()`。默认配置 `DRV_MODE_AUTO` 不能推导“run一开始自动full_init”。

正式golden测试的run先raise objection，再 `build_flow`、检查快照、通过resource client解析TX queue ID，随后 `start_driver_flow`、`setup_queue`、TX submit/complete、reset teardown，最后drop objection。fixture的 `start_driver_flow:736` 明确逐步调用生产atomic ops完成初始化，不调用full_init；这样ring只在 `setup_queue` 创建一次。该基线也没有fixture先设置 `DRIVER_MANUAL` 的代码。后续业务章节将沿这条实际调用链展开，FSM全自动初始化属于另一入口。

env的 `report_phase:997` 在配置无效时跳过；正常调用Host-memory、IOMMU和每Function queue manager的 `leak_check()`，再打印barrier统计。它检查但不替代reset teardown释放资源。scoreboard、coverage、perf自己的report由UVM分别调用。因而“测试结束会自动report”不能作为未完成设备复位也可安全释放DMA的理由。

# 5 Function内部：创建、身份应用、协议选择与延迟建队列

## 5.1 Function先保存身份，再创建独占对象

[virtio_function_instance.sv](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/sriov/virtio_function_instance.sv) 第16～54行区分三类成员。身份值包括function/service key、完整PCIe ID、BDF、kind、vf_index和BAR数组；外部引用包括resource manager、snapshot上下文、pcie_ctx_ref和共享mem/IOMMU/barrier/err_inj/wait_pol；本Function构造的对象包括driver agent、vq_mgr、dataplane、transport、resource client，以及绑定阶段选出的protocol/ops/FSM/backend。`pcie_ctx_ref`可选、由外部PCIe管理方拥有，当前PF创建路径未传它，默认null。

`configure_from_ctx(ctx,service_key,pcie_ctx=null)`（第150行）由PF容器调用。它根据service解析owner、PCIe ID和DEVICE_MEMORY/MAILBOX/MSIX三种BAR，检查manager确实包含Function，禁止已经绑定的Function改挂另一device/resource快照、service、manager或PCIe context。若resource client已经创建，先尝试绑定资源，再发布成员；成功返回1并调用 `apply_function_configuration()`。缺上下文、非VIO key、身份/BAR缺失或归属重绑都返回0并保留fatal诊断。

`build_phase:106` 的核心仅五次create：

```systemverilog
driver_agent = virtio_driver_agent::type_id::create("driver_agent", this);
vq_mgr = virtqueue_manager::type_id::create("vq_mgr");
dataplane = virtio_net_dataplane::type_id::create("dataplane");
transport = virtio_pci_transport::type_id::create("transport");
resource_client = virtio_resource_client::type_id::create("resource_client");
apply_function_configuration();
```

`apply_function_configuration:588` 要求transport/vq_mgr/resource_client存在且PCIe身份有效，否则早返回；正常把完整ID交给transport，把Host/BDF交给queue manager和数据面引擎，把BAR租约交给bar accessor。若resource client未绑定service，则绑定同一个snapshot_ctx/service，失败fatal；最后 `transport.configure_fabric_managed(resource_client)` 标明由Fabric资源视图管理。这里仍没有Host ring分配。

## 5.2 transport和agent的内部创建

transport的 [new（第79行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_pci_transport.sv#L79) 创建 `cap_mgr`、`bar`、`notify_mgr`、默认 `wait_pol` 和 `virtio_fabric_preconfigured_discovery`。cap manager和notify manager指向同一个bar accessor；初始queue数、特性为0，BDF为0，身份valid为0。bar上的RC sequencer在之后提交绑定才注入，所以“transport已构造”不代表能访问设备。

agent的 [build_phase（第55行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_driver_agent.sv#L55) 总会创建monitor和observer，只有 `UVM_ACTIVE` 才创建driver、sequencer。monitor保存解码后的事件及协议检查接口；observer接PCIe TLP再向monitor解释。agent并不在此函数创建ops/FSM，它们只是待注入成员。

`connect_phase`把active driver的seq_item_port接sequencer导出，并调用 `apply_component_bindings()`：非空ops/FSM/protocol传给driver，monitor缺少transport/vq_mgr时从ops补齐，复制协商特性视图，observer.monitor指向monitor。这个函数不分配资源、不启动事务。`start_of_simulation_phase`再次调用它；active driver缺ops/FSM报UVM_ERROR。这样可以处理父fixture晚于子agent执行connect的情况。

## 5.3 ops、FSM、protocol、backend何时真正出现

Function的 `preflight_bind_pcie(pcie_rc_seqr)`（第252行）首先清上一次pending，检查sequencer、agent、transport、vq_mgr及transport三个必需子对象。它从agent已有ops/FSM取候选，再调用 `prepare_driver_candidates(label,drv_cfg,ref ops,ref fsm)`（第73行）。标准主线 `private_cfg==null`，创建 `virtio_standard_driver_protocol`；私有配置非空才创建私有协议。不是全局factory覆盖所有Function的驱动语义。

基类协议的 [prepare_candidates（第40行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_driver_protocol.sv#L40) 仅在候选为null时创建通用FSM和atomic ops，create的context参数来自当前Function。已有候选允许复用，但env跨Function别名检查禁止共享运行态。Function拒绝factory返回null，并检查FSM能绑定当前qpair上限；成功保存pending对象并置 `pcie_bind_prepared=1`，尚未发布正式共享引用。

`commit_bind_pcie(hmem,iommu_mdl,bar_mdl,einj,wpol,pcie_rc_seqr)`（第323行）要求预检成功且pending ops/FSM非空，否则fatal返回0。它委托 `commit_validated_pcie_components`（第373行）进行如下装配。

| 接线目的 | 本次赋值或调用 | 为什么 |
| --- | --- | --- |
| 配置后端 | `select_config_backend(label)`创建common或private backend，再`bind_transport` | 协议和寄存器布局保持一致 |
| 协议提交 | `pending_protocol.bind_ops(ops,backend,driver_cfg,why)` | 标准要求common backend；私有配置在此冻结 |
| FSM上限 | `fsm.bind_mq_pair_limit(...)` | 初始化不能越过资源分配的pair能力 |
| queue manager | 传mem/IOMMU/barrier/err_inj/wait policy | 每条队列用同一共享基础设施 |
| transport | 传wait policy、RC sequencer；统一bar引用 | 配置访问/notify走真实PCIe通路 |
| ops | 传transport/vq_mgr/mem/IOMMU/wait policy | 一个ops集中拥有正常队列DMA生命周期 |
| dataplane | 协议安装，写Host/BDF，`bind_ops(ops)` | TX/RX engine借用同一个ops而非另做分配 |
| agent/driver/monitor | 发布ops/FSM/protocol及transport/vq_mgr | 事务驱动、手工ops和监控使用同一上下文 |

标准协议 `bind_ops`（protocol文件第108行）拒绝null后端以及不是 `virtio_common_cfg_backend` 的对象，成功设置 `ops.config_backend` 和 `ops.protocol`。Function还会检查协议提交和FSM上限绑定的返回值；失败清pending返回0。最终Function保存共享基础设施和正式protocol，再清pending引用。`cancel_bind_pcie`只是丢弃预检暂存，不会销毁已创建对象或释放Host-memory。

## 5.4 dataplane与queues：wrapper存在不等于ring存在

dataplane的 [new（第39行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/dataplane/virtio_net_dataplane.sv#L39) 创建TX engine、RX engine和offload engine。Function提交时直接注入共同offload、Host/BDF和ops，标准协议的 `install_dataplane`为空实现，保留默认引擎。当前Function没有调用dataplane的 `configure(features,mtu,mss,rx_mode,rx_buf_sz,rx_refill_thresh,bdf,host_id)`；不能仅因该API存在就说正式初始化已同步所有offload参数。golden TX直接调用ops，也没有绕经这个wrapper的TX engine。

`bind_ops(ops)`（dataplane第92行）只把同一handle放进两个engine；不检查null、不分配DMA，调用者必须在收发前准备好ops。`configure`若由其他上层调用，则同步特性、MTU/MSS、RX缓存参数和DMA身份到engine/offload，函数本身不返回成功标志。

queue manager的构造函数（`src/virtqueue/virtqueue_manager.sv:45`）不建任何queue。真正的 [create_queue(queue_id,queue_size,vq_type)（第63行）](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/virtqueue_manager.sv#L63) 按类型创建split/packed/custom队列，调用 `vq.setup(...,mem,iommu,barrier,err_inj,wait_pol,bdf,host_id)`，再登记 `queues[queue_id]`。重复ID报错但返回已有对象，不是返回null；未知类型才返回null。它是对象建立入口，后续atomic queue setup负责完整ring分配/映射/寄存器编程及失败处理，不能把manager的一次create当成队列已经在设备启用。

因此到PCIe connect成功时，应该看到可用的资源client、transport、driver agent、ops/FSM和空queue manager。到测试 `setup_queue` 成功后才有具体queue及ring资源。到TX完成后释放的是该报文的DMA资源；整条queue直到verified reset/teardown才退役。这个时间顺序是后续章节理解“谁申请、谁映射、谁通知、谁回收”的基础。

## 5.5 本组章节函数导航

下面位置均在固定SHA的 `virtio_net_vip/` 下；上文同文件GitHub链接可直接定位，行号是函数定义行或紧邻入口。表中列出本组装配主线的导航，不替代正文中的参数和失败解释。

| 文件与入口 | 调用者 | 阅读目的 |
| --- | --- | --- |
| `tests/virtio_real_driver_flow_test.sv:36 build_phase` | UVM | 唯一fixture创建入口 |
| `tests/virtio_real_driver_flow_fixture.sv:99 build_phase` | UVM | 配置、共享池、DPU/Virtio/PCIe/MODEL附件创建 |
| 同文件`:263 connect_phase`、`:307 end_of_elaboration_phase` | UVM | 接外部PCIe；解析快照、初始化设备 |
| 同文件`:412 build_flow` | test.run_phase | 检查就绪，发布flow_ready |
| 同文件`:736 start_driver_flow` | test.run_phase | 逐步生产ops初始化，不调用full_init |
| 同文件`:1124 configure_devices` | fixture.end_of_elaboration | 快照身份/租约转为MODEL配置 |
| `src/env/virtio_net_env_config.sv:197 make_default_driver_config`、`:339 get_service_config` | env.connect | 从service资源上限派生行为 |
| `src/env/virtio_net_env.sv:87 new`、`:255 build_phase` | factory/UVM | 建基础设施和snapshot拓扑 |
| 同文件`:98 build_snapshot_topology` | env.build | PF分组，Function/VF只读访问视图 |
| 同文件`:235 snapshot_effective_dut_caps` | 外部读者 | 返回能力防御性副本 |
| 同文件`:433 connect_phase` | UVM | 行为和analysis接线 |
| 同文件`:514 bind_pcie`、`:580 bind_pcie_endpoints` | fixture/集成环境 | 单domain通路或按完整ID选择endpoint |
| 同文件`:704 bind_all`、`:743 abort_bind` | 两个绑定入口 | 统一预检、提交、pending清理 |
| 同文件`:754 preflight_plan`、`:799 validate_plan_adapters` | bind_all | 跨Function运行态与adapter拓扑检查 |
| 同文件`:849 commit_plan_adapters`、`:954 bind_function_pcie` | bind_all | 外部PCIe/observer/协议VIF装配 |
| 同文件`:997 report_phase` | UVM | leak检查和barrier统计 |
| `src/sriov/vio_snapshot_ctx.sv:23 create_checked` | env/PF独立入口 | 校验冻结对与manager同源 |
| `src/sriov/virtio_pf_instance.sv:98 configure_services_ctx` | env.build_snapshot_topology | 验证组并创建PF/VF |
| 同文件`:306 collect_functions`、`:318 build_phase`、`:334 connect_phase` | env/UVM | 视图收集、manager、reset owner |
| `src/sriov/virtio_function_instance.sv:150 configure_from_ctx`、`:588 apply_function_configuration` | PF配置/Function.build | 身份、BAR、resource client安装 |
| 同文件`:106 build_phase` | UVM | Function五类独占对象创建 |
| 同文件`:73 prepare_driver_candidates`、`:252 preflight_bind_pcie` | env.preflight | 选择协议、准备ops/FSM候选 |
| 同文件`:323 commit_bind_pcie`、`:373 commit_validated_pcie_components` | env.bind_function_pcie | 发布共享依赖和正式驱动对象 |
| 同文件`:363 select_config_backend` | Function提交内部 | 创建协议对应寄存器后端 |
| `src/agent/virtio_driver_protocol.sv:40 prepare_candidates` | Function预检 | 懒创建通用ops/FSM |
| `src/agent/virtio_driver_agent.sv:55 build_phase` | UVM | active/passive组件边界 |
| `src/transport/virtio_pci_transport.sv:79 new` | Function.build | cap/bar/notify/default策略创建 |
| `src/dataplane/virtio_net_dataplane.sv:39 new`、`:92 bind_ops` | Function build/提交 | engine创建及共同ops注入 |
| `src/virtqueue/virtqueue_manager.sv:63 create_queue` | atomic queue setup | 延迟创建具体队列对象 |
