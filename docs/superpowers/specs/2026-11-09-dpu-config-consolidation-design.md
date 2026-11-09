# DPU 配置下沉与 Notify 使能设计

日期：2026-11-09。状态：用户已确认设计，进入实施计划阶段；源码迁移和仿真尚未执行。代码规范及精简架构要求已补入 `/home/ryan/workspace/ryan/AGENTS.md`。

## 1. 已确认的目标

以当前 `virtio_work/integration/project` 中已实现的 DUT 字段、地址布局和写入顺序为依据，把可复用配置收进 `dpu_common`，替换其中与当前 DUT 不符的旧配置实现。

用户自己的 `env_cfg` 直接组合 `dpu_cfg`、`vio_cfg` 和 `pcie_cfg`。不要求继承参考 `project_env_cfg`，也不增加一个同时包住三者的新配置对象。参考 `project_env`/`project_env_cfg` 保留为组装示例。

新增硬件要求：VIO 或 RDMA 的 Notify 表配置成功后，经该批表使用的管理 BAR，发送一次 32 位写：`BAR base + 0x80044 = 1`。这里按现有配置接口，将用户给出的 `0x80044` 解释为 BAR 内偏移。

保留多 Host/PF/VF、实际 BAR 分配、逐表扩展、标准 packed/自定义队列、Host memory 共享、Intel bind 和原生 PCIe TL 访问能力。

## 2. 现状与迁移边界

当前 `project_env_cfg.sv` 同时承担三类子配置的创建、DPU 输入构建、硬件表字段/布局、VIO ring 生命周期和运行期参数刷新。`project_dut_config_seq.sv` 已集中承担硬件读写，因此不能再把旧 DPU 寄存器计划作为第二套默认实现。

核对到的旧实现差异包括 BDF 默认偏移 `0x56000`、32 位 MSI-X linear 项、三个 DWORD 的 VRX 项以及 Notify 双 bank 提交。当前 project 使用 BDF `0x108000`、64 位 MSI-X linear 项、四个 DWORD 的 VRX 项及单 bank Notify。迁移以当前 project 为准，不能为通过旧测试而保留两套生产表定义。

但 `dpu_reg_executor` 等通用执行接口仍被 `pcie_work/pcie_dpu_integration` 和 VIO 测试使用。删除范围是失效的 DUT 布局、重复生成/执行入口和纯转发包装，不能直接删除这些仍有调用者的通用能力。

| 内容 | 最终归属 | 处理方式 |
| --- | --- | --- |
| Host/PF/VF 默认输入、BDF/BAR 分配、资源快照 | `dpu_common` | 将 project 输入构建并入现有 DPU 配置；只解析和分配一次 |
| BDF、BAR mapping、MSI-X、QSCH、Notify、VTX/VRX 字段与布局 | `dpu_common` | 迁移当前 project 定义及生成规则，替换旧 DUT 定义 |
| 真实 ring、IOVA、队列启停、确认和释放 | `virtio_work` | 保留在 VIO；导出配置所需的实际队列值 |
| PCIe TL 发送、RC 选择、Intel 路由 | PCIe 集成层 | 复用同一 DPU BAR 视图与 `pcie_tl_reg_seq` |
| VIO IOMMU/DMA 代理与接收处理 | VIO 集成层 | 保留其真实依赖，不放进 DPU 资源包 |
| 子组件创建、VIF 绑定、配置句柄发布 | 用户 env／参考 project env | 只保留平台组装代码 |

## 3. 公共配置与编译依赖

`dpu_env_cfg` 整合原 `dpu_device_env_config` 和 project 中属于 DPU 的字段、默认值、表生成方法。它拥有 authoring 输入、解析后的资源视图和表项；不拥有 PCIe/VIO 子组件，不释放 VIO ring。

公共核心仍放在 `dpu_resource_pkg`，不 import `pcie_tl_pkg` 或 `virtio_net_pkg`。VIO 已依赖 DPU，因此不能把引用 `virtio_net_env`、`vio_external_setup` 的整个 project cfg 原样移进这个包。

