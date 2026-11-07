# 外部配置 VIO：一个 env、一个 cfg

把本目录的 [project_env_cfg.sv](project_env_cfg.sv) 与
[project_env.sv](project_env.sv) 合入已有大 cfg/env，保留类内 `extern` 声明和类外实现。
已有 env 仍 `extends uvm_env`，不需要再包一层项目 env，也不继承 DPU env。
[完整源码导出](../../docs/project_env_full_code.md) 包含依赖类型、BAR registry、RC driver、
cfg、env 与 base_test；修改源码后运行 `python3 scripts/render_project_code.py` 更新。

每 Host 一个 segment 0、一个 RC 与 Intel `HARD_IP` wrapper；同 Host 的 PF/VF 共用端口。
DPU 快照拥有 BDF/BAR/队列资源身份，VIO 拥有 ring/DMA，平台拥有 RTL 配置与停机判断。
项目配置只发 Memory Read/Write，不发现 capability、不协商、不自动 reset/init。
准备和软件确认不访问 DUT。Packed 使用标准 12B `virtio_net_hdr`，512B 报文另计；
Custom 使用私有 descriptor/CQ，512B 报文不带 Virtio header。

## 最短接入顺序

1. 编译 [filelists/project_integration.f](../../filelists/project_integration.f)。
   设置 `AIP_CORE_ROOT`、`DPU_COMMON_ROOT`、`HOST_MEM_ROOT`、`NET_PACKET_ROOT`、
   `PCIE_WORK_ROOT`、`INTEL_PCIE_ROOT`、`QUEUE_WORK_ROOT`。AIP 必须是包含
   `src/sv/aip_core_pkg.sv` 的匹配版本；旧本地 AIP 布局未被修改或验证。
   已有统一 filelist 时只补缺失 package，普通 `.sv` include 不再单独编译。
2. test build 创建 cfg，调用一次 `cfg.load_params()`，填入平台布局/身份/控制项、
   Intel VIF、协议 VIF，以及可选已有 Host pool/IOMMU。将同一 cfg 以 `"cfg"`
   下发给 env，再创建 env。每个 Host 的 IOMMU 有独立状态，不能复制同一可变对象。
3. 平台等待复位释放与 Intel 接口就绪。connect 已发布 `env.dpu_setup` 和
   `env.bar_registry` 并安装 RC 路由；EOE 只幂等检查同一快照。
   `dpu.print_bar_map=1` 默认逐代打印每个真实偶数 BAR 的
   Host/Function/BDF/base/size/包含式 end/RC slot。打印不访问 DUT。
4. 建立公共 scope，按需要分别调用 BAR、AF、PFVF、BDF、Completion BDF、prefix、
   MSI-X 配置与 `verify_dpu_configuration()`。这些入口无需 VIO 或 ring；
   平台已有配置可以只做类别/范围验证。缺布局或 hook 的类别明确失败。
5. `prepare_vio_configuration(selection, ok, why)` 分配并导出真实 ring IOVA。
   然后调用 `configure_vio_notify()`、`configure_qsch()`、`configure_vio_queues()`、
   `enable_vio_queues()`、需要时 `enable_msix()`、`verify_vio_configuration()`，
   最后 `commit_vio_configuration()`。每次都检查 `ok/why`。
6. `env.register_aip_commands()` 后进入一次 `aip_tcl_bridge::run_loop()`。
   项目只注册 `vio_start/vio_tx/vio_wait_rx/vio_stop`。TX 成功表示已提交；
   网络侧 RX 激励、报文比对和最终业务完成仍由平台完成。
7. 停止所有所选 Function 的 FSM/业务命令；平台停用队列并确认没有在途 DMA 后，
   调用 `release_vio_resources(selection, 1, ok, why)`。stop 本身不代表 quiescence。
   已导出或部分配置失败的 ring、mapping、通知状态在此之前必须保留。

[project_base_test.sv](project_base_test.sv) 给出上述逐类别调用顺序。
它是虚类，平台实现 `bind_platform_handles()`、`prepare_platform()` 和
`finish_platform()`；最后一个 hook 必须承担实际业务检查、停机确认与释放。
若采用它的固定全类别流程，就必须提供所调用类别的 hook/布局；若平台只需要部分
公共类别，把对应调用移植到已有 test，不以空成功 hook 假装硬件配置完成。
`env.vio_setups[h]` 保留当前已发行 setup，可在 finish 中构造相同 service scope。

