// tests：验证逐包 SG 参数、真实 DMA 字节及 Packed/Custom 跨圈流控。
// 复用已有 offload fixture；设备只按 Notify 游标完成已通知的包，不读取生产链记录。
// 测试拥有 packet/fixture，ops 拥有 DMA；每轮检查完成和分配计数，不靠销毁掩盖泄漏。

// 暴露生产 AIP 参数入口，仅用于采样断言；不复制解析器或参数存储。
class virtio_segment_param_probe extends virtio_aip_sequence;
    // 构造真实参数入口，默认使用 vio.tx；不创建额外参数存储。
    extern function new(string	name = "segment_params");

    // 输出值副本；运行期修改不能改变已采样的请求。
    extern function void sample(output virtio_tx_seg_t	request);
endclass

function virtio_segment_param_probe::new(string	name = "segment_params");
    super.new(name);
    path = "vio.tx";
endfunction

function void virtio_segment_param_probe::sample(output virtio_tx_seg_t	request);
    load_tx_segments(request);
endfunction

// 只捕获本测试指定的参数 fatal，核对完整消息；其他 fatal 不能豁免。
class virtio_segment_fatal_catcher extends uvm_report_catcher;
    string		expected;
    int unsigned	caught;

    // 仅初始化捕获器；调用方按每次用例设置 expected 并注册/撤销。
    extern function new(string	name = "segment_fatal");
    // 只捕获匹配的参数 fatal，其余报告按正常 UVM 流程处理。
    extern virtual function action_e catch();
endclass

function virtio_segment_fatal_catcher::new(string	name = "segment_fatal");
    super.new(name);
endfunction

function uvm_report_catcher::action_e virtio_segment_fatal_catcher::catch();
    if (get_severity() == UVM_FATAL && get_id() == "VIO_TX_SEG" && get_message() == expected) begin
        caught++;
        return CAUGHT;
    end
    return THROW;
endfunction

