# 单个 DUT 配置 sequence，共用已有 env_cfg

本设计已按用户最新要求简化：用户只通过一个配置 seq 写 DUT，
不为其他 seq 重写或额外操作增加并发保护、版本计数、撤销状态机。

## 实现分工

- `project_env` 创建 DPU、PCIe、VIO，绑定 Intel VIF/Host memory/Function endpoint。
- `project_env_cfg` 保存参数、布局和 env 生成的资源：`dpu_setup`、`bar_registry`、
  `vio_setups`、`vio_envs`、`rc_sequencers`。`records` 只保存生成的 typed 表项。
- `project_dut_config_seq` 保存配置顺序和全部硬件配置 task；从同一 cfg 取数据，
  使用已有 `pcie_tl_reg_seq` 发真实 Memory Read/Write。
- `project_base_test` 等待平台就绪后 start 一个配置 seq，成功后才启动业务。

只新增 `project_dut_config_seq.sv`，不新增 context 类。
仍为一个 env、一个 env_cfg；不继承 dpu_device_env、不增设 global_cfg/SVT/建链。

## 对象传递

base_test 的 `set(this, "env", "cfg", cfg)` 交给 env。
env 再将同一对象以 `env_cfg` 键发布到 `pcie_env.*`，供配置 seq 在 `pre_start`
通过 `uvm_config_db::get(m_sequencer, "", "env_cfg", cfg)` 获取。
config_db 传的是对象句柄，env.connect 后填入的资源可以直接从 cfg 读取。
不复制资源，不逐字段传参。

默认单 Host 启动为 `config_seq.start(cfg.rc_sequencers[cfg.tl_slot_by_host[0]])`。
多 Host 仍由一个 seq 顺序处理，每笔访问使用 BAR 解析出的真实 RC slot。

## 正常流程

公共 BAR/AF（已声明时）/PFVF/BDF/Completion BDF/prefix/MSI-X 配置及平台验证，
然后准备本地 ring，依次配置 notify、QSCH、VTX/VRX，执行队列/MSI-X 使能和平台验证，
最后 `cfg.commit_vio_configuration()` 确认资源。任一步失败即返回，test 不启动业务。
平台独有的配置和读回由派生 seq 的 `user_*` hook 实现。

高 DWORD 到低 DWORD，每笔32 bit；VTX/VRX 四笔数据后写 control-clear、control-trigger。
保留字段、地址范围、访问路由和 PCIe 返回结果检查；不维护跨 seq 配置成功账本，
不支持并发配置、写版本检查或中止后自动恢复。错误不自动释放可能仍被 DUT 使用的 DMA。
核心 VIO 的资源创建/确认/停机释放能力保持原样。

字段以图片为准，驱动仅提供可修改的偏移示例，notify 单 bank。
BAR base 和 ring IOVA 由环境产生；用户给出 DUT BAR 内寄存器偏移和配置方法。

## 源码与验证

参考 package 只在 cfg 后 include 配置 seq；生产 filelist/package 不添加 integration。
`pcie_work`、`dpu_common` 无需本轮变更。

在 10.11.10.53 用 VCS 检查：正常单 seq start/get cfg、Packed/Custom、单/多 Host、
公共无 VIO、MSI-X、逐 DWORD 与间接6笔、字段/地址拒绝，以及12个独立仿真的
VTX/VRX 发送失败点（1..6）。驱动地址示例另行提取编译。
不再将跨 seq 并发、重写/撤销和 kill 恢复列为当前项目能力或验收条件。
验证结果记入 `docs/vio_external_configuration_validation.md`，不把模型证据当成 RTL 验收。
