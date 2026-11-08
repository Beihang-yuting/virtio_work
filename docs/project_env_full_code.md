# 项目外部配置完整源码

本文件由 `python3 scripts/render_project_code.py` 自动生成，禁止手工修改代码块。
运行 `python3 scripts/render_project_code.py --check` 检查是否与最终源码一致。
最短接入顺序、平台 hook/布局和 Intel bind 见 [README](../integration/project/README.md)。

保留一个 env、一个 cfg；辅助 typed/registry/driver 文件是必要依赖，不可只复制两个类。
下列 `.sv` 文件由 `project_env_pkg.sv` 按其 include 顺序包含，不得重复单独编译。
按需替换项目类名前缀时，同步更新 extern 定义的类限定名。

外部 package 顺序由 `filelists/project_integration.f` → `filelists/aip_integration.f`
→ `filelists/dpu_common.f` / `filelists/virtio_net.f` 明确声明：AIP (`src/sv`布局)、
DPU、net_packet、host_mem、PCIe TL、VIO、AIP glue、Intel interface/adapter，再到本包。
依赖版本与 package SHA-256 见 [验证记录](vio_external_configuration_validation.md)。
生产 VIO filelist 不包含本目录；模型测试需另外添加 `filelists/project_tests.f`。

默认采用驱动参考 BDF/MSI-X/VIO/QSCH 布局，配置 seq 已实现这些表的写入和可选真实读回。
第一笔配置写为 AF 声明：经 Host0 RC 向已分配的 h0.pf0.bar0.base+0x1010 写32'h5555_aaaa。
declare_af() 复用 pcie_tl_reg_seq，发送4B Memory Write后单次读同地址，等待Completion并要求状态8。
随后每100次完整DWORD配置写再读一次状态；无轮询、无尾读，任一步失败停止。
AF读关闭SCB历史RAM比较，保留协议检查及状态8校验；与PROJECT_AF表独立，不执行额外Host-ID协商。
所有寄存器访问固定TC0/attr0；AF同步不受configure_public或verify_readback控制。
BDF默认开启，MSI-X按实际完成模式选择；其余公共表默认关闭。
默认 dpu.verify_readback=0；设为1时增加配置读回。
Notify 仅写/读实际队列对的有效项；首次配置前 DUT 须按05.png复位未用项
（type=3、lookup key/global_qid全1、reserved=0）。MSI-X 线性表尾部初始化保持原流程。
BAR 编码、公共验证及实际复位/接口绑定仍由平台负责。
base_test 显式启动一个配置 seq，共用 env_cfg 中的资源完成写表、使能、所选验证和确认。
ring 在写队列表前准备；不自动执行 Virtio capability 发现、协商或复位。
单队列联调可改用 project_single_queue_config_seq：在独立 seq 内固定 BDF/Notify/QSCH/VTX
布局和策略，实际 BAR/ring 继续由 env 分配；原 project_dut_config_seq 行为不变。
Host0/PF0/no-VF、一对 Packed256/Polling/TX-only 和 DPU32 Notify 必须在 env 构建前选定。
独立寄存器访问可用 project_pcie_reg_seq 注册 aip_cmd_reg：addr 为 Host0/PF0 BAR0 偏移，
cfg 来自显式句柄或启动 sequencer 的 env_cfg；实际 BAR 基址和 RC 由环境解析。

## `filelists/project_integration.f`

SHA-256: `572ea28deb405984db0993704333bff68b59f3862d2b3f1db3610480e7893ccb`

```text
// Intel HARD_IP + 真实 EP 应用 DUT 的唯一项目参考入口；从 virtio_work 根运行。
// 依赖根由调用方提供；Intel interface、adapter 和 DUT 的接口几何必须一致。
// 已有统一工程 filelist 时，按此顺序增补缺失包，禁止把已有包再次编译。
-f filelists/aip_integration.f
+incdir+$INTEL_PCIE_ROOT/src
$INTEL_PCIE_ROOT/src/interface/intel_pcie_if.sv
$INTEL_PCIE_ROOT/src/adapter/intel_pcie_adapter_pkg.sv
+incdir+integration/project
integration/project/project_env_pkg.sv
```

## `integration/project/project_env_pkg.sv`

SHA-256: `b29372c4da392ab5c099ec132d8f99d43e4c30ca59059fbaa953ee6afed38985`

```systemverilog
// integration/project：项目参考组装的唯一 package 编译入口。
// 顺序：AIP→DPU/Host memory/PCIe TL/VIO→AIP glue→本包。
// 固定 Intel 接入；Intel interface/adapter package 必须在本包之前编译。
// include 的普通 .sv 不可另行编译；本包只定义类型，不创建组件或取得外部资源。
package project_env_pkg;
	timeunit 1ns;
	timeprecision 1ps;

	import uvm_pkg::*;
	import aip_core_pkg::*;
	import host_mem_pkg::*;
	import dpu_resource_pkg::*;
	import pcie_tl_pkg::*;
	import virtio_net_pkg::*;
	import virtio_aip_pkg::*;
	import intel_pcie_adapter_pkg::*;
	`include "uvm_macros.svh"

	`include "project_bar_registry.sv"
	`include "project_dut_config.sv"
	`include "project_vio_config.sv"
	`include "project_pcie_rc_driver.sv"
	`include "project_env_cfg.sv"
	`include "project_pcie_reg_seq.sv"
	`include "project_dut_config_seq.sv"
	`include "project_single_queue_config_seq.sv"
	`include "project_env.sv"
	`include "project_base_test.sv"
endpackage
```

## `integration/project/project_bar_registry.sv`

SHA-256: `9ac7764586b9d83452a4fbd839f619bc8342bc6fa497cf0afdc6d1cd1fdd93a2`

```systemverilog
// integration/project：逻辑 BAR 到冻结 DPU 租约与 Intel 路由的唯一投影层。
// 依赖 dpu_resource_pkg/pcie_tl_pkg；借用不可变 snapshot，不分配资源或访问 DUT。
// registry 从 initialize、显式绑定到 freeze 单向演进；新代使用新对象，旧引用不能混用。
// target 描述访问窗口，绝不推导待配置表项的 owner；调用方分别保存两种身份。
typedef struct {
    dpu_function_key_t		function_key;
    dpu_pcie_function_id_t	pcie_id;
    int unsigned			global_function_id;
    dpu_bar_pair_lease_t	bar_lease;
    int unsigned			rc_slot;
    string					canonical_name;
    dpu_device_snapshot		snapshot;
    longint unsigned		snapshot_generation;
    pcie_tl_cq_route_t		route;
} project_bar_target_t;

// 平台 requester 编码可不同于快照 BDF；显式记录可避免 EP/SW 模式推断。
typedef struct {
    dpu_function_key_t	function_key;
    int unsigned		pf_index;
    int					vf_index;
    bit [15:0]			requester_id;
} project_intel_function_route_t;

// 先收集绑定，再冻结可查询的值副本；缺 Intel 绑定可打印，但不可作为发送目标。
class project_bar_registry extends uvm_object;
    `uvm_object_utils(project_bar_registry)
    protected dpu_device_snapshot				m_snapshot;
    protected longint unsigned					m_generation;
    protected bit								m_frozen;
    protected int unsigned						m_slot_by_host[int unsigned];
    protected project_intel_function_route_t	m_routes[string];
    protected project_bar_target_t				m_targets[$];
    protected static bit						m_auto_printed[string];

    // 根据 wire requester 查冻结 Function/BDF；用于接收 DMA，不按数组位置推测。
    extern function bit resolve_requester(input int unsigned host_id,
        input bit [15:0] requester_id, output dpu_function_key_t key,
        output dpu_pcie_function_id_t pcie_id, output string why);

    // 创建空对象；调用 initialize 前任何查询/绑定都失败。
    extern function	new(
        string	name = "project_bar_registry"
    );

    // 借用冻结快照，generation 由发布方提供且非零；禁止二次初始化。
    extern function bit	initialize(
        dpu_device_snapshot	snapshot,
        longint unsigned	generation,
        output string		why
    );

    // Host 与 RC slot 一一对应；重复/未知 Host 或冻结后修改均失败。
    extern function bit	bind_host(
        int unsigned	host_id,
        int unsigned	rc_slot,
        output string	why
    );

    // 显式绑定 Intel 3 位 PF/11 位 VF 与 DMA requester；PF 的 vf_index 必须为 -1。
    extern function bit	bind_function(
        dpu_function_key_t	key,
        int unsigned		pf_index,
        int					vf_index,
        bit [15:0]			requester_id,
        output string		why
    );

    // 检查所有 Host 路由和实际 BAR，冻结内部投影；不要求未使用 Function 已绑 Intel。
    extern function bit	freeze(
        output string	why
    );

    // 判断生命周期；不给调用方可写内部容器。
    extern function bit	is_frozen();

    // 验证指定 Host/segment 的 RC slot；segment 当前只接受 0。
    extern function bit	get_slot(
        int unsigned		host_id,
        int unsigned		segment_id,
        output int unsigned	rc_slot,
        output string		why
    );

    // 严格完整解析名字；显式前缀与访问上下文冲突时报错，无上下文只允许唯一 Host。
    extern function bit	resolve_name(
        string						name,
        output project_bar_target_t	target,
        output string				why,
        input bit					has_access_host = 0,
        input int unsigned			access_host = 0
    );

    // 使用完整 Function 和实际偶数 BAR ID 查询，绝不把 ID 当成 role。
    extern function bit	resolve_function(
        dpu_function_key_t			key,
        int unsigned				bar_id,
        output project_bar_target_t	target,
        output string				why
    );

    // 高级调试只接受真实 base，域内须唯一；BAR 内部地址不是 base。
    extern function bit	resolve_base(
        int unsigned				host_id,
        int unsigned				segment_id,
        bit [63:0]					base,
        output project_bar_target_t	target,
        output string				why
    );

    // 校验引用身份及内容后以 65 位检查完整区间；失败地址清零，width 不可为零。
    extern function bit	check_range(
        project_bar_target_t	target,
        bit [63:0]				byte_offset,
        bit [63:0]				width_bytes,
        output bit [63:0]		address,
        output string			why
    );

    // Memory 使用实际窗口和整个字节跨度；不读取或改变 requester 身份。
    extern function bit	route_memory(
        int unsigned				host_id,
        int unsigned				segment_id,
        bit [63:0]					address,
        bit [63:0]					width_bytes,
        output pcie_tl_cq_route_t	route,
        output string				why
    );

    // Completion 反查原 Requester ID，完全独立于 Memory 地址和 BAR 归属。
    extern function bit	route_completion(
        int unsigned				host_id,
        int unsigned				segment_id,
        bit [15:0]					requester_id,
        output pcie_tl_cq_route_t	route,
        output string				why
    );

    // 输出稳定排序的真实租约；自动模式按快照身份与代号去重，手工模式可重复。
    extern function bit	print_bar_map(
        output string	why,
        input bit	automatic_print = 0
    );

    // 统一状态门；只在未冻结的已初始化对象上允许构建操作。
    extern protected function bit	mutable(
        output string	why
    );

    // 严格消费文字 token；失败时不推进 cursor。
    extern protected function bit	consume(
        string				name,
        string				token,
        ref int unsigned	cursor
    );

    // 逐字符十进制累积，提前检查 uint 溢出，至少要求一位数字。
    extern protected function bit	decimal(
        string				name,
        ref int unsigned	cursor,
        output int unsigned	value
    );
endclass

// 创建空对象；调用 initialize 前任何查询/绑定都失败。
function	project_bar_registry::new(
    string	name = "project_bar_registry"
);
    super.new(name);
endfunction

// 统一状态门；只在未冻结的已初始化对象上允许构建操作。
function bit	project_bar_registry::mutable(
    output string	why
);
    why = "";

    if (m_snapshot == null || m_frozen) begin
        why = "BAR registry is uninitialized or frozen";
        return 0;
    end
    return 1;
endfunction

// 借用冻结快照，generation 由发布方提供且非零；禁止二次初始化。
function bit	project_bar_registry::initialize(
    dpu_device_snapshot	snapshot,
    longint unsigned	generation,
    output string		why
);
    why = "";

    if (m_snapshot != null || snapshot == null || generation == 0) begin
        why = "BAR registry requires a new instance, frozen snapshot and nonzero generation";
        return 0;
    end

    if (!snapshot.is_frozen()) begin
        why = "BAR registry snapshot is not frozen";
        return 0;
    end
    m_snapshot   = snapshot;
    m_generation = generation;
    return 1;
endfunction

// Host 与 RC slot 一一对应；重复/未知 Host 或冻结后修改均失败。
function bit	project_bar_registry::bind_host(
    int unsigned	host_id,
    int unsigned	rc_slot,
    output string	why
);
    dpu_host_info_t	hosts[$];
    bit				found;

    if (!mutable(why)) begin
        return 0;
    end
    m_snapshot.list_hosts(hosts);

    foreach (hosts[i]) begin
        if (hosts[i].host_id == host_id) begin
            found = 1;
        end
    end

    if (!found || m_slot_by_host.exists(host_id)) begin
        why = "unknown or duplicate Host binding";
        return 0;
    end

    foreach (m_slot_by_host[h]) begin
        if (m_slot_by_host[h] == rc_slot) begin
            why = "RC slot already belongs to another Host";
            return 0;
        end
    end
    m_slot_by_host[host_id] = rc_slot;
    return 1;
endfunction

// 显式绑定 Intel 3 位 PF/11 位 VF 与 DMA requester；PF 的 vf_index 必须为 -1。
function bit	project_bar_registry::bind_function(
    dpu_function_key_t	key,
    int unsigned		pf_index,
    int					vf_index,
    bit [15:0]			requester_id,
    output string		why
);
    dpu_pcie_function_id_t	id;
    string					key_name;

    if (!mutable(why)) begin
        return 0;
    end

    if (!m_snapshot.get_pcie_id(key, id, why)) begin
        return 0;
    end
    key_name = dpu_function_key_name(key);

    if (id.domain.segment_id != 0 || pf_index > 7 ||
        (key.kind == DPU_FUNCTION_PF && vf_index != -1) ||
        (key.kind == DPU_FUNCTION_VF && (vf_index < 0 || vf_index > 2047))) begin
        why = "Intel route exceeds PF/VF width or unsupported segment/kind";
        return 0;
    end

    if (m_routes.exists(key_name)) begin
        why = "duplicate Function route binding";
        return 0;
    end

    foreach (m_routes[k]) begin
        if (m_routes[k].function_key.host_id == key.host_id) begin
            if (m_routes[k].requester_id == requester_id ||
                (m_routes[k].pf_index == pf_index && m_routes[k].vf_index == vf_index)) begin
                why = "ambiguous Intel Function or requester binding in Host domain";
                return 0;
            end
        end
    end
    m_routes[key_name] = '{key, pf_index, vf_index, requester_id};
    return 1;
endfunction

// 检查所有 Host 路由和实际 BAR，冻结内部投影；不要求未使用 Function 已绑 Intel。
function bit	project_bar_registry::freeze(
    output string	why
);
    dpu_function_key_t		keys[$];
    project_bar_target_t	pending[$];
    dpu_host_info_t			hosts[$];

    if (!mutable(why)) begin
        return 0;
    end
    m_snapshot.list_hosts(hosts);

    foreach (hosts[i]) begin
        if (!m_slot_by_host.exists(hosts[i].host_id)) begin
            why = "snapshot Host has no RC binding";
            return 0;
        end
    end
    m_snapshot.list_functions(keys);

    foreach (keys[i]) begin
        dpu_bar_pair_lease_t	bars[$];
        dpu_pcie_function_id_t	id;
        int unsigned			global_id;
        string					key_name;

        if (!m_snapshot.get_pcie_id(keys[i], id, why) ||
            !m_snapshot.get_global_function_id(keys[i], global_id, why) ||
            !m_snapshot.list_bars(keys[i], bars, why)) begin
            return 0;
        end

        if (id.domain.segment_id != 0 || !m_slot_by_host.exists(keys[i].host_id)) begin
            why = "snapshot Function has unsupported segment or missing Host RC binding";
            return 0;
        end
        key_name = dpu_function_key_name(keys[i]);

        // DPU 的列表按 role 排序；这里按真实 BAR 编号排序，避免展示顺序暗示 role=id。
        bars.sort() with (item.even_bar_id);

        foreach (bars[b]) begin
            project_bar_target_t	target;

            if (bars[b].even_bar_id > 4 || bars[b].even_bar_id[0] || bars[b].size == 0) begin
                why = "invalid 64-bit BAR pair id or empty lease";
                return 0;
            end

            if (b > 0 && bars[b - 1].even_bar_id == bars[b].even_bar_id) begin
                why = "duplicate BAR id within Function";
                return 0;
            end
            target.function_key       = keys[i];
            target.pcie_id            = id;
            target.global_function_id = global_id;
            target.bar_lease          = bars[b];
            target.rc_slot            = m_slot_by_host[keys[i].host_id];
            target.canonical_name     = $sformatf("h%0d.pf%0d", keys[i].host_id, keys[i].pf_id);

            if (keys[i].kind == DPU_FUNCTION_VF) begin
                target.canonical_name = {target.canonical_name, $sformatf(".vf%0d", keys[i].vf_id)};
            end
            target.canonical_name      = {target.canonical_name, $sformatf(".bar%0d", bars[b].even_bar_id)};
            target.snapshot            = m_snapshot;
            target.snapshot_generation = m_generation;
            target.route               = pcie_tl_cq_route_default();
            target.route.target_bdf    = id.bdf;
            target.route.target_func   = id.bdf[7:0];
            target.route.bar_id        = 3'(bars[b].even_bar_id);
            target.route.bar_aperture  = 6'($clog2(bars[b].size));

            if (m_routes.exists(key_name)) begin
                target.route.valid    = 1;
                target.route.pf_index = int'(m_routes[key_name].pf_index);
                target.route.is_vf    = keys[i].kind == DPU_FUNCTION_VF;
                target.route.vf_index = m_routes[key_name].vf_index;
            end
            pending.push_back(target);
        end
    end
    m_targets = pending;
    m_frozen  = 1;
    why       = "";
    return 1;
endfunction

// 判断生命周期；不给调用方可写内部容器。
function bit	project_bar_registry::is_frozen();
    return m_frozen;
endfunction

// 验证指定 Host/segment 的 RC slot；segment 当前只接受 0。
function bit	project_bar_registry::get_slot(
    int unsigned		host_id,
    int unsigned		segment_id,
    output int unsigned	rc_slot,
    output string		why
);
    rc_slot = 0;
    why     = "";

    if (!m_frozen || segment_id != 0 || !m_slot_by_host.exists(host_id)) begin
        why = "BAR registry not ready or Host/segment route missing";
        return 0;
    end
    rc_slot = m_slot_by_host[host_id];
    return 1;
endfunction

// 严格消费文字 token；失败时不推进 cursor。
function bit	project_bar_registry::consume(
    string				name,
    string				token,
    ref int unsigned	cursor
);
    if (cursor + token.len() > name.len()) begin
        return 0;
    end

    for (int unsigned	i = 0; i < token.len(); i++) begin
        if (name.getc(cursor + i) != token.getc(i)) begin
            return 0;
        end
    end
    cursor += token.len();
    return 1;
endfunction

// 逐字符十进制累积，提前检查 uint 溢出，至少要求一位数字。
function bit	project_bar_registry::decimal(
    string				name,
    ref int unsigned	cursor,
    output int unsigned	value
);
    int unsigned	start;
    int unsigned	digit;

    start = cursor;
    value = 0;

    while (cursor < name.len() && name.getc(cursor) >= "0" && name.getc(cursor) <= "9") begin
        digit = name.getc(cursor) - "0";

        if (value > (32'hffffffff - digit) / 10) begin
            return 0;
        end
        value = value * 10 + digit;
        cursor++;
    end
    return cursor > start;
endfunction

// 严格完整解析名字；显式前缀与访问上下文冲突时报错，无上下文只允许唯一 Host。
function bit	project_bar_registry::resolve_name(
    string						name,
    output project_bar_target_t	target,
    output string				why,
    input bit					has_access_host = 0,
    input int unsigned			access_host = 0
);
    dpu_function_key_t	key;
    int unsigned		cursor;
    int unsigned		bar_id;
    int unsigned		unique_host;
    bit					explicit_host;

    target = '{function_key:'{0, 0, DPU_FUNCTION_PF, 0},
        bar_lease:'{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
        snapshot:null, canonical_name:"", default:0};
    key           = '{0, 0, DPU_FUNCTION_PF, 0};
    cursor        = 0;
    why           = {"invalid BAR target syntax: ", name};
    explicit_host = consume(name, "h", cursor);

    if (explicit_host) begin
        if (!decimal(name, cursor, key.host_id) || !consume(name, ".", cursor)) begin
            return 0;
        end

        if (has_access_host && key.host_id != access_host) begin
            why = "explicit target Host conflicts with access Host";
            return 0;
        end
    end

    if (!consume(name, "pf", cursor) || !decimal(name, cursor, key.pf_id)) begin
        return 0;
    end

    if (consume(name, ".vf", cursor)) begin
        key.kind = DPU_FUNCTION_VF;

        if (!decimal(name, cursor, key.vf_id)) begin
            return 0;
        end
    end

    if (!consume(name, ".bar", cursor) || !decimal(name, cursor, bar_id) || cursor != name.len()) begin
        return 0;
    end

    if (!explicit_host) begin
        if (has_access_host) begin
            key.host_id = access_host;
        end else if (m_slot_by_host.num() == 1) begin
            void'(m_slot_by_host.first(unique_host));
            key.host_id = unique_host;
        end else begin
            why = "short BAR target requires explicit access Host in multi-Host registry";
            return 0;
        end
    end
    return resolve_function(key, bar_id, target, why);
endfunction

// 使用完整 Function 和实际偶数 BAR ID 查询，绝不把 ID 当成 role。
function bit	project_bar_registry::resolve_function(
    dpu_function_key_t			key,
    int unsigned				bar_id,
    output project_bar_target_t	target,
    output string				why
);
    target = '{function_key:'{0, 0, DPU_FUNCTION_PF, 0},
        bar_lease:'{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
        snapshot:null, canonical_name:"", default:0};
    why    = "BAR registry not frozen, Function/BAR unknown, or Intel route unbound";

    if (!m_frozen) begin
        return 0;
    end

    foreach (m_targets[i]) begin
        if (dpu_same_function_key(m_targets[i].function_key, key) && m_targets[i].bar_lease.even_bar_id == bar_id) begin
            if (!m_targets[i].route.valid) begin
                return 0;
            end
            target = m_targets[i];
            why    = "";
            return 1;
        end
    end
    return 0;
endfunction

// 高级调试只接受真实 base，域内须唯一；BAR 内部地址不是 base。
function bit	project_bar_registry::resolve_base(
    int unsigned				host_id,
    int unsigned				segment_id,
    bit [63:0]					base,
    output project_bar_target_t	target,
    output string				why
);
    int unsigned	slot;
    int				match_index;

    target = '{function_key:'{0, 0, DPU_FUNCTION_PF, 0},
        bar_lease:'{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
        snapshot:null, canonical_name:"", default:0};

    if (!get_slot(host_id, segment_id, slot, why)) begin
        return 0;
    end
    match_index = -1;

    foreach (m_targets[i]) begin
        if (m_targets[i].function_key.host_id == host_id && m_targets[i].bar_lease.base == base) begin
            if (match_index >= 0) begin
                why = "ambiguous BAR base in domain";
                return 0;
            end
            match_index = i;
        end
    end

    if (match_index < 0) begin
        why = "address is not a registered BAR base";
        return 0;
    end
    return resolve_function(m_targets[match_index].function_key, m_targets[match_index].bar_lease.even_bar_id, target, why);
endfunction

// 校验引用身份及内容后以 65 位检查完整区间；失败地址清零，width 不可为零。
function bit	project_bar_registry::check_range(
    project_bar_target_t	target,
    bit [63:0]				byte_offset,
    bit [63:0]				width_bytes,
    output bit [63:0]		address,
    output string			why
);
    project_bar_target_t	current;
    bit [64:0]				last_offset;
    bit [64:0]				first_address;
    bit [64:0]				last_address;

    address = 0;
    why     = "stale BAR target snapshot or generation";

    if (!m_frozen || target.snapshot != m_snapshot || target.snapshot_generation != m_generation) begin
        return 0;
    end

    if (!resolve_function(target.function_key, target.bar_lease.even_bar_id, current, why)) begin
        return 0;
    end

    if (target.pcie_id != current.pcie_id || target.global_function_id != current.global_function_id ||
        target.bar_lease != current.bar_lease || target.rc_slot != current.rc_slot ||
        target.canonical_name != current.canonical_name || target.route != current.route) begin
        why = "BAR target contents differ from frozen registry";
        return 0;
    end

    if (width_bytes == 0) begin
        why = "BAR access has zero width";
        return 0;
    end
    last_offset   = {1'b0, byte_offset} + {1'b0, width_bytes} - 1;
    first_address = {1'b0, current.bar_lease.base} + {1'b0, byte_offset};
    last_address  = first_address + {1'b0, width_bytes} - 1;
    // 先限制 BAR 内偏移，避免两个 65 位和仍在极大无效输入下发生第二次进位。
    if (last_offset[64] || last_offset >= {1'b0, current.bar_lease.size} || first_address[64] || last_address[64]) begin
        why = "BAR access crosses lease boundary or overflows 64-bit address";
        return 0;
    end
    address = first_address[63:0];
    why     = "";
    return 1;
endfunction

// Memory 使用实际窗口和整个字节跨度；不读取或改变 requester 身份。
function bit	project_bar_registry::route_memory(
    int unsigned				host_id,
    int unsigned				segment_id,
    bit [63:0]					address,
    bit [63:0]					width_bytes,
    output pcie_tl_cq_route_t	route,
    output string				why
);
    int unsigned	slot;
    int				match_index;
    bit [63:0]		checked;

    route = pcie_tl_cq_route_default();

    if (!get_slot(host_id, segment_id, slot, why)) begin
        return 0;
    end
    match_index = -1;

    foreach (m_targets[i]) begin
        if (m_targets[i].function_key.host_id == host_id &&
            address >= m_targets[i].bar_lease.base && address - m_targets[i].bar_lease.base < m_targets[i].bar_lease.size) begin
            if (match_index >= 0) begin
                why = "ambiguous Memory address in Host domain";
                return 0;
            end
            match_index = i;
        end
    end

    if (match_index < 0) begin
        why = "Memory address has no registered BAR window";
        return 0;
    end

    if (!check_range(m_targets[match_index], address - m_targets[match_index].bar_lease.base, width_bytes, checked, why)) begin
        return 0;
    end
    route            = m_targets[match_index].route;
    route.bar_offset = address - m_targets[match_index].bar_lease.base;
    return 1;
endfunction

// Completion 反查原 Requester ID，完全独立于 Memory 地址和 BAR 归属。
function bit	project_bar_registry::route_completion(
    int unsigned				host_id,
    int unsigned				segment_id,
    bit [15:0]					requester_id,
    output pcie_tl_cq_route_t	route,
    output string				why
);
    int unsigned			slot;
    dpu_pcie_function_id_t	id;

    route = pcie_tl_cq_route_default();

    if (!get_slot(host_id, segment_id, slot, why)) begin
        return 0;
    end

    foreach (m_routes[k]) begin
        if (m_routes[k].function_key.host_id == host_id && m_routes[k].requester_id == requester_id) begin
            if (!m_snapshot.get_pcie_id(m_routes[k].function_key, id, why)) begin
                return 0;
            end
            route.valid       = 1;
            route.target_bdf  = id.bdf;
            route.target_func = id.bdf[7:0];
            route.pf_index    = int'(m_routes[k].pf_index);
            route.is_vf       = m_routes[k].function_key.kind == DPU_FUNCTION_VF;
            route.vf_index    = m_routes[k].vf_index;
            return 1;
        end
    end
    why = "Completion Requester ID has no explicit Intel Function mapping";
    return 0;
endfunction

// 输出稳定排序的真实租约；自动模式按快照身份与代号去重，手工模式可重复。
function bit	project_bar_registry::print_bar_map(
    output string	why,
    input bit	automatic_print = 0
);
    string	identity;

    why = "";

    if (!m_frozen) begin
        why = "BAR map is not ready for publication";
        return 0;
    end
    identity = $sformatf("%0d:%0d", m_snapshot.get_inst_id(), m_generation);

    if (automatic_print && m_auto_printed.exists(identity)) begin
        return 1;
    end
    `uvm_info("DPU_BAR_MAP", $sformatf("snapshot=%0d identity=%0d", m_generation, m_snapshot.get_inst_id()), UVM_LOW)

    foreach (m_targets[i]) begin
        string	binding;

        binding = m_targets[i].route.valid ? $sformatf("pf=%0d vf=%0d active=%0b", m_targets[i].route.pf_index,
            m_targets[i].route.vf_index, m_targets[i].route.is_vf) : "unbound";
        `uvm_info("DPU_BAR_MAP", $sformatf("target=%s snapshot=%0d host=%0d seg=%0d bdf=%04h gfid=%0d role=%s bar=%0d base=%016h size=%016h last=%016h rc=%0d intel_route=%s",
            m_targets[i].canonical_name, m_generation, m_targets[i].function_key.host_id, m_targets[i].pcie_id.domain.segment_id,
            m_targets[i].pcie_id.bdf, m_targets[i].global_function_id, m_targets[i].bar_lease.role.name(),
            m_targets[i].bar_lease.even_bar_id, m_targets[i].bar_lease.base, m_targets[i].bar_lease.size,
            m_targets[i].bar_lease.base + m_targets[i].bar_lease.size - 1, m_targets[i].rc_slot, binding), UVM_LOW)
    end

    if (automatic_print) begin
        m_auto_printed[identity] = 1;
    end
    return 1;
endfunction

// 只读遍历平台 requester 映射；只有冻结 registry 可用于接收，未知身份明确拒绝。
function bit project_bar_registry::resolve_requester(input int unsigned host_id,
    input bit [15:0] requester_id, output dpu_function_key_t key,
    output dpu_pcie_function_id_t pcie_id, output string why);
    why = "unknown DMA requester in frozen Host registry";
    if (!m_frozen) return 0;
    foreach (m_routes[name]) begin
        if (m_routes[name].function_key.host_id == host_id &&
            m_routes[name].requester_id == requester_id) begin
            key = m_routes[name].function_key;
            return m_snapshot.get_pcie_id(key, pcie_id, why);
        end
    end
    return 0;
endfunction
```

## `integration/project/project_dut_config.sv`

SHA-256: `c8284e2126faeefed848b39f156add0e043836405841ff5ada913441c8145f09`