// 复用 offload fixture 的报文/内存能力，新增独立设备消费循环验证 SG 和回收。
class virtio_tx_segments_test extends virtio_tx_offload_test;
    `uvm_component_utils(virtio_tx_segments_test)

    virtio_segment_param_probe	probe;
    int unsigned		checked_packets;
    int unsigned		checked_descriptors;

    // 父类只提供报文和内存助手；本类 run_phase 独立安排分段测试。
    extern function new(string	name, uvm_component	parent);
    // 经真实 AIP 命令更新参数，失败立即停止，不直接改参数数据库。
    extern task set_value(string	name, string	value);
    // 核对固定/范围/运行期切换、值副本和别名隔离。
    extern task check_segment_params();
    // 遍历实际描述符，核对数量/长度/地址和重组字节；返回实际占用槽数。
    extern function int unsigned check_segments(virtqueue_base	vq, int unsigned	head,
        packet_item	item, virtio_tx_offload_t	offload, virtio_tx_seg_t	segments);
    // 设备延迟完成，生产者只能依靠正常等待回收继续；验证尾批和 DB 实际游标。
    extern task check_segment_streams();
    // 非法参数必须在本包 DMA/描述符/DB 之前 fatal，环满仍由正常等待处理。
    extern task check_invalid_segments();
    // 完成项已覆盖 NEXT 后保存/恢复，验证链元数据和 AVAIL/USED 双位门禁。
    extern function void check_packed_snapshot();
    // 仅创建本测试资源，结束前显式完成所有包并检查内存。
    extern virtual task run_phase(uvm_phase	phase);
endclass

function virtio_tx_segments_test::new(string	name, uvm_component	parent);
    super.new(name, parent);
endfunction

task virtio_tx_segments_test::set_value(string	name, string	value);
    int		status;
    string	result;

    aip_cmd::exec_result({"set_param path=vio.tx.", name, " value=", value},
                        SRC_INTERNAL, status, result);
    require_true(status == 0, result);
endtask

task virtio_tx_segments_test::check_segment_params();
    virtio_tx_seg_t	first;
    virtio_tx_seg_t	next_request;
    bit			seen[int unsigned];
    virtio_transaction	original;
    virtio_transaction	copied;

    // CLI 场景先核对启动参数，随后再用 set_param 覆盖，验证同一入口的优先级。
    if ($test$plusargs("SEG_CLI")) begin
        probe.sample(first);
        require_true(first.count_set && first.desc_count == 9 && first.mode == VIO_SEG_RANDOM,
            "CLI segment parameters reach the production sampler");
    end
    set_value("desc_count", "[8:10]");
    set_value("seg_mode", "VIO_SEG_RANDOM");
    repeat (100) begin
        probe.sample(first);
        require_true(first.count_set && first.desc_count inside {[8:10]} &&
            first.mode == VIO_SEG_RANDOM, "AIP range sampled per packet");
        seen[first.desc_count] = 1;
    end
    require_true(seen.num() == 3, "range sampling covered 8, 9 and 10 descriptors");
    set_value("desc_count", "2");
    set_value("seg_mode", "VIO_SEG_EQUAL");
    probe.sample(next_request);
    require_true(next_request.desc_count == 2 && next_request.mode == VIO_SEG_EQUAL &&
        first.desc_count inside {[8:10]} && first.mode == VIO_SEG_RANDOM,
        "runtime parameters do not alter an earlier packet");
    original = new("original");
    copied = new("copied");
    original.tx_seg = first;
    copied.copy(original);
    require_true(copied.tx_seg == first, "transaction copy preserves SG request");
    probe.path = "vio.tx_other";
    probe.sample(next_request);
    require_true(!next_request.count_set && next_request.mode == VIO_SEG_EQUAL,
        "another TX alias retains independent defaults");
    probe.path = "vio.tx";
endtask

// 期望 offload 字节沿用已独立验证的 adapter；本测试独立遍历 SG、拼接 DMA，
// 不用被测分段函数生成期望长度或地址。
function int unsigned virtio_tx_segments_test::check_segments(
    virtqueue_base	vq, int unsigned	head, packet_item	item,
    virtio_tx_offload_t	offload, virtio_tx_seg_t	segments
);
    byte unsigned		expected[$];
    byte unsigned		actual[$];
    byte			data[];
    virtio_net_hdr_t		hdr;
    vio_private_tx_offload_t	control;
    string			why;
    bit				private_format;
    int unsigned		fixed_slots;
    int unsigned		data_count;
    int unsigned		length;
    int unsigned		slot;
    int unsigned		total;
    int unsigned		min_length;
    int unsigned		max_length;
    bit [63:0]			address;
    bit [63:0]			next_address;
    bit [31:0]			word2;
    bit [15:0]			buffer_id;

    private_format = vq.descriptor_format() == VQ_CUSTOM;
    expected = item.pkt.raw_data;
    require_true(virtio_net_packet_adapter::prepare_tx(expected, offload, private_format,
        ops.negotiated_features, hdr, control, why), why);
    fixed_slots = private_format ? int'(control.tso) : 1;
    data_count = segments.desc_count - fixed_slots;
    min_length = '1;
    max_length = 0;
    total = 0;
    next_address = 0;
    buffer_id = read_le(vq.desc_table_addr + head * 16 + 12, 2);

    if (!private_format)
        require_true(read_le(vq.desc_table_addr + head * 16 + 8, 4) == 12,
            "standard header remains one complete 12-byte descriptor");
    else if (control.tso) begin
        word2 = read_le(vq.desc_table_addr + head * 16 + 12, 4);
        require_true(word2[15] && word2[16], "Custom TSO extension remains first and chained");
    end

    for (int unsigned i = 0; i < segments.desc_count; i++) begin
        slot = (head + i) % vq.queue_size;
        word2 = read_le(vq.desc_table_addr + slot * 16 + 12, 4);
        if (!private_format) begin
            require_true(word2[15:0] == buffer_id, "one packet carries one Buffer ID including tail");
            require_true(word2[16] == (i + 1 < segments.desc_count), "Packed NEXT chain length");
        end else begin
            require_true(word2[16] == (i + 1 < segments.desc_count), "Custom NEXT chain length");
        end
        if (i < fixed_slots) continue;
        length = read_le(vq.desc_table_addr + slot * 16 + 8, 4);
        if (private_format) length &= 18'h3ffff;
        address = read_le(vq.desc_table_addr + slot * 16, 8);
        require_true(length != 0 && (!private_format || length <= 65536), "positive legal segment length");
        if (i > fixed_slots)
            require_true(address == next_address, "segments reference consecutive bytes of one DMA buffer");
        next_address = address + length;
        read_dma(address, length, data);
        foreach (data[j]) actual.push_back(data[j]);
        total += length;
        if (length < min_length) min_length = length;
        if (length > max_length) max_length = length;
        if (segments.mode == VIO_SEG_EQUAL)
            require_true(length == expected.size()/data_count + int'(i-fixed_slots < expected.size()%data_count),
                "equal split distributes remainder without losing bytes");
    end
    require_true(total == expected.size() && actual == expected, "SG reconstruction equals original offload packet");
    if (segments.mode == VIO_SEG_EQUAL)
        require_true(max_length - min_length <= 1, "equal segments differ by at most one byte");
    checked_packets++;
    checked_descriptors += segments.desc_count;
    return segments.desc_count;
endfunction

task virtio_tx_segments_test::check_segment_streams();
    virtqueue_base	vq;
    custom_virtqueue	private_vq;
    packet_item		item;
    virtio_net_hdr_t	hdr;
    virtio_tx_offload_t	offload;
    virtio_tx_seg_t	segments;
    uvm_object		completed[$];
    int unsigned	heads[$];
    int unsigned	counts[$];
    int unsigned	depth;
    int unsigned	packet_count;
    int unsigned	head;
    int unsigned	actual_count;
    int unsigned	published_slots;
    int unsigned	consumed_slots;
    int unsigned	consumed_packets;
    int unsigned	kicks_seen;
    int unsigned	kick_start;
    int unsigned	target_tail;
    bit			target_wrap;
    int unsigned	batch_left;
    int unsigned	maps_before;
    byte		cq[2];
    bit			fixed_two;

    depth = 256;
    packet_count = 2000;
    void'($value$plusargs("SEG_DEPTH=%d", depth));
    void'($value$plusargs("SEG_PACKETS=%d", packet_count));
    fixed_two = $test$plusargs("SEG_FIXED2");
    require_true(depth inside {16, 32, 128, 256} && packet_count >= 200, "valid stress dimensions");
    hdr = '{default:0};

    for (int mode = 0; mode < 3; mode++) begin
        for (int split_mode = 0; split_mode < 2; split_mode++) begin
            if (mode == 0) begin
                vq = kit.add_packed(1, depth);
                private_vq = null;
            end else begin
                require_true($cast(private_vq, kit.vq_mgr.create_queue(1, depth, VQ_CUSTOM)), "Custom stream queue");
                private_vq.local_qid = 1;
                private_vq.alloc_rings();
                vq = private_vq;
            end
            ops.negotiated_features = mode == 0 ? features : 0;
            set_value("desc_count", fixed_two ? (mode == 1 ? "1" : "2") :
                (mode == 0 ? "[8:10]" : (mode == 1 ? "[1:7]" : "[2:8]")));
            set_value("seg_mode", split_mode == 0 ? "VIO_SEG_EQUAL" : "VIO_SEG_RANDOM");
            heads.delete();
            counts.delete();
            published_slots = 0;
            consumed_slots = 0;
            consumed_packets = 0;
            kick_start = transport.kick_count;
            kicks_seen = kick_start;
            batch_left = 0;

            fork
                begin : sender
                    for (int n = 0; n < packet_count; n++) begin
                        item = make_packet($urandom_range(0, 1) ? ETH_IPV4_TCP : ETH_IPV6_TCP,
                                           fixed_two ? 512 : $urandom_range(128, 8192));
                        offload = '{valid:1, csum:bit'($urandom_range(0, 1)),
                            gso:(mode == 2 || (mode == 0 && $urandom_range(0, 1))), mss:32};
                        probe.sample(segments);
                        if (batch_left == 0) batch_left = fixed_two ? 1 : $urandom_range(16, 64);
                        maps_before = iommu.total_maps;
                        ops.tx_submit(1, hdr, item, 0, head, offload, 100,
                            (batch_left == 1 || n + 1 == packet_count), segments);
                        require_true(head == published_slots % depth, "producer cursor follows actual descriptor count");
                        actual_count = check_segments(vq, head, item, offload, segments);
                        require_true(iommu.total_maps - maps_before == (mode == 0 ? 2 : 1),
                            "SG count does not multiply DMA allocations");
                        heads.push_back(head);
                        counts.push_back(actual_count);
                        published_slots += actual_count;
                        batch_left--;
                    end
                end
                begin : device
                    while (consumed_packets < packet_count) begin
                        wait (transport.kick_count > kicks_seen);
                        kicks_seen = transport.kick_count;
                        target_tail = transport.last_kick_next_avail_idx;
                        target_wrap = transport.last_kick_wrap_counter;
                        #($urandom_range(10, 30) * 1ns);
                        // 只消费通知游标之前的整包；未通知尾批不能被提前完成。
                        while (consumed_slots % depth != target_tail ||
                               !((consumed_slots / depth) % 2) != target_wrap) begin
                            require_true(consumed_packets < heads.size(), "Notify never exposes an unsubmitted packet");
                            if (mode == 0)
                                virtio_vq_test_kit::complete_packed(kit.mem, vq, heads[consumed_packets]);
                            consumed_slots += counts[consumed_packets];
                            consumed_packets++;
                        end
                        if (mode != 0) begin
                            cq = '{target_tail[7:0], {target_wrap, target_tail[14:8]}};
                            kit.mem.write_mem(private_vq.cq_addr, cq);
                        end
                    end
                end
            join
            completed.delete();
            ops.tx_complete(1, completed, depth);
            require_true(consumed_packets == packet_count && vq.total_poll_used_ops == packet_count &&
                vq.get_free_count() == (mode == 0 ? depth : depth-1) &&
                iommu.total_maps == iommu.total_unmaps, "all packets including tail batch complete without leaks");
            `uvm_info("TX_SEG_STREAM", $sformatf(
                "mode=%0d split=%0d depth=%0d packets=%0d descriptors=%0d DBs=%0d",
                mode, split_mode, depth, packet_count, published_slots, transport.kick_count-kick_start), UVM_NONE)
            kit.vq_mgr.destroy_all();
        end
    end