```systemverilog
// 公共 scope 的空 Function/BAR 列表表示全部；可追加类别过滤用于局部验证。
project_dpu_config_scope	public_scope;
dpu_function_key_t	functions[$];
int unsigned	bars[$];
project_vio_selection_t	selection;
bit	ok;
string	why;

public_scope = new("public", env.dpu_setup, functions, bars);
env.configure_bar_table(public_scope, ok, why);
if (!ok) `uvm_fatal("CONFIG", why)
// 其余实际需要的独立公共类别见 base_test，全部配置后再 verify。
env.prepare_vio_configuration(selection, ok, why);
if (!ok) `uvm_fatal("PREPARE", why)
// 按步骤5配置、使能、验证、确认；selection 必须保留到停机释放。
```

不存在 `configure_device()` 或自动 register-plan/executor 安装。Legacy 标准驱动和
register-plan API 仍可在其独立入口使用；项目 external 流程不调用这些入口。

## 平台必须声明什么

| 输入 | 所有者与约束 |
| --- | --- |
| `function_policies[Function名]` | 显式 EP wire requester、Intel PF/VF sideband、vport/Pfvf/各表 index；SW requester 使用快照 BDF。访问身份和表项 owner 分开 |
| `validate_pfvf_relationship(family, why)` | cfg 的纯函数 override，检查完整实际 PF family；图片没有完整公式，默认失败，不把测试的 `vf_id+1` 当硬件关系 |
| `table_layouts[kind]` | 显式模块 BAR 内基址、图片相对偏移、宽度、容量、索引政策、访问目标；VTX/VRX 还需 data/control/index/trigger 间接端口 |
| `bar_mapping_per_lease` 或 `bar_group_policies` | 选择完整租约粒度或明确原子成员组；BAR 编码 hook 由平台实现，scope 不得拆组 |
| `msix_policies` / `message_templates` | 真实 table/PBA 布局与显式 PBA words、完整 message address/data、interval/self-mask，Function control 或明确 table-only enable |
| `vio_policies[service名]` | VTX/VRX 非 ring 策略、QSCH net/group/ETH/ETS、VRX RAM 名/descriptor槽起点与容量、notify lookup BAR/offset |
| `platform_controls` | 仅实际存在的 AF/MSI-X enable/queue auxiliary/SPWRR/TC-weight/RDMA/RNET 等项与允许写 mask；未知寄存器不造默认 |
| 每类别 `user_configure_*` / `user_enable_*` / `user_verify_*` | 一个 typed 单项 hook；env 按真实记录遍历并去重。verify 必须代表平台的实际读回/状态检查 |

公共 topology/routes/layout/messages 在 connect 的首次成功 publication 后冻结；
后续公开调用和 EOE 发布同一快照是幂等操作。`print_bar_map=0` 可先静默安装路由，
稍后置1并调用 `publish_dpu_configuration()` 完成首次日志输出；不能延后必需的
connect 路由安装。改变 topology 必须重建 env。VIO enabled/pairs/format/geometry
在 placement 前冻结；只有 `cfg.vio_policies` 的平台表策略可在所有旧代 ring 释放后
更改，并在下一次 prepare 采样。任何 accepted typed 重写都会使旧配置/验证/使能
结果失效，部分发送失败也不能保留旧 READY；必须重新使能、验证再确认。

以下是**独立的平台布局示例**，所有基址、容量、端口、trigger/index 关系均是假定值，
只能在平台寄存器规范明确相同时采用。`0x10000` 是图片 VTX 表内相对偏移，不能据此
推断模块基址。表宽固定16B，VTX/VRX 必须间接访问；notify 仅单 bank。

```systemverilog
// cfg load 后、env 创建前填写；真实项目逐字段替换为其平台声明。
project_table_layout_t	vtx_layout;
vtx_layout = '{
	provided:1, reg_target:"pf0.bar0",
	access_host_provided:1, access_host:0, access_uses_owner_host:0,
	module_offset:64'h0080_0000, table_offset:64'h10000,
	capacity:512, entry_bytes:16, index_policy:PROJECT_INDEX_GLOBAL_QPAIR,
	indirect:1, data_port:64'h400, control_port:64'h420,
	index_mask:32'h000001ff, control_fixed:0, trigger_mask:32'h80000000,
	index_shift:0, required:1
};
cfg.table_layouts[PROJECT_VTX] = vtx_layout;
```

