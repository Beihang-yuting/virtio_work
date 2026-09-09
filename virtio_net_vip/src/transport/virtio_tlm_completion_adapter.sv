`ifndef VIRTIO_TLM_COMPLETION_ADAPTER_SV
`define VIRTIO_TLM_COMPLETION_ADAPTER_SV

// Reusable completion path for TLM PCIe tests.  PCIe RC drivers own the
// response route, while virtio BAR helper sequences consume completions from
// this adapter instead of waiting on a sequence response that the TLM driver
// does not return.
//
// 中文定位：transport 目录内 TLM(无时序)PCIe 路径的 completion 回填层。
// 职责：TLM RC driver 不把 completion 作为 sequence response 返回，本文件用
// factory override 把 RC driver 与四个 BAR 读写 sequence 替换成"driver 截获
// completion -> adapter 暂存 -> sequence 按 {tag, requester_id} 认领"的模型，
// 供 virtio_bar_accessor 的 helper sequence 在 TLM 测试中复用。
// 依赖：pcie_tl_vip(pcie_tl_rc_driver/pcie_tl_cpl_tlp)、virtio_bar_accessor
// 中的四个基类 sequence、dpu domain key 比较/命名工具。
// 所有权/生命周期：adapter 为 uvm_object，由 env/测试创建并持有；静态
// factory_owner 进程内全局唯一(第二个实例安装 override 直接 fatal)。adapter
// 只借用 RC driver 引用不拥有 driver；暂存 completion 由认领方摘走或 drain()
// 统一清空。
class virtio_tlm_completion_adapter extends uvm_object;
    `uvm_object_utils(virtio_tlm_completion_adapter)

    // A completion can arrive before the sequence that owns its tag reaches
    // the wait.  Keep every accepted completion until its {tag, requester_id}
    // owner claims it; never let an unrelated waiter consume it from a FIFO.
    protected pcie_tl_cpl_tlp retained_cpls[$];
    protected pcie_tl_base_driver retained_cpl_sources[$];
    protected uvm_event cpl_available;
    protected static virtio_tlm_completion_adapter factory_owner;
    protected pcie_tl_base_driver registered_rc_driver;
    protected pcie_tl_base_driver factory_rc_drivers[$];
    protected dpu_pcie_domain_key_t bound_domains[$];
    protected pcie_tl_base_driver bound_domain_drivers[$];
    local bit rc_driver_registration_failed;
    int unsigned completions_received;
    int unsigned completions_consumed;

    // 构造只创建"有新 completion 到达"事件对象；此时未安装 factory override，
    // 也未绑定任何 RC driver，需调用方后续显式安装/绑定。
    function new(string name = "virtio_tlm_completion_adapter");
        super.new(name);
        cpl_available = new("tlm_completion_available");
        rc_driver_registration_failed = 0;
    endfunction

    extern virtual function void install_factory_overrides();

    extern function bit register_rc_driver(pcie_tl_base_driver rc_driver);

    extern function bit bind_registered_rc_driver();

    extern function bit bind_rc_driver(pcie_tl_base_driver rc_driver);

    // Factory discovery is deliberately separate from the legacy one-driver
    // registration contract.  A shared adapter may discover several shims,
    // while register_rc_driver()/bind_rc_driver() continue to reject a second
    // driver exactly as their public compatibility API always has.
    extern function void note_factory_rc_driver(
        pcie_tl_base_driver rc_driver
    );

    extern function bit domain_rc_driver_binding_supported(
        input dpu_pcie_domain_key_t domain,
        input pcie_tl_base_driver rc_driver,
        output string why
    );

    extern function bit bind_domain_rc_driver(
        input dpu_pcie_domain_key_t domain,
        input pcie_tl_base_driver rc_driver
    );

    // 返回当前持有 factory override 的 adapter(未安装时为 null)；
    // RC driver shim 在构造期用它完成自注册，纯查询无副作用。
    static function virtio_tlm_completion_adapter get_factory_owner();
        return factory_owner;
    endfunction

    // 丢弃全部暂存 completion 及其来源记录。用于模式切换/复位前清理陈旧
    // completion，防止后续 waiter 误领旧 tag；统计计数器不回退。
    virtual function void drain();
        retained_cpls.delete();
        retained_cpl_sources.delete();
    endfunction

    // 按 {tag, requester_id} 认领一个暂存 completion；没有则阻塞等待新
    // completion 事件或超时(timeout_ns)。命中即从暂存队列摘除并 ok=1；
    // 超时返回 ok=0 且 cpl=null，是否告警由调用方决定。注意：本路径不区分
    // 来源 driver，多 domain 场景应改用 wait_matching_domain_completion，
    // 否则独立 domain 中等值 tag/BDF 可能被跨域误领。
    virtual task wait_matching_completion(
        input int unsigned timeout_ns,
        input bit [9:0] expected_tag,
        input bit [15:0] expected_requester_id,
        ref pcie_tl_cpl_tlp cpl,
        ref bit ok
    );
        time deadline;
        time remaining;

        ok = 0;
        cpl = null;
        deadline = $time + (timeout_ns * 1ns);
        forever begin
            foreach (retained_cpls[index]) begin
                if (retained_cpls[index].tag == expected_tag &&
                    retained_cpls[index].requester_id == expected_requester_id) begin
                    cpl = retained_cpls[index];
                    retained_cpls.delete(index);
                    retained_cpl_sources.delete(index);
                    completions_consumed++;
                    ok = 1;
                    return;
                end
            end

            if ($time >= deadline)
                return;

            remaining = deadline - $time;
            fork : wait_matching_completion_blk
                cpl_available.wait_trigger();
                #(remaining);
            join_any
            disable wait_matching_completion_blk;
        end
    endtask

    // 多 domain 版本的认领：除 tag/requester_id 外，还要求 completion 的来源
    // driver 与 expected_pcie_id.domain 已绑定的 driver 一致，隔离不同 domain
    // 中数值相同的 tag/BDF。只可能命中经 put_completion_from_driver() 入队且
    // 其 domain 已 bind 的 completion；put_completion()(来源为 null)入队的
    // completion 永远不会被本等待认领。
    virtual task wait_matching_domain_completion(
        input int unsigned timeout_ns,
        input dpu_pcie_function_id_t expected_pcie_id,
        input bit [9:0] expected_tag,
        input bit [15:0] expected_requester_id,
        ref pcie_tl_cpl_tlp cpl,
        ref bit ok
    );
        time deadline;
        time remaining;

        ok = 0;
        cpl = null;
        deadline = $time + (timeout_ns * 1ns);
        forever begin
            foreach (retained_cpls[index]) begin
                bit source_matches_domain;

                source_matches_domain = 0;
                foreach (bound_domains[domain_index]) begin
                    if ((retained_cpl_sources[index] ==
                         bound_domain_drivers[domain_index]) &&
                        dpu_same_domain_key(
                            bound_domains[domain_index],
                            expected_pcie_id.domain)) begin
                        source_matches_domain = 1;
                        break;
                    end
                end
                if (source_matches_domain &&
                    retained_cpls[index].tag == expected_tag &&
                    retained_cpls[index].requester_id ==
                        expected_requester_id) begin
                    cpl = retained_cpls[index];
                    retained_cpls.delete(index);
                    retained_cpl_sources.delete(index);
                    completions_consumed++;
                    ok = 1;
                    return;
                end
            end

            if ($time >= deadline)
                return;

            remaining = deadline - $time;
            fork : wait_matching_domain_completion_blk
                cpl_available.wait_trigger();
                #(remaining);
            join_any
            disable wait_matching_domain_completion_blk;
        end
    endtask

    // 兼容入口：暂存一个来源未知(记为 null)的 completion 并唤醒所有等待者。
    // 只能被 wait_matching_completion() 认领，不参与 domain 匹配。
    virtual function void put_completion(pcie_tl_cpl_tlp cpl);
        retained_cpls.push_back(cpl);
        retained_cpl_sources.push_back(null);
        completions_received++;
        cpl_available.trigger();
    endfunction

    // shim 截获 completion 后的入队入口：连同来源 driver 一起暂存，使 domain
    // 认领路径能校验来源归属；同样唤醒所有等待者。
    virtual function void put_completion_from_driver(
        input pcie_tl_base_driver source_driver,
        input pcie_tl_cpl_tlp cpl
    );
        retained_cpls.push_back(cpl);
        retained_cpl_sources.push_back(source_driver);
        completions_received++;
        cpl_available.trigger();
    endfunction
endclass : virtio_tlm_completion_adapter

// RC driver 的 factory 替身：在父类正常处理 completion 之后，把它旁路复制进
// completion adapter。构造期向当前 factory_owner 自报家门，使共享 adapter
// 能发现多个 shim 实例(多 domain 场景)。
class virtio_tlm_rc_driver_shim extends pcie_tl_rc_driver;
    `uvm_component_utils(virtio_tlm_rc_driver_shim)

    virtio_tlm_completion_adapter adapter;

    // 构造期即向 factory_owner 登记自身(note_factory_rc_driver)；
    // owner 为 null(尚未安装 override)时静默跳过，等待显式 bind。
    function new(string name = "virtio_tlm_rc_driver_shim",
                 uvm_component parent = null);
        virtio_tlm_completion_adapter owner;
        super.new(name, parent);
        owner = virtio_tlm_completion_adapter::get_factory_owner();
        if (owner != null)
            owner.note_factory_rc_driver(this);
    endfunction

    // 先让父类维护自身的 tag/回填状态；仅当父类接受(result=1)且已绑定
    // adapter 时才旁路暂存，避免把父类拒收的 completion 灌入认领队列。
    virtual function bit handle_completion(pcie_tl_cpl_tlp cpl);
        bit result;
        result = super.handle_completion(cpl);
        if (result && adapter != null)
            adapter.put_completion_from_driver(this, cpl);
        return result;
    endfunction
