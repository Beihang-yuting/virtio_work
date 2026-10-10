# 10. 具体业务：一个 16 字节 TX 如何提交

## 10.1 先看测试真正调用了什么

入口在 `virtio_net_vip/tests/virtio_real_driver_flow_test.sv`。其 `run_phase():40` 先验证 fixture、取得 pair0 的 TX qid，调用 `start_driver_flow()`，再 `setup_queue(tx_queue_id,256,VQ_SPLIT,ok)`。MODEL 分支从第 84 行开始，实际请求可节选为：

```systemverilog
pkt = virtio_real_driver_flow_packet::type_id::create("tx_packet");
hdr = '{default: 0};
flow.submit_tx(tx_queue_id, hdr, pkt, 1'b0, desc_id, ok);
flow.complete_tx(tx_queue_id, completed, 1, completed_count, ok);
```

此处 `use_indirect=0`，不是 indirect descriptor 测试；completion budget=1，不是等待所有队列清空。`pkt` 的 [new():16 与 do_pack():24](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_test.sv#L16) 在同一文件，构造函数保存以下确定的 16 字节，do_pack 按每字节 8 bit 打包：

```text
de ad be ef 01 23 45 67 89 ab cd ef 10 20 30 40
```

这是用于 golden lifecycle 的合成 UVM 对象，不是一份完整合法的以太网报文。生产 TX 操作仍会把它的 16 字节作为 payload 投递；不能因为方法名里有 packet 就声称该测试证明了 Ethernet/IP/UDP 解析正确。只有空打包结果才触发 64 字节最低容量兜底，这个对象有数据，不会变成 64 字节。

`flow` 只是把测试意图交给已绑定 Function 的生产 ops。它不在 fixture 中直接写 desc/avail/used，更不自行调用设备 push_used 来制造通过。

## 10.2 submit_tx 的对象与失败契约

[fixture.submit_tx():880](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L880) 的输入为 `queue_id、net_hdr、pkt、use_indirect`，通过 ref 参数返回 `desc_id、ok`。开始先写 `ok=0、desc_id='1`；只有已有 `m_flow_ready`、已开始 driver flow、非空 pkt、可解析的 selected Function 和可用 ops，才调用该 Function 的 `ops.tx_submit()`。

返回后 `ok=(desc_id!='1)`。它表明驱动接受并发布了这一条提交，不表明设备已经完成 DMA，更不表明中断已经被 monitor 采样。直接调用 ops 的调用者也须保证这些引用已绑定；生产 ops 并不会为一个裸对象重建完整环境。

实际函数 [virtio_atomic_ops.tx_submit():22](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_datapath.svh#L22) 位于 `agent/atomic_ops/virtio_atomic_ops_datapath.svh`。这个文件被 `agent/virtio_atomic_ops.sv` 在 class 体内 include：它不是另一个 UVM 组件，也不是另一个数据面对象。去找函数时应先确认所属类，再打开被 include 的实际实现文件。

tx_submit 先把 desc_id 保持为失败哨兵。请求 indirect 却未协商 INDIRECT_DESC、qid 没有对应 vq、无 header 的队列却携带 offload 请求，都会提前报错返回；这些情况不会进入成功 DMA 所有权记录。

## 10.3 header 和 payload 的字节从哪里来

主线 negotiated features 是 CSUM|VERSION_1。`vq.net_hdr_bytes()` 调用 [virtio_net_hdr_util.get_hdr_size():27](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/types/virtio_net_hdr.sv#L27)：HASH_REPORT 为 20 字节，MRG_RXBUF 或 VERSION_1 为 12 字节，其余为 10 字节。因此这里是 12，而不是“未协商 MRG_RXBUF，所以必然是 10”。

`pack_hdr():54` 按小端把 flags、gso_type、hdr_len、gso_size、csum_start、csum_offset，以及本格式携带的 num_buffers 编码。输入 hdr 全零，得到 12 个零字节；CSUM 只是允许能力，零 flags 没有请求实际 checksum offload。

payload 先试 [virtio_net_packet_adapter.pack():22](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/dataplane/virtio_net_packet_adapter.sv#L22)。如果对象是外部 `packet_item`，adapter 取真实 wire bytes，避免把它 UVM do_pack 的长度前缀当成网络帧。当前合成对象不是 packet_item，于是走 `uvm_packer → pkt.do_pack → get_bytes`，恰好取回上述 16 字节。

主线的 descriptor 长度与 backing 请求如下。分配器内部还可能按自己的 granule 向上取整，表中是 ops 请求的字节数，不把它等同于 Buddy 内部实际占用量。

| 区域 | 有效 descriptor 长度 | ops 请求 backing | 实际内容 |
| --- | --- | --- | --- |
| Header | 12 B | DWORD 对齐后 12 B | 全零 virtio-net header |
| Payload | 16 B | DWORD 对齐后 16 B | 固定 16 B 合成数据 |

DWORD padding 的目的，是让设备模型经 PCIe MemRd 读最后一个不完整 DWORD 时不跨出实际 backing block。descriptor 长度仍是有效字节长度，不能把 padding 字节算进业务 payload。

## 10.4 每一次提交的 DMA 所有权怎么建立

tx_submit 创建一个局部 `virtio_dma_buffer_set("tx_dma")`，调用 `bind_domain(mem,iommu,transport.iommu_host_id(),transport.bdf)`。这个集合只借用 mem/IOMMU；它拥有本次提交申请的 GPA 和 IOVA 记录，不拥有共享 manager。

[virtio_dma_buffer_set](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_dma_buffer_set.sv#L24) 中关键函数的使用顺序是：

| 函数位置 | 当前调用 | 输出或副作用 |
| --- | --- | --- |
| `new:24 / bind_domain:29` | 空集合绑定 Host/BDF 域 | 保存借用引用，不分配 payload |
| `alloc:38` | header 与 payload 各一次 | 返回集合索引，登记 GPA；失败 -1 |
| `write:52` | 写 12 B header、16 B payload | 修改共享 Host backing |
| `map:63` | 两项均 DMA_TO_DEVICE | 建立设备可读 IOVA；0 或全 1 视为失败 |
| `get_iova:78` | 组装两个 SG entry | descriptor 用 IOVA，不用 GPA |
| `release_all:96` | 提交前失败回滚 | 先解映射已映射项，再释放所有 GPA |
| `disown:107` | 记录已交给 ops 后调用 | 只清集合，不释放 backing |

先分配、再写内容、再建立 DMA_TO_DEVICE 映射。第二份分配失败会释放第一份；任一映射失败会解映射成功项并释放两份 backing；add_buf 失败也由集合回滚。不会把没有提交成功的记录加入 tx_dma_map，避免后来等待一个不存在的完成。

成功发布后 [adopt_dma_set():272](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_atomic_ops.sv#L272) 把每项转成 `{host_id,bdf,gpa,iova}` 的 normal_dma_record，按 header→payload 顺序追加到 `tx_dma_map[qid]`，再 disown 集合。此后由完成或已确认的设备复位退休，不再由局部集合释放。

注意 backing 的所有权分两类：ring/indirect table 由 queue 持有；普通 header/payload 由 ops 的 DMA 记录持有。poll_used 归还 descriptor 并不意味着它可以释放这些普通 payload。

## 10.5 两个 SG 如何变成 Split descriptor 与 avail

tx_submit 构造两个 device-readable SG list：第一个 `{addr=I_hdr,len=12}`，第二个 `{addr=I_pkt,len=16}`。调用 `vq.add_buf(sgs,2,0,pkt,0)`：n_out=2、n_in=0，token 是原 pkt 句柄，indirect=false。

[split_virtqueue.add_buf():203](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/split_virtqueue.sv#L203) 先检查 SG 数相加溢出、SG 总数为 0 或超过输入数组长度、没有 entry、空闲 descriptor 不足；输入数组可以包含不参与本次提交的尾项，并不要求长度完全相等。直接链需要两个 ring descriptor，indirect 模式才只占一个主 ring 槽并另建表。

在这个新建、无其它提交的 queue 中，空闲链从 0 开始，所以 head=0，第二项=1；这是“新队列首提交”的结果，不是以后每次都返回 0。两个 descriptor 的业务含义如下：

| Descriptor | 地址 / len | Flags / next | Device 权限 |
| --- | --- | --- | --- |
| 0，链首 | `I_hdr / 12` | NEXT / 1 | 可读，不置 WRITE |
| 1，链尾 | `I_pkt / 16` | 0 / 0 | 可读，不置 WRITE |

write_desc 在 Host GPA 的 desc table 编码每个 16 B 项：64 bit addr、32 bit len、16 bit flags、16 bit next。内存位置是 GPA，descriptor 里的 addr 字段则是 IOVA，必须分清这两个地址层次。

发布次序为：写完整 descriptor → `barrier.wmb()` → `avail.ring[0]=head` → `avail_idx` 从 0 加到 1并写进 avail.idx → `barrier.mb()` → `token_map[head]=pkt` 及发布账本。具体字节偏移：avail ring entry 在 `G_avail+4`，avail.idx 在 `G_avail+2`。

两个 descriptor 只产生一个 avail entry，因为 avail 公布的是“一条链的 head”，不是每个 SG 分别公布。空闲 descriptor 数从 256 减到 254。buffer 数、descriptor 数、avail entry 数、packet 数不是同一个计数。

## 10.6 真正的通知由谁发，submit 返回又意味着什么

add_buf 不会自己发 PCIe notify。tx_submit 先 adopt DMA 所有权，再检查 `vq.needs_notification()`。主线未协商 EVENT_IDX，设备 used.flags 没有要求 NO_NOTIFY，首条提交需要通知。

调用链是 [kick_with_fault():242](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_atomic_ops.sv#L242) → PRE_NOTIFY 故障边界 → `vq.prepare_notify()` → `cfg_backend().notify_queue(qprog,next_idx,wrap)` → [virtio_pci_transport.kick():647](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/transport/virtio_pci_transport.sv#L647) → BAR write，然后 POST_NOTIFY 边界。只有 prepare_notify 返回真才调用后端通知，返回假也仍执行 POST_NOTIFY。普通 backend 的 `notify_queue():123` 转交 transport；私有 backend 使用自己的 doorbell，不能用标准 notify offset 替代。

没有 NOTIFICATION_DATA 时，写入的是标准 queue_id 通知；协商该 feature 才携带 next_idx/wrap 扩展数据。实际 MMIO 地址由 capability base、queue_notify_off 和 notify multiplier 组合，不能把“qid=1”直接当成绝对 BAR 地址。

`virtqueue_base.kick()` 只是队列层统计接口，并不保证发出 TLP。当前生产路径统一走 ops/配置后端的 notify；直接在测试里调用裸 vq.kick 而没有 transport 通路，不能证明真实设备已被唤醒。

到这里 driver 可以返回 desc_id，fixture 可以返回 ok=1；设备 worker 的处理是另一条并发执行路径。完成的唯一数据依据是设备在共享 Host memory 发布的 used 状态，下一章继续跟踪它如何出现。

# 11. 独立设备怎样消费 TX 并产生完成

## 11.1 notify 从 PCIe 到设备 worker

MODEL 的 RC→EP 请求由外部 PCIe 环境送到被 factory 替换的 `vdev_ep_driver`。它的 [handle_request():35](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_uvm_ep_port.sv#L35) 先请共享 device_port.serve 判断请求是否属于某个注册的 vdev；处理不了才交回基类。`serve():89` 按 BDF 处理配置请求，按设备认领的 BAR 地址处理 MMIO，并按 PCIe Byte Enable 提取有效字节。

本次 notify 是 MMIO write：port 调用 `dev.mmio_write()`，继而 `vdev_virtio_pci.region_write()` 进入 notify 区域。没有 PCIe Memory Write Completion 等待；posted write 与设备 worker 处理不能等同为一个同步函数调用。

[vdev_virtio_pci.notify():434](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_virtio_pci.sv#L434) 从 data 低 16 bit 取 qid，发布 notify 事件、增加通知计数，然后检查 qid 是否匹配 notify slot、是否越界、队列是否 enable、是否已有 DRIVER_OK。条件不足时告警并忽略调度。MQ 协商时，未激活 pair 的 TX 也不能因为 Host 建好了 ring 就发包。

检查通过后 `schedule(qid)` 把队列放入工作列表并触发 work_ev；同一个 q 已在列表时不重复入队。设备基类 [run_phase():380](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_base.sv#L380) 是常驻 worker：优先处理待投中断，再 pop 队列并调用 `service_queue(q)`。这是设备侧 run task，不是顶层 virtio env 自动初始化的任务。

## 11.2 设备看到的 ring 地址怎样访问同一份 Host 内存

[service_queue():491](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_virtio_pci.sv#L491) 保存当前 epoch，循环要求 epoch 不变、queue enable、未 broken、DRIVER_OK。RX 还要求有待收帧。每轮执行 `fetch → chain_ok → consume → push_used`，任何失败、复位换代或中途停队都不会继续正常发布这一轮完成。

设备的 desc/driver/device 地址来自驱动已编程的 common config，是 IOVA。`dma_rd/dma_wr` 先检查 PCI Bus Master Enable，再交给 port；它们不从 queue 对象中偷取 GPA，也不使用驱动 token_map 来猜 payload。

[device_port.dma_read():192 与 dma_write():219](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_uvm_ep_port.sv#L192) 按 IOVA 和翻译后 GPA 的双侧 4 KiB 边界切块。`page_chunk():267` 用 `{m_host_id,requester BDF}` 和 DMA 方向调用共享 IOMMU；映射缺失或权限不允许时报告 VDEV_DMA，返回失败，不绕过 IOMMU。

MODEL 的翻译发生在 port 内：IOVA→GPA 后，懒创建的 [virtio_pcie_model_dma_adapter.read():120 / write():181](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/pcie/virtio_pcie_model_dma_adapter.sv#L120) 把 GPA 与 requester BDF 转成 EP-originated PCIe MemRd/MemWr。adapter 借用 EP driver，DWORD 对齐、Byte Enable、Completion 取回由这一层处理；单次请求不得跨 4 KiB，读操作还受超时限制。

PCIe RC 服务访问的是 fixture 预先绑定的同一个 host_mem_pool manager，因此设备读到驱动写过的 descriptor/header/payload；设备写 used 后，驱动也读到同一份 backing。这里没有第二套 payload 镜像替设备制造结果。

REAL_DUT 不能照搬这一步的地址含义：RTL 发出的 TLP 本身可以携带 IOVA，本地 Host responder 使用 IOVA proxy 完成翻译。MODEL port 先翻译后发出的 TLP 则携带 GPA。不要以 MODEL monitor 看见的 GPA 为理由，把 REAL_DUT 的 IOVA 直接当 GPA 使用。

## 11.3 从 avail.head 到 payload 字节

[fetch():523](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_virtio_pci.sv#L523) 在 split 分支先 DMA 读取 `I_avail+2` 的 16 bit avail.idx。本次读到 1，设备 last_avail 初始 0，表示有一条新链；若两者相同，函数返回 got=0，不能凭 notify 就伪造工作。

它检查生产者领先数不得超过 queue_size，再读 `I_avail+4+2*(last_avail%256)`，得到 head=0。随后推进设备 last_avail，并经 `read_split_chain():642` 从 `I_desc+16*head` 逐项读 descriptor，沿 NEXT 找到第二项。越界、循环、非法间接表或 DMA 失败会由 device_error 处理，而不是按正常完成归还。

`chain_ok():701` 检查零长度、可写之后再出现可读、TX 出现 WRITE、RX 链首非 WRITE 等方向错误。本次两项都可读，长度分别 12 和 16，合法进入 `consume():741` 的 TX 分支。

`read_readable():725` 分别 DMA 读 I_hdr 的 12 B 和 I_pkt 的 16 B，按链顺序拼成 28 B。`tx_frame():800` 解前 12 B 的 header，发布 descriptor-chain 事件，再把余下 16 B 发布为 VDEV_PKT 的 TX bytes。它并不重新对原 pkt 句柄 do_pack，而是使用实际 DMA 读回的字节。

模型还调用 `inject_rx(q/2,frame)` 将帧放进同对 RX backlog。当前 TX 测试没有建立 RX0 ring，所以这份回环帧不会被自动交给驱动，也不能算作已验证 RX。后续整设备 reset 会清 backlog；第 12 章的 RX 测试是另一轮独立激励。

## 11.4 一条链如何写成一个 used entry

TX 两个 descriptor 产生一个 used entry，不是每个 descriptor 产生一个完成。`consume()` 的 TX 分支不向任何可写业务 buffer 写入，所以本模型的 used_len 保持 0；它不是“发送 payload 长度=16”的计数器。

[push_used():948](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_virtio_pci.sv#L948) 先把 `{id=head=0,len=0}` 小端写到 `I_used+4+8*(used_idx%256)`，再将设备 used_idx 从 0 加到 1，DMA 写 `I_used+2`。写回成功才增加 completion_count、发布 VDEV_COMPLETE，然后 `used_notify():1004` 决定是否中断。

没有 EVENT_IDX 时，设备读 avail.flags 的 NO_INTERRUPT；主线没有禁用 callback，因此按已绑定队列 MSI-X vector 触发中断。IRQ 被 mask 时可先挂起，不能保证每个 used 都立即产生一个可见中断。

`vdev_base.raise_irq():354` 按 MSI-X Enable、表项及 mask 判断能否发送，增加设备中断计数；port.raise_msix():241 构造 MSI-X Memory Write 供 PCIe monitor 观测。MODEL 这里延迟发布被观察的事件，不阻塞 worker。故“设备 interrupt_count 已增加”和“monitor 已采到中断”可能不在同一时刻。

## 11.5 驱动读取 used，然后分两层回收

[fixture.complete_tx():918](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L918) 清空 output 队列，有限次调用 `ops.tx_complete(qid,completed,max_budget)`；本轮没有新结果就等 1 ns，直到看到新增对象或轮询次数上限耗尽。max_budget 是单次 ops 的完成数量预算，`m_poll_timeout_ns` 才限制 fixture 的尝试次数。它不会等待中断后才允许 polling。

`tx_complete():189` 调 `vq.poll_used(token,len)`。实际 [split_virtqueue.poll_used():339](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/virtqueue/split_virtqueue.sv#L339) 先做 read barrier，再读共享 Host backing 的 used.idx。等于 last_used_idx 时返回 0；有新完成才取 `{used_id,used_len}` 并查 token_map。

成功取回原 pkt token 后，queue 删除 token、释放可能的 indirect table，并把 descriptor 链放回 free list。本次两个 descriptor 归还，free count 回到 256；last_used_idx 加到 1。used_id 不在 token_map 时报告错误并返回 0，链回收中检测到循环也会报错，不应把错误日志与函数返回值混为一个“成功”判据。

随后 ops 根据完成 packet 数退休普通 DMA 记录。普通带 header 的队列每个 packet 对应两条记录，因此本次从 tx_dma_map[qid] pop header 和 payload，调用 `retire_normal_dma_record():153`，逐条 `iommu.unmap_for_host()` 然后 `mem.free()`。空记录队列被删除，但 ring 的三段 backing 和映射仍保留，供下次提交复用；整设备 reset 才拆除它们。

fixture 的 `ok=(completed.size()!=0)` 只说明取到了非零完成，并不保证一般情况下达到 max_budget，也不直接比较完成对象是否和原 pkt 逐字段相等。本测试在第 113～123 行另外断言 count=1、objects=1，以及 notify、DMA read/write、completion、interrupt 计数有增长。

## 11.6 monitor、scoreboard 与测试各证明什么

被动路径为 PCIe RC/EP monitor.tlp_ap → per-Function observer adapter.write → virtio_monitor.observe_* → FIFO/event/SVA/txn_ap。adapter 用 frozen identity、requester BDF 和 owned BAR 区间路由，先把 MSI-X 与 MMIO 分出来，再把本 Function 的其它设备内存请求归为 DMA；它不替设备做业务搬运。

[virtio_monitor.observe_dma():189](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/virtio_monitor.sv#L189) 在 DMA window 已配置且检查开启时验证范围、非零大小和地址回绕。`observe_queue_notify():275` 与 `observe_interrupt():218` 检查通知/完成信用等语义，`publish_event():498` 按事件写 FIFO、触发 event、广播 txn，错误还通过 err_ap 报告。所有这些是观察，不是写 used 的生产者。

[scoreboard.write():79](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_scoreboard.sv#L79) 对 is_monitor_event 单独计数并处理部分检查，然后直接 return。当前黄金测试直接调用 ops，未通过 `VIO_TXN_SEND_PKTS/WAIT_PKTS` 构造一对 expected/actual 业务事务。因此不能声称 scoreboard 在这个 TX 测试中完成了 16 B wire payload 的逐字节比对。

scoreboard 的 `check_dma_access():337` 当前只拒绝 size=0；名字和旧注释比实际实现更宽，不能据此宣称它独立验证了每条 IOMMU 权限。DMA 权限的真实拒绝点在 port/IOMMU；monitor 另负责已配置窗口的被动检查。`check_notification():321` 主要记录日志，不能把它当成完整中断协议证明。

| 当前证据来源 | 能说明什么 | 不能单独说明什么 |
| --- | --- | --- |
| TX 测试完成数与计数断言 | 请求穿过 notify/DMA/used/IRQ 路径 | 全套 Ethernet/offload 正确性 |
| Device DMA 与 used | 真正消费共享 backing 并发布完成 | 原 test 对象的所有字段都被比较 |
| Observer / monitor / SVA | 地址、状态、通知等已实现契约被观察检查 | 自动拥有所有 payload expected |
| Scoreboard 业务事务分支 | 有 SEND/WAIT 事务时可做 expected/actual 匹配 | 直接 ops 主线必然走过该分支 |
| 下一章 RX test | 实际内存读回形成的帧与输入字节一致 | 自动代表所有协议/异常场景已覆盖 |

这不是降低主线价值，而是明确“闭环在哪里产生、哪些条件由谁断言”，避免仅看到 scoreboard 被创建就认为所有七类检查都已覆盖了当前业务。

# 12. 具体业务：四帧 RX 从网络入口回到 packet_item

## 12.1 这是独立测试，网络侧字节必须另有来源

入口是 [virtio_real_driver_rx_test.run_phase():28](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_rx_test.sv#L28)。它的 build_phase():23 新建同类fixture，从新一轮UVM生命周期开始；不是上一章TX测试完成后继续处理回环帧。run先raise objection，检查build_flow，经 `rx_queue_id_for_pair(0,rx_queue_id,why)` 查询冻结资源映射，再初始化driver并建立一条split256 RX队列。默认pair0对应RX0，但查询结果才是本次使用的qid。

第56行显式检查 `execution_profile().has_model_device()`。不是MODEL就以 `REAL_DUT_RX_SOURCE_UNAVAILABLE` fatal结束：当前测试没有平台网络入口callback，RC Host-memory responder也只回答设备DMA，不能制造网络接收帧。设置REAL_DUT模式不会自动把模型入包变成RTL端口激励。

队列建好后，测试记录notify、DMA write、completion、interrupt四项设备计数，再构造四个外部 `packet_item`，约束 `pkt_kind==ETH_IPV4_UDP`、`pkt_len inside {[128:512]}`。随机化失败立即fatal。成功后 `pkt.pkt.do_pack()`，保存expected句柄，调用fixture.inject_rx。这里的 `pkt_len` 是外部报文对象的生成参数，源码中实际传递的是 `pkt.pkt.raw_data`；不能直接把128..512当作已证明的准确wire字节数。精确长度应取pack后的字节队列大小，本章以 `F_i` 表示第i帧的实际字节数。

## 12.2 inject只入设备backlog，不直接填Host buffer

[fixture.inject_rx():959](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L959) 接收qid、packet对象和ref ok。它先置ok=0，要求MODEL device存在、packet非空、qid为偶数且 `virtio_net_packet_adapter::pack` 成功；失败报告UVM_ERROR。成功时复制wire bytes到 `bit[7:0] frame[$]`，调用 `dev.inject_rx(queue_id/2,frame)` 后置ok=1。

继承自 [vdev_base.inject_rx():282](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_base.sv#L282) 的实现把字节队列存入 `rx_backlog[pair]`，并 `schedule(2*pair)` 唤醒RX队列。这个函数不写Host buffer，也不创建used项；没有“帧已经成功DMA到Host”的返回值。fixture的ok只说明通过包装层校验并把帧交给设备。

四帧全部先进入backlog，然后测试才执行refill。即使worker先获得调度，RX ring尚无avail时 `fetch` 返回got=0，帧仍留在backlog。refill发出的notify再调度同一RX队列，`service_queue():491` 检查epoch、queue enable、DRIVER_OK、broken和backlog，之后才走fetch→chain_ok→consume→push_used。这正是测试有意验证的“帧先到、可写buffer后到”。

## 12.3 refill发布四个可写buffer，容量与有效长度分开算

[fixture.refill_rx():984](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L984) 查找selected Function和ops，调用 `ops.rx_refill(queue_id,count)` 后设置ok=1。它不检查内部实际填了多少，也不额外检查flow started；正式测试通过前序初始化保证调用时机。

生产入口 [rx_refill():238](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_datapath.svh#L238) 的第三参数 `buf_size=0` 表示使用默认容量：先尝试queue_program中的RX容量，仍为0则取header长度+1514。显式非零参数优先于这两者。标准主线协商CSUM|VERSION_1，header为12B，所以descriptor容量为1526B；分配与映射大小DWORD向上取整为1528B。

| 量 | 单buffer主线值 | 作用 |
| --- | --- | --- |
| Virtio header长度 | 12B | VERSION_1带来字段布局，不代表MRG_RXBUF已协商 |
| Descriptor可写长度 | 12+1514=1526B | 设备可用容量，不是本次已收长度 |
| GPA申请及IOVA映射长度 | 1528B | DWORD对齐的backing，权限DMA_FROM_DEVICE |
| 实际used_len | 正常时12+F_i | 设备写回的header与帧总长 |

每次循环创建一份独立buffer：DMA集合alloc→清零→map(DMA_FROM_DEVICE)，生成一个SG entry `{addr=I_buf,len=1526}`，调用 `vq.add_buf(sgs,0,1,null,0)`。n_out=0、n_in=1说明设备可写；token=null说明接收前没有一个可供“归还”的原输入packet句柄。split队列仍在token_map登记该head，只是其值为空，因此poll_used检查的是键存在，不是token非空。

新队列成功填四份时head依次0、1、2、3，每份一个WRITE descriptor、一个avail条目，free count由256到252。GPA为随机分配，不能画成四份连续buffer。每份add_buf成功后经adopt_dma_set把所有权转给 `rx_dma_map[qid]`；整个循环末尾有成功提交且needs_notification时才统一kick。清零buffer是驱动准备可写内存，不是伪造设备数据。

队列不存在会早返回；ring满、Host分配失败、IOMMU映射失败或add_buf失败都可能提前结束。映射/add_buf失败回滚当次DMA集合，此前成功的buffer仍在RX表中等待完成。task没有filled输出，fixture.ok=1不能代替“确实填了四份”的断言；test后续要求收到恰好四帧才完成这个验证。

## 12.4 设备写header、payload和used，used_len说明实际写入多少

`consume`的RX分支调用 [vdev_virtio_pci.rx_frame():820](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_virtio_pci.sv#L820)。它取并弹出该pair的第一帧，构造全零header后设置 `num_buffers=1`，通过encode_hdr生成12B，再追加帧字节。主线header的偏移10（从0计数，即第11字节）因此是1，而不是TX主线的全零header。

设备先累加链内descriptor的容量room。若 `12+F_i > room`，报告VDEV_RX warning，丢弃已经出backlog的帧，保留ok=1、used_len=0返回；service_queue随后可以把buffer以len0归还。不能把“有used完成”单独看成“收到完整帧”。若容量足够，逐descriptor取相应片段，经 `dma_wr(chain[i].addr,part,ok)` 写入设备可见IOVA。port验证FROM_DEVICE写权限并翻译到共享GPA，再发EP-originated PCIe写，具体传输边界沿用第11章。

任一DMA写失败令ok=0并返回，本轮不会正常push_used；被弹出的帧也不会由本函数自动放回backlog。全部写成功后发布链/header和RX字节事件，设置 `used_len=payload.size()`，即12+F_i。然后push_used写 `{head,used_len}`、推进used.idx并决定中断。四帧正常接收各产生一个完成；设备不把padding的两字节算进used_len，也不会把整份1526B容量一律上报为有效数据。

这个MODEL实现一次处理一条descriptor链，放不下就len0归还，并没有在此自动跨多条独立avail链合包。驱动侧支持MRG_RXBUF的代码存在，不表示默认设备模型或当前测试覆盖了该场景。

## 12.5 Host按used长度复制字节，再退休每份DMA

[fixture.receive_rx():1007](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L1007) 先清received队列与count，检查Function/ops，再有限次调用 `ops.rx_receive(queue_id,received,budget)`。累计数量达到budget即停止，没有新增对象才等1ns；循环耗尽也返回已有结果。最后 `received_count=received.size()`、`ok=(received_count!=0)`，所以一般调用者必须另查count，不能把非空等同于收到budget份。

底层 [rx_receive_frames():325](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_datapath.svh#L325) 的输入是qid与max_budget，frames为追加式ref输出。它取得vq、算header长度，循环poll_used。split.poll_used从共享Host ring读取完成、取回null token并归还descriptor；之后ops从 `rx_dma_map[qid]` 按提交顺序pop一份normal DMA record，用其中GPA读取used_len字节。

当前实现用FIFO所有权表配合设备按提交次序完成的MODEL主线，不是在这里拿used_id做通用乱序DMA映射查找。used有完成但ownership表为空会报错停止。读回长度小于header时报告短包、退休当前record并停止；例如设备容量不足归还len0，不会成为一份合法packet。

正常路径unpack前12B header，剩余字节进入 `frame.payload`，然后retire当前record：按域unmap IOVA，再free GPA。数据已经复制进frame，DMA backing随后释放不会丢失返回内容。其合包数计算是：没有协商MRG_RXBUF，或header.num_buffers为0，都按1处理。VERSION_1虽然携带num_buffers字段，却不能单独让该字段触发多buffer拼接。

如果另一测试真的协商MRG_RXBUF，后续buffer会继续poll_used、复制全部续接字节并分别退休record。缺续接buffer时会报错跳出合包循环，但本实现仍可能把已组装的部分frame追加到frames；不能声称“解析成功就保证完整合包”。本主线无MRG且每帧一buffer，不经过该异常分支。队列RX记录全部耗尽后删除该映射表项，ring资源留到最终reset再拆。

## 12.6 从frame到packet_item，逐字节比较才闭合RX内容证据

[ops.rx_receive():419](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_datapath.svh#L419) 对每个frame调用 [virtio_net_packet_adapter.unpack():41](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/dataplane/virtio_net_packet_adapter.sv#L41)。adapter拒绝空字节，创建新的packet_item及packet payload对象，调用外部payload.unpack，再按raw_data长度是否一致返回成功。这不是把inject传入的expected对象直接还给测试。

unpack成功才把新对象加入received；失败且frame.token非空才回退返回token。本RX refill的token为null，解析失败便不会增加received数量。adapter的长度判定本身也不等于验证所有IP/UDP字段或校验和合法性；完整内容比对由测试下一步完成。

test首先要求count和received.size都等于4，再逐项cast为packet_item，调用 [adapter.compare():57](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/dataplane/virtio_net_packet_adapter.sv#L57)。compare将expected和actual通过pack转成wire字节，先比长度再逐byte比较；空对象、无法pack、长度或任意字节不同都失败。它没有依赖packet_item.do_compare的字段选择，也没有把Virtio header一起当以太帧比较。

因此本测试的内容证据链为：输入raw_data → backlog帧 → 设备DMA写buffer → Host按used_len读回 → 去12B header → 新packet_item.raw_data → expected/actual逐字节一致。测试另查notify、DMA write、completion和interrupt计数均增加，最后执行reset_and_teardown。通过这些断言仍不表示所有checksum、RSS、GSO、多队列、mergeable或REAL_DUT接入场景都已覆盖。

## 12.7 dataplane engines是另一层调用入口，不是第二个DMA所有者

Function创建的dataplane wrapper已有TX/RX engine，但这个RX测试直接通过fixture调用ops，并没有调用rx_engine.receive_packets。引擎对照能解释为何项目保留wrapper而仍强调ops作为统一资源边界。

| 入口与位置 | 做什么 | 参数与边界 |
| --- | --- | --- |
| `src/dataplane/virtio_rx_engine.sv:88 refill_buffers` | 调`ops.rx_refill(qid,count,get_rx_buf_size())` | 显式传engine容量；缺ops/manager/queue报错；不独占DMA |
| 同文件`:107 receive_packets` | 调`rx_receive_frames`，可选checksum检查、建packet并累计统计 | qid、budget、ref received；缺上下文早返回，checksum失败告警；free count低于threshold再补buffer |
| 同文件`:64 build_received_packet` | adapter.unpack成功返回packet_item，否则创建wrapper | wrapper保留payload/header/实际长度，供错误测试检查 |
| `src/dataplane/virtio_tx_engine.sv:55 submit_packet` | 从字节推导header，再调同一个ops.tx_submit | qid、pkt、indirect、ref desc_id；空数据拒绝，不走ops的空payload64B兜底 |
| `src/dataplane/virtio_net_dataplane.sv:92 bind_ops` | 两engine借用同一个ops | 仅接线，不分配ring或报文 |

源码：[RX engine](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/dataplane/virtio_rx_engine.sv#L64)、[TX engine](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/dataplane/virtio_tx_engine.sv#L55)。

RX engine只在协商GUEST_CSUM时调用offload.verify_rx_csum；默认主线协商的是CSUM，不是GUEST_CSUM。engine还在解析失败时返回wrapper，而直接ops.rx_receive只在token非空时回退；两条API返回语义不能混写。自动补充条件实际是 `vq.get_free_count() < refill_threshold`，threshold=0关闭该分支，不应泛化成“每收到一个包自动补一个”。这些wrapper承担转换、策略和统计，buffer分配、IOMMU、descriptor、notify与退休仍委托同一个ops。