PCIe 相关 sequence 和路由实现放在 `dpu_common/integration/pcie` 的独立 `dpu_pcie_pkg`，在 DPU 核心及 PCIe TL 之后编译。VIO 的薄集成代码放在 `virtio_work/integration/dpu`，在 VIO 核心和 `dpu_pcie_pkg` 之后编译。这些入口由集成 filelist 显式加入，参考 project 文件不加入生产核心 package。

编译关系为：

```text
AIP / Host memory / UVM
          ↓
dpu_resource_pkg       pcie_tl_pkg
       ↓                   ↓
       ├──── dpu_pcie_pkg ──┘
       ↓
virtio_net_pkg
       ↓
VIO 的 DPU 集成包（同时使用 dpu_pcie_pkg）
       ↓
用户 env package 或参考 project_env_pkg
```

这里只表达依赖关系；独立包之间无需人为增加编译先后约束。Intel interface/adapter 沿现有 filelist 在使用者之前编译。

## 4. BAR 与 PCIe 的复用

`dpu_bar_map` 保存冻结资源中的 Function/BDF/BAR 查询结果，支持完整 Function key 和 `h0.pf0.bar0` 形式的名称查找。它不重新分配地址。

当前 registry 的 RC slot、Intel sideband 和 requester 路由部分归入 PCIe 集成层的 `dpu_pcie_bar_map`，继承公共 BAR 查询；这是同一个运行期对象，DPU cfg、配置 seq 和 RC driver 都引用它。基类不依赖 PCIe 类型。

`pcie_cfg` 继续配置 transport、tag、超时、MPS/MRRS 等。BAR 信息通过上述共享映射交给 PCIe driver，不能在 `pcie_cfg` 再随机生成一套地址。每个 Host 的 PCIe DMA 与 VIO 也绑定同一 Host memory manager。

表项 owner 与访问 target 保持区分。例如 VF 的表项可以通过 PF0 BAR0 配置，不能根据 target 把 owner 改成 PF0。Notify 使能复用的是管理 target，不是业务 doorbell 所属 Function 的 BAR。

## 5. 实际队列信息与配置 sequence

VIO 保留 `prepare_external_configuration()`、确认和释放接口，并导出 DPU 写表必需的值：service/Function 身份、local/global qpair、TX/RX 方向、实际格式、ring 深度、descriptor IOVA、Notify 地址和消息向量等。导出的值来自实际分配结果；DPU 不按配置参数再次猜测 ring 地址或格式。

导出类型使用 DPU 已有身份/资源类型及必要的硬件字段，不复制完整 `vio_queue_setup_t`、VIO 对象句柄或另一套 VIO 参数解析器。

公共 `dpu_cfg_seq` 从启动 sequencer 的 config_db 取得 `dpu_env_cfg`，提供默认公共表流程及独立类别入口。它不再要求取得用户完整 `env_cfg`。BAR 相对访问 `dpu_bar_reg_seq` 使用同样的 DPU cfg 和 PCIe 映射，保留 `reg_acc` 的输入、输出与读比较控制语义。

VIO 集成层保留一个薄 sequence，继承 `dpu_cfg_seq`，只连接 VIO 准备、真实队列值导出、成功确认这几个生命周期步骤。表字段、地址计算、遍历和 PCIe 写入都在公共实现中。通过已有 AIP 注册方式把它注册为 `dut_config`，用户无需复制这些生命周期逻辑。

默认执行顺序保持现有行为：

```text
AF 声明并读取状态
    ↓
所选公共表、BDF、按完成模式选择的 MSI-X
    ↓
VIO 准备实际 ring 并导出队列信息
    ↓
VIO Notify 表 → Notify 使能
    ↓
QSCH → VTX/VRX → 队列使能
    ↓
可选读回检查 → VIO 确认配置成功
```

RDMA Notify 保留独立配置入口；本次新增使能不隐含把 RDMA 配置加入默认 VIO 流程。

保留独立 `configure_bdf()`／`configure_vio_notify()` 等批量入口和 virtual `write_bdf()`／`write_vtx()` 等单项入口。把只调用一次 `write_*` 的 `user_configure_*` 转发层合并到 virtual 写入口；用户仍可以按表覆盖实现。