endtask

task virtio_tx_segments_test::check_invalid_segments();
    virtqueue_base			vq;
    custom_virtqueue			private_vq;
    virtio_segment_fatal_catcher	catcher;
    packet_item				item;
    virtio_tx_offload_t			offload;
    virtio_tx_seg_t			segments;
    virtio_net_hdr_t			hdr;
    int unsigned			head;
    int unsigned			depth;
    int unsigned			packet_length;
    int unsigned			maps_before;
    int unsigned			kicks_before;
    int unsigned			minimum;
    int unsigned			maximum;
    byte				before_ring[];
    byte				after_ring[];
    string				format_name;

    hdr = '{default:0};
    catcher = new();
    for (int mode = 0; mode < 4; mode++) begin
        depth = mode == 3 ? 128 : 16;
        packet_length = mode == 3 ? 64 : 512;
        item = make_packet(ETH_IPV4_TCP, packet_length);
        if (mode == 0 || mode == 3) begin
            vq = kit.add_packed(1, depth);
            format_name = "VQ_PACKED";
        end else begin
            require_true($cast(private_vq, kit.vq_mgr.create_queue(1, 16, VQ_CUSTOM)), "Custom negative queue");
            private_vq.local_qid = 1;
            private_vq.alloc_rings();
            vq = private_vq;
            format_name = "VQ_CUSTOM";
        end
        ops.negotiated_features = (mode == 0 || mode == 3) ? features : 0;
        offload = '{valid:1, csum:0, gso:(mode == 2), mss:32};
        minimum = mode == 1 ? 1 : 2;
        maximum = mode == 0 ? 16 : (mode == 3 ? 65 : (mode == 1 ? 7 : 8));
        for (int bad = 0; bad < 3; bad++) begin
            segments = '{count_set:1, desc_count:(bad == 0 ? 0 : (bad == 1 ? minimum-1 : maximum+1)),
                mode:VIO_SEG_RANDOM};
            catcher.expected = $sformatf(
                "queue=1 format=%s packet_length=%0d desc_count=%0d allowed=[%0d:%0d]",
                format_name, packet_length, segments.desc_count, minimum, maximum);
            maps_before = iommu.total_maps;
            kicks_before = transport.kick_count;
            kit.mem.read_mem(vq.desc_table_addr, 16*depth, before_ring);
            uvm_report_cb::add(null, catcher);
            ops.tx_submit(1, hdr, item, 0, head, offload, 100, 1, segments);
            uvm_report_cb::delete(null, catcher);
            kit.mem.read_mem(vq.desc_table_addr, 16*depth, after_ring);
            require_true(catcher.caught == 1 && head == '1 && before_ring == after_ring &&
                iommu.total_maps == maps_before && transport.kick_count == kicks_before,
                "invalid count fatals before DMA, descriptor publication or Notify");
            catcher.caught = 0;
        end
        kit.vq_mgr.destroy_all();
    end
