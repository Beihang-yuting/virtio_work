# 项目 DUT 配置从 env 迁移到 sequence

状态：接口设计，待用户审阅；下述新增类/API 尚未实现。
现有逐 DWORD 写序修正和驱动地址示例作为迁移基线，不代表 sequence 拆分已完成。

## 用户目标与约束

用户希望 env 只承担环境组装，寄存器和表项配置放进可直接启动的 sequence；
sequence 使用已有 `pcie_work` 发送真实 Memory Read/Write。
用户修改 DUT 寄存器偏移、字段策略即可，物理 BAR 地址由环境分配并自动解析。

保持一个 env、一个 env_cfg，不继承 DPU env，不增设 device_env/global_cfg。
Intel bind 仍是每 Host 一个 wrapper，PF/VF 共用该 Host 的 PCIe TL 接口。
沿用现有 typed 表项和图片字段、外部配置生命周期、单 bank notify、
高 DWORD 到低 DWORD 的32-bit写序；VTX/VRX 四笔数据后 clear/trigger，共六笔。
不恢复 capability discovery、PCI 配置空间访问、主动建链或自动 virtio_init。

本轮涉及当前集成的 BAR/BDF/PFVF/MSI-X/notify/QSCH/VTX/VRX 表；
不把驱动中全部 PP、转发、RDMA 业务初始化迁入 VIO 配置流程。

## 推荐拆分

| 层 | 保留/迁移职责 | 所有权 |
| --- | --- | --- |
| `project_env_cfg` | 参数、规模、字段策略、驱动参考寄存器偏移 | test 创建一次，下发同一对象 |
| `project_env` | DPU/PCIe/VIO 组件构建，VIF/内存/路由绑定，prepare/commit/release 与业务入口 | 拥有组件与一个内部共享配置上下文 |
| `project_dut_config_context` | 冻结配置视图、表项导出、范围/身份检查、配置状态、revision、在途计数、锁 | env 创建并保持，sequence 借用；没有主动 MMIO |
| `project_dut_config_seq` | 类别顺序、用户单项配置/使能/验证 task、DWORD/间接端口发送 | test 创建，可派生或 factory override；不拥有 ring/BAR |
| `pcie_tl_reg_seq` | 一次 Memory Read/Write 的 TLP、Completion 和错误传播 | 由配置 seq 创建、启动于真实 RC sequencer |

上下文是 env 内部的运行期状态对象，不是第二套 env_cfg，用户不用创建或逐字段填写。
不能把这些状态复制到临时 sequence：更换 sequence 后仍须识别同一代 ring、旧验证失效、
共享表依赖和并发间接写端口。

只增加两个参考源码：`project_dut_config_context.sv`、`project_dut_config_seq.sv`。
表的 packed 类型继续放在现有两个类型文件，不按每种表再造一个类。
底层写函数不是只包一层 env 调用；写入实现和平台 hook 真正移出 env。

备选的“seq 仅调用 env.configure_*”虽可立即提供 start 入口，但不能减小 env；
“每张表建一个独立 seq”会增加用户需要理解的类和启动层次。推荐一个配置 seq，
内部按类别调用 typed task，共用唯一 PCIe 发送实现。

## 用户启动接口

以下为拟议 API，说明拆分后的 test 用法，不是当前可直接编译的代码。
`my_dut_config_seq` 是用户实现具体硬件 hook 的配置 seq；派生自 `project_dut_config_seq`。

```systemverilog
// test 的 run_phase 中：平台先等待复位释放、Intel 接口可用。
my_dut_config_seq			config_seq;
project_vio_selection_t	selection;
bit							ok;
string						why;

env.prepare_vio_configuration(selection, ok, why);
if (!ok) `uvm_fatal("VIO_PREPARE", why)

config_seq = my_dut_config_seq::type_id::create("config_seq");
config_seq.dut_context = env.dut_context;
config_seq.selection   = selection;

// 当前单 Host：用户直接在 PCIe RC sequencer 上启动。
config_seq.start(env.pcie_env.rc_agents[0].sequencer);
if (!config_seq.ok) `uvm_fatal("DUT_CONFIG", config_seq.why)

// sequence 成功包含所需配置、使能和平台验证；最终准入仍由环境检查。
env.commit_vio_configuration(selection, ok, why);
if (!ok) `uvm_fatal("VIO_COMMIT", why)
```

单 Host 示例的 slot0 来自默认 Host→RC 映射；自定义映射时使用 cfg 的实际 slot。
`start(rc_sequencer)` 限定本次操作的访问 RC：发送前完整预检所有目标是否都属于该 RC，
否则零发送并报错，不能把其他 Host 的配置偷偷送到 RC0。

多 Host 可在同一配置 seq 上使用 `start(null)`，由上下文的实际 BAR 目标选择 RC。
这时它承担 virtual sequence 的调度角色，子 `pcie_tl_reg_seq` 仍启动在真实
`rc_agents[target.rc_slot].sequencer`；不要求额外创建 virtual sequencer 组件。
两种启动方式均核对访问窗口的 Host，不能用表项 owner 的 Host 代替管理窗口的 Host。

公共配置可不带 VIO selection 单独运行；正常完整配置由 seq.body 明确组织
公共表→notify→QSCH→队列→使能→平台验证。需要单独配置类别时，使用 seq 的类别选择输入，
选择空集必须明确报错或显式表示公共/业务关闭，不能意外扩大成“全部”。

## 用户修改位置

1. 地址：在 cfg 中集中声明各表的 `module_offset/table_offset/data_port/control_port`。
   `pf0.bar0` 等目标保留为逻辑名字，sequence 通过上下文 registry 解析真实 base。
2. 字段：在 cfg 的 Function/VIO/message policy 中设置，prepare 后形成 typed item。
   不允许在 hook 中随意改掉已绑定的 BDF、ring IOVA、qid 或 vector。
3. 写法：将现有 `user_configure_*`、`user_enable_*`、`user_verify_*` 移到 seq。
   普通表调用 `write_bdf(item)` 等 checked helper；平台特有表可用 BAR 名称的 DWORD API。
4. 启动：base_test 创建 seq、传共享 context/selection、调用 start，并检查 ok/why。
   Tcl 发包仍在配置验证并 commit 后进行。

例如 VTX 单项 hook 的形态保持 extern 和类外实现，只改变所属类：

```systemverilog
// 类内：item 来自冻结资源，失败返回给配置 sequence 的 body。
extern virtual task user_configure_vtx_queue(
	input project_vtx_cfg_t	item,
	output bit				ok,
	output string			why
);

