# VIO 外部设备配置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已经审阅的外部配置设计落实为可编译、可验证的参考环境：用户按逻辑 BAR 访问，通过单项 typed task 配置 DUT，然后运行 Packed/Custom VIO。

**Architecture:** DPU 冻结身份和资源，VIO 独立准备实际 ring，项目公共配置和 VIO 配置引用同一快照。项目 env 负责按范围遍历与确认，用户 hook 负责硬件访问；项目 RC driver 将同一分配映射到 Intel sideband。标准独立驱动保留原行为。

**Tech Stack:** SystemVerilog/UVM、dpu_common、pcie_tl_vip、pcie_intel、host_mem、aip_core；VCS 在 ubuntu@10.11.10.53 执行。

**Spec:** `docs/superpowers/specs/2026-11-07-vio-external-device-configuration-design.md`；位域来源为同目录 `2026-11-07-dpu-queue-interface-image-notes.md`。

**Driver supplement:** 用户实现期间提供当前驱动，补充依据为同目录 specs 中
`2026-11-07-current-driver-compatibility-notes.md`。Task 2 增加TX内层校验位与
完整RX CQ解析/查询及黄金字节测试；Task 3 的配置表以图片为准，驱动只补充
未覆盖的操作流程。Packed保持标准header，可显式选择DPU32通知。

## Global Constraints

- 一个项目 env extends uvm_env、一个 env_cfg；每 Host 一个 RC/Intel HARD_IP wrapper，segment 0。
- 项目配置只使用 Memory Read/Write；准备阶段不访问 DUT，不发现 capabilities、不协商、不复位、不自动编程。
- 配置表以用户图片为准；notify只实现单bank逐项高DWORD先写，不实现双bank、全表搬移或bank-select/ready。未知控制地址须显式声明。
- Packed 带标准 virtio_net_hdr；Custom 保留私有 descriptor/CQ 和无 Virtio header 的数据面。
- integration 只在独立参考 package/filelist 编译；生产 package 只加入必要的通用 VIO 源码。
- 参数根为 dpu.*、vio.*、pcie_cfg.*，注册留在拥有字段的配置类中。
- 默认访问 pf0.bar0；访问 Function 与被配置表项的 owner 分开。BAR ID 不是 role，也不是列表下标。
- 配置缺布局、缺 hook、缺依赖或旧代引用均失败；不制造硬件地址或伪造配置成功。
- 启用方向分别准备；MSI-X 完成不得靠轮询兜底；早到中断保留。
- 已导出/部分编程的 DMA 资源保留到平台明确确认 DUT 停止 DMA；stop 不等于 quiescence。
- 新增/修改函数 task 有中文职责和边界注释；项目类使用 extern、宽松排版，类型与变量名之间使用真实 Tab。
- 只提交本任务明确文件，不提交已有 build/；此次不推送远程。
- 根据上级 AGENTS.md，代码/架构由 Astra 实现审查，VCS/日志验证由 GPT-5.6-sol 执行。

## 执行与持久记录

用户已明确“开始实现吧”，继续在现有 review/virtio-sdd-optimized 工作分支完成，不再次请求相同授权。按依赖顺序执行以下四项；每项先做独立验证，再进入依赖它的下一项。实现报告、审查结论和命令证据保存在本计划独占的 `.superpowers/sdd/2026-11-07-vio-external-device-configuration/`，最终验证摘要进入版本管理文档。

## Task 1: 冻结 BAR 引用与 Intel 路由

**Files:**
- Create: `integration/project/project_bar_registry.sv`
- Create: `integration/project/project_pcie_rc_driver.sv`
- Modify: `integration/project/project_env_pkg.sv`
- Test: `integration/project/tests/project_bar_registry_test.sv`
- Modify: `filelists/project_tests.f`（仅测试入口）

**Interfaces:**
- Consumes: `dpu_device_snapshot` 的 `list_functions/list_bars/get_pcie_id/get_global_function_id`；实际 `dpu_bar_lease` 值类型按源码复用。
- Produces: `project_bar_target_t`，含完整 Function key、PCIe id、global id、BAR lease、RC slot、canonical name、快照身份/代号、Intel route。
- Produces: `project_bar_registry`，借用冻结快照，显式绑定 Host→slot 和 Function→Intel PF/VF/requester 映射后冻结；解析名字、Function+BAR 和物理 base 到同一目标；检查完整访问范围；打印真实租约；提供 Memory 地址和 Completion requester 路由查询。
- Produces: `project_pcie_rc_driver extends pcie_tl_rc_driver`，发送前查询 registry 并设置 cq_route，再调用 super.send_tlp；未安装/缺映射明确报错，禁止 Config TLP。