endclass : virtio_tlm_rc_driver_shim

// virtio_bar_mem_rd_seq 的 TLM 替身：base 版本依赖 tlp.rb_done 回填，而 TLM
// driver 不回填，因此改为发出 DWord 对齐的 MEM_RD 后到 adapter 认领 completion。
// 静态 adapter 是 install_factory_overrides() 注入的全局回退；每个 sequence 的
// endpoint_completion_adapter/endpoint_pcie_id 优先，用于多 domain 隔离。
class virtio_tlm_bar_mem_rd_seq extends virtio_bar_mem_rd_seq;
    `uvm_object_utils(virtio_tlm_bar_mem_rd_seq)

    static virtio_tlm_completion_adapter adapter;

    // 仅透传基类构造；请求字段由 BAR accessor 在 start 前逐一赋值。
    function new(string name = "virtio_tlm_bar_mem_rd_seq");
        super.new(name);
    endfunction

    // 发送 1-DWord MEM_RD(地址对齐到 DWord、保留调用方 byte enable)，随后在
    // 选定 adapter 上等待 completion(固定 50000ns 超时)。endpoint 携带有效
    // pcie_id 时走 domain 认领，否则走全局认领。成功置 cpl_ok=1 并按
    // little-endian 组装 rdata；adapter 未绑定报错，超时仅告警且 rdata 保持 0。
    virtual task body();
        pcie_tl_mem_tlp tlp;
        pcie_tl_cpl_tlp cpl;
        virtio_tlm_completion_adapter selected_adapter;
        bit ok;

        tlp = pcie_tl_mem_tlp::type_id::create("mem_rd_tlp");
        start_item(tlp);
        tlp.kind = TLP_MEM_RD;
        // PCIe Memory Request addresses identify a DWord; the requested
        // bytes within it are selected by first_be.  Keep the accessor's
        // byte enables intact, but align this TLM request so the EP returns
        // the same DWord that read_reg() subsequently extracts from.
        tlp.addr = {addr[63:2], 2'b00};
        tlp.length = 10'h1;
        tlp.first_be = first_be;
        tlp.last_be = last_be;
        tlp.is_64bit = is_64bit || (addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
        tlp.type_f = TLP_TYPE_MEM_RD;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        finish_item(tlp);

        cpl_ok = 0;
        rdata = '0;
        selected_adapter = (endpoint_completion_adapter != null) ?
            endpoint_completion_adapter : adapter;
        if (selected_adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Memory-read adapter is not bound")
            return;
        end
        if ((endpoint_completion_adapter != null) &&
            endpoint_pcie_id_valid) begin
            selected_adapter.wait_matching_domain_completion(
                50000, endpoint_pcie_id, tlp.tag, tlp.requester_id,
                cpl, ok);
        end
        else begin
            selected_adapter.wait_matching_completion(
                50000, tlp.tag, tlp.requester_id, cpl, ok);
        end
        if (!ok || cpl == null) begin
            `uvm_warning("TLM_COMPLETION",
                         $sformatf("Completion timeout for addr=0x%016h", addr))
            return;
        end
        cpl_ok = 1;
        if (cpl.payload.size() >= 4)
            rdata = {cpl.payload[3], cpl.payload[2],
                     cpl.payload[1], cpl.payload[0]};
        else
            for (int i = 0; i < cpl.payload.size(); i++)
                rdata[i*8 +: 8] = cpl.payload[i];
    endtask