// 类外：使用 sequence 自身的 checked helper，不再回调 env 做实际寄存器发送。
task my_dut_config_seq::user_configure_vtx_queue(
	input project_vtx_cfg_t	item,
	output bit				ok,
	output string			why
);
	write_vtx(item, ok, why);
endtask
```

发送链为：用户配置 seq → typed 检查/高低 DWORD/间接触发 → `pcie_tl_reg_seq`
→ 解析所得 RC sequencer → Intel adapter/bind → DUT。
配置 seq 派生自 `uvm_sequence #(pcie_tl_tlp)`，复用现有 PCIe item 类型；
不继承一次性 `pcie_tl_reg_seq` 来承载整个初始化，避免混淆一次寄存器访问与整组配置。

## 生命周期和错误合同

- 共享上下文先接受整批操作，登记在途寿命，再进入任何会等待的用户 hook/子 seq。
  prepare、commit、release 不能越过等待中的配置/验证操作。
- 每次已接受的重写先撤销旧 configured/verified/enabled 结果；分段失败也不能保留旧 READY。
  记录 revision 防止较早写入或验证完成覆盖较新的失败状态。
- 同 BAR/control 端口共用 env 生命周期内的锁；两个不同 seq 也不能穿插六笔 VTX/VRX 写。
  锁只在发送层获取一次，不在外层 seq 与内层 helper 重复获取。
- 表项完整宽度、X/Z、BAR 边界、4KB 边界、路由和 typed 关联在第一笔发送前检查。
  任一 DWORD 失败停止，不继续 data/control，不自动重试、reset 或释放 DMA。
- posted 完成只表示发送完成；verify 必须代表平台实际读回/状态检查。序列返回 ok 后，
  env.commit 仍检查依赖与本代状态。
- 外部 `kill()`/phase 终止同样是中止，不视作配置成功。上下文的操作票据必须撤销就绪，
  但不能在子 sequence 的发送尚未停止时过早释放端口锁或在途计数。
  迁移实现应覆盖中止路径；无法确认停发时保留失败/在途状态并阻止重配，交平台停机收尾。
- 原始 BAR API 不获得 typed 成功状态。它的串行化和资源寿命由调用它的配置批次负责。

## 源码迁移范围

| 文件 | 拟修改 |
| --- | --- |
| `integration/project/project_env.sv` | 移出配置/用户 hook/MMIO，实现集中于构建/绑定/资源生命周期；持有 dut_context |
| `integration/project/project_dut_config_context.sv` | 新增持久状态与纯校验/导出逻辑，复用已有 typed 类型 |
| `integration/project/project_dut_config_seq.sv` | 新增 body、类别 task、平台 hook、checked/原始 MMIO task |
| `integration/project/project_base_test.sv` | 用配置 sequence 启动替代逐项 env.configure 调用 |
| `integration/project/project_env_pkg.sv` | 仅参考 package 内增加包含顺序，避免 seq 依赖具体 project_env |
| `integration/project/tests/*` | 测试平台 hook 派生自配置 seq，保持 Intel 线侧事务断言 |
| `integration/project/README.md`、`driver_address_example.md`、完整源码导出 | 改为 seq 集成/启动/修改示例，保留已核实驱动偏移 |

顺序建议为 registry/types/RC driver/cfg/context/sequence/env/base_test。
不修改生产 VIO/DPU/PCIe 的原 filelist/package；`pcie_work` 和 `dpu_common` 本轮无需改动。
不保留大批 env 兼容代理 task 来抵消减小 env 的目标；当前参考调用点和测试一同迁移，
迁移说明列出旧 `env.configure_*` 对应的新 seq 入口。

## 验证

在 `10.11.10.53` 用 VCS 验证：

1. 复用当前写序基线：4/8/12/16B 高到低、raw MMIO 语义不变、VTX/VRX 六笔、同端口并发不交错。
2. 两个独立配置 seq 共享状态；六个失败点、重写/验证交叠、prepare/commit/release 准入保持原合同。
3. 单 RC start 合法发送；错 RC 或跨 RC 批次在首笔前拒绝；多 Host start(null) 使用真实目标槽位。
4. 用户 seq override 生效，base_test 无需在 env 中实现寄存器 hook；公共无 VIO、Packed/Custom、MSI-X 相关场景保留。
5. 中止或 kill 不把部分表项置为成功，不留下可静默越过的端口锁/生命周期状态。
6. 驱动地址示例编译、源码导出一致、生产 filelist 不变。模型验证与真实 RTL 地址/位域验收分开报告。
