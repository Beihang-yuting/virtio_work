# VIO 外部配置验证记录

当前项目已改为单个配置 seq，配置数据直接取同一 env_cfg。旧 env 配置接口、并发锁、
重写/撤销等条目仅描述下文对应版本的历史证据，不能作为当前接口说明。
当前用法见 [集成说明](../integration/project/README.md)，本轮结果见文末单 seq 验证。

证据分三层：核心/registry组件合同、真实 Intel VIP adapter→monitor→bridge→项目RC的
模型报文路径、用户实际RTL。前两层使用明确声明的模型平台；没有提供用户RTL，
因此这里不认证其模块基址、间接端口语义、PBA真实容量、QSCH调度或线侧收发。
“模型未测的软件合同”也单独列出，不能用RTL边界代替。

Task3历史产品基线为 `2426d2e0e25c911806e10404917ffb3ccfbf1381`，Task4随后添加验证与文档。
全分支审查基线 `f8230f68c5b48efcdfe9d17603341b86af3730fb` 的I1/I2最终修复采用
下文 `finalfix1` 冻结源码身份及六项聚焦证据；不把旧矩阵追记为新产品全量复测。
Task1/2/3已通过的未改源码证据保留原身份复用。全部仿真由指定5.6
验证代理在 `ubuntu@10.11.10.53`（`simv-ai`）通过 `bash -lic` 加载VCS/license执行，
VCS版本 `W-2024.09-SP1_Full64`。本地未使用旧AIP checkout进行编译。

## 依赖和复现方式

隔离根 `/home/ubuntu/ryan/vio_external_config_validation_20261107.DjqaPI` 下每个候选有
独立源码树和输出。Task1/2保留冻结source archive/逐文件SHA、原始日志和依赖provenance；
Task3/4才采用独立控制端manifest、本地/远端重新生成manifest一致性及远端逐文件
`sha256sum -c`握手，不能把后来的流程反写到旧轮证据。
依赖必须保持这组匹配版本，尤其AIP的 `src/sv/aip_core_pkg.sv` 布局。

| 依赖 | Git HEAD（有元数据时） | 编译入口 SHA-256 |
|---|---|---|
| aip_core | `938ee5af5ad7a440ae8f7cfc1bea83d0f10384cf` | `dadcb1ddb858a220442c5f0e40f36570607c7010b822a34d59a50f940ddf5c8d` |
| dpu_common | 快照无 Git 元数据 | `36dbad2db046ba1c75fe83683205ba3a5a4defe774185f44cb8f84d40afa844e` |
| host_mem | `35ec087014744ec85cf6c0fe17e1f7118ee7a7b7` | `ee03b07c3a84606376b0855116c5f2da478c6fde92986a4a8639f71bbdf032ba` |
| net_packet | `b8a4c1469511159a59d1a547ed0b5fe896a68e5e` | `60b6adf46f550d99a25567b9af00b659862bbfbace5f64154dfbb4d813cd229f` |
| pcie_work | `2e5ba74aeb1090d0e893efa8b42515c782ddb5d7` | `29d91675a2bfb3b4da0ef15f8232b07316c5abec0284c547c50729755c67cbf7` |
| pcie_intel | 快照无 Git 元数据 | `3905978c8017ac90b192264d885daf0468530aeb1020eae0e6761eb0b24bb12b` |
| queue_work | `1b143469bdb65df128d6dead32c9aabb8c9d187b` | `55d8fad88dcc69afcd4e476040f75b8a644115740db0224a882b68086bcee0cc` |

入口 SHA 分别对应各依赖的 package 文件；完整绝对路径和 VCS ID 在远程
`dependency_provenance.txt` 及日志归档中。

设置各依赖根后，在仓库根目录使用以下命令；`out` 是新建的本轮输出目录。
模型testbench才使用 `project_tests.f`，真实项目使用自己的top/bind。

```bash
out=build/project_external
mkdir -p "$out"
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -debug_access+all -f filelists/project_integration.f -f filelists/project_tests.f \
  -top project_env_tb -Mdir="$out/csrc" -o "$out/simv" -l "$out/compile.log"
scripts/strict_log_check.sh compile "$out/compile.log"
log="$out/contract.log"
timeout 180s "$out/simv" -exitstatus +UVM_TESTNAME=project_external_contract_test \
  +UVM_VERBOSITY=UVM_LOW <场景plusargs> -l "$log"
scripts/strict_log_check.sh sim "$log"
```

验收必须同时满足进程RC、strict检查、所要求的PASS marker和完整UVM summary。
正常测试要求RC/strict=`0/0`、W/E/F=`0/0/0`；期望fatal负例单列核对精确ID/理由，
不能混入正常strict汇总。

## 已保留的冻结证据

| 代号 | 冻结源码和运行 | 可复用的结论 |
| --- | --- | --- |
| T1 | `646a458`，`project_bar_registry_test`，244 checks；三个精确fatal负例 | 路径/域/owner/偶数BAR、完整父类发送与codec sideband、打印去重；不等同Intel整条接收路径 |
| T2P | `b79585f` GREEN8，`virtio_external_parameter_test`、`virtio_external_direction_test`；invalid-checksum精确fatal | 最终service参数优先级、方向和QID16；四模式生命周期已被下列T3C重跑覆盖 |
| T2R | GREEN8普通maintained filelist六项全绿 | queue semantics、unit、host mem reclaim、real driver、private ring contract、private driver；受Task3影响的两项flow再由T3L覆盖 |
| T3C | compile13，`virtio_external_configuration_test`、direction、lifecycle Packed/Custom×poll/MSI-X、integrity default/release，共8项 | 核心prepare/confirm/release/integrity；MSI-X为observer注入，DMA使用IOMMU API，没有Intel RX |
| T3P | compile13项目12场景，全绿；产品 `9f26a55` | types、VF32 TXRX、2VF×16、TX-only32、noVIO、2Host/2VF、小规模Packed MSI-X/Custom poll/Custom MSI-X、1/2pair取消、双Host revoke |
| T3W | compile14 `virtio_worker_wait_test` | 两个普通FSM各两pair独立计时进展、stop ack及stop后停止调用；避免把旧单pair证据扩写为并发证明 |
| T3F | `2426d2e` fix1b六场景 | typed rewrite/partial send/verify并发失效；PF-only对稀疏VF0/VF3消费者保护；Custom MSI-X、双Host revoke、取消恢复 |
| T3L | 同一fix1b源码普通入口重新编译，两项flow及compile13 legacy AIP | ordinary `virtio_real_driver_flow_test`、`dpu_priv_driver_flow_test` 与 `virtio_aip_command_test`；均为MODEL/录制组件，不是RTL |

T3P具体plusargs：默认、`+PROJECT_TWO_VFS`、`+PROJECT_TX_ONLY`、`+PROJECT_NO_VIO`、
`+PROJECT_TWO_HOSTS +PROJECT_TWO_VFS +PROJECT_SMALL`、`+PROJECT_SMALL +PROJECT_MSIX`、
`+PROJECT_SMALL +PROJECT_CUSTOM`、`+PROJECT_SMALL +PROJECT_CUSTOM +PROJECT_MSIX`、
`+PROJECT_SMALL +PROJECT_TX_ONLY +PROJECT_CANCEL`、同项加`+PROJECT_ONE_PAIR`、
`+PROJECT_TWO_HOSTS +PROJECT_SMALL +PROJECT_REVOKE`；另一个test为`project_external_config_test`。
T3F重写是 `+PROJECT_SMALL +PROJECT_REWRITE`；PFVF为
`+PROJECT_SMALL +PROJECT_TX_ONLY +PROJECT_PFVF_GUARD`，单VF再加`+PROJECT_PFVF_SINGLE`。

| 证据文件（本地 `build/vio_external_config_validation/` 下） | SHA-256 |
| --- | --- |
| `validation_logs.tar.gz`（T1基础/provenance） | `d0dc190956e4f328fc7d5948c155d455b35820ab325babefc1b01bdfbc8c2bf8` |
| `r1_validation_logs.tar.gz`（T1最终R1） | `cc812e6d15792d5555c3c52837550c3cbaf4bb4630cf6e675f0a1b8ccafbb9a1` |
| `remote_evidence/task2_r1_review_validation_logs.tar.gz`（T2最终R1） | `341227ecf56ff759afad8fd64d97698d5e2d0287519e463c4168a1f4b2fe403f` |
| `task2_r1_green_snapshot/full_tree_green3.tar.gz` | `5e8cd3d0e928763914ee93134821d327f1dd332155b9605dc6c450933e2c2fb8` |
| `task2_green8_snapshot.tar.gz` | `6dccbf4513842e91605d7ee7669befc804f2362f7bee392c91554a756098edd2` |
| `task2_validation_logs.tar.gz`（GREEN8） | `ea55e0e0fae870d9651a6f7ed8e813330cce6f0a252e544c595614763becea8e` |
| `remote_evidence/task3_final/results.md` | `f5d060c2a37ff8073db5c1365bdbca3b871e1989e3ca84341137fa7174067400` |
| `task3_final_validation_logs.tar.gz` | `86da777f24a2be351e8571aed12326b81306bf6a8e19f88d252555ad80c766f9` |
| `remote_evidence/task3_fix1b/results.md` | `7d2eeb70f22771ecfeb27dac2af773b8766f7b969c9d18a086fc39c2ba6f9fbb` |
| `task3_fix1b_validation_logs.tar.gz` | `b54ca969becbed7649dfb3a9e40e7d30ea2169ecff166575efa3107e63697735` |
| `remote_evidence/task3_fix1b_compat/results.md` | `327428be5a8f3af68c9477d776a81268199e123bc4a8b764bdc2f90faf21e641` |
| `task3_fix1b_compat_validation_logs.tar.gz` | `a433b8314b9e7c4bcb17f5fc5062f5954c2a66e42784e8afa233d4de7c47b6e8` |

T1最终五文件清单是 `r1_green_snapshot/sha256.txt`；T2最终完整源码逐文件清单是
`task2_r1_green_snapshot/source_green3.sha256`。旧R1中间归档不替代上列最终review证据。

compile13/14控制端150文件manifest SHA分别为
`baa1c9f4a0b57477fff0798b344d47fc9727cd985a3e316759e3aaac517bdf7d`、
`bbc2aefe63dffa0d1a80a6bc6e937ec0d440a8a86fae24a5c93b9b051d226c6d`；两者只有worker fixture
不同，其他149项一致。fix1b控制manifest为
`e0c4e17698570249aa7c53b00ae26a77fe30fed5226af17ddb5971ad19ccba8b`，只改变project env与
integration test；完整158文件manifest为
`237d809fa71c9652e33b772ad15254039b3d936008b2ac28162e31f3d08b9b07`。

## Spec §9逐项核对

