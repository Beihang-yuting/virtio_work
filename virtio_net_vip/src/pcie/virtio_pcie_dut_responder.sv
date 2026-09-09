`ifndef VIRTIO_PCIE_DUT_RESPONDER_SV
`define VIRTIO_PCIE_DUT_RESPONDER_SV

// Device-side boundary for the real-driver flow.  The responder consumes
// monitor-verified queue kicks and performs all queue/ring/data accesses as
// endpoint-originated PCIe DMA.  It deliberately does not own or free any
// driver allocation; normal virtqueue polling remains the driver's job.
// 中文契约：这是没有 RTL DUT 时使用的 MODEL 行为模型；REAL_DUT 必须不创建它。
// 主要依赖：virtio_monitor/virtio_pci_transport/virtqueue_manager、共享
// host_mem_manager、virtio_iommu_model 以及 pcie_work EP driver。所有这些句柄均由
// 调用方拥有；本类只创建自己的 FIFO 和 model DMA adapter，不释放外部对象。
// 生命周期：build_phase 建 FIFO，bind_function 完成一次绑定，start 启动 notify worker，
// stop/wait_stopped 停止并等待在途 DMA；reset/teardown 由上层驱动负责完成。
class virtio_pcie_dut_responder extends uvm_subscriber #(virtio_transaction);
    `uvm_component_utils(virtio_pcie_dut_responder)

    typedef struct {
        bit configured;
        bit enabled;
        bit reset;
        int unsigned queue_size;
        bit [63:0] desc_iova;
        bit [63:0] driver_iova;
        bit [63:0] device_iova;
        int unsigned msix_vector;
        virtqueue_type_e ring_type;
    } queue_state_t;

    typedef struct {
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] flags;
        bit [15:0] next;
        bit [15:0] id;
    } descriptor_t;

    typedef struct {
        byte unsigned data[$];
    } rx_pending_t;

    uvm_tlm_analysis_fifo #(virtio_transaction) notify_fifo;

    protected virtio_monitor       m_monitor;
    protected virtio_pci_transport m_transport;
    protected virtqueue_manager    m_vq_mgr;
    protected host_mem_manager     m_mem;
    protected virtio_iommu_model   m_iommu;
    protected pcie_tl_ep_driver    m_ep_driver;
    protected virtio_pcie_model_dma_adapter m_dma_adapter;
    protected bit                  m_bound;
    protected bit                  m_running;
    protected int unsigned         m_host_id;
    protected bit [15:0]           m_bdf;
    protected int unsigned         m_segment_id;
    protected int unsigned         m_notify_count;
    protected int unsigned         m_dma_read_count;
    protected int unsigned         m_dma_write_count;
    protected int unsigned         m_interrupt_count;
    protected int unsigned         m_completion_count;
    protected int unsigned         m_worker_count;
    protected int unsigned         m_epoch;
    protected queue_state_t        m_queues[int unsigned];
    protected bit                   m_queue_busy[int unsigned];
    protected int unsigned          m_split_next_avail[int unsigned];
    protected int unsigned          m_packed_next[int unsigned];
    protected bit                    m_packed_wrap[int unsigned];
    // 中文说明：待注入报文只是 DUT responder 的输入，真正的 RX buffer、
    // used ring 和中断更新仍必须经过 EP-originated PCIe DMA。
    protected rx_pending_t           m_rx_pending[int unsigned][$];

    // 创建未绑定、未运行 responder；计数器和 epoch 清零，不访问外部 PCIe/Host 对象。
    function new(string name = "virtio_pcie_dut_responder",
                 uvm_component parent = null);
        super.new(name, parent);
        m_bound = 0;
        m_running = 0;
        m_host_id = 0;
        m_bdf = '0;
        m_segment_id = 0;
        m_notify_count = 0;
        m_dma_read_count = 0;
        m_dma_write_count = 0;
        m_interrupt_count = 0;
        m_completion_count = 0;
        m_worker_count = 0;
        m_epoch = 0;
    endfunction

    // UVM 生命周期：只创建 notify FIFO；真正的外部句柄绑定延迟到 bind_function。
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        notify_fifo = new("notify_fifo", this);
    endfunction

    // 接口契约：输入 monitor/transport/vq_mgr/Host memory/IOMMU/EP driver，why 返回
    // 失败原因。成功会创建并连接 MODEL DMA adapter、订阅 monitor、清除 EP driver
    // 的 Host-memory 直通字段；不拥有或释放传入对象。失败条件包括任一句柄为空、
    // monitor txn_ap 为空、transport 未解析合法 BDF。仅支持 MODEL，重复绑定行为由
    // 调用方避免；REAL_DUT 不应调用此接口。
    function bit bind_function(
        virtio_monitor monitor,
        virtio_pci_transport transport,
        virtqueue_manager vq_mgr,
        host_mem_manager mem,
        virtio_iommu_model iommu,
        pcie_tl_ep_driver ep_driver,
        output string why
    );
        why = "";
        if (monitor == null) begin why = "monitor is null"; return 0; end
        if (transport == null) begin why = "transport is null"; return 0; end
        if (vq_mgr == null) begin why = "virtqueue manager is null"; return 0; end
        if (mem == null) begin why = "Host memory manager is null"; return 0; end
        if (iommu == null) begin why = "IOMMU model is null"; return 0; end
        if (ep_driver == null) begin why = "PCIe EP driver is null"; return 0; end
        if (monitor.txn_ap == null) begin why = "monitor transaction port is null"; return 0; end
        if (!transport.pcie_id_valid || transport.bdf == 16'h0) begin
            why = "transport has no resolved function BDF";
            return 0;
        end
        m_monitor = monitor;
        m_transport = transport;
        m_vq_mgr = vq_mgr;
        m_mem = mem;
        m_iommu = iommu;
        m_ep_driver = ep_driver;
        m_dma_adapter = virtio_pcie_model_dma_adapter::type_id::create(
            "model_dma_adapter");
        if (!m_dma_adapter.connect_ep(ep_driver, transport.bdf, why))
            return 0;
        m_host_id = transport.iommu_host_id();
        m_bdf = transport.bdf;
        m_segment_id = transport.pcie_id.domain.segment_id;

        // The EP driver owns the device BAR/configuration image in its sparse
        // mem_space.  Host memory belongs to the RC-side unified backend;
        // assigning it to the EP would make RC MMIO reads fetch Host memory
        // instead of the endpoint register image.  MODEL-originated DMA uses
        // the adapter's public send_tlp() path and therefore does not need
        // ep_driver.mem.
        m_ep_driver.mem = null;
        m_ep_driver.use_unified_mem = 0;
        m_bound = 1;
        monitor.txn_ap.connect(this.analysis_export);
        return 1;
    endfunction

    // 启动异步 notify 消费 worker；未 bind 时报告错误并返回，重复 start 为 no-op。
    // 成功只改变运行状态并 fork worker，不分配 ring、不发送 DMA。
    task start();
        if (!m_bound) begin
            `uvm_error("VIRTIO_RESP", "start called before bind_function")
            return;
        end
        if (m_running)
            return;
        m_running = 1;
        fork : responder_consumer
            consume_notifies();
        join_none
    endtask

    // uvm_component owns a task named stop(string), so keep the exact
    // override signature while allowing the no-argument responder API used by
    // tests through a default value.
    // 停止契约：禁止新 notify、递增 epoch、标记队列 reset、丢弃待注入 RX，并阻塞
    // 直到所有 worker 退出；无超时，若底层 DMA task 卡住可能持续等待。ph_name 仅
    // 为 UVM 生命周期兼容参数，不参与行为判断。
    virtual task stop(string ph_name = "");
        m_running = 0;
        m_epoch++;
        foreach (m_queues[qid]) begin
            m_queues[qid].enabled = 0;
            m_queues[qid].reset = 1;
            m_queue_busy[qid] = 0;
        end
        m_rx_pending.delete();
        // The consumer polls the FIFO with bounded waits, so this task
        // returns only after all workers have observed cancellation.
        while (m_worker_count != 0)
            #1ns;
    endtask

    // Kept as an explicit lifecycle alias for callers that want to document
    // the quiescence boundary separately from the UVM stop hook.
    // 仅等待 worker_count 归零，不再次修改 running/queue 状态，也没有超时机制。
    task wait_stopped();
        while (m_worker_count != 0)
            #1ns;
    endtask

    // 统计 getter：notify_count 为接受的合法 kick 数；DMA/interrupt/completion 计数
    // 由对应设备侧操作递增；只读，不触发队列或 PCIe 副作用。
    function int unsigned notify_count(); return m_notify_count; endfunction
    function int unsigned dma_read_count(); return m_dma_read_count; endfunction
    function int unsigned dma_write_count(); return m_dma_write_count; endfunction
    function int unsigned interrupt_count(); return m_interrupt_count; endfunction
    function int unsigned completion_count(); return m_completion_count; endfunction
    function bit running(); return m_running; endfunction

    // 将设备侧两个时序点转发给共享 virtqueue 错误注入器。REAL_DUT
    // 不创建本 responder，因此不会与真实 DUT 的 DMA 路径重复注入。
    // 在设备读取前或写 used 前消费共享 virtqueue fault。未知队列或无 manager 时
    // no-op；只会执行 queue 已支持的 descriptor mutation，REAL_DUT 不调用本类。
    protected function void consume_queue_fault(
        input int unsigned qid,
        input virtqueue_error_phase_e fault_phase
    );
        virtqueue_base vq;
        if ((m_vq_mgr == null) || !m_vq_mgr.has_queue(qid))
            return;
        vq = m_vq_mgr.get_queue(qid);
        if (vq != null)
            void'(vq.process_error_injection(fault_phase));
    endfunction

    // 该组件是没有 RTL DUT 时使用的设备行为模型。REAL_DUT 模式必须绕过
    // 它，避免模型和真实 DUT 同时消费 notify 或产生 DMA。
    // 固定返回 1，供 fixture 在选择 MODEL/REAL_DUT 执行主体时做能力判定。
    function bit model_only(); return 1'b1; endfunction

    // 能力检查：仅 VIRTIO_EXEC_MODEL 返回成功；不改变运行状态，失败原因写入 why。
    function bit can_start(
        input virtio_execution_mode_e mode,
        output string why
    );
        why = "";
        if (mode != VIRTIO_EXEC_MODEL) begin
            why = "virtio_pcie_dut_responder is MODEL-only";
            return 1'b0;
        end
        return 1'b1;
    endfunction

    // MODEL-only RX 注入接口：输入 packet 仅被 pack 成待处理字节并排入指定队列，
    // 不立即写 Host memory/used ring/中断；header 按 driver_features 编码。未绑定、
    // packet 为空或 pack 失败时 ok=0。REAL_DUT 没有此 responder，调用必然不可用。
    virtual task inject_rx_packet(
        input int unsigned queue_id,
        input virtio_net_hdr_t net_hdr,
        input uvm_object packet,
        output bit ok
    );
        rx_pending_t pending;
        byte unsigned hdr_bytes[$];
        byte unsigned pkt_bytes[$];
        ok = 0;
        if (!m_bound || (packet == null)) return;
        if (!virtio_net_packet_adapter::pack(packet, pkt_bytes)) return;
        virtio_net_hdr_util::pack_hdr(net_hdr, m_transport.driver_features,
                                      hdr_bytes);
        pending.data.delete();
        foreach (hdr_bytes[i]) pending.data.push_back(hdr_bytes[i]);
        foreach (pkt_bytes[i]) pending.data.push_back(pkt_bytes[i]);
        if (!m_rx_pending.exists(queue_id)) m_rx_pending[queue_id] = {};
        m_rx_pending[queue_id].push_back(pending);
        ok = 1;
    endtask

    // 接口契约：只接受 monitor 已判定的 queue kick 和 reset/queue-state 事件；其它
    // BAR 写、monitor_error、空事务直接丢弃。成功 kick 会递增 notify_count 并写入 FIFO，
    // reset 会推进 epoch/清理队列状态；本 callback 不阻塞等待 DMA。
    // Existing transaction FIFO is the contract boundary.  Only events that
    // observe_queue_notify() accepted (ATOMIC_KICK and !monitor_error) enter
    // the responder FIFO; arbitrary BAR writes can never start a worker.
    virtual function void write(virtio_transaction t);
        if (t == null)
            return;
        if (t.monitor_event == VIRTIO_MON_QUEUE_STATE) begin
            if (t.monitor_is_write)
                capture_queue_state(t);
            return;
        end
        if ((t.monitor_event == VIRTIO_MON_BAR_ACCESS) &&
            (t.txn_type == VIO_TXN_INIT) && t.monitor_is_write &&
            (t.monitor_bar_offset == VIRTIO_PCI_COMMON_STATUS) &&
            ((t.monitor_bar_id == 32'hffff_ffff) ||
             (m_transport != null) && (m_transport.cap_mgr != null) &&
             m_transport.cap_mgr.common_cfg_found &&
             (t.monitor_bar_id == m_transport.cap_mgr.common_cfg_cap.bar)) &&
            (t.monitor_data[7:0] == DEV_STATUS_RESET)) begin
            m_epoch++;
            foreach (m_queues[qid]) begin
                m_queues[qid].enabled = 0;
                m_queues[qid].reset = 1;
            end
            return;
        end
        if ((t.monitor_event != VIRTIO_MON_BAR_ACCESS) ||
            (t.txn_type != VIO_TXN_ATOMIC_OP) ||
            (t.atomic_op != ATOMIC_KICK) || t.monitor_error)
            return;
        m_notify_count++;
        if (notify_fifo != null)
            notify_fifo.write(t);
    endfunction

    // 增量捕获 common-config 队列寄存器；未知 queue 从确定的 reset struct 开始，随后
    // 用 vq_mgr 补 ring 类型/地址。只更新本模型的 queue_state，不写回 transport。
    protected function void capture_queue_state(virtio_transaction txn);
        queue_state_t q;
        int unsigned qid;
        qid = txn.queue_id;
        // An associative-array miss leaves a packed struct unknown.  Start
        // every newly observed queue from a deterministic reset state; later
        // common-config writes fill the individual fields incrementally.
        q = '{default: 0};
        if (m_queues.exists(qid)) q = m_queues[qid];
        q.reset = 0;
        case (txn.monitor_bar_offset)
            VIRTIO_PCI_COMMON_Q_SIZE: begin
                q.queue_size = txn.monitor_data[15:0];
                q.configured = (q.queue_size != 0);
            end
            VIRTIO_PCI_COMMON_Q_DESCLO: q.desc_iova[31:0] = txn.monitor_data[31:0];
            VIRTIO_PCI_COMMON_Q_DESCHI: q.desc_iova[63:32] = txn.monitor_data[31:0];
            VIRTIO_PCI_COMMON_Q_AVAILLO: q.driver_iova[31:0] = txn.monitor_data[31:0];
            VIRTIO_PCI_COMMON_Q_AVAILHI: q.driver_iova[63:32] = txn.monitor_data[31:0];
            VIRTIO_PCI_COMMON_Q_USEDLO: q.device_iova[31:0] = txn.monitor_data[31:0];
            VIRTIO_PCI_COMMON_Q_USEDHI: q.device_iova[63:32] = txn.monitor_data[31:0];
            VIRTIO_PCI_COMMON_Q_MSIX: q.msix_vector = txn.monitor_data[15:0];
            VIRTIO_PCI_COMMON_Q_ENABLE: begin
                q.enabled = txn.monitor_data[0];
                if (!q.enabled) q.reset = 1;
            end
            VIRTIO_PCI_COMMON_Q_RESET: begin
                if (txn.monitor_data[0]) begin
                    q.enabled = 0;
                    q.reset = 1;
                    m_epoch++;
                end
            end
            default: ;
        endcase
        if (m_vq_mgr != null) begin
            virtqueue_base vq;
            packed_virtqueue packed_vq;
            vq = m_vq_mgr.get_queue(qid);
            if (vq != null) begin
                q.ring_type = VQ_SPLIT;
                if ($cast(packed_vq, vq)) q.ring_type = VQ_PACKED;
                // The queue object is the source of truth when available.
                if (q.queue_size == 0) q.queue_size = vq.queue_size;
                if (q.desc_iova == 0) q.desc_iova = vq.desc_table_addr;
                if (q.driver_iova == 0) q.driver_iova = vq.driver_ring_addr;
                if (q.device_iova == 0) q.device_iova = vq.device_ring_addr;
            end
        end
        m_queues[qid] = q;
    endfunction

    // 后台 worker：轮询 FIFO，按 FIFO 顺序串行调用 process_notify；停止由 m_running
    // 控制，空 FIFO 以有限延时让出时间片。
    protected task consume_notifies();
        virtio_transaction txn;
        while (m_running) begin
            if (notify_fifo.try_get(txn)) begin
                // Process one accepted kick synchronously.  The DMA helpers
                // yield through the endpoint transaction path, so this keeps
                // the worker lifecycle deterministic while preserving the
                // FIFO ordering of device-side queue consumption.
                process_notify(txn);
            end
            else
                #1ns;
        end
    endtask

    // 处理单个 kick：校验 queue 存在/已配置/已使能且不忙，再按 Split/Packed 完成
    // descriptor、used ring 和中断。unknown/incomplete/busy/取消的队列会安全丢弃，
    // 输出仅通过 ok 和计数器体现，无直接返回给 monitor。
    protected task process_notify(virtio_transaction txn);
        queue_state_t q;
        int unsigned qid;
        int unsigned local_epoch;
        bit ok;

        m_worker_count++;
        qid = txn.queue_id;
        local_epoch = m_epoch;
        if (!m_queues.exists(qid)) begin
            `uvm_warning("VIRTIO_RESP", $sformatf(
                "Ignoring kick for unknown queue %0d", qid));
            m_worker_count--;
            return;
        end
        q = m_queues[qid];
        if (!q.configured || !q.enabled || q.reset || q.queue_size == 0 ||
            q.desc_iova == 0 || q.driver_iova == 0 || q.device_iova == 0) begin
            `uvm_warning("VIRTIO_RESP", $sformatf(
                "Ignoring kick for disabled/incomplete queue %0d", qid));
            m_worker_count--;
            return;
        end
        if (m_queue_busy.exists(qid) && m_queue_busy[qid]) begin
            m_worker_count--;
            return;
        end
        m_queue_busy[qid] = 1;
        if (q.ring_type == VQ_PACKED)
            complete_packed(qid, q, local_epoch, ok);
        else
            complete_split(qid, q, local_epoch, ok);
        m_queue_busy[qid] = 0;
        m_worker_count--;
    endtask

    // 任一运行停止、epoch 变化、队列不存在/禁用/reset 即视为取消，供长事务快速退出。
    protected function bit cancelled(input int unsigned epoch,
                                     input int unsigned qid);
        return !m_running || (epoch != m_epoch) ||
               !m_queues.exists(qid) || !m_queues[qid].enabled ||
               m_queues[qid].reset;
    endfunction

    // Split 完成路径：读取 avail idx/descriptor chain，执行 IOVA DMA 读写，写 used
    // entry/idx，更新 next_avail 并发中断；PRE_DEVICE_READ/BEFORE_USED fault 在相应
    // 边界消费。translation、环损坏或取消时 ok=0；无新 avail 时是正常空操作。
    protected task complete_split(
        input int unsigned qid,
        input queue_state_t q,
        input int unsigned epoch,
        output bit ok
    );
        bit [7:0] bytes[];
        bit [7:0] avail_bytes[];
        bit [15:0] avail_idx;
        int unsigned next;
        int unsigned avail_entry;
        descriptor_t descs[$];
        bit chain_ok;
        bit access_ok;
        int unsigned used_len;
        ok = 0;
        consume_queue_fault(qid, VQ_FAULT_PRE_DEVICE_READ);
        dma_read_iova(q.driver_iova + 2, 2, avail_bytes, qid, epoch, access_ok);
        if (!access_ok) return;
        avail_idx = le16(avail_bytes);
        next = m_split_next_avail.exists(qid) ? m_split_next_avail[qid] : 0;
        while ((next != avail_idx) && !cancelled(epoch, qid)) begin
            avail_entry = 4 + (next % q.queue_size) * 2;
            dma_read_iova(q.driver_iova + avail_entry, 2, bytes, qid, epoch, access_ok);
            if (!access_ok) return;
            read_split_chain(q, le16(bytes), descs, qid, epoch, chain_ok);
            if (!chain_ok) return;
            complete_descriptor_payload(descs, qid, epoch, access_ok,
                                        used_len);
            if (!access_ok) return;
            consume_queue_fault(qid, VQ_FAULT_BEFORE_USED);
            write_split_used(q, le16(bytes), used_len, qid, epoch, access_ok);
            if (!access_ok) return;
            next++;
            m_split_next_avail[qid] = next[15:0];
            m_completion_count++;
            emit_interrupt(q, qid);
        end
        ok = 1;
    endtask

    // Packed 完成路径：检查当前 wrap/flags，读取 descriptor chain，写回 USED wrap，
    // 更新 index/wrap 并发中断；输出 ok，非法链、DMA 失败或取消时提前返回。
    protected task complete_packed(
        input int unsigned qid,
        input queue_state_t q,
        input int unsigned epoch,
        output bit ok
    );
        descriptor_t descs[$];
        descriptor_t head;
        bit [7:0] bytes[];
        bit [15:0] flags;
        int unsigned index;
        bit wrap;
        bit access_ok;
        int unsigned used_len;
        ok = 0;
        index = m_packed_next.exists(qid) ? m_packed_next[qid] : 0;
        wrap = m_packed_wrap.exists(qid) ? m_packed_wrap[qid] : 1;
        consume_queue_fault(qid, VQ_FAULT_PRE_DEVICE_READ);
        dma_read_iova(q.desc_iova + index * 16 + 14, 2,
                      bytes, qid, epoch, access_ok);
        if (!access_ok) return;
        flags = le16(bytes);
        if (flags[7] != wrap) begin
            ok = 1;
            return;
        end
        read_packed_chain(q, index, wrap, descs, qid, epoch, access_ok);
        if (!access_ok) return;
        complete_descriptor_payload(descs, qid, epoch, access_ok, used_len);
        if (!access_ok) return;
        consume_queue_fault(qid, VQ_FAULT_BEFORE_USED);
        foreach (descs[d]) begin
            flags = descs[d].flags;
            flags[15] = wrap;
            bytes = new[2]; bytes[0] = flags[7:0]; bytes[1] = flags[15:8];
            dma_write_iova(q.desc_iova + (index + d) % q.queue_size * 16 + 14,
                           bytes, qid, epoch, access_ok);
            if (!access_ok) return;
        end
        index++;
        if (index >= q.queue_size) begin index = 0; wrap = ~wrap; end
        m_packed_next[qid] = index;
        m_packed_wrap[qid] = wrap;
        m_completion_count++;
        emit_interrupt(q, qid);
        ok = 1;
    endtask

    // 根据 descriptor flags 区分设备可读 TX buffer 与可写 RX buffer；从 pending RX
    // 队列取 payload，跨多个 writable descriptor 写回并产生 used_len。容量不足、
    // DMA 失败或取消时 ok=0，成功消费对应 pending packet。
    protected task complete_descriptor_payload(
        input descriptor_t descs[$], input int unsigned qid,
        input int unsigned epoch,
        output bit ok, output int unsigned used_len
    );
        bit [7:0] payload[$];
        bit [7:0] data[];
        bit access_ok;
        int unsigned cursor;
        ok = 0;
        used_len = 0;
        cursor = 0;
        foreach (descs[d]) begin
            if (cancelled(epoch, qid)) return;
            if (!(descs[d].flags & VIRTQ_DESC_F_WRITE)) begin
                if (descs[d].len == 0) return;
                dma_read_iova(descs[d].addr, descs[d].len, data, qid, epoch,
                              access_ok);
                if (!access_ok) return;
                foreach (data[i]) payload.push_back(data[i]);
            end
        end
        if ((payload.size() == 0) && m_rx_pending.exists(qid) &&
            (m_rx_pending[qid].size() != 0)) begin
            foreach (m_rx_pending[qid][0].data[i])
                payload.push_back(m_rx_pending[qid][0].data[i]);
        end
        // A chain with writable buffers is an RX destination.  Copy the
        // payload gathered from device-readable descriptors into it.  A TX
        // chain with no writable buffer is still completed normally.
        foreach (descs[d]) begin
            if (descs[d].flags & VIRTQ_DESC_F_WRITE) begin
                int unsigned available = (cursor < payload.size()) ?
                                          payload.size() - cursor : 0;
                int unsigned count = (descs[d].len < available) ?
                                      descs[d].len : available;
                data = new[count];
                for (int i = 0; i < count; i++) data[i] = payload[cursor + i];
                dma_write_iova(descs[d].addr, data, qid, epoch, access_ok);
                if (!access_ok) return;
                cursor += count;
            end
        end
        if ((m_rx_pending.exists(qid)) &&
            (m_rx_pending[qid].size() != 0) &&
            (cursor < payload.size())) begin
            `uvm_error("VIRTIO_RESP", $sformatf(
                "RX packet does not fit writable descriptor chain queue=%0d payload=%0d written=%0d",
                qid, payload.size(), cursor))
            return;
        end
        used_len = payload.size();
        if ((payload.size() != 0) && m_rx_pending.exists(qid) &&
            (m_rx_pending[qid].size() != 0) && (cursor != 0)) begin
            m_rx_pending[qid].pop_front();
            if (m_rx_pending[qid].size() == 0) m_rx_pending.delete(qid);
        end
        ok = 1;
    endtask

    // 读取 Split 链并输出标准 descriptor 数组；检查 index 上界和 safety 防循环，
    // INDIRECT 只允许合法长度且拒绝嵌套。DMA/格式/取消失败时 ok=0。
    protected task read_split_chain(
        input queue_state_t q,
        input int unsigned head,
        ref descriptor_t descs[$],
        input int unsigned qid,
        input int unsigned epoch,
        output bit ok
    );
        int unsigned current;
        int unsigned safety;
        descs.delete(); ok = 0;
        current = head;
        safety = 0;
        do begin
            descriptor_t d;
            bit [7:0] bytes[];
            if ((current >= q.queue_size) || (safety++ > q.queue_size)) return;
            dma_read_iova(q.desc_iova + current * 16, 16,
                          bytes, qid, epoch, ok);
            if (!ok) return;
            d.addr = le64(bytes); d.len = le32(bytes, 8);
            d.flags = le16(bytes, 12); d.next = le16(bytes, 14); d.id = current;
            if ((d.flags & VIRTQ_DESC_F_INDIRECT) != 0) begin
                descriptor_t indirect[$];
                if ((d.len == 0) || ((d.len % 16) != 0)) return;
                read_indirect_chain(d.addr, d.len, indirect, qid, epoch, ok);
                if (!ok) return;
                foreach (indirect[i]) descs.push_back(indirect[i]);
                break;
            end
            descs.push_back(d);
            if (!(d.flags & VIRTQ_DESC_F_NEXT)) break;
            current = d.next;
        end while (!cancelled(epoch, qid));
        ok = (descs.size() != 0);
    endtask

    // 读取 Packed 链并输出 descriptor 数组；按 ring index/wrap 遍历，限制 safety，
    // 拒绝非法 INDIRECT/嵌套。DMA 或取消失败时 ok=0。
    protected task read_packed_chain(
        input queue_state_t q, input int unsigned start, input bit wrap,
        ref descriptor_t descs[$], input int unsigned qid,
        input int unsigned epoch,
        output bit ok
    );
        int unsigned index;
        int unsigned safety;
        descs.delete(); index = start; safety = 0; ok = 0;
        do begin
            descriptor_t d; bit [7:0] bytes[];
            if (safety++ > q.queue_size) return;
            dma_read_iova(q.desc_iova + index * 16, 16,
                          bytes, qid, epoch, ok);
            if (!ok) return;
            d.addr = le64(bytes); d.len = le32(bytes, 8);
            d.id = le16(bytes, 12); d.flags = le16(bytes, 14);
            if ((d.flags & VIRTQ_DESC_F_INDIRECT) != 0) begin
                descriptor_t indirect[$];
                if ((d.len == 0) || ((d.len % 16) != 0)) return;
                read_indirect_chain(d.addr, d.len, indirect, qid, epoch, ok);
                if (!ok) return;
                foreach (indirect[i]) descs.push_back(indirect[i]);
                break;
            end
            descs.push_back(d);
            if (!(d.flags & VIRTQ_DESC_F_NEXT)) break;
            index++; if (index >= q.queue_size) index = 0;
        end while (!cancelled(epoch, qid));
        ok = (descs.size() != 0);
    endtask

    // 读取间接表并展开到输出队列；table_bytes 必须是 16 字节整数倍，禁止嵌套和
    // 越界 next。失败时清空/保持无效 descs 并返回 ok=0。
    protected task read_indirect_chain(
        input bit [63:0] table_iova, input int unsigned table_bytes,
        ref descriptor_t descs[$], input int unsigned qid,
        input int unsigned epoch,
        output bit ok
    );
        int unsigned index;
        int unsigned count;
        descs.delete(); count = table_bytes / 16; ok = 0;
        for (index = 0; index < count; index++) begin
            descriptor_t d; bit [7:0] bytes[];
            dma_read_iova(table_iova + index * 16, 16,
                          bytes, qid, epoch, ok);
            if (!ok) return;
            d.addr = le64(bytes); d.len = le32(bytes, 8);
            d.flags = le16(bytes, 12); d.next = le16(bytes, 14); d.id = index;
            if (d.flags & VIRTQ_DESC_F_INDIRECT) return;
            descs.push_back(d);
            if (!(d.flags & VIRTQ_DESC_F_NEXT)) break;
            if (d.next >= count) return;
            index = d.next - 1;
        end
        ok = (descs.size() != 0);
    endtask

    // 读取 used idx、写入 used element 和递增 idx；所有访问经 IOVA DMA helper，
    // 输出 ok=0 表示翻译/PCIe Completion/取消失败。
    protected task write_split_used(
        input queue_state_t q, input int unsigned head,
        input int unsigned used_len, input int unsigned qid,
        input int unsigned epoch,
        output bit ok
    );
        bit [7:0] bytes[];
        bit [15:0] used_idx;
        ok = 0;
        dma_read_iova(q.device_iova + 2, 2, bytes, qid, epoch, ok);
        if (!ok) return;
        used_idx = le16(bytes);
        bytes = new[8];
        bytes[0] = head[7:0]; bytes[1] = head[15:8];
        bytes[2] = 0; bytes[3] = 0;
        bytes[4] = used_len[7:0]; bytes[5] = used_len[15:8];
        bytes[6] = used_len[23:16]; bytes[7] = used_len[31:24];
        dma_write_iova(q.device_iova + 4 + (used_idx % q.queue_size) * 8,
                       bytes, qid, epoch, ok);
        if (!ok) return;
        bytes = new[2];
        bytes[0] = (used_idx + 1) & 8'hff;
        bytes[1] = (used_idx + 1) >> 8;
        dma_write_iova(q.device_iova + 2, bytes, qid, epoch, ok);
    endtask

    // 按队列 MSI-X vector 触发 MODEL sideband；IRQ_POLLING 不发中断，无有效 vector
    // 仅 warning。计数器只在实际调用 notify_mgr 成功分支递增，REAL_DUT 不执行此 task。
    protected task emit_interrupt(input queue_state_t q, input int unsigned qid);
        int unsigned vector;
        if (m_transport == null || m_ep_driver == null)
            return;
        vector = q.msix_vector;
        if (m_transport.notify_mgr != null &&
            m_transport.notify_mgr.msix_table.size() > vector) begin
            // MODEL mode uses the transport's interrupt sideband.  The
            // external pcie_work package intentionally treats every EP
            // Memory Write as ordinary host-memory traffic; sending the
            // architectural x86 MSI address (0xFEE0_0000) through that path
            // would incorrectly ask host_mem to back the APIC aperture.
            // REAL_DUT remains passive and observes the actual MSI-X TLP.
            m_transport.notify_mgr.on_interrupt_received(vector);
            m_interrupt_count++;
            return;
        end
        if (m_transport.notify_mgr != null &&
            m_transport.notify_mgr.irq_mode == IRQ_POLLING)
            return;
        `uvm_warning("VIRTIO_RESP", $sformatf(
            "queue %0d has no programmed MSI-X vector", qid));
    endtask

    // 设备读 Host：输入 IOVA/长度，按 IOVA 与翻译后 GPA 的 4KiB 边界切块，经 IOMMU
    // translate 和 MODEL PCIe Completion 读取；取消、翻译失败、Completion 超时/短读
    // 时 ok=0，成功输出完整 data 并递增 DMA read 计数，不直接读 m_mem。
    protected task dma_read_iova(
        input bit [63:0] iova, input int unsigned size,
        output bit [7:0] data[], input int unsigned qid,
        input int unsigned epoch, output bit ok
    );
        bit [63:0] gpa;
        bit [63:0] probe_gpa;
        iommu_fault_e fault;
        byte accum[$];
        ok = 0;
        data = new[0];
        accum.delete();
        if (cancelled(epoch, qid)) return;
        if (size == 0) begin ok = 1; return; end

        // The EP helper emits one legal PCIe Memory Read at a time.  Split
        // large or page-crossing accesses here so jumbo RX/TX buffers still
        // traverse the same Completion-backed PCIe path instead of falling
        // back to a direct host-memory read.
        for (int unsigned offset = 0; offset < size; ) begin
            int unsigned chunk;
            int unsigned iova_page_left;
            int unsigned gpa_page_left;
            bit [7:0] part[];

            if (cancelled(epoch, qid)) return;
            if (!m_iommu.translate_for_host(m_host_id, m_bdf, iova + offset,
                                            1, DMA_TO_DEVICE, probe_gpa,
                                            fault)) begin
                `uvm_error("VIRTIO_RESP", $sformatf(
                    "DMA read probe translation failed queue=%0d host=%0d segment=%0d BDF=0x%04x IOVA=0x%016h fault=%s",
                    qid, m_host_id, m_segment_id, m_bdf, iova + offset,
                    fault.name()));
                return;
            end
            iova_page_left = 4096 - int'((iova + offset) & 64'hfff);
            gpa_page_left  = 4096 - int'(probe_gpa & 64'hfff);
            chunk = size - offset;
            if (chunk > 4096) chunk = 4096;
            if (chunk > iova_page_left) chunk = iova_page_left;
            if (chunk > gpa_page_left)  chunk = gpa_page_left;
            if (!m_iommu.translate_for_host(m_host_id, m_bdf, iova + offset,
                                            chunk, DMA_TO_DEVICE, gpa,
                                            fault)) begin
                `uvm_error("VIRTIO_RESP", $sformatf(
                    "DMA read translation failed queue=%0d host=%0d segment=%0d BDF=0x%04x IOVA=0x%016h size=%0d fault=%s",
                    qid, m_host_id, m_segment_id, m_bdf, iova + offset,
                    chunk, fault.name()));
                return;
            end
            m_dma_adapter.read(gpa, chunk, part);
            if (part.size() != chunk) return;
            foreach (part[i]) accum.push_back(part[i]);
            offset += chunk;
            m_dma_read_count++;
        end
        data = new[accum.size()];
        foreach (accum[i]) data[i] = accum[i];
        ok = (data.size() == size);
    endtask

    // 设备写 Host：输入 IOVA/字节，按页切块，经 IOMMU validate 和 MODEL MemWr 写入；
    // 取消、权限/翻译失败或适配器拒绝时 ok=0，成功递增 DMA write 计数，不直接写 m_mem。
    protected task dma_write_iova(
        input bit [63:0] iova, input bit [7:0] data[],
        input int unsigned qid, input int unsigned epoch, output bit ok
    );
        bit [63:0] gpa;
        bit [63:0] probe_gpa;
        iommu_fault_e fault;
        ok = 0;
        if (cancelled(epoch, qid)) return;
        if (data.size() == 0) begin ok = 1; return; end

        for (int unsigned offset = 0; offset < data.size(); ) begin
            int unsigned chunk;
            int unsigned iova_page_left;
            int unsigned gpa_page_left;
            bit [7:0] part[];

            if (cancelled(epoch, qid)) return;
            if (!m_iommu.validate_for_host(m_host_id, m_bdf, iova + offset,
                                           1, DMA_FROM_DEVICE, probe_gpa,
                                           fault)) begin
                `uvm_error("VIRTIO_RESP", $sformatf(
                    "DMA write probe translation failed queue=%0d host=%0d segment=%0d BDF=0x%04x IOVA=0x%016h fault=%s",
                    qid, m_host_id, m_segment_id, m_bdf, iova + offset,
                    fault.name()));
                return;
            end
            iova_page_left = 4096 - int'((iova + offset) & 64'hfff);
            gpa_page_left  = 4096 - int'(probe_gpa & 64'hfff);
            chunk = data.size() - offset;
            if (chunk > 4096) chunk = 4096;
            if (chunk > iova_page_left) chunk = iova_page_left;
            if (chunk > gpa_page_left)  chunk = gpa_page_left;
            if (!m_iommu.validate_for_host(m_host_id, m_bdf, iova + offset,
                                           chunk, DMA_FROM_DEVICE, gpa,
                                           fault)) begin
                `uvm_error("VIRTIO_RESP", $sformatf(
                    "DMA write translation failed queue=%0d host=%0d segment=%0d BDF=0x%04x IOVA=0x%016h size=%0d fault=%s",
                    qid, m_host_id, m_segment_id, m_bdf, iova + offset,
                    chunk, fault.name()));
                return;
            end
            part = new[chunk];
            for (int unsigned i = 0; i < chunk; i++)
                part[i] = data[offset + i];
            m_dma_adapter.write(gpa, part);
            offset += chunk;
            m_dma_write_count++;
        end
        ok = 1;
    endtask

    // little-endian 解码辅助；输入不足时返回 0，不产生副作用。
    protected function bit [15:0] le16(
        input bit [7:0] data[], input int unsigned off = 0
    );
        return (data.size() >= off + 2) ?
               {data[off + 1], data[off]} : 0;
    endfunction
    protected function bit [31:0] le32(input bit [7:0] data[], input int unsigned off = 0);
        return (data.size() >= off + 4) ?
               {data[off + 3], data[off + 2], data[off + 1], data[off]} : 0;
    endfunction
    protected function bit [63:0] le64(input bit [7:0] data[]);
        return (data.size() >= 8) ?
               {data[7], data[6], data[5], data[4], data[3], data[2], data[1], data[0]} : 0;
    endfunction
endclass

`endif
