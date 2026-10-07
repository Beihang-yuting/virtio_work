// 目录层次：virtio_net_vip/src/devmodel；DPU 私有 NIC 设备模型（20f9:5013），行为依据 icpu-kernel-driver
// lance_net_mailbox@f2c9cd6 的 AF 路径，寄存器名取 dpu_common reg plan；不一致处按驱动实现并列疑点如下。
// **依据：** 53 `/home/ubuntu/wn/icpu-kernel-driver`（`lance_net_mailbox@f2c9cd6`，只读，本地副本 md5 一致）与
// dpu_common `4d73996` reg plan（`dpu_device_bootstrap_plan_builder.sv`、`dpu_vio_dataplane_plan_extension.sv`）。
// 驱动读 BAR2 qinfo `host_id`（`{pfvf_id[6:0], host_id[9:7]}`，main.c:2020）：`pfvf_id==0` 走 **AF 路径**（驱动直接
// 在 BAR0 写芯片表），否则走 PF 路径（全部经 mailbox 消息请求 AF）。单个 20f9:5013 设备 + cosim 只有 AF 路径可行，
// 本模型报告 `pfvf_id=0`，只建模 AF 路径；PF/VF mailbox 消息协议不建模（疑点 M-8）。
//
// **驱动寄存器序列（AF 路径，1 个队列对：RX lqid 0 / TX lqid 1，全局队列 gq=0，gfid=0，向量 gv 从 0 分配）**
//
// | # | 阶段 | 驱动位置 | 区 | 偏移 | 访问 | 值 / 语义 | 设备模型 |
// |---|---|---|---|---|---|---|---|
// | 1 | probe | pci_enable_device/set_master | cfg | CMD | W | MEM、BME | wmask |
// | 2 | probe | dpu_probe main.c:2020 | BAR2 | 0x0C | R | `{pfvf_id[6:0], host_id[9:7]}` | 只读，pfvf=0 |
// | 3 | AF | af_soft_reset_fe main.c:1914 | BAR0 | 0x1000014 | W,W | 7，msleep 5，0 | 非 0 写清数据面状态（M-1） |
// | 4 | AF | main.c:2027 | BAR0 | 0x1010 | R | bit3 须为 0 | 读回 0x20040 |
// | 5 | AF | main.c:2035 | BAR0 | 0x1010 | W | 0x5555AAAA | 置 0x20040=`{1,host}` |
// | 6 | AF | main.c:2040 | BAR0 | 0x1010 | R | 须为 `8\|host` | 同 #4 |
// | 7 | AF | main.c:2052 | BAR0 | 0x60040 | W | `(v&7)\|8`（INTF_MB_AF_HOST_ID） | 存储 |
// | 8 | all | main.c:2124 | BAR0 | 0x1010 | R | 须 bit3 | 同 #4 |
// | 9 | AF | 芯片初始化（split horizon、fw init 轮询 0x1000020 bit31、rx_mtu、pause、res_mng、rss_alg、macvlan、QSCH 0xB00100、l3mc、fec） | BAR0 | 多处 | R/W | 与数据队列无关；dpu_af_res_mng_init af_mng.c:88–95 读 GREG_INFO 规格 0x1000108–0x1000138 | 通用寄存器存储；0x1000020 读 bit31=1；0x100010C 读 136（M-13） |
// | 10 | all | dpu_mailbox_cfg_bdf mailbox.c:441 | BAR2 | 0x04 | W | `1<<16 \| bdf` | 存储 |
// | 11–15 | all | mailbox 队列 reset/config/tail/enable mailbox.c:158–372 | BAR2 | 0x2C/0x1C/0x20–0x28/0x10–0x18/0x00 | W | mailbox 环 | 存储，不处理消息 |
// | 16 | AF | af_configure_func_msix_map af_mng.c:695 | BAR0 | 0xC0000+((srcid<<7)+i)*4，i<needed | W | `gv_i \| 1<<11`；needed=num_lan+1+13 | 线性表：CQ 中断反查本地向量 |
// | 17 | AF | af_mng.c:703 | BAR0 | 0x56000+gfid*4 | W | `bdf \| 1<<16` | 存储 |
// | 18 | all | init_interrupt_scheme（内核） | cfg+BAR4 | MSI-X | W | 内核 | 底座 MSI-X |
// | 19 | AF | af_enable_mailbox_irq mailbox.c:708,717 | BAR0 | 0x54000+gv_mb*4；0x68000+srcid*16 ×4 | W | mailbox 中断 | 存储 |
// | 20 | all | dpu_read_real_bar_base_addr main.c:938,941 | cfg | 0x10/0x14 | R | BAR0 物理地址 = notify 地址 | — |
// | 21 | AF | fill_qid_map_table af_mng.c:872–899 | BAR0 | 0x28000+bank*0x4000+i*16（i<128）×4 DW；0x20044 | W,R | 有效项 DW0=`{addr[31:7],blk,lq[4:0],net=1}`、DW1=`{host[2:0],addr[60:32]}`、DW2=`gq[10:0]`、DW3=0；无效项 `FFFFFFFF,FFFFFFFF,7FF,0`；每项写后读回；最后 0x20044=`rdy\|bank<<1` 写后读回 | doorbell 路由（活动 bank、notify 地址=本 BAR0、lq/blk=lqid>>1） |
// | 22 | AF | add_vnet/queue_2_qsch main.c:1185,1133 | BAR0 | 0xB12000/0xB11000/0xB10000/0xB13000 | W | QSCH 映射 | 存储 |
// | 23 | probe | MAC/VLAN/SR-IOV/固件版本（AF 内部或 mailbox） | — | — | — | — | — |
// | 24 | open | dpu_af_hw_config_tx_ring af_mng.c:1406–1419 | BAR0 | 0x880134–0x880140；0x880130；0x890000+q*16 | W×4；W,W；R×4 | VTX 参数（DW2：q_depth[3:0]、queue_en[4]=0、virtio_mode[5]=0、seg_en[7]=1、sport_type[14:12]=host、dma_msix[25:15]=gv；DW3 sport_id=gfid）；ram_cfg 写 `q` 再 `q\|0x2000`；读回比较 desc_addr | VTX 表（`wr_enable[13]` 且 `selector[12]=0` 时写入） |
// | 25 | open | dpu_af_hw_config_rx_ring af_mng.c:1310,1360–1368 | BAR0 | 0x902000+q*4；0x900204–0x90020C；0x900200 | R；W×3；W,W | 读 [15:0] 须 0x8000；VRX 参数（DW2：q_depth、queue_en[4]=1、dport_type[8:6]=host、dport_id[18:9]=gfid、dma_msix[29:19]=gv）；wr_cfg 写 `q` 再 `0x10000\|q` | VRX 表；tail 寄存器复位值 0x8000 |
// | 26 | open | af_configure_rss_group_table af_mng.c:1697–1703 | BAR0 | 0x4A0020；0x4A9000+… | W | RSS | 存储 |
// | 27 | open | dpu_af_configure_msix_irq interrupt.c:386,389 | BAR0 | 0x54000+gv*4；0x48000+gv*16+0xC | W；W | `gfid\|host<<8\|self_mask(1)<<11\|valid<<12`；0（解除全局屏蔽） | CQ 中断门控与自屏蔽 |
// | 28 | open | dpu_af_control_tx_queue af_mng.c:1598–1612 | BAR0 | 0x890000+q*16；0x880134–40；0x880130 | R×4；W×4；W,W | 读回后置 queue_en=1 | 同 #24 |
// | 29 | open | dpu_alloc_rx_bufs txrx.c:964 | BAR0 | 0x0 | W | `1<<31 \| 511<<16 \| 0`=0x81FF0000 | RX doorbell |
// | 30 | open | up_complete | BAR0 | 0x4AA000+gfid*4 RMW | R/W | vport fwd | 存储 |
// | 31 | TX | dpu_tx_map txrx.c:1492 | BAR0 | 0x0 | W | `wrap[31]\|tail[30:16]\|lqid[15:0]`，1 包=0x80010001 | TX doorbell |
// | 32 | IRQ | dpu_enable_msix_irq interrupt.c:276 | BAR0 | 0x1004 | W | `gv<<1`（mask_en=0）解除自屏蔽 | 解除 gv 自屏蔽，挂起时补发一次 |
// | 33 | stop | dpu_down：control_tx(en=0)、reset_tx txrx.c:382–524、control_rx(en=0) af_mng.c:1570–1589、reset_rx txrx.c:543–550、全部停完后 clear_msix_irqs_conf interrupt.c:257–265 | BAR0 | TX：#28 置 en=0；轮询 0xB22000+q*4 [11:9]=0；0x880100 写 `q`、`q\|1<<31`；轮询 0x880104 bit0；0x880154（stat_clr_cfg，清 TX 统计）写 `q\|1<<16`、`\|1<<31`；轮询 0x880158（stat_clr_done）bit0。RX：0x900210 写 `i<<14\|q`、`\|0x10000` 后读 0x900214（i=0..3，af_mng.c:1564 按 sizeof(vrx_queue_para_table_entry)/4 读 4 DW：u64 成员使结构对齐到 16 B，DW3 为填充）；写回 en=0；0x900200 `q`、`0x10000\|q`；0x90010C 写 0；0x900108 `q`、`q\|1<<31`；轮询 0x90010C bit0。全部 TX、RX 停完后按向量升序 0x54000+gv*4 写 0 | 见左 | 停队/复位完成位；`stall_queue_stop` 旋钮使完成位永不置位、QSCH 报在途 |
// | 34–38 | remove | qid map 失效重写 + 0x20044、QSCH 删除、mailbox 中断关闭、清 0x56000/0xC0000、BAR2 0x2C/0x1C 拆除、0x60040=0、0x20040=0 | BAR0/BAR2 | — | W | rmmod | 存储（0x20040 写 0 即解除声明） |
//
// **描述符/CQ/doorbell（与 C1 `custom_virtqueue` 一致）：** 16B 描述符 `addr[63:0]`；W1 `len[17:0]、dport_info[29:18]、
// dport_id_l[31:30]`；W2 `dport_id_h[7:0]、dport_type[10:8]、rss_lag[11]、cpu_tx_cos[14:12]、dtype[15]、next[16]、l3_cs[17]、
// l4_cs[18]、fwd[20:19]、avail[23]、used[31]`（驱动写 avail=wrap、used=!wrap）。TX ring：N×16B 描述符 + CQ（u16 `head_index[14:0]、
// wrap[15]`，初值 0x8000）；RX ring：N×16B 描述符 + N×16B CQ（DW0 `desc_num[31:28]`；DW1 `head_idx[15:0]、pkt_len[29:16]、
// csum_status[30]、cq_wrapper[31]`）。doorbell BAR0+0 共享，`wrap[31]|tail[30:16]|lqid[15:0]`，RX lqid=2i，TX lqid=2i+1。
//
// **疑点（驱动与 reg plan、模型推断）：**
// - D-1 reg plan `dpu_vio_pack_vtx_ram_cfg` 把 selector 放 bit13、wr_enable 放 bit14，写 `q|0x2000` 再 `q|0x6000`；驱动结构
//   `ram_selector:1@12`（PARA=0）、`wr_enable@13`，写 `q` 再 `q|0x2000`。模型按驱动。
// - D-2 reg plan 缺：#3 软复位、#8 第二次 0x1010 读、#25 VRX tail 检查、#24 读回、TX 先 en=0 再 RMW 置 1、#27 self_mask=1 与
//   0x48000+0xC 解除屏蔽；多出：0x60040 读回、MSIX_INTERVAL(0x52000) 写；默认 `msix_self_mask=0` 与驱动队列向量的 1 不同。
//   VIP 后端不做 #9/#22/#26/#30（与数据队列无关的芯片表），F 阶段对比时列白名单。
// - D-3 reg plan 以 2×64 位写 qid map，驱动是 4×32 位写 + 读回并重写全部 128 项。VIP 后端不建 mailbox 环（#11–15、#19）。
// - D-4 f2c9cd6 把 srcid 改成 `host<<10`：host_id=1 时 `MSIX_LINEAR_TBL_ENTRY((srcid<<7)+i)` 落到 0x140000+（INTF_PCONFIG），
//   `MBL_MAP_TBL_E_ADDR(srcid)` 落到 0x6C000；reg plan 复制了同样溢出。模型按同一公式解码（一致即可路由）。
// - D-5 G2P `src_port` 为 1 位，驱动赋 host+2 被截断（plan 同样截断）。
// - D-6 发给 AF 的 RX buf_len=2048，而描述符 len≈1664（≥5.12 内核）。模型按描述符 len 填充。
// - D-7 AF 路径 RSS 用不带 pfvf 的 srcid；`dpu_control_queue` 用 ecpu_host_id 而复位用 host_id。
// - D-8 `dpu_reset_rx_queue` 恒返回 0。
// - D-9 TX 首描述符 len=skb->len 后被 headlen 覆盖；l3/l4_cs 只在清理时复位。
// - D-10 ST 模式判断 `srcid>=MIN || srcid<=MAX` 恒真（默认 fabric_mode 无害）。
// - D-11 无 SR-IOV 能力时 pos=0，驱动读标准头 0x14/0x16/0x24/0x28 并照常发 REGISTER_VF_BAR_INFO/CFG_VFS_BDF。
// - M-1 0x1000014 软复位的芯片语义不明：模型只清数据面（VTX/VRX 表、环运行态、自屏蔽），保留其它寄存器与 AF 声明。
// - M-2 doorbell → 全局队列：按活动 bank 中 notify 地址=本 BAR0、`{blk,lq}=lqid>>1` 的有效项取 gq，`lqid bit0` 为方向（驱动未写明，推断）。
// - M-3 VRX tail 寄存器（0x902000+q*4）在 doorbell 后的值不明：模型返回 `{tail_wrap,tail}`，复位后 0x8000。
// - M-4 完成信号：先写 CQ，再按 VTX/VRX `dma_msix`→info 表（valid、self_mask）→线性表反查本地 MSI-X 向量；self_mask=1 时发出后
//   自屏蔽，0x1004 写 `gv<<1` 解除（推断）。自屏蔽期间的完成置该 gv 挂起，解除时由 worker 补发一次：驱动 dpu_napi_poll
//   （interrupt.c:279–335）在 napi_complete_done 后写 0x1004、不再轮询，窗口内的完成若丢弃则永远收不到中断。
//   挂起在 info.valid=0 或使用该 gv 的使能队列全部复位后作废。
// - M-5 TX CQ `head_index` 为最后完成描述符的下一槽、`wrap` 为该位置的圈号（驱动只比较 head_index，wrap 读而不用）。
// - M-6 QSCH 状态 0xB22000+q*4 的 vld/fly/regi（bit11/10/9）：模型空闲为 0，`stall_queue_stop` 时报 bit10。
// - M-7 RX 一帧跨多个描述符（desc_num≤15，`head_idx`=首描述符号）；驱动只用 pkt_len 与 cq_wrapper。
// - M-8 PF/VF mailbox 路径未建模；qinfo 恒报 `pfvf_id=0`。
// - M-9 全局资源分配：设备全新时驱动从 0 分配 gq/gfid/gv；VIP 后端取 gq=gv=队列对号（`local_qid>>1`）、gfid=0。
//   local_qid_base≠0 时，VIP 后端的 qid map 槽位与 lq/blk（M-2）、gq、gv 都不从 0 起，驱动则每个 Function 连续用
//   0..n-1；这是 F 阶段对比时的已知差异。
// - M-10 doorbell 路由不比较 qid map DW1 的 host[31:29]：doorbell 写只带地址与 lqid，不带 host；单设备模型只有一个 host，
//   notify 地址（=本 BAR0）已唯一确定 Function，驱动写入的 host 与 qinfo 报告值相同，比较它不增加区分度。
// - M-11 全局屏蔽 0x48000+gv*16+0xC 未写时按 0（不屏蔽）处理：驱动只写 0（#27）、从不置 1 也不读，驱动与 reg plan 都未给出
//   复位值；按 0 处理意味着漏写 #27 第二步不会被模型发现（若芯片复位值为 1，驱动的这一写是必需的）。
// - M-12 VTX/VRX DW2 virtio_mode[5]=1（芯片 virtio 环模式）不建模：参数表照存并告警，数据面仍按私有环处理。
// - M-13 GREG_INFO 规格寄存器（0x1000100+，只读芯片能力）驱动与 reg plan 都未给出取值。驱动从 vport_port_num 减以太口数得到
//   可分配的全局 Function 数（af_mng.c:95），为 0 时 probe 在 af_mng.c:669 失败。模型令 vport_port_num=136
//   （= DPU_MAX_HOST×DPU_MAX_FUNC，驱动 res_record 的容量），其余规格读 0：以太口 0、flow/mc/vblk 关、mac_num 0。
//   因此 cosim 中 probe 打印 "There is no available VLAN slot left"（macvlan.c:1635，flow 关，VLAN 广播流表 0 项）；另有
//   发往 ECPU 的组播地址 mailbox 消息（type 131 DPU_MAILBOX_CFG_MC_ADDR，adapter_ops.c:119/124）等待 USED 超时（M-8）。
//   两者驱动均容忍，netdev 照常注册、收发。
`ifndef VDEV_DPU_PRIV_SV
`define VDEV_DPU_PRIV_SV