```systemverilog
// integration/project：截图版硬件值类型；仅独立项目 package 包含，禁止进入生产 VIO。
// packed 只描述线格式；普通记录借用冻结快照，不拥有或释放设备/DMA 资源。
// 保留 X/Z 供发送前拒绝；所有未知模块基址和端口由平台明确声明。

typedef struct packed {
	logic [12:0]	reserved_31_19;
	logic		vdpa_en;
	logic		ecrc_en;
	logic		valid;
	logic [15:0]	requester_id;
} project_bdf_entry_t;

typedef struct packed {
	logic		vf_valid;
	logic [10:0]	vf_num;
	logic [3:0]	pf_num;
} project_ep_requester_id_t;

typedef struct packed {
	logic [13:0]	reserved_31_18;
	logic		ecrc_en;
	logic		valid;
	logic [15:0]	completion_id;
} project_completion_bdf_entry_t;

typedef struct packed {
	logic [20:0]	reserved_31_11;
	logic [9:0]	first_vf_offset;
	logic		valid;
} project_pfvf_entry_t;

typedef struct packed {
	logic [29:0]	reserved_63_34;
	logic		vdpa_en;
	logic		valid;
	logic [31:0]	tlp_prefix;
} project_tlp_prefix_entry_t;

typedef struct packed {
	logic [28:0]	reserved_63_35;
	logic [12:0]	global_msix_idx;
	logic [2:0]	host_id;
	logic [9:0]	pfvf_id;
	logic [8:0]	local_msix_idx;
} project_msix_linear_entry_t;

typedef struct packed {
	logic [16:0]	reserved_31_15;
	logic		valid;
	logic		self_mask;
	logic [2:0]	host_id;
	logic [9:0]	function_id;
} project_msix_info_entry_t;

typedef struct packed {
	logic [15:0]	intrl_pnum;
	logic [15:0]	intrl_rate;
} project_msix_interval_entry_t;

typedef struct packed {
	logic [30:0]	reserved_127_97;
	logic		msix_mask;
	logic [31:0]	msix_data;
	logic [63:0]	msix_addr;
} project_msix_table_entry_t;

typedef struct packed {
	logic		valid;
	logic [17:0]	reserved_30_13;
	logic [9:0]	net_id;
	logic [2:0]	cos;
} project_qsch_q2tc_entry_t;

typedef struct packed {
	logic		valid;
	logic [20:0]	reserved_30_10;
	logic [9:0]	group_id;
} project_qsch_n2g_entry_t;

typedef struct packed {
	logic		valid;
	logic [10:0]	reserved_30_20;
	logic [3:0]	dpt;
	logic [11:0]	reserved_15_4;
	logic [3:0]	lvl2_id;
} project_qsch_g2p_entry_t;

typedef struct packed {
	logic [27:0]	reserved_31_4;
	logic [2:0]	host_id;
	logic		enable;
} project_qsch_rnet_entry_t;

typedef struct packed {
	logic [4:0]	reserved_63_59;
	logic [7:0]	vf_id;
	logic [2:0]	host_id;
	logic [47:0]	base_addr_60_13;
} project_rdma_notify_entry_t;

typedef struct packed {
	logic [63:0]	pending;
} project_msix_pba_word_t;

typedef struct packed {
	logic [15:0]	intrl_pnum_stat;
	logic [15:0]	intrl_rate_timer;
} project_msix_stat_t;

typedef struct packed {
	logic [31:0]	status;
} project_pfvf_drop_status_t;

typedef struct packed {
	logic [31:0]	clear_mask;
} project_pfvf_drop_clear_t;

// 同域消息必须唯一确定 owner/vector；接收 sink 不依赖是否存在 VIO service。
typedef struct {
	dpu_function_key_t	owner;
	int unsigned	local_vector;
	int unsigned	global_vector;
	logic [63:0]	address;
	logic [31:0]	data;
	logic	masked;
} project_msix_message_t;

// 类别独立记账；可选平台项不冒充截图已有位域，状态读取不进入初始化类别。
typedef enum int unsigned {
	PROJECT_BAR, PROJECT_AF, PROJECT_PFVF, PROJECT_BDF, PROJECT_COMPLETION_BDF,
	PROJECT_PREFIX, PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL,
	PROJECT_MSIX_CONTROL, PROJECT_MSIX_TABLE, PROJECT_MSIX_FUNCTION,
	PROJECT_NOTIFY, PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR,
	PROJECT_TC_WEIGHT, PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX,
	PROJECT_RDMA_NOTIFY, PROJECT_RNET, PROJECT_MSIX_PBA, PROJECT_MSIX_STAT, PROJECT_PFVF_DROP
} project_table_kind_e;

// 平台必须声明索引来源；局部/全局编号不能因为数值恰巧相同就互换。
typedef enum int unsigned {
	PROJECT_INDEX_EXPLICIT, PROJECT_INDEX_GLOBAL_FUNCTION, PROJECT_INDEX_GLOBAL_QPAIR,
	PROJECT_INDEX_GLOBAL_VECTOR, PROJECT_INDEX_LOCAL_VECTOR
} project_index_policy_e;

typedef enum int unsigned {PROJECT_HOST_EP, PROJECT_HOST_SW} project_host_mode_e;

// 表目标独立于表项 owner；offset 是选定 BAR 内模块偏移，绝非物理地址。
// 间接端口数据宽度固定为该项宽度；control 写入先 clear 再 set trigger_mask。
typedef struct {
	bit	provided;
	string	reg_target;
	bit	access_host_provided;
	int unsigned	access_host;
	bit	access_uses_owner_host;
	logic [63:0]	module_offset;
	logic [63:0]	table_offset;
	int unsigned	capacity;
	int unsigned	entry_bytes;
	project_index_policy_e	index_policy;
	bit	indirect;
	logic [63:0]	data_port;
	logic [63:0]	control_port;
	logic [31:0]	index_mask;
	logic [31:0]	control_fixed;
	logic [31:0]	trigger_mask;
	int unsigned	index_shift;
	bit	required;
} project_table_layout_t;

// 每 Function 的平台编码输入。完整 VF Routing ID 由平台给出，绝不按数量推断。
typedef struct {
	dpu_function_key_t	key;
	project_host_mode_e	mode;
	int unsigned	intel_pf;
	int	intel_vf;
	logic [15:0]	requester;
	int unsigned	vport;
	int unsigned	pfvf;
	int unsigned	first_vf_offset;
	int unsigned	bdf_index;
	int unsigned	completion_index;
	int unsigned	prefix_index;
	logic [31:0]	prefix;
	bit	prefix_enabled;
	bit	ecrc;
	bit	vdpa;
} project_function_policy_t;

// ctx 保存真实访问目标和整个操作范围；仅冻结视图生成，checked helper 再核对原件。
typedef struct {
	dpu_device_snapshot	snapshot;
	longint unsigned	snapshot_id;
	longint unsigned	config_generation;
	string	layout_id;
	project_table_kind_e	kind;
	project_bar_target_t	target;
	project_table_layout_t	layout;
	int unsigned	table_index;
	bit [63:0]	byte_offset;
	string	record_key;
} project_table_context_t;

// 初始化非 packed 上下文时显式处理 class/string/enum，避免四态垃圾参与副本校验。
function automatic project_table_context_t project_empty_context(input project_bar_target_t target);
	project_table_context_t value;
	value.snapshot = null;
	value.snapshot_id = 0;
	value.config_generation = 0;
	value.layout_id = "";
	value.kind = PROJECT_BAR;
	value.target = target;
	value.layout = '{reg_target:"", index_policy:PROJECT_INDEX_EXPLICIT, default:0};
	value.table_index = 0;
	value.byte_offset = 0;
	value.record_key = "";
	return value;
endfunction

// 公共 Function 查询不依赖 VIO ring；service 集合与租约来自同一个冻结快照。
typedef struct {
	dpu_function_key_t	key;
	dpu_pcie_function_id_t	pcie_id;
	int unsigned	global_function_id;
	int unsigned	rc_slot;
	bit	is_af;
	dpu_service_key_t	services[$];
	dpu_bar_pair_lease_t	bars[$];
} project_function_record_t;

// BAR 编码未知，保持真实租约及平台声明的完整原子组，不制造可发送 payload。
typedef struct {
	project_table_context_t	ctx;
	project_function_record_t	owners[$];
	project_bar_target_t	members[$];
} project_bar_mapping_cfg_t;

// 平台控制项没有截图线格式，保留显式声明的 raw/mask；不同类别仍使用独立 hook。
// consumers_complete 声明 catalog 的共享消费者完整（允许明确空集）；AF/SPWRR/TC_WEIGHT 必填。
// MSI-X/RNET/RDMA 自动加入实际 owner service；非空额外消费者也必须声明完整并属于冻结拓扑。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	bit	consumers_complete;
	logic [127:0]	value;
	logic [127:0]	writable_mask;
} project_control_cfg_t;

// bdf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_bdf_entry_t	entry;
} project_bdf_cfg_t;

// completion_bdf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_completion_bdf_entry_t	entry;
} project_completion_bdf_cfg_t;

// pfvf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_pfvf_entry_t	entry;
} project_pfvf_cfg_t;

// tlp_prefix 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_tlp_prefix_entry_t	entry;
} project_tlp_prefix_cfg_t;

// msix_linear 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_linear_entry_t	entry;
} project_msix_linear_cfg_t;

// msix_info 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_info_entry_t	entry;
} project_msix_info_cfg_t;

// msix_interval 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_interval_entry_t	entry;
} project_msix_interval_cfg_t;

// msix_table 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_table_entry_t	entry;
} project_msix_table_cfg_t;

// qsch_q2tc 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_q2tc_entry_t	entry;
} project_qsch_q2tc_cfg_t;

// qsch_n2g 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_n2g_entry_t	entry;
} project_qsch_n2g_cfg_t;

// qsch_g2p 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_g2p_entry_t	entry;
} project_qsch_g2p_cfg_t;

// qsch_rnet 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_rnet_entry_t	entry;
} project_qsch_rnet_cfg_t;

// rdma_notify 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_rdma_notify_entry_t	entry;
} project_rdma_notify_cfg_t;

// 公共只读导出拥有值副本、借用 snapshot/registry；不依赖 VIO ring 生命周期。
class project_dpu_setup extends uvm_object;
	local dpu_device_snapshot	m_snapshot;
	local project_bar_registry	m_registry;
	local longint unsigned	m_generation;
	local project_function_record_t	m_functions[$];
	local dpu_af_extra_queue_binding_t	m_extras[$];

	// 发布时一次构造，未知/失配的 Function 或 slot 使构造失败而不是发布半份视图。
	extern function new(string name, dpu_device_snapshot snapshot,
		project_bar_registry registry, longint unsigned generation);
	// 导出前校验真实租约和 RC 域；失败不改变旧值集合。
	extern function bit populate(input dpu_resource_snapshot resources, output string why);
	// 身份和代号只读，用于拒绝旧 scope；调用方无法更换内部 registry。
	extern function bit belongs_to(input dpu_device_snapshot snapshot, input project_bar_registry registry);
	// 查询函数只返回值副本，不允许通过副本改写冻结拓扑。
	extern function void list_functions(output project_function_record_t records[$]);
	extern function bit get_function(input dpu_function_key_t key, output project_function_record_t record);
	extern function void list_af_extra_queues(output dpu_af_extra_queue_binding_t records[$]);
	extern function longint unsigned get_generation();
endclass

// 空键表示整份视图；BAR 选择仍保留完整 Function 身份，不重新编号。
class project_dpu_config_scope extends uvm_object;
	local project_dpu_setup	m_setup;
	local dpu_function_key_t	m_keys[$];
	local int unsigned	m_bars[$];
	local project_table_kind_e	m_kinds[$];
	// 保存选择；validate 在任何 hook 前一次检查全部未知/重复项。
	extern function new(string name, project_dpu_setup setup,
		dpu_function_key_t keys[$], int unsigned bars[$], project_table_kind_e kinds[$] = {});
	// 同一代且全部键存在才通过；空子集合不能意外扩大成其他 Host。
	extern function bit validate(input project_dpu_setup setup, output string why);
	// 只读选择查询，调用前必须 validate。
	extern function bit selects(input dpu_function_key_t key);
	extern function bit selects_bar(input int unsigned bar_id);
	extern function bit selects_kind(input project_table_kind_e kind);
endclass

// 借用冻结来源，populate 成功前无 Function 记录可访问。
function project_dpu_setup::new(string name, dpu_device_snapshot snapshot,
	project_bar_registry registry, longint unsigned generation);
	super.new(name);
	m_snapshot = snapshot;
	m_registry = registry;
	m_generation = generation;
endfunction

// 从实际快照枚举租约，保持无 VIO Host/Function 的公共导出能力。
function bit project_dpu_setup::populate(input dpu_resource_snapshot resources, output string why);
	dpu_function_key_t	keys[$];
	dpu_function_key_t	af;
	dpu_bar_pair_lease_t	af_bar;
	dpu_service_key_t	services[$];
	project_function_record_t	candidates[$];
	why = "public setup needs frozen registry and snapshots";
	if (m_snapshot == null || m_registry == null || resources == null) return 0;
	if (!m_registry.is_frozen() || m_functions.size() != 0 || m_generation == 0) return 0;
	if (!m_snapshot.get_expected_af(af, af_bar, why)) return 0;
	m_snapshot.list_functions(keys);
	m_snapshot.list_services(DPU_SERVICE_VIO_NET, services);
	foreach (keys[i]) begin
		project_function_record_t	r;
		r.key = keys[i];
		r.is_af = dpu_same_function_key(keys[i], af);
		if (!m_snapshot.get_pcie_id(r.key, r.pcie_id, why) ||
			!m_snapshot.get_global_function_id(r.key, r.global_function_id, why) ||
			!m_snapshot.list_bars(r.key, r.bars, why) ||
			!m_registry.get_slot(r.key.host_id, r.pcie_id.domain.segment_id, r.rc_slot, why)) return 0;
		foreach (services[j])
			if (dpu_same_function_key(r.key, services[j].function_key)) r.services.push_back(services[j]);
		candidates.push_back(r);
	end
	m_functions = candidates;
	resources.list_af_extra_queue_bindings(m_extras);
	why = "";
	return 1;
endfunction

// 只比较借用身份，既不重新采样参数也不重新分配地址。
function bit project_dpu_setup::belongs_to(input dpu_device_snapshot snapshot, input project_bar_registry registry);
	return m_snapshot == snapshot && m_registry == registry && m_generation != 0;
endfunction

// 返回整份值副本，修改结果不影响公共拓扑。
function void project_dpu_setup::list_functions(output project_function_record_t records[$]);
	records = m_functions;
endfunction

// 完整 Function key 查询，失败不回退 PF0。
function bit project_dpu_setup::get_function(input dpu_function_key_t key, output project_function_record_t record);
	foreach (m_functions[i]) begin
		if (dpu_same_function_key(m_functions[i].key, key)) begin
			record = m_functions[i];
			return 1;
		end
	end
	return 0;
endfunction

// AF 额外项是真实容量消费者，单列而不虚构 ring。
function void project_dpu_setup::list_af_extra_queues(output dpu_af_extra_queue_binding_t records[$]);
	records = m_extras;
endfunction

// 公共发布代号不随 VIO ring 准备代号变化。
function longint unsigned project_dpu_setup::get_generation();
	return m_generation;
endfunction

// scope 借用精确 setup；不取得资源或管理权。
function project_dpu_config_scope::new(string name, project_dpu_setup setup,
	dpu_function_key_t keys[$], int unsigned bars[$], project_table_kind_e kinds[$]);
	super.new(name);
	m_setup = setup;
	m_keys = keys;
	m_bars = bars;
	m_kinds = kinds;
endfunction

// 全范围只读预检必须发生在第一个用户 hook 前；BAR 必须在每个选中 Function 存在。
function bit project_dpu_config_scope::validate(input project_dpu_setup setup, output string why);
	project_function_record_t	r;
	project_function_record_t	all[$];
	bit	seen[string];
	bit	found;
	why = "scope belongs to another public setup";
	if (setup == null || setup != m_setup) return 0;
	foreach (m_keys[i]) begin
		if (!setup.get_function(m_keys[i], r) || seen.exists(dpu_function_key_name(m_keys[i]))) begin
			why = "scope contains unknown/duplicate Function";
			return 0;
		end
		seen[dpu_function_key_name(m_keys[i])] = 1;
	end
	setup.list_functions(all);
	foreach (m_bars[b]) begin
		foreach (m_bars[j]) if (j < b && m_bars[b] == m_bars[j]) begin
			why = "scope contains duplicate BAR"; return 0;
		end
		foreach (all[f]) begin
			if (!selects(all[f].key)) continue;
			found = 0;
			foreach (all[f].bars[k]) if (all[f].bars[k].even_bar_id == m_bars[b]) found = 1;
			if (!found) begin why = "scope BAR is not a real lease on every selected Function"; return 0; end
		end
	end
	why = "";
	return 1;
endfunction

// 不按全局编号范围推测成员，非连续 Function 保持原身份。
function bit project_dpu_config_scope::selects(input dpu_function_key_t key);
	if (m_keys.size() == 0) return 1;
	foreach (m_keys[i]) if (dpu_same_function_key(m_keys[i], key)) return 1;
	return 0;
endfunction

// 空 BAR 列表表示选中 Function 的实际全部租约。
function bit project_dpu_config_scope::selects_bar(input int unsigned bar_id);
	if (m_bars.size() == 0) return 1;
	foreach (m_bars[i]) if (m_bars[i] == bar_id) return 1;
	return 0;
endfunction

// 只读/W1C 查询只接受独立上下文；禁止用状态值进入普通初始化 dispatch。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
} project_state_query_t;

typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	project_pfvf_drop_clear_t	entry;
} project_pfvf_drop_clear_cfg_t;

// MSI-X 地址/数据模板独立于 VIO；存在标志区分显式零与未提供，PBA 容量必须明确。
typedef struct {
	bit	table_only_enable;
	bit	interval_present;
	project_msix_interval_entry_t	interval_entry;
	bit	self_mask_present;
	logic	self_mask;
	bit	address_present;
	bit	data_present;
	logic [63:0]	address_base;
	logic [63:0]	address_stride;
	logic [31:0]	data_base;
	logic [31:0]	data_stride;
	bit	table_present;
	int unsigned	table_bar;
	logic [63:0]	table_offset;
	int unsigned	table_size;
	bit	pba_present;
	int unsigned	pba_bar;
	logic [63:0]	pba_offset;
	int unsigned	pba_words;
} project_msix_policy_t;

// BAR 原子组只声明逻辑成员，发布时解析真实租约；不要求用户在 build 前知道随机 BAR base。
typedef struct {
	string	name;
	dpu_function_key_t	functions[$];
	int unsigned	bar_ids[$];
} project_bar_group_policy_t;

// PFVF 关系校验输入包含同一 PF 的完整实际成员，不用数量/隐含 VF stride 推算路由。
typedef struct {
	project_function_record_t	functions[$];
	project_function_policy_t	policies[$];
} project_pfvf_relationship_t;

// 空类别列表保持全类别视图；明确类别只能确认其自己的账本项。
function bit project_dpu_config_scope::selects_kind(input project_table_kind_e kind);
	if (m_kinds.size() == 0) return 1;
	foreach (m_kinds[i]) if (m_kinds[i] == kind) return 1;
	return 0;
endfunction
```

## `integration/project/project_vio_config.sv`

SHA-256: `af17bc0996c99420bb51b010c9f3cc980f5955e56f90f572b660a7b61f4a262b`

```systemverilog
// integration/project：截图版硬件值类型；仅独立项目 package 包含，禁止进入生产 VIO。
// packed 只描述线格式；普通记录借用冻结快照，不拥有或释放设备/DMA 资源。
// 保留 X/Z 供发送前拒绝；所有未知模块基址和端口由平台明确声明。

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

typedef struct packed {
	logic [50:0]	reserved_127_77;
	logic [1:0]	notify_type;
	logic [10:0]	global_qid;
	logic [2:0]	host_id;
	logic [53:0]	base_addr_60_7;
	logic [6:0]	local_qid_encoding;
} project_vio_notify_entry_t;

typedef struct packed {
	logic		reserved_127;             // [127]
	logic [14:0]	dsc_pre_read_ram_addr;     // [126:112]，单位为 descriptor 槽
	logic [2:0]	dsc_pre_max_num;           // [111:109]，0 表示 256 槽
	logic		reserved_108;             // [108]
	logic [1:0]	dsc_pre_read_threshold;    // [107:106]
	logic [1:0]	dsc_dma_num;               // [105:104]
	logic [1:0]	dsc_mode;                  // [103:102]
	logic [2:0]	payload_dsc_len;           // [101:99]
	logic [1:0]	head_dsc_len;              // [98:97]
	logic		dma_msix_en;               // [96]
	logic [12:0]	dma_msix;                 // [95:83]
	logic [9:0]	dport_id;                 // [82:73]
	logic [2:0]	dport;                    // [72:70]
	logic		virtio_mode;              // [69]
	logic		queue_en;                 // [68]
	logic [3:0]	q_depth;                  // [67:64]，log2(descriptor 数)
	logic [63:0]	dsc_addr;                 // [63:0]，设备可见 ring IOVA
} project_vrx_entry_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	project_vtx_entry_t	entry;
} project_vtx_cfg_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	project_vrx_entry_t	entry;
} project_vrx_cfg_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	project_vio_notify_entry_t	entry;
} project_vio_notify_cfg_t;

// 队列平台策略按 service 给出；pair 映射可用显式基数/步长生成，冻结后不可重新采样。
// VRX RAM 是 descriptor 槽，域名表示实际共享 RAM；不同 Host 相同域仍检查非重叠。
typedef struct {
	dpu_service_key_t	service_key;
	project_vtx_entry_t	vtx;
	project_vrx_entry_t	vrx;
	bit	fpga;
	string	prefetch_ram;
	int unsigned	prefetch_start;
	int unsigned	prefetch_slots;
	int unsigned	net_base;
	int unsigned	net_stride;
	int unsigned	group_id;
	int unsigned	cos;
	int unsigned	eth_ports;
	bit	ets;
	bit	distinguish_business;
	int unsigned	ets_priority;
	bit	notify_net_pair5;
	bit	notify_table_base_provided;
	int unsigned	notify_table_bar;
	logic [63:0]	notify_table_offset;
} project_vio_policy_t;

// 内部统一账本复用预检/锁/结果；外部 hook 始终消费类别对应的 typed cfg。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	bit	has_queue;
	vio_queue_setup_t	binding;
	logic [127:0]	entry;
	logic [127:0]	enable_mask;
	logic [127:0]	enable_value;
	string	dependencies[$];
} project_config_record_t;

// 跨 Host 选择显式携带每个核心 setup/scope；调用方可选非连续 Host/service。
// 值只借用句柄，项目在提交/释放前先验证全部 Host，不能把循环误当原子保证。
typedef struct {
	vio_external_setup	setups[int unsigned];
	vio_config_scope	scopes[int unsigned];
} project_vio_selection_t;

// 使能和辅助上下文仍携带完整 ring 绑定，用户无需回查其他配置对象。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	logic [127:0]	value;
	logic [127:0]	writable_mask;
} project_queue_control_cfg_t;
```

## `integration/project/project_pcie_rc_driver.sv`

SHA-256: `637c23823a5c94531de283720c977099c666cff7ac006a67d6c1719884f8759c`

```systemverilog
// integration/project：固定 Intel 接入的 RC 发送前路由桥，依赖冻结 BAR registry。
// 借用 registry；请求、Tag、Completion 生命周期继续由通用 RC driver 管理。
// env 应对 pcie_tl_rc_driver 安装实例 override，路径 pcie_env.rc_agent_<slot>.driver，
// 保留 agent 自己的 base_driver override 链；connect 阶段检查 cast 后安装冻结映射。
class project_pcie_rc_driver extends pcie_tl_rc_driver;
	`uvm_component_utils(project_pcie_rc_driver)
	protected project_bar_registry	m_registry;
	protected int unsigned			m_host_id;
	protected int unsigned			m_segment_id;
	protected int unsigned			m_rc_slot;

	local project_msix_message_t	m_messages[$];
	local virtio_pcie_iova_host_mem_proxy	m_proxies[bit [15:0]];
	local virtio_iommu_model	m_iommu;
	local host_mem_manager	m_backing;
	local semaphore	m_receive_lock = new(1);
	local bit	m_receive_installed;

	// 整个 catalog 预检后一次冻结；消息 sink 与 DMA 都保留本 RC 的 Host 域。
	extern function bit install_receive_path(input host_mem_manager backing,
		input virtio_iommu_model iommu, input project_msix_message_t messages[$],
		output string why);

	// 只读检查完整 wire 请求；返回 sink 标志，不写 Host、不消耗 observer 的消息。
	extern function bit validate_receive(input pcie_tl_tlp request,
		output bit message_sink, output string why);

	// bridge 仍是唯一 responder；仅在串行锁内临时选择 requester 对应的 IOVA proxy。
	extern virtual task handle_request(pcie_tl_tlp req);

	// 只构造组件，不推断 Host 或默认 PF0 路由。
	extern function	new(
		string			name = "project_pcie_rc_driver",
		uvm_component	parent = null
	);

	// 显式注入已冻结 registry 与自身域/slot；已安装后只允许完全相同的重复注入，禁止静默更换活跃映射。
	extern function bit	install_registry(
		project_bar_registry	registry,
		int unsigned			host_id,
		int unsigned			segment_id,
		int unsigned			rc_slot,
		output string			why
	);

	// 唯一发送前判定入口；先核对实际 Type/Fmt 与地址编码，再路由；失败清空旧 route，保留身份和 Tag。
	extern function bit	route_tlp(
		pcie_tl_tlp		tlp,
		output string	why
	);

	// 先完成路由再进入父类；失败为明确 fatal 且立即返回，不分配 Tag、不发送观察/数据。
	extern virtual task	send_tlp(
		pcie_tl_tlp	tlp
	);
endclass

// 只构造组件，不推断 Host 或默认 PF0 路由。
function	project_pcie_rc_driver::new(
	string			name = "project_pcie_rc_driver",
	uvm_component	parent = null
);
	super.new(name, parent);
endfunction

// 显式注入已冻结 registry 与自身域/slot；已安装后只允许完全相同的重复注入，禁止静默更换活跃映射。
function bit	project_pcie_rc_driver::install_registry(
	project_bar_registry	registry,
	int unsigned			host_id,
	int unsigned			segment_id,
	int unsigned			rc_slot,
	output string			why
);
	int unsigned	bound_slot;

	why = "project RC requires a frozen registry";

	if (registry == null) begin
		return 0;
	end

	if (!registry.get_slot(host_id, segment_id, bound_slot, why)) begin
		return 0;
	end

	if (bound_slot != rc_slot) begin
		why = "project RC slot disagrees with registry Host binding";
		return 0;
	end

	if (m_registry != null && (m_registry != registry || m_host_id != host_id ||
		m_segment_id != segment_id || m_rc_slot != rc_slot)) begin
		why = "project RC registry binding is immutable after installation";
		return 0;
	end

	m_registry   = registry;
	m_host_id    = host_id;
	m_segment_id = segment_id;
	m_rc_slot    = rc_slot;
	why          = "";
	return 1;
endfunction