编号与[批准规格](superpowers/specs/2026-11-07-vio-external-device-configuration-design.md#9-验证要求)
一致。T4是新contract fixture；各场景是否通过、源码冻结身份及失败轮记录见后文。
下面明确区分组件断言、真实Intel报文路径与仍须实际RTL确认的行为。

| # | 分组 | 已有/新增断言和证据 | 限制 |
| --- | --- | --- | --- |
| 1 | 生命周期 | T3C spy无prepare/confirm访问；T4真实Intel请求计数覆盖build/public export、prepare、commit/idle | 不证明平台自写hook无其他总线副作用 |
| 2 | 数据面 | T3C逐字节512B TX与独立12B Packed header；T3P真实Intel TX完成 | TX payload byte golden来自核心IOMMU路径 |
| 3 | 数据面 | T3C导出与实际IOVA；T3P真实Intel非identity双向DMA；T4真实RX buffer/used/CQ写 | 实际RTL DMA另验 |
| 4 | 解析/PCIe | T1相同BDF/地址隔离；T3P双Host/双VF Function IOMMU；T4多Host/MMIO/RX | 不把仅数值不同当隔离证明 |
| 5 | 表项 | T4显式pinned global qpair100/103等，local pair不重编号，notify按binding | fixture全局编号不是默认值 |
| 6 | 生命周期 | T3C origin/generation/方向/深度/capability；T3P typed8种变更零TLP；T4缺布局/坏策略 | 每种错误须按实际断言解读 |
| 7 | 生命周期 | T3C失败/释放完整性；T3P中途hook失败、双Host预检、保留DMA；T3F revoke | quiescence是平台给出的事实，不由stop推断 |
| 8 | 生命周期 | T3C无自动协议访问；T4真实idle计数；项目未安装executor | 无后台common config轮询 |
| 9 | 标准回归 | T2R/T3L普通入口；T3P取消注册仅business；静态filelist隔离 | legacy能力保留在独立入口 |
| 10 | 数据面 | T3C当前Custom512B TX/RX、CQ映射；T4真实512B RX；T4当前格式组件专项核对TX CQ初值0080、RX N-1、长度512及6个完成跨4槽回绕；T2R TX wrap | RX wrap组件专项直接写IOMMU背后的CQ，不能称Intel wrap收包；真实Intel RX另有独立证据 |
| 11 | 数据面 | T4双Host/双VF混合Packed/Custom、非连续global qpair，mode绑定和实际RX | 不依赖AF0/gfid0；实际RTL混合调度另验 |
| 12 | 表项 | T3P VF32/双VF16、hook计数；T4 AF32+额外11精确fatal | 不把总qpair容量当每Function容量 |
| 13 | 表项 | T3P typed独立field golden；T4控制场景真实SW Completion BDF、prefix、AF、MSI-X control/function、SPWRR/TC_WEIGHT/QUEUE_AUX/RNET；notify单bank精确计数；缺hook/layout拒绝 | 未知寄存器地址均为显式模型声明；实际RTL编码仍需平台实现 |
| 14 | PCIe | T4完整4/8/12/16B与稀疏mask、真实BAR2 sideband、posted和显式readback、UR Completion；T1禁止Config | UR是模型注入的实际Completion |
| 15 | 数据面 | T3C四模式；T3P实际Intel TX无IRQ不完成；T4四模式实际RX无IRQ不完成 | 无poll fallback |
| 16 | PCIe | T3C任意地址/full data/共享消息；T3P公共catalog sink与双Host；T4消息不在APIC、exact Host/data匹配及同域歧义拒绝；mixed MSI-X用相同address/data核对实际跨Host不提前唤醒 | 消息歧义专项为组件API断言，实际Intel消息投递另由T4 RX证明 |
| 17 | 表项 | T3C ring/notify分离；T3P独立公共MSI-X；T4显式两word PBA读index1、拒index2，table/PBA重叠拒绝；精确配置写计数 | PBA容量由模型声明；未认证用户RTL容量 |
| 18 | 生命周期 | T3C early/shared permits；T3P新代取消门禁；T4跨代旧pending清除、Custom MSI-X两次真实RX和显式用户rearm Memory写 | rearm端口为模型声明，不认证实际RTL self-mask电路 |
| 19 | 表项 | T3P32/32、TX-only0VRX；T4 sparse qpair/多Host，optional queue_aux精确每pair一次、SPWRR/TC_WEIGHT每service一次 | 共享项按实际record key去重 |
| 20 | 生命周期 | T3P中途hook失败无自动重试与DMA保留；T3F partial send/rewrite/verify交错失效 | 失败需平台显式恢复 |
| 21 | 表项 | T3P noVIO公共配置、public scope；T4原子BAR group、独立queue事务捕获 | 不填最大容量空项 |
| 22 | 解析/表项 | T3F sparse VF0/VF3与PF1独立consumer；T3P noVIO保持公共配置；T4 PF0两VF、PF1一VF，完整MMIO/队列/RX路径 | unequal VF场景在冻结前声明实际成员，不在运行时改快照 |
| 23 | 生命周期 | T3P scoped verify/缺依赖；T3F无关PF仍可写和验证修订 | 全部类别交错增量组合仍非穷举 |
| 24 | 表项 | T1真实租约；T4完整BAR组与split scope在hook前拒绝 | 平台BAR编码可表示性由实际hook负责，不能冒充图片已给出编码 |
| 25 | 表项 | T3P21型独立字段golden/保留位与typed X；T4 reserved/X策略、MMIO Z、vtx.dma_info=16窄化前fatal；SW与EP独立身份场景 | 全部整数的组合不是穷举 |
| 26 | 表项 | T4 net128/group64、显式模块+图片offset、2ETH/VNET与4ETH/ETS、shared冲突 | 硬件调度行为另验 |
| 27 | 表项/生命周期 | T3P不同RAM；T4共享RAM双Host、Host0释放保留Host1并拒reprepare，全部释放后新代改变Host0预取区；alignment/capacity/overlap/headsplit/fpga_high/prefetch_depth/Custom8192拒绝 | RAM范围校验是模型合同；实际RTL RAM组织另验 |
| 28 | PCIe | T4真实VTX/VRX data→clear→trigger、同端口两并发写不可交错、notify/MSI-X linear/RDMA高DWORD先、PBA只读及W1C8005单写无RMW | 所有端口/掩码均显式平台声明，不含旧bank/commit |
| 29 | 表项 | T3P noVIO公共MSI-X、显式mapping validator；T3F稀疏PF族 | 所有mapping/layout负例组合非穷举 |
| 30 | 生命周期 | T3P8种typed mutation零发送；T3F重写必须重enable/verify；T4按域QSCH和全旧代释放后的prefetch新策略 | 核心enabled/pairs/geometry不在prepare重采样 |
| 31 | PCIe | T1路由/错误域；T4PFVF_GUARD通过PF0管理窗口配置VF3，直接访问VF3 BAR2捕获真实PF/VF/BAR sideband | 管理窗口与owner独立；实际用户RTL译码另验 |
| 32 | PCIe | T3P实际adapter→monitor→bridge→RC、wire requester/Tag/PF/VF completion；T4 RX/notify | 实际用户RTL不在模型中；未安装driver的配置失败由构建检查/T1负例支撑 |
| 33 | 解析 | T1 244checks：short/full、parentPF、非连续ID、unknown/odd/trailing/overflow，发TLP前失败 | unchanged证据复用 |
| 34 | 解析 | T1冻结副本/旧代拒绝；T3P publication冻结；T4同pf0.bar0路径在两个独立冻结snapshot分别解析1MB/3MB租约 | 改租约对照为registry组件API；新topology需重建env |
| 35 | 解析/表项 | T1逐项含末地址、64位BAR去重与打印去重；T3P类别target；T4保持connect路由安装，延后首次BAR日志精确1+实际BAR数、公开重复调用去重/同句柄/零TLP | 模型日志只代表冻结模型租约 |

## 设计裁决及代价

1. **Requester、Intel sideband与PFVF关系**：EP wire Requester编码和Intel PF/VF tuple
   保持独立显式映射，canonical requester必须与冻结registry一致；SW requester仍是
   snapshot BDF。图片未给出完整 `First_vf_offset ↔ 实际VF成员 ↔ Pfvf_id` 公式，
   因此cfg必须提供无副作用的完整family关系validator。缺规则只阻止PFVF及依赖的
   MSI-X，BAR/BDF保持独立。代价是平台需要额外实现一次纯校验override；测试的
   `vf_id+1`仅是fixture，不能默认为硬件公式或以10位宽度检查替代关系验证。
2. **停止代验证失败的撤销**：对已经认证且worker停止的generation，验证失败必须
   关闭core confirmation、runtime readiness、FSM readiness和ops external_active。
   revoke使用已发行handle、origin、generation、scope和私有凭证认证，保留队列、
   mapping、在途DMA和通知，不因几何损坏而拒绝关闭业务门禁；所有Host先预检再变更。
   外来/旧代/坏scope无副作用；confirm/release仍执行完整integrity检查。
   同代reconfirm不清AIP取消。代价是额外guarded revoke API和显式重新验证，
   没有增加设备访问或提前回收内存。
3. **首次路由安装与首次BAR日志分开**：本参考env必须在connect安装RC registry，
   EOE和后续公开调用只幂等处理同一快照。规格§9.35的晚首次日志用
   `print_bar_map=0→1`验证，未就绪registry拒绝打印复用T1证据；不复制connect、
   跳过接线或清空已发布对象来制造晚路由安装。代价是topology变化必须重建env，
   后续publication不能替换活动路由。

## Task4结果与自检

最终源码为contract6。11个正常场景、13个策略拒绝场景及3个精确fatal负例
全部按各自验收条件通过；正常/策略场景严格检查通过，fatal负例单列验收。
生产基线不变，测试清单增加一个contract fixture。控制端151文件manifest
`40232af766141c024c609ebcb5013c9a916ecfb025aa497153a2323b66b6cf72`；
控制端、本地独立生成与远端重新生成一致，逐文件151/151通过；
测试文件SHA `bcaa4169cb0f5304501073c664d222eeab6ad71509c1414758267c2a3bd9f77a`；
测试filelist SHA `39c8f1740d3183943a92dbbc369ce18d73c198c4a4b8df451d5ef84875d83cf8`。

contract5已完成其余10个正常场景和13个策略拒绝场景，均RC/strict=`0/0`、
W/E/F=`0/0/0`，要求的marker完整；三个精确fatal为RC/strict=`3/1`、
W/E/F=`0/0/1`并逐一核对唯一ID/reason。contract6只补late BAR print场景，compile/sim/strict均0、W/E/F=`0/0/0`，
2051 checks与标准8+打印专属marker齐全；SCB19/19 matched，mismatch/unexpected/timeout均0。
其运行日志SHA为 `342fbfd40080ed7a1fb3184339944ed86f21eea37d1933f8b304fc32b011caff`。
contract5→6只改测试的晚打印分支；其余150份控制端源码不变，10个正常及13+3个
负例复用contract5冻结运行，未声称所有场景均重新运行于contract6。

最终统一结果与原始日志保存在以下文件；路径相对仓库根目录。results逐场景列出
命令、检查数、marker、RC/strict、UVM/SCB及运行日志SHA，不以进程退出码单独判定。

| 证据 | SHA-256 |
| --- | --- |
| `build/vio_external_config_validation/remote_evidence/task4_contract6/results.md` | `16552344788403029c3ad46504222ed8ce20590df3ac58da82615325a0236c47` |
| `build/vio_external_config_validation/task4_final_validation_logs.tar.gz` | `594eb4930aeb5abd61f7e63cb964e3ededfd15badcc9630f71fcebebf7a596cc` |
| `remote_evidence/task4_contract5/SHA256SUMS`（193项通过，位于同一build根） | `49dc346c4dc65128a8ddf2214acc4f2631a1d03eb5c1ea0d5839472a97503499` |
| `remote_evidence/task4_contract6/SHA256SUMS`（21项通过，位于同一build根） | `d9e8f54021650f3c09eb99568f7c95952c5caacef789dcc68ac17a103dec3f9d` |

复用的contract5控制端151文件manifest为
`686e5c2a19feb50a1a05312911765c7ec20384d3b04ad6719b4dc3467b21663a`，
其测试文件为 `a503823fff6ce469ac9656e0ae1137ae1db66746af6ca1f8cb7b28ce1d2d590b`。
5/6均完成独立本地/远端重新生成及151/151逐项核对；compile日志SHA分别为
`39654063fea1482c70c85dd770ecfb7dead22e01d655ec7faff704d026aeb47a`、
`65377c586fec17e8c34c6b1730fd1162d548e74902b8f473b6ef8cac3ec01c6d`。

正常场景均为 `+UVM_TESTNAME=project_external_contract_test +PROJECT_SMALL`，
下列额外plusargs应分别运行，不能把不同场景的marker拼成一次通过：

| 场景 | 额外plusargs | 重点断言 |
| --- | --- | --- |
| Packed polling | 无 | 完整MMIO、512B RX、顺序/组件合同、新代IRQ清理 |
| Packed MSI-X | `+PROJECT_MSIX` | 完成写不代替消息，真实Intel消息后交付 |
| Custom polling | `+PROJECT_CUSTOM` | 无Virtio header，私有CQ长度 |
| Custom MSI-X | `+PROJECT_CUSTOM +PROJECT_MSIX` | 私有CQ与消息门禁 |
| mixed两Host polling | `+PROJECT_TWO_VFS +PROJECT_TWO_HOSTS +PROJECT_MIXED +PROJECT_ETS` | 混合格式、4ETH/ETS、共享RAM、部分Host释放与重分配 |
| mixed两Host MSI-X | 上项再加 `+PROJECT_MSIX` | 相同address/data的Host0消息不能给Host1提前完成许可 |
| unequal VF | `+PROJECT_TWO_VFS +PROJECT_UNEQUAL` | PF0两个VF、PF1一个VF |
| late BAR print | `+PROJECT_LATE_BAR_PRINT` | connect静默安装路由，运行期首次BAR日志逐项计数、同句柄、重复去重/零TLP |
| self-mask | `+PROJECT_CUSTOM +PROJECT_MSIX +PROJECT_SELF_MASK` | 两次RX之间显式模型用户rearm写 |
| sparse VF3 | `+PROJECT_PFVF_GUARD` | VF0/VF3实际BAR2与管理窗口sideband |
| optional controls | `+PROJECT_MSIX +PROJECT_CONTROLS` | SW固定BDF真实分配、prefix及所有已声明控制项 |

| 正常场景 | 检查数 | 运行日志SHA-256 |
| --- | ---: | --- |
| Packed polling | 2048 | `ee5a7c74bfe622688ce645b38f9989bab8134b2905e1ebbf36483885da3fa223` |
| Packed MSI-X | 2049 | `91b56b644928a8a1fe60f55bf55a1a027ed657ef3cba47029b10dca89a4e2280` |
| Custom polling | 2046 | `3b681cb1b894674c4e3c7e9e0d314581cf62fe35f95dfc569d122a9cb351224f` |
| Custom MSI-X | 2047 | `78ffbf48fb4fbb1650134b910048e9fec2363c1118894718cf7ee0a7e0acc669` |
| mixed两Host polling | 5728 | `3d9365e467eb6145fd06e6147c50105a306795dc20c897b97a07550504c138aa` |
| mixed两Host MSI-X | 5732 | `950a43f9ba06cfe1ff2e6bae93d9c5d795bcb82454f64295a900c9a7464f6497` |
| unequal VF | 4556 | `512541045d9af9cd3ab624edadf73624d9b6b2cbe3afffb8599c3603fbc91894` |
| late BAR print | 2051 | `342fbfd40080ed7a1fb3184339944ed86f21eea37d1933f8b304fc32b011caff` |
| self-mask | 2601 | `338192d2f0f600113133e2e15202f4c5948966565b6cb936280d24680f73e209` |
| sparse VF3 | 3418 | `2c2a96570fe242dae5092d6b3ff91fff3fc5e428cc06dcc29d4a4d15af743065` |
| optional controls | 2193 | `7a906536ee9c816812b4884db6e1fac5d0f9a4812e2e8a69804e3ec566043a15` |

每个正常场景要求实际出现一次 `PROJECT_MMIO_CONTRACT_PASS`、
`PROJECT_PUBLIC_IDENTITY_PASS`、`PROJECT_CURRENT_CUSTOM_RING_PASS`、
`PROJECT_OPTIONAL_STATE_PASS`、`PROJECT_INDIRECT_SERIAL_PASS`、
`PROJECT_INTEL_RX_PASS`、`PROJECT_GENERATION_REUSE_PASS`、
`PROJECT_EXTERNAL_CONTRACT_PASS`；controls另要求 `PROJECT_CONTROLS_PASS`，
late BAR print另要求 `PROJECT_LATE_BAR_PRINT_PASS`。

13个策略拒绝场景使用相同test和 `+PROJECT_SMALL +PROJECT_POLICY_CASE=<值>`：
`alignment`、`capacity`、`headsplit`、`reserved`、`unknown`、`qsch_overflow`、
`missing_layout`、`missing_hook`、`fpga_high`、`pba_overlap`；
`overlap`、`qsch_conflict`再加 `+PROJECT_TWO_VFS`；`prefetch_depth`再加
`+vio.queue_size=256`。每项要求 `PROJECT_POLICY_REJECTION_PASS`，RC/strict均0，
零配置TLP、保留已导出资源、拒绝提交和未确认停机释放，然后显式quiescence释放。
策略汇总 `task4_contract5/remote/project/policy/results.tsv` SHA：
`79c63c64bcc572acf646a53876e3f287bdc5e969936f664c6510c971143d4a20`。

三个expected-fatal场景使用相同test及 `+PROJECT_SMALL`：

| 额外plusargs | 精确fatal ID | 必须包含的reason |
| --- | --- | --- |
| `+vio.h0.pf0.i0.enabled=1 +vio.h0.pf0.i0.pairs=32` | `DPU_DEVICE_ENV` | `AF ordinary and extra qpairs exceed the per-device ceiling` |
| `+vio.vtx.dma_info=16` | `PROJECT_CFG` | `vtx.dma_info exceeds declared width` |
| `+PROJECT_CUSTOM +vio.queue_size=8192` | `PROJECT_CFG` | `external mode requires exact nonzero Packed/Custom geometry within capacity` |

fatal汇总 `task4_contract5/remote/project/expected_fatal/results.tsv` SHA：
`5234c4157d8aeb9ca747e354162914d3ad18ee921ddb3efbc87d91ca4f1d7419`；三个结果
均已核对RC/strict=`3/1`、唯一指定fatal与UVM=`0/0/1`，不混入正常strict GREEN。

UR负例仍经实际Intel引脚产生UR Completion，并要求MMIO返回失败。模型在该请求已
进入记分板pending、尚无Completion tracker时，仅把此request key的
`expected_cpl_status`声明为UR；不改线包或计数。唯一预期 `RW_SEQ` UR warning
按severity/ID/完整状态字符串精确捕获且要求一次；记分板最终仍须零mismatch/unexpected。

保留的失败轮：contract1两个fixture `IRPC`（packet adapter ref要求byte queue，
测试用了dynamic array），无仿真；contract2 compile通过，SMALL暴露预期UR未声明与
notify共享项去重的测试预期错误；contract3 compile RC/strict=0/1（三个enum初始化
warning），SMALL诊断RC/strict=0/1、W/E/F=0/1/0，七个早期marker均齐全，但UR遗留
一个SCB mismatch。前三轮均不计GREEN，也没有把fixture问题当产品缺陷修复。
contract4 compile与SMALL均RC/strict=0/0、W/E/F=0/0/0，2048 checks与8 markers齐全；
记分板19 Completion全部matched，mismatch/unexpected/timeout均0。其余矩阵未运行；
自审发现可选控制的两处模型相对偏移错误，contract5只修Completion BDF为
`module0x300000 + relative0x18000`、RNET为`relative0x15000/capacity256`。
这些仍是模型平台声明，不能迁移为用户RTL默认值。
contract5的late-publication fixture失败于“late publication was already performed”：
它忽略connect已经发布并安装RC路由的前置条件。控制端按规格§9.35裁决，将该项
修正为晚首次BAR日志，不绕过connect或清空已发布对象。contract6只改此fixture，
产品不变；未就绪拒绝打印复用T1组件证据。
5的稀疏VF3场景曾被脚本误要求父integration test专属`PROJECT_PFVF_GUARD_PASS`；
按contract实际八个marker和真实sideband断言复核既有全绿日志后接受，没有重跑。最终文档明确不支持运行时首次路由安装；拓扑改变的代价是重建env。

静态门禁：`python3 scripts/render_project_code.py --check`、`git diff --check`，
生产filelist/package无项目入口；新SystemVerilog使用extern、真实Tab和中文意图注释。
未修改外部依赖或旧AIP checkout，不提交build产物，不推送。


## 最终审查修复：finalfix1（I1/I2）

I1修复让prepare/commit/release在配置、使能、验证批次hook或独立checked写仍活动时
零副作用拒绝；不在helper内递归获取批次锁。I2以冻结实际owner service和经过校验、
去重的显式shared消费者建立统一控制依赖；AF/SPWRR/TC-weight的平台作用域必须通过
`consumers_complete`完整声明。实际硬件作用域仍由平台负责，不从PF/AF名称猜测。

冻结manifest为 `finalfix1-controller-source.sha256`（151项），SHA-256：
`0885d1e54f28220aac683d49194411c083d9070af8b6ecb9fc0c7b8333a3eb94`。
控制端独立manifest、本地151/151、全新远端重新生成manifest逐字节比较及151/151
`sha256sum -c`全部通过后才ACK编译；结束时控制端再次确认当前151源码未变。
相对审查基线只有三个编译源码改变：

| 文件 | finalfix1 SHA-256 |
| --- | --- |
| `integration/project/project_env.sv` | `9842b7931f46e6108b5a826c51b3d30cdb0aff7c6a4cfc86768ff62a633fcb58` |
| `integration/project/project_dut_config.sv` | `c8284e2126faeefed848b39f156add0e043836405841ff5ada913441c8145f09` |
| `integration/project/tests/project_external_contract_test.sv` | `1e52c74dbf87b38ca6e434567e113ca4074d7cd2fa1ea34e4b1d774481d13249` |

远端候选根为
`/home/ubuntu/ryan/vio_external_config_validation_20261107.DjqaPI/finalfix1_work`，
`out=build/vio_external_config_validation/finalfix1/project`，日志为`$out/matrix/<row>.log`。
编译使用本文前述两个project filelist、`project_env_tb`与同一VCS选项；compile/strict
为0/0，compile log SHA `cfaa607ccfc75662115c1e3ebf2668a8f25648dda2e662f6a0a96a5e9c28707d`。
逐行执行命令形式如下，`testname`和`plusargs`取表中值：

```bash
timeout 180s "$out/simv" -exitstatus "+UVM_TESTNAME=$testname" \
  +UVM_VERBOSITY=UVM_LOW <plusargs> -l "$log"
scripts/strict_log_check.sh sim "$log"
```

六项全部sim/strict=0/0、UVM W/E/F=0/0/0，每个指定marker恰好一次；所有PCIe
scoreboard mismatch/unexpected/timed-out=0/0/0，两Host场景的两个scoreboard均通过。
除rewrite外均为`project_external_contract_test`；rewrite为`project_external_integration_test`。

| row | plusargs | 必需marker（均有`PROJECT_`前缀） | log SHA-256 |
| --- | --- | --- | --- |
| lifetime | `+PROJECT_SMALL +PROJECT_LIFETIME` | `OPERATION_LIFETIME_PASS`, `GENERATION_REUSE_PASS`, `EXTERNAL_CONTRACT_PASS` | `f417de468aef19178b6b4396f99199bda994fa705d0b958159a393ca9ae2f9e3` |
| control_guard | `+PROJECT_SMALL +PROJECT_CONTROLS +PROJECT_CONTROL_GUARD +PROJECT_MSIX` | `CONTROL_CONSUMERS_PASS`, `CONTROLS_PASS`, `EXTERNAL_CONTRACT_PASS` | `0ab9202b1faabd739e5f3af4a94fef7eefebc70d5f85dbdaf0feb9f1df2353c9` |
| control_scope_missing | `+PROJECT_SMALL +PROJECT_CONTROLS +PROJECT_POLICY_CASE=control_scope_missing` | `POLICY_REJECTION_PASS` | `ee1fd6db1c57c14451ed0da1c2a8957ce9254387e17e149d8db3132d20dda055` |
| control_consumer_unknown | `+PROJECT_SMALL +PROJECT_CONTROLS +PROJECT_POLICY_CASE=control_consumer_unknown` | `POLICY_REJECTION_PASS` | `97c820bb702277953e72683ad2db35eba0c596b73bf12d31861d69f712ab8071` |
| rewrite | `+PROJECT_SMALL +PROJECT_REWRITE` | `REWRITE_PASS`, `EXTERNAL_FLOW_PASS` | `a2184849cf3d97ea71dec32cf8dc871ef0e6692bcbc05c265203f30a46c48ff9` |
| two_host_msix | `+PROJECT_TWO_HOSTS +PROJECT_SMALL +PROJECT_MSIX` | `GENERATION_REUSE_PASS`, `EXTERNAL_CONTRACT_PASS` | `fb61e4620e69a42f7cf8e9bd102d9b4f03e6bff1aa4ca230f526ed29340247f4` |

lifetime覆盖间接独立写/使能的真实等待、configure/enable在helper前等待、verify返回前
等待五个窗口。每次release/commit/prepare均以精确活动操作诊断拒绝，setup/ring和
核心mapping完整性不变；恢复操作成功后正常release/reprepare，旧代typed写/使能/
验证/提交仍拒绝且不发包。control_guard覆盖自动owner消费者、重复显式shared去重、
confirmed/stopped及running两阶段typed/public写在hook/TLP前拒绝、独立PF正常使能，
以及shared公共验证失败撤销VF确认而保留DMA、显式恢复成功。两个策略负例断言精确
诊断、零hook、零requests/completions、保留资源和最后合法释放。

完整证据位于 `build/vio_external_config_validation/remote_evidence/finalfix1/`：

| 工件 | SHA-256 |
| --- | --- |
| `results.md` | `34bf7fe21a647565db741aca93cd44af0b4b8a9c13a90b868a3f01bc353bbdba` |
| `SHA256SUMS`（50项全部复核通过） | `778292e6de319ad0a20aea8c79adde262bd5ea63fc6c4b5be2a5f6ee9769e081` |
| `commands/run_primary_rows.sh` | `5a6895c2ee4b0a5c95a50e3cca6a6de6e2561701aacad5f817dcc5acf3101221` |
| `commands/run_remaining_rows.sh` | `c771d128ce932a09e8ffc9671700143b2e8454e5323318fc378ccc04e23b190e` |
| `build/vio_external_config_validation/finalfix1_validation_logs.tar.gz` | `00a089bab1be8b03ab3ff0339b983ac4ab3d0ca23ffce4eebfb5d888b4e342da` |

I1/I2源于审查的具体源码交错分析；新catalog字段与旧fixture不兼容，没有声称精确旧基线
RED仿真，也没有加入兼容shim。未改core/worker/legacy及Task1–4广域矩阵不重复运行，
继续保留各自原冻结身份；本波只关闭两项最终审查缺口并覆盖相邻rewrite/两Host路径。
证据仍是模型端点与Intel VIP路径的软件合同，不认证未提供用户RTL的物理寄存器语义。

## 最终审查与归档

最终代码提交为 `ce223312e14f17d8e6c4b4de0aa97ffb7781a189`，编译输入与上面的
finalfix1冻结清单完全一致。本节仅补充审查与归档记录，不修改编译输入。

四项任务的独立审查均已关闭。全分支审查覆盖 `3bf18f3..f8230f68`，发现的两项
Important问题由同一修复提交处理；随后独立审查仅复核
`f8230f68..ce22331`。最终结论为 **规格符合性PASS、代码质量PASS，I1/I2均已解决**，
无新增Critical、Important或Minor问题，也没有挂起或豁免的问题。
复审独立核对151项源码、50项验证证据及完整源码导出，全部一致；没有重复仿真。

本计划的完整工作记录已保存到本地归档
`build/vio_external_config_validation/sdd_final_review_evidence.tar.gz`，SHA-256：
`90a01ad2a34f1a4d7642b55bab08c9afe230bf7c5cc8c16e31fe0d1ac2060e85`。
归档内153个文件逐项核对内容哈希，包括任务报告、各轮审查、差异包、源码清单、
验证记录与三个裁决的完整原文。逐文件保存凭据为同目录
`sdd_final_review_evidence.receipt.json`。最终审查报告在归档内的
`2026-11-07-vio-external-device-configuration/final-r1-review.md`；全分支原审查为
同目录`final-review.md`。临时工作目录只在归档核对成功后清理。

保留本地分支 `review/virtio-sdd-optimized`，本轮没有合并或推送；本地build证据未加入Git。

## 2026-11-07：逐 DWORD 写表与上传驱动地址参考

以 `8290bb9` 为代码基线，本次修改仅涉及项目参考 env 的表项发送、两个项目测试
和参考文档。所有 checked 表项每次发送4B，按高 DWORD→低 DWORD；VTX/VRX
保持同端口锁，完整四笔数据后才发送 clear/trigger。原始 `pcie_bar_write*` 的
宽度/byte-mask 合同不变，新增 `pcie_table_write_by_name()` 供用户自定义表复用。

仿真主机为 `ubuntu@10.11.10.53`，VCS `W-2024.09-SP1 Full64`。
独立工作目录：`/home/ubuntu/ryan/table_write_vcs_20261107.vH77Xj`。
完整编译/运行/strict/源码身份/依赖身份记录保存在本地
`build/vio_external_config_validation/remote_evidence/table_write_vcs/`。

| 验证 | 结果 |
| --- | --- |
| 项目编译、strict compile | `0 / 0` |
| `project_external_contract_test +PROJECT_SMALL +PROJECT_DRIVER_PORTS` | 仿真/strict `0 / 0`，2583项检查；MMIO/TABLE_DWORD/INDIRECT_SERIAL/EXTERNAL_CONTRACT marker 各1次 |
| `project_external_integration_test +PROJECT_SMALL +PROJECT_DRIVER_PORTS +PROJECT_REWRITE` | 仿真/strict `0 / 0`，834项检查；INDIRECT_FAILURE/REWRITE/EXTERNAL_FLOW marker 各1次 |
| 文档提取 `driver_reference_sample_tb` | 编译/strict `0 / 0`，运行0，ADDRESS_PASS 1次；检查18种地址/宽度，编译19个 typed hook 和 BAR helper |

两条项目仿真的 PCIe scoreboard mismatched/unexpected/timed-out 均为 `0/0/0`。
合同覆盖 raw MMIO、4/8/12/16B 高到低写、非法整项零发送、PF/VF 路由、typed 表项
写序和并发12笔完整组。VTX/VRX 分别注入第1至6笔失败，检查立即停止及旧就绪状态撤销。
首轮发现测试固定使用旧 QSCH 模型地址，改为显式选择驱动参考地址后同场景通过；
该失败日志保留在证据中。33项证据文件校验和全部通过。

驱动真实 VTX/VRX 写序是低到高，当前项目按用户要求采用高到低；地址参考与此差异
已在 [逐表写入示例](../integration/project/driver_address_example.md) 明确区分。
验证使用模型端点和 Intel VIP，不证明用户 RTL 的地址、BAR limit 或 VF size-code 语义。
本节证据不包含后续 env→sequence 拆分；拆分后的验证见下一节。

## 2026-11-07：单个配置 sequence 与共享 env_cfg

在 `0f1fee8` 基线后的工作区中，将 DUT 写表和平台 hook 移到
`project_dut_config_seq`，参数、资源视图和 typed 表项保存在同一个 `project_env_cfg`。
env 负责组件组装和句柄发布，base_test 等待平台就绪后启动一个配置 seq。
本轮按用户的单 seq 使用方式删除项目层并发锁、写版本、重写撤销及相应测试，
保留正常配置顺序、参数/路由检查和发送失败立即停止的行为。

仿真在 `ubuntu@10.11.10.53` 的独立目录
`/home/ubuntu/ryan/project_config_seq_vcs_20261107.Y1zthi` 执行，
使用 VCS `W-2024.09-SP1 Full64`。项目重新编译与 strict compile 均返回0。
以下16条项目仿真全部 sim/strict=`0/0`，UVM W/E/F=`0/0/0`，
每个 PCIe scoreboard 的 mismatched/unexpected/timed-out 均为 `0/0/0`。

| 测试 | plusargs | 验证结果 |
| --- | --- | --- |
| `project_external_integration_test` | `+PROJECT_SMALL +PROJECT_DRIVER_PORTS` | 正常 start，从 PCIe sequencer 取得同一 cfg；写表后进入 READY；CONFIG_SEQ/FLOW marker各1次 |
| `project_external_contract_test` | `+PROJECT_SMALL +PROJECT_DRIVER_PORTS` | MMIO、PF/VF 路由、高到低 DWORD 写序、typed 表项和实际 Intel RX；MMIO_CONTRACT/TABLE_DWORD/EXTERNAL_CONTRACT marker各1次 |
| `project_external_integration_test` | `+PROJECT_SMALL +PROJECT_DRIVER_PORTS +PROJECT_TWO_HOSTS +PROJECT_CUSTOM +PROJECT_MSIX` | 单个 seq 顺序配置两 Host；Custom 512B TX、used DMA 和真实 MSI-X 消息；两个 scoreboard 均通过 |
| `project_external_integration_test` | `+PROJECT_SMALL +PROJECT_DRIVER_PORTS +PROJECT_NO_VIO` | 只配置公共资源，无 VIO ring；CONFIG_SEQ/FLOW marker各1次 |
| `project_external_integration_test`，12条独立仿真 | `+PROJECT_SMALL +PROJECT_DRIVER_PORTS +PROJECT_FAIL_DIRECTION=vtx\|vrx +PROJECT_FAIL_DWORD=1..6` | 两方向各六笔发送失败点；CONFIG_FAILURE/FLOW marker各1次，CONFIG_SEQ marker为0；方向与失败序号逐行核对 |

表中的 marker 均带 `PROJECT_` 前缀和 `_PASS` 后缀，只计实际 `UVM_INFO` 消息，
不重复计算 UVM summary 中的 ID 统计。失败注入要求在第 N 笔立即停止，
不能继续发送、确认资源或进入发包状态；不测试其他 seq 重写或自动恢复。

驱动地址文档同步为派生配置 seq 写法，提取后的 `driver_reference_sample_tb`
独立编译/strict compile=`0/0`、运行返回0，`DRIVER_REFERENCE_ADDRESS_PASS` 恰好一次。
该 top 为纯 module，没有 UVM summary；运行日志按 strict 警告/错误扫描检查，
返回0，另行核对 VCS/UVM warning 和 error/fatal 均为0。
样例编译19个 typed hook 和 BAR helper，按独立数字期望检查18种地址/宽度。
驱动的低到高写序与项目按用户要求采用的高到低写序仍在示例中明确区分。

编译修正过程保留两次 fixture 错误：迁移时漏掉三个 extern 构造声明，以及
`private_cfg` 被替换为 `private_this`；修复后重新编译当前源码并运行全部项目。
首条正常行曾因 wrapper 同时计入 UVM summary 而误报 marker 两次，
按实际 `UVM_INFO` 行重新核对后通过，没有为计数错误修改产品逻辑。

完整证据位于 `build/vio_external_config_validation/remote_evidence/project_config_seq_vcs/`。
`results.tsv` 的19项包括两个编译、16条项目仿真及一个文档样例，全部通过。
本地复核 `SHA256SUMS` 的115/115项一致；`provenance/source_manifest.sha256`
覆盖参考 package/全部参考 SV、项目测试及 testbench、三个 filelist 和抽取样例，
与仿真完成时的工作区19/19项逐字节一致。依赖继续使用本文前述隔离快照，入口 SHA 记录于
`provenance/dependency_provenance.txt`。本轮未修改生产源码或依赖。

提交前的暂存区检查发现新文件 `project_dut_config_seq.sv` 末尾多一个空行，
仅删除最后一个换行字节并重新生成完整源码文档；其余18项编译输入与清单完全一致。
删除前源码保存在 `build/dut_config_seq_migration/project_dut_config_seq.validated.sv`，
逐字节验证最终源码加一个换行即等于该仿真版本，未因这项格式修正重复仿真。
最终 seq SHA-256 为 `385d71ba64055ff68be6c19ffef77c2e5dbe25bb907fbb23ab3322c61cb21178`。

| 证据文件 | SHA-256 |
| --- | --- |
| `provenance/source_manifest.sha256` | `442803ce482c4d661661d2dc55a4b7e2e506fded8d20b8a4d472496e5882fc05` |
| `results.tsv` | `70f4c14fc406ca0838ea7c9583623858006e9d69c4b655a69733f4297a7f3fae` |
| `SHA256SUMS` | `3c2e1b0a921d3ade8322a561c3b7c8b323df383f26f307b50fd05ad7e74eced4` |

`python3 scripts/render_project_code.py --check` 与 `git diff --check` 均通过。

当前证据仍是模型端点与实际 Intel VIP 路径的软件验证。真实 RTL 的寄存器偏移、
BAR 编码和平台 verify hook 由集成项目提供。生产 filelist/package 未加入 integration，
`dpu_common`、`pcie_work` 无需本轮修改。

## 2026-11-08：PF0 直接配置、Notify 排序与可选读回

本轮基于 `6de73f9`，补齐参考 `project_env_cfg` 与 `project_dut_config_seq`，
使无 PCIe IP 的 Host0/PF0、标准 Packed、轮询、一对只启 VTX 场景可以直接启动配置基类。
`dpu.configure_public=0` 默认跳过公共硬件表，软件 BAR 分配、Intel 路由和队列资源仍保留。
`dpu.driver_layouts=1` 提供上传驱动的 VIO/QSCH 地址；显式平台布局优先。
默认 seq 写入 Notify、QSCH 模式与映射/权重、VTX/VRX 参数及使能位，然后确认资源。
任一步失败以带阶段名的 `PROJECT_CONFIG_SEQ` fatal 结束，不再静默返回成功。

按用户最终要求，`dpu.verify_readback=0` 为默认值：内建配置流程不发送 Memory Read。
设为1恢复 QSCH 模式、VIO/QSCH 表和 Notify 无效尾部的读回，以及已选公共配置的验证。
独立显式 verify API 仍执行验证。关闭读回时，READY 表示配置写入流程完成，
不表示已读取 DUT 确认寄存器值；参数检查、发送结果检查和失败停止仍然有效。

Notify 排序直接核对上传驱动 `af_mng.c:1632–1734`：

```text
Function key = (host_id << 61) | (notify_addr & 0x1fffffffffffff80)
先按 Function key 升序，再按 Function 内本地 pair 编号升序
Notify 行号 = 排序后的位置；global_qid = 资源分配的映射结果
```

驱动包 `prj1_v2_dpu_kernel_eth_driver.tar.gz` 的 SHA-256 为
`97d8422424354c53c8ca7155a1b769e35b120c1d7a77d2be0faed642eb407ac7`。
当前仍采用图片的512行单 bank：RX/TX 共用一行，空行填最大 key、type=3、reserved=0；
全部 Host 共用一个管理窗口，不操作双 bank 切换或 ready 寄存器。
独立排序 fixture 故意让 PF1 BAR 低于 PF0、pair 输入倒序且重复 RX/TX，
断言排序后的 global qid 为 `2,3,0,1`，验证行号与 global qid 相互独立。

仿真主机 `ubuntu@10.11.10.53`，VCS `W-2024.09-SP1_Full64`。
远端隔离根为 `/home/ubuntu/ryan/project_config_notify_vcs_20261108.B07JHL`，
构建输出为 `build/vio_external_config_validation/config_notify_vcs/final`。
使用 `filelists/project_integration.f`、`filelists/project_tests.f` 和 `project_env_tb`；
编译及 strict compile 均为0。最终15条仿真全部 sim/strict=`0/0`，
UVM W/E/F=`0/0/0`，所有 PCIe scoreboard 的 mismatch/unexpected/timeout=`0/0/0`。

| 场景 | 测试 / 附加参数 | 结果 |
| --- | --- | --- |
| 默认只写 | `project_bare_config_test` | 2066次配置写，0次读，READY 与512B TX Notify通过 |
| 开启读回 | 同上，`+dpu.verify_readback=1` | 相同2066次写，519次真实读，READY 与TX Notify通过 |
| 两对 VTX | 同上，`+PROJECT_BARE_PAIRS=2` | 2082次写、0次读；排序、队列表与TX Notify通过 |
| Packed TX+RX | 同上，`+PROJECT_BARE_RX` | 2078次写、0次读；两方向配置与使能通过 |
| Custom VTX | 同上，`+PROJECT_CUSTOM` | 2066次写、0次读；私有模式位与TX Notify通过 |
| Custom TX+RX | 同上，`+PROJECT_CUSTOM +PROJECT_BARE_RX` | 2078次写、0次读；配置与TX Notify通过 |
| 错误读回 | 同上，`+PROJECT_BARE_CORRUPT` | fixture开启读回；精确捕获验证失败，不进入READY |
| 缺少布局 | 同上，`+PROJECT_BARE_MISSING_LAYOUT` | prepare失败，零配置写，不进入READY |
| 原集成流程 | `project_external_integration_test +PROJECT_SMALL +PROJECT_DRIVER_PORTS` | CONFIG_SEQ / EXTERNAL_FLOW marker各1次 |
| 两Host | 同上，`+PROJECT_TWO_HOSTS +PROJECT_SMALL +PROJECT_TX_ONLY` | 两Host与统一Notify窗口通过，两个SCB均无错误 |
| 原接口合同 | `project_external_contract_test +PROJECT_SMALL +PROJECT_DRIVER_PORTS` | EXTERNAL_CONTRACT / TABLE_DWORD / INTEL_RX marker各1次 |
| VTX/VRX发送故障，4条 | 集成测试，`+PROJECT_SMALL +PROJECT_DRIVER_PORTS +PROJECT_FAIL_DIRECTION=vtx\|vrx +PROJECT_FAIL_DWORD=3\|6` | 各失败点停止，CONFIG_FAILURE / EXTERNAL_FLOW各1次，无CONFIG_SEQ成功marker |

表中缩写 marker 均有 `PROJECT_` 前缀与 `_PASS` 后缀，仅统计实际报告、不重复计入summary。
所有 bare 正例同时出现 `PROJECT_BARE_CONFIG_PASS` 和 `PROJECT_BARE_TX_NOTIFY_PASS`，
负例只有预期 `PROJECT_BARE_FAILURE_PASS`，禁止两个正例 marker。
默认只写与开启读回的仿真时间分别为8.354μs、12.506μs；统计区间从 seq 启动前到
首次512B TX Notify观测完成，包含模型检查，**不是单独的配置延迟**。

错误读回 fixture 最初只改变 Completion 字节，导致 PCIe SCB 同时记录数据不一致。
修正为模拟设备存储错误：同步设备模型和 SCB 的单字节数据基准，保留 cfg 期望值；
实际 Completion 仍触发配置 seq 的比较失败，SCB 的传输检查保持开启。
原失败证据保存在 `config_notify_vcs_readback_on_baseline/`，未修改产品逻辑来屏蔽错误。

最终证据位于 `build/vio_external_config_validation/remote_evidence/config_notify_vcs_final/`。
`source_manifest.sha256` 的21项与最终本地源码逐字节一致；`SHA256SUMS` 的88项复核通过。
`accepted_results.tsv` 保存15行返回码、strict、marker、UVM与SCB结果；
`simulation_log_manifest.sha256` 保存15个仿真日志哈希，依赖身份见 `dependency_provenance.txt`。

| 证据文件 | SHA-256 |
| --- | --- |
| `source_manifest.sha256` | `a5eaa064c7d3dab7533eb60dc63d7cde1c40cc16e08246b6ce0e37ea47d376b3` |
| `accepted_results.tsv` | `e985bedc99f0068121d879e6571e74b61f404e794283bfb5423cf0057fcd2f0b` |
| `SHA256SUMS` | `395f8c6dae9f9b9d0119ef2874c574264d021d18bd5a9b276595a3f428b82cc8` |

`python3 scripts/render_project_code.py --check` 与 `git diff --check` 通过。
参考 env 接线、生产 filelist/package、核心 VIO、`dpu_common` 和 `pcie_work` 本轮均未修改。
验证使用真实 Intel VIP 请求与模型端点，512B测试观察首次业务Notify；
未模拟真实 DUT 的报文消费或完成，不把上述结果当作完整RTL收发通过。

## 2026-11-08：独立 BDF 与按完成模式配置 MSI-X

按用户要求，本增量只验证新增配置，没有重新运行上一节15项回归。
`dpu.configure_bdf=1` 默认在队列配置前写 BDF 表；`configure_public=0` 不再跳过它。
MSI-X 按最终完成模式选择 Function，先配置映射、消息和控制，再使能队列；
普通轮询不写 MSI-X，其他 BAR/PFVF/Completion BDF/Prefix 配置仍由公共开关选择。
默认消息表使能、interval=0、self_mask=0；消息地址和data必须显式提供。

MSI-X linear 按上传驱动的 Host/PFVF/local-vector 查找顺序分配行号，global vector
仅保存为映射结果。中断场景初始化2048行单 bank，空行有效字段全1、reserved=0；
不操作双 bank 切换或 ready。BDF/MSI-X 的读回沿用 `dpu.verify_readback=0` 默认关闭。

VCS 仍在 `ubuntu@10.11.10.53` 执行，版本 `W-2024.09-SP1_Full64`，远端隔离根为
`/home/ubuntu/ryan/project_config_notify_vcs_20261108.B07JHL`，本轮输出目录为
`build/vio_external_config_validation/public_split_vcs/final`。
增量编译、strict compile和以下5项 sim/strict 全部返回0。
每项 UVM W/E/F=`0/0/0`，所有 PCIe scoreboard 的 mismatch/unexpected/timeout=`0/0/0`。

| 测试：`project_bare_config_test` | 配置写／读 | 检查结果 |
| --- | --- | --- |
| 默认参数 | 2067／0 | BDF `0x108000=0x00010000` 恰好写一次且先于队列；未写MSI-X；首次512B TX Notify通过 |
| `+PROJECT_BARE_MSIX` | 6235／0 | 四类MSI-X表、Host消息地址/data、实际向量关联、完整单bank与尾项通过 |
| `+PROJECT_BARE_MSIX +dpu.verify_readback=1` | 6235／2604 | BDF、MSI-X及原VIO表实际Memory读回通过 |
| `+PROJECT_BARE_MSIX_MISSING_MESSAGE` | 零PCIe请求 | 在 `select_msix_scope` 精确失败，不进入READY |
| `+PROJECT_BARE_CORRUPT_BDF` | 1／1 | 实际读回 `0x00010001` 与期望 `0x00010000` 不符，在 `verify_function_configuration` 失败，不进入READY |

正例的 `PROJECT_BARE_CONFIG_PASS`、`PROJECT_BARE_TX_NOTIFY_PASS` 各1次；负例只有
`PROJECT_BARE_FAILURE_PASS`，两个成功marker均为0。BDF故障注入同步设备模型和SCB的
单字节存储基准，保留cfg期望，实际Completion触发比较失败；没有关闭传输检查。

MSI-X场景比轮询多4168笔写：2048行linear表的4096个DWORD，加12个实际消息向量各
6个DWORD（info 1、interval 1、message 4）。这些向量来自本次实际VIO/AF资源快照；
table-only策略没有额外Function控制写。三条正例从seq启动到首次Notify观测分别为
8.358μs、25.030μs、45.862μs，不作为纯配置延迟。

证据保存在 `build/vio_external_config_validation/remote_evidence/public_split_vcs_final/`，
包括5条日志、返回码、strict/marker结果、依赖身份和源文件清单。
21项冻结源码与当前本地源码一致，42项证据SHA核对通过。

| 证据文件 | SHA-256 |
| --- | --- |
| `source_manifest.sha256` | `9a798da83af47255a11529b8e9b2ba20e0c570b023b8d5948ecb73f017306bfd` |
| `accepted_results.tsv` | `3221a4d96f15ea30362f8e3dae724b330ab89e0ce5bad9a9ce3446cbfaec4191` |
| `SHA256SUMS` | `3d083fbf83cf6100e887a25458600bedf82fd2bd19599d564abe13e609a07655` |

本轮仍是模型端点与实际Intel VIP路径的配置验证，不宣称真实DUT报文处理或中断业务完成。
生产filelist/package、参考env接线、核心VIO、`dpu_common`和`pcie_work`均未修改。
源码导出一致性与 `git diff --check` 通过；本地构建证据不加入Git。

## 2026-11-08：Notify 仅配置实际队列对

本增量删除 Notify 未用行的写入及读回，保留每对一项、TX/RX 共用、Host/BAR/pair
全局排序及每项高 DWORD→低 DWORD 写序。首次配置前，DUT 必须已按 `05.png`
复位未用项：type=3，lookup key/global_qid 全1，reserved=0。
MSI-X 线性表的尾部初始化未改动；以上历史验证数据保持原样。

仅运行本轮4项聚焦验证，没有重跑历史矩阵。VCS 在 `ubuntu@10.11.10.53` 执行，
版本 `W-2024.09-SP1_Full64`，远端目录为
`/home/ubuntu/ryan/project_config_notify_vcs_20261108.B07JHL`。
编译、strict compile及4项仿真/strict均返回0；每项成功marker和请求数量断言通过，
UVM W/E/F及PCIe SCB mismatch/unexpected/timeout均为0。

| 测试：`project_bare_config_test` | 配置写／读 | 检查结果 |
| --- | --- | --- |
| 默认 Packed 单 VTX | 23／0 | Notify仅1项4笔写；BDF、QSCH、VTX与首次512B TX Notify通过 |
| `+dpu.verify_readback=1` | 23／9 | 仅实际有效表项和QSCH模式读回；没有未用Notify行访问 |
| `+PROJECT_BARE_PAIRS=32 +PROJECT_BARE_RX +dpu.caps.af_extra_queue_count=0` | 1027／0 | 同PF32对TX/RX对应32个Notify项、共128笔Notify写；两方向队列配置与使能通过 |
| `+PROJECT_CUSTOM` | 23／0 | Custom模式与有效Notify项配置、首次业务Notify通过 |

32对场景使用已有 `af_extra_queue_count=0` 参数释放默认AF额外11对占用；没有放宽
资源容量检查。模型在接收每一笔Notify Memory Read/Write时检查整个请求范围只能落在
实际 `pairs × 16` 字节内，访问任意未用行即失败；同时核对连续有效行、每行4笔高到低
写序、每对映射字段和TX/RX去重。没有为未用Notify RAM新增存储模型。

证据目录为 `build/vio_external_config_validation/remote_evidence/notify_active_vcs_final/`。
21项冻结源码与本地源码一致，38项证据SHA核对通过；`accepted_results.tsv` 保存本轮
4项返回码、strict、marker、请求数量与UVM/SCB汇总，4个仿真日志哈希单独归档。

| 证据文件 | SHA-256 |
| --- | --- |
| `source_manifest.sha256` | `fefecb496398431db8d3e6c72faba642628cb1addd206e726c8bb93651d24613` |
| `accepted_results.tsv` | `d518c814a385ab5135ce7b0eec9908b0eb5096dc6c60a084b118defe0225686d` |
| `SHA256SUMS` | `adc44f9a17230244e42d8cb59e232e3f4ecb044ec69fabde5b54f12eedd36749` |

最终源码技术复审、源码导出一致性及 `git diff --check` 通过。本轮验证使用模型端点和
实际Intel VIP路径，确认配置请求及首次业务Notify；未验证真实RTL的复位值、查找行为、
报文消费或完成。生产filelist/package、cfg、env、核心VIO、`dpu_common`和`pcie_work`均未修改。

## 2026-11-08：独立单队列固定配置 seq

新增参考入口 `project_single_queue_config_seq`，固定 BDF/Notify/QSCH/VTX 地址和策略，
通过原配置 seq 的 PCIe Memory 路径执行。原 `project_dut_config_seq`、env、env_cfg 和
生产 filelist/package 保持不变；新类只加入参考 project package 与完整源码导出。

本轮只在 `ubuntu@10.11.10.53` 运行三项聚焦验证。编译、三项仿真及各自严格日志检查
均返回0，UVM WARNING/ERROR/FATAL均为0；预期负例仅精确捕获对应配置阶段的 fatal。
测试在 env 发布前删除全部表布局，并确认执行前输入与冻结布局均为空。

| `project_single_queue_config_test` 场景 | 配置写／读 | 结果 |
| --- | --- | --- |
| 独立固定 seq；`dpu.bdf_first=16` | 24／0 | Packed256、Polling、TX-only、一对队列到 READY；另产生一次512B TX业务Notify |
| `+PROJECT_FIXED_ORIGINAL` | 1／0 | 原seq只发送AF，准确报缺少PROJECT_BDF布局，不分配VIO ring |
| `+PROJECT_BARE_AF_WRITE_FAIL` | 0／0 | 新seq首笔AF发送故障准确停在declare_af，不进入READY |

正例使用真实分配的 PCI BDF `0x0010`、独立的 EP requester编码0，以及 PF0 BAR0基址
`0x000000201e000000`。AF写地址为该基址加 `0x1010`，BDF写地址为基址加 `0x108000`；
其余地址、VTX ring IOVA、Notify的local/global qid关联均由实际Intel请求和表内容检查。
24笔配置写包括AF1、BDF1、Notify4、QSCH6、VTX初始化及使能12；后续业务Notify另计。

本地证据位于 `build/vio_external_config_validation/remote_evidence/single_queue_seq_vcs_final/`，
包含 `accepted_results.txt`、编译/运行日志、严格检查结果、依赖身份、冻结源码与SHA校验。
新seq验证源码SHA-256为 `0839c6ac1ecb1e0bf88fed249c6aba18594ae69d0b41bcacbb580826e63d9862`。
最终技术审查、源码导出一致性及 `git diff --check` 通过；构建证据不加入Git。
以上证明模型端点与实际Intel VIP路径的配置和首次Notify，不宣称真实RTL已消费报文或完成业务。

## 2026-11-08：PF0 BAR0 相对地址 reg_acc

新增参考 `project_pcie_reg_seq`，继承原生寄存器命令字段，接收显式cfg或从RC sequencer
取得env_cfg。`addr`保持BAR0内偏移，经真实registry检查后向对应RC发送绝对地址请求；
不启动配置seq、不分配ring，错误通过四参数 `aip_cmd_reg` 的 `seq.error_msg` 返回。
本轮未修改原env/env_cfg/DUT配置seq、`pcie_work`或生产filelist/package。

在 `ubuntu@10.11.10.53` 使用AIP依赖 `aip_core_set_param_expr` 的 `660d6dd` 版本，
仅运行SV命令派发与真实Tcl/UCLI两个定向场景。最终编译、两例仿真及严格日志检查均返回0。

| `project_pcie_reg_test` 入口 | 实际Memory请求 | 检查结果 |
| --- | --- | --- |
| SV `aip_cmd::exec_result` | 24，12写/12读 | 106项断言通过，覆盖命名/位置参数和错误回传 |
| `+AIP_TCL` / `project_pcie_reg.tcl` | 24，12写/12读 | Tcl9项检查和SV收尾97项断言通过 |

两例均覆盖显式cfg注入、同一对象重复start不累加BAR基址、issued_tlps清理、越界后恢复读回，
以及自动获取cfg的 `reg_acc`：偏移0x1010写/读0x5555aaaa、128bit读写、0x5555稀疏mask，
完整范围越界返回非零状态和准确错误且不新增请求。实际Intel端检查环境分配的BAR基址加
指定偏移与最终字节内容。UVM W/E/F均为0；PCIe SCB req=24、cpl=12、matched=12，
mismatch/unexpected/timeout均为0。

首次Tcl启动在0fs因依赖模块加载需要 `AIP_CORE`、而runner仅设置 `AIP_CORE_ROOT` 失败；
测试脚本已在source前将两者指向同一仓库，随后真实UCLI通过，SV源码无需改动或重编。
证据位于 `build/vio_external_config_validation/remote_evidence/project_pcie_reg_seq_vcs_final/`，
包含编译日志、`sv_exec`、`tcl_ucli`、首次失败 `tcl_ucli_env_missing` 及冻结源码。
产品seq SHA-256为 `a5d581d27cccf9771ea82046d2498998f0e42e3b0ae3132fa86fabbaaf92cf15`，
最终Tcl脚本SHA-256为 `d2c39531321ed7f82805529ded996a560d08f1c06e2cfa9b6fe1be8e9ba2e637`。
最终技术审查、完整源码导出一致性和 `git diff --check` 通过；验证对象为Intel模型端点，
不代表真实RTL寄存器副作用已验证，构建证据不加入Git。

## 2026-11-08：AF 状态同步与逐请求读值比较

本轮为默认配置 seq 补齐 AF 同步：向环境分配的 Host0/PF0 BAR0+`0x1010`
写 `0x5555aaaa` 后，立即单次读取同地址并等待 Completion，状态必须为8。
此后每成功完成100次完整DWORD配置写，再执行同样的状态读；每次start独立计数，
不轮询、不补尾读，也不受普通表项 `verify_readback` 开关控制。
单次传输失败或状态不为8立即停止，不能继续配置或提交READY。

PCIe新增默认开启的逐请求 `check_read_data`，AF状态读将其设0，仅跳过SCB历史RAM
写值比较，保留Completion协议检查。寄存器访问固定TC0、attr0；普通RW流量保留原
随机属性。AIP寄存器宏增加可选五参数映射，Tcl支持 `check_read_data=0/1`，省略时
每次恢复1。旧三/四参数注册仍编译；未映射时显式传该选项在启动前报错。
Tcl读取只返回原始值，状态等于8的判断由自动配置seq负责。

VCS在 `ubuntu@10.11.10.53` 运行，版本 `W-2024.09`，目录为
`/home/ubuntu/ryan/project_config_notify_vcs_20261108.B07JHL`。
PCIe/AIP依赖使用本轮冻结文件重新构建；最终Project、AIP编译和strict compile均通过。
AIP首次使用Makefile的非必要 `-lca` 选项产生usage warning并被strict拒绝；
去掉该runner选项后，同一源码重编无warning/error，没有为此修改产品源码。

| 聚焦场景 | 配置写／读或Memory请求 | 检查结果 |
| --- | --- | --- |
| 固定单队列seq，Packed256/Polling/VTX | 24写／1读 | AF状态8后继续，290项检查；另产生一次512B TX业务Notify |
| 默认seq，16对TX-only | 324写／4读 | 首次及第100/200/300次DWORD写后读取AF，3109项检查；另产生一次业务Notify |
| 初始AF状态错误7 | 1写／1读 | 准确停在declare_af，无后续写或轮询，不进入READY |
| 初始AF Completion返回UR | 1写／1读 | 准确停在declare_af，SCB保留1次协议失配，证明关闭数据比较不关闭协议检查 |
| 16对队列，第2次AF读返回7 | 101写／2读 | 准确停在configure_qsch，无后续配置或READY |
| reg_acc SV命令入口 | 26请求，12写／14读 | 145项检查，opt-out读返回8；显式1及下一次省略均恢复RAM比较 |
| reg_acc真实Tcl/UCLI入口 | 26请求，12写／14读 | Tcl13项及SV131项检查；逐次策略、非法值与范围错误回传正确 |
| AIP test_reg_wide | 不发PCIe请求 | 38项检查；旧注册兼容、五参数普通/严格宏、0/1/默认/非法值覆盖 |

设备模型故意延迟AF Completion 50ns，期间检查不能收到后续配置写；该延迟仅在测试
模型中，产品seq没有固定等待。真实Intel请求逐笔检查TC0/attr0、BAR绝对地址及完整
DWORD边界。单队列/16对正例SCB mismatch、unexpected、timeout均为0。
错值负例SCB也保持0，由seq自身校验寄存器状态失败。

UR负例故意保留SCB mismatch=1；reg_acc两例分别故意保留mismatch=2，来自两笔
开启RAM比较的AF状态读（读值8与写magic不同）。这些计数不清零、不屏蔽全局SCB。
精确catcher和 `check_matrix.sh` 同时校验预期错误次数、成功marker、请求数量和
零unexpected/timeout；其余错误仍按失败处理。通用strict对这三例非零失配的拒绝日志
保留，由专用负例检查接受。全部8例最终UVM WARNING/ERROR/FATAL汇总均为0。

证据位于 `build/vio_external_config_validation/remote_evidence/af_status_vcs_final/`，
包含8例日志、编译日志、通用strict与专用接受结果、冻结源码和依赖身份。
最终独立复核13项冻结源码SHA与本地一致、81项证据SHA正确；验证期间未改产品源码。

| 证据文件 | SHA-256 |
| --- | --- |
| `source_manifest.sha256` | `836862e7905b2515d369a16c802d3f33cccbf22f2fd5e16bc5306e405216d333` |
| `accepted_results.tsv` | `85d31ee196e292b21e50884e39976d77bc6b9f68f79599e765210427620c4aae` |
| `SHA256SUMS` | `567364cd2ec590a826cb7caf00559a4494b842d317e01090fed6b16f97132a88` |

最终技术审查确认请求元数据经reg→RW→TLP→TX快照→SCB传播，复制与adapter重编码
保留策略；失败传播、顺序约束与每100次写同步均有对应验证。三仓库 `git diff --check`
及12份源码导出一致性检查通过。env/env_cfg、核心VIO、dpu_common和生产filelist/package
未修改。上述验证覆盖模型端点与实际Intel VIP配置链路，不证明真实RTL的AF副作用、
Notify查表、DMA报文消费或完成已经验证；真实DUT须按约定返回AF状态8。

## 2026-11-08：恢复快照后显式重载参数

新增Tcl `load_params` 在已构建的同一project env/cfg上重采样允许字段，
纯候选通过全Host及RC消息预检后才原地提交；命令不分配ring、不发送DUT配置。
后续仍使用 `project_dut_config_seq` 下表。核心VIO service需求、FSM行为、
自动Custom私有配置、等待策略、冻结表目录及RC的MSI-X识别目录一并更新。
Host/PF/VF、队列对数、协议类型/features、BAR/BDF及内存资源保持build时不变；
本轮不重新加载 `pcie_cfg.*`，也不修改AIP、dpu_common或pcie_work源码。

在 `ubuntu@10.11.10.53` 使用VCS `W-2024.09-SP1`，隔离目录为
`/home/ubuntu/ryan/project_restore_load_params_vcs_20261108.c7bvH8`。
从空csrc全量编译项目及测试，compile和strict均通过。Packed与Custom分别执行
两个独立进程：首次在1100ns、env已构建且DUT写为0时保存；第二次携带新CLI
启动同一simv，restore后立即重新source AIP loader，再执行真实Tcl重载和配置。

两组均从256深度/轮询恢复为512深度/MSI-X；Notify偏移变为`0x80`，
v0消息地址/数据变为`0xa00000000000/0x24681357`，未重新提供的v1保留旧值；
QSCH SPWRR变为`0x55`，VTX dma_info变为5。Custom另验证私有dport_id变为`0x23`。
各例检查同一cfg/Host cfg/registry/资源快照及原BAR/BDF句柄和值保持不变，
修改pairs被拒绝且原值不变，合法重复重载不累积条目，活动代重载被拒绝且READY不变。

| 最终场景 | 实际配置写／读 | SV检查 | Tcl检查 | 结果 |
| --- | --- | --- | --- | --- |
| Packed独立save/restore | 4132／42 | 21083 | 11 | 新表值、新Notify及新MSI-X完成均通过 |
| Custom独立save/restore | 4132／42 | 21084 | 11 | 同上，另验证私有控制字段刷新 |

实际Intel请求覆盖配置写/读、512B TX Notify、模型返回的完成DMA及新MSI-X。
在中断到达前不能取出完成报文，中断后正确返回原packet，证明更新后的MSI-X未被当作DMA。
两例SCB均为4177请求、42 Completion，mismatched/unexpected/timeout均为0，
UVM WARNING/ERROR/FATAL均为0；最终四进程均首次通过，无超时重试。
该验证使用Intel模型端点，不代表真实RTL的报文消费与寄存器副作用已经验证。

首次功能运行时runner的可执行文件自动探测指向VCS ucli，因此额外修正runner：
保存与恢复均显式设置 `::aip_simv_path`，再重跑上述四进程作为最终证据。
这是快照元数据绑定修正，未修改产品源码或AIP；两份最终meta均记录同一个实际simv
绝对路径、size=`1275480`、mtime=`1794129194`及保存时刻1100ns。

证据位于 `build/vio_external_config_validation/remote_evidence/restore_load_params_vcs_final/`，
最终日志仅取 `packed_final`、`custom_final`，并包含编译/strict、runner及冻结7文件SHA。
独立审查已核对归档SHA、7份实际测试源码身份、四进程返回码、成功marker、UVM汇总和两份meta。

| 证据文件 | SHA-256 |
| --- | --- |
| `restore_load_params_summary.tar.gz` | `6f9bcda6340e764ebcdb45fee52afae8a990a12ac7aa93aef001f8bc61c378ee` |
| `results.tsv` | `da583110db8d6bde5c3540993b21d064494c476847fe9afa9999b45167b5e0dc` |
| `runtime_reload_format_audit/manifest.json` | `277abfde2c3001d3e0f58341e8213445b313753bbc452ce2e3ca0fce1e221089` |

仿真完成后，仅对新增方法参数的类型/名称间隔改用Tab，并撤销核心文件4处无关旧格式差异。
因此最终core cfg、project env、project RC及测试文件与实际仿真版本的字节SHA不同，
其余3份冻结文件完全一致；全部7份文件去空白内容相同，没有功能变更。
原始7文件及前后SHA保存在 `build/vio_external_config_validation/runtime_reload_format_audit/`；
没有将最终格式版本宣称为字节相同的仿真输入。最终源码导出12项一致性及
`git diff --check`通过，生产filelist/package和原base_test运行顺序保持不变。


## 2026-11-09：公共配置迁入 dpu_common、Notify 后置使能

本节为当前实现。此前 `project_dut_config_seq`、`project_pcie_reg_seq`、旧 registry 等
名称仅属于历史记录；当前入口为 `vio_dpu_cfg_seq`、`dpu_bar_reg_seq` 和 `dpu_env_cfg`。
DPU 核心不依赖 PCIe/VIO，可选 PCIe 包只依赖公共 DPU 和原生 PCIe TL。
参考 env/cfg 保留组装、共享内存和 Intel bind，公共类型/表生成/写序不再重复实现。

新增 `dpu_cfg_seq::enable_notify()`：本批 VIO/RDMA Notify 表全成功后，按管理 BAR 去重，
每个目标以4B Memory Write写 `BAR+0x80044=1`。偏移不叠加模块基址、不设置 bank 位，
不额外读回；空批次不写、表失败不使能、使能失败不报告成功。该写计入每100笔 DWORD
之后的 AF 状态读计数。BAR/Host memory 共用一个分配结果，VIO 导出实际 ring/IOVA。

仿真使用 `10.11.10.53` 的 VCS `W-2024.09-SP1`，隔离目录 `/tmp/dpu_cfg_sr8q0qy7`。
正常场景进程退出成功、strict检查通过；预期故障逐项核对失败原因、写入数量及未进入READY。

| 验证范围 | 结果 |
| --- | --- |
| DPU 核心，无 PCIe/VIO | 独立编译及6项资源/plan/executor测试通过 |
| 硬件字段 | BDF32、MSI-X linear64、VTX/VRX/Notify128位检查通过 |
| 可选 PCIe 集成，无 VIO | 编译及通用 PCIe executor测试通过 |
| 完整项目、BAR、普通寄存器访问 | 编译/地址路由通过；寄存器读比较负例单独接受，见下文 |
| 单 PF0/一对 Packed VTX | 25笔配置写、1笔AF读，真实Intel业务DB匹配；配置与512B提交通过 |
| Packed/Custom × polling/MSI-X | 四组合合同及四组合生命周期均通过，包含释放后重新准备 |
| 双 Host、多 VF、混合格式、ETS | 7125项检查通过，含实际descriptor导出、共享Host manager和512B RX |
| Notify批次 | VIO/RDMA、管理目标去重、多目标、空批次、表写/使能失败通过 |
| 可选公共控制/驱动端口 | 2668项检查通过，保留PBA只读和独立W1C能力 |
| 失败停止 | 缺Notify布局、VTX第2笔/VRX第5笔发送失败通过，未继续配置或确认READY |
| 旧私有驱动/原生TLM executor/AIP参数 | 定向回归通过，通用executor仍可独立使用 |

最终代码与“已增加Notify使能、尚未做架构迁移”的基线使用相同seed17和参数，
从实际Intel接收端抽取事务。比较完整原始顺序，不排序，不忽略AF读或业务DB：

| 场景 | 事务数 | 逐笔内容及顺序 |
| --- | ---: | --- |
| 一对Packed/轮询 | 27 | 完全一致 |
| 一对Custom/轮询 | 27 | 完全一致 |
| 32对Packed/轮询，AF extra=0 | 653 | 完全一致 |
| 一对Packed/MSI-X | 4236 | 完全一致 |

比较字段为Host、目标BAR/base、offset、方向、字节数、first/last BE、payload。
32对场景显式提供 `+dpu.caps.af_extra_queue_count=0`：未提供时原版和新版都因默认
11个AF额外队列占用32对上限而拒绝。没有为了让测试通过而改变资源默认值。

最终 `verified/simv` 对Packed和Custom分别进行两个独立进程的保存/恢复。
在1100ns保存未下DUT配置的环境；恢复进程用新CLI，并在restore后立即重新source AIP loader。
`load_params` 由 `aip_cmd_task` 注册，保持原cfg/BAR/BDF/Host资源句柄，更新队列深度、
Notify、MSI-X、QSCH、VTX策略；Custom另更新私有dport_id。非法pairs修改不改变原状态，
重复合法重载不累积资源，活动代重载被拒绝。随后真实配置、新DB和新MSI-X路径均通过。

| 独立恢复 | 配置写/读 | SV检查 | Tcl检查 | SCB |
| --- | --- | ---: | ---: | --- |
| Packed | 4133/42 | 21088 | 11 | mismatch/unexpected/timeout均0 |
| Custom | 4133/42 | 21089 | 11 | mismatch/unexpected/timeout均0 |

`project_pcie_reg_test` 的两次 SCB RAM 数据不匹配是测试显式注入的期望负例，用于比较
`check_read_data` 默认/开启与关闭的行为。测试完成26次请求，精确catcher核对两次不匹配
及最终汇总，UVM ERROR/FATAL为0；通用strict会拒绝 `Mismatched: 2`，因此此项单独接受，
不宣称它是普通strict零不匹配通过。其他仿真不使用这个豁免。

本轮发现并修正通用executor测试的快照注入，以及缺布局失败后已分配ring的收尾范围。
后者在返回失败时保留可释放selection，既不确认READY，也不隐含释放DMA；平台确认停机后
测试显式释放，最终strict无资源泄漏告警。初次失败日志保留在证据中。

本地证据目录：`build/dpu_cfg_sr8q0qy7/`。`remote_evidence/` 保存编译/运行日志，
`verified_compare_results.json`、`verified_restore_results.json` 记录最终事务与恢复结果，
`remote_audit.json` 核对提交到VCS主机的234份源码/脚本、simv和两份checkpoint身份及外部依赖哈希。
`final_sources.tar.gz` 为提交到VCS主机的源码/脚本，`final_working_sources.tar.gz` 为最终工作区源码；
最后19个文件仅整理Tab空白，`final_format_audit.json` 逐项证明去注释/空白后的token相同。
`preexisting_packet_audit.json` 确认16个已有报文/等待实现与实施前逐字节相同。
源码导出6文件一致性、测试清单静态合同和四仓库diff空白检查均通过。

上述验证包含Intel VIP接口模型、DPU资源与真实驱动格式合同；没有宣称真实RTL的
AF副作用、Notify查表、DMA消费或业务完成已在本轮验证。集成时同步新公共包与用户参考，
重新编译并保存快照；本轮未提交或推送远程。

## 2026-11-09：配置复审修复与当前源码回归

本轮在原 cfg/seq 和 AIP 宏中修复参数采样、Notify 基址与失败清理问题。
显式加载的 VIO 全局/Host 参数只采样一次，service 和运行期候选继承该结果；
精确 service 覆盖仍有效，重载缺失项保留当前值。Custom 私有默认控制先合并再传给队列，
随后应用各层 qN 覆盖，首次构建与重载使用相同顺序。

Notify 默认从实际导出的 doorbell `[60:7]` 生成查找基址，
`notify_table_bar/notify_table_offset` 改为可选覆盖；显式基址仍检查范围、128B 对齐和高位一致。
多 Host prepare 部分成功后返回可释放的 selection，供原释放入口清理并重试。
公共 publish 先核对 device/resources/BAR map 的同源冻结身份，全部预检成功后才发布；
失败保留旧状态。PCIe RC/EP 拓扑由 cfg 确定，env 只校验并绑定。

验证在 `ubuntu@10.11.10.53` 的 `/tmp/dpu_cfg_fix_20261109` 使用 VCS
`W-2024.09-SP1` 进行。六个编译组全部通过严格日志检查；20 项普通用例和
两组独立 save/restore 通过，共22个逻辑场景、24次成功仿真。
本节使用当前源码重新编译，不把上一节旧归档结果计入本轮覆盖。

| 验证范围 | 本轮结果 |
| --- | --- |
| DPU 核心与公共发布 | 6项核心用例及1项独立类型/发布测试通过；覆盖未冻结、跨快照、首次/再次发布失败和修正后重试 |
| PCIe 可选集成，无 VIO | 独立编译及 TL executor 用例通过 |
| VIO 相关集成 | 私有驱动、外部队列配置、DPU PCIe TL executor 共3项通过 |
| AIP 与 TX/RX | 5项通过；参数543项检查、RX buffer 204项检查；TX offload 及分段通过，分段覆盖12000包/71993个descriptor |
| Project 定向测试 | 4项通过；Notify 296项检查、Packed/Custom合同2499/2497项检查，双Host中途失败后释放与重试通过 |
| Packed 独立保存/恢复 | DUT检查21088项、Tcl检查11项，通过 |
| Custom 独立保存/恢复 | DUT检查21089项、Tcl检查11项，通过 |

Notify 用例覆盖非零实际基址、显式地址低7位不同但高位一致、高位冲突拒绝及原排序规则。
参数用例包含12轮全局/Host随机值继承，以及Custom单队列覆盖优先级和缺失字段保留。
恢复用例在独立进程中使用新CLI，检查重载、实际写表、新Notify和MSI-X完成；
非法pairs修改、重复合法重载、活动代拒绝均按原合同验证。
Host/PF/VF、队列对数、协议类型/features等快照固定边界没有扩展。

独立类型测试运行退出码为0，出现 `DPU_TABLE_TYPES_PASS` 且无Warning/Error/Fatal；
它是standalone module，不生成UVM Report Summary。其他场景均通过对应UVM/严格日志检查。

证据位于 `build/dpu_cfg_fix_20261109/`，结果见 `VALIDATION_RESULT.md`，
复现步骤见 `FINAL_INPUTS.execute.md`。实际输入由v2基包、三文件增量和正确的
`aip_core_set_param_expr`依赖组成；不能只使用旧v2包复现。
AIP依赖HEAD为 `a0367231fd9568f68547123b7173d49b586b84f6`，工作树干净；
Tcl bridge在53主机从该源码构建。最终输入2445个文件已逐项核对本地与53一致。

| 证据文件 | SHA-256 |
| --- | --- |
| `final_inputs_v5.sha256` | `5e3ea777f7c0e3152b2d8c74f2f08abf72fb04a5d3d1ca437508477476741f49` |
| `final_evidence_bundle.tar.gz` | `dda257f1e9aba0cb286fe540ed52338dd3f24e3baaa6a0ea75253a269cfb1e90` |

证据保留了修正前的测试枚举告警、错误AIP依赖根和缺少生成Tcl bridge的日志，
通过结论只使用修正后的编译与运行结果。提交检查时仅移除
`dpu_common/src/dpu_bar_map.sv` 和 `integration/pcie/dpu_pcie_bar_map.sv` 各一行末尾空行；
其余源码保持验证时的字节内容。`commit_format_audit.json` 记录两份文件前后SHA，
并确认差异只有末尾换行；本节验证记录也在核对后补充。
本轮是模型端点和软件集成的针对性验证，不代表整仓全量回归或真实RTL DUT验证。
