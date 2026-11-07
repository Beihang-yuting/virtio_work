# VIO 外部配置验证记录

证据分三层：核心/registry组件合同、真实 Intel VIP adapter→monitor→bridge→项目RC的
模型报文路径、用户实际RTL。前两层使用明确声明的模型平台；没有提供用户RTL，
因此这里不认证其模块基址、间接端口语义、PBA真实容量、QSCH调度或线侧收发。
“模型未测的软件合同”也单独列出，不能用RTL边界代替。

最终产品基线为 `2426d2e0e25c911806e10404917ffb3ccfbf1381`；Task4仅添加验证与文档。
Task1/2/3已通过的未改源码证据复用，不为增加数量重复运行。全部仿真由指定5.6
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