下面是**完整的 VTX 单项 hook**，放入合并后的 env 类；其他类别按同样方式调用
各自 checked helper。它不替代 BAR 编码和平台 verification，也不负责外围循环。

```systemverilog
// 类内声明：传入绑定来自冻结 setup；失败原样返回给类别账本。
extern virtual task user_configure_vtx_queue(
	input project_vtx_cfg_t	item, output bit	ok, output string	why);

// 类外定义：检查身份/IOVA/深度/mode/vector 后按声明端口序列化发送。
// posted 成功只表明发送完成；平台后续仍须显式 verify。
task my_env::user_configure_vtx_queue(
	input project_vtx_cfg_t	item, output bit	ok, output string	why);
	write_vtx(item, ok, why);
endtask
```

同一个 VF32 TX+RX 只实现一次 VTX/VRX hook，env 各调用32次；TX-only 不调用 VRX。
队列 owner、local pair/qid 和 global qpair 来自 `item.binding`，不能自行移位换算。
notify lookup base 与真正 doorbell 是不同输入。notify/MSI-X linear/RDMA notify
按高 DWORD→低 DWORD写；VTX/VRX 按 data→control-clear→control-trigger 串行写。
PBA/stat 没有初始化写；drop 清除使用独立显式 W1C mask API。

## BAR 目标与32对队列

默认访问目标 `pf0.bar0` 指管理窗口；配置 VF3 的 VTX 表项仍以 PF0 sideband 发出。
显式访问 VF3 BAR 则用它的真实租约与 VF3 sideband。BAR ID 是真实偶数硬件 BAR
编号，不是 role 或数组下标；64位 BAR 的奇数高 DWORD不能单独访问。

```systemverilog
// 路径只选访问窗口；以下offset/data也是示例，不代表任何已验证RTL寄存器。
env.pcie_bar_write_by_name("h0.pf0.bar0", 'h40, 4, 128'h1234, 0, ok, why);
env.pcie_bar_write_by_name("h0.pf0.vf3.bar2", 'h40, 4, 128'h1234, 0, ok, why);
```

`pcie_bar_read_by_name` 返回128位数据和 `ok/why`；支持4/8/12/16B，mask 的1表示
跳过该字节，稀疏 mask 会拆成连续 Memory TLP 区间。posted 写不会自动读回；
读 Completion 错误向上传递。多 Host 短目标需显式 `access_host_provided` 或
`access_uses_owner_host`；手动 by-name 多 Host 访问必须写 `hH`，不静默回退。

单 VF32 的业务参数（布局/身份/MSI-X/notify 仍由平台提供）：

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=1
+vio.enabled=0 +vio.h0.pf0.vf0.i0.enabled=1
+vio.h0.pf0.vf0.i0.pairs=32 +vio.queue_size=512 +vio.queue_type=VQ_PACKED
+vio.completion_mode=VIRTIO_COMPLETION_POLLING
```

两个 VF 各16对则设 `dpu.vfs_per_pf=2`，分别使能两个精确 service 并各设 `pairs=16`。
AF PF0 的额外11对计入每 Function 上限，不能把32普通对直接放在默认 AF。
`vio.enabled` 只控制服务与队列需求，不删除公共 Function/BAR。完整参数和 legacy
边界见 [参数表](../../docs/aip_parameters.md#项目外部配置参数)。

```tcl
set_param vio.target h0.pf0.vf0.i0
vio_start
set_param vio.tx.len 512
vio_tx count=10
# RX需要项目网络侧真实送包，vio_wait_rx只等待。
set_param vio.rx.expected 10
set_param vio.rx.timeout_ns 50000
vio_wait_rx
vio_stop
end_test
```

MSI-X 模式必须收到注册地址与完整 data 的真实消息后才处理完成，不能用 polling
兜底。共享 vector 的每条队列分别领取 pending；self-mask 的硬件重新使能由用户
平台流程负责。取消后仅 stop 或同代确认不能恢复复用，必须停机释放并准备、
配置、验证、确认新代。

## 实际组件与接收路径

```text
my_env extends uvm_env
  dpu_env : dpu_device_env
    vio_hH : virtio_net_env       每Host一个，构建时读取父DPU已冻结快照
  pcie_env : pcie_tl_env
    rc_agents[slot]               project_pcie_rc_driver factory override
    rc_adapter_slot              Intel HARD_IP，无主动EP