## 6. Notify 使能的精确行为

| 项目 | 约定 |
| --- | --- |
| 地址 | 该批 Notify 表实际管理 BAR 的 base 加 `64'h0008_0044` |
| 数据 | `32'h0000_0001` |
| 宽度/byte enable | 4 字节，四字节均写入 |
| 触发位置 | 本次选中的 Notify 表项全部写成功之后 |
| 去重范围 | 每次配置调用内，每个不同管理 target 写一次 |
| 空选择 | 没有实际表项时不写使能 |
| 失败 | 表项写失败则停止，不发送该批使能；使能失败则本次配置失败 |
| 读回 | 不增加专门的使能读回或轮询 |

`0x80044` 已是完整 BAR 内偏移，不能再叠加 Notify 的 `module_offset` 或 `table_offset`。也不能写旧的 `0x20044`，或把 bit 1 当 bank 选择补进去。

使能寄存器范围在该批首笔表写之前与表范围一起检查。配置入口在写完有效表项后调用一个公共 `enable_notify(target, ok, why)`；VIO 和 RDMA 使用同一个实现。该 task 可覆盖，默认偏移与值集中定义，不为这笔必需写增加额外用户开关。

同一管理 target 连续调用 RDMA 和 VIO 独立配置时，各调用成功后均写一次 1。无需跨 sequence 的“已经使能”状态或额外事务管理器。

新增写通过现有 MMIO helper 和 `pcie_tl_reg_seq` 发送，计入每 100 次 DWORD 写插入一次 AF 状态读的计数。保持多 DWORD 表项从高到低写入，以及 VTX/VRX 数据端口四次写完才触发控制端口的顺序。这里保证的是现有 PCIe 配置路径上的发送次序，不把 posted write 的发送完成描述成 DUT 生效确认。

## 7. 参数与运行期刷新

参数按所有者使用 AIP 的 `aip_int`、`aip_enum`、`aip_string` 及集合宏读取。保留已有 `dpu.*`、`vio.*`、`pcie_cfg.*` 外部路径；内部字段改名时用局部同名变量保持原参数键，因为这些宏会字符串化变量名。

每个随机参数只有一个采样所有者。DPU 读取拓扑和公共硬件策略，VIO 读取最终 service/发包行为，PCIe 读取传输设置。用于资源分配、写队列表和发包的队列要求复用同一份采样结果。

首次构建顺序是：加载 DPU 拓扑输入 → 加载 VIO service 要求 → 将实际 service 资源需求交给 DPU → 一次解析分配 → 创建并连接组件。不能在 DPU 分配之后由另一轮 VIO 随机采样改变队列需求。

运行期 `load_params` 用已有 AIP 命令宏在顶层注册一次，不再手写 `project_load_params_command` 类，也不让每个 cfg 注册同名命令。宏调用的 task 更新命令的 `status/result_out`，保持失败不会被显示为成功。宏内部生成的适配类是 AIP 自身实现，无需用户维护。

刷新沿用当前能力边界：不重建 Host/PF/VF 或重分配 BAR；队列几何/表参数变更在无活动 ring 的允许阶段生效，之后重新执行配置 seq。运行期命令本身不发 PCIe 配置请求。本文不增加在线缩扩容、跨 seq 仲裁或新的 restore 缓存层。

## 8. 文件与命名收敛

| 当前来源 | 目标 |
| --- | --- |
| `dpu_device_env.sv` 内的 cfg 类及 project 的 DPU 构建部分 | `dpu_common/src/dpu_env_cfg.sv` |
| `project_dut_config.sv` 的公共值类型/上下文 | `dpu_common/src/dpu_table_types.sv` |
| `project_vio_config.sv` 的硬件 entry/策略 | `dpu_common/src/dpu_vio_table_types.sv` |
| `project_bar_registry.sv` 的资源查询 | `dpu_common/src/dpu_bar_map.sv` |
| registry 的 PCIe 路由、公共配置 seq、BAR reg seq | `dpu_common/integration/pcie` |
| project 的 VIO ring 生命周期及 IOMMU 接收关联 | `virtio_work/integration/dpu`，复用 VIO 核心接口 |
| `project_env.sv`、`project_env_cfg.sv` | 保留精简的创建、绑定和发布示例 |