endclass : virtio_tlm_bar_mem_rd_seq

// virtio_bar_mem_wr_seq 的 TLM 替身：Memory Write 是 posted 事务，无 completion
// 需要认领，但仍需绕开 base 版本的 randomize/rb_done 契约、直接构造合法 TLP。
class virtio_tlm_bar_mem_wr_seq extends virtio_bar_mem_wr_seq;
    `uvm_object_utils(virtio_tlm_bar_mem_wr_seq)

    // 仅透传基类构造；请求字段由 BAR accessor 在 start 前逐一赋值。
    function new(string name = "virtio_tlm_bar_mem_wr_seq");
        super.new(name);
    endfunction

    // 发送 1-DWord MEM_WR：地址对齐到 DWord，把右对齐的 wdata 按 first_be
    // 使能的字节 lane 依次装入 payload(如 offset=2/BE=C 用 lane2/3)。
    // posted 写不产生 completion，因此发送后即结束、不等待 adapter。
    virtual task body();
        pcie_tl_mem_tlp tlp;

        tlp = pcie_tl_mem_tlp::type_id::create("mem_wr_tlp");
        start_item(tlp);
        tlp.kind = TLP_MEM_WR;
        // A PCIe Memory Write address identifies its containing DWord; byte
        // enables select payload lanes in that DWord.  BAR writes pass their
        // input data right-justified, so pack sequential source bytes into
        // the enabled lanes (for example offset 2 / BE=C uses lanes 2 and 3).
        tlp.addr = {addr[63:2], 2'b00};
        tlp.length = 10'h1;
        tlp.first_be = first_be;
        tlp.last_be = last_be;
        tlp.is_64bit = is_64bit || (addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        tlp.payload = new[4];
        begin
            int source_byte;
            source_byte = 0;
            for (int lane = 0; lane < 4; lane++) begin
                tlp.payload[lane] = '0;
                if (first_be[lane]) begin
                    tlp.payload[lane] = wdata[source_byte*8 +: 8];
                    source_byte++;
                end
            end
        end
        finish_item(tlp);
    endtask
endclass : virtio_tlm_bar_mem_wr_seq

// virtio_bar_cfg_rd_seq 的 TLM 替身：Type-0 配置读为 non-posted，必须认领
// completion 才能得到 rdata；adapter 选择与 mem 读一致(endpoint 优先、静态回退)。
class virtio_tlm_bar_cfg_rd_seq extends virtio_bar_cfg_rd_seq;
    `uvm_object_utils(virtio_tlm_bar_cfg_rd_seq)

    static virtio_tlm_completion_adapter adapter;

    // 仅透传基类构造；target_bdf/reg_num 等由 BAR accessor 在 start 前赋值。
    function new(string name = "virtio_tlm_bar_cfg_rd_seq");
        super.new(name);
    endfunction

    // 发出 Type-0 CFG_RD 后到选定 adapter 认领 completion(50000ns 超时)。
    // 超时仅告警并保持 cpl_ok=0/rdata=0，由调用方判断；payload 按
    // little-endian 组装，短 payload 逐字节回填。
    virtual task body();
        pcie_tl_cfg_tlp tlp;
        pcie_tl_cpl_tlp cpl;
        virtio_tlm_completion_adapter selected_adapter;
        bit ok;

        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_rd_tlp");
        start_item(tlp);
        tlp.kind = TLP_CFG_RD0;
        tlp.fmt = FMT_3DW_NO_DATA;
        tlp.type_f = TLP_TYPE_CFG_RD0;
        tlp.completer_id = target_bdf;
        tlp.reg_num = reg_num;
        tlp.first_be = first_be;
        tlp.length = 10'h1;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        finish_item(tlp);

        cpl_ok = 0;
        rdata = '0;
        selected_adapter = (endpoint_completion_adapter != null) ?
            endpoint_completion_adapter : adapter;
        if (selected_adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Config-read adapter is not bound")
            return;
        end
        if ((endpoint_completion_adapter != null) &&
            endpoint_pcie_id_valid) begin
            selected_adapter.wait_matching_domain_completion(
                50000, endpoint_pcie_id, tlp.tag, tlp.requester_id,
                cpl, ok);
        end
        else begin
            selected_adapter.wait_matching_completion(
                50000, tlp.tag, tlp.requester_id, cpl, ok);
        end
        if (!ok || cpl == null) begin
            `uvm_warning("TLM_COMPLETION",
                         $sformatf("Completion timeout for config register %0d", reg_num))
            return;
        end
        cpl_ok = 1;
        if (cpl.payload.size() >= 4)
            rdata = {cpl.payload[3], cpl.payload[2],
                     cpl.payload[1], cpl.payload[0]};
        else
            for (int i = 0; i < cpl.payload.size(); i++)
                rdata[i*8 +: 8] = cpl.payload[i];
    endtask
endclass : virtio_tlm_bar_cfg_rd_seq

// virtio_bar_cfg_wr_seq 的 TLM 替身：配置写为 non-posted，发出后仍等待其
// completion(内容丢弃)，保证 EP 已接收该写之后 sequence 才结束，维持
// 后续访问的顺序性。
class virtio_tlm_bar_cfg_wr_seq extends virtio_bar_cfg_wr_seq;
    `uvm_object_utils(virtio_tlm_bar_cfg_wr_seq)

    static virtio_tlm_completion_adapter adapter;

    // 仅透传基类构造；target_bdf/reg_num/wdata 等由 BAR accessor 在 start 前赋值。
    function new(string name = "virtio_tlm_bar_cfg_wr_seq");
        super.new(name);
    endfunction

    // 发送 Type-0 CFG_WR(payload 按 little-endian 拆成 4 字节)，随后等待写
    // completion 以保证顺序。保守观察：等待结果 ok 未做检查，超时既不告警
    // 也不向调用方反馈，写失败对上层不可见。
    virtual task body();
        pcie_tl_cfg_tlp tlp;
        pcie_tl_cpl_tlp cpl;
        virtio_tlm_completion_adapter selected_adapter;
        bit ok;

        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_wr_tlp");
        start_item(tlp);
        tlp.kind = TLP_CFG_WR0;
        tlp.fmt = FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_CFG_WR0;
        tlp.completer_id = target_bdf;
        tlp.reg_num = reg_num;
        tlp.first_be = first_be;
        tlp.length = 10'h1;
        tlp.tc = 0;
        tlp.attr = 0;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        tlp.inject_ecrc_err = 0;
        tlp.inject_lcrc_err = 0;
        tlp.inject_poisoned = 0;
        tlp.violate_ordering = 0;
        tlp.field_bitmask = 0;
        tlp.has_prefix = 0;
        tlp.payload = new[4];
        tlp.payload[0] = wdata[7:0];
        tlp.payload[1] = wdata[15:8];
        tlp.payload[2] = wdata[23:16];
        tlp.payload[3] = wdata[31:24];
        finish_item(tlp);

        selected_adapter = (endpoint_completion_adapter != null) ?
            endpoint_completion_adapter : adapter;
        if (selected_adapter == null) begin
            `uvm_error("TLM_COMPLETION", "Config-write adapter is not bound")
            return;
        end
        if ((endpoint_completion_adapter != null) &&
            endpoint_pcie_id_valid) begin
            selected_adapter.wait_matching_domain_completion(
                50000, endpoint_pcie_id, tlp.tag, tlp.requester_id,
                cpl, ok);
        end
        else begin
            selected_adapter.wait_matching_completion(
                50000, tlp.tag, tlp.requester_id, cpl, ok);
        end
    endtask
endclass : virtio_tlm_bar_cfg_wr_seq

// 把 RC driver 与四个 BAR sequence 的 factory 类型整体替换为 TLM 版本，并把
// 自己登记为全局 factory_owner。约束：进程内只允许一个 owner(不同实例重复
// 安装直接 fatal)；副作用是全局的——安装后所有后续 factory create 都走 TLM
// 路径。mem_wr 序列无 completion 需求，故未给它注入静态 adapter。
function void virtio_tlm_completion_adapter::install_factory_overrides();
    if (factory_owner != null && factory_owner != this) begin
        `uvm_fatal("TLM_COMPLETION",
                   "A distinct completion adapter already owns the factory overrides")
        return;
    end
    factory_owner = this;
    pcie_tl_rc_driver::type_id::set_type_override(
        virtio_tlm_rc_driver_shim::get_type());
    virtio_bar_mem_rd_seq::type_id::set_type_override(
        virtio_tlm_bar_mem_rd_seq::get_type());
    virtio_bar_mem_wr_seq::type_id::set_type_override(
        virtio_tlm_bar_mem_wr_seq::get_type());
    virtio_bar_cfg_rd_seq::type_id::set_type_override(
        virtio_tlm_bar_cfg_rd_seq::get_type());
    virtio_bar_cfg_wr_seq::type_id::set_type_override(
        virtio_tlm_bar_cfg_wr_seq::get_type());
    virtio_tlm_bar_mem_rd_seq::adapter = this;
    virtio_tlm_bar_cfg_rd_seq::adapter = this;
    virtio_tlm_bar_cfg_wr_seq::adapter = this;
endfunction

// shim 构造回调：登记新发现的 RC driver(null 忽略、重复去重)。仅当此前一个
// driver 都没有时才顺带完成旧式单 driver 绑定；后续 shim 只入发现列表，留给
// bind_domain_rc_driver() 显式分域绑定，避免污染多 domain 配置。
function void virtio_tlm_completion_adapter::note_factory_rc_driver(
    pcie_tl_base_driver rc_driver
);
    virtio_tlm_rc_driver_shim shim;

    if (rc_driver == null)
        return;
    foreach (factory_rc_drivers[index]) begin
        if (factory_rc_drivers[index] == rc_driver)
            return;
    end
    factory_rc_drivers.push_back(rc_driver);
    // Preserve the legacy single-driver discovery behavior when exactly one
    // shim exists.  Discovering later shims does not call the public legacy
    // registration API and therefore does not poison multi-domain setup.
    if (registered_rc_driver == null) begin
        registered_rc_driver = rc_driver;
        if ($cast(shim, rc_driver))
            shim.adapter = this;
    end
endfunction

// 纯校验(无副作用)：判断 domain 与 rc_driver 能否建立 1:1 绑定。拒绝 null/
// 非 shim 类型/已绑其它 adapter 的 driver，以及 domain 或 driver 任一方已
// 存在不同配对的情况；完全相同的既有配对视为允许(幂等)。why 带回失败原因。
function bit virtio_tlm_completion_adapter::domain_rc_driver_binding_supported(
    input dpu_pcie_domain_key_t domain,
    input pcie_tl_base_driver rc_driver,
    output string why
);
    virtio_tlm_rc_driver_shim shim;

    why = "";
    if (rc_driver == null) begin
        why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
               " has a null RC driver"};
        return 0;
    end
    if (!$cast(shim, rc_driver)) begin
        why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
               " RC driver was not created as virtio_tlm_rc_driver_shim"};
        return 0;
    end
    if ((shim.adapter != null) && (shim.adapter != this)) begin
        why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
               " RC driver is already bound to a distinct completion adapter"};
        return 0;
    end
    foreach (bound_domains[index]) begin
        if (dpu_same_domain_key(bound_domains[index], domain)) begin
            if (bound_domain_drivers[index] != rc_driver) begin
                why = {"PCIe domain ", dpu_pcie_domain_key_name(domain),
                       " is already bound to a distinct RC driver"};
                return 0;
            end
            return 1;
        end
        if (bound_domain_drivers[index] == rc_driver) begin
            why = {"RC driver is already bound to distinct PCIe domain ",
                   dpu_pcie_domain_key_name(bound_domains[index])};
            return 0;
        end
    end
    return 1;