```

同一个 Host manager 交给 VIO 和 RC。项目 RC 根据冻结 wire Requester 映射选择
Host/Function IOMMU，完整权限预检后临时用原 IOVA proxy 调用父 RC responder；
保留原 wire Requester/Tag/Completion lower-address 和 Intel PF/VF sideband。
公共 MSI-X catalog 可在无 VIO 时独立 sink。RC RX monitor 提供 DMA/MSI-X 观察，
RC driver `tx_ap` 提供实际发出的 doorbell 观察。**不要再挂第二个 Host responder**。
完整 factory override、bridge、route API 均已在模型的真实 Intel 引脚路径验证；
用户 RTL 基址、端口语义与线侧收发仍需平台验收。

`tl_slot_by_host[h]` 默认 `h→h`，load 后/build 前可交换，例如
`cfg.tl_slot_by_host[0]=1; cfg.tl_slot_by_host[1]=0;`。VIF/cfg 始终按物理 slot 填写，
映射必须完整且一一对应。不同 Host 可有相同 BDF/数值 BAR 地址，访问域仍独立。

## Intel 配置放在哪里

参考 env/cfg 直接使用 Intel。`cfg.load_params()` 和
`env.prepare_pcie_config()` 设置的关键组合为：

```systemverilog
cfg.pcie_cfg.if_mode          = SV_IF_MODE;
cfg.pcie_cfg.rc_agent_enable  = 1;
cfg.pcie_cfg.rc_is_active     = UVM_ACTIVE;
cfg.pcie_cfg.num_rc           = cfg.tl_slot_by_host.num();
cfg.pcie_cfg.ep_agent_enable  = 0;
cfg.pcie_cfg.num_ep           = 0;
cfg.pcie_cfg.ep_auto_response = 0;
cfg.pcie_cfg.use_unified_mem  = 1;
cfg.pcie_cfg.infinite_credit  = 1;
```

Intel adapter 自身会驱引脚，所以这里关闭 EP 组件，不能仅将 EP 标为 passive。
每个 Host manager 用 `bind_host_memory(slot, host_id, manager, why)` 交给对应 RC，
不生成 EP→Root 绑定；每个 Function 的 endpoint 使用 RC monitor，EP monitor 为 null。

`env.build_phase()` 在创建 PCIe 子环境前执行：

```systemverilog
prepare_intel_bindings();
intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env");
pcie_env = pcie_tl_env::type_id::create("pcie_env", this);
```

`prepare_intel_bindings()` 完整实现见 [env 源码](project_env.sv)；它在以下实际路径
设置 `intel_cfg` 与 `vif`，然后 Intel adapter 在自己的 build 中读取：

```text
uvm_test_top.env.pcie_env.rc_adapter_0
uvm_test_top.env.pcie_env.rc_adapter_1
```

单 RC 仍叫 `rc_adapter_0`，不能用标量句柄名字 `rc_adapter` 当组件路径。
如果你的大 env 不叫 `env`，更新 top/bind 中的实际路径；env 内使用相对路径不变。

setup 函数安装当前 PCIe env 子树的 factory instance override，设置 `SV_IF_MODE`、
公共无限 FC 和 `pcie_svt_bridge_required=1`。这个历史字段名在这里表示外部引脚
bridge，不会创建 SVT、global_cfg、topology adapter 或链路训练。

### 已经使用 Intel bind wrapper

沿用 `pcie_intel/bind/intel_pcie_bind_wrapper.sv` 的
`intel_pcie_bind_wrapper_inout`。当前一个 Host 时只绑定一个物理端口，例如：

```systemverilog
// 放在项目自己的 bind 文件中；路径替换成实际 DUT 实例。
// .* 仅适用于绑定点包含与 wrapper 同名、同宽度的全部 wire/tri 网络。
bind tb_top.u_dut.u_pcie0 intel_pcie_bind_wrapper_inout #(
    .ADAPTER_PATH("uvm_test_top.env.pcie_env.rc_adapter_0"),
    .SIDE("HARD_IP")
) u_pcie_bind (.*);
```

wrapper 在 time-0 已发布 cfg/VIF；大 cfg 中可以留空 `intel_cfg_by_slot` 和
`intel_rc_vifs`，env 会从 config_db 取得并保留同一个对象。两个入口同时有值时，
要求它们是同一 cfg/VIF；冲突立即报错，不静默替换 wrapper 配置。

top 需在 wrapper 初始化之后调用一次 `run_test()`：

```systemverilog
initial begin
    #0;
    // 本 initial 位于 tb_top；可选地修改 wrapper 持有的同一 cfg。
    // 不修改 cfg.side：引脚方向已由 bind 参数 SIDE 在展开时决定。
    u_dut.u_pcie0.u_pcie_bind.cfg.check_parity = 1;
    u_dut.u_pcie0.u_pcie_bind.cfg.rx_gap_cycles = 0;
    run_test();