- [ ] 写覆盖合法、非法、跨 Host、同号 VF、奇数高 BAR、旧快照、64 位溢出、范围尾端的实际 SV 测试；让未定义接口首先表现为编译失败。
- [ ] 实现严格逐字符解析（不可用仅检查 sscanf 匹配个数的宽松解析）：

```text
consume optional h + decimal + '.'
consume pf + decimal
consume optional '.vf' + decimal
consume '.bar' + decimal
require end of input; decimal accumulation checks uint overflow
resolve unique Host or explicit access Host; list_bars then match even_bar_id
```

- [ ] registry 只在构建时接收映射；冻结后返回值副本。查询地址必须在相同 Host/segment 内唯一匹配，范围用 65 位运算检查，缺路由不回退 PF0。
- [ ] route 对 Memory 请求使用真实 BAR 窗口，对 Completion 使用原请求 Requester ID；检查实际 codec 的 PF/VF/BAR 位宽。driver 的 instance override 指向 pcie_tl_rc_driver，不与 rc_agent 的 base override 竞争。
- [ ] 自动打印按快照代号去重，手工打印可重复；状态未就绪时不打印最终结果。包含完整路径、BDF、base/size/末地址、RC 和绑定状态。
- [ ] 由验证代理在 VCS 主机编译/执行新增测试，记录命令、退出码、UVM summary 和负例诊断；修复后定向重跑。
- [ ] 单项提交，记录外部可调用的最终完整函数签名，供 Task 3 使用。

## Task 2: VIO 本地准备、确认及生命周期

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv`
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv`
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv` 及 `agent/atomic_ops/virtio_atomic_ops_queue.svh`
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv`
- Modify: `virtio_net_vip/src/agent/virtio_driver_protocol.sv`
- Create: `virtio_net_vip/src/agent/virtio_external_driver_protocol.sv`
- Create: `virtio_net_vip/src/transport/virtio_external_config_backend.sv`
- Modify: `virtio_net_vip/src/transport/virtio_notification_manager.sv`
- Modify: `virtio_net_vip/src/transport/virtio_pcie_observer_adapter.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`
- Create: `virtio_net_vip/src/env/vio_external_setup.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`、`src/virtio_net_pkg.sv`、必要的私有协议接入和通用源码 filelist
- Test: 新增通用外部协议定向测试，归入现有独立测试入口。

**Interfaces:**
- Consumes: 已冻结 service 配置、DPU service/qpair 绑定、真实 host_mem/IOMMU、显式 notify 和 MSI-X message 配置。
- Produces: `vio_queue_setup_t` 值记录（精确 owner/service/方向/local qid/global qpair/vector、真实 ring GPA/IOVA/长度、初始 wrap/index、notify 和 completion mode）。
- Produces: 只读 `vio_external_setup` 和 `vio_config_scope`；环境接口 `prepare_external_configuration`、`confirm_external_configuration`、`release_external_resources`，均通过 ok/why 返回，引用来源环境/代号且不能伪造成功。
- 配置入口固定外部模式，独立标准协议不受影响；Task 3 调用实际报告中的方法签名，不复制内部状态。

- [ ] 编写无配置访问的 spy 测试，用未知态/越界/旧代/未确认提交/释放未停 DMA 等负例锁定合同。
- [ ] 分离 queue 本地创建、分配、映射和编程；标准 setup_queue 继续组合原流程。外部准备直接调用本地部分，不能实现假成功 configure_queue。

```text
validate exact service config and DPU resources
allocate queue object -> initialize format-specific ring -> map all real regions
derive/export IOVA from actual mappings; hold ownership in ops
freeze setup generation -> user config -> explicit confirm -> READY
stop workers -> platform confirms quiescence -> unmap/free -> invalidate generation
```

- [ ] Packed 复用 header/payload 格式；Custom 自动构造并加载相应 private_cfg，校验深度和 notify 重复输入，不走 AF 寄存器初始化。复制 service 级 enabled/方向/完成/通知参数并检查 feature 合约。
- [ ] 固定轮询或 MSI-X worker；外部协议禁用 status 监控、reset、MQ/RSS、mask 自动写。MSI-X 接收按 Host/地址/数据匹配已注册项，保留早到消息和共享向量；不从 data 低位猜向量。
- [ ] setup 查询返回值副本，记录真实 ring 资源，prepare 失败只回滚未交付资源，导出后失败保留。
- [ ] 在 VCS 主机验证 Packed 和 Custom 各 512B TX、Custom RX、非 identity DMA、轮询和真实中断；验证无消息时不能完成；运行相关标准协议回归。
- [ ] 单项提交，向 Task 3 交付实际接口与测试证据。

## Task 3: 项目 typed 表项、参数与独立用户回调

