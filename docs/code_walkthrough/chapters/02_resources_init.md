# 6 从冻结资源到本 Function 的队列身份

## 6.1 先固定本章的运行实例

本章延续 `virtio_real_driver_flow_test` 的正式 MODEL 路径。测试创建 `flow`，在 run phase 先检查 `build_flow(why)`，从 placement 查询 pair 0 的 TX 队列号，调用 `start_driver_flow(ok)`，然后执行 `setup_queue(tx_queue_id, 256, VQ_SPLIT, ok)`。其后才提交一份 16 字节 payload。初始化阶段并没有构造一个 sequence transaction，也没有调用 `fsm.full_init()`。配置里的 `DRV_MODE_AUTO` 不是自动发生初始化的证据。

阅读入口：[golden test，L46](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_test.sv#L46)、[fixture 初始化，L736](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L736)。后面提到完整 FSM，是解释同一批底层接口的另一条调用路径，不能把两条路径拼成一次运行。

| 本次实例的参数 | 实际来源 | 本次含义 |
|---|---|---|
| Host 0、一个 VIO PF | fixture 构造默认值与 builder 请求 | 首个 PF 被选为 AF；BDF 仍由冻结 snapshot 提供 |
| 每 PF 两对 qpair | builder 的固定 VIO 资源请求 | 资源已预留，不代表设备已接受两对 active queues |
| `num_queue_pairs=2` | fixture 默认行为，经 service 配置按分配数限制 | 用于容量检查与向量规划 |
| `queue_size=256`、`VQ_SPLIT` | fixture 默认值；测试建队时再次明确传参 | golden 实际只建立 pair 0 的 TX 队列 |
| driver feature mask 全 1 | `default_driver_features` | 表示驱动愿意取设备声明位，不是所有特性都已启用 |
| device features `0x0000000100000001` | fixture 的 `device_features`，注入 MODEL device | 只有 CSUM 与 VERSION_1 |
| GPA 随机分配、IOVA 随机分配 | `HOST_MEM_RANDOM`、`IOMMU_IOVA_RANDOM` | 地址例子必须用符号或运行日志，不能假定顺序连续 |

因此本次没有协商 PACKED、MQ、CTRL_VQ、MRG_RXBUF、EVENT_IDX 或 NOTIFICATION_DATA。`default_rx_mode=RX_MODE_MERGEABLE` 是行为配置字段，不能覆盖设备 feature 寄存器。不要据此给 golden 画出 mergeable RX 或 packed ring。

## 6.2 谁决定 BDF、BAR 和 qpair

`dpu_common` 负责设备/资源快照，Virtio 消费冻结结果。fixture 的 `end_of_elaboration_phase` 取得 `device_snapshot` 和 `resource_snapshot`，要求两者 frozen，查询 `get_expected_af` 得到 Function key，再用 `get_pcie_id` 得到 PCIe identity。它按 BDF 查找 `function_instances`，不是把数组第 0 项当成身份权威；随后 `list_bars` 必须得到三对 BAR。

`snapshot_is_frozen()` 还验证 resource snapshot 确实引用这一份 device snapshot。这里的“同一对”是对象关系，不是“字段看起来相似”。`build_flow` 检查的是已经接好的环境和 readiness，不能拿它当成分配 BDF、写 BAR 或完成设备初始化的函数。

`virtio_resource_client::bind_to_service(device_snapshot, resource_snapshot, service_key, why)` 是直接绑定入口；生产路径通过已经验证的 `vio_snapshot_ctx` 调用 `bind_to_ctx`。两者最后进入 `bind_validated`：service 必须为 `DPU_SERVICE_VIO_NET`，其 owner 必须与 service 的 Function key 一致，且资源快照至少含一条该 service 的 qpair binding。它逐条复制 placement 结果并按 `local_pair` 排序，再一次性提交内部映射。

每条映射保存 `virtio_pair_index`、`local_pair`、RX/TX 的 local virtqueue ID，以及 global qpair ID。关键关系是 **RX 和 TX 共用一个 global qpair ID**。global ID 标识 DPU 内部那一对资源；local virtqueue ID 才区分 Function 内收发方向。禁止将 global ID 乘二生成 RX/TX 队列号，也不能把 sorted array index、local pair 和协议 pair index 混为一个编号。

fixture 的 `tx_queue_id_for_pair(0, tx_queue_id, why)` 导出排序后的映射，检查索引范围，再返回该项的 `tx_virtqueue_id`。默认标准布局是 RX0/TX1、RX2/TX3，但测试仍使用映射查询。这个做法使 placement 更换 local 编号后，测试不必偷偷承担重新分配资源的职责。

绑定有明确生命周期：同一个 snapshot 对和同一个 service 的重绑返回成功；改绑到另一对快照或另一 service 被拒绝。`reset_runtime_state` 只清运行就绪，不释放 placement 所有权。`mark_runtime_ready` 表示绑定后的运行准备状态，不等价于 `DRIVER_OK`，更不等价于所有 ring 都已建立。

源码：[resource client，L35](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/sriov/virtio_resource_client.sv#L35)、[映射导出与就绪，L156](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/sriov/virtio_resource_client.sv#L156)、[TX 队列查询，L537](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L537)。

## 6.3 资源配置与驱动行为配置不是同一张表

`virtio_net_env::connect_phase` 为每个 Function 调用 `resource_snapshot.list_vio_bindings_for_service`，取实际 binding 条数为 `allocated_qpairs`。零条直接 fatal。随后调用 `cfg.get_service_config(service_key, allocated_qpairs, driver_cfg, why)`，将结果交给该 Function 的 `drv_cfg`。

`get_service_config` 优先使用显式 service 配置；没有覆盖时调用 `make_default_driver_config(max_pairs)`。默认的 num pairs 被实际分配上限截断，显式配置超出分配数也被截断，`max_vio_net_qpairs_per_device` 写入该 service 的可用上限。queue size、ring type、feature mask、RX 行为、IRQ 模式、NAPI budget 等才来自 Virtio 环境默认值。因此“配置要求两对”是驱动愿望，“placement 分了几对”是可用资源，设备的 `num_queues` 又是后面通过寄存器读到的能力，三者需要分别核对。

本次 fixture 覆盖 `default_num_pairs=2`，设备模型 `max_pairs` 也取这个值，`queue_max=256`，但模型的 feature mask 是独立字段；不能因为模型暴露四条数据队列，就自动得到 MQ feature。只有控制队列命令成功，才能把标准设备 active pairs 从复位后的默认一对改成多对。

私有 service 配置存在时，`get_service_config` 会验证它，将队列格式设为 `VQ_CUSTOM`、中断设为 polling、driver features 清零，并采用私有 RX 容量；没有显式 service 行为覆盖时才采用私有默认 ring 深度。这是按 Function 选择的协议，不是把标准 split 的类名替换为 custom 就完成适配。

源码：[环境按资源解析行为，L433](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_net_env.sv#L433)、[默认行为生成，L197](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_net_env_config.sv#L197)、[service 覆盖，L339](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_net_env_config.sv#L339)。

# 7 Transport 接通以后，怎样发现设备并完成协商

## 7.1 接通对象不是完成寄存器初始化

Function 的 `apply_function_configuration` 把 snapshot 的完整 PCIe identity 交给 transport，设置 VF 属性，把同一 host/BDF 注入 queue manager 和数据面 engine，再导入 BAR leases 与 resource client。`commit_validated_pcie_components` 把共享 Host memory、IOMMU、barrier、错误注入和 wait policy 接到 manager；把 transport、manager、memory、IOMMU 接到 ops；再让 FSM 引用同一个 ops 和 driver config。PCIe RC sequencer 是借用的外部传输入口。

这个连接步骤没有分配 ring，也没有生成 DMA 完成。标准协议绑定 `virtio_common_cfg_backend`；私有协议绑定自己的 backend。上层 ops 因而可以保持“复位、协商、建队”等动作名称，而寄存器契约由 backend 决定。preflight/commit 的分离用于避免一个 Function 验证失败后，环境留下半套已经可运行的连接。

源码：[连接提交，L373](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/sriov/virtio_function_instance.sv#L373)、[身份应用，L588](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/sriov/virtio_function_instance.sv#L588)。

## 7.2 从 Fabric BAR 租约到 capability 中的实际窗口

golden 的 `start_driver_flow` 先等待 protocol event interface 退出平台复位，然后调用 `transport.discover_and_init_bars()`。入口委托 `virtio_fabric_preconfigured_discovery::discover`，而不是重新枚举和分配全局 BAR 空间。

发现策略首先要求 Function 已受 Fabric 管理、BAR role layout 已激活、resource client 非空。随后将 requester identity 及 bar 引用接好，经配置事务 `program_fabric_bar_pairs()` 写三对 64 位 BAR；再读改写 PCI Command，把 Memory Space Enable 与 Bus Master Enable 置 1。BAR 已经有地址，不等于设备已经允许 MMIO、DMA 和 MSI-X：Command 位就是这个差别。

`cap_mgr.discover_capabilities()` 从配置空间 0x34 的 capability pointer 开始，按链表读配置 DWORD。它屏蔽指针低两位，识别 vendor-specific Virtio capability 与 MSI-X capability，最多走 48 项；达到上限报告可能存在环。Virtio capability 提供 `cfg_type`、BAR 编号、offset、length，notify capability 还带 multiplier。这里通过 PCIe 配置读得到的内容由设备模型回答，不是 fixture 把 cap manager 的 found 标志直接设为成功。

随后 `capabilities_use_fabric_windows` 核对角色：common/ISR/device/pci-config capability 应落在 device-memory BAR；notify 应落在 mailbox BAR；若有 MSI-X，其 table BIR 应落在 MSI-X BAR。common、notify、ISR 是必须发现的。角色错误或缺失会 fatal，不能继续用默认 offset 访问寄存器。成功后设置 `fabric_capability_discovered` 并让 resource client `mark_runtime_ready`。

需要区分两个层次：快照提供“这对 BAR 被授权放在哪儿、承担什么角色”；capability 说明“设备在该 BAR 内的哪个 offset 提供哪一种接口”。两者结合才能形成 MMIO 地址。notify 地址同样不能简单写成 `BAR + queue_id*4`，其公式是 `BAR_base + notify_cap.offset + queue_notify_off*notify_off_multiplier`。

源码：[发现策略，L97](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_discovery_strategy.sv#L97)、[capability walk，L116](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_pci_cap_manager.sv#L116)、[MSE/BME，L760](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_pci_transport.sv#L760)。

## 7.3 status、feature mask 和失败返回

发现之后，fixture 调用 `ops.device_reset_verified(step_ok)`。它通过 backend 确认设备 status 回到 0，确认后才回收上一生命周期的队列/DMA；超时不能当作已停止 DMA。失败时 fixture 返回 `ok=0`，不会继续写 ACKNOWLEDGE。

随后依次执行 `set_acknowledge()`、`set_driver()`、`negotiate_features(driver_cfg.driver_features, negotiated)`、`set_features_ok(step_ok)`。标准 backend 最终进入 transport：先写 DFSELECT=0/1 分别读两个 32 位 device feature 窗口，得到 64 位 `dev_feat`；计算 `negotiated = dev_feat & driver_supported`；再通过 GFSELECT=0/1 写低/高半部。transport 缓存 device/driver features，并更新 `notification_data_enable`；ops 也保存 `negotiated_features`，后面的 header 长度和控制队列判断使用它。

`FEATURES_OK` 必须写后读回，设备清掉该位就是拒绝。fixture 此时调用 `set_failed` 并退出。本次全 1 的驱动 mask 与模型的 CSUM|VERSION_1 相交，仍然只有这两位。队列类型是显式配置参数，`virtqueue_manager` 并不会从 feature 位自动挑选 split 或 packed。因此设计新的 packed 测试时，需要同时保证设备广告、驱动协商结果和队列类型一致，不能只改一个 enum。

fixture 接着读取 `num_queues`，计算 `2*num_queue_pairs`，若协商 CTRL_VQ 再加一；所需数超过设备能力则写 FAILED 并退出。本次检查四条队列容量，但并未在这里创建四个 ring。它先 `setup_msix(4)`，再写 DRIVER_OK 并回读确认；最后把共享 FSM 的只读生命周期视图置为 `FSM_READY`，设置 `m_driver_flow_started=1`。

正常 status 累加可读作 `0 → ACKNOWLEDGE → ACKNOWLEDGE|DRIVER → 加 FEATURES_OK → 加 DRIVER_OK`。不要用 FSM_READY 替代设备 status 的证据：fixture 已显式回读 DRIVER_OK，但其设置 FSM_READY 不会自动创建队列、启动 background worker，亦不会替设备写 used ring。

源码：[verified reset 与 status，L14](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh#L14)、[特性交集，L321](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_pci_transport.sv#L321)。

## 7.4 与 full_init 的对照：不是同一次调用

`virtio_auto_fsm::full_init()` 是批量生命周期入口。它先拒绝 unknown、零或超出 Function 上限的 queue-pair 数；`do_full_init` 推进 DISCOVERING、NEGOTIATING、MSIX_SETUP、QUEUE_SETUP。与 fixture 最大差别是，它调用 `setup_all_queues(active_num_pairs, queue_format(), queue_size, setup_ok)`，成功后才写 DRIVER_OK 并进入 READY；fixture 则先完成 status/MSI-X，再由测试显式建一条 TX 队列。

复位失败处理也不能混为同一保证：[do_full_init 的 reset 分支，L281](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_auto_fsm.sv#L281) 仅对 `protocol.requires_verified_reset()` 为真的协议立即检查 reset_ok，失败进入 FSM_ERROR 并返回；标准协议调用 `ops.device_reset()`，该包装不把确认结果传回 FSM，随后仍进入 ACKNOWLEDGE/DRIVER 步骤。fixture 则始终显式调用 verified 接口并检查结果。因此 fixture 的“reset 失败立即退出”不能推广为本基线标准 full_init 的同等保证。

`setup_all_queues` 通过 `setup_queue_range` 建 RX/TX 成对队列，按协商结果额外建立 control VQ。CTRL_VQ 存在而 MQ 未协商时，多于一对会与标准 control queue 布局冲突，因此在建队前拒绝。批量失败会尝试回滚本次已建队列；若标准设备未协商 RING_RESET，或单队停队不能确认，会升级为 verified Function reset，影响整个 Function。Function reset 也失败时，保留未能安全停止的资源并置 recovery pending，不能保证失败后一定全部释放。

MQ 的 `active_num_pairs` 还表示 Host 预建的目标拓扑，不能孤立解释为设备已接受值。多对标准队列建好后 `mq_pairs_committed` 仍为假，必须经过 `configure_mq` 的 control 命令确认。`start_dataplane` 会拒绝未提交的目标。这就是“预留两对资源”“预建两对 ring”“设备 active_pairs=2”三个状态的实际代码分界。golden 默认没有 MQ，本章不把该测试说成已经证明多队列启用。

源码：[full_init，L228](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_auto_fsm.sv#L228)、[start_dataplane 门槛，L357](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_auto_fsm.sv#L357)。

# 8 建立 ring：对象、Host GPA 与设备 IOVA

## 8.1 setup_queue 才是 ring 的分配入口

测试的 `flow.setup_queue(tx_queue_id, 256, VQ_SPLIT, ok)` 先要求 flow 已启动且 Function 上下文完整，再调用生产 `ops.setup_queue`。fixture 没有自己分配 descriptor，更没有预先放一个完成条目。ops 初始 `ok=0`，先拒绝 recovery pending、缺失 transport/manager/IOMMU/memory，以及重复 queue ID；重复检查发生在查询设备与分配内存之前，避免覆盖旧 ring 所有权。

标准 backend 选择 queue ID 并读取 Q_SIZE 上限。请求 0 表示采用设备上限；超过上限则警告并裁剪；有效大小为 0 则失败。本次请求和模型上限都是 256。接着 manager 按 enum 创建 `split_virtqueue`、`packed_virtqueue` 或 `custom_virtqueue`，调用其 `setup` 注入共享对象和 host/BDF，登记到 `queues[queue_id]`。manager 此时只创建对象，并未调用 `alloc_rings`。

ops 验证队列 host 与 transport 的冻结 DMA host 一致，生成 `virtio_queue_program_t`，填 host、BDF、queue ID、有效大小、格式、local ID 与方向，再让 backend `prepare_queue` 补充协议信息。私有 backend 在这里配置方向、local qid、RX 容量与 doorbell。通过后才调用 `vq.alloc_rings()`。

manager 的 `create_queue` 单独遇到重复 ID 会报错并返回旧对象；正式 ops 则提前拒绝，不能把 manager 的行为当成“setup_queue 幂等成功”。创建失败返回 null，域不一致或 prepare 拒绝时销毁新对象，调用方仍得到失败。

源码：[生产建队入口，L15](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_queue.svh#L15)、[manager 工厂，L63](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/virtqueue_manager.sv#L63)。

## 8.2 split 256 的三块布局

`split_virtqueue::alloc_rings()` 向共享 Host memory manager 做三次分配。下表是源码要求的逻辑字节数与对齐；底层 buddy allocator 的实际保留粒度可以更大，不能把逻辑长度当成物理分配器占用统计。

| 区域 | 大小公式 | N=256 | 对齐 | 后续写者 |
|---|---|---:|---:|---|
| descriptor table | 16N | 4096 B | 4096 B | 驱动发布 addr/len/flags/next |
| available ring | 6+2N | 518 B | 2 B | 驱动发布 head 与 avail index |
| used ring | 6+8N | 2054 B | 4096 B | 设备发布完成 id/len 与 used index |

descriptor 项按小端存储 64 位地址、32 位长度、16 位 flags、16 位 next。avail 包含 flags、idx、N 个 16 位 head 和末端 event 字段；used 包含 flags、idx、N 个 `{id,len}` 以及末端 event 字段。源码无论本次是否协商 EVENT_IDX 都预留这些尾部字节，所以公式中的常数是 6。

三块成功后清零，然后为 descriptor 的空闲链填写 next；`free_head=0`、`num_free=256`、`avail_idx=0`、`last_used_idx=0`，状态进入 `VQ_CONFIGURE`。此时初始化 used 区为零是 Host 在交付之前准备内存，不是测试伪造设备完成；后续非零 used 完成仍必须来自设备 DMA。

由于 Host 分配策略随机，不画“desc 后面紧接 avail 后面紧接 used”的假连续布局。应把它们命名为 `G_desc`、`G_avail`、`G_used`，分别记录 GPA、大小和对齐。请求失败用全 1 地址标识。这里有一处阅读限制：split/packed 的 `alloc_rings` 只报告错误，没有 success 返回值；其 `get_ring_regions` 仍按成员地址返回固定数量的区域。因此不能仅凭 ops 的“空区域列表检查”就声称标准 ring 的分配失败已被完整拦截；golden 的成功路径并未覆盖内存耗尽故障。

源码：[split 分配，L117](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/split_virtqueue.sv#L117)。

## 8.3 GPA 与 IOVA 分开追踪

GPA 是共享 Host memory backing 的地址，Host 侧 `mem_write/mem_read` 使用它。IOVA 是设备 DMA 和 descriptor 中使用的地址，由 IOMMU 在 host/BDF 域内映射；BAR 地址则是寄存器访问窗口。这三种地址即使数值偶然相同，也不是同一种资源。

fixture 的 GPA aperture 为 `0x0000000100000000..0x00000001ffffffff`；默认 IOVA aperture 独立配置为 `[0x0000000080000000, 0xfffffffffffff000)`。`iommu_strict=1` 启用权限检查。binding 给 PCIe Host memory 路径的 manager 与驱动分配 ring 的 manager 相同，因此设备经 IOMMU 翻译后的 DMA 落到同一份 backing，不存在一个“驱动内存副本”和另一个“设备内存副本”。

ops 调用 `get_ring_regions(region_gpas, region_sizes)`，逐区 `map_for_host(transport.iommu_host_id(), transport.bdf, GPA, size, DMA_BIDIRECTIONAL)`。ring 使用双向权限，是这一实现对整个 ring 区的统一映射策略；普通 TX payload 与 RX buffer 的权限在数据面另外指定。mapping 返回 0 或全 1 算失败，已成功映射的部分会 unmap，随后销毁队列并释放 ring。

成功后 `ring_iovas[queue_id]` 记录映射所有权，`ring_iova_of` 按“所在 region 的 IOVA + 区内偏移”计算 desc/driver/device 三个设备地址。此时写寄存器用的是 `I_desc/I_avail/I_used`，不是 `G_desc/G_avail/G_used`。ring 对象负责 Host 分配的释放，ops 负责对应 IOVA 的撤销；reset/teardown 必须先确认设备不再 DMA，再共同回收。

源码：[地址域默认值，L71](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_net_env_config.sv#L71)、[IOMMU 映射，L178](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/iommu/virtio_iommu_model.sv#L178)。

## 8.4 packed 与 DPU 私有 ring 的边界

packed 仍是标准 Virtio 格式。`packed_virtqueue::alloc_rings` 一次申请 `16N+8` 字节、4096 对齐的连续 Host 块：前面是描述符，后面是各 4 字节 driver event 和 device event。N=256 时逻辑大小 4104 B。它把 `driver_ring_addr/device_ring_addr` 指向两个 event 结构，初始化 avail/used wrap 都为 1，index 为 0。它没有 split 的两个独立 head/index ring；描述符通过 AVAIL/USED 位和 wrap 表达归属。

虽然 packed 只做一次 Host 分配，其 `get_ring_regions` 明确返回三个映射区域：`16N`、4、4。不要据物理连续性擅自推导 event IOVA 等于 descriptor IOVA 加长度；当前 ops 按三个区域各做一次映射并编程三个地址。释放 Host 块一次，与撤销三个映射，是两个不同粒度的动作。

`VQ_CUSTOM` 对应 DPU 私有协议，不属于标准 packed 的别名。custom ring 同时包含私有 descriptor 与 CQ：TX 用 `16N+2` 的有效字节，RX 用 `32N`，再向上取整到 4096 分配。ops 对显式私有深度要求 2..4096 且为 2 的幂；custom 分配还要求 local qid 不超过 255，禁止重复分配，并冻结方向、local ID 与大小。它预留一个槽，空闲上限为 N-1；标准 split 的 256 个空闲 descriptor 不能直接照搬成 custom 可提交 256 项。

私有协议通过独立 backend 编程 VTX/VRX 等寄存器和私有 doorbell，无标准 feature 协商、无 Virtio-net header，完成方式为 polling。golden fixture 的标准 status/capability 路径不能未经调整就作为私有协议教程；私有实例应从 `examples/dpu_priv_ring` 的独立测试阅读。

源码：[packed 分配，L155](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/packed_virtqueue.sv#L155)、[packed 映射区域，L575](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/packed_virtqueue.sv#L575)、[custom 分配，L206](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/custom_virtqueue.sv#L206)。

# 9 把队列发布给设备：寄存器、通知、中断与 RX 预填

## 9.1 队列 enable 是发布边界

映射完成后，ops 从 notify manager 获取该 queue ID 的 MSI-X vector；初始化已规划的向量直接复用，后续新队列可动态分配。返回 `0xffff` 表示无可用向量，此时撤销本次映射、删除记录并销毁队列。随后将三个 IOVA、ring 总字节和 vector 填入 `qprog`，调用 backend 的 `configure_queue` 和 `enable_queue`。

标准 `virtio_common_cfg_backend::configure_queue` 进入 `transport.setup_single_queue`，顺序是选择 queue、写 size、写 descriptor/driver/device 64 位地址、写并回读队列 MSI-X 映射、读取 queue_notify_off、最后写 queue_enable=1。这个顺序确保设备拿到 enable 时，地址和向量都已经准备。设备拒绝 vector 时，notify manager 记录实际读回的 NO_VECTOR，不能只保留“驱动想写的向量”。

标准 backend 的 enable 操作本身不再发 TLP，因为 configure 的末尾已经 enable。它也没有通用的配置失败返回通道：`configure_queue` 调完 transport 后置 `ok=1`；底层寄存器错误由 transport 的报告体现。fixture 因此额外选择该队列并读 queue_enable，发现未使能就把自身 `ok` 清零。文档不能把这一层的 success 描述成“逐个地址和所有硬件字段都已完整回读验证”。

ops 成功后保存 `queue_programs[queue_id]`，设置 `vq.state=VQ_ENABLED` 与 `queue_enable=1`。这些是 Host 侧记录；设备模型是通过真正收到的 common-config 写建立设备侧队列状态。后面设备读 descriptor 时，依赖的是寄存器中的 IOVA 与 IOMMU 翻译，并不直接拿 manager 内的 SV 队列句柄读取完成状态。

源码：[标准 backend，L184](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_config_backend.sv#L184)、[寄存器发布，L694](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_pci_transport.sv#L694)、[fixture 回读，L830](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L830)。

## 9.2 MSI-X 表、queue vector 与 notify 是三件事

`ops.setup_msix(num_queues)` 仅在 manager 已有队列数恰好等于 num_queues 时使用实际队列 ID；数量不等时（包括尚未建队或只建了一部分），根据目标数量生成 ID 集合，存在 control VQ 时单独计算其位置。backend 检查 MSI-X capability，初始化表、分配中断向量、绑定 config vector 与每队列 vector、解除 mask，并在 PCI 配置空间置 MSI-X Enable、清 Function Mask。资源不足时通知管理器可以退为共享 MSI-X 或 INTx；无 MSI-X capability 时也退为 INTx。因此 `IRQ_MSIX_PER_QUEUE` 是请求/默认策略，运行时实际模式仍需看 manager 的结果。

队列 kick 是 Host→设备的通知写，MSI-X 是设备→Host 的完成/事件通知，不能因为名字里都有 notification 就把二者当一条总线动作。golden 默认未协商 NOTIFICATION_DATA，`transport.kick` 写 2 字节 queue ID；协商后才写 4 字节，其中 split 包含 next avail index，packed 还带 wrap。地址使用第 7 章的 capability 公式，`queue_notify_off` 来自设备读回。未建队导致 offset 数组越界时，kick 报错并返回。

queue enable 自身不是提交包；它只是让设备认识 ring。TX 的后续 `add_buf` 发布 descriptor/avail，再按 suppression 决定 kick；设备自行读取 ring、搬运数据、发布 used、发中断。测试不能用一次 notify 写的发生代替 DMA/used/MSI-X 整条路径成功的证据。

源码：[MSI-X 规划，L326](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh#L326)、[标准 MSI-X 配置，L211](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_config_backend.sv#L211)、[kick，L647](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_pci_transport.sv#L647)。

## 9.3 DRIVER_OK 之后谁预填 RX

golden TX 测试到此只有一条 TX ring，不会自动补 RX。独立 RX 测试会建立 RX 队列，先把四帧注入 MODEL 网络侧，再显式 `refill_rx(queue_id, 4, ok)`；这是另一次测试运行，不是 golden TX 的下一步。

完整 FSM 路径则在 `full_init` 成功后进入 READY；只有显式 `start_dataplane()` 才检查 MQ commit 与前一代 worker 退出情况，转 RUNNING，为每个偶数 RX 队列调用 `ops.rx_refill(rx_qid, drv_cfg.queue_size)`，然后启动背景补充、完成和中断等 worker。因此 RX 预填不属于 `full_init` 的 ring 建立阶段。

`rx_refill(queue_id, num_bufs, buf_size=0)` 从 manager 取队列，用 `vq.net_hdr_bytes(negotiated_features)` 决定 header 长度；容量优先采用显式非零 buf_size，其次采用 backend 给队列的 RX 容量，两者都为 0 才退到 header+1514。DMA 分配大小向 4 字节取整，descriptor 长度仍是可用容量。每个 buffer 分配 Host GPA、清零，以 `DMA_FROM_DEVICE` 映射 IOVA，创建一段 device-writable SG，经 `vq.add_buf(sgs, 0, 1, null, 0)` 发布。成功后所有权转入 `rx_dma_map`，供 RX 完成或 reset 回收；有提交且需要通知时才 kick。

队列满、内存不足、映射失败或 add_buf 失败都会使循环提前结束。此 task 没有“实际填了多少”的 output 参数；fixture 的 `refill_rx` 只要找到 ops 并完成调用就把 `ok=1`，所以不能把这个 ok 当成精确填满请求数的断言。要证明四帧被接收，还要检查设备完成与生产 `rx_receive` 的返回数量。

在这一步，驱动提供的是空 buffer 与写权限；网络帧与 used 完成仍由设备模型生成。清零 RX buffer、填 descriptor、更新 avail 都是驱动行为，设备通过 EP-originated DMA 写 header/payload/used 才是接收完成。第 12 章从这一已发布的 ring 接续逐字节 RX 数据路径。

源码：[RX 预填，L238](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_datapath.svh#L238)、[fixture refill，L984](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L984)。

## 9.4 关键函数导航

下表中的路径均相对 `virtio_net_vip/`；上文链接固定到本文基线 SHA，避免分支继续演进后行号漂移。

| 源码入口 | 主要调用者与参数 | 结果和应检查的边界 |
|---|---|---|
| `tests/virtio_real_driver_flow_fixture.sv:307 end_of_elaboration_phase` | UVM；无业务输入 | 从 frozen snapshot 解析 AF/BDF/BAR，缺失句柄或快照不冻结不能 ready |
| `src/sriov/virtio_resource_client.sv:70 bind_validated` | bind_to_ctx / bind_to_service；snapshot 对、service key | 按 local_pair 保存映射；拒绝错误 owner、空 binding、改绑 |
| `src/env/virtio_net_env_config.sv:339 get_service_config` | env.connect_phase；service key、allocated_qpairs | 输出 driver_cfg，按资源限制对数，叠加私有协议选择 |
| `src/sriov/virtio_function_instance.sv:373 commit_validated_pcie_components` | Function PCIe commit；共享资源与 ops/FSM 候选 | 绑定 backend、域与外部 sequencer；不分配 ring |
| `src/transport/virtio_discovery_strategy.sv:97 discover` | transport.discover_and_init_bars；transport | 编程 BAR、开 MSE/BME、扫描并检查 capability，错误 fatal |
| `src/transport/virtio_pci_cap_manager.sv:116 discover_capabilities` | 发现策略；bar_ref | 配置链表扫描，48 项上限，记录各窗口 |
| `tests/virtio_real_driver_flow_fixture.sv:736 start_driver_flow` | golden run_phase；ref ok | verified reset、协商、容量、MSI-X、DRIVER_OK；不建 ring |
| `src/agent/virtio_auto_fsm.sv:228 full_init` | 另一条 FSM 初始化入口；drv_cfg | 批量建队后 DRIVER_OK，标准多对仍需 MQ commit |
| `src/agent/atomic_ops/virtio_atomic_ops_queue.svh:15 setup_queue` | fixture/FSM；qid、size、type、output ok | 创建→分配→映射→编程；重复/恢复 pending 提前拒绝 |
| `src/virtqueue/virtqueue_manager.sv:63 create_queue` | ops；qid、size、type | 类型工厂与共享引用注入，登记队列对象 |
| `src/virtqueue/split_virtqueue.sv:117 alloc_rings` | ops；队列已有 size/mem | 三块 GPA、清零与 free list，分配失败报告 |
| `src/virtqueue/packed_virtqueue.sv:155 alloc_rings` | ops；队列已有 size/mem | 一块 GPA、descriptor+两个 event，wrap 初值为 1 |
| `src/iommu/virtio_iommu_model.sv:178 map_for_host` | ops；host/BDF/GPA/size/权限 | 返回设备 IOVA，记录域与权限映射 |
| `src/transport/virtio_pci_transport.sv:694 setup_single_queue` | common backend；三地址、大小、vector | 地址和 vector 先于 enable，保存设备 notify offset |
| `src/transport/virtio_pci_transport.sv:647 kick` | backend；qid、next index、wrap | 按协商选择 2/4B 通知，拒绝无 notify offset 的 qid |
| `src/agent/virtio_auto_fsm.sv:357 start_dataplane` | 显式 FSM 数据面启动 | READY 与 MQ commit 门槛，预填 RX 后启动 worker |
| `src/agent/atomic_ops/virtio_atomic_ops_datapath.svh:238 rx_refill` | fixture 或 FSM；qid、数量、可选容量 | 发布可写 buffer，部分成功可提前结束，无数量 output |