end
```

完整 pin 连接和每个信号方向见外部
[Intel bind 文档](https://github.com/Beihang-yuting/pcie_intel/blob/main/docs/integration/bind.md)。
wrapper 的 inout actual 必须是 `wire/tri` net；DUT 内部为 `logic` 变量时，可选取父层
实际连接 DUT 端口的网络作为绑定点。`HARD_IP` 驱 RX、TX ready/credit，采样 DUT 的 TX；
它与 RC/EP 协议角色分开。wrapper 自带的默认 ADAPTER_PATH 少了本项目的 `pcie_env`
一层，必须显式填写完整路径；ADAPTER_NAME 仅影响 cfg 对象名，无须另设。

### 从一个 Host 扩展到多个 Host

本参考采用一 Host 一物理端口，因此 Host、RC adapter 和 wrapper 数量一致；
增加同一 Host 内的 PF/VF 不增加 wrapper。默认映射如下：

| DPU Host | TL slot | 物理绑定点示例 | ADAPTER_PATH |
| --- | --- | --- | --- |
| Host0 | 0 | `tb_top.u_dut.u_pcie0` | `uvm_test_top.env.pcie_env.rc_adapter_0` |
| Host1 | 1 | `tb_top.u_dut.u_pcie1` | `uvm_test_top.env.pcie_env.rc_adapter_1` |

当前单 Host 仅保留上面的 port0 bind，运行参数为默认值：

```text
+dpu.hosts=1 +dpu.pfs_per_host=1 +dpu.vfs_per_pf=0
```

以后接入第二个物理端口时，再将下面的实例级 bind 加入工程并重新编译，运行设
`+dpu.hosts=2`。env/cfg 不需要新增第二套类，默认自动生成 `tl_slot_by_host[1]=1`：

```systemverilog
bind tb_top.u_dut.u_pcie1 intel_pcie_bind_wrapper_inout #(
    .ADAPTER_PATH("uvm_test_top.env.pcie_env.rc_adapter_1"),
    .SIDE("HARD_IP")
) u_pcie_bind (.*);
```

每个 wrapper 独立持有一个 interface 和一个 cfg，并独立发布；不能多个端口使用同一个
ADAPTER_PATH，也不应使用固定路径的模块类型 bind 覆盖该类型的所有 DUT 实例。
env 会拒绝已用 slot 间复用 cfg/VIF，但不会清点所有 HDL wrapper，也无法追溯同一路径
在 time-0 被重复发布覆盖。使用实例级 bind 和唯一完整路径可以明确对应关系。

bind 的存在和数量在 elaboration 时确定；`dpu.hosts` 在 UVM build 前加载，不能生成
HDL wrapper。只绑定一个端口却设置两个 Host，会因缺 `rc_adapter_1` 的 VIF 立即 fatal。
也不要在当前不用的端口上预绑仍接着有效 DUT 网络的 wrapper：它持续驱动所拥有的网络，
没有 UVM adapter 初始化的接口可能把 X 送入 DUT。按本次需要的端口选择 bind 文件即可，
无需额外接口选择宏。

需要交换 Host 与物理端口时，只在 build 前调整 `tl_slot_by_host`；wrapper 的路径始终
表示物理 slot。接口中的 4×256 bit 是同一端口的四个 AVST segment，与 Host 数无关。
多 Host 还需满足 DPU caps、Function 数和 queue 资源上限，并提供各活动 Function 的协议 VIF。

### 平台直接持有 Intel interface

不使用 wrapper 时，可在已有 test 的 `bind_platform_handles()` 中注入 HDL top
发布的 VIF；下面是完整的单 Host 注入方法，`project_base_test` 已先调用 load：

```systemverilog
// 类内声明；package 需 import intel_pcie_adapter_pkg::*。
// top 在 run_test 前把已有 interface 发布为 uvm_test_top 的 intel_vif_0。
extern virtual function void bind_platform_handles();