endfunction

// 提交 domain->driver 绑定：先走 supported 校验(失败 fatal 并返回 0)；已有
// 相同配对则幂等返回 1；否则登记配对并把 shim.adapter 指向本 adapter。
function bit virtio_tlm_completion_adapter::bind_domain_rc_driver(
    input dpu_pcie_domain_key_t domain,
    input pcie_tl_base_driver rc_driver
);
    virtio_tlm_rc_driver_shim shim;
    string why;

    if (!domain_rc_driver_binding_supported(domain, rc_driver, why)) begin
        `uvm_fatal("TLM_COMPLETION", why)
        return 0;
    end
    foreach (bound_domains[index]) begin
        if (dpu_same_domain_key(bound_domains[index], domain))
            return 1;
    end
    if (!$cast(shim, rc_driver)) begin
        `uvm_fatal("TLM_COMPLETION",
            "validated domain RC driver could not be cast during commit")
        return 0;
    end
    bound_domains.push_back(domain);
    bound_domain_drivers.push_back(rc_driver);
    shim.adapter = this;
    return 1;
endfunction

// 旧式单 driver 绑定：整个 adapter 只接受一个 RC driver，重复绑定同一
// driver 幂等成功。任何一次失败都会置 rc_driver_registration_failed 粘滞
// 标志，之后所有注册/绑定调用一律 fatal，防止半绑定状态被继续使用。
function bit virtio_tlm_completion_adapter::bind_rc_driver(
    pcie_tl_base_driver rc_driver
);
    virtio_tlm_rc_driver_shim shim;
    if (rc_driver_registration_failed) begin
        `uvm_fatal("TLM_COMPLETION",
                   "Completion adapter RC driver registration previously failed")
        return 0;
    end
    if (rc_driver == null) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION", "RC driver is null")
        return 0;
    end
    if (!$cast(shim, rc_driver)) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION",
                   "RC driver was not created as virtio_tlm_rc_driver_shim")
        return 0;
    end
    if (shim.adapter != null && shim.adapter != this) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION",
                   "RC driver is already bound to a distinct completion adapter")
        return 0;
    end
    if (registered_rc_driver != null && registered_rc_driver != rc_driver) begin
        rc_driver_registration_failed = 1;
        `uvm_fatal("TLM_COMPLETION",
                   "A distinct RC driver is already registered with this completion adapter")
        return 0;
    end
    registered_rc_driver = rc_driver;
    shim.adapter = this;
    return 1;