endtask

function void virtio_tx_segments_test::check_packed_snapshot();
    packed_virtqueue		source_vq;
    packed_virtqueue		destination;
    virtqueue_snapshot_t	snapshot;
    virtio_sg_list		sgs[1];
    virtio_sg_entry		entry;
    uvm_object			packet_token;
    uvm_object			completed_token;
    int unsigned		head;
    int unsigned		length;
    byte			flags[2];

    source_vq = kit.make_packed("snapshot_source", 1, 8, 16'h1);
    // USED=1/AVAIL=0 不属于首圈完成，旧版只检查 USED 会误判。
    flags = '{0, 8'h80};
    kit.mem.write_mem(source_vq.desc_table_addr + 14, flags);
    require_true(!source_vq.vq_poll(0), "used bit alone is not a completion");
    kit.mem.mem_set(source_vq.desc_table_addr, 0, 16*8);
    packet_token = virtio_transaction::type_id::create("snapshot_packet");
    for (int i = 0; i < 3; i++) begin
        entry = '{default:0};
        entry.addr = 64'h200000 + i*32;
        entry.len = 32;
        sgs[0].entries.push_back(entry);
    end
    head = source_vq.add_buf(sgs, 1, 0, packet_token, 0);
    virtio_vq_test_kit::complete_packed(kit.mem, source_vq, head);
    source_vq.save_state(snapshot);
    source_vq.free_rings();
    destination = kit.make_packed("snapshot_destination", 1, 8, 16'h1);
    require_true(destination.restore_state(snapshot), "restore pending chain metadata after completion overwrote NEXT");
    require_true(destination.poll_used(completed_token, length) && completed_token == packet_token &&
        destination.get_free_count() == 8, "restored completion returns all three descriptor slots");
    destination.free_rings();
endfunction

task virtio_tx_segments_test::run_phase(uvm_phase	phase);
    phase.raise_objection(this);
    features = 64'h0100000500001801;
    fixture = new("segment_memory");
    require_true(fixture.create_host(0, 64'h100000000, 64'h100ffffff), "Host memory allocation");
    iommu = new("segment_iommu");
    kit = virtio_vq_test_kit::create_kit("segments", fixture.get_host(0), iommu, 16'h1);
    transport = new("segment_transport");
    transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h1));
    ops = kit.make_ops(transport, "segment_ops");
    probe = new();
    check_segment_params();
    check_invalid_segments();
    check_packed_snapshot();
    check_segment_streams();
    aip_cmdline_override::clear("vio.tx.desc_count");
    aip_cmdline_override::clear("vio.tx.seg_mode");
    fixture.leak_check();
    `uvm_info("TX_SEG_PASS", $sformatf("packets=%0d descriptors=%0d", checked_packets, checked_descriptors), UVM_NONE)
    phase.drop_objection(this);
endtask