// 唯一发送前判定入口；先核对实际 Type/Fmt 与地址编码，再路由；失败清空旧 route，保留身份和 Tag。
function bit	project_pcie_rc_driver::route_tlp(
	pcie_tl_tlp		tlp,
	output string	why
);
	pcie_tl_mem_tlp		mem;
	pcie_tl_cpl_tlp		cpl;
	pcie_tl_cq_route_t	route;
	bit [64:0]			first_address;
	bit [64:0]			last_address;
	int					first_lane;
	int					last_lane;

	why = "project RC has no installed BAR registry or request is null";

	if (tlp == null) begin
		return 0;
	end
	tlp.cq_route = pcie_tl_cq_route_default();

	if (m_registry == null) begin
		return 0;
	end

	case (tlp.kind)
		TLP_MEM_RD, TLP_MEM_WR, TLP_MEM_RD_LK: begin
			if (!$cast(mem, tlp)) begin
				why = "Memory TLP kind/type mismatch";
				return 0;
			end
			// kind 是对象语义，codec 却直接写 type_f/fmt；普通赋值不会执行随机约束，
			// 必须在父类发送前核对，避免 Config 伪装或读写/锁定语义改变。
			if (mem.type_f != (mem.kind == TLP_MEM_RD_LK ? TLP_TYPE_MEM_RD_LK : TLP_TYPE_MEM_RD) ||
				(mem.kind == TLP_MEM_WR && !(mem.fmt inside {FMT_3DW_WITH_DATA, FMT_4DW_WITH_DATA})) ||
				(mem.kind != TLP_MEM_WR && !(mem.fmt inside {FMT_3DW_NO_DATA, FMT_4DW_NO_DATA}))) begin
				why = "Memory kind/Type/Fmt mismatch";
				return 0;
			end

			// 3DW 编码只携带低 32 位；不能用完整高地址通过 BAR 检查后再在线上截断。
			if ((mem.fmt inside {FMT_3DW_NO_DATA, FMT_3DW_WITH_DATA}) && mem.addr[63:32] != 0) begin
				why = "3DW Memory cannot encode a nonzero upper address";
				return 0;
			end

			first_lane = -1;
			last_lane  = -1;
			// BE 可能稀疏：检查首末使能字节之间的整个跨度，不仅检查起始地址。
			// wire DWORD 与 BAR 范围各自保留意义；不用 request.addr 低位替代 first_be。
			for (int unsigned	i = 0; i < pcie_tl_mem_dw_count(mem) * 4; i++) begin
				if (pcie_tl_mem_lane_enabled(mem, i)) begin
					if (first_lane < 0) begin
						first_lane = int'(i);
					end
					last_lane = int'(i);
				end
			end

			if (first_lane < 0) begin
				why = "Memory request has no enabled bytes";
				return 0;
			end
			first_address = {1'b0, pcie_tl_mem_wire_addr(mem)} + 65'(first_lane);
			last_address  = {1'b0, pcie_tl_mem_wire_addr(mem)} + 65'(last_lane);

			if (first_address[64] || last_address[64] || first_address[63:12] != last_address[63:12]) begin
				why = "Memory request overflows address or crosses 4KB boundary";
				return 0;
			end

			if (!m_registry.route_memory(m_host_id, m_segment_id, first_address[63:0],
				64'(last_lane - first_lane + 1), route, why)) begin
				return 0;
			end
		end
		TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK: begin
			if (!$cast(cpl, tlp)) begin
				why = "Completion TLP kind/type mismatch";
				return 0;
			end

			// Completion 只有 3DW 形式；Type 的锁定位和 Fmt 的数据位须与 kind 同义。
			if (cpl.type_f != ((cpl.kind inside {TLP_CPL_LK, TLP_CPLD_LK}) ? TLP_TYPE_CPL_LK : TLP_TYPE_CPL) ||
				cpl.fmt != ((cpl.kind inside {TLP_CPLD, TLP_CPLD_LK}) ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA)) begin
				why = "Completion kind/Type/Fmt mismatch";
				return 0;
			end

			if (!m_registry.route_completion(m_host_id, m_segment_id, cpl.requester_id, route, why)) begin
				return 0;
			end
		end
		TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1: begin
			why = "Configuration TLP is prohibited by project external-device mode";
			return 0;
		end
		default: begin
			why = "project RC supports only Memory requests and Completions";
			return 0;
		end
	endcase
	tlp.cq_route = route;
	why          = "";
	return 1;
endfunction

// 先完成路由再进入父类；失败为明确 fatal 且立即返回，不分配 Tag、不发送观察/数据。
task	project_pcie_rc_driver::send_tlp(
	pcie_tl_tlp	tlp
);
	string	why;

	if (!route_tlp(tlp, why)) begin
		`uvm_fatal("PROJECT_RC_ROUTE", why)
		return;
	end
	super.send_tlp(tlp);
endtask

// 公共消息项先完整预检，成功后借用 Host/IOMMU；不安装第二个 responder。
function bit project_pcie_rc_driver::install_receive_path(input host_mem_manager backing,
	input virtio_iommu_model iommu, input project_msix_message_t messages[$], output string why);
	dpu_function_key_t	key;
	dpu_pcie_function_id_t	id;
	why = "receive path needs registry, Host memory and IOMMU";
	if (m_receive_installed || m_registry == null || backing == null || iommu == null) return 0;
	if (!backing.is_initialized() || backing.get_host_id() != m_host_id) return 0;
	foreach (messages[i]) begin
		if (messages[i].owner.host_id != m_host_id ||
			$isunknown({messages[i].address, messages[i].data, messages[i].masked}) ||
			messages[i].address[1:0] != 0) begin
			why = "message catalog has wrong Host, unknown data or unaligned address";
			return 0;
		end
		foreach (messages[j]) begin
			if (j < i && messages[i].address == messages[j].address && messages[i].data == messages[j].data) begin
				why = "message catalog contains duplicate/ambiguous receiver";
				return 0;
			end
		end
	end
	m_backing = backing;
	m_iommu = iommu;
	m_messages = messages;
	m_receive_installed = 1;
	why = "";
	return 1;
endfunction

// 校验全部使能字节及权限，确保失败发生在首个 dirty write/Completion 之前。
// sink 只识别完整四字节消息；未知消息仍走严格 DMA，不能吞掉普通内存访问。
function bit project_pcie_rc_driver::validate_receive(input pcie_tl_tlp request,
	output bit message_sink, output string why);
	pcie_tl_mem_tlp	r;
	dpu_function_key_t	key;
	dpu_pcie_function_id_t	id;
	bit [63:0]	gpa;
	bit [64:0]	address;
	bit [31:0]	data;
	iommu_fault_e	fault;
	int unsigned	count;
	int	first_lane;
	int	last_lane;
	message_sink = 0;
	why = "external RC accepts only valid Memory requests";
	if (!m_receive_installed || request == null) return 0;
	if (!$cast(r, request)) return 0;
	if (!(r.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR}) ||
		r.type_f != (r.kind == TLP_MEM_RD_LK ? TLP_TYPE_MEM_RD_LK : TLP_TYPE_MEM_RD) ||
		(r.kind == TLP_MEM_WR && !(r.fmt inside {FMT_3DW_WITH_DATA, FMT_4DW_WITH_DATA})) ||
		(r.kind != TLP_MEM_WR && !(r.fmt inside {FMT_3DW_NO_DATA, FMT_4DW_NO_DATA})) ||
		((r.fmt inside {FMT_3DW_NO_DATA, FMT_3DW_WITH_DATA}) && r.addr[63:32] != 0)) return 0;
	count = pcie_tl_mem_dw_count(r) * 4;
	if (r.kind == TLP_MEM_WR && r.payload.size() != count) begin
		why = "DMA write payload length differs from wire length";
		return 0;
	end
	first_lane = -1;
	last_lane = -1;
	for (int unsigned i = 0; i < count; i++) begin
		if (pcie_tl_mem_lane_enabled(r, i)) begin
			if (first_lane < 0) first_lane = i;
			last_lane = i;
		end
	end
	address = {1'b0, pcie_tl_mem_wire_addr(r)} + count - 1;
	if (first_lane < 0 || address[64] || address[63:12] != r.addr[63:12]) begin
		why = "DMA request has empty lanes, overflow or crosses 4KB";
		return 0;
	end
	if (r.kind == TLP_MEM_WR && last_lane - first_lane == 3 &&
		pcie_tl_mem_valid_bytes(r) == 4) begin
		data = '0;
		for (int unsigned i = 0; i < 4; i++) data[i*8 +: 8] = r.payload[first_lane+i];
		foreach (m_messages[i]) begin
			if (m_messages[i].address == pcie_tl_mem_wire_addr(r) + first_lane && m_messages[i].data == data) begin
				message_sink = 1;
				why = "";
				return 1;
			end
		end
	end
	if (!m_registry.resolve_requester(m_host_id, r.requester_id, key, id, why)) return 0;
	for (int unsigned i = 0; i < count; i++) begin
		if (pcie_tl_mem_lane_enabled(r, i) && !m_iommu.validate_for_host(m_host_id,
			id.bdf, pcie_tl_mem_wire_addr(r) + i, 1,
			r.kind == TLP_MEM_WR ? DMA_FROM_DEVICE : DMA_TO_DEVICE, gpa, fault)) begin
			why = {"DMA permission/range failure: ", fault.name()};
			return 0;
		end
	end
	why = "";
	return 1;
endfunction

// 锁只在 RC receive 边界持有；父类异步发送 Completion 期间不会被另一 requester 改写 mem。
task project_pcie_rc_driver::handle_request(pcie_tl_tlp req);
	bit	message_sink;
	string	why;
	host_mem_api	saved_mem;
	dpu_function_key_t	key;
	dpu_pcie_function_id_t	id;
	pcie_tl_mem_tlp	r;
	m_receive_lock.get();
	if (!validate_receive(req, message_sink, why)) begin
		m_receive_lock.put();
		`uvm_error("PROJECT_RC_DMA", why)
		return;
	end
	if (message_sink) begin
		m_receive_lock.put();
		return;
	end
	void'($cast(r, req));
	if (!m_registry.resolve_requester(m_host_id, r.requester_id, key, id, why)) begin
		m_receive_lock.put();
		`uvm_error("PROJECT_RC_DMA", why)
		return;
	end
	if (!m_proxies.exists(r.requester_id)) begin
		m_proxies[r.requester_id] = virtio_pcie_iova_host_mem_proxy::type_id::create("requester_proxy");
		if (!m_proxies[r.requester_id].configure(m_backing, m_iommu, m_host_id, id.bdf, why)) begin
			m_receive_lock.put();
			`uvm_fatal("PROJECT_RC_DMA", why)
			return;
		end
	end
	saved_mem = mem;
	mem = m_proxies[r.requester_id];
	super.handle_request(req);
	mem = saved_mem;
	m_receive_lock.put();
endtask
```

## `integration/project/project_env_cfg.sv`

SHA-256: `54f48e3246fc2cf3253392c63aec6ddd136e811735dff1c508cdf39f7b5a43e8`

```systemverilog
// integration/project：项目级配置组合与参数构建示例。
// 依赖 DPU、PCIe TL、Intel adapter、VIO 与 AIP；由 project_env_pkg 按顺序包含。
// 类内集中声明配置成员和 extern 方法；全部实现在本文件类外展开，无额外编译入口。
// cfg 拥有输入配置与资源视图，借用 env 发布的组件、快照、pool、IOMMU 与 VIF。
// 同一 cfg 通过 config_db 交给配置 seq；纯校验/资源生命周期在此，硬件访问在 seq。
// BDF 独立默认开启，MSI-X 按完成模式选择；其余公共表由 configure_public 显式开启。
// load_params 只生成输入，不解析快照、不创建组件、不访问 DUT；每个对象只加载一次。
// 每 Host 一个 segment 0 和一组 TL 接口；PF/VF 共用接口，不配置 SVT 或链路训练。
// 固定使用真实 EP 应用 DUT 的 Intel HARD_IP 接口；每 Host 仅创建一个 RC。
class project_env_cfg extends uvm_object;
	`uvm_object_utils(project_env_cfg)

	// 默认采用驱动 VIO/QSCH/BDF/MSI-X 布局与无 IP 的 PF0 软件路由；显式平台声明优先。
	// BDF 默认下发，MSI-X 按完成模式选择；其余公共表开关不影响 BAR/队列软件资源。
	string				reg_target = "pf0.bar0";
	bit				print_bar_map = 1;
	bit				configure_public = 0;
	bit				configure_bdf = 1;
	bit				driver_layouts = 1;
	// 日常用例默认只写；调试时开启配置读回，失败则不确认资源。
	bit				verify_readback = 0;

	// QSCH 模式寄存器采用驱动偏移；SP/WRR 与 TC 权重按实际 net_id 生成。
	bit				qsch_configure_controls = 1;
	int unsigned			qsch_mode = 0;
	logic [63:0]			qsch_mode_offset = 'hb001c0;
	logic [31:0]			qsch_spwrr = 'hff;
	logic [31:0]			qsch_tc_weight = 'h11111111;
	project_table_layout_t		table_layouts[project_table_kind_e];
	project_function_policy_t	function_policies[string];
	project_vio_policy_t		vio_policies[string];
	project_msix_message_t		messages[$];
	project_bar_mapping_cfg_t	bar_groups[$];
	bit				bar_mapping_per_lease = 0;
	project_bar_group_policy_t	bar_group_policies[$];
	project_control_cfg_t		platform_controls[$];

	project_msix_policy_t	msix_policies[string];
	project_msix_message_t	message_templates[string][int unsigned];

	// 参数只在 load_params 一次采样；消息模板无需 VIO service，公共向量在发布时关联。
	extern protected function void load_platform_params();
	// 只补未声明布局；调用者可用 provided 布局覆盖，或关闭 driver_layouts 全部自行提供。
	extern function void use_driver_reference_layouts();
	extern protected function void set_driver_layout(
		input project_table_kind_e	kind,
		input logic [63:0]		module_offset,
		input logic [63:0]		table_offset,
		input int unsigned		entry_bytes,
		input int unsigned		capacity,
		input project_index_policy_e	index_policy
	);

	// 软件路由只在默认 PF0/no-VF 场景补齐；其余 Function 的 requester 必须显式提供。
	extern protected function void load_function_routes();

	// 每代准备时从实际资源生成缺省调度项；显式 catalog 优先，不累积上代生成项。
	extern protected function bit materialize_qsch_controls(
		output string	why
	);

	// 从最终完成模式选择中断 Function；无中断时返回 null，缺消息或 mask 置位则失败。
	extern function bit select_msix_scope(
		output project_dpu_config_scope	scope,
		output string			why
	);

	// 完整冻结消息生成稳定查找行号，独立 scope 只筛选；不依赖 ring 分配。
	extern protected function bit materialize_msix_linear_records(
		output string	why,
		input project_dpu_config_scope	scope = null
	);

	// 公共向量来自资源快照，AF 额外资源也能在没有任何 VIO service 时产生消息项。
	extern function bit materialize_messages(
		input dpu_resource_snapshot	resources,
		output string			why
	);
	// 同一共享向量只登记一次；显式消息优先但必须与冻结向量身份一致。
	extern protected function bit add_message(
		input dpu_function_key_t	owner,
		input int unsigned		local_vector,
		input int unsigned		global_vector,
		output string			why
	);

	// PF0/no-VF 参考关系可直接校验；其他 PF/VF 家族须由平台提供真实编码规则。
	extern virtual function bit validate_pfvf_relationship(
		input project_pfvf_relationship_t	family,
		output string				why
	);

	// 按完整 service 最终需求创建唯一固定 placement request，disabled 不删除 Function。
	extern protected function void add_service_request(
		input dpu_function_key_t	key
	);

	// 三类子配置由本对象创建；每个 Host 的 VIO 配置在加载参数后独立生成。
	dpu_device_env_config	dpu_cfg;
	virtio_net_env_config	vio_cfg;
	virtio_net_env_config	vio_cfg_by_host[int unsigned];
	pcie_tl_env_config	pcie_cfg;

	// 值是 RC agent 下标；EP 由真实 DUT 提供。缺省 h→h，PF/VF 共用 Host 的 slot。
	int unsigned	tl_slot_by_host[int unsigned];

	// 借用平台已有 pool；分配模式和粒度只作用于需要新建的 Host manager。
	host_mem_pool	host_mem_pool_binding;
	alloc_mode_e	host_mem_mode    = MODE_BUDDY;
	int unsigned	host_mem_granule = DEFAULT_MIN_GRANULE;

	// 按物理 RC slot 索引，不是按 PF/VF 索引；同一 Host 的 Function 共用端口。
	// 平台可注入句柄，或由 bind wrapper 向实际 adapter 路径发布；env 会复用并校验。
	// Intel cfg 没有 load_params；这里不宣称 pcie_cfg.intel.* 已自动注册。
	intel_pcie_adapter_config	intel_cfg_by_slot[int unsigned];
	intel_pcie_vif_t		intel_rc_vifs[int unsigned];

	virtual virtio_protocol_event_if	protocol_vifs[$];

	// 这是配置生成规模，不是另一套已解析拓扑；最终身份以 DPU snapshot 为准。
	longint unsigned	hosts         = 1;
	longint unsigned	pfs_per_host  = 1;
	longint unsigned	vfs_per_pf    = 0;
	protected bit		params_loaded = 0;

	// 创建默认子 cfg，不读取参数；默认构造名字只在此声明，类外实现沿用该接口。
	extern function	new(
		string	name = "project_env_cfg"
	);

	// 仅首次调用加载参数并生成 Host/PF/VF 输入，拒绝覆盖已有拓扑或越过硬件容量。
	extern virtual function void	load_params();

	// 只读校验 Host→slot 的完整一一映射，失败通过 why 返回原因，不修补配置。
	extern function bit	validate_tl_mapping(
		output string	why
	);

	// 创建未解析的 Host 地址模板；调用者后续填写身份并加载 Host 级参数。
	extern protected function dpu_host_cfg	make_host_template();

	// 按完整身份和 DUT BAR 能力生成一个 Function；能力缺失时立即报告 fatal。
	extern protected function dpu_function_cfg	make_function(
		int unsigned		host_id,
		int unsigned		pf_id,
		dpu_function_kind_e	kind,
		int unsigned		vf_id
	);

	// env 在 connect 填充，seq 借用；保持同一对象句柄，禁止 clone/copy 运行期 cfg。
	// 输入参数在 load_params 采样；下面运行期字段只由 env、配置 seq 和生命周期方法更新。
	bit				runtime_ready;
	dpu_device_snapshot		device_snapshot;
	dpu_resource_snapshot		resource_snapshot;
	uvm_sequencer #(pcie_tl_tlp)	rc_sequencers[int unsigned];
	virtio_net_env			vio_envs[int unsigned];

	// BAR/公共视图和当前 ring 代可供用户只读查询；组件与 ring 仍由原创建者拥有。
	project_bar_registry	bar_registry;
	project_dpu_setup	dpu_setup;
	vio_external_setup	vio_setups[int unsigned];
	project_msix_message_t	frozen_messages[$];
	project_config_record_t	records[string];
	// 全部已准备服务的单 bank Notify 排序目录；scope 只筛选，不能重新编号。
	project_config_record_t	notify_records[$];
	// MSI-X 线性查找表按 Host/PFVF/local vector 排序，global vector 只保存到内容。
	project_config_record_t	msix_linear_records[$];
	protected bit		msix_directory_ready;


	project_table_layout_t		frozen_layouts[project_table_kind_e];
	project_function_policy_t	frozen_functions[string];
	project_vio_policy_t		frozen_policies[string];
	string				frozen_reg_target;
	project_bar_mapping_cfg_t	frozen_bar_groups[$];
	project_control_cfg_t		frozen_controls[$];
	project_msix_policy_t		frozen_msix_policies[string];

	// 表项数据集中保存在 cfg，供单个配置 sequence 的 hook 查询与填写。
	// 准备仅分配本地 ring；返回各 Host 的真实视图，硬件配置由后续独立入口完成。
	extern task prepare_vio_configuration(
		output project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 全部 Host 准备完成后按驱动查找键排序，发布稳定行号；失败不发布半份目录。
	extern protected function bit materialize_notify_records(
		output string	why
	);

	// 所选全部 Host 共用核心只读 validator；所有检查结束前绝不确认/释放第一个 Host。
	extern function bit preflight_vio(
		input project_vio_selection_t	selection,
		output string			why
	);

	// 在配置 sequence 的写表、使能及所选验证成功后确认资源，随后允许业务发包。
	extern function void commit_vio_configuration(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 平台确认 DUT 已停止 DMA 后释放整 Host 的 ring；不自动停机，也不执行寄存器写入。
	extern function void release_vio_resources(
		input project_vio_selection_t	selection,
		input logic			dut_quiesced,
		output bit			ok,
		output string			why
	);


	// 控制消费者来自冻结实际 service；平台共享范围必须显式完整声明。
	extern function bit control_consumers(
		input project_control_cfg_t	item,
		output dpu_service_key_t	consumers[$],
		output string			why
	);


	// 从平台已冻结布局解析真实目标，图片相对偏移单独保留；整个操作范围先检查。
	extern function bit make_context(
		input project_table_kind_e	kind,
		input dpu_function_key_t	owner,
		input int unsigned		index,
		input longint unsigned		generation,
		output project_table_context_t	ctx,
		output string			why
	);

	// 公共类别只消费冻结 Function/消息/布局；缺失映射只阻止当前类别，不依赖 VIO ring。
	extern function bit public_records(
		input project_table_kind_e	kind,
		input project_dpu_config_scope	scope,
		output project_config_record_t	selected[$],
		output string			why
	);

	// 队列表按真实 service/qpair/IOVA 生成；任何平台策略越界都在窄字段赋值前拒绝。
	extern function bit queue_records(
		input project_vio_selection_t	selection,
		input project_table_kind_e	kinds[$],
		output project_config_record_t	selected[$],
		output string			why
	);

	// 小型类别集合查询，只统一遍历条件，不建立第二个 callback 引擎。
	extern function bit kind_selected(
		input project_table_kind_e	kind,
		input project_table_kind_e	kinds[$]
	);


	// 同批配置中共享表项必须一致；合并消费者供 typed hook 使用，避免重复写同一硬件项。
	extern function bit remember_record(
		input project_config_record_t	record,
		output string			why
	);

	// 控制 payload/mask 只来自已冻结 catalog，不把未定义位扩展成全可写。
	extern function logic [127:0] platform_control_mask(
		input project_config_record_t	record
	);


	// 只读生成状态上下文，缺失 PBA 实际容量时拒绝，不猜截图内部冲突。
	extern function bit get_state_context(
		input project_table_kind_e	kind,
		input dpu_function_key_t	owner,
		input int unsigned		index,
		output project_state_query_t	item,
		output string			why
	);

	// 组装完整冻结 PF 家族给平台纯规则；与写 hook 分离，任何访问前完成。
	extern function bit validate_pfvf_family(
		input dpu_function_key_t	owner,
		output string			why
	);
endclass


// 创建配置容器；固定 REAL_DUT，实际 Intel 接口由 bind wrapper 或平台注入。
// new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
function	project_env_cfg::new(
	string	name
);
	super.new(name);

	dpu_cfg  = dpu_device_env_config::type_id::create("dpu_cfg");
	vio_cfg  = virtio_net_env_config::type_id::create("vio_cfg");
	pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");

	vio_cfg.execution_mode = VIRTIO_EXEC_REAL_DUT;
	vio_cfg.external_configuration = 1;

	dpu_cfg.device_cfg.af_request.mode      = DPU_AF_SELECTED;
	dpu_cfg.device_cfg.af_request.requester = '{
		host_id: 0,
		pf_id:   0,
		kind:    DPU_FUNCTION_PF,
		vf_id:   0
	};
endfunction


// 构造全局 Host 模板；GPA 和 MMIO 分开，BDF 范围覆盖默认 PF/VF 规模。
// 每 Host 的 identity 和参数覆盖由 load_params 设置，不在这里解析实际地址。
function dpu_host_cfg	project_env_cfg::make_host_template();
	dpu_host_cfg		host;
	dpu_pcie_domain_cfg	domain;
	dpu_mmio_window_cfg	window;
	dpu_bdf_range_t		bdf_range;

	host = dpu_host_cfg::type_id::create("host_template");

	host.has_gpa_aperture = 1;
	host.gpa_base         = 64'h0000_1000_0000_0000;
	host.gpa_limit        = host.gpa_base + 64'h1000_0000;

	domain     = dpu_pcie_domain_cfg::type_id::create("domain_template");
	domain.key = '{
		host_id:    0,
		segment_id: 0
	};

	bdf_range = '{
		first_bdf: 16'h0010,
		last_bdf:  16'h0fff
	};

	domain.bdf_ranges.push_back(bdf_range);

	window = dpu_mmio_window_cfg::type_id::create("mmio_template");

	window.base          = 64'h0000_0020_0000_0000;
	window.limit         = window.base + 64'h0000_0001_0000_0000;
	window.allowed_roles = '{
		DPU_BAR_DEVICE_MEMORY,
		DPU_BAR_MAILBOX,
		DPU_BAR_MSIX
	};

	domain.mmio_windows.push_back(window);
	domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;

	host.pcie_domains.push_back(domain);

	return host;
endfunction


// 按 Host/PF/VF 身份创建 Function，并从 DUT caps 取得 BAR 规格。
// 全部 BAR/BDF 均由 resolver 最终放置；未知规格立即 fatal，不能制造设备能力。
function dpu_function_cfg	project_env_cfg::make_function(
	int unsigned		host_id,
	int unsigned		pf_id,
	dpu_function_kind_e	kind,
	int unsigned		vf_id
);
	dpu_function_cfg	f;
	dpu_bar_role_e		roles[3] = '{
		DPU_BAR_DEVICE_MEMORY,
		DPU_BAR_MAILBOX,
		DPU_BAR_MSIX
	};
	string	why;

	f = dpu_function_cfg::type_id::create(
		$sformatf(
			"fn_h%0d_pf%0d_%0d_vf%0d",
			host_id,
			pf_id,
			kind,
			vf_id
		)
	);

	f.key = '{
		host_id: host_id,
		pf_id:   pf_id,
		kind:    kind,
		vf_id:   vf_id
	};

	f.domain_key = '{
		host_id:    host_id,
		segment_id: 0
	};

	f.bdf_mode = DPU_ALLOC_AUTO;
	f.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);

	foreach (roles[i]) begin
		dpu_bar_profile_t	profile;
		dpu_bar_request		bar;

		if (!dpu_cfg.device_cfg.dut_caps.lookup_bar_profile(
			kind,
			roles[i],
			profile,
			why
		)) begin
			`uvm_fatal("PROJECT_CFG", why)
		end

		bar = dpu_bar_request::type_id::create($sformatf("bar_%0d", i));

		bar.role        = profile.role;
		bar.even_bar_id = profile.even_bar_id;
		bar.size        = profile.size;
		bar.alignment   = profile.alignment;
		bar.placement   = DPU_ALLOC_AUTO;

		f.bars.push_back(bar);
	end

	return f;
endfunction


// 验证 Host→TL slot 是完整的一一映射；不补缺项，避免错配后静默使用 Root0。
// 仅支持每 Host 一个 segment 0；失败返回原因，不修改输入配置或访问 DUT。
function bit	project_env_cfg::validate_tl_mapping(
	output string	why
);
	bit		used_slots[int unsigned];
	int unsigned	count;

	why   = "";
	count = dpu_cfg.device_cfg.hosts.size();

	if (
		count == 0 ||
		tl_slot_by_host.num() != count ||
		vio_cfg_by_host.num() != count
	) begin
		why = "each DPU Host needs exactly one VIO config and TL slot";
		return 0;
	end

	foreach (dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg	host;
		int unsigned	slot;

		host = dpu_cfg.device_cfg.hosts[i];

		if (host == null) begin
			why = "DPU Host config is null";
			return 0;
		end

		if (
			!tl_slot_by_host.exists(host.host_id) ||
			!vio_cfg_by_host.exists(host.host_id) ||
			vio_cfg_by_host[host.host_id] == null
		) begin
			why = $sformatf("Host%0d has no VIO config or TL slot", host.host_id);
			return 0;
		end

		slot = tl_slot_by_host[host.host_id];

		if (slot >= count || used_slots.exists(slot)) begin
			why = "TL slots must be unique and cover 0..Host_count-1";
			return 0;
		end

		if (host.pcie_domains.size() != 1) begin
			why = "Intel project requires one PCIe domain per Host";
			return 0;
		end

		if (host.pcie_domains[0] == null) begin
			why = "Host PCIe domain is null";
			return 0;
		end

		if (
			host.pcie_domains[0].key.host_id != host.host_id ||
			host.pcie_domains[0].key.segment_id != 0
		) begin
			why = "Intel project requires Host-owned segment 0";
			return 0;
		end

		used_slots[slot] = 1;
	end

	return 1;
endfunction


// 唯一参数构建入口：先采样规模/模板，再创建 Host/PF/VF/placement 和 Host 行为。
// 再调用幂等返回，不重新采样；已有输入的项目应把加载入口合入原构造点，省去生成循环。
// 默认生成器拒绝覆盖非空逻辑配置，避免重复追加 Host/PF/VF 和资源请求。
// base_test 无须逐项赋值；AIP-off 时保留默认值，但仍正常创建对象。
function void	project_env_cfg::load_params();
	dpu_dut_caps			caps;
	dpu_host_cfg			host_template;
	dpu_resource_pool_config_t	profile;

	string			why;

	if (params_loaded) begin
		return;
	end

	if (
		(dpu_cfg.device_cfg.hosts.size() != 0) ||
		(dpu_cfg.device_cfg.functions.size() != 0) ||
		(dpu_cfg.placement_cfg.vio_requests.size() != 0) ||
		(dpu_cfg.placement_cfg.profiles.size() != 0)
	) begin
		`uvm_fatal(
			"PROJECT_CFG",
			"default authoring cannot overwrite an existing DPU topology"
		)
	end

	dpu_cfg.device_cfg.load_params("dpu");
	caps = dpu_cfg.device_cfg.dut_caps;

	if (!caps.validate(why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end

`ifdef AIP_CMDLINE_SV
	`DPU_AIP_UINT("dpu", longint unsigned, hosts, this.hosts)
	`DPU_AIP_UINT("dpu", longint unsigned, pfs_per_host, this.pfs_per_host)
	`DPU_AIP_UINT("dpu", longint unsigned, vfs_per_pf, this.vfs_per_pf)

	begin
		alloc_mode_e		mem_mode;
		host_mem_alloc_policy_e	mem_policy;
		longint unsigned	mem_granule;

		`aip_enum("dpu", alloc_mode_e, mem_mode, host_mem_mode)
		`aip_enum("dpu", host_mem_alloc_policy_e, mem_policy, vio_cfg.host_mem_policy)
		`DPU_AIP_UINT("dpu", longint unsigned, mem_granule, host_mem_granule)

		if (
			(mem_granule == 0) ||
			(mem_granule > 64) ||
			((mem_granule & (mem_granule - 1)) != 0)
		) begin
			`uvm_fatal("PROJECT_CFG", "dpu.mem_granule must be a power of two in 1..64")
		end

		host_mem_mode           = mem_mode;
		host_mem_granule        = int'(mem_granule);
		vio_cfg.host_mem_policy = mem_policy;
	end
`endif

	if (
		(hosts == 0) ||
		(hosts > caps.max_hosts) ||
		(pfs_per_host == 0) ||
		(pfs_per_host > caps.max_pfs_per_host) ||
		(pfs_per_host > 4) ||
		(vfs_per_pf > caps.max_vfs_per_pf)
	) begin
		`uvm_fatal("PROJECT_CFG", "Host/PF/VF counts exceed DUT or VIO source-id capacity")
	end

	if ((hosts * pfs_per_host * (1 + vfs_per_pf)) > caps.max_functions) begin
		`uvm_fatal("PROJECT_CFG", "total Function count exceeds DUT capability")
	end

	vio_cfg.external_configuration = 1;
	vio_cfg.load_params("vio");
`ifdef AIP_CMDLINE_SV
	`aip_string("dpu", reg_target, this.reg_target)
	`aip_int("dpu", bit, print_bar_map, this.print_bar_map)
`endif

	if (vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT) begin
		`uvm_fatal("PROJECT_INTEL", "Intel reference requires REAL_DUT EP application logic")
	end

	host_template = make_host_template();
	host_template.load_params("dpu");

	profile.name             = "virtio.qpair";
	profile.class_id         = '0;
	profile.kind             = DPU_RESOURCE_KIND_QUEUE;
	profile.capacity         = caps.vio_global_qpair_count;
	profile.max_per_function = caps.max_vio_net_qpairs_per_device;

	dpu_cfg.placement_cfg.profiles.push_back(profile);

	for (int unsigned	h = 0; h < hosts; h++) begin
		dpu_host_cfg		host;
		virtio_net_env_config	host_vio;
		bit [64:0]		base;
		bit [64:0]		limit;

		host = dpu_host_cfg::type_id::create($sformatf("host_%0d", h));
		host.copy_from(host_template);

		host.host_id                     = h;
		host.pcie_domains[0].key.host_id = h;

		base  = {1'b0, host.gpa_base} + h * 65'h0000_0100_0000_0000;
		limit = {1'b0, host.gpa_limit} + h * 65'h0000_0100_0000_0000;

		if (base[64] || limit[64]) begin
			`uvm_fatal("PROJECT_CFG", "Host GPA stride overflows")
		end

		host.gpa_base  = base[63:0];
		host.gpa_limit = limit[63:0];

		base  = {1'b0, host.pcie_domains[0].mmio_windows[0].base} + h * 65'h0000_0010_0000_0000;
		limit = {1'b0, host.pcie_domains[0].mmio_windows[0].limit} + h * 65'h0000_0010_0000_0000;

		if (base[64] || limit[64]) begin
			`uvm_fatal("PROJECT_CFG", "Host MMIO stride overflows")
		end

		host.pcie_domains[0].mmio_windows[0].base  = base[63:0];
		host.pcie_domains[0].mmio_windows[0].limit = limit[63:0];

		host.load_params($sformatf("dpu.h%0d", h));
		dpu_cfg.device_cfg.hosts.push_back(host);

		host_vio = virtio_net_env_config::type_id::create($sformatf("vio_cfg_h%0d", h));
		host_vio.copy_defaults_from(vio_cfg);

		host_vio.host_id           = h;
		host_vio.host_scope_enable = 1;
		host_vio.host_scope_id     = h;

		host_vio.load_params($sformatf("vio.h%0d", h));
		host_vio.enable_service_params("vio");

		if (host_vio.execution_mode != vio_cfg.execution_mode) begin
			`uvm_fatal(
				"PROJECT_CFG",
				"one PCIe environment requires consistent VIO execution modes"
			)
		end

		vio_cfg_by_host[h] = host_vio;

		for (int unsigned	pf = 0; pf < pfs_per_host; pf++) begin
			dpu_function_cfg	f;
			string			path;

			path = $sformatf("dpu.h%0d.pf%0d", h, pf);
			f    = make_function(h, pf, DPU_FUNCTION_PF, 0);

			f.load_params(path);
			dpu_cfg.device_cfg.functions.push_back(f);

			add_service_request(f.key);

			for (int unsigned	vf = 0; vf < vfs_per_pf; vf++) begin
				f = make_function(h, pf, DPU_FUNCTION_VF, vf);
				f.load_params($sformatf("%s.vf%0d", path, vf));

				dpu_cfg.device_cfg.functions.push_back(f);
				add_service_request(f.key);
			end
		end
	end

	// 精确需求已经冻结，禁止再让 placement 参数另行扩大或平均分配 service 容量。
	dpu_cfg.vio_policy.load_params("dpu");

	if (tl_slot_by_host.num() == 0) begin
		for (int unsigned	h = 0; h < hosts; h++) begin
			tl_slot_by_host[h] = h;
		end
	end

	if (!validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end

	// Intel 的接口选择由下面的固定模式和 env 的 instance override 完成，
	// 无需额外选择宏。标量参数仍加载，但不能绕过真实 DUT 的方向与信用约束。
	pcie_cfg.if_mode          = SV_IF_MODE;
	pcie_cfg.rc_is_active     = UVM_ACTIVE;
	pcie_cfg.ep_auto_response = 0;
	pcie_cfg.use_unified_mem  = 1;
	pcie_cfg.mem_access_mode  = PCIE_TL_MEM_PER_BUFFER;

	// 真实 EP 应用逻辑由 DUT 提供；Intel adapter 即使放在 passive agent 旁也会驱动
	// 引脚，因此必须关闭 EP 组件，而不是仅将 EP 标成 UVM_PASSIVE。
	pcie_cfg.rc_agent_enable = 1;
	pcie_cfg.ep_agent_enable = 0;
	pcie_cfg.num_rc          = tl_slot_by_host.num();
	pcie_cfg.num_ep          = 0;

	// 公共 FC 不门控；每端口有限 AVST credit 由 intel_cfg 独立管理。
	pcie_cfg.infinite_credit = 1;
	pcie_cfg.load_params("pcie_cfg");

	if (pcie_cfg.ep_auto_response) begin
		`uvm_fatal("PROJECT_CFG", "real EP DUT must provide its own responses")
	end

	if (!pcie_cfg.infinite_credit) begin
		`uvm_fatal("PROJECT_INTEL", "pcie_cfg.infinite_credit must be 1; Intel owns AVST credits")
	end

	load_platform_params();
	load_function_routes();
	if (driver_layouts) begin
		use_driver_reference_layouts();
	end
	params_loaded = 1;
endfunction

// 在 DPU placement 前使用将来交给同 Host env 的同一个 cfg 缓存最终 service 需求。
function void project_env_cfg::add_service_request(
	input dpu_function_key_t	key
);
	dpu_service_key_t		service;
	vio_service_requirement_t	requirement;
	dpu_vio_placement_request	request;
	string				why;
	service.function_key = key;
	service.service_kind = DPU_SERVICE_VIO_NET;
	service.service_instance_id = 0;
	if (!vio_cfg_by_host[key.host_id].resolve_final_service_requirement(service, requirement, why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end
	if (!requirement.enabled) return;
	request = dpu_vio_placement_request::type_id::create(dpu_service_key_name(service));
	request.request_id = dpu_cfg.placement_cfg.vio_requests.size();
	request.service_instance_id = service.service_instance_id;
	request.total_qpairs = requirement.behavior.num_queue_pairs;
	request.candidate_kind = key.kind == DPU_FUNCTION_VF ? DPU_VIO_CANDIDATE_VF_ONLY : DPU_VIO_CANDIDATE_PF_ONLY;
	request.device_policy = DPU_VIO_DEVICE_FIXED;
	request.fixed_devices.push_back(key);
	dpu_cfg.placement_cfg.vio_requests.push_back(request);
endfunction

// 在原 cfg 的唯一加载点注册表目标与公共 MSI-X 模板；全局→Host→精确 Function 逐级覆盖。
function void project_env_cfg::load_platform_params();
	string			paths[$];
	string			path;
	string			name;
	string			raw;
	string			target;
	project_table_kind_e	kinds[$] = '{PROJECT_BAR,PROJECT_AF,PROJECT_PFVF,PROJECT_BDF,PROJECT_COMPLETION_BDF,PROJECT_PREFIX,
		PROJECT_MSIX_LINEAR,PROJECT_MSIX_INFO,PROJECT_MSIX_INTERVAL,PROJECT_MSIX_CONTROL,PROJECT_MSIX_TABLE,
		PROJECT_MSIX_FUNCTION,PROJECT_NOTIFY,PROJECT_Q2TC,PROJECT_N2G,PROJECT_G2P,PROJECT_SPWRR,PROJECT_TC_WEIGHT,
		PROJECT_VTX,PROJECT_VRX,PROJECT_QUEUE_AUX,PROJECT_RDMA_NOTIFY,PROJECT_RNET};
	string	labels[$] = '{"bar","af","pfvf","bdf","completion_bdf","tlp_prefix","msix_linear","msix_info",
		"msix_interval","msix_control","msix_table","msix_function","vio_notify","qsch_q2tc","qsch_n2g","qsch_g2p",
		"qsch_spwrr","qsch_tc_weight","vtx","vrx","queue_aux","rdma_notify","qsch_rnet"};
	// 无 IP 参考模式：仅使用消息表使能，默认不节流、不自屏蔽；真实消息地址/数据仍必须提供。
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		name = dpu_function_key_name(dpu_cfg.device_cfg.functions[f].key);
		if (!msix_policies.exists(name)) begin
			msix_policies[name] = '{table_only_enable:1, interval_present:1, self_mask_present:1, default:0};
		end
	end
`ifdef AIP_CMDLINE_SV
	`aip_int("dpu", bit, configure_public, this.configure_public)
	`aip_int("dpu", bit, configure_bdf, this.configure_bdf)
	`aip_int("dpu", bit, driver_layouts, this.driver_layouts)
	`aip_int("dpu", bit, verify_readback, this.verify_readback)
	begin
		longint unsigned	mode;
		longint unsigned	mode_offset;
		longint unsigned	spwrr;
		longint unsigned	tc_weight;
		bit			configure_controls;

		`DPU_AIP_UINT("dpu.qsch", longint unsigned, mode, qsch_mode)
		`DPU_AIP_UINT("dpu.qsch", longint unsigned, mode_offset, qsch_mode_offset)
		`DPU_AIP_UINT("dpu.qsch", longint unsigned, spwrr, qsch_spwrr)
		`DPU_AIP_UINT("dpu.qsch", longint unsigned, tc_weight, qsch_tc_weight)
		`aip_int("dpu.qsch", bit, configure_controls, qsch_configure_controls)

		if (mode > 1 || spwrr > 'hff || tc_weight > 32'hffffffff || mode_offset[1:0] != 0) begin
			`uvm_fatal("PROJECT_CFG", "QSCH mode/weight width or mode register alignment is invalid")
		end

		qsch_mode               = mode;
		qsch_mode_offset        = mode_offset;
		qsch_spwrr              = spwrr;
		qsch_tc_weight          = tc_weight;
		qsch_configure_controls = configure_controls;
	end

	foreach (kinds[k]) begin
		paths.delete();
		case (kinds[k])
			PROJECT_BAR: paths.push_back("dpu.bar_map");
			PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_CONTROL,
			PROJECT_MSIX_TABLE, PROJECT_MSIX_FUNCTION: paths.push_back("dpu.msix");
			PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_RNET:
				paths.push_back("dpu.qsch");
			default: ;
		endcase
		paths.push_back({"dpu.", labels[k]});
		case (kinds[k])
			PROJECT_VTX: paths.push_back("vio.vtx");
			PROJECT_VRX: paths.push_back("vio.vrx");
			PROJECT_NOTIFY: paths.push_back("vio.notify_table");
			default: ;
		endcase
		foreach (paths[i]) begin
			raw = aip_cmdline#(string)::get_cmdline_string("reg_target", paths[i]);
			if (raw != "") begin
				aip_cmdline#(string)::get_single_value("reg_target", paths[i], reg_target, target);
				table_layouts[kinds[k]].reg_target = target;
			end
		end
	end
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		project_msix_policy_t	p;
		dpu_function_key_t	owner;
		owner = dpu_cfg.device_cfg.functions[f].key;
		name = dpu_function_key_name(owner);
		if (msix_policies.exists(name)) p = msix_policies[name];
		else p = '{default:0};
		paths = '{"dpu.msix", $sformatf("dpu.h%0d.msix", owner.host_id)};
		path = $sformatf("dpu.h%0d.pf%0d", owner.host_id, owner.pf_id);
		if (owner.kind == DPU_FUNCTION_VF) path = {path, $sformatf(".vf%0d", owner.vf_id)};
		paths.push_back({path, ".msix"});
		foreach (paths[i]) begin
			longint unsigned	value;
			string			fields[$] = '{"table_bar","table_offset","table_size","pba_bar","pba_offset","pba_words",
				"msg_addr_base","msg_addr_stride","msg_data_base","msg_data_stride","interval_rate","interval_packets","self_mask","table_only_enable"};
			foreach (fields[j]) begin
				raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], paths[i]);
				if (raw == "") continue;
				if (aip_str::str_find(raw, "-") >= 0) `uvm_fatal("PROJECT_CFG", "MSI-X unsigned field is negative")
				aip_cmdline#(longint unsigned)::get_single_value(fields[j], paths[i], 0, value);
				if ((j inside {0,2,3,5,8,9}) && value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "MSI-X field exceeds32 bits")
				case (j)
					0: p.table_bar = value;
					1: begin p.table_offset = value; p.table_present = 1; end
					2: p.table_size = value;
					3: p.pba_bar = value;
					4: begin p.pba_offset = value; p.pba_present = 1; end
					5: p.pba_words = value;
					6: begin p.address_base = value; p.address_present = 1; end
					7: p.address_stride = value;
					8: begin p.data_base = value; p.data_present = 1; end
					9: p.data_stride = value;
					10: begin
						if (value > 65535) `uvm_fatal("PROJECT_CFG", "MSI-X interval rate exceeds16 bits")
						p.interval_entry.intrl_rate = value; p.interval_present = 1;
					end
					11: begin
						if (value > 65535) `uvm_fatal("PROJECT_CFG", "MSI-X interval packet threshold exceeds16 bits")
						p.interval_entry.intrl_pnum = value; p.interval_present = 1;
					end
					12: begin
						if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X self_mask must be boolean")
						p.self_mask = value; p.self_mask_present = 1;
					end
					13: begin
						if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X table_only_enable must be boolean")
						p.table_only_enable = value;
					end
					default: ;
				endcase
			end
		end
		msix_policies[name] = p;
		for (int unsigned v = 0; v < 64; v++) begin
			project_msix_message_t	m;
			bit			address_valid;
			bit			data_valid;
			bit [64:0]		address;
			bit [64:0]		data;
			m.owner = owner;
			m.local_vector = v;
			m.global_vector = 0;
			m.masked = 0;
			address = {1'b0,p.address_base} + 65'(v)*p.address_stride;
			data = 65'(p.data_base) + 65'(v)*p.data_stride;
			address_valid = p.address_present;
			data_valid = p.data_present;
			m.address = address[63:0];
			m.data = data[31:0];
			foreach (paths[i]) begin
				longint unsigned	value;
				string			vector_path;
				string			fields[$] = '{"msg_addr","msg_data","masked"};
				vector_path = {paths[i],$sformatf(".v%0d", v)};
				foreach (fields[j]) begin
					raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], vector_path);
					if (raw == "") continue;
					if (aip_str::str_find(raw, "-") >= 0) `uvm_fatal("PROJECT_CFG", "negative MSI-X vector value")
					aip_cmdline#(longint unsigned)::get_single_value(fields[j], vector_path, 0, value);
					case (j)
						0: begin m.address = value; address_valid = 1; address = value; end
						1: begin
							if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "MSI-X data exceeds32 bits")
							m.data = value; data_valid = 1; data = value;
						end
						2: begin
							if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X masked must be0/1")
							m.masked = value;
						end
					endcase
				end
			end
			if ((address_valid && address[64]) || (data_valid && data > 32'hffffffff))
				`uvm_fatal("PROJECT_CFG", "MSI-X template overflow")
			if (address_valid && data_valid) message_templates[name][v] = m;
		end
	end
	// 平台表策略沿同一全局→Host→精确 service 路径加载；资源几何仍由核心冻结合同拥有。
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		project_vio_policy_t	q;
		dpu_service_key_t	service;
		bit			provided;
		string			fields[$] = '{"vtx.dma_info","vtx.tail_buf_id_dis","vtx.redraw_en","vtx.high_speed_mode","vtx.seg_en","vtx.interl_seg_en","vrx.dsc_pre_max_num","vrx.dsc_pre_read_threshold","vrx.dsc_dma_num","vrx.dsc_mode","vrx.payload_dsc_len","vrx.head_dsc_len","qsch.net_base","qsch.net_stride","qsch.group_id","qsch.cos","qsch.eth_ports","qsch.ets","qsch.distinguish_business","qsch.ets_priority","fpga","prefetch_start","prefetch_slots","notify_net_pair5","notify_table_bar","notify_table_offset"};
		service.function_key = dpu_cfg.device_cfg.functions[f].key;
		service.service_kind = DPU_SERVICE_VIO_NET;
		service.service_instance_id = 0;
		name = dpu_service_key_name(service);
		provided = vio_policies.exists(name);
		if (provided) q = vio_policies[name];
		else q = '{service_key:service, prefetch_ram:"", default:0};
		paths = '{"dpu", "vio", $sformatf("vio.h%0d", service.function_key.host_id)};
		path = $sformatf("vio.h%0d.pf%0d", service.function_key.host_id, service.function_key.pf_id);
		if (service.function_key.kind == DPU_FUNCTION_VF) path = {path, $sformatf(".vf%0d", service.function_key.vf_id)};
		paths.push_back({path, ".i0"});
		foreach (paths[i]) begin
			raw = (paths[i] == "dpu") ? "" : aip_cmdline#(string)::get_cmdline_string("prefetch_ram", paths[i]);
			if (raw != "") begin
				aip_cmdline#(string)::get_single_value("prefetch_ram", paths[i], "", q.prefetch_ram);
				provided = 1;
			end
			foreach (fields[j]) begin
				longint unsigned	value;
				// dpu.qsch 提供全局调度策略，VIO 路径只覆盖相同字段。
				if (paths[i] == "dpu" && (j < 12 || j > 19)) continue;
				raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], paths[i]);
				if (raw == "") continue;
				if (aip_str::str_find(raw, "-") >= 0) `uvm_fatal("PROJECT_CFG", "negative platform queue policy")
				aip_cmdline#(longint unsigned)::get_single_value(fields[j], paths[i], 0, value);
				provided = 1;
				case (j)
					0: begin
						if (value > 4'hf) `uvm_fatal("PROJECT_CFG", "vtx.dma_info exceeds declared width")
						q.vtx.dma_info = value;
					end
					1: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.tail_buf_id_dis exceeds declared width")
						q.vtx.tail_buf_id_dis = value;
					end
					2: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.redraw_en exceeds declared width")
						q.vtx.redraw_en = value;
					end
					3: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.high_speed_mode exceeds declared width")
						q.vtx.high_speed_mode = value;
					end
					4: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.seg_en exceeds declared width")
						q.vtx.seg_en = value;
					end
					5: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.interl_seg_en exceeds declared width")
						q.vtx.interl_seg_en = value;
					end
					6: begin
						if (value > 3'h7) `uvm_fatal("PROJECT_CFG", "vrx.dsc_pre_max_num exceeds declared width")
						q.vrx.dsc_pre_max_num = value;
					end
					7: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.dsc_pre_read_threshold exceeds declared width")
						q.vrx.dsc_pre_read_threshold = value;
					end
					8: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.dsc_dma_num exceeds declared width")
						q.vrx.dsc_dma_num = value;
					end
					9: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.dsc_mode exceeds declared width")
						q.vrx.dsc_mode = value;
					end
					10: begin
						if (value > 3'h7) `uvm_fatal("PROJECT_CFG", "vrx.payload_dsc_len exceeds declared width")
						q.vrx.payload_dsc_len = value;
					end
					11: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.head_dsc_len exceeds declared width")
						q.vrx.head_dsc_len = value;
					end
					12: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.net_base exceeds declared width")
						q.net_base = value;
					end
					13: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.net_stride exceeds declared width")
						q.net_stride = value;
					end
					14: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.group_id exceeds declared width")
						q.group_id = value;
					end
					15: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.cos exceeds declared width")
						q.cos = value;
					end
					16: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.eth_ports exceeds declared width")
						q.eth_ports = value;
					end
					17: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "qsch.ets exceeds declared width")
						q.ets = value;
					end
					18: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "qsch.distinguish_business exceeds declared width")
						q.distinguish_business = value;
					end
					19: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.ets_priority exceeds declared width")
						q.ets_priority = value;
					end
					20: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "fpga exceeds declared width")
						q.fpga = value;
					end
					21: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "prefetch_start exceeds declared width")
						q.prefetch_start = value;
					end
					22: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "prefetch_slots exceeds declared width")
						q.prefetch_slots = value;
					end
					23: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "notify_net_pair5 exceeds declared width")
						q.notify_net_pair5 = value;
					end
					24: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "notify_table_bar exceeds declared width")
						q.notify_table_bar = value;
					end
					25: begin
						q.notify_table_offset = value;
						q.notify_table_base_provided = 1;
					end
					default: ;
				endcase
			end
		end
		if (provided) vio_policies[dpu_service_key_name(service)] = q;
	end