公共名称使用 `dpu_env_cfg`、`dpu_cfg_seq`、`dpu_bar_reg_seq`、`dpu_bar_map`、`dpu_table_ctx_t`、`dpu_table_item_t`、`dpu_cfg_scope`。字段继续明确区分 local/global qid、qpair、BAR base、offset、IOVA 和 owner/target。

删除被替代的 project 类型/实现定义，更新 package、filelist、派生类和示例的引用，避免同一个类型在两个包内重新定义。旧 DPU layout/policy/builder 的 DUT 专属部分逐项替换，保留确有调用者的通用资源解析和寄存器执行接口。

旧驱动设备模型 `virtio_net_vip/src/devmodel/vdev_dpu_priv.sv` 有明确的驱动版本和旧寄存器协议依据。它不是当前真实 DUT 的配置依据。本次不把其旧驱动协议强行改成截图协议；迁移时检查对被替换生产 builder 的编译引用，旧驱动模型自己的协议常量留在其 devmodel 层。当前该文件的 builder 引用出现在驱动对照注释中，不能把注释引用当成代码依赖。这样既不污染新公共布局，也不删除已有驱动对照能力。

## 9. 格式和日志

类内使用 extern 声明，函数/task 实现在类外；一行一个声明或主要语句，多参数调用、结构赋值及判断分行。SystemVerilog 类型与变量名之间使用 Tab。

文件头和函数前用中文说明职责、所有权、输入/输出以及具体失败条件。只整理本次迁移/修改的区域，不进行无关文件格式化。

布局缺失只打印表名、Function、目标 BAR、缺失字段与配置入口；不直接打印整个结构体。正常配置日志按阶段汇总；Notify 使能记录目标、BAR 内偏移和值，详细 DWORD 日志保留在调试级别。

## 10. 验证与交付判据

所有仿真在指定 VCS 主机 `10.11.10.53` 执行。先完成 Notify 的针对性验证，再按迁移影响运行依赖编译和集成测试，不把未执行的测试写成通过。

Notify 针对性检查：

1. VIO 单队列和多队列：每个管理 target 只新增一笔 `+0x80044` 的全字节 DWORD 写，数据为 1，位置在最后一个 Notify 表 DWORD 之后。
2. RDMA 独立入口具有相同后置使能；使用现有 scope/记录测试核对实际目标。
3. 显式改用其他管理 BAR、多 Host、多个 owner 共享管理 BAR时，地址、RC 和去重结果正确；不能按 owner 数重复使能。
4. 空选择、布局或范围不合法、表写失败时不发送使能；使能失败正确返回失败。
5. 新增写跨过第 100 笔时保留 AF 状态读；不出现额外的逐表读回。

迁移验证检查：

- DPU 核心无需 VIO/PCIe 即可编译；PCIe 集成无需引入 VIO；完整参考环境编译无循环依赖或重复类型。
- 单 Host/PF、多个 PF/VF 和多 Host 读取的 BDF/BAR、qpair、MSI-X 资源一致；PCIe 与 VIO 共用实际 Host memory。
- packed 和 custom 的 VTX/VRX 字段来自实际 ring；Notify 排序、高到低 DWORD 顺序及间接触发顺序与当前 project 基线一致。
- 除新增使能写及由其触发的既有 AF 周期读，迁移前后同配置产生的 MMIO 内容和顺序一致。
- `reg_acc`、`dut_config`、命令行参数及允许阶段的运行期 `load_params` 可用；失败状态和简洁日志可辨认。
- 在实施开始前重新记录工作区已有差异，逐项保留并适配；本次设计不覆盖当前未提交的发包/恢复参数等修改。

完成后交付精简的完整 env/env_cfg/base_test 示例及编译顺序，说明需要替换的文件和命令注册点。源码迁移、仿真与远程推送分别报告，未请求推送时不推送。