**Files:**
- Create: `integration/project/project_dut_config.sv`
- Create: `integration/project/project_vio_config.sv`
- Modify: `integration/project/project_env_cfg.sv`、`project_env.sv`、`project_base_test.sv`、`project_env_pkg.sv`
- Modify: `integration/aip/virtio_aip_pkg.sv`
- Test: `integration/project/tests/project_external_config_test.sv` 及参考测试入口

**Interfaces:**
- Consumes: Task 1 registry/target/driver；Task 2 setup/scope/准备确认释放 API。
- Produces: spec §5.1 每个独立批量方法和 extern virtual user hook；唯一配置输入为 typed cfg，结果为 output bit ok/output string why。
- Produces: project_dpu_setup/project_dpu_config_scope，公共快照只读视图不依赖 VIO ring。
- Produces: 原 env_cfg.load_params 中 dpu.reg_target、各表 reg_target、dpu.print_bar_map、显式中断/布局/策略输入和精确 service 需求。

- [ ] 按截图记录生成每张表的 packed entry；外层 cfg 为 ctx + owner/consumers + entry，队列为 ctx + binding + entry。独立常量向量验证 21 个类型位宽与字段，特别是 VTX bit72、13-bit vector、VRX 第4 DWORD、QSCH 10-bit net/group。
- [ ] 公共导出遍历实际 Function/BAR、绑定快照和 scope；未知 key/旧代拒绝；BAR 组粒度由显式声明确定并检查完整成员，不猜连续 VF 窗口。
- [ ] env_cfg 按全局→Host→精确 service 读取最终 enabled/pairs，逐 service 建固定 placement request；AF 额外 11 对仍受32对上限约束。参数不能在冻结后改变记录。MSI-X 独立加载不依赖 VIO。
- [ ] 显式平台布局映射决定 vport/Pfvf/requester EP-SW 编码、表 index、间接端口、QSCH 与 VRX 预取 RAM；缺输入只阻止相应类别，不能采用旧编码或编造偏移。
- [ ] env 删除 configure_device 和默认 executor/backend 安装；connect 冻结 registry/安装路由，EOE/发布调用打印检查。保持 Intel bind、Host 内存和 endpoint 原有接线。
- [ ] 先预检完整 scope 后逐项调用用户 hook，记录本代类别+entry 的结果。未填必需 hook 返回失败；共享项去重；锁住共享间接端口；失败撤销相关确认并保留 DMA。

```systemverilog
// 各 task 保持一个配置输入；示意签名，具体 cfg 在本项定义。
extern virtual task user_configure_vtx_queue(
    input project_vtx_queue_cfg_t cfg,
    output bit ok,
    output string why
);
```

- [ ] PCIe helper 在检查目标/范围/长度/skip-mask 后调用 pcie_tl_reg_seq；posted success 只表示发送，确认由用户 verify hook 返回。notify/MSI-X linear 明确高 DWORD 先写，VTX/VRX 使用平台声明间接端口。
- [ ] 使能和提交检查全部相关依赖；独立 verify 可确认已由平台配置的范围。运行中不能重写已交付资源依赖；reset/quiesce 由用户显式执行。
- [ ] AIP 在项目只注册 start/tx/wait_rx/stop，公共 legacy register_commands 保持兼容；base_test 展示用户配置顺序而不自动调用旧初始化。
- [ ] VCS 验证单 VF32对、两 VF各16对、TX-only、无 VIO 只配置 BAR/BDF、多 Host/非连续选择、hook 中途失败、typed记录一致性和真实 Intel RX sideband。
- [ ] 单项提交，保留项目生产入口隔离。

## Task 4: 联合验证与可直接使用的接入文档

**Files:**
- Modify: `integration/project/README.md`
- Modify: `docs/project_env_full_code.md`
- Modify: `docs/aip_parameters.md`
- Create: `docs/vio_external_configuration_validation.md`
- Modify: 专项测试与必要的发现缺陷代码（小修复单独提交）

**Interfaces:** 消费前三项真实 API 和日志；文档不得把设计接口误标为已验证功能。

- [ ] 运行 spec §9 的35项验证矩阵；对测试按解析/表项/生命周期/数据面/PCIe/标准回归分组，记录每项证据和实际 DUT 才能验证的边界。
- [ ] 测试发出完整 Memory TLP 经 Intel adapter/codec，检查 sideband、地址、payload、mask、完成错误传递；无 Config TLP。
- [ ] README 给出 env/cfg/base_test 的具体接入顺序、平台必须填写的布局与 hook、pf0.bar0 和 vf BAR 示例、32对队列参数、BAR 映射打印和停机释放。
- [ ] 全部实际新增参数同步参数表；完整代码文档从最终源码生成，避免两份实现漂移。
- [ ] 5.6 验证报告后由 Astra 最终审查；检查 git diff --check 和生产 filelist 隔离，提交已验证文件；不推送。