endfunction

// bind_rc_driver 的公开注册包装：失败同样置粘滞失败标志。与
// note_factory_rc_driver() 的被动发现不同，这是调用方显式注册的入口。
function bit virtio_tlm_completion_adapter::register_rc_driver(
    pcie_tl_base_driver rc_driver
);
    if (rc_driver_registration_failed) begin
        `uvm_fatal("TLM_COMPLETION",
                   "Completion adapter RC driver registration previously failed")
        return 0;
    end
    if (!bind_rc_driver(rc_driver)) begin
        rc_driver_registration_failed = 1;
        return 0;
    end
    return 1;
endfunction

// 把 factory 阶段发现/登记的 driver 正式提交绑定；从未登记过任何 driver
// 或此前注册已失败则 fatal。供 env 在 build 完成后统一提交。
function bit virtio_tlm_completion_adapter::bind_registered_rc_driver();
    if (rc_driver_registration_failed) begin
        `uvm_fatal("TLM_COMPLETION",
                   "Completion adapter RC driver registration previously failed")
        return 0;
    end
    if (registered_rc_driver == null) begin
        `uvm_fatal("TLM_COMPLETION",
                   "No factory-created RC driver registered with completion adapter")
        return 0;
    end
    return bind_rc_driver(registered_rc_driver);
endfunction

`endif // VIRTIO_TLM_COMPLETION_ADAPTER_SV