class vdev_dpu_priv extends vdev_base;
    `uvm_component_utils(vdev_dpu_priv)

    // BAR0（驱动 register.h / af_mng.h 名称见文件头表）
    localparam bit [31:0] DOORBELL         = 32'h000_0000;
    localparam bit [31:0] MSIX_REARM       = 32'h000_1004;
    localparam bit [31:0] AF_DECLARATION   = 32'h000_1010;
    localparam bit [31:0] PCMPL_AF_HOST    = 32'h002_0040;
    localparam bit [31:0] QID_MAP_SEL      = 32'h002_0044;
    localparam bit [31:0] QID_MAP_BASE     = 32'h002_8000;
    localparam bit [31:0] MSIX_CTRL_BASE   = 32'h004_8000;
    localparam bit [31:0] MSIX_INFO_BASE   = 32'h005_4000;
    localparam bit [31:0] BDF_MAP_BASE     = 32'h005_6000;
    localparam bit [31:0] MB_AF_HOST       = 32'h006_0040;
    localparam bit [31:0] MSIX_LINEAR_BASE = 32'h00c_0000;
    localparam bit [31:0] MSIX_LINEAR_END  = 32'h014_0000;   // INTF_PCONFIG（register.h:38），线性表之后
    localparam bit [31:0] VTX_RESET        = 32'h088_0100;
    localparam bit [31:0] VTX_RESET_DONE   = 32'h088_0104;
    localparam bit [31:0] VTX_RAM_CFG      = 32'h088_0130;
    localparam bit [31:0] VTX_CONTENT      = 32'h088_0134;
    localparam bit [31:0] VTX_STAT_CLR     = 32'h088_0154;   // vtx_stat_clr_cfg：{en[31], q_num[24:16], start_q[15:0]}
    localparam bit [31:0] VTX_STAT_CLR_DONE = 32'h088_0158;
    localparam bit [31:0] VTX_PARA_RD      = 32'h089_0000;
    localparam bit [31:0] VRX_RESET        = 32'h090_0108;
    localparam bit [31:0] VRX_RESET_DONE   = 32'h090_010c;
    localparam bit [31:0] VRX_WR_CFG       = 32'h090_0200;
    localparam bit [31:0] VRX_CONTENT      = 32'h090_0204;
    localparam bit [31:0] VRX_RD_CFG       = 32'h090_0210;
    localparam bit [31:0] VRX_RD_DATA      = 32'h090_0214;
    localparam bit [31:0] VRX_TAIL         = 32'h090_2000;
    localparam bit [31:0] QSCH_STATE       = 32'h0b2_2000;
    localparam bit [31:0] SOFT_RESET       = 32'h100_0014;
    localparam bit [31:0] FW_READY         = 32'h100_0020;
    localparam bit [31:0] GREG_VPORT_SPEC  = 32'h100_010c;   // greg_vport_spec.vport_port_num[15:0]（只读，M-13）
    localparam int unsigned VPORT_NUM      = 136;            // DPU_MAX_HOST(2) * DPU_MAX_FUNC(68)，hw.h:17–18
    localparam int unsigned MAX_QUEUES     = 128;
    localparam int unsigned IRQ_WORK       = 2 * MAX_QUEUES;   // 工作项 IRQ_WORK+gv：补发挂起的 gv

    int unsigned host_id;
    bit          stall_queue_stop;

    typedef struct { bit [31:0] dw[4]; } para_t;
    typedef struct {
        int unsigned tail;
        bit          tail_wrap;
        int unsigned cons;
        bit          cons_wrap;
        int unsigned cq;
        bit          cq_wrap;
    } ring_t;

    protected bit [31:0] regs[bit [31:0]];
    protected bit [31:0] qinfo[16];
    protected para_t     vtx[int unsigned];
    protected para_t     vrx[int unsigned];
    protected bit [31:0] vtx_content[4];
    protected bit [31:0] vrx_content[3];
    protected bit [31:0] vrx_rd_cfg;
    protected ring_t     rings[int unsigned];     // 键 2*gq+tx
    protected bit        broken[int unsigned];    // 键 2*gq+tx
    protected bit        gv_masked[int unsigned];
    protected bit        gv_pending[int unsigned];
    protected bit        vtx_reset_done;
    protected bit        vtx_stat_clr_done;
    protected bit        vrx_reset_done;

    function new(string name = "vdev_dpu_priv", uvm_component parent = null);
        super.new(name, parent);
        host_id = 0;
        stall_queue_stop = 0;
    endfunction

    virtual function void init();
        bit [63:0] sizes[3];

        sizes[0] = 64'h200_0000;
        sizes[1] = 64'h1_0000;
        sizes[2] = 64'h1_0000;
        init_header(16'h20f9, 16'h5013, 24'h020000, 8'h01, sizes);
        add_msix(4, 32'h0, 32'h8000, 64);
        regs.delete();
        foreach (qinfo[i])
            qinfo[i] = 0;
        qinfo[3] = {22'h0, host_id[2:0], 7'h0};
        vrx_rd_cfg = 0;
        vtx_reset_done = 0;
        vtx_stat_clr_done = 0;
        vrx_reset_done = 0;
        soft_reset();
    endfunction

    // 测试观察：某方向全局队列的参数表 queue_en 位（且未因环错误停用）。
    function bit queue_enabled(bit tx, int unsigned gq);
        if (broken.exists(2 * gq + tx))
            return 0;
        if (tx)
            return vtx.exists(gq) && vtx[gq].dw[2][4];
        return vrx.exists(gq) && vrx[gq].dw[2][4];
    endfunction

    // M-1：只清数据面状态。
    protected function void soft_reset();
        quiesce();
        vtx.delete();
        vrx.delete();
        rings.delete();
        broken.delete();
        gv_masked.delete();
        gv_pending.delete();
    endfunction

    protected function bit [31:0] reg_val(bit [31:0] off);
        return regs.exists(off) ? regs[off] : 32'h0;
    endfunction

    protected function ring_t ring_of(int unsigned gq, bit tx);
        ring_t r;

        if (rings.exists(2 * gq + tx))
            return rings[2 * gq + tx];
        r.tail = 0;
        r.tail_wrap = 1;
        r.cons = 0;
        r.cons_wrap = 1;
        r.cq = 0;
        r.cq_wrap = 1;
        return r;
    endfunction

    // worker 只写回消费侧字段，doorbell 期间更新的 tail 不被覆盖；队列已被复位删除时不复活。
    protected function void save_consumer(int unsigned gq, bit tx, ring_t r);
        ring_t cur;

        if (!rings.exists(2 * gq + tx))
            return;
        cur = rings[2 * gq + tx];
        cur.cons = r.cons;
        cur.cons_wrap = r.cons_wrap;
        cur.cq = r.cq;
        cur.cq_wrap = r.cq_wrap;
        rings[2 * gq + tx] = cur;
    endfunction

    protected function bit [31:0] para_word(bit tx, int unsigned gq, int unsigned i);
        if (i > 3)
            return 0;
        if (tx)
            return vtx.exists(gq) ? vtx[gq].dw[i] : 32'h0;
        return vrx.exists(gq) ? vrx[gq].dw[i] : 32'h0;
    endfunction

    // ---------------- MMIO ----------------
    virtual function bit [31:0] region_read(int unsigned bar, bit [31:0] off, int unsigned size);
        bit [31:0] v;

        v = 0;
        if (bar == 2) begin
            if (off < 32'h40)
                v = qinfo[off[5:2]];
            reg_event(0, "bar2", qinfo_field(off), -1, v);
        end else if (bar == 0) begin
            v = bar0_read(off);
            reg_event(0, "bar0", bar0_field(off), -1, v);
        end
        return v;
    endfunction

    protected function bit [31:0] bar0_read(bit [31:0] off);
        ring_t r;

        if (off == AF_DECLARATION)
            return reg_val(PCMPL_AF_HOST);
        if (off == FW_READY)
            return 32'h8000_0000;
        if (off == GREG_VPORT_SPEC)
            return VPORT_NUM;
        if (off == VTX_RESET_DONE)
            return vtx_reset_done;
        if (off == VTX_STAT_CLR_DONE)
            return vtx_stat_clr_done;
        if (off == VRX_RESET_DONE)
            return vrx_reset_done;
        if (off == VRX_RD_DATA)
            return para_word(0, vrx_rd_cfg[8:0], vrx_rd_cfg[15:14]);
        if ((off >= VTX_PARA_RD) && (off < VTX_PARA_RD + 16 * MAX_QUEUES))
            return para_word(1, (off - VTX_PARA_RD) / 16, ((off - VTX_PARA_RD) / 4) % 4);
        if ((off >= VRX_TAIL) && (off < VRX_TAIL + 4 * MAX_QUEUES)) begin
            r = ring_of((off - VRX_TAIL) / 4, 0);
            return {16'h0, r.tail_wrap, r.tail[14:0]};
        end
        if ((off >= QSCH_STATE) && (off < QSCH_STATE + 4 * MAX_QUEUES))
            return (stall_queue_stop && vtx.exists((off - QSCH_STATE) / 4)) ? 32'h0000_0400 : 32'h0;
        return reg_val(off);
    endfunction

    virtual function void region_write(int unsigned bar, bit [31:0] off, int unsigned size,
                                       bit [31:0] data);
        if (bar == 2) begin
            reg_event(1, "bar2", qinfo_field(off), -1, data);
            if ((off < 32'h40) && (off != 32'h0c))
                qinfo[off[5:2]] = data;
            return;
        end
        if (bar != 0)
            return;
        if (off == DOORBELL) begin
            doorbell(data);
            return;
        end
        reg_event(1, "bar0", bar0_field(off), -1, data);
        if (off == AF_DECLARATION) begin
            // main.c:2035：魔数声明 AF；其它值不改变（main.c:2426 注释：写 0 不能清除，须写 0x20040）。
            if (data == 32'h5555_aaaa)
                regs[PCMPL_AF_HOST] = {28'h0, 1'b1, host_id[2:0]};
        end else if (off == MSIX_REARM) begin
            gv_masked[data[11:1]] = data[0];
            if (!data[0] && gv_pending.exists(data[11:1]))
                schedule(IRQ_WORK + data[11:1]);
        end else if (off == VTX_RAM_CFG) begin
            if (data[13] && !data[12])
                store_para(1, data[8:0]);
        end else if (off == VRX_WR_CFG) begin
            if (data[31:16] != 0)
                store_para(0, data[15:0]);
        end else if (off == VRX_RD_CFG)
            vrx_rd_cfg = data;
        else if (off == VTX_RESET)
            vtx_reset_done = data[31] ? stop_ring(1, data[8:0]) : 1'b0;
        else if (off == VTX_STAT_CLR)
            vtx_stat_clr_done = data[31] ? !stall_queue_stop : 1'b0;
        else if (off == VRX_RESET_DONE)
            vrx_reset_done = 0;
        else if (off == VRX_RESET) begin
            if (data[31])
                vrx_reset_done = stop_ring(0, data[8:0]);
        end else if ((off >= VTX_CONTENT) && (off < VTX_CONTENT + 16))
            vtx_content[(off - VTX_CONTENT) / 4] = data;
        else if ((off >= VRX_CONTENT) && (off < VRX_CONTENT + 12))
            vrx_content[(off - VRX_CONTENT) / 4] = data;
        else if ((off == SOFT_RESET) && (data != 0))
            soft_reset();
        else
            regs[off] = data;
    endfunction

    // 参数表写入（驱动 wr_ram_cfg）；queue_en 由 0 变 1 时发 queue_cfg。
    protected function void store_para(bit tx, int unsigned gq);
        para_t p;
        bit was;
        vdev_event e;

        was = queue_enabled(tx, gq);
        for (int unsigned i = 0; i < 3; i++)
            p.dw[i] = tx ? vtx_content[i] : vrx_content[i];
        p.dw[3] = tx ? vtx_content[3] : 32'h0;
        if (p.dw[2][5])
            `uvm_warning("VDEV_DPU_PRIV", $sformatf("BDF 0x%04h %s queue %0d sets virtio_mode=1; only the private ring is modelled",
                         bdf, tx ? "VTX" : "VRX", gq))
        if (tx)
            vtx[gq] = p;
        else
            vrx[gq] = p;
        if (!was && queue_enabled(tx, gq)) begin
            e = new_event(VDEV_QUEUE_CFG);
            e.q = 2 * gq + tx;
            e.size = 1 << p.dw[2][3:0];
            e.vector = tx ? p.dw[2][25:15] : p.dw[2][29:19];
            e.enable = 1;
            e.ring_fmt = "priv";
            emit(e);
            if (!tx && has_backlog(gq))
                schedule(2 * gq);
        end
    endfunction

    // 驱动 dpu_af_reset_{tx,rx}_queue：清该队列运行态、停止其 DMA；旋钮打开时永不完成。
    // 该队列的 gv 不再被任何使能队列使用时，作废其挂起中断（TX/RX 可共用 gv）。
    protected function bit stop_ring(bit tx, int unsigned gq);
        int unsigned gv;
        bit shared;

        if (stall_queue_stop)
            return 0;
        rings.delete(2 * gq + tx);
        broken.delete(2 * gq + tx);
        if (!tx)
            rx_backlog.delete(gq);
        gv = queue_gv(tx, gq);
        shared = 0;
        foreach (vtx[q])
            shared |= queue_enabled(1, q) && (queue_gv(1, q) == gv);
        foreach (vrx[q])
            shared |= queue_enabled(0, q) && (queue_gv(0, q) == gv);
        if (!shared)
            gv_pending.delete(gv);
        return 1;
    endfunction

    // 参数表 DW2 的 dma_msix（全局向量号）。
    protected function int unsigned queue_gv(bit tx, int unsigned gq);
        return tx ? (para_word(1, gq, 2) >> 15) & 32'h7ff : (para_word(0, gq, 2) >> 19) & 32'h7ff;
    endfunction

    // M-2：活动 bank 中 notify 地址等于本 BAR0、{blk,lq} 等于队列对号的有效项给出全局队列号。
    protected function int lookup_qid(int unsigned pair);
        bit [31:0] sel;
        bit [31:0] dw0;
        bit [31:0] dw1;
        bit [31:0] dw2;
        bit [31:0] base;
        bit [63:0] bar0;

        sel = reg_val(QID_MAP_SEL);
        if (!sel[0])
            return -1;
        bar0 = bar_base(0);
        for (int unsigned i = 0; i < 128; i++) begin
            base = QID_MAP_BASE + sel[1] * 32'h4000 + 16 * i;
            dw0 = reg_val(base);
            dw1 = reg_val(base + 4);
            dw2 = reg_val(base + 8);
            if ((dw0 == 32'hffff_ffff) || !dw0[0])
                continue;
            if (({dw0[6], dw0[5:1]} == pair) && ({dw1[28:0], dw0[31:7]} == bar0[60:7]))
                return dw2[10:0];
        end
        return -1;
    endfunction

    protected function void doorbell(bit [31:0] data);
        vdev_event e;
        ring_t r;
        int gq;
        bit tx;

        e = new_event(VDEV_NOTIFY);
        e.q = data[15:0];
        e.next_idx = data[30:16];
        e.wrap = data[31];
        emit(e);
        n_notify++;
        tx = data[0];
        gq = lookup_qid(data[15:1]);
        if ((gq < 0) || !queue_enabled(tx, gq)) begin
            `uvm_warning("VDEV_DPU_PRIV", $sformatf(
                "BDF 0x%04h doorbell 0x%08h has no enabled %s queue (qid map / %s parameters)",
                bdf, data, tx ? "TX" : "RX", tx ? "VTX" : "VRX"))
            return;
        end
        r = ring_of(gq, tx);
        r.tail = data[30:16];
        r.tail_wrap = data[31];
        rings[2 * gq + tx] = r;
        schedule(2 * gq + tx);
    endfunction

    protected function void ring_error(bit tx, int unsigned gq, string why);
        `uvm_warning("VDEV_DPU_PRIV", $sformatf("BDF 0x%04h %s queue %0d: %s", bdf, tx ? "TX" : "RX", gq, why))
        broken[2 * gq + tx] = 1;
    endfunction

    // M-4：info.valid、全局屏蔽、自屏蔽都通过后，线性表反查本地向量并经底座发 MSI-X；自屏蔽时置挂起。
    protected task cq_irq(int unsigned gv);
        bit [31:0] info;
        bit [31:0] ctrl;
        bit [31:0] e;
        bit [31:0] srcid;

        info = reg_val(MSIX_INFO_BASE + 4 * gv);
        ctrl = reg_val(MSIX_CTRL_BASE + 16 * gv + 32'hc);
        if (!info[12]) begin
            gv_pending.delete(gv);
            return;
        end
        if (ctrl[0])
            return;
        if (gv_masked.exists(gv) && gv_masked[gv]) begin
            gv_pending[gv] = 1;
            return;
        end
        gv_pending.delete(gv);
        srcid = host_id << 10;
        for (int unsigned i = 0; i < 128; i++) begin
            e = reg_val(MSIX_LINEAR_BASE + 4 * ((srcid << 7) + i));
            if (e[11] && (e[10:0] == gv)) begin
                if (info[11])
                    gv_masked[gv] = 1;
                raise_irq(i);
                return;
            end
        end
    endtask

    // ---------------- 数据路径 ----------------
    virtual task service_queue(int unsigned q);
        if (q >= IRQ_WORK) begin
            if (gv_pending.exists(q - IRQ_WORK))     // 排队期间已投递或作废则不再处理
                cq_irq(q - IRQ_WORK);
        end else if (q % 2)
            service_tx(q / 2);
        else
            service_rx(q / 2);
    endtask

    protected task service_tx(int unsigned gq);
        int unsigned my_epoch;
        int unsigned n;
        int unsigned first;
        bit [63:0] base;
        bit [63:0] addr;
        bit [31:0] w1;
        bit [31:0] w2;
        bit [7:0] b[];
        bit [7:0] d[];
        bit [7:0] frame[$];
        bit ok;
        bit more;
        ring_t r;
        vdev_event chain;
        vdev_event e;

        my_epoch = epoch;
        while ((my_epoch == epoch) && queue_enabled(1, gq)) begin
            r = ring_of(gq, 1);
            if ((r.cons == r.tail) && (r.cons_wrap == r.tail_wrap))
                break;
            base = {vtx[gq].dw[1], vtx[gq].dw[0]};
            n = 1 << vtx[gq].dw[2][3:0];
            chain = new_event(VDEV_DESC_CHAIN);
            chain.q = 2 * gq + 1;
            frame.delete();
            first = r.cons;
            more = 1;
            while (more) begin
                dma_rd(base + 16 * r.cons, 16, b, ok);
                if (!ok)
                    return;
                addr = {b[7], b[6], b[5], b[4], b[3], b[2], b[1], b[0]};
                w1 = {b[11], b[10], b[9], b[8]};
                w2 = {b[15], b[14], b[13], b[12]};
                if ((w2[23] != r.cons_wrap) || (w2[31] == r.cons_wrap) || (chain.seg_len.size() >= 8)) begin
                    ring_error(1, gq, $sformatf("descriptor %0d word2=0x%08h does not match wrap %0b",
                                                r.cons, w2, r.cons_wrap));
                    return;
                end
                if ((chain.seg_len.size() == 0) && take_fault(2 * gq + 1, VQ_FAULT_PRE_DEVICE_READ) &&
                    (err_inj.err_type == VQ_ERR_ZERO_LEN_BUF))
                    w1[17:0] = 0;
                chain.seg_len.push_back(w1[17:0]);
                chain.seg_flags.push_back(w2);
                if (!w2[15]) begin
                    if (w1[17:0] == 0) begin
                        ring_error(1, gq, "data descriptor has zero length");
                        return;
                    end
                    dma_rd(addr, w1[17:0], d, ok);
                    if (!ok)
                        return;
                    foreach (d[i])
                        frame.push_back(d[i]);
                end
                more = w2[16];
                r.cons++;
                if (r.cons == n) begin
                    r.cons = 0;
                    r.cons_wrap = ~r.cons_wrap;
                end
            end
            emit(chain);
            e = new_event(VDEV_PKT);
            e.dir = "tx";
            e.q = 2 * gq + 1;
            e.bytes = frame;
            e.len = frame.size();
            emit(e);
            // M-5：TX CQ = {wrap, head_index}，head 为最后完成描述符的下一槽。
            b = new[2];
            b[0] = r.cons[7:0];
            b[1] = {r.cons_wrap, r.cons[14:8]};
            dma_wr(base + 16 * n, b, ok);
            if (!ok)
                return;
            save_consumer(gq, 1, r);
            n_complete++;
            e = new_event(VDEV_COMPLETE);
            e.q = 2 * gq + 1;
            e.id = first;
            e.len = frame.size();
            emit(e);
            inject_rx(gq, frame);
            cq_irq(vtx[gq].dw[2][25:15]);
        end
    endtask

    protected task service_rx(int unsigned gq);
        int unsigned my_epoch;
        int unsigned n;
        int unsigned avail;
        int unsigned cursor;
        int unsigned cnt;
        int unsigned take;
        bit [63:0] base;
        bit [63:0] addrs[$];
        int unsigned lens[$];
        bit [7:0] b[];
        bit [7:0] part[];
        bit [31:0] w1;
        bit [31:0] w2;
        bit [31:0] dw1;
        bit slot_wrap;
        int unsigned flen;
        bit ok;
        ring_t r;
        frame_t f;
        vdev_event chain;
        vdev_event e;

        my_epoch = epoch;
        while ((my_epoch == epoch) && queue_enabled(0, gq) && has_backlog(gq)) begin
            r = ring_of(gq, 0);
            base = {vrx[gq].dw[1], vrx[gq].dw[0]};
            n = 1 << vrx[gq].dw[2][3:0];
            avail = (r.tail + n - r.cons) % n;
            if ((avail == 0) && (r.tail_wrap != r.cons_wrap))
                avail = n;
            f = rx_backlog[gq][0];
            if ((f.data.size() == 0) || (f.data.size() > 16383)) begin
                void'(rx_backlog[gq].pop_front());
                `uvm_warning("VDEV_DPU_PRIV", $sformatf("BDF 0x%04h dropped a %0d-byte RX frame (pkt_len is 14 bits)",
                             bdf, f.data.size()))
                continue;
            end
            // 先确认已投递的描述符能装下整帧（M-7：最多 15 个），不够就等下一次 doorbell。
            addrs.delete();
            lens.delete();
            chain = new_event(VDEV_DESC_CHAIN);
            chain.q = 2 * gq;
            cursor = 0;
            cnt = 0;
            while ((cursor < f.data.size()) && (cnt < avail) && (cnt < 15)) begin
                dma_rd(base + 16 * ((r.cons + cnt) % n), 16, b, ok);
                if (!ok)
                    return;
                w1 = {b[11], b[10], b[9], b[8]};
                w2 = {b[15], b[14], b[13], b[12]};
                slot_wrap = r.cons_wrap ^ ((r.cons + cnt) >= n);
                if ((w2[23] != slot_wrap) || (w2[31] == slot_wrap) || (w1[17:0] == 0)) begin
                    ring_error(0, gq, $sformatf("descriptor %0d word1=0x%08h word2=0x%08h is not a posted buffer",
                                                (r.cons + cnt) % n, w1, w2));
                    return;
                end
                addrs.push_back({b[7], b[6], b[5], b[4], b[3], b[2], b[1], b[0]});
                lens.push_back(w1[17:0]);
                chain.seg_len.push_back(w1[17:0]);
                chain.seg_flags.push_back(w2);
                cursor += w1[17:0];
                cnt++;
            end
            if (cursor < f.data.size())
                break;
            cursor = 0;
            foreach (addrs[i]) begin
                take = f.data.size() - cursor;
                if (take > lens[i])
                    take = lens[i];
                part = new[take];
                foreach (part[j])
                    part[j] = f.data[cursor + j];
                dma_wr(addrs[i], part, ok);
                if (!ok)
                    return;
                cursor += take;
            end
            b = new[16];
            foreach (b[i])
                b[i] = 8'h00;
            b[3] = {cnt[3:0], 4'h0};
            flen = f.data.size();
            dw1 = {r.cq_wrap, 1'b0, flen[13:0], r.cons[15:0]};
            for (int unsigned i = 0; i < 4; i++)
                b[4 + i] = dw1[8*i +: 8];
            dma_wr(base + 16 * n + 16 * r.cq, b, ok);
            if (!ok)
                return;
            r.cons = (r.cons + cnt) % n;
            if (r.cons < cnt)
                r.cons_wrap = ~r.cons_wrap;
            r.cq++;
            if (r.cq == n) begin
                r.cq = 0;
                r.cq_wrap = ~r.cq_wrap;
            end
            save_consumer(gq, 0, r);
            void'(rx_backlog[gq].pop_front());
            emit(chain);
            e = new_event(VDEV_PKT);
            e.dir = "rx";
            e.q = 2 * gq;
            e.bytes = f.data;
            e.len = f.data.size();
            emit(e);
            n_complete++;
            e = new_event(VDEV_COMPLETE);
            e.q = 2 * gq;
            e.id = dw1[15:0];
            e.len = f.data.size();
            emit(e);
            cq_irq(vrx[gq].dw[2][29:19]);
        end
    endtask

    // ---------------- 事件字段名 ----------------
    protected function string qinfo_field(bit [31:0] off);
        case (off)
            32'h00: return "mb_doorbell";
            32'h04: return "bdf";
            32'h08: return "msix";
            32'h0c: return "host_id";
            32'h10: return "rx_base_lo";
            32'h14: return "rx_base_hi";
            32'h18: return "rx_size_bwid";
            32'h1c: return "rx_cmd";
            32'h20: return "tx_base_lo";
            32'h24: return "tx_base_hi";
            32'h28: return "tx_size_bwid";
            32'h2c: return "tx_cmd";
            default: return $sformatf("0x%02h", off);
        endcase
    endfunction

    protected function string bar0_field(bit [31:0] off);
        bit [31:0] linear_window;

        linear_window = MSIX_LINEAR_BASE + 4 * ((host_id << 10) << 7);
        case (off)
            MSIX_REARM:     return "msix_rearm";
            AF_DECLARATION: return "af_declaration";
            PCMPL_AF_HOST:  return "pcmpl_af_host_id";
            QID_MAP_SEL:    return "qid_map_sel";
            MB_AF_HOST:     return "mb_af_host_id";
            VTX_RESET:      return "vtx_reset";
            VTX_RESET_DONE: return "vtx_reset_done";
            VTX_RAM_CFG:    return "vtx_ram_cfg";
            VTX_STAT_CLR:      return "vtx_stat_clr_cfg";
            VTX_STAT_CLR_DONE: return "vtx_stat_clr_done";
            VRX_RESET:      return "vrx_reset";
            VRX_RESET_DONE: return "vrx_reset_done";
            VRX_WR_CFG:     return "vrx_wr_cfg";
            VRX_RD_CFG:     return "vrx_rd_cfg";
            VRX_RD_DATA:    return "vrx_rd_data";
            SOFT_RESET:     return "soft_reset";
            FW_READY:       return "fw_ready";
            GREG_VPORT_SPEC: return "greg_vport_spec";
            default: ;
        endcase
        if ((off >= VTX_CONTENT) && (off < VTX_CONTENT + 16))
            return $sformatf("vtx_content.dw%0d", (off - VTX_CONTENT) / 4);
        if ((off >= VRX_CONTENT) && (off < VRX_CONTENT + 12))
            return $sformatf("vrx_content.dw%0d", (off - VRX_CONTENT) / 4);
        if ((off >= VTX_PARA_RD) && (off < VTX_PARA_RD + 16 * MAX_QUEUES))
            return $sformatf("vtx_para.%0d.dw%0d", (off - VTX_PARA_RD) / 16, ((off - VTX_PARA_RD) / 4) % 4);
        if ((off >= VRX_TAIL) && (off < VRX_TAIL + 4 * MAX_QUEUES))
            return $sformatf("vrx_tail.%0d", (off - VRX_TAIL) / 4);
        if ((off >= QSCH_STATE) && (off < QSCH_STATE + 4 * MAX_QUEUES))
            return $sformatf("qsch_state.%0d", (off - QSCH_STATE) / 4);
        if ((off >= QID_MAP_BASE) && (off < QID_MAP_BASE + 32'h8000))
            return $sformatf("qid_map.b%0d.e%0d.dw%0d", (off - QID_MAP_BASE) / 32'h4000,
                             ((off - QID_MAP_BASE) % 32'h4000) / 16, ((off - QID_MAP_BASE) % 16) / 4);
        if ((off >= MSIX_CTRL_BASE) && (off < MSIX_INFO_BASE))
            return $sformatf("msix_ctrl.%0d.dw%0d", (off - MSIX_CTRL_BASE) / 16, ((off - MSIX_CTRL_BASE) % 16) / 4);
        if ((off >= MSIX_INFO_BASE) && (off < BDF_MAP_BASE))
            return $sformatf("msix_info.%0d", (off - MSIX_INFO_BASE) / 4);
        if ((off >= BDF_MAP_BASE) && (off < BDF_MAP_BASE + 32'h1000))
            return $sformatf("bdf_map.%0d", (off - BDF_MAP_BASE) / 4);
        // 线性表本身，加上本设备 srcid 的解码窗口（cq_irq 的 128 项；D-4 溢出时落在 INTF_PCONFIG 之后）。
        if (((off >= MSIX_LINEAR_BASE) && (off < MSIX_LINEAR_END)) ||
            ((off >= linear_window) && (off < linear_window + 4 * 128)))
            return $sformatf("msix_linear.%0d", (off - MSIX_LINEAR_BASE) / 4);
        return $sformatf("0x%07h", off);
    endfunction
endclass
`endif