// 类外定义；只绑定已有平台句柄，不创建第二个接口或env。
function void my_test::bind_platform_handles();
    intel_pcie_vif_t	vif;

    if (!uvm_config_db#(intel_pcie_vif_t)::get(this, "", "intel_vif_0", vif) || vif == null)
        `uvm_fatal("MY_TEST", "Intel port 0 interface is missing")
    cfg.intel_rc_vifs[0] = vif;
    cfg.intel_cfg_by_slot[0] = intel_pcie_adapter_config::type_id::create("intel_port0");
    cfg.intel_cfg_by_slot[0].side = INTEL_PCIE_HARD_IP;
    cfg.intel_cfg_by_slot[0].check_parity = 1;
    cfg.intel_cfg_by_slot[0].credit_enable = 1;
    cfg.intel_cfg_by_slot[0].rx_gap_cycles = 0;
    cfg.intel_cfg_by_slot[0].validate();
endfunction
```

top 的对应发布语句（`pcie_port0` 为已连接 DUT 的真实 interface）为：

```systemverilog
uvm_config_db#(intel_pcie_vif_t)::set(
    null, "uvm_test_top", "intel_vif_0", pcie_port0);
```

没有注入 Intel cfg 时，env 创建独立的 HARD_IP 默认配置；没有 VIF 则立即失败。
多 Host 按物理 slot 循环注入，不得多个端口共用同一个可变 cfg 或 VIF。
`protocol_vifs` 仍要按活动 Function 提供，它是 Virtio 协议观察接口，不能用 Intel
PCIe VIF 替代；也可沿用 top 的 `protocol_event_vif_N` 发布方式。

| Intel cfg 字段 | 默认值与含义 |
| --- | --- |
| `side` | 本参考要求显式 `INTEL_PCIE_HARD_IP`；库类原默认 AUTO 不用于本参考的外部注入 |
| `header_big_endian` / `check_parity` | 默认 1 / 0，匹配 DUT 的 header 字节顺序与 parity 契约 |
| `credit_enable` | 默认 1，控制本地 AVST credits |
| `header_capacity[3]` / `data_capacity[3]` | `{16,16,16}` / `{512,512,512}`；索引 P/NP/CPL，data 单位 16 B |
| `infinite_header[3]` / `infinite_data[3]` | 默认全 0；每类独立选择有限/无限 AVST credit |
| `tx_stop_latency` | 默认 1，合法 1..16 |
| `rx_gap_cycles` / `rx_start_segment` | 默认 0 / 0；4 段独立起包只支持 st0/st1 |
| `x16_single_width` | 默认 0，只适用于 2×256 几何 |

这些是 `intel_pcie_adapter_config` 的原有 SV 字段，目前没有 `load_params()`，
所以 `+pcie_cfg.intel.rx_gap_cycles=...` **不会自动生效**。先在 build 前设置对象字段。
已有 `pcie_cfg.*` 仍用于公共 TL 策略；Intel 接入要求 `infinite_credit=1`，
`init_*_credit` 不控制 AVST 的有限 credit，不能用它们测试 Intel 引脚背压。

## 验证与范围

运行时使用匹配依赖和用户 DUT top；模型参考测试才添加 `filelists/project_tests.f`。
生产 `filelists/virtio_net.f` / `virtio_net_pkg` 不导入 integration。
完整35项证据、依赖 commit/package哈希、可复现命令与未覆盖边界见
[外部配置验证记录](../../docs/vio_external_configuration_validation.md)。