`endif
endfunction

// 采用驱动中已经核对的模块/表偏移；只补缺项，保留用户提供的完整布局和目标覆盖。
// 空目标由 frozen_reg_target 解析；短名字通常按 owner Host 访问，Notify/MSI-X 线性表由 Host0 管理。
function void project_env_cfg::set_driver_layout(
	input project_table_kind_e	kind,
	input logic [63:0]		module_offset,
	input logic [63:0]		table_offset,
	input int unsigned		entry_bytes,
	input int unsigned		capacity,
	input project_index_policy_e	index_policy
);
	string	target;
	string	access_target;

	if (table_layouts.exists(kind) && table_layouts[kind].provided) return;
	target = table_layouts.exists(kind) ? table_layouts[kind].reg_target : "";
	access_target = target == "" ? reg_target : target;
	table_layouts[kind] = '{
		provided:1, reg_target:target, access_uses_owner_host:(access_target.substr(0, 0) != "h"),
		module_offset:module_offset, table_offset:table_offset,
		entry_bytes:entry_bytes, capacity:capacity,
		index_policy:index_policy, required:!(kind inside {PROJECT_SPWRR, PROJECT_TC_WEIGHT}), default:0
	};

	// 多 Host 共用全局查找表；短目标默认走 Host0，显式 hH 目标保持平台选择。
	if (kind inside {PROJECT_NOTIFY, PROJECT_MSIX_LINEAR} && access_target.substr(0, 0) != "h") begin
		table_layouts[kind].access_host_provided   = 1;
		table_layouts[kind].access_host            = 0;
		table_layouts[kind].access_uses_owner_host = 0;
	end
endfunction


// 安装 VIO/QSCH、BDF 与 MSI-X 的驱动参考布局；BAR/PFVF 等其他公共表仍由平台声明。
// VTX/VRX 使用四次 DWORD 数据写和控制触发端口，不把间接表当作线性 MMIO。
function void project_env_cfg::use_driver_reference_layouts();
	set_driver_layout(PROJECT_BDF, 'h100000, 'h08000, 4, 128, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_MSIX_LINEAR, 'h080000, 'h40000, 8, 2048, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_MSIX_INFO, 'h100000, 'h50000, 4, 1024, PROJECT_INDEX_GLOBAL_VECTOR);
	set_driver_layout(PROJECT_MSIX_INTERVAL, 'h100000, 'h40000, 4, 1024, PROJECT_INDEX_GLOBAL_VECTOR);
	set_driver_layout(PROJECT_MSIX_TABLE, 'h100000, 'h20000, 16, 1024, PROJECT_INDEX_GLOBAL_VECTOR);
	set_driver_layout(PROJECT_NOTIFY, 'h080000, 'h20000, 16, 512, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_Q2TC, 'hb00000, 'h10000, 4, 2048, PROJECT_INDEX_GLOBAL_QPAIR);
	set_driver_layout(PROJECT_N2G, 'hb00000, 'h12000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_G2P, 'hb00000, 'h14000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_SPWRR, 'hb00000, 'h16000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	set_driver_layout(PROJECT_TC_WEIGHT, 'hb00000, 'h18000, 4, 1024, PROJECT_INDEX_EXPLICIT);

	if (!table_layouts.exists(PROJECT_VTX) || !table_layouts[PROJECT_VTX].provided) begin
		set_driver_layout(PROJECT_VTX, 'h880000, 'h10000, 16, 2048, PROJECT_INDEX_GLOBAL_QPAIR);
		table_layouts[PROJECT_VTX].indirect     = 1;
		table_layouts[PROJECT_VTX].data_port    = 'h134;
		table_layouts[PROJECT_VTX].control_port = 'h130;
		table_layouts[PROJECT_VTX].index_mask   = 'h7ff;
		table_layouts[PROJECT_VTX].trigger_mask = 'h2000;
	end

	if (!table_layouts.exists(PROJECT_VRX) || !table_layouts[PROJECT_VRX].provided) begin
		set_driver_layout(PROJECT_VRX, 'h900000, 'h10000, 16, 2048, PROJECT_INDEX_GLOBAL_QPAIR);
		table_layouts[PROJECT_VRX].indirect     = 1;
		table_layouts[PROJECT_VRX].data_port    = 'h204;
		table_layouts[PROJECT_VRX].control_port = 'h200;
		table_layouts[PROJECT_VRX].index_mask   = 'hffff;
		table_layouts[PROJECT_VRX].trigger_mask = 'h10000;
	end

endfunction


// 无 PCIe IP 的参考接线约定为各 Host PF0 / VF=-1 / wire requester=0 / vport=0。
// 这是 Intel sideband/DMA 软件路由，绝不表示已向 DUT 写 BDF/PFVF 表。
// 显式 policy 优先作为缺省值；CLI 可覆盖字段，其余 PF/VF 不猜 requester/Intel 身份。
function void project_env_cfg::load_function_routes();
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		dpu_function_key_t		owner;
		project_function_policy_t	policy;
		string				name;
		string				path;
		bit				provided;
		bit [3:0]			fields_present;

		owner    = dpu_cfg.device_cfg.functions[f].key;
		name     = dpu_function_key_name(owner);
		provided = function_policies.exists(name);
		if (provided) begin
			policy = function_policies[name];
		end
		else begin
			policy = '{key:owner, mode:PROJECT_HOST_EP, intel_vf:-1, default:0};
			provided = owner.kind == DPU_FUNCTION_PF && owner.pf_id == 0 && vfs_per_pf == 0;
		end

		if (!function_policies.exists(name)) policy.bdf_index = policy.vport;
		fields_present = provided ? 4'hf : 0;
		path = $sformatf("dpu.h%0d.pf%0d", owner.host_id, owner.pf_id);
		if (owner.kind == DPU_FUNCTION_VF) path = {path, $sformatf(".vf%0d", owner.vf_id)};
`ifdef AIP_CMDLINE_SV
		begin
			string	fields[$] = '{"requester", "intel_pf", "intel_vf", "vport"};

			foreach (fields[i]) begin
				string		raw;
				longint signed	value;

				raw = aip_cmdline#(longint signed)::get_cmdline_string(fields[i], path);
				if (raw == "") continue;
				aip_cmdline#(longint signed)::get_single_value(fields[i], path, 0, value);
				if ((i == 0 && (value < 0 || value > 65535)) ||
					(i == 1 && (value < 0 || value > 7)) ||
					(i == 2 && ((owner.kind == DPU_FUNCTION_PF && value != -1) ||
						(owner.kind == DPU_FUNCTION_VF && (value < 0 || value > 2047)))) ||
					(i == 3 && (value < 0 || value > 1023))) begin
					`uvm_fatal("PROJECT_CFG", {path, ".", fields[i], " is outside the Intel/VIO field range"})
				end

				case (i)
					0: policy.requester = value;
					1: policy.intel_pf  = value;
					2: policy.intel_vf  = value;
					3: policy.vport     = value;
				endcase
				fields_present[i] = 1;
			end
		end
		begin
			string		raw;
			longint unsigned	value;

			if (!function_policies.exists(name)) policy.bdf_index = policy.vport;
			raw = aip_cmdline#(longint unsigned)::get_cmdline_string("bdf_index", path);
			if (raw != "") begin
				if (aip_str::str_find(raw, "-") >= 0) `uvm_fatal("PROJECT_CFG", "bdf_index must be unsigned")
				aip_cmdline#(longint unsigned)::get_single_value("bdf_index", path, policy.bdf_index, value);
				if (value >= 128) `uvm_fatal("PROJECT_CFG", "bdf_index exceeds 128-row requester table")
				policy.bdf_index = value;
			end
		end
`endif
		if (fields_present != 0 && fields_present != 4'hf) begin
			`uvm_fatal("PROJECT_CFG", {path, " requires requester, intel_pf, intel_vf and vport together"})
		end
		if (fields_present == 4'hf) function_policies[name] = policy;
	end
endfunction


// 以实际 qpair/net_id 和最终管理 BAR 为键合并默认调度项，覆盖所有实际消费者。
// 每代从用户 catalog 重建 frozen_controls；同一地址的显式项优先，不改变其值或声明范围。
// 非 ETS/ETS 必须与全局模式一致；范围/布局失败在任何 VIO MMIO 写入前返回原因。
function bit project_env_cfg::materialize_qsch_controls(
	output string	why
);
	dpu_vio_qpair_binding_t	pairs[$];
	project_table_kind_e	kinds[$] = '{PROJECT_SPWRR, PROJECT_TC_WEIGHT};
	bit			automatic_item[int];

	frozen_controls = platform_controls;
	why = "";
	if (!qsch_configure_controls) return 1;
	if (qsch_mode > 1 || $isunknown({qsch_mode_offset, qsch_spwrr, qsch_tc_weight}) ||
		qsch_mode_offset[1:0] != 0 || qsch_spwrr > 'hff) begin
		why = "QSCH mode/weight width or mode register alignment is invalid";
		return 0;
	end

	resource_snapshot.list_vio_bindings(pairs);
	foreach (pairs[p]) begin
		project_vio_policy_t		policy;
		vio_service_requirement_t	requirement;
		logic [63:0]			net_id;
		string				name;

		name = dpu_service_key_name(pairs[p].service_key);
		if (!frozen_policies.exists(name)) begin
			why = {"queue platform policy missing: ", name};
			return 0;
		end
		policy = frozen_policies[name];
		if (!vio_cfg_by_host[pairs[p].service_key.function_key.host_id].resolve_final_service_requirement(
			pairs[p].service_key, requirement, why)) return 0;
		if (!requirement.tx_enable) continue;
		if (policy.ets != qsch_mode) begin
			why = {"QSCH mode disagrees with service ets: ", name};
			return 0;
		end
		net_id = 64'(policy.net_base) + 64'(pairs[p].virtio_pair_index) * policy.net_stride;
		if (net_id >= 1024) begin
			why = {"QSCH net_id exceeds 10 bits: ", name};
			return 0;
		end

		foreach (kinds[k]) begin
			project_control_cfg_t	item;
			int			match;

			item.owner = pairs[p].service_key.function_key;
			if (!make_context(kinds[k], item.owner, int'(net_id), 0, item.ctx, why)) return 0;
			match = -1;
			foreach (frozen_controls[c]) begin
				project_table_context_t	ctx;

				if (frozen_controls[c].ctx.kind != kinds[k]) continue;
				if (!make_context(kinds[k], frozen_controls[c].owner,
					frozen_controls[c].ctx.table_index, 0, ctx, why)) return 0;
				if (ctx.record_key == item.ctx.record_key) begin
					match = c;
					break;
				end
			end

			if (match == -1) begin
				item.consumers = '{pairs[p].service_key};
				item.consumers_complete = 1;
				item.value = kinds[k] == PROJECT_SPWRR ? 128'(qsch_spwrr) : 128'(qsch_tc_weight);
				item.writable_mask = kinds[k] == PROJECT_SPWRR ? 128'hff : 128'hffffffff;
				automatic_item[frozen_controls.size()] = 1;
				frozen_controls.push_back(item);
			end
			else if (automatic_item.exists(match)) begin
				bit	found;

				found = 0;
				foreach (frozen_controls[match].consumers[c]) begin
					if (dpu_service_key_name(frozen_controls[match].consumers[c]) == name) found = 1;
				end
				if (!found) frozen_controls[match].consumers.push_back(pairs[p].service_key);
			end
		end
	end
	return 1;
endfunction


// 公共向量来自资源快照，AF 额外资源也能在没有任何 VIO service 时产生消息项。
function bit project_env_cfg::materialize_messages(
	input dpu_resource_snapshot	resources,
	output string			why
);
	dpu_vio_qpair_binding_t		pairs[$];
	dpu_af_extra_queue_binding_t	extras[$];
	why = "resource snapshot missing";
	if (resources == null) return 0;
	resources.list_vio_bindings(pairs);
	resources.list_af_extra_queue_bindings(extras);
	foreach (pairs[i]) if (!add_message(pairs[i].service_key.function_key, pairs[i].local_msix_vector_id,
		pairs[i].global_msix_vector_id, why)) return 0;
	foreach (extras[i]) if (!add_message(extras[i].af_function_key, extras[i].local_msix_vector_id,
		extras[i].global_msix_vector_id, why)) return 0;
	why = "";
	return 1;
endfunction

// 以最终 service 完成模式选择 Function；轮询且未要求公共配置时保持空范围，不误选全部。
// MSI-X pair 必须有对应未屏蔽消息；公共模式另保留显式消息的 AF/其他 Function。
// 在 env connect 发布资源后、任何 DUT 写入前调用；缺 Host cfg/快照时明确返回依赖错误。
function bit project_env_cfg::select_msix_scope(
	output project_dpu_config_scope	scope,
	output string			why
);
	dpu_vio_qpair_binding_t	pairs[$];
	dpu_function_key_t	keys[$];
	int unsigned		bars[$];
	bit			seen[string];

	scope = null;
	why = "MSI-X selection requires published DPU resources";
	if (resource_snapshot == null || dpu_setup == null) return 0;
	resource_snapshot.list_vio_bindings(pairs);
	foreach (pairs[p]) begin
		vio_service_requirement_t	requirement;
		bit				found;
		string				name;

		if (!vio_cfg_by_host.exists(pairs[p].service_key.function_key.host_id)) begin
			why = "MSI-X selection requires the published Host VIO config";
			return 0;
		end
		if (vio_cfg_by_host[pairs[p].service_key.function_key.host_id] == null) begin
			why = "MSI-X selection Host VIO config is null";
			return 0;
		end
		if (!vio_cfg_by_host[pairs[p].service_key.function_key.host_id].resolve_final_service_requirement(
			pairs[p].service_key, requirement, why)) return 0;
		if (!requirement.enabled || requirement.completion_mode != VIRTIO_COMPLETION_MSIX) continue;
		found = 0;
		foreach (frozen_messages[m]) begin
			if (!dpu_same_function_key(frozen_messages[m].owner, pairs[p].service_key.function_key) ||
				frozen_messages[m].local_vector != pairs[p].local_msix_vector_id) continue;
			if (frozen_messages[m].global_vector != pairs[p].global_msix_vector_id ||
				frozen_messages[m].masked !== 1'b0 ||
				$isunknown({frozen_messages[m].address, frozen_messages[m].data})) begin
				why = "MSI-X queue message is masked, unknown or disagrees with allocated vector";
				return 0;
			end
			found = 1;
		end
		if (!found) begin
			why = {"MSI-X completion requires explicit message address/data: ", dpu_service_key_name(pairs[p].service_key)};
			return 0;
		end
		name = dpu_function_key_name(pairs[p].service_key.function_key);
		if (!seen.exists(name)) begin
			seen[name] = 1;
			keys.push_back(pairs[p].service_key.function_key);
		end
	end
	if (configure_public) begin
		foreach (frozen_messages[m]) begin
			string	name;

			name = dpu_function_key_name(frozen_messages[m].owner);
			if (!seen.exists(name)) begin
				seen[name] = 1;
				keys.push_back(frozen_messages[m].owner);
			end
		end
	end
	msix_linear_records.delete();
	msix_directory_ready = 1;
	why = "";
	if (keys.size() == 0) return 1;
	scope = new("msix_scope", dpu_setup, keys, bars);
	if (!scope.validate(dpu_setup, why)) return 0;
	return materialize_msix_linear_records(why, scope);
endfunction


// 驱动按 Host/PFVF 排 Function、按 local vector 排组内项；global vector 仅作为查找结果。
// 默认独立 API 首次消费完整冻结消息；默认 body 显式选择完成模式范围后生成紧凑目录。
// 所有行必须落到同一管理 bank，失败不发布半份目录，也不按局部 public scope 重新编号。
function bit project_env_cfg::materialize_msix_linear_records(
	output string	why,
	input project_dpu_config_scope	scope
);
	project_config_record_t	pending[$];
	project_function_record_t	functions[$];
	string			owner_by_key[int unsigned];
	bit			checked_family[string];

	msix_directory_ready = 0;
	msix_linear_records.delete();
	why = "";
	dpu_setup.list_functions(functions);
	foreach (frozen_messages[m]) begin
		project_function_policy_t	policy;
		project_msix_linear_entry_t	entry;
		project_config_record_t		record;
		string				name;
		int unsigned			lookup_key;

		if (scope != null && !scope.selects(frozen_messages[m].owner)) continue;
		name = dpu_function_key_name(frozen_messages[m].owner);
		if (!frozen_functions.exists(name)) begin
			why = {"MSI-X Function routing policy missing: ", name};
			return 0;
		end
		policy = frozen_functions[name];
		if (!checked_family.exists(name)) begin
			if (!validate_pfvf_family(policy.key, why)) return 0;
			checked_family[name] = 1;
		end
		if (policy.key.host_id >= 8 || policy.pfvf >= 1024 ||
			frozen_messages[m].local_vector >= 512 || frozen_messages[m].global_vector >= 8192) begin
			why = "MSI-X linear field exceeds screenshot encoding";
			return 0;
		end
		lookup_key = (policy.key.host_id << 19) | (policy.pfvf << 9) | frozen_messages[m].local_vector;
		if (owner_by_key.exists(lookup_key)) begin
			why = "duplicate MSI-X Host/PFVF/local-vector lookup key";
			return 0;
		end
		owner_by_key[lookup_key] = name;
		entry                 = '0;
		entry.global_msix_idx = frozen_messages[m].global_vector;
		entry.host_id         = policy.key.host_id;
		entry.pfvf_id         = policy.pfvf;
		entry.local_msix_idx  = frozen_messages[m].local_vector;
		record.owner          = frozen_messages[m].owner;
		record.has_queue      = 0;
		record.entry          = 128'(entry);
		record.enable_mask    = 0;
		record.enable_value   = 0;
		record.consumers.delete();
		record.dependencies.delete();
		foreach (functions[f]) begin
			if (dpu_same_function_key(functions[f].key, record.owner)) record.consumers = functions[f].services;
		end
		pending.push_back(record);
	end
	pending.sort() with (item.entry[21:0]);
	if (pending.size() > 2048) begin
		why = "MSI-X linear single-bank image exceeds 2048 rows";
		return 0;
	end
	foreach (pending[i]) begin
		if (!make_context(PROJECT_MSIX_LINEAR, pending[i].owner, i, 0, pending[i].ctx, why)) return 0;
		if (i != 0 && (
			pending[i].ctx.target.canonical_name != pending[0].ctx.target.canonical_name ||
			pending[i].ctx.layout.module_offset != pending[0].ctx.layout.module_offset ||
			pending[i].ctx.layout.table_offset != pending[0].ctx.layout.table_offset ||
			pending[i].ctx.layout.capacity != pending[0].ctx.layout.capacity
		)) begin
			why = "MSI-X linear directory requires one management window; set dpu.msix_linear.reg_target";
			return 0;
		end
	end
	msix_linear_records = pending;
	msix_directory_ready = 1;
	return 1;
endfunction


// 同一共享向量只登记一次；显式消息优先但必须与冻结向量身份一致。
function bit project_env_cfg::add_message(
	input dpu_function_key_t	owner,
	input int unsigned		local_vector,
	input int unsigned		global_vector,
	output string			why
);
	string			name;
	project_msix_message_t	m;
	name = dpu_function_key_name(owner);
	why = "";
	foreach (messages[i]) begin
		if (dpu_same_function_key(messages[i].owner, owner) && messages[i].local_vector == local_vector) begin
			if (messages[i].global_vector != global_vector) begin why = "explicit shared MSI-X vector conflicts with DPU binding"; return 0; end
			return 1;
		end
	end
	if (!message_templates.exists(name) || !message_templates[name].exists(local_vector)) return 1;
	m = message_templates[name][local_vector];
	m.global_vector = global_vector;
	messages.push_back(m);
	return 1;
endfunction

// 仅 PF0/no-VF 且 Intel/PFVF 均为参考编码时通过；其余家族保留平台真实关系校验。
function bit project_env_cfg::validate_pfvf_relationship(
	input project_pfvf_relationship_t	family,
	output string				why
);
	if (family.functions.size() == 1 && family.policies.size() == 1 &&
		family.functions[0].key.kind == DPU_FUNCTION_PF && family.functions[0].key.pf_id == 0 &&
		family.policies[0].intel_pf == 0 && family.policies[0].intel_vf == -1 &&
		family.policies[0].pfvf == 0) begin
		why = "";
		return 1;
	end
	why = "platform PFVF relationship validator is required beyond the PF0/no-VF reference";
	return 0;
endfunction


// 从平台已冻结布局解析真实目标，图片相对偏移单独保留；整个操作范围先检查。
function bit project_env_cfg::make_context(
	input project_table_kind_e	kind,
	input dpu_function_key_t	owner,
	input int unsigned		index,
	input longint unsigned		generation,
	output project_table_context_t	ctx,
	output string			why
);
	project_table_layout_t	layout;
	bit [64:0]		offset;
	bit [63:0]		address;
	bit [63:0]		expected_offset;
	string			name;
	why = {"missing platform layout: ", kind.name()};
	if (bar_registry == null) return 0;
	if (frozen_layouts.exists(kind)) layout = frozen_layouts[kind];
	else begin
		layout.provided = 0;
		layout.reg_target = "";
		layout.access_host_provided = 0;
		layout.access_host = 0;
		layout.access_uses_owner_host = 0;
		layout.module_offset = 0;
		layout.table_offset = 0;
		layout.capacity = 0;
		layout.entry_bytes = 0;
		layout.index_policy = PROJECT_INDEX_EXPLICIT;
		layout.indirect = 0;
		layout.data_port = 0;
		layout.control_port = 0;
		layout.index_mask = 0;
		layout.control_fixed = 0;
		layout.trigger_mask = 0;
		layout.index_shift = 0;
		layout.required = 0;
	end
	if (kind inside {PROJECT_MSIX_TABLE, PROJECT_MSIX_PBA} && frozen_msix_policies.exists(dpu_function_key_name(owner))) begin
		project_msix_policy_t	p;
		bit			provided;
		bit [63:0]		base;
		int unsigned		bar_id;
		p = frozen_msix_policies[dpu_function_key_name(owner)];
		if (p.table_present && p.pba_present && p.table_bar == p.pba_bar) begin
			bit [64:0]	table_end;
			bit [64:0]	pba_end;
			table_end = {1'b0, p.table_offset} + 65'(p.table_size)*16;
			pba_end = {1'b0, p.pba_offset} + 65'(p.pba_words)*8;
			if ($isunknown({p.table_offset,p.pba_offset}) || table_end[64] || pba_end[64] ||
				({1'b0,p.table_offset} < pba_end && {1'b0,p.pba_offset} < table_end)) begin
				why = "MSI-X table/PBA declarations overlap or overflow"; return 0;
			end
		end
		provided = kind == PROJECT_MSIX_TABLE ? p.table_present : p.pba_present;
		if (provided) begin
			base = kind == PROJECT_MSIX_TABLE ? p.table_offset : p.pba_offset;
			bar_id = kind == PROJECT_MSIX_TABLE ? p.table_bar : p.pba_bar;
			if (base < (kind == PROJECT_MSIX_TABLE ? 'h20000 : 'h10000) ||
				$isunknown(base) || (kind == PROJECT_MSIX_TABLE && (base[3:0] != 0 || p.table_size == 0 || p.table_size > 1024)) ||
				(kind == PROJECT_MSIX_PBA && (base[2:0] != 0 || p.pba_words == 0))) begin
				why = "explicit MSI-X/PBA layout has invalid offset/capacity"; return 0;
			end
			layout.provided = 1;
			layout.reg_target = $sformatf("h%0d.pf%0d", owner.host_id, owner.pf_id);
			if (owner.kind == DPU_FUNCTION_VF) layout.reg_target = {layout.reg_target,$sformatf(".vf%0d",owner.vf_id)};
			layout.reg_target = {layout.reg_target,$sformatf(".bar%0d",bar_id)};
			layout.table_offset = kind == PROJECT_MSIX_TABLE ? 'h20000 : 'h10000;
			layout.module_offset = base - layout.table_offset;
			layout.capacity = kind == PROJECT_MSIX_TABLE ? p.table_size : p.pba_words;
			layout.entry_bytes = kind == PROJECT_MSIX_TABLE ? 16 : 8;
			layout.index_policy = PROJECT_INDEX_LOCAL_VECTOR;
			layout.indirect = 0;
		end
	end
	if (!layout.provided) return 0;
	if ($isunknown({layout.module_offset, layout.table_offset, layout.data_port, layout.control_port,
		layout.index_mask, layout.control_fixed, layout.trigger_mask}) ||
		!(layout.entry_bytes inside {4,8,12,16}) || index >= layout.capacity) begin
		why = "layout/index has unknown values or unsupported capacity/width";
		return 0;
	end
	if ((kind inside {PROJECT_VTX,PROJECT_VRX,PROJECT_NOTIFY,PROJECT_MSIX_TABLE} && layout.entry_bytes != 16) ||
		(kind inside {PROJECT_PREFIX,PROJECT_MSIX_LINEAR,PROJECT_RDMA_NOTIFY,PROJECT_MSIX_PBA} && layout.entry_bytes != 8) ||
		(kind inside {PROJECT_BDF,PROJECT_PFVF,PROJECT_COMPLETION_BDF,PROJECT_MSIX_INFO,PROJECT_MSIX_INTERVAL,
			PROJECT_Q2TC,PROJECT_N2G,PROJECT_G2P,PROJECT_RNET,PROJECT_MSIX_STAT,PROJECT_PFVF_DROP} && layout.entry_bytes != 4)) begin
		why = "declared table width contradicts screenshot"; return 0;
	end
	case (kind)
		PROJECT_BDF, PROJECT_PFVF: expected_offset = 'h8000;
		PROJECT_COMPLETION_BDF, PROJECT_PREFIX: expected_offset = 'h18000;
		PROJECT_MSIX_LINEAR, PROJECT_MSIX_INTERVAL: expected_offset = 'h40000;
		PROJECT_MSIX_INFO: expected_offset = 'h50000;
		PROJECT_MSIX_TABLE, PROJECT_NOTIFY: expected_offset = 'h20000;
		PROJECT_Q2TC, PROJECT_VTX, PROJECT_VRX: expected_offset = 'h10000;
		PROJECT_N2G: expected_offset = 'h12000;
		PROJECT_G2P: expected_offset = 'h14000;
		PROJECT_RNET: expected_offset = 'h15000;
		PROJECT_RDMA_NOTIFY: expected_offset = 'hc000;
		PROJECT_MSIX_PBA: expected_offset = 'h10000;
		PROJECT_MSIX_STAT: expected_offset = 'h48000;
		PROJECT_PFVF_DROP: expected_offset = 'ha000;
		default: expected_offset = layout.table_offset;
	endcase
	if (layout.table_offset != expected_offset ||
		(kind inside {PROJECT_VTX, PROJECT_VRX} && !layout.indirect)) begin
		why = "layout contradicts screenshot offset or required indirect access";
		return 0;
	end
	name = layout.reg_target == "" ? frozen_reg_target : layout.reg_target;
	if (!bar_registry.resolve_name(name, ctx.target, why,
		layout.access_host_provided || layout.access_uses_owner_host,
		layout.access_host_provided ? layout.access_host : owner.host_id)) return 0;
	if (kind inside {PROJECT_MSIX_TABLE, PROJECT_MSIX_PBA}) begin
		bit [64:0]	span_offset;
		span_offset = {1'b0, layout.module_offset} + {1'b0, layout.table_offset};
		if (span_offset[64] || !bar_registry.check_range(ctx.target, span_offset[63:0],
			64'(layout.capacity) * layout.entry_bytes, address, why)) return 0;
	end
	offset = {1'b0, layout.module_offset} + {1'b0, layout.table_offset} + 65'(index) * layout.entry_bytes;
	if (offset[64] || !bar_registry.check_range(ctx.target, offset[63:0], layout.entry_bytes, address, why)) return 0;
	if (layout.indirect) begin
		bit [64:0]	data_offset;
		bit [64:0]	control_offset;
		data_offset = {1'b0, layout.module_offset} + {1'b0, layout.data_port};
		control_offset = {1'b0, layout.module_offset} + {1'b0, layout.control_port};
		if (data_offset[64] || control_offset[64] || layout.index_shift >= 32 ||
			((64'(index) << layout.index_shift) & ~64'(layout.index_mask)) != 0 ||
			(layout.index_mask & (layout.control_fixed | layout.trigger_mask)) != 0 ||
			layout.trigger_mask == 0 || (layout.control_fixed & layout.trigger_mask) != 0 ||
			!bar_registry.check_range(ctx.target, data_offset[63:0], layout.entry_bytes, address, why) ||
			!bar_registry.check_range(ctx.target, control_offset[63:0], 4, address, why) ||
			data_offset[1:0] != 0 || control_offset[1:0] != 0 ||
			data_offset[11:0] + layout.entry_bytes > 4096) begin
			why = "indirect ports/index do not fit declared BAR operation";
			return 0;
		end
	end
	ctx.snapshot = device_snapshot;
	ctx.snapshot_id = dpu_setup.get_generation();
	ctx.config_generation = generation;
	ctx.layout_id = "image-2026-11-07";
	ctx.kind = kind;
	ctx.layout = layout;
	ctx.table_index = index;
	ctx.byte_offset = offset[63:0];
	ctx.record_key = $sformatf("%0d:%s:%016h", kind, ctx.target.canonical_name, ctx.byte_offset);
	why = "";
	return 1;
endfunction


// 同批配置中共享表项必须一致；合并消费者供 typed hook 使用，避免重复写同一硬件项。
function bit project_env_cfg::remember_record(
	input project_config_record_t	record,
	output string			why
);
	string	key;
	key = record.ctx.record_key;
	why = "";
	if (records.exists(key)) begin
		if (records[key].ctx !== record.ctx || records[key].entry !== record.entry ||
			records[key].enable_mask !== record.enable_mask || records[key].enable_value !== record.enable_value) begin
			why = {"conflicting table input: ", key};
			return 0;
		end
		foreach (record.consumers[i]) begin
			bit	found;
			found = 0;
			foreach (records[key].consumers[j])
				if (dpu_service_key_name(record.consumers[i]) == dpu_service_key_name(records[key].consumers[j])) found = 1;
			if (!found) records[key].consumers.push_back(record.consumers[i]);
		end
		return 1;
	end
	records[key] = record;
	return 1;
endfunction


// MSI-X/RNET/RDMA 的 Function 范围由实际 owner service 派生；AF/共享调度范围不能猜测。
// 显式消费者逐一核对冻结拓扑并去重，表项生成和用户 hook 共用这一份关系。
function bit project_env_cfg::control_consumers(
	input project_control_cfg_t	item,
	output dpu_service_key_t	consumers[$],
	output string			why
);
	project_function_record_t	functions[$];
	bit				seen[string];
	bit				owner_found;
	consumers.delete();
	dpu_setup.list_functions(functions);
	if ((item.ctx.kind inside {PROJECT_AF, PROJECT_SPWRR, PROJECT_TC_WEIGHT} || item.consumers.size() != 0) &&
		!item.consumers_complete) begin
		why = "platform control requires complete explicit consumer scope"; return 0;
	end
	foreach (functions[f]) begin
		if (!dpu_same_function_key(functions[f].key, item.owner)) continue;
		owner_found = 1;
		if (!(item.ctx.kind inside {PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION, PROJECT_RNET, PROJECT_RDMA_NOTIFY})) continue;
		foreach (functions[f].services[v]) begin
			consumers.push_back(functions[f].services[v]);
			seen[dpu_service_key_name(functions[f].services[v])] = 1;
		end
	end
	if (!owner_found) begin why = "control owner absent from frozen topology"; return 0; end
	foreach (item.consumers[c]) begin
		bit	found;
		string	name;
		name = dpu_service_key_name(item.consumers[c]);
		found = 0;
		foreach (functions[f]) foreach (functions[f].services[v])
			if (dpu_service_key_name(functions[f].services[v]) == name) found = 1;
		if (!found) begin why = "control consumer absent from frozen topology"; return 0; end
		if (!seen.exists(name)) begin consumers.push_back(item.consumers[c]); seen[name] = 1; end
	end
	return 1;
endfunction


// 控制 payload/mask 只来自已冻结 catalog，不把未定义位扩展成全可写。
function logic [127:0] project_env_cfg::platform_control_mask(
	input project_config_record_t	record
);
	foreach (frozen_controls[c])
		if (frozen_controls[c].ctx.kind == record.ctx.kind && frozen_controls[c].ctx.table_index == record.ctx.table_index &&
			dpu_same_function_key(frozen_controls[c].owner, record.owner)) return frozen_controls[c].writable_mask;
	return 0;
endfunction


// 公共类别只消费冻结 Function/消息/布局；缺失映射只阻止当前类别，不依赖 VIO ring。
function bit project_env_cfg::public_records(
	input project_table_kind_e	kind,
	input project_dpu_config_scope	scope,
	output project_config_record_t	selected[$],
	output string			why
);
	project_function_record_t	functions[$];
	project_function_policy_t	p;
	project_config_record_t		r;
	int unsigned			index;
	selected.delete();
	if (scope == null) return 0;
	if (!scope.validate(dpu_setup, why)) return 0;
	dpu_setup.list_functions(functions);
	if (kind == PROJECT_MSIX_LINEAR) begin
		if (!msix_directory_ready && !materialize_msix_linear_records(why)) return 0;
		foreach (msix_linear_records[i]) begin
			if (scope.selects(msix_linear_records[i].owner)) selected.push_back(msix_linear_records[i]);
		end
		return 1;
	end
	if (kind == PROJECT_BAR) begin
		if (frozen_bar_groups.size() == 0) begin why = "BAR mapping atomic groups must be explicitly declared"; return 0; end
		foreach (frozen_bar_groups[g]) begin
			bit	any_selected;
			bit	all_selected;
			any_selected = 0;
			all_selected = 1;
			if (frozen_bar_groups[g].members.size() == 0) begin why = "empty BAR mapping group"; return 0; end
			foreach (frozen_bar_groups[g].members[m]) begin
				project_bar_target_t	target;
				bit			chosen;
				target = frozen_bar_groups[g].members[m];
				chosen = scope.selects(target.function_key) && scope.selects_bar(target.bar_lease.even_bar_id);
				any_selected |= chosen;
				all_selected &= chosen;
				begin
					bit [63:0]	address;
					if (!bar_registry.check_range(target, 0, target.bar_lease.size, address, why)) return 0;
				end
			end
			if (!any_selected) continue;
			if (!all_selected) begin why = "BAR scope splits a declared atomic group"; return 0; end
			r.ctx = frozen_bar_groups[g].ctx;
			r.ctx.snapshot = device_snapshot;
			r.ctx.snapshot_id = dpu_setup.get_generation();
			r.ctx.config_generation = 0;
			r.ctx.kind = PROJECT_BAR;
			r.ctx.table_index = g;
			r.ctx.record_key = $sformatf("BAR:%0d", g);
			r.owner = frozen_bar_groups[g].members[0].function_key;
			r.has_queue = 0;
			r.entry = '0;
			r.enable_mask = '0;
			r.enable_value = '0;
			r.consumers.delete();
			foreach (functions[f]) foreach (frozen_bar_groups[g].members[m]) begin
				if (!dpu_same_function_key(functions[f].key, frozen_bar_groups[g].members[m].function_key)) continue;
				foreach (functions[f].services[v]) r.consumers.push_back(functions[f].services[v]);
			end
			r.dependencies.delete();
			selected.push_back(r);
		end
		// 全部选中租约必须有且只有一个声明组，不能默默遗漏未编码的 BAR。
		foreach (functions[f]) begin
			if (!scope.selects(functions[f].key)) continue;
			foreach (functions[f].bars[b]) begin
				int unsigned	count;
				if (!scope.selects_bar(functions[f].bars[b].even_bar_id)) continue;
				count = 0;
				foreach (selected[s]) foreach (frozen_bar_groups[selected[s].ctx.table_index].members[m]) begin
					project_bar_target_t	t;
					t = frozen_bar_groups[selected[s].ctx.table_index].members[m];
					if (dpu_same_function_key(t.function_key, functions[f].key) && t.bar_lease.even_bar_id == functions[f].bars[b].even_bar_id) count++;
				end
				if (count != 1) begin why = "selected BAR has missing/duplicate mapping group membership"; return 0; end
			end
		end
		return 1;
	end
	// 图中没有定义的控制项仅按平台显式 catalog 遍历，不补默认寄存器或 payload。
	if (kind inside {PROJECT_AF, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION, PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX, PROJECT_RDMA_NOTIFY, PROJECT_RNET}) begin
		foreach (frozen_controls[i]) begin
			if (frozen_controls[i].ctx.kind != kind || !scope.selects(frozen_controls[i].owner)) continue;
			r.ctx = frozen_controls[i].ctx;
			if (!make_context(kind, frozen_controls[i].owner, r.ctx.table_index, 0, r.ctx, why)) return 0;
			r.owner = frozen_controls[i].owner;
			if (!control_consumers(frozen_controls[i], r.consumers, why)) return 0;
			r.entry = frozen_controls[i].value;
			r.enable_mask = '0;
			r.enable_value = '0;
			r.has_queue = 0;
			if ($isunknown({r.entry, frozen_controls[i].writable_mask}) || (r.entry & ~frozen_controls[i].writable_mask) != 0) begin
				why = "platform control contains unknown/reserved bits"; return 0;
			end
			if (kind == PROJECT_RNET) begin
				project_qsch_rnet_entry_t	e;
				e = project_qsch_rnet_entry_t'(r.entry);
				if (r.entry[127:32] != 0 || e.reserved_31_4 != 0 || e.host_id != r.owner.host_id || r.ctx.table_index >= 256) begin
					why = "RNET reserved/Host/index encoding invalid"; return 0;
				end
			end
			if (kind == PROJECT_RDMA_NOTIFY) begin
				project_rdma_notify_entry_t	e;
				e = project_rdma_notify_entry_t'(r.entry);
				if (r.entry[127:64] != 0 || e.reserved_63_59 != 0 || e.host_id != r.owner.host_id ||
					r.owner.kind != DPU_FUNCTION_VF || r.ctx.table_index >= 256) begin
					why = "RDMA notify reserved/Host/VF/index encoding invalid"; return 0;
				end
			end
			selected.push_back(r);
		end
		if (kind inside {PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION}) begin
			foreach (frozen_messages[m]) begin
				bit	covered;
				string	owner_name;
				if (!scope.selects(frozen_messages[m].owner)) continue;
				owner_name = dpu_function_key_name(frozen_messages[m].owner);
				covered = frozen_msix_policies.exists(owner_name) && frozen_msix_policies[owner_name].table_only_enable;
				foreach (selected[c]) if (dpu_same_function_key(selected[c].owner, frozen_messages[m].owner)) covered = 1;
				if (!covered) begin why = "MSI-X requires explicit control or table-only enable declaration"; return 0; end
			end
		end
		if (selected.size() == 0 && (kind == PROJECT_AF ||
			(frozen_layouts.exists(kind) && frozen_layouts[kind].required))) begin
			why = {"required platform control catalog is empty: ", kind.name()}; return 0;
		end
		return 1;
	end
	foreach (functions[f]) begin
		string	name;
		if (!scope.selects(functions[f].key)) continue;
		name = dpu_function_key_name(functions[f].key);
		if (!frozen_functions.exists(name)) begin why = {"platform Function mapping missing: ", name}; return 0; end
		p = frozen_functions[name];
		if (kind == PROJECT_PFVF && !validate_pfvf_family(p.key, why)) return 0;
		r.owner = functions[f].key;
		r.consumers = functions[f].services;
		r.has_queue = 0;
		r.entry = '0;
		r.enable_mask = '0;
		r.enable_value = '0;
		r.dependencies.delete();
		if (kind inside {PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_TABLE}) begin
			foreach (frozen_messages[m]) begin
				project_msix_message_t	message;
				message = frozen_messages[m];
				if (!dpu_same_function_key(message.owner, r.owner)) continue;
				if (kind == PROJECT_MSIX_TABLE && frozen_msix_policies.exists(name) && frozen_msix_policies[name].table_present)
					index = message.local_vector;
				else begin
				if (!frozen_layouts.exists(kind) ||
					!(frozen_layouts[kind].index_policy inside {PROJECT_INDEX_GLOBAL_VECTOR, PROJECT_INDEX_LOCAL_VECTOR})) begin
					why = "MSI-X table requires explicit local/global vector index policy"; return 0;
				end
				index = frozen_layouts[kind].index_policy == PROJECT_INDEX_GLOBAL_VECTOR ? message.global_vector : message.local_vector;
				end
				if (index >= 1024 ||
					(kind == PROJECT_MSIX_INFO && p.vport >= 128)) begin
					why = "MSI-X mapping exceeds screenshot capacity/reserved fields"; return 0;
				end
				case (kind)
					PROJECT_MSIX_INFO: begin
						project_msix_info_entry_t	e;
						e = '0;
						if (!frozen_msix_policies.exists(name) || !frozen_msix_policies[name].self_mask_present ||
							$isunknown(frozen_msix_policies[name].self_mask)) begin
							why = "MSI-X info requires explicit self-mask policy"; return 0;
						end
						e.self_mask = frozen_msix_policies[name].self_mask;
						e.valid = 1;
						e.host_id = p.key.host_id;
						e.function_id = p.vport;
						r.entry = 128'(e);
					end
					PROJECT_MSIX_INTERVAL: begin
							if (!frozen_msix_policies.exists(name) || !frozen_msix_policies[name].interval_present ||
								$isunknown(frozen_msix_policies[name].interval_entry)) begin
								why = "MSI-X interval requires explicit rate/packet policy"; return 0;
							end
							r.entry = 128'(frozen_msix_policies[name].interval_entry);
						end
					PROJECT_MSIX_TABLE: begin
						project_msix_table_entry_t	e;
						e = '0;
						e.msix_addr = message.address;
						e.msix_data = message.data;
						e.msix_mask = message.masked;
						r.entry = 128'(e);
					end
					default: ;
				endcase
				if (!make_context(kind, r.owner, index, 0, r.ctx, why)) return 0;
				selected.push_back(r);
			end
			continue;
		end
		case (kind)
			PROJECT_BDF: begin
				project_bdf_entry_t		e;
				project_ep_requester_id_t	ep;
				if (p.bdf_index >= 128 || $isunknown(p.requester)) begin why = "requester table index/encoding invalid"; return 0; end
				ep = project_ep_requester_id_t'(p.requester);
				if ((p.mode == PROJECT_HOST_SW && p.requester != functions[f].pcie_id.bdf) ||
					(p.mode == PROJECT_HOST_EP && ep.vf_valid != (p.key.kind == DPU_FUNCTION_VF))) begin why = "requester EP/SW encoding contradicts explicit route"; return 0; end
				e = '0;
				e.requester_id = p.requester;
				e.valid = 1;
				e.ecrc_en = p.ecrc;
				e.vdpa_en = p.vdpa;
				r.entry = 128'(e);
				index = p.bdf_index;
			end
			PROJECT_COMPLETION_BDF: begin
				project_completion_bdf_entry_t	e;
				if (p.mode == PROJECT_HOST_EP) continue;
				if (p.completion_index >= 4096) begin why = "Completion table index exceeds screenshot"; return 0; end
				e = '0;
				e.valid = 1;
				e.ecrc_en = p.ecrc;
				e.completion_id = functions[f].pcie_id.bdf;
				r.entry = 128'(e);
				index = p.completion_index;
			end
			PROJECT_PFVF: begin
				project_pfvf_entry_t	e;
				if (p.key.kind != DPU_FUNCTION_PF) continue;
				// PFVF 是整族依赖；按冻结身份收集实际 VF，不推断连续编号。
				r.consumers.delete();
				foreach (functions[member]) begin
					if (functions[member].key.host_id != p.key.host_id || functions[member].key.pf_id != p.key.pf_id) continue;
					foreach (functions[member].services[service]) r.consumers.push_back(functions[member].services[service]);
				end
				if (p.intel_pf >= 4 || p.first_vf_offset >= 1024) begin why = "PFVF mapping exceeds screenshot fields"; return 0; end
				e = '0;
				e.valid = 1;
				e.first_vf_offset = p.first_vf_offset;
				r.entry = 128'(e);
				index = p.intel_pf;
			end
			PROJECT_PREFIX: begin
				project_tlp_prefix_entry_t	e;
				if (!p.prefix_enabled) continue;
				if (p.prefix_index >= 256 || $isunknown(p.prefix)) begin why = "prefix invalid"; return 0; end
				e = '0;
				e.valid = 1;
				e.vdpa_en = p.vdpa;
				e.tlp_prefix = p.prefix;
				r.entry = 128'(e);
				index = p.prefix_index;
			end
			default: begin why = "category is not a public table"; return 0; end
		endcase
		if (!make_context(kind, r.owner, index, 0, r.ctx, why)) return 0;
		selected.push_back(r);
	end
	why = "";
	return 1;
endfunction


// 本地准备不发送 TLP；由单个配置 sequence 在写 VIO 表之前调用。
// 所有 Host 的绑定先解析，真实 ring 仅由核心 env 分配；准备失败保留已交付 Host 的视图。
task project_env_cfg::prepare_vio_configuration(
	output project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	dpu_vio_qpair_binding_t		pairs[$];
	vio_external_queue_binding_t	bindings[int unsigned][$];
	vio_service_requirement_t	requirement;
	dpu_service_key_t		keys[$];
	ok = 0;
	selection.setups.delete();
	selection.scopes.delete();
	why = "public configuration must be published first";
	if (dpu_setup == null) return;
	foreach (vio_setups[h]) if (vio_setups[h] != null) begin why = "release existing VIO generation before reprepare"; return; end
	notify_records.delete();
	// 全部旧 ring 代释放后才冻结显式平台表策略；核心 service enabled/pairs/geometry/format 仍用 placement 前缓存合同。
	frozen_policies = this.vio_policies;
	if (!materialize_qsch_controls(why)) return;
	resource_snapshot.list_vio_bindings(pairs);
	foreach (pairs[p]) begin
		int unsigned	h;
		h = pairs[p].service_key.function_key.host_id;
		if (!vio_envs.exists(h) || !this.vio_cfg_by_host.exists(h)) return;
		if (vio_envs[h] == null || this.vio_cfg_by_host[h] == null) return;
		if (!this.vio_cfg_by_host[h].resolve_final_service_requirement(pairs[p].service_key, requirement, why)) return;
		for (int direction = 0; direction < 2; direction++) begin
			vio_external_queue_binding_t	b;
			bit [64:0]			offset;
			bit				message_found;
			dpu_priv_driver_config		private_cfg;
			dpu_priv_queue_config		private_queue;
			if ((direction == 0 && !requirement.rx_enable) || (direction == 1 && !requirement.tx_enable)) continue;
			b.service_key = pairs[p].service_key;
			b.local_qid = direction == 0 ? pairs[p].rx_local_virtqueue_id : pairs[p].tx_local_virtqueue_id;
			private_cfg = this.vio_cfg_by_host[h].get_dpu_private_config(b.service_key);
			private_queue = null;
			if (requirement.behavior.vq_type == VQ_CUSTOM && private_cfg != null)
				private_queue = private_cfg.resolve_queue(b.local_qid);
			if (!requirement.notify_layout_valid && (private_queue == null || !private_queue.notify_offset_present)) begin
				why = "service/queue has no explicit doorbell binding"; return;
			end
			offset = {1'b0, requirement.notify_base} + 65'(b.local_qid) * {1'b0, requirement.notify_stride};
			if (offset[64]) begin why = "doorbell offset overflow"; return; end
			b.notify_bar = requirement.notify_bar;
			b.notify_offset = offset[63:0];
			if (private_queue != null) begin
				if (private_queue.notify_bar_present) b.notify_bar = private_queue.notify_bar;
				if (private_queue.notify_offset_present) b.notify_offset = private_queue.notify_offset;
			end
			b.notify_encoding = requirement.notify_encoding;
			b.local_vector = pairs[p].local_msix_vector_id;
			b.global_vector = pairs[p].global_msix_vector_id;
			b.msix_valid = 0;
			b.message_address = 0;
			b.message_data = 0;
			b.masked = 0;
			message_found = 0;
			foreach (frozen_messages[m]) begin
				if (dpu_same_function_key(frozen_messages[m].owner, b.service_key.function_key) &&
					frozen_messages[m].local_vector == b.local_vector) begin
					if (frozen_messages[m].global_vector != b.global_vector) begin why = "public vector disagrees with qpair binding"; return; end
					message_found = 1;
					b.msix_valid = 1;
					b.message_address = frozen_messages[m].address;
					b.message_data = frozen_messages[m].data;
					b.masked = frozen_messages[m].masked;
				end
			end
			if (requirement.completion_mode == VIRTIO_COMPLETION_MSIX && !message_found) begin why = "MSI-X service has no frozen public message"; return; end
			bindings[h].push_back(b);
		end
	end
	foreach (bindings[h]) begin
		vio_config_scope	scope;
		vio_external_setup	setup;
		vio_envs[h].prepare_external_configuration(bindings[h], setup, ok, why);
		if (!ok) return;
		vio_setups[h] = setup;
		keys.delete();
		scope = new($sformatf("vio_scope_h%0d", h), setup, keys);
		selection.setups[h] = setup;
		selection.scopes[h] = scope;
	end
	if (!materialize_notify_records(why)) begin
		ok = 0;
		return;
	end
	ok = 1;
	why = "";
endtask


// 驱动先按 Host/BAR 查找基址排序 Function，再在组内按 pair 编号排列；硬件行号是排序位置。
// 从完整已准备目录生成一次，RX/TX 共用 pair 项；global_qid 只写入 payload，不作为表行号。
// 同 Host 同基址属于不同 service 时存在查找歧义，拒绝发布；失败保持目录为空。
function bit project_env_cfg::materialize_notify_records(
	output string	why
);
	project_config_record_t	pending[$];
	vio_queue_setup_t	queues[$];
	string			service_by_base[bit [63:0]];
	int			pair_rows[string];

	notify_records.delete();
	why = "";
	foreach (vio_setups[h]) begin
		if (vio_setups[h] == null) continue;
		vio_setups[h].list_queues(queues);
		foreach (queues[q]) begin
			project_vio_policy_t		policy;
			project_vio_notify_entry_t	entry;
			project_bar_target_t		target;
			project_config_record_t		record;
			bit [63:0]			base;
			bit [63:0]			lookup_key;
			string				service;
			string				pair_name;

			service = dpu_service_key_name(queues[q].service_key);
			if (!frozen_policies.exists(service)) begin
				why = {"queue platform policy missing: ", service};
				return 0;
			end
			policy = frozen_policies[service];
			if (!policy.notify_table_base_provided || $isunknown(policy.notify_table_offset) ||
				!bar_registry.resolve_function(queues[q].service_key.function_key,
					policy.notify_table_bar, target, why) ||
				!bar_registry.check_range(target, policy.notify_table_offset, 128, base, why)) begin
				why = "notify table lookup base requires explicit owner BAR/offset";
				return 0;
			end
			if (!policy.notify_net_pair5 || queues[q].qpair.virtio_pair_index >= 32 ||
				queues[q].qpair.rx_local_virtqueue_id >= 64 || queues[q].qpair.tx_local_virtqueue_id >= 64 ||
				queues[q].qpair.global_qpair_id >= 2048 || h >= 8 ||
				base[63:61] != 0 || base[6:0] != 0) begin
				why = "notify single-bank pair5/base/index cannot represent binding";
				return 0;
			end

			lookup_key = (64'(h) << 61) | base;
			if (service_by_base.exists(lookup_key) && service_by_base[lookup_key] != service) begin
				why = "different VIO services share the same Notify Host/BAR lookup base";
				return 0;
			end
			service_by_base[lookup_key] = service;
			entry                    = '0;
			entry.global_qid         = queues[q].qpair.global_qpair_id;
			entry.host_id            = h;
			entry.base_addr_60_7     = base[60:7];
			entry.local_qid_encoding = (queues[q].qpair.virtio_pair_index << 1) | 1;
			pair_name = $sformatf("%s.pair%0d", service, queues[q].qpair.virtio_pair_index);
			if (pair_rows.exists(pair_name)) begin
				if (pending[pair_rows[pair_name]].entry != 128'(entry)) begin
					why = "RX/TX of one qpair disagree on the Notify mapping";
					return 0;
				end
				continue;
			end

			record.owner        = queues[q].service_key.function_key;
			record.consumers    = '{queues[q].service_key};
			record.has_queue    = 1;
			record.binding      = queues[q];
			record.entry        = entry;
			record.enable_mask  = 0;
			record.enable_value = 0;
			record.dependencies.delete();
			pair_rows[pair_name] = pending.size();
			pending.push_back(record);
		end
	end

	// 低 64 位恰好为 {host_id, base_addr_60_7, local_qid_encoding}，不含 global_qid。
	pending.sort() with (item.entry[63:0]);
	if (pending.size() > 512) begin
		why = "Notify single-bank image exceeds 512 rows";
		return 0;
	end
	foreach (pending[i]) begin
		if (!make_context(PROJECT_NOTIFY, pending[i].owner, i,
			vio_setups[pending[i].owner.host_id].get_generation(), pending[i].ctx, why)) return 0;

		// 全局行号必须落到同一 bank；按 owner 分散窗口会留下未初始化的中间行。
		if (i != 0 && (
			pending[i].ctx.target.canonical_name != pending[0].ctx.target.canonical_name ||
			pending[i].ctx.layout.module_offset != pending[0].ctx.layout.module_offset ||
			pending[i].ctx.layout.table_offset != pending[0].ctx.layout.table_offset ||
			pending[i].ctx.layout.capacity != pending[0].ctx.layout.capacity
		)) begin
			why = "Notify single-bank directory requires one management window; set vio.notify_table.reg_target to a complete hH.pfP.barB target";
			return 0;
		end
	end
	notify_records = pending;
	return 1;
endfunction


// 所选全部 Host 共用核心只读 validator；所有检查结束前绝不确认/释放第一个 Host。
function bit project_env_cfg::preflight_vio(
	input project_vio_selection_t	selection,
	output string			why
);
	why = "VIO selection is empty or has incomplete Host setup/scope pairs";
	if (selection.setups.num() == 0 || selection.scopes.num() != selection.setups.num()) return 0;
	foreach (selection.setups[h]) begin
		if (!vio_envs.exists(h) || !vio_setups.exists(h) || !selection.scopes.exists(h)) return 0;
		if (vio_envs[h] == null || selection.setups[h] == null ||
			selection.setups[h] != vio_setups[h] || selection.scopes[h] == null) return 0;
		if (!vio_envs[h].preflight_external_configuration(selection.setups[h], selection.scopes[h], why)) return 0;
	end
	why = "";
	return 1;
endfunction


// 队列表按真实 service/qpair/IOVA 生成；任何平台策略越界都在窄字段赋值前拒绝。
function bit project_env_cfg::queue_records(
	input project_vio_selection_t	selection,
	input project_table_kind_e	kinds[$],
	output project_config_record_t	selected[$],
	output string			why
);
	vio_queue_setup_t		queues[$];
	project_vio_policy_t		policy;
	project_function_policy_t	fp;
	project_config_record_t		r;
	int unsigned			depth;
	int unsigned			pre_count;
	int unsigned			pre_start;
	int unsigned			net_id;
	int unsigned			index;
	string				service;
	selected.delete();
	if (!preflight_vio(selection, why)) return 0;
	if (kind_selected(PROJECT_NOTIFY, kinds)) begin
		foreach (notify_records[i]) begin
			int unsigned	host_id;

			host_id = notify_records[i].owner.host_id;
			if (selection.scopes.exists(host_id) &&
				selection.scopes[host_id].selects(notify_records[i].binding.service_key)) begin
				selected.push_back(notify_records[i]);
			end
		end
		if (kinds.size() == 1) begin
			why = "";
			return 1;
		end
	end
	foreach (selection.setups[h]) begin
		selection.setups[h].list_queues(queues);
		foreach (queues[q]) begin
			if (!selection.scopes[h].selects(queues[q].service_key)) continue;
			service = dpu_service_key_name(queues[q].service_key);
			if (!frozen_policies.exists(service) || !frozen_functions.exists(dpu_function_key_name(queues[q].service_key.function_key))) begin
				why = {"queue platform policy missing: ", service}; return 0;
			end
			policy = frozen_policies[service];
			fp = frozen_functions[dpu_function_key_name(queues[q].service_key.function_key)];
			if (queues[q].queue_size < 32 || queues[q].queue_size > 32768 ||
				(queues[q].queue_type == VQ_CUSTOM && queues[q].queue_size > 4096) ||
				(queues[q].queue_size & (queues[q].queue_size-1)) != 0 || fp.vport >= 1024 ||
				queues[q].qpair.global_msix_vector_id >= 8192 || queues[q].qpair.global_qpair_id >= (policy.fpga ? 512 : 2048)) begin
				why = "queue geometry/vector/vport exceeds screenshot or VIP bounds"; return 0;
			end
			depth = $clog2(queues[q].queue_size);
			r.owner = queues[q].service_key.function_key;
			r.consumers.delete();
			r.consumers.push_back(queues[q].service_key);
			r.has_queue = 1;
			r.binding = queues[q];
			r.dependencies.delete();
			foreach (kinds[k]) begin
				bit	found;
				if (!(kinds[k] inside {PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX})) continue;
				found = 0;
				foreach (frozen_controls[c]) begin
					bit	selected_consumer;

					if (frozen_controls[c].ctx.kind != kinds[k]) continue;
					selected_consumer = dpu_same_function_key(frozen_controls[c].owner,
						queues[q].service_key.function_key);
					foreach (frozen_controls[c].consumers[v]) begin
						if (dpu_service_key_name(frozen_controls[c].consumers[v]) == service) selected_consumer = 1;
					end
					if (!selected_consumer) continue;
					if (kinds[k] == PROJECT_QUEUE_AUX && frozen_controls[c].ctx.table_index != queues[q].qpair.global_qpair_id) continue;
					if ($isunknown({frozen_controls[c].value, frozen_controls[c].writable_mask}) ||
						(frozen_controls[c].value & ~frozen_controls[c].writable_mask) != 0) begin
						why = "queue control contains unknown/reserved bits"; return 0;
					end
					if (!control_consumers(frozen_controls[c], r.consumers, why)) return 0;
					if (kinds[k] == PROJECT_QUEUE_AUX) begin
						bit	bound_consumer;
						bound_consumer = 0;
						foreach (r.consumers[v])
							if (dpu_service_key_name(r.consumers[v]) == service) bound_consumer = 1;
						if (!bound_consumer) r.consumers.push_back(queues[q].service_key);
					end
					r.owner = frozen_controls[c].owner;
					r.has_queue = kinds[k] == PROJECT_QUEUE_AUX;
					r.entry = frozen_controls[c].value;
					r.enable_mask = 0;
					r.enable_value = 0;
					if (!make_context(kinds[k], r.owner, frozen_controls[c].ctx.table_index,
						kinds[k] == PROJECT_QUEUE_AUX ? selection.setups[h].get_generation() : 0, r.ctx, why)) return 0;
					selected.push_back(r);
					found = 1;
				end
				if (!found && frozen_layouts.exists(kinds[k]) && frozen_layouts[kinds[k]].required) begin
					why = {"required queue control missing: ", kinds[k].name()}; return 0;
				end
			end
			r.owner = queues[q].service_key.function_key;
			r.consumers.delete();
			r.consumers.push_back(queues[q].service_key);
			r.has_queue = 1;
			r.enable_mask = 128'h1 << 68;
			r.enable_value = r.enable_mask;
			if ((queues[q].tx_mode && kind_selected(PROJECT_VTX, kinds)) ||
				(!queues[q].tx_mode && kind_selected(PROJECT_VRX, kinds))) begin
			if (queues[q].tx_mode) begin
				project_vtx_entry_t	e;
				e = policy.vtx;
				if ($isunknown(e) || e.reserved_127_112 != 0 || e.reserved_111_106 != 0 ||
					e.queue_en != 0 || e.queue_stop != 0 || (e.high_speed_mode && depth < 7) || h > 6) begin
					why = "VTX template reserved/enable/Host/high-speed constraint violated"; return 0;
				end
				e.desc_addr = queues[q].desc_iova;
				e.q_depth = depth;
				e.virtio_mode = queues[q].queue_type == VQ_PACKED;
				e.sport = h;
				e.sport_id = fp.vport;
				e.dma_msix = queues[q].qpair.global_msix_vector_id;
				r.entry = e;
				if (!make_context(PROJECT_VTX, r.owner, queues[q].qpair.global_qpair_id, selection.setups[h].get_generation(), r.ctx, why)) return 0;
			end else begin
				project_vrx_entry_t	e;
				e = policy.vrx;
				pre_count = e.dsc_pre_max_num == 0 ? 256 : e.dsc_pre_max_num == 1 ? 128 : e.dsc_pre_max_num == 2 ? 64 : e.dsc_pre_max_num == 3 ? 32 : 16;
				pre_start = policy.prefetch_start + queues[q].qpair.virtio_pair_index * pre_count;
				if ($isunknown(e) || e.reserved_127 != 0 || e.reserved_108 != 0 || e.queue_en != 0 ||
					e.dsc_mode != 0 || e.payload_dsc_len != 0 || e.head_dsc_len != 0 || h > 3 ||
					policy.prefetch_ram == "" || pre_count >= queues[q].queue_size ||
					policy.prefetch_slots != pre_count || pre_start % pre_count != 0 ||
					64'(policy.prefetch_start) + 64'(queues[q].allocated_qpairs) * pre_count > (policy.fpga ? 16384 : 32768)) begin
					why = "VRX reserved/head-split/Host/prefetch policy invalid"; return 0;
				end
				// 以全部冻结 service 的 RAM 预留检查重叠，局部 scope 不会重新从零分配。
				foreach (frozen_policies[other]) begin
					if (other != service && frozen_policies[other].prefetch_ram == policy.prefetch_ram) begin
						vio_service_requirement_t	other_requirement;
						int unsigned			oh;
						oh = frozen_policies[other].service_key.function_key.host_id;
						if (!this.vio_cfg_by_host.exists(oh)) return 0;
						if (this.vio_cfg_by_host[oh] == null) return 0;
						if (!this.vio_cfg_by_host[oh].resolve_final_service_requirement(frozen_policies[other].service_key, other_requirement, why)) return 0;
						if (other_requirement.enabled && other_requirement.rx_enable &&
							64'(policy.prefetch_start) < 64'(frozen_policies[other].prefetch_start) + 64'(other_requirement.behavior.num_queue_pairs)*frozen_policies[other].prefetch_slots &&
							64'(frozen_policies[other].prefetch_start) < 64'(policy.prefetch_start) + 64'(queues[q].allocated_qpairs)*pre_count) begin
							why = "VRX descriptor RAM reservations overlap across services/Hosts"; return 0;
						end
					end
				end
				e.dsc_addr = queues[q].desc_iova;
				e.q_depth = depth;
				e.virtio_mode = queues[q].queue_type == VQ_PACKED;
				e.dport = h;
				e.dport_id = fp.vport;
				e.dma_msix = queues[q].qpair.global_msix_vector_id;
				e.dma_msix_en = queues[q].completion_mode == VIRTIO_COMPLETION_MSIX;
				e.dsc_pre_read_ram_addr = pre_start;
				r.entry = e;
				if (!make_context(PROJECT_VRX, r.owner, queues[q].qpair.global_qpair_id, selection.setups[h].get_generation(), r.ctx, why)) return 0;
			end
			selected.push_back(r);
			end
			// 非 ring 表不携带 ring enable 位，独立批次与合并 verify 必须生成相同记录。
			r.enable_mask = 0;
			r.enable_value = 0;
			if (kind_selected(PROJECT_Q2TC, kinds) || kind_selected(PROJECT_N2G, kinds) || kind_selected(PROJECT_G2P, kinds)) begin
			// Q2TC/N2G/G2P 编号由显式策略生成；net/group 十位先检查再赋值。
			if (64'(policy.net_base) + 64'(queues[q].qpair.virtio_pair_index)*policy.net_stride >= 1024 ||
				policy.group_id >= 1024 || policy.cos >= 8 || policy.eth_ports + h >= 16 ||
				policy.eth_ports == 0 || (policy.ets && policy.ets_priority >= 8) || (!policy.ets && h >= 5) ||
				queues[q].qpair.global_qpair_id >= 1024) begin why = "QSCH topology exceeds declared screenshot encoding"; return 0; end
			net_id = policy.net_base + queues[q].qpair.virtio_pair_index * policy.net_stride;
			if (kind_selected(PROJECT_Q2TC, kinds)) begin
				project_qsch_q2tc_entry_t	e;
				e = '0;
				e.valid = 1;
				e.net_id = net_id;
				e.cos = policy.cos;
				r.entry = e;
				if (!make_context(PROJECT_Q2TC, r.owner, queues[q].qpair.global_qpair_id, selection.setups[h].get_generation(), r.ctx, why)) return 0;
				selected.push_back(r);
			end
			r.has_queue = 0;
			if (kind_selected(PROJECT_N2G, kinds)) begin
				project_qsch_n2g_entry_t	e;
				e = '0;
				e.valid = 1;
				e.group_id = policy.group_id;
				r.entry = e;
				if (!make_context(PROJECT_N2G, r.owner, net_id, 0, r.ctx, why)) return 0;
				selected.push_back(r);
			end
			if (kind_selected(PROJECT_G2P, kinds)) begin
				project_qsch_g2p_entry_t	e;
				e = '0;
				e.valid = 1;
				e.dpt = policy.eth_ports + h;
				e.lvl2_id = policy.ets ? policy.ets_priority : h;
				r.entry = e;
				if (!make_context(PROJECT_G2P, r.owner, policy.group_id, 0, r.ctx, why)) return 0;
				selected.push_back(r);
			end
			end
		end
	end
	why = "";
	return 1;
endfunction


// 小型类别集合查询，只统一遍历条件，不建立第二个 callback 引擎。
function bit project_env_cfg::kind_selected(
	input project_table_kind_e	kind,
	input project_table_kind_e	kinds[$]
);
	foreach (kinds[i]) if (kind == kinds[i]) return 1;
	return 0;
endfunction


// 在配置 sequence 的写表、使能及所选验证成功后确认资源，随后允许业务发包。
// 关闭读回时以平台认可的写入流程作为确认依据，不代表已读取 DUT 验证硬件状态。
// 核心仍校验导出的 ring 与实际队列一致；此处不维护跨 sequence 的状态账本。
function void project_env_cfg::commit_vio_configuration(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	ok = 0;
	if (!preflight_vio(selection, why)) return;

	foreach (selection.setups[h]) begin
		if (!vio_envs[h].confirm_external_configuration(selection.setups[h], selection.scopes[h], 1, why)) return;
	end
	ok = 1;
	why = "";
endfunction


// 平台确认 DUT 已停止 DMA 后释放整 Host 的 ring；不自动停机，也不执行寄存器写入。
function void project_env_cfg::release_vio_resources(
	input project_vio_selection_t	selection,
	input logic			dut_quiesced,
	output bit			ok,
	output string			why
);
	vio_queue_setup_t	queues[$];
	string			remove_keys[$];
	ok = 0;
	why = "release needs explicit platform quiescence";
	if (dut_quiesced !== 1'b1 || !preflight_vio(selection, why)) return;
	foreach (selection.setups[h]) begin
		selection.setups[h].list_queues(queues);
		foreach (queues[q]) if (!selection.scopes[h].selects(queues[q].service_key)) begin why = "release must select complete Host generation"; return; end
		if (!vio_envs[h].preflight_external_configuration(selection.setups[h], null, why)) return;
	end
	foreach (selection.setups[h]) begin
		if (!vio_envs[h].release_external_resources(selection.setups[h], dut_quiesced, why)) return;
		vio_setups.delete(h);
	end
	// 只移除已释放 Host 的 Notify 项，存活 Host 保持硬件行号；下一代全量 prepare 再排序。
	for (int i = notify_records.size() - 1; i >= 0; i--) begin
		if (selection.setups.exists(notify_records[i].owner.host_id)) notify_records.delete(i);
	end
	foreach (records[name]) begin
		if (records[name].ctx.kind inside {PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT}) begin
			for (int c = records[name].consumers.size()-1; c >= 0; c--)
				if (selection.setups.exists(records[name].consumers[c].function_key.host_id)) records[name].consumers.delete(c);
			if (records[name].consumers.size() == 0) remove_keys.push_back(name);
		end else if (records[name].has_queue && selection.setups.exists(records[name].owner.host_id)) remove_keys.push_back(name);
	end
	foreach (remove_keys[i]) begin
		records.delete(remove_keys[i]);
	end
	ok = 1;
	why = "";
endfunction


// 只允许状态类别，调用者必须显式提供实测 PBA 容量和各自模块偏移。
function bit project_env_cfg::get_state_context(
	input project_table_kind_e	kind,
	input dpu_function_key_t	owner,
	input int unsigned		index,
	output project_state_query_t	item,
	output string			why
);
	why = "not a readable state category";
	if (!(kind inside {PROJECT_MSIX_PBA, PROJECT_MSIX_STAT, PROJECT_PFVF_DROP})) return 0;
	item.owner = owner;
	return make_context(kind, owner, index, 0, item.ctx, why);
endfunction


// 同 PF 完整成员和实际 BDF/路由交付平台；缺映射/角色错误在调用纯规则前拒绝。
function bit project_env_cfg::validate_pfvf_family(
	input dpu_function_key_t	owner,
	output string			why
);
	project_function_record_t	functions[$];
	project_pfvf_relationship_t	family;
	dpu_setup.list_functions(functions);
	foreach (functions[i]) begin
		string	name;
		if (functions[i].key.host_id != owner.host_id || functions[i].key.pf_id != owner.pf_id) continue;
		name = dpu_function_key_name(functions[i].key);
		if (!frozen_functions.exists(name)) begin why = "PFVF family lacks explicit routing policy"; return 0; end
		if (frozen_functions[name].pfvf >= 1024 || frozen_functions[name].first_vf_offset >= 1024) begin
			why = "PFVF family field exceeds screenshot width"; return 0;
		end
		family.functions.push_back(functions[i]);
		family.policies.push_back(frozen_functions[name]);
	end
	if (family.functions.size() == 0) begin why = "PFVF family is empty"; return 0; end
	return this.validate_pfvf_relationship(family, why);
endfunction
```

## `integration/project/project_pcie_reg_seq.sv`

SHA-256: `49e222e952ee52c175c273ca9228a054f805e2d0e35b9d451c0e349a1f78c80e`

```systemverilog
// integration/project：供 AIP reg_acc 使用的 PF0 BAR0 相对地址访问 sequence。
// 继承 pcie_tl_reg_seq 的命令字段；依赖 env_cfg 中真实 BAR registry 和 RC sequencer。
// cfg 由用户赋值或从启动 sequencer 的 env_cfg 获取；本类借用句柄，不分配或配置 DUT 资源。
// addr 始终是 Host0/PF0 BAR0 内偏移，完整请求先检查范围，再交原生 seq 发送 Memory TLP。
// 每次执行清空输出；失败通过 status/error_msg 返回 Tcl，不 fatal、不累加修改 addr。
class project_pcie_reg_seq extends pcie_tl_reg_seq;
	`uvm_object_utils(project_pcie_reg_seq)

	project_env_cfg	cfg;

	// 保留原寄存器命令默认宽度和 byte skip-mask 语义。
	extern function new(string name = "project_pcie_reg_seq");
	// 解析真实 BAR0 基址和 Host0 RC，原样传递读写字段并回传结果；不启动 DUT 配置流程。
	extern virtual task body();
endclass

// 输入默认值沿用 pcie_tl_reg_seq，cfg 初始为空便于直接使用已有 env_cfg 注册。
function project_pcie_reg_seq::new(string name);
	super.new(name);
endfunction

// 整个 len 范围在发送前校验，包括 masked 字节；posted 写成功仅表示发送完成。
// 显式 new 原生子 seq，避免用户把父类 factory override 到本类后递归创建包装层。
task project_pcie_reg_seq::body();
	project_bar_target_t	target;
	bit [63:0]		absolute_address;
	pcie_tl_reg_seq		request;

	rdata     = '0;
	status    = PCIE_RW_OK;
	error_msg = "";
	issued_tlps.delete();
	if (!validate_request()) return;
	status = PCIE_RW_ERR;
	if (cfg == null) begin
		if (m_sequencer == null) begin
			error_msg = "PF0 BAR0 access requires cfg or a sequencer with env_cfg";
			return;
		end
		if (!uvm_config_db#(project_env_cfg)::get(m_sequencer, "", "env_cfg", cfg) || cfg == null) begin
			error_msg = "PCIe sequencer has no project env_cfg";
			return;
		end
	end
	if (cfg.bar_registry == null) begin
		error_msg = "PF0 BAR0 registry has not been published";
		return;
	end
	if (!cfg.bar_registry.resolve_name("h0.pf0.bar0", target, error_msg)) return;
	if (!cfg.bar_registry.check_range(target, addr, len, absolute_address, error_msg)) return;
	if (!cfg.rc_sequencers.exists(target.rc_slot) || cfg.rc_sequencers[target.rc_slot] == null) begin
		error_msg = "PF0 BAR0 has no mapped PCIe RC sequencer";
		return;
	end

	`uvm_info("PROJECT_REG_ACC", $sformatf(
		"h0.pf0.bar0 base=0x%016h + offset=0x%016h = address=0x%016h len=%0d write=%0b rc=%0d",
		target.bar_lease.base, addr, absolute_address, len, is_write, target.rc_slot), UVM_LOW)
	request = new("pf0_bar0_request");
	request.is_write        = is_write;
	request.addr            = absolute_address;
	request.len             = len;
	request.mask            = mask;
	request.wdata           = wdata;
	request.rb_timeout_ns   = rb_timeout_ns;
	request.check_read_data = check_read_data;
	request.start(cfg.rc_sequencers[target.rc_slot], this);
	rdata       = request.rdata;
	status      = request.status;
	error_msg   = request.error_msg;
	issued_tlps = request.issued_tlps;
endtask
```

## `integration/project/project_dut_config_seq.sv`

SHA-256: `2750f747e6cd9ca5ab43b5566ec236856e084880328ed6577a9cf1ceba9b7a47`

```systemverilog
// integration/project：可直接 start 的 DUT 表配置 sequence，使用同一个 project_env_cfg。
// 依赖 cfg 中的真实 BAR/队列视图与 PCIe RC sequencer；不创建第二套 context 或 env。
// task/hook 属于本 sequence，cfg 保存参数、资源与表项数据；ring/BAR 不归 seq 所有。
// 所有硬件访问复用 pcie_tl_reg_seq，经实际目标 RC、Intel bind 发往 DUT。
// 默认 body 先声明 Host0/PF0 为 AF 并单次读回状态8，再配置 BDF、VIO/QSCH；MSI-X 按完成模式选择。
// 已知表按图片字段和 cfg 地址真实写入；读回可选，失败报告 fatal 并保留 DMA 资源。
// Notify 仅访问实际队列对的有效项；首次配置前 DUT 已按 05.png 复位为无效项：
// type=3，lookup key/global_qid 全1，reserved=0。未用槽位保持该复位值，不由 seq 写入或读回。
class project_dut_config_seq extends uvm_sequence #(pcie_tl_tlp);
	`uvm_object_utils(project_dut_config_seq)

	project_env_cfg		cfg;
	project_vio_selection_t	selection;
	bit			success;
	string			error_msg;
	// 当前 seq 自上次成功 AF 状态读之后完成的完整 DWORD 写数；每次 start 独立计数。
	protected int unsigned	writes_since_af_read;

	// 对象只保存本次执行结果；运行期共享状态始终在 cfg，不随 sequence 销毁。
	extern function new(
		string	name = "project_dut_config_seq"
	);

	// start 时取得配置句柄；派生 body 自动获得 cfg，不需要调用 env 的配置 task。
	extern virtual task pre_start();

	// 平台先等待复位就绪；AF 声明先于写表，VIO 在写入、所选验证和 commit 后成功。
	extern virtual task body();

	// 固定向 Host0/PF0 BAR0+0x1010 写声明后读一次状态8；不轮询，任一步失败停止。
	extern virtual task declare_af(
		output bit	ok,
		output string	why
	);

	// 单次读取固定状态寄存器并要求8；成功后清写计数，失败保留原因，不轮询。
	extern protected task read_af_status(
		output bit	ok,
		output string	why
	);

	// start 返回前报告失败，AIP 直接注册本类时也不会把提前 return 显示为配置成功。
	extern virtual task post_start();

	// 给当前失败添加阶段名；所有调用均在首次失败停止，不继续使能或释放资源。
	extern protected function bit completed_step(
		input string	step,
		input bit	ok
	);


	// MMIO helper 校验四态输入和完整范围，posted success 仅表示发送完成。
	extern task pcie_bar_write(
		input dpu_function_key_t	owner,
		input int unsigned		bar_id,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		input logic [31:0]		byte_skip_mask,
		output bit			ok,
		output string			why
	);

	// 读 Completion 的失败和短数据由底层 sequence 明确上传，不把默认零当成功。
	extern task pcie_bar_read(
		input dpu_function_key_t	owner,
		input int unsigned		bar_id,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [31:0]		byte_skip_mask,
		output logic [127:0]		data,
		output bit			ok,
		output string			why
	);

	// 手动路径无隐含 Host，多个 Host 时必须写完整 h 前缀。
	extern task pcie_bar_write_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [127:0]	data,
		input logic [31:0]	byte_skip_mask,
		output bit		ok,
		output string		why
	);

	// 名字解析与实际 Function API 复用同一个范围/格式检查。
	extern task pcie_bar_read_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [31:0]	byte_skip_mask,
		output logic [127:0]	data,
		output bit		ok,
		output string		why
	);

	// 用户自定义表按高 DWORD 到低 DWORD 写；完整预检后发送，失败立即停止。
	// 不隐含控制触发或读回；在配置 sequence 内按所需顺序调用。
	extern task pcie_table_write_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [127:0]	data,
		output bit		ok,
		output string		why
	);

	// 有界显式轮询；比较 mask 与 byte skip-mask 是不同概念，不在后台自动读状态。
	extern task pcie_poll_bar(
		input dpu_function_key_t	owner,
		input int unsigned		bar_id,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		mask,
		input logic [127:0]		expected,
		input int unsigned		attempts,
		input time			interval,
		output bit			ok,
		output string			why
	);

	// typed helper 在首笔发送前校验完整表项，随后顺序发送所有 DWORD。
	extern protected task checked_write(
		input project_config_record_t	record,
		input logic [127:0]		value,
		input bit			enabling,
		output bit			ok,
		output string			why
	);

	// 全部四态检查在转换前执行；check_read_data 仅为状态读关闭 SCB 的 RAM 写值比较。
	extern protected task mmio(
		input project_bar_target_t	target,
		input bit			writing,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		input logic [31:0]		byte_skip_mask,
		output logic [127:0]		result,
		output bit			ok,
		output string			why,
		input bit			check_read_data = 1
	);

	// 统一表项写序；保留原始 mmio 的宽度/掩码语义，禁止先发送再发现越界。
	extern protected task write_table_dwords(
		input project_bar_target_t	target,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		output bit			ok,
		output string			why
	);

	// 公共控制 hook 可复用同一 checked 路径；mask 和消费者也必须匹配原件。
	extern task write_control(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 辅助项有实际 ring 绑定，不能借控制 payload 修改另一个 pair。
	extern task write_queue_aux(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 唯一 typed dispatch；不在单项 hook 中复制外围循环，也不隐含执行其他类别。
	extern protected task dispatch_record(
		input project_config_record_t	record,
		output bit			ok,
		output string			why
	);

	// 先生成所选公共表，再逐项调用用户 hook；同一硬件项只写一次，失败立即停止。
	extern protected task configure_public(
		input project_table_kind_e	kinds[$],
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 按实际 service/qpair 遍历；共享 QSCH 项去重，TX-only 不生成 VRX 写入。
	extern protected task configure_queues(
		input project_table_kind_e	kinds[$],
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 独立 configure_bar_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_bar_table(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_af 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_af(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_pf_vf_map 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_pf_vf_map(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_bdf_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_bdf_table(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_completion_bdf_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_completion_bdf_table(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_tlp_prefix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_tlp_prefix(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_msix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_msix(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 enable_msix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task enable_msix(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_rdma_notify 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_rdma_notify(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_qsch_rnet 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_qsch_rnet(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_vio_notify 入口；不隐含调用其他类别。
	extern task configure_vio_notify(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// MSI-X linear 同样按查找键排列；完整流程填充单 bank 无效尾部，独立表入口不隐含初始化。
	extern protected task process_msix_tail(
		input bit	verify,
		output bit	ok,
		output string	why
	);

	// 独立 configure_qsch 入口；不隐含调用其他类别。
	extern task configure_qsch(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 每个实际管理 BAR 写一次 QSCH 模式，按开关读回；不改变调度表的 owner 或索引。
	extern task configure_qsch_mode(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 独立 configure_vio_queues 入口；不隐含调用其他类别。
	extern task configure_vio_queues(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 使能和验证分别执行；任何必需类别失败均保留 DMA 并阻止提交。
	extern task enable_vio_queues(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 公共配置写完后交由平台读回或检查状态；不将 posted 发送完成当成硬件生效。
	extern task verify_dpu_configuration(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 读回本轮基础 BDF 和所选 MSI-X 数据表；不要求平台实现其他公共表验证。
	// 默认 body 仅在 verify_readback=1 时调用；显式调用本方法始终执行真实读取。
	extern virtual task verify_function_configuration(
		input project_dpu_config_scope	bdf_scope,
		input project_dpu_config_scope	msix_scope,
		output bit			ok,
		output string			why
	);

	// 队列配置写完后执行平台验证；成功后默认 body 才调用 cfg.commit_vio_configuration。
	extern task verify_vio_configuration(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_bdf；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_bdf_entry(
		input project_bdf_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_bdf(
		input project_bdf_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 本类默认调用 write_completion_bdf；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_completion_bdf_entry(
		input project_completion_bdf_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_completion_bdf(
		input project_completion_bdf_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 本类默认调用 write_pfvf；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_pf_vf_entry(
		input project_pfvf_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_pfvf(
		input project_pfvf_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_tlp_prefix；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_tlp_prefix_entry(
		input project_tlp_prefix_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_tlp_prefix(
		input project_tlp_prefix_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_msix_linear；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_msix_linear_entry(
		input project_msix_linear_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_linear(
		input project_msix_linear_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_msix_info；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_msix_info_entry(
		input project_msix_info_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_info(
		input project_msix_info_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_msix_interval；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_msix_interval_entry(
		input project_msix_interval_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_interval(
		input project_msix_interval_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 本类默认调用 write_msix_table；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_msix_table_entry(
		input project_msix_table_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_table(
		input project_msix_table_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_qsch_q2tc；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_qsch_q2tc(
		input project_qsch_q2tc_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_q2tc(
		input project_qsch_q2tc_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_qsch_n2g；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_qsch_n2g(
		input project_qsch_n2g_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_n2g(
		input project_qsch_n2g_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_qsch_g2p；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_qsch_g2p(
		input project_qsch_g2p_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_g2p(
		input project_qsch_g2p_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_rdma_notify；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_rdma_notify_entry(
		input project_rdma_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_rdma_notify(
		input project_rdma_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_qsch_rnet；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_qsch_rnet_entry(
		input project_qsch_rnet_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_rnet(
		input project_qsch_rnet_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_vtx；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_vtx_queue(
		input project_vtx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vtx(
		input project_vtx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 本类默认调用 write_vrx；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_vrx_queue(
		input project_vrx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vrx(
		input project_vrx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 本类默认调用 write_vio_notify；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_vio_notify_entry(
		input project_vio_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vio_notify(
		input project_vio_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_prepare_device(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_af(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_msix_control_entry(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_msix_function(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_control；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_qsch_spwrr(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_control；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_qsch_tc_weight(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 本类默认调用 write_queue_aux；覆写此 hook 可适配平台访问时序。
	extern virtual task user_configure_queue_aux(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 本类默认调用 write_enabled_queue；覆写此 hook 可适配平台访问时序。
	extern virtual task user_enable_queue(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_quiesce_device(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_reset_device(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// BAR 映射必须接收完整原子组，不能推测连续 VF 窗口。
	extern virtual task user_configure_bar_mapping_entry(
		input project_bar_mapping_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 验证平台已有配置允许独立于写入入口调用；成功只确认传入 scope。
	extern virtual task user_verify_dpu_configuration(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 默认真实读回 Notify/QSCH/队列表并比较；项目可覆写自清零或只写寄存器的验证。
	extern virtual task user_verify_vio_configuration(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 使能专用 checked 入口，只允许冻结 enable 位变化并完整核对 ring 绑定。
	extern task write_enabled_queue(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 只读状态查询与明确 W1C 清除保持独立，不隐含写入配置表。
	extern task read_msix_pba(
		input project_state_query_t	item,
		output project_msix_pba_word_t	value,
		output bit			ok,
		output string			why
	);

	// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
	extern task read_msix_stat(
		input project_state_query_t	item,
		output project_msix_stat_t	value,
		output bit			ok,
		output string			why
	);

	// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
	extern task read_pfvf_drop_status(
		input project_state_query_t		item,
		output project_pfvf_drop_status_t	value,
		output bit				ok,
		output string				why
	);

	// 显式 clear_mask 与状态值类型隔离；未知态、错误目标在用户 hook 前拒绝。
	extern task clear_pfvf_drop_status(
		input project_pfvf_drop_clear_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
	extern virtual task user_read_msix_stat(
		input project_state_query_t	item,
		output project_msix_stat_t	value,
		output bit			ok,
		output string			why
	);

	// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
	extern virtual task user_read_pfvf_drop_status(
		input project_state_query_t		item,
		output project_pfvf_drop_status_t	value,
		output bit				ok,
		output string				why
	);

	// 清除由用户显式执行；不把读出的 status 自动回写。
	extern virtual task user_clear_pfvf_drop_status(
		input project_pfvf_drop_clear_cfg_t	item,
		output bit				ok,
		output string				why
	);
endclass


// 构造 sequence 外壳，不读取参数，不访问 DUT。
function project_dut_config_seq::new(
	string	name
);
	super.new(name);
endfunction

// UVM 即使 start(..., call_pre_post=0) 也调用 pre_start，故派生 body 可直接使用 cfg。
task project_dut_config_seq::pre_start();
	success = 0;
	error_msg = "";
	writes_since_af_read = 0;
	if (m_sequencer == null) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "start configuration on the project's PCIe RC sequencer")
	end
	if (!uvm_config_db#(project_env_cfg)::get(m_sequencer, "", "env_cfg", cfg) || cfg == null) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "PCIe sequencer has no env_cfg")
	end
	if (!cfg.runtime_ready) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "env connect must finish before configuration")
	end
endtask

// 默认先声明 Host0/PF0 为 AF，再执行 BDF、所选 MSI-X 和 VIO；其余公共表独立可选。
// 同一 seq 串行完成配置；verify_readback=1 时读回符合预期才开放业务，首次失败保留现场。
task project_dut_config_seq::body();
	project_dpu_config_scope	public_scope;
	project_dpu_config_scope	bdf_scope;
	project_dpu_config_scope	msix_scope;
	dpu_function_key_t	functions[$];
	int unsigned		bars[$];
	bit			ok;

	`uvm_info("PROJECT_CONFIG_SEQ", $sformatf("begin DUT configuration (readback=%0b)", cfg.verify_readback), UVM_LOW)
	public_scope = new("public_scope", cfg.dpu_setup, functions, bars);
	if (cfg.configure_bdf) bdf_scope = public_scope;
	ok = cfg.select_msix_scope(msix_scope, error_msg);
	if (!completed_step("select_msix_scope", ok)) return;

	declare_af(ok, error_msg);
	if (!completed_step("declare_af", ok)) return;

	if (cfg.configure_public) begin
		configure_bar_table(public_scope, ok, error_msg);
		if (!completed_step("configure_bar_table", ok)) return;

		if (cfg.frozen_layouts.exists(PROJECT_AF)) begin
			configure_af(public_scope, ok, error_msg);
			if (!completed_step("configure_af", ok)) return;
		end

		configure_pf_vf_map(public_scope, ok, error_msg);
		if (!completed_step("configure_pf_vf_map", ok)) return;

		configure_completion_bdf_table(public_scope, ok, error_msg);
		if (!completed_step("configure_completion_bdf_table", ok)) return;

		configure_tlp_prefix(public_scope, ok, error_msg);
		if (!completed_step("configure_tlp_prefix", ok)) return;
	end

	if (bdf_scope != null) begin
		configure_bdf_table(bdf_scope, ok, error_msg);
		if (!completed_step("configure_bdf_table", ok)) return;
	end

	// 消息映射与中断控制先于队列使能；无公共消息需求的 polling 不产生 MSI-X 配置写。
	if (msix_scope != null) begin
		configure_msix(msix_scope, ok, error_msg);
		if (!completed_step("configure_msix", ok)) return;

		process_msix_tail(0, ok, error_msg);
		if (!completed_step("initialize_msix_tail", ok)) return;

		enable_msix(msix_scope, ok, error_msg);
		if (!completed_step("enable_msix", ok)) return;
	end

	if (cfg.verify_readback) begin
		verify_function_configuration(bdf_scope, msix_scope, ok, error_msg);
		if (!completed_step("verify_function_configuration", ok)) return;

		if (msix_scope != null) begin
			process_msix_tail(1, ok, error_msg);
			if (!completed_step("verify_msix_tail", ok)) return;
		end

		if (cfg.configure_public) begin
			verify_dpu_configuration(public_scope, ok, error_msg);
			if (!completed_step("verify_dpu_configuration", ok)) return;
		end
	end

	cfg.prepare_vio_configuration(selection, ok, error_msg);
	if (!completed_step("prepare_vio_configuration", ok)) return;

	if (selection.setups.num() != 0) begin
		configure_vio_notify(selection, ok, error_msg);
		if (!completed_step("configure_vio_notify", ok)) return;

		configure_qsch(selection, ok, error_msg);
		if (!completed_step("configure_qsch", ok)) return;

		configure_vio_queues(selection, ok, error_msg);
		if (!completed_step("configure_vio_queues", ok)) return;

		enable_vio_queues(selection, ok, error_msg);
		if (!completed_step("enable_vio_queues", ok)) return;

		if (cfg.verify_readback) begin
			verify_vio_configuration(selection, ok, error_msg);
			if (!completed_step("verify_vio_configuration", ok)) return;
		end

		cfg.commit_vio_configuration(selection, ok, error_msg);
		if (!completed_step("commit_vio_configuration", ok)) return;
	end

	success   = 1;
	error_msg = "";
	`uvm_info("PROJECT_CONFIG_SEQ", $sformatf("DUT configuration completed (readback=%0b)", cfg.verify_readback), UVM_LOW)
endtask


// 通过真实 Host0 RC 先写 magic，再同步读一次4B状态；必须返回8才允许后续表配置。
// 状态寄存器不按写入值比较，只关闭该次读的 RAM 数据比较；Completion 失败仍原样上传。
// 不受 configure_public/verify_readback 控制，不轮询、不执行驱动其余 Host-ID 流程。
task project_dut_config_seq::declare_af(
	output bit	ok,
	output string	why
);
	pcie_bar_write_by_name("h0.pf0.bar0", 64'h1010, 4, 128'h5555_aaaa, 32'h0, ok, why);
	if (!ok) return;
	read_af_status(ok, why);
endtask


// 首次声明和每100笔完整DWORD配置写复用同一同步状态读；真实Completion返回前不能继续写。
// 只有该读跳过 RAM 写值比较；单次值不为8或传输失败立即终止，不插固定延迟或额外尾读。
task project_dut_config_seq::read_af_status(
	output bit	ok,
	output string	why
);
	project_bar_target_t	target;
	logic [127:0]		status_data;

	ok = 0;
	if (!cfg.bar_registry.resolve_name("h0.pf0.bar0", target, why)) return;
	mmio(target, 0, 64'h1010, 4, '0, '0, status_data, ok, why, 0);
	if (!ok) return;
	if (status_data[31:0] !== 32'h8) begin
		ok = 0;
		why = $sformatf("AF status expected 0x00000008, got 0x%08h", status_data[31:0]);
		return;
	end
	writes_since_af_read = 0;
endtask


// 失败在 start 返回前显式报告；AIP 无需理解自定义 success 字段也能看见错误。
task project_dut_config_seq::post_start();
	if (!success) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", error_msg == "" ? "DUT configuration failed" : error_msg)
	end
endtask


// 给首个错误加执行阶段，保留底层地址/字段/Completion 原因以便定位。
function bit project_dut_config_seq::completed_step(
	input string	step,
	input bit	ok
);
	if (!ok) begin
		error_msg = {step, ": ", error_msg};
	end

	return ok;
endfunction


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_bar_table(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_BAR};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_af(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_AF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_pf_vf_map(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_PFVF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_bdf_table(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_BDF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_completion_bdf_table(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_COMPLETION_BDF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_tlp_prefix(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_PREFIX};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_msix(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_CONTROL, PROJECT_MSIX_TABLE};
	configure_public(kinds, scope, ok, why);
endtask


// 在配置顺序中执行 MSI-X Function 使能；真实控制项由平台声明。
task project_dut_config_seq::enable_msix(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_MSIX_FUNCTION};

	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_rdma_notify(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_RDMA_NOTIFY};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_qsch_rnet(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_RNET};
	configure_public(kinds, scope, ok, why);
endtask


// 每对队列只写一条排序后的有效 Notify 项；同 pair 的 TX/RX 已由 cfg 去重。
// 首次配置前未用槽位须为图片复位无效值，本入口不初始化或读回未用槽位。
task project_dut_config_seq::configure_vio_notify(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_NOTIFY};
	configure_queues(kinds, selection, ok, why);
endtask


// 驱动的 MSI-X linear 无效行将全部非 reserved 字段置1，使空行排在查找目录尾部。
// 完整配置只使用一张统一管理窗口的单 bank；不自动切换 bank 或写 ready 寄存器。
task project_dut_config_seq::process_msix_tail(
	input bit	verify,
	output bit	ok,
	output string	why
);
	project_msix_linear_entry_t	invalid_entry;
	project_table_context_t		ctx;
	logic [127:0]			readback;
	bit [63:0]			offset;
	bit [63:0]			address;

	ok  = 0;
	why = "MSI-X linear directory is empty";
	if (cfg.msix_linear_records.size() == 0) return;

	ctx = cfg.msix_linear_records[0].ctx;
	if (ctx.layout.capacity > 2048 || cfg.msix_linear_records.size() > ctx.layout.capacity) begin
		why = "MSI-X linear directory exceeds the single-bank layout";
		return;
	end
	invalid_entry                = '1;
	invalid_entry.reserved_63_35 = '0;
	offset = ctx.layout.module_offset + ctx.layout.table_offset;
	if (!cfg.bar_registry.check_range(ctx.target, offset,
		64'(ctx.layout.capacity) * 8, address, why)) return;

	for (int unsigned row = cfg.msix_linear_records.size(); row < ctx.layout.capacity; row++) begin
		offset = ctx.layout.module_offset + ctx.layout.table_offset + 64'(row) * 8;
		if (verify) begin
			mmio(ctx.target, 0, offset, 8, 0, 0, readback, ok, why);
			if (!ok) return;
			if (readback !== 128'(invalid_entry)) begin
				ok  = 0;
				why = $sformatf("MSI-X invalid-row readback mismatch row=%0d offset=0x%016h", row, offset);
				return;
			end
		end else begin
			write_table_dwords(ctx.target, offset, 8, 128'(invalid_entry), ok, why);
			if (!ok) return;
		end
	end

	ok  = 1;
	why = "";
endtask


// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_dut_config_seq::configure_qsch(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT};

	if (cfg.qsch_configure_controls) begin
		configure_qsch_mode(selection, ok, why);
		if (!ok) return;
	end

	configure_queues(kinds, selection, ok, why);
endtask


// 从实际 Q2TC 目标解析管理 BAR；同一窗口仅写一次模式，所有值均由 cfg 参数提供。
// mode 的 VNET/ETS 关系已在 cfg 准备控制项时校验；可选读回失败不会继续使能队列。
task project_dut_config_seq::configure_qsch_mode(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_Q2TC};
	project_config_record_t	batch[$];
	bit			seen[string];
	logic [127:0]		readback;

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;

	foreach (batch[i]) begin
		if (seen.exists(batch[i].ctx.target.canonical_name)) continue;
		seen[batch[i].ctx.target.canonical_name] = 1;

		mmio(batch[i].ctx.target, 1, cfg.qsch_mode_offset,
			4, 128'(cfg.qsch_mode), 0, readback, ok, why);
		if (!ok) return;
		if (!cfg.verify_readback) continue;

		mmio(batch[i].ctx.target, 0, cfg.qsch_mode_offset,
			4, 0, 0, readback, ok, why);
		if (!ok) return;

		if (readback[31:0] !== 32'(cfg.qsch_mode)) begin
			ok  = 0;
			why = $sformatf("QSCH mode readback mismatch offset=0x%016h expected=%08h actual=%08h",
				cfg.qsch_mode_offset, cfg.qsch_mode, readback[31:0]);
			return;
		end
	end

	ok  = 1;
	why = "";
endtask


// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_dut_config_seq::configure_vio_queues(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX};
	configure_queues(kinds, selection, ok, why);
endtask


// 默认以 write_bdf 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_bdf_entry(
	input project_bdf_cfg_t	item,
	output bit		ok,
	output string		why
);
	write_bdf(item, ok, why);
endtask


// 默认以 write_completion_bdf 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_completion_bdf_entry(
	input project_completion_bdf_cfg_t	item,
	output bit				ok,
	output string				why
);
	write_completion_bdf(item, ok, why);
endtask


// 默认以 write_pfvf 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_pf_vf_entry(
	input project_pfvf_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_pfvf(item, ok, why);
endtask


// 默认以 write_tlp_prefix 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_tlp_prefix_entry(
	input project_tlp_prefix_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_tlp_prefix(item, ok, why);
endtask


// 默认以 write_msix_linear 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_msix_linear_entry(
	input project_msix_linear_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_msix_linear(item, ok, why);
endtask


// 默认以 write_msix_info 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_msix_info_entry(
	input project_msix_info_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_msix_info(item, ok, why);
endtask


// 默认以 write_msix_interval 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_msix_interval_entry(
	input project_msix_interval_cfg_t	item,
	output bit				ok,
	output string				why
);
	write_msix_interval(item, ok, why);
endtask


// 默认以 write_msix_table 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_msix_table_entry(
	input project_msix_table_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_msix_table(item, ok, why);
endtask


// 默认以 write_qsch_q2tc 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_qsch_q2tc(
	input project_qsch_q2tc_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_qsch_q2tc(item, ok, why);
endtask


// 默认以 write_qsch_n2g 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_qsch_n2g(
	input project_qsch_n2g_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_qsch_n2g(item, ok, why);
endtask


// 默认以 write_qsch_g2p 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_qsch_g2p(
	input project_qsch_g2p_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_qsch_g2p(item, ok, why);
endtask


// 默认以 write_rdma_notify 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_rdma_notify_entry(
	input project_rdma_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_rdma_notify(item, ok, why);
endtask


// 默认以 write_qsch_rnet 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_qsch_rnet_entry(
	input project_qsch_rnet_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_qsch_rnet(item, ok, why);
endtask


// 默认以 write_vtx 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_vtx_queue(
	input project_vtx_cfg_t	item,
	output bit		ok,
	output string		why
);
	write_vtx(item, ok, why);
endtask


// 默认以 write_vrx 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_vrx_queue(
	input project_vrx_cfg_t	item,
	output bit		ok,
	output string		why
);
	write_vrx(item, ok, why);
endtask


// 默认以 write_vio_notify 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_vio_notify_entry(
	input project_vio_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_vio_notify(item, ok, why);
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_prepare_device(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_prepare_device is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_af(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_af is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_msix_control_entry(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_msix_control_entry is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_msix_function(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_msix_function is not implemented";
endtask


// 默认以 write_control 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_qsch_spwrr(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_control(item, ok, why);
endtask


// 默认以 write_control 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_qsch_tc_weight(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	write_control(item, ok, why);
endtask


// 默认以 write_queue_aux 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_configure_queue_aux(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	write_queue_aux(item, ok, why);
endtask


// 默认以 write_enabled_queue 发送本项；平台可覆写写法，失败原样交给配置流程。
task project_dut_config_seq::user_enable_queue(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	write_enabled_queue(item, ok, why);
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_quiesce_device(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_quiesce_device is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_reset_device(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_reset_device is not implemented";
endtask


// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_dut_config_seq::user_configure_bar_mapping_entry(
	input project_bar_mapping_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_bar_mapping_entry is not implemented";
endtask


// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_dut_config_seq::user_verify_dpu_configuration(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_verify_dpu_configuration is not implemented";
endtask


// 读回实际配置表，而非共享 data staging 端口；使能后的队列表按 enable 位更新期望值。
// 当前初始化尚未发 Notify，ring 不应运行；自清零/只写的项目寄存器可覆写此验证方法。
// 读失败或任一有效位不符都阻止 commit，不把 posted 发送成功视为设备已应用。
task project_dut_config_seq::user_verify_vio_configuration(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{
		PROJECT_NOTIFY, PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P,
		PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX
	};
	project_config_record_t	batch[$];
	bit			seen[string];
	logic [127:0]		readback;
	logic [127:0]		expected;
	logic [127:0]		mask;

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;

	foreach (batch[i]) begin
		if (seen.exists(batch[i].ctx.record_key)) continue;
		seen[batch[i].ctx.record_key] = 1;

		expected = (batch[i].entry & ~batch[i].enable_mask) | batch[i].enable_value;
		mask     = '1;
		mask     = mask >> (128 - batch[i].ctx.layout.entry_bytes * 8);

		if (batch[i].ctx.kind inside {PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX}) begin
			mask = cfg.platform_control_mask(batch[i]);
		end

		mmio(batch[i].ctx.target, 0, batch[i].ctx.byte_offset,
			batch[i].ctx.layout.entry_bytes, 0, 0, readback, ok, why);
		if (!ok) return;

		if ((readback & mask) !== (expected & mask)) begin
			ok  = 0;
			why = $sformatf("readback mismatch %s BAR offset=0x%016h expected=%032h actual=%032h mask=%032h",
				batch[i].ctx.record_key, batch[i].ctx.byte_offset, expected, readback, mask);
			return;
		end
	end

	ok  = 1;
	why = "";
endtask

// 全部四态检查在两态 registry/sequence 转换前执行，保留小端 byte lane 和 skip-mask 语义。
task project_dut_config_seq::mmio(
	input project_bar_target_t	target,
	input bit			writing,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	input logic [31:0]		byte_skip_mask,
	output logic [127:0]		result,
	output bit			ok,
	output string			why,
	input bit			check_read_data
);
	pcie_tl_reg_seq	seq;
	bit [63:0]	address;
	ok = 0;
	result = '0;
	why = "MMIO contains X/Z, unsupported width/alignment or skip-mask";
	if ($isunknown({offset, data, byte_skip_mask}) || !(length inside {4,8,12,16}) ||
		offset[1:0] != 0 || (byte_skip_mask != '1 && (byte_skip_mask >> length) != 0) ||
		(writing && length < 16 && (data >> (8*length)) != 0)) return;
	if (cfg.bar_registry == null) return;
	if (!cfg.bar_registry.check_range(target, offset, length, address, why)) return;
	if (address[11:0] + length > 4096 || (!cfg.rc_sequencers.exists(target.rc_slot) || cfg.rc_sequencers[target.rc_slot] == null)) begin
		why = "MMIO crosses 4KB or has no RC sequencer";
		return;
	end
	seq = pcie_tl_reg_seq::type_id::create("project_mmio");
	seq.is_write = writing;
	seq.addr = address;
	seq.len = length;
	seq.mask = byte_skip_mask;
	seq.wdata = data;
	seq.check_read_data = check_read_data;
	seq.start(cfg.rc_sequencers[target.rc_slot], this);
	ok = seq.status == PCIE_RW_OK;
	why = seq.error_msg;
	result = seq.rdata;
	// 当前表写均为完整4B；宽访问和部分/全屏蔽访问不冒充一个完整DWORD，也不额外拆包。
	if (ok && writing && length == 4 && byte_skip_mask == 0 && seq.issued_tlps.size() != 0) begin
		writes_since_af_read++;
		if (writes_since_af_read == 100) read_af_status(ok, why);
	end
endtask


// Function+真实 BAR 查找，offset 永远相对所选 BAR；失败不回退默认窗口。
task project_dut_config_seq::pcie_bar_write(
	input dpu_function_key_t	owner,
	input int unsigned		bar_id,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	input logic [31:0]		byte_skip_mask,
	output bit			ok,
	output string			why
);
	project_bar_target_t	target;
	logic [127:0]		ignored;
	ok = 0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask


// 读 Completion 的失败和短数据由底层 sequence 明确上传，不把默认零当成功。
task project_dut_config_seq::pcie_bar_read(
	input dpu_function_key_t	owner,
	input int unsigned		bar_id,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [31:0]		byte_skip_mask,
	output logic [127:0]		data,
	output bit			ok,
	output string			why
);
	project_bar_target_t	target;
	ok = 0;
	data = '0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask


// 手动路径无隐含 Host，多个 Host 时必须写完整 h 前缀。
task project_dut_config_seq::pcie_bar_write_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [127:0]	data,
	input logic [31:0]	byte_skip_mask,
	output bit		ok,
	output string		why
);
	project_bar_target_t	target;
	logic [127:0]		ignored;
	ok = 0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_name(name, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask


// 解析用户选择的真实 BAR 后逐 DWORD 写完整表项；不改变 cfg 中已生成的 typed 表项。
// 地址是 BAR 内偏移；不自动读回或触发间接控制，失败保留已发出的 posted 写。
task project_dut_config_seq::pcie_table_write_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [127:0]	data,
	output bit		ok,
	output string		why
);
	project_bar_target_t	target;

	ok  = 0;
	why = "public registry not published";

	if (cfg.bar_registry == null) begin
		return;
	end

	if (!cfg.bar_registry.resolve_name(name, target, why)) begin
		return;
	end

	write_table_dwords(target, offset, length, data, ok, why);
endtask


// 表项最多 128 bit，每次仅发 32 bit，高位放高地址；不反转 DWORD 内字节。
// 第一笔前检查整项宽度、已知值、BAR 和 4KB 范围；任何发送失败立即返回。
// 单个配置 sequence 顺序调用；本层返回后调用者才发送 clear/trigger。
task project_dut_config_seq::write_table_dwords(
	input project_bar_target_t	target,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	output bit			ok,
	output string			why
);
	logic [127:0]	ignored;
	bit [63:0]	address;

	ok  = 0;
	why = "table write contains X/Z, unsupported width/alignment or excess data";

	if (
		$isunknown({offset, data}) ||
		!(length inside {4, 8, 12, 16}) ||
		offset[1:0] != 0 ||
		(length < 16 && (data >> (8 * length)) != 0)
	) begin
		return;
	end

	if (cfg.bar_registry == null || !cfg.runtime_ready) begin
		why = "table write requires published registry and PCIe environment";
		return;
	end

	if (!cfg.bar_registry.check_range(target, offset, length, address, why)) begin
		return;
	end

	if (address[11:0] + length > 4096 || (!cfg.rc_sequencers.exists(target.rc_slot) || cfg.rc_sequencers[target.rc_slot] == null)) begin
		why = "table write crosses 4KB or has no RC sequencer";
		return;
	end

	for (int	dword = int'(length / 4) - 1; dword >= 0; dword--) begin
		mmio(
			target, 1, offset + 4 * dword, 4,
			128'(data[dword * 32 +: 32]), 0, ignored, ok, why
		);

		if (!ok) begin
			return;
		end
	end
endtask


// 名字解析与实际 Function API 复用同一个范围/格式检查。
task project_dut_config_seq::pcie_bar_read_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [31:0]	byte_skip_mask,
	output logic [127:0]	data,
	output bit		ok,
	output string		why
);
	project_bar_target_t	target;
	ok = 0;
	data = '0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_name(name, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask


// 有界显式轮询；比较 mask 与 byte skip-mask 是不同概念，不在后台自动读状态。
task project_dut_config_seq::pcie_poll_bar(
	input dpu_function_key_t	owner,
	input int unsigned		bar_id,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		mask,
	input logic [127:0]		expected,
	input int unsigned		attempts,
	input time			interval,
	output bit			ok,
	output string			why
);
	logic [127:0]	data;
	ok = 0;
	why = "poll needs finite attempts and known comparison";
	if (attempts == 0 || $isunknown({mask, expected})) return;
	for (int unsigned i = 0; i < attempts; i++) begin
		pcie_bar_read(owner, bar_id, offset, length, 0, data, ok, why);
		if (!ok) return;
		if ((data & mask) === (expected & mask)) return;
		if (i + 1 < attempts) #(interval);
	end
	ok = 0;
	why = "BAR poll exhausted attempts";
endtask


// 检查表项绑定与字段宽度；仅 enabling 改变声明的 enable/mask 位。
// 单个配置 sequence 按顺序调用，VTX/VRX 不插入其他表访问。
// 每项先高到低逐 DWORD 写；VTX/VRX 的四笔数据全部成功后才发 clear/trigger。
task project_dut_config_seq::checked_write(
	input project_config_record_t	record,
	input logic [127:0]		value,
	input bit			enabling,
	output bit			ok,
	output string			why
);
	project_config_record_t	original;
	project_table_layout_t	layout;
	logic [127:0]		ignored;
	logic [127:0]		expected;
	bit [63:0]		address;
	bit [63:0]		offset;
	logic [31:0]		control;
	ok = 0;
	why = "checked table write has no matching frozen record";
	if (!cfg.records.exists(record.ctx.record_key)) return;
	original = cfg.records[record.ctx.record_key];
	expected = enabling ? (original.entry & ~original.enable_mask) | original.enable_value : original.entry;
	if (record.ctx !== original.ctx || record.has_queue != original.has_queue ||
		!dpu_same_function_key(record.owner, original.owner) ||
		(record.has_queue && record.binding !== original.binding) || $isunknown(value) || value !== expected) begin
		why = "checked table context/binding/entry differs from immutable export";
		return;
	end
	if (record.has_queue) begin
		vio_config_scope	local_scope;
		dpu_service_key_t	keys[$];
		keys.push_back(record.binding.service_key);
		local_scope = new("write_scope", cfg.vio_setups[record.owner.host_id], keys);
		if (!cfg.vio_envs[record.owner.host_id].preflight_external_configuration(cfg.vio_setups[record.owner.host_id], local_scope, why)) return;
	end
	layout = original.ctx.layout;
	if (!cfg.bar_registry.check_range(original.ctx.target, original.ctx.byte_offset, layout.entry_bytes, address, why)) return;
	if (layout.indirect) begin
		offset = layout.module_offset + layout.data_port;
		if (!cfg.bar_registry.check_range(original.ctx.target, offset, layout.entry_bytes, address, why) ||
			!cfg.bar_registry.check_range(original.ctx.target, layout.module_offset + layout.control_port, 4, address, why)) return;
	end
	if (layout.indirect) begin

		write_table_dwords(original.ctx.target, offset, layout.entry_bytes, value, ok, why);
		control = layout.control_fixed | (original.ctx.table_index << layout.index_shift);

		if (ok) begin
			mmio(original.ctx.target, 1, layout.module_offset + layout.control_port,
				4, 128'(control), 0, ignored, ok, why);
		end

		if (ok) begin
			mmio(original.ctx.target, 1, layout.module_offset + layout.control_port,
				4, 128'(control | layout.trigger_mask), 0, ignored, ok, why);
		end

	end else begin
		write_table_dwords(original.ctx.target, original.ctx.byte_offset,
			layout.entry_bytes, value, ok, why);
	end
endtask


// bdf typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_bdf(
	input project_bdf_cfg_t	item,
	output bit		ok,
	output string		why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_BDF) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// completion_bdf typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_completion_bdf(
	input project_completion_bdf_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_COMPLETION_BDF) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// pfvf typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_pfvf(
	input project_pfvf_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_PFVF) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// tlp_prefix typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_tlp_prefix(
	input project_tlp_prefix_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_PREFIX) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_linear typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_linear(
	input project_msix_linear_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_LINEAR) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_info typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_info(
	input project_msix_info_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_INFO) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_interval typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_interval(
	input project_msix_interval_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_INTERVAL) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_table typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_table(
	input project_msix_table_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_TABLE) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_q2tc typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_q2tc(
	input project_qsch_q2tc_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_Q2TC) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_n2g typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_n2g(
	input project_qsch_n2g_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_N2G) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_g2p typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_g2p(
	input project_qsch_g2p_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_G2P) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// rdma_notify typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_rdma_notify(
	input project_rdma_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_RDMA_NOTIFY) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_rnet typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_rnet(
	input project_qsch_rnet_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_RNET) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// vtx typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_vtx(
	input project_vtx_cfg_t	item,
	output bit		ok,
	output string		why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_VTX) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// vrx typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_vrx(
	input project_vrx_cfg_t	item,
	output bit		ok,
	output string		why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_VRX) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// vio_notify typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_vio_notify(
	input project_vio_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_NOTIFY) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// 唯一 typed dispatch；不在单项 hook 中复制外围循环，也不隐含执行其他类别。
task project_dut_config_seq::dispatch_record(
	input project_config_record_t	record,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "unsupported table category";
	case (record.ctx.kind)
		PROJECT_BDF: begin
			project_bdf_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_bdf_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_bdf_entry(item, ok, why);
		end
		PROJECT_COMPLETION_BDF: begin
			project_completion_bdf_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_completion_bdf_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_completion_bdf_entry(item, ok, why);
		end
		PROJECT_PFVF: begin
			project_pfvf_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_pfvf_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_pf_vf_entry(item, ok, why);
		end
		PROJECT_PREFIX: begin
			project_tlp_prefix_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_tlp_prefix_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_tlp_prefix_entry(item, ok, why);
		end
		PROJECT_MSIX_LINEAR: begin
			project_msix_linear_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_linear_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_linear_entry(item, ok, why);
		end
		PROJECT_MSIX_INFO: begin
			project_msix_info_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_info_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_info_entry(item, ok, why);
		end
		PROJECT_MSIX_INTERVAL: begin
			project_msix_interval_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_interval_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_interval_entry(item, ok, why);
		end
		PROJECT_MSIX_TABLE: begin
			project_msix_table_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_table_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_table_entry(item, ok, why);
		end
		PROJECT_Q2TC: begin
			project_qsch_q2tc_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_q2tc_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_q2tc(item, ok, why);
		end
		PROJECT_N2G: begin
			project_qsch_n2g_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_n2g_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_n2g(item, ok, why);
		end
		PROJECT_G2P: begin
			project_qsch_g2p_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_g2p_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_g2p(item, ok, why);
		end
		PROJECT_RDMA_NOTIFY: begin
			project_rdma_notify_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_rdma_notify_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_rdma_notify_entry(item, ok, why);
		end
		PROJECT_RNET: begin
			project_qsch_rnet_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_rnet_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_rnet_entry(item, ok, why);
		end
		PROJECT_VTX: begin
			project_vtx_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_vtx_entry_t'(record.entry);
			item.binding = record.binding;
			user_configure_vtx_queue(item, ok, why);
		end
		PROJECT_VRX: begin
			project_vrx_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_vrx_entry_t'(record.entry);
			item.binding = record.binding;
			user_configure_vrx_queue(item, ok, why);
		end
		PROJECT_NOTIFY: begin
			project_vio_notify_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_vio_notify_entry_t'(record.entry);
			item.binding = record.binding;
			user_configure_vio_notify_entry(item, ok, why);
		end
		PROJECT_QUEUE_AUX: begin
			project_queue_control_cfg_t	item;
			item.ctx = record.ctx;
			item.binding = record.binding;
			item.value = record.entry;
			item.writable_mask = cfg.platform_control_mask(record);
			user_configure_queue_aux(item, ok, why);
		end
		PROJECT_BAR: begin
			project_bar_mapping_cfg_t	item;
			item = cfg.frozen_bar_groups[record.ctx.table_index];
			item.ctx = record.ctx;
			user_configure_bar_mapping_entry(item, ok, why);
		end
		default: begin
			project_control_cfg_t	item;
			item.ctx = record.ctx;
			item.owner = record.owner;
			item.consumers = record.consumers;
			item.consumers_complete = 1;
			item.value = record.entry;
			item.writable_mask = cfg.platform_control_mask(record);
			case (record.ctx.kind)
				PROJECT_AF: user_configure_af(item, ok, why);
				PROJECT_MSIX_CONTROL: user_configure_msix_control_entry(item, ok, why);
				PROJECT_MSIX_FUNCTION: user_configure_msix_function(item, ok, why);
				PROJECT_SPWRR: user_configure_qsch_spwrr(item, ok, why);
				PROJECT_TC_WEIGHT: user_configure_qsch_tc_weight(item, ok, why);

				default: ;
			endcase
		end
	endcase
endtask


// 公共控制 hook 可复用同一 checked 路径；mask 和消费者也必须匹配原件。
task project_dut_config_seq::write_control(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "control has no matching frozen record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (!(r.ctx.kind inside {PROJECT_AF, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION, PROJECT_SPWRR, PROJECT_TC_WEIGHT}) ||
		item.writable_mask !== cfg.platform_control_mask(r) || item.consumers != r.consumers) return;
	r.ctx = item.ctx;
	r.owner = item.owner;
	checked_write(r, item.value, 0, ok, why);
endtask


// 辅助项有实际 ring 绑定，不能借控制 payload 修改另一个 pair。
task project_dut_config_seq::write_queue_aux(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "queue auxiliary control has no matching frozen record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (r.ctx.kind != PROJECT_QUEUE_AUX || item.writable_mask !== cfg.platform_control_mask(r)) return;
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, item.value, 0, ok, why);
endtask


// 先生成所选公共表，再逐项调用用户 hook；同一硬件项只写一次，失败立即停止。
task project_dut_config_seq::configure_public(
	input project_table_kind_e	kinds[$],
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_config_record_t	selected[$];
	project_config_record_t	batch[$];
	bit			seen[string];

	ok = 0;
	foreach (kinds[k]) begin
		if (!cfg.public_records(kinds[k], scope, selected, why)) return;
		foreach (selected[i]) batch.push_back(selected[i]);
	end
	foreach (batch[i]) if (!cfg.remember_record(batch[i], why)) return;

	foreach (batch[i]) begin
		string	key;

		key = batch[i].ctx.record_key;
		if (seen.exists(key)) continue;
		seen[key] = 1;
		dispatch_record(cfg.records[key], ok, why);
		if (!ok) begin
			why = {key, ": ", why};
			return;
		end
	end
	ok = 1;
	why = "";
endtask


// 按实际 service/qpair 遍历；共享 QSCH 项去重，TX-only 不生成 VRX 写入。
task project_dut_config_seq::configure_queues(
	input project_table_kind_e	kinds[$],
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_config_record_t	batch[$];
	bit			seen[string];

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;
	foreach (batch[i]) if (!cfg.remember_record(batch[i], why)) return;

	foreach (batch[i]) begin
		string	key;

		key = batch[i].ctx.record_key;
		if (seen.exists(key)) continue;
		seen[key] = 1;
		dispatch_record(cfg.records[key], ok, why);
		if (!ok) begin
			why = {key, ": ", why};
			return;
		end
	end
	ok = 1;
	why = "";
endtask


// 写表完成后逐队列使能；平台 task 返回失败时不再处理下一条队列。
task project_dut_config_seq::enable_vio_queues(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_config_record_t		batch[$];
	project_table_kind_e		kinds[$] = '{PROJECT_VTX, PROJECT_VRX};
	project_queue_control_cfg_t	item;

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;
	foreach (batch[i]) if (!cfg.remember_record(batch[i], why)) return;

	foreach (batch[i]) begin
		item.ctx = batch[i].ctx;
		item.binding = batch[i].binding;
		item.value = (batch[i].entry & ~batch[i].enable_mask) | batch[i].enable_value;
		item.writable_mask = batch[i].enable_mask;
		user_enable_queue(item, ok, why);
		if (!ok) return;
	end
	ok = 1;
	why = "";
endtask


// 公共配置写完后交由平台读回或检查状态；不将 posted 发送完成当成硬件生效。
task project_dut_config_seq::verify_dpu_configuration(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "public verification scope is missing";
	if (scope == null) return;
	if (!scope.validate(cfg.dpu_setup, why)) return;

	user_verify_dpu_configuration(scope, ok, why);
endtask


// BDF 与 MSI-X 已从其他公共配置独立；可选读回只覆盖本次真正选中的数据表。
// 空 scope 表示该类别未执行，不能构造空 Function 列表来意外验证全部 Function。
// 每条记录按实际 BAR 和宽度读取；任一不符立即返回，不使能后续 VIO 队列。
task project_dut_config_seq::verify_function_configuration(
	input project_dpu_config_scope	bdf_scope,
	input project_dpu_config_scope	msix_scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_BDF, PROJECT_MSIX_LINEAR,
		PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_TABLE};
	project_config_record_t	batch[$];
	project_dpu_config_scope	scope;
	bit			seen[string];
	logic [127:0]		readback;

	ok = 0;
	foreach (kinds[k]) begin
		scope = kinds[k] == PROJECT_BDF ? bdf_scope : msix_scope;
		if (scope == null) continue;
		if (!cfg.public_records(kinds[k], scope, batch, why)) return;
		foreach (batch[i]) begin
			if (seen.exists(batch[i].ctx.record_key)) continue;
			seen[batch[i].ctx.record_key] = 1;
			mmio(batch[i].ctx.target, 0, batch[i].ctx.byte_offset,
				batch[i].ctx.layout.entry_bytes, 0, 0, readback, ok, why);
			if (!ok) return;
			if (readback !== batch[i].entry) begin
				ok  = 0;
				why = $sformatf("readback mismatch %s BAR offset=0x%016h expected=%032h actual=%032h",
					batch[i].ctx.record_key, batch[i].ctx.byte_offset, batch[i].entry, readback);
				return;
			end
		end
	end

	ok  = 1;
	why = "";
endtask


// 队列配置写完后执行平台验证；成功后默认 body 才调用 cfg.commit_vio_configuration。
task project_dut_config_seq::verify_vio_configuration(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	ok = 0;
	if (!cfg.preflight_vio(selection, why)) return;

	user_verify_vio_configuration(selection, ok, why);
endtask


// queue enable 只能更新已声明的 enable 位，仅改变平台声明的 enable 位。
task project_dut_config_seq::write_enabled_queue(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "queue enable has no frozen typed record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (!r.has_queue || !(r.ctx.kind inside {PROJECT_VTX, PROJECT_VRX}) ||
		item.writable_mask !== r.enable_mask) return;
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, item.value, 1, ok, why);
endtask


// PBA 是只读字；读取整个64位值，不把总容量从结构体宽度推断出来。
task project_dut_config_seq::read_msix_pba(
	input project_state_query_t	item,
	output project_msix_pba_word_t	value,
	output bit			ok,
	output string			why
);
	project_state_query_t	canonical;
	logic [127:0]		data;
	ok = 0;
	value = '0;
	if (!cfg.get_state_context(PROJECT_MSIX_PBA, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "PBA context differs from frozen layout"; return; end
	mmio(item.ctx.target, 0, item.ctx.byte_offset, 8, 0, 0, data, ok, why);
	if (ok) value.pending = data[63:0];
endtask


// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
task project_dut_config_seq::read_msix_stat(
	input project_state_query_t	item,
	output project_msix_stat_t	value,
	output bit			ok,
	output string			why
);
	project_state_query_t	canonical;
	ok = 0;
	value = '0;
	if (!cfg.get_state_context(PROJECT_MSIX_STAT, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "state context differs from frozen layout"; return; end
	user_read_msix_stat(item, value, ok, why);
endtask


// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
task project_dut_config_seq::user_read_msix_stat(
	input project_state_query_t	item,
	output project_msix_stat_t	value,
	output bit			ok,
	output string			why
);
	value = '0;
	ok = 0;
	why = "required user_read_msix_stat is not implemented";
endtask


// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
task project_dut_config_seq::read_pfvf_drop_status(
	input project_state_query_t		item,
	output project_pfvf_drop_status_t	value,
	output bit				ok,
	output string				why
);
	project_state_query_t	canonical;
	ok = 0;
	value = '0;
	if (!cfg.get_state_context(PROJECT_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "state context differs from frozen layout"; return; end
	user_read_pfvf_drop_status(item, value, ok, why);
endtask


// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
task project_dut_config_seq::user_read_pfvf_drop_status(
	input project_state_query_t		item,
	output project_pfvf_drop_status_t	value,
	output bit				ok,
	output string				why
);
	value = '0;
	ok = 0;
	why = "required user_read_pfvf_drop_status is not implemented";
endtask


// 显式 clear_mask 与状态值类型隔离；未知态、错误目标在用户 hook 前拒绝。
task project_dut_config_seq::clear_pfvf_drop_status(
	input project_pfvf_drop_clear_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_state_query_t	canonical;
	ok = 0;
	if (!cfg.get_state_context(PROJECT_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx || $isunknown(item.entry)) begin why = "invalid W1C context/mask"; return; end
	user_clear_pfvf_drop_status(item, ok, why);
endtask


// 清除由用户显式执行；不把读出的 status 自动回写。
task project_dut_config_seq::user_clear_pfvf_drop_status(
	input project_pfvf_drop_clear_cfg_t	item,
	output bit				ok,
	output string				why
);
	ok = 0;
	why = "required user_clear_pfvf_drop_status is not implemented";
endtask
```

## `integration/project/project_single_queue_config_seq.sv`

SHA-256: `0839c6ac1ecb1e0bf88fed249c6aba18594ae69d0b41bcacbb580826e63d9862`

```systemverilog
// integration/project：单 Host/PF0、一对 Packed 队列的固定 VTX 联调配置入口。
// 依赖 project_dut_config_seq 的真实 PCIe 写表流程；本类写死表偏移与策略，不依赖平台布局输入。
// cfg/env 仍拥有 BDF/BAR、队列和 DMA ring；本 seq 借用这些资源，不重建冻结拓扑或伪造地址。
// build 前必须选择 Packed256/Polling/TX-only 和 BAR0 offset0 DPU32 Notify；不支持运行期改模式。
class project_single_queue_config_seq extends project_dut_config_seq;
	`uvm_object_utils(project_single_queue_config_seq)

	// 构造独立入口，不改变原 project_dut_config_seq 的行为。
	extern function new(string name = "project_single_queue_config_seq");
	// 校验已分配资源后安装固定表/策略，再复用真实配置、使能和失败传播流程。
	extern virtual task body();
	// 固定基线只接受实际的一 Host/PF0/一 pair；冻结合同不匹配时返回具体原因。
	extern protected function bit prepare_fixed_configuration(output string why);
	// 把明确的驱动偏移同时写到输入与冻结视图；仅本入口使用，目标固定 h0.pf0.bar0。
	extern protected function void fixed_layout(
		input project_table_kind_e	kind,
		input logic [63:0]		module_offset,
		input logic [63:0]		table_offset,
		input int unsigned		bytes,
		input int unsigned		capacity,
		input project_index_policy_e	index_policy
	);
endclass

// 对象只保存执行状态；共享资源由 cfg/env 管理。
function project_single_queue_config_seq::new(string name);
	super.new(name);
endfunction

// 先检查冻结的软件模式，避免 DUT 写成 Packed 而 driver 仍运行另一种格式。
task project_single_queue_config_seq::body();
	if (!prepare_fixed_configuration(error_msg)) begin
		error_msg = {"single_queue_baseline: ", error_msg};
		return;
	end
	super.body();
endtask

// 使用同一个固定管理窗口；VTX 间接端口在调用后单独补齐，其余都是线性 DWORD 表。
function void project_single_queue_config_seq::fixed_layout(
	input project_table_kind_e	kind,
	input logic [63:0]		module_offset,
	input logic [63:0]		table_offset,
	input int unsigned		bytes,
	input int unsigned		capacity,
	input project_index_policy_e	index_policy
);
	cfg.table_layouts[kind] = '{
		provided:1, reg_target:"h0.pf0.bar0", module_offset:module_offset, table_offset:table_offset,
		entry_bytes:bytes, capacity:capacity, index_policy:index_policy, required:1, default:0
	};
	cfg.frozen_layouts[kind] = cfg.table_layouts[kind];
endfunction

// 固定寄存器偏移和策略，BAR base/global qid/ring IOVA 保留实际分配值。
// 所有检查都在首笔 Memory Write 前完成；通信失败仍由父类原样报告，不跳过或伪造成功。
function bit project_single_queue_config_seq::prepare_fixed_configuration(output string why);
	dpu_host_info_t			hosts[$];
	dpu_function_key_t		functions[$];
	dpu_vio_qpair_binding_t		pairs[$];
	dpu_function_key_t		pf0;
	dpu_function_key_t		requester_owner;
	dpu_pcie_function_id_t		requester_pcie_id;
	vio_service_requirement_t	requirement;
	project_vio_policy_t		policy;
	project_function_policy_t	function_policy;
	project_bar_target_t		target;
	string				name;

	pf0 = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
	why = "expected published Host0/PF0/no-VF with exactly one VIO pair";
	if (cfg.device_snapshot == null || cfg.resource_snapshot == null || cfg.bar_registry == null) return 0;
	if (!cfg.vio_cfg_by_host.exists(0) || cfg.vio_cfg_by_host[0] == null) return 0;
	cfg.device_snapshot.list_hosts(hosts);
	cfg.device_snapshot.list_functions(functions);
	cfg.resource_snapshot.list_vio_bindings(pairs);
	if (hosts.size() != 1 || functions.size() != 1 || pairs.size() != 1) begin
		why = $sformatf("expected hosts/functions/pairs=1/1/1, actual=%0d/%0d/%0d",
			hosts.size(), functions.size(), pairs.size());
		return 0;
	end
	if (hosts[0].host_id != 0 || !dpu_same_function_key(functions[0], pf0) ||
		!dpu_same_function_key(pairs[0].service_key.function_key, pf0) || pairs[0].virtio_pair_index != 0) return 0;
	if (!cfg.vio_cfg_by_host[0].resolve_final_service_requirement(pairs[0].service_key, requirement, why)) return 0;
	if (!requirement.enabled || !requirement.tx_enable || requirement.rx_enable ||
		requirement.behavior.num_queue_pairs != 1 || requirement.behavior.vq_type != VQ_PACKED ||
		requirement.behavior.queue_size != 256 || requirement.completion_mode != VIRTIO_COMPLETION_POLLING ||
		!requirement.notify_layout_valid || requirement.notify_bar != 0 || requirement.notify_base != 0 ||
		requirement.notify_stride != 0 || requirement.notify_encoding != VIO_NOTIFY_DPU32) begin
		why = $sformatf({"expected enabled Packed256/Polling/TX-only/1pair, BAR0+0 DPU32 Notify; ",
			"actual enabled=%0b tx/rx=%0b/%0b pairs=%0d type=%s size=%0d completion=%s ",
			"notify_valid=%0b bar=%0d base=%h stride=%h encoding=%s"},
			requirement.enabled, requirement.tx_enable, requirement.rx_enable, requirement.behavior.num_queue_pairs,
			requirement.behavior.vq_type.name(), requirement.behavior.queue_size, requirement.completion_mode.name(),
			requirement.notify_layout_valid, requirement.notify_bar, requirement.notify_base, requirement.notify_stride,
			requirement.notify_encoding.name());
		return 0;
	end
	if (!cfg.bar_registry.resolve_name("h0.pf0.bar0", target, why)) return 0;
	name = dpu_function_key_name(pf0);
	why = "expected actual PF0 EP route requester=0/intel_pf=0/no-VF/vport=0";
	if (!cfg.frozen_functions.exists(name)) return 0;
	function_policy = cfg.frozen_functions[name];
	if (target.route.pf_index != 0 || target.route.is_vf ||
		function_policy.mode != PROJECT_HOST_EP || function_policy.requester != 0 ||
		function_policy.intel_pf != 0 || function_policy.intel_vf != -1 || function_policy.vport != 0) return 0;
	// EP requester 编码与资源分配的 PCI BDF 独立；允许 bdf_first=16 等真实分配起点。
	if (!cfg.bar_registry.resolve_requester(0, 0, requester_owner, requester_pcie_id, why)) return 0;
	if (!dpu_same_function_key(requester_owner, pf0)) begin
		why = "requester 0 does not resolve to the actual Host0/PF0 registry owner";
		return 0;
	end

	// 固定只下 AF、BDF、Notify、QSCH 和 VTX；Polling 不创建 MSI-X 表或 BAR/PFVF 公共表。
	cfg.configure_public        = 0;
	cfg.configure_bdf           = 1;
	cfg.verify_readback         = 0;
	cfg.reg_target              = "h0.pf0.bar0";
	cfg.frozen_reg_target       = "h0.pf0.bar0";
	cfg.qsch_configure_controls = 1;
	cfg.qsch_mode               = 0;
	cfg.qsch_mode_offset        = 'hb001c0;
	cfg.qsch_spwrr              = 'hff;
	cfg.qsch_tc_weight          = 'h11111111;
	cfg.platform_controls.delete();
	function_policy.bdf_index = 0;
	function_policy.ecrc      = 0;
	function_policy.vdpa      = 0;
	cfg.function_policies[name] = function_policy;
	cfg.frozen_functions[name] = function_policy;

	fixed_layout(PROJECT_BDF, 'h100000, 'h8000, 4, 128, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_NOTIFY, 'h080000, 'h20000, 16, 512, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_Q2TC, 'hb00000, 'h10000, 4, 2048, PROJECT_INDEX_GLOBAL_QPAIR);
	fixed_layout(PROJECT_N2G, 'hb00000, 'h12000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_G2P, 'hb00000, 'h14000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_SPWRR, 'hb00000, 'h16000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_TC_WEIGHT, 'hb00000, 'h18000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_VTX, 'h880000, 'h10000, 16, 2048, PROJECT_INDEX_GLOBAL_QPAIR);
	cfg.table_layouts[PROJECT_VTX].indirect     = 1;
	cfg.table_layouts[PROJECT_VTX].data_port    = 'h134;
	cfg.table_layouts[PROJECT_VTX].control_port = 'h130;
	cfg.table_layouts[PROJECT_VTX].index_mask   = 'h7ff;
	cfg.table_layouts[PROJECT_VTX].trigger_mask = 'h2000;
	cfg.frozen_layouts[PROJECT_VTX] = cfg.table_layouts[PROJECT_VTX];

	policy = '{service_key:pairs[0].service_key, prefetch_ram:"", net_stride:1, eth_ports:8,
		notify_net_pair5:1, notify_table_base_provided:1, default:0};
	cfg.vio_policies[dpu_service_key_name(policy.service_key)] = policy;
	cfg.frozen_policies = cfg.vio_policies;
	why = "";
	return 1;
endfunction
```

## `integration/project/project_env.sv`

SHA-256: `699390c3212017232d83d082c34ed4a942d993a181041bce0390ec101e5ca2cb`

```systemverilog
// integration/project：项目组件组装；仅继承 uvm_env，不承担寄存器写表。
// 依赖同包 cfg/registry/RC driver 与 DPU、PCIe TL、Intel adapter、VIO。
// env 拥有子组件，cfg 持有同一仿真期的借用句柄、冻结资源和配置状态。
// connect 发布到同一个 cfg；配置 seq 从 PCIe sequencer 的 config_db 取得它。
// 每 Host 一个 Intel RC，PF/VF 共用；VIO 挂在 DPU 子树保证快照先发布。
class project_env extends uvm_env;
	`uvm_component_utils(project_env)

	project_env_cfg	cfg;
	dpu_device_env	dpu_env;
	pcie_tl_env	pcie_env;
	virtio_net_env	vio_envs[int unsigned];
	host_mem_pool	shared_pool;

	local bit	tx_observation_bound[int unsigned];

	// 首次成功发布后才打印，重复同快照幂等，新拓扑要求 rebuild 而不留下新旧路由混合。
	extern function void publish_dpu_configuration(
		output bit	ok,
		output string	why
	);

	// EOE 与晚首次发布共用同一检查；自动打印去重由 registry 维护。
	extern virtual function void end_of_elaboration_phase(
		uvm_phase	phase
	);

	// 构造组件壳；配置与共享资源延迟到 build，允许 test 先注入平台对象。
	extern function	new(
		string		name,
		uvm_component	parent
	);

	// 按 UVM 顺序建立 DPU、PCIe 和 VIO；缺 cfg 或绑定冲突立即报错。
	extern virtual function void	build_phase(
		uvm_phase	phase
	);

	// 子环境构建完毕后绑定快照、协议接口和 Function endpoint；拒绝跨 Host 错配。
	extern virtual function void	connect_phase(
		uvm_phase	phase
	);

	// 每次仿真登记一次各 Host 的 VIO 服务及 Tcl 命令；空服务或重复注册会报错。
	extern function void	register_aip_commands();

	// 准备或借用各 Host 的共享内存，校验已有 manager 的身份、范围与分配策略。
	extern protected function void	prepare_host_memory();

	// 根据 Host→slot 映射设置 RC 数量和内存绑定，校验 Intel 真实 DUT 接入约束。
	extern protected function void	prepare_pcie_config();

	// 在 PCIe build 前解析各端口的 cfg/VIF，借用 wrapper 对象并拒绝缺失或复用。
	extern protected function void	prepare_intel_bindings();

	// 连接阶段核对实际 adapter、cfg/VIF 句柄及 RC-only 组件树，不再补绑接口。
	extern protected function void	check_intel_bindings();

	// 按完整 Function 身份分配协议 VIF，拒绝空接口以及跨 Host/Function 复用。
	extern protected function void	bind_protocol_vifs();
endclass


// 构造项目组件壳；资源创建延迟到 build，以允许 test 注入已有平台对象。
function	project_env::new(
	string		name,
	uvm_component	parent
);
	super.new(name, parent);
endfunction


// 为每个 Host 准备唯一 manager；DPU 的 GPA limit 是开区间，pool end 是闭区间。
// 已有 manager 必须覆盖声明 aperture 且策略一致，不重置已有分配/数据。
function void	project_env::prepare_host_memory();
	host_mem_pool	dpu_pool;

	shared_pool = cfg.host_mem_pool_binding;

	if (cfg.dpu_cfg.host_mem_pool_ref != null) begin
		if (!$cast(dpu_pool, cfg.dpu_cfg.host_mem_pool_ref)) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"DPU memory owner is not a host_mem_pool"
			)
		end

		if (shared_pool != null && shared_pool != dpu_pool) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"project and DPU specify distinct Host pools"
			)
		end

		shared_pool = dpu_pool;
	end

	if (shared_pool == null) begin
		shared_pool = host_mem_pool::type_id::create("shared_pool");
	end

	foreach (cfg.dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg		host;
		virtio_net_env_config	vio;
		host_mem_manager	manager;

		host = cfg.dpu_cfg.device_cfg.hosts[i];

		if (
			host == null ||
			!host.has_gpa_aperture ||
			host.gpa_limit <= host.gpa_base
		) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"each Host requires a nonempty GPA aperture"
			)
		end

		if (!cfg.vio_cfg_by_host.exists(host.host_id)) begin
			`uvm_fatal("PROJECT_ENV", "Host has no VIO behavior configuration")
		end

		vio = cfg.vio_cfg_by_host[host.host_id];

		if (!shared_pool.has_host(host.host_id)) begin
			if (!shared_pool.create_host(
				host.host_id,
				host.gpa_base,
				host.gpa_limit - 1,
				cfg.host_mem_mode,
				cfg.host_mem_granule,
				vio.host_mem_policy
			)) begin
				`uvm_fatal("PROJECT_ENV", "could not initialize Host memory")
			end
		end

		manager = shared_pool.get_host(host.host_id);

		if (
			!manager.is_initialized() ||
			manager.get_host_id() != host.host_id ||
			!manager.contains_range(host.gpa_base, host.gpa_limit - host.gpa_base) ||
			manager.get_alloc_policy() != vio.host_mem_policy
		) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"existing Host memory disagrees with configured aperture/policy"
			)
		end

		if (
			vio.host_mem_binding != null ||
			(vio.host_mem_pool_binding != null && vio.host_mem_pool_binding != shared_pool)
		) begin
			`uvm_fatal("PROJECT_ENV", "Host VIO cfg must borrow the project-owned pool")
		end

		vio.host_mem_pool_binding = shared_pool;
		vio.mem_base              = host.gpa_base;
		vio.mem_end               = host.gpa_limit - 1;
	end

	cfg.host_mem_pool_binding     = shared_pool;
	cfg.dpu_cfg.host_mem_pool_ref = shared_pool;
endfunction


// 按显式 Host→slot 准备 TL cfg；只借用同一 Host manager，不复制 BDF/BAR。
// 每 Host 只保留一个 RC，EP 和配置空间/MMIO 响应来自真实 DUT。
// 既有绑定只校验不重建；Switch、多余绑定或不同 manager 都拒绝。
function void	project_env::prepare_pcie_config();
	string	why;

	if (!cfg.validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end

	if (cfg.pcie_cfg.switch_enable) begin
		`uvm_fatal("PROJECT_ENV", "Intel project reference does not create a Switch")
	end

	cfg.pcie_cfg.rc_agent_enable = 1;
	cfg.pcie_cfg.num_rc          = cfg.tl_slot_by_host.num();

	if (
		cfg.vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT ||
		cfg.pcie_cfg.if_mode != SV_IF_MODE ||
		!cfg.pcie_cfg.infinite_credit ||
		cfg.pcie_cfg.rc_is_active != UVM_ACTIVE ||
		cfg.pcie_cfg.ep_auto_response ||
		!cfg.pcie_cfg.use_unified_mem
	) begin
		`uvm_fatal(
			"PROJECT_INTEL",
			"Intel requires REAL_DUT, SV_IF_MODE, active RC, unified memory and infinite public FC"
		)
	end

	cfg.pcie_cfg.ep_agent_enable = 0;
	cfg.pcie_cfg.num_ep          = 0;

	if (cfg.pcie_cfg.ep_root_by_index.num() != 0) begin
		`uvm_fatal("PROJECT_INTEL", "real EP DUT must not have VIP EP-to-Root bindings")
	end

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned		slot;
		host_mem_manager	manager;

		slot    = cfg.tl_slot_by_host[h];
		manager = shared_pool.get_host(h);

		if (cfg.pcie_cfg.host_mem_by_root.exists(slot)) begin
			if (
				cfg.pcie_cfg.host_mem_by_root[slot] != manager ||
				!cfg.pcie_cfg.host_id_by_root.exists(slot) ||
				cfg.pcie_cfg.host_id_by_root[slot] != h
			) begin
				`uvm_fatal(
					"PROJECT_ENV",
					"PCIe Host memory binding disagrees with DPU owner"
				)
			end
		end else if (!cfg.pcie_cfg.bind_host_memory(slot, h, manager, why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end
	end

	if (cfg.pcie_cfg.host_mem_by_root.num() != cfg.tl_slot_by_host.num()) begin
		`uvm_fatal("PROJECT_ENV", "extra PCIe Root bindings are not part of this project")
	end
endfunction


// 在 pcie_env::create 前解析每个端口的配置和 VIF：cfg 显式句柄与 wrapper 发布值
// 必须相同；只缺配置时可创建 HARD_IP 默认对象，缺 HDL 接口则不能自动补造。
// 复用 wrapper 对象以保留端口压力/信用设置，拒绝跨端口共享可变 cfg 或物理 VIF。
function void	project_env::prepare_intel_bindings();
	intel_pcie_adapter_config	used_cfgs[$];
	intel_pcie_vif_t		used_vifs[$];

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned			slot;
		string				path;
		intel_pcie_adapter_config	port_cfg;
		intel_pcie_adapter_config	published_cfg;
		intel_pcie_vif_t		vif;
		intel_pcie_vif_t		published_vif;

		slot          = cfg.tl_slot_by_host[h];
		path          = $sformatf("pcie_env.rc_adapter_%0d", slot);
		port_cfg      = null;
		published_cfg = null;
		vif           = null;
		published_vif = null;

		if (cfg.intel_cfg_by_slot.exists(slot)) begin
			port_cfg = cfg.intel_cfg_by_slot[slot];

			if (port_cfg == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel cfg is null")
			end
		end

		if (uvm_config_db#(intel_pcie_adapter_config)::get(
			this,
			path,
			"intel_cfg",
			published_cfg
		)) begin
			if (
				published_cfg == null ||
				(port_cfg != null && port_cfg != published_cfg)
			) begin
				`uvm_fatal(
					"PROJECT_INTEL",
					"project and wrapper publish different Intel cfg handles"
				)
			end

			port_cfg = published_cfg;
		end

		if (port_cfg == null) begin
			port_cfg = intel_pcie_adapter_config::type_id::create(
				$sformatf("intel_cfg_%0d", slot)
			);

			port_cfg.side = INTEL_PCIE_HARD_IP;
		end

		if (port_cfg.side != INTEL_PCIE_HARD_IP) begin
			`uvm_fatal(
				"PROJECT_INTEL",
				"EP application DUT requires explicit INTEL_PCIE_HARD_IP side"
			)
		end

		port_cfg.validate();

		if (cfg.intel_rc_vifs.exists(slot)) begin
			vif = cfg.intel_rc_vifs[slot];

			if (vif == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel VIF is null")
			end
		end

		if (uvm_config_db#(intel_pcie_vif_t)::get(
			this,
			path,
			"vif",
			published_vif
		)) begin
			if (
				published_vif == null ||
				(vif != null && vif != published_vif)
			) begin
				`uvm_fatal(
					"PROJECT_INTEL",
					"project and wrapper publish different Intel VIFs"
				)
			end

			vif = published_vif;
		end

		if (vif == null) begin
			`uvm_fatal(
				"PROJECT_INTEL",
				$sformatf("missing Intel VIF at %s.%s", get_full_name(), path)
			)
		end

		foreach (used_cfgs[i]) begin
			if (used_cfgs[i] == port_cfg || used_vifs[i] == vif) begin
				`uvm_fatal(
					"PROJECT_INTEL",
					"Intel cfg or VIF reused by distinct TL slots"
				)
			end
		end

		used_cfgs.push_back(port_cfg);
		used_vifs.push_back(vif);

		cfg.intel_cfg_by_slot[slot] = port_cfg;
		cfg.intel_rc_vifs[slot]     = vif;

		uvm_config_db#(intel_pcie_adapter_config)::set(
			this,
			path,
			"intel_cfg",
			port_cfg
		);

		uvm_config_db#(intel_pcie_vif_t)::set(
			this,
			path,
			"vif",
			vif
		);
	end

	if (
		cfg.intel_cfg_by_slot.num() != cfg.tl_slot_by_host.num() ||
		cfg.intel_rc_vifs.num() != cfg.tl_slot_by_host.num()
	) begin
		`uvm_fatal("PROJECT_INTEL", "Intel bindings contain an unused TL slot")
	end
endfunction


// connect 时只校验实际创建的 adapter，不再补绑接口；否则 adapter build 早已失败。
// 确认 instance override 和 bridge 生效，防止接口配置看似存在却仍走公共 TLM 回环。
function void	project_env::check_intel_bindings();
	if (
		!pcie_env.bridge_required ||
		pcie_env.ep_agent != null ||
		pcie_env.ep_agents.size() != 0 ||
		pcie_env.ep_adapter != null ||
		pcie_env.ep_adapters.size() != 0
	) begin
		`uvm_fatal(
			"PROJECT_INTEL",
			"Intel needs the external-pin bridge and RC-only component tree"
		)
	end

	foreach (cfg.intel_cfg_by_slot[slot]) begin
		intel_pcie_if_adapter	adapter;

		if (slot >= pcie_env.rc_adapters.size()) begin
			`uvm_fatal("PROJECT_INTEL", "Intel RC adapter slot is missing")
		end

		if (!$cast(adapter, pcie_env.rc_adapters[slot]) || adapter == null) begin
			`uvm_fatal("PROJECT_INTEL", "Intel instance factory override did not take effect")
		end

		if (
			adapter.cfg != cfg.intel_cfg_by_slot[slot] ||
			adapter.avst_vif != cfg.intel_rc_vifs[slot]
		) begin
			`uvm_fatal("PROJECT_INTEL", "Intel adapter consumed different cfg/VIF handles")
		end
	end
endfunction


// 这里只创建组件和发布输入，不提前查询 DPU snapshot，也不手动调用子组件 build。
// create(..., dpu_env) 让 VIO 位于 DPU 子树；框架先 build DPU，再 build VIO。
// PCIe 只需要 Host 内存和 TL cfg，可以与 DPU 同级，不依赖二者遍历先后顺序。
function void	project_env::build_phase(
	uvm_phase	phase
);

	super.build_phase(phase);

	if (
		!uvm_config_db#(project_env_cfg)::get(this, "", "cfg", cfg) ||
		cfg == null
	) begin
		`uvm_fatal("PROJECT_ENV", "project environment cfg is missing")
	end

	cfg.load_params();
	uvm_config_db#(project_env_cfg)::set(this, "pcie_env.*", "env_cfg", cfg);
	prepare_host_memory();
	prepare_pcie_config();

	uvm_config_db#(dpu_device_env_config)::set(
		this,
		"dpu_env",
		"cfg",
		cfg.dpu_cfg
	);

	dpu_env = dpu_device_env::type_id::create("dpu_env", this);

	prepare_intel_bindings();

	// bridge 的历史字段名含 svt，但这里只开启外部引脚传输，不创建 SVT/provider。
	intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env");
	foreach (cfg.tl_slot_by_host[h]) begin
		pcie_tl_rc_driver::type_id::set_inst_override(project_pcie_rc_driver::get_type(),
			$sformatf("pcie_env.rc_agent_%0d.driver", cfg.tl_slot_by_host[h]), this);
	end
	pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

	foreach (cfg.vio_cfg_by_host[h]) begin
		string	child_name;

		child_name = $sformatf("vio_h%0d", h);

		uvm_config_db#(virtio_net_env_config)::set(
			dpu_env,
			child_name,
			"cfg",
			cfg.vio_cfg_by_host[h]
		);

		vio_envs[h] = virtio_net_env::type_id::create(child_name, dpu_env);
	end
endfunction


// 全项目统一分配协议 VIF；显式身份映射优先，兼容 top 的全局 VIF slot 入口。
// 在 Function 绑定 PCIe 前拒绝空接口和跨 Host/Function 复用，不依赖各 Host 局部计数。
function void	project_env::bind_protocol_vifs();
	virtual virtio_protocol_event_if	used[$];
	virtual virtio_protocol_event_if	vif;
	int unsigned				slot;
	string					why;

	slot = 0;

	foreach (vio_envs[h]) begin
		foreach (vio_envs[h].function_instances[i]) begin
			virtio_function_instance	f;

			f = vio_envs[h].function_instances[i];

			if (!cfg.vio_cfg_by_host[h].get_protocol_event_vif(f.pcie_id, vif)) begin
				if (cfg.protocol_vifs.size() != 0) begin
					if (slot >= cfg.protocol_vifs.size()) begin
						`uvm_fatal("PROJECT_ENV", "protocol VIF pool is too small")
					end

					vif = cfg.protocol_vifs[slot];
				end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
					null,
					"uvm_test_top",
					$sformatf("protocol_event_vif_%0d", slot),
					vif
				)) begin
					`uvm_fatal("PROJECT_ENV", "global protocol VIF slot is missing")
				end

				if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why)) begin
					`uvm_fatal("PROJECT_ENV", why)
				end
			end

			if (vif == null) begin
				`uvm_fatal("PROJECT_ENV", "protocol VIF is null")
			end

			foreach (used[j]) begin
				if (used[j] == vif) begin
					`uvm_fatal("PROJECT_ENV", "protocol VIF reused by distinct Functions/Hosts")
				end
			end

			used.push_back(vif);
			slot++;
		end
	end
endfunction


// connect 自底向上运行，此时 DPU 快照和 PCIe/VIO 子组件均已完成 build/connect。
// 从 Function 的完整身份选择 Host 对应的 TL slot；BDF/BAR 不在 PCIe 中重新分配。
function void	project_env::connect_phase(
	uvm_phase	phase
);
	super.connect_phase(phase);

	if (
		pcie_env.global_cfg != null ||
		pcie_env.topology_adapter != null ||
		pcie_env.backend_provider_active ||
		pcie_env.cfg != cfg.pcie_cfg
	) begin
		`uvm_fatal("PROJECT_ENV", "Intel project requires the direct PCIe cfg-only path")
	end

	check_intel_bindings();
	bind_protocol_vifs();

	begin
		bit	ok;
		string	why;
		publish_dpu_configuration(ok, why);
		if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
	end

	foreach (vio_envs[h]) begin
		virtio_pcie_function_endpoint	endpoints[$];
		int unsigned			slot;

		slot = cfg.tl_slot_by_host[h];

		if (slot >= pcie_env.rc_agents.size() || pcie_env.rc_agents[slot] == null) begin
			`uvm_fatal("PROJECT_ENV", "Host has no native RC agent")
		end

		foreach (vio_envs[h].function_instances[i]) begin
			virtio_function_instance	f;
			virtio_pcie_function_endpoint	endpoint;

			f = vio_envs[h].function_instances[i];

			if (f.pcie_id.domain.host_id != h || f.pcie_id.domain.segment_id != 0) begin
				`uvm_fatal("PROJECT_ENV", "Function does not belong to its Host segment 0")
			end

			endpoint = virtio_pcie_function_endpoint::type_id::create(
				$sformatf("endpoint_h%0d_f%0d", h, i)
			);

			// Completion 由 PCIe RC driver 接收；无模型 completion adapter 或 EP monitor。
			// 同 Host 的所有 Function 共用该 RC，完整身份仍由 endpoint 保留。
			endpoint.configure(
				f.pcie_id,
				pcie_env.rc_agents[slot].sequencer,
				pcie_env.rc_agents[slot].rc_driver,
				null,
				pcie_env.rc_agents[slot].monitor,
				null
			);

			endpoints.push_back(endpoint);
		end

		if (!vio_envs[h].bind_pcie_endpoints(endpoints)) begin
			`uvm_fatal("PROJECT_ENV", "VIO endpoint binding failed")
		end
		// 真 DUT 无 EP 接收 monitor；RC monitor 仅收包，发出的真实 doorbell 从 driver TX 观察口补齐。
		// 仅补出站观察，不连接第二 responder，也不重复消费入站 MSI-X。
		if (!tx_observation_bound.exists(h)) begin
			foreach (vio_envs[h].function_instances[i])
				pcie_env.rc_agents[slot].rc_driver.tx_ap.connect(
					vio_envs[h].function_instances[i].driver_agent.observer.analysis_export);
			tx_observation_bound[h] = 1;
		end
	end
	// 发布真实组件句柄，所有配置 sequence 共享它们，不复制运行期状态。
	cfg.vio_envs = vio_envs;
	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned	slot;

		slot = cfg.tl_slot_by_host[h];
		cfg.rc_sequencers[slot] = pcie_env.rc_agents[slot].sequencer;
	end
	cfg.runtime_ready = 1;
endfunction


// 每个仿真调用一次：按完整 service 身份登记各 Host，再注册已有 Tcl 命令。
// 空 Host 可跳过；全局没有 VIO service 或重复注册属于接入错误。
function void	project_env::register_aip_commands();
	int unsigned	active_hosts;
	string		why;

	active_hosts = 0;

	foreach (vio_envs[h]) begin
		if (vio_envs[h].function_instances.size() == 0) begin
			continue;
		end

		if (!virtio_aip_registry::bind_env(vio_envs[h], why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end

		active_hosts++;
	end

	if (active_hosts == 0) return;

	if (!virtio_aip_registry::register_business_commands(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end
endfunction


// 成功冻结并安装同一个 registry 后才发布视图。新 DPU snapshot 需要重建 env，禁止静默重绑。
function void project_env::publish_dpu_configuration(
	output bit	ok,
	output string	why
);
	project_bar_registry		candidate;
	project_dpu_setup		view;
	dpu_host_info_t			hosts[$];
	project_pcie_rc_driver		driver;
	project_msix_message_t		host_messages[$];
	project_bar_mapping_cfg_t	groups[$];
	groups = cfg.bar_groups;
	ok = 0;
	why = "DPU/PCIe components are not ready";
	if (dpu_env == null || pcie_env == null) return;
	if (dpu_env.get_snapshot() == null) return;
	if (cfg.bar_registry != null) begin
		if (cfg.dpu_setup == null) begin why = "published setup is missing"; return; end
		if (!cfg.dpu_setup.belongs_to(dpu_env.get_snapshot(), cfg.bar_registry)) begin
			why = "new DPU snapshot requires project env rebuild; live RC routing is immutable";
			return;
		end
		ok = !cfg.print_bar_map || cfg.bar_registry.print_bar_map(why, 1);
		return;
	end
	if (!cfg.materialize_messages(dpu_env.get_resource_snapshot(), why)) return;
	candidate = project_bar_registry::type_id::create("bar_registry");
	if (!candidate.initialize(dpu_env.get_snapshot(), 1, why)) return;
	dpu_env.get_snapshot().list_hosts(hosts);
	foreach (hosts[i]) begin
		if (!cfg.tl_slot_by_host.exists(hosts[i].host_id) ||
			!candidate.bind_host(hosts[i].host_id, cfg.tl_slot_by_host[hosts[i].host_id], why)) return;
	end
	foreach (cfg.function_policies[name]) begin
		project_function_policy_t	p;
		p = cfg.function_policies[name];
		if (name != dpu_function_key_name(p.key) || $isunknown(p.requester) ||
			!candidate.bind_function(p.key, p.intel_pf, p.intel_vf, p.requester, why)) return;
	end
	if (!candidate.freeze(why)) return;
	view = new("dpu_setup", dpu_env.get_snapshot(), candidate, 1);
	if (!view.populate(dpu_env.get_resource_snapshot(), why)) return;
	begin
		project_function_record_t	functions[$];
		view.list_functions(functions);
		if (cfg.bar_mapping_per_lease && (cfg.bar_group_policies.size() != 0 || cfg.bar_groups.size() != 0)) begin
			why = "BAR per-lease and explicit group declarations are mutually exclusive"; return;
		end
		if (cfg.bar_mapping_per_lease) begin
			foreach (functions[f]) foreach (functions[f].bars[b]) begin
				project_bar_mapping_cfg_t	group;
				project_bar_target_t		target;
				if (!candidate.resolve_function(functions[f].key, functions[f].bars[b].even_bar_id, target, why)) return;
				group.owners.push_back(functions[f]);
				group.members.push_back(target);
				group.ctx = project_empty_context(target);
				group.ctx.layout_id = "platform-bar-per-lease";
				groups.push_back(group);
			end
		end else foreach (cfg.bar_group_policies[g]) begin
			project_bar_mapping_cfg_t	group;
			project_bar_target_t		target;
			project_function_record_t	owner;
			if (cfg.bar_group_policies[g].functions.size() == 0 ||
				cfg.bar_group_policies[g].functions.size() != cfg.bar_group_policies[g].bar_ids.size()) begin
				why = "BAR atomic group requires complete Function/BAR pairs"; return;
			end
			foreach (cfg.bar_group_policies[g].functions[m]) begin
				if (!view.get_function(cfg.bar_group_policies[g].functions[m], owner) ||
					!candidate.resolve_function(owner.key, cfg.bar_group_policies[g].bar_ids[m], target, why)) return;
				group.owners.push_back(owner);
				group.members.push_back(target);
			end
			group.ctx = project_empty_context(group.members[0]);
			group.ctx.layout_id = cfg.bar_group_policies[g].name;
			groups.push_back(group);
		end
	end
	// 全部 RC cast 和 catalog 检查先完成；install 不会在成功前更换任何外部可见 registry。
	foreach (hosts[i]) begin
		int unsigned	slot;
		slot = cfg.tl_slot_by_host[hosts[i].host_id];
		if (slot >= pcie_env.rc_agents.size() ||
			!$cast(driver, pcie_env.rc_agents[slot].rc_driver)) begin
			why = "project RC instance override was not installed";
			return;
		end
	end
	foreach (cfg.messages[i]) begin
		project_function_record_t	owner;
		if (!view.get_function(cfg.messages[i].owner, owner) ||
			$isunknown({cfg.messages[i].address, cfg.messages[i].data, cfg.messages[i].masked}) ||
			cfg.messages[i].address[1:0] != 0 || cfg.messages[i].local_vector >= 64 ||
			cfg.messages[i].global_vector >= 8192) begin
			why = "public MSI-X catalog contains invalid owner/address/vector";
			return;
		end
		foreach (cfg.messages[j]) if (j < i &&
			cfg.messages[i].owner.host_id == cfg.messages[j].owner.host_id &&
			((cfg.messages[i].address == cfg.messages[j].address && cfg.messages[i].data == cfg.messages[j].data) ||
			(dpu_same_function_key(cfg.messages[i].owner, cfg.messages[j].owner) && cfg.messages[i].local_vector == cfg.messages[j].local_vector))) begin
			why = "public MSI-X catalog has ambiguous message or duplicate vector";
			return;
		end
	end
	foreach (hosts[i]) begin
		int unsigned	h;
		int unsigned	slot;
		h = hosts[i].host_id;
		slot = cfg.tl_slot_by_host[h];
		void'($cast(driver, pcie_env.rc_agents[slot].rc_driver));
		host_messages.delete();
		foreach (cfg.messages[m]) if (cfg.messages[m].owner.host_id == h) host_messages.push_back(cfg.messages[m]);
		if (!driver.install_registry(candidate, h, 0, slot, why) ||
			!driver.install_receive_path(vio_envs[h].host_mem, vio_envs[h].iommu, host_messages, why)) begin
			`uvm_fatal("PROJECT_PUBLICATION", why)
			return;
		end
	end
	cfg.device_snapshot = dpu_env.get_snapshot();
	cfg.resource_snapshot = dpu_env.get_resource_snapshot();
	cfg.bar_registry = candidate;
	cfg.dpu_setup = view;
	cfg.frozen_messages = cfg.messages;
	cfg.frozen_layouts = cfg.table_layouts;
	cfg.frozen_functions = cfg.function_policies;
	cfg.frozen_policies = cfg.vio_policies;
	cfg.frozen_reg_target = cfg.reg_target;
	cfg.frozen_bar_groups = groups;
	cfg.frozen_controls = cfg.platform_controls;
	cfg.frozen_msix_policies = cfg.msix_policies;
	ok = !cfg.print_bar_map || cfg.bar_registry.print_bar_map(why, 1);
endfunction


// EOE 与晚首次发布共用同一检查；自动打印去重由 registry 维护。
function void project_env::end_of_elaboration_phase(
	uvm_phase	phase
);
	bit	ok;
	string	why;
	super.end_of_elaboration_phase(phase);
	publish_dpu_configuration(ok, why);
	if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
endfunction
```

## `integration/project/project_base_test.sv`

SHA-256: `e45747fabc9c7727fd041878c91cd86858c2e0bdf42abe85858fa8c7f2cf9afa`

```systemverilog
// integration/project：可继承的 AIP base_test，由 project_env_pkg 最后包含。
// 依赖本目录 env/cfg 与 AIP bridge；基类拥有 objection 和统一配置/命令入口。
// 不知道平台的 reset/TL 接口/DMA/业务完成信号，故将这三处保留为强制实现的接口，
// 防止空 hook 假装平台已准备好。派生 test 用 factory 注册，本虚类不注册 factory。
virtual class project_base_test extends uvm_test;
	project_env_cfg	cfg;
	project_env	env;

	// 构造 test 壳；构建参数由 cfg.load_params 负责，无需在 new 重复逐项赋值。
	extern function new(
		string		name,
		uvm_component	parent
	);

	// 在 cfg 加载后、env 构建前注入平台 pool/IOMMU/VIF 等句柄。
	// cfg 若已由 top 完整注入，派生类可显式提供空实现；此 hook 不重新 load_params。
	pure virtual function void bind_platform_handles();

	// 等待真实复位/Intel 接口就绪，准备 requester-aware DMA 和平台网络检查器。
	// 必须有平台自己的超时及错误处理；返回后才启动 DUT 配置 sequence。
	pure virtual task prepare_platform();

	// Tcl 退出后等待业务完成并检查数据、DMA、PCIe/协议监测与资源回收。
	// vio_tx 返回只表示提交，不能仅凭 AIP run_loop 退出认定业务测试通过。
	pure virtual task finish_platform();

	// 支持 top 提供预建 cfg 或使用 factory；单一参数入口后只下发同一 cfg 句柄。
	extern virtual function void build_phase(
		uvm_phase	phase
	);

	// 配置 sequence 失败即停止参考流程，已导出资源留给平台 quiesce/release。
	extern function void require_success(
		input bit	ok,
		input string	why
	);

	// 唯一运行顺序：平台就绪→独立表配置/可选读回→VIO 确认→业务命令→Tcl→业务收尾。
	// 运行期 Tcl 只能改变下一条命令采样的参数，不能改写已冻结拓扑。
	extern virtual task run_phase(
		uvm_phase	phase
	);
endclass

// 构造 test 外壳，不读取设备。
function project_base_test::new(
	string		name,
	uvm_component	parent
);
	super.new(name, parent);
endfunction

// 唯一参数加载后注入平台句柄，再构建同一个 env。
function void project_base_test::build_phase(
	uvm_phase	phase
);
	super.build_phase(phase);
	if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg))
		cfg = project_env_cfg::type_id::create("cfg");
	if (cfg == null) `uvm_fatal("PROJECT_TEST", "project_cfg is null")
	cfg.load_params();
	bind_platform_handles();
	uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
	env = project_env::type_id::create("env", this);
endfunction

// 配置失败立即停止参考流程，资源仍由平台显式回收。
function void project_base_test::require_success(
	input bit	ok,
	input string	why
);
	if (!ok) `uvm_fatal("PROJECT_TEST", why)
endfunction

// 平台就绪后启动一个配置 sequence；失败不进入业务，成功才注册发包命令。
// 参考 VIO/QSCH 布局可直接使用基类；平台特殊访问才需 factory override 单项 hook。
task project_base_test::run_phase(
	uvm_phase	phase
);
	project_dut_config_seq	config_seq;
	int unsigned		host;

	phase.raise_objection(this);
	prepare_platform();

	config_seq = project_dut_config_seq::type_id::create("config_seq");
	if (!cfg.tl_slot_by_host.first(host)) begin
		`uvm_fatal("PROJECT_TEST", "no PCIe Host configured")
	end
	config_seq.start(cfg.rc_sequencers[cfg.tl_slot_by_host[host]]);
	require_success(config_seq.success, config_seq.error_msg);

	if (cfg.vio_setups.num() != 0) begin
		env.register_aip_commands();
		aip_tcl_bridge::run_loop();
	end
	finish_platform();
	phase.drop_objection(this);
endtask
```
