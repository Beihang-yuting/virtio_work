# 真实驱动对比验证与私有模式收敛 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复已知缺陷，私有模式收敛到通用接入点，配置后端成为唯一配置通道，设备模型与驱动分离；再借用 cosim 让真实 Linux 驱动与 VIP 驱动面对同一设备模型做对比，修复差异。

**Architecture:** 阶段 A（R3 缺陷）→ B（R2 后端唯一通道）→ C（R1 私有模式收敛）→ D（R4 独立设备模型，含私有寄存器级后端）→ E（53 上临时 cosim 冒烟）→ F（对比与修复、报告）。A–D 每任务独立提交且回归全过；E–F 的临时代码只在 53 `~/cosim_diff/`。

**Tech Stack:** SystemVerilog / UVM 1.2，VCS W-2024.09-SP1（53），dpu_common `4d73996`；QEMU 9.2.0（TCG）+ cosim-platform（借用）；Ubuntu 6.8.0-107 guest；Python 3（对比脚本）。

**Spec:** `docs/superpowers/specs/2026-10-07-cosim-driver-diff-design.md`

## Global Constraints

- 工作树：本机 `/home/ubuntu/ryan/virtio_sdd`，分支 `feat/cosim-driver-diff`（起点 `956001f`，基于 `6834ae6`）。不推送。不碰 `/home/ubuntu/ryan/virtio_work`。
- 不修改 dpu_common、pcie_work、host_mem、net_packet、queue_work；cosim-platform 与 icpu-kernel-driver 仓库不提交任何改动。
- SYNC（工作树根目录）：`sshpass -p ubuntu rsync -a --delete --exclude .git --exclude .superpowers --exclude build --exclude logs --exclude csrc -e "ssh -o StrictHostKeyChecking=no" ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/`
- 单测：`sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && mkdir -p logs && TEST=<t> ./scripts/vcs.sh > logs/<t>.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/<t>.log | tail -20'`
- 回归（15–25 分钟）：`sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'`，期望 `STRICT_REGRESSION PASS tests=<N>`（起点 40；新增测试的任务写明新 N）。
- 53 上同一时间只跑一个仿真任务（共享 build 目录）。
- VCS 约束：`ref` 形参之后的形参同为 ref，传变量不传字面量；块内声明须在语句之前。
- 提交：Conventional Commits，中文描述，不加 Co-Authored-By；不 push。
- 公共接口：被测试使用的接口要么保持签名，要么在同一任务内迁移全部调用方；不留兼容空壳。
- 行为非等价：以测试意图为准修实现，不放宽断言迁就实现。
- 文档：`scripts/test_manifest.sh` 在每个测试前校验 README/手册的测试列表；改测试列表或删改文档提到的类时同步更新 README.md、`docs/virtio_net_vip_manual.md`、`docs/virtio_verification_flow.md`。
- 精简原则：不为单一用途建抽象；删除被替代的代码，不保留旧路径。
- 私有设备行为依据：53 `/home/ubuntu/wn/icpu-kernel-driver`（`lance_net_mailbox@f2c9cd6`，只读），寄存器定义取 dpu_common reg plan。
- 临时 cosim 环境：53 `~/cosim_diff/`（本地 git），cosim-platform 本地副本从 59 `ryan@10.11.10.59:~/workspace/ryan/software/cosim-platform`（pw 123）复制；QEMU 源码 53 `~/qemu-9.2.0.tar.xz`。

## Review Focus

1. **私有 VF 与标准 VF 共存**：C 阶段删除私有 ops/fsm 子类后，同一 Host 下两种 Function 各自初始化、收发、停机回收互不影响。由 `dpu_priv_driver_flow_test` 覆盖（断言不变）。
2. **独立设备看不到驱动内部状态**：D 阶段设备模型只能从 PCIe 请求得知寄存器值。期望 VIP 漏写/错写任一队列寄存器时，设备拒绝该队列并在测试中暴露。由 D 阶段设备单元测试的"缺写 queue_driver 时 enable 被拒"用例覆盖。
3. **ctrl 超时后的迟到完成**：A 阶段 R3.1。期望迟到完成不被下一条命令消费、超时命令的 buffer 不被复用。由 `virtio_ctrl_vq_test` 新用例覆盖。
4. **MQ 扩容后的中断向量**：A 阶段 R3.2。期望扩容后新队列拿到有效向量。由新单元用例覆盖。
5. **私有寄存器级后端与真实驱动一致**：D 阶段私有后端的寄存器写序列须与真实驱动源码一致。由 D 阶段私有设备单元测试按驱动源码顺序断言，F 阶段 cosim 对比最终确认。

---

## 执行顺序

A1 → A2 → A3 → A4 → B1 → B2 → C1 → C2 → C3 → C4 → D1 → D2 → D3 → D4 → D5 → D6 → E1 → E2 → E3 → F1 → F2 → F3

回归测试数：A–C 为 40；D1 起 41（新增 `virtio_vdev_unit_test`），F 阶段每个 VIP 修复补的测试优先加入既有测试，不新增 manifest 条目时保持 41。

各阶段末尾的 "Notes for integrator" 记录接口、偏离与风险，执行相关任务前先阅读。

---

## 阶段 A：已知缺陷（规范 R3）

四个缺陷均已在 `feat/cosim-driver-diff`（`956001f`）上逐一确认真实存在，证据见各任务的“缺陷确认”。
行号均指起点代码；编辑一律按唯一文本锚点定位，不按行号。

---

### Task A1: ctrl_send 超时后复位或隔离 control VQ，与 Admin VQ 共用恢复实现（规范 R3.1）

**缺陷确认：** `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh:409-419` 中 `ctrl_send`
轮询超时后只报错，随即 `dma_set.release_all()` 解除映射并释放 hdr/data/ack 三块缓冲，而描述符仍挂在 control VQ 上
（未 detach、未复位队列）。后果两条：(1) 设备迟到的完成会 DMA 写入已释放、可能已被下一条命令复用的 IOVA/GPA；
(2) 迟到完成留在 used ring，下一次 `ctrl_send` 的 `poll_used`（同文件 :399-406）先拿到它，把自己命令的 ack
缓冲当成结果读取并释放，自己的描述符反而悬空。对照同文件 Admin VQ 路径 :215-236：超时后先 Q_RESET（协商
`VIRTIO_F_RING_RESET`）或 PF 全复位，复位未确认时 `quarantine_into` 隔离 DMA。缺陷真实存在。

另：Admin 路径 :217 的 Q_RESET 直接调用 `admin_context.transport.write_queue_reset_verified`，绕过配置后端；
本任务让共用实现经后端发出，因此 `virtio_admin_vq_context` 增加 `config_backend` 字段（B1 再用它替换
`virtio_pf_manager.sv:690` 的直接 status 读）。

ctrl 侧没有 PF 全复位 owner：未协商 RING_RESET 或 Q_RESET 未确认时，缓冲隔离在 ops 中，后续 `ctrl_send`
拒绝提交，直到 `device_reset_verified` 确认复位后回收（不在 ctrl_send 内部做整机复位）。

**Files:**
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv`（前向声明 + `virtio_admin_vq_context.config_backend`）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`（ctrl 隔离列表成员、`has_pending_normal_dma`）
- Modify: `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh`（共用 helper、admin/ctrl 调用）
- Modify: `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh`（设备复位回收 ctrl 隔离）
- Modify: `virtio_net_vip/tests/virtio_admin_vq_test.sv`（上下文注入 common-config 后端）
- Modify: `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`（设备桩 + 两个子测试）
- Test: `virtio_ctrl_vq_test`、`virtio_admin_vq_test`

**Interfaces:**
- Consumes: `virtio_config_backend::reset_queue(int unsigned queue_id, output bit ok)`；
  `virtio_admin_full_reset_owner::reset_pf_lifecycle(ref bit reset_complete)`；
  `virtio_dma_buffer_set::quarantine_into(ref bit [63:0] q_iovas[$], ref bit [63:0] q_gpas[$])`；
  `virtio_mock_transport`（`queue_reset_count/last_reset_queue_id/queue_reset_complete/programmed_qids/kick_count`）。
- Produces:
  - `protected task virtio_atomic_ops::reset_or_quarantine_vq(int unsigned queue_id, virtio_config_backend backend, bit ring_reset, virtio_admin_full_reset_owner full_reset_owner, virtio_dma_buffer_set dma_set, ref bit [63:0] quarantined_iovas[$], ref bit [63:0] quarantined_gpas[$], ref bit reset_complete)`——ctrl 与 admin 唯一的超时恢复实现。
  - `virtio_admin_vq_context::config_backend`（`virtio_config_backend`，须绑定 `ctx.transport`）；为空时
    `admin_vq_submit: incomplete Admin VQ context`，绑定其他 transport 时 `admin_vq_submit: Admin VQ binding is inconsistent`。
  - `ctrl_send` 新错误串（`ATOMIC_OPS`）：`ctrl_send: control VQ %0d reset did not complete; DMA is quarantined until device reset`、
    `ctrl_send: control VQ has quarantined DMA; device reset required`、`ctrl_send: control VQ %0d could not be re-enabled after reset`；
    原 `ctrl_send: timeout waiting for control VQ completion` 保留。
  - 契约：Q_RESET 确认后 control VQ 被拆除并按原大小/格式重新启用（设备侧再编程一次）；未确认时缓冲保持映射与分配，
    `device_reset_verified` 成功后回收。

- [ ] **Step 1: 写失败测试**

  `virtio_ctrl_vq_test.sv`：在 `endclass : virtio_ctrl_vq_test_migration_fsm` 之后、`class virtio_ctrl_vq_test extends uvm_test;`
  之前插入设备桩：
  ```systemverilog
  // control VQ 设备桩：kick 时从 split avail ring 取走新命令并登记 {head, ack IOVA}；
  // answer_on_kick=1 时立即以 VIRTIO_NET_OK 完成，否则留给 complete_pending()（迟到完成）。
  // Q_RESET 确认后丢弃待完成命令并从 0 重新计数，与真实设备的队列复位语义一致。
  class virtio_ctrl_vq_test_device extends virtio_mock_transport;
      `uvm_object_utils(virtio_ctrl_vq_test_device)

      virtqueue_manager  vq_mgr;
      host_mem_manager   mem;
      virtio_iommu_model iommu;
      bit                answer_on_kick;
      int unsigned       seen_avail;
      int unsigned       used_idx;
      int unsigned       pending_heads[$];
      bit [63:0]         pending_acks[$];

      function new(string name = "virtio_ctrl_vq_test_device");
          super.new(name);
          answer_on_kick = 0;
          seen_avail = 0;
          used_idx = 0;
      endfunction

      virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                        bit wrap_counter);
          virtqueue_base vq;
          byte raw[];
          int unsigned avail_idx;
          int unsigned head;

          super.kick(queue_id, next_avail_idx, wrap_counter);
          vq = vq_mgr.get_queue(queue_id);
          mem.read_mem(vq.driver_ring_addr + 2, 2, raw);
          avail_idx = {raw[1], raw[0]};
          while (seen_avail != avail_idx) begin
              mem.read_mem(vq.driver_ring_addr + 4 + (seen_avail % vq.queue_size) * 2, 2, raw);
              head = {raw[1], raw[0]};
              pending_heads.push_back(head);
              pending_acks.push_back(chain_tail(vq, head));
              seen_avail++;
          end
          if (answer_on_kick)
              complete_pending();
      endtask

      virtual task write_queue_reset_verified(int unsigned queue_id,
                                              ref bit reset_complete);
          super.write_queue_reset_verified(queue_id, reset_complete);
          if (reset_complete) begin
              pending_heads.delete();
              pending_acks.delete();
              seen_avail = 0;
              used_idx = 0;
          end
      endtask

      // 以 VIRTIO_NET_OK 完成全部待完成命令：经 IOMMU 写 ack，再发布 used ring 项。
      function void complete_pending();
          virtqueue_base vq;
          byte ack[];
          iommu_fault_e fault;

          vq = vq_mgr.get_queue(last_kick_queue_id);
          ack = new[1];
          ack[0] = VIRTIO_NET_OK;
          foreach (pending_heads[i]) begin
              void'(iommu.write_from_device_for_host(iommu_host_id(), mem, bdf,
                                                     pending_acks[i], ack, fault));
              virtio_vq_test_kit::complete_split_at(mem, vq, used_idx % vq.queue_size,
                                                    pending_heads[i], 1, used_idx + 1);
              used_idx++;
          end
          pending_heads.delete();
          pending_acks.delete();
      endfunction

      // 沿 split 描述符链走到末项（ack，设备可写），返回其 IOVA。
      protected function bit [63:0] chain_tail(virtqueue_base vq, int unsigned head);
          byte raw[];
          int unsigned idx;

          idx = head;
          mem.read_mem(vq.desc_table_addr + idx * 16, 16, raw);
          while ({raw[13], raw[12]} & VIRTQ_DESC_F_NEXT) begin
              idx = {raw[15], raw[14]};
              mem.read_mem(vq.desc_table_addr + idx * 16, 16, raw);
          end
          return {raw[7], raw[6], raw[5], raw[4], raw[3], raw[2], raw[1], raw[0]};
      endfunction
  endclass : virtio_ctrl_vq_test_device
  ```

  `run_phase` old：
  ```systemverilog
          test_ctrl_send_map_failure_rolls_back();
          test_ctrl_vq_outside_data_range_migration_and_msix();
  ```
  new：
  ```systemverilog
          test_ctrl_send_map_failure_rolls_back();
          test_ctrl_send_timeout_resets_queue();
          test_ctrl_send_timeout_quarantines_without_ring_reset();
          test_ctrl_vq_outside_data_range_migration_and_msix();
  ```

  在 `endclass : virtio_ctrl_vq_test` 之前插入：
  ```systemverilog
      // 协商 RING_RESET：第一条命令设备不应答 → 超时后 Q_RESET 并重新启用 control VQ；
      // 设备随后的迟到完成不得被第二条命令消费，第二条命令拿到自己的 ack，描述符全部归还。
      task test_ctrl_send_timeout_resets_queue();
          virtio_ctrl_vq_test_device device =
              virtio_ctrl_vq_test_device::type_id::create("timeout_reset_device");
          virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("timeout_reset_ops");
          virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("timeout_reset_vq_mgr");
          virtio_ctrl_vq_test_mem mem =
              virtio_ctrl_vq_test_mem::type_id::create("timeout_reset_mem");
          virtio_ctrl_vq_test_iommu iommu =
              virtio_ctrl_vq_test_iommu::type_id::create("timeout_reset_iommu");
          virtio_ctrl_vq_test_catcher catcher;
          virtio_ctrl_ack_e first_ack;
          virtio_ctrl_ack_e second_ack;
          byte unsigned data[];
          int unsigned expected_qids[$];
          bit ok;

          mem.init_region(64'h7400_0000, 64'h7400_FFFF);
          wire_ops(ops, device, vq_mgr, mem, mem, iommu, 16'h0904);
          device.vq_mgr = vq_mgr;
          device.mem = mem;
          device.iommu = iommu;
          ops.wait_pol.default_timeout_ns = 200;
          ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
          ops.negotiated_features[VIRTIO_F_RING_RESET] = 1'b1;
          ops.setup_queue(2, 8, VQ_SPLIT, ok);
          assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")

          data = new[2];
          data[0] = 8'h01;
          data[1] = 8'h00;
          catcher = new("timeout_reset_catcher");
          catcher.expect_error("ATOMIC_OPS", "*ctrl_send: timeout waiting for control VQ completion*");
          uvm_report_cb::add(null, catcher);
          ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                        data, first_ack);
          uvm_report_cb::delete(null, catcher);

          device.complete_pending();   // 迟到完成：已确认复位的设备不再持有该命令
          device.answer_on_kick = 1;
          ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                        data, second_ack);
          expected_qids = '{2, 2};
          assert((first_ack == VIRTIO_NET_CTRL_ACK_ERR) &&
                 (second_ack == VIRTIO_NET_CTRL_ACK_OK) && (catcher.caught_count == 1) &&
                 (device.queue_reset_count == 1) && (device.last_reset_queue_id == 2) &&
                 (device.programmed_qids == expected_qids) &&
                 (vq_mgr.get_queue(2).get_free_count() == 8))
              else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                  "ctrl_send timeout did not reset the control VQ before reuse (acks=%s/%s caught=%0d resets=%0d programmed=%p free=%0d)",
                  first_ack.name(), second_ack.name(), catcher.caught_count,
                  device.queue_reset_count, device.programmed_qids,
                  vq_mgr.get_queue(2).get_free_count()))

          ops.teardown_queue(2);
          assert((iommu.active_mapping_count() == 0) && (mem.outstanding_allocations() == 0))
              else `uvm_fatal("CTRL_VQ_TEST", "timeout-reset test leaked control queue resources")
          mem.leak_check();
          `uvm_info("CTRL_VQ_TEST", "ctrl_send timeout queue-reset test PASSED", UVM_LOW)
      endtask

      // 未协商 RING_RESET：超时命令无法单独复位，其缓冲保持映射与分配（IOVA 不会被
      // 复用），迟到完成写入仍有效；control VQ 拒绝后续命令，确认的设备复位后才回收。
      task test_ctrl_send_timeout_quarantines_without_ring_reset();
          virtio_ctrl_vq_test_device device =
              virtio_ctrl_vq_test_device::type_id::create("quarantine_device");
          virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("quarantine_ops");
          virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("quarantine_vq_mgr");
          virtio_ctrl_vq_test_mem mem =
              virtio_ctrl_vq_test_mem::type_id::create("quarantine_mem");
          virtio_ctrl_vq_test_iommu iommu =
              virtio_ctrl_vq_test_iommu::type_id::create("quarantine_iommu");
          virtio_ctrl_vq_test_catcher catcher;
          virtqueue_base ctrl_vq;
          virtio_ctrl_ack_e first_ack;
          virtio_ctrl_ack_e second_ack;
          byte unsigned data[];
          int unsigned maps_before;
          int unsigned allocs_before;
          bit ok;

          mem.init_region(64'h7500_0000, 64'h7500_FFFF);
          wire_ops(ops, device, vq_mgr, mem, mem, iommu, 16'h0905);
          device.vq_mgr = vq_mgr;
          device.mem = mem;
          device.iommu = iommu;
          ops.wait_pol.default_timeout_ns = 200;
          ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
          ops.setup_queue(2, 8, VQ_SPLIT, ok);
          assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")
          ctrl_vq = vq_mgr.get_queue(2);
          maps_before = iommu.active_mapping_count();
          allocs_before = mem.outstanding_allocations();

          data = new[2];
          data[0] = 8'h01;
          data[1] = 8'h00;
          catcher = new("quarantine_catcher");
          catcher.expect_error("ATOMIC_OPS", "*ctrl_send: timeout waiting for control VQ completion*");
          catcher.expect_error("ATOMIC_OPS", "*DMA is quarantined until device reset*");
          catcher.expect_error("ATOMIC_OPS", "*ctrl_send: control VQ has quarantined DMA; device reset required*");
          uvm_report_cb::add(null, catcher);
          ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                        data, first_ack);
          assert((first_ack == VIRTIO_NET_CTRL_ACK_ERR) && (device.queue_reset_count == 0) &&
                 (mem.outstanding_allocations() == allocs_before + 3) &&
                 (iommu.active_mapping_count() == maps_before + 3) &&
                 (ctrl_vq.get_free_count() == 5))
              else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                  "ctrl_send timeout released DMA the device may still own (ack=%s resets=%0d allocs=%0d/%0d maps=%0d/%0d free=%0d)",
                  first_ack.name(), device.queue_reset_count, mem.outstanding_allocations(),
                  allocs_before, iommu.active_mapping_count(), maps_before,
                  ctrl_vq.get_free_count()))

          device.complete_pending();   // 迟到完成写入仍映射的隔离缓冲
          ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                        data, second_ack);
          uvm_report_cb::delete(null, catcher);
          assert((second_ack == VIRTIO_NET_CTRL_ACK_ERR) && (catcher.caught_count == 3) &&
                 (device.kick_count == 1))
              else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                  "control VQ accepted a command while DMA was quarantined (ack=%s caught=%0d kicks=%0d)",
                  second_ack.name(), catcher.caught_count, device.kick_count))

          ops.device_reset();
          assert((vq_mgr.get_queue_count() == 0) && (iommu.active_mapping_count() == 0) &&
                 (mem.outstanding_allocations() == 0))
              else `uvm_fatal("CTRL_VQ_TEST",
                  "verified device reset did not release quarantined control DMA")
          mem.leak_check();
          `uvm_info("CTRL_VQ_TEST", "ctrl_send timeout quarantine test PASSED", UVM_LOW)
      endtask
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后按“单测”命令运行 `TEST=virtio_ctrl_vq_test`。期望第一个新子测试失败：
  `UVM_FATAL ... [CTRL_VQ_TEST] ctrl_send timeout did not reset the control VQ before reuse (acks=VIRTIO_NET_CTRL_ACK_ERR/VIRTIO_NET_CTRL_ACK_OK caught=1 resets=0 programmed='{2} free=5)`
  （修复前超时不复位队列，迟到完成被第二条命令消费，第二条命令的 3 个描述符悬空）；之前可能有迟到完成写已解除映射
  IOVA 引起的未捕获 `IOMMU_*` 报告。汇总 `UVM_FATAL :    1`。

- [ ] **Step 3: 实现**

  3a. `virtio_net_vip/src/types/virtio_net_types.sv` old：
  ```systemverilog
  typedef class virtio_wait_policy;
  ```
  new：
  ```systemverilog
  typedef class virtio_wait_policy;
  typedef class virtio_config_backend;
  ```
  同文件 old：
  ```systemverilog
      virtio_admin_full_reset_owner full_reset_owner;
      // Admin commands share one virtqueue, so they must retain exclusive
  ```
  new：
  ```systemverilog
      virtio_admin_full_reset_owner full_reset_owner;
      // 本 Admin VQ 所在 PF 的配置后端（必须绑定上面的 transport）；Q_RESET 与 status
      // 读取都经它发出，Admin 路径不直接访问 common-config 寄存器。
      virtio_config_backend config_backend;
      // Admin commands share one virtqueue, so they must retain exclusive
  ```

  3b. `virtio_net_vip/src/agent/virtio_atomic_ops.sv` old：
  ```systemverilog
      protected virtio_queue_program_t queue_programs[int unsigned];
  ```
  new：
  ```systemverilog
      protected virtio_queue_program_t queue_programs[int unsigned];
      // control VQ 超时且设备未确认复位时隔离的缓冲（ctrl_send 的 dma_set 移入）。期间
      // ctrl_send 拒绝提交；只有 device_reset_verified 确认复位后才解除映射并释放。
      protected bit [63:0] ctrl_quarantined_iovas[$];
      protected bit [63:0] ctrl_quarantined_gpas[$];
  ```
  同文件 old：
  ```systemverilog
          return (migration_restore_dma.size() != 0);
      endfunction
  ```
  new：
  ```systemverilog
          return (migration_restore_dma.size() != 0) || (ctrl_quarantined_gpas.size() != 0);
      endfunction
  ```

  3c. `virtio_atomic_ops_lifecycle.svh`（`device_reset_verified`）old：
  ```systemverilog
          release_migration_restore_payloads();

          // detach_all_queues() releases descriptor ownership only.  After a
  ```
  new：
  ```systemverilog
          release_migration_restore_payloads();
          foreach (ctrl_quarantined_iovas[i])
              iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                   ctrl_quarantined_iovas[i]);
          foreach (ctrl_quarantined_gpas[i])
              mem.free(ctrl_quarantined_gpas[i]);
          ctrl_quarantined_iovas.delete();
          ctrl_quarantined_gpas.delete();

          // detach_all_queues() releases descriptor ownership only.  After a
  ```

  3d. `virtio_atomic_ops_ctrl_admin.svh`：在
  `    // ------------------------------------------------------------------------\n    // admin_vq_submit -- Submit one PF Admin-VQ request and consume response`
  之前插入共用 helper：
  ```systemverilog
      // ------------------------------------------------------------------------
      // reset_or_quarantine_vq -- 已发布但未得到有效完成的请求的唯一恢复入口
      //
      // 设备可能仍持有该请求的描述符与 DMA 缓冲。先让设备确认停止访问该队列：
      // ring_reset=1 时经后端 Q_RESET，否则 full_reset_owner 非空时请求 PF 全复位，
      // 两者皆无视为未确认。未确认时把 dma_set 移入隔离列表（之后 release_all 为空
      // 操作），调用方不得复用该队列，直到设备复位后回收隔离列表。确认后由调用方按
      // 各自的队列语义重建 ring。ctrl_send 与 admin_vq_submit 共用，不得复制。
      // ------------------------------------------------------------------------
      protected task reset_or_quarantine_vq(
          int unsigned                  queue_id,
          virtio_config_backend         backend,
          bit                           ring_reset,
          virtio_admin_full_reset_owner full_reset_owner,
          virtio_dma_buffer_set         dma_set,
          ref bit [63:0]                quarantined_iovas[$],
          ref bit [63:0]                quarantined_gpas[$],
          ref bit                       reset_complete
      );
          reset_complete = 0;
          if (ring_reset)
              backend.reset_queue(queue_id, reset_complete);
          else if (full_reset_owner != null)
              full_reset_owner.reset_pf_lifecycle(reset_complete);
          if (!reset_complete)
              dma_set.quarantine_into(quarantined_iovas, quarantined_gpas);
      endtask

  ```
  `admin_vq_submit` 上下文检查 old：
  ```systemverilog
              (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
              (admin_context.response_capacity == 0) || !admin_context.configured ||
  ```
  new：
  ```systemverilog
              (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
              (admin_context.config_backend == null) ||
              (admin_context.response_capacity == 0) || !admin_context.configured ||
  ```
  绑定一致性检查 old：
  ```systemverilog
              (admin_context.vq.iommu != admin_context.iommu)) begin
              `uvm_error("ATOMIC_OPS",
                  "admin_vq_submit: Admin VQ binding is inconsistent")
  ```
  new：
  ```systemverilog
              (admin_context.vq.iommu != admin_context.iommu) ||
              (admin_context.config_backend.bound_transport() !=
                  admin_context.transport)) begin
              `uvm_error("ATOMIC_OPS",
                  "admin_vq_submit: Admin VQ binding is inconsistent")
  ```
  Admin 恢复段 old：
  ```systemverilog
          if (submitted && reset_required) begin
              if (admin_context.negotiated_features[VIRTIO_F_RING_RESET])
                  admin_context.transport.write_queue_reset_verified(
                      admin_context.queue_id, reset_complete
                  );
              else
                  admin_context.full_reset_owner.reset_pf_lifecycle(reset_complete);
              admin_context.configured = 0;
              admin_context.recovery_required = 1;
              if (reset_complete) begin
                  admin_context.vq.detach_all_unused(detached_tokens);
                  admin_context.vq.reset_queue();
                  admin_context.vq.alloc_rings();
              end else begin
                  admin_context.dma_quarantined = 1;
                  dma_set.quarantine_into(admin_context.quarantined_iovas,
                                          admin_context.quarantined_gpas);
                  `uvm_error("ATOMIC_OPS", $sformatf(
  ```
  new：
  ```systemverilog
          if (submitted && reset_required) begin
              reset_or_quarantine_vq(admin_context.queue_id, admin_context.config_backend,
                                     admin_context.negotiated_features[VIRTIO_F_RING_RESET],
                                     admin_context.full_reset_owner, dma_set,
                                     admin_context.quarantined_iovas,
                                     admin_context.quarantined_gpas, reset_complete);
              admin_context.configured = 0;
              admin_context.recovery_required = 1;
              if (reset_complete) begin
                  admin_context.vq.detach_all_unused(detached_tokens);
                  admin_context.vq.reset_queue();
                  admin_context.vq.alloc_rings();
              end else begin
                  admin_context.dma_quarantined = 1;
                  `uvm_error("ATOMIC_OPS", $sformatf(
  ```
  （其后的错误消息与 `end end` 不变。）

  `ctrl_send` 局部变量 old：
  ```systemverilog
          bit              got_used;
          int unsigned     data_alloc_size;
  ```
  new：
  ```systemverilog
          bit              got_used;
          int unsigned     data_alloc_size;
          bit              reset_complete;
          bit              requeued;
          int unsigned     ctrl_size;
          virtqueue_type_e ctrl_type;
  ```
  old：
  ```systemverilog
          // 所有失败路径都返回 ERR；只有读到设备写回的 OK 才改为 OK。
          ack = VIRTIO_NET_CTRL_ACK_ERR;
  ```
  new：
  ```systemverilog
          // 所有失败路径都返回 ERR；只有读到设备写回的 OK 才改为 OK。
          ack = VIRTIO_NET_CTRL_ACK_ERR;

          // 上一条命令超时且设备未确认复位：其缓冲仍在设备可达范围内，迟到完成可能
          // 随时出现，此时提交会消费别人的完成；必须先完成设备复位。
          if (ctrl_quarantined_gpas.size() != 0) begin
              `uvm_error("ATOMIC_OPS",
                  "ctrl_send: control VQ has quarantined DMA; device reset required")
              return;
          end
  ```
  old：
  ```systemverilog
          if (!got_used) begin
              `uvm_error("ATOMIC_OPS", "ctrl_send: timeout waiting for control VQ completion")
          end else begin
  ```
  new：
  ```systemverilog
          if (!got_used) begin
              // 与 Admin VQ 同一恢复路径。确认复位后拆除并按原大小/格式重新启用 control
              // VQ（ring 与设备编程都重建）；未确认则隔离缓冲，等待设备复位。
              `uvm_error("ATOMIC_OPS", "ctrl_send: timeout waiting for control VQ completion")
              reset_or_quarantine_vq(ctrl_qid, cfg_backend(),
                                     negotiated_features[VIRTIO_F_RING_RESET], null, dma_set,
                                     ctrl_quarantined_iovas, ctrl_quarantined_gpas,
                                     reset_complete);
              if (reset_complete) begin
                  ctrl_size = ctrl_vq.queue_size;
                  ctrl_type = ctrl_vq.descriptor_format();
                  teardown_queue(ctrl_qid);
                  setup_queue(ctrl_qid, ctrl_size, ctrl_type, requeued);
                  if (!requeued)
                      `uvm_error("ATOMIC_OPS", $sformatf(
                          "ctrl_send: control VQ %0d could not be re-enabled after reset", ctrl_qid))
              end else begin
                  `uvm_error("ATOMIC_OPS", $sformatf(
                      "ctrl_send: control VQ %0d reset did not complete; DMA is quarantined until device reset",
                      ctrl_qid))
              end
          end else begin
  ```
  old：
  ```systemverilog
          // Cleanup IOMMU mappings and host memory
          dma_set.release_all();
  ```
  new：
  ```systemverilog
          // 正常完成或已确认复位时释放；隔离后集合为空，这里是空操作。
          dma_set.release_all();
  ```

  3e. `virtio_net_vip/tests/virtio_admin_vq_test.sv`（`configure_admin_context`）old：
  ```systemverilog
          ctx = virtio_admin_vq_context::type_id::create("admin_vq_context");
          ctx.transport = transport;
  ```
  new：
  ```systemverilog
          ctx = virtio_admin_vq_context::type_id::create("admin_vq_context");
          ctx.transport = transport;
          ctx.config_backend = virtio_common_cfg_backend::type_id::create("admin_cfg_backend");
          ctx.config_backend.bind_transport(transport);
  ```

- [ ] **Step 4: 运行，确认通过**

  SYNC 后依次单测 `TEST=virtio_ctrl_vq_test`、`TEST=virtio_admin_vq_test`。期望三行汇总均为 0；ctrl 日志含
  `ctrl_send timeout queue-reset test PASSED` 与 `ctrl_send timeout quarantine test PASSED`，无 `Leak check:`；
  admin 测试断言不变（`queue_reset_count`/`device_reset_count` 与此前相同）。

- [ ] **Step 5: 回归**

  回归命令；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 6: 提交**

  ```bash
  git add virtio_net_vip/src/types/virtio_net_types.sv virtio_net_vip/src/agent/virtio_atomic_ops.sv \
          virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh \
          virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh \
          virtio_net_vip/tests/virtio_admin_vq_test.sv virtio_net_vip/tests/virtio_ctrl_vq_test.sv
  git commit -m "fix: ctrl_send 超时后复位或隔离 control VQ，与 Admin VQ 共用恢复实现"
  ```

---

### Task A2: MQ 扩缩容后按实际队列集合重新配置 MSI-X（规范 R3.2）

**缺陷确认：** `virtio_net_vip/src/agent/virtio_auto_fsm.sv:548-586` 的 `do_configure_mq` 扩容只调用
`ops.setup_queue_range`，既不更新 `num_total_queues` 也不调用 `setup_msix`。新队列的向量来自
`virtio_atomic_ops_queue.svh:136-139`：取 `notify_mgr.queue_vectors[queue_id]`，越界则取 0。初始化时
`virtio_notification_manager.sv:240-261` 的 `remap_queue_vectors` 把空洞队列号置为 `0xFFFF`（NO_VECTOR），
例如 {0,1,4} 时队列 2/3 为 `0xFFFF`；无 control VQ 时新队列号越界得到 0（config 向量）。两种情况新队列都拿不到
自己的向量，且 `write_queue_msix_vector` 从未对它们执行。缺陷真实存在。

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv`（`do_configure_mq`）
- Modify: `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`（新子测试）
- Test: `virtio_ctrl_vq_test`

**Interfaces:**
- Consumes: `virtio_atomic_ops::setup_msix(int unsigned num_queues)`（数量等于 `vq_mgr.get_queue_count()` 时按实际队列号绑定）；
  `virtio_ctrl_vq_migration_transport`（`msix_bound_vectors`、`max_virtqueue_pairs`）。
- Produces: `configure_mq` 成功后 `num_total_queues == ops.vq_mgr.get_queue_count()`，且每条实际队列都经后端
  重新绑定 MSI-X 向量（缩容同样重建）。

- [ ] **Step 1: 写失败测试**

  `virtio_ctrl_vq_test.sv` `run_phase` old：
  ```systemverilog
          test_ctrl_vq_outside_data_range_migration_and_msix();
          `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE)
  ```
  new：
  ```systemverilog
          test_ctrl_vq_outside_data_range_migration_and_msix();
          test_mq_expansion_rebinds_msix();
          `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE)
  ```
  在 `endclass : virtio_ctrl_vq_test` 之前插入：
  ```systemverilog
      // 1 对 + CTRL_VQ（max_virtqueue_pairs=2，队列 {0,1,4}）扩到 2 对：每条实际队列（含新建
      // 的 RX1/TX1）都必须绑定有效、互不相同、非 config 的向量，并与 notification manager 一致。
      task test_mq_expansion_rebinds_msix();
          virtio_ctrl_vq_migration_transport transport =
              virtio_ctrl_vq_migration_transport::type_id::create("mq_msix_transport");
          virtio_ctrl_vq_test_mq_ops ops =
              virtio_ctrl_vq_test_mq_ops::type_id::create("mq_msix_ops");
          virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("mq_msix_vq_mgr");
          virtio_ctrl_vq_test_mem mem = virtio_ctrl_vq_test_mem::type_id::create("mq_msix_mem");
          virtio_ctrl_vq_test_iommu iommu =
              virtio_ctrl_vq_test_iommu::type_id::create("mq_msix_iommu");
          virtio_auto_fsm fsm = virtio_auto_fsm::type_id::create("mq_msix_fsm");
          virtio_memory_barrier_model barrier =
              virtio_memory_barrier_model::type_id::create("mq_msix_barrier");
          virtio_wait_policy mq_wait_pol =
              virtio_wait_policy::type_id::create("mq_msix_wait_pol");
          int unsigned qids[$];
          bit seen_vectors[int unsigned];
          bit ok;
          string why;

          mem.init_region(64'h7600_0000, 64'h7600_FFFF);
          vq_mgr.mem = mem;
          vq_mgr.iommu = iommu;
          vq_mgr.barrier = barrier;
          vq_mgr.wait_pol = mq_wait_pol;
          vq_mgr.bdf = 16'h0906;
          transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0906));
          transport.max_virtqueue_pairs = 2;
          transport.cap_mgr.msix_found = 1;
          transport.cap_mgr.msix_table_size = 8;
          transport.cap_mgr.msix_table_bir = 4;
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.mem = mem;
          ops.iommu = iommu;
          ops.wait_pol = mq_wait_pol;
          ops.negotiated_features = '0;
          ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
          ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
          ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;

          ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
          if (!ok || (vq_mgr.get_queue(4) == null))
              `uvm_fatal("CTRL_VQ_TEST", "MQ MSI-X test setup did not create queues {0,1,4}")
          ops.setup_msix(3);
          fsm.ops = ops;
          fsm.drv_cfg.queue_size = 8;
          fsm.drv_cfg.vq_type = VQ_SPLIT;
          if (!fsm.bind_mq_pair_limit(2, why))
              `uvm_fatal("CTRL_VQ_TEST", why)
          fsm.configure_mq(2);

          vq_mgr.get_queue_ids(qids);
          if ((fsm.state == FSM_ERROR) || (qids.size() != 5))
              `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                  "MQ expansion 1->2 failed: state=%s queues=%p", fsm.state.name(), qids))
          foreach (qids[i]) begin
              if (!transport.msix_bound_vectors.exists(qids[i]) ||
                  (transport.msix_bound_vectors[qids[i]] !=
                   transport.notify_mgr.queue_vectors[qids[i]]) ||
                  (transport.msix_bound_vectors[qids[i]] == 32'hFFFF) ||
                  (transport.msix_bound_vectors[qids[i]] ==
                   transport.notify_mgr.config_vector) ||
                  seen_vectors.exists(transport.msix_bound_vectors[qids[i]]))
                  `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                      "MQ expansion left queue %0d without a valid MSI-X vector: bound=%p vectors=%p",
                      qids[i], transport.msix_bound_vectors, transport.notify_mgr.queue_vectors))
              seen_vectors[transport.msix_bound_vectors[qids[i]]] = 1;
          end

          foreach (qids[i])
              ops.teardown_queue(qids[i]);
          if ((vq_mgr.get_queue_count() != 0) || (iommu.active_mapping_count() != 0) ||
              (mem.outstanding_allocations() != 0))
              `uvm_error("CTRL_VQ_TEST", "MQ MSI-X test leaked queue resources")
          mem.leak_check();
          `uvm_info("CTRL_VQ_TEST", "MQ expansion MSI-X rebinding test PASSED", UVM_LOW)
      endtask
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测 `TEST=virtio_ctrl_vq_test`。期望：
  `UVM_FATAL ... [CTRL_VQ_TEST] MQ expansion left queue 2 without a valid MSI-X vector: bound='{0:..., 1:..., 4:...} vectors='{1, 2, 65535, 65535, 3}`
  （队列 2/3 从未绑定），汇总 `UVM_FATAL :    1`。

- [ ] **Step 3: 实现**

  `virtio_auto_fsm.sv` old：
  ```systemverilog
              active_num_pairs = num_pairs;
          end else begin
              `uvm_error("AUTO_FSM",
                  $sformatf("configure_mq: device rejected MQ change to %0d pairs", num_pairs))
  ```
  new：
  ```systemverilog
              active_num_pairs = num_pairs;
              // 队列集合已变化：按 vq_mgr 中的实际队列重新建立 MSI-X，扩容新建的队列
              // 不得停留在 NO_VECTOR（或误用 config 向量）。
              num_total_queues = ops.vq_mgr.get_queue_count();
              ops.setup_msix(num_total_queues);
          end else begin
              `uvm_error("AUTO_FSM",
                  $sformatf("configure_mq: device rejected MQ change to %0d pairs", num_pairs))
  ```
  同函数头注释 old：
  ```systemverilog
      // （任一失败拆除本次新建的全部队列并 FSM_ERROR），最后更新 active_num_pairs。
  ```
  new：
  ```systemverilog
      // （任一失败拆除本次新建的全部队列并 FSM_ERROR），最后更新 active_num_pairs 与
      // num_total_queues，并按实际队列集合重建 MSI-X。
  ```

- [ ] **Step 4: 运行，确认通过**

  单测 `TEST=virtio_ctrl_vq_test`：三行汇总为 0，日志含 `MQ expansion MSI-X rebinding test PASSED`；
  原 `control VQ at 2*max_virtqueue_pairs test PASSED` 仍在（无 MSI-X capability 的 mock 走 INTx 分支，不写寄存器）。

- [ ] **Step 5: 回归**

  回归命令；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 6: 提交**

  ```bash
  git add virtio_net_vip/src/agent/virtio_auto_fsm.sv virtio_net_vip/tests/virtio_ctrl_vq_test.sv
  git commit -m "fix: MQ 扩缩容后按实际队列集合重新配置 MSI-X"
  ```

---

### Task A3: 标准协议 MANUAL ATOMIC_KICK 经 ops 发 doorbell（规范 R3.3）

**缺陷确认：** `virtio_net_vip/src/agent/virtio_driver_protocol.sv:97-106` 的
`virtio_standard_driver_protocol::kick` 只调用 `vq.kick()`；`virtqueue_base.sv:173-184` 注释明确该方法“只计数并消费
PRE/POST_NOTIFY 故障，不发 PCIe TLP”。生产通知只在受保护的 `virtio_atomic_ops::kick_with_fault`
（`virtio_atomic_ops.sv:145-153`）里，MANUAL 序列无法到达。私有协议（`dpu_priv_driver_protocol.sv:83-91`）经
`dpu_priv_atomic_ops::kick_queue` 真正发 doorbell，标准协议没有对等入口。缺陷真实存在。

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`（公有 `kick_queue`）
- Modify: `virtio_net_vip/src/agent/virtio_driver_protocol.sv`（标准 `kick`）
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv`（新子测试）
- Test: `virtio_unit_test`

**Interfaces:**
- Consumes: `kick_with_fault(virtqueue_base vq, int unsigned qid, virtio_pci_transport via = null)`；`virtio_mock_transport` kick 记录。
- Produces: `virtual task virtio_atomic_ops::kick_queue(int unsigned queue_id)`——MANUAL 通知入口，无条件发 doorbell；
  队列不存在时 `ATOMIC_OPS` 错误 `kick_queue: queue %0d not found` 且不通知。`dpu_priv_atomic_ops::kick_queue`
  （同签名）自此成为其覆写。

- [ ] **Step 1: 写失败测试**

  `virtio_unit_test.sv` `run_phase` old：
  ```systemverilog
          test_driver_protocol_selection();
          test_fabric_bar_layout_roles();
  ```
  new：
  ```systemverilog
          test_driver_protocol_selection();
          test_standard_manual_kick_notifies();
          test_fabric_bar_layout_roles();
  ```
  在文件末尾（锚点 `    endtask\n\nendclass\n\n`endif // VIRTIO_UNIT_TEST_SV`）的 `endclass` 之前插入：
  ```systemverilog
      // 标准协议 MANUAL ATOMIC_KICK 必须经 ops 向设备发 doorbell（携带 ring 游标），不能只在
      // 软件队列上计数；队列不存在时报错且不通知。
      task test_standard_manual_kick_notifies();
          virtio_standard_driver_protocol proto;
          virtio_mock_transport transport;
          virtio_vq_test_kit kit;
          virtio_atomic_ops ops;
          host_mem_manager mem;
          virtio_iommu_model iommu;
          split_virtqueue vq;
          virtio_unit_exact_error_catcher catcher;

          mem = host_mem_manager::type_id::create("manual_kick_mem");
          mem.init_region(64'h7900_0000, 64'h7900_FFFF);
          iommu = virtio_iommu_model::type_id::create("manual_kick_iommu");
          transport = virtio_mock_transport::type_id::create("manual_kick_transport");
          transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0134));
          kit = virtio_vq_test_kit::create_kit("manual_kick", mem, iommu, 16'h0134);
          ops = kit.make_ops(transport, "manual_kick_ops");
          vq = kit.add_split(0, 8);
          proto = virtio_standard_driver_protocol::type_id::create("manual_kick_protocol");

          proto.kick(ops, 0);
          catcher = new("manual_kick_missing_catcher", "ATOMIC_OPS",
                        "kick_queue: queue 5 not found");
          uvm_report_cb::add(null, catcher);
          proto.kick(ops, 5);
          uvm_report_cb::delete(null, catcher);
          if ((transport.kick_count != 1) || (transport.last_kick_queue_id != 0) ||
              (transport.last_kick_next_avail_idx != vq.get_notify_next_idx()) ||
              (catcher.caught_count != 1))
              `uvm_error("TEST", $sformatf(
                  "standard MANUAL ATOMIC_KICK did not notify the device (kicks=%0d caught=%0d)",
                  transport.kick_count, catcher.caught_count))
          kit.vq_mgr.destroy_all();
          `uvm_info("UNIT_TEST", "test_standard_manual_kick_notifies PASSED", UVM_LOW)
      endtask
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测 `TEST=virtio_unit_test`。期望
  `UVM_ERROR ... [TEST] standard MANUAL ATOMIC_KICK did not notify the device (kicks=0 caught=0)`，
  之前有未捕获的 `[VQ_MGR] get_queue: queue_id=5 not found` 与 `[VIRTIO_DRV] ATOMIC_KICK: queue 5 not found`；
  汇总 `UVM_ERROR :    3`。

- [ ] **Step 3: 实现**

  `virtio_atomic_ops.sv`：在 `kick_with_fault` 的 `endtask` 之后（锚点
  `        void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));\n    endtask`）插入：
  ```systemverilog

      // MANUAL ATOMIC_KICK 的生产入口：对已建队列无条件发 doorbell（经 PRE/POST_NOTIFY
      // 故障钩子，携带当前 ring 游标），不做事件抑制判断；队列不存在时报错且不通知。
      virtual task kick_queue(int unsigned queue_id);
          if ((vq_mgr == null) || !vq_mgr.has_queue(queue_id)) begin
              `uvm_error("ATOMIC_OPS", $sformatf("kick_queue: queue %0d not found", queue_id))
              return;
          end
          kick_with_fault(vq_mgr.get_queue(queue_id), queue_id);
      endtask
  ```
  `virtio_driver_protocol.sv` old：
  ```systemverilog
      virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
          virtqueue_base vq;

          vq = ops.vq_mgr.get_queue(queue_id);
          if (vq != null)
              vq.kick();
          else
              `uvm_error("VIRTIO_DRV",
                  $sformatf("ATOMIC_KICK: queue %0d not found", queue_id))
      endtask
  ```
  new：
  ```systemverilog
      // 经 ops 发出真实 doorbell；队列不存在由 ops 报告。
      virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
          ops.kick_queue(queue_id);
      endtask
  ```

- [ ] **Step 4: 运行，确认通过**

  单测 `TEST=virtio_unit_test`：三行汇总为 0，日志含 `test_standard_manual_kick_notifies PASSED`。

- [ ] **Step 5: 回归**

  回归命令；期望 `STRICT_REGRESSION PASS tests=40`（`dpu_priv_driver_flow_test` 覆盖私有 `kick_queue` 覆写未受影响）。

- [ ] **Step 6: 提交**

  ```bash
  git add virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/agent/virtio_driver_protocol.sv \
          virtio_net_vip/tests/virtio_unit_test.sv
  git commit -m "fix: 标准协议 MANUAL ATOMIC_KICK 经 ops 发送 doorbell"
  ```

---

### Task A4: virtqueue 的 device_host_id 去掉默认值（规范 R3.4）

**缺陷确认：** `virtio_net_vip/src/virtqueue/virtqueue_base.sv:120-129` 的 `setup(...)` 末参
`int unsigned device_host_id = 0`（注释 :117 写明 “legacy host0”）。virtqueue 构造函数 `new(name)` 不带 host，
host 只经 `setup` 注入，因此漏传即静默落到 host0 的 IOMMU 域。现存漏传点：`virtio_net_vip/tests/virtio_traffic_test.sv:491-492`
（`txq.setup(...)`）与 `:496-497`（`rxq.setup(...)`）。缺陷真实存在（契约所说的“构造参数”实际是 `setup` 参数，见 Notes）。

全部 virtqueue 创建点（`setup` 调用点）与处置：
| 位置 | 现状 | 处置 |
|---|---|---|
| `src/virtqueue/virtqueue_manager.sv:99` `vq.setup(..., bdf, host_id)` | 显式（manager 的 `host_id`） | 不改 |
| `tests/virtio_vq_test_kit.sv` `make_split` / `make_packed` `vq.setup(..., bdf, host_id)` | 显式（kit 的 `host_id`） | 不改 |
| `tests/virtio_host_mem_reclaim_test.sv:122`、`:132` `..., 16'h0100, 0)` | 显式 host0 | 不改 |
| `tests/virtio_traffic_test.sv:491` `txq.setup(..., 16'h0100)` | 漏传 | 补 `kit.host_id` |
| `tests/virtio_traffic_test.sv:496` `rxq.setup(..., 16'h0100)` | 漏传 | 补 `kit.host_id` |

`virtqueue_manager::create_queue` 的调用点（`virtio_atomic_ops_queue.svh:64`、`dpu_priv_atomic_ops.sv:97`、
`examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv:83`、tests 中 unit/vq_test_kit/traffic/stress/pf_lifecycle/monitor
共 19 处）不传 host，host 由 manager 的 `host_id` 经上面第一行显式传入，签名不变、无需修改。

**Files:**
- Modify: `virtio_net_vip/src/virtqueue/virtqueue_base.sv`
- Modify: `virtio_net_vip/tests/virtio_traffic_test.sv`
- Test: 编译（任一测试）+ `virtio_traffic_test`

**Interfaces:**
- Consumes: 无。
- Produces: `virtual function void virtqueue_base::setup(int unsigned qid, int unsigned size, host_mem_manager m, virtio_iommu_model io, virtio_memory_barrier_model b, virtqueue_error_injector e, virtio_wait_policy w, bit [15:0] device_bdf, int unsigned device_host_id)`——`device_host_id` 必填。C 阶段新增的 `dpu_priv_virtqueue` 不得重新引入默认值。

- [ ] **Step 1: 写失败“测试”（编译期）**

  `virtqueue_base.sv` old：
  ```systemverilog
      //   device_host_id -- PCIe host/IOMMU requester domain (legacy host0)
  ```
  new：
  ```systemverilog
      //   device_host_id -- PCIe host/IOMMU requester domain（必填，无默认 host）
  ```
  old：
  ```systemverilog
          bit [15:0] device_bdf,
          int unsigned device_host_id = 0
      );
  ```
  new：
  ```systemverilog
          bit [15:0] device_bdf,
          int unsigned device_host_id
      );
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测 `TEST=virtio_traffic_test`。期望编译失败，`^Error-` 行类似
  `Error-[TFAFTC] Too few arguments to function/task call`，指向 `virtio_traffic_test.sv` 的 `txq.setup(` 与 `rxq.setup(`
  两处（其他调用点已显式传 host，不应报错）。

- [ ] **Step 3: 修复调用点**

  `virtio_traffic_test.sv` old：
  ```systemverilog
                      txq.setup(1, queue_size, mem, iommu, kit.barrier, kit.err_inj,
                                kit.wait_pol, 16'h0100);
  ```
  new：
  ```systemverilog
                      txq.setup(1, queue_size, mem, iommu, kit.barrier, kit.err_inj,
                                kit.wait_pol, 16'h0100, kit.host_id);
  ```
  old：
  ```systemverilog
                      rxq.setup(0, queue_size, mem, iommu, kit.barrier, kit.err_inj,
                                kit.wait_pol, 16'h0100);
  ```
  new：
  ```systemverilog
                      rxq.setup(0, queue_size, mem, iommu, kit.barrier, kit.err_inj,
                                kit.wait_pol, 16'h0100, kit.host_id);
  ```

- [ ] **Step 4: 运行，确认通过**

  单测 `TEST=virtio_traffic_test`：无 `^Error-`，三行汇总为 0。再确认无漏网：
  `grep -rn "\.setup(" virtio_net_vip examples --include=*.sv | grep -v "seq\.\|env\."` 输出中每个 virtqueue `setup` 都有 9 个实参。

- [ ] **Step 5: 回归**

  回归命令；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 6: 提交**

  ```bash
  git add virtio_net_vip/src/virtqueue/virtqueue_base.sv virtio_net_vip/tests/virtio_traffic_test.sv
  git commit -m "fix: virtqueue setup 的 device_host_id 去掉默认值，创建点显式传 host"
  ```

---

## 阶段 B：配置后端成为唯一配置通道（规范 R2）

### Task B1: status 与 net config 访问全部经配置后端（规范 R2）

**现状（逐项 grep 确认）：** `grep -rnE "transport\.(read_device_status|write_device_status|reset_device_verified|write_queue_reset_verified|read_net_config|...)\(" virtio_net_vip/src | grep -v src/transport/`
在后端类之外命中：
| 位置 | 访问 | 处置 |
|---|---|---|
| `agent/virtio_auto_fsm.sv:1095` | `ops.transport.read_net_config(cfg)`（config_change_handler） | 改 `ops.read_net_config` |
| `agent/virtio_auto_fsm.sv:1122` | `ops.transport.read_device_status(dev_status)` | 改 `ops.read_device_status` |
| `agent/virtio_migration_engine.sv:610` | `ops.transport.read_device_status(dev_status)`（capture_snapshot） | 改 `ops.read_device_status` |
| `agent/virtio_migration_engine.sv:615` | `ops.transport.read_net_config(snap.net_config)` | 改 `ops.read_net_config` |
| `agent/atomic_ops/virtio_atomic_ops_queue.svh:337` | `transport.read_net_config(net_cfg)`（setup_all_queues 定位 control VQ） | 改 `read_net_config` |
| `agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh:217` | Admin Q_RESET 直写 transport | A1 已改为经 `admin_context.config_backend` |
| `sriov/virtio_pf_manager.sv:690` | `admin_context.transport.read_device_status(device_status)`（admin_cmd） | 改 `admin_context.config_backend.read_status` |

`atomic_ops/virtio_atomic_ops_lifecycle.svh` 的 status/feature/queue/MSI-X 操作已全部经 `cfg_backend()`，无旁路。
不属于 status/配置寄存器、本任务不动的访问（见 Notes）：`transport.notify_mgr.*`（驱动侧向量表与中断模式状态）、
`auto_fsm.sv:220` `discover_and_init_bars()`（能力发现，spec-2 范围）、`pf_manager.sv:378/499/528` 的 PCI 配置空间
（vendor id、FLR）、`dpu_priv_driver_config.sv:45` 私有 doorbell。

net config 是设备配置空间，后端目前没有入口，新增 `read_net_config`；私有后端拒绝（私有 FSM 覆写了
config_change_handler/迁移/MQ，不会走到）。

**Files:**
- Modify: `virtio_net_vip/src/transport/virtio_config_backend.sv`（基类纯虚 + common 实现）
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_config_backend.sv`（拒绝）
- Modify: `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh`（ops 包装）
- Modify: `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_queue.svh`
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv`
- Modify: `virtio_net_vip/src/agent/virtio_migration_engine.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_manager.sv`
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv`（记录后端实现新入口 + 新子测试）
- Test: `virtio_unit_test`、`virtio_ctrl_vq_test`、`virtio_admin_vq_test`

**Interfaces:**
- Consumes: A1 的 `virtio_admin_vq_context::config_backend`；`virtio_atomic_ops::read_device_status(output bit [7:0] status)`（已有）。
- Produces:
  - `pure virtual task virtio_config_backend::read_net_config(output virtio_net_device_config_t cfg)`；common 实现读 transport；
    `dpu_priv_config_backend` 报 `DPU_PRIV_OPS` 错误 `read_net_config: 私有驱动不使用标准 Virtio 控制寄存器` 并清零。
    D 阶段的私有寄存器级后端与 E 阶段任何新后端都必须实现它。
  - `virtual task virtio_atomic_ops::read_net_config(output virtio_net_device_config_t cfg)`（经后端）。
  - `admin_cmd` 在 `config_backend == null` 时报 `admin_cmd: Admin VQ is not configured`。
  - 验收 grep（Step 4）在 `virtio_net_vip/src` 的 `src/transport/` 之外无输出。

- [ ] **Step 1: 写失败测试**

  `virtio_unit_test.sv` 记录后端 old：
  ```systemverilog
      virtio_queue_program_t disabled_program;

      function new(string name = "virtio_unit_recording_backend");
          super.new(name);
          status_reg = 0;
      endfunction
  ```
  new：
  ```systemverilog
      virtio_queue_program_t disabled_program;
      virtio_net_device_config_t net_config;

      function new(string name = "virtio_unit_recording_backend");
          super.new(name);
          status_reg = 0;
          net_config = '{default: 0};
      endfunction
  ```
  old：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          calls.push_back("clear_msix");
          ok = 1;
      endtask
  endclass : virtio_unit_recording_backend
  ```
  new：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          calls.push_back("clear_msix");
          ok = 1;
      endtask
      virtual task read_net_config(output virtio_net_device_config_t cfg);
          calls.push_back("read_net_config");
          cfg = net_config;
      endtask
  endclass : virtio_unit_recording_backend
  ```
  （此时基类尚无 `read_net_config`，记录后端多出的方法可以编译；测试本身因行为而失败。）

  `run_phase` old：
  ```systemverilog
          test_config_backend_injection();
          test_common_backend_queue_reset_result();
  ```
  new：
  ```systemverilog
          test_config_backend_injection();
          test_config_reads_use_backend();
          test_common_backend_queue_reset_result();
  ```
  在文件末尾 `endclass` 之前插入：
  ```systemverilog
      // 队列片段（control VQ 定位）与迁移采集读取的 net config / status 必须经注入的
      // 后端，transport 的 net config 寄存器不得被直接读取。
      task test_config_reads_use_backend();
          virtio_mock_transport transport;
          virtio_unit_recording_backend backend;
          virtio_vq_test_kit kit;
          virtio_atomic_ops ops;
          virtio_migration_engine migration;
          virtio_device_snapshot_t snap;
          host_mem_manager mem;
          virtio_iommu_model iommu;
          int unsigned net_config_calls;
          int unsigned status_calls;
          bit ctrl_at_4;
          bit reset_ok;
          bit ok;

          mem = host_mem_manager::type_id::create("cfg_read_mem");
          mem.init_region(64'h7800_0000, 64'h7800_FFFF);
          iommu = virtio_iommu_model::type_id::create("cfg_read_iommu");
          transport = virtio_mock_transport::type_id::create("cfg_read_transport");
          transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0135));
          kit = virtio_vq_test_kit::create_kit("cfg_read", mem, iommu, 16'h0135);
          ops = kit.make_ops(transport, "cfg_read_ops");
          backend = virtio_unit_recording_backend::type_id::create("cfg_read_backend");
          backend.net_config.max_virtqueue_pairs = 2;
          ops.config_backend = backend;
          ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
          ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;

          // 后端报告 max_virtqueue_pairs=2，control VQ 必须是 4（mock transport 报告 1）。
          ops.setup_all_queues(1, VQ_SPLIT, 4, ok);
          ctrl_at_4 = ok && kit.vq_mgr.has_queue(4);
          ops.device_reset_verified(reset_ok);

          migration = virtio_migration_engine::type_id::create("cfg_read_migration");
          migration.capture_snapshot(ops, 0, 0, 0, ok, snap);
          net_config_calls = 0;
          status_calls = 0;
          foreach (backend.calls[i]) begin
              if (backend.calls[i] == "read_net_config")
                  net_config_calls++;
              if (backend.calls[i] == "read_status")
                  status_calls++;
          end
          if (!ctrl_at_4 || !reset_ok || !ok || (net_config_calls != 2) ||
              (status_calls != 1) || (transport.net_config_reads != 0) ||
              (snap.net_config.max_virtqueue_pairs != 2))
              `uvm_error("TEST", $sformatf(
                  "status/net config reads bypassed the config backend (ctrl_at_4=%0b ok=%0b net_cfg=%0d status=%0d direct_net_cfg=%0d)",
                  ctrl_at_4, ok, net_config_calls, status_calls, transport.net_config_reads))
          `uvm_info("UNIT_TEST", "test_config_reads_use_backend PASSED", UVM_LOW)
      endtask
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测 `TEST=virtio_unit_test`。期望
  `UVM_ERROR ... [TEST] status/net config reads bypassed the config backend (ctrl_at_4=0 ok=1 net_cfg=0 status=0 direct_net_cfg=2)`，
  汇总 `UVM_ERROR :    1`。

- [ ] **Step 3: 实现**

  3a. `virtio_config_backend.sv` 基类 old：
  ```systemverilog
      // 屏蔽全部 MSI-X 向量。
      pure virtual task clear_msix(output bit ok);
  endclass
  ```
  new：
  ```systemverilog
      // 屏蔽全部 MSI-X 向量。
      pure virtual task clear_msix(output bit ok);
      // 读取 virtio-net 设备配置空间（MAC、link status、max_virtqueue_pairs 等）。
      pure virtual task read_net_config(output virtio_net_device_config_t cfg);
  endclass
  ```
  common 后端 old：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          transport.notify_mgr.mask_all();
          ok = 1;
      endtask
  endclass
  ```
  new：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          transport.notify_mgr.mask_all();
          ok = 1;
      endtask

      virtual task read_net_config(output virtio_net_device_config_t cfg);
          virtio_net_device_config_t value;

          transport.read_net_config(value);
          cfg = value;
      endtask
  endclass
  ```
  3b. `dpu_priv_config_backend.sv` old：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          ok = 0;
          reject("clear_msix");
      endtask
  ```
  new：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          ok = 0;
          reject("clear_msix");
      endtask

      virtual task read_net_config(output virtio_net_device_config_t cfg);
          cfg = '{default: 0};
          reject("read_net_config");
      endtask
  ```
  3c. `virtio_atomic_ops_lifecycle.svh` old：
  ```systemverilog
      virtual task read_device_status(output bit [7:0] status);
          virtio_config_backend backend;

          backend = cfg_backend();
          backend.read_status(status);
      endtask
  ```
  new：
  ```systemverilog
      virtual task read_device_status(output bit [7:0] status);
          virtio_config_backend backend;

          backend = cfg_backend();
          backend.read_status(status);
      endtask

      // 设备 net config 读取：FSM、迁移与建队片段的唯一入口，经配置后端。
      virtual task read_net_config(output virtio_net_device_config_t cfg);
          virtio_config_backend backend;

          backend = cfg_backend();
          backend.read_net_config(cfg);
      endtask
  ```
  3d. `virtio_atomic_ops_queue.svh` old：
  ```systemverilog
                  transport.read_net_config(net_cfg);
  ```
  new：
  ```systemverilog
                  read_net_config(net_cfg);
  ```
  3e. `virtio_auto_fsm.sv` old：
  ```systemverilog
                  ops.transport.read_net_config(cfg);
  ```
  new：
  ```systemverilog
                  ops.read_net_config(cfg);
  ```
  old：
  ```systemverilog
                      ops.transport.read_device_status(dev_status);
  ```
  new：
  ```systemverilog
                      ops.read_device_status(dev_status);
  ```
  3f. `virtio_migration_engine.sv` old：
  ```systemverilog
              ops.transport.read_device_status(dev_status);
              snap.device_status = dev_status;
          end

          // 4. Read device config
          ops.transport.read_net_config(snap.net_config);
  ```
  new：
  ```systemverilog
              ops.read_device_status(dev_status);
              snap.device_status = dev_status;
          end

          // 4. Read device config
          ops.read_net_config(snap.net_config);
  ```
  3g. `virtio_pf_manager.sv`（`admin_cmd`）old：
  ```systemverilog
                  (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
                  (admin_context.response_capacity == 0)) begin
                      `uvm_error("PF_MGR", "admin_cmd: Admin VQ is not configured")
  ```
  new：
  ```systemverilog
                  (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
                  (admin_context.config_backend == null) ||
                  (admin_context.response_capacity == 0)) begin
                      `uvm_error("PF_MGR", "admin_cmd: Admin VQ is not configured")
  ```
  old：
  ```systemverilog
              // Use the transport API rather than a cached status field, so the
              // decision always follows the same device-visible status source.
              admin_context.transport.read_device_status(device_status);
  ```
  new：
  ```systemverilog
              // 经 PF 配置后端读取设备可见 status，而不是缓存字段或直接寄存器访问。
              admin_context.config_backend.read_status(device_status);
  ```

- [ ] **Step 4: 运行，确认通过**

  依次单测 `TEST=virtio_unit_test`、`TEST=virtio_ctrl_vq_test`、`TEST=virtio_admin_vq_test`：三行汇总均为 0，unit 日志含
  `test_config_reads_use_backend PASSED`。本地验收 grep（工作树根目录）：
  ```bash
  grep -rnE "transport\.(read_device_status|write_device_status|reset_device_verified|write_queue_reset_verified|read_net_config|read_device_features|write_driver_features|negotiate_features|select_queue|read_queue_num_max|setup_single_queue|write_queue_enable|write_queue_msix_vector|write_config_msix_vector)\(" virtio_net_vip/src | grep -v "^virtio_net_vip/src/transport/"
  ```
  期望无输出。

- [ ] **Step 5: 回归**

  回归命令；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 6: 提交**

  ```bash
  git add virtio_net_vip/src/transport/virtio_config_backend.sv virtio_net_vip/src/dpu_priv/dpu_priv_config_backend.sv \
          virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh \
          virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_queue.svh \
          virtio_net_vip/src/agent/virtio_auto_fsm.sv virtio_net_vip/src/agent/virtio_migration_engine.sv \
          virtio_net_vip/src/sriov/virtio_pf_manager.sv virtio_net_vip/tests/virtio_unit_test.sv
  git commit -m "refactor: status 与 net config 访问全部经配置后端"
  ```

---

### Task B2: Function 提交时选择配置后端，ops 不再自建后端（规范 R2）

**现状：** `virtio_net_vip/src/agent/virtio_atomic_ops.sv:126-134` 的 `cfg_backend()` 在 `config_backend` 为空时
自建 `virtio_common_cfg_backend`；`dpu_priv/dpu_priv_atomic_ops.sv:33-36` 的 `configure_private` 再自建
`dpu_priv_config_backend` 并覆盖 `config_backend`。`sriov/virtio_function_instance.sv:368-450`
（`commit_validated_pcie_components`）只下发 protocol，不选择后端。即后端由 ops 自行决定，Function 的冻结配置
不起作用。现状真实，需要改。

设计：Function 在提交时按冻结的 Function 配置（`private_cfg` 非空即私有环）选择后端并绑定其 transport，经扩展后的
`protocol.bind_ops(ops, backend, behavior, why)` 与协议配置一起下发；协议只在成功时写入 ops（失败的提交不留半绑定）。
`cfg_backend()` 遇到空后端 `uvm_fatal`（接线错误，继续执行会空句柄解引用）。不经 Function 直接装配 ops 的测试
显式绑定 common-config 后端。

需要显式绑定后端的测试装配点（按 `cfg_backend()` 的使用点逐一核对过）：
| 位置 | 处置 |
|---|---|
| `tests/virtio_vq_test_kit.sv` `make_ops`（覆盖 indirect_desc 7 处、net_packet_multi_queue、pf_lifecycle 447/589/663、migration_dirty 1462 及 A3/B1 新测试） | 调用新 `bind_common_backend` |
| `tests/virtio_ctrl_vq_test.sv` `wire_ops`（覆盖 twice_max/alloc/map/A1 两个子测试） | 同上 |
| `tests/virtio_ctrl_vq_test.sv` `test_ctrl_vq_outside_data_range_migration_and_msix` | 同上 |
| `tests/virtio_ctrl_vq_test.sv` `test_mq_expansion_rebinds_msix`（A2） | 同上 |
| `tests/virtio_pf_lifecycle_reset_test.sv` verified_reset_ops（:535）、failed_reset_ops（:710） | 同上 |
| `tests/virtio_migration_dirty_test.sv` 6 处手工装配（:576/694/794/923/1067/1248，均为 `        ops.mem = mem;`） | 同上 |
| `tests/virtio_unit_test.sv` `test_common_backend_queue_reset_result`（:1388） | `ops.config_backend = backend;` |
| 不需要：unit :352 late_binding、:638 host1_ops（只做 DMA 写）、:1313/:1414 已注入记录后端、:1491/:1556；admin_vq_test :560/:623（Admin 走上下文后端）；dut_caps 各处经 Function 提交 | 不改 |

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`（`config_backend` 注释、`cfg_backend()`）
- Modify: `virtio_net_vip/src/agent/virtio_driver_protocol.sv`（`bind_ops` 签名，标准实现）
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv`（`bind_ops`）
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv`（`configure_private` 接收后端）
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`（提交时选择并下发）
- Modify: `virtio_net_vip/tests/virtio_vq_test_kit.sv`、`virtio_ctrl_vq_test.sv`、`virtio_pf_lifecycle_reset_test.sv`、
  `virtio_migration_dirty_test.sv`、`virtio_unit_test.sv`、`virtio_dut_caps_test.sv`
- Test: `virtio_unit_test`、`virtio_dut_caps_test`，回归全集

**Interfaces:**
- Consumes: B1 后的 `virtio_config_backend`（含 `read_net_config`）。
- Produces:
  - `pure virtual function bit virtio_driver_protocol::bind_ops(virtio_atomic_ops ops, virtio_config_backend backend, virtio_driver_config_t behavior, output string why)`；
    标准实现：`backend == null` → `why="标准协议缺少配置后端"` 返回 0，否则写入 `ops.config_backend`；私有实现：非
    `dpu_priv_config_backend` → `why="私有协议要求 dpu_priv_config_backend"` 返回 0，成功时经 `configure_private` 写入。
  - `function bit dpu_priv_atomic_ops::configure_private(dpu_priv_driver_config cfg, int unsigned pairs, dpu_priv_config_backend backend, output string why)`（C 阶段删除该类时由 `dpu_priv_driver_protocol` 接管同一逻辑）。
  - `local function virtio_config_backend virtio_function_instance::select_config_backend(string label)`——后端的唯一创建点
    （D 阶段把私有寄存器级后端接在这里）。
  - `cfg_backend()` 空后端：`UVM_FATAL [ATOMIC_OPS] no config backend selected; virtio_function_instance hands one down at commit`。
  - 测试件：`static function void virtio_vq_test_kit::bind_common_backend(virtio_atomic_ops ops)`。
  - 验收 grep：`virtio_common_cfg_backend::type_id::create` / `dpu_priv_config_backend::type_id::create` 在 `virtio_net_vip/src` 中只出现于 `virtio_function_instance.sv`。

- [ ] **Step 1: 写失败测试**

  1a. `virtio_unit_test.sv`：精确匹配 catcher 同时接受 UVM_FATAL。old：
  ```systemverilog
          if ((get_severity() == UVM_ERROR) && (get_id() == expected_id) &&
              (get_message() == expected_message)) begin
  ```
  new：
  ```systemverilog
          if (((get_severity() == UVM_ERROR) || (get_severity() == UVM_FATAL)) &&
              (get_id() == expected_id) && (get_message() == expected_message)) begin
  ```
  在 `endclass : virtio_unit_range_ops` 之后插入：
  ```systemverilog

  // 只暴露受保护的 cfg_backend()，验证未下发后端时 ops 不再自建。
  class virtio_unit_backend_probe_ops extends virtio_atomic_ops;
      `uvm_object_utils(virtio_unit_backend_probe_ops)

      function new(string name = "virtio_unit_backend_probe_ops");
          super.new(name);
      endfunction

      function virtio_config_backend probe_backend();
          return cfg_backend();
      endfunction
  endclass : virtio_unit_backend_probe_ops
  ```
  `run_phase` old：
  ```systemverilog
          test_config_reads_use_backend();
          test_common_backend_queue_reset_result();
  ```
  new：
  ```systemverilog
          test_config_reads_use_backend();
          test_ops_requires_selected_backend();
          test_common_backend_queue_reset_result();
  ```
  文件末尾 `endclass` 之前插入：
  ```systemverilog
      // 后端由 Function 在提交时选择并下发；ops 未获下发时是接线错误，不得自建后端。
      task test_ops_requires_selected_backend();
          virtio_unit_backend_probe_ops ops;
          virtio_unit_exact_error_catcher catcher;
          virtio_config_backend backend;

          ops = virtio_unit_backend_probe_ops::type_id::create("backendless_ops");
          ops.transport = virtio_mock_transport::type_id::create("backendless_transport");
          catcher = new("backendless_catcher", "ATOMIC_OPS",
              "no config backend selected; virtio_function_instance hands one down at commit");
          uvm_report_cb::add(null, catcher);
          backend = ops.probe_backend();
          uvm_report_cb::delete(null, catcher);
          if ((backend != null) || (ops.config_backend != null) || (catcher.caught_count != 1))
              `uvm_error("TEST", $sformatf(
                  "ops without a selected backend created one (backend=%0b caught=%0d)",
                  backend != null, catcher.caught_count))
          `uvm_info("UNIT_TEST", "test_ops_requires_selected_backend PASSED", UVM_LOW)
      endtask
  ```

  1b. `virtio_dut_caps_test.sv`（`assert_driver_mq_dispatch_uses_dut_cap`）old：
  ```systemverilog
          virtio_dut_caps_expected_mq_bind_fatal rebind_catcher;
  ```
  new：
  ```systemverilog
          virtio_dut_caps_expected_mq_bind_fatal rebind_catcher;
          virtio_common_cfg_backend common_backend;
  ```
  old：
  ```systemverilog
                  "committed function did not hand its driver protocol to the agent")
  ```
  new：
  ```systemverilog
                  "committed function did not hand its driver protocol to the agent")
          // 标准 Function 提交时选择 common-config 后端，绑定本 Function 的 transport 后下发给 ops。
          if (!$cast(common_backend, ops.config_backend) || (common_backend == null) ||
              (common_backend.bound_transport() != transport))
              `uvm_fatal("DUT_CAPS",
                  "committed standard function did not hand down a common-config backend bound to its transport")
  ```
  （`assert_function_commit_failure_discards_candidates`）old：
  ```systemverilog
              (busy_ops.transport != null) || (private_fsm.ops != null)) begin
  ```
  new：
  ```systemverilog
              (busy_ops.transport != null) || (busy_ops.config_backend != null) ||
              (private_fsm.ops != null)) begin
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测 `TEST=virtio_unit_test`，期望
  `UVM_ERROR ... [TEST] ops without a selected backend created one (backend=1 caught=0)`；再单测
  `TEST=virtio_dut_caps_test`，期望
  `UVM_FATAL ... [DUT_CAPS] committed standard function did not hand down a common-config backend bound to its transport`。

- [ ] **Step 3: 实现**

  3a. `virtio_atomic_ops.sv` old：
  ```systemverilog
      // ===== Device configuration backend =====
      // 设备配置副作用的唯一出口；为空时使用绑定当前 transport 的 common-config
      // 后端。私有 ops 与后续 AF 直配在此注入其他实现。
      virtio_config_backend      config_backend;
  ```
  new：
  ```systemverilog
      // ===== Device configuration backend =====
      // 设备配置副作用的唯一出口；由 virtio_function_instance 在提交时按 Function 配置
      // 选择并经协议下发（不经 Function 的装配方须显式注入）。为空即接线错误。
      virtio_config_backend      config_backend;
  ```
  old：
  ```systemverilog
      // 返回本 ops 的配置后端：未注入时创建 common-config 后端；每次调用都重新绑定
      // 当前 transport，测试或 Function 替换 transport 后不会访问旧对象。
      protected function virtio_config_backend cfg_backend();
          if (config_backend == null)
              config_backend = virtio_common_cfg_backend::type_id::create(
                  {get_name(), "_cfg_backend"});
          config_backend.bind_transport(transport);
          return config_backend;
      endfunction
  ```
  new：
  ```systemverilog
      // 返回 Function 下发的配置后端；ops 不自建后端，未下发时 UVM_FATAL。每次调用都
      // 重新绑定当前 transport，测试或 Function 替换 transport 后不会访问旧对象。
      protected function virtio_config_backend cfg_backend();
          if (config_backend == null) begin
              `uvm_fatal("ATOMIC_OPS",
                  "no config backend selected; virtio_function_instance hands one down at commit")
              return null;
          end
          config_backend.bind_transport(transport);
          return config_backend;
      endfunction
  ```

  3b. `virtio_driver_protocol.sv` 基类 old：
  ```systemverilog
      // 提交：把协议专属配置冻结进 ops；失败时 why 说明原因。
      pure virtual function bit bind_ops(virtio_atomic_ops ops,
                                         virtio_driver_config_t behavior,
                                         output string why);
  ```
  new：
  ```systemverilog
      // 提交：把 Function 选定的配置后端与协议专属配置一起冻结进 ops；失败时 why 说明
      // 原因且 ops 不被修改。
      pure virtual function bit bind_ops(virtio_atomic_ops ops,
                                         virtio_config_backend backend,
                                         virtio_driver_config_t behavior,
                                         output string why);
  ```
  标准实现 old：
  ```systemverilog
      // 标准驱动没有需要冻结的协议专属配置。
      virtual function bit bind_ops(virtio_atomic_ops ops,
                                    virtio_driver_config_t behavior,
                                    output string why);
          why = "";
          return 1;
      endfunction
  ```
  new：
  ```systemverilog
      // 标准驱动只下发配置后端，没有其他需要冻结的协议专属配置。
      virtual function bit bind_ops(virtio_atomic_ops ops,
                                    virtio_config_backend backend,
                                    virtio_driver_config_t behavior,
                                    output string why);
          why = "";
          if (backend == null) begin
              why = "标准协议缺少配置后端";
              return 0;
          end
          ops.config_backend = backend;
          return 1;
      endfunction
  ```

  3c. `dpu_priv_driver_protocol.sv` old：
  ```systemverilog
      // 冻结一份私有配置进 ops（有活动队列时 ops 拒绝重配）。
      virtual function bit bind_ops(virtio_atomic_ops ops,
                                    virtio_driver_config_t behavior,
                                    output string why);
          dpu_priv_atomic_ops private_ops;

          why = "";
          if (!$cast(private_ops, ops) || (private_ops == null)) begin
              why = "私有协议要求 dpu_priv_atomic_ops";
              return 0;
          end
          return private_ops.configure_private(private_cfg, behavior.num_queue_pairs, why);
      endfunction
  ```
  new：
  ```systemverilog
      // 冻结一份私有配置与私有配置后端进 ops（有活动队列时 ops 拒绝重配）。
      virtual function bit bind_ops(virtio_atomic_ops ops,
                                    virtio_config_backend backend,
                                    virtio_driver_config_t behavior,
                                    output string why);
          dpu_priv_atomic_ops private_ops;
          dpu_priv_config_backend private_backend;

          why = "";
          if (!$cast(private_ops, ops) || (private_ops == null)) begin
              why = "私有协议要求 dpu_priv_atomic_ops";
              return 0;
          end
          if (!$cast(private_backend, backend) || (private_backend == null)) begin
              why = "私有协议要求 dpu_priv_config_backend";
              return 0;
          end
          return private_ops.configure_private(private_cfg, behavior.num_queue_pairs,
                                               private_backend, why);
      endfunction
  ```

  3d. `dpu_priv_atomic_ops.sv` old：
  ```systemverilog
      function bit configure_private(dpu_priv_driver_config cfg,
                                      int unsigned pairs, output string why);
          if ((cfg == null) || (contexts.num() != 0)) begin
              why = "private 配置为空或仍有活动队列";
              return 0;
          end
          if (!cfg.validate(pairs, why)) return 0;
          private_backend = dpu_priv_config_backend::type_id::create(
              {get_name(), "_private_backend"});
          private_backend.control = cfg.control;
          config_backend = private_backend;
  ```
  new：
  ```systemverilog
      function bit configure_private(dpu_priv_driver_config cfg, int unsigned pairs,
                                      dpu_priv_config_backend backend, output string why);
          if ((cfg == null) || (backend == null) || (contexts.num() != 0)) begin
              why = "private 配置为空或仍有活动队列";
              return 0;
          end
          if (!cfg.validate(pairs, why)) return 0;
          backend.control = cfg.control;
          private_backend = backend;
          config_backend = backend;
  ```

  3e. `virtio_function_instance.sv` 注释 old：
  ```systemverilog
      // 选择本 Function 的驱动协议并由协议创建/校验 ops/FSM 候选；这是 driver 工厂
      // 选择的唯一位置，预检不访问设备。private_cfg 是否为空只在这里判断一次，其余
      // 标准/私有差异都经协议对象分派；factory 返回空对象时 UVM_FATAL。配置仅在提交时冻结。
  ```
  new：
  ```systemverilog
      // 选择本 Function 的驱动协议并由协议创建/校验 ops/FSM 候选；这是 driver 工厂
      // 选择的唯一位置，预检不访问设备。配置后端在提交时按同一 private_cfg 选择
      // （select_config_backend），其余标准/私有差异都经协议对象分派；factory 返回空对象时
      // UVM_FATAL。配置仅在提交时冻结。
  ```
  在 `commit_validated_pcie_components` 定义之前（锚点
  `    // 只由 commit_bind_pcie 调用：接线已通过 preflight_bind_pcie 空句柄、factory`）插入：
  ```systemverilog
      // 按冻结的 Function 配置选择配置后端：私有环（private_cfg 非空）用私有后端，否则
      // common-config 后端。后端的唯一创建点；只创建对象，不访问设备。
      local function virtio_config_backend select_config_backend(string label);
          if (private_cfg != null)
              return dpu_priv_config_backend::type_id::create({label, "_cfg_backend"});
          return virtio_common_cfg_backend::type_id::create({label, "_cfg_backend"});
      endfunction

  ```
  `commit_validated_pcie_components` old：
  ```systemverilog
          string why;

          if (pending_protocol == null) begin
              `uvm_fatal("FUNCTION_BIND", $sformatf(
                  "%s PCIe bind commit has no driver protocol", function_name))
              return 0;
          end
          if (!pending_protocol.bind_ops(ops, driver_cfg, why)) begin
  ```
  new：
  ```systemverilog
          string why;
          virtio_config_backend backend;

          if (pending_protocol == null) begin
              `uvm_fatal("FUNCTION_BIND", $sformatf(
                  "%s PCIe bind commit has no driver protocol", function_name))
              return 0;
          end
          // 后端与协议一起下发；协议只在成功时写入 ops，失败的提交不留半绑定。
          backend = select_config_backend(function_name);
          backend.bind_transport(transport_ref);
          if (!pending_protocol.bind_ops(ops, backend, driver_cfg, why)) begin
  ```

  3f. 测试件 `virtio_vq_test_kit.sv`：在 `make_ops` 之前（锚点
  `    // 把 ops 接到本套件的 vq_mgr/mem/iommu/wait_pol 与给定 transport；ops 为空时新建`）插入：
  ```systemverilog
      // 标准 Function 的配置后端由 virtio_function_instance 在提交时下发；不经 Function
      // 直接装配 ops 的测试用本函数显式注入 common-config 后端。
      static function void bind_common_backend(virtio_atomic_ops ops);
          ops.config_backend = virtio_common_cfg_backend::type_id::create(
              {ops.get_name(), "_cfg_backend"});
      endfunction

  ```
  `make_ops` old：
  ```systemverilog
          ops.wait_pol = wait_pol;
          return ops;
      endfunction
  ```
  new：
  ```systemverilog
          ops.wait_pol = wait_pol;
          bind_common_backend(ops);
          return ops;
      endfunction
  ```
  `virtio_ctrl_vq_test.sv` `wire_ops` old：
  ```systemverilog
          ops.wait_pol = wait_pol;
      endfunction
  ```
  new：
  ```systemverilog
          ops.wait_pol = wait_pol;
          virtio_vq_test_kit::bind_common_backend(ops);
      endfunction
  ```
  gap 子测试 old：
  ```systemverilog
          ops.wait_pol = wait_pol;
          ops.negotiated_features = '0;
  ```
  new：
  ```systemverilog
          ops.wait_pol = wait_pol;
          virtio_vq_test_kit::bind_common_backend(ops);
          ops.negotiated_features = '0;
  ```
  A2 子测试 old：
  ```systemverilog
          ops.wait_pol = mq_wait_pol;
  ```
  new：
  ```systemverilog
          ops.wait_pol = mq_wait_pol;
          virtio_vq_test_kit::bind_common_backend(ops);
  ```
  `virtio_pf_lifecycle_reset_test.sv` old：
  ```systemverilog
          ops.negotiated_features = 64'h0000_0300_0000_0000;
  ```
  new：
  ```systemverilog
          ops.negotiated_features = 64'h0000_0300_0000_0000;
          virtio_vq_test_kit::bind_common_backend(ops);
  ```
  old：
  ```systemverilog
          features_before = 64'h0000_0060_0000_0000;
  ```
  new：
  ```systemverilog
          features_before = 64'h0000_0060_0000_0000;
          virtio_vq_test_kit::bind_common_backend(ops);
  ```
  `virtio_migration_dirty_test.sv`：本文件 `^        ops.mem = mem;$` 恰好 6 处（:579/697/797/926/1070/1251 附近，
  `grep -c` 已核对为 6），全部替换（Edit `replace_all`）。old：
  ```systemverilog
          ops.mem = mem;
  ```
  new：
  ```systemverilog
          ops.mem = mem;
          virtio_vq_test_kit::bind_common_backend(ops);
  ```
  `virtio_unit_test.sv`（`test_common_backend_queue_reset_result`）old：
  ```systemverilog
          ops = virtio_atomic_ops::type_id::create("queue_reset_ops");
          ops.transport = transport;
  ```
  new：
  ```systemverilog
          ops = virtio_atomic_ops::type_id::create("queue_reset_ops");
          ops.transport = transport;
          ops.config_backend = backend;
  ```
  `test_driver_protocol_selection` 迁移到新签名并断言下发。局部变量 old：
  ```systemverilog
          virtio_driver_config_t behavior;
          virtio_unit_exact_error_catcher catcher;
          string why;

          behavior.num_queue_pairs = 1;
  ```
  new：
  ```systemverilog
          virtio_driver_config_t behavior;
          virtio_unit_exact_error_catcher catcher;
          virtio_common_cfg_backend std_backend;
          dpu_priv_config_backend priv_backend;
          string why;

          behavior.num_queue_pairs = 1;
          std_backend = virtio_common_cfg_backend::type_id::create("unit_standard_backend");
          priv_backend = dpu_priv_config_backend::type_id::create("unit_private_backend");
  ```
  old：
  ```systemverilog
              !standard.bind_ops(ops, behavior, why))
              `uvm_error("TEST", "standard driver protocol did not select standard ops/FSM")
  ```
  new：
  ```systemverilog
              !standard.bind_ops(ops, std_backend, behavior, why) ||
              (ops.config_backend != std_backend))
              `uvm_error("TEST", "standard driver protocol did not select standard ops/FSM")
  ```
  old：
  ```systemverilog
              !private_protocol.bind_ops(ops, behavior, why))
              `uvm_error("TEST", {"private driver protocol did not select private ops/FSM: ", why})
  ```
  new：
  ```systemverilog
              !private_protocol.bind_ops(ops, priv_backend, behavior, why) ||
              (ops.config_backend != priv_backend) ||
              (priv_backend.control != private_cfg.control))
              `uvm_error("TEST", {"private driver protocol did not select private ops/FSM: ", why})
          if (private_protocol.bind_ops(ops, std_backend, behavior, why) ||
              (why != "私有协议要求 dpu_priv_config_backend") ||
              (ops.config_backend != priv_backend))
              `uvm_error("TEST", {"private protocol accepted a common-config backend: ", why})
  ```

- [ ] **Step 4: 运行，确认通过**

  依次单测 `TEST=virtio_unit_test`、`TEST=virtio_dut_caps_test`、`TEST=virtio_ctrl_vq_test`、
  `TEST=virtio_pf_lifecycle_reset_test`、`TEST=virtio_migration_dirty_test`：三行汇总均为 0，unit 日志含
  `test_ops_requires_selected_backend PASSED`；任何日志都不得出现 `no config backend selected`。本地验收 grep：
  ```bash
  grep -rn "virtio_common_cfg_backend::type_id::create\|dpu_priv_config_backend::type_id::create" virtio_net_vip/src
  ```
  期望只有 `virtio_net_vip/src/sriov/virtio_function_instance.sv` 两行。

- [ ] **Step 5: 回归**

  回归命令；期望 `STRICT_REGRESSION PASS tests=40`。若某测试因 `UVM_FATAL [ATOMIC_OPS] no config backend selected`
  失败，说明存在上表未列的直接装配点：在该装配点调用 `virtio_vq_test_kit::bind_common_backend(ops)`（私有 ops 则注入
  `dpu_priv_config_backend`），不得恢复 ops 自建后端。

- [ ] **Step 6: 提交**

  ```bash
  git add virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/agent/virtio_driver_protocol.sv \
          virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv \
          virtio_net_vip/src/sriov/virtio_function_instance.sv \
          virtio_net_vip/tests/virtio_vq_test_kit.sv virtio_net_vip/tests/virtio_ctrl_vq_test.sv \
          virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv virtio_net_vip/tests/virtio_migration_dirty_test.sv \
          virtio_net_vip/tests/virtio_unit_test.sv virtio_net_vip/tests/virtio_dut_caps_test.sv
  git commit -m "refactor: Function 提交时选择配置后端并随协议下发，ops 不再自建后端"
  ```

---

## Notes for integrator (A/B)

**产出的接口（后续阶段依赖）：**
- `virtio_atomic_ops::reset_or_quarantine_vq(...)`（A1）：ctrl/admin 唯一超时恢复实现。C 阶段删除 `uses_private_ring()` 等私有分支时不要动它。
- `virtio_admin_vq_context::config_backend`（A1 引入，B1 用于 `admin_cmd` status 读）。
- `virtio_atomic_ops::kick_queue(int unsigned)`（A3，virtual）。`dpu_priv_atomic_ops::kick_queue` 已是其覆写；C 阶段把私有 kick
  移进 `dpu_priv_virtqueue`/protocol 时，`dpu_priv_driver_protocol::kick` 可直接改为 `ops.kick_queue(queue_id)`，A3 未改它。
- `virtqueue_base::setup(..., bit [15:0] device_bdf, int unsigned device_host_id)`（A4，无默认）。C 的 `dpu_priv_virtqueue` 继承即可。
- `virtio_config_backend::read_net_config(output virtio_net_device_config_t)`（B1，纯虚）+ `virtio_atomic_ops::read_net_config`。D 阶段
  私有寄存器级后端、E 阶段任何新后端都必须实现。
- `virtio_driver_protocol::bind_ops(ops, backend, behavior, why)`（B2 新签名）；`virtio_function_instance::select_config_backend`
  是后端唯一创建点（D 阶段改私有后端只改这里与 `dpu_priv_config_backend`）；`dpu_priv_atomic_ops::configure_private(cfg, pairs, backend, why)`
  （C 删除该类时把同一逻辑并入 `dpu_priv_driver_protocol::bind_ops`）。
- 测试件 `virtio_vq_test_kit::bind_common_backend(ops)`。

**与契约的偏差：**
- A4：契约写“virtqueue constructor `device_host_id`”，实际默认值在 `virtqueue_base::setup()`（构造函数不带 host），改的是 `setup`。
  `virtqueue_manager::create_queue` 不传 host、签名不变（host 来自 `vq_mgr.host_id`）；测试件 `create_kit(..., host_id = 0)`
  的默认值保留（仅测试）。`vq_mgr.host_id` 未赋值时仍为 0，由 `setup_queue` 已有的 host 一致性检查兜底。
- A1：ctrl 没有 PF 全复位 owner，未协商 RING_RESET 时直接隔离并阻塞 control VQ 至 `device_reset_verified`；为让 Admin 的 Q_RESET
  也经后端，Admin 上下文新增 `config_backend` 字段（契约未写）。
- B2：后端由 Function 按 `private_cfg` 在 `commit_validated_pcie_components` 选择（`private_cfg` 即冻结配置中的私有环标志），经扩展
  后的 `bind_ops` 下发；空后端是 `uvm_fatal`（契约写 “error”；用 error 会继续执行并空句柄崩溃）。

**风险：**
- A2：`configure_mq` 每次改队列数都重跑 `setup_msix`，对真实 DUT 会重写 MSI-X 表项（先屏蔽再解除）并重写每条队列的
  `queue_msix_vector`。真实 Linux 驱动在 MQ 变更时不重写向量（它一开始就按最大队列数分配），F 阶段对比可能报差异，届时按
  对比结论再调整，不要在 A2 预先做。
- A1：Q_RESET 成功后 control VQ 被拆除并重新编程一次（设备侧多一次队列编程序列），同样可能在 F 阶段对比中出现。
- B2：直接装配 ops 的测试若有遗漏，会在回归中以 `no config backend selected` 致命错误暴露（已按 `cfg_backend()` 使用点逐一核对
  并列表）；examples 只经 env 提交，无直接装配。
- B1 刻意不动：`transport.notify_mgr.*`（驱动侧向量/中断状态，不是设备寄存器）、`virtio_auto_fsm.sv:220`
  `discover_and_init_bars()`（能力发现，spec-2）、`virtio_pf_manager.sv:378/499/528` 的 PCI 配置空间访问（vendor id、FLR）、
  `dpu_priv_driver_config.sv:45` 私有 doorbell。若评审认为能力发现也属“配置通道”，需在 spec-2 中处理。
- 任务顺序依赖：A1→B1（`config_backend` 字段）、A2→B2（`mq_wait_pol` 锚点）、A3/B1→B2（unit 测试使用 `make_ops`），按 A1..A4、B1、B2 顺序执行。

## 阶段 C：私有模式收敛（规范 R1）

**目标：** 私有模式只通过三处表达差异——`dpu_priv_config_backend`（队列参数表、status/feature/
MSI-X 在私有设备上的语义、doorbell）、`dpu_priv_virtqueue`（16B 描述符、CQ、通知游标）、
`dpu_priv_driver_protocol`（能力声明、MANUAL kick/poll、复位语义）。ops 与 FSM 只保留一套通用实现。
删除 `dpu_priv_atomic_ops`、`dpu_priv_auto_fsm`、`custom_virtqueue`（含 `virtqueue_custom_callback`）、
`dpu_priv_ring_callback` 与 `uses_private_ring()`。

**前置：** A、B 已合入。B 之后 `ops.config_backend` 由 `virtio_function_instance` 在 commit 时按冻结快照
设置（私有 → `dpu_priv_config_backend`），ops 不再默认创建后端；status/net-config 访问只经后端。
本阶段的 old 锚点按 `956001f` 写成；A/B 若改动了同一段，按语义套用（anchor 文本找不到时以函数名定位）。

### C0. 迁移清单（本阶段的核心）

**`dpu_priv_atomic_ops`（`src/dpu_priv/dpu_priv_atomic_ops.sv`，456 行）**

| # | 成员 | 新归属 | 说明 |
|---|---|---|---|
| 1 | 字段 `private_backend` / `queue_cfg[]` / `default_size` / `rx_size` / `configured_pairs` | backend | `dpu_priv_config_backend` 保存 `queue_cfg[]`、`default_size`、`rx_size`；队列号是否在表内即原 `configured_pairs` 约束 |
| 2 | 字段 `contexts[]` | 通用（已正确） | 通用 ops 的 `queue_programs[]` 保存同样的设备视角参数（`to_context()` 一一对应） |
| 3 | `configure_private()` | protocol + backend | `dpu_priv_driver_protocol::bind_ops` 校验后调用 `dpu_priv_config_backend::bind_private`；“仍有活动队列”改为通用 `ops.has_active_queues()`（错误文案不变） |
| 4 | `get_queue_context()` | 通用 | 新增通用 `ops.get_queue_program()`；测试用 `dpu_priv_config_backend::to_context()` 转换 |
| 5 | `uses_private_ring()`（含基类 `virtio_atomic_ops::uses_private_ring`） | 删除 | 仅私有 FSM 自检和单元测试使用 |
| 6 | `context_ready()` | 通用（已正确）+ vq | 通用 `setup_queue` 已查 transport/vq_mgr/iommu/mem 与 vq host；barrier 非空检查在 `dpu_priv_virtqueue.prepare_notify()`；mem/iommu/bdf 同一性是 Function 接线不变量 |
| 7 | `setup_queue()` | 通用 + backend + vq | 深度：`backend.query_queue_max`（私有=默认环大小，表外队列=0 被拒）；方向/本地号/TX 控制：新钩子 `backend.prepare_queue()`；整块 desc+CQ 只映射一次：新钩子 `vq.get_ring_regions()`；CQ IOVA = 同一映射内偏移 |
| 8 | `setup_all_queues()` | 通用（已正确）+ protocol | 私有后端不接受任何 feature ⇒ 不建 control VQ；队列类型由 `protocol.queue_format()` 决定 |
| 9 | `release_stopped_queue()` | 通用（已正确） | 通用 `teardown_queue`/`device_reset_verified` 的回收顺序相同：detach token → 退休数据 DMA → unmap ring → destroy |
| 10 | `teardown_queue()` | 通用（已正确） | 通用版本已在 `backend.disable_queue` 未确认时保留全部资源 |
| 11 | `reset_queue()`（= teardown） | 通用 + backend | 通用 `reset_queue` → 私有 `backend.reset_queue` 空操作 ok=1；FSM `reset_single_queue` 负责 teardown + 重建 |
| 12 | `device_reset_verified()` | 通用（已正确） | 通用版本经 `backend.reset` 确认，失败保留全部 DMA |
| 13 | `kick_queue()` | 通用 + vq + backend | 新增通用 `ops.kick_queue()`；`kick_with_fault` 先 `vq.prepare_notify()`（wmb、游标），再 `backend.notify_queue(q, next_idx, wrap)`；私有后端组 32-bit 字写 doorbell |
| 14 | `tx_submit()` | 通用 + vq | `vq.net_hdr_bytes()==0` 时只发原始帧一个 SG，拒绝 header offload 请求；7 条 data desc 上限、方向检查已在 `dpu_priv_virtqueue.add_buf` |
| 15 | `tx_complete()` | 通用 | 每包退休记录数 = header 有无（2/1） |
| 16 | `rx_refill()` | 通用 + backend | `buf_size==0` 时取 `queue_programs[q].rx_buf_size`（私有后端在 `prepare_queue` 填入），否则 header+1514 |
| 17 | `rx_receive_frames()` | 通用 | header 字节数 0 时不解 header，payload 为整帧，`num_buffers=1`（特性为 0 自然成立） |
| 18 | `rx_receive()` | 通用（已正确） | 差异：无法解析的私有帧由报错改为与标准一致的静默丢弃（见集成说明） |
| 19 | `ctrl_send()` | 通用 + protocol | 通用 `ctrl_send` 开头查 `protocol.has_ctrl_vq()`，在找队列前拒绝，ack=ERR |
| 20 | `reject_standard_control()` | 删除 | — |
| 21–29 | `read_device_features` / `write_driver_features` / `negotiate_features` / `set_acknowledge` / `set_driver` / `set_features_ok` / `verify_features_ok` / `set_driver_ok` / `set_failed` | 通用 + backend | 私有后端语义：特性恒 0；status 为驱动侧影子寄存器（复位清零）。MANUAL 原始 status 访问仍由 driver 按 `allows_status_access()` 拒绝 |
| 30 | `setup_msix()` | 通用 + backend | 私有后端 `set_msix`/`clear_msix` 为空操作 ok=1（当前固定 polling；D 阶段接 AF MSI-X 映射） |

**`dpu_priv_auto_fsm`（81 行）**

| 成员 | 新归属 | 说明 |
|---|---|---|
| `do_full_init()` | 通用 + backend + protocol | 发现走新钩子 `backend.discover()`（私有为空，D 阶段接 AF/BAR2）；`protocol.requires_verified_reset()` 时用 `device_reset_verified` 且失败 → FSM_ERROR；status/feature 由后端语义承载；队列类型 `protocol.queue_format()`；`setup_msix` 私有为空操作。原 VQ_CUSTOM/polling 前置检查：polling 由 `prepare_candidates` 检查，类型由 `queue_format` 强制 |
| `do_full_init()` 中 `drv_cfg.queue_size` 回写 | 删除 | env_cfg 总给私有 Function 非零环大小（无 service 行为时取 `default_queue_size`，system 示例为 256）；0 的语义统一为“设备上限”（私有=默认环大小） |
| `config_change_handler()` | 通用（已正确） | B 之后 net config/status 只经后端：私有后端返回全零配置与影子 status，永不触发 DEVICE_NEEDS_RESET，不产生 MMIO |
| `adaptive_irq_loop()` | 通用（已正确） | 只调用 `vq.disable_cb/enable_cb`，私有队列上仅改本地标志，无 MMIO |
| `do_configure_mq()` | protocol | 通用 `configure_mq` 入口查 `supports_mq()` |
| `freeze_for_migration()` / `do_restore_from_migration()` | protocol | 通用入口查 `supports_migration()` |
| `reset_single_queue()` | 通用 | 通用版本吸收“先停 worker、teardown 未确认即 FSM_ERROR、完成后重启 worker”；私有 `backend.reset_queue` 为空操作 |

**`custom_virtqueue` / `virtqueue_custom_callback` / `dpu_priv_ring_callback`**

| 成员 | 新归属 |
|---|---|
| `custom_virtqueue` 全部委托方法、`check_cb` | 删除（两层间接消失） |
| `desc_entry_size` / `desc_field_defs` / `write_desc_field` / `read_desc_field` / `find_field_def` | 删除（dead：只有 README 示例） |
| `dpu_priv_ring_callback` 全部字段与 `cb_*` 方法 | `dpu_priv_virtqueue` 同名方法（去 `cb_` 前缀，`vq.` → 自身成员），`cb_kick` → `prepare_notify()`+`kick()`；`owner_vq` 消失 |
| `cb_save_state` / `cb_restore_state`（拒绝） | `dpu_priv_virtqueue` 保持拒绝（迁移由 `supports_migration()=0` 在 FSM 入口挡住） |

**通用代码中的私有分支**

| 位置 | 处理 |
|---|---|
| `virtio_atomic_ops::uses_private_ring` | 删除 |
| `virtqueue_manager::create_queue` `VQ_CUSTOM` | `VQ_DPU_PRIV` → `dpu_priv_virtqueue` |
| `setup_queue` `case (vq_type)` 的 `default:` ring 尺寸 | 删除，改用 `vq.get_ring_regions()` |
| `virtqueue_base::descriptor_format` 默认、`virtqueue_error_injector` 的 `VQ_CUSTOM` 拒绝 | 枚举改名，语义不变（私有布局不做通用描述符破坏） |
| `dpu_priv_driver_protocol` 中对私有 ops/FSM 的 `$cast` | 删除 |
| `virtio_driver::dispatch_atomic_op` 的 `allows_status_access()` | 保留（已是能力查询） |
| `virtio_function_instance::prepare_driver_candidates` 的 `private_cfg != null` | 保留（规范要求的唯一选择点） |
| `virtio_function_instance::shutdown` 的 `requires_verified_reset()` | 保留（已是能力查询） |
| `virtio_net_env_config::get_service_config` 私有分支 | 保留（配置解析，不属 ops/FSM），枚举改名 |
| `virtio_coverage` `bins custom` | 改名 `bins dpu_priv` |

**任务划分：** C1 队列层（新队列类、枚举改名、删两类）；C2 协议能力 + 通用门控 + 按格式映射 ring；
C3 后端钩子 + 通用数据路径/FSM 吸收私有行为 + 删除私有 ops/FSM + 迁移测试；C4 文档与最终 grep 证据。

**预期 src 行数变化：** 删除 1,546 行（373+636+456+81），新增约 790 行
（`dpu_priv_virtqueue` ≈560，其余为钩子、能力、门控与数据路径分支），**净减约 750 行**
（76 文件 → 74 文件）。tests/examples 净增约 120 行（新单元子测试）。

---

### Task C1: `dpu_priv_virtqueue` 与 `VQ_DPU_PRIV`（规范 R1，队列层）

**Files:**
- Create: `virtio_net_vip/src/dpu_priv/dpu_priv_virtqueue.sv`
- Delete: `virtio_net_vip/src/virtqueue/custom_virtqueue.sv`、`virtio_net_vip/src/dpu_priv/dpu_priv_ring_callback.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`、`virtio_net_vip/src/types/virtio_net_types.sv`、
  `virtio_net_vip/src/virtqueue/virtqueue_base.sv`、`split_virtqueue.sv`、`packed_virtqueue.sv`、
  `virtqueue_manager.sv`、`virtqueue_error_injector.sv`、`virtio_net_vip/src/env/virtio_coverage.sv`、
  `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv`（过渡改动，C3 删除）
- 枚举改名波及：`dpu_priv_auto_fsm.sv`、`dpu_priv_driver_protocol.sv`、`dpu_priv_config_backend.sv`、
  `virtio_net_env_config.sv`、`transport/virtio_config_backend.sv`（注释）、`tests/virtio_coverage_test.sv`、
  `tests/virtio_desc_corruption_test.sv`
- Modify: `examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv`
- Test: `dpu_priv_ring_contract_test`、`dpu_priv_driver_flow_test`、`virtio_desc_corruption_test`、`virtio_coverage_test`

**Interfaces:**
- Produces: `class dpu_priv_virtqueue extends virtqueue_base`（`src/dpu_priv/dpu_priv_virtqueue.sv`）。公开字段
  `tx_mode, local_qid, dport_info, dport_id, dport_type, rss_lag, cpu_tx_cos, l3_cs, l4_cs, fwd, cq_addr,
  ring_alloc_bytes, last_notify_word, notify_count, producer_index, producer_wrap, consumer_index,
  consumer_wrap, cq_consumer_index, cq_consumer_wrap`；方法 `decode_rx_cq(...)`、
  `static function bit [31:0] notify_word(bit wrap, int unsigned tail, int unsigned qid)`。
- Produces: `virtqueue_type_e = { VQ_SPLIT, VQ_PACKED, VQ_DPU_PRIV }`；`virtqueue_manager::create_queue(.., VQ_DPU_PRIV)`
  返回 `dpu_priv_virtqueue`。
- Produces（`virtqueue_base` 新钩子，C2/C3 使用）：
  `pure virtual function void get_ring_regions(output bit [63:0] gpas[$], output int unsigned sizes[$])`、
  `virtual function int unsigned net_hdr_bytes(bit [63:0] features)`、`virtual function bit prepare_notify()`。

- [ ] **Step 1: 写失败测试（合同测试改为面对 `dpu_priv_virtqueue`）**

  `dpu_priv_ring_contract_test.sv` 机械迁移，断言与黄金字节一律不动：
  1. 文件头注释第 2 行“生产私有回调”→“生产私有队列 `dpu_priv_virtqueue`”；第 25 行注释
     “通过真实 custom_virtqueue 接口”→“通过真实 dpu_priv_virtqueue 接口”。
  2. `make_queue` 整个函数 old（第 70–91 行，从 `// 从生产队列工厂创建 VQ_CUSTOM` 到 `endfunction`）替换为：
     ```systemverilog
         // 从生产队列工厂创建 VQ_DPU_PRIV，在 alloc_rings 前写入方向与本地队列号。
         // qid 是 VIP 本地队列 ID，local_qid 则是驱动通知字中的 DPU 本地队列号。
         // 若工厂类型不符或未分配环，fatal 阻止后续读写无效地址。
         protected function void make_queue(
             input int unsigned qid,
             input int unsigned size,
             input bit tx_mode,
             input int unsigned local_qid,
             output dpu_priv_virtqueue vq
         );
             virtqueue_base base_vq;

             base_vq = manager.create_queue(qid, size, VQ_DPU_PRIV);
             if (!$cast(vq, base_vq) || (vq == null))
                 `uvm_fatal("DPU_PRIV", "queue manager did not create dpu_priv_virtqueue")
             vq.tx_mode = tx_mode;
             vq.local_qid = local_qid;
             vq.alloc_rings();
             if (vq.desc_table_addr == 0 || vq.cq_addr == 0)
                 `uvm_fatal("DPU_PRIV", "private ring allocation failed")
         endfunction
     ```
  3. 每个测试 task 内：删除 `dpu_priv_ring_callback cb;`（`test_default_geometry` 中删除 `tx_cb`/`rx_cb`），
     `custom_virtqueue` → `dpu_priv_virtqueue`；`make_queue(..., tx, cb)` → `make_queue(..., tx)`（rx 同理）；
     其后所有 `cb.` 替换为该 task 的队列变量（`test_tx_layout_and_completion`/`test_tx_large_sg_split`/
     `test_tx_wrap` 用 `tx.`，`test_rx_layout_and_completion` 用 `rx.`），`test_default_geometry` 中
     `tx_cb.` → `tx.`、`rx_cb.` → `rx.`。即 `cb.dport_info = ...` → `tx.dport_info = ...`、
     `cb.last_notify_word` → `tx.last_notify_word`、`cb.cq_addr` → `tx.cq_addr`、`cb.decode_rx_cq(` →
     `rx.decode_rx_cq(`、`cb.producer_wrap` → `tx.producer_wrap`、`tx_cb.ring_alloc_bytes` → `tx.ring_alloc_bytes` 等。
  4. 核对：`grep -n '\bcb\b\|cb\.\|custom' examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv` 无输出；
     `grep -c 'uvm_fatal' examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv` 迁移前后都是 30。

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测（`TEST=dpu_priv_ring_contract_test`）。期望编译失败：`Error-` 行指出
  `dpu_priv_virtqueue` / `VQ_DPU_PRIV` 未声明。

- [ ] **Step 3: 枚举改名**

  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -rl 'VQ_CUSTOM' virtio_net_vip examples | xargs sed -i 's/VQ_CUSTOM/VQ_DPU_PRIV/g'
  grep -rn 'VQ_CUSTOM' virtio_net_vip examples   # 期望无输出
  ```
  `virtio_net_types.sv:126` 结果为 `typedef enum { VQ_SPLIT, VQ_PACKED, VQ_DPU_PRIV } virtqueue_type_e;`（序号不变）。
  `virtio_coverage.sv` old：`            bins custom = {VQ_DPU_PRIV};` new：`            bins dpu_priv = {VQ_DPU_PRIV};`。
  `virtqueue_error_injector.sv` old：`            why = "custom virtqueue descriptor layout is not known";`
  new：`            why = "DPU private descriptor layout is not known";`。
  `transport/virtio_config_backend.sv` 第 19 行注释已由 sed 改为 `(VQ_DPU_PRIV)`，无需再动。

- [ ] **Step 4: `virtqueue_base` 新钩子**

  文件头注释 old：`// Subclasses (split_virtqueue, packed_virtqueue, custom_virtqueue) implement`
  new：`// Subclasses (split_virtqueue, packed_virtqueue, dpu_priv_virtqueue) implement`。

  `kick()` 上方注释 old：
  ```systemverilog
      // 它不发 PCIe TLP；生产路径由 virtio_atomic_ops 经 transport 发通知。
      // custom 队列覆盖为回调。
  ```
  new：
  ```systemverilog
      // 它不发 PCIe TLP；生产路径由 virtio_atomic_ops 经配置后端发通知。
      // dpu_priv 队列覆盖为发布通知游标。
  ```

  old（通知游标默认实现之后）：
  ```systemverilog
      virtual function bit get_notify_wrap();
          return 1'b0;
      endfunction
  ```
  new：
  ```systemverilog
      virtual function bit get_notify_wrap();
          return 1'b0;
      endfunction

      // 设备可见 ring 内存区（GPA 与字节数，按映射顺序）；ops 逐区映射，并按区内
      // 偏移推出 desc/driver/device 三个 IOVA。未分配 ring 时返回空列表。
      pure virtual function void get_ring_regions(output bit [63:0] gpas[$],
                                                  output int unsigned sizes[$]);

      // 本格式每个报文携带的 virtio-net header 字节数；标准格式由协商特性决定。
      virtual function int unsigned net_hdr_bytes(bit [63:0] features);
          return virtio_net_hdr_util::get_hdr_size(features);
      endfunction

      // 写 doorbell 前的格式钩子（发布屏障、通知游标）；返回 0 时 ops 不发通知。
      // split/packed 在 add_buf 中已完成发布，无需额外动作。
      virtual function bit prepare_notify();
          return 1;
      endfunction
  ```
  （`virtio_net_hdr_util` 由 `types/virtio_net_hdr.sv` 提供，先于 virtqueue 编译。）

  `descriptor_format()` 上方注释中 “a custom queue deliberately defaults to VQ_DPU_PRIV so the generic corruption
  helper cannot guess a field offset for a user-defined layout.” 改为 “any other layout defaults to VQ_DPU_PRIV so
  the generic corruption helper cannot guess a field offset.”（Step 3 之后该句已含 `VQ_DPU_PRIV`；按原换行逐行改）。
  `inject_desc_error` 上方 `// custom 队列覆盖为回调，因为通用注入器不认识自定义布局。` →
  `// dpu_priv 队列覆盖为拒绝，因为通用注入器不认识私有布局。`；`detach_all_unused` 上方
  `// 随后释放队列所有权。custom 队列覆盖为回调。` → `// 随后释放队列所有权。dpu_priv 队列按发布顺序覆盖。`。

- [ ] **Step 5: split/packed 声明 ring 区**

  `split_virtqueue.sv` old：
  ```systemverilog
      // Split notification data carries the free-running avail->idx.
  ```
  new：
  ```systemverilog
      // desc 表、avail ring、used ring 三区，尺寸与 virtio 1.2 §2.7 一致。
      virtual function void get_ring_regions(output bit [63:0] gpas[$],
                                             output int unsigned sizes[$]);
          gpas  = '{desc_table_addr, driver_ring_addr, device_ring_addr};
          sizes = '{16 * queue_size, 6 + 2 * queue_size, 6 + 8 * queue_size};
      endfunction

      // Split notification data carries the free-running avail->idx.
  ```
  `packed_virtqueue.sv` old：
  ```systemverilog
      // Packed notification data carries the next descriptor slot and the
  ```
  new：
  ```systemverilog
      // 描述符环与两份 4B event suppression 结构，各在自己的 GPA 上映射。
      virtual function void get_ring_regions(output bit [63:0] gpas[$],
                                             output int unsigned sizes[$]);
          gpas  = '{desc_table_addr, driver_ring_addr, device_ring_addr};
          sizes = '{16 * queue_size, 4, 4};
      endfunction

      // Packed notification data carries the next descriptor slot and the
  ```
  （尺寸与 `virtio_atomic_ops_queue.svh` 现有 `case (vq_type)` 的 SPLIT/PACKED 分支逐项相同，C2 用它替换该 case。）

- [ ] **Step 6: 新建 `dpu_priv_virtqueue.sv`**

  方法体由 `dpu_priv_ring_callback.sv` 同名 `cb_*` 方法逐行搬入：去掉 `vq` 形参，`vq.X` → `X`，
  `binding_ok(vq, op)` → `binding_ok(op)`，`cb_get_free_count(vq)` → `get_free_count()`；
  `owner_vq` 与 custom 专属的 `desc_entry_size/desc_field_defs` 赋值删除。文件开头至 `read_tx_cq`：
  ```systemverilog
  // 目录层次：virtio_net_vip/src/dpu_priv；由 virtio_net_pkg 在 packed_virtqueue 之后、
  // virtqueue_manager 之前纳入。职责：icpu-kernel-driver DPU_RING_T_PRIV 的 16B TX/RX
  // 描述符、完成队列（CQ）与通知游标，作为与 split/packed 平级的队列格式。
  // 依赖 virtqueue_base、host_mem_manager 与驱动 txrx.h、txrx.c 的小端位域布局。
  // 所有权：本队列独占连续 desc+CQ 分配，free_rings 归还；SG 地址、token、数据 DMA
  // 由 ops 持有，本队列只在完成或 detach 前借用 token。复位保留 ring 分配。
  // 适用边界：普通 TX data desc 与单 buffer RX；不支持 DPU_TSO 扩展描述符、间接描述符、
  // RX 多 buffer、迁移与错误注入。通知字由 ops 经配置后端写 doorbell。
  `ifndef DPU_PRIV_VIRTQUEUE_SV
  `define DPU_PRIV_VIRTQUEUE_SV

  // 私有环与标准 packed 虽同为 16 字节描述符，但 W1/W2、CQ 与 doorbell 语义完全不同。
  // 方向与 local_qid 在 alloc_rings 前写入（配置后端或测试），分配后冻结。
  class dpu_priv_virtqueue extends virtqueue_base;
      `uvm_object_utils(dpu_priv_virtqueue)

      // 驱动 dpu_ring.local_qid 是 u8：RX 通常为 2*qpair，TX 为 2*qpair+1。
      // 此值属于 PF/VF 本地队列空间，不能由全局 queue_id 推断。
      bit          tx_mode;
      int unsigned local_qid;

      // TX 首个 data desc 的路由和校验控制；后续 SG 描述符只携带数据字段。
      bit [11:0] dport_info;
      bit [9:0]  dport_id;
      bit [2:0]  dport_type;
      bit        rss_lag;
      bit [2:0]  cpu_tx_cos;
      bit        l3_cs;
      bit        l4_cs;
      bit [1:0]  fwd;

      // 驱动按页对齐分配，CQ 紧随 N 个 16B 描述符。
      bit [63:0]   cq_addr;
      int unsigned ring_alloc_bytes;

      // 最近一次发布的驱动 writel 值与次数（诊断/合同测试）。
      bit [31:0]   last_notify_word;
      int unsigned notify_count;

      // 各索引均是 ring 槽号；wrap 初值为 1，每越过 N-1 槽翻转一次。
      int unsigned producer_index;
      bit          producer_wrap;
      int unsigned consumer_index;
      bit          consumer_wrap;
      int unsigned cq_consumer_index;
      bit          cq_consumer_wrap;

      // pending 按发布顺序保存每包首槽、链长、TX 字节数/RX buffer 长度和借用 token。
      // 留空一槽使生产者与消费者的同槽索引没有满/空歧义。
      typedef struct {
          int unsigned head_index;
          int unsigned desc_count;
          int unsigned byte_count;
          uvm_object   token;
      } pending_record_t;

      protected pending_record_t pending[$];
      protected int unsigned     pending_desc_count;
      protected int unsigned     unnotified_desc_count;
      protected bit              completion_notifications_enabled;

      protected bit              ring_allocated;
      protected bit              allocated_tx_mode;
      protected int unsigned     allocated_local_qid;
      protected int unsigned     allocated_queue_size;
      protected bit [63:0]       ring_base;
      protected host_mem_manager ring_mem;

      // 默认 TX 方向、local_qid=0、fwd=DPU_FWD_NORMAL；不分配内存。
      function new(string name = "dpu_priv_virtqueue");
          super.new(name);
          log_tag = "DPU_PRIV_RING";
          tx_mode = 1;
          local_qid = 0;
          fwd = 2'd1;
          reset_runtime();
          ring_allocated = 0;
          ring_alloc_bytes = 0;
          ring_base = 0;
          cq_addr = 0;
          ring_mem = null;
      endfunction

      // 驱动 writel 值 {wrapcounter[31], tail_ptr[30:16], local_qid[15:0]}；私有后端
      // 写 doorbell 时使用同一编码。
      static function bit [31:0] notify_word(bit wrap, int unsigned tail, int unsigned qid);
          return {wrap, tail[14:0], qid[15:0]};
      endfunction

      // 清理索引、借用 token 和通知记录，不触及 ring 内存或外部 SG。
      protected function void reset_runtime();
          pending.delete();
          pending_desc_count = 0;
          unnotified_desc_count = 0;
          producer_index = 0;
          producer_wrap = 1;
          consumer_index = 0;
          consumer_wrap = 1;
          cq_consumer_index = 0;
          cq_consumer_wrap = 1;
          completion_notifications_enabled = 1;
          last_notify_word = 0;
          notify_count = 0;
      endfunction

      // 按驱动 dpu_setup_{tx,rx}_rings 清零完整分配块；TX CQ 初始 head=0、wrap=1，
      // RX CQ 全零使首圈期望的 cq_wrapper=1 不会误判为空队列有完成。
      protected function void initialize_ring();
          byte initial_tx_cq[2];

          ring_mem.mem_set(ring_base, 0, ring_alloc_bytes);
          if (allocated_tx_mode) begin
              initial_tx_cq[0] = 8'h00;
              initial_tx_cq[1] = 8'h80;
              ring_mem.write_mem(cq_addr, initial_tx_cq);
          end
      endfunction

      // 分配后内存/几何/方向/local_qid 被改动则拒绝操作，防止按 TX 的 2B CQ 读 RX 的 16B CQ。
      protected function bit binding_ok(string operation);
          if (!ring_allocated || (mem != ring_mem) || (desc_table_addr != ring_base) ||
              (queue_size != allocated_queue_size) ||
              (tx_mode != allocated_tx_mode) || (local_qid != allocated_local_qid)) begin
              `uvm_error("DPU_PRIV_RING", $sformatf(
                  "%s: ring 未分配或 VQ/方向/local_qid 已改变", operation))
              return 0;
          end
          return 1;
      endfunction

      // 单个描述符按驱动原生 little-endian 16B 写入：addr[63:0]、W1、W2。
      // W1.len 仅 18 位，必须整字打包后一次写入，避免覆盖相邻的 dport 字段。
      protected function void write_descriptor(int unsigned index, bit [63:0] addr,
                                               bit [31:0] word1, bit [31:0] word2);
          byte data[16];

          for (int unsigned i = 0; i < 8; i++)
              data[i] = addr[i*8 +: 8];
          for (int unsigned i = 0; i < 4; i++) begin
              data[8+i] = word1[i*8 +: 8];
              data[12+i] = word2[i*8 +: 8];
          end
          ring_mem.write_mem(ring_base + index * 16, data);
      endfunction

      // 推进一个槽并处理 wrap；queue_size 在 alloc 时限制为 2..4096。
      protected function void advance_slot(ref int unsigned index, ref bit wrap);
          index++;
          if (index == allocated_queue_size) begin
              index = 0;
              wrap = ~wrap;
          end
      endfunction

      // TX CQ：bit[14:0] head_index，bit[15] wrapcounter；读前由调用者执行 rmb。
      protected function void read_tx_cq(output int unsigned head_index, output bit wrap);
          byte data[];
          bit [15:0] word0;

          ring_mem.read_mem(cq_addr, 2, data);
          word0 = {data[1], data[0]};
          head_index = word0[14:0];
          wrap = word0[15];
      endfunction
  ```
  接着按原样搬入（仅做上述机械替换；行号指 `dpu_priv_ring_callback.sv@956001f`）：
  - `decode_rx_cq(...)`：第 177–209 行（含注释），函数体不变。
  - `alloc_rings()`：来自 `cb_alloc_rings`（第 211–256 行）。签名 `virtual function void alloc_rings();`；
    删局部变量 `custom_virtqueue custom_vq;`；首个条件改为
    `if (ring_allocated || (mem == null) || (queue_size < 2) || (queue_size > 4096) || (local_qid > 255)) begin`
    （报错文案不变）；其余 `vq.mem`/`vq.queue_size`/`vq.desc_table_addr`/`vq.driver_ring_addr`/
    `vq.device_ring_addr`/`vq.queue_enable`/`vq.state` 去掉 `vq.`；删除 `owner_vq = vq;`、
    `custom_vq.desc_entry_size = 16;`、`custom_vq.desc_field_defs = '{...};` 三行。
  - `free_rings()`：来自 `cb_free_rings`（第 258–281 行），删除 `if (vq != owner_vq) begin … end` 四行与
    `owner_vq = null;`，其余去 `vq.`。
  - `reset_queue()`：来自 `cb_reset_queue`（第 283–302 行）。未分配分支写为
    `reset_runtime(); state = VQ_RESET; return;`；`binding_ok(vq, "reset_queue")` → `binding_ok("reset_queue")`；
    末尾三行计数清零改为 `clear_op_counters();`（基类 protected，清同样三个计数）。
  - `detach_all_unused(ref uvm_object tokens[$])`：来自 `cb_detach_all_unused`（第 304–316 行），
    `cb_reset_queue(vq)` → `reset_queue()`。
  - `add_buf(virtio_sg_list sgs[], int unsigned n_out_sgs, int unsigned n_in_sgs, uvm_object token, bit indirect)`：
    来自 `cb_add_buf`（第 318–451 行），`binding_ok(vq, "add_buf")` → `binding_ok("add_buf")`、
    `cb_get_free_count(vq)` → `get_free_count()`、`vq.total_add_buf_ops++` → `total_add_buf_ops++`。
  - `poll_used(ref uvm_object token, ref int unsigned len)`：来自 `cb_poll_used`（第 472–539 行），
    `vq.barrier` → `barrier`、`vq.total_poll_used_ops++` → `total_poll_used_ops++`。
  - `disable_cb()` / `enable_cb()` / `enable_cb_delayed()` / `vq_poll(int unsigned last_used)`：
    来自第 541–591 行，同样替换（`cb_enable_cb(vq)` → `enable_cb()`）。
  - `get_pending_count()`：`if (!ring_allocated) return 0; return pending.size();`。
  - `inject_desc_error(virtqueue_error_e err_type)`、`save_state(ref virtqueue_snapshot_t snap)`、
    `restore_state(virtqueue_snapshot_t snap)`：来自第 615–633 行，报错文案不变。
  然后写入以下新/改方法，并以 `endclass : dpu_priv_virtqueue` 与 `` `endif // DPU_PRIV_VIRTQUEUE_SV `` 结束：
  ```systemverilog
      // 先用 wmb 发布描述符，再记录驱动 writel 值；ops 随后经配置后端写 doorbell。
      // 未绑定 barrier 时拒绝通知，避免把尚未排序的描述符当作已发布。
      virtual function bit prepare_notify();
          if (!binding_ok("kick"))
              return 0;
          if (barrier == null) begin
              `uvm_error("DPU_PRIV_RING", "kick: 缺少 memory barrier")
              return 0;
          end
          barrier.wmb("DPU private ring descriptors before notify");
          last_notify_word = notify_word(producer_wrap, producer_index, allocated_local_qid);
          notify_count++;
          unnotified_desc_count = 0;
          total_kick_ops++;
          return 1;
      endfunction

      // 手工 kick（合同测试）只发布游标，不发 MMIO。
      virtual task kick();
          void'(prepare_notify());
      endtask

      // 返回当前仍可发布的描述符槽数；始终留一空槽，未分配返回 0。
      virtual function int unsigned get_free_count();
          if (!ring_allocated)
              return 0;
          return allocated_queue_size - 1 - pending_desc_count;
      endfunction

      // 私有 ring 没有设备 event suppression；有未通知的新描述符就需要写 doorbell。
      virtual function bit needs_notification();
          return ring_allocated && (unnotified_desc_count != 0);
      endfunction

      // doorbell 的 tail/wrap 即生产者游标。
      virtual function int unsigned get_notify_next_idx();
          return producer_index;
      endfunction
      virtual function bit get_notify_wrap();
          return producer_wrap;
      endfunction

      // 私有帧不带 virtio-net header。
      virtual function int unsigned net_hdr_bytes(bit [63:0] features);
          return 0;
      endfunction

      // 整块 desc+CQ 是一个连续映射区；未分配时为空。
      virtual function void get_ring_regions(output bit [63:0] gpas[$],
                                             output int unsigned sizes[$]);
          gpas.delete();
          sizes.delete();
          if (!ring_allocated)
              return;
          gpas.push_back(ring_base);
          sizes.push_back(ring_alloc_bytes);
      endfunction

      // 通用描述符破坏器不认识私有 W1/W2。
      virtual function virtqueue_type_e descriptor_format();
          return VQ_DPU_PRIV;
      endfunction
  ```

- [ ] **Step 7: 工厂与包**

  `virtqueue_manager.sv` old（Step 3 sed 之后）：
  ```systemverilog
              VQ_DPU_PRIV: begin
                  custom_virtqueue cq = custom_virtqueue::type_id::create(qname);
                  vq = cq;
              end
  ```
  new：
  ```systemverilog
              VQ_DPU_PRIV: begin
                  dpu_priv_virtqueue pq_priv = dpu_priv_virtqueue::type_id::create(qname);
                  vq = pq_priv;
              end
  ```
  同文件头注释：`//   - virtqueue_base, split_virtqueue, packed_virtqueue, custom_virtqueue` →
  `//   - virtqueue_base, split_virtqueue, packed_virtqueue, dpu_priv_virtqueue`；
  `// custom_virtqueue based on vq_type.` → `// dpu_priv_virtqueue based on vq_type.`；第 7–8 行
  `Creates split, packed, or` / `// custom virtqueues` 中 `custom` → `DPU private`。

  `virtio_net_pkg.sv` old：
  ```systemverilog
    `include "virtqueue/custom_virtqueue.sv"
    `include "dpu_priv/dpu_priv_ring_callback.sv"
  ```
  new：
  ```systemverilog
    `include "dpu_priv/dpu_priv_virtqueue.sv"
  ```
  ```bash
  git rm virtio_net_vip/src/virtqueue/custom_virtqueue.sv virtio_net_vip/src/dpu_priv/dpu_priv_ring_callback.sv
  ```

- [ ] **Step 8: 私有 ops 过渡改动（C3 整体删除）**

  `dpu_priv_atomic_ops.sv` `setup_queue` 声明 old：
  ```systemverilog
          custom_virtqueue vq;
          virtqueue_base base_vq;
          dpu_priv_ring_callback cb;
  ```
  new：
  ```systemverilog
          dpu_priv_virtqueue vq;
          virtqueue_base base_vq;
  ```
  old：
  ```systemverilog
          if (!$cast(vq, base_vq)) begin
              `uvm_error("DPU_PRIV_OPS", "setup_queue: 工厂未返回 custom_virtqueue")
              return;
          end
          cb = new($sformatf("private_cb_%0d", queue_id), queue_id%2, q.local_qid);
          cb.dport_info = q.dport_info;
          cb.dport_id = q.dport_id;
          cb.dport_type = q.dport_type;
          cb.cpu_tx_cos = q.cpu_tx_cos;
          cb.rss_lag = q.rss_lag;
          cb.l3_cs = q.l3_cs;
          cb.l4_cs = q.l4_cs;
          cb.fwd = q.fwd;
          vq.custom_cb = cb;
          vq.alloc_rings();
          if (cb.ring_alloc_bytes == 0) begin
  ```
  new：
  ```systemverilog
          if (!$cast(vq, base_vq)) begin
              `uvm_error("DPU_PRIV_OPS", "setup_queue: 工厂未返回 dpu_priv_virtqueue")
              return;
          end
          vq.tx_mode = queue_id%2;
          vq.local_qid = q.local_qid;
          vq.dport_info = q.dport_info;
          vq.dport_id = q.dport_id;
          vq.dport_type = q.dport_type;
          vq.cpu_tx_cos = q.cpu_tx_cos;
          vq.rss_lag = q.rss_lag;
          vq.l3_cs = q.l3_cs;
          vq.l4_cs = q.l4_cs;
          vq.fwd = q.fwd;
          vq.alloc_rings();
          if (vq.ring_alloc_bytes == 0) begin
  ```
  old：`        ctx.ring_bytes = cb.ring_alloc_bytes;` new：`        ctx.ring_bytes = vq.ring_alloc_bytes;`

  `kick_queue` 整个 task（从 `    virtual task kick_queue(int unsigned queue_id);` 到其 `endtask`）替换为：
  ```systemverilog
      virtual task kick_queue(int unsigned queue_id);
          dpu_priv_virtqueue vq;
          if (!contexts.exists(queue_id) || !$cast(vq, vq_mgr.get_queue(queue_id))) begin
              `uvm_error("DPU_PRIV_OPS", "kick: 私有队列尚未创建")
              return;
          end
          vq.kick();
          private_backend.bind_transport(transport);
          private_backend.notify_queue(contexts[queue_id], vq.last_notify_word);
      endtask
  ```
  （`private_backend` 的写法以 B 之后的实际代码为准；B 若已改成从 `config_backend` cast，照用。）

- [ ] **Step 9: 运行，确认通过**

  单测依次：`TEST=dpu_priv_ring_contract_test`（日志含 `DPU private TX/RX ring contract PASSED`）、
  `TEST=dpu_priv_driver_flow_test`（含 `DPU private src driver flow PASSED`）、`TEST=virtio_desc_corruption_test`、
  `TEST=virtio_coverage_test`。三行汇总均为 0。

- [ ] **Step 10: 删除证据**

  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -rn 'custom_virtqueue\|virtqueue_custom_callback\|dpu_priv_ring_callback\|custom_cb\|desc_field_defs\|VQ_CUSTOM' \
      virtio_net_vip/src virtio_net_vip/tests examples --include=*.sv --include=*.svh
  ```
  期望无输出（README/手册在 C4 处理）。

- [ ] **Step 11: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 12: 提交**

  ```bash
  git add virtio_net_vip/src/dpu_priv/dpu_priv_virtqueue.sv virtio_net_vip/src/virtio_net_pkg.sv \
      virtio_net_vip/src/types/virtio_net_types.sv virtio_net_vip/src/virtqueue \
      virtio_net_vip/src/env/virtio_coverage.sv virtio_net_vip/src/env/virtio_net_env_config.sv \
      virtio_net_vip/src/transport/virtio_config_backend.sv virtio_net_vip/src/dpu_priv \
      virtio_net_vip/tests/virtio_coverage_test.sv virtio_net_vip/tests/virtio_desc_corruption_test.sv \
      examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv
  git commit -m "refactor: 私有环改为与 split/packed 平级的 dpu_priv_virtqueue，删除 custom_virtqueue 与回调层"
  ```

---

### Task C2: 驱动协议能力声明、通用门控与按格式映射 ring（规范 R1）

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_driver_protocol.sv`、`virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv`
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`、`agent/atomic_ops/virtio_atomic_ops_queue.svh`、
  `agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh`、`virtio_net_vip/src/agent/virtio_auto_fsm.sv`
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv`（3 个新子测试）
- Test: `virtio_unit_test`、`virtio_ctrl_vq_test`、`virtio_migration_dirty_test`、`virtio_dut_caps_test`、`dpu_priv_driver_flow_test`

**Interfaces:**
- Produces（`virtio_driver_protocol`，基类纯虚，标准与私有实现）：`function bit has_ctrl_vq()`、
  `function bit supports_mq()`、`function bit supports_migration()`、
  `function virtqueue_type_e queue_format(virtqueue_type_e requested)`。标准：1/1/1/requested；私有：0/0/0/`VQ_DPU_PRIV`。
- Produces：`virtio_atomic_ops::protocol`（`virtio_driver_protocol`，由协议 `bind_ops` 注入；为空按标准处理）。
- Produces 错误契约：`ATOMIC_OPS` `ctrl_send: driver protocol has no control VQ`（ack=ERR，不碰队列）；
  `AUTO_FSM` `configure_mq: driver protocol does not support dynamic MQ`、
  `freeze_for_migration: driver protocol does not support migration`、
  `restore_from_migration: driver protocol does not support migration`（ok=0），FSM 状态不变。
- Produces：通用 `setup_queue` 按 `vq.get_ring_regions()` 映射；`virtio_queue_program_t.ring_bytes` = 各区字节和。

- [ ] **Step 1: 写失败测试**

  `virtio_unit_test.sv` `run_phase` old：
  ```systemverilog
          test_driver_protocol_selection();
  ```
  new：
  ```systemverilog
          test_driver_protocol_selection();
          test_driver_protocol_capabilities();
          test_private_capability_gates();
          test_setup_queue_maps_format_regions();
  ```
  在 `    // 驱动协议决定 ops/FSM 的类型、status 访问权限与关机复位语义；私有协议拒绝` 之前插入：
  ```systemverilog
      // 协议能力是通用 ops/FSM 区分标准与私有 Function 的唯一依据；bind_ops 把协议
      // 绑定进 ops，供 ops 内的能力查询使用。
      task test_driver_protocol_capabilities();
          virtio_standard_driver_protocol standard;
          dpu_priv_driver_protocol private_protocol;
          virtio_atomic_ops ops;
          virtio_driver_config_t behavior;
          string why;

          standard = virtio_standard_driver_protocol::type_id::create("cap_standard_protocol");
          private_protocol = dpu_priv_driver_protocol::type_id::create("cap_private_protocol");
          if (!standard.has_ctrl_vq() || !standard.supports_mq() ||
              !standard.supports_migration() ||
              (standard.queue_format(VQ_SPLIT) != VQ_SPLIT) ||
              (standard.queue_format(VQ_PACKED) != VQ_PACKED))
              `uvm_error("TEST", "standard protocol capabilities differ from virtio-net")
          if (private_protocol.has_ctrl_vq() || private_protocol.supports_mq() ||
              private_protocol.supports_migration() ||
              (private_protocol.queue_format(VQ_SPLIT) != VQ_DPU_PRIV) ||
              (private_protocol.queue_format(VQ_PACKED) != VQ_DPU_PRIV))
              `uvm_error("TEST", "private protocol capabilities differ from the DPU private ring")

          ops = virtio_atomic_ops::type_id::create("cap_ops");
          behavior.num_queue_pairs = 1;
          if (!standard.bind_ops(ops, behavior, why) || (ops.protocol != standard))
              `uvm_error("TEST", "standard bind_ops did not bind the protocol into ops")
          `uvm_info("UNIT_TEST", "test_driver_protocol_capabilities PASSED", UVM_LOW)
      endtask

      // 私有协议没有 control VQ、动态 MQ 与迁移：通用 ops/FSM 必须在访问队列或设备前
      // 拒绝，且不改变 FSM 状态。ops 只有协议、没有 transport/队列，任何越过门控的
      // 访问都会以空句柄失败。
      task test_private_capability_gates();
          dpu_priv_driver_protocol private_protocol;
          virtio_atomic_ops ops;
          virtio_auto_fsm fsm;
          virtio_unit_exact_error_catcher catcher;
          virtio_device_snapshot_t snap;
          virtio_ctrl_ack_e ack;
          byte unsigned data[];
          string why;
          bit ok;

          private_protocol = dpu_priv_driver_protocol::type_id::create("gate_private_protocol");
          ops = virtio_atomic_ops::type_id::create("gate_ops");
          ops.protocol = private_protocol;
          fsm = virtio_auto_fsm::type_id::create("gate_fsm");
          fsm.ops = ops;
          if (!fsm.bind_mq_pair_limit(2, why))
              `uvm_fatal("TEST", why)

          data = new[2];
          data[0] = 8'h01;
          data[1] = 8'h00;
          ack = VIRTIO_NET_CTRL_ACK_OK;
          catcher = new("gate_ctrl_catcher", "ATOMIC_OPS",
                        "ctrl_send: driver protocol has no control VQ");
          uvm_report_cb::add(null, catcher);
          ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, data, ack);
          uvm_report_cb::delete(null, catcher);
          if ((ack != VIRTIO_NET_CTRL_ACK_ERR) || (catcher.caught_count != 1))
              `uvm_error("TEST", "private ctrl_send was not rejected before touching a queue")

          catcher = new("gate_mq_catcher", "AUTO_FSM",
                        "configure_mq: driver protocol does not support dynamic MQ");
          uvm_report_cb::add(null, catcher);
          fsm.configure_mq(1);
          uvm_report_cb::delete(null, catcher);
          if ((catcher.caught_count != 1) || (fsm.state != FSM_IDLE))
              `uvm_error("TEST", "private configure_mq was not rejected by capability")

          catcher = new("gate_freeze_catcher", "AUTO_FSM",
                        "freeze_for_migration: driver protocol does not support migration");
          uvm_report_cb::add(null, catcher);
          fsm.freeze_for_migration(snap);
          uvm_report_cb::delete(null, catcher);
          if ((catcher.caught_count != 1) || (fsm.state != FSM_IDLE))
              `uvm_error("TEST", "private freeze was not rejected by capability")

          snap.num_queue_pairs = 1;
          ok = 1;
          catcher = new("gate_restore_catcher", "AUTO_FSM",
                        "restore_from_migration: driver protocol does not support migration");
          uvm_report_cb::add(null, catcher);
          fsm.restore_from_migration(snap, ok);
          uvm_report_cb::delete(null, catcher);
          if (ok || (catcher.caught_count != 1) || (fsm.state != FSM_IDLE))
              `uvm_error("TEST", "private restore was not rejected by capability")
          `uvm_info("UNIT_TEST", "test_private_capability_gates PASSED", UVM_LOW)
      endtask

      // 通用 setup_queue 按队列格式声明的 ring 区映射：私有环整块 desc+CQ 只映射一次，
      // CQ 的 IOVA 是同一映射内的偏移，没有 driver 区；拆除只解除这一条映射。
      task test_setup_queue_maps_format_regions();
          virtio_atomic_ops ops;
          virtio_unit_recording_backend backend;
          virtio_pci_transport transport;
          virtqueue_manager vq_mgr;
          virtio_iommu_model iommu;
          host_mem_manager mem;
          virtio_queue_program_t q;
          int unsigned maps_before;
          int unsigned unmaps_before;
          bit ok;

          ops = virtio_atomic_ops::type_id::create("regions_ops");
          backend = virtio_unit_recording_backend::type_id::create("regions_backend");
          transport = virtio_pci_transport::type_id::create("regions_transport");
          vq_mgr = virtqueue_manager::type_id::create("regions_vq_mgr");
          iommu = virtio_iommu_model::type_id::create("regions_iommu");
          mem = host_mem_manager::type_id::create("regions_mem");
          mem.init_region(64'h7800_0000, 64'h7801_FFFF);
          transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0133));
          vq_mgr.mem = mem;
          vq_mgr.iommu = iommu;
          vq_mgr.bdf = transport.bdf;
          vq_mgr.host_id = transport.iommu_host_id();
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.iommu = iommu;
          ops.mem = mem;
          ops.config_backend = backend;

          maps_before = iommu.total_maps;
          unmaps_before = iommu.total_unmaps;
          ops.setup_queue(1, 8, VQ_DPU_PRIV, ok);
          q = backend.configured_program;
          if (!ok || (iommu.total_maps != maps_before + 1) || (q.ring_bytes != 4096) ||
              (q.desc_iova == 0) || (q.driver_iova != 0) ||
              (q.device_iova != q.desc_iova + 8*16))
              `uvm_error("TEST", $sformatf(
                  "private ring regions mapped wrongly (ok=%0d maps=%0d bytes=%0d desc=0x%0h driver=0x%0h device=0x%0h)",
                  ok, iommu.total_maps - maps_before, q.ring_bytes,
                  q.desc_iova, q.driver_iova, q.device_iova))
          ops.teardown_queue(1);
          if ((iommu.total_unmaps != unmaps_before + 1) || (vq_mgr.get_queue_count() != 0))
              `uvm_error("TEST", "private ring teardown did not release its single mapping")
          mem.leak_check();
          `uvm_info("UNIT_TEST", "test_setup_queue_maps_format_regions PASSED", UVM_LOW)
      endtask

  ```
  （`virtio_unit_recording_backend.query_queue_max` 固定返回 8；新建的 `dpu_priv_virtqueue` 默认 TX 方向，
  8×16+2 字节页对齐为 4096。B 若改了单元测试 fixture 的后端接线方式，按 B 的写法接 `backend`。）

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测（`TEST=virtio_unit_test`）。期望编译失败：`Error-` 指出 `has_ctrl_vq`、`protocol` 不是成员。
  （旧 `setup_queue` 对 `VQ_DPU_PRIV` 走 `default:` 三区映射，区域测试会报
  `private ring regions mapped wrongly (ok=1 maps=3 ...)`。）

- [ ] **Step 3: 协议能力**

  `virtio_driver_protocol.sv` 基类 old：
  ```systemverilog
      // 驱动复位与 Function 关机是否必须等待设备确认停 DMA（失败保留全部资源）。
      pure virtual function bit requires_verified_reset();
  ```
  new：
  ```systemverilog
      // 驱动复位与 Function 关机是否必须等待设备确认停 DMA（失败保留全部资源）。
      pure virtual function bit requires_verified_reset();
      // 能力声明：通用 ops/FSM 只按这些查询区分协议，不做类型判断。
      // 是否有 virtio-net control VQ（ctrl_send 及其上的 MQ/RSS/announce 命令）。
      pure virtual function bit has_ctrl_vq();
      // 是否支持运行期改变队列对数（configure_mq）。
      pure virtual function bit supports_mq();
      // 是否支持迁移冻结与恢复。
      pure virtual function bit supports_migration();
      // 本协议实际使用的队列格式；requested 为 Function 配置值。
      pure virtual function virtqueue_type_e queue_format(virtqueue_type_e requested);
  ```
  标准协议 old：
  ```systemverilog
      virtual function bit requires_verified_reset();
          return 0;
      endfunction
  ```
  new：
  ```systemverilog
      virtual function bit requires_verified_reset();
          return 0;
      endfunction

      virtual function bit has_ctrl_vq();
          return 1;
      endfunction

      virtual function bit supports_mq();
          return 1;
      endfunction

      virtual function bit supports_migration();
          return 1;
      endfunction

      virtual function virtqueue_type_e queue_format(virtqueue_type_e requested);
          return requested;
      endfunction
  ```
  标准 `bind_ops` 体 old（位于 `// 标准驱动没有需要冻结的协议专属配置。` 之下）：
  ```systemverilog
          why = "";
          return 1;
      endfunction
  ```
  new：
  ```systemverilog
          why = "";
          ops.protocol = this;
          return 1;
      endfunction
  ```
  `dpu_priv_driver_protocol.sv` old：
  ```systemverilog
      virtual function bit requires_verified_reset();
          return 1;
      endfunction
  ```
  new：
  ```systemverilog
      virtual function bit requires_verified_reset();
          return 1;
      endfunction

      // 私有环没有 virtio-net control VQ；队列数只能停机重配；快照不描述 CQ 与私有控制面。
      virtual function bit has_ctrl_vq();
          return 0;
      endfunction

      virtual function bit supports_mq();
          return 0;
      endfunction

      virtual function bit supports_migration();
          return 0;
      endfunction

      // 私有 Function 只使用私有环，与配置值无关。
      virtual function virtqueue_type_e queue_format(virtqueue_type_e requested);
          return VQ_DPU_PRIV;
      endfunction
  ```
  私有 `bind_ops` old：
  ```systemverilog
          return private_ops.configure_private(private_cfg, behavior.num_queue_pairs, why);
  ```
  new：
  ```systemverilog
          if (!private_ops.configure_private(private_cfg, behavior.num_queue_pairs, why))
              return 0;
          ops.protocol = this;
          return 1;
  ```

- [ ] **Step 4: ops 持有协议并门控 control VQ**

  `virtio_atomic_ops.sv` old：
  ```systemverilog
  `ifndef VIRTIO_ATOMIC_OPS_SV
  `define VIRTIO_ATOMIC_OPS_SV
  ```
  new：
  ```systemverilog
  `ifndef VIRTIO_ATOMIC_OPS_SV
  `define VIRTIO_ATOMIC_OPS_SV

  // 驱动协议在本文件之后编译；ops 只查询其能力。
  typedef class virtio_driver_protocol;
  ```
  old：
  ```systemverilog
      virtio_config_backend      config_backend;
  ```
  new：
  ```systemverilog
      virtio_config_backend      config_backend;

      // ===== Driver protocol =====
      // 由协议 bind_ops 在 Function 提交时注入；ops 只查询能力（control VQ 等）。
      // 为空（直接构造 ops 的单元测试）时按标准 virtio 处理。
      virtio_driver_protocol     protocol;
  ```
  在 `kick_with_fault` 上方注释块之前插入：
  ```systemverilog
      // ring 内地址 → 设备视角 IOVA：落在第 i 个已映射 ring 区内时按区内偏移换算；
      // 0（私有环无 driver 区）或不在任何区内返回 0。
      protected function bit [63:0] ring_iova_of(bit [63:0] gpa, bit [63:0] gpas[$],
                                                 int unsigned sizes[$],
                                                 bit [63:0] iovas[$]);
          if (gpa == 0)
              return 0;
          foreach (gpas[i])
              if ((gpa >= gpas[i]) && (gpa < gpas[i] + sizes[i]))
                  return iovas[i] + (gpa - gpas[i]);
          return 0;
      endfunction

  ```
  `virtio_atomic_ops_ctrl_admin.svh` `ctrl_send` old：
  ```systemverilog
          // 所有失败路径都返回 ERR；只有读到设备写回的 OK 才改为 OK。
          ack = VIRTIO_NET_CTRL_ACK_ERR;
  ```
  new：
  ```systemverilog
          // 所有失败路径都返回 ERR；只有读到设备写回的 OK 才改为 OK。
          ack = VIRTIO_NET_CTRL_ACK_ERR;
          if ((protocol != null) && !protocol.has_ctrl_vq()) begin
              `uvm_error("ATOMIC_OPS", "ctrl_send: driver protocol has no control VQ")
              return;
          end
  ```

- [ ] **Step 5: FSM 能力门控**

  `virtio_auto_fsm.sv` `configure_mq` old：
  ```systemverilog
      task configure_mq(int unsigned num_pairs);
          if ($isunknown(num_pairs) || (num_pairs == 0) ||
  ```
  new：
  ```systemverilog
      task configure_mq(int unsigned num_pairs);
          if ((ops != null) && (ops.protocol != null) && !ops.protocol.supports_mq()) begin
              `uvm_error("AUTO_FSM", "configure_mq: driver protocol does not support dynamic MQ")
              return;
          end
          if ($isunknown(num_pairs) || (num_pairs == 0) ||
  ```
  `freeze_for_migration` old：
  ```systemverilog
          bit capture_ok;

          `uvm_info("AUTO_FSM", "freeze_for_migration: starting freeze", UVM_LOW)
  ```
  new：
  ```systemverilog
          bit capture_ok;

          if ((ops != null) && (ops.protocol != null) && !ops.protocol.supports_migration()) begin
              `uvm_error("AUTO_FSM", "freeze_for_migration: driver protocol does not support migration")
              return;
          end
          `uvm_info("AUTO_FSM", "freeze_for_migration: starting freeze", UVM_LOW)
  ```
  `restore_from_migration` old：
  ```systemverilog
                                  output bit ok);
          ok = 0;
          if ($isunknown(snap.num_queue_pairs) ||
  ```
  new：
  ```systemverilog
                                  output bit ok);
          ok = 0;
          if ((ops != null) && (ops.protocol != null) && !ops.protocol.supports_migration()) begin
              `uvm_error("AUTO_FSM", "restore_from_migration: driver protocol does not support migration")
              return;
          end
          if ($isunknown(snap.num_queue_pairs) ||
  ```
  在 `    task full_init();` 之前插入（C3 使用）：
  ```systemverilog
      // 本 Function 的队列格式：驱动协议可改写配置值（私有协议固定 VQ_DPU_PRIV）。
      protected function virtqueue_type_e queue_format();
          if ((ops == null) || (ops.protocol == null))
              return drv_cfg.vq_type;
          return ops.protocol.queue_format(drv_cfg.vq_type);
      endfunction

  ```
  （`ops.protocol` 的类型来自 `virtio_atomic_ops.sv` 中的前向 typedef；FSM 在协议定义之前编译，方法调用在
  elaboration 解析。私有 FSM 在 C2 仍覆写 `do_configure_mq`/`freeze_for_migration`，入口门控对其先行生效，
  只改变报错 ID/文案，无测试依赖旧文案。）

- [ ] **Step 6: 通用 `setup_queue` 按格式映射 ring**

  `virtio_atomic_ops_queue.svh` `setup_queue` 声明 old：
  ```systemverilog
          int unsigned       desc_size;
          int unsigned       avail_size;
          int unsigned       used_size;
  ```
  new：
  ```systemverilog
          bit [63:0]         region_gpas[$];
          int unsigned       region_sizes[$];
          bit [63:0]         region_iovas[$];
          int unsigned       ring_bytes;
          bit                map_failed;
  ```
  old：从 `        // 5. Allocate ring memory` 到 `        ring_iovas[queue_id] = '{desc_iova, avail_iova, used_iova};`
  （`956001f` 第 81–133 行整段，含 `case (vq_type)` 尺寸计算与三次映射）。new：
  ```systemverilog
          // 5. Allocate ring memory
          vq.alloc_rings();

          // 6-7. 按队列格式声明的 ring 区逐区映射（split 三区、packed 描述符环加两份
          // 4B event 结构、私有环整块 desc+CQ）。全部映射后统一判定，失败撤销已成功的
          // 映射并销毁队列；未分配出 ring（空区表）按映射失败处理。
          vq.get_ring_regions(region_gpas, region_sizes);
          map_failed = (region_gpas.size() == 0);
          foreach (region_gpas[i]) begin
              region_iovas.push_back(iommu.map_for_host(get_iommu_host_id(transport),
                  transport.bdf, region_gpas[i], region_sizes[i], DMA_BIDIRECTIONAL));
              if ((region_iovas[i] == '1) || (region_iovas[i] == 0))
                  map_failed = 1;
          end
          if (map_failed) begin
              foreach (region_iovas[i])
                  if ((region_iovas[i] != '1) && (region_iovas[i] != 0))
                      iommu.unmap_for_host(get_iommu_host_id(transport),
                                           transport.bdf, region_iovas[i]);
              vq_mgr.destroy_queue(queue_id);
              `uvm_error("ATOMIC_OPS", $sformatf(
                  "setup_queue: failed to map queue_id=%0d rings", queue_id))
              return;
          end

          // Track ring IOVAs for cleanup；三个设备视角地址按区内偏移换算。
          ring_iovas[queue_id] = region_iovas;
          desc_iova  = ring_iova_of(vq.desc_table_addr, region_gpas, region_sizes, region_iovas);
          avail_iova = ring_iova_of(vq.driver_ring_addr, region_gpas, region_sizes, region_iovas);
          used_iova  = ring_iova_of(vq.device_ring_addr, region_gpas, region_sizes, region_iovas);
          ring_bytes = 0;
          foreach (region_sizes[i])
              ring_bytes += region_sizes[i];
  ```
  （split/packed 的映射调用次数、顺序、尺寸与 GPA 与旧代码逐一相同，三个 IOVA 均为各区起点。）
  old：
  ```systemverilog
          qprog.device_iova = used_iova;
  ```
  new：
  ```systemverilog
          qprog.device_iova = used_iova;
          qprog.ring_bytes  = ring_bytes;
  ```
  后端拒绝回滚段 old：
  ```systemverilog
              iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf, desc_iova);
              iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf, avail_iova);
              iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf, used_iova);
              ring_iovas.delete(queue_id);
  ```
  new：
  ```systemverilog
              foreach (region_iovas[i])
                  iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                       region_iovas[i]);
              ring_iovas.delete(queue_id);
  ```
  `virtio_atomic_ops.sv` 字段注释 old：`// queue_id -> ring IOVAs (desc, avail, used)` new：`// queue_id -> 每个 ring 区一个 IOVA`。

- [ ] **Step 7: 运行，确认通过**

  单测：`TEST=virtio_unit_test`（含三条新 PASSED 行）、`TEST=virtio_ctrl_vq_test`、`TEST=virtio_migration_dirty_test`、
  `TEST=virtio_dut_caps_test`、`TEST=dpu_priv_driver_flow_test`、`TEST=dpu_priv_ring_contract_test`。三行汇总均为 0。

- [ ] **Step 8: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 9: 提交**

  ```bash
  git add virtio_net_vip/src/agent/virtio_driver_protocol.sv virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv \
      virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_queue.svh \
      virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh virtio_net_vip/src/agent/virtio_auto_fsm.sv \
      virtio_net_vip/tests/virtio_unit_test.sv
  git commit -m "refactor: 驱动协议声明 control VQ/MQ/迁移/队列格式能力，通用 setup_queue 按格式映射 ring"
  ```

---

### Task C3: 通用 ops/FSM 承担私有 Function，删除私有 ops/FSM（规范 R1）

**Files:**
- Modify: `virtio_net_vip/src/transport/virtio_config_backend.sv`（三个钩子）
- Rewrite: `virtio_net_vip/src/dpu_priv/dpu_priv_config_backend.sv`、`virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv`
- Modify: `virtio_net_vip/src/agent/virtio_driver_protocol.sv`（`prepare_candidates` 上移到基类）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`、`atomic_ops/virtio_atomic_ops_lifecycle.svh`、
  `atomic_ops/virtio_atomic_ops_queue.svh`、`atomic_ops/virtio_atomic_ops_datapath.svh`、`virtio_auto_fsm.sv`、
  `virtio_driver.sv`（注释）
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`（注释；后端赋值顺序仅在 Step 3 核对不符时移动）、
  `virtio_net_vip/src/env/virtio_net_env.sv`（注释）、`virtio_net_vip/src/virtio_net_pkg.sv`
- Delete: `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv`、`virtio_net_vip/src/dpu_priv/dpu_priv_auto_fsm.sv`
- Modify: `examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv`、`virtio_net_vip/tests/virtio_unit_test.sv`、
  `virtio_net_vip/tests/virtio_dut_caps_test.sv`
- Test: `dpu_priv_driver_flow_test`、`dpu_priv_ring_contract_test`、`virtio_unit_test`、`virtio_dut_caps_test`、
  `virtio_pf_lifecycle_reset_test`、`virtio_ctrl_vq_test`、`virtio_full_test`

**Interfaces:**
- Consumes: C1 `dpu_priv_virtqueue` 与 vq 钩子；C2 能力、`ops.protocol`、`ring_iova_of`、FSM `queue_format()`；
  B 的 `ops.config_backend`（commit 时设置）与后端 device-config 读接口。
- Produces（`virtio_config_backend` 非纯虚钩子，基类默认即标准行为）：
  `virtual task discover()`（默认 `transport.discover_and_init_bars()`）、
  `virtual function bit prepare_queue(virtqueue_base vq, ref virtio_queue_program_t q)`（默认 1）、
  `virtual task notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap)`（默认 `transport.kick`）。
- Produces（`virtio_atomic_ops`）：`virtual task kick_queue(int unsigned queue_id)`、
  `function bit get_queue_program(int unsigned queue_id, output virtio_queue_program_t q)`、
  `function bit has_active_queues()`、`virtual task discover_device()`。删除 `uses_private_ring()`。
- Produces（`dpu_priv_config_backend`）：`function void bind_private(dpu_priv_driver_config cfg, int unsigned pairs)`；
  保留 `static function dpu_priv_queue_context_t to_context(virtio_queue_program_t q)`；删除 `from_context`。
- Produces：私有 Function 构造路径——`env_cfg.add_dpu_private_config(key, cfg, why)` → Function
  `prepare_driver_candidates` 选 `dpu_priv_driver_protocol` → 协议创建通用 `virtio_atomic_ops`/`virtio_auto_fsm`
  → commit：B 设置 `ops.config_backend = dpu_priv_config_backend` → `protocol.bind_ops` 冻结私有配置进后端、
  `ops.protocol = protocol`。

- [ ] **Step 1: 写失败测试（迁移流程测试、单元测试与 dut_caps 测试）**

  **(a) `examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv`**（断言条件与次数不变，只换观察入口与消息来源）

  old：`    dpu_priv_atomic_ops private_ops[2];` new：`    virtio_atomic_ops private_ops[2];`

  `end_of_elaboration_phase` old：
  ```systemverilog
                  virtio_function_instance f;
                  dpu_priv_atomic_ops check_private;
                  f = env.function_instances[i];
                  if (!(f.preflight_bind_pcie(unused_rc) &&
                        f.commit_bind_pcie(env.host_mem, env.iommu,
                            env.barrier, env.err_inj, env.wait_pol, unused_rc)))
                      `uvm_fatal("DPU_FLOW", "Function binding failed")
                  if (f.function_key.vf_id == 0) begin
                      if (f.private_cfg == null || !$cast(private_ops[h], f.driver_agent.ops))
                          `uvm_fatal("DPU_FLOW", "env private configuration did not reach ops")
                      private_functions[h] = f;
                  end else if ($cast(check_private, f.driver_agent.ops))
                      `uvm_fatal("DPU_FLOW", "private selection changed a standard VF")
  ```
  new：
  ```systemverilog
                  virtio_function_instance f;
                  dpu_priv_config_backend check_private;
                  f = env.function_instances[i];
                  if (!(f.preflight_bind_pcie(unused_rc) &&
                        f.commit_bind_pcie(env.host_mem, env.iommu,
                            env.barrier, env.err_inj, env.wait_pol, unused_rc)))
                      `uvm_fatal("DPU_FLOW", "Function binding failed")
                  // 私有与标准 VF 共用通用 ops/FSM；选择结果体现在配置后端与协议上。
                  if (f.function_key.vf_id == 0) begin
                      private_ops[h] = f.driver_agent.ops;
                      if (f.private_cfg == null || private_ops[h] == null ||
                          !$cast(check_private, private_ops[h].config_backend) ||
                          check_private == null || f.protocol == null ||
                          private_ops[h].protocol != f.protocol ||
                          f.protocol.protocol_name() != "dpu_priv")
                          `uvm_fatal("DPU_FLOW", "env private configuration did not reach ops")
                      private_functions[h] = f;
                  end else if (($cast(check_private, f.driver_agent.ops.config_backend) &&
                                check_private != null) ||
                               f.protocol.protocol_name() != "standard")
                      `uvm_fatal("DPU_FLOW", "private selection changed a standard VF")
  ```
  `check_traffic` 声明 old：`        dpu_priv_queue_context_t tx_ctx, rx_ctx;`
  new：
  ```systemverilog
          dpu_priv_queue_context_t tx_ctx, rx_ctx;
          virtio_queue_program_t tx_prog, rx_prog;
  ```
  old：
  ```systemverilog
          if (!private_ops[h].get_queue_context(1, tx_ctx) ||
              !private_ops[h].get_queue_context(0, rx_ctx) ||
              tx_ctx.host_id != h || tx_ctx.local_qid != h*8+1)
              `uvm_fatal("DPU_FLOW", "private queue context/host routing mismatch")
  ```
  new：
  ```systemverilog
          if (!private_ops[h].get_queue_program(1, tx_prog) ||
              !private_ops[h].get_queue_program(0, rx_prog))
              `uvm_fatal("DPU_FLOW", "private queue context/host routing mismatch")
          tx_ctx = dpu_priv_config_backend::to_context(tx_prog);
          rx_ctx = dpu_priv_config_backend::to_context(rx_prog);
          if (tx_ctx.host_id != h || tx_ctx.local_qid != h*8+1)
              `uvm_fatal("DPU_FLOW", "private queue context/host routing mismatch")
  ```
  `dpu_priv_expected_error::catch` old：`(get_id() == "DPU_PRIV_OPS") &&` new：`(get_id() == "ATOMIC_OPS") &&`。

  `check_lifecycle` 声明 old：`        dpu_priv_queue_context_t ctx;` new：`        virtio_queue_program_t prog;`；
  三处 `private_ops[h].get_queue_context(0, ctx)` → `private_ops[h].get_queue_program(0, prog)`；
  old：`        catcher.expected = "teardown: 未确认 DMA 停止，保留队列资源";`
  new：`        catcher.expected = "teardown_queue: config backend did not confirm queue_id=0 stopped; retaining queue DMA";`
  两处 old：`        catcher.expected = "reset: 未确认 Function 停止 DMA，保留资源";`
  new：`        catcher.expected = "device_reset: transport reset did not complete; retaining PF DMA";`
  （两条文案取自通用 `teardown_queue`/`device_reset_verified`；A/B 若改过文案，用当时树上的原文，仍为整串精确匹配。
  `virtio_pf_lifecycle_reset_test` 也匹配后一条，故 C 不改它。）

  **(b) `virtio_unit_test.sv`：`test_driver_protocol_selection` 整个 task（含上方两行注释）替换为：**
  ```systemverilog
      // 驱动协议决定 status 访问权限、关机复位语义与私有配置冻结；两种协议都创建通用
      // ops/FSM。私有协议只接受私有配置后端，并把协议绑定进 ops。
      task test_driver_protocol_selection();
          virtio_standard_driver_protocol standard;
          dpu_priv_driver_protocol private_protocol;
          dpu_priv_driver_config private_cfg;
          virtio_atomic_ops ops;
          virtio_auto_fsm fsm;
          virtio_driver_config_t behavior;
          string why;

          behavior.num_queue_pairs = 1;
          standard = virtio_standard_driver_protocol::type_id::create(
              "unit_standard_protocol");
          ops = null;
          fsm = null;
          if (!standard.allows_status_access() || standard.requires_verified_reset() ||
              !standard.prepare_candidates("unit_standard", null, behavior, ops, fsm) ||
              (ops == null) || (fsm == null) ||
              !standard.bind_ops(ops, behavior, why) || (ops.protocol != standard))
              `uvm_error("TEST", "standard driver protocol did not select standard ops/FSM")

          private_cfg = dpu_priv_driver_config::type_id::create("unit_private_cfg");
          private_cfg.control = virtio_unit_priv_control_stub::type_id::create(
              "unit_private_control");
          private_protocol = dpu_priv_driver_protocol::type_id::create(
              "unit_private_protocol");
          private_protocol.private_cfg = private_cfg;
          behavior.irq_mode = IRQ_POLLING;
          ops = null;
          fsm = null;
          if (private_protocol.allows_status_access() ||
              !private_protocol.requires_verified_reset() ||
              !private_protocol.prepare_candidates("unit_private", null, behavior, ops, fsm) ||
              (ops == null) || (fsm == null))
              `uvm_error("TEST", "private driver protocol did not create generic ops/FSM")

          // 仍挂标准后端的 ops：私有协议必须拒绝冻结，且不绑定协议。
          ops.config_backend = virtio_common_cfg_backend::type_id::create(
              "unit_conflicting_backend");
          if (private_protocol.bind_ops(ops, behavior, why) ||
              (why != "私有协议要求 dpu_priv_config_backend") || (ops.protocol != null))
              `uvm_error("TEST", {"private protocol accepted a standard config backend: ", why})

          ops.config_backend = dpu_priv_config_backend::type_id::create(
              "unit_private_backend");
          if (!private_protocol.bind_ops(ops, behavior, why) ||
              (ops.protocol != private_protocol))
              `uvm_error("TEST", {"private protocol did not bind its backend: ", why})
          `uvm_info("UNIT_TEST", "test_driver_protocol_selection PASSED", UVM_LOW)
      endtask
  ```

  **(c) `virtio_dut_caps_test.sv`**：类 old：
  ```systemverilog
  // 带一条活动队列上下文的私有 ops：预检通过，但提交时 configure_private 拒绝重配，
  // 用于制造 commit_bind_pcie 的提交半段失败。
  class virtio_dut_caps_busy_priv_ops extends dpu_priv_atomic_ops;
      `uvm_object_utils(virtio_dut_caps_busy_priv_ops)

      function new(string name = "virtio_dut_caps_busy_priv_ops");
          super.new(name);
      endfunction

      function void mark_queue_active();
          dpu_priv_queue_context_t ctx;
          ctx = '{default:0};
          contexts[0] = ctx;
      endfunction
  endclass
  ```
  new：
  ```systemverilog
  // 带一条已编程队列的 ops：预检通过，但提交时私有协议 bind_ops 拒绝重新冻结配置，
  // 用于制造 commit_bind_pcie 的提交半段失败。
  class virtio_dut_caps_busy_ops extends virtio_atomic_ops;
      `uvm_object_utils(virtio_dut_caps_busy_ops)

      function new(string name = "virtio_dut_caps_busy_ops");
          super.new(name);
      endfunction

      function void mark_queue_active();
          queue_programs[0] = virtio_empty_queue_program();
      endfunction
  endclass
  ```
  `assert_function_commit_failure_discards_candidates` 中：`virtio_dut_caps_busy_priv_ops busy_ops;` →
  `virtio_dut_caps_busy_ops busy_ops;`；`dpu_priv_auto_fsm private_fsm;` → `virtio_auto_fsm private_fsm;`；
  `virtio_dut_caps_busy_priv_ops::type_id::create(` → `virtio_dut_caps_busy_ops::type_id::create(`；
  `dpu_priv_auto_fsm::type_id::create(` → `virtio_auto_fsm::type_id::create(`；task 上方注释
  “提交半段失败（私有 ops 仍有活动队列）” → “提交半段失败（ops 仍有活动队列）”。catcher 文案
  `{"无法冻结私有驱动配置: ", "private 配置为空或仍有活动队列"}` 与全部断言不变。

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测 `TEST=dpu_priv_driver_flow_test`：期望编译失败，`Error-` 指出 `get_queue_program` 不是
  `virtio_atomic_ops` 的成员。

- [ ] **Step 3: 前置核对（B 的落点）**

  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -n 'config_backend\s*=\|bind_ops' virtio_net_vip/src/sriov/virtio_function_instance.sv
  grep -rn 'transport\.read_net_config\|transport\.read_device_status' virtio_net_vip/src/agent
  ```
  期望：`ops.config_backend = ...` 出现在 `pending_protocol.bind_ops(ops, ...)` 之前；若在其后，把后端赋值语句
  整体移到 `if (!pending_protocol.bind_ops(ops, driver_cfg, why)) begin` 之前（不改其内容）。第二条 grep 期望
  无输出（B1 已把 net config/status 读改走后端）；记下 B 给后端加的 device-config 读方法名，Step 5 覆写它。

- [ ] **Step 4: 后端基类钩子**

  `virtio_config_backend.sv` old：
  ```systemverilog
      // 屏蔽全部 MSI-X 向量。
      pure virtual task clear_msix(output bit ok);
  endclass
  ```
  new：
  ```systemverilog
      // 屏蔽全部 MSI-X 向量。
      pure virtual task clear_msix(output bit ok);

      // 以下钩子的默认实现即标准 virtio-pci 行为；私有后端覆写。
      // 设备发现：BAR/capability 枚举，委托 transport 的发现策略。
      virtual task discover();
          transport.discover_and_init_bars();
      endtask

      // 建队钩子：ops 已创建队列对象、尚未分配 ring；后端可按自己的队列参数表配置
      // 队列对象并补全编程参数。返回 0 时 ops 销毁队列，设备未被访问。
      virtual function bit prepare_queue(virtqueue_base vq, ref virtio_queue_program_t q);
          return 1;
      endfunction

      // 通知设备队列有新缓冲；标准设备经 notify capability 写 next_idx/wrap。
      virtual task notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap);
          transport.kick(q.queue_id, next_idx, wrap);
      endtask
  endclass
  ```
  （测试中的后端桩不覆写这三个钩子，行为与改动前相同。）

- [ ] **Step 5: 重写 `dpu_priv_config_backend.sv`**

  完整文件（`to_context` 原样保留，`from_context` 与 `reject` 删除）：
  ```systemverilog
  // 目录层次：src/dpu_priv；DPU 私有环的配置后端：通用 ops/FSM 对私有 Function 的全部
  // 设备副作用都经这里。依赖 dpu_priv_device_control（借用，D 阶段由寄存器级实现替换）
  // 与 dpu_priv_virtqueue。保存本 Function 冻结的队列参数表，不持有 Host 内存或映射。
  // 私有设备没有 virtio status/feature/MSI-X/device-config 寄存器：status 是驱动侧影子
  // 值（复位清零），特性恒为 0，device config 全零，队列上限为私有默认环大小，当前固定
  // polling，MSI-X 编程为空操作。
  `ifndef DPU_PRIV_CONFIG_BACKEND_SV
  `define DPU_PRIV_CONFIG_BACKEND_SV

  class dpu_priv_config_backend extends virtio_config_backend;
      `uvm_object_utils(dpu_priv_config_backend)

      // 设备控制实现；bind_private 从私有配置注入。
      dpu_priv_device_control control;
      // 冻结的队列参数表（Function 内 RX 偶/TX 奇队列号 → 本地号、doorbell、TX 控制）。
      protected dpu_priv_queue_config queue_cfg[int unsigned];
      protected int unsigned default_size;
      protected int unsigned rx_size;
      protected bit [7:0]    status_shadow;

      // 构造不访问设备；配置由私有协议 bind_ops 冻结进来。
      function new(string name = "dpu_priv_config_backend");
          super.new(name);
          control = null;
          default_size = 0;
          rx_size = 0;
          status_shadow = 0;
      endfunction

      // 冻结一份已校验的私有配置（调用方先 validate，且 ops 无活动队列）。
      function void bind_private(dpu_priv_driver_config cfg, int unsigned pairs);
          control = cfg.control;
          default_size = cfg.default_queue_size;
          rx_size = cfg.rx_buf_size;
          queue_cfg.delete();
          for (int unsigned qid = 0; qid < pairs*2; qid++)
              queue_cfg[qid] = cfg.resolve_queue(qid);
          status_shadow = 0;
      endfunction

      // （此处原样保留 to_context：从 “// 统一编程参数 → 私有控制上下文” 注释到其 endfunction。）

      // 私有 Function 没有 virtio capability 链；AF 声明与 BAR2 qinfo 在 D 阶段接入。
      virtual task discover();
      endtask

      // Function 级复位由控制后端确认停 DMA；成功后影子 status 清零。
      virtual task reset(output bit ok);
          bit done;

          control.reset_device(transport.iommu_host_id(), transport.bdf, done);
          if (done)
              status_shadow = 0;
          ok = done;
      endtask

      virtual task read_status(output bit [7:0] status);
          status = status_shadow;
      endtask

      virtual task write_status(bit [7:0] status);
          status_shadow = status;
      endtask

      virtual task read_device_features(output bit [63:0] features);
          features = 0;
      endtask

      virtual task write_driver_features(bit [63:0] features);
      endtask

      virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
          accepted = 0;
      endtask

      // 表内队列的上限是私有默认环大小；表外队列返回 0，ops 在建队前拒绝。
      virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
          max_size = queue_cfg.exists(queue_id) ? default_size : 0;
      endtask

      // 把参数表应用到新建的私有队列（方向、本地号、TX 首描述符控制）与编程参数
      // （本地号、RX 容量、doorbell 位置）；非私有格式或表外队列拒绝。
      virtual function bit prepare_queue(virtqueue_base vq, ref virtio_queue_program_t q);
          dpu_priv_virtqueue pvq;
          dpu_priv_queue_config c;

          if (!$cast(pvq, vq) || (pvq == null) || !queue_cfg.exists(q.queue_id)) begin
              `uvm_error("DPU_PRIV_BACKEND", $sformatf(
                  "prepare_queue: queue %0d 不是已配置的私有队列", q.queue_id))
              return 0;
          end
          c = queue_cfg[q.queue_id];
          pvq.tx_mode = q.tx_mode;
          pvq.local_qid = c.local_qid;
          pvq.dport_info = c.dport_info;
          pvq.dport_id = c.dport_id;
          pvq.dport_type = c.dport_type;
          pvq.cpu_tx_cos = c.cpu_tx_cos;
          pvq.rss_lag = c.rss_lag;
          pvq.l3_cs = c.l3_cs;
          pvq.l4_cs = c.l4_cs;
          pvq.fwd = c.fwd;
          q.local_qid = c.local_qid;
          q.rx_buf_size = rx_size;
          q.notify_bar = c.notify_bar;
          q.notify_offset = c.notify_offset;
          return 1;
      endfunction

      // 配置并启动一条私有队列；失败时控制后端保证该队列未启动 DMA。
      virtual task configure_queue(virtio_queue_program_t q, output bit ok);
          bit done;

          control.configure_queue(to_context(q), done);
          ok = done;
      endtask

      // 私有队列在 configure_queue 中已经启动。
      virtual task enable_queue(virtio_queue_program_t q, output bit ok);
          ok = 1;
      endtask

      // 停止队列并等待 DMA 排空；只有 ok=1 才允许调用方释放 ring 与数据缓冲。
      virtual task disable_queue(virtio_queue_program_t q, output bit ok);
          bit done;

          control.disable_queue(to_context(q), done);
          ok = done;
      endtask

      // 私有队列复位 = 停队（teardown 已确认）+ 重建；这里没有寄存器动作。
      virtual task reset_queue(int unsigned queue_id, output bit ok);
          ok = 1;
      endtask

      // 当前固定 polling，没有要编程的向量。
      virtual task set_msix(int unsigned queue_ids[$], output bit ok);
          ok = 1;
      endtask

      virtual task clear_msix(output bit ok);
          ok = 1;
      endtask

      // 私有 doorbell：驱动 writel({wrap, tail, local_qid}, notify_addr)。
      virtual task notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap);
          control.notify_queue(transport, to_context(q),
              dpu_priv_virtqueue::notify_word(wrap, next_idx, q.local_qid));
      endtask

      // （B 新增的 device-config 读方法在此覆写：输出 '{default:0}，不报错、不访问设备。
      //  方法名与签名照抄 B 在 virtio_config_backend 中的声明。）
  endclass
  `endif
  ```

- [ ] **Step 6: 协议——`prepare_candidates` 上移，私有协议改用通用 ops/FSM**

  `virtio_driver_protocol.sv` 基类 old：
  ```systemverilog
      // 预检：校验行为配置，按需创建 ops/FSM 候选；已提供的对象类型不符时返回 0。
      // 不访问设备，不冻结配置。
      pure virtual function bit prepare_candidates(
          string label, uvm_component parent, virtio_driver_config_t behavior,
          ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
  ```
  new：
  ```systemverilog
      // 预检：按需用 factory 创建通用 ops/FSM 候选；协议可先校验自己的配置。
      // 不访问设备，不冻结配置；创建失败留给调用方的空句柄检查报告。
      virtual function bit prepare_candidates(
          string label, uvm_component parent, virtio_driver_config_t behavior,
          ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
          if (candidate_fsm == null)
              candidate_fsm = virtio_auto_fsm::type_id::create(
                  {label, "_fsm"}, parent);
          if (candidate_ops == null)
              candidate_ops = virtio_atomic_ops::type_id::create(
                  {label, "_ops"}, parent);
          return 1;
      endfunction
  ```
  标准协议中整段删除：从 `    // 未提供时用 factory 创建标准 FSM 与 ops；创建失败留给调用方的空句柄检查报告。`
  到该函数 `endfunction`。标准协议 `kick` 保持 A3 之后的实现。

  `dpu_priv_driver_protocol.sv` 完整文件：
  ```systemverilog
  // 目录层次：src/dpu_priv；DPU 私有环驱动协议：只声明私有 Function 与标准 virtio 的差异
  // （能力、队列格式、MANUAL kick/poll、复位语义），ops/FSM 均为通用实现。依赖
  // dpu_priv_driver_config（借用，env_cfg 按 service key 注入）与 Function 提交时选定的
  // dpu_priv_config_backend。复位与关机必须由控制后端确认停 DMA，失败保留资源。
  `ifndef DPU_PRIV_DRIVER_PROTOCOL_SV
  `define DPU_PRIV_DRIVER_PROTOCOL_SV

  class dpu_priv_driver_protocol extends virtio_driver_protocol;
      `uvm_object_utils(dpu_priv_driver_protocol)

      // 本 Function 的私有配置；prepare/bind 前由 Function 注入。
      dpu_priv_driver_config private_cfg;

      // 构造不访问设备。
      function new(string name = "dpu_priv_driver_protocol");
          super.new(name);
          private_cfg = null;
      endfunction

      virtual function string protocol_name();
          return "dpu_priv";
      endfunction

      // 私有设备没有标准 status 寄存器，MANUAL 原始 status 访问被 driver 拒绝。
      virtual function bit allows_status_access();
          return 0;
      endfunction

      virtual function bit requires_verified_reset();
          return 1;
      endfunction

      // （此处原样保留 C2 加入的 has_ctrl_vq / supports_mq / supports_migration / queue_format。）

      // 校验私有配置与 polling 行为，再创建通用 ops/FSM 候选。
      virtual function bit prepare_candidates(
          string label, uvm_component parent, virtio_driver_config_t behavior,
          ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
          string why;

          why = "private_cfg 未注入";
          if ((private_cfg == null) ||
              !private_cfg.validate(behavior.num_queue_pairs, why) ||
              (behavior.irq_mode != IRQ_POLLING)) begin
              `uvm_error("FUNCTION_BIND", {"私有驱动配置非法: ", why})
              return 0;
          end
          return super.prepare_candidates(label, parent, behavior,
                                          candidate_ops, candidate_fsm);
      endfunction

      // 把私有配置冻结进本 Function 的私有配置后端，并把协议绑定进 ops。ops 仍有活动
      // 队列或后端不是私有后端时拒绝，不改动 ops 与后端。
      virtual function bit bind_ops(virtio_atomic_ops ops,
                                    virtio_driver_config_t behavior,
                                    output string why);
          dpu_priv_config_backend backend;

          why = "";
          if ((private_cfg == null) || (ops == null) || ops.has_active_queues()) begin
              why = "private 配置为空或仍有活动队列";
              return 0;
          end
          if (!private_cfg.validate(behavior.num_queue_pairs, why))
              return 0;
          if (!$cast(backend, ops.config_backend) || (backend == null)) begin
              why = "私有协议要求 dpu_priv_config_backend";
              return 0;
          end
          backend.bind_private(private_cfg, behavior.num_queue_pairs);
          ops.negotiated_features = 0;
          ops.protocol = this;
          return 1;
      endfunction

      // 私有 Function 复用标准引擎类与同一 ops；私有 buffer 容量不含 Virtio header，
      // 补充由调用方/FSM 控制。
      virtual function void install_dataplane(virtio_net_dataplane dataplane,
                                              virtio_atomic_ops ops, string label);
          if (dataplane == null)
              return;
          dataplane.rx_engine.buf_size = private_cfg.rx_buf_size;
          dataplane.rx_engine.refill_threshold = 0;
      endfunction

      // MANUAL ATOMIC_KICK：发布屏障后经私有后端写 32-bit doorbell。
      virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
          ops.kick_queue(queue_id);
      endtask

      // 私有完成必须经过 ops 回收数据 DMA，不能裸 poll 丢弃 token。
      virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
          int unsigned budget;

          budget = 1;
          if (req.queue_id % 2)
              ops.tx_complete(req.queue_id, req.completed_pkts, budget);
          else
              ops.rx_receive(req.queue_id, req.received_pkts, budget);
      endtask

      // 先停止后台 worker，再确认设备停止 DMA；结果决定 FSM 进入重初始化或错误态。
      virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm,
                         virtio_transaction req);
          if (fsm.state == FSM_RUNNING) fsm.stop_dataplane();
          ops.device_reset_verified(req.success);
          fsm.state = req.success ? FSM_REINIT_REQUIRED : FSM_ERROR;
      endtask
  endclass
  `endif
  ```

- [ ] **Step 7: 通用 ops**

  `virtio_atomic_ops.sv` old：
  ```systemverilog
      // 是否为 DPU 私有环 ops；私有 FSM 用它确认 ops/FSM 配对，无需类型转换。
      virtual function bit uses_private_ring();
          return 0;
      endfunction
  ```
  new：
  ```systemverilog
      // 只读导出已编程队列的设备视角参数（诊断/测试）；未建队返回 0 且输出空程序。
      function bit get_queue_program(int unsigned queue_id,
                                     output virtio_queue_program_t q);
          q = virtio_empty_queue_program();
          if (!queue_programs.exists(queue_id))
              return 0;
          q = queue_programs[queue_id];
          return 1;
      endfunction

      // 是否仍有已编程队列；驱动协议据此拒绝对活动 ops 重新冻结配置。
      function bit has_active_queues();
          return queue_programs.num() != 0;
      endfunction
  ```
  `kick_with_fault` 整个 task（含上方 4 行注释）替换为：
  ```systemverilog
      // 生产路径的通知边界：PRE_NOTIFY 故障钩子 → 队列格式发布（prepare_notify）→
      // 通知（携带 ring 游标 next_idx/wrap）→ POST_NOTIFY 故障钩子。不调用
      // virtqueue::kick()，那只计数；调用方自己决定是否需要通知。via 为空时经配置
      // 后端通知（标准：notify capability；私有：私有 doorbell），Admin VQ 传入其上下文 transport。
      protected task kick_with_fault(virtqueue_base vq, int unsigned qid,
                                     virtio_pci_transport via = null);
          virtio_config_backend backend;
          virtio_queue_program_t qprog;

          void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
          if (vq.prepare_notify()) begin
              if (via != null)
                  via.kick(qid, vq.get_notify_next_idx(), vq.get_notify_wrap());
              else begin
                  if (queue_programs.exists(qid))
                      qprog = queue_programs[qid];
                  else begin
                      qprog = virtio_empty_queue_program();
                      qprog.queue_id = qid;
                  end
                  backend = cfg_backend();
                  backend.notify_queue(qprog, vq.get_notify_next_idx(), vq.get_notify_wrap());
              end
          end
          void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
      endtask

      // MANUAL ATOMIC_KICK 与私有协议共用的通知入口。
      virtual task kick_queue(int unsigned queue_id);
          virtqueue_base vq;

          if ((vq_mgr == null) || !vq_mgr.has_queue(queue_id)) begin
              `uvm_error("ATOMIC_OPS", $sformatf("kick_queue: queue %0d not found", queue_id))
              return;
          end
          vq = vq_mgr.get_queue(queue_id);
          kick_with_fault(vq, queue_id);
      endtask
  ```
  （若 A3 已加入等价的公开 kick 入口，保留 A3 的名字与实现、删去此处 `kick_queue`，私有协议 `kick` 调 A3 的入口。）

  `virtio_atomic_ops_lifecycle.svh` 在 `    // 便捷入口：执行验证式设备复位但忽略完成标志` 之前插入：
  ```systemverilog
      // 设备发现经配置后端：标准设备枚举 BAR/capability，私有设备由其后端决定。
      virtual task discover_device();
          virtio_config_backend backend;

          backend = cfg_backend();
          backend.discover();
      endtask

  ```

  `virtio_atomic_ops_queue.svh` `setup_queue`：编程参数基本字段提前，分配 ring 前调用后端钩子。old：
  ```systemverilog
          // 5. Allocate ring memory
          vq.alloc_rings();
  ```
  new：
  ```systemverilog
          // 4b. 编程参数基本字段；后端可按其队列参数表配置队列对象并补全参数
          // （私有：方向、本地号、RX 容量、doorbell）。拒绝时设备未被访问。
          qprog = virtio_empty_queue_program();
          qprog.host_id    = get_iommu_host_id(transport);
          qprog.bdf        = transport.bdf;
          qprog.queue_id   = queue_id;
          qprog.queue_size = eff_size;
          qprog.vq_type    = vq_type;
          qprog.local_qid  = queue_id;
          qprog.tx_mode    = queue_id[0];
          if (!backend.prepare_queue(vq, qprog)) begin
              vq_mgr.destroy_queue(queue_id);
              `uvm_error("ATOMIC_OPS", $sformatf(
                  "setup_queue: config backend rejected queue_id=%0d", queue_id))
              return;
          end

          // 5. Allocate ring memory
          vq.alloc_rings();
  ```
  old（第 9 步编程段开头）：
  ```systemverilog
          qprog = virtio_empty_queue_program();
          qprog.host_id     = get_iommu_host_id(transport);
          qprog.bdf         = transport.bdf;
          qprog.queue_id    = queue_id;
          qprog.queue_size  = eff_size;
          qprog.vq_type     = vq_type;
          qprog.desc_iova   = desc_iova;
  ```
  new：
  ```systemverilog
          qprog.desc_iova   = desc_iova;
  ```
  old：
  ```systemverilog
          qprog.msix_vector = msix_vector;
          qprog.local_qid   = queue_id;
          qprog.tx_mode     = queue_id[0];
          backend.configure_queue(qprog, configured);
  ```
  new：
  ```systemverilog
          qprog.msix_vector = msix_vector;
          backend.configure_queue(qprog, configured);
  ```
  （`backend = cfg_backend();` 在第 1–2 步已取得，早于 4b。）

  `virtio_atomic_ops_datapath.svh` `tx_submit` 声明 old（tx_submit 内）：`        virtio_dma_buffer_set dma_set;`
  new：
  ```systemverilog
          virtio_dma_buffer_set dma_set;
          int unsigned     n_out;
  ```
  old：
  ```systemverilog
          // 1. Pack net_hdr to bytes
          virtio_net_hdr_util::pack_hdr(net_hdr, negotiated_features, hdr_bytes);
          hdr_size = hdr_bytes.size();
  ```
  new：
  ```systemverilog
          // 1. Pack net_hdr to bytes.  队列格式不带 virtio-net header（DPU 私有环）时只发
          // 原始帧，header 中的 offload 请求无处承载，显式拒绝。
          hdr_size = vq.net_hdr_bytes(negotiated_features);
          if ((hdr_size == 0) && ((net_hdr.flags != 0) ||
                                  (net_hdr.gso_type != VIRTIO_NET_HDR_GSO_NONE))) begin
              `uvm_error("ATOMIC_OPS", $sformatf(
                  "tx_submit: queue %0d carries no virtio-net header; offload request rejected",
                  queue_id))
              return;
          end
          if (hdr_size != 0) begin
              virtio_net_hdr_util::pack_hdr(net_hdr, negotiated_features, hdr_bytes);
              hdr_size = hdr_bytes.size();
          end
  ```
  old：
  ```systemverilog
          hdr_idx = dma_set.alloc(hdr_dma_size);
          pkt_idx = (hdr_idx < 0) ? -1 : dma_set.alloc(pkt_dma_size);
  ```
  new：
  ```systemverilog
          hdr_idx = (hdr_size == 0) ? -1 : dma_set.alloc(hdr_dma_size);
          pkt_idx = ((hdr_size != 0) && (hdr_idx < 0)) ? -1 : dma_set.alloc(pkt_dma_size);
  ```
  old：
  ```systemverilog
          hdr_data = new[hdr_size];
          foreach (hdr_bytes[i]) hdr_data[i] = hdr_bytes[i];
          dma_set.write(hdr_idx, hdr_data);
  ```
  new：
  ```systemverilog
          if (hdr_size != 0) begin
              hdr_data = new[hdr_size];
              foreach (hdr_bytes[i]) hdr_data[i] = hdr_bytes[i];
              dma_set.write(hdr_idx, hdr_data);
          end
  ```
  old：`        if (!dma_set.map(hdr_idx, DMA_TO_DEVICE)) begin`
  new：`        if ((hdr_size != 0) && !dma_set.map(hdr_idx, DMA_TO_DEVICE)) begin`

  old（第 6 步）：
  ```systemverilog
          // 6. Build scatter-gather lists: [hdr_sg(out)] [data_sg(out)]
          hdr_entry.addr = dma_set.get_iova(hdr_idx);
          hdr_entry.len  = hdr_size;
          sgs[0].entries.push_back(hdr_entry);

          pkt_entry.addr = dma_set.get_iova(pkt_idx);
          pkt_entry.len  = pkt_size;
          sgs[1].entries.push_back(pkt_entry);
  ```
  new：
  ```systemverilog
          // 6. Build scatter-gather lists: [hdr_sg(out)] [data_sg(out)]；无 header 时只有 data。
          n_out = 0;
          if (hdr_size != 0) begin
              hdr_entry.addr = dma_set.get_iova(hdr_idx);
              hdr_entry.len  = hdr_size;
              sgs[n_out].entries.push_back(hdr_entry);
              n_out++;
          end

          pkt_entry.addr = dma_set.get_iova(pkt_idx);
          pkt_entry.len  = pkt_size;
          sgs[n_out].entries.push_back(pkt_entry);
          n_out++;
  ```
  old：`        desc_id = vq.add_buf(sgs, 2, 0, pkt, use_indirect);`
  new：`        desc_id = vq.add_buf(sgs, n_out, 0, pkt, use_indirect);`
  old：
  ```systemverilog
          // Hand both ownership records (hdr first, matching tx_complete's
          // two-per-packet retirement) to completion/reset before notifying.
  ```
  new：
  ```systemverilog
          // Hand the ownership records (hdr first, matching tx_complete's
          // per-packet retirement count) to completion/reset before notifying.
  ```

  `tx_complete` old：
  ```systemverilog
          // Clean up IOMMU mappings for completed TX buffers
          // (Each TX uses 2 IOVAs: hdr + data)
          if (tx_dma_map.exists(queue_id)) begin
              int unsigned iovas_to_free = count * 2;
  ```
  new：
  ```systemverilog
          // Clean up IOMMU mappings for completed TX buffers：每包 header+data 两条，
          // 不带 header 的队列格式只有 data 一条。
          if (tx_dma_map.exists(queue_id)) begin
              int unsigned iovas_to_free =
                  count * ((vq.net_hdr_bytes(negotiated_features) == 0) ? 1 : 2);
  ```

  `rx_refill` old：
  ```systemverilog
          // Determine buffer size based on header size + typical MTU
          hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

          // Use reasonable default: header + 1514 (standard Ethernet MTU)
          if (buf_size == 0)
              buf_size = hdr_size + 1514;
  ```
  new：
  ```systemverilog
          // Determine buffer size based on header size + typical MTU
          hdr_size = vq.net_hdr_bytes(negotiated_features);

          // 默认容量：配置后端给出的队列 RX 容量（私有环），否则 header + 1514。
          if ((buf_size == 0) && queue_programs.exists(queue_id))
              buf_size = queue_programs[queue_id].rx_buf_size;
          if (buf_size == 0)
              buf_size = hdr_size + 1514;
  ```

  `rx_receive_frames` old：
  ```systemverilog
          hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

          while (count < max_budget) begin
  ```
  new：
  ```systemverilog
          hdr_size = vq.net_hdr_bytes(negotiated_features);

          while (count < max_budget) begin
  ```
  old：
  ```systemverilog
                  virtio_net_hdr_util::unpack_hdr(first_bytes,
                                                  negotiated_features, frame.net_hdr);
  ```
  new：
  ```systemverilog
                  if (hdr_size != 0)
                      virtio_net_hdr_util::unpack_hdr(first_bytes,
                                                      negotiated_features, frame.net_hdr);
                  else
                      frame.net_hdr = '{default:0};
  ```

- [ ] **Step 8: 通用 FSM**

  `do_full_init` 声明 old：
  ```systemverilog
          bit        setup_ok;
          int unsigned total_queues;
  ```
  new：
  ```systemverilog
          bit        setup_ok;
          bit        reset_ok;
          int unsigned total_queues;
  ```
  old：`        ops.transport.discover_and_init_bars();` new：`        ops.discover_device();`
  old：
  ```systemverilog
          ops.device_reset();

          ops.set_acknowledge();
  ```
  new：
  ```systemverilog
          // 要求确认停 DMA 的协议（私有环）复位未确认即失败，保留全部资源；标准协议
          // 保持原 device_reset 调用（测试子类会覆写它）。
          if ((ops.protocol != null) && ops.protocol.requires_verified_reset()) begin
              ops.device_reset_verified(reset_ok);
              if (!reset_ok) begin
                  state = FSM_ERROR;
                  `uvm_error("AUTO_FSM", "full_init: device reset not confirmed; retaining DMA")
                  return;
              end
          end else
              ops.device_reset();

          ops.set_acknowledge();
  ```
  old：
  ```systemverilog
          ops.setup_all_queues(active_num_pairs, drv_cfg.vq_type,
                               drv_cfg.queue_size, setup_ok);
  ```
  new：
  ```systemverilog
          ops.setup_all_queues(active_num_pairs, queue_format(),
                               drv_cfg.queue_size, setup_ok);
  ```

  `reset_single_queue` 整个 task（含上方 `// reset_single_queue -- Reset and re-setup a single queue` 注释块）替换为：
  ```systemverilog
      // ------------------------------------------------------------------------
      // reset_single_queue -- Reset and re-setup a single queue
      //
      // 先停后台 worker（它们会轮询被拆除的队列），teardown 未确认停 DMA 时保留队列并
      // 进入 FSM_ERROR；重建成功后 RX 队列补 buffer，原先运行的数据面重新启动。
      // ------------------------------------------------------------------------
      virtual task reset_single_queue(int unsigned queue_id);
          bit setup_ok;
          bit was_running;
          `uvm_info("AUTO_FSM",
              $sformatf("reset_single_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

          was_running = (state == FSM_RUNNING);
          if (was_running)
              stop_dataplane();

          ops.teardown_queue(queue_id);
          if (ops.vq_mgr.has_queue(queue_id)) begin
              state = FSM_ERROR;
              `uvm_error("AUTO_FSM", $sformatf(
                  "reset_single_queue: queue %0d was not stopped; retaining it", queue_id))
              return;
          end

          // 经配置后端复位（标准：Q_RESET；私有：teardown 已完成停队）
          ops.reset_queue(queue_id);

          ops.setup_queue(queue_id, drv_cfg.queue_size, queue_format(), setup_ok);
          if (!setup_ok) begin
              state = FSM_ERROR;
              `uvm_error("AUTO_FSM", $sformatf(
                  "reset_single_queue: failed to setup queue %0d", queue_id))
              return;
          end

          // If this is a receive queue (even-numbered), refill RX buffers
          if (queue_id % 2 == 0 && queue_id < active_num_pairs * 2) begin
              ops.rx_refill(queue_id, drv_cfg.queue_size);
          end

          if (was_running)
              start_dataplane();

          `uvm_info("AUTO_FSM",
              $sformatf("reset_single_queue: queue_id=%0d complete", queue_id), UVM_MEDIUM)
      endtask
  ```

- [ ] **Step 9: 删除私有 ops/FSM 与残留**

  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  git rm virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv virtio_net_vip/src/dpu_priv/dpu_priv_auto_fsm.sv
  ```
  `virtio_net_pkg.sv` 删除两行：
  ```systemverilog
    `include "dpu_priv/dpu_priv_atomic_ops.sv"
    `include "dpu_priv/dpu_priv_auto_fsm.sv"
  ```
  `virtio_net_env.sv` 注释 old：
  ```systemverilog
              // 每个 Function 单独选择驱动；控制后端由顶层注入，建队回调由私有 ops
              // 自动创建。这里仅传配置，不在 connect 阶段执行硬件访问或分配 ring。
  ```
  new：
  ```systemverilog
              // 每个 Function 单独选择驱动协议；私有配置在 Function 提交时冻结进私有
              // 配置后端。这里仅传配置，不在 connect 阶段执行硬件访问或分配 ring。
  ```
  `virtio_driver.sv` `dispatch_error_injection` 上方注释 `私有回调对不支持的错误类型显式报错` →
  `私有队列对不支持的错误类型显式报错`。`virtio_function_instance.sv` 第 5 行注释 `标准/私有 ops/FSM` → `通用 ops/FSM`。

- [ ] **Step 10: 删除证据**

  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -rn 'dpu_priv_atomic_ops\|dpu_priv_auto_fsm\|uses_private_ring\|get_queue_context\|configure_private\|from_context\|DPU_PRIV_OPS\|DPU_PRIV_FSM' \
      virtio_net_vip/src virtio_net_vip/tests examples --include=*.sv --include=*.svh
  ```
  期望无输出。
  ```bash
  grep -rn 'dpu_priv' virtio_net_vip/src/agent
  ```
  期望无输出（通用 ops/FSM/driver/protocol 基类中没有按私有类型或名字的分支；`VQ_DPU_PRIV` 只出现在
  `virtqueue_base::descriptor_format`、`virtqueue_manager`、`virtio_net_types` 与私有文件中）。

- [ ] **Step 11: 运行，确认通过**

  单测依次：`TEST=dpu_priv_driver_flow_test`（日志含 `DPU private src driver flow PASSED: two Hosts, raw TX/RX, DMA lifecycle`）、
  `TEST=dpu_priv_ring_contract_test`、`TEST=virtio_unit_test`、`TEST=virtio_dut_caps_test`、
  `TEST=virtio_pf_lifecycle_reset_test`、`TEST=virtio_ctrl_vq_test`、`TEST=virtio_full_test`。三行汇总均为 0。
  流程测试失败时按测试意图修实现（规范执行规则 5），不改断言。

- [ ] **Step 12: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 13: 提交**

  ```bash
  git add virtio_net_vip/src/transport/virtio_config_backend.sv virtio_net_vip/src/dpu_priv \
      virtio_net_vip/src/agent virtio_net_vip/src/sriov/virtio_function_instance.sv \
      virtio_net_vip/src/env/virtio_net_env.sv virtio_net_vip/src/virtio_net_pkg.sv \
      examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv virtio_net_vip/tests/virtio_unit_test.sv \
      virtio_net_vip/tests/virtio_dut_caps_test.sv
  git commit -m "refactor: 私有 Function 改用通用 ops/FSM，差异收敛到配置后端、私有队列与驱动协议"
  ```

---

### Task C4: 文档与最终核对（规范 R1）

**Files:**
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`、`docs/virtio_verification_flow.md`、
  `examples/dpu_priv_ring/README.md`、`examples/dpu_priv_ring/STANDARD_MODE_AUDIT.md`（仅当提及删除类）
- Test: 全量回归（`scripts/test_manifest.sh` 在每个测试前校验文档）

- [ ] **Step 1: README.md**
  - 第 160 行 `| **Custom Virtqueue** | 用户自定义格式 | 通过回调接口扩展，支持厂商私有描述符格式 |` →
    `| **DPU Private Ring** | 16B 私有描述符 + CQ | 与 split/packed 平级的 dpu_priv_virtqueue，对应 icpu-kernel-driver DPU_RING_T_PRIV |`。
  - 目录树删除 `│   │   ├── custom_virtqueue.sv             ← 自定义扩展`；`dpu_priv/` 下
    `dpu_priv_ring_callback.sv`、`dpu_priv_atomic_ops.sv`、`dpu_priv_auto_fsm.sv` 三行替换为一行
    `│   │   ├── dpu_priv_virtqueue.sv           ← 私有 TX/RX 描述符/CQ 队列格式`；
    `dpu_priv_config_backend.sv` 注释改为 `← 私有配置后端（队列参数表、status/feature 语义、doorbell）`；
    `dpu_priv_driver_protocol.sv` 注释改为 `← 私有协议（能力声明、MANUAL kick/poll、复位语义）`。
  - 第 765–780 行附近 “继承回调基类，实现厂商私有描述符格式” 的 `virtqueue_custom_callback` 示例整段删除，
    换成两句：新队列格式按 `dpu_priv_virtqueue` 的方式直接继承 `virtqueue_base`（实现 ring 方法与
    `get_ring_regions`），设备侧差异放进 `virtio_config_backend` 子类，能力差异放进 `virtio_driver_protocol` 子类。
- [ ] **Step 2: `docs/virtio_net_vip_manual.md`**
  - 第 148 行 `split_virtqueue / packed_virtqueue / custom_virtqueue` → `split_virtqueue / packed_virtqueue / dpu_priv_virtqueue`。
  - 第 337 行 `custom_virtqueue.sv -- Custom Virtqueue (回调委托)` 删除；第 374–379 行目录同 README 处理。
  - 第 430 行 `私有 ops/FSM、配置后端、ring 回调` → `私有队列格式、配置后端与驱动协议（ops/FSM 为通用实现）`。
  - 第 500 行 `VQ_CUSTOM` → `VQ_DPU_PRIV`；第 793 行 “14 个纯虚方法（由 split/packed/custom 实现）” →
    “15 个纯虚方法（由 split/packed/dpu_priv 实现，含 get_ring_regions）”。
  - 第 885–904 行 custom_virtqueue 章节改写为 “DPU 私有环队列” 小节：`VQ_DPU_PRIV` 由 `virtqueue_manager` 创建
    `dpu_priv_virtqueue`；方向/本地号/TX 控制由 `dpu_priv_config_backend.prepare_queue` 写入；desc+CQ 一次映射；
    通知字 `{wrap, tail, local_qid}` 经后端写 doorbell。并附能力表：标准 `has_ctrl_vq/supports_mq/supports_migration`
    = 1/1/1、`queue_format` = 配置值；私有 0/0/0、`VQ_DPU_PRIV`。
- [ ] **Step 3: `docs/virtio_verification_flow.md`**：第 19 行 `atomic_ops(~55)` 按方法数变化更新为 `~60`
  （新增 `kick_queue`、`get_queue_program`、`has_active_queues`、`discover_device`、`ring_iova_of`，删 `uses_private_ring`）；
  若文中有私有 ops/FSM 的流程框，改为 “通用 ops/FSM + 私有后端/队列/协议”。
- [ ] **Step 4: `examples/dpu_priv_ring/README.md`**：文件表三行（ring_callback/atomic_ops/auto_fsm）替换为
  `src/dpu_priv/dpu_priv_virtqueue.sv`（16B 描述符、CQ、wrap、64KiB TX 分片）、`src/dpu_priv/dpu_priv_config_backend.sv`
  （队列参数表、doorbell、status/feature 语义）、`src/dpu_priv/dpu_priv_driver_protocol.sv`（能力与复位语义）；
  第 70 行 `VQ_CUSTOM` → `VQ_DPU_PRIV`；第 83–85 行改为 “Function 选择 `dpu_priv_driver_protocol`，创建通用 ops/FSM，
  提交时冻结私有配置进 `dpu_priv_config_backend`”；第 108 行建队顺序改为 “创建 `VQ_DPU_PRIV` → 后端写方向/本地号 →
  分配连续 desc+CQ → 一次映射 → 控制后端配置启动”；若有 `get_queue_context` 用法，改为
  `get_queue_program` + `dpu_priv_config_backend::to_context`。
  `STANDARD_MODE_AUDIT.md` 第 115 行 `dpu_priv_*` 若指已删除类，改为 `dpu_priv_virtqueue`。
- [ ] **Step 5: 最终 grep 证据**
  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -rn 'custom_virtqueue\|virtqueue_custom_callback\|dpu_priv_ring_callback\|dpu_priv_atomic_ops\|dpu_priv_auto_fsm\|uses_private_ring\|VQ_CUSTOM\|get_queue_context\|configure_private\|custom_cb' \
      README.md docs/virtio_net_vip_manual.md docs/virtio_verification_flow.md examples virtio_net_vip scripts
  ```
  期望无输出（`docs/superpowers/` 下的历史计划/规范不在范围）。
  ```bash
  git diff --shortstat HEAD~4 -- virtio_net_vip/src
  ```
  记录阶段 C 的 src 增删行数（期望净减约 750）。
- [ ] **Step 6: 回归**：REGRESSION；期望 `STRICT_REGRESSION PASS tests=40`（`test_manifest.sh` 文档校验通过）。
- [ ] **Step 7: 提交**
  ```bash
  git add README.md docs/virtio_net_vip_manual.md docs/virtio_verification_flow.md examples/dpu_priv_ring/README.md \
      examples/dpu_priv_ring/STANDARD_MODE_AUDIT.md
  git commit -m "docs: 私有模式收敛后的类与能力说明"
  ```

---

## Notes for integrator (C)

**阶段 C 产出的名字（D 依赖）：**
- 私有队列类：`dpu_priv_virtqueue extends virtqueue_base`（`src/dpu_priv/dpu_priv_virtqueue.sv`）；
  `static notify_word(wrap, tail, qid)` 是 doorbell 编码的唯一定义。`vdev_dpu_priv` 按同一 16B/CQ 布局解析。
- 枚举：`virtqueue_type_e = { VQ_SPLIT, VQ_PACKED, VQ_DPU_PRIV }`。
- `virtqueue_base` 新钩子：`get_ring_regions`（纯虚）、`net_hdr_bytes`、`prepare_notify`。
- 协议能力：`has_ctrl_vq()`、`supports_mq()`、`supports_migration()`、`queue_format(requested)`；保留
  `allows_status_access()`、`requires_verified_reset()`。`prepare_candidates` 改为基类具体实现（私有协议先校验再 `super`）。
- ops：`protocol` 字段（由 `bind_ops` 注入）、`kick_queue`、`get_queue_program`、`has_active_queues`、`discover_device`。
- 后端钩子（`virtio_config_backend`，非纯虚，默认即标准行为）：`discover()`、`prepare_queue(vq, ref q)`、
  `notify_queue(q, next_idx, wrap)`。D 的寄存器级 `dpu_priv_config_backend` 在这三处以及
  `reset/configure_queue/disable_queue/read_status/write_status/set_msix` 中落 AF 0x1010/0x60040、BAR2 qinfo 与
  doorbell MMIO，并替换 `control`（`dpu_priv_device_control`）字段；`bind_private(cfg, pairs)` 是配置冻结入口。
- 私有 Function 的构造方式（测试/示例）：`dpu_priv_driver_config cfg; cfg.control = <control>;
  env_cfg.add_dpu_private_config(service_key, cfg, why);` → Function 提交后 `f.driver_agent.ops` 是通用
  `virtio_atomic_ops`，`ops.config_backend` 是 `dpu_priv_config_backend`，`f.protocol.protocol_name()=="dpu_priv"`；
  队列参数用 `ops.get_queue_program(qid, q)` + `dpu_priv_config_backend::to_context(q)` 观察。直接构造（单元测试）：
  通用 ops + `ops.config_backend = dpu_priv_config_backend::type_id::create(..)` + `private_protocol.bind_ops(ops, behavior, why)`。

**与接口约定的偏差：**
1. 约定只列了协议能力；实际还给 `virtqueue_base` 加了 `net_hdr_bytes()`（header 有无属于环格式，避免 ops 再查协议）、
   `get_ring_regions()`、`prepare_notify()`，给 `virtio_config_backend` 加了 `discover/prepare_queue/notify_queue` 三个
   非纯虚钩子。doorbell 放在后端（它是 MMIO），协议 `kick` 只转调 `ops.kick_queue`。
2. `ops.protocol` 由协议 `bind_ops` 注入，不由 Function 直接赋值；FSM 经 `ops.protocol` 查询能力，不另持协议。
3. `dpu_priv_config_backend::from_context` 删除（无调用方）。
4. `custom_virtqueue`/`dpu_priv_ring_callback` 在 C1 即删除（约定写在 C 末尾），故 C1 对 `dpu_priv_atomic_ops`
   有过渡改动，C3 整体删除。

**依赖 A/B 的假设（实施前核对）：**
- B：`ops.config_backend` 在 `pending_protocol.bind_ops` 之前赋值（C3 Step 3 核对，必要时只移动该语句）；
  `cfg_backend()` 仍存在并每次重新绑定 transport；B 给后端加的 device-config 读方法由私有后端覆写为全零。
- A3：若 A3 已提供公开的 kick 入口，用它代替 `kick_queue`，并考虑把两协议相同的 `kick` 上移到基类。
- A1/B 若改了 `teardown_queue`/`device_reset_verified` 的错误文案，流程测试 catcher 用当时原文。

**行为变化与风险：**
- 私有 `queue_size` 显式值大于 `default_queue_size` 时现在被钳到默认值并报 UVM_WARNING（strict 回归视为失败）；
  原实现允许到 4096。当前私有 Function 用 256/512，不受影响；需要更大环时调大 `default_queue_size`。
- `queue_size=0` 的私有 Function 不再回写解析后的深度（启动预填 0 个 RX buffer，由后台补充），与标准一致。
- 私有 RX 帧无法解析为 packet_item 时由报错改为静默丢弃（与标准 `rx_receive` 一致）。
- 私有 TX 在 ring 满时由静默返回改为 `dpu_priv_virtqueue.add_buf` 报错（`DPU_PRIV_RING`）；现有测试不触发。
- 通用 `reset_single_queue` 现在先停再起数据面、teardown 未确认即 FSM_ERROR（标准 Function 同样生效，属正确性修复；
  当前无测试经 `VIO_TXN_RESET_QUEUE` 调用）。
- 通用 `kick_with_fault` 经 `cfg_backend()` 发通知：未设后端却走 TX/RX kick 的单元测试会因 B 的“后端为空即报错”失败，
  需补 `virtio_common_cfg_backend`（B 迁移时多半已补）。
- FSM 经前向 typedef 调用 `ops.protocol` 的方法（协议在 FSM 之后编译）；VCS 支持。若编译报错，把
  `agent/virtio_driver_protocol.sv` 的 include 提到 `agent/virtio_atomic_ops.sv` 之前，并在其顶部加
  `typedef class virtio_atomic_ops; typedef class virtio_auto_fsm; typedef class virtio_transaction;`。

**集成裁决（控制者）：** `bind_ops` 以 B2 的签名为准：`bind_ops(virtio_atomic_ops ops, virtio_config_backend backend, ...behavior, why)`，
后端由 `virtio_function_instance::select_config_backend` 创建并经 `bind_ops` 下发（`bind_ops` 内赋 `ops.config_backend` 与 `ops.protocol`）。
C 阶段各任务中"直接构造"示例与 C3 Step 3 的核对改为传入 backend 参数；`dpu_priv_atomic_ops::configure_private(cfg, pairs, backend, why)`
的逻辑并入 `dpu_priv_driver_protocol::bind_ops`。

## 阶段 D：设备与驱动分离（规范 R4）

**目标：** 新增独立设备模型 `virtio_net_vip/src/devmodel/`。设备只依据收到的配置/MMIO 请求维护状态，经端口发 DMA
与 MSI-X，不引用任何驱动侧对象（transport、ops、virtqueue、notify_mgr）。它替换 `virtio_pcie_dut_responder`（标准）
与 `dpu_priv_device_control`（私有）；`dpu_priv_config_backend` 改为按真实驱动寄存器序列访问私有设备。

**前置：** A、B、C 已合入。C 之后：`dpu_priv_virtqueue`（16B 描述符、TX CQ 2B、RX CQ 16B、
`static notify_word(wrap, tail, qid)`）、`virtio_config_backend` 的 `discover/prepare_queue/notify_queue` 钩子、
`bind_ops(ops, backend, behavior, why)`（控制者裁决）、`virtio_function_instance::select_config_backend`、
B 的 `read_net_config`。本阶段 old 锚点按 C 完成后的树写；若 A–C 改动了同一段，按语义套用。

**任务划分（相对建议的调整）：** D1 设备底座 + 新单元测试；D2 标准设备；D3 切换 fixture、修复独立设备暴露的
VIP 缺陷、删除 responder；**D4 私有设备（含驱动寄存器序列表）**；**D5 寄存器级私有后端 + 迁移私有测试 + 删除
`dpu_priv_device_control`**；D6 文档与最终核对。私有设备排在私有后端之前，因为寄存器级后端没有设备就无法回归
（`dpu_priv_driver_flow_test` 当前依赖 `dpu_priv_example_control`），这样每个任务都能保持回归全过。

**回归数：** D1 新增 `virtio_vdev_unit_test`，此后 `STRICT_REGRESSION PASS tests=41`。

**设备标识与 BAR（VCS 与 cosim 相同）：**

| 设备 | ID | BAR0 | BAR2 | BAR4 |
|---|---|---|---|---|
| `vdev_virtio_pci` | 1af4:1041 | 16 KiB：common@0x0000(0x40)、ISR@0x1000、device_cfg@0x2000(0x100) | 4 KiB：notify，`queue_notify_off=q`、multiplier 4 | 64 KiB：MSI-X 表@0、PBA@0x8000，`2*max_pairs+2` 向量 |
| `vdev_dpu_priv` | 20f9:5013 | 32 MiB：doorbell@0、AF 声明@0x1010、芯片表（见 D4 表） | 64 KiB：qinfo（mailbox 队列寄存器） | 64 KiB：MSI-X 表@0、PBA@0x8000，64 向量 |

标准设备的 notify 放在 BAR2（Fabric 角色 mailbox），因为 VIP 的 `virtio_fabric_preconfigured_discovery`
强制 notify 位于 mailbox BAR；规范“标准：BAR0 virtio 区域，BAR4 MSI-X”的表述在 E 阶段按此修正（Linux 不关心
notify 在哪个 BAR）。

**调试 marker：** PCIe 扩展配置空间 0x100 的 Vendor-Specific Extended Capability（ID 0x000B，VSEC ID 0x5644
“VD”，长度 0xC），marker 寄存器在 **0x108**（32 位 RW）。写 marker 只产生 `marker` 事件（不产生 `reg_wr`）。
不用标准链上的 vendor cap（0x09）：VIP `virtio_pci_cap_manager::parse_virtio_cap` 对未知 `cfg_type` 报
UVM_WARNING，严格回归会失败；guest 用 `setpci -s <BDF> 0x108.L=<n>`（设备带 PCIe 能力，Linux 开放 4 KiB 配置空间）。

---

### Task D1: 设备底座 `vdev_port` / `vdev_base` / `vdev_uvm_ep_port` 与 `virtio_vdev_unit_test`（规范 R4）

**Files:**
- Create: `virtio_net_vip/src/devmodel/vdev_port.sv`、`virtio_net_vip/src/devmodel/vdev_base.sv`、
  `virtio_net_vip/src/devmodel/vdev_uvm_ep_port.sv`
- Create: `virtio_net_vip/tests/vdev_loopback_port.sv`（测试件：无 PCIe 回环端口、事件记录器、预期报告捕获器）、
  `virtio_net_vip/tests/virtio_vdev_unit_test.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`、`filelists/tests.f`、`scripts/test_manifest.sh`、`README.md`、
  `docs/virtio_net_vip_manual.md`
- Test: `virtio_vdev_unit_test`（新）

**Interfaces:**
- Produces: `vdev_event`（uvm_object，字段见 Notes）与 `function string to_json()`；
  `virtual class vdev_port`：`attach(vdev_base)`、`device_by_bdf(bdf)`、`device_by_addr(addr, output bar, output offset)`、
  `pure virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len, output bit [7:0] data[], output bit ok)`、
  `pure virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[], output bit ok)`、
  `pure virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data)`。
- Produces: `virtual class vdev_base extends uvm_component`：`port`、`bdf`、`event_ap`、`err_inj`；主机侧零时间入口
  `cfg_read/cfg_write/claims/mmio_read/mmio_write`；`inject_rx(pair, frame)`；计数 `notify_count()/dma_read_count()/
  dma_write_count()/completion_count()/interrupt_count()`；子类实现 `init()/region_read()/region_write()/service_queue()`。
- Produces: `vdev_ep_driver extends pcie_tl_ep_driver`（请求先交端口）与 `vdev_uvm_ep_port::connect_ep(ep, ep_monitor, iommu, host_id, output why)`。

- [ ] **Step 1: 写失败测试**

  新建 `virtio_net_vip/tests/vdev_loopback_port.sv`：
  ```systemverilog
  // 目录层次：virtio_net_vip/tests；设备模型测试件（不进 src）。
  // vdev_loopback_port：无 PCIe 链路的设备端口。Host 侧前门把配置/MMIO 直接交给设备；设备 DMA
  // 经严格 IOMMU 翻译读写共享 Host memory（写走 write_from_device_for_host，保留权限与脏页记录）；
  // MSI-X 只记录地址/数据。vdev_event_log：订阅 event_ap，按发生顺序保存事件。
  // 所有权：端口借用 mem/iommu，不分配、不释放；设备由测试创建。
  `ifndef VDEV_LOOPBACK_PORT_SV
  `define VDEV_LOOPBACK_PORT_SV

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import virtio_net_pkg::*;

  class vdev_loopback_port extends vdev_port;
      `uvm_object_utils(vdev_loopback_port)

      host_mem_manager   mem;
      virtio_iommu_model iommu;
      int unsigned       host_id;
      bit [63:0]         msix_addr[$];
      bit [31:0]         msix_data[$];

      function new(string name = "vdev_loopback_port");
          super.new(name);
          host_id = 0;
      endfunction

      // 配置读写按目标 BDF 分派；无设备时读返回全 1（UR）。
      function bit [31:0] host_cfg_read(bit [15:0] target, bit [11:0] addr);
          vdev_base dev;

          dev = device_by_bdf(target);
          return (dev == null) ? 32'hffff_ffff : dev.cfg_read(addr);
      endfunction

      function void host_cfg_write(bit [15:0] target, bit [11:0] addr, bit [31:0] data,
                                   bit [3:0] be = 4'hf);
          vdev_base dev;

          dev = device_by_bdf(target);
          if (dev != null)
              dev.cfg_write(addr, data, be);
      endfunction

      // MMIO 按设备已编程的 BAR 窗口分派；size 为 1/2/4，返回值右对齐。
      function bit [31:0] host_read(bit [63:0] addr, int unsigned size);
          vdev_base dev;
          int unsigned bar;
          bit [31:0] off;

          dev = device_by_addr(addr, bar, off);
          return (dev == null) ? 32'hffff_ffff : dev.mmio_read(bar, off, size);
      endfunction

      function void host_write(bit [63:0] addr, int unsigned size, bit [31:0] data);
          vdev_base dev;
          int unsigned bar;
          bit [31:0] off;

          dev = device_by_addr(addr, bar, off);
          if (dev != null)
              dev.mmio_write(bar, off, size, data);
      endfunction

      virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                            output bit [7:0] data[], output bit ok);
          bit [63:0] gpa;
          iommu_fault_e fault;
          byte raw[];

          data = new[0];
          ok = iommu.translate_for_host(host_id, requester, addr, len, DMA_TO_DEVICE, gpa, fault);
          if (!ok)
              return;
          mem.read_mem(gpa, len, raw);
          data = new[raw.size()];
          foreach (raw[i])
              data[i] = raw[i];
          ok = (data.size() == len);
      endtask

      virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                             output bit ok);
          iommu_fault_e fault;
          byte raw[];

          raw = new[data.size()];
          foreach (data[i])
              raw[i] = data[i];
          ok = iommu.write_from_device_for_host(host_id, mem, requester, addr, raw, fault);
      endtask

      virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
          msix_addr.push_back(addr);
          msix_data.push_back(data);
      endtask
  endclass

  class vdev_event_log extends uvm_subscriber #(vdev_event);
      `uvm_component_utils(vdev_event_log)

      vdev_event events[$];

      function new(string name = "vdev_event_log", uvm_component parent = null);
          super.new(name, parent);
      endfunction

      virtual function void write(vdev_event t);
          events.push_back(t);
      endfunction

      // 按类型筛选（保持顺序）。
      function void select(vdev_event_kind_e kind, ref vdev_event out[$]);
          out.delete();
          foreach (events[i])
              if (events[i].kind == kind)
                  out.push_back(events[i]);
      endfunction

      // 寄存器访问序列 "W|R region field 0xval"（不含配置空间），供私有驱动序列断言。
      function void reg_trace(ref string out[$]);
          out.delete();
          foreach (events[i])
              if ((events[i].kind inside {VDEV_REG_WR, VDEV_REG_RD}) && (events[i].region != "cfg"))
                  out.push_back($sformatf("%s %s %s 0x%0h",
                      (events[i].kind == VDEV_REG_WR) ? "W" : "R",
                      events[i].region, events[i].field, events[i].val));
      endfunction
  endclass

  // 吞掉匹配 ID 且消息含给定子串的 WARNING/ERROR，并计数；其它报告照常抛出。
  class vdev_expect_catcher extends uvm_report_catcher;
      string       id;
      string       text;
      int unsigned caught;

      function new(string name = "vdev_expect_catcher");
          super.new(name);
          caught = 0;
      endfunction

      virtual function action_e catch();
          string msg;

          msg = get_message();
          if ((get_id() == id) && (get_severity() inside {UVM_WARNING, UVM_ERROR})) begin
              for (int i = 0; i + text.len() <= msg.len(); i++)
                  if (msg.substr(i, i + text.len() - 1) == text) begin
                      caught++;
                      return CAUGHT;
                  end
          end
          return THROW;
      endfunction
  endclass
  `endif
  ```

  新建 `virtio_net_vip/tests/virtio_vdev_unit_test.sv`：
  ```systemverilog
  // 目录层次：virtio_net_vip/tests；独立设备模型单元测试（无 PCIe）。测试只经 vdev_loopback_port 的
  // 配置/MMIO 前门驱动设备，设备 DMA 经 IOMMU 读写共享 Host memory。D1 覆盖底座：配置空间、能力链、
  // 调试 marker、MSI-X 表/PBA/屏蔽语义与 worker DMA；D2/D3/D4/D5 追加标准与私有设备用例。
  `ifndef VIRTIO_VDEV_UNIT_TEST_SV
  `define VIRTIO_VDEV_UNIT_TEST_SV

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import virtio_net_pkg::*;

  // 底座测试设备：BAR0+0 为 scratch 寄存器；BAR0+4 写入任意值触发一次服务：
  // 从 echo_iova 读 4 字节、加一写回 echo_iova+4，然后发向量 0。
  class vdev_unit_echo_device extends vdev_base;
      `uvm_component_utils(vdev_unit_echo_device)

      bit [31:0] scratch;
      bit [63:0] echo_iova;

      function new(string name = "vdev_unit_echo_device", uvm_component parent = null);
          super.new(name, parent);
      endfunction

      virtual function void init();
          bit [63:0] sizes[3];

          sizes[0] = 64'h1000;
          sizes[1] = 64'h1000;
          sizes[2] = 64'h1_0000;
          init_header(16'h1234, 16'h5678, 24'h020000, 8'h01, sizes);
          add_msix(4, 32'h0, 32'h8000, 4);
          scratch = 0;
      endfunction

      virtual function bit [31:0] region_read(int unsigned bar, bit [31:0] off, int unsigned size);
          return ((bar == 0) && (off == 0)) ? scratch : 32'h0;
      endfunction

      virtual function void region_write(int unsigned bar, bit [31:0] off, int unsigned size,
                                         bit [31:0] data);
          if ((bar == 0) && (off == 0))
              scratch = data;
          if ((bar == 0) && (off == 4))
              schedule(0);
      endfunction

      virtual task service_queue(int unsigned q);
          bit [7:0] d[];
          bit [31:0] v;
          bit ok;

          dma_rd(echo_iova, 4, d, ok);
          if (!ok)
              return;
          v = {d[3], d[2], d[1], d[0]} + 1;
          foreach (d[i])
              d[i] = v[8*i +: 8];
          dma_wr(echo_iova + 4, d, ok);
          raise_irq(0);
      endtask
  endclass

  class virtio_vdev_unit_test extends uvm_test;
      `uvm_component_utils(virtio_vdev_unit_test)

      localparam bit [15:0] ECHO_BDF  = 16'h0300;
      localparam bit [63:0] ECHO_BAR0 = 64'h0000_0040_0000_0000;
      localparam bit [63:0] ECHO_BAR2 = 64'h0000_0040_0001_0000;
      localparam bit [63:0] ECHO_BAR4 = 64'h0000_0040_0002_0000;

      host_mem_manager      mem;
      virtio_iommu_model    iommu;
      virtio_vq_test_kit    kit;
      vdev_loopback_port    port;
      vdev_unit_echo_device echo;
      vdev_event_log        echo_log;

      function new(string name = "virtio_vdev_unit_test", uvm_component parent = null);
          super.new(name, parent);
      endfunction

      virtual function void build_phase(uvm_phase phase);
          super.build_phase(phase);
          mem = host_mem_manager::type_id::create("vdev_unit_mem");
          mem.set_host_id(0);
          mem.init_region(64'h0000_0001_0000_0000, 64'h0000_0001_00ff_ffff, MODE_BUDDY);
          iommu = virtio_iommu_model::type_id::create("vdev_unit_iommu");
          kit = virtio_vq_test_kit::create_kit("vdev_unit", mem, iommu, ECHO_BDF);
          port = vdev_loopback_port::type_id::create("vdev_unit_port");
          port.mem = mem;
          port.iommu = iommu;
          port.host_id = 0;
          echo = vdev_unit_echo_device::type_id::create("echo", this);
          echo_log = vdev_event_log::type_id::create("echo_log", this);
      endfunction

      virtual function void connect_phase(uvm_phase phase);
          super.connect_phase(phase);
          echo.event_ap.connect(echo_log.analysis_export);
      endfunction

      // 把三对 64 位 BAR 写进设备配置空间（等价平台枚举）。
      protected function void program_bars(bit [15:0] target, bit [63:0] b0, bit [63:0] b2,
                                           bit [63:0] b4);
          bit [63:0] bases[3];

          bases[0] = b0;
          bases[1] = b2;
          bases[2] = b4;
          for (int unsigned i = 0; i < 3; i++) begin
              port.host_cfg_write(target, 12'h010 + 8*i, bases[i][31:0]);
              port.host_cfg_write(target, 12'h014 + 8*i, bases[i][63:32]);
          end
      endfunction

      // 分配并按方向映射一块 Host 内存，返回 IOVA；gpa 输出供测试直接读写字节。
      protected function bit [63:0] map_buffer(bit [15:0] target, int unsigned size, dma_dir_e dir,
                                               output bit [63:0] gpa);
          gpa = mem.alloc(size, 4096);
          if (gpa == '1)
              `uvm_fatal("VDEV_UNIT", "Host memory allocation failed")
          return iommu.map_for_host(0, target, gpa, size, dir);
      endfunction

      // 等设备 worker 处理完。
      protected task settle();
          #1us;
      endtask

      // 配置头、BAR 尺寸探测与能力链：PCIe(0x10) → MSI-X(0x11) → 结束；扩展空间 0x100 为调试 VSEC。
      task test_base_config_space();
          bit [31:0] v;
          bit [7:0] ptr;
          bit [7:0] ids[$];

          if (port.host_cfg_read(ECHO_BDF, 12'h000) != 32'h5678_1234)
              `uvm_fatal("VDEV_UNIT", "vendor/device ID mismatch")
          port.host_cfg_write(ECHO_BDF, 12'h010, 32'hffff_ffff);
          port.host_cfg_write(ECHO_BDF, 12'h014, 32'hffff_ffff);
          if ((port.host_cfg_read(ECHO_BDF, 12'h010) != 32'hffff_f004) ||
              (port.host_cfg_read(ECHO_BDF, 12'h014) != 32'hffff_ffff))
              `uvm_fatal("VDEV_UNIT", "BAR0 sizing readback does not encode a 4 KiB 64-bit BAR")
          program_bars(ECHO_BDF, ECHO_BAR0, ECHO_BAR2, ECHO_BAR4);
          port.host_cfg_write(ECHO_BDF, 12'h004, 32'h0000_0006, 4'h3);
          v = port.host_cfg_read(ECHO_BDF, 12'h004);
          if ((v[15:0] != 16'h0006) || !v[20])
              `uvm_fatal("VDEV_UNIT", $sformatf("command/status readback 0x%08h", v))
          v = port.host_cfg_read(ECHO_BDF, 12'h034);
          ptr = v[7:0];
          while (ptr != 0) begin
              v = port.host_cfg_read(ECHO_BDF, {4'h0, ptr});
              ids.push_back(v[7:0]);
              if ((v[7:0] == 8'h11) &&
                  ((v[26:16] != 3) ||
                   (port.host_cfg_read(ECHO_BDF, {4'h0, ptr} + 4) != 32'h0000_0004) ||
                   (port.host_cfg_read(ECHO_BDF, {4'h0, ptr} + 8) != 32'h0000_8004)))
                  `uvm_fatal("VDEV_UNIT", "MSI-X capability table size/BIR/offset mismatch")
              ptr = v[15:8];
          end
          if ((ids.size() != 2) || (ids[0] != 8'h10) || (ids[1] != 8'h11))
              `uvm_fatal("VDEV_UNIT", "capability chain is not PCIe -> MSI-X")
          if ((port.host_cfg_read(ECHO_BDF, 12'h100) != 32'h0001_000b) ||
              (port.host_cfg_read(ECHO_BDF, 12'h104) != 32'h00c0_5644))
              `uvm_fatal("VDEV_UNIT", "debug VSEC header mismatch")
          if ((port.host_read(ECHO_BAR0, 4) != 0) || (port.host_read(ECHO_BAR0 - 4, 4) != 32'hffff_ffff))
              `uvm_fatal("VDEV_UNIT", "BAR0 window decode is wrong")
          port.host_write(ECHO_BAR0, 4, 32'hcafe_f00d);
          if (port.host_read(ECHO_BAR0, 4) != 32'hcafe_f00d)
              `uvm_fatal("VDEV_UNIT", "scratch register did not retain the MMIO write")
          `uvm_info("VDEV_UNIT", "test_base_config_space PASSED", UVM_LOW)
      endtask

      // marker 写只产生 marker 事件（不记 reg_wr），值可读回；JSON 形如 vdev_diff.py 输入。
      task test_base_marker();
          vdev_event ev[$];

          echo_log.events.delete();
          port.host_cfg_write(ECHO_BDF, 12'h108, 32'd7);
          echo_log.select(VDEV_MARKER, ev);
          if ((ev.size() != 1) || (ev[0].scenario != 7) || (ev[0].fn != ECHO_BDF) ||
              (ev[0].to_json() != "{\"ev\":\"marker\",\"scenario\":7}") ||
              (port.host_cfg_read(ECHO_BDF, 12'h108) != 32'd7))
              `uvm_fatal("VDEV_UNIT", "marker write did not emit exactly one marker event")
          echo_log.select(VDEV_REG_WR, ev);
          if (ev.size() != 0)
              `uvm_fatal("VDEV_UNIT", "marker write must not be recorded as reg_wr")
          `uvm_info("VDEV_UNIT", "test_base_marker PASSED", UVM_LOW)
      endtask

      // MSI-X：未使能不发；使能但向量屏蔽时挂 PBA；解除屏蔽后补发；worker 的 DMA 经 IOMMU。
      task test_base_msix_and_dma();
          bit [63:0] gpa;
          byte data[];
          byte word[];
          bit [31:0] v;
          vdev_event ev[$];

          echo.echo_iova = map_buffer(ECHO_BDF, 4096, DMA_BIDIRECTIONAL, gpa);
          word = new[4];
          word[0] = 8'h44;
          word[1] = 8'h33;
          word[2] = 8'h22;
          word[3] = 8'h11;
          mem.write_mem(gpa, word);
          // 未使能 MSI-X：DMA 发生、中断不发。
          port.host_write(ECHO_BAR0 + 4, 4, 1);
          settle();
          mem.read_mem(gpa + 4, 4, data);
          if ((data[0] != 8'h45) || (data[3] != 8'h11) || (port.msix_addr.size() != 0) ||
              (echo.dma_read_count() != 1) || (echo.dma_write_count() != 1))
              `uvm_fatal("VDEV_UNIT", "worker DMA or MSI-X disable gating failed")
          // 编程向量 0（复位时 vector control=1 屏蔽），再使能 MSI-X（能力在 0x7c：PCIe 能力 60 字节之后）。
          port.host_write(ECHO_BAR4 + 0, 4, 32'hfee0_0000);
          port.host_write(ECHO_BAR4 + 4, 4, 32'h0);
          port.host_write(ECHO_BAR4 + 8, 4, 32'h0300_0000);
          if (port.host_read(ECHO_BAR4 + 12, 4) != 1)
              `uvm_fatal("VDEV_UNIT", "MSI-X vector control reset value must be masked")
          v = port.host_cfg_read(ECHO_BDF, 12'h07c);
          if (v[7:0] != 8'h11)
              `uvm_fatal("VDEV_UNIT", "MSI-X capability is not at 0x7c")
          port.host_cfg_write(ECHO_BDF, 12'h07c, 32'h8000_0000, 4'hc);
          port.host_write(ECHO_BAR0 + 4, 4, 1);
          settle();
          if ((port.msix_addr.size() != 0) || (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 1))
              `uvm_fatal("VDEV_UNIT", "masked vector did not set its PBA bit")
          port.host_write(ECHO_BAR4 + 12, 4, 0);
          settle();
          echo_log.select(VDEV_IRQ, ev);
          if ((port.msix_addr.size() != 1) || (port.msix_addr[0] != 64'hfee0_0000) ||
              (port.msix_data[0] != 32'h0300_0000) || (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 0) ||
              (ev.size() != 1) || (ev[0].vector != 0) || (echo.interrupt_count() != 1))
              `uvm_fatal("VDEV_UNIT", "unmasking a pending vector did not deliver exactly one MSI-X")
          iommu.unmap_for_host(0, ECHO_BDF, echo.echo_iova);
          mem.free(gpa);
          `uvm_info("VDEV_UNIT", "test_base_msix_and_dma PASSED", UVM_LOW)
      endtask

      virtual task run_phase(uvm_phase phase);
          phase.raise_objection(this);
          echo.bdf = ECHO_BDF;
          echo.init();
          port.attach(echo);
          test_base_config_space();
          test_base_marker();
          test_base_msix_and_dma();
          mem.leak_check();
          iommu.leak_check();
          `uvm_info("VDEV_UNIT", "virtio_vdev_unit_test PASSED", UVM_NONE)
          phase.drop_objection(this);
      endtask
  endclass
  `endif
  ```
  （D2–D5 在 `run_phase` 的 `test_base_msix_and_dma();` 与 `mem.leak_check();` 之间追加调用。）

  `filelists/tests.f` old：
  ```
  virtio_net_vip/tests/virtio_vq_test_kit.sv
  ```
  new：
  ```
  virtio_net_vip/tests/virtio_vq_test_kit.sv
  // 设备模型测试件：无 PCIe 回环端口、事件记录器、预期报告捕获器。
  virtio_net_vip/tests/vdev_loopback_port.sv
  ```
  old：
  ```
  virtio_net_vip/tests/virtio_unit_test.sv
  ```
  new：
  ```
  virtio_net_vip/tests/virtio_unit_test.sv
  virtio_net_vip/tests/virtio_vdev_unit_test.sv
  ```

  `scripts/test_manifest.sh` old：
  ```
    virtio_unit_test
    virtio_host_mem_reclaim_test
  ```
  new：
  ```
    virtio_unit_test
    virtio_vdev_unit_test
    virtio_host_mem_reclaim_test
  ```
  文档测试清单（`_validate_documentation_contracts` 按顺序比对）：`README.md` 与 `docs/virtio_net_vip_manual.md`
  两处 old `` `virtio_fabric_resource_test`、`virtio_unit_test`、 `` new
  `` `virtio_fabric_resource_test`、`virtio_unit_test`、`virtio_vdev_unit_test`、 ``；README old
  `` `dpu_priv_ring_contract_test`，共 40 项。 `` new `` `dpu_priv_ring_contract_test`，共 41 项。 ``；
  手册 old `共 40 项。该入口` new `共 41 项。该入口`。

- [ ] **Step 2: 运行，确认失败**

  SYNC 后单测 `TEST=virtio_vdev_unit_test`。期望编译失败：`Error-` 指出 `vdev_port`/`vdev_base` 未声明。

- [ ] **Step 3: 新建 `src/devmodel/vdev_port.sv`**
  ```systemverilog
  // 目录层次：virtio_net_vip/src/devmodel；独立设备模型的端口抽象与语义事件。
  // 设备只依据端口送来的配置/MMIO 请求维护状态，经端口发 DMA 与 MSI-X。端口实现决定传输：
  // vdev_uvm_ep_port（VCS 回归，pcie_tl EP driver）、vdev_cosim_port（E 阶段临时，DPI）、
  // vdev_loopback_port（单元测试）。本文件不引用任何驱动侧对象。
  `ifndef VDEV_PORT_SV
  `define VDEV_PORT_SV

  typedef class vdev_base;

  typedef enum {
      VDEV_REG_WR, VDEV_REG_RD, VDEV_STATUS, VDEV_FEATURES, VDEV_QUEUE_CFG, VDEV_NOTIFY,
      VDEV_DESC_CHAIN, VDEV_PKT, VDEV_COMPLETE, VDEV_IRQ, VDEV_CTRL, VDEV_MARKER
  } vdev_event_kind_e;

  // 一条设备侧语义事件，字段与规范“对比方法”事件表一一对应；只填本类型用到的字段。
  // to_json() 输出 vdev_diff.py 读取的单行 JSON；pkt 带帧字节 hex（"bytes"），sha1 由脚本补算。
  class vdev_event extends uvm_object;
      `uvm_object_utils(vdev_event)

      vdev_event_kind_e kind;
      int unsigned      fn;            // 设备 BDF
      string            region;        // reg_wr/reg_rd
      string            field;
      int               q;             // 队列号；-1 表示与队列无关
      bit [63:0]        val;
      bit [7:0]         from_status;
      bit [7:0]         to_status;
      bit [63:0]        dev_offered;
      bit [63:0]        drv_accepted;
      int unsigned      size;          // queue_cfg
      int unsigned      vector;        // queue_cfg / irq
      bit               enable;
      string            ring_fmt;      // split / packed / priv
      int unsigned      next_idx;      // notify
      bit               wrap;
      int unsigned      seg_len[$];    // desc_chain
      bit [31:0]        seg_flags[$];
      bit               has_hdr;
      virtio_net_hdr_t  hdr;
      string            dir;           // pkt：tx / rx
      bit [7:0]         bytes[$];      // pkt：以太网帧（不含 virtio-net header）
      int unsigned      id;            // complete
      int unsigned      len;           // complete / pkt
      bit [7:0]         ctrl_class;
      bit [7:0]         ctrl_cmd;
      bit [7:0]         ctrl_data[$];
      bit [7:0]         ack;
      int unsigned      scenario;      // marker

      function new(string name = "vdev_event");
          super.new(name);
          q = -1;
          has_hdr = 0;
      endfunction

      function string to_json();
          string s;

          case (kind)
              VDEV_REG_WR, VDEV_REG_RD:
                  s = $sformatf("{\"ev\":\"%s\",\"fn\":%0d,\"region\":\"%s\",\"field\":\"%s\",\"q\":%0d,\"val\":%0d}",
                                (kind == VDEV_REG_WR) ? "reg_wr" : "reg_rd", fn, region, field, q, val);
              VDEV_STATUS:
                  s = $sformatf("{\"ev\":\"status\",\"from\":%0d,\"to\":%0d}", from_status, to_status);
              VDEV_FEATURES:
                  s = $sformatf("{\"ev\":\"features\",\"dev_offered\":%0d,\"drv_accepted\":%0d}",
                                dev_offered, drv_accepted);
              VDEV_QUEUE_CFG:
                  s = $sformatf("{\"ev\":\"queue_cfg\",\"q\":%0d,\"size\":%0d,\"vector\":%0d,\"enable\":%0d,\"ring_fmt\":\"%s\"}",
                                q, size, vector, enable, ring_fmt);
              VDEV_NOTIFY:
                  s = $sformatf("{\"ev\":\"notify\",\"q\":%0d,\"next_idx\":%0d,\"wrap\":%0d}", q, next_idx, wrap);
              VDEV_DESC_CHAIN: begin
                  s = $sformatf("{\"ev\":\"desc_chain\",\"q\":%0d,\"segs\":[", q);
                  foreach (seg_len[i])
                      s = {s, (i == 0) ? "" : ",", $sformatf("[%0d,%0d]", seg_len[i], seg_flags[i])};
                  s = {s, "],\"hdr\":"};
                  if (!has_hdr)
                      s = {s, "null}"};
                  else
                      s = {s, $sformatf("{\"flags\":%0d,\"gso_type\":%0d,\"hdr_len\":%0d,\"gso_size\":%0d,\"csum_start\":%0d,\"csum_offset\":%0d,\"num_buffers\":%0d}}",
                           hdr.flags, hdr.gso_type, hdr.hdr_len, hdr.gso_size, hdr.csum_start,
                           hdr.csum_offset, hdr.num_buffers)};
              end
              VDEV_PKT: begin
                  s = $sformatf("{\"ev\":\"pkt\",\"dir\":\"%s\",\"q\":%0d,\"len\":%0d,\"bytes\":\"",
                                dir, q, bytes.size());
                  foreach (bytes[i])
                      s = {s, $sformatf("%02x", bytes[i])};
                  s = {s, "\"}"};
              end
              VDEV_COMPLETE:
                  s = $sformatf("{\"ev\":\"complete\",\"q\":%0d,\"id\":%0d,\"len\":%0d}", q, id, len);
              VDEV_IRQ:
                  s = $sformatf("{\"ev\":\"irq\",\"vector\":%0d}", vector);
              VDEV_CTRL: begin
                  s = $sformatf("{\"ev\":\"ctrl\",\"class\":%0d,\"cmd\":%0d,\"data\":[", ctrl_class, ctrl_cmd);
                  foreach (ctrl_data[i])
                      s = {s, (i == 0) ? "" : ",", $sformatf("%0d", ctrl_data[i])};
                  s = {s, $sformatf("],\"ack\":%0d}", ack)};
              end
              VDEV_MARKER:
                  s = $sformatf("{\"ev\":\"marker\",\"scenario\":%0d}", scenario);
          endcase
          return s;
      endfunction
  endclass

  // 设备端口：同一链路可挂多个 Function，按 BDF（配置）或 BAR 窗口（MMIO）分派。
  virtual class vdev_port extends uvm_object;
      protected vdev_base m_devices[$];

      function new(string name = "vdev_port");
          super.new(name);
      endfunction

      // 挂接设备；设备经 port 句柄发 DMA/MSI-X。
      function void attach(vdev_base dev);
          m_devices.push_back(dev);
          dev.port = this;
      endfunction

      function vdev_base device_by_bdf(bit [15:0] target);
          foreach (m_devices[i])
              if (m_devices[i].bdf == target)
                  return m_devices[i];
          return null;
      endfunction

      function vdev_base device_by_addr(bit [63:0] addr, output int unsigned bar,
                                        output bit [31:0] offset);
          bar = 0;
          offset = 0;
          foreach (m_devices[i])
              if (m_devices[i].claims(addr, bar, offset))
                  return m_devices[i];
          return null;
      endfunction

      // 设备 → Host：DMA 读/写（地址为设备可见 IOVA）与 MSI-X 消息写。
      pure virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                                 output bit [7:0] data[], output bit ok);
      pure virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                                  output bit ok);
      pure virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
  endclass
  `endif
  ```

- [ ] **Step 4: 新建 `src/devmodel/vdev_base.sv`**
  ```systemverilog
  // 目录层次：virtio_net_vip/src/devmodel；独立设备模型的公共底座。
  // 职责：PCI 配置空间（Type 0 头、64 位 BAR、能力链 PCIe/MSI-X/子类 vendor cap、扩展空间 0x100 的
  // 调试 VSEC 与 marker 寄存器 0x108）、MSI-X 表/PBA 与屏蔽语义、语义事件 event_ap、单 worker 队列服务
  // 调度、TX→RX 回环缓存、设备侧故障点。子类只实现 BAR 寄存器区与队列服务。
  // 依赖 vdev_port、virtqueue_error_injector（可选）与 virtio 类型常量；不引用任何驱动侧对象。
  // 时序：配置/MMIO 处理是零时间函数（端口在请求入口直接调用，不得阻塞）；DMA 与中断只在
  // run_phase 的 worker 中发生。INTx 消息不建模：MSI-X 未使能时设备只置 ISR（子类）。
  `ifndef VDEV_BASE_SV
  `define VDEV_BASE_SV

  virtual class vdev_base extends uvm_component;
      localparam bit [11:0] DEBUG_VSEC_OFF   = 12'h100;
      localparam bit [11:0] DEBUG_MARKER_OFF = 12'h108;
      localparam bit [15:0] DEBUG_VSEC_ID    = 16'h5644;

      vdev_port                       port;
      bit [15:0]                      bdf;
      uvm_analysis_port #(vdev_event) event_ap;
      virtqueue_error_injector        err_inj;

      typedef struct { bit [7:0] data[$]; } frame_t;

      protected bit [7:0]    cfg[4096];
      protected bit [7:0]    cfg_wmask[4096];
      protected bit [63:0]   bar_size[6];
      protected bit [7:0]    last_cap;
      protected bit [7:0]    next_cap;
      protected bit [7:0]    msix_cap;
      protected int unsigned msix_bar;
      protected int unsigned msix_vectors;
      protected bit [31:0]   msix_table_off;
      protected bit [31:0]   msix_pba_off;
      protected bit [31:0]   msix_table[];
      protected bit          msix_pending[];
      protected frame_t      rx_backlog[int unsigned][$];
      protected int unsigned work_q[$];
      protected int unsigned irq_q[$];
      protected event        work_ev;
      protected int unsigned epoch;
      protected int unsigned busy_epoch;
      protected bit          busy;
      protected int unsigned n_notify, n_dma_rd, n_dma_wr, n_complete, n_irq;

      function new(string name, uvm_component parent);
          super.new(name, parent);
          event_ap = new("event_ap", this);
          port = null;
          err_inj = null;
          bdf = '0;
          msix_cap = 0;
          msix_vectors = 0;
          epoch = 0;
          busy = 0;
          n_notify = 0;
          n_dma_rd = 0;
          n_dma_wr = 0;
          n_complete = 0;
          n_irq = 0;
      endfunction

      // 构建配置空间并复位设备状态；BDF 与设备参数须先设置。
      pure virtual function void init();
      // BAR 寄存器区读写（MSI-X 区已由底座处理）；size 为 1/2/4，读返回值右对齐。
      pure virtual function bit [31:0] region_read(int unsigned bar, bit [31:0] off, int unsigned size);
      pure virtual function void region_write(int unsigned bar, bit [31:0] off, int unsigned size,
                                              bit [31:0] data);
      // 服务一个工作项（编码由子类定义）；只在 worker 中调用。
      pure virtual task service_queue(int unsigned q);

      // ---------------- 统计（测试断言用） ----------------
      function int unsigned notify_count();     return n_notify;   endfunction
      function int unsigned dma_read_count();   return n_dma_rd;   endfunction
      function int unsigned dma_write_count();  return n_dma_wr;   endfunction
      function int unsigned completion_count(); return n_complete; endfunction
      function int unsigned interrupt_count();  return n_irq;      endfunction

      // ---------------- 字节/位工具 ----------------
      protected function bit [31:0] get_cfg(bit [11:0] off, int unsigned n);
          bit [31:0] v;

          v = 0;
          for (int unsigned b = 0; b < n; b++)
              v[8*b +: 8] = cfg[off + b];
          return v;
      endfunction

      protected function void put_cfg(bit [11:0] off, int unsigned n, bit [31:0] v);
          for (int unsigned b = 0; b < n; b++)
              cfg[off + b] = v[8*b +: 8];
      endfunction

      // 1/2/4 字节访问的值掩码。
      static function bit [31:0] size_mask(int unsigned size);
          return (size >= 4) ? 32'hffff_ffff : ((32'h1 << (8 * size)) - 1);
      endfunction

      // 把 size 字节的写数据按字节偏移 lane 合并进 32 位寄存器。
      static function bit [31:0] merge32(bit [31:0] old, bit [1:0] lane, int unsigned size,
                                         bit [31:0] data);
          bit [31:0] m;

          m = size_mask(size) << (8 * lane);
          return (old & ~m) | ((data << (8 * lane)) & m);
      endfunction

      // ---------------- 配置空间构建 ----------------
      // Type 0 头：ID、类代码、64 位非预取 MMIO BAR（尺寸 0 表示未实现）、PCIe 能力（v2 端点，
      // 使主机开放 4 KiB 配置空间）与调试 VSEC。可写位：command 的 MEM/BME/INTx-disable、中断线、
      // BAR 地址位、marker 寄存器；MSI-X 控制位由 add_msix 打开。
      protected function void init_header(bit [15:0] vid, bit [15:0] did, bit [23:0] class_code,
                                          bit [7:0] rev, bit [63:0] sizes[3]);
          bit [63:0] mask;
          bit [7:0] body[];

          foreach (cfg[i]) begin
              cfg[i] = 0;
              cfg_wmask[i] = 0;
          end
          put_cfg(12'h000, 2, vid);
          put_cfg(12'h002, 2, did);
          cfg_wmask[12'h004] = 8'h06;
          cfg_wmask[12'h005] = 8'h04;
          cfg[12'h006] = 8'h10;
          cfg[12'h008] = rev;
          put_cfg(12'h009, 3, class_code);
          put_cfg(12'h02c, 2, vid);
          put_cfg(12'h02e, 2, did);
          cfg[12'h03d] = 8'h01;
          cfg_wmask[12'h03c] = 8'hff;
          for (int unsigned i = 0; i < 3; i++) begin
              bar_size[2*i] = sizes[i];
              bar_size[2*i + 1] = 0;
              if (sizes[i] == 0)
                  continue;
              cfg[12'h010 + 8*i] = 8'h04;
              mask = ~(sizes[i] - 1);
              for (int unsigned b = 0; b < 8; b++)
                  cfg_wmask[12'h010 + 8*i + b] = mask[8*b +: 8] & ((b == 0) ? 8'hf0 : 8'hff);
          end
          last_cap = 0;
          next_cap = 8'h40;
          body = new[58];
          foreach (body[i])
              body[i] = 0;
          body[0] = 8'h02;
          void'(add_cap(8'h10, body));
          put_cfg(DEBUG_VSEC_OFF, 4, {12'h000, 4'h1, 16'h000b});
          put_cfg(DEBUG_VSEC_OFF + 4, 4, {12'h00c, 4'h0, DEBUG_VSEC_ID});
          for (int unsigned b = 0; b < 4; b++)
              cfg_wmask[DEBUG_MARKER_OFF + b] = 8'hff;
      endfunction

      // 在标准能力链尾追加一个能力（body 从能力第 2 字节起），返回其偏移；4 字节对齐。
      protected function bit [7:0] add_cap(bit [7:0] id, bit [7:0] body[]);
          bit [7:0] off;

          off = next_cap;
          cfg[off] = id;
          cfg[off + 1] = 8'h00;
          foreach (body[i])
              cfg[off + 2 + i] = body[i];
          if (last_cap == 0)
              cfg[12'h034] = off;
          else
              cfg[last_cap + 1] = off;
          last_cap = off;
          next_cap = (off + 2 + body.size() + 3) & 8'hfc;
          return off;
      endfunction

      // MSI-X 能力与表：vectors 个表项（复位为屏蔽），PBA 只读；Enable/Function Mask 可写。
      protected function void add_msix(int unsigned bar, bit [31:0] table_off, bit [31:0] pba_off,
                                       int unsigned vectors);
          bit [7:0] body[];
          bit [15:0] ctrl;
          bit [31:0] t;
          bit [31:0] p;

          body = new[10];
          ctrl = vectors - 1;
          t = table_off | bar;
          p = pba_off | bar;
          body[0] = ctrl[7:0];
          body[1] = ctrl[15:8];
          for (int unsigned b = 0; b < 4; b++) begin
              body[2 + b] = t[8*b +: 8];
              body[6 + b] = p[8*b +: 8];
          end
          msix_cap = add_cap(8'h11, body);
          cfg_wmask[msix_cap + 3] = 8'hc0;
          msix_bar = bar;
          msix_table_off = table_off;
          msix_pba_off = pba_off;
          msix_vectors = vectors;
          msix_table = new[4 * vectors];
          msix_pending = new[vectors];
          for (int unsigned v = 0; v < vectors; v++) begin
              msix_table[4*v] = 0;
              msix_table[4*v + 1] = 0;
              msix_table[4*v + 2] = 0;
              msix_table[4*v + 3] = 1;
              msix_pending[v] = 0;
          end
      endfunction

      // ---------------- 主机侧入口（零时间） ----------------
      function bit [31:0] cfg_read(bit [11:0] addr);
          bit [11:0] a;
          bit [31:0] v;

          a = {addr[11:2], 2'b00};
          v = get_cfg(a, 4);
          reg_event(0, "cfg", $sformatf("0x%03h", a), -1, v);
          return v;
      endfunction

      // 按字节使能与 cfg_wmask 合并；marker 写只发 marker 事件；MSI-X 控制变化后补发挂起中断。
      function void cfg_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
          bit [11:0] a;
          vdev_event e;

          a = {addr[11:2], 2'b00};
          for (int unsigned b = 0; b < 4; b++)
              if (be[b])
                  cfg[a + b] = (cfg[a + b] & ~cfg_wmask[a + b]) | (data[8*b +: 8] & cfg_wmask[a + b]);
          if (a == DEBUG_MARKER_OFF) begin
              e = new_event(VDEV_MARKER);
              e.scenario = get_cfg(DEBUG_MARKER_OFF, 4);
              emit(e);
              return;
          end
          reg_event(1, "cfg", $sformatf("0x%03h", a), -1, data);
          if ((msix_cap != 0) && (a == {4'h0, msix_cap}))
              flush_pending();
      endfunction

      function bit [63:0] bar_base(int unsigned bar);
          bit [63:0] v;

          for (int unsigned b = 0; b < 8; b++)
              v[8*b +: 8] = cfg[12'h010 + 4*bar + b];
          return {v[63:4], 4'h0};
      endfunction

      function bit claims(bit [63:0] addr, output int unsigned bar, output bit [31:0] offset);
          bit [63:0] base;

          bar = 0;
          offset = 0;
          for (int unsigned b = 0; b < 6; b += 2) begin
              if (bar_size[b] == 0)
                  continue;
              base = bar_base(b);
              if ((base != 0) && (addr >= base) && (addr < base + bar_size[b])) begin
                  bar = b;
                  offset = addr - base;
                  return 1;
              end
          end
          return 0;
      endfunction

      function bit [31:0] mmio_read(int unsigned bar, bit [31:0] off, int unsigned size);
          if ((msix_vectors != 0) && (bar == msix_bar))
              return msix_read(off, size);
          return region_read(bar, off, size) & size_mask(size);
      endfunction

      function void mmio_write(int unsigned bar, bit [31:0] off, int unsigned size, bit [31:0] data);
          if ((msix_vectors != 0) && (bar == msix_bar))
              msix_write(off, size, data);
          else
              region_write(bar, off, size, data & size_mask(size));
      endfunction

      // 设备网络侧入包（测试激励或回环）：按队列对缓存，等该对 RX 队列有 buffer 时写入。
      function void inject_rx(int unsigned pair, bit [7:0] frame[$]);
          frame_t f;

          f.data = frame;
          if (!rx_backlog.exists(pair))
              rx_backlog[pair] = {};
          rx_backlog[pair].push_back(f);
          schedule(2 * pair);
      endfunction

      // ---------------- MSI-X ----------------
      protected function bit msix_enabled();
          bit [31:0] ctrl;

          ctrl = get_cfg({4'h0, msix_cap} + 2, 2);
          return (msix_cap != 0) && ctrl[15];
      endfunction

      protected function bit [31:0] msix_read(bit [31:0] off, int unsigned size);
          bit [31:0] v;
          int unsigned base;

          v = 0;
          if ((off >= msix_table_off) && (off < msix_table_off + 16 * msix_vectors)) begin
              v = msix_table[(off - msix_table_off) / 4] >> (8 * off[1:0]);
              reg_event(0, "msix", $sformatf("vec%0d.dw%0d", (off - msix_table_off) / 16,
                        ((off - msix_table_off) / 4) % 4), -1, v);
          end else if ((off >= msix_pba_off) &&
                       (off < msix_pba_off + 8 * ((msix_vectors + 63) / 64))) begin
              base = ((off - msix_pba_off) & ~32'h3) * 8;
              for (int unsigned i = 0; i < 32; i++)
                  if (base + i < msix_vectors)
                      v[i] = msix_pending[base + i];
              v = v >> (8 * off[1:0]);
              reg_event(0, "msix", "pba", -1, v);
          end
          return v & size_mask(size);
      endfunction

      protected function void msix_write(bit [31:0] off, int unsigned size, bit [31:0] data);
          int unsigned idx;

          if ((off < msix_table_off) || (off >= msix_table_off + 16 * msix_vectors))
              return;
          idx = (off - msix_table_off) / 4;
          msix_table[idx] = merge32(msix_table[idx], off[1:0], size, data);
          reg_event(1, "msix", $sformatf("vec%0d.dw%0d", idx / 4, idx % 4), -1, msix_table[idx]);
          if (((idx % 4) == 3) && !msix_table[idx][0] && msix_pending[idx / 4]) begin
              irq_q.push_back(idx / 4);
              -> work_ev;
          end
      endfunction

      // 使能/功能屏蔽变化后，把已解除屏蔽的挂起向量交给 worker 补发。
      protected function void flush_pending();
          bit [31:0] ctrl;

          ctrl = get_cfg({4'h0, msix_cap} + 2, 2);
          if (!ctrl[15] || ctrl[14])
              return;
          foreach (msix_pending[v])
              if (msix_pending[v] && !msix_table[4*v + 3][0])
                  irq_q.push_back(v);
          -> work_ev;
      endfunction

      // 发一个 MSI-X 向量：未使能不发；功能屏蔽或向量屏蔽时置 PBA；NO_VECTOR/越界忽略。
      protected task raise_irq(int unsigned vector);
          bit [31:0] ctrl;
          vdev_event e;

          if (vector >= msix_vectors)
              return;
          ctrl = get_cfg({4'h0, msix_cap} + 2, 2);
          if (!ctrl[15])
              return;
          if (ctrl[14] || msix_table[4*vector + 3][0]) begin
              msix_pending[vector] = 1;
              return;
          end
          msix_pending[vector] = 0;
          port.raise_msix(bdf, {msix_table[4*vector + 1], msix_table[4*vector]},
                          msix_table[4*vector + 2]);
          n_irq++;
          e = new_event(VDEV_IRQ);
          e.vector = vector;
          emit(e);
      endtask

      // ---------------- worker、DMA、复位 ----------------
      // 单 worker 串行处理：补发中断优先，再服务队列；busy_epoch 用于复位时判断在途工作。
      virtual task run_phase(uvm_phase phase);
          int unsigned q;

          forever begin
              while ((work_q.size() == 0) && (irq_q.size() == 0))
                  @(work_ev);
              if (irq_q.size() != 0) begin
                  raise_irq(irq_q.pop_front());
                  continue;
              end
              q = work_q.pop_front();
              busy = 1;
              busy_epoch = epoch;
              service_queue(q);
              busy = 0;
          end
      endtask

      protected function void schedule(int unsigned q);
          foreach (work_q[i])
              if (work_q[i] == q)
                  return;
          work_q.push_back(q);
          -> work_ev;
      endfunction

      // 复位：丢弃待处理工作与回环帧；在途服务看到 epoch 变化后停止。
      protected function void quiesce();
          epoch++;
          work_q.delete();
          irq_q.delete();
          rx_backlog.delete();
      endfunction

      // 复位后仍有在途服务（DMA 未停）。
      protected function bit draining();
          return busy && (busy_epoch != epoch);
      endfunction

      protected function bit has_backlog(int unsigned pair);
          return rx_backlog.exists(pair) && (rx_backlog[pair].size() != 0);
      endfunction

      protected task dma_rd(bit [63:0] addr, int unsigned len, output bit [7:0] data[], output bit ok);
          port.dma_read(bdf, addr, len, data, ok);
          n_dma_rd++;
      endtask

      protected task dma_wr(bit [63:0] addr, bit [7:0] data[], output bit ok);
          port.dma_write(bdf, addr, data, ok);
          n_dma_wr++;
      endtask

      // 设备侧故障点：只消费本模型能实现的错误类型（PRE_DEVICE_READ：零长、方向翻转；
      // BEFORE_USED：完成长度多报 1）。其它类型留给驱动侧时序点或专用接口。
      protected function bit take_fault(int unsigned q, virtqueue_error_phase_e phase);
          if (err_inj == null)
              return 0;
          if ((phase == VQ_FAULT_PRE_DEVICE_READ) &&
              !(err_inj.err_type inside {VQ_ERR_ZERO_LEN_BUF, VQ_ERR_WRONG_FLAGS}))
              return 0;
          if ((phase == VQ_FAULT_BEFORE_USED) && (err_inj.err_type != VQ_ERR_WRONG_USED_LEN))
              return 0;
          return err_inj.should_inject(q, phase);
      endfunction

      // ---------------- 事件 ----------------
      protected function vdev_event new_event(vdev_event_kind_e kind);
          vdev_event e;

          e = vdev_event::type_id::create("vdev_event");
          e.kind = kind;
          e.fn = bdf;
          return e;
      endfunction

      protected function void emit(vdev_event e);
          event_ap.write(e);
      endfunction

      protected function void reg_event(bit wr, string region, string field, int q, bit [63:0] val);
          vdev_event e;

          e = new_event(wr ? VDEV_REG_WR : VDEV_REG_RD);
          e.region = region;
          e.field = field;
          e.q = q;
          e.val = val;
          emit(e);
      endfunction
  endclass
  `endif
  ```

- [ ] **Step 5: 新建 `src/devmodel/vdev_uvm_ep_port.sv`**（DMA 切块与翻译从 `virtio_pcie_dut_responder::dma_read_iova/
  dma_write_iova` 迁入，去掉队列/epoch 取消；D3 删除 responder）
  ```systemverilog
  // 目录层次：virtio_net_vip/src/devmodel；VCS 回归用的设备端口：接在 pcie_tl EP driver 上。
  // RC→EP 的 CfgRd/CfgWr（按目标 BDF）与 MemRd/MemWr（按设备 BAR 窗口）交给设备并在请求入口直接回
  // Completion；无设备认领的请求走 EP driver 基类。请求入口与 EP 的 Completion 接收共用 TLM 线程，必须
  // 零时间；设备 DMA 只在设备 worker 中发起。设备 DMA：按 IOVA/GPA 两侧 4KiB 边界切块，经平台 IOMMU 翻译
  // 后由 virtio_pcie_model_dma_adapter 发 EP-originated MemRd/MemWr。MSI-X：pcie_tl 的 RC 会把 EP MemWr
  // 写进 Host memory，APIC 窗口没有后备内存，因此端口把 MSI-X MemWr 直接发布到 EP monitor 的 tlp_ap——
  // 与真实链路上被动观察到的 TLP 相同，VIP observer 照常解码。
  // 所有权：借用 EP driver/monitor/IOMMU；只创建每个 requester 的 DMA adapter。
  `ifndef VDEV_UVM_EP_PORT_SV
  `define VDEV_UVM_EP_PORT_SV

  typedef class vdev_uvm_ep_port;

  // pcie_tl EP driver 的设备模型接入点（fixture 以 factory override 替换 pcie_tl_ep_driver）。
  class vdev_ep_driver extends pcie_tl_ep_driver;
      `uvm_component_utils(vdev_ep_driver)

      vdev_uvm_ep_port port;

      function new(string name = "vdev_ep_driver", uvm_component parent = null);
          super.new(name, parent);
          port = null;
      endfunction

      virtual task handle_request(pcie_tl_tlp req);
          bit handled;

          handled = 0;
          if (port != null)
              port.serve(req, handled);
          if (!handled)
              super.handle_request(req);
      endtask
  endclass

  class vdev_uvm_ep_port extends vdev_port;
      `uvm_object_utils(vdev_uvm_ep_port)

      protected vdev_ep_driver                m_ep;
      protected pcie_tl_base_monitor          m_ep_monitor;
      protected virtio_iommu_model            m_iommu;
      protected int unsigned                  m_host_id;
      protected virtio_pcie_model_dma_adapter m_dma[bit [15:0]];

      function new(string name = "vdev_uvm_ep_port");
          super.new(name);
      endfunction

      // 绑定 EP driver（须为 vdev_ep_driver）、EP monitor（MSI-X 发布点）与平台 IOMMU。
      function bit connect_ep(pcie_tl_ep_driver ep, pcie_tl_base_monitor ep_monitor,
                              virtio_iommu_model iommu, int unsigned host_id, output string why);
          why = "";
          if (!$cast(m_ep, ep) || (m_ep == null)) begin
              why = "EP driver is not a vdev_ep_driver";
              return 0;
          end
          if ((ep_monitor == null) || (ep_monitor.tlp_ap == null)) begin
              why = "EP monitor is unavailable";
              return 0;
          end
          if (iommu == null) begin
              why = "IOMMU model is null";
              return 0;
          end
          m_ep_monitor = ep_monitor;
          m_iommu = iommu;
          m_host_id = host_id;
          // 设备寄存器由模型应答；Host memory 属于 RC 侧，不能挂到 EP 上。
          m_ep.mem = null;
          m_ep.use_unified_mem = 0;
          m_ep.port = this;
          return 1;
      endfunction

      // 请求入口：认领则直接回 Completion（MemWr 为 posted，无 Completion）。
      task serve(pcie_tl_tlp req, output bit handled);
          pcie_tl_cfg_tlp cfg_req;
          pcie_tl_mem_tlp mem_req;
          pcie_tl_cpl_tlp cpl;
          vdev_base dev;
          int unsigned bar;
          int unsigned dw_count;
          int unsigned valid;
          int unsigned first;
          int unsigned n;
          bit [31:0] off;
          bit [31:0] data;
          bit [3:0] be;

          handled = 0;
          if (req.kind inside {TLP_CFG_RD0, TLP_CFG_RD1, TLP_CFG_WR0, TLP_CFG_WR1}) begin
              if (!$cast(cfg_req, req))
                  return;
              dev = device_by_bdf(cfg_req.completer_id);
              if (dev == null)
                  return;
              cpl = m_ep.generate_completion(req, CPL_STATUS_SC);
              cpl.completer_id = dev.bdf;
              if (req.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) begin
                  data = dev.cfg_read(cfg_req.get_cfg_addr());
                  cpl.kind = TLP_CPLD;
                  cpl.fmt = FMT_3DW_WITH_DATA;
                  cpl.length = 1;
                  cpl.payload = new[4];
                  foreach (cpl.payload[i])
                      cpl.payload[i] = data[8*i +: 8];
              end else begin
                  data = 0;
                  for (int i = 0; (i < 4) && (i < req.payload.size()); i++)
                      data[8*i +: 8] = req.payload[i];
                  dev.cfg_write(cfg_req.get_cfg_addr(), data, cfg_req.first_be);
              end
              m_ep.send_tlp(cpl);
              handled = 1;
              return;
          end
          if (!(req.kind inside {TLP_MEM_RD, TLP_MEM_WR}) || !$cast(mem_req, req))
              return;
          dev = device_by_addr({mem_req.addr[63:2], 2'b00}, bar, off);
          if (dev == null)
              return;
          dw_count = (mem_req.length == 0) ? 1024 : mem_req.length;
          if (req.kind == TLP_MEM_WR) begin
              for (int unsigned i = 0; i < dw_count; i++) begin
                  be = (i == 0) ? mem_req.first_be : ((i == dw_count - 1) ? mem_req.last_be : 4'hf);
                  if (!lanes(be, first, n))
                      continue;
                  data = 0;
                  for (int unsigned b = 0; b < 4; b++)
                      if (4*i + b < req.payload.size())
                          data[8*b +: 8] = req.payload[4*i + b];
                  dev.mmio_write(bar, off + 4*i + first, n, data >> (8 * first));
              end
              handled = 1;
              return;
          end
          cpl = m_ep.generate_completion(req, CPL_STATUS_SC);
          cpl.kind = TLP_CPLD;
          cpl.fmt = FMT_3DW_WITH_DATA;
          cpl.length = mem_req.length;
          cpl.completer_id = dev.bdf;
          cpl.payload = new[4 * dw_count];
          foreach (cpl.payload[i])
              cpl.payload[i] = 8'h00;
          valid = 0;
          for (int unsigned i = 0; i < dw_count; i++) begin
              be = (i == 0) ? mem_req.first_be : ((i == dw_count - 1) ? mem_req.last_be : 4'hf);
              if (!lanes(be, first, n))
                  continue;
              data = dev.mmio_read(bar, off + 4*i + first, n) << (8 * first);
              for (int unsigned b = 0; b < 4; b++)
                  cpl.payload[4*i + b] = data[8*b +: 8];
              valid += n;
          end
          void'(lanes(mem_req.first_be, first, n));
          cpl.byte_count = valid;
          cpl.lower_addr = {mem_req.addr[6:2], 2'b00} + first;
          m_ep.send_tlp(cpl);
          handled = 1;
      endtask

      // 字节使能 → 首字节与连续字节数；全 0 返回 0。
      protected function bit lanes(bit [3:0] be, output int unsigned first, output int unsigned n);
          int unsigned last;

          first = 0;
          n = 0;
          if (be == 0)
              return 0;
          while (!be[first])
              first++;
          last = 3;
          while (!be[last])
              last--;
          n = last - first + 1;
          return 1;
      endfunction

      virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                            output bit [7:0] data[], output bit ok);
          bit [63:0] gpa;
          bit [7:0] part[];
          bit [7:0] accum[$];
          int unsigned offset;
          int unsigned chunk;

          ok = 0;
          data = new[0];
          offset = 0;
          while (offset < len) begin
              if (!page_chunk(requester, addr + offset, len - offset, DMA_TO_DEVICE, gpa, chunk))
                  return;
              adapter(requester).read(gpa, chunk, part);
              if (part.size() != chunk)
                  return;
              foreach (part[i])
                  accum.push_back(part[i]);
              offset += chunk;
          end
          data = new[accum.size()];
          foreach (accum[i])
              data[i] = accum[i];
          ok = 1;
      endtask

      virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                             output bit ok);
          bit [63:0] gpa;
          bit [7:0] part[];
          int unsigned offset;
          int unsigned chunk;

          ok = 0;
          offset = 0;
          while (offset < data.size()) begin
              if (!page_chunk(requester, addr + offset, data.size() - offset, DMA_FROM_DEVICE,
                              gpa, chunk))
                  return;
              part = new[chunk];
              foreach (part[i])
                  part[i] = data[offset + i];
              adapter(requester).write(gpa, part);
              offset += chunk;
          end
          ok = 1;
      endtask

      virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
          pcie_tl_mem_tlp tlp;

          tlp = pcie_tl_mem_tlp::type_id::create("vdev_msix");
          tlp.kind = TLP_MEM_WR;
          tlp.type_f = TLP_TYPE_MEM_WR;
          tlp.addr = addr;
          tlp.is_64bit = (addr[63:32] != 0);
          tlp.fmt = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
          tlp.length = 1;
          tlp.first_be = 4'hf;
          tlp.last_be = 4'h0;
          tlp.requester_id = requester;
          tlp.payload = new[4];
          foreach (tlp.payload[i])
              tlp.payload[i] = data[8*i +: 8];
          m_ep_monitor.tlp_ap.write(tlp);
      endtask

      // 按 IOVA 与翻译后 GPA 两侧 4KiB 边界切块并翻译；翻译失败报告并返回 0。
      protected function bit page_chunk(bit [15:0] requester, bit [63:0] iova, int unsigned remain,
                                        dma_dir_e dir, output bit [63:0] gpa,
                                        output int unsigned chunk);
          bit [63:0] probe;
          iommu_fault_e fault;
          int unsigned iova_left;
          int unsigned gpa_left;
          bit ok;

          gpa = 0;
          chunk = 0;
          ok = (dir == DMA_TO_DEVICE) ?
               m_iommu.translate_for_host(m_host_id, requester, iova, 1, dir, probe, fault) :
               m_iommu.validate_for_host(m_host_id, requester, iova, 1, dir, probe, fault);
          if (ok) begin
              iova_left = 4096 - iova[11:0];
              gpa_left = 4096 - probe[11:0];
              chunk = remain;
              if (chunk > iova_left)
                  chunk = iova_left;
              if (chunk > gpa_left)
                  chunk = gpa_left;
              ok = (dir == DMA_TO_DEVICE) ?
                   m_iommu.translate_for_host(m_host_id, requester, iova, chunk, dir, gpa, fault) :
                   m_iommu.validate_for_host(m_host_id, requester, iova, chunk, dir, gpa, fault);
          end
          if (!ok)
              `uvm_error("VDEV_DMA", $sformatf(
                  "%s translation failed host=%0d requester=0x%04h IOVA=0x%016h fault=%s",
                  dir.name(), m_host_id, requester, iova, fault.name()))
          return ok;
      endfunction

      protected function virtio_pcie_model_dma_adapter adapter(bit [15:0] requester);
          string why;

          if (!m_dma.exists(requester)) begin
              m_dma[requester] = virtio_pcie_model_dma_adapter::type_id::create(
                  $sformatf("vdev_dma_%04h", requester));
              void'(m_dma[requester].connect_ep(m_ep, requester, why));
          end
          return m_dma[requester];
      endfunction
  endclass
  `endif
  ```
  （`translate_for_host/validate_for_host` 的 `gpa/fault` 是 `ref` 形参，这里传的都是局部变量。）

- [ ] **Step 6: 包含进包**

  `virtio_net_pkg.sv` old：
  ```systemverilog
    `include "pcie/virtio_pcie_iova_host_mem_proxy.sv"
    `include "pcie/virtio_pcie_dut_responder.sv"
  ```
  new：
  ```systemverilog
    `include "pcie/virtio_pcie_iova_host_mem_proxy.sv"
    // 独立设备模型（devmodel/）：只依据 PCIe 请求维护状态，不引用驱动侧对象。
    `include "devmodel/vdev_port.sv"
    `include "devmodel/vdev_base.sv"
    `include "devmodel/vdev_uvm_ep_port.sv"
    `include "pcie/virtio_pcie_dut_responder.sv"
  ```

- [ ] **Step 7: 运行，确认通过**

  单测 `TEST=virtio_vdev_unit_test`：日志含 `test_base_config_space PASSED`、`test_base_marker PASSED`、
  `test_base_msix_and_dma PASSED` 与 `virtio_vdev_unit_test PASSED`，三行汇总为 0。再跑 `TEST=virtio_unit_test`。

- [ ] **Step 8: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=41`。

- [ ] **Step 9: 提交**
  ```bash
  git add virtio_net_vip/src/devmodel virtio_net_vip/src/virtio_net_pkg.sv \
      virtio_net_vip/tests/vdev_loopback_port.sv virtio_net_vip/tests/virtio_vdev_unit_test.sv \
      filelists/tests.f scripts/test_manifest.sh README.md docs/virtio_net_vip_manual.md
  git commit -m "feat: 新增独立设备模型底座（端口、配置空间、MSI-X、语义事件）与设备单元测试"
  ```

---
### Task D2: 标准设备 `vdev_virtio_pci`（规范 R4）

**Files:**
- Create: `virtio_net_vip/src/devmodel/vdev_virtio_pci.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`、`virtio_net_vip/tests/virtio_vdev_unit_test.sv`
- Test: `virtio_vdev_unit_test`

**Interfaces:**
- Consumes: D1 底座；`virtqueue_error_injector::should_inject`；virtio 常量（`VIRTIO_PCI_CAP_*`、`VIRTIO_F_*`、
  `VIRTIO_NET_F_*`、`VIRTQ_DESC_F_*`、`DEV_STATUS_*`、`VIRTIO_NET_CTRL_*`）。不使用 `virtio_net_hdr_util`
  （header 编解码在设备内独立实现，避免与驱动共用同一段代码而互相掩盖错误）。
- Produces: `class vdev_virtio_pci extends vdev_base`；参数字段 `device_features`、`max_pairs`、`queue_max`、`mac`、`mtu`
  （`init()` 前设置）；`num_queues()`。行为契约：
  - common_cfg：DFSELECT/GFSELECT 窗口；`config_msix_vector`/`queue_msix_vector` 超出表大小读回 `0xFFFF`；
    FEATURES_OK 之后驱动特性只读；队列地址/大小只在 `queue_enable=0` 时可写。
  - status：写 0 复位（在途服务未停时读回复位前的值，停后读 0）；首次写 FEATURES_OK 时发 `features` 事件，
    驱动特性不是设备特性子集或缺 VERSION_1 时拒绝（读回无 FEATURES_OK）。每次写发 `status` 事件。
  - `queue_enable=1`：要求 FEATURES_OK、`queue_size` 在 1..queue_max（split 须为 2 的幂）、desc/driver/device 三个
    地址都已写入；任一缺失则拒绝（读回 0）并报 `UVM_WARNING` `VDEV_QUEUE` “queue_driver not written” 等；
    成功发 `queue_cfg` 事件。`queue_enable=0` 按停队处理。`queue_reset`（RING_RESET 已协商）同步复位该队列。
  - notify：BAR2 偏移 `4*q`，数据低 16 位须等于 q；队列未使能、错位或 DRIVER_OK 前报 `UVM_WARNING` `VDEV_QUEUE`。
  - 数据路径：split 与 packed（含 INDIRECT）；TX 读整条链、解 virtio-net header、帧回环到同对 RX，used len=0；
    RX 写 header（`num_buffers=1`）+ 帧，单链容纳不下时丢帧并报 `VDEV_RX` 警告；ctrl VQ（队列号 `2*max_pairs`，
    CTRL_VQ 已协商）应答 MQ/RX/MAC/VLAN/ANNOUNCE；EVENT_IDX、`VIRTQ_AVAIL_F_NO_INTERRUPT`、packed 事件抑制；
    MSI-X 使能时发队列向量，否则置 ISR bit0。
  - 链非法（零长、读写方向错、TX 含可写描述符、RX 首描述符只读）：队列停用、status 置 DEVICE_NEEDS_RESET、
    发配置中断（或 ISR bit1），报 `UVM_WARNING` `VDEV_RING`。
  - 设备侧故障点：取链后 `PRE_DEVICE_READ`（`ZERO_LEN_BUF` 置首描述符 len=0；`WRONG_FLAGS` 翻转首描述符 WRITE），
    写 used 前 `BEFORE_USED`（`WRONG_USED_LEN` 长度加一）。

- [ ] **Step 1: 写失败测试**

  `virtio_vdev_unit_test.sv`：在 `class vdev_unit_echo_device` 之前加入：
  ```systemverilog
  // 最小 token：只用于核对完成返回的对象身份。
  class vdev_unit_token extends uvm_object;
      `uvm_object_utils(vdev_unit_token)
      function new(string name = "vdev_unit_token");
          super.new(name);
      endfunction
  endclass
  ```
  类内 localparam 区 old：
  ```systemverilog
      localparam bit [63:0] ECHO_BAR4 = 64'h0000_0040_0002_0000;
  ```
  new：
  ```systemverilog
      localparam bit [63:0] ECHO_BAR4 = 64'h0000_0040_0002_0000;
      localparam bit [15:0] STD_BDF   = 16'h0400;
      localparam bit [63:0] STD_BAR0  = 64'h0000_0041_0000_0000;
      localparam bit [63:0] STD_BAR2  = 64'h0000_0041_0001_0000;
      localparam bit [63:0] STD_BAR4  = 64'h0000_0041_0002_0000;
  ```
  字段 old：
  ```systemverilog
      vdev_event_log        echo_log;
  ```
  new：
  ```systemverilog
      vdev_event_log        echo_log;
      vdev_virtio_pci       std;
      vdev_event_log        std_log;
      virtio_vq_test_kit    std_kit;
  ```
  `build_phase` old：
  ```systemverilog
          echo_log = vdev_event_log::type_id::create("echo_log", this);
      endfunction
  ```
  new：
  ```systemverilog
          echo_log = vdev_event_log::type_id::create("echo_log", this);
          std_kit = virtio_vq_test_kit::create_kit("vdev_std", mem, iommu, STD_BDF);
          std = vdev_virtio_pci::type_id::create("std", this);
          std_log = vdev_event_log::type_id::create("std_log", this);
      endfunction
  ```
  `connect_phase` old：
  ```systemverilog
          echo.event_ap.connect(echo_log.analysis_export);
  ```
  new：
  ```systemverilog
          echo.event_ap.connect(echo_log.analysis_export);
          std.event_ap.connect(std_log.analysis_export);
  ```
  在 `virtual task run_phase` 之前加入标准设备辅助与用例：
  ```systemverilog
      protected function void std_wr(bit [31:0] off, int unsigned size, bit [31:0] data);
          port.host_write(STD_BAR0 + off, size, data);
      endfunction

      protected function bit [31:0] std_rd(bit [31:0] off, int unsigned size);
          return port.host_read(STD_BAR0 + off, size);
      endfunction

      // 沿能力链找第一个 id（vendor cap 再按 cfg_type 区分）；未找到返回 0。
      protected function bit [7:0] find_cap(bit [15:0] target, bit [7:0] id, bit [7:0] cfg_type = 0);
          bit [31:0] v;
          bit [7:0] ptr;

          v = port.host_cfg_read(target, 12'h034);
          ptr = v[7:0];
          while (ptr != 0) begin
              v = port.host_cfg_read(target, {4'h0, ptr});
              if ((v[7:0] == id) && ((id != 8'h09) || (v[31:24] == cfg_type)))
                  return ptr;
              ptr = v[15:8];
          end
          return 0;
      endfunction

      // 标准初始化到 FEATURES_OK（不写 DRIVER_OK）；返回读回的 status。
      protected function bit [7:0] std_negotiate(bit [63:0] drv);
          std_wr(32'h14, 1, 0);
          std_wr(32'h14, 1, 8'h03);
          std_wr(32'h08, 4, 0);
          std_wr(32'h0c, 4, drv[31:0]);
          std_wr(32'h08, 4, 1);
          std_wr(32'h0c, 4, drv[63:32]);
          std_wr(32'h14, 1, 8'h0b);
          return std_rd(32'h14, 1);
      endfunction

      // MSI-X：向量 v → 地址 0xFEE0_0000+4v、数据 v，全部解除屏蔽，再使能。
      protected function void std_msix_on();
          bit [7:0] cap;

          for (int unsigned v = 0; v < 6; v++) begin
              port.host_write(STD_BAR4 + 16*v, 4, 32'hfee0_0000 + 4*v);
              port.host_write(STD_BAR4 + 16*v + 4, 4, 0);
              port.host_write(STD_BAR4 + 16*v + 8, 4, v);
              port.host_write(STD_BAR4 + 16*v + 12, 4, 0);
          end
          cap = find_cap(STD_BDF, 8'h11);
          port.host_cfg_write(STD_BDF, {4'h0, cap}, 32'h8000_0000, 4'hc);
      endfunction

      // 把队列 q 的 ring 映射进 IOMMU 并编程（缺 skip_driver 时故意不写 driver 地址）；返回 ring IOVA。
      protected function void std_program_queue(int unsigned q, virtqueue_base vq, bit enable,
                                                bit skip_driver, ref bit [63:0] iovas[$]);
          bit [63:0] gpas[$];
          int unsigned sizes[$];

          vq.get_ring_regions(gpas, sizes);
          iovas.delete();
          foreach (gpas[i])
              iovas.push_back(iommu.map_for_host(0, STD_BDF, gpas[i], sizes[i], DMA_BIDIRECTIONAL));
          std_wr(32'h16, 2, q);
          std_wr(32'h18, 2, vq.queue_size);
          std_wr(32'h1a, 2, q + 1);
          std_wr(32'h20, 4, iovas[0][31:0]);
          std_wr(32'h24, 4, iovas[0][63:32]);
          if (!skip_driver) begin
              std_wr(32'h28, 4, iovas[1][31:0]);
              std_wr(32'h2c, 4, iovas[1][63:32]);
          end
          std_wr(32'h30, 4, iovas[2][31:0]);
          std_wr(32'h34, 4, iovas[2][63:32]);
          if (enable)
              std_wr(32'h1c, 2, 1);
      endfunction

      protected function void std_release(virtqueue_base vq, bit [63:0] iovas[$]);
          foreach (iovas[i])
              iommu.unmap_for_host(0, STD_BDF, iovas[i]);
          vq.free_rings();
      endfunction

      // 一个单 SG 的 buffer：分配、写入 data、按方向映射；返回 SG 列表（地址为 IOVA）。
      protected function void std_buffer(byte unsigned data[$], int unsigned size, dma_dir_e dir,
                                         output bit [63:0] gpa, output bit [63:0] iova,
                                         output virtio_sg_list sg);
          byte raw[];

          gpa = mem.alloc(size, 64);
          raw = new[size];
          foreach (raw[i])
              raw[i] = (i < data.size()) ? data[i] : 8'h00;
          mem.write_mem(gpa, raw);
          iova = iommu.map_for_host(0, STD_BDF, gpa, size, dir);
          sg.entries.delete();
          sg.entries.push_back('{addr: iova, len: size, is_indirect: 0});
      endfunction

      protected task wait_used(virtqueue_base vq, output uvm_object tok, output int unsigned len);
          uvm_object t;
          int unsigned l;

          tok = null;
          len = 0;
          for (int i = 0; i < 200; i++) begin
              if (vq.poll_used(t, l)) begin
                  tok = t;
                  len = l;
                  return;
              end
              #10ns;
          end
          `uvm_fatal("VDEV_UNIT", $sformatf("queue %0d produced no used entry", vq.queue_id))
      endtask

      // 配置空间与特性：四个 virtio cap 的 BAR 角色、DFSELECT 窗口、FEATURES_OK 拒绝与 features 事件。
      task test_std_config_and_features();
          bit [31:0] v;
          bit [7:0] cap;
          vdev_event ev[$];

          std.bdf = STD_BDF;
          std.max_pairs = 2;
          std.device_features = 64'h0000_0001_0000_0000;
          std.device_features[VIRTIO_NET_F_MAC] = 1;
          std.device_features[VIRTIO_NET_F_CTRL_VQ] = 1;
          std.device_features[VIRTIO_NET_F_MQ] = 1;
          std.device_features[VIRTIO_F_RING_PACKED] = 1;
          std.init();
          port.attach(std);
          program_bars(STD_BDF, STD_BAR0, STD_BAR2, STD_BAR4);
          if (port.host_cfg_read(STD_BDF, 12'h000) != 32'h1041_1af4)
              `uvm_fatal("VDEV_UNIT", "standard device ID mismatch")
          cap = find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_NOTIFY_CFG);
          v = port.host_cfg_read(STD_BDF, {4'h0, cap} + 4);
          if ((cap == 0) || (v[7:0] != 2) ||
              (port.host_cfg_read(STD_BDF, {4'h0, cap} + 16) != 4) ||
              (find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_COMMON_CFG) == 0) ||
              (find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_ISR_CFG) == 0) ||
              (find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_DEVICE_CFG) == 0))
              `uvm_fatal("VDEV_UNIT", "virtio capabilities or notify BAR/multiplier mismatch")
          if ((std_rd(32'h12, 2) != 5) || (std_rd(32'h2008, 2) != 2))
              `uvm_fatal("VDEV_UNIT", "num_queues/max_virtqueue_pairs mismatch")
          std_wr(32'h00, 4, 0);
          v = std_rd(32'h04, 4);
          std_wr(32'h00, 4, 1);
          if ((v != std.device_features[31:0]) || (std_rd(32'h04, 4) != std.device_features[63:32]))
              `uvm_fatal("VDEV_UNIT", "DFSELECT window did not select the feature word")
          std_log.events.delete();
          v = std_negotiate(64'h0000_0001_0000_0001);     // 设备未提供 CSUM
          std_log.select(VDEV_FEATURES, ev);
          if ((v & DEV_STATUS_FEATURES_OK) || (ev.size() != 1) ||
              (ev[0].drv_accepted != 64'h0000_0001_0000_0001))
              `uvm_fatal("VDEV_UNIT", "device accepted a feature it never offered")
          v = std_negotiate(std.device_features & ~(64'h1 << VIRTIO_F_RING_PACKED));
          if (!(v & DEV_STATUS_FEATURES_OK))
              `uvm_fatal("VDEV_UNIT", "device rejected a valid feature subset")
          std_log.select(VDEV_STATUS, ev);
          if ((ev.size() == 0) || (ev[ev.size() - 1].to_status != 8'h0b))
              `uvm_fatal("VDEV_UNIT", "status transition event missing")
          `uvm_info("VDEV_UNIT", "test_std_config_and_features PASSED", UVM_LOW)
      endtask

      // 规范 Review Focus 2：缺写 queue_driver 时 enable 被拒，补写后 enable 成功并发 queue_cfg。
      task test_std_enable_requires_all_addresses();
          split_virtqueue vq;
          bit [63:0] iovas[$];
          vdev_event ev[$];
          vdev_expect_catcher catcher;

          vq = std_kit.make_split("enable_rx", 0, 8, STD_BDF);
          std_log.events.delete();
          catcher = new("enable_catcher");
          catcher.id = "VDEV_QUEUE";
          catcher.text = "queue_driver not written";
          uvm_report_cb::add(null, catcher);
          std_program_queue(0, vq, 1, 1, iovas);
          uvm_report_cb::delete(null, catcher);
          std_log.select(VDEV_QUEUE_CFG, ev);
          if ((catcher.caught != 1) || (std_rd(32'h1c, 2) != 0) || (ev.size() != 0))
              `uvm_fatal("VDEV_UNIT", "enable without queue_driver was not rejected")
          std_wr(32'h28, 4, iovas[1][31:0]);
          std_wr(32'h2c, 4, iovas[1][63:32]);
          std_wr(32'h1c, 2, 1);
          std_log.select(VDEV_QUEUE_CFG, ev);
          if ((std_rd(32'h1c, 2) != 1) || (ev.size() != 1) || (ev[0].q != 0) || (ev[0].size != 8) ||
              (ev[0].vector != 1) || (ev[0].ring_fmt != "split"))
              `uvm_fatal("VDEV_UNIT", "complete queue programming did not enable the queue")
          std_wr(32'h1c, 2, 0);
          std_release(vq, iovas);
          `uvm_info("VDEV_UNIT", "test_std_enable_requires_all_addresses PASSED", UVM_LOW)
      endtask

      // split：TX 帧（含 12B header）回环到 RX；校验 RX buffer 字节、事件与 MSI-X。
      task test_std_split_tx_loopback_rx();
          split_virtqueue rxq, txq;
          bit [63:0] rx_iovas[$], tx_iovas[$];
          bit [63:0] rx_gpa, rx_iova, tx_gpa, tx_iova;
          virtio_sg_list sgs[];
          byte unsigned tx_bytes[$];
          byte unsigned none[$];
          byte got[];
          uvm_object tok;
          int unsigned len;
          vdev_unit_token rx_tok, tx_tok;
          vdev_event ev[$];

          void'(std_negotiate(64'h0000_0001_0000_0000));
          rxq = std_kit.make_split("split_rx", 0, 8, STD_BDF);
          txq = std_kit.make_split("split_tx", 1, 8, STD_BDF);
          std_program_queue(0, rxq, 1, 0, rx_iovas);
          std_program_queue(1, txq, 1, 0, tx_iovas);
          std_msix_on();
          std_wr(32'h14, 1, 8'h0f);
          tx_bytes = '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                       8'hde, 8'had, 8'hbe, 8'hef, 8'h01, 8'h02, 8'h03, 8'h04};
          sgs = new[1];
          std_buffer(none, 64, DMA_FROM_DEVICE, rx_gpa, rx_iova, sgs[0]);
          rx_tok = new("rx_tok");
          void'(rxq.add_buf(sgs, 0, 1, rx_tok, 0));
          port.host_write(STD_BAR2 + 0, 2, 0);
          std_buffer(tx_bytes, tx_bytes.size(), DMA_TO_DEVICE, tx_gpa, tx_iova, sgs[0]);
          tx_tok = new("tx_tok");
          std_log.events.delete();
          void'(txq.add_buf(sgs, 1, 0, tx_tok, 0));
          port.host_write(STD_BAR2 + 4, 2, 1);
          wait_used(txq, tok, len);
          if ((tok != tx_tok) || (len != 0))
              `uvm_fatal("VDEV_UNIT", "TX used entry token/len mismatch")
          wait_used(rxq, tok, len);
          mem.read_mem(rx_gpa, 20, got);
          if ((tok != rx_tok) || (len != 20) || (got[10] != 8'h01) || (got[12] != 8'hde) ||
              (got[19] != 8'h04))
              `uvm_fatal("VDEV_UNIT", "RX buffer does not hold header(num_buffers=1)+looped frame")
          std_log.select(VDEV_PKT, ev);
          if ((ev.size() != 2) || (ev[0].dir != "tx") || (ev[1].dir != "rx") ||
              (ev[0].bytes != ev[1].bytes) || (ev[0].bytes.size() != 8))
              `uvm_fatal("VDEV_UNIT", "pkt events do not show the same 8-byte frame on TX and RX")
          std_log.select(VDEV_IRQ, ev);
          if ((ev.size() != 2) || (port.msix_data[port.msix_data.size() - 1] != 1))
              `uvm_fatal("VDEV_UNIT", "queue completions did not raise their MSI-X vectors")
          iommu.unmap_for_host(0, STD_BDF, rx_iova);
          iommu.unmap_for_host(0, STD_BDF, tx_iova);
          mem.free(rx_gpa);
          mem.free(tx_gpa);
          std_wr(32'h14, 1, 0);
          std_release(rxq, rx_iovas);
          std_release(txq, tx_iovas);
          `uvm_info("VDEV_UNIT", "test_std_split_tx_loopback_rx PASSED", UVM_LOW)
      endtask

      // packed：TX 完成写回 head 槽的 id/len/flags（AVAIL=USED=wrap），驱动 poll_used 认领。
      task test_std_packed_tx();
          packed_virtqueue txq;
          bit [63:0] iovas[$];
          bit [63:0] gpa, iova;
          virtio_sg_list sgs[];
          byte unsigned bytes[$];
          uvm_object tok;
          int unsigned len;
          vdev_unit_token t;
          vdev_event ev[$];

          void'(std_negotiate(64'h0000_0001_0000_0000 | (64'h1 << VIRTIO_F_RING_PACKED)));
          txq = std_kit.make_packed("packed_tx", 1, 8, STD_BDF);
          std_program_queue(1, txq, 1, 0, iovas);
          std_wr(32'h14, 1, 8'h0f);
          for (int i = 0; i < 16; i++)
              bytes.push_back(i);
          sgs = new[1];
          std_buffer(bytes, 16, DMA_TO_DEVICE, gpa, iova, sgs[0]);
          t = new("packed_tok");
          std_log.events.delete();
          void'(txq.add_buf(sgs, 1, 0, t, 0));
          port.host_write(STD_BAR2 + 4, 2, 1);
          wait_used(txq, tok, len);
          std_log.select(VDEV_QUEUE_CFG, ev);
          if (tok != t)
              `uvm_fatal("VDEV_UNIT", "packed used descriptor returned the wrong token")
          std_log.select(VDEV_PKT, ev);
          if ((ev.size() != 1) || (ev[0].bytes.size() != 4))
              `uvm_fatal("VDEV_UNIT", "packed TX frame (16B minus 12B header) not observed")
          iommu.unmap_for_host(0, STD_BDF, iova);
          mem.free(gpa);
          std_wr(32'h14, 1, 0);
          std_release(txq, iovas);
          `uvm_info("VDEV_UNIT", "test_std_packed_tx PASSED", UVM_LOW)
      endtask

      // ctrl VQ：MQ VQ_PAIRS_SET 2 → ACK_OK；5（超过 max_pairs）→ ACK_ERR；ctrl 事件记录 class/cmd/data/ack。
      task test_std_ctrl_mq();
          split_virtqueue cq;
          bit [63:0] iovas[$];
          bit [63:0] hdr_gpa, hdr_iova, data_gpa, data_iova, ack_gpa, ack_iova;
          virtio_sg_list sgs[];
          byte unsigned hdr_b[$], data_b[$], none[$];
          byte got[];
          uvm_object tok;
          int unsigned len;
          vdev_unit_token t;
          vdev_event ev[$];
          bit [63:0] drv;

          drv = 64'h0000_0001_0000_0000;
          drv[VIRTIO_NET_F_CTRL_VQ] = 1;
          drv[VIRTIO_NET_F_MQ] = 1;
          void'(std_negotiate(drv));
          cq = std_kit.make_split("ctrl_q", 4, 8, STD_BDF);
          std_program_queue(4, cq, 1, 0, iovas);
          std_wr(32'h14, 1, 8'h0f);
          std_log.events.delete();
          for (int round = 0; round < 2; round++) begin
              hdr_b = '{VIRTIO_NET_CTRL_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET};
              data_b = '{(round == 0) ? 8'd2 : 8'd5, 8'd0};
              sgs = new[3];
              std_buffer(hdr_b, 2, DMA_TO_DEVICE, hdr_gpa, hdr_iova, sgs[0]);
              std_buffer(data_b, 2, DMA_TO_DEVICE, data_gpa, data_iova, sgs[1]);
              std_buffer(none, 1, DMA_FROM_DEVICE, ack_gpa, ack_iova, sgs[2]);
              t = new("ctrl_tok");
              void'(cq.add_buf(sgs, 2, 1, t, 0));
              port.host_write(STD_BAR2 + 16, 2, 4);
              wait_used(cq, tok, len);
              mem.read_mem(ack_gpa, 1, got);
              if ((tok != t) || (len != 1) || (got[0] != ((round == 0) ? 0 : 1)))
                  `uvm_fatal("VDEV_UNIT", $sformatf("MQ VQ_PAIRS_SET round %0d ack=%0d", round, got[0]))
              iommu.unmap_for_host(0, STD_BDF, hdr_iova);
              iommu.unmap_for_host(0, STD_BDF, data_iova);
              iommu.unmap_for_host(0, STD_BDF, ack_iova);
              mem.free(hdr_gpa);
              mem.free(data_gpa);
              mem.free(ack_gpa);
          end
          std_log.select(VDEV_CTRL, ev);
          if ((ev.size() != 2) || (ev[0].ctrl_class != VIRTIO_NET_CTRL_MQ) || (ev[0].ack != 0) ||
              (ev[0].ctrl_data.size() != 2) || (ev[0].ctrl_data[0] != 2) || (ev[1].ack != 1))
              `uvm_fatal("VDEV_UNIT", "ctrl events do not record the MQ command sequence")
          std_wr(32'h14, 1, 0);
          std_release(cq, iovas);
          `uvm_info("VDEV_UNIT", "test_std_ctrl_mq PASSED", UVM_LOW)
      endtask

      // 设备侧故障点：PRE_DEVICE_READ 把 TX 首描述符长度置零 → 设备拒绝链、置 DEVICE_NEEDS_RESET
      // 并发配置中断；随后写 status=0 复位，status 与 queue_enable 读回 0。
      task test_std_device_fault_and_reset();
          split_virtqueue txq;
          bit [63:0] iovas[$];
          bit [63:0] gpa, iova;
          virtio_sg_list sgs[];
          byte unsigned bytes[$];
          vdev_unit_token t;
          vdev_expect_catcher catcher;
          int unsigned irq_before;

          void'(std_negotiate(64'h0000_0001_0000_0000));
          txq = std_kit.make_split("fault_tx", 1, 8, STD_BDF);
          std_program_queue(1, txq, 1, 0, iovas);
          std_wr(32'h10, 2, 0);                       // config 向量 0
          std_wr(32'h14, 1, 8'h0f);
          std.err_inj = std_kit.err_inj;
          std_kit.err_inj.configure(VQ_ERR_ZERO_LEN_BUF, 0, 1, 100, VQ_FAULT_PRE_DEVICE_READ);
          for (int i = 0; i < 32; i++)
              bytes.push_back(i);
          sgs = new[1];
          std_buffer(bytes, 32, DMA_TO_DEVICE, gpa, iova, sgs[0]);
          t = new("fault_tok");
          irq_before = port.msix_addr.size();
          catcher = new("fault_catcher");
          catcher.id = "VDEV_RING";
          catcher.text = "zero length";
          uvm_report_cb::add(null, catcher);
          void'(txq.add_buf(sgs, 1, 0, t, 0));
          port.host_write(STD_BAR2 + 4, 2, 1);
          settle();
          uvm_report_cb::delete(null, catcher);
          if ((catcher.caught != 1) || !(std_rd(32'h14, 1) & DEV_STATUS_DEVICE_NEEDS_RESET) ||
              (port.msix_addr.size() != irq_before + 1) || (port.msix_data[irq_before] != 0) ||
              (std_kit.err_inj.injection_count() != 1))
              `uvm_fatal("VDEV_UNIT", "device-side zero-length fault was not reported as DEVICE_NEEDS_RESET")
          std_kit.err_inj.disable_injection();
          std.err_inj = null;
          std_wr(32'h14, 1, 0);
          std_wr(32'h16, 2, 1);
          if ((std_rd(32'h14, 1) != 0) || (std_rd(32'h1c, 2) != 0))
              `uvm_fatal("VDEV_UNIT", "device reset did not clear status/queue_enable")
          iommu.unmap_for_host(0, STD_BDF, iova);
          mem.free(gpa);
          std_release(txq, iovas);
          `uvm_info("VDEV_UNIT", "test_std_device_fault_and_reset PASSED", UVM_LOW)
      endtask
  ```
  `run_phase` old：
  ```systemverilog
          test_base_msix_and_dma();
          mem.leak_check();
  ```
  new：
  ```systemverilog
          test_base_msix_and_dma();
          test_std_config_and_features();
          test_std_enable_requires_all_addresses();
          test_std_split_tx_loopback_rx();
          test_std_packed_tx();
          test_std_ctrl_mq();
          test_std_device_fault_and_reset();
          mem.leak_check();
  ```
  说明：`std_buffer` 的 `'{addr: iova, len: size, is_indirect: 0}` 若 VCS 对结构赋值模式报错，改为先声明
  `virtio_sg_entry e; e.addr = iova; e.len = size; e.is_indirect = 0; sg.entries.push_back(e);`（断言不变）。
  在 RX 用例中先 post RX buffer 再提交 TX，回环帧在 RX 有 buffer 时立即写入；`port.host_write(STD_BAR2 + 0, 2, 0)`
  是 RX 队列的 notify。

- [ ] **Step 2: 运行，确认失败**

  单测 `TEST=virtio_vdev_unit_test`：期望编译失败，`Error-` 指出 `vdev_virtio_pci` 未声明。

- [ ] **Step 3: 新建 `src/devmodel/vdev_virtio_pci.sv`**
  ```systemverilog
  // 目录层次：virtio_net_vip/src/devmodel；标准 virtio-net PCI 设备模型（1af4:1041，virtio 1.2）。
  // 寄存器：BAR0 common_cfg@0x0、ISR@0x1000、device_cfg@0x2000；BAR2 notify（off=q，multiplier 4）；
  // BAR4 MSI-X（底座）。数据路径：split/packed（含 INDIRECT）、TX→同对 RX 回环、ctrl VQ、事件抑制。
  // 只依据收到的寄存器写与 DMA 读到的 ring 字节工作，不引用驱动侧对象；header 编解码自实现。
  // 工作项编码：队列号 q（RX=偶、TX=奇、ctrl=2*max_pairs）。
  `ifndef VDEV_VIRTIO_PCI_SV
  `define VDEV_VIRTIO_PCI_SV

  class vdev_virtio_pci extends vdev_base;
      `uvm_component_utils(vdev_virtio_pci)

      localparam bit [31:0]   ISR_OFF     = 32'h1000;
      localparam bit [31:0]   DEVCFG_OFF  = 32'h2000;
      localparam int unsigned NOTIFY_MULT = 4;
      localparam bit [15:0]   NO_VECTOR   = 16'hffff;

      // 设备参数：init() 前由环境设置。
      bit [63:0]   device_features;
      int unsigned max_pairs;
      int unsigned queue_max;
      bit [47:0]   mac;
      bit [15:0]   mtu;

      typedef struct {
          bit [15:0] size;
          bit [15:0] msix;
          bit        enable;
          bit [63:0] desc;
          bit [63:0] driver;
          bit [63:0] device;
          bit [15:0] last_avail;    // split：自由计数的消费位置；packed：下一个槽号
          bit [15:0] used_idx;      // split：自由计数的 used 位置
          bit        wrap;          // packed：设备当前槽的 wrap
          bit        broken;
      } vq_t;

      typedef struct {
          bit [63:0] addr;
          bit [31:0] len;
          bit [15:0] flags;
          bit [15:0] next;
          bit [15:0] id;
      } desc_t;

      protected vq_t       vqs[];
      protected bit [7:0]  status;
      protected bit [7:0]  status_before_reset;
      protected bit [31:0] dfselect;
      protected bit [31:0] gfselect;
      protected bit [63:0] driver_features;
      protected bit [15:0] config_msix;
      protected bit [15:0] qsel;
      protected bit [7:0]  isr;
      protected bit [7:0]  generation;
      protected int unsigned curr_pairs;

      function new(string name = "vdev_virtio_pci", uvm_component parent = null);
          super.new(name, parent);
          device_features = 0;
          device_features[VIRTIO_F_VERSION_1] = 1;
          max_pairs = 1;
          queue_max = 256;
          mac = 48'h02_00_00_00_00_01;
          mtu = 16'd1500;
          status = 0;
          status_before_reset = 0;
          generation = 0;
      endfunction

      function int unsigned num_queues();
          return 2 * max_pairs + (device_features[VIRTIO_NET_F_CTRL_VQ] ? 1 : 0);
      endfunction

      virtual function void init();
          bit [63:0] sizes[3];

          sizes[0] = 64'h4000;
          sizes[1] = 64'h1000;
          sizes[2] = 64'h1_0000;
          init_header(16'h1af4, 16'h1041, 24'h020000, 8'h01, sizes);
          vqs = new[num_queues()];
          add_virtio_cap(VIRTIO_PCI_CAP_COMMON_CFG, 0, 32'h0, 32'h40, 0);
          add_virtio_cap(VIRTIO_PCI_CAP_NOTIFY_CFG, 2, 32'h0, num_queues() * NOTIFY_MULT, NOTIFY_MULT);
          add_virtio_cap(VIRTIO_PCI_CAP_ISR_CFG, 0, ISR_OFF, 32'h4, 0);
          add_virtio_cap(VIRTIO_PCI_CAP_DEVICE_CFG, 0, DEVCFG_OFF, 32'h100, 0);
          add_msix(4, 32'h0, 32'h8000, 2 * max_pairs + 2);
          status = 0;
          reset_device();
      endfunction

      // virtio_pci_cap：cap_len、cfg_type、bar、offset、length（notify 另带 multiplier）。
      protected function void add_virtio_cap(bit [7:0] cfg_type, int unsigned bar, bit [31:0] off,
                                             bit [31:0] len, bit [31:0] mult);
          bit [7:0] body[];

          body = new[(cfg_type == VIRTIO_PCI_CAP_NOTIFY_CFG) ? 18 : 14];
          foreach (body[i])
              body[i] = 0;
          body[0] = body.size() + 2;
          body[1] = cfg_type;
          body[2] = bar;
          for (int unsigned b = 0; b < 4; b++) begin
              body[6 + b] = off[8*b +: 8];
              body[10 + b] = len[8*b +: 8];
              if (body.size() == 18)
                  body[14 + b] = mult[8*b +: 8];
          end
          void'(add_cap(8'h09, body));
      endfunction

      // ---------------- 分类与协商结果 ----------------
      protected function bit is_packed();
          return driver_features[VIRTIO_F_RING_PACKED];
      endfunction
      protected function bit is_rx(int unsigned q);
          return (q < 2 * max_pairs) && ((q % 2) == 0);
      endfunction
      protected function bit is_tx(int unsigned q);
          return (q < 2 * max_pairs) && ((q % 2) == 1);
      endfunction
      protected function bit is_ctrl(int unsigned q);
          return (q == 2 * max_pairs) && driver_features[VIRTIO_NET_F_CTRL_VQ];
      endfunction
      protected function int unsigned hdr_len();
          if (driver_features[VIRTIO_NET_F_HASH_REPORT])
              return 20;
          return (driver_features[VIRTIO_F_VERSION_1] || driver_features[VIRTIO_NET_F_MRG_RXBUF]) ? 12 : 10;
      endfunction
      protected function bit [15:0] vector_or_none(bit [15:0] v);
          return (v < msix_vectors) ? v : NO_VECTOR;
      endfunction

      // ---------------- 复位 ----------------
      protected function void reset_vq(int unsigned q);
          vqs[q].size = queue_max;
          vqs[q].msix = NO_VECTOR;
          vqs[q].enable = 0;
          vqs[q].desc = 0;
          vqs[q].driver = 0;
          vqs[q].device = 0;
          vqs[q].last_avail = 0;
          vqs[q].used_idx = 0;
          vqs[q].wrap = 1;
          vqs[q].broken = 0;
      endfunction

      protected function void reset_device();
          quiesce();
          status = 0;
          driver_features = 0;
          dfselect = 0;
          gfselect = 0;
          config_msix = NO_VECTOR;
          qsel = 0;
          isr = 0;
          curr_pairs = 1;
          foreach (vqs[q])
              reset_vq(q);
      endfunction

      // ---------------- 寄存器镜像 ----------------
      protected function bit [511:0] common_image();
          bit [511:0] img;

          img = 0;
          img[8*'h00 +: 32] = dfselect;
          img[8*'h04 +: 32] = (dfselect == 0) ? device_features[31:0] :
                              ((dfselect == 1) ? device_features[63:32] : 32'h0);
          img[8*'h08 +: 32] = gfselect;
          img[8*'h0c +: 32] = (gfselect == 0) ? driver_features[31:0] :
                              ((gfselect == 1) ? driver_features[63:32] : 32'h0);
          img[8*'h10 +: 16] = config_msix;
          img[8*'h12 +: 16] = num_queues();
          img[8*'h14 +: 8]  = draining() ? status_before_reset : status;
          img[8*'h15 +: 8]  = generation;
          img[8*'h16 +: 16] = qsel;
          if (qsel < vqs.size()) begin
              img[8*'h18 +: 16] = vqs[qsel].size;
              img[8*'h1a +: 16] = vqs[qsel].msix;
              img[8*'h1c +: 16] = vqs[qsel].enable;
              img[8*'h1e +: 16] = qsel;
              img[8*'h20 +: 64] = vqs[qsel].desc;
              img[8*'h28 +: 64] = vqs[qsel].driver;
              img[8*'h30 +: 64] = vqs[qsel].device;
              img[8*'h38 +: 16] = qsel;
          end
          return img;
      endfunction

      protected function string common_field(bit [31:0] off, output int q);
          q = ((off >= 32'h18) && (off < 32'h3c)) ? int'(qsel) : -1;
          case (off)
              32'h00: return "device_feature_select";
              32'h04: return "device_feature";
              32'h08: return "driver_feature_select";
              32'h0c: return "driver_feature";
              32'h10: return "config_msix_vector";
              32'h12: return "num_queues";
              32'h14: return "device_status";
              32'h15: return "config_generation";
              32'h16: return "queue_select";
              32'h18: return "queue_size";
              32'h1a: return "queue_msix_vector";
              32'h1c: return "queue_enable";
              32'h1e: return "queue_notify_off";
              32'h20: return "queue_desc_lo";
              32'h24: return "queue_desc_hi";
              32'h28: return "queue_driver_lo";
              32'h2c: return "queue_driver_hi";
              32'h30: return "queue_device_lo";
              32'h34: return "queue_device_hi";
              32'h38: return "queue_notify_data";
              32'h3a: return "queue_reset";
              default: return $sformatf("0x%02h", off);
          endcase
      endfunction

      // virtio_net_config：mac、status(LINK_UP)、max_virtqueue_pairs、mtu、speed、duplex。
      protected function bit [2047:0] devcfg_image();
          bit [2047:0] img;

          img = 0;
          for (int unsigned i = 0; i < 6; i++)
              img[8*i +: 8] = mac[8*(5 - i) +: 8];
          img[8*6 +: 16]  = 16'h0001;
          img[8*8 +: 16]  = max_pairs;
          img[8*10 +: 16] = mtu;
          img[8*12 +: 32] = 32'd10000;
          img[8*16 +: 8]  = 8'h01;
          return img;
      endfunction

      protected function string devcfg_field(bit [31:0] off);
          if (off < 6)
              return "mac";
          case (off)
              32'h06: return "status";
              32'h08: return "max_virtqueue_pairs";
              32'h0a: return "mtu";
              32'h0c: return "speed";
              32'h10: return "duplex";
              default: return $sformatf("0x%02h", off);
          endcase
      endfunction

      // ---------------- MMIO ----------------
      virtual function bit [31:0] region_read(int unsigned bar, bit [31:0] off, int unsigned size);
          bit [2047:0] img;
          bit [31:0] v;
          int q;
          string field;

          v = 0;
          if ((bar == 0) && (off < 32'h40)) begin
              img = common_image();
              v = img[8*off +: 32];
              field = common_field(off, q);
              reg_event(0, "common_cfg", field, q, v & size_mask(size));
          end else if ((bar == 0) && (off >= ISR_OFF) && (off < ISR_OFF + 4)) begin
              if (off == ISR_OFF) begin
                  v = isr;
                  isr = 0;
              end
              reg_event(0, "isr", "isr", -1, v);
          end else if ((bar == 0) && (off >= DEVCFG_OFF) && (off < DEVCFG_OFF + 32'h100)) begin
              img = devcfg_image();
              v = img[8*(off - DEVCFG_OFF) +: 32];
              reg_event(0, "device_cfg", devcfg_field(off - DEVCFG_OFF), -1, v & size_mask(size));
          end
          return v;
      endfunction

      virtual function void region_write(int unsigned bar, bit [31:0] off, int unsigned size,
                                         bit [31:0] data);
          int q;
          string field;

          if ((bar == 2) && (off < num_queues() * NOTIFY_MULT)) begin
              notify(off / NOTIFY_MULT, data);
              return;
          end
          if ((bar == 0) && (off < 32'h40)) begin
              field = common_field(off, q);
              reg_event(1, "common_cfg", field, q, data);
              common_write(off, data);
              return;
          end
          // ISR 与 device_cfg 只读；其它偏移无寄存器。写被忽略但留痕。
          reg_event(1, ((bar == 0) && (off >= DEVCFG_OFF)) ? "device_cfg" : $sformatf("bar%0d", bar),
                    $sformatf("0x%0h", off), -1, data);
      endfunction

      protected function void common_write(bit [31:0] off, bit [31:0] data);
          bit valid_q;
          bit idle_q;

          valid_q = (qsel < vqs.size());
          idle_q = valid_q && !vqs[qsel].enable;
          case (off)
              32'h00: dfselect = data;
              32'h08: gfselect = data;
              32'h0c: if (!(status & DEV_STATUS_FEATURES_OK)) begin
                          if (gfselect == 0)
                              driver_features[31:0] = data;
                          else if (gfselect == 1)
                              driver_features[63:32] = data;
                      end
              32'h10: config_msix = vector_or_none(data[15:0]);
              32'h14: write_status(data[7:0]);
              32'h16: qsel = data[15:0];
              32'h18: if (idle_q) vqs[qsel].size = data[15:0];
              32'h1a: if (valid_q) vqs[qsel].msix = vector_or_none(data[15:0]);
              32'h1c: if (valid_q) queue_enable(qsel, data[0]);
              32'h20: if (idle_q) vqs[qsel].desc[31:0] = data;
              32'h24: if (idle_q) vqs[qsel].desc[63:32] = data;
              32'h28: if (idle_q) vqs[qsel].driver[31:0] = data;
              32'h2c: if (idle_q) vqs[qsel].driver[63:32] = data;
              32'h30: if (idle_q) vqs[qsel].device[31:0] = data;
              32'h34: if (idle_q) vqs[qsel].device[63:32] = data;
              32'h3a: if (valid_q && data[0] && driver_features[VIRTIO_F_RING_RESET]) reset_vq(qsel);
              default: ;
          endcase
      endfunction

      protected function void write_status(bit [7:0] v);
          bit [7:0] old;
          vdev_event e;

          old = status;
          if (v == 0) begin
              status_before_reset = status;
              reset_device();
          end else begin
              if ((v & DEV_STATUS_FEATURES_OK) && !(old & DEV_STATUS_FEATURES_OK)) begin
                  e = new_event(VDEV_FEATURES);
                  e.dev_offered = device_features;
                  e.drv_accepted = driver_features;
                  emit(e);
                  if (((driver_features & ~device_features) != 0) ||
                      (device_features[VIRTIO_F_VERSION_1] && !driver_features[VIRTIO_F_VERSION_1]))
                      v = v & ~DEV_STATUS_FEATURES_OK;
              end
              status = v;
          end
          e = new_event(VDEV_STATUS);
          e.from_status = old;
          e.to_status = status;
          emit(e);
      endfunction

      protected function string enable_check(int unsigned q);
          if (!(status & DEV_STATUS_FEATURES_OK))
              return "FEATURES_OK not set";
          if ((vqs[q].size == 0) || (vqs[q].size > queue_max))
              return $sformatf("queue_size %0d outside 1..%0d", vqs[q].size, queue_max);
          if (!is_packed() && ((vqs[q].size & (vqs[q].size - 1)) != 0))
              return "split queue_size is not a power of 2";
          if (vqs[q].desc == 0)
              return "queue_desc not written";
          if (vqs[q].driver == 0)
              return "queue_driver not written";
          if (vqs[q].device == 0)
              return "queue_device not written";
          return "";
      endfunction

      protected function void queue_enable(int unsigned q, bit v);
          string why;
          vdev_event e;

          if (!v) begin
              // virtio 1.x 驱动不应写 0；按停队处理，后续 notify 被忽略。
              vqs[q].enable = 0;
              return;
          end
          if (vqs[q].enable)
              return;
          why = enable_check(q);
          if (why != "") begin
              `uvm_warning("VDEV_QUEUE", $sformatf("BDF 0x%04h queue %0d enable rejected: %s", bdf, q, why))
              return;
          end
          vqs[q].enable = 1;
          vqs[q].last_avail = 0;
          vqs[q].used_idx = 0;
          vqs[q].wrap = 1;
          vqs[q].broken = 0;
          e = new_event(VDEV_QUEUE_CFG);
          e.q = q;
          e.size = vqs[q].size;
          e.vector = vqs[q].msix;
          e.enable = 1;
          e.ring_fmt = is_packed() ? "packed" : "split";
          emit(e);
      endfunction

      protected function void notify(int unsigned slot, bit [31:0] data);
          vdev_event e;
          int unsigned q;

          q = data[15:0];
          e = new_event(VDEV_NOTIFY);
          e.q = q;
          if (driver_features[VIRTIO_F_NOTIFICATION_DATA]) begin
              e.next_idx = is_packed() ? data[30:16] : data[31:16];
              e.wrap = is_packed() ? data[31] : 1'b0;
          end
          emit(e);
          n_notify++;
          if ((q != slot) || (q >= vqs.size()) || !vqs[q].enable || !(status & DEV_STATUS_DRIVER_OK)) begin
              `uvm_warning("VDEV_QUEUE", $sformatf(
                  "BDF 0x%04h ignored notify data=0x%08h at slot %0d (queue disabled, mismatched or before DRIVER_OK)",
                  bdf, data, slot))
              return;
          end
          schedule(q);
      endfunction

      // 链非法：停用队列、置 DEVICE_NEEDS_RESET 并发配置中断（MSI-X 未使能时置 ISR bit1）。
      protected function void device_error(int unsigned q, string why);
          bit [7:0] old;
          vdev_event e;

          `uvm_warning("VDEV_RING", $sformatf("BDF 0x%04h queue %0d: %s", bdf, q, why))
          vqs[q].broken = 1;
          old = status;
          status = status | DEV_STATUS_DEVICE_NEEDS_RESET;
          generation++;
          e = new_event(VDEV_STATUS);
          e.from_status = old;
          e.to_status = status;
          emit(e);
          if (msix_enabled()) begin
              irq_q.push_back(config_msix);
              -> work_ev;
          end else
              isr = isr | 8'h02;
      endfunction

      // ---------------- 数据路径 ----------------
      virtual task service_queue(int unsigned q);
          int unsigned my_epoch;
          int unsigned id;
          int unsigned slot;
          int unsigned slots;
          int unsigned used_len;
          bit got;
          bit ok;
          desc_t chain[$];

          my_epoch = epoch;
          while ((my_epoch == epoch) && (q < vqs.size()) && vqs[q].enable && !vqs[q].broken &&
                 (status & DEV_STATUS_DRIVER_OK)) begin
              if (is_rx(q) && !has_backlog(q / 2))
                  break;
              fetch(q, got, id, slot, slots, chain);
              if (!got || (my_epoch != epoch) || !chain_ok(q, chain))
                  break;
              consume(q, chain, used_len, ok);
              if (!ok || (my_epoch != epoch))
                  break;
              if (take_fault(q, VQ_FAULT_BEFORE_USED))
                  used_len++;
              push_used(q, id, slot, slots, used_len, ok);
              if (!ok)
                  break;
          end
      endtask

      // 取下一条可用链：split 读 avail，packed 按 wrap 判断槽可用；读完整条链（展开 INDIRECT）。
      protected task fetch(int unsigned q, output bit got, output int unsigned id,
                           output int unsigned slot, output int unsigned slots, ref desc_t chain[$]);
          bit [7:0] b[];
          bit ok;
          bit [15:0] avail_idx;
          bit [15:0] flags;

          got = 0;
          id = 0;
          slot = vqs[q].last_avail;
          slots = 0;
          chain.delete();
          if (!is_packed()) begin
              dma_rd(vqs[q].driver + 2, 2, b, ok);
              if (!ok)
                  return;
              avail_idx = {b[1], b[0]};
              if (avail_idx == vqs[q].last_avail)
                  return;
              dma_rd(vqs[q].driver + 4 + 2 * (vqs[q].last_avail % vqs[q].size), 2, b, ok);
              if (!ok)
                  return;
              id = {b[1], b[0]};
              vqs[q].last_avail++;
              slots = 1;
              read_split_chain(q, id, ok, chain);
          end else begin
              dma_rd(vqs[q].desc + 16 * slot + 14, 2, b, ok);
              if (!ok)
                  return;
              flags = {b[1], b[0]};
              if ((flags[7] != vqs[q].wrap) || (flags[15] == vqs[q].wrap))
                  return;
              read_packed_chain(q, ok, id, slots, chain);
          end
          if (!ok)
              return;
          got = 1;
          if (take_fault(q, VQ_FAULT_PRE_DEVICE_READ)) begin
              if (err_inj.err_type == VQ_ERR_ZERO_LEN_BUF)
                  chain[0].len = 0;
              else
                  chain[0].flags = chain[0].flags ^ VIRTQ_DESC_F_WRITE;
          end
      endtask

      protected task read_desc(bit [63:0] addr, bit packed_fmt, output bit ok, output desc_t d);
          bit [7:0] b[];

          d = '{default: 0};
          dma_rd(addr, 16, b, ok);
          if (!ok)
              return;
          d.addr = {b[7], b[6], b[5], b[4], b[3], b[2], b[1], b[0]};
          d.len = {b[11], b[10], b[9], b[8]};
          if (packed_fmt) begin
              d.id = {b[13], b[12]};
              d.flags = {b[15], b[14]};
          end else begin
              d.flags = {b[13], b[12]};
              d.next = {b[15], b[14]};
          end
      endtask

      // INDIRECT 表：split 格式按 next 链接，packed 格式顺序排列；禁止嵌套。
      protected task read_indirect(desc_t ind, bit packed_fmt, output bit ok, ref desc_t chain[$]);
          desc_t d;
          int unsigned n;
          int unsigned i;
          int unsigned guard;

          ok = 0;
          n = ind.len / 16;
          if ((ind.len == 0) || ((ind.len % 16) != 0))
              return;
          i = 0;
          guard = 0;
          while ((i < n) && (guard++ < n)) begin
              read_desc(ind.addr + 16 * i, 0, ok, d);
              if (!ok || (d.flags & VIRTQ_DESC_F_INDIRECT)) begin
                  ok = 0;
                  return;
              end
              chain.push_back(d);
              if (packed_fmt) begin
                  i++;
              end else begin
                  if (!(d.flags & VIRTQ_DESC_F_NEXT))
                      break;
                  i = d.next;
              end
          end
          ok = (chain.size() != 0);
      endtask

      protected task read_split_chain(int unsigned q, int unsigned head, output bit ok,
                                      ref desc_t chain[$]);
          desc_t d;
          int unsigned idx;
          int unsigned guard;

          ok = 0;
          idx = head;
          guard = 0;
          forever begin
              if ((idx >= vqs[q].size) || (guard++ > vqs[q].size))
                  return;
              read_desc(vqs[q].desc + 16 * idx, 0, ok, d);
              if (!ok)
                  return;
              if (d.flags & VIRTQ_DESC_F_INDIRECT) begin
                  read_indirect(d, 0, ok, chain);
                  return;
              end
              chain.push_back(d);
              if (!(d.flags & VIRTQ_DESC_F_NEXT))
                  break;
              idx = d.next;
          end
          ok = 1;
      endtask

      // packed 链：从当前槽顺序读到无 NEXT；buffer id 取链尾描述符；推进槽与 wrap。
      protected task read_packed_chain(int unsigned q, output bit ok, output int unsigned id,
                                       output int unsigned slots, ref desc_t chain[$]);
          desc_t d;

          ok = 0;
          id = 0;
          slots = 0;
          forever begin
              if (slots >= vqs[q].size)
                  return;
              read_desc(vqs[q].desc + 16 * vqs[q].last_avail, 1, ok, d);
              if (!ok)
                  return;
              slots++;
              vqs[q].last_avail++;
              if (vqs[q].last_avail == vqs[q].size) begin
                  vqs[q].last_avail = 0;
                  vqs[q].wrap = ~vqs[q].wrap;
              end
              id = d.id;
              if (d.flags & VIRTQ_DESC_F_INDIRECT) begin
                  read_indirect(d, 1, ok, chain);
                  return;
              end
              chain.push_back(d);
              if (!(d.flags & VIRTQ_DESC_F_NEXT))
                  break;
          end
          ok = 1;
      endtask

      protected function bit chain_ok(int unsigned q, desc_t chain[$]);
          bit seen_write;
          string why;

          seen_write = 0;
          why = "";
          foreach (chain[i]) begin
              if ((why == "") && (chain[i].len == 0))
                  why = $sformatf("descriptor %0d has zero length", i);
              if (chain[i].flags & VIRTQ_DESC_F_WRITE)
                  seen_write = 1;
              else if ((why == "") && seen_write)
                  why = "device-readable descriptor after a writable one";
          end
          if ((why == "") && is_tx(q) && seen_write)
              why = "TX chain contains a writable descriptor";
          if ((why == "") && is_rx(q) && !(chain[0].flags & VIRTQ_DESC_F_WRITE))
              why = "RX chain starts with a device-readable descriptor";
          if (why == "")
              return 1;
          device_error(q, why);
          return 0;
      endfunction

      protected task read_readable(desc_t chain[$], output bit ok, ref bit [7:0] data[$]);
          bit [7:0] b[];

          data.delete();
          ok = 1;
          foreach (chain[i]) begin
              if (chain[i].flags & VIRTQ_DESC_F_WRITE)
                  continue;
              dma_rd(chain[i].addr, chain[i].len, b, ok);
              if (!ok)
                  return;
              foreach (b[j])
                  data.push_back(b[j]);
          end
      endtask

      protected task consume(int unsigned q, desc_t chain[$], output int unsigned used_len,
                             output bit ok);
          bit [7:0] data[$];

          used_len = 0;
          ok = 1;
          if (is_tx(q)) begin
              read_readable(chain, ok, data);
              if (ok)
                  tx_frame(q, chain, data);
          end else if (is_rx(q))
              rx_frame(q, chain, used_len, ok);
          else if (is_ctrl(q))
              ctrl_cmd(q, chain, used_len, ok);
      endtask

      protected function vdev_event chain_event(int unsigned q, desc_t chain[$]);
          vdev_event e;

          e = new_event(VDEV_DESC_CHAIN);
          e.q = q;
          foreach (chain[i]) begin
              e.seg_len.push_back(chain[i].len);
              e.seg_flags.push_back(chain[i].flags);
          end
          return e;
      endfunction

      protected function virtio_net_hdr_t decode_hdr(bit [7:0] d[$]);
          virtio_net_hdr_t h;

          h = '{default: 0};
          if (d.size() < 10)
              return h;
          h.flags = d[0];
          h.gso_type = d[1];
          h.hdr_len = {d[3], d[2]};
          h.gso_size = {d[5], d[4]};
          h.csum_start = {d[7], d[6]};
          h.csum_offset = {d[9], d[8]};
          if ((hdr_len() >= 12) && (d.size() >= 12))
              h.num_buffers = {d[11], d[10]};
          return h;
      endfunction

      protected function void encode_hdr(virtio_net_hdr_t h, ref bit [7:0] out[$]);
          out.delete();
          out = '{h.flags, h.gso_type, h.hdr_len[7:0], h.hdr_len[15:8], h.gso_size[7:0],
                  h.gso_size[15:8], h.csum_start[7:0], h.csum_start[15:8], h.csum_offset[7:0],
                  h.csum_offset[15:8]};
          if (hdr_len() >= 12) begin
              out.push_back(h.num_buffers[7:0]);
              out.push_back(h.num_buffers[15:8]);
          end
          while (out.size() < hdr_len())
              out.push_back(8'h00);
      endfunction

      // TX：解 header、发 desc_chain/pkt 事件，帧回环到同对 RX。
      protected function void tx_frame(int unsigned q, desc_t chain[$], bit [7:0] data[$]);
          vdev_event e;
          bit [7:0] frame[$];

          e = chain_event(q, chain);
          e.has_hdr = 1;
          e.hdr = decode_hdr(data);
          emit(e);
          if (data.size() > hdr_len())
              frame = data[hdr_len():$];
          e = new_event(VDEV_PKT);
          e.dir = "tx";
          e.q = q;
          e.bytes = frame;
          e.len = frame.size();
          emit(e);
          inject_rx(q / 2, frame);
      endfunction

      // RX：header（num_buffers=1）+ 帧写进可写描述符；单链放不下时丢帧（buffer 以 len 0 归还）。
      protected task rx_frame(int unsigned q, desc_t chain[$], output int unsigned used_len,
                              output bit ok);
          virtio_net_hdr_t hdr;
          bit [7:0] payload[$];
          bit [7:0] part[];
          frame_t f;
          int unsigned room;
          int unsigned cursor;
          int unsigned n;
          vdev_event e;

          used_len = 0;
          ok = 1;
          f = rx_backlog[q / 2][0];
          void'(rx_backlog[q / 2].pop_front());
          hdr = '{default: 0};
          hdr.num_buffers = 1;
          encode_hdr(hdr, payload);
          foreach (f.data[i])
              payload.push_back(f.data[i]);
          room = 0;
          foreach (chain[i])
              room += chain[i].len;
          if (payload.size() > room) begin
              `uvm_warning("VDEV_RX", $sformatf(
                  "BDF 0x%04h queue %0d dropped a %0d-byte frame: buffer chain holds %0d bytes",
                  bdf, q, payload.size(), room))
              return;
          end
          cursor = 0;
          foreach (chain[i]) begin
              if (cursor >= payload.size())
                  break;
              n = payload.size() - cursor;
              if (n > chain[i].len)
                  n = chain[i].len;
              part = new[n];
              foreach (part[j])
                  part[j] = payload[cursor + j];
              dma_wr(chain[i].addr, part, ok);
              if (!ok)
                  return;
              cursor += n;
          end
          e = chain_event(q, chain);
          e.has_hdr = 1;
          e.hdr = hdr;
          emit(e);
          e = new_event(VDEV_PKT);
          e.dir = "rx";
          e.q = q;
          e.bytes = f.data;
          e.len = f.data.size();
          emit(e);
          used_len = payload.size();
      endtask

      // ctrl：可读部分 {class, cmd, data...}，最后一个可写描述符的首字节是 ack。
      protected task ctrl_cmd(int unsigned q, desc_t chain[$], output int unsigned used_len,
                              output bit ok);
          bit [7:0] req[$];
          bit [7:0] ack_b[];
          bit [7:0] args[$];
          vdev_event e;

          used_len = 0;
          read_readable(chain, ok, req);
          if (!ok)
              return;
          if ((req.size() < 2) || !(chain[chain.size() - 1].flags & VIRTQ_DESC_F_WRITE)) begin
              device_error(q, "malformed control command");
              ok = 0;
              return;
          end
          if (req.size() > 2)
              args = req[2:$];
          ack_b = new[1];
          ack_b[0] = ctrl_apply(req[0], req[1], args);
          dma_wr(chain[chain.size() - 1].addr, ack_b, ok);
          if (!ok)
              return;
          e = new_event(VDEV_CTRL);
          e.q = q;
          e.ctrl_class = req[0];
          e.ctrl_cmd = req[1];
          e.ctrl_data = args;
          e.ack = ack_b[0];
          emit(e);
          used_len = 1;
      endtask

      // virtio 1.2 §5.1.6.5：未协商对应特性或参数非法时 ACK_ERR(1)。
      protected function bit [7:0] ctrl_apply(bit [7:0] cls, bit [7:0] cmd, bit [7:0] data[$]);
          bit [15:0] pairs;

          case (cls)
              VIRTIO_NET_CTRL_MQ: begin
                  if (!driver_features[VIRTIO_NET_F_MQ] || (cmd != VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET) ||
                      (data.size() != 2))
                      return 1;
                  pairs = {data[1], data[0]};
                  if ((pairs == 0) || (pairs > max_pairs))
                      return 1;
                  curr_pairs = pairs;
                  return 0;
              end
              VIRTIO_NET_CTRL_RX:
                  return (driver_features[VIRTIO_NET_F_CTRL_RX] && (data.size() == 1) &&
                          ((cmd <= 1) || ((cmd <= 5) && driver_features[VIRTIO_NET_F_CTRL_RX_EXTRA]))) ? 0 : 1;
              VIRTIO_NET_CTRL_MAC: begin
                  if ((cmd == VIRTIO_NET_CTRL_MAC_ADDR_SET) && driver_features[VIRTIO_NET_F_CTRL_MAC_ADDR] &&
                      (data.size() == 6)) begin
                      mac = {data[0], data[1], data[2], data[3], data[4], data[5]};
                      return 0;
                  end
                  return ((cmd == VIRTIO_NET_CTRL_MAC_TABLE_SET) && driver_features[VIRTIO_NET_F_CTRL_RX]) ? 0 : 1;
              end
              VIRTIO_NET_CTRL_VLAN:
                  return (driver_features[VIRTIO_NET_F_CTRL_VLAN] && (cmd <= 1) && (data.size() == 2)) ? 0 : 1;
              VIRTIO_NET_CTRL_ANNOUNCE:
                  return (driver_features[VIRTIO_NET_F_GUEST_ANNOUNCE] && (cmd == 0)) ? 0 : 1;
              default:
                  return 1;
          endcase
      endfunction

      // 写回 used：split 写 used 元素再写 used idx；packed 在链首槽写 len/id，最后写 flags。
      protected task push_used(int unsigned q, int unsigned id, int unsigned slot, int unsigned slots,
                               int unsigned len, output bit ok);
          bit [7:0] b[];
          bit [15:0] old_idx;
          bit slot_wrap;
          vdev_event e;

          if (!is_packed()) begin
              b = new[8];
              for (int unsigned i = 0; i < 4; i++) begin
                  b[i] = id >> (8 * i);
                  b[4 + i] = len >> (8 * i);
              end
              dma_wr(vqs[q].device + 4 + 8 * (vqs[q].used_idx % vqs[q].size), b, ok);
              if (!ok)
                  return;
              old_idx = vqs[q].used_idx;
              vqs[q].used_idx++;
              b = new[2];
              b[0] = vqs[q].used_idx[7:0];
              b[1] = vqs[q].used_idx[15:8];
              dma_wr(vqs[q].device + 2, b, ok);
          end else begin
              old_idx = 0;
              slot_wrap = ((slot + slots) >= vqs[q].size) ? ~vqs[q].wrap : vqs[q].wrap;
              b = new[6];
              for (int unsigned i = 0; i < 4; i++)
                  b[i] = len >> (8 * i);
              b[4] = id[7:0];
              b[5] = id[15:8];
              dma_wr(vqs[q].desc + 16 * slot + 8, b, ok);
              if (!ok)
                  return;
              b = new[2];
              b[0] = slot_wrap ? 8'h80 : 8'h00;
              b[1] = slot_wrap ? 8'h80 : 8'h00;
              dma_wr(vqs[q].desc + 16 * slot + 14, b, ok);
          end
          if (!ok)
              return;
          n_complete++;
          e = new_event(VDEV_COMPLETE);
          e.q = q;
          e.id = id;
          e.len = len;
          emit(e);
          used_notify(q, old_idx);
      endtask

      // 事件抑制：split 按 EVENT_IDX 的 used_event 或 avail.flags NO_INTERRUPT；packed 读驱动事件抑制区
      // flags（1=禁用；2=按描述符，本模型视同启用）。
      protected task used_notify(int unsigned q, bit [15:0] old_idx);
          bit [7:0] b[];
          bit [15:0] ev;
          bit ok;
          bit need;

          if (!is_packed() && driver_features[VIRTIO_F_RING_EVENT_IDX]) begin
              dma_rd(vqs[q].driver + 4 + 2 * vqs[q].size, 2, b, ok);
              ev = {b[1], b[0]};
              need = ok && (16'(vqs[q].used_idx - ev - 1) < 16'(vqs[q].used_idx - old_idx));
          end else if (!is_packed()) begin
              dma_rd(vqs[q].driver, 2, b, ok);
              need = ok && !b[0][0];
          end else begin
              dma_rd(vqs[q].driver + 2, 2, b, ok);
              need = ok && (b[0][1:0] != 2'b01);
          end
          if (!need)
              return;
          if (msix_enabled())
              raise_irq(vqs[q].msix);
          else
              isr = isr | 8'h01;
      endtask
  endclass
  `endif
  ```
  说明（packed used wrap）：设备在取链时已推进 `last_avail/wrap`；`push_used` 需要链首槽的 wrap，按
  “链首槽 + 链长是否越过环尾”反推。`read_packed_chain` 之前的 wrap 即链首槽 wrap，等价写法是在 `fetch` 里保存；
  实现时若发现反推与 `poll_used` 不一致，改为在 `fetch` 输出 `slot_wrap`（断言不变）。

- [ ] **Step 4: 包含进包**

  `virtio_net_pkg.sv` old：
  ```systemverilog
    `include "devmodel/vdev_uvm_ep_port.sv"
  ```
  new：
  ```systemverilog
    `include "devmodel/vdev_uvm_ep_port.sv"
    `include "devmodel/vdev_virtio_pci.sv"
  ```

- [ ] **Step 5: 运行，确认通过**

  单测 `TEST=virtio_vdev_unit_test`：日志依次含 6 条 `test_std_* PASSED`，三行汇总为 0。

- [ ] **Step 6: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=41`。

- [ ] **Step 7: 提交**
  ```bash
  git add virtio_net_vip/src/devmodel/vdev_virtio_pci.sv virtio_net_vip/src/virtio_net_pkg.sv \
      virtio_net_vip/tests/virtio_vdev_unit_test.sv
  git commit -m "feat: 新增标准 virtio-net 设备模型（common_cfg、split/packed、ctrl VQ、MSI-X、故障点）"
  ```

---
### Task D3: fixture 改接 `vdev_virtio_pci`，修复独立设备暴露的 VIP 缺陷，删除 `virtio_pcie_dut_responder`（规范 R4）

**现状（核对过）：** responder 只被 `virtio_real_driver_flow_fixture` 使用（`virtio_real_driver_flow_test`、
`virtio_real_driver_rx_test`、`virtio_real_driver_multiqueue_test` 经 `flow.dut_responder()`，`virtio_full_test`、
`virtio_dual_test` 经同一 fixture 的端点镜像）；env 不创建它。它不应答 MMIO——寄存器值来自 fixture 写进 EP
`mem_space` 的镜像加 `virtio_feature_select_ep_driver` 的 DFSELECT 补丁；队列地址缺失时取 VIP virtqueue 的
`desc_table_addr`；中断直接调 `transport.notify_mgr.on_interrupt_received`；RX header 用 `transport.driver_features`
编码；设备侧故障点调用 VIP virtqueue 的 `process_error_injection`。这些“偷看”全部由设备模型自身状态替代。

**已知会被独立设备暴露的 VIP 缺陷（先写失败用例再修）：**
`virtio_common_cfg_backend::set_msix` 只写 MSI-X 表项（全部带屏蔽位）并清 `notify_mgr` 的影子屏蔽位，
从不写 PCI 配置空间的 MSI-X Enable，也不清设备表项的 Vector Control。真实设备在这种状态下不会发 MSI-X；
旧 responder 绕过了它（直接调 notify_mgr）。另外旧镜像的 MSI-X Table Size 字段为 0（1 个向量），VIP 实际退回
INTx；新设备提供 `2*max_pairs+2` 个向量，fixture 流程改走每队列 MSI-X。

**Files:**
- Modify: `virtio_net_vip/src/transport/virtio_notification_manager.sv`、`virtio_net_vip/src/transport/virtio_config_backend.sv`
- Modify: `virtio_net_vip/tests/vdev_loopback_port.sv`（回环 BAR accessor）、`virtio_net_vip/tests/virtio_vdev_unit_test.sv`
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`、`virtio_real_driver_flow_test.sv`、
  `virtio_real_driver_rx_test.sv`、`virtio_real_driver_multiqueue_test.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`、`virtio_net_vip/src/env/virtio_execution_profile.sv`（注释）、
  `virtio_net_vip/src/types/virtio_net_types.sv`（注释）
- Delete: `virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv`
- Test: `virtio_vdev_unit_test`、`virtio_real_driver_flow_test`、`virtio_real_driver_rx_test`、
  `virtio_real_driver_multiqueue_test`、`virtio_full_integration_test`、`virtio_dual_test`

**Interfaces:**
- Produces（测试件）：`vdev_loopback_bar_accessor extends virtio_bar_accessor`（`port`、`target_bdf`；覆写
  `read_reg/write_reg/write_msix_reg/config_read/config_write`，保留基类 BAR 角色守卫）。D5 复用。
- Produces（fixture）：`device_port`、`devices[]`、`function vdev_virtio_pci device()`；
  `inject_rx(input int unsigned queue_id, input uvm_object pkt, ref bit ok)`（去掉 `net_hdr`：header 由设备生成）。
  删除 `dut_responder()`、`model_responder_active()`、`virtio_feature_select_ep_driver`、`install_endpoint_image`。
- Changes（VIP）：`set_msix` 末尾写 MSI-X Enable=1/Function Mask=0；`clear_msix` 置 Function Mask；
  `notify_mgr` 的 `mask_vector/unmask_vector/mask_all/unmask_all` 把屏蔽位写进设备表项 Vector Control。

- [ ] **Step 1: 写失败测试**

  (a) `virtio_net_vip/tests/vdev_loopback_port.sv`：在 `class vdev_event_log` 之前加入：
  ```systemverilog
  // 回环 BAR accessor：把 VIP transport 的 MMIO/配置访问直接交给 vdev_loopback_port（无 PCIe）。
  // 保留基类的 BAR 角色守卫；bar_base 由测试设置（Fabric 布局存在时由 Function 绑定写入）。
  class vdev_loopback_bar_accessor extends virtio_bar_accessor;
      `uvm_object_utils(vdev_loopback_bar_accessor)

      vdev_loopback_port port;
      bit [15:0]         target_bdf;

      function new(string name = "vdev_loopback_bar_accessor");
          super.new(name);
      endfunction

      virtual task read_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size,
                            ref bit [31:0] data);
          if ((bar_id > 5) || !allow_functional_bar_access(bar_id)) begin
              data = '0;
              return;
          end
          data = port.host_read(bar_base[bar_id] + offset, size);
      endtask

      virtual task write_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size,
                             bit [31:0] data);
          if ((bar_id > 5) || !allow_functional_bar_access(bar_id))
              return;
          port.host_write(bar_base[bar_id] + offset, size, data);
      endtask

      virtual task write_msix_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size,
                                  bit [31:0] data);
          if ((bar_id > 5) || !allow_msix_bar_access(bar_id))
              return;
          port.host_write(bar_base[bar_id] + offset, size, data);
      endtask

      virtual task config_read(bit [11:0] addr, ref bit [31:0] data);
          data = port.host_cfg_read(target_bdf, addr);
      endtask

      virtual task config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
          port.host_cfg_write(target_bdf, addr, data, be);
      endtask
  endclass
  ```

  (b) `virtio_vdev_unit_test.sv`：在 `virtual task run_phase` 之前加入：
  ```systemverilog
      // 独立设备暴露的 VIP 缺陷：common-config 后端 set_msix 必须在设备上打开 MSI-X（Enable=1、
      // Function Mask=0）并清掉所用向量的 Vector Control；clear_msix 必须重新屏蔽。
      task test_vip_msix_enables_device();
          virtio_pci_transport t;
          vdev_loopback_bar_accessor acc;
          virtio_common_cfg_backend be;
          int unsigned qids[$];
          bit [31:0] v;
          bit [7:0] cap;
          bit ok;

          t = virtio_pci_transport::type_id::create("vip_msix_transport");
          t.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(STD_BDF));
          acc = vdev_loopback_bar_accessor::type_id::create("vip_msix_bar");
          acc.port = port;
          acc.target_bdf = STD_BDF;
          acc.bar_base[0] = STD_BAR0;
          acc.bar_base[2] = STD_BAR2;
          acc.bar_base[4] = STD_BAR4;
          t.bar = acc;
          t.cap_mgr.bar_ref = acc;
          t.notify_mgr.bar = acc;
          t.cap_mgr.discover_capabilities();
          cap = find_cap(STD_BDF, 8'h11);
          // 回到设备复位后的 MSI-X 状态：关闭使能、全部向量屏蔽。
          port.host_cfg_write(STD_BDF, {4'h0, cap}, 32'h0, 4'hc);
          for (int unsigned i = 0; i < 6; i++)
              port.host_write(STD_BAR4 + 16*i + 12, 4, 1);
          be = virtio_common_cfg_backend::type_id::create("vip_msix_backend");
          be.bind_transport(t);
          qids.push_back(0);
          qids.push_back(1);
          be.set_msix(qids, ok);
          v = port.host_cfg_read(STD_BDF, {4'h0, cap});
          if (!ok || !v[31] || v[30])
              `uvm_fatal("VDEV_UNIT", $sformatf(
                  "set_msix left device MSI-X disabled or function-masked (ctrl=0x%04h)", v[31:16]))
          for (int unsigned i = 0; i < 3; i++)
              if (port.host_read(STD_BAR4 + 16*i + 12, 4) != 0)
                  `uvm_fatal("VDEV_UNIT", $sformatf("set_msix left vector %0d masked in the device table", i))
          be.clear_msix(ok);
          v = port.host_cfg_read(STD_BDF, {4'h0, cap});
          if (!ok || !v[30] || (port.host_read(STD_BAR4 + 12, 4) != 1))
              `uvm_fatal("VDEV_UNIT", "clear_msix did not mask the device MSI-X function/vectors")
          `uvm_info("VDEV_UNIT", "test_vip_msix_enables_device PASSED", UVM_LOW)
      endtask
  ```
  `run_phase` old：
  ```systemverilog
          test_std_device_fault_and_reset();
          mem.leak_check();
  ```
  new：
  ```systemverilog
          test_std_device_fault_and_reset();
          test_vip_msix_enables_device();
          mem.leak_check();
  ```

  (c) 【在 Step 4 提交 VIP 修复之后再做】三个真实驱动流程测试改为面对设备模型（断言条件与次数不变；responder 生命周期——start/running/stop——
  随 responder 一起消失，设备没有“启动”状态，复位由驱动写 status=0 完成）。

  `virtio_real_driver_flow_test.sv` old：
  ```systemverilog
      if (is_model) begin
        if (flow.dut_responder() == null) begin
          `uvm_error("REAL_FLOW", "MODEL fixture did not expose DUT responder")
        end else begin
        flow.dut_responder().start();
      if (!flow.dut_responder().running())
          `uvm_error("REAL_FLOW", "DUT responder did not enter running state")
        else begin
  ```
  new：
  ```systemverilog
      if (is_model) begin
        if (flow.device() == null) begin
          `uvm_error("REAL_FLOW", "MODEL fixture did not expose its device model")
        end else begin
  ```
  old：
  ```systemverilog
            `uvm_error("REAL_FLOW", "TX did not traverse notify/DMA/used/interrupt path")

          flow.dut_responder().stop();
          flow.dut_responder().wait_stopped();
          if (flow.dut_responder().running())
            `uvm_error("REAL_FLOW", "DUT responder did not stop cleanly")
        end
        end
  ```
  new：
  ```systemverilog
            `uvm_error("REAL_FLOW", "TX did not traverse notify/DMA/used/interrupt path")
        end
  ```
  其余 `flow.dut_responder()` 全部改为 `flow.device()`：
  ```bash
  sed -i 's/flow\.dut_responder()/flow.device()/g' virtio_net_vip/tests/virtio_real_driver_flow_test.sv \
      virtio_net_vip/tests/virtio_real_driver_rx_test.sv virtio_net_vip/tests/virtio_real_driver_multiqueue_test.sv
  ```
  `virtio_real_driver_rx_test.sv`（sed 之后）old：
  ```systemverilog
      if (flow.device() == null)
        `uvm_fatal("REAL_RX", "fixture did not expose DUT responder")
      flow.device().start();
      if (!flow.device().running())
        `uvm_fatal("REAL_RX", "DUT responder did not start")
  ```
  new：
  ```systemverilog
      if (flow.device() == null)
        `uvm_fatal("REAL_RX", "fixture did not expose its device model")
  ```
  old：`      flow.inject_rx(rx_queue_id, hdr, pkt, ok);` new：`      flow.inject_rx(rx_queue_id, pkt, ok);`；
  old：`            "responder rejected RX packet %0d", i))` new：`            "device rejected RX packet %0d", i))`；
  删除两行（`hdr` 只为 inject_rx 存在）：`    virtio_net_hdr_t hdr;` 与 `    hdr = '{default: 0};`；
  old：
  ```systemverilog
      flow.device().stop();
      flow.device().wait_stopped();
      flow.reset_and_teardown(ok);
  ```
  new：
  ```systemverilog
      flow.reset_and_teardown(ok);
  ```
  测试头部注释中 “The responder must wait for a writable descriptor” → “The device must wait for a writable descriptor”。

  `virtio_real_driver_multiqueue_test.sv`（sed 之后）old：
  ```systemverilog
        if (flow.device() == null)
          `uvm_fatal("REAL_MQ", "MODEL fixture did not expose DUT responder")
        flow.device().start();
        if (!flow.device().running())
          `uvm_fatal("REAL_MQ", "MODEL DUT responder did not start")
  ```
  new：
  ```systemverilog
        if (flow.device() == null)
          `uvm_fatal("REAL_MQ", "MODEL fixture did not expose its device model")
  ```
  old：
  ```systemverilog
        flow.device().stop();
        flow.device().wait_stopped();
      end else begin
  ```
  new：
  ```systemverilog
      end else begin
  ```

- [ ] **Step 2: 运行，确认失败**

  `TEST=virtio_vdev_unit_test`：期望 `UVM_FATAL` “set_msix left device MSI-X disabled or function-masked (ctrl=0x0005)”
  （缺陷复现）。做完 (c) 后 `TEST=virtio_real_driver_flow_test`：期望编译失败，`Error-` 指出 `device` 不是 fixture 的成员。

- [ ] **Step 3: 修复 VIP（MSI-X 使能与屏蔽写回设备）**

  `virtio_notification_manager.sv` old：
  ```systemverilog
      bit               msix_function_mask = 0; // global function mask
  ```
  new：
  ```systemverilog
      bit               msix_function_mask = 0; // global function mask
      // setup_msix 记录的设备表位置；屏蔽位经它写回表项 Vector Control（+0xC）。
      protected int unsigned msix_table_bar_id;
      protected bit [31:0]   msix_table_base;
  ```
  `setup_msix` old：
  ```systemverilog
          msix_table = new[num_vectors];
          msix_mask  = new[num_vectors];
  ```
  new：
  ```systemverilog
          msix_table = new[num_vectors];
          msix_mask  = new[num_vectors];
          msix_table_bar_id = msix_table_bar;
          msix_table_base = msix_table_offset;
  ```
  在 `    // 屏蔽单个向量；越界仅告警不生效。` 之前加入：
  ```systemverilog
      // 把向量的影子屏蔽位写进设备 MSI-X 表项 Vector Control；未建表或无 BAR accessor 时不访问设备。
      protected task write_vector_control(int unsigned vector);
          if ((bar == null) || (vector >= msix_mask.size()))
              return;
          bar.write_msix_reg(msix_table_bar_id, msix_table_base + vector * 16 + 32'hC, 4,
                             {31'h0, msix_mask[vector]});
      endtask

  ```
  `mask_vector` old：
  ```systemverilog
          msix_mask[vector] = 1;
          msix_table[vector].masked = 1;
          `uvm_info("NOTIFY_MGR",
              $sformatf("Masked MSI-X vector %0d", vector), UVM_HIGH)
  ```
  new：
  ```systemverilog
          msix_mask[vector] = 1;
          msix_table[vector].masked = 1;
          write_vector_control(vector);
          `uvm_info("NOTIFY_MGR",
              $sformatf("Masked MSI-X vector %0d", vector), UVM_HIGH)
  ```
  `unmask_vector` old：
  ```systemverilog
          msix_mask[vector] = 0;
          msix_table[vector].masked = 0;
          `uvm_info("NOTIFY_MGR",
              $sformatf("Unmasked MSI-X vector %0d", vector), UVM_HIGH)
  ```
  new：
  ```systemverilog
          msix_mask[vector] = 0;
          msix_table[vector].masked = 0;
          write_vector_control(vector);
          `uvm_info("NOTIFY_MGR",
              $sformatf("Unmasked MSI-X vector %0d", vector), UVM_HIGH)
  ```
  `mask_all` 循环体 old：
  ```systemverilog
              msix_mask[i] = 1;
              msix_table[i].masked = 1;
          end
          `uvm_info("NOTIFY_MGR", "All MSI-X vectors masked (function mask)", UVM_MEDIUM)
  ```
  new：
  ```systemverilog
              msix_mask[i] = 1;
              msix_table[i].masked = 1;
              write_vector_control(i);
          end
          `uvm_info("NOTIFY_MGR", "All MSI-X vectors masked (function mask)", UVM_MEDIUM)
  ```
  `unmask_all` 循环体 old：
  ```systemverilog
              msix_mask[i] = 0;
              msix_table[i].masked = 0;
          end
          `uvm_info("NOTIFY_MGR", "All MSI-X vectors unmasked", UVM_MEDIUM)
  ```
  new：
  ```systemverilog
              msix_mask[i] = 0;
              msix_table[i].masked = 0;
              write_vector_control(i);
          end
          `uvm_info("NOTIFY_MGR", "All MSI-X vectors unmasked", UVM_MEDIUM)
  ```
  文件中 “mask/unmask：只更新本地 msix_mask/msix_table.masked 影子位，供 on_interrupt_received 判定是否压制；
  不回写设备端 Vector Control 寄存器。” 改为 “mask/unmask：更新影子位并写回设备端 Vector Control 寄存器。”

  `virtio_config_backend.sv`（`virtio_common_cfg_backend::set_msix`）old：
  ```systemverilog
              // Unmask all vectors
              transport.notify_mgr.unmask_all();
  ```
  new：
  ```systemverilog
              // Unmask all vectors
              transport.notify_mgr.unmask_all();

              // MSI-X Enable 与 Function Mask 在 PCI 配置空间（能力 +2 的 Message Control）；
              // 设备只有看到 Enable=1、Function Mask=0 才会发 MSI-X。
              transport.bar.config_write({4'h0, transport.cap_mgr.msix_cap_offset},
                                         32'h8000_0000, 4'hc);
  ```
  old：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          transport.notify_mgr.mask_all();
          ok = 1;
      endtask
  ```
  new：
  ```systemverilog
      virtual task clear_msix(output bit ok);
          transport.notify_mgr.mask_all();
          if (transport.cap_mgr.has_msix())
              transport.bar.config_write({4'h0, transport.cap_mgr.msix_cap_offset},
                                         32'hc000_0000, 4'hc);
          ok = 1;
      endtask
  ```
  单测 `TEST=virtio_vdev_unit_test`：期望 `test_vip_msix_enables_device PASSED`。

- [ ] **Step 4: 回归并提交 VIP 修复**

  REGRESSION（此时 (c) 未改，fixture 仍用 responder；新增的配置写/表项写落到旧 EP 镜像，无副作用）；期望
  `STRICT_REGRESSION PASS tests=41`。
  ```bash
  git add virtio_net_vip/src/transport/virtio_notification_manager.sv \
      virtio_net_vip/src/transport/virtio_config_backend.sv \
      virtio_net_vip/tests/vdev_loopback_port.sv virtio_net_vip/tests/virtio_vdev_unit_test.sv
  git commit -m "fix: set_msix 打开设备 MSI-X 使能并把向量屏蔽位写回设备表项"
  ```
  随后做 Step 1(c)，运行 `TEST=virtio_real_driver_flow_test` 确认编译失败，再进入 Step 5。

- [ ] **Step 5: fixture 改接设备模型**

  `virtio_real_driver_flow_fixture.sv`：
  1. 删除整个 `virtio_feature_select_ep_driver` 类：从 `// 中文说明：MODEL 端点驱动只增加 virtio common-config 的 DFSELECT 语义：`
     到其 `endclass`（含其后空行）。
  2. old：`    virtio_pcie_dut_responder  responder;` new：
     ```systemverilog
         // MODEL 设备：每个 VIO PF 一个独立设备模型，经 vdev_uvm_ep_port 接在 EP driver 上。
         vdev_uvm_ep_port           device_port;
         vdev_virtio_pci            devices[];
     ```
  3. old：
     ```systemverilog
         // MODEL 端点镜像为每个 VIO PF 提供的 64 位 device features（按 DFSELECT
         // 分低/高 32 位返回）。缺省值保持原镜像行为（两个半字都是 0x1）；需要
         // 其它特性集合的测试在 build_phase 之前设置。
     ```
     new：
     ```systemverilog
         // MODEL 设备模型提供的 64 位 device features（缺省 CSUM|VERSION_1）；需要其它
         // 特性集合的测试在 build_phase 之前设置。
     ```
  4. 删除 `    protected bit                    m_responder_bound;` 与 `new()` 中的 `        m_responder_bound = 0;`。
  5. 删除 localparam 块：从 `    localparam bit [7:0] COMMON_CAP_OFFSET = 8'h50;` 到 `    localparam bit [31:0] MSIX_PBA_OFFSET = 32'h8000;`。
  6. `build_phase` old：
     ```systemverilog
                 pcie_tl_ep_driver::type_id::set_inst_override(
                     virtio_feature_select_ep_driver::get_type(), "pcie_env.*", this);
     ```
     new：
     ```systemverilog
                 pcie_tl_ep_driver::type_id::set_inst_override(
                     vdev_ep_driver::get_type(), "pcie_env.*", this);
     ```
     old：
     ```systemverilog
         // REAL_DUT 模式只保留 PCIe/virtio 观察路径，绝不创建主动模型。
         if (m_profile.has_model_device())
             responder = virtio_pcie_dut_responder::type_id::create(
                 "responder", this);
     endfunction
     ```
     new：
     ```systemverilog
         // REAL_DUT 模式只保留 PCIe/virtio 观察路径，绝不创建设备模型。
         if (m_profile.has_model_device()) begin
             device_port = vdev_uvm_ep_port::type_id::create("device_port");
             devices = new[vio_pf_count];
             foreach (devices[i])
                 devices[i] = vdev_virtio_pci::type_id::create($sformatf("vdev%0d", i), this);
         end
     endfunction
     ```
  7. `connect_phase`：把从 `        // Analysis connections must be established during connect_phase.  The` 到
     `        // REAL_DUT Host-memory responder must wait for the frozen snapshot's` 之前（不含）的整段替换为：
     ```systemverilog
         // MODEL 设备端口接到 EP driver/monitor 与平台 IOMMU；设备在 end_of_elaboration
         // 按冻结 snapshot 的 BDF 初始化后挂上端口。
         if ((m_profile != null) && m_profile.has_model_device() && (device_port != null)) begin
             string port_why;
             if (!device_port.connect_ep(m_pcie_env.ep_agent.ep_driver,
                                         m_pcie_env.ep_agent.monitor,
                                         m_virtio_env.iommu, virtio_cfg.host_id, port_why))
                 `uvm_error("REAL_FLOW", {"device port bind failed: ", port_why})
         end

     ```
  8. `end_of_elaboration_phase` old：
     ```systemverilog
         // MODEL mode owns a local endpoint image.  In REAL_DUT the endpoint
         // driver is passive/absent and all config/BAR responses come from RTL.
         if (m_profile.has_model_device()) begin
             if ((m_pcie_env.ep_agent.ep_driver == null) ||
                 !install_endpoint_image(why)) begin
                 `uvm_error("REAL_FLOW", {"endpoint image setup failed: ", why})
                 return;
             end
         end
     ```
     new：
     ```systemverilog
         // MODEL 由独立设备模型应答配置/MMIO；REAL_DUT 的配置/BAR 响应全部来自 RTL。
         if (m_profile.has_model_device() && !configure_devices(why)) begin
             `uvm_error("REAL_FLOW", {"device model setup failed: ", why})
             return;
         end
     ```
     再把从 `        if (m_profile.has_model_device() && (responder != null)) begin` 到
     `            m_pcie_env.cfg_mgr);`（含 `ep_driver_ref`/`cfg_mgr_ref` 两个 config_db 发布，它们只为旧镜像服务；
     `virtio_e2e_test` 自己发布）的整段删除，保留其后的 `        m_endpoint_ready = 1;`。
  9. 删除 `dut_responder()` 与 `model_responder_active()` 两个函数，在原 `dut_responder()` 位置加入：
     ```systemverilog
         // 冻结 snapshot 选中的 Function 对应的设备模型；REAL_DUT 返回 null。
         function vdev_virtio_pci device();
             foreach (devices[i])
                 if ((devices[i] != null) && (devices[i].bdf == m_pcie_id.bdf))
                     return devices[i];
             return null;
         endfunction
     ```
  10. `inject_rx` 整个 task（含上方 3 行注释）替换为：
     ```systemverilog
         // 设备网络侧入包（MODEL）：帧原样交给设备，设备在 RX 队列有 buffer 时自行生成
         // virtio-net header 并经 EP-originated PCIe DMA 写入。
         virtual task inject_rx(
             input int unsigned queue_id,
             input uvm_object pkt,
             ref bit ok
         );
             byte unsigned bytes[$];
             bit [7:0] frame[$];
             vdev_virtio_pci dev;

             ok = 0;
             dev = device();
             if ((dev == null) || (pkt == null) || ((queue_id % 2) != 0) ||
                 !virtio_net_packet_adapter::pack(pkt, bytes)) begin
                 `uvm_error("REAL_FLOW",
                            "inject_rx requires a MODEL device, an RX queue and a packable packet")
                 return;
             end
             foreach (bytes[i])
                 frame.push_back(bytes[i]);
             dev.inject_rx(queue_id / 2, frame);
             ok = 1;
         endtask
     ```
  11. `reset_and_teardown` old：
     ```systemverilog
         if (host_mem_responder != null)
             host_mem_responder.shutdown();
         if (responder != null)
             responder.stop();
         if (responder != null)
             responder.wait_stopped();
         if ((responder != null) && responder.running()) begin
             `uvm_error("REAL_FLOW", "responder workers remain after stop")
             return;
         end
     ```
     new：
     ```systemverilog
         if (host_mem_responder != null)
             host_mem_responder.shutdown();
     ```
     其上注释 “Quiesce responder/FSM workers first, then perform the verified normal” → “Quiesce FSM workers first
     (the device stops its own DMA when status is reset), then perform the verified normal”。
  12. 把从 `    protected function bit install_endpoint_image(output string why);` 到 `write_ep32` 函数的 `endfunction`
     （`install_endpoint_image`、`write_bar`、`register_virtio_caps`、`add_feature_window`、`write_common_defaults`、
     `write_ep16`、`write_ep32`）整段替换为：
     ```systemverilog
         // 每个 VIO Function 一个设备模型：BDF 取自冻结 snapshot，特性/队列取自本 fixture 配置；
         // BAR 基址由 VIP 的 Fabric 发现经配置写编程。snapshot 租约须容纳设备 BAR。
         protected function bit configure_devices(output string why);
             int unsigned k;
             dpu_bar_pair_lease_t bars[$];
             bit [63:0] need[int unsigned];

             why = "";
             if ((device_port == null) || (m_virtio_env == null) || (m_device_snapshot == null)) begin
                 why = "device port, virtio environment or snapshot is unavailable";
                 return 0;
             end
             need[0] = 64'h4000;
             need[2] = 64'h1000;
             need[4] = 64'h1_0000;
             k = 0;
             foreach (m_virtio_env.function_instances[index]) begin
                 virtio_function_instance f;
                 f = m_virtio_env.function_instances[index];
                 if ((f == null) || !f.pcie_id_valid)
                     continue;
                 if (k >= devices.size()) begin
                     why = "snapshot has more VIO functions than device models";
                     return 0;
                 end
                 if (!m_device_snapshot.list_bars(f.function_key, bars, why))
                     return 0;
                 foreach (bars[i])
                     if (need.exists(bars[i].even_bar_id) &&
                         (bars[i].size < need[bars[i].even_bar_id])) begin
                         why = $sformatf("BDF 0x%04h BAR%0d lease is smaller than the device BAR",
                                         f.bdf, bars[i].even_bar_id);
                         return 0;
                     end
                 devices[k].bdf = f.bdf;
                 devices[k].max_pairs = virtio_cfg.default_num_pairs;
                 devices[k].queue_max = virtio_cfg.default_queue_size;
                 devices[k].device_features = device_features;
                 devices[k].err_inj = m_virtio_env.err_inj;
                 devices[k].init();
                 device_port.attach(devices[k]);
                 k++;
             end
             if (k == 0)
                 why = "no VIO function resolved a PCIe identity";
             return k != 0;
         endfunction
     ```
  13. 注释同步（文字替换，不改代码）：`setup_queue` 上方 “the responder observes the resulting common-config writes”
     → “the device model receives the resulting common-config writes”；`complete_tx` 上方 “until the responder
     has processed the notify” → “until the device has processed the notify”；`receive_rx` 上方 “Wait for the
     responder's PCIe used-ring write” → “Wait for the device's PCIe used-ring write”；`execution_profile()` 上方
     “MODEL responder 计数” → “MODEL 设备计数”。

- [ ] **Step 6: 删除 responder 与相关注释**
  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  git rm virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv
  ```
  `virtio_net_pkg.sv` 删除行 `  \`include "pcie/virtio_pcie_dut_responder.sv"`。
  `virtio_execution_profile.sv` old：
  ```systemverilog
      // 是否由本地 MODEL 扮演设备：创建 TLM completion adapter、EP responder，
      // 安装端点配置镜像并用 MODEL DMA adapter 产生设备侧 DMA。
  ```
  new：
  ```systemverilog
      // 是否由本地 MODEL 扮演设备：创建 TLM completion adapter 与独立设备模型
      // （vdev_virtio_pci 经 vdev_uvm_ep_port 应答配置/MMIO 并发起设备侧 DMA）。
  ```
  old：`// 无 RTL DUT：VIP 的 responder 扮演设备，PCIe 走 TLM 回环。`
  new：`// 无 RTL DUT：独立设备模型扮演设备，PCIe 走 TLM 回环。`
  `virtio_net_types.sv` old：`// model responder or a REAL_DUT Host-memory fault provider.  ANY preserves a`
  new：`// device model (vdev_base::take_fault) or a REAL_DUT fault provider.  ANY preserves a`。

- [ ] **Step 7: 运行并按规则处理暴露的问题**

  单测依次：`virtio_vdev_unit_test`、`virtio_real_driver_flow_test`、`virtio_real_driver_rx_test`、
  `virtio_real_driver_multiqueue_test`、`virtio_full_integration_test`、`virtio_dual_test`。期望三行汇总为 0，
  日志分别含原有 PASS 文案（`real-driver net_packet RX PASSED`、`real-driver net_packet multi-queue TX PASSED`、
  `OVERALL: PASS`）。

  失败时逐条判定（规范“风险”表规则，不放宽断言）：

  | 现象 | 判定 | 处理 |
  |---|---|---|
  | `interrupt_count()` 不增长 | VIP 缺陷（Step 3 已修） | — |
  | `VDEV_QUEUE` “enable rejected: queue_xxx not written / FEATURES_OK not set” | VIP 漏写/错序 | 修 VIP 对应写序列，在 `virtio_vdev_unit_test` 用 `vdev_loopback_bar_accessor`+`virtio_common_cfg_backend` 复现后再修 |
  | `VDEV_QUEUE` “ignored notify … before DRIVER_OK / disabled” | VIP 在不允许时 kick | 同上 |
  | `VDEV_RING` 链非法 | VIP 构链错误 | 同上 |
  | `VDEV_RX` 丢帧 | 测试 RX buffer 小于 header+帧 | 改测试输入（buffer 尺寸），不改断言 |
  | 断言依赖旧 responder 的偷看行为（例如忽略 `VIRTQ_AVAIL_F_NO_INTERRUPT` 仍发中断） | 测试依赖 responder | 改测试输入使其满足协议（例如不置 NO_INTERRUPT），不改断言 |
  | `num_queues` 读回 5（含 ctrl VQ） | 设备正确（旧镜像漏了 ctrl VQ） | 无 |

  每个新增 VIP 修复单独提交：`fix: <中文描述>`，并在 `virtio_vdev_unit_test` 增加对应失败用例。

- [ ] **Step 8: 删除证据**
  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -rn 'virtio_pcie_dut_responder\|dut_responder\|virtio_feature_select_ep_driver\|install_endpoint_image\|model_responder_active\|m_responder_bound' \
      virtio_net_vip examples scripts filelists --include=*.sv --include=*.svh --include=*.f --include=*.sh
  ```
  期望无输出（README/手册/验证流程在 D6 处理）。

- [ ] **Step 9: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=41`。

- [ ] **Step 10: 提交**
  ```bash
  git add -A virtio_net_vip/src virtio_net_vip/tests
  git commit -m "refactor: 真实驱动流程改由独立设备模型 vdev_virtio_pci 应答，删除 virtio_pcie_dut_responder"
  ```

---
### Task D4: 私有设备 `vdev_dpu_priv`（规范 R4，驱动寄存器序列）

**依据：** 53 `/home/ubuntu/wn/icpu-kernel-driver`（`lance_net_mailbox@f2c9cd6`，只读，本地副本 md5 一致）与
dpu_common `4d73996` reg plan（`dpu_device_bootstrap_plan_builder.sv`、`dpu_vio_dataplane_plan_extension.sv`）。
驱动读 BAR2 qinfo `host_id`（`{pfvf_id[6:0], host_id[9:7]}`，main.c:2020）：`pfvf_id==0` 走 **AF 路径**（驱动直接
在 BAR0 写芯片表），否则走 PF 路径（全部经 mailbox 消息请求 AF）。单个 20f9:5013 设备 + cosim 只有 AF 路径可行，
本模型报告 `pfvf_id=0`，只建模 AF 路径；PF/VF mailbox 消息协议不建模（疑点 M-8）。

**驱动寄存器序列（AF 路径，1 个队列对：RX lqid 0 / TX lqid 1，全局队列 gq=0，gfid=0，向量 gv 从 0 分配）**

| # | 阶段 | 驱动位置 | 区 | 偏移 | 访问 | 值 / 语义 | 设备模型 | VIP 后端（D5） |
|---|---|---|---|---|---|---|---|---|
| 1 | probe | pci_enable_device/set_master | cfg | CMD | W | MEM、BME | wmask | 平台 |
| 2 | probe | dpu_probe main.c:2020 | BAR2 | 0x0C | R | `{pfvf_id[6:0], host_id[9:7]}` | 只读，pfvf=0 | discover |
| 3 | AF | af_soft_reset_fe main.c:1914 | BAR0 | 0x1000014 | W,W | 7，msleep 5，0 | 非 0 写清数据面状态（M-1） | discover |
| 4 | AF | main.c:2027 | BAR0 | 0x1010 | R | bit3 须为 0 | 读回 0x20040 | discover |
| 5 | AF | main.c:2035 | BAR0 | 0x1010 | W | 0x5555AAAA | 置 0x20040=`{1,host}` | discover |
| 6 | AF | main.c:2040 | BAR0 | 0x1010 | R | 须为 `8\|host` | 同 #4 | discover |
| 7 | AF | main.c:2052 | BAR0 | 0x60040 | W | `(v&7)\|8`（INTF_MB_AF_HOST_ID） | 存储 | discover |
| 8 | all | main.c:2124 | BAR0 | 0x1010 | R | 须 bit3 | 同 #4 | discover |
| 9 | AF | 芯片初始化（split horizon、fw init 轮询 0x1000020 bit31、rx_mtu、pause、res_mng、rss_alg、macvlan、QSCH 0xB00100、l3mc、fec） | BAR0 | 多处 | R/W | 与数据队列无关 | 通用寄存器存储；0x1000020 读 bit31=1 | 不做（D-2） |
| 10 | all | dpu_mailbox_cfg_bdf mailbox.c:441 | BAR2 | 0x04 | W | `1<<16 \| bdf` | 存储 | discover |
| 11–15 | all | mailbox 队列 reset/config/tail/enable mailbox.c:158–372 | BAR2 | 0x2C/0x1C/0x20–0x28/0x10–0x18/0x00 | W | mailbox 环 | 存储，不处理消息 | 不做（D-3） |
| 16 | AF | af_configure_func_msix_map af_mng.c:695 | BAR0 | 0xC0000+((srcid<<7)+i)*4，i<needed | W | `gv_i \| 1<<11`；needed=num_lan+1+13 | 线性表：CQ 中断反查本地向量 | discover（gv_i=i） |
| 17 | AF | af_mng.c:703 | BAR0 | 0x56000+gfid*4 | W | `bdf \| 1<<16` | 存储 | discover |
| 18 | all | init_interrupt_scheme（内核） | cfg+BAR4 | MSI-X | W | 内核 | 底座 MSI-X | 不做（VIP 私有固定 polling） |
| 19 | AF | af_enable_mailbox_irq mailbox.c:708,717 | BAR0 | 0x54000+gv_mb*4；0x68000+srcid*16 ×4 | W | mailbox 中断 | 存储 | 不做（D-3） |
| 20 | all | dpu_read_real_bar_base_addr main.c:938,941 | cfg | 0x10/0x14 | R | BAR0 物理地址 = notify 地址 | — | discover |
| 21 | AF | fill_qid_map_table af_mng.c:872–899 | BAR0 | 0x28000+bank*0x4000+i*16（i<128）×4 DW；0x20044 | W,R | 有效项 DW0=`{addr[31:7],blk,lq[4:0],net=1}`、DW1=`{host[2:0],addr[60:32]}`、DW2=`gq[10:0]`、DW3=0；无效项 `FFFFFFFF,FFFFFFFF,7FF,0`；每项写后读回；最后 0x20044=`rdy\|bank<<1` 写后读回 | doorbell 路由（活动 bank、notify 地址=本 BAR0、lq/blk=lqid>>1） | discover（有效项=本 Function 队列对，gq=对号） |
| 22 | AF | add_vnet/queue_2_qsch main.c:1185,1133 | BAR0 | 0xB12000/0xB11000/0xB10000/0xB13000 | W | QSCH 映射 | 存储 | 不做（D-2） |
| 23 | probe | MAC/VLAN/SR-IOV/固件版本（AF 内部或 mailbox） | — | — | — | — | — | 不做 |
| 24 | open | dpu_af_hw_config_tx_ring af_mng.c:1406–1419 | BAR0 | 0x880134–0x880140；0x880130；0x890000+q*16 | W×4；W,W；R×4 | VTX 参数（DW2：q_depth[3:0]、queue_en[4]=0、virtio_mode[5]=0、seg_en[7]=1、sport_type[14:12]=host、dma_msix[25:15]=gv；DW3 sport_id=gfid）；ram_cfg 写 `q` 再 `q\|0x2000`；读回比较 desc_addr | VTX 表（`wr_enable[13]` 且 `selector[12]=0` 时写入） | configure_queue(TX) |
| 25 | open | dpu_af_hw_config_rx_ring af_mng.c:1310,1360–1368 | BAR0 | 0x902000+q*4；0x900204–0x90020C；0x900200 | R；W×3；W,W | 读 [15:0] 须 0x8000；VRX 参数（DW2：q_depth、queue_en[4]=1、dport_type[8:6]=host、dport_id[18:9]=gfid、dma_msix[29:19]=gv）；wr_cfg 写 `q` 再 `0x10000\|q` | VRX 表；tail 寄存器复位值 0x8000 | configure_queue(RX) |
| 26 | open | af_configure_rss_group_table af_mng.c:1697–1703 | BAR0 | 0x4A0020；0x4A9000+… | W | RSS | 存储 | 不做（D-2） |
| 27 | open | dpu_af_configure_msix_irq interrupt.c:386,389 | BAR0 | 0x54000+gv*4；0x48000+gv*16+0xC | W；W | `gfid\|host<<8\|self_mask(1)<<11\|valid<<12`；0（解除全局屏蔽） | CQ 中断门控与自屏蔽 | enable_queue(RX) |
| 28 | open | dpu_af_control_tx_queue af_mng.c:1598–1612 | BAR0 | 0x890000+q*16；0x880134–40；0x880130 | R×4；W×4；W,W | 读回后置 queue_en=1 | 同 #24 | enable_queue(TX) |
| 29 | open | dpu_alloc_rx_bufs txrx.c:964 | BAR0 | 0x0 | W | `1<<31 \| 511<<16 \| 0`=0x81FF0000 | RX doorbell | ops RX 补充后的 notify（tail 取补充数） |
| 30 | open | up_complete | BAR0 | 0x4AA000+gfid*4 RMW | R/W | vport fwd | 存储 | 不做 |
| 31 | TX | dpu_tx_map txrx.c:1492 | BAR0 | 0x0 | W | `wrap[31]\|tail[30:16]\|lqid[15:0]`，1 包=0x80010001 | TX doorbell | notify_queue |
| 32 | IRQ | dpu_enable_msix_irq interrupt.c:276 | BAR0 | 0x1004 | W | `gv<<1`（mask_en=0）解除自屏蔽 | 解除 gv 自屏蔽 | 不做（polling） |
| 33 | stop | dpu_down：control_tx(en=0)、reset_tx txrx.c:382–524、control_rx(en=0) af_mng.c:1570–1589、reset_rx txrx.c:543–550、clear_msix_irq_conf interrupt.c:234 | BAR0 | TX：#28 置 en=0；轮询 0xB22000+q*4 [11:9]=0；0x880100 写 `q`、`q\|1<<31`；轮询 0x880104 bit0；0x880154 写 `q\|1<<16`、`\|1<<31`；轮询 0x880158 bit0。RX：0x900210 写 `i<<14\|q`、`\|0x10000` 后读 0x900214（i=0..3）；写回 en=0；0x900200 `q`、`0x10000\|q`；0x90010C 写 0；0x900108 `q`、`q\|1<<31`；轮询 0x90010C bit0；0x54000+gv*4 写 0 | 见左 | 停队/复位完成位；`stall_queue_stop` 旋钮使完成位永不置位、QSCH 报在途 | disable_queue / reset（先全部 TX 再全部 RX） |
| 34–38 | remove | qid map 失效重写 + 0x20044、QSCH 删除、mailbox 中断关闭、清 0x56000/0xC0000、BAR2 0x2C/0x1C 拆除、0x60040=0、0x20040=0 | BAR0/BAR2 | — | W | rmmod | 存储（0x20040 写 0 即解除声明） | 不做（VIP 无 rmmod 对应，F 阶段 S4 判定） |

**描述符/CQ/doorbell（与 C1 `dpu_priv_virtqueue` 一致）：** 16B 描述符 `addr[63:0]`；W1 `len[17:0]、dport_info[29:18]、
dport_id_l[31:30]`；W2 `dport_id_h[7:0]、dport_type[10:8]、rss_lag[11]、cpu_tx_cos[14:12]、dtype[15]、next[16]、l3_cs[17]、
l4_cs[18]、fwd[20:19]、avail[23]、used[31]`（驱动写 avail=wrap、used=!wrap）。TX ring：N×16B 描述符 + CQ（u16 `head_index[14:0]、
wrap[15]`，初值 0x8000）；RX ring：N×16B 描述符 + N×16B CQ（DW0 `desc_num[31:28]`；DW1 `head_idx[15:0]、pkt_len[29:16]、
csum_status[30]、cq_wrapper[31]`）。doorbell BAR0+0 共享，`wrap[31]|tail[30:16]|lqid[15:0]`，RX lqid=2i，TX lqid=2i+1。

**疑点（驱动与 reg plan、模型推断）：**
- D-1 reg plan `dpu_vio_pack_vtx_ram_cfg` 把 selector 放 bit13、wr_enable 放 bit14，写 `q|0x2000` 再 `q|0x6000`；驱动结构
  `ram_selector:1@12`（PARA=0）、`wr_enable@13`，写 `q` 再 `q|0x2000`。模型按驱动。
- D-2 reg plan 缺：#3 软复位、#8 第二次 0x1010 读、#25 VRX tail 检查、#24 读回、TX 先 en=0 再 RMW 置 1、#27 self_mask=1 与
  0x48000+0xC 解除屏蔽；多出：0x60040 读回、MSIX_INTERVAL(0x52000) 写；默认 `msix_self_mask=0` 与驱动队列向量的 1 不同。
  VIP 后端不做 #9/#22/#26/#30（与数据队列无关的芯片表），F 阶段对比时列白名单。
- D-3 reg plan 以 2×64 位写 qid map，驱动是 4×32 位写 + 读回并重写全部 128 项。VIP 后端不建 mailbox 环（#11–15、#19）。
- D-4 f2c9cd6 把 srcid 改成 `host<<10`：host_id=1 时 `MSIX_LINEAR_TBL_ENTRY((srcid<<7)+i)` 落到 0x140000+（INTF_PCONFIG），
  `MBL_MAP_TBL_E_ADDR(srcid)` 落到 0x6C000；reg plan 复制了同样溢出。模型按同一公式解码（一致即可路由）。
- D-5 G2P `src_port` 为 1 位，驱动赋 host+2 被截断（plan 同样截断）。
- D-6 发给 AF 的 RX buf_len=2048，而描述符 len≈1664（≥5.12 内核）。模型按描述符 len 填充。
- D-7 AF 路径 RSS 用不带 pfvf 的 srcid；`dpu_control_queue` 用 ecpu_host_id 而复位用 host_id。
- D-8 `dpu_reset_rx_queue` 恒返回 0。
- D-9 TX 首描述符 len=skb->len 后被 headlen 覆盖；l3/l4_cs 只在清理时复位。
- D-10 ST 模式判断 `srcid>=MIN || srcid<=MAX` 恒真（默认 fabric_mode 无害）。
- D-11 无 SR-IOV 能力时 pos=0，驱动读标准头 0x14/0x16/0x24/0x28 并照常发 REGISTER_VF_BAR_INFO/CFG_VFS_BDF。
- M-1 0x1000014 软复位的芯片语义不明：模型只清数据面（VTX/VRX 表、环运行态、自屏蔽），保留其它寄存器与 AF 声明。
- M-2 doorbell → 全局队列：按活动 bank 中 notify 地址=本 BAR0、`{blk,lq}=lqid>>1` 的有效项取 gq，`lqid bit0` 为方向（驱动未写明，推断）。
- M-3 VRX tail 寄存器（0x902000+q*4）在 doorbell 后的值不明：模型返回 `{tail_wrap,tail}`，复位后 0x8000。
- M-4 完成信号：先写 CQ，再按 VTX/VRX `dma_msix`→info 表（valid、self_mask）→线性表反查本地 MSI-X 向量；self_mask=1 时发出后
  自屏蔽，0x1004 写 `gv<<1` 解除（推断）。
- M-5 TX CQ `head_index` 为最后完成描述符的下一槽、`wrap` 为该位置的圈号（驱动只比较 head_index，wrap 读而不用）。
- M-6 QSCH 状态 0xB22000+q*4 的 vld/fly/regi（bit11/10/9）：模型空闲为 0，`stall_queue_stop` 时报 bit10。
- M-7 RX 一帧跨多个描述符（desc_num≤15，`head_idx`=首描述符号）；驱动只用 pkt_len 与 cq_wrapper。
- M-8 PF/VF mailbox 路径未建模；qinfo 恒报 `pfvf_id=0`。
- M-9 全局资源分配：设备全新时驱动从 0 分配 gq/gfid/gv；VIP 后端取 gq=gv=队列对号（`local_qid>>1`）、gfid=0。

**Files:**
- Create: `virtio_net_vip/src/devmodel/vdev_dpu_priv.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`、`virtio_net_vip/tests/virtio_vdev_unit_test.sv`
- Test: `virtio_vdev_unit_test`

**Interfaces:**
- Produces: `class vdev_dpu_priv extends vdev_base`；参数 `host_id`（qinfo 报告的 host，默认 0）、`stall_queue_stop`
  （测试旋钮：队列复位永不完成、QSCH 报在途）；观察接口 `function bit queue_enabled(bit tx, int unsigned gq)`。
  工作项编码 `2*gq + tx`；事件 q：`notify` 用驱动写的 lqid，其余数据事件用 `2*gq+dir`（gq=队列对号时与 lqid 相同）。
  `queue_cfg.ring_fmt="priv"`。

- [ ] **Step 1: 写失败测试（按驱动顺序的原始 MMIO 序列）**

  `virtio_vdev_unit_test.sv` localparam 区 old：
  ```systemverilog
      localparam bit [63:0] STD_BAR4  = 64'h0000_0041_0002_0000;
  ```
  new：
  ```systemverilog
      localparam bit [63:0] STD_BAR4  = 64'h0000_0041_0002_0000;
      localparam bit [15:0] PRIV_BDF  = 16'h0500;
      localparam bit [63:0] PRIV_BAR0 = 64'h0000_0042_0000_0000;
      localparam bit [63:0] PRIV_BAR2 = 64'h0000_0042_0200_0000;
      localparam bit [63:0] PRIV_BAR4 = 64'h0000_0042_0201_0000;
  ```
  字段 old：`    virtio_vq_test_kit    std_kit;` new：
  ```systemverilog
      virtio_vq_test_kit    std_kit;
      vdev_dpu_priv         priv;
      vdev_event_log        priv_log;
  ```
  `build_phase` old：
  ```systemverilog
          std_log = vdev_event_log::type_id::create("std_log", this);
      endfunction
  ```
  new：
  ```systemverilog
          std_log = vdev_event_log::type_id::create("std_log", this);
          priv = vdev_dpu_priv::type_id::create("priv", this);
          priv_log = vdev_event_log::type_id::create("priv_log", this);
      endfunction
  ```
  `connect_phase` old：`        std.event_ap.connect(std_log.analysis_export);` new：
  ```systemverilog
          std.event_ap.connect(std_log.analysis_export);
          priv.event_ap.connect(priv_log.analysis_export);
  ```
  在 `virtual task run_phase` 之前加入：
  ```systemverilog
      protected function void priv_wr(bit [31:0] off, bit [31:0] data);
          port.host_write(PRIV_BAR0 + off, 4, data);
      endfunction

      protected function bit [31:0] priv_rd(bit [31:0] off);
          return port.host_read(PRIV_BAR0 + off, 4);
      endfunction

      // 驱动 txrx.h 的 16B 描述符：addr、W1.len、W2.fwd=1、avail=wrap、used=!wrap、next。
      protected function void priv_desc(bit [63:0] slot_gpa, bit [63:0] buf_iova, int unsigned len,
                                        bit wrap, bit next_bit);
          byte d[];
          bit [31:0] w1;
          bit [31:0] w2;

          d = new[16];
          w1 = len[17:0];
          w2 = 0;
          w2[16] = next_bit;
          w2[20:19] = 2'd1;
          w2[23] = wrap;
          w2[31] = ~wrap;
          for (int i = 0; i < 8; i++)
              d[i] = buf_iova[8*i +: 8];
          for (int i = 0; i < 4; i++) begin
              d[8 + i] = w1[8*i +: 8];
              d[12 + i] = w2[8*i +: 8];
          end
          mem.write_mem(slot_gpa, d);
      endfunction

      protected function void expect_mem(bit [63:0] gpa, byte golden[], string label);
          byte got[];

          mem.read_mem(gpa, golden.size(), got);
          foreach (golden[i])
              if (got[i] !== golden[i])
                  `uvm_fatal("VDEV_UNIT", $sformatf("%s byte[%0d]=%02h expected %02h", label, i, got[i], golden[i]))
      endfunction

      // 驱动 AF 路径（D4 表 #2–#8、#10、#16、#17、#21、#24、#25、#27、#28、#29、#31、#32、#33）的原始寄存器序列
      // 驱动私有设备：校验 AF 声明、qid map 路由、VTX/VRX 参数表、TX/RX CQ 黄金字节、MSI-X 自屏蔽与停队完成位。
      task test_priv_driver_sequence();
          bit [31:0] v;
          bit [31:0] para[4];
          bit [31:0] srcid;
          bit [2:0] host;
          bit [7:0] cap;
          bit [63:0] tx_gpa, tx_ring, rx_gpa, rx_ring, f_gpa, f_iova, r0_gpa, r0_iova, r1_gpa, r1_iova;
          byte frame[];
          byte cq_tx1[] = '{8'h01, 8'h80};
          byte cq_tx2[] = '{8'h02, 8'h80};
          byte cq_rx0[] = '{8'h00, 8'h00, 8'h00, 8'h10, 8'h00, 8'h00, 8'h40, 8'h80,
                            8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
          byte cq_rx1[] = '{8'h00, 8'h00, 8'h00, 8'h10, 8'h01, 8'h00, 8'h40, 8'h80};
          int unsigned irq0;
          vdev_event ev[$];
          vdev_expect_catcher catcher;

          priv.bdf = PRIV_BDF;
          priv.host_id = 1;
          priv.init();
          port.attach(priv);
          program_bars(PRIV_BDF, PRIV_BAR0, PRIV_BAR2, PRIV_BAR4);
          if (port.host_cfg_read(PRIV_BDF, 12'h000) != 32'h5013_20f9)
              `uvm_fatal("VDEV_UNIT", "private device ID mismatch")
          // probe
          v = port.host_read(PRIV_BAR2 + 32'h0c, 4);
          if ((v[6:0] != 0) || (v[9:7] != 1))
              `uvm_fatal("VDEV_UNIT", "qinfo host_id must report pfvf_id 0 and host 1")
          host = v[9:7];
          priv_wr(32'h100_0014, 32'h7);
          priv_wr(32'h100_0014, 32'h0);
          if (priv_rd(32'h1010) & 32'h8)
              `uvm_fatal("VDEV_UNIT", "fresh device reports AF already declared")
          priv_wr(32'h1010, 32'h5555_aaaa);
          v = priv_rd(32'h1010);
          if (v != {28'h0, 1'b1, host})
              `uvm_fatal("VDEV_UNIT", $sformatf("AF declaration readback 0x%08h", v))
          priv_wr(32'h6_0040, (v & 32'h7) | 32'h8);
          if (!(priv_rd(32'h1010) & 32'h8))
              `uvm_fatal("VDEV_UNIT", "AF declaration lost")
          port.host_write(PRIV_BAR2 + 32'h04, 4, (32'h1 << 16) | PRIV_BDF);
          srcid = host << 10;
          for (int unsigned i = 0; i < 15; i++)
              priv_wr(32'hc_0000 + 4 * ((srcid << 7) + i), (32'h1 << 11) | i);
          priv_wr(32'h5_6000, (32'h1 << 16) | PRIV_BDF);
          priv_wr(32'h2_8000, {PRIV_BAR0[31:7], 1'b0, 5'd0, 1'b1});
          priv_wr(32'h2_8004, {host, PRIV_BAR0[60:32]});
          priv_wr(32'h2_8008, 32'h0);
          priv_wr(32'h2_800c, 32'h0);
          priv_wr(32'h2_0044, 32'h1);
          // open：N=8 的 TX/RX ring（各 4 KiB，清零；TX CQ 初值 0x8000）
          tx_ring = map_buffer(PRIV_BDF, 4096, DMA_BIDIRECTIONAL, tx_gpa);
          rx_ring = map_buffer(PRIV_BDF, 4096, DMA_BIDIRECTIONAL, rx_gpa);
          mem.mem_set(tx_gpa, 0, 4096);
          mem.mem_set(rx_gpa, 0, 4096);
          frame = new[2];
          frame[0] = 8'h00;
          frame[1] = 8'h80;
          mem.write_mem(tx_gpa + 128, frame);
          priv_wr(32'h88_0134, tx_ring[31:0]);
          priv_wr(32'h88_0138, tx_ring[63:32]);
          priv_wr(32'h88_013c, (host << 12) | (32'h1 << 7) | 32'h3);
          priv_wr(32'h88_0140, 32'h0);
          priv_wr(32'h88_0130, 32'h0);
          priv_wr(32'h88_0130, 32'h2000);
          if ((priv_rd(32'h89_0000) != tx_ring[31:0]) || (priv_rd(32'h89_0004) != tx_ring[63:32]))
              `uvm_fatal("VDEV_UNIT", "VTX parameter readback mismatch")
          if (priv_rd(32'h90_2000) != 32'h8000)
              `uvm_fatal("VDEV_UNIT", "VRX tail must read 0x8000 before configuration")
          priv_wr(32'h90_0204, rx_ring[31:0]);
          priv_wr(32'h90_0208, rx_ring[63:32]);
          priv_wr(32'h90_020c, (host << 6) | (32'h1 << 4) | 32'h3);
          priv_wr(32'h90_0200, 32'h0);
          priv_wr(32'h90_0200, 32'h1_0000);
          priv_wr(32'h5_4000, (32'h1 << 12) | (32'h1 << 11) | (host << 8));
          priv_wr(32'h4_800c, 32'h0);
          // 内核为本地向量 0 编程 MSI-X 并使能
          port.host_write(PRIV_BAR4 + 0, 4, 32'hfee0_1000);
          port.host_write(PRIV_BAR4 + 4, 4, 32'h0);
          port.host_write(PRIV_BAR4 + 8, 4, 32'h500);
          port.host_write(PRIV_BAR4 + 12, 4, 32'h0);
          cap = find_cap(PRIV_BDF, 8'h11);
          port.host_cfg_write(PRIV_BDF, {4'h0, cap}, 32'h8000_0000, 4'hc);
          for (int unsigned i = 0; i < 4; i++)
              para[i] = priv_rd(32'h89_0000 + 4*i);
          para[2][4] = 1;
          for (int unsigned i = 0; i < 4; i++)
              priv_wr(32'h88_0134 + 4*i, para[i]);
          priv_wr(32'h88_0130, 32'h0);
          priv_wr(32'h88_0130, 32'h2000);
          priv_log.select(VDEV_QUEUE_CFG, ev);
          if ((ev.size() != 2) || (ev[0].q != 0) || (ev[1].q != 1) || (ev[1].size != 8) ||
              (ev[1].vector != 0) || (ev[1].ring_fmt != "priv"))
              `uvm_fatal("VDEV_UNIT", "VRX/VTX enable did not emit queue_cfg for lqid 0 and 1")
          // RX 补两个 2048B buffer，doorbell tail=2
          r0_iova = map_buffer(PRIV_BDF, 2048, DMA_FROM_DEVICE, r0_gpa);
          r1_iova = map_buffer(PRIV_BDF, 2048, DMA_FROM_DEVICE, r1_gpa);
          priv_desc(rx_gpa, r0_iova, 2048, 1, 0);
          priv_desc(rx_gpa + 16, r1_iova, 2048, 1, 0);
          priv_wr(32'h0, 32'h8002_0000);
          // TX 一帧 64B
          frame = new[64];
          foreach (frame[i])
              frame[i] = i + 1;
          f_iova = map_buffer(PRIV_BDF, 64, DMA_TO_DEVICE, f_gpa);
          mem.write_mem(f_gpa, frame);
          irq0 = port.msix_addr.size();
          priv_desc(tx_gpa, f_iova, 64, 1, 0);
          priv_wr(32'h0, 32'h8001_0001);
          settle();
          expect_mem(tx_gpa + 128, cq_tx1, "TX CQ after one packet");
          expect_mem(rx_gpa + 128, cq_rx0, "RX CQ entry 0");
          expect_mem(r0_gpa, frame, "RX buffer 0");
          // TX 与 RX 共用 gv0：TX 完成发一次后自屏蔽，RX 完成不再发
          if ((port.msix_addr.size() != irq0 + 1) || (port.msix_data[irq0] != 32'h500))
              `uvm_fatal("VDEV_UNIT", "CQ completion did not raise exactly one self-masked MSI-X")
          priv_wr(32'h1004, 32'h0);
          priv_desc(tx_gpa + 16, f_iova, 64, 1, 0);
          priv_wr(32'h0, 32'h8002_0001);
          settle();
          expect_mem(tx_gpa + 128, cq_tx2, "TX CQ after two packets");
          expect_mem(rx_gpa + 128 + 16, cq_rx1, "RX CQ entry 1");
          if (port.msix_addr.size() != irq0 + 2)
              `uvm_fatal("VDEV_UNIT", "0x1004 re-arm did not allow the next MSI-X")
          priv_log.select(VDEV_PKT, ev);
          if ((ev.size() != 4) || (ev[0].dir != "tx") || (ev[0].q != 1) || (ev[1].dir != "rx") ||
              (ev[1].q != 0) || (ev[1].bytes.size() != 64))
              `uvm_fatal("VDEV_UNIT", "pkt events do not show TX loopback into RX")
          // stop：TX
          for (int unsigned i = 0; i < 4; i++)
              para[i] = priv_rd(32'h89_0000 + 4*i);
          para[2][4] = 0;
          for (int unsigned i = 0; i < 4; i++)
              priv_wr(32'h88_0134 + 4*i, para[i]);
          priv_wr(32'h88_0130, 32'h0);
          priv_wr(32'h88_0130, 32'h2000);
          if (priv_rd(32'hb2_2000) & 32'h0e00)
              `uvm_fatal("VDEV_UNIT", "idle TX queue reports in-flight QSCH state")
          priv_wr(32'h88_0100, 32'h0);
          priv_wr(32'h88_0100, 32'h8000_0000);
          v = priv_rd(32'h88_0104);
          if (!v[0])
              `uvm_fatal("VDEV_UNIT", "TX queue reset did not complete")
          priv_wr(32'h88_0154, 32'h1_0000);
          priv_wr(32'h88_0154, 32'h8001_0000);
          v = priv_rd(32'h88_0158);
          if (!v[0])
              `uvm_fatal("VDEV_UNIT", "TX tail reset did not complete")
          catcher = new("priv_doorbell_catcher");
          catcher.id = "VDEV_DPU_PRIV";
          catcher.text = "has no enabled TX queue";
          uvm_report_cb::add(null, catcher);
          priv_wr(32'h0, 32'h8003_0001);
          uvm_report_cb::delete(null, catcher);
          if (catcher.caught != 1)
              `uvm_fatal("VDEV_UNIT", "doorbell for a disabled TX queue was accepted")
          // stop：RX，先以旋钮制造“DMA 不停”，复位完成位必须保持 0
          priv.stall_queue_stop = 1;
          for (int unsigned i = 0; i < 4; i++) begin
              priv_wr(32'h90_0210, (i << 14));
              priv_wr(32'h90_0210, (i << 14) | 32'h1_0000);
              para[i] = priv_rd(32'h90_0214);
          end
          if ({para[1], para[0]} != rx_ring)
              `uvm_fatal("VDEV_UNIT", "VRX indirect read did not return the descriptor address")
          para[2][4] = 0;
          for (int unsigned i = 0; i < 3; i++)
              priv_wr(32'h90_0204 + 4*i, para[i]);
          priv_wr(32'h90_0200, 32'h0);
          priv_wr(32'h90_0200, 32'h1_0000);
          priv_wr(32'h90_010c, 32'h0);
          priv_wr(32'h90_0108, 32'h0);
          priv_wr(32'h90_0108, 32'h8000_0000);
          v = priv_rd(32'h90_010c);
          if (v[0] || priv.queue_enabled(0, 0))
              `uvm_fatal("VDEV_UNIT", "stalled RX reset reported completion or left VRX enabled")
          priv.stall_queue_stop = 0;
          priv_wr(32'h90_0108, 32'h0);
          priv_wr(32'h90_0108, 32'h8000_0000);
          v = priv_rd(32'h90_010c);
          if (!v[0] || (priv_rd(32'h90_2000) != 32'h8000))
              `uvm_fatal("VDEV_UNIT", "RX reset did not complete or restore the VRX tail")
          priv_wr(32'h5_4000, 32'h0);
          iommu.unmap_for_host(0, PRIV_BDF, tx_ring);
          iommu.unmap_for_host(0, PRIV_BDF, rx_ring);
          iommu.unmap_for_host(0, PRIV_BDF, f_iova);
          iommu.unmap_for_host(0, PRIV_BDF, r0_iova);
          iommu.unmap_for_host(0, PRIV_BDF, r1_iova);
          mem.free(tx_gpa);
          mem.free(rx_gpa);
          mem.free(f_gpa);
          mem.free(r0_gpa);
          mem.free(r1_gpa);
          `uvm_info("VDEV_UNIT", "test_priv_driver_sequence PASSED", UVM_LOW)
      endtask
  ```
  `run_phase` old：
  ```systemverilog
          test_vip_msix_enables_device();
          mem.leak_check();
  ```
  new：
  ```systemverilog
          test_vip_msix_enables_device();
          test_priv_driver_sequence();
          mem.leak_check();
  ```

- [ ] **Step 2: 运行，确认失败**

  `TEST=virtio_vdev_unit_test`：期望编译失败，`Error-` 指出 `vdev_dpu_priv` 未声明。

- [ ] **Step 3: 新建 `src/devmodel/vdev_dpu_priv.sv`**

  文件头注释：把上面“驱动寄存器序列”表（不含“VIP 后端”列）、描述符/CQ/doorbell 布局与全部疑点（D-1..D-11、M-1..M-9）
  以 `//` 注释原样写入，置于 `` `ifndef VDEV_DPU_PRIV_SV `` 之前，开头两行为：
  ```systemverilog
  // 目录层次：virtio_net_vip/src/devmodel；DPU 私有 NIC 设备模型（20f9:5013），行为依据 icpu-kernel-driver
  // lance_net_mailbox@f2c9cd6 的 AF 路径，寄存器名取 dpu_common reg plan；不一致处按驱动实现并列疑点如下。
  ```
  代码：
  ```systemverilog
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
      localparam bit [31:0] VTX_RESET        = 32'h088_0100;
      localparam bit [31:0] VTX_RESET_DONE   = 32'h088_0104;
      localparam bit [31:0] VTX_RAM_CFG      = 32'h088_0130;
      localparam bit [31:0] VTX_CONTENT      = 32'h088_0134;
      localparam bit [31:0] VTX_TAIL_RESET   = 32'h088_0154;
      localparam bit [31:0] VTX_TAIL_DONE    = 32'h088_0158;
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
      localparam int unsigned MAX_QUEUES     = 128;

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
      protected bit        vtx_reset_done;
      protected bit        vtx_tail_done;
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
          vtx_tail_done = 0;
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
      endfunction

      protected function bit [31:0] reg(bit [31:0] off);
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
              return reg(PCMPL_AF_HOST);
          if (off == FW_READY)
              return 32'h8000_0000;
          if (off == VTX_RESET_DONE)
              return vtx_reset_done;
          if (off == VTX_TAIL_DONE)
              return vtx_tail_done;
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
          return reg(off);
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
          end else if (off == MSIX_REARM)
              gv_masked[data[11:1]] = data[0];
          else if (off == VTX_RAM_CFG) begin
              if (data[13] && !data[12])
                  store_para(1, data[8:0]);
          end else if (off == VRX_WR_CFG) begin
              if (data[31:16] != 0)
                  store_para(0, data[15:0]);
          end else if (off == VRX_RD_CFG)
              vrx_rd_cfg = data;
          else if (off == VTX_RESET)
              vtx_reset_done = data[31] ? stop_ring(1, data[10:0]) : 1'b0;
          else if (off == VTX_TAIL_RESET)
              vtx_tail_done = data[31] ? !stall_queue_stop : 1'b0;
          else if (off == VRX_RESET_DONE)
              vrx_reset_done = 0;
          else if (off == VRX_RESET) begin
              if (data[31])
                  vrx_reset_done = stop_ring(0, data[10:0]);
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
      protected function bit stop_ring(bit tx, int unsigned gq);
          if (stall_queue_stop)
              return 0;
          rings.delete(2 * gq + tx);
          broken.delete(2 * gq + tx);
          if (!tx)
              rx_backlog.delete(gq);
          return 1;
      endfunction

      // M-2：活动 bank 中 notify 地址等于本 BAR0、{blk,lq} 等于队列对号的有效项给出全局队列号。
      protected function int lookup_qid(int unsigned pair);
          bit [31:0] sel;
          bit [31:0] dw0;
          bit [31:0] dw1;
          bit [31:0] dw2;
          bit [31:0] base;
          bit [63:0] bar0;

          sel = reg(QID_MAP_SEL);
          if (!sel[0])
              return -1;
          bar0 = bar_base(0);
          for (int unsigned i = 0; i < 128; i++) begin
              base = QID_MAP_BASE + sel[1] * 32'h4000 + 16 * i;
              dw0 = reg(base);
              dw1 = reg(base + 4);
              dw2 = reg(base + 8);
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

      // M-4：info.valid、全局屏蔽、自屏蔽都通过后，线性表反查本地向量并经底座发 MSI-X。
      protected task cq_irq(int unsigned gv);
          bit [31:0] info;
          bit [31:0] ctrl;
          bit [31:0] e;
          bit [31:0] srcid;

          info = reg(MSIX_INFO_BASE + 4 * gv);
          ctrl = reg(MSIX_CTRL_BASE + 16 * gv + 32'hc);
          if (!info[12] || ctrl[0] || (gv_masked.exists(gv) && gv_masked[gv]))
              return;
          srcid = host_id << 10;
          for (int unsigned i = 0; i < 128; i++) begin
              e = reg(MSIX_LINEAR_BASE + 4 * ((srcid << 7) + i));
              if (e[11] && (e[10:0] == gv)) begin
                  if (info[11])
                      gv_masked[gv] = 1;
                  raise_irq(i);
                  return;
              end
          end
      endtask

      // ---------------- 数据路径 ----------------
      virtual task service_queue(int unsigned w);
          if (w % 2)
              service_tx(w / 2);
          else
              service_rx(w / 2);
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
              dw1 = {r.cq_wrap, 1'b0, f.data.size()[13:0], r.cons[15:0]};
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
          case (off)
              MSIX_REARM:     return "msix_rearm";
              AF_DECLARATION: return "af_declaration";
              PCMPL_AF_HOST:  return "pcmpl_af_host_id";
              QID_MAP_SEL:    return "qid_map_sel";
              MB_AF_HOST:     return "mb_af_host_id";
              VTX_RESET:      return "vtx_reset";
              VTX_RESET_DONE: return "vtx_reset_done";
              VTX_RAM_CFG:    return "vtx_ram_cfg";
              VTX_TAIL_RESET: return "vtx_tail_reset";
              VTX_TAIL_DONE:  return "vtx_tail_reset_done";
              VRX_RESET:      return "vrx_reset";
              VRX_RESET_DONE: return "vrx_reset_done";
              VRX_WR_CFG:     return "vrx_wr_cfg";
              VRX_RD_CFG:     return "vrx_rd_cfg";
              VRX_RD_DATA:    return "vrx_rd_data";
              SOFT_RESET:     return "soft_reset";
              FW_READY:       return "fw_ready";
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
          if ((off >= MSIX_LINEAR_BASE) && (off < MSIX_LINEAR_BASE + 32'h40_0000))
              return $sformatf("msix_linear.%0d", (off - MSIX_LINEAR_BASE) / 4);
          return $sformatf("0x%07h", off);
      endfunction
  endclass
  `endif
  ```
  说明：`f.data.size()[13:0]` 若 VCS 不接受方法调用结果的位选，先赋给 `int unsigned len14` 再取 `len14[13:0]`。
  RX 消费位置推进写成 `(r.cons + cnt) % n` 并在回绕时翻转 wrap（`cnt <= n`，至多回绕一次）。

- [ ] **Step 4: 包含进包**

  `virtio_net_pkg.sv` old：`  \`include "devmodel/vdev_virtio_pci.sv"` new：
  ```systemverilog
    `include "devmodel/vdev_virtio_pci.sv"
    `include "devmodel/vdev_dpu_priv.sv"
  ```

- [ ] **Step 5: 运行，确认通过**

  `TEST=virtio_vdev_unit_test`：日志含 `test_priv_driver_sequence PASSED`，三行汇总为 0。

- [ ] **Step 6: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=41`。

- [ ] **Step 7: 提交**
  ```bash
  git add virtio_net_vip/src/devmodel/vdev_dpu_priv.sv virtio_net_vip/src/virtio_net_pkg.sv \
      virtio_net_vip/tests/virtio_vdev_unit_test.sv
  git commit -m "feat: 新增 DPU 私有设备模型（AF 声明、qid map、VTX/VRX 参数表、16B 描述符与 CQ），文件头列驱动寄存器序列与疑点"
  ```

---
### Task D5: 寄存器级 `dpu_priv_config_backend`，私有测试面对 `vdev_dpu_priv`，删除 `dpu_priv_device_control`（规范 R4）

**范围：** 后端按 D4 表“VIP 后端”列实现 AF 路径的数据队列子集：`discover()`=#2–#8、#10、#16、#17、#20、#21（只做一次，
`probed` 记忆）；`configure_queue`=#24（TX）/#25（RX）；`enable_queue`=#28（TX）/#27（RX，本队列对的中断向量）；
`disable_queue`=#33；`reset()`=对全部已配置队列先 TX 后 RX 执行 #33（对应 `dpu_down`；AF 声明与映射表保留——
FSM 每次 full_init 先 discover 后 reset，reset 若撤销声明会让随后的建队失去 qid map）；`notify_queue`=#29/#31。
全局资源：gq = gv = 队列对号（`local_qid>>1`），gfid=0（M-9）。不做 #9、#11–15、#18、#19、#22、#23、#26、#30、#32、
#34–38（D-2/D-3；F 阶段对比时白名单）。BAR 编程是平台职责（Linux 驱动不写 BAR），后端不做。

**Files:**
- Rewrite: `virtio_net_vip/src/dpu_priv/dpu_priv_config_backend.sv`
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_driver_config.sv`（删 `dpu_priv_device_control`、`dpu_priv_queue_context_t`、
  `control` 字段）、`virtio_net_vip/src/transport/virtio_config_backend.sv`（注释）
- Modify: `virtio_net_vip/tests/virtio_vdev_unit_test.sv`、`virtio_net_vip/tests/virtio_unit_test.sv`、
  `virtio_net_vip/tests/virtio_dut_caps_test.sv`、`examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv`、
  `examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv`
- Test: `virtio_vdev_unit_test`、`dpu_priv_driver_flow_test`、`dpu_priv_ring_contract_test`、`virtio_unit_test`、`virtio_dut_caps_test`

**Interfaces:**
- Consumes: D4 设备；D3 `vdev_loopback_bar_accessor`；C 的 `bind_private(cfg, pairs)`、`prepare_queue` 钩子、
  `dpu_priv_virtqueue::notify_word`；B 的 `read_net_config`；`transport.wait_pol.queue_reset_timeout_ns`（停队轮询上限）。
- Produces: `dpu_priv_config_backend`（寄存器级，无 `control`）；失败约定：`disable_queue/reset` 轮询超时返回 `ok=0`
  且**不报错**（由通用 ops 报 `ATOMIC_OPS` 错误，私有流程测试的 catcher 只认这一条）；`discover()` 发现 `pfvf_id!=0`、
  AF 已被声明、声明读回不符或 qid map 读回不符时报 `DPU_PRIV_BACKEND` 错误。
- Removes: `dpu_priv_device_control`、`dpu_priv_queue_context_t`、`dpu_priv_driver_config::control`、
  `dpu_priv_config_backend::to_context`、`dpu_priv_example_control`、`virtio_unit_priv_control_stub`、
  `virtio_dut_caps_priv_control_stub`。

- [ ] **Step 1: 写失败测试**

  (a) `virtio_vdev_unit_test.sv`：在 `virtual task run_phase` 之前加入（Review Focus 5）：
  ```systemverilog
      protected function void expect_trace(string got[$], string want[$], string label);
          int unsigned n;

          n = (got.size() < want.size()) ? got.size() : want.size();
          for (int unsigned i = 0; i < n; i++)
              if (got[i] != want[i])
                  `uvm_fatal("VDEV_UNIT", $sformatf("%s step %0d: got '%s', driver order expects '%s'",
                                                    label, i, got[i], want[i]))
          if (got.size() != want.size())
              `uvm_fatal("VDEV_UNIT", $sformatf("%s: %0d register accesses, driver order has %0d",
                                                label, got.size(), want.size()))
      endfunction

      // 规范 Review Focus 5：寄存器级私有后端的访问序列与驱动 AF 路径一致（D4 表）。设备重新 init 为
      // host 0 的全新状态，后端经回环 accessor 访问；停队用旋钮制造“DMA 不停”。
      task test_priv_backend_sequence();
          virtio_pci_transport t;
          vdev_loopback_bar_accessor acc;
          dpu_priv_config_backend be;
          dpu_priv_driver_config cfg;
          virtio_queue_program_t rxp, txp;
          string trace[$];
          string want[$];
          bit [31:0] e[4];
          bit [63:0] rx_gpa, tx_gpa, rx_ring, tx_ring;
          bit ok;

          priv.host_id = 0;
          priv.init();
          program_bars(PRIV_BDF, PRIV_BAR0, PRIV_BAR2, PRIV_BAR4);
          t = virtio_pci_transport::type_id::create("priv_transport");
          t.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(PRIV_BDF));
          t.wait_pol = kit.wait_pol;
          acc = vdev_loopback_bar_accessor::type_id::create("priv_bar");
          acc.port = port;
          acc.target_bdf = PRIV_BDF;
          acc.bar_base[0] = PRIV_BAR0;
          acc.bar_base[2] = PRIV_BAR2;
          acc.bar_base[4] = PRIV_BAR4;
          t.bar = acc;
          cfg = dpu_priv_driver_config::type_id::create("priv_cfg");
          be = dpu_priv_config_backend::type_id::create("priv_backend");
          be.bind_transport(t);
          be.bind_private(cfg, 1);
          // probe
          priv_log.events.delete();
          be.discover();
          priv_log.reg_trace(trace);
          want = '{"R bar2 host_id 0x0", "W bar0 soft_reset 0x7", "W bar0 soft_reset 0x0",
                   "R bar0 af_declaration 0x0", "W bar0 af_declaration 0x5555aaaa",
                   "R bar0 af_declaration 0x8", "W bar0 mb_af_host_id 0x8",
                   "R bar0 af_declaration 0x8", "W bar2 bdf 0x10500"};
          for (int unsigned i = 0; i < 15; i++)
              want.push_back($sformatf("W bar0 msix_linear.%0d 0x%0h", i, 32'h800 | i));
          want.push_back("W bar0 bdf_map.0 0x10500");
          for (int unsigned i = 0; i < 128; i++) begin
              if (i == 0) begin
                  e[0] = {PRIV_BAR0[31:7], 7'h01};
                  e[1] = {3'h0, PRIV_BAR0[60:32]};
                  e[2] = 32'h0;
              end else begin
                  e[0] = 32'hffff_ffff;
                  e[1] = 32'hffff_ffff;
                  e[2] = 32'h0000_07ff;
              end
              e[3] = 32'h0;
              for (int unsigned w = 0; w < 4; w++)
                  want.push_back($sformatf("W bar0 qid_map.b0.e%0d.dw%0d 0x%0h", i, w, e[w]));
              for (int unsigned w = 0; w < 4; w++)
                  want.push_back($sformatf("R bar0 qid_map.b0.e%0d.dw%0d 0x%0h", i, w, e[w]));
          end
          want.push_back("W bar0 qid_map_sel 0x1");
          want.push_back("R bar0 qid_map_sel 0x1");
          expect_trace(trace, want, "probe");
          // open：RX 建队+中断，TX 建队+使能
          rx_ring = map_buffer(PRIV_BDF, 4096, DMA_BIDIRECTIONAL, rx_gpa);
          tx_ring = map_buffer(PRIV_BDF, 4096, DMA_BIDIRECTIONAL, tx_gpa);
          rxp = virtio_empty_queue_program();
          rxp.queue_id = 0;
          rxp.local_qid = 0;
          rxp.queue_size = 8;
          rxp.desc_iova = rx_ring;
          txp = rxp;
          txp.queue_id = 1;
          txp.local_qid = 1;
          txp.tx_mode = 1;
          txp.desc_iova = tx_ring;
          priv_log.events.delete();
          be.configure_queue(rxp, ok);
          if (ok) be.enable_queue(rxp, ok);
          if (ok) be.configure_queue(txp, ok);
          if (ok) be.enable_queue(txp, ok);
          if (!ok || !priv.queue_enabled(0, 0) || !priv.queue_enabled(1, 0))
              `uvm_fatal("VDEV_UNIT", "private backend did not configure and enable both queues")
          priv_log.reg_trace(trace);
          want = '{"R bar0 vrx_tail.0 0x8000",
                   $sformatf("W bar0 vrx_content.dw0 0x%0h", rx_ring[31:0]),
                   $sformatf("W bar0 vrx_content.dw1 0x%0h", rx_ring[63:32]),
                   "W bar0 vrx_content.dw2 0x13", "W bar0 vrx_wr_cfg 0x0", "W bar0 vrx_wr_cfg 0x10000",
                   "W bar0 msix_info.0 0x1800", "W bar0 msix_ctrl.0.dw3 0x0",
                   $sformatf("W bar0 vtx_content.dw0 0x%0h", tx_ring[31:0]),
                   $sformatf("W bar0 vtx_content.dw1 0x%0h", tx_ring[63:32]),
                   "W bar0 vtx_content.dw2 0x83", "W bar0 vtx_content.dw3 0x0",
                   "W bar0 vtx_ram_cfg 0x0", "W bar0 vtx_ram_cfg 0x2000",
                   $sformatf("R bar0 vtx_para.0.dw0 0x%0h", tx_ring[31:0]),
                   $sformatf("R bar0 vtx_para.0.dw1 0x%0h", tx_ring[63:32]),
                   "R bar0 vtx_para.0.dw2 0x83", "R bar0 vtx_para.0.dw3 0x0",
                   $sformatf("R bar0 vtx_para.0.dw0 0x%0h", tx_ring[31:0]),
                   $sformatf("R bar0 vtx_para.0.dw1 0x%0h", tx_ring[63:32]),
                   "R bar0 vtx_para.0.dw2 0x83", "R bar0 vtx_para.0.dw3 0x0",
                   $sformatf("W bar0 vtx_content.dw0 0x%0h", tx_ring[31:0]),
                   $sformatf("W bar0 vtx_content.dw1 0x%0h", tx_ring[63:32]),
                   "W bar0 vtx_content.dw2 0x93", "W bar0 vtx_content.dw3 0x0",
                   "W bar0 vtx_ram_cfg 0x0", "W bar0 vtx_ram_cfg 0x2000"};
          expect_trace(trace, want, "open");
          // stop：DMA 不停时复位必须返回 ok=0 且不报错；恢复后按驱动顺序先 TX 后 RX 停队
          priv.stall_queue_stop = 1;
          be.reset(ok);
          if (ok)
              `uvm_fatal("VDEV_UNIT", "private reset reported success while the device kept DMA running")
          priv.stall_queue_stop = 0;
          priv_log.events.delete();
          be.reset(ok);
          if (!ok || priv.queue_enabled(0, 0) || priv.queue_enabled(1, 0))
              `uvm_fatal("VDEV_UNIT", "private reset did not stop both queues")
          priv_log.reg_trace(trace);
          want = '{$sformatf("R bar0 vtx_para.0.dw0 0x%0h", tx_ring[31:0]),
                   $sformatf("R bar0 vtx_para.0.dw1 0x%0h", tx_ring[63:32]),
                   "R bar0 vtx_para.0.dw2 0x83", "R bar0 vtx_para.0.dw3 0x0",
                   $sformatf("W bar0 vtx_content.dw0 0x%0h", tx_ring[31:0]),
                   $sformatf("W bar0 vtx_content.dw1 0x%0h", tx_ring[63:32]),
                   "W bar0 vtx_content.dw2 0x83", "W bar0 vtx_content.dw3 0x0",
                   "W bar0 vtx_ram_cfg 0x0", "W bar0 vtx_ram_cfg 0x2000",
                   "R bar0 qsch_state.0 0x0", "W bar0 vtx_reset 0x0", "W bar0 vtx_reset 0x80000000",
                   "R bar0 vtx_reset_done 0x1", "W bar0 vtx_tail_reset 0x10000",
                   "W bar0 vtx_tail_reset 0x80010000", "R bar0 vtx_tail_reset_done 0x1",
                   "W bar0 vrx_rd_cfg 0x0", "W bar0 vrx_rd_cfg 0x10000",
                   $sformatf("R bar0 vrx_rd_data 0x%0h", rx_ring[31:0]),
                   "W bar0 vrx_rd_cfg 0x4000", "W bar0 vrx_rd_cfg 0x14000",
                   $sformatf("R bar0 vrx_rd_data 0x%0h", rx_ring[63:32]),
                   "W bar0 vrx_rd_cfg 0x8000", "W bar0 vrx_rd_cfg 0x18000", "R bar0 vrx_rd_data 0x13",
                   "W bar0 vrx_rd_cfg 0xc000", "W bar0 vrx_rd_cfg 0x1c000", "R bar0 vrx_rd_data 0x0",
                   $sformatf("W bar0 vrx_content.dw0 0x%0h", rx_ring[31:0]),
                   $sformatf("W bar0 vrx_content.dw1 0x%0h", rx_ring[63:32]),
                   "W bar0 vrx_content.dw2 0x3", "W bar0 vrx_wr_cfg 0x0", "W bar0 vrx_wr_cfg 0x10000",
                   "W bar0 vrx_reset_done 0x0", "W bar0 vrx_reset 0x0", "W bar0 vrx_reset 0x80000000",
                   "R bar0 vrx_reset_done 0x1", "W bar0 msix_info.0 0x0"};
          expect_trace(trace, want, "stop");
          iommu.unmap_for_host(0, PRIV_BDF, rx_ring);
          iommu.unmap_for_host(0, PRIV_BDF, tx_ring);
          mem.free(rx_gpa);
          mem.free(tx_gpa);
          `uvm_info("VDEV_UNIT", "test_priv_backend_sequence PASSED", UVM_LOW)
      endtask
  ```
  （第一次 `be.reset` 停在 TX：参数已写成 en=0 而 QSCH 报在途，所以第二次 reset 读回的 TX DW2 已是 0x83；RX 尚未处理，
  读回 DW2 仍为 0x13，清 queue_en 后写回 0x3。）
  `run_phase` old：
  ```systemverilog
          test_priv_driver_sequence();
          mem.leak_check();
  ```
  new：
  ```systemverilog
          test_priv_driver_sequence();
          test_priv_backend_sequence();
          mem.leak_check();
  ```

  (b) `examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv`（在 C3 改动后的文本上改；断言条件与次数不变，观察入口从
  测试控制后端换成设备事件与设备旋钮）：
  1. 文件头三行 old：
     ```systemverilog
     // 目录层次：examples/dpu_priv_ring；验证 src 私有驱动在双 Host 顶层环境中的使用流程。
     // 依赖 virtio_system_env 示例与生产 virtio_net_pkg；配置/后端由测试持有，数据/ring
     // 生命周期完全交给生产 ops。模拟后端仅处理设备控制和 IOVA DMA，不替代驱动实现。
     ```
     new：
     ```systemverilog
     // 目录层次：examples/dpu_priv_ring；验证 src 私有驱动在双 Host 顶层环境中的使用流程。
     // 每个 Host 的私有 VF 面对独立设备模型 vdev_dpu_priv（回环端口：寄存器访问直达设备，设备 DMA 经该
     // Host 的 IOMMU）。数据/ring 生命周期完全交给生产 ops，测试只从设备事件观察描述符、帧字节与通知字。
     ```
  2. 删除整个 `dpu_priv_example_control` 类（从 `// 测试设备后端保存真正传入的队列配置，通过 IOMMU 读写 ring/帧/CQ。`
     到其 `endclass`）。
  3. 字段 old：`    dpu_priv_example_control controls[2];` new：
     ```systemverilog
         vdev_dpu_priv      devices[2];
         vdev_loopback_port ports[2];
         vdev_event_log     logs[2];
     ```
  4. `build_phase` old：
     ```systemverilog
             controls[host_id] = new($sformatf("host%0d_control", host_id));
             private_cfg = new($sformatf("host%0d_private", host_id));
             private_cfg.control = controls[host_id];
     ```
     new：
     ```systemverilog
             devices[host_id] = vdev_dpu_priv::type_id::create($sformatf("host%0d_vdev", host_id), this);
             logs[host_id] = vdev_event_log::type_id::create($sformatf("host%0d_vdev_log", host_id), this);
             ports[host_id] = vdev_loopback_port::type_id::create($sformatf("host%0d_vdev_port", host_id));
             private_cfg = new($sformatf("host%0d_private", host_id));
     ```
     在 `build_phase` 的 `endfunction` 之后加入：
     ```systemverilog
         virtual function void connect_phase(uvm_phase phase);
             super.connect_phase(phase);
             foreach (devices[h])
                 devices[h].event_ap.connect(logs[h].analysis_export);
         endfunction

         // 私有 VF 面对 vdev_dpu_priv：设备按该 VF 的 BDF 初始化（qinfo 报告 host=h、pfvf=0），挂到本 Host 的
         // 回环端口；VF 的 BAR accessor 换成回环 accessor，必须在 Function 绑定（把 accessor 接进 notify_mgr/
         // cap_mgr）之前完成。BAR 由测试按设备尺寸放置（VF 租约 BAR0 只有 16 KiB，私有设备寄存器窗 32 MiB），
         // 写进设备配置空间并同步给 accessor；回环 accessor 无 Fabric 布局，不受租约约束。
         function void attach_private_device(int unsigned h, virtio_function_instance f);
             vdev_loopback_bar_accessor acc;
             bit [63:0] bases[3];

             devices[h].bdf = f.bdf;
             devices[h].host_id = h;
             devices[h].init();
             ports[h].attach(devices[h]);
             acc = vdev_loopback_bar_accessor::type_id::create($sformatf("host%0d_priv_bar", h));
             acc.port = ports[h];
             acc.target_bdf = f.bdf;
             bases[0] = 64'h0000_0080_0000_0000 + h * 64'h0000_0000_1000_0000;
             bases[1] = bases[0] + 64'h0000_0000_0400_0000;
             bases[2] = bases[0] + 64'h0000_0000_0500_0000;
             for (int unsigned i = 0; i < 3; i++) begin
                 acc.bar_base[2*i] = bases[i];
                 ports[h].host_cfg_write(f.bdf, 12'h010 + 8*i, bases[i][31:0]);
                 ports[h].host_cfg_write(f.bdf, 12'h014 + 8*i, bases[i][63:32]);
             end
             f.transport.bar = acc;
         endfunction

         function bit same_bytes(bit [7:0] a[$], byte unsigned b[$]);
             if (a.size() != b.size())
                 return 0;
             foreach (a[i])
                 if (a[i] != b[i])
                     return 0;
             return 1;
         endfunction
     ```
  5. `end_of_elaboration_phase` old：
     ```systemverilog
                 controls[h].mem = system_env.get_host_mem(h);
                 controls[h].iommu = env.iommu;
     ```
     new：
     ```systemverilog
                 ports[h].mem = system_env.get_host_mem(h);
                 ports[h].iommu = env.iommu;
                 ports[h].host_id = h;
     ```
     old（C3 之后 foreach 体开头）：
     ```systemverilog
                 f = env.function_instances[i];
                 if (!(f.preflight_bind_pcie(unused_rc) &&
     ```
     new：
     ```systemverilog
                 f = env.function_instances[i];
                 if (f.function_key.vf_id == 0)
                     attach_private_device(h, f);
                 if (!(f.preflight_bind_pcie(unused_rc) &&
     ```
  6. 删除 `descriptor()` 函数（从 `    // 从设备视角读一个 16B 描述符` 到其 `endfunction`）。
  7. `check_traffic` 整个 task（含上方注释）替换为：
     ```systemverilog
         // 生产 ops/引擎走一次 TX/RX：设备按 qid map 与 VTX/VRX 参数表经 IOMMU 读帧、写 CQ，TX 帧回环到
         // 同队列对的 RX。从设备事件核对描述符长度（不含 header）、原始字节、通知字与 RX buffer 容量，
         // 并核对 token、完成长度与单帧 DMA 回收数量。
         task check_traffic(int unsigned h);
             virtio_queue_program_t tx_prog, rx_prog;
             packet_item frame;
             virtio_net_hdr_t hdr;
             uvm_object completed[$], received[$];
             byte unsigned raw[$];
             vdev_event ev[$];
             int unsigned id, before_count, tx_notifies;
             bit [31:0] tx_word;
             int unsigned budget = 8;
             frame = make_frame($sformatf("host%0d_frame", h), 128+64*h);
             hdr = '{default:0};
             if (!private_ops[h].get_queue_program(1, tx_prog) ||
                 !private_ops[h].get_queue_program(0, rx_prog) ||
                 tx_prog.host_id != h || tx_prog.local_qid != h*8+1)
                 `uvm_fatal("DPU_FLOW", "private queue context/host routing mismatch")
             if (!virtio_net_packet_adapter::pack(frame, raw))
                 `uvm_fatal("DPU_FLOW", "frame could not be packed")
             logs[h].events.delete();
             if (h == 0) private_ops[h].tx_submit(1, hdr, frame, 0, id);
             else private_functions[h].dataplane.tx_engine.submit_packet(1, frame, 0, id);
             if (id != 0) `uvm_fatal("DPU_FLOW", "private TX submission failed")
             #1us;
             logs[h].select(VDEV_DESC_CHAIN, ev);
             if ((ev.size() != 1) || (ev[0].q != tx_prog.local_qid) || (ev[0].seg_len.size() != 1) ||
                 (ev[0].seg_len[0] != raw.size()))
                 `uvm_fatal("DPU_FLOW", "TX descriptor contains a header or wrong length")
             logs[h].select(VDEV_PKT, ev);
             if ((ev.size() == 0) || (ev[0].dir != "tx") || !same_bytes(ev[0].bytes, raw))
                 `uvm_fatal("DPU_FLOW", "TX DMA bytes differ from raw Ethernet frame")
             logs[h].select(VDEV_NOTIFY, ev);
             tx_notifies = 0;
             foreach (ev[i])
                 if (ev[i].q == tx_prog.local_qid) begin
                     tx_notifies++;
                     tx_word = {ev[i].wrap, ev[i].next_idx[14:0], 16'(ev[i].q)};
                 end
             if ((tx_notifies != 1) || (tx_word != (32'h8001_0000 | tx_prog.local_qid)))
                 `uvm_fatal("DPU_FLOW", "TX notification did not carry tail/wrap/local_qid")
             before_count = ports[h].iommu.total_unmaps;
             if (h == 0) private_ops[h].tx_complete(1, completed, budget);
             else private_functions[h].dataplane.tx_engine.complete_tx(1, 8, completed);
             if (completed.size() != 1 || completed[0] != frame ||
                 ports[h].iommu.total_unmaps != before_count+1)
                 `uvm_fatal("DPU_FLOW", "TX completion ownership did not retire exactly once")

             logs[h].events.delete();
             if (h == 0) private_ops[h].rx_refill(0, 2);
             else begin
                 if (private_functions[h].dataplane.rx_engine.get_rx_buf_size() != 2048)
                     `uvm_fatal("DPU_FLOW", "private engine buffer query includes a header")
                 private_functions[h].dataplane.rx_engine.refill_buffers(0, 2);
             end
             #1us;
             logs[h].select(VDEV_DESC_CHAIN, ev);
             if ((ev.size() != 1) || (ev[0].q != rx_prog.local_qid) || (ev[0].seg_len[0] != 2048))
                 `uvm_fatal("DPU_FLOW", "RX buffer size not taken from config")
             if (h == 0) private_ops[h].rx_receive(0, received, budget);
             else private_functions[h].dataplane.rx_engine.receive_packets(0, 8, received);
             if (received.size() != 1 || !virtio_net_packet_adapter::compare(frame, received[0]))
                 `uvm_fatal("DPU_FLOW", "RX did not return the exact Ethernet frame")
         endtask
     ```
  8. `check_lifecycle` 整个 task（含上方注释）替换为：
     ```systemverilog
         // 设备旋钮 stall_queue_stop 让停队/复位永不完成（DMA 不停）：确认 Host/DMA 资源原封保留，再恢复后
         // 重试释放。随后跑公共 FSM 后台补 RX，再从 Function.shutdown 停机；检查失败保护和成功后必须重新初始化
         // 的状态，确保不会进入标准寄存器路径，也不留下可误启动的 FSM。
         task check_lifecycle(int unsigned h);
             dpu_priv_expected_error catcher;
             virtio_queue_program_t prog;
             int unsigned maps_before;
             bit ok;
             catcher = new();
             uvm_report_cb::add(null, catcher);
             maps_before = ports[h].iommu.total_unmaps;
             devices[h].stall_queue_stop = 1;
             catcher.expected = "teardown_queue: config backend did not confirm queue_id=0 stopped; retaining queue DMA";
             private_ops[h].teardown_queue(0);
             if (catcher.matched != 1 || ports[h].iommu.total_unmaps != maps_before ||
                 !private_ops[h].get_queue_program(0, prog))
                 `uvm_fatal("DPU_FLOW", "failed stop released live DMA")
             catcher.expected = "device_reset: transport reset did not complete; retaining PF DMA";
             private_ops[h].device_reset_verified(ok);
             if (ok || catcher.matched != 2 || ports[h].iommu.total_unmaps != maps_before)
                 `uvm_fatal("DPU_FLOW", "failed reset released live DMA")
             devices[h].stall_queue_stop = 0;
             private_ops[h].teardown_queue(0);
             if (private_ops[h].get_queue_program(0, prog) ||
                 private_functions[h].vq_mgr.has_queue(0) ||
                 devices[h].queue_enabled(0, 4*h) || ports[h].iommu.total_unmaps <= maps_before)
                 `uvm_fatal("DPU_FLOW", "successful stop did not retire RX queue ownership")
             private_ops[h].device_reset_verified(ok);
             if (!ok || private_functions[h].vq_mgr.get_queue_count() != 0)
                 `uvm_fatal("DPU_FLOW", "successful reset did not destroy private queues")
             private_functions[h].driver_agent.fsm.full_init();
             private_functions[h].driver_agent.fsm.start_dataplane();
             #100ns;
             maps_before = ports[h].iommu.total_unmaps;
             devices[h].stall_queue_stop = 1;
             catcher.expected = "device_reset: transport reset did not complete; retaining PF DMA";
             private_functions[h].shutdown();
             if (catcher.matched != 3 || ports[h].iommu.total_unmaps != maps_before ||
                 private_functions[h].state != VF_RESET_FAILED ||
                 private_functions[h].driver_agent.fsm.state != FSM_ERROR ||
                 !private_ops[h].get_queue_program(0, prog))
                 `uvm_fatal("DPU_FLOW", "failed Function shutdown lost resources or failure state")
             devices[h].stall_queue_stop = 0;
             private_functions[h].shutdown();
             if (private_functions[h].state != VF_DISABLED ||
                 private_functions[h].driver_agent.fsm.state != FSM_REINIT_REQUIRED ||
                 private_functions[h].vq_mgr.get_queue_count() != 0 ||
                 ports[h].iommu.total_maps != ports[h].iommu.total_unmaps)
                 `uvm_fatal("DPU_FLOW", "successful shutdown leaked DMA or left a restartable FSM")
             uvm_report_cb::delete(null, catcher);
         endtask
     ```
     （两条 catcher 文案沿用 C3 Step 1(a) 写入的原文；A/B 若改过，照当时树上的原文。）
  9. `run_phase` old：`                if (controls[0].mem == controls[1].mem)` new：`                if (ports[0].mem == ports[1].mem)`。

  (c) `examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv`：文件头第 4–5 行 old：
  ```systemverilog
  // 测试拥有 Host memory、queue manager、回调与模拟设备 CQ 写入；所有环在结束时
  // 释放。本文件不访问真实 DUT/MMIO，只验证驱动可见的描述符、通知值与回收语义。
  ```
  new：
  ```systemverilog
  // 测试拥有 Host memory、queue manager 与模拟 CQ 写入；所有环在结束时释放。前五个子测试只验证驱动
  // 可见的描述符、通知值与回收语义；最后一个经回环端口驱动独立设备 vdev_dpu_priv，验证设备写出的
  // CQ 字节与同一组 C 黄金值一致并被生产 poll_used 认领。
  ```
  字段 old：`    virtqueue_manager manager;` new：
  ```systemverilog
      virtqueue_manager manager;
      vdev_dpu_priv device;
      vdev_loopback_port dev_port;
  ```
  `build_phase` old：
  ```systemverilog
          manager.host_id = 0;
          manager.bdf = 16'h0100;
      endfunction
  ```
  new：
  ```systemverilog
          manager.host_id = 0;
          manager.bdf = 16'h0100;
          device = vdev_dpu_priv::type_id::create("dpu_priv_vdev", this);
          dev_port = vdev_loopback_port::type_id::create("dpu_priv_vdev_port");
          dev_port.mem = mem;
          dev_port.iommu = iommu;
          dev_port.host_id = 0;
      endfunction
  ```
  在 `virtual task run_phase` 之前加入：
  ```systemverilog
      protected function void dev_wr(bit [31:0] off, bit [31:0] data);
          dev_port.host_write(64'h0000_0044_0000_0000 + off, 4, data);
      endfunction

      // 设备往返：生产 dpu_priv_virtqueue 发布 TX/RX，vdev_dpu_priv 按 qid map 与 VTX/VRX 参数表（驱动
      // #21/#24/#25/#28 的最小子集，q_depth=3、queue_en=1）读描述符、写 CQ；TX CQ 必须等于黄金 01 80，
      // RX CQ 按驱动布局解码出单 buffer、原长度，且两边都被 poll_used 认领。
      protected task test_device_round_trip();
          dpu_priv_virtqueue tx;
          dpu_priv_virtqueue rx;
          bit [63:0] tx_iova, rx_iova, f_gpa, f_iova, b_gpa, b_iova;
          virtio_sg_list sgs[];
          virtio_sg_entry entry;
          byte frame[];
          uvm_object tok;
          int unsigned len, desc_num, pkt_len, head_idx;
          bit wrap;
          dpu_priv_test_token t_tx, t_rx;
          byte cq_done[2] = '{8'h01, 8'h80};

          device.bdf = 16'h0100;
          device.init();
          dev_port.attach(device);
          dev_port.host_cfg_write(16'h0100, 12'h010, 32'h0000_0000);
          dev_port.host_cfg_write(16'h0100, 12'h014, 32'h0000_0044);
          make_queue(11, 8, 1, 1, tx);
          make_queue(10, 8, 0, 0, rx);
          tx_iova = iommu.map_for_host(0, 16'h0100, tx.desc_table_addr, tx.ring_alloc_bytes, DMA_BIDIRECTIONAL);
          rx_iova = iommu.map_for_host(0, 16'h0100, rx.desc_table_addr, rx.ring_alloc_bytes, DMA_BIDIRECTIONAL);
          dev_wr(32'h2_8000, 32'h0000_0001);
          dev_wr(32'h2_8004, 32'h0000_0044);
          dev_wr(32'h2_8008, 32'h0);
          dev_wr(32'h2_0044, 32'h1);
          dev_wr(32'h88_0134, tx_iova[31:0]);
          dev_wr(32'h88_0138, tx_iova[63:32]);
          dev_wr(32'h88_013c, 32'h93);
          dev_wr(32'h88_0140, 32'h0);
          dev_wr(32'h88_0130, 32'h0);
          dev_wr(32'h88_0130, 32'h2000);
          dev_wr(32'h90_0204, rx_iova[31:0]);
          dev_wr(32'h90_0208, rx_iova[63:32]);
          dev_wr(32'h90_020c, 32'h13);
          dev_wr(32'h90_0200, 32'h0);
          dev_wr(32'h90_0200, 32'h1_0000);
          b_gpa = mem.alloc(2048, 64);
          b_iova = iommu.map_for_host(0, 16'h0100, b_gpa, 2048, DMA_FROM_DEVICE);
          entry.addr = b_iova;
          entry.len = 2048;
          entry.is_indirect = 0;
          sgs = new[1];
          sgs[0].entries.push_back(entry);
          t_rx = dpu_priv_test_token::type_id::create("round_trip_rx");
          void'(rx.add_buf(sgs, 0, 1, t_rx, 0));
          rx.kick();
          dev_wr(32'h0, rx.last_notify_word);
          frame = new[60];
          foreach (frame[i])
              frame[i] = 8'h30 + i;
          f_gpa = mem.alloc(64, 64);
          mem.write_mem(f_gpa, frame);
          f_iova = iommu.map_for_host(0, 16'h0100, f_gpa, 60, DMA_TO_DEVICE);
          entry.addr = f_iova;
          entry.len = 60;
          sgs[0].entries.delete();
          sgs[0].entries.push_back(entry);
          t_tx = dpu_priv_test_token::type_id::create("round_trip_tx");
          void'(tx.add_buf(sgs, 1, 0, t_tx, 0));
          tx.kick();
          dev_wr(32'h0, tx.last_notify_word);
          #1us;
          expect_bytes(tx.cq_addr, cq_done, "device-written TX CQ");
          tok = null;
          len = 0;
          if (!tx.poll_used(tok, len) || (tok != t_tx) || (len != 60))
              `uvm_fatal("DPU_PRIV", "device TX CQ was not reclaimed by the production queue")
          if (!rx.decode_rx_cq(0, desc_num, pkt_len, wrap, head_idx) || (desc_num != 1) ||
              (pkt_len != 60) || !wrap || (head_idx != 0))
              `uvm_fatal("DPU_PRIV", "device RX CQ does not follow the driver layout")
          tok = null;
          if (!rx.poll_used(tok, len) || (tok != t_rx) || (len != 60))
              `uvm_fatal("DPU_PRIV", "device RX CQ was not reclaimed by the production queue")
          iommu.unmap_for_host(0, 16'h0100, f_iova);
          iommu.unmap_for_host(0, 16'h0100, b_iova);
          iommu.unmap_for_host(0, 16'h0100, tx_iova);
          iommu.unmap_for_host(0, 16'h0100, rx_iova);
          mem.free(f_gpa);
          mem.free(b_gpa);
          manager.destroy_queue(11);
          manager.destroy_queue(10);
      endtask
  ```
  `run_phase` old：
  ```systemverilog
          test_tx_wrap();
          manager.destroy_all();
  ```
  new：
  ```systemverilog
          test_tx_wrap();
          test_device_round_trip();
          manager.destroy_all();
  ```
  断言计数：`grep -c 'uvm_fatal' examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv` 由 30 变为 33（只增不减）。

  (d) 删除测试桩：`virtio_unit_test.sv` 删除 `virtio_unit_priv_control_stub` 整个类（从 `// 私有控制后端桩：所有操作立即成功，`
  到 `endclass : virtio_unit_priv_control_stub`），并在 `test_driver_protocol_selection` 删除两行：
  ```systemverilog
          private_cfg.control = virtio_unit_priv_control_stub::type_id::create(
              "unit_private_control");
  ```
  `virtio_dut_caps_test.sv` 删除 `virtio_dut_caps_priv_control_stub` 整个类（从 `// 私有控制桩：只为满足 private_cfg.validate 的非空要求`
  到其 `endclass`），并删除两行：
  ```systemverilog
          private_cfg.control = virtio_dut_caps_priv_control_stub::type_id::create(
              "commit_failure_private_control");
  ```
  （这两个测试的私有用例只检查配置冻结/提交失败，不访问设备；`validate` 去掉 `control` 非空条件后它们原有断言不变。）

- [ ] **Step 2: 运行，确认失败**

  `TEST=virtio_vdev_unit_test`：期望 `test_priv_backend_sequence` 报 `UVM_FATAL` “probe: 0 register accesses, driver
  order has 1051”（C 版 `discover()` 为空）。`TEST=dpu_priv_driver_flow_test`：期望 `FUNCTION_BIND` 错误
  “私有驱动配置非法: private control/defaults…”（测试不再注入 `control`，C 版 `validate` 仍要求它）。

- [ ] **Step 3: `dpu_priv_driver_config.sv` 去掉设备控制接口**

  文件头 old：
  ```systemverilog
  // 目录层次：src/dpu_priv；定义私有队列的控制接口与分层配置。
  // 依赖 virtio_pci_transport、UVM 和驱动 txrx.h 的字段宽度；由 virtio_net_pkg 纳入。
  // test/顶层拥有配置和设备控制实现；每个 Function 的 ops 借用配置并保存已建队的
  // context 副本。control 必须在返回成功前完成设备配置/停 DMA，不拥有 Host 内存。
  ```
  new：
  ```systemverilog
  // 目录层次：src/dpu_priv；定义私有队列的分层配置（每 Function 默认值与单队列覆盖）。
  // 依赖 UVM 和驱动 txrx.h 的字段宽度；由 virtio_net_pkg 纳入。test/顶层拥有配置；私有配置后端
  // 在 bind_private 时冻结一份副本，设备访问全部由寄存器级后端完成。
  ```
  删除从 `// 设备控制接收明确的 Host/BDF/local_qid 与 IOVA，不能用全局资源编号代替本地号。` 到
  `dpu_priv_device_control` 的 `endclass`（含 `dpu_priv_queue_context_t` typedef 与整个虚类）。
  old：`// 每队列覆盖配置只保存通知和 TX 控制，不持有 ring 索引；运行态仍由独立回调持有。`
  new：`// 每队列覆盖配置只保存通知和 TX 控制，不持有 ring 索引；运行态由 dpu_priv_virtqueue 持有。`
  old：
  ```systemverilog
      dpu_priv_device_control control;
      int unsigned default_queue_size = 512;
  ```
  new：
  ```systemverilog
      int unsigned default_queue_size = 512;
  ```
  old：`    // 创建本 Function 的默认队列配置；控制后端必须由上层注入，不自动造设备模型。`
  new：`    // 创建本 Function 的默认队列配置。`
  old：`        if ((control == null) || (defaults == null) || (pairs == 0) ||`
  new：`        if ((defaults == null) || (pairs == 0) ||`
  old：`            why = "private control/defaults、队列对数、环大小或 RX buffer 配置非法";`
  new：`            why = "private defaults、队列对数、环大小或 RX buffer 配置非法";`

  `virtio_config_backend.sv` 头注释 old：`//   dpu_priv_config_backend   : DPU 私有环控制面（dpu_priv_device_control）。`
  new：`//   dpu_priv_config_backend   : DPU 私有设备寄存器级后端（真实驱动 AF 路径的寄存器序列）。`

- [ ] **Step 4: 重写 `dpu_priv_config_backend.sv`**（完整文件）
  ```systemverilog
  // 目录层次：src/dpu_priv；DPU 私有设备的寄存器级配置后端：通用 ops/FSM 对私有 Function 的全部设备副作用
  // 都经这里，按真实驱动 icpu-kernel-driver（lance_net_mailbox@f2c9cd6）AF 路径的寄存器序列访问设备；
  // 序列表与疑点见 devmodel/vdev_dpu_priv.sv 文件头（本后端实现其中“VIP 后端”列）。依赖 transport 的 BAR
  // accessor 与 dpu_priv_virtqueue；保存冻结的队列参数表与已配置队列，不持有 Host 内存或映射。
  // 私有设备没有 virtio status/feature/device-config：status 是驱动侧影子值（复位清零），特性恒 0，device
  // config 全零；队列上限为私有默认环大小。VIP 私有数据面固定 polling：不编程 PCI MSI-X 表，但按驱动建立
  // 设备侧 MSI-X 映射。只实现 pfvf_id=0 的 AF 路径（PF/VF mailbox 未建模）。
  `ifndef DPU_PRIV_CONFIG_BACKEND_SV
  `define DPU_PRIV_CONFIG_BACKEND_SV

  class dpu_priv_config_backend extends virtio_config_backend;
      `uvm_object_utils(dpu_priv_config_backend)

      // 驱动 register.h / af_mng.h / mailbox.h 的地址（BAR0，除注明 BAR2）。
      localparam bit [31:0] QINFO_BDF        = 32'h0000_0004;   // BAR2
      localparam bit [31:0] QINFO_HOST       = 32'h0000_000c;   // BAR2
      localparam bit [31:0] AF_DECLARATION   = 32'h000_1010;
      localparam bit [31:0] QID_MAP_SEL      = 32'h002_0044;
      localparam bit [31:0] QID_MAP_BASE     = 32'h002_8000;
      localparam bit [31:0] MSIX_CTRL_BASE   = 32'h004_8000;
      localparam bit [31:0] MSIX_INFO_BASE   = 32'h005_4000;
      localparam bit [31:0] BDF_MAP_BASE     = 32'h005_6000;
      localparam bit [31:0] MB_AF_HOST       = 32'h006_0040;
      localparam bit [31:0] MSIX_LINEAR_BASE = 32'h00c_0000;
      localparam bit [31:0] VTX_RESET        = 32'h088_0100;
      localparam bit [31:0] VTX_RESET_DONE   = 32'h088_0104;
      localparam bit [31:0] VTX_RAM_CFG      = 32'h088_0130;
      localparam bit [31:0] VTX_CONTENT      = 32'h088_0134;
      localparam bit [31:0] VTX_TAIL_RESET   = 32'h088_0154;
      localparam bit [31:0] VTX_TAIL_DONE    = 32'h088_0158;
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
      // 驱动 init_interrupt_scheme：needed = num_lan_msix + 1（mailbox）+ DPU_AF_EXTRA_INTR_NUM-1（=13，见疑点）。
      localparam int unsigned AF_EXTRA_INTR  = 13;

      protected dpu_priv_queue_config  queue_cfg[int unsigned];
      protected int unsigned           default_size;
      protected int unsigned           rx_size;
      protected int unsigned           pairs;
      protected bit [7:0]              status_shadow;
      protected bit                    probed;
      protected bit [2:0]              host;
      protected bit                    qid_bank;
      protected virtio_queue_program_t active[int unsigned];

      function new(string name = "dpu_priv_config_backend");
          super.new(name);
          default_size = 0;
          rx_size = 0;
          pairs = 0;
          status_shadow = 0;
          probed = 0;
          host = 0;
          qid_bank = 0;
      endfunction

      // 冻结一份已校验的私有配置（调用方先 validate，且 ops 无活动队列）。
      function void bind_private(dpu_priv_driver_config cfg, int unsigned qpairs);
          default_size = cfg.default_queue_size;
          rx_size = cfg.rx_buf_size;
          pairs = qpairs;
          queue_cfg.delete();
          for (int unsigned qid = 0; qid < qpairs * 2; qid++)
              queue_cfg[qid] = cfg.resolve_queue(qid);
          status_shadow = 0;
      endfunction

      // ---------------- MMIO 与轮询 ----------------
      protected task wr0(bit [31:0] off, bit [31:0] v);
          transport.bar.write_reg(0, off, 4, v);
      endtask

      protected task rd0(bit [31:0] off, output bit [31:0] v);
          bit [31:0] d;

          transport.bar.read_reg(0, off, 4, d);
          v = d;
      endtask

      protected task wr2(bit [31:0] off, bit [31:0] v);
          transport.bar.write_reg(2, off, 4, v);
      endtask

      protected task rd2(bit [31:0] off, output bit [31:0] v);
          bit [31:0] d;

          transport.bar.read_reg(2, off, 4, d);
          v = d;
      endtask

      // 读到 (v & mask) == want 为止；超时返回 0（不报错，由调用方决定）。上限取 queue_reset_timeout_ns。
      protected task poll0(bit [31:0] off, bit [31:0] mask, bit [31:0] want, output bit ok);
          bit [31:0] v;
          int unsigned waited;
          int unsigned interval;
          int unsigned limit;

          interval = (transport.wait_pol.default_poll_interval_ns == 0) ? 1 :
                     transport.wait_pol.default_poll_interval_ns;
          limit = transport.wait_pol.effective_timeout(transport.wait_pol.queue_reset_timeout_ns);
          waited = 0;
          forever begin
              rd0(off, v);
              if ((v & mask) == want) begin
                  ok = 1;
                  return;
              end
              if (waited >= limit) begin
                  ok = 0;
                  return;
              end
              #(interval * 1ns);
              waited += interval;
          end
      endtask

      // ---------------- 参数字 ----------------
      // VTX DW2：q_depth[3:0]、queue_en[4]、seg_en[7]=1、sport_type[14:12]=host、dma_msix[25:15]=gv。
      protected function bit [31:0] vtx_dw2(virtio_queue_program_t q, bit en);
          bit [31:0] v;

          v = 0;
          v[3:0] = $clog2(q.queue_size);
          v[4] = en;
          v[7] = 1'b1;
          v[14:12] = host;
          v[25:15] = q.local_qid >> 1;
          return v;
      endfunction

      // VRX DW2：q_depth[3:0]、queue_en[4]、dport_type[8:6]=host、dport_id[18:9]=gfid(0)、dma_msix[29:19]=gv。
      protected function bit [31:0] vrx_dw2(virtio_queue_program_t q, bit en);
          bit [31:0] v;

          v = 0;
          v[3:0] = $clog2(q.queue_size);
          v[4] = en;
          v[8:6] = host;
          v[29:19] = q.local_qid >> 1;
          return v;
      endfunction

      protected task write_vtx(int unsigned gq, bit [31:0] dw[4]);
          for (int unsigned i = 0; i < 4; i++)
              wr0(VTX_CONTENT + 4 * i, dw[i]);
          wr0(VTX_RAM_CFG, gq);
          wr0(VTX_RAM_CFG, gq | 32'h2000);
      endtask

      protected task read_vtx(int unsigned gq, output bit [31:0] dw[4]);
          bit [31:0] v;

          for (int unsigned i = 0; i < 4; i++) begin
              rd0(VTX_PARA_RD + 16 * gq + 4 * i, v);
              dw[i] = v;
          end
      endtask

      // #21 fill_qid_map_table：128 项逐项写 4 DW 再读回；本 Function 的队列对 i=local_qid>>1 有效（gq=i），
      // 其余写无效项；最后置 bank 就绪并读回，下次换另一 bank。
      protected task write_qid_map(bit [63:0] bar0, output bit ok);
          bit valid[int unsigned];
          bit [31:0] e[4];
          bit [31:0] v;
          bit [31:0] base;

          ok = 0;
          foreach (queue_cfg[qid])
              valid[queue_cfg[qid].local_qid >> 1] = 1;
          for (int unsigned i = 0; i < 128; i++) begin
              if (valid.exists(i)) begin
                  e[0] = {bar0[31:7], i[5], i[4:0], 1'b1};
                  e[1] = {host, bar0[60:32]};
                  e[2] = {21'h0, i[10:0]};
              end else begin
                  e[0] = 32'hffff_ffff;
                  e[1] = 32'hffff_ffff;
                  e[2] = 32'h0000_07ff;
              end
              e[3] = 32'h0;
              base = QID_MAP_BASE + qid_bank * 32'h4000 + 16 * i;
              for (int unsigned w = 0; w < 4; w++)
                  wr0(base + 4 * w, e[w]);
              for (int unsigned w = 0; w < 4; w++) begin
                  rd0(base + 4 * w, v);
                  if (v != e[w])
                      return;
              end
          end
          wr0(QID_MAP_SEL, {30'h0, qid_bank, 1'b1});
          rd0(QID_MAP_SEL, v);
          if (v != {30'h0, qid_bank, 1'b1})
              return;
          qid_bank = ~qid_bank;
          ok = 1;
      endtask

      // ---------------- 生命周期钩子 ----------------
      // probe（D4 表 #2–#8、#10、#16、#17、#20、#21），每个后端只做一次。
      virtual task discover();
          bit [31:0] v;
          bit [31:0] lo;
          bit [31:0] hi;
          bit [31:0] srcid;
          bit ok;

          if (probed)
              return;
          rd2(QINFO_HOST, v);
          if (v[6:0] != 0) begin
              `uvm_error("DPU_PRIV_BACKEND", $sformatf(
                  "qinfo host_id=0x%08h reports pfvf_id %0d; only the AF path (pfvf_id=0) is modeled", v, v[6:0]))
              return;
          end
          host = v[9:7];
          wr0(SOFT_RESET, 32'h7);
          wr0(SOFT_RESET, 32'h0);
          rd0(AF_DECLARATION, v);
          if (v[3]) begin
              `uvm_error("DPU_PRIV_BACKEND", $sformatf("AF is already declared (0x1010=0x%08h)", v))
              return;
          end
          wr0(AF_DECLARATION, 32'h5555_aaaa);
          rd0(AF_DECLARATION, v);
          if (v != {28'h0, 1'b1, host}) begin
              `uvm_error("DPU_PRIV_BACKEND", $sformatf("AF declaration readback 0x%08h, expected 0x%08h",
                         v, {28'h0, 1'b1, host}))
              return;
          end
          wr0(MB_AF_HOST, {28'h0, 1'b1, v[2:0]});
          rd0(AF_DECLARATION, v);
          if (!v[3]) begin
              `uvm_error("DPU_PRIV_BACKEND", "AF declaration was lost after the mailbox AF host write")
              return;
          end
          wr2(QINFO_BDF, {15'h0, 1'b1, transport.bdf});
          srcid = {host, 10'h0};
          for (int unsigned i = 0; i < pairs + 1 + AF_EXTRA_INTR; i++)
              wr0(MSIX_LINEAR_BASE + 4 * ((srcid << 7) + i), {20'h0, 1'b1, i[10:0]});
          wr0(BDF_MAP_BASE, {15'h0, 1'b1, transport.bdf});
          transport.bar.config_read(PCI_CFG_BAR0, lo);
          transport.bar.config_read(PCI_CFG_BAR0 + 12'h4, hi);
          write_qid_map({hi, lo[31:4], 4'h0}, ok);
          if (!ok) begin
              `uvm_error("DPU_PRIV_BACKEND", "qid map readback mismatch")
              return;
          end
          probed = 1;
      endtask

      // Function 复位 = 驱动 dpu_down：先停全部 TX 再停全部 RX（#33）；任一未确认停止即 ok=0，调用方保留全部
      // DMA。AF 声明与映射表保留（对应驱动未 rmmod）。成功后影子 status 清零。
      virtual task reset(output bit ok);
          virtio_queue_program_t order[$];
          bit done;

          foreach (active[id])
              if (active[id].tx_mode)
                  order.push_back(active[id]);
          foreach (active[id])
              if (!active[id].tx_mode)
                  order.push_back(active[id]);
          ok = 1;
          foreach (order[i]) begin
              disable_queue(order[i], done);
              if (!done) begin
                  ok = 0;
                  return;
              end
          end
          status_shadow = 0;
      endtask

      virtual task read_status(output bit [7:0] status);
          status = status_shadow;
      endtask

      virtual task write_status(bit [7:0] status);
          status_shadow = status;
      endtask

      virtual task read_device_features(output bit [63:0] features);
          features = 0;
      endtask

      virtual task write_driver_features(bit [63:0] features);
      endtask

      virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
          accepted = 0;
      endtask

      // 表内队列的上限是私有默认环大小；表外队列返回 0，ops 在建队前拒绝。
      virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
          max_size = queue_cfg.exists(queue_id) ? default_size : 0;
      endtask

      // （此处原样保留 C3 写入的 prepare_queue：从 “// 把参数表应用到新建的私有队列” 注释到其 endfunction。）

      // #24（TX，queue_en=0 并读回比较 desc_addr）/ #25（RX，先查 VRX tail=0x8000，queue_en=1）。
      virtual task configure_queue(virtio_queue_program_t q, output bit ok);
          bit [31:0] dw[4];
          bit [31:0] v;
          int unsigned gq;

          ok = 0;
          gq = q.local_qid >> 1;
          if (q.tx_mode) begin
              dw[0] = q.desc_iova[31:0];
              dw[1] = q.desc_iova[63:32];
              dw[2] = vtx_dw2(q, 0);
              dw[3] = 32'h0;
              write_vtx(gq, dw);
              read_vtx(gq, dw);
              if ({dw[1], dw[0]} != q.desc_iova)
                  return;
          end else begin
              rd0(VRX_TAIL + 4 * gq, v);
              if (v[15:0] != 16'h8000)
                  return;
              wr0(VRX_CONTENT, q.desc_iova[31:0]);
              wr0(VRX_CONTENT + 4, q.desc_iova[63:32]);
              wr0(VRX_CONTENT + 8, vrx_dw2(q, 1));
              wr0(VRX_WR_CFG, gq);
              wr0(VRX_WR_CFG, 32'h1_0000 | gq);
          end
          active[q.queue_id] = q;
          ok = 1;
      endtask

      // #28（TX：读回参数后置 queue_en=1）/ #27（RX：本队列对向量 info=valid|self_mask，解除全局屏蔽）。
      virtual task enable_queue(virtio_queue_program_t q, output bit ok);
          bit [31:0] dw[4];
          int unsigned gq;

          gq = q.local_qid >> 1;
          if (q.tx_mode) begin
              read_vtx(gq, dw);
              dw[2][4] = 1'b1;
              write_vtx(gq, dw);
          end else begin
              wr0(MSIX_INFO_BASE + 4 * gq, {19'h0, 1'b1, 1'b1, host, 8'h0});
              wr0(MSIX_CTRL_BASE + 16 * gq + 32'hc, 32'h0);
          end
          ok = 1;
      endtask

      // #33：TX 置 queue_en=0 → 等 QSCH 空闲 → 队列复位 → tail 复位；RX 间接读回参数 → 置 queue_en=0 → 复位，
      // 最后清该队列对的中断 info。任一轮询超时 ok=0（不报错），队列仍记为已配置以便重试。
      virtual task disable_queue(virtio_queue_program_t q, output bit ok);
          bit [31:0] dw[4];
          bit [31:0] v;
          int unsigned gq;

          ok = 0;
          gq = q.local_qid >> 1;
          if (q.tx_mode) begin
              read_vtx(gq, dw);
              dw[2][4] = 1'b0;
              write_vtx(gq, dw);
              poll0(QSCH_STATE + 4 * gq, 32'h0000_0e00, 32'h0, ok);
              if (!ok)
                  return;
              wr0(VTX_RESET, gq);
              wr0(VTX_RESET, gq | 32'h8000_0000);
              poll0(VTX_RESET_DONE, 32'h1, 32'h1, ok);
              if (!ok)
                  return;
              wr0(VTX_TAIL_RESET, gq | 32'h1_0000);
              wr0(VTX_TAIL_RESET, gq | 32'h8001_0000);
              poll0(VTX_TAIL_DONE, 32'h1, 32'h1, ok);
              if (!ok)
                  return;
          end else begin
              for (int unsigned i = 0; i < 4; i++) begin
                  wr0(VRX_RD_CFG, (i << 14) | gq);
                  wr0(VRX_RD_CFG, (i << 14) | gq | 32'h1_0000);
                  rd0(VRX_RD_DATA, v);
                  dw[i] = v;
              end
              dw[2][4] = 1'b0;
              for (int unsigned i = 0; i < 3; i++)
                  wr0(VRX_CONTENT + 4 * i, dw[i]);
              wr0(VRX_WR_CFG, gq);
              wr0(VRX_WR_CFG, 32'h1_0000 | gq);
              wr0(VRX_RESET_DONE, 32'h0);
              wr0(VRX_RESET, gq);
              wr0(VRX_RESET, gq | 32'h8000_0000);
              poll0(VRX_RESET_DONE, 32'h1, 32'h1, ok);
              if (!ok)
                  return;
              wr0(MSIX_INFO_BASE + 4 * gq, 32'h0);
          end
          active.delete(q.queue_id);
      endtask

      // 私有队列复位 = 停队（teardown 已确认）+ 重建；这里没有寄存器动作。
      virtual task reset_queue(int unsigned queue_id, output bit ok);
          ok = 1;
      endtask

      // VIP 私有数据面固定 polling，不编程 PCI MSI-X 表；设备侧映射在 discover/enable_queue 中按驱动建立。
      virtual task set_msix(int unsigned queue_ids[$], output bit ok);
          ok = 1;
      endtask

      virtual task clear_msix(output bit ok);
          ok = 1;
      endtask

      // #29/#31：BAR0+0 共享 doorbell，驱动 writel({wrap, tail, local_qid})。
      virtual task notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap);
          transport.bar.write_reg(q.notify_bar, q.notify_offset, 4,
                                  dpu_priv_virtqueue::notify_word(wrap, next_idx, q.local_qid));
      endtask

      // 私有设备没有 virtio-net device config。
      virtual task read_net_config(output virtio_net_device_config_t cfg);
          cfg = '{default: 0};
      endtask
  endclass
  `endif
  ```
  （`prepare_queue` 不变——它只把参数表写进队列对象与编程参数；B 新增的 device-config 读方法名若不是
  `read_net_config`，按 B 的声明改名。C3 中 `to_context` 随 `dpu_priv_queue_context_t` 一起删除。）

- [ ] **Step 5: 运行，确认通过**

  单测依次：`virtio_vdev_unit_test`（含 `test_priv_backend_sequence PASSED`）、`dpu_priv_driver_flow_test`
  （含 `DPU private src driver flow PASSED`）、`dpu_priv_ring_contract_test`（含 `DPU private TX/RX ring contract PASSED`）、
  `virtio_unit_test`、`virtio_dut_caps_test`。三行汇总均为 0。

- [ ] **Step 6: 删除证据**
  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -rn 'dpu_priv_device_control\|dpu_priv_queue_context_t\|dpu_priv_example_control\|priv_control_stub\|to_context\|\.control\b' \
      virtio_net_vip examples --include=*.sv --include=*.svh
  ```
  期望无输出（`examples/dpu_priv_ring/README.md` 与手册在 D6 处理）。

- [ ] **Step 7: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=41`。

- [ ] **Step 8: 提交**
  ```bash
  git add virtio_net_vip/src/dpu_priv virtio_net_vip/src/transport/virtio_config_backend.sv \
      virtio_net_vip/tests/virtio_vdev_unit_test.sv virtio_net_vip/tests/virtio_unit_test.sv \
      virtio_net_vip/tests/virtio_dut_caps_test.sv examples/dpu_priv_ring
  git commit -m "refactor: 私有配置后端改为按真实驱动寄存器序列访问 vdev_dpu_priv，删除 dpu_priv_device_control"
  ```

---
### Task D6: 文档与最终核对（规范 R4）

**Files:**
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`、`docs/virtio_verification_flow.md`、`examples/dpu_priv_ring/README.md`
- Test: 任一维护测试（`scripts/test_manifest.sh` 在运行前校验文档测试清单）、全量回归

- [ ] **Step 1: README.md**

  1. 第 6 行 old：`模式通过 TLM/本地 responder 完成可复现的协议与数据闭环；只有 REAL_DUT 模式才`
     new：`模式通过 TLM 与独立设备模型完成可复现的协议与数据闭环；只有 REAL_DUT 模式才`
  2. old：`Root 都有一条绑定。MODEL responder 通过 IOMMU 模型把设备可见 IOVA 翻译为 Host`
     new：`Root 都有一条绑定。MODEL 设备端口（vdev_uvm_ep_port）通过 IOMMU 模型把设备可见 IOVA 翻译为 Host`
  3. 目录树 old：`│   │   ├── virtio_pcie_dut_responder.sv    ← MODEL 设备侧行为模型（EP 发起 DMA）` → 删除该行；在
     `│   ├── pcie/                               ← PCIe 适配层` 这一行之前插入：
     ```
     │   ├── devmodel/                           ← 独立设备模型（只依据收到的 PCIe 请求维护状态）
     │   │   ├── vdev_port.sv                    ← 端口抽象（DMA/MSI-X）与语义事件 vdev_event
     │   │   ├── vdev_base.sv                    ← 配置空间、能力链、MSI-X、调试 marker、worker、回环
     │   │   ├── vdev_uvm_ep_port.sv             ← 接 pcie_tl EP driver 的端口（VCS 回归）
     │   │   ├── vdev_virtio_pci.sv              ← 标准 virtio-net 设备 1af4:1041
     │   │   └── vdev_dpu_priv.sv                ← DPU 私有设备 20f9:5013（驱动寄存器序列与疑点见文件头）
     ```
     tests 树中 `virtio_unit_test.sv` 一行之后插入：
     ```
     │   ├── virtio_vdev_unit_test.sv            ← 独立设备模型单元测试（无 PCIe）
     │   ├── vdev_loopback_port.sv               ← 设备测试件：回环端口/BAR accessor、事件记录器
     ```
     （缩进与相邻行一致。）`dpu_priv_driver_config.sv` 行说明改为 `← 私有队列分层配置`，`dpu_priv_config_backend.sv` 行说明改为
     `← 私有设备寄存器级后端（真实驱动 AF 路径）`（C4 之后的行文本按 grep 定位）。
  4. 执行模式小节 old：
     ```
     - MODEL 由 `virtio_pcie_dut_responder` 消费 notify、读取/写入共享 Host memory、
       更新 used ring，并通过 notification manager sideband 模拟 MSI-X/INTx 事件；该
       事件不是 RTL 发出的真实 PCIe MSI-X TLP，但可在没有 RTL 的 TLM 回环中完成闭环。
     - REAL_DUT 不创建该 responder；PCIe EP agent 被动观察真实 RTL 的 TLP，RC 侧必须
     ```
     new：
     ```
     - MODEL 由独立设备模型 `vdev_virtio_pci`（经 `vdev_uvm_ep_port` 接在 pcie_tl EP driver 上）
       应答配置空间与 BAR 寄存器、消费 notify、经 EP-originated DMA 读写 ring 与 payload，并按
       设备自己的 MSI-X 表发 MSI-X MemWr（发布到 EP monitor，由 VIP observer 解码）；设备不引用
       任何驱动侧对象，VIP 漏写/错写寄存器会被设备拒绝并报 `VDEV_*` 警告。
     - REAL_DUT 不创建设备模型；PCIe EP agent 被动观察真实 RTL 的 TLP，RC 侧必须
     ```
     old：`上述条件任一缺失时，fixture 会在 `build_flow()` 阶段失败；不能把 MODEL responder`
     new：`上述条件任一缺失时，fixture 会在 `build_flow()` 阶段失败；不能把 MODEL 设备模型`

- [ ] **Step 2: docs/virtio_net_vip_manual.md**

  1. 目录树 old：`|   |   +-- virtio_pcie_dut_responder.sv    -- MODEL 设备侧行为模型 (EP 发起 DMA)` → 删除；在 `|   +-- pcie/` 之前插入：
     ```
     |   +-- devmodel/
     |   |   +-- vdev_port.sv                    -- 端口抽象与语义事件 vdev_event
     |   |   +-- vdev_base.sv                    -- 配置空间/能力链/MSI-X/调试 marker/worker/回环
     |   |   +-- vdev_uvm_ep_port.sv             -- 接 pcie_tl EP driver 的端口
     |   |   +-- vdev_virtio_pci.sv              -- 标准 virtio-net 设备 1af4:1041
     |   |   +-- vdev_dpu_priv.sv                -- DPU 私有设备 20f9:5013
     ```
     tests 树 `virtio_unit_test.sv` 行之后插入 `virtio_vdev_unit_test.sv`（独立设备模型单元测试）与 `vdev_loopback_port.sv`
     （设备测试件）两行，格式同相邻行。
  2. old：
     ```
     |  (MODEL responder or REAL_DUT Host-memory proxy |
     ```
     new：
     ```
     |  (MODEL vdev_uvm_ep_port or REAL_DUT Host-mem   |
     ```
     old：
     ```
     MODEL responder 当前通过 notification manager sideband 产生等价中断事件，不发送
     真实 MSI-X Memory Write TLP。
     ```
     new：
     ```
     MODEL 设备模型按自己的 MSI-X 表构造 MSI-X Memory Write，并发布到 EP monitor（pcie_tl 的 RC
     会把 EP MemWr 写进 Host memory，APIC 窗口没有后备内存）；VIP observer 与 REAL_DUT 下一样解码。
     ```
  3. 故障边界表 old：
     ```
     | `VQ_FAULT_PRE_DEVICE_READ` | 设备/响应器准备读取 descriptor 前 | MODEL responder；REAL_DUT 需用户/平台另接 fault provider（当前未实现） |
     | `VQ_FAULT_BEFORE_USED` | 写回 used ring 前 | MODEL responder；REAL_DUT 需用户/平台另接 fault provider（当前未实现） |
     ```
     new：
     ```
     | `VQ_FAULT_PRE_DEVICE_READ` | 设备取到链、读 payload 前 | MODEL 设备模型（`ZERO_LEN_BUF`、`WRONG_FLAGS` 作用于设备读到的首描述符）；REAL_DUT 需平台另接 fault provider（当前未实现） |
     | `VQ_FAULT_BEFORE_USED` | 写回 used ring 前 | MODEL 设备模型（`WRONG_USED_LEN` 使完成长度加一）；REAL_DUT 同上 |
     ```
     old：`实际调用方提供一个具体阶段。同一 queue/responder 操作即使依次经过 PRE/POST 两个`
     new：`实际调用方提供一个具体阶段。同一队列/设备操作即使依次经过 PRE/POST 两个`
  4. old：`` `tx_submit()`，由 `virtio_pcie_dut_responder` 通过 EP-originated PCIe DMA ``
     new：`` `tx_submit()`，由设备模型 `vdev_virtio_pci` 通过 EP-originated PCIe DMA ``；
     old：`检查 Host/IOMMU/queue 无泄漏。REAL_DUT 模式不创建这个 responder，只被动观察真实`
     new：`检查 Host/IOMMU/queue 无泄漏。REAL_DUT 模式不创建设备模型，只被动观察真实`；
     old：`分配/映射可写 buffer，MODEL responder 从待注入的 `packet_item` 生成 virtio-net`
     new：`分配/映射可写 buffer，MODEL 设备模型从注入的 `packet_item`（或同队列对 TX 回环帧）生成 virtio-net`。
  5. 执行模式表 old：
     ```
     | `VIRTIO_EXEC_MODEL` | `virtio_pcie_dut_responder` 消费 notify，经过 IOMMU/Host-memory 完成 DMA/used ring，并由 notification manager sideband 模拟中断（非真实 MSI-X TLP） | 无 RTL 时的完整 TLM 闭环 |
     | `VIRTIO_EXEC_REAL_DUT` | 不创建本地 device responder；被动观察真实 RTL 的 PCIe TLP | 真实配置、notify、DMA、used/interrupt 事件和 driver 回收 |
     ```
     new：
     ```
     | `VIRTIO_EXEC_MODEL` | 独立设备模型 `vdev_virtio_pci` 应答配置/BAR、消费 notify、经 IOMMU/EP DMA 完成 ring 与 payload，并按设备 MSI-X 表发 MSI-X MemWr | 无 RTL 时的完整 TLM 闭环；VIP 寄存器序列由设备独立校验 |
     | `VIRTIO_EXEC_REAL_DUT` | 不创建设备模型；被动观察真实 RTL 的 PCIe TLP | 真实配置、notify、DMA、used/interrupt 事件和 driver 回收 |
     ```
     old：`纳入真实 RX 回归。MODEL 的 responder 计数不能作为 RTL 数据面通过的证据。`
     new：`纳入真实 RX 回归。MODEL 设备模型的计数不能作为 RTL 数据面通过的证据。`
     在该段之后（`仓库默认 \`virtio_tb_top.sv\`` 一行之前）插入小节：
     ```
     #### 独立设备模型（`src/devmodel/`）

     | 设备 | ID | BAR0 | BAR2 | BAR4 |
     |------|----|------|------|------|
     | `vdev_virtio_pci` | 1af4:1041 | common@0x0、ISR@0x1000、device_cfg@0x2000 | notify（off=q，multiplier 4） | MSI-X 表@0、PBA@0x8000（`2*max_pairs+2` 向量） |
     | `vdev_dpu_priv` | 20f9:5013 | doorbell@0、AF 声明 0x1010、qid map、VTX/VRX 参数表等（真实驱动 AF 路径） | qinfo | MSI-X（64 向量） |

     设备只依据收到的配置/MMIO 请求维护状态，经 `vdev_port`（`dma_read/dma_write/raise_msix`）访问 Host。
     语义事件经 `event_ap` 输出（`reg_wr/reg_rd/status/features/queue_cfg/notify/desc_chain/pkt/complete/irq/ctrl/marker`，
     `vdev_event::to_json()` 为单行 JSON）。调试 marker：扩展配置空间 0x100 的 VSEC（ID 0x5644），寄存器 0x108，
     写入场景号产生 `marker` 事件。TX 帧原样回环到同队列对的 RX；`inject_rx(pair, frame)` 是设备网络侧激励。
     私有设备的驱动寄存器序列表与疑点见 `vdev_dpu_priv.sv` 文件头；`dpu_priv_config_backend` 按其中 VIP 列访问设备。
     ```
  6. 测试清单与 41 项已在 D1 更新；单元测试表（`| 单元测试 | \`virtio_unit_test.sv\` |` 所在表）在其后加一行
     `| 设备模型单元测试 | \`virtio_vdev_unit_test.sv\` | 无 PCIe | vdev_base、vdev_virtio_pci、vdev_dpu_priv、私有后端寄存器序列 |`。

- [ ] **Step 3: docs/virtio_verification_flow.md**

  1. 图中 old：
     ```
          │ dut_responder + │  │ 真实 RTL DUT             │
          │ model_dma_adapt │  │ DUT DMA ← real_dut_host_ │
     ```
     new：
     ```
          │ vdev_virtio_pci │  │ 真实 RTL DUT             │
          │ + vdev_uvm_ep_  │  │ DUT DMA ← real_dut_host_ │
     ```
     下一行 `│ （发真 EP TLP）  │` 改为 `│ port（发真 EP TLP）│`，保持框线列对齐。
  2. 第 10 步 old（从 `10. **设备侧收 kick（MODEL）**：` 到 `    注意：MODEL 的 MSI-X 走 sideband 直调` 及其后续说明行，直到下一编号步骤之前）new：
     ```
     10. **设备侧收 kick（MODEL）**：notify MemWr 到达 EP driver，`vdev_ep_driver::handle_request` 交给
         `vdev_uvm_ep_port::serve`，按 BAR 窗口分派到 `vdev_virtio_pci::region_write` → `notify()` 核对
         队列已使能且 DRIVER_OK 后排入设备 worker → worker 经 `vdev_uvm_ep_port::dma_read`（IOVA 逐 4KiB
         块经 iommu 翻译，再由 `virtio_pcie_model_dma_adapter` 发 **EP→RC MemRd TLP**）读 avail/desc 链 →
         读/写 payload → MemWr 写 used ring → 按设备 MSI-X 表发 MSI-X MemWr（发布到 EP monitor，observer
         解码为中断事件）。设备只看到 PCIe 请求，不读取 VIP 的 transport/virtqueue。
     ```
  3. REAL_DUT 表 old：`| 设备行为 | 不创建 dut_responder——设备行为全部是 RTL 自己的 |`
     new：`| 设备行为 | 不创建设备模型——设备行为全部是 RTL 自己的 |`

- [ ] **Step 4: examples/dpu_priv_ring/README.md**

  1. “## 1. 在顶层准备设备控制后端” 整节（到 “## 2.” 之前）替换为：
     ```
     ## 1. 设备与配置后端

     私有 Function 的全部设备访问由 `dpu_priv_config_backend` 完成：它按真实驱动 AF 路径（`pfvf_id=0`）
     的寄存器序列访问 BAR0/BAR2——AF 声明（0x1010 魔数 0x5555AAAA、0x60040）、qinfo、MSI-X 映射表、qid map、
     VTX/VRX 队列参数表、共享 doorbell（BAR0+0，`wrap<<31 | tail<<16 | local_qid`）与停队/复位轮询。序列表、
     驱动与 reg plan 的疑点见 `src/devmodel/vdev_dpu_priv.sv` 文件头。PF/VF mailbox 路径未建模。

     纯模型测试使用独立设备模型 `vdev_dpu_priv`：本目录的流程测试把它挂在回环端口上（寄存器访问直达设备，
     设备 DMA 经该 Host 的 IOMMU），设备按 qid map 与参数表处理描述符、写 CQ，并把 TX 帧回环到同一队列对的
     RX。测试旋钮 `stall_queue_stop` 让停队/复位永不完成，用来验证“DMA 未停则保留资源”。PCIe 枚举与 BAR 放置
     属于平台，后端不写 BAR。

     连接真实 DUT 时，在绑定 PCIe 前设置 `vio_cfg.execution_mode = VIRTIO_EXEC_REAL_DUT`
     和 `vio_cfg.completion_mode = VIRTIO_COMPLETION_POLLING`。
     ```
  2. 代码示例删除行 `private_cfg.control = my_device_control;`。
  3. 源码表中 `dpu_priv_driver_config.sv` 行职责改为 “Function/queue 分层配置”；新增一行
     `| \`src/devmodel/vdev_dpu_priv.sv\` | 私有设备模型（驱动寄存器序列、16B 描述符与 CQ、qid map 路由） |`。
  4. “流程测试复用 `examples/virtio_system_env` 顶层：” 一段替换为：
     ```
     流程测试复用 `examples/virtio_system_env` 顶层：两个 Host 各有一个私有 VF 和一个标准 VF，私有 VF 面对
     `vdev_dpu_priv`；验证 env_cfg 到 ops/FSM 的选择、寄存器级后端、TX/RX 原始帧（从设备事件核对描述符长度、
     帧字节与通知字）、引擎委托、停 DMA 失败保护，以及后台启动/停止后的 DMA 回收。合同测试核对 GCC 生成的
     TX/RX/CQ 黄金字节、默认 512 项布局、65537B TX 分片和环回绕，并让 `vdev_dpu_priv` 写出的 CQ 与同一组黄金值
     对齐。
     ```

- [ ] **Step 5: 文档校验与最终 grep**
  ```bash
  cd /home/ubuntu/ryan/virtio_sdd
  grep -rn 'virtio_pcie_dut_responder\|dut_responder\|virtio_feature_select_ep_driver\|dpu_priv_device_control\|dpu_priv_example_control\|dpu_priv_queue_context_t\|priv_control_stub\|private_cfg\.control' \
      README.md docs/virtio_net_vip_manual.md docs/virtio_verification_flow.md examples virtio_net_vip scripts filelists
  grep -n 'responder' README.md docs/virtio_net_vip_manual.md docs/virtio_verification_flow.md | grep -v 'real_dut_host_mem_responder\|Host-memory responder\|Host-mem\|REAL_DUT\|RC 侧'
  ls virtio_net_vip/src/devmodel
  ```
  期望：第一条无输出；第二条无输出或只剩 REAL_DUT Host-memory responder 的上下文行（逐行目视确认）；第三条列出 5 个文件。
  单测 `TEST=virtio_vdev_unit_test`（`test_manifest.sh` 的文档测试清单校验随之运行，必须无 “maintained-test list” 报错）。

- [ ] **Step 6: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=41`。

- [ ] **Step 7: 提交**
  ```bash
  git add README.md docs/virtio_net_vip_manual.md docs/virtio_verification_flow.md examples/dpu_priv_ring/README.md
  git commit -m "docs: README/手册/验证流程同步独立设备模型与寄存器级私有后端"
  ```

---

## Notes for integrator (D)

**最终 `vdev_port` API（E 的 `vdev_cosim_port` 继承它）：**
```systemverilog
virtual class vdev_port extends uvm_object;
    protected vdev_base m_devices[$];
    function void attach(vdev_base dev);                                   // 设置 dev.port
    function vdev_base device_by_bdf(bit [15:0] target);                    // 配置请求分派
    function vdev_base device_by_addr(bit [63:0] addr, output int unsigned bar,
                                      output bit [31:0] offset);            // MMIO 分派（按设备已编程 BAR）
    pure virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                               output bit [7:0] data[], output bit ok);     // addr 为设备可见 IOVA
    pure virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                                output bit ok);
    pure virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
endclass
```
端口把主机请求交给设备的零时间入口（端口实现负责回 Completion）：`vdev_base::cfg_read(bit [11:0] addr)` /
`cfg_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be)`（DW 对齐地址）、`mmio_read(int unsigned bar, bit [31:0] off,
int unsigned size)` / `mmio_write(bar, off, size, data)`（size 1/2/4，值右对齐；多 DW TLP 由端口按 DW/字节使能拆分）。
DMA 与 MSI-X 只在设备 worker（`vdev_base::run_phase`）中调用，可阻塞。cosim 端口若 IOMMU 在 QEMU 侧，`dma_read/write`
直接用 IOVA 调 `dma_read/write_sync`，不经 VIP IOMMU。

**`vdev_event` 字段：** `kind`（`vdev_event_kind_e`：`VDEV_REG_WR/REG_RD/STATUS/FEATURES/QUEUE_CFG/NOTIFY/DESC_CHAIN/PKT/
COMPLETE/IRQ/CTRL/MARKER`）、`fn`（BDF）、`region`、`field`、`q`（-1=无关）、`val`、`from_status/to_status`、
`dev_offered/drv_accepted`、`size`、`vector`、`enable`、`ring_fmt`（split/packed/priv）、`next_idx`、`wrap`、
`seg_len[$]`、`seg_flags[$]`（32 位；标准为 16 位 flags，私有为 W2）、`has_hdr`、`hdr`（`virtio_net_hdr_t`）、`dir`、
`bytes[$]`（以太网帧，不含 header）、`id`、`len`、`ctrl_class/ctrl_cmd/ctrl_data[$]/ack`、`scenario`。
`to_json()` 键名与 `vdev_diff.py` 一致：`ev`、`fn`、`region`、`field`、`q`、`val`、`from`、`to`、`dev_offered`、`drv_accepted`、
`size`、`vector`、`enable`、`ring_fmt`、`next_idx`、`wrap`、`segs`（`[[len,flags],…]`）、`hdr`（对象或 `null`）、`dir`、`len`、
`bytes`（hex，脚本补 sha1）、`id`、`class`、`cmd`、`data`、`ack`、`scenario`。配置空间访问记为 `region="cfg"`、
`field="0x%03h"`。标准 common_cfg 字段名与 Linux `virtio_pci_common_cfg` 一致（`device_feature_select`、`queue_desc_lo/hi`、
`queue_driver_lo/hi`、`queue_device_lo/hi` 等，队列字段 `q`=queue_select）。私有区 `region="bar0"/"bar2"`，字段名见
`vdev_dpu_priv::bar0_field/qinfo_field`（如 `af_declaration`、`mb_af_host_id`、`qid_map.b0.e0.dw0`、`vtx_content.dw2`、
`vrx_tail.0`、`msix_info.0`），`q` 恒为 -1；私有 doorbell 只发 `notify`（`q`=驱动写的 lqid），不发 `reg_wr`。

**调试 cap：** 扩展配置空间 0x100：Vendor-Specific Extended Capability（DW0=`0x0001000B`，DW1=`0x00C05644`），
marker 寄存器 **0x108**（32 位 RW）。写入只发 `marker`（`scenario`=写入值），不发 `reg_wr`。两种设备都带 PCIe 能力（v2），
Linux 开放 4 KiB 配置空间，`setpci -s <BDF> 0x108.L=<n>` 可写。

**设备 ID / BAR：**
- 标准 `vdev_virtio_pci`：1af4:1041，类 0x020000；BAR0 16 KiB（common@0x0 长 0x40、ISR@0x1000、device_cfg@0x2000 长 0x100），
  BAR2 4 KiB（notify，`queue_notify_off=q`，multiplier 4），BAR4 64 KiB（MSI-X 表@0、PBA@0x8000，`2*max_pairs+2` 向量）；
  `num_queues = 2*max_pairs + CTRL_VQ`；能力链 PCIe(0x40) → common → notify → ISR → device → MSI-X。
  **与规范表的偏差：** 规范写“标准：BAR0 virtio 区域，BAR4 MSI-X”，实际 notify 在 BAR2（VIP Fabric 发现强制 notify 位于 mailbox BAR）；E 阶段的 cosim-pcie-pf 需暴露 BAR0/2/4 三对。
- 私有 `vdev_dpu_priv`：20f9:5013，类 0x020000；BAR0 32 MiB，BAR2 64 KiB（qinfo），BAR4 64 KiB（MSI-X 64 向量）。
  参数 `host_id`（qinfo 报告）、`stall_queue_stop`（测试旋钮）；观察 `queue_enabled(tx, gq)`。

**与契约的偏差：**
1. 任务顺序：私有设备（D4）先于寄存器级后端（D5），保证每个任务回归可过。
2. `vdev_event` 定义在 `vdev_port.sv`（端口与设备共用，文件清单不变）。
3. 新增测试件 `virtio_net_vip/tests/vdev_loopback_port.sv`（`vdev_loopback_port`、`vdev_loopback_bar_accessor`、
   `vdev_event_log`、`vdev_expect_catcher`），供单元测试与两个私有测试使用；不进 src。
4. `dpu_priv_ring_contract_test` 的黄金字节子测试仍是队列级（黄金描述符里的地址不是可映射 IOVA，设备无法消费）；
   “面对 vdev_dpu_priv”体现为新增的设备往返子测试（设备写出的 CQ 对齐同一组黄金值）。
5. fixture 的 `inject_rx` 去掉 `net_hdr` 形参（header 由设备生成）；`dut_responder()` 改为 `device()`；responder 的
   start/stop/running 生命周期随 responder 删除，设备复位由驱动写 status=0 完成。
6. 删除 `dpu_priv_queue_context_t` 与 `dpu_priv_config_backend::to_context`（C 保留了 `to_context`；其唯一用途是给已删除的
   `dpu_priv_device_control` 传参），流程测试改用 `virtio_queue_program_t`。
7. D3 修了独立设备暴露的 VIP 缺陷：`set_msix` 写 MSI-X Enable/Function Mask，`notify_mgr` 的屏蔽位写回设备表项。
   fixture 流程因此从 INTx 回退（旧镜像 Table Size=0）改为每队列 MSI-X。

**驱动推导的疑点（详见 D4 表下与 `vdev_dpu_priv.sv` 文件头）：** reg plan 的 VTX ram_cfg 位错（D-1）、plan 缺/多的步骤
（D-2）、qid map 写法（D-3）、srcid=`host<<10` 溢出（D-4）、G2P 截断（D-5）、RX buf_len 2048 vs 描述符 len（D-6）、
RSS srcid（D-7）、`dpu_reset_rx_queue` 恒 0（D-8）、TX 首描述符 len 覆盖（D-9）、ST 判断恒真（D-10）、无 SR-IOV 能力时的
配置读（D-11）；模型推断 M-1..M-9（软复位语义、doorbell→gq 路由、VRX tail 值、CQ 中断与自屏蔽、TX CQ head 含义、QSCH 位、
RX 多描述符、mailbox 未建模、gq/gv 分配）。VIP 后端刻意不做的驱动步骤：#9、#11–15、#18、#19、#22、#23、#26、#30、#32、
#34–38——F 阶段对比私有模式时这些写只出现在 Linux 轨迹，需逐条白名单（理由：与数据队列无关 / mailbox 未建模 / polling /
无 rmmod 对应）。VIP 建队顺序为“每队列对 RX 配置+中断、TX 配置+使能”，驱动是“全部 TX 配置、全部 RX 配置、RSS、全部中断、
全部 TX 使能”，F 阶段若列偏序规则需按此判定。

**风险：**
- 独立设备会暴露更多 VIP 时序问题（例如 DRIVER_OK 前 kick、漏写队列地址）：D3 Step 7 给了逐条判定规则；预计至少
  MSI-X 一项（已列为已知缺陷）。修复数量未知，可能拉长 D3。
- `vdev_uvm_ep_port::raise_msix` 把 MSI-X MemWr 直接写进 EP monitor 的 `tlp_ap`：pcie_tl scoreboard 会把它记为 EP 发出的
  posted 写（只存数据，不比对）；若 pcie_work 日后在 `write_ep` 加严格检查，需要改为专用 analysis port 连到 observer。
- 请求入口与 Completion 接收共用 TLM 线程：设备 MMIO 处理必须零时间（已按此设计），任何在 `serve` 里加入等待都会死锁。
- `fork`/`event` 驱动的单 worker 串行处理所有队列：大流量测试（dual/full 只走寄存器，不走设备数据面）不受影响；若后续把
  bandwidth 类测试接到设备数据面，吞吐受单 worker 限制。
- 私有后端每次 discover 读写 qid map 128×8 次 MMIO；VCS 下经 pcie_tl 时约增加数千 TLP，若 E/F 的私有 cosim 慢可减为只写
  有效项（会偏离驱动序列，需白名单）。
- 规范 R4 验收“40 个回归测试在新模型下全部通过”：实际变为 41（新增设备单元测试）；`virtio_e2e_test` 自带 EP 镜像，不经设备模型。
- src 行数净增约 1.7k（devmodel 约 2.4k，删 responder 844、私有控制接口约 45、后端净增约 200）。

## 阶段 E：53 上临时 cosim 冒烟（`~/cosim_diff/`）

本阶段的代码和产物只放在 53 `~/cosim_diff/`（本地 git，不推送），不进入 `virtio_sdd`。阶段 F 中发现的 VIP 或设备模型缺陷，在 `virtio_sdd` 中修复并提交，遵守 Global Constraints。

**调研结论（2026-10-07，只读调研，影响本阶段做法）：**

1. **`cosim-pcie-pf` 不能直接用于单 PF。** `qemu-plugin/cosim_pcie_pf.c` 中 `cosim_pf_addr_is_local()` 把配置空间 0x34–0x37、0x40–0xFF 和 0x100 以上全部留在 QEMU 本地，不转发到 VCS。结果是设备模型的整条 cap 链在 guest 中不可见，包括 virtio vendor cap、调试 marker cap 和设备侧 MSI-X cap。QEMU 自己的 MSI-X 表放在 BAR0 偏移 0（`msix_init(... bar_nr = 0 ...)`），会盖住 common_cfg。所以规范里“只改 `NUM_PFS=1` 时选 `cosim-pcie-pf`”这一处不够：virtio_pci modern probe 找不到 COMMON_CFG，驱动不会绑定。
2. **`cosim-pcie-rc`（`NUM_PFS=1` 时 Makefile 的默认选择）转发全部配置空间**，0x100 以上也转发，因为它是 `INTERFACE_PCIE_DEVICE`。设备模型因此可以独占配置空间和 MSI-X。它的缺口是只注册 BAR0，而且是 32 位。59 上已经跑通过一条链路（`docs/COSIM-ETH-MSIX-DEBUG.md` §2.2）：MSI-X 由 VCS 用 `bridge_vcs_dma_write_sync` 写消息地址，经 `pci_dma_write` 投递到 APIC，ICMP 能双向往返。
3. 因此 E1 推荐**路线 R**：在 `cosim-pcie-rc` 上打一个本地补丁，内容是多 BAR（64 位）注册、MMIO 最大访问宽度改为 4、APIC 区 DMA 写改由 BH 投递。**路线 P**（改 `cosim-pcie-pf`）作为备选。这偏离了规范“使用 cosim-pcie-pf”的字面要求，见 E1 决策点 D-E1，执行前需要用户确认。
4. Guest 镜像 `guest/images/ubuntu` 的内核是 `6.8.0-107-generic`，用户态却是 **Alpine 3.20**（busybox、openrc），没有 gcc 和 python3。`/usr/sbin/setpci`、`/usr/bin/lspci`、`/usr/sbin/ethtool`、`/sbin/ip` 都有。`modules.builtin` 显示 **virtio、virtio_pci、virtio_net、virtio_blk 都是内建的**：启动时 virtio_net 就会绑定标准设备，`modprobe`/`rmmod` 用不了。标准模式下 S1/S4 改用 sysfs `bind`/`unbind` 代替。
5. 53 是 Ubuntu 20.04，只有 gcc 9.4。`/usr/local` 下有 glib 2.66.8，满足 QEMU 9.2 的 ≥2.66 要求，系统自带的是 2.64.6。另有 python 3.8.10 + tomli 2.4.1，meson 用 QEMU 自带的 wheel 1.5.0，ninja 1.10.0、pixman 0.38.4、libfdt 1.5.1、cmake 3.16.3、e2fsprogs 1.45.5 均已就绪，`~` 剩余 70G。`/dev/shm` 已用 84%，剩 1.3G，够 16MB SHM。
6. `dpu_snd1.ko` 不能在 53 上针对 6.8 编译：noble 头文件包里的 `fixdep`/`modpost` 需要 glibc ≥ 2.34，内核 `.config` 打开的编译选项需要 gcc ≥ 12。**本机（Ubuntu 24.04，gcc 13.3）可以 `apt download linux-headers-6.8.0-107{,-generic}`，已确认有候选版本**，所以在本机编译。规范给的回退方案“用 Debian 镜像在 guest 内编译”不可行：Debian 镜像内核 6.1.0-42，没有 gcc、没有头文件，guest 也没有网络。
7. 53 上另有一份 `~/test_cosim`，属于其他工作，不要碰。59 上的 cosim-platform 位于 HEAD `6b99406`，另有 10 个文件未提交修改，按工作树原样复制并记录。

约定（以下各任务通用）：
```bash
S53='sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53'
PUT() { sshpass -p ubuntu scp -o StrictHostKeyChecking=no "$1" "ubuntu@10.11.10.53:cosim_diff/$2"; }   # 本机写好后放到 53
```
53 上的目录布局（E1 建立）：
```
~/cosim_diff/
  cosim-platform/   59 工作树副本 + 本地补丁（git 跟踪）
  qemu/             QEMU 9.2.0 源码与构建（git 忽略）
  images/           vmlinuz、rootfs.orig.ext4、rootfs.ext4（git 忽略）
  sv/               vdev_cosim_pkg.sv、cosim_vdev_top.sv、vdev_diff_pkg.sv、vdev_diff_tests.sv
  guest/            vdev-init、vdev_lib.sh、vdev_smoke.sh、run_scenarios.sh、vdev_pktgen.c、inject.sh
  drv/              src/（icpu-kernel-driver 只读副本）、patches/、SOURCE
  tools/            vdev_diff.py
  build_cosim.sh run_cosim.sh vip_diff.sh
  rules_priv.json whitelist_std.json whitelist_priv.json triage_std.md triage_priv.md
  build/ out/ run/ logs/   （git 忽略）
```

---

### Task E1: 53 临时环境（cosim-platform 副本、bridge、QEMU 9.2.0、guest 镜像、单 Function 多 BAR 补丁）

**Files:**
- Create (53): `~/cosim_diff/.gitignore`、`~/cosim_diff/cosim-platform/`（rsync 副本）、`~/cosim_diff/cosim-platform.SOURCE`
- Modify (53，路线 R): `~/cosim_diff/cosim-platform/qemu-plugin/cosim_pcie_rc.c`、`~/cosim_diff/cosim-platform/qemu-plugin/cosim_pcie_rc.h`
- Create (53): `~/cosim_diff/qemu/`（解压 `~/qemu-9.2.0.tar.xz` 并构建）、`~/cosim_diff/images/{vmlinuz,rootfs.orig.ext4,rootfs.ext4}`
- Test: `qemu-system-x86_64 -device help`、无 VCS 时的连接超时探测

**Interfaces:**
- Consumes: 59 `ryan@10.11.10.59:~/workspace/ryan/software/cosim-platform`（pw 123），53 `~/qemu-9.2.0.tar.xz`，`/usr/local/lib/x86_64-linux-gnu` 下的 glib 2.66.8。
- Produces:
  - `~/cosim_diff/qemu/build/qemu-system-x86_64`，提供 `cosim-pcie-rc`（以及未改动的 `cosim-pcie-pf`/`cosim-pcie-vf`）。
  - `~/cosim_diff/cosim-platform/build/bridge/libcosim_bridge.so`。
  - 路线 R 下，`cosim-pcie-rc` 的行为：
    - realize 时通过 CfgRd/CfgWr 测量 VCS 端 BAR0..5，按测得的 32/64 位和 prefetch 属性注册全部内存 BAR。
    - 配置空间整段转发给 VCS。
    - MMIO 访问拆成不超过 4 字节的单 DW TLP。
    - 落在 0xFEE00000–0xFEEFFFFF 的 4 字节 DMA 写（MSI-X 消息）由 QEMU 主循环 BH 用 `pci_dma_write` 投递；DMA completion 立即返回给 VCS。
    - 按阶段 D 的设备布局，guest 应看到三对 64 位非预取 BAR：标准 `vdev_virtio_pci`（1af4:1041）BAR0 16 KiB（common/ISR/device_cfg）、BAR2 4 KiB（notify）、BAR4 64 KiB（MSI-X 表@0、PBA@0x8000，6 个向量）；私有 `vdev_dpu_priv`（20f9:5013）BAR0 32 MiB、BAR2 64 KiB（qinfo）、BAR4 64 KiB（MSI-X，64 个向量）。补丁按 sizing 注册，不写死尺寸。

**决策点 D-E1（执行前请用户确认）：** 规范写的是“使用 cosim-pcie-pf”，但调研结论 1 说明 pf 在单 PF 下看不到设备模型的 cap 链。

| 路线 | 改动 | 设备模型看到的东西 | 代价 |
|---|---|---|---|
| R（推荐） | `cosim_pcie_rc.{c,h}` 约 80 行：多 BAR 注册、max_access 4、APIC 写转 BH | 全部配置空间、MSI-X 表和 PBA 的 MMIO，与 VCS 回归中的 UVM EP 端口一致 | MSI-X 经 DMA 写投递（59 已验证）。DMA 不转 BH 的话，VCS 同步等待与持 BQL 的 vCPU MMIO 会互等，所以补丁必须带 BH 投递 |
| P（备选） | `cosim_pcie_pf.c`：`cosim_pf_addr_is_local` 只保留 QEMU 自有 cap 的范围；MSI-X 移到 BAR4（`cap_pos=0xB0`），PCIe cap 移到 0xC0，0xC1 的 next 指向 VCS 的 0x34 链头；VCS 用 `bridge_vcs_raise_msi(vector)` | 设备 cap 链可见，但看不到 MSI-X 使能和屏蔽。D 的 `vdev_base` 能力链从 0x40 起（PCIe cap 在 0x40），与 QEMU 自有 cap 冲突 | 除 QEMU 改动外还要改 D 的设备底座：D 没有“MSI-X 由主机侧持有”开关，`vdev_port::raise_msix(requester, addr, data)` 只给消息地址和数据、不给向量号。本计划不含这些改动 |

用户确认前不进入 Step 4。如果路线 R 在 E2 冒烟中三轮修正后仍不能完成枚举或中断投递，停下汇报：改走路线 P 需要先在 `virtio_sdd` 中给 D 的设备底座加上述开关和按向量投递的端口接口，属于扩大范围，由用户决定。

- [ ] **Step 1: 建目录与本地 git，复制 cosim-platform 工作树**

  ```bash
  $S53 'set -euo pipefail
  CD=$HOME/cosim_diff; mkdir -p $CD/{images,build,out,run,logs,sv,guest,drv,tools}; cd $CD
  git init -q; git config user.name Ryan; git config user.email ssymtdhb@gmail.com
  printf "images/\nqemu/\nbuild/\nout/\nrun/\nlogs/\ncosim-platform/build/\ndrv/src/*.o\ndrv/src/*.ko\nguest/vdev_pktgen\nguest/dpu_snd1.ko\n" > .gitignore
  sshpass -p 123 rsync -a -e "ssh -o StrictHostKeyChecking=no" \
    --exclude .git --exclude "build*/" --exclude vcs_sim --exclude logs --exclude run \
    --exclude guest/images --exclude "*.png" --exclude "*.pptx" --exclude __pycache__ \
    ryan@10.11.10.59:workspace/ryan/software/cosim-platform/ $CD/cosim-platform/
  sshpass -p 123 ssh -o StrictHostKeyChecking=no ryan@10.11.10.59 \
    "cd ~/workspace/ryan/software/cosim-platform && git rev-parse HEAD && git status --porcelain" > $CD/cosim-platform.SOURCE
  git add -A && git commit -qm "chore: 导入 cosim-platform 工作树副本（59 6b99406 + 未提交改动）"
  head -3 cosim-platform.SOURCE; ls cosim-platform/qemu-plugin cosim-platform/bridge/vcs'
  ```
  期望：`cosim-platform.SOURCE` 首行是 `6b99406...`；能列出 `cosim_pcie_rc.c`、`cosim_pcie_pf.c`、`bridge_vcs.sv`、`bridge_vcs.c`。

- [ ] **Step 2: 复制 Ubuntu guest 镜像（只要 vmlinuz 和 rootfs）**

  ```bash
  $S53 'set -euo pipefail; CD=$HOME/cosim_diff
  for f in vmlinuz rootfs.ext4; do
    sshpass -p 123 rsync -a -e "ssh -o StrictHostKeyChecking=no" \
      ryan@10.11.10.59:workspace/ryan/software/cosim-platform/guest/images/ubuntu/$f $CD/images/
  done
  mv $CD/images/rootfs.ext4 $CD/images/rootfs.orig.ext4
  cp $CD/images/rootfs.orig.ext4 $CD/images/rootfs.ext4
  file $CD/images/vmlinuz
  /sbin/dumpe2fs -h $CD/images/rootfs.ext4 2>/dev/null | grep -E "features|Free blocks"
  /sbin/debugfs -R "cat /etc/os-release" $CD/images/rootfs.ext4 2>/dev/null | head -1'
  ```
  期望：`version 6.8.0-107-generic`。features 不含 `orphan_file`；含的话 53 的 e2fsprogs 1.45 写不了，需要在 59 上用 `tune2fs -O ^orphan_file` 处理一份副本再拷。`Free blocks` 约 41652（4K 块，约 160MB），无需扩容。`NAME="Alpine Linux"`。

- [ ] **Step 3: 编译 bridge 库**

  ```bash
  $S53 'set -euo pipefail; cd ~/cosim_diff/cosim-platform
  cmake -B build -DCMAKE_BUILD_TYPE=Debug > ../logs/bridge_cmake.log 2>&1
  cmake --build build -j8 > ../logs/bridge_build.log 2>&1 || cmake --build build -j8 --target cosim_bridge cosim_bridge_vcs >> ../logs/bridge_build.log 2>&1
  ls -l build/bridge/libcosim_bridge.so build/bridge/libcosim_bridge_vcs.so'
  ```
  期望两个 `.so` 都存在。全量构建失败时会退回只构建这两个目标，测试程序编译失败不影响后续步骤。

- [ ] **Step 4: 路线 R 补丁，`cosim_pcie_rc.h`**

  在 `struct CosimPCIeRC` 末尾的 `volatile int msi_queue_tail;` 之后追加（old → new）：
  ```c
      volatile int msi_queue_tail;   /* irq_poller 线程写 */
  };
  ```
  ```c
      volatile int msi_queue_tail;   /* irq_poller 线程写 */

      /* cosim_diff 本地补丁：APIC 区 DMA 写（MSI-X 消息）转主循环 BH 投递。
       * vCPU 持 BQL 阻塞等待 MRd 完成时，若 irq_poller 线程同步投递 MSI 需要 BQL，
       * 而 VCS 正在同步等待该 DMA 完成，双方互等。转 BH 后 DMA 立即完成。 */
      void *msix_bh;
      uint64_t msix_addr[COSIM_MSI_QUEUE_SIZE];
      uint32_t msix_data[COSIM_MSI_QUEUE_SIZE];
      volatile int msix_head;
      volatile int msix_tail;
  };
  ```

- [ ] **Step 5: 路线 R 补丁，`cosim_pcie_rc.c`**

  (a) 在 `cosim_dma_cb` 定义之前插入：
  ```c
  /* cosim_diff 本地补丁：MSI-X 消息写延迟到主循环投递（见 cosim_pcie_rc.h） */
  static void cosim_msix_bh_cb(void *opaque)
  {
      CosimPCIeRC *s = COSIM_PCIE_RC(opaque);

      while (s->msix_head != s->msix_tail) {
          int idx = s->msix_head % COSIM_MSI_QUEUE_SIZE;
          uint64_t addr = s->msix_addr[idx];
          uint32_t data = cpu_to_le32(s->msix_data[idx]);
          __atomic_thread_fence(__ATOMIC_ACQUIRE);
          s->msix_head++;
          pci_dma_write(PCI_DEVICE(s), addr, &data, sizeof(data));
      }
  }

  static bool cosim_defer_msix(CosimPCIeRC *s, uint64_t addr,
                               const uint8_t *buf, uint32_t len)
  {
      int tail = s->msix_tail;

      if (addr < 0xFEE00000ULL || addr >= 0xFEF00000ULL || len != 4) {
          return false;
      }
      if (tail - s->msix_head >= COSIM_MSI_QUEUE_SIZE) {
          qemu_log("cosim: MSI-X defer queue full, drop addr=0x%" PRIx64 "\n", addr);
          return true;
      }
      s->msix_addr[tail % COSIM_MSI_QUEUE_SIZE] = addr;
      s->msix_data[tail % COSIM_MSI_QUEUE_SIZE] = ldl_le_p(buf);
      __atomic_thread_fence(__ATOMIC_RELEASE);
      s->msix_tail = tail + 1;
      qemu_bh_schedule((QEMUBH *)s->msix_bh);
      return true;
  }
  ```
  (b) `cosim_dma_cb` 的 TCP 写分支，old：
  ```c
              pci_dma_write(PCI_DEVICE(s), req->host_addr, buf, len);
              bridge_complete_dma(ctx, req->tag, 0);
  ```
  new：
  ```c
              if (!cosim_defer_msix(s, req->host_addr, buf, len)) {
                  pci_dma_write(PCI_DEVICE(s), req->host_addr, buf, len);
              }
              bridge_complete_dma(ctx, req->tag, 0);
  ```
  SHM 写分支，old：
  ```c
          if (req->direction == DMA_DIR_WRITE) {
              cpu_physical_memory_write(req->host_addr, dma_buf, req->len);
          } else {
  ```
  new：
  ```c
          if (req->direction == DMA_DIR_WRITE) {
              if (!cosim_defer_msix(s, req->host_addr, dma_buf, req->len)) {
                  cpu_physical_memory_write(req->host_addr, dma_buf, req->len);
              }
          } else {
  ```
  (c) `cosim_mmio_ops` 的 `.max_access_size = 8,` 改为 `.max_access_size = 4,`。原因：读写路径只构造 4 字节 TLP，`first_be` 是 `uint8_t`，8 字节访问会丢掉高 DW。
  (d) 删除已不再使用的 `cosim_query_bar_size()`。在 `cosim_pcie_rc_realize` 中，把 old：
  ```c
      /* BAR sizing — 查询 BAR0 大小 */
      uint32_t bar0_size = cosim_query_bar_size(ctx, 0);
      if (bar0_size == 0) bar0_size = 64 * 1024;  /* fallback 64KB */
      COSIM_DPRINTF(s, "realize BAR0 size: %u bytes (0x%x)\n",
              bar0_size, bar0_size);
  ```
  删除，再把 old：
  ```c
      /* 注册 BAR0 — opaque 指向 CosimBarContext（携带 bar_index） */
      s->bar_ctx[0].dev = s;
      s->bar_ctx[0].bar_index = 0;
      memory_region_init_io(&s->bars[0], OBJECT(s), &cosim_mmio_ops,
                            &s->bar_ctx[0], "cosim-bar0", bar0_size);
      pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bars[0]);
      s->num_bars = 1;
  ```
  替换为：
  ```c
      /* cosim_diff 本地补丁：按 VCS EP 的 BAR sizing 注册 BAR0..5（含 64 位与 prefetch） */
      for (int i = 0; i < COSIM_MAX_BARS; i++) {
          uint32_t reg  = PCI_BASE_ADDRESS_0 + i * 4;
          uint32_t orig = cosim_cfgrd(ctx, reg);
          cosim_cfgwr(ctx, reg, 0xFFFFFFFF);
          uint32_t lo = cosim_cfgrd(ctx, reg);
          cosim_cfgwr(ctx, reg, orig);
          if (lo == 0 || lo == 0xFFFFFFFF || (lo & PCI_BASE_ADDRESS_SPACE_IO)) {
              continue;
          }
          bool is64 = (lo & PCI_BASE_ADDRESS_MEM_TYPE_MASK) == PCI_BASE_ADDRESS_MEM_TYPE_64;
          uint64_t mask = 0xFFFFFFFF00000000ULL | (lo & PCI_BASE_ADDRESS_MEM_MASK);
          if (is64 && i + 1 < COSIM_MAX_BARS) {
              uint32_t orig_hi = cosim_cfgrd(ctx, reg + 4);
              cosim_cfgwr(ctx, reg + 4, 0xFFFFFFFF);
              uint32_t hi = cosim_cfgrd(ctx, reg + 4);
              cosim_cfgwr(ctx, reg + 4, orig_hi);
              mask = ((uint64_t)hi << 32) | (lo & PCI_BASE_ADDRESS_MEM_MASK);
          }
          uint64_t size = ~mask + 1;
          char name[16];
          snprintf(name, sizeof(name), "cosim-bar%d", i);
          s->bar_ctx[i].dev = s;
          s->bar_ctx[i].bar_index = i;
          memory_region_init_io(&s->bars[i], OBJECT(s), &cosim_mmio_ops,
                                &s->bar_ctx[i], name, size);
          pci_register_bar(pci_dev, i,
                           PCI_BASE_ADDRESS_SPACE_MEMORY |
                           (lo & (PCI_BASE_ADDRESS_MEM_TYPE_MASK | PCI_BASE_ADDRESS_MEM_PREFETCH)),
                           &s->bars[i]);
          s->num_bars++;
          COSIM_DPRINTF(s, "realize BAR%d size=0x%" PRIx64 " %s\n",
                        i, size, is64 ? "64-bit" : "32-bit");
          if (is64) {
              i++;
          }
      }
      if (s->num_bars == 0) {
          error_setg(errp, "cosim: VCS EP exposes no memory BAR");
          bridge_destroy(ctx);
          s->bridge_ctx = NULL;
          return;
      }
  ```
  (e) realize 中 `s->msi_bh = qemu_bh_new(cosim_msi_bh_cb, s);` 之后追加：
  ```c
      s->msix_head = 0;
      s->msix_tail = 0;
      s->msix_bh = qemu_bh_new(cosim_msix_bh_cb, s);
  ```
  `cosim_pcie_rc_exit` 中，`msi_bh` 释放块之后追加：
  ```c
      if (s->msix_bh) {
          qemu_bh_delete((QEMUBH *)s->msix_bh);
          s->msix_bh = NULL;
      }
  ```
  提交：`cd ~/cosim_diff && git add -A && git commit -qm "patch(rc): 多 BAR、单 DW MMIO、MSI-X 消息转 BH 投递"`。

- [ ] **Step 6: 解压 QEMU、注入插件并构建**

  ```bash
  $S53 'set -euo pipefail; CD=$HOME/cosim_diff; CP=$CD/cosim-platform; cd $CD
  tar xJf ~/qemu-9.2.0.tar.xz && mv qemu-9.2.0 qemu
  cp $CP/qemu-plugin/cosim_pcie_{rc,pf,vf}.c qemu/hw/net/
  cp $CP/qemu-plugin/cosim_pcie_{rc,pf,vf}.h qemu/include/hw/net/
  cp $CP/bridge/common/cosim_topology.h qemu/include/hw/net/
  cat >> qemu/hw/net/meson.build <<EOF

  # CoSim PCIe devices（cosim_diff 临时）
  system_ss.add(files('"'"'cosim_pcie_rc.c'"'"'))
  system_ss.add(files('"'"'cosim_pcie_pf.c'"'"'))
  system_ss.add(files('"'"'cosim_pcie_vf.c'"'"'))
  EOF
  patch -d qemu -p1 < $CP/qemu-plugin/patches/0001-pcie-sriov-skip-acpi-hotplug-for-vf.patch
  cd qemu && ./configure --target-list=x86_64-softmmu --disable-docs --disable-werror \
    --extra-cflags="-I$CP/bridge/common -I$CP/bridge/qemu" \
    --extra-ldflags="-L$CP/build/bridge -lcosim_bridge -Wl,-rpath,$CP/build/bridge -Wl,-rpath,/usr/local/lib/x86_64-linux-gnu" \
    > $CD/logs/qemu_configure.log 2>&1
  ninja -C build -j8 qemu-system-x86_64 > $CD/logs/qemu_build.log 2>&1; echo build_rc=$?'
  ```
  期望 `build_rc=0`，8 核约 15–25 分钟。configure 报 glib 版本不足时，先在命令前加 `PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig` 再试（`pkg-config --modversion glib-2.0` 当前已返回 2.66.8）。之后修改插件时，按 Step 6 的 `cp` 重新复制一遍，再 `ninja -C build qemu-system-x86_64` 增量构建。

- [ ] **Step 7: 验证 QEMU 与 bridge 连接路径**

  ```bash
  $S53 'set -u; CD=$HOME/cosim_diff; Q=$CD/qemu/build/qemu-system-x86_64
  $Q --version | head -1
  ldd $Q | grep -E "not found|libglib|libcosim_bridge"
  $Q -device help 2>&1 | grep -E "cosim-pcie-(rc|pf|vf)"
  rm -f $CD/run/probe.sock; COSIM_CONNECT_TIMEOUT=5 timeout 60 $Q -M q35 -display none -monitor none \
    -device cosim-pcie-rc,shm_name=/vdev_probe,sock_path=$CD/run/probe.sock > $CD/logs/probe.log 2>&1; echo probe_rc=$?
  grep -iE "bridge_connect|timeout|超时" $CD/logs/probe.log | head -3; rm -f /dev/shm/vdev_probe'
  ```
  期望：
  - 第一行为 `QEMU emulator version 9.2.0`。
  - ldd 没有 `not found`，glib 指向 `/usr/local/lib/x86_64-linux-gnu`，`libcosim_bridge.so` 指向 `cosim-platform/build/bridge`。
  - 三个 cosim 设备都在列表里。
  - `probe_rc` 非 0，日志里有 `bridge_connect failed` 或等待超时字样，说明 SHM 与 socket 建立路径可用。

---

### Task E2: VCS 侧 cosim 顶层与冒烟（`vdev_cosim_port`、`cosim_vdev_top`、`+VDEV=std|priv`）

**Files:**
- Create (53): `~/cosim_diff/sv/vdev_diff_pkg.sv`（cosim 与 VIP 对比测试共用的设备参数；F1 再加记录器）、`~/cosim_diff/sv/vdev_cosim_pkg.sv`、`~/cosim_diff/sv/cosim_vdev_top.sv`
- Create (53): `~/cosim_diff/build_cosim.sh`、`~/cosim_diff/run_cosim.sh`
- Create (53): `~/cosim_diff/guest/vdev-init`、`~/cosim_diff/guest/vdev_lib.sh`、`~/cosim_diff/guest/vdev_smoke.sh`、`~/cosim_diff/guest/inject.sh`
- Test: `run_cosim.sh std smoke`、`run_cosim.sh priv smoke`

**Interfaces:**
- Consumes:
  - 阶段 D 的 `vdev_port`、`vdev_base`、`vdev_virtio_pci`、`vdev_dpu_priv`，编在 `virtio_net_pkg` 中（D Notes 的最终 API）：
    - `vdev_port`：`attach(vdev_base)`、`device_by_bdf(bit [15:0])`、`device_by_addr(addr, output int unsigned bar, output bit [31:0] offset)`；纯虚 `dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len, output bit [7:0] data[], output bit ok)`、`dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[], output bit ok)`、`raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data)`。
    - `vdev_base`（`uvm_component`，构造时建 `event_ap`）：字段 `bdf`；先设参数再调 `init()`；零时间入口 `function bit [31:0] cfg_read(bit [11:0] addr)`、`function void cfg_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be)`、`function bit [31:0] mmio_read(int unsigned bar, bit [31:0] off, int unsigned size)`、`function void mmio_write(int unsigned bar, bit [31:0] off, int unsigned size, bit [31:0] data)`（size 1/2/4，值右对齐）。DMA 与 MSI-X 只由设备自己的 `run_phase` worker 发起；MSI-X 表、屏蔽和 PBA 由 `vdev_base` 处理，端口只投递消息写。
    - 参数：`vdev_virtio_pci` 的 `device_features`、`max_pairs`、`queue_max`；`vdev_dpu_priv` 的 `host_id`（0 即 qinfo 报 pfvf_id=0、host 0，驱动走 AF 路径）。
    - 调试 VSEC：扩展配置空间 0x100（DW0=`0x0001000B`，DW1=`0x00C05644`），marker 寄存器 `vdev_base::DEBUG_MARKER_OFF`=0x108，写入只发 `marker` 事件。
  - `cosim_bridge_pkg`（`cosim-platform/bridge/vcs/bridge_vcs.sv`），用到的 DPI 签名（原文）：
    ```systemverilog
    import "DPI-C" function int bridge_vcs_init(input string shm_name, input string sock_path);
    import "DPI-C" function int bridge_vcs_poll_tlp_scalar();          // 0=取到 1=空 -1=QEMU 断开
    import "DPI-C" function int bridge_vcs_get_poll_type();            // 0 MWr 1 MRd 2 CfgWr 3 CfgRd
    import "DPI-C" function longint bridge_vcs_get_poll_addr();
    import "DPI-C" function int bridge_vcs_get_poll_len();
    import "DPI-C" function int bridge_vcs_get_poll_tag();
    import "DPI-C" function int unsigned bridge_vcs_get_poll_data(input int index);
    import "DPI-C" function byte unsigned bridge_vcs_get_poll_first_be();
    import "DPI-C" function void bridge_vcs_set_cpl_data(input int index, input int unsigned value);
    import "DPI-C" function int bridge_vcs_send_cpl_scalar(input int tag, input int len);
    import "DPI-C" function int bridge_vcs_dma_read_sync(input longint unsigned host_addr,
                                                         output int unsigned data[16], input int len);
    import "DPI-C" function int bridge_vcs_dma_write_sync(input longint unsigned host_addr,
                                                          input int unsigned data[16], input int len);
    ```
    规范里的 `poll_tlp`/`send_completion` 用标量版本 `bridge_vcs_poll_tlp_scalar` + getter、`bridge_vcs_set_cpl_data` + `bridge_vcs_send_cpl_scalar` 实现。cosim-platform 注释说 VCS 在 package/class 作用域调用带 output 数组参数的 DPI 会崩，标量版本绕开了这个问题。`dma_read/write_sync` 每次最多 64 字节，按 64 字节分块。
- Produces:
  - `~/cosim_diff/build/simv_cosim`，top 为 `cosim_vdev_top`，test 为 `cosim_vdev_test`。plusarg：`+VDEV=std|priv`、`+SHM_NAME`、`+SOCK_PATH`、`+SIM_TIMEOUT_MS`。设备 BDF 固定为 `COSIM_BDF`=0x0018（guest 00:03.0）。
  - `run_cosim.sh <std|priv> <smoke|scen> [N]`，输出目录 `~/cosim_diff/out/<dev>/<mode>/`，包含 `guest.log`、`qemu.log`、`vcs.log`，F1 之后还有 `linux.jsonl`。
  - 规范里的 `+BYPASS_CONFIG` 在本顶层不需要：不例化 `pcie_ep_stub`/`config_proxy`，配置空间直接由设备模型应答，效果与 BYPASS 相同。

- [ ] **Step 1: 写 `~/cosim_diff/sv/vdev_diff_pkg.sv` 与 `~/cosim_diff/sv/vdev_cosim_pkg.sv`**

  `vdev_diff_pkg.sv`（cosim 顶层与 F2/F3 的 VIP 对比测试共用；F1 在 `endpackage` 前加入记录器）：
  ```systemverilog
  // vdev_diff_pkg.sv —— 临时：cosim 一侧与 VIP 一侧共用的设备参数和 marker 发送。只在 53 ~/cosim_diff 编译。
  `ifndef VDEV_DIFF_PKG_SV
  `define VDEV_DIFF_PKG_SV
  package vdev_diff_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import virtio_net_pkg::*;

    // 标准设备参数。VIP 一侧由 virtio_real_driver_flow_fixture::configure_devices 交给 vdev_virtio_pci：
    // max_pairs = virtio_cfg.default_num_pairs（2），queue_max = default_queue_size（256），
    // device_features = flow.device_features（对比测试在 fixture build_phase 前写入本常量）。两侧必须相同。
    localparam int unsigned VDEV_DIFF_STD_PAIRS     = 2;
    localparam int unsigned VDEV_DIFF_STD_QUEUE_MAX = 256;
    localparam bit [63:0]   VDEV_DIFF_STD_FEATURES  = (64'h1 << VIRTIO_F_VERSION_1) |
                                                      (64'h1 << VIRTIO_NET_F_MAC) |
                                                      (64'h1 << VIRTIO_NET_F_CTRL_VQ) |
                                                      (64'h1 << VIRTIO_NET_F_MQ);

    // 发场景 marker：走设备的零时间配置写入口写调试 VSEC 的 marker 寄存器（0x108），
    // 与 guest `setpci -s <BDF> 108.L=<n>` 产生同一个 marker 事件（不产生 reg_wr）。
    function automatic void vdev_marker(vdev_base dev, int unsigned scenario);
      dev.cfg_write(vdev_base::DEBUG_MARKER_OFF, scenario, 4'hf);
    endfunction
  endpackage
  `endif
  ```

  `vdev_cosim_pkg.sv`：
  ```systemverilog
  // vdev_cosim_pkg.sv —— 临时：QEMU cosim 端口与 cosim 测试。只在 53 ~/cosim_diff 编译，不进入 virtio_sdd。
  `ifndef VDEV_COSIM_PKG_SV
  `define VDEV_COSIM_PKG_SV
  package vdev_cosim_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import virtio_net_pkg::*;
    import cosim_bridge_pkg::*;
    import vdev_diff_pkg::*;

    // bridge/common/cosim_types.h 的 tlp_type_t
    localparam int BV_MWR   = 0;
    localparam int BV_MRD   = 1;
    localparam int BV_CFGWR = 2;
    localparam int BV_CFGRD = 3;
    localparam int DMA_CHUNK = 64;   // bridge_vcs_dma_*_sync 单次上限（data[16]）
    // run_cosim.sh 把 cosim-pcie-rc 放在 addr=0x3，guest 中为 00:03.0。只影响事件的 fn，vdev_diff.py 不比 fn。
    localparam bit [15:0] COSIM_BDF = 16'h0018;

    // vdev_port 的 DPI 实现：QEMU cosim 设备 <-> 设备模型。QEMU 发来的请求都是单 DW：
    //   CfgRd：addr 为 DW 对齐的配置偏移；CfgWr：addr 为字节偏移，len=1/2/4，数据在低位；
    //   MRd/MWr：addr 为 DW 对齐的完整 PCIe 地址，first_be 指出有效字节，MWr 数据已在字节通道上。
    // MWr/CfgWr 是 fire-and-forget，不回 completion。链路上只有一个 Function，配置请求按 COSIM_BDF 分派；
    // MMIO 按设备已编程的 BAR 窗口分派（device_by_addr）。设备入口是零时间函数，不会阻塞 serve()。
    // DMA/MSI-X 由设备 worker 调用；guest 没有 vIOMMU，addr 即 guest 物理地址，requester 不使用。
    class vdev_cosim_port extends vdev_port;
      `uvm_object_utils(vdev_cosim_port)

      int unsigned poll_ns = 200;
      int unsigned n_cfg_rd, n_cfg_wr, n_mem_rd, n_mem_wr, n_dma_rd, n_dma_wr, n_msix;

      function new(string name = "vdev_cosim_port");
        super.new(name);
      endfunction

      function void open_shm(string shm_name, string sock_path);
        if (bridge_vcs_init(shm_name, sock_path) != 0)
          `uvm_fatal("COSIM_PORT", $sformatf("bridge_vcs_init(%s, %s) failed", shm_name, sock_path))
      endfunction

      // 服务 QEMU 请求，直到 QEMU 退出（bridge 返回 -1）。
      task serve();
        int ret;
        forever begin
          ret = bridge_vcs_poll_tlp_scalar();
          if (ret < 0) begin
            `uvm_info("COSIM_PORT", $sformatf(
                "QEMU 断开 cfg_rd=%0d cfg_wr=%0d mem_rd=%0d mem_wr=%0d dma_rd=%0d dma_wr=%0d msix=%0d",
                n_cfg_rd, n_cfg_wr, n_mem_rd, n_mem_wr, n_dma_rd, n_dma_wr, n_msix), UVM_LOW)
            return;
          end
          if (ret > 0) begin
            #(poll_ns * 1ns);
            continue;
          end
          handle_one();
        end
      endtask

      // first_be → 设备入口接受的 (字节通道, 宽度)：整 DW、低/高半字各一次访问，其余逐字节拆分。
      protected function void split_be(bit [3:0] be, ref int unsigned lane[$], ref int unsigned size[$]);
        lane.delete();
        size.delete();
        case (be)
          4'hf: begin lane.push_back(0); size.push_back(4); end
          4'h3: begin lane.push_back(0); size.push_back(2); end
          4'hc: begin lane.push_back(2); size.push_back(2); end
          default:
            for (int unsigned b = 0; b < 4; b++)
              if (be[b]) begin
                lane.push_back(b);
                size.push_back(1);
              end
        endcase
      endfunction

      protected task handle_one();
        int          kind;
        bit [63:0]   addr;
        int          len;
        int          tag;
        bit [31:0]   wdata;
        bit [31:0]   rdata;
        bit [3:0]    be;
        int unsigned off;
        int unsigned bar;
        bit [31:0]   boff;
        int unsigned lane[$];
        int unsigned size[$];
        vdev_base    d;
        kind  = bridge_vcs_get_poll_type();
        addr  = bridge_vcs_get_poll_addr();
        len   = bridge_vcs_get_poll_len();
        tag   = bridge_vcs_get_poll_tag();
        wdata = bridge_vcs_get_poll_data(0);
        case (kind)
          BV_CFGRD: begin
            n_cfg_rd++;
            d = device_by_bdf(COSIM_BDF);
            rdata = (d == null) ? '1 : d.cfg_read(addr[11:0]);
            complete(tag, rdata);
          end
          BV_CFGWR: begin
            n_cfg_wr++;
            d = device_by_bdf(COSIM_BDF);
            off = addr[1:0];
            be  = 4'(((1 << len) - 1) << off);
            if (d != null)
              d.cfg_write(addr[11:0], wdata << (8 * off), be);
          end
          BV_MRD: begin
            n_mem_rd++;
            d = device_by_addr(addr, bar, boff);
            rdata = '1;
            if (d == null) begin
              `uvm_warning("COSIM_PORT", $sformatf("MRd 未命中 BAR addr=0x%016h", addr))
            end else begin
              rdata = 0;
              split_be(bridge_vcs_get_poll_first_be(), lane, size);
              foreach (lane[i])
                rdata |= d.mmio_read(bar, boff + lane[i], size[i]) << (8 * lane[i]);
            end
            complete(tag, rdata);
          end
          BV_MWR: begin
            n_mem_wr++;
            d = device_by_addr(addr, bar, boff);
            if (d == null) begin
              `uvm_warning("COSIM_PORT", $sformatf("MWr 未命中 BAR addr=0x%016h", addr))
            end else begin
              split_be(bridge_vcs_get_poll_first_be(), lane, size);
              foreach (lane[i])
                d.mmio_write(bar, boff + lane[i], size[i], wdata >> (8 * lane[i]));
            end
          end
          default:
            `uvm_error("COSIM_PORT", $sformatf("不支持的 TLP 类型 %0d addr=0x%016h", kind, addr))
        endcase
      endtask

      protected function void complete(int tag, bit [31:0] data);
        for (int i = 0; i < 16; i++)
          bridge_vcs_set_cpl_data(i, 0);
        bridge_vcs_set_cpl_data(0, data);
        if (bridge_vcs_send_cpl_scalar(tag, 4) < 0)
          `uvm_error("COSIM_PORT", $sformatf("completion 发送失败 tag=%0d", tag))
      endfunction

      virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                            output bit [7:0] data[], output bit ok);
        int unsigned buf[16];
        int unsigned done;
        int unsigned n;
        data = new[len];
        ok = 1;
        done = 0;
        while (done < len) begin
          n = (len - done > DMA_CHUNK) ? DMA_CHUNK : len - done;
          if (bridge_vcs_dma_read_sync(addr + done, buf, n) != 0) begin
            `uvm_error("COSIM_PORT", $sformatf("DMA 读失败 addr=0x%016h len=%0d", addr + done, n))
            ok = 0;
            return;
          end
          for (int unsigned i = 0; i < n; i++)
            data[done + i] = buf[i / 4][8 * (i % 4) +: 8];
          done += n;
        end
        n_dma_rd++;
      endtask

      virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                             output bit ok);
        int unsigned buf[16];
        int unsigned done;
        int unsigned n;
        ok = 1;
        done = 0;
        while (done < data.size()) begin
          n = (data.size() - done > DMA_CHUNK) ? DMA_CHUNK : data.size() - done;
          buf = '{default: 0};
          for (int unsigned i = 0; i < n; i++)
            buf[i / 4][8 * (i % 4) +: 8] = data[done + i];
          if (bridge_vcs_dma_write_sync(addr + done, buf, n) != 0) begin
            `uvm_error("COSIM_PORT", $sformatf("DMA 写失败 addr=0x%016h len=%0d", addr + done, n))
            ok = 0;
            return;
          end
          done += n;
        end
        n_dma_wr++;
      endtask

      // 路线 R：vdev_base 已按表项解析出消息地址/数据并处理屏蔽，这里只做 4 字节 DMA 写（QEMU 侧转 BH 投递）。
      virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
        int unsigned buf[16];
        n_msix++;
        buf = '{default: 0};
        buf[0] = data;
        if (bridge_vcs_dma_write_sync(addr, buf, 4) != 0)
          `uvm_error("COSIM_PORT", $sformatf("MSI-X 投递失败 addr=0x%016h data=0x%08h", addr, data))
      endtask
    endclass

    class cosim_vdev_test extends uvm_test;
      `uvm_component_utils(cosim_vdev_test)
      vdev_base       dev;
      vdev_cosim_port port;
      string          mode;

      function new(string name, uvm_component parent);
        super.new(name, parent);
      endfunction

      // 设备参数在 init() 前给定；标准设备与 VIP 对比测试用同一组 vdev_diff_pkg 常量。
      function void build_phase(uvm_phase phase);
        vdev_virtio_pci std_dev;
        vdev_dpu_priv   priv_dev;
        super.build_phase(phase);
        if (!$value$plusargs("VDEV=%s", mode))
          mode = "std";
        case (mode)
          "std": begin
            std_dev = vdev_virtio_pci::type_id::create("dev", this);
            std_dev.device_features = VDEV_DIFF_STD_FEATURES;
            std_dev.max_pairs = VDEV_DIFF_STD_PAIRS;
            std_dev.queue_max = VDEV_DIFF_STD_QUEUE_MAX;
            dev = std_dev;
          end
          "priv": begin
            priv_dev = vdev_dpu_priv::type_id::create("dev", this);
            priv_dev.host_id = 0;   // qinfo 报 pfvf_id=0、host 0：dpu_snd1 走 AF 路径（D4）
            dev = priv_dev;
          end
          default: `uvm_fatal("COSIM_TEST", {"+VDEV 只接受 std|priv，实际为 ", mode})
        endcase
        dev.bdf = COSIM_BDF;
        dev.init();
        port = vdev_cosim_port::type_id::create("port");
        port.attach(dev);
      endfunction

      task run_phase(uvm_phase phase);
        string shm_name;
        string sock_path;
        phase.raise_objection(this);
        if (!$value$plusargs("SHM_NAME=%s", shm_name))
          `uvm_fatal("COSIM_TEST", "缺少 +SHM_NAME")
        if (!$value$plusargs("SOCK_PATH=%s", sock_path))
          `uvm_fatal("COSIM_TEST", "缺少 +SOCK_PATH")
        port.open_shm(shm_name, sock_path);
        port.serve();
        phase.drop_objection(this);
      endtask
    endclass
  endpackage
  `endif
  ```

- [ ] **Step 2: 写 `~/cosim_diff/sv/cosim_vdev_top.sv`**

  ```systemverilog
  // cosim_vdev_top.sv —— 临时 cosim 顶层：没有接口，设备模型经 vdev_cosim_port 直连 QEMU。
  `timescale 1ns/1ps
  module cosim_vdev_top;
    import uvm_pkg::*;
    import vdev_cosim_pkg::*;

    initial run_test("cosim_vdev_test");

    // 安全网：QEMU 异常时防止 simv 挂死；正常结束由 QEMU 关机（bridge 返回 -1）触发。
    initial begin
      longint timeout_ms;
      if (!$value$plusargs("SIM_TIMEOUT_MS=%d", timeout_ms))
        timeout_ms = 3600000;
      repeat (timeout_ms) #1ms;
      $display("[COSIM_TOP] SIM_TIMEOUT_MS=%0d reached, finishing", timeout_ms);
      $finish;
    end
  endmodule
  ```

- [ ] **Step 3: 写 `~/cosim_diff/build_cosim.sh`**

  ```bash
  #!/usr/bin/env bash
  # build_cosim.sh —— 编译 simv_cosim：virtio_net_pkg（含 devmodel）+ cosim bridge DPI + 临时顶层
  set -euo pipefail
  source ~/virtio_priv_run/env.sh
  CD=$HOME/cosim_diff; BR=$CD/cosim-platform/bridge; VW=$HOME/virtio_priv_run/virtio_work
  C_SRCS=(
    "$BR/vcs/bridge_vcs.c" "$BR/vcs/sock_sync_vcs.c"
    "$BR/common/shm_layout.c" "$BR/common/ring_buffer.c" "$BR/common/dma_manager.c"
    "$BR/common/trace_log.c" "$BR/common/eth_shm.c" "$BR/common/link_model.c"
    "$BR/vcs/virtqueue_dma.c" "$BR/eth/eth_mac_dpi.c" "$BR/eth/eth_port.c"
    "$BR/common/transport_shm.c" "$BR/common/transport_tcp.c"
  )
  SV_EXTRA=( "$CD/sv/vdev_diff_pkg.sv" "$CD/sv/vdev_cosim_pkg.sv" "$CD/sv/cosim_vdev_top.sv" )
  mkdir -p "$CD/build"
  cd "$VW"
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -f filelists/dpu_common.f -f filelists/virtio_net.f \
    +incdir+"$BR/vcs" "$BR/vcs/bridge_vcs.sv" \
    +incdir+"$CD/sv" "${SV_EXTRA[@]}" \
    -CFLAGS "-I$BR/common -I$BR/vcs -I$BR/qemu -I$BR/eth -std=c99 -D_POSIX_C_SOURCE=200112L" \
    -LDFLAGS "-Wl,--no-as-needed -lrt -lpthread" \
    "${C_SRCS[@]}" \
    -top cosim_vdev_top -Mdir="$CD/build/csrc_cosim" -o "$CD/build/simv_cosim" \
    -l "$CD/build/compile_cosim.log" > /dev/null
  echo "BUILD_COSIM OK $CD/build/simv_cosim"
  ```
  C 源文件列表和 CFLAGS/LDFLAGS 照抄 cosim-platform `Makefile` 的 `vcs-vip` 目标（`BRIDGE_C_SRCS`、`VCS_CFLAGS`、`VCS_LDFLAGS`）。`bridge_vcs.sv` 引用了 eth/vq 等 DPI，即使不调用，也要把对应 C 源一起链接。编译在 `virtio_work` 目录下进行，因为 filelist 里是相对路径，`-Mdir` 指向 `~/cosim_diff/build`，不会动 `virtio_work/csrc`。

- [ ] **Step 4: 写 guest 侧公共函数与冒烟脚本**

  `~/cosim_diff/guest/vdev_lib.sh`：
  ```sh
  # vdev_lib.sh —— guest 脚本公共函数（busybox ash）。调用方先设置 VDEV_TAG。
  log() { echo "$VDEV_TAG $*"; }

  find_bdf() {  # $1=vendor $2=device（0x 前缀小写）
    for d in /sys/bus/pci/devices/*; do
      if [ "$(cat "$d/vendor")" = "$1" ] && [ "$(cat "$d/device")" = "$2" ]; then
        basename "$d"; return 0
      fi
    done
    return 1
  }

  # 调试 VSEC（vdev_base，两种设备相同）：扩展配置空间 0x100，DW0=0x0001000b（Vendor-Specific Extended
  # Capability v1，next=0），DW1 低 16 位为 VSEC ID 0x5644；marker 寄存器固定在 0x108（32 位读写，写入只发
  # marker 事件）。设备带 PCIe 能力，q35 下 Linux 经 MMCONFIG 开放 4 KiB 配置空间，setpci 可直接访问。
  MOFF=108
  check_marker_cap() {
    [ "$(setpci -s "$BDF" 100.L)" = "0001000b" ] && [ "$(setpci -s "$BDF" 104.W)" = "5644" ]
  }

  select_device() {  # $1=std|priv；设置 BDF 并确认调试 VSEC
    case "$1" in
      std)  BDF=$(find_bdf 0x1af4 0x1041) ;;
      priv) BDF=$(find_bdf 0x20f9 0x5013) ;;
      *)    return 1 ;;
    esac
    [ -n "$BDF" ] || return 1
    check_marker_cap
  }

  marker() {
    setpci -s "$BDF" "$MOFF.L=$(printf '%08x' "$1")"
    log "marker $1"
    sleep 1
  }

  wait_netdev() {  # 输出接口名；最长等 120 s（TCG + VCS 很慢）
    i=0
    while [ $i -lt 120 ]; do
      for n in /sys/bus/pci/devices/$BDF/net/* /sys/bus/pci/devices/$BDF/virtio*/net/*; do
        [ -e "$n" ] && { basename "$n"; return 0; }
      done
      sleep 1; i=$((i + 1))
    done
    return 1
  }
  ```
  `~/cosim_diff/guest/vdev_smoke.sh`：
  ```sh
  #!/bin/sh
  # vdev_smoke.sh std|priv —— 冒烟：设备可见、BAR 与 cap 正确、配置空间可读写。
  VDEV_TAG=VDEV_SMOKE
  . /usr/local/bin/vdev_lib.sh
  select_device "$1" || { log "FAIL 找不到 $1 设备或调试 VSEC"; lspci -nn; exit 1; }
  log "bdf=$BDF vsec=$(setpci -s "$BDF" 100.L) $(setpci -s "$BDF" 104.L)"
  lspci -nn -vvv -s "$BDF"
  log "id=$(setpci -s "$BDF" 0.L)"
  cmd=$(setpci -s "$BDF" 4.W)
  setpci -s "$BDF" "4.W=$cmd"
  [ "$(setpci -s "$BDF" 4.W)" = "$cmd" ] || { log "FAIL command 回读不一致"; exit 1; }
  setpci -s "$BDF" "$MOFF.L=000000a5"
  [ "$(setpci -s "$BDF" "$MOFF.L")" = "000000a5" ] || { log "FAIL marker 回读不一致"; exit 1; }
  log "cfg_rw OK"
  for n in /sys/bus/pci/devices/$BDF/net/* /sys/bus/pci/devices/$BDF/virtio*/net/*; do
    [ -e "$n" ] && log "netdev $(basename "$n")"
  done
  log "PASS"
  ```
  `~/cosim_diff/guest/vdev-init`（经内核 `init=` 启动，代替 openrc）：
  ```sh
  #!/bin/sh
  # vdev-init —— cosim 对比专用 init：挂载伪文件系统、跑冒烟或场景、关机（QEMU 随之退出）
  export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
  mount -t proc proc /proc
  mount -t sysfs sysfs /sys
  mount -t devtmpfs devtmpfs /dev 2>/dev/null
  mount -o remount,rw / 2>/dev/null
  arg() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" /proc/cmdline; }
  MODE=$(arg vdev_mode); DEV=$(arg vdev_dev); N=$(arg vdev_n)
  echo "VDEV_INIT mode=$MODE dev=$DEV n=${N:-16} kernel=$(uname -r)"
  case "$MODE" in
    smoke) /usr/local/bin/vdev_smoke.sh "$DEV" ;;
    scen)  /usr/local/bin/run_scenarios.sh "$DEV" "${N:-16}" ;;
    *)     echo "VDEV_INIT unknown vdev_mode '$MODE'"; false ;;
  esac
  echo "VDEV_GUEST_DONE rc=$?"
  sync
  poweroff -f
  ```
  `~/cosim_diff/guest/inject.sh`（用 debugfs 写镜像，不需要 root）：
  ```bash
  #!/usr/bin/env bash
  # inject.sh <rootfs.ext4> —— 把 guest/ 下的脚本与产物写入镜像（覆盖同名文件）
  set -euo pipefail
  IMG=${1:?rootfs image}; G=$(cd "$(dirname "$0")" && pwd); CMD=$(mktemp)
  trap 'rm -f "$CMD"' EXIT
  put() {  # src 目标目录 文件名 八进制权限
    [ -f "$1" ] || return 0
    printf 'cd %s\nrm %s\nwrite %s %s\nsif %s mode 0100%s\nsif %s uid 0\nsif %s gid 0\n' \
      "$2" "$3" "$1" "$3" "$3" "$4" "$3" "$3" > "$CMD"
    /sbin/debugfs -w -f "$CMD" "$IMG" > /dev/null 2>&1
  }
  /sbin/debugfs -w -R "mkdir /lib/modules/extra" "$IMG" > /dev/null 2>&1 || true
  put "$G/vdev-init"         /sbin              vdev-init         755
  put "$G/vdev_lib.sh"       /usr/local/bin     vdev_lib.sh       644
  put "$G/vdev_smoke.sh"     /usr/local/bin     vdev_smoke.sh     755
  put "$G/run_scenarios.sh"  /usr/local/bin     run_scenarios.sh  755
  put "$G/vdev_pktgen"       /usr/local/bin     vdev_pktgen       755
  put "$G/dpu_snd1.ko"       /lib/modules/extra dpu_snd1.ko       644
  /sbin/debugfs -R "ls -l /usr/local/bin" "$IMG" 2>/dev/null | grep -E "vdev|run_scen"
  /sbin/debugfs -R "ls -l /sbin/vdev-init" "$IMG" 2>/dev/null
  ```

- [ ] **Step 5: 写 `~/cosim_diff/run_cosim.sh`**

  ```bash
  #!/usr/bin/env bash
  # run_cosim.sh <std|priv> <smoke|scen> [N] —— 先起 QEMU（建 SHM 与 socket），再起 simv_cosim，等 guest 关机
  set -euo pipefail
  DEV=${1:?std|priv}; MODE=${2:?smoke|scen}; N=${3:-16}
  CD=$HOME/cosim_diff; OUT=$CD/out/$DEV/$MODE; SHM=/vdev_$DEV; SOCK=$CD/run/vdev_$DEV.sock
  mkdir -p "$OUT" "$CD/run"; rm -f "$SOCK" "/dev/shm$SHM" "$OUT"/*.log "$OUT/linux.jsonl"
  export COSIM_CONNECT_TIMEOUT=300
  timeout "${WALL_S:-3600}" "$CD/qemu/build/qemu-system-x86_64" -M q35 -m 512M -smp 1 -accel tcg \
    -display none -monitor none -no-reboot -action panic=shutdown -serial "file:$OUT/guest.log" \
    -kernel "$CD/images/vmlinuz" \
    -drive "file=$CD/images/rootfs.ext4,format=raw,if=none,id=rootdisk" \
    -device virtio-blk-pci,drive=rootdisk,addr=0x10 \
    -append "console=ttyS0 root=/dev/vda rw init=/sbin/vdev-init ipv6.disable=1 loglevel=4 vdev_mode=$MODE vdev_dev=$DEV vdev_n=$N" \
    -device "cosim-pcie-rc,shm_name=$SHM,sock_path=$SOCK,addr=0x3" \
    -d guest_errors,unimp -D "$OUT/qemu_debug.log" > "$OUT/qemu.log" 2>&1 &
  QPID=$!
  for _ in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 1; done
  [ -S "$SOCK" ] || { echo "QEMU 未建立 $SOCK"; kill "$QPID" 2>/dev/null; exit 1; }
  set +u; source ~/virtio_priv_run/env.sh; set -u
  "$CD/build/simv_cosim" +VDEV="$DEV" +SHM_NAME="$SHM" +SOCK_PATH="$SOCK" \
    +VDEV_JSONL="$OUT/linux.jsonl" +SIM_TIMEOUT_MS=36000000 +UVM_VERBOSITY=UVM_LOW \
    ${COSIM_EXTRA:-} > "$OUT/vcs.log" 2>&1 &
  VPID=$!
  QRC=0; wait "$QPID" || QRC=$?
  for _ in $(seq 1 120); do kill -0 "$VPID" 2>/dev/null || break; sleep 1; done
  kill "$VPID" 2>/dev/null || true
  VRC=0; wait "$VPID" || VRC=$?
  rm -f "$SOCK" "/dev/shm$SHM"
  echo "RUN_COSIM dev=$DEV mode=$MODE qemu_rc=$QRC vcs_rc=$VRC out=$OUT"
  grep -hE "VDEV_(SMOKE|SCN|PKTGEN|GUEST_DONE)" "$OUT/guest.log" | tail -8
  grep -E "UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" "$OUT/vcs.log" || true
  ```
  `addr=0x3` 决定 guest BDF 00:03.0，与 `vdev_cosim_pkg::COSIM_BDF` 对应。路线 P 需要先改 D 的设备底座，见 D-E1。

- [ ] **Step 6: 放置文件、编译、注入镜像**

  本机把 Step 1–5 的文件写好后用 `PUT` 放到 53 对应路径，然后：
  ```bash
  $S53 'set -euo pipefail; cd ~/cosim_diff
  chmod +x build_cosim.sh run_cosim.sh guest/inject.sh guest/vdev-init guest/vdev_smoke.sh
  ./build_cosim.sh; grep -c "Warning-\[" build/compile_cosim.log || true
  ./guest/inject.sh images/rootfs.ext4
  git add -A && git commit -qm "feat: cosim 顶层、端口与冒烟脚本"'
  ```
  期望：
  - 输出 `BUILD_COSIM OK`。
  - inject 能列出 `vdev_lib.sh`、`vdev_smoke.sh` 和 `/sbin/vdev-init`，权限为 `100755`，uid 0。
  - 本文件已按 D 的最终 API 编写（见 Notes“已对齐”）。若编译仍报 `vdev_port` 纯虚方法或 `vdev_base` 入口签名不一致，以 `virtio_net_vip/src/devmodel/vdev_port.sv`、`vdev_base.sv` 的实际代码为准改本临时文件，不要改 D 的代码去迁就它。
  - 若报 virtio_net_pkg 依赖 queue_work 的类型，在 `build_cosim.sh` 的 `-f filelists/virtio_net.f` 之后加 `-f filelists/queue_work_integration.f`。
  - 若 VCS 在 class 作用域调用 `bridge_vcs_dma_read_sync`（有 output 数组参数）时崩溃，在 `cosim_vdev_top` 中写 module 级 task 包装，类里改调包装：把 package 内的调用替换为 `$root.cosim_vdev_top.dma_read_shim(...)`。

- [ ] **Step 7: 冒烟，标准设备**

  ```bash
  $S53 'cd ~/cosim_diff && WALL_S=1800 ./run_cosim.sh std smoke'
  $S53 'cd ~/cosim_diff/out/std/smoke && grep -E "\[1af4:1041\]|Region [0-5]:|Vendor Specific|MSI-X:|VDEV_SMOKE" guest.log; grep "QEMU 断开" vcs.log'
  ```
  期望：
  - `qemu_rc=0`，guest 中 `VDEV_GUEST_DONE rc=0`，`VDEV_SMOKE PASS`、`VDEV_SMOKE cfg_rw OK`。
  - lspci 显示 `[1af4:1041]`；`Region 0`（16K）、`Region 2`（4K，notify）、`Region 4`（64K，MSI-X）均为 `Memory at ... (64-bit, non-prefetchable)`；`Express (v2) Endpoint`；4 条 `Vendor Specific Information`（VirtIO CommonCfg/Notify/ISR/DeviceCfg，notify cap 指向 BAR2）；`MSI-X: Enable+ Count=6`；`Capabilities: [100 v1] Vendor Specific Information: ID=5644 Rev=0 Len=00c`。内建 virtio_net 启动时已绑定，所以还有 `VDEV_SMOKE netdev eth0`。
  - vcs.log 的 `QEMU 断开` 行中 `cfg_rd`、`mem_rd` 均大于 0。`UVM_ERROR : 0`，`UVM_FATAL : 0`。

  失败时的判定：
  - lspci 看不到 cap：检查设备模型的 Status.CapList 和 0x34；看不到 `[100 v1]`：确认 guest 走 MMCONFIG（`dmesg | grep -i mmconfig`），以及 rc 补丁把 0x100 以上的配置访问转发给 VCS。
  - 缺 BAR：检查设备模型 BAR 的 sizing 掩码与 64 位类型位，以及 `qemu_debug.log` 中 `realize BAR` 行。启动时加 `-device cosim-pcie-rc,...,debug=on`。
  - guest 卡在 virtio 探测：检查 MRd completion 是否回出（vcs.log 中 `mem_rd` 计数）。
  - `MSI-X: Enable+` 但 `/proc/interrupts` 不增长：检查 `raise_msix` 的地址和数据，以及 QEMU 日志中的 DMA 写。
  - 属于设备模型（阶段 D 代码）的缺陷：回到 `virtio_sdd` 修复，先补 D 的设备单元测试，再跑回归并提交，然后 SYNC、`./build_cosim.sh` 重跑。三轮修正仍无法枚举或无法投递中断，停下汇报（路线 P 需先改 D，见 D-E1）。

- [ ] **Step 8: 冒烟，私有设备**

  ```bash
  $S53 'cd ~/cosim_diff && WALL_S=1800 ./run_cosim.sh priv smoke'
  $S53 'cd ~/cosim_diff/out/priv/smoke && grep -E "\[20f9:5013\]|Region [0-5]:|Vendor Specific|MSI-X:|VDEV_SMOKE" guest.log'
  ```
  期望：
  - `[20f9:5013]`，`Region 0`（32M）、`Region 2`（64K，qinfo）、`Region 4`（64K）均为 64 位 Memory。
  - 有 `MSI-X: Enable- Count=64`（还没有驱动），有 `[100 v1] Vendor Specific Information: ID=5644`。
  - `VDEV_SMOKE cfg_rw OK`、`VDEV_SMOKE PASS`，vcs.log 中 `UVM_ERROR : 0`。
  - 提交：`$S53 'cd ~/cosim_diff && git add -A && git commit -qm "test: 冒烟通过（std/priv）"'`，`out/` 已被 git 忽略。

---

### Task E3: Guest 场景脚本、`vdev_pktgen`、私有驱动 `dpu_snd1.ko`

**Files:**
- Create (53): `~/cosim_diff/guest/run_scenarios.sh`、`~/cosim_diff/guest/vdev_pktgen.c`
- Create (53): `~/cosim_diff/drv/src/`（icpu-kernel-driver 的只读副本，不含构建产物）、`~/cosim_diff/drv/SOURCE`、`~/cosim_diff/drv/patches/0001-linux-6.8-compat.patch`（仅在需要时）
- Create (本机，临时): `~/cosim_diff_drv/`（头文件包和构建目录，不进任何仓库）
- Produces (53): `~/cosim_diff/guest/vdev_pktgen`（静态链接）、`~/cosim_diff/guest/dpu_snd1.ko`
- Test: `run_cosim.sh std scen`、`run_cosim.sh priv scen`，guest 中输出 `VDEV_SCN PASS`

**Interfaces:**
- Consumes: E2 的 `vdev_lib.sh`（`select_device`、`marker`、`wait_netdev`）和 `inject.sh`；53 `/home/ubuntu/wn/icpu-kernel-driver`（`f2c9cd6`，只读）。
- Produces:
  - 场景与 marker 号：S1=1，S2=2，S3=3（仅 std），S4=4，结束=255。marker 之前（段 0，启动期绑定）不参与对比。
  - 帧集合：N 个，长度 128 字节，按 `build_frame(seq)` 逐字节确定，与 F2 的 VIP `vdev_diff_frame` 一致：
    - 目的 MAC 为 `ff:ff:ff:ff:ff:ff`，源 MAC 为 `02:56:44:45:56:00`，ethertype `0x88b5`。
    - 第 14–17 字节是大端 seq。
    - 第 j 字节（j≥18）为 `(seq*7 + j) & 0xff`。
  - 标准模式中，“modprobe/rmmod”由 `virtio-pci` 的 sysfs `bind`/`unbind` 代替，因为 virtio_net 是内建的。

- [ ] **Step 1: 写 `~/cosim_diff/guest/run_scenarios.sh`**

  ```sh
  #!/bin/sh
  # run_scenarios.sh std|priv N —— S1..S4，每段前写 marker；任何一步失败即退出（不写结束 marker）
  VDEV_TAG=VDEV_SCN
  . /usr/local/bin/vdev_lib.sh
  DEV=$1; N=${2:-16}
  die() { log "FAIL $*"; exit 1; }
  select_device "$DEV" || die "找不到 $DEV 设备或调试 VSEC"
  log "bdf=$BDF n=$N"
  PG="/usr/local/bin/vdev_pktgen -n $N -l 128 -t 600"
  VPCI=/sys/bus/pci/drivers/virtio-pci

  if [ "$DEV" = std ]; then
    # 内建 virtio_net 在启动时已绑定：先解绑（设备复位），启动期事件留在段 0
    [ -e "$VPCI/$BDF" ] && echo "$BDF" > "$VPCI/unbind"
    marker 1
    echo "$BDF" > "$VPCI/bind" || die "S1 bind"
    IF=$(wait_netdev) || die "S1 无 netdev"
    ip link set "$IF" up || die "S1 link up"
    sleep 3
    marker 2
    $PG -i "$IF" || die "S2 pktgen"
    marker 3
    ethtool -L "$IF" combined 2 || die "S3 ethtool -L"
    echo 0 > "/sys/class/net/$IF/queues/tx-0/xps_cpus" || die "S3 xps tx-0"
    echo 1 > "/sys/class/net/$IF/queues/tx-1/xps_cpus" || die "S3 xps tx-1"   # 单 CPU 的发送全部落到第 2 对
    sleep 1
    $PG -i "$IF" || die "S3 pktgen"
    marker 4
    ip link set "$IF" down
    sleep 1
    echo "$BDF" > "$VPCI/unbind" || die "S4 unbind"
  else
    marker 1
    insmod /lib/modules/extra/dpu_snd1.ko || die "S1 insmod"
    IF=$(wait_netdev) || die "S1 无 netdev"
    ip link set "$IF" up || die "S1 link up"
    sleep 3
    marker 2
    $PG -i "$IF" || die "S2 pktgen"
    marker 4
    ip link set "$IF" down
    sleep 1
    rmmod dpu_snd1 || die "S4 rmmod"
  fi
  marker 255
  log "PASS"
  ```

- [ ] **Step 2: 写 `~/cosim_diff/guest/vdev_pktgen.c`**

  ```c
  /* vdev_pktgen.c —— guest 内静态程序：经 AF_PACKET 发 N 个固定帧，等待设备回环并逐字节校验。
   * 用法：vdev_pktgen -i IFNAME [-n N] [-l LEN] [-t TIMEOUT_S]；全部收回且无错帧时退出码 0。 */
  #define _GNU_SOURCE
  #include <arpa/inet.h>
  #include <errno.h>
  #include <linux/if_packet.h>
  #include <net/if.h>
  #include <poll.h>
  #include <stdint.h>
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include <sys/socket.h>
  #include <time.h>
  #include <unistd.h>

  #define ETH_P_VDEV  0x88B5
  #define MAX_FRAMES  1024
  #define MIN_LEN     60
  #define MAX_LEN     1514
  #define HDR_LEN     18

  static const uint8_t SRC_MAC[6] = {0x02, 0x56, 0x44, 0x45, 0x56, 0x00};

  /* 与 VIP 侧 vdev_diff_frame::build() 逐字节一致 */
  static void build_frame(uint8_t *f, uint32_t seq, int len)
  {
      memset(f, 0xff, 6);
      memcpy(f + 6, SRC_MAC, 6);
      f[12] = ETH_P_VDEV >> 8;
      f[13] = ETH_P_VDEV & 0xff;
      f[14] = (uint8_t)(seq >> 24);
      f[15] = (uint8_t)(seq >> 16);
      f[16] = (uint8_t)(seq >> 8);
      f[17] = (uint8_t)seq;
      for (int j = HDR_LEN; j < len; j++)
          f[j] = (uint8_t)(seq * 7u + (uint32_t)j);
  }

  static double now_s(void)
  {
      struct timespec ts;
      clock_gettime(CLOCK_MONOTONIC, &ts);
      return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
  }

  int main(int argc, char **argv)
  {
      const char *ifname = NULL;
      int n = 16, len = 128, timeout_s = 300, opt;
      static uint8_t seen[MAX_FRAMES];
      uint8_t frame[MAX_LEN], buf[2048];

      while ((opt = getopt(argc, argv, "i:n:l:t:")) != -1) {
          switch (opt) {
          case 'i': ifname = optarg; break;
          case 'n': n = atoi(optarg); break;
          case 'l': len = atoi(optarg); break;
          case 't': timeout_s = atoi(optarg); break;
          default:
              fprintf(stderr, "usage: %s -i IF [-n N] [-l LEN] [-t S]\n", argv[0]);
              return 2;
          }
      }
      if (!ifname || n < 1 || n > MAX_FRAMES || len < MIN_LEN || len > MAX_LEN || timeout_s < 1) {
          fprintf(stderr, "vdev_pktgen: bad arguments\n");
          return 2;
      }
      unsigned int ifindex = if_nametoindex(ifname);
      if (ifindex == 0) {
          perror("if_nametoindex");
          return 2;
      }
      int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_VDEV));
      if (fd < 0) {
          perror("socket");
          return 2;
      }
      struct sockaddr_ll sll;
      memset(&sll, 0, sizeof(sll));
      sll.sll_family = AF_PACKET;
      sll.sll_protocol = htons(ETH_P_VDEV);
      sll.sll_ifindex = (int)ifindex;
      if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
          perror("bind");
          return 2;
      }
      for (int i = 0; i < n; i++) {
          build_frame(frame, (uint32_t)i, len);
          if (send(fd, frame, (size_t)len, 0) != len) {
              perror("send");
              return 1;
          }
      }
      int got = 0, bad = 0;
      double deadline = now_s() + timeout_s;
      while (got < n && now_s() < deadline) {
          struct pollfd p = {.fd = fd, .events = POLLIN};
          int r = poll(&p, 1, 1000);
          if (r < 0 && errno != EINTR) {
              perror("poll");
              return 1;
          }
          if (r <= 0)
              continue;
          struct sockaddr_ll from;
          socklen_t fl = sizeof(from);
          ssize_t k = recvfrom(fd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl);
          if (k < 0) {
              if (errno == EINTR)
                  continue;
              perror("recvfrom");
              return 1;
          }
          if (from.sll_pkttype == PACKET_OUTGOING)
              continue;
          if (k != len) {
              bad++;
              continue;
          }
          uint32_t seq = ((uint32_t)buf[14] << 24) | ((uint32_t)buf[15] << 16) |
                         ((uint32_t)buf[16] << 8) | buf[17];
          if (seq >= (uint32_t)n || seen[seq]) {
              bad++;
              continue;
          }
          build_frame(frame, seq, len);
          if (memcmp(frame, buf, (size_t)len) != 0) {
              bad++;
              continue;
          }
          seen[seq] = 1;
          got++;
      }
      printf("VDEV_PKTGEN if=%s sent=%d got=%d bad=%d\n", ifname, n, got, bad);
      return (got == n && bad == 0) ? 0 : 1;
  }
  ```
  编译与检查：
  ```bash
  $S53 'cd ~/cosim_diff/guest && gcc -O2 -static -Wall -Wextra -Werror -o vdev_pktgen vdev_pktgen.c && file vdev_pktgen'
  ```
  期望 `statically linked`，无告警。53 上没有 root，跑不了 AF_PACKET，运行验证放在 Step 6 的 guest 中。

- [ ] **Step 3: 私有驱动源码副本（53）**

  ```bash
  $S53 'set -euo pipefail; D=/home/ubuntu/wn/icpu-kernel-driver; C=$HOME/cosim_diff/drv
  mkdir -p $C/src $C/patches
  rsync -a --delete --exclude .git --exclude "*.o" --exclude "*.ko" --exclude "*.mod" --exclude "*.mod.c" \
    --exclude ".*.cmd" --exclude modules.order --exclude Module.symvers $D/ $C/src/
  { git -C $D rev-parse HEAD; git -C $D status --porcelain; } > $C/SOURCE
  head -1 $C/SOURCE; ls $C/src | head -5'
  ```
  期望 `SOURCE` 首行为 `f2c9cd6...`。原仓库只读，不在里面构建，因为它的工作树里已有针对 5.15 的 `.o`/`.ko`。

- [ ] **Step 4: 本机针对 6.8.0-107 编译 `dpu_snd1.ko`**

  本机是 Ubuntu 24.04 + gcc 13.3，与 noble 内核的构建工具链一致。53 不行，见调研结论 6。
  ```bash
  W=$HOME/cosim_diff_drv; mkdir -p "$W/hdr" && cd "$W"
  apt download linux-headers-6.8.0-107 linux-headers-6.8.0-107-generic
  for d in linux-headers-6.8.0-107*.deb; do dpkg -x "$d" hdr; done
  KDIR=$W/hdr/usr/src/linux-headers-6.8.0-107-generic
  ls -l "$KDIR/scripts/basic/fixdep" "$KDIR/scripts/mod/modpost" "$KDIR/.config"
  sshpass -p ubuntu rsync -a --delete -e "ssh -o StrictHostKeyChecking=no" ubuntu@10.11.10.53:cosim_diff/drv/src/ "$W/src/"
  cp -a "$W/src" "$W/src.orig"
  make -C "$W/src" KERNELDIR="$KDIR" -j8 2>&1 | tee "$W/build.log" | grep -E "error|warning: implicit" | head -30
  modinfo -F vermagic "$W/src/dpu_snd1.ko"
  ```
  期望 vermagic 为 `6.8.0-107-generic SMP preempt mod_unload modversions`。

  编译失败时：
  - 在 `$W/src` 里按 `compat.h` 的现有风格加版本宏，只做兼容修改，不改驱动逻辑，然后重编。
  - 生成补丁：`diff -ruN -x "*.o" -x "*.ko" -x "*.mod*" -x ".*.cmd" -x modules.order -x Module.symvers src.orig src > 0001-linux-6.8-compat.patch`，放到 `drv/patches/`。
  - 判定：兼容修改涉及驱动语义（不只是 API 改名或签名），或者两小时内不能通过，就停下，把编译错误摘要交给用户决定。规范里的 Debian 回退不可行，原因见调研结论 6。

  放回 53：
  ```bash
  PUT "$W/src/dpu_snd1.ko" guest/dpu_snd1.ko
  [ -f "$W/0001-linux-6.8-compat.patch" ] && PUT "$W/0001-linux-6.8-compat.patch" drv/patches/0001-linux-6.8-compat.patch
  ```

- [ ] **Step 5: 注入镜像并提交**

  ```bash
  $S53 'set -euo pipefail; cd ~/cosim_diff; chmod +x guest/run_scenarios.sh
  ./guest/inject.sh images/rootfs.ext4
  /sbin/debugfs -R "ls -l /lib/modules/extra" images/rootfs.ext4 2>/dev/null | grep dpu_snd1
  git add -A && git commit -qm "feat: guest 场景脚本、vdev_pktgen、dpu_snd1 6.8 兼容补丁"'
  ```

- [ ] **Step 6: 场景试跑（guest 侧能否走完）**

  ```bash
  $S53 'cd ~/cosim_diff && WALL_S=3600 ./run_cosim.sh std scen 16'
  $S53 'cd ~/cosim_diff && WALL_S=3600 ./run_cosim.sh priv scen 16'
  ```
  期望：两次都出现 `VDEV_SCN marker 1/2/(3)/4/255`、`VDEV_PKTGEN ... got=16 bad=0`、`VDEV_SCN PASS`，`VDEV_GUEST_DONE rc=0`。

  失败判定：Linux 驱动是参照方，它在设备模型上跑不通，按“模型有误”处理，在 `virtio_sdd` 修复：
  1. 先补设备单元测试（RED），修复 D 的模型文件。
  2. 跑回归并提交，提交信息形如 `fix: vdev_virtio_pci <现象>（cosim 冒烟）`。
  3. SYNC，`./build_cosim.sh`，重跑。

  私有模式下，若驱动 probe 卡在 AF 声明、mailbox 或 qinfo 等未建模行为，把驱动源码中的预期写进 `vdev_dpu_priv.sv` 文件头的疑点清单，再按驱动预期实现，不猜测语义。连续三轮仍不能完成 S1，停下汇报卡住的寄存器序列（`dmesg` 和 vcs.log 摘要）。

---

## 阶段 F：Linux 与 VIP 驱动的差异对比、修复与报告

### Task F1: JSONL 事件记录器与 `vdev_diff.py`

**Files:**
- Modify (53): `~/cosim_diff/sv/vdev_diff_pkg.sv`（加 `vdev_jsonl_writer`）、`~/cosim_diff/sv/vdev_cosim_pkg.sv`（`cosim_vdev_test` 挂上记录器）
- Create (53): `~/cosim_diff/tools/vdev_diff.py`
- Test: `python3 tools/vdev_diff.py selftest`；`run_cosim.sh std smoke` 产生 `linux.jsonl`

**Interfaces:**
- Consumes: D 的 `vdev_event`（`kind` 为 `vdev_event_kind_e`）、`function string to_json()` 和 `vdev_base::event_ap`。
- Produces:
  - JSONL 每行一个事件：`{"seq":n,` + `vdev_event::to_json()` 的其余键。键名由 D 定义并与本脚本一致：`ev`、`fn`（设备 BDF，只在 `reg_wr`/`reg_rd` 中出现）、`region`、`field`、`q`、`val`、`from`、`to`、`dev_offered`、`drv_accepted`、`size`、`vector`、`enable`、`ring_fmt`、`next_idx`、`wrap`、`segs`（`[[len,flags],...]`）、`hdr`（对象；无 header 时为 `null`）、`dir`、`len`、`bytes`（十六进制，脚本补 sha1）、`id`、`class`、`cmd`、`data`（整数数组）、`ack`、`scenario`。
  - 配置空间访问为 `region="cfg"`、`field="0x%03h"`；标准 common_cfg 为 `region="common_cfg"`，字段名同 Linux `virtio_pci_common_cfg`（队列字段的 `q` 为当时的 `queue_select`）；MSI-X 表为 `region="msix"`、`field="vec<n>.dw<m>"`；私有区为 `region="bar0"/"bar2"`，`q` 恒为 -1，doorbell 只发 `notify`。
  - `vdev_diff.py diff|caps|selftest`，退出码：0 通过，1 有未豁免差异，2 输入错误。
  - 白名单格式：`[{"rule":"strict.queue_cfg","scenario":3,"key_re":"...","reason":"..."}]`，`scenario` 可以是 `"*"`，`reason` 必填。
  - 规则文件（可选，覆盖默认值）：`{"status_field":..., "addr_fields":{前缀:对齐}, "enable_requires":[...], "review_ignore_fields":[...], "order_pairs":[["kind:region.field[=val]", "..."], ...]}`。

差异分类：

| 类别 | 内容 | 不一致时 |
|---|---|---|
| strict | `features` 序列、`status` 转换序列、`ctrl` 序列、`queue_cfg` 多重集、`pkt` 多重集（dir,q,len,sha1）、场景缺失 | 失败 |
| order | 每条轨迹分别检查：queue enable 须在 FEATURES_OK 之后、DRIVER_OK 之前；enable 前须写过地址；复位后须读到 status=0 才重新初始化；IOVA 对齐；私有模式 `order_pairs` | 失败 |
| review | 规范没有分类、但需要人工判定的差异：`desc_chain`、`complete`（q,len）、`reg_wr` 多重集（去掉选择类和已被 strict 覆盖的字段）、`notify`/`irq` 是否发生（只比集合，不比次数） | 失败，除非被白名单豁免 |
| info | 冗余寄存器读、配置空间访问 | 只记录 |

- [ ] **Step 1: 在 `~/cosim_diff/sv/vdev_diff_pkg.sv` 中加入 `vdev_jsonl_writer`**

  在 E2 写好的 `vdev_diff_pkg.sv` 的 `endpackage` 之前加入（JSON 文本由 D 的 `vdev_event::to_json()` 生成，键名已与 `vdev_diff.py` 对齐，这里只在前面加 `seq`）：
  ```systemverilog
    // 订阅设备 event_ap，按到达顺序写 JSONL：每行 {"seq":n, <vdev_event::to_json() 的键>}。
    // cosim 顶层与 VIP 对比测试共用。路径来自 +VDEV_JSONL。
    class vdev_jsonl_writer extends uvm_subscriber #(vdev_event);
      `uvm_component_utils(vdev_jsonl_writer)
      string                 path;
      protected int          fd;
      protected int unsigned seq;

      function new(string name, uvm_component parent);
        super.new(name, parent);
      endfunction

      function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!$value$plusargs("VDEV_JSONL=%s", path))
          `uvm_fatal("VDEV_JSONL", "缺少 +VDEV_JSONL=<路径>")
        fd = $fopen(path, "w");
        if (fd == 0)
          `uvm_fatal("VDEV_JSONL", {"无法打开 ", path})
      endfunction

      function void write(vdev_event t);
        string j;
        j = t.to_json();
        if (j.len() < 2)
          `uvm_fatal("VDEV_JSONL", $sformatf("事件 %s 没有 JSON 表示", t.kind.name()))
        $fdisplay(fd, "{\"seq\":%0d,%s", seq, j.substr(1, j.len() - 1));
        $fflush(fd);
        seq++;
      endfunction

      function void final_phase(uvm_phase phase);
        super.final_phase(phase);
        if (fd != 0)
          $fclose(fd);
        `uvm_info("VDEV_JSONL", $sformatf("%0d events -> %s", seq, path), UVM_LOW)
      endfunction
    endclass
  ```

- [ ] **Step 2: cosim 测试挂上记录器**

  `vdev_cosim_pkg.sv` 的 `cosim_vdev_test` 中，old：
  ```systemverilog
      vdev_base       dev;
      vdev_cosim_port port;
      string          mode;
  ```
  new：
  ```systemverilog
      vdev_base         dev;
      vdev_cosim_port   port;
      vdev_jsonl_writer writer;
      string            mode;
  ```
  `build_phase` 末尾 `port.attach(dev);` 之后加 `writer = vdev_jsonl_writer::type_id::create("writer", this);`，并新增：
  ```systemverilog
      function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        dev.event_ap.connect(writer.analysis_export);
      endfunction
  ```
  `build_cosim.sh` 在 E2 已编入 `vdev_diff_pkg.sv`，不用改。

- [ ] **Step 3: 写 `~/cosim_diff/tools/vdev_diff.py`（全文）**

  ```python
  #!/usr/bin/env python3
  """vdev_diff.py: 对比 Linux 驱动与 VIP 驱动面对同一设备模型时的设备侧语义事件（JSONL）。

  子命令：
    diff LINUX.jsonl VIP.jsonl --mode std|priv [--rules R.json] [--whitelist W.json] [--report OUT.md]
    caps LINUX.jsonl      打印 S1 中 Linux 接受的 feature（十六进制，不带 0x），供 +VDEV_DRV_FEATURES
    selftest              内置自测
  退出码：0 无未豁免差异；1 存在未豁免的 strict/order/review 差异；2 输入或格式错误。
  """
  import argparse
  import hashlib
  import json
  import os
  import re
  import sys
  import tempfile
  from collections import Counter
  from itertools import zip_longest

  STATUS_DRIVER_OK = 0x04
  STATUS_FEATURES_OK = 0x08
  END_MARKER = 0xFF
  SCENARIO_NAMES = {
      0: "启动期（不对比）",
      1: "S1 初始化与 feature 协商",
      2: "S2 单队列收发",
      3: "S3 多队列与 ctrl VQ",
      4: "S4 关闭与复位",
  }
  FAIL_CATS = ("strict", "order", "review")
  # fn 是设备 BDF：cosim 为 00:03.0，VIP 为 snapshot 分配的 BDF，两侧各只有一个 Function，不参与比较。
  DROP_KEYS = ("seq", "t", "time", "fn")

  DEFAULT_RULES = {
      "std": {
          "status_field": "device_status",
          "addr_fields": {"queue_desc": 16, "queue_driver": 2, "queue_device": 4},
          "enable_requires": ["queue_desc", "queue_driver", "queue_device"],
          "review_ignore_fields": ["device_feature_select", "driver_feature_select",
                                   "driver_feature", "queue_select", "device_status"],
          "order_pairs": [],
      },
      "priv": {
          "status_field": "",
          "addr_fields": {},
          "enable_requires": [],
          "review_ignore_fields": [],
          "order_pairs": [],
      },
  }

  # strict 规则：事件类型 -> (比较字段, 比较方式)
  STRICT = {
      "features": (("dev_offered", "drv_accepted"), "seq"),
      "status": (("from", "to"), "seq"),
      "ctrl": (("class", "cmd", "data", "ack"), "seq"),
      "queue_cfg": (("q", "size", "vector", "enable", "ring_fmt"), "set"),
      "pkt": (("dir", "q", "len", "sha1"), "set"),
  }


  class InputError(Exception):
      pass


  def load(path):
      events = []
      with open(path, encoding="utf-8") as fh:
          for lineno, line in enumerate(fh, 1):
              line = line.strip()
              if not line:
                  continue
              try:
                  ev = json.loads(line)
              except json.JSONDecodeError as exc:
                  raise InputError(f"{path}:{lineno}: JSON 解析失败: {exc}") from exc
              if not isinstance(ev, dict) or "ev" not in ev:
                  raise InputError(f"{path}:{lineno}: 缺少 ev 字段")
              events.append(ev)
      return events


  def split_segments(events):
      """按 marker 切段：{场景号: [事件]}；段 0 为第一个 marker 之前。"""
      segs = {0: []}
      cur = 0
      for ev in events:
          if ev["ev"] == "marker":
              cur = int(ev["scenario"])
              segs.setdefault(cur, [])
              continue
          segs.setdefault(cur, []).append(ev)
      return segs


  def freeze(value):
      if isinstance(value, list):
          return tuple(freeze(v) for v in value)
      if isinstance(value, dict):
          return tuple(sorted((k, freeze(v)) for k, v in value.items()))
      return value


  class Normalizer:
      """去掉时间/序号/BDF，pkt 补 sha1，IOVA 换成按出现顺序编号的符号并校验对齐。"""

      def __init__(self, rules, trace):
          self.rules = rules
          self.trace = trace
          self.symbols = {}
          self.counts = Counter()
          self.problems = []  # (场景, key)

      def _addr_rule(self, field):
          for prefix, align in self.rules["addr_fields"].items():
              if field.startswith(prefix):
                  return align
          return None

      def norm(self, ev, scenario):
          ev = {k: v for k, v in ev.items() if k not in DROP_KEYS}
          kind = ev["ev"]
          if kind == "pkt":
              if "sha1" not in ev:
                  ev["sha1"] = hashlib.sha1(bytes.fromhex(ev.get("bytes", ""))).hexdigest()
              ev.pop("bytes", None)
          if kind in ("reg_wr", "reg_rd"):
              field = ev.get("field", "")
              align = self._addr_rule(field)
              if align is not None:
                  raw = int(ev.get("val", 0))
                  if not field.endswith("_hi") and raw % align:
                      self.problems.append((scenario, f"{self.trace}: {field} q={ev.get('q')} "
                                            f"val=0x{raw:x} 未按 {align} 字节对齐"))
                  ident = (ev.get("fn"), ev.get("region"), field, ev.get("q"))
                  if ident + (raw,) not in self.symbols:
                      self.counts[ident] += 1
                      self.symbols[ident + (raw,)] = f"@{field}.q{ev.get('q')}#{self.counts[ident]}"
                  ev["val"] = self.symbols[ident + (raw,)]
          return ev


  def normalize(events, rules, trace):
      normer = Normalizer(rules, trace)
      segs = split_segments(events)
      out = {scn: [normer.norm(ev, scn) for ev in evs] for scn, evs in segs.items()}
      return out, normer.problems


  def project(evs, kind, keys):
      return [tuple(freeze(e.get(k)) for k in keys) for e in evs if e["ev"] == kind]


  def diff_seq(a, b):
      out = []
      for i, (x, y) in enumerate(zip_longest(a, b)):
          if x != y:
              out.append(f"#{i} linux={x if x is not None else '-'} vip={y if y is not None else '-'}")
      return out


  def diff_multiset(a, b):
      ca, cb = Counter(a), Counter(b)
      out = [f"only_linux x{n} {item}" for item, n in sorted((ca - cb).items(), key=str)]
      out += [f"only_vip x{n} {item}" for item, n in sorted((cb - ca).items(), key=str)]
      return out


  def match_pattern(ev, pattern):
      """pattern 形如 'reg_wr:bar0.af_declaration' 或 'reg_wr:bar0.af_declaration=0x5555aaaa'。"""
      kind, _, rest = pattern.partition(":")
      target, _, val = rest.partition("=")
      region, _, field = target.partition(".")
      if ev["ev"] != kind or ev.get("region") != region or ev.get("field") != field:
          return False
      return val == "" or ev.get("val") == int(val, 0)


  def check_order(segs, rules, trace):
      out = []
      status = 0
      addr_written = {}
      wait_zero_read = False
      for scn in sorted(segs):
          for ev in segs[scn]:
              kind = ev["ev"]
              if kind == "status":
                  to = int(ev["to"])
                  if to == 0:
                      addr_written.clear()
                      wait_zero_read = bool(rules["status_field"])
                  elif int(ev["from"]) == 0 and wait_zero_read:
                      out.append((scn, f"{trace}: 复位后未读到 status=0 即写 0x{to:02x}"))
                      wait_zero_read = False
                  status = to
              elif (kind == "reg_rd" and wait_zero_read and ev.get("field") == rules["status_field"]
                    and ev.get("val") == 0):
                  wait_zero_read = False
              elif kind == "reg_wr":
                  for prefix in rules["enable_requires"]:
                      if ev.get("field", "").startswith(prefix):
                          addr_written.setdefault(ev.get("q"), set()).add(prefix)
              elif kind == "queue_cfg" and int(ev.get("enable", 0)):
                  q = ev.get("q")
                  if not status & STATUS_FEATURES_OK or status & STATUS_DRIVER_OK:
                      out.append((scn, f"{trace}: q{q} enable 时 status=0x{status:02x}"
                                       "（应在 FEATURES_OK 之后、DRIVER_OK 之前）"))
                  missing = [p for p in rules["enable_requires"] if p not in addr_written.get(q, set())]
                  if missing:
                      out.append((scn, f"{trace}: q{q} enable 前缺少地址写 {','.join(missing)}"))
          for first, second in rules["order_pairs"]:
              idx_a = next((i for i, e in enumerate(segs[scn]) if match_pattern(e, first)), None)
              idx_b = next((i for i, e in enumerate(segs[scn]) if match_pattern(e, second)), None)
              if idx_b is not None and (idx_a is None or idx_a > idx_b):
                  out.append((scn, f"{trace}: {second} 出现在 {first} 之前或缺少后者"))
      return out


  def compare(lin, vip, rules):
      """返回差异列表：dict(cat, rule, scenario, key)。"""
      diffs = []
      ignore = set(rules["review_ignore_fields"])
      wr_keys = ("fn", "region", "field", "q", "val")
      rd_keys = ("fn", "region", "field", "q")

      def writes(evs):
          return [tuple(freeze(e.get(k)) for k in wr_keys) for e in evs
                  if e["ev"] == "reg_wr" and e.get("region") != "cfg" and e.get("field") not in ignore]

      def reads(evs):
          return [tuple(freeze(e.get(k)) for k in rd_keys) for e in evs
                  if e["ev"] == "reg_rd" or (e["ev"] == "reg_wr" and e.get("region") == "cfg")]

      scns = sorted(s for s in set(lin) | set(vip) if s not in (0, END_MARKER))
      for scn in scns:
          a, b = lin.get(scn), vip.get(scn)
          if a is None or b is None:
              side = "linux" if a is None else "vip"
              diffs.append(dict(cat="strict", rule="strict.scenario", scenario=scn, key=f"{side} 缺少该场景"))
              continue
          for kind, (keys, how) in STRICT.items():
              pa, pb = project(a, kind, keys), project(b, kind, keys)
              items = diff_seq(pa, pb) if how == "seq" else diff_multiset(pa, pb)
              diffs += [dict(cat="strict", rule=f"strict.{kind}", scenario=scn, key=k) for k in items]
          for kind, field in (("notify", "q"), ("irq", "vector")):
              sa = {e.get(field) for e in a if e["ev"] == kind}
              sb = {e.get(field) for e in b if e["ev"] == kind}
              if sa != sb:
                  diffs.append(dict(cat="review", rule=f"review.{kind}", scenario=scn,
                                    key=f"linux={sorted(sa, key=str)} vip={sorted(sb, key=str)}"))
          for kind, keys in (("desc_chain", ("q", "segs", "hdr")), ("complete", ("q", "len"))):
              for k in diff_multiset(project(a, kind, keys), project(b, kind, keys)):
                  diffs.append(dict(cat="review", rule=f"review.{kind}", scenario=scn, key=k))
          for k in diff_multiset(writes(a), writes(b)):
              diffs.append(dict(cat="review", rule="review.reg_wr", scenario=scn, key=k))
          for k in diff_multiset(reads(a), reads(b)):
              diffs.append(dict(cat="info", rule="info.access", scenario=scn, key=k))
      return diffs


  def load_whitelist(path):
      if not path:
          return []
      with open(path, encoding="utf-8") as fh:
          entries = json.load(fh)
      for i, ent in enumerate(entries):
          for field in ("rule", "scenario", "key_re", "reason"):
              if field not in ent:
                  raise InputError(f"{path}[{i}]: 缺少 {field}")
          if not str(ent["reason"]).strip():
              raise InputError(f"{path}[{i}]: reason 不能为空")
          re.compile(ent["key_re"])
      return entries


  def apply_whitelist(diffs, entries):
      used = [0] * len(entries)
      for d in diffs:
          d["waived_by"] = None
          if d["cat"] == "info":
              continue
          for i, ent in enumerate(entries):
              if ent["rule"] == d["rule"] and ent["scenario"] in ("*", d["scenario"]) \
                      and re.search(ent["key_re"], d["key"]):
                  d["waived_by"] = ent["reason"]
                  used[i] += 1
                  break
      return [ent for ent, n in zip(entries, used) if n == 0]


  def load_rules(mode, path):
      rules = json.loads(json.dumps(DEFAULT_RULES[mode]))
      if path:
          with open(path, encoding="utf-8") as fh:
              rules.update(json.load(fh))
      return rules


  def run_diff(linux_path, vip_path, mode, rules_path=None, wl_path=None):
      rules = load_rules(mode, rules_path)
      lin, p_lin = normalize(load(linux_path), rules, "linux")
      vip, p_vip = normalize(load(vip_path), rules, "vip")
      diffs = compare(lin, vip, rules)
      for scn, key in p_lin + p_vip + check_order(lin, rules, "linux") + check_order(vip, rules, "vip"):
          diffs.append(dict(cat="order", rule="order", scenario=scn, key=key))
      stale = apply_whitelist(diffs, load_whitelist(wl_path))
      failing = [d for d in diffs if d["cat"] in FAIL_CATS and d["waived_by"] is None]
      return diffs, stale, (1 if failing else 0)


  def render(diffs, stale, mode):
      lines = [f"# vdev_diff 结果（{mode}）", "", "| 场景 | strict | order | review | info | 结论 |",
               "|---|---|---|---|---|---|"]
      expected = {1, 2, 4} | ({3} if mode == "std" else set())
      for scn in sorted({d["scenario"] for d in diffs} | expected):
          cnt = Counter(d["cat"] for d in diffs if d["scenario"] == scn and d["waived_by"] is None)
          bad = sum(cnt[c] for c in FAIL_CATS)
          lines.append(f"| {SCENARIO_NAMES.get(scn, scn)} | {cnt['strict']} | {cnt['order']} | "
                       f"{cnt['review']} | {cnt['info']} | {'FAIL' if bad else 'PASS'} |")
      lines += ["", "| 场景 | 规则 | 差异 | 判定 |", "|---|---|---|---|"]
      for d in sorted(diffs, key=lambda x: (x["scenario"], x["cat"], x["rule"], x["key"])):
          verdict = "INFO" if d["cat"] == "info" else (f"豁免：{d['waived_by']}" if d["waived_by"] else "FAIL")
          lines.append(f"| {d['scenario']} | {d['rule']} | `{d['key']}` | {verdict} |")
      if stale:
          lines += ["", "未使用的白名单条目："] + [f"- {json.dumps(e, ensure_ascii=False)}" for e in stale]
      return "\n".join(lines) + "\n"


  def cmd_caps(path):
      segs = split_segments(load(path))
      for scn in (1, 0):
          for ev in segs.get(scn, []):
              if ev["ev"] == "features":
                  return f"{int(ev['drv_accepted']):x}"
      raise InputError(f"{path}: 没有 features 事件")


  def _write(path, events):
      with open(path, "w", encoding="utf-8") as fh:
          for ev in events:
              fh.write(json.dumps(ev) + "\n")


  def _trace(desc_addr=0x10000, enable_after_ok=False, pkt_payload="00ff", irq_times=2):
      def wr(field, val):
          return {"ev": "reg_wr", "fn": 0, "region": "common_cfg", "field": field, "q": 0, "val": val}

      ev = [{"ev": "status", "from": 0, "to": 0},
            {"ev": "reg_rd", "fn": 0, "region": "common_cfg", "field": "device_status", "q": -1, "val": 0},
            {"ev": "marker", "scenario": 1},
            {"ev": "status", "from": 0, "to": 1}, {"ev": "status", "from": 1, "to": 3},
            {"ev": "features", "dev_offered": 0x130000020, "drv_accepted": 0x100000020},
            {"ev": "status", "from": 3, "to": 11}]
      qcfg = [wr("queue_desc_lo", desc_addr), wr("queue_desc_hi", 0),
              wr("queue_driver_lo", desc_addr + 0x1000), wr("queue_device_lo", desc_addr + 0x2000),
              {"ev": "queue_cfg", "q": 0, "size": 256, "vector": 1, "enable": 1, "ring_fmt": "split"}]
      ok = [{"ev": "status", "from": 11, "to": 15}]
      ev += (ok + qcfg) if enable_after_ok else (qcfg + ok)
      ev += [{"ev": "marker", "scenario": 2}, {"ev": "notify", "q": 1, "next_idx": 1, "wrap": 0},
             {"ev": "pkt", "dir": "tx", "q": 1, "len": 2, "bytes": pkt_payload}]
      ev += [{"ev": "irq", "vector": 2}] * irq_times
      ev += [{"ev": "marker", "scenario": 4}, {"ev": "status", "from": 15, "to": 0},
             {"ev": "marker", "scenario": END_MARKER}]
      return ev


  def selftest():
      tmp = tempfile.mkdtemp(prefix="vdev_diff_")
      lin, vip = os.path.join(tmp, "l.jsonl"), os.path.join(tmp, "v.jsonl")
      wl = os.path.join(tmp, "wl.json")

      def run(lin_ev, vip_ev, wl_entries=None):
          _write(lin, lin_ev)
          _write(vip, vip_ev)
          path = None
          if wl_entries is not None:
              with open(wl, "w", encoding="utf-8") as fh:
                  json.dump(wl_entries, fh)
              path = wl
          return run_diff(lin, vip, "std", None, path)

      # 1. IOVA 不同但都对齐：无差异
      diffs, _, rc = run(_trace(), _trace(desc_addr=0x7f000))
      assert rc == 0 and not diffs, diffs
      # 2. irq 次数不同：只比是否发生
      diffs, _, rc = run(_trace(), _trace(irq_times=5))
      assert rc == 0 and not diffs, diffs
      # 3. 报文内容不同：strict.pkt 失败
      diffs, _, rc = run(_trace(), _trace(pkt_payload="0100"))
      assert rc == 1 and {d["rule"] for d in diffs} == {"strict.pkt"}, diffs
      # 4. DRIVER_OK 之后 enable 队列：偏序失败
      diffs, _, rc = run(_trace(), _trace(enable_after_ok=True))
      assert rc == 1 and any("DRIVER_OK" in d["key"] for d in diffs if d["cat"] == "order"), diffs
      # 5. 描述符表地址未按 16 字节对齐：偏序（对齐）失败
      diffs, _, rc = run(_trace(), _trace(desc_addr=0x10008))
      assert rc == 1 and any("对齐" in d["key"] for d in diffs), diffs
      # 6. 白名单豁免 + 未使用条目报告
      diffs, stale, rc = run(_trace(), _trace(pkt_payload="0100"),
                             [{"rule": "strict.pkt", "scenario": 2, "key_re": "only_", "reason": "自测豁免"},
                              {"rule": "order", "scenario": "*", "key_re": "never", "reason": "未用"}])
      assert rc == 0 and len(stale) == 1, (diffs, stale)
      # 7. 复位后没读 status=0 就重新初始化：偏序失败
      no_reset_read = [e for e in _trace() if not (e["ev"] == "reg_rd" and e["field"] == "device_status")]
      diffs, _, rc = run(_trace(), no_reset_read)
      assert rc == 1 and any("复位后" in d["key"] for d in diffs), diffs
      # 8. 多余的配置读：只记 info，不失败
      extra_rd = _trace()
      extra_rd.insert(5, {"ev": "reg_rd", "fn": 0, "region": "device_cfg", "field": "mac", "q": -1, "val": 1})
      diffs, _, rc = run(_trace(), extra_rd)
      assert rc == 0 and [d["cat"] for d in diffs] == ["info"], diffs
      # 9. caps 取 Linux 的 drv_accepted
      _write(lin, _trace())
      assert cmd_caps(lin) == "100000020"
      print("vdev_diff selftest PASS")
      return 0


  def main(argv):
      ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
      sub = ap.add_subparsers(dest="cmd", required=True)
      p_diff = sub.add_parser("diff")
      p_diff.add_argument("linux")
      p_diff.add_argument("vip")
      p_diff.add_argument("--mode", choices=("std", "priv"), required=True)
      p_diff.add_argument("--rules")
      p_diff.add_argument("--whitelist")
      p_diff.add_argument("--report")
      p_caps = sub.add_parser("caps")
      p_caps.add_argument("linux")
      sub.add_parser("selftest")
      args = ap.parse_args(argv)
      try:
          if args.cmd == "selftest":
              return selftest()
          if args.cmd == "caps":
              print(cmd_caps(args.linux))
              return 0
          diffs, stale, rc = run_diff(args.linux, args.vip, args.mode, args.rules, args.whitelist)
      except (InputError, OSError, ValueError) as exc:
          print(f"vdev_diff: {exc}", file=sys.stderr)
          return 2
      text = render(diffs, stale, args.mode)
      if args.report:
          with open(args.report, "w", encoding="utf-8") as fh:
              fh.write(text)
      print(text)
      print(f"VDEV_DIFF {'FAIL' if rc else 'PASS'} mode={args.mode}")
      return rc


  if __name__ == "__main__":
      sys.exit(main(sys.argv[1:]))
  ```
  起草时已在本机 Python 3.12 下用 `selftest` 验证通过（9 个用例）。脚本只用 3.8 可用的语法。

- [ ] **Step 4: 自测、重编、产生第一份 Linux 轨迹**

  ```bash
  $S53 'cd ~/cosim_diff && python3 -I tools/vdev_diff.py selftest'
  $S53 'cd ~/cosim_diff && ./build_cosim.sh && WALL_S=1800 ./run_cosim.sh std smoke'
  $S53 'cd ~/cosim_diff/out/std/smoke && wc -l linux.jsonl && grep -c "\"ev\":\"marker\"" linux.jsonl && head -3 linux.jsonl && python3 -I -c "import json,sys; [json.loads(l) for l in open(\"linux.jsonl\")]; print(\"JSON OK\")"'
  ```
  期望：
  - 输出 `vdev_diff selftest PASS`。
  - `linux.jsonl` 有数百行以上。冒烟写过一次 0xA5，所以至少有 1 个 `marker` 事件，`scenario` 为 165。
  - 每行都能被 JSON 解析，输出 `JSON OK`。
  - 若 `"field":""` 或 `region` 为空的事件很多，说明设备模型的字段解码不全，回到 D 补齐（模型有误）。

  提交：`$S53 'cd ~/cosim_diff && git add -A && git commit -qm "feat: JSONL 记录器与 vdev_diff.py"'`。

---

### Task F2: 标准模式对比、逐条判定与修复

**Files:**
- Create (53): `~/cosim_diff/sv/vdev_diff_tests.sv`（`vdev_diff_frame`、`vdev_diff_std_test`）、`~/cosim_diff/vip_diff.sh`、`~/cosim_diff/whitelist_std.json`、`~/cosim_diff/triage_std.md`
- Modify (`virtio_sdd`，按差异而定): VIP 源码、设备模型（`virtio_net_vip/src/devmodel/*`）、对应回归测试；新增测试时同步 `scripts/test_manifest.sh`、`filelists/tests.f`、README.md、`docs/virtio_net_vip_manual.md`、`docs/virtio_verification_flow.md`
- Test: `vdev_diff.py diff ... --mode std` 输出 `VDEV_DIFF PASS`；`strict_regression` 全过

**Interfaces:**
- Consumes:
  - E3 的帧定义和 marker 号；F1 的记录器与 `vdev_diff.py`。
  - `virtio_real_driver_flow_fixture` 的 API：`build_flow`、`function_bdf`、`function_by_bdf`、`start_driver_flow`、`setup_queue`、`submit_tx`、`complete_tx`、`refill_rx`、`receive_rx`、`tx_queue_id_for_pair`、`rx_queue_id_for_pair`、`reset_and_teardown`，字段 `device_features`；D3 之后的 `devices[]`（`vdev_virtio_pci`，build_phase 创建）与 `function vdev_virtio_pci device()`（end_of_elaboration 后按 BDF 返回）。
  - 驱动特性：`virtio_function_instance::drv_cfg.driver_features`（`start_driver_flow` 读它协商）。MQ：`virtio_atomic_ops::ctrl_set_mq_pairs(n, ref bit success)` 与 `setup_msix(n)`（A2 的重建顺序）。
  - E2 的 `vdev_diff_pkg`（`VDEV_DIFF_STD_*`、`vdev_marker`）。
- Produces:
  - `out/std/scen/linux.jsonl`、`out/std/scen/vip.jsonl`、`out/std/scen/diff.md`。
  - `triage_std.md`：每条差异一行，记录 ID（STD-nn）、场景、规则、差异摘要、判定、处理（提交号或白名单理由）、新增回归测试。

- [ ] **Step 1: 写 `~/cosim_diff/sv/vdev_diff_tests.sv`**

  ```systemverilog
  // vdev_diff_tests.sv —— 临时 VIP 侧对比测试。只经 ~/cosim_diff/vip_diff.sh 编译，不进 manifest。
  `ifndef VDEV_DIFF_TESTS_SV
  `define VDEV_DIFF_TESTS_SV
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import virtio_net_pkg::*;
  import net_packet_pkg::*;
  import vdev_diff_pkg::*;

  // 与 guest vdev_pktgen.c build_frame() 逐字节一致。raw_data 预先填好：virtio_net_packet_adapter::pack
  // 只要求 packet_item 且 raw_data 非空时直接取这些字节，不再 do_pack。
  class vdev_diff_frame;
    static function packet_item build(int unsigned seq, int unsigned len);
      packet_item item;
      item = packet_item::type_id::create($sformatf("vdev_diff_frame%0d", seq));
      repeat (6) item.pkt.raw_data.push_back(8'hff);
      item.pkt.raw_data.push_back(8'h02); item.pkt.raw_data.push_back(8'h56);
      item.pkt.raw_data.push_back(8'h44); item.pkt.raw_data.push_back(8'h45);
      item.pkt.raw_data.push_back(8'h56); item.pkt.raw_data.push_back(8'h00);
      item.pkt.raw_data.push_back(8'h88); item.pkt.raw_data.push_back(8'hb5);
      item.pkt.raw_data.push_back(seq[31:24]); item.pkt.raw_data.push_back(seq[23:16]);
      item.pkt.raw_data.push_back(seq[15:8]);  item.pkt.raw_data.push_back(seq[7:0]);
      for (int unsigned j = 18; j < len; j++)
        item.pkt.raw_data.push_back(8'((seq * 7 + j) & 'hff));
      return item;
    endfunction
  endclass

  // 标准模式：virtio_real_driver_flow_fixture（MODEL）面对 vdev_virtio_pci，经 vdev_uvm_ep_port 走 pcie_tl。
  class vdev_diff_std_test extends uvm_test;
    `uvm_component_utils(vdev_diff_std_test)
    virtio_real_driver_flow_fixture flow;
    vdev_jsonl_writer               writer;
    int unsigned                    n_frames;
    int unsigned                    frame_len;
    int unsigned                    qsize;
    bit [63:0]                      drv_features;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // flow.device_features 必须在 fixture 的 build_phase 之前写入（fixture 注释的约定）；configure_devices
    // 再把它和 default_num_pairs/default_queue_size 交给 vdev_virtio_pci。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
      flow.device_features = VDEV_DIFF_STD_FEATURES;
      writer = vdev_jsonl_writer::type_id::create("writer", this);
      if (!$value$plusargs("VDEV_N=%d", n_frames))
        n_frames = 16;
      if (!$value$plusargs("VDEV_LEN=%d", frame_len))
        frame_len = 128;
      if (!$value$plusargs("VDEV_QSIZE=%d", qsize))
        qsize = VDEV_DIFF_STD_QUEUE_MAX;
      if (!$value$plusargs("VDEV_DRV_FEATURES=%h", drv_features))
        `uvm_fatal("VDEV_DIFF", "缺少 +VDEV_DRV_FEATURES（vdev_diff.py caps linux.jsonl）")
    endfunction

    // fixture 在 build_phase 为每个 VIO PF 建一个设备（vio_pf_count 缺省 1）；BDF 到 end_of_elaboration 才定，
    // flow.device() 此时还是 null，所以按 devices[] 接线。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (flow.devices.size() != 1)
        `uvm_fatal("VDEV_DIFF", $sformatf("期望 1 个 MODEL 设备，实际 %0d", flow.devices.size()))
      flow.devices[0].event_ap.connect(writer.analysis_export);
    endfunction

    // 子组件先跑 end_of_elaboration：configure_devices 已给设备赋参数，这里确认与 cosim 一侧相同。
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if ((flow.devices[0].max_pairs != VDEV_DIFF_STD_PAIRS) ||
          (flow.devices[0].queue_max != VDEV_DIFF_STD_QUEUE_MAX) ||
          (flow.devices[0].device_features != VDEV_DIFF_STD_FEATURES))
        `uvm_fatal("VDEV_DIFF", "VIP 一侧设备参数与 cosim 一侧（vdev_diff_pkg）不一致")
    endfunction

    task setup_pair(int unsigned pair, virtqueue_type_e fmt);
      int unsigned rx_q;
      int unsigned tx_q;
      bit          ok;
      string       why;
      if (!flow.rx_queue_id_for_pair(pair, rx_q, why) || !flow.tx_queue_id_for_pair(pair, tx_q, why))
        `uvm_fatal("VDEV_DIFF", why)
      flow.setup_queue(rx_q, qsize, fmt, ok);
      if (!ok) `uvm_error("VDEV_DIFF", $sformatf("pair%0d RX 队列建立失败", pair))
      flow.setup_queue(tx_q, qsize, fmt, ok);
      if (!ok) `uvm_error("VDEV_DIFF", $sformatf("pair%0d TX 队列建立失败", pair))
    endtask

    task traffic(int unsigned pair);
      int unsigned     rx_q;
      int unsigned     tx_q;
      int unsigned     desc_id;
      int unsigned     done_count;
      bit              ok;
      string           why;
      virtio_net_hdr_t hdr;
      packet_item      frame;
      uvm_object       completed[$];
      uvm_object       received[$];
      if (!flow.rx_queue_id_for_pair(pair, rx_q, why) || !flow.tx_queue_id_for_pair(pair, tx_q, why))
        `uvm_fatal("VDEV_DIFF", why)
      flow.refill_rx(rx_q, n_frames, ok);
      if (!ok) `uvm_error("VDEV_DIFF", $sformatf("pair%0d RX refill 失败", pair))
      hdr = '{default: 0};
      for (int unsigned i = 0; i < n_frames; i++) begin
        frame = vdev_diff_frame::build(i, frame_len);
        flow.submit_tx(tx_q, hdr, frame, 1'b0, desc_id, ok);
        if (!ok) `uvm_error("VDEV_DIFF", $sformatf("pair%0d 帧 %0d 提交失败", pair, i))
      end
      flow.complete_tx(tx_q, completed, n_frames, done_count, ok);
      if (!ok || done_count != n_frames)
        `uvm_error("VDEV_DIFF", $sformatf("pair%0d TX 完成 %0d/%0d", pair, done_count, n_frames))
      flow.receive_rx(rx_q, n_frames, received, done_count, ok);
      if (!ok || done_count != n_frames)
        `uvm_error("VDEV_DIFF", $sformatf("pair%0d RX 收到 %0d/%0d", pair, done_count, n_frames))
    endtask

    task run_phase(uvm_phase phase);
      bit                      ok;
      string                   why;
      virtqueue_type_e         fmt;
      virtio_function_instance f;
      phase.raise_objection(this);
      if (flow.build_flow(why) == 0)
        `uvm_fatal("VDEV_DIFF", why)
      f = flow.function_by_bdf(flow.function_bdf());
      if ((f == null) || (flow.device() == null))
        `uvm_fatal("VDEV_DIFF", "选中的 Function 或其 MODEL 设备不存在")
      // start_driver_flow 用 f.drv_cfg.driver_features 协商；取 Linux S1 实际接受的集合（caps）。
      f.drv_cfg.driver_features = drv_features;
      fmt = drv_features[VIRTIO_F_RING_PACKED] ? VQ_PACKED : VQ_SPLIT;
      vdev_marker(flow.device(), 1);
      flow.start_driver_flow(ok);
      if (!ok) `uvm_error("VDEV_DIFF", "S1 初始化失败")
      setup_pair(0, fmt);
      if (drv_features[VIRTIO_NET_F_CTRL_VQ]) begin
        flow.setup_queue(2 * VDEV_DIFF_STD_PAIRS, qsize, fmt, ok);   // ctrl VQ 队列号 2*max_pairs（D2）
        if (!ok) `uvm_error("VDEV_DIFF", "S1 ctrl VQ 建立失败")
      end
      vdev_marker(flow.device(), 2);
      traffic(0);
      vdev_marker(flow.device(), 3);
      // 与 virtio_auto_fsm::do_configure_mq（含 A2 的 MSI-X 重建）同序。fixture 不走 FSM 的 full_init，
      // FSM 的 active_num_pairs 没有记录，不能直接调 fsm.configure_mq。
      f.driver_agent.ops.ctrl_set_mq_pairs(2, ok);
      if (!ok) `uvm_error("VDEV_DIFF", "S3 VQ_PAIRS_SET 2 失败")
      setup_pair(1, fmt);
      f.driver_agent.ops.setup_msix(f.vq_mgr.get_queue_count());
      traffic(1);
      vdev_marker(flow.device(), 4);
      flow.reset_and_teardown(ok);
      if (!ok) `uvm_error("VDEV_DIFF", "S4 复位回收失败")
      vdev_marker(flow.device(), 255);
      phase.drop_objection(this);
    endtask
  endclass
  `endif
  ```
  说明：
  - VIP 侧按 VIP 正常用法建队列（先 `start_driver_flow` 再 `setup_queue`）。若 VIP 在 DRIVER_OK 之后才 enable 队列，或扩容时没有走 RING_RESET 就新建队列，`vdev_diff.py` 的偏序检查会把它报出来。这正是要找的差异，不在测试里绕开。
  - 驱动侧配置 `num_queue_pairs` 保持 fixture 的 2（`start_driver_flow` 按 2 对 + ctrl 建 MSI-X），与 Linux 按最大队列数分配向量的做法一致。

- [ ] **Step 2: 写 `~/cosim_diff/vip_diff.sh`**

  ```bash
  #!/usr/bin/env bash
  # vip_diff.sh <test> <out.jsonl> [plusargs...] —— 编译“回归 simv + 临时对比测试”，运行一个对比测试
  set -euo pipefail
  TEST=${1:?test}; OUT=${2:?out.jsonl}; shift 2
  CD=$HOME/cosim_diff; VW=$HOME/virtio_priv_run/virtio_work
  set +u; source ~/virtio_priv_run/env.sh; set -u
  mkdir -p "$CD/build" "$(dirname "$OUT")"
  cd "$VW"
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -f filelists/dpu_common.f -f filelists/virtio_net.f -f filelists/queue_work_integration.f \
    +incdir+"$CD/sv" "$CD/sv/vdev_diff_pkg.sv" \
    -f filelists/tests.f "$CD/sv/vdev_diff_tests.sv" \
    -top virtio_tb_top -Mdir="$CD/build/csrc_vipdiff" -o "$CD/build/simv_vipdiff" \
    -l "$CD/build/compile_vipdiff.log" > /dev/null
  LOG=${OUT%.jsonl}.log
  "$CD/build/simv_vipdiff" +UVM_TESTNAME="$TEST" +VDEV_JSONL="$OUT" +UVM_VERBOSITY=UVM_LOW "$@" > "$LOG" 2>&1 || true
  grep -E "^Error-|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" "$LOG" | tail -5
  echo "VIP_DIFF test=$TEST out=$OUT log=$LOG"
  ```
  这个 simv 与回归 simv 同源，只多编了两个临时文件。`-Mdir`/`-o` 指向 `~/cosim_diff/build`，不碰 `virtio_work/build`。仍遵守“53 上同一时间只跑一个仿真”。

- [ ] **Step 3: Linux 轨迹（标准模式）**

  ```bash
  $S53 'cd ~/cosim_diff && ./build_cosim.sh && WALL_S=3600 ./run_cosim.sh std scen 16'
  $S53 'cd ~/cosim_diff/out/std/scen && grep -o "\"ev\":\"marker\",\"scenario\":[0-9]*" linux.jsonl; python3 -I ../../../tools/vdev_diff.py caps linux.jsonl'
  ```
  期望：
  - guest 输出 `VDEV_SCN PASS`。
  - marker 依次为 1、2、3、4、255。
  - `caps` 打印一个十六进制 feature 值，记为 `CAPS`。
  - Linux 轨迹自身有 order 违例时（第一次 diff 会报 `linux: ...`），先按“模型有误或规则有误”判定。Linux 驱动是参照方，不改 Linux 的行为。

- [ ] **Step 4: VIP 轨迹与第一次对比**

  ```bash
  $S53 'cd ~/cosim_diff && echo "[]" > whitelist_std.json && CAPS=$(python3 -I tools/vdev_diff.py caps out/std/scen/linux.jsonl) && \
    ./vip_diff.sh vdev_diff_std_test out/std/scen/vip.jsonl +VDEV_DRV_FEATURES=$CAPS +VDEV_N=16'
  $S53 'cd ~/cosim_diff && python3 -I tools/vdev_diff.py diff out/std/scen/linux.jsonl out/std/scen/vip.jsonl \
    --mode std --whitelist whitelist_std.json --report out/std/scen/diff.md | tail -40'
  ```
  VIP 测试编译不过时，以 D/C 完成后 fixture 与 ops 的实际代码为准改 `vdev_diff_tests.sv`（只改临时文件）。VIP 测试运行报 `UVM_ERROR` 时，这本身就是差异，记入 triage。

- [ ] **Step 5: 逐条判定（循环直到 `VDEV_DIFF PASS`）**

  把 `diff.md` 中每条 `FAIL` 行编号（STD-01、STD-02……）写进 `triage_std.md`，逐条给出下列判定之一：

  | 判定 | 依据 | 处理 |
  |---|---|---|
  | VIP 有误 | VIP 行为违反 virtio 1.2 的 MUST/SHOULD 条款，或者与 Linux 不同且 Linux 一侧是规范要求的唯一做法 | 在 `virtio_sdd` 修 VIP（见下方流程） |
  | 模型有误 | Linux 一侧出现 order 违例；或模型的应答随驱动不同而不合规范（例如接受了非法序列、事件字段解码错误、漏发事件） | 在 `virtio_sdd` 修 `devmodel/`：先补 D 的设备单元测试，再按下方流程提交 |
  | 两者都合规 | 规范允许的选择不同，例如向量分配、MSI-X 表项的消息地址/数据（`region=msix`，平台决定）、队列深度、描述符布局、ctrl RX 模式命令的有无、读寄存器的冗余 | 写入 `whitelist_std.json`，`reason` 写明规范条款或理由，`key_re` 尽量窄 |

  VIP 有误时的修复流程（每条差异一个提交，遵守 Global Constraints）：
  1. 在 `virtio_sdd` 的常规回归中写失败测试（RED）。优先在已有测试里加用例（如 `virtio_ctrl_vq_test`、`virtio_real_driver_multiqueue_test`）。必须新增测试时，同步 manifest、`tests.f` 和三份文档的清单，回归数 N 加 1。
  2. SYNC，单测确认失败。
  3. 修复，单测通过。
  4. 回归：`STRICT_REGRESSION PASS tests=<N>`。
  5. 提交：`fix: <现象>（cosim 对比 STD-nn）`。
  6. SYNC，然后重跑 Step 4 的 VIP 一侧。只有设备模型改动时，才需要连同 Step 3 的 Linux 一侧一起重跑。

  每轮之后重新 diff。全部条目处理完时，期望 `VDEV_DIFF PASS mode=std`，且 `diff.md` 没有“未使用的白名单条目”。若某条差异的修复需要改动公共接口或推翻 A–D 的设计，停下汇报，不要在本任务里扩大范围。

- [ ] **Step 6: 收尾**

  ```bash
  $S53 'cd ~/cosim_diff && git add -A && git commit -qm "test: 标准模式对比通过（triage_std.md、whitelist_std.json）"'
  ```
  期望 `triage_std.md` 中每条都有判定和处理，`virtio_sdd` 中每个修复提交都对应一条 STD-nn。

---

### Task F3: 私有模式对比与修复、差异报告、终回归

**Files:**
- Modify (53): `~/cosim_diff/sv/vdev_diff_tests.sv`（追加 `vdev_diff_priv_test`）
- Create (53): `~/cosim_diff/rules_priv.json`、`~/cosim_diff/whitelist_priv.json`、`~/cosim_diff/triage_priv.md`
- Create (`virtio_sdd`): `docs/cosim-driver-diff-report.md`
- Modify (`virtio_sdd`，按差异而定): 同 F2
- Test: `vdev_diff.py diff ... --mode priv` 输出 `VDEV_DIFF PASS`；终回归 `STRICT_REGRESSION PASS tests=<N>`

**Interfaces:**
- Consumes:
  - F2 的 `vdev_diff_frame`、`vip_diff.sh` 与 `vdev_diff_pkg`。
  - D5 之后的 `dpu_priv_driver_flow_test`（`devices[2]`/`ports[2]`/`logs[2]`、`private_functions[2]`、`private_ops[2]`（`virtio_atomic_ops`）、`attach_private_device`）。
  - D 的 `vdev_dpu_priv` 事件字段名（`bar0_field/qinfo_field`）与 D Notes 中 VIP 后端刻意不做的驱动步骤清单。
  - 驱动源码 `icpu-kernel-driver f2c9cd6` 的寄存器访问顺序，例如 `main.c` probe：读 BAR2 `DPU_MAILBOX_QINFO_CFG_HOST_ID_FIELD` → `af_soft_reset_fe` → 读 `DPU_AF_DECLARATION_ADDR` → 写魔数 → 回读 → 写 `DPU_AF_HOST_ID_REG_ADDR`。
- Produces: 私有模式的对比结论、`docs/cosim-driver-diff-report.md` 和最终回归结果。

- [ ] **Step 1: 私有偏序规则 `~/cosim_diff/rules_priv.json`**

  字段名取自 D 的 `vdev_dpu_priv::bar0_field/qinfo_field`（与 D5 `virtio_vdev_unit_test` 的 `test_priv_backend_sequence` 期望序列同名）。执行前仍要对照 `out/priv/scen/linux.jsonl` 中实际出现的名字核对一遍。
  ```json
  {
    "status_field": "",
    "addr_fields": {"vtx_content.dw0": 1, "vtx_content.dw1": 1, "vrx_content.dw0": 1, "vrx_content.dw1": 1,
                    "qid_map.": 1, "bdf": 1},
    "enable_requires": [],
    "review_ignore_fields": [],
    "order_pairs": [
      ["reg_rd:bar2.host_id", "reg_wr:bar0.soft_reset"],
      ["reg_wr:bar0.soft_reset", "reg_wr:bar0.af_declaration"],
      ["reg_wr:bar0.af_declaration=0x5555aaaa", "reg_wr:bar0.mb_af_host_id"],
      ["reg_wr:bar0.mb_af_host_id", "reg_wr:bar2.bdf"]
    ]
  }
  ```
  - `addr_fields` 在私有模式下只用来符号化与平台有关的值，对齐取 1（不做对齐检查）：VTX/VRX 参数表 DW0/DW1 是 ring IOVA；qid map 各项 DW0/DW1 含 notify 地址（BAR0 基址）；`bdf`（BAR2）与 `bdf_map.<n>` 含 BDF。qid map 的 gq（DW2）随整组符号化，gq 差异由 `queue_cfg` 的 strict 比较兜住。
  - 私有寄存器事件的 `q` 恒为 -1，不能按队列核对“enable 前写地址”，故 `enable_requires` 为空。
  - 每条 `order_pairs` 在报告“私有偏序依据”中注明驱动源码位置：`main.c:2020`（读 BAR2 host_id）→ `main.c:1914`（`af_soft_reset_fe`）→ `main.c:2035`（写 0x5555AAAA）→ `main.c:2052`（`INTF_MB_AF_HOST_ID`）→ `mailbox.c:441`（`dpu_mailbox_cfg_bdf`），对应 D4 表 #2、#3、#5、#7、#10。驱动中看不出顺序的，不写进规则。

- [ ] **Step 2: 追加 `vdev_diff_priv_test`**

  D 之后 `virtio_real_driver_flow_fixture` 只建标准 Function，私有 VF 面对 `vdev_dpu_priv` 的唯一装配在 `dpu_priv_driver_flow_test`（双 Host 系统环境，`attach_private_device` 把每个 Host 的 VF0 挂到回环端口）。对比测试继承它，只用 Host 0 的私有 VF（RX lqid 0、TX lqid 1），不跑父类的 `run_phase`。在 `vdev_diff_tests.sv` 的 `` `endif `` 之前追加：
  ```systemverilog
  class vdev_diff_priv_test extends dpu_priv_driver_flow_test;
    `uvm_component_utils(vdev_diff_priv_test)
    localparam int unsigned MAX_POLLS = 100000;
    vdev_jsonl_writer writer;
    int unsigned      n_frames;
    int unsigned      frame_len;

    function new(string name = "vdev_diff_priv_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      writer = vdev_jsonl_writer::type_id::create("writer", this);
      if (!$value$plusargs("VDEV_N=%d", n_frames))
        n_frames = 16;
      if (!$value$plusargs("VDEV_LEN=%d", frame_len))
        frame_len = 128;
    endfunction

    // 父类把 devices[h].event_ap 接到 logs[h]；这里再把 Host 0 的设备接到记录器。
    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      devices[0].event_ap.connect(writer.analysis_export);
    endfunction

    // 有界轮询：设备 worker 写完 CQ 后 ops 才能认领。
    task wait_tx(int unsigned want);
      uvm_object part[$];
      int unsigned got;
      got = 0;
      for (int unsigned i = 0; (i < MAX_POLLS) && (got < want); i++) begin
        part.delete();
        private_ops[0].tx_complete(1, part, want - got);
        got += part.size();
        if (part.size() == 0)
          #10ns;
      end
      if (got != want)
        `uvm_error("VDEV_DIFF", $sformatf("私有 TX 完成 %0d/%0d", got, want))
    endtask

    task wait_rx(int unsigned want);
      uvm_object part[$];
      int unsigned got;
      got = 0;
      for (int unsigned i = 0; (i < MAX_POLLS) && (got < want); i++) begin
        part.delete();
        private_ops[0].rx_receive(0, part, want - got);
        got += part.size();
        if (part.size() == 0)
          #10ns;
      end
      if (got != want)
        `uvm_error("VDEV_DIFF", $sformatf("私有 RX 收到 %0d/%0d", got, want))
    endtask

    virtual task run_phase(uvm_phase phase);
      virtio_net_hdr_t hdr;
      packet_item      frame;
      int unsigned     id;
      phase.raise_objection(this);
      vdev_marker(devices[0], 1);
      private_functions[0].driver_agent.fsm.full_init();
      if (private_functions[0].driver_agent.fsm.state != FSM_READY)
        `uvm_fatal("VDEV_DIFF", "S1 私有初始化失败")
      vdev_marker(devices[0], 2);
      hdr = '{default: 0};
      private_ops[0].rx_refill(0, n_frames);
      for (int unsigned i = 0; i < n_frames; i++) begin
        frame = vdev_diff_frame::build(i, frame_len);
        private_ops[0].tx_submit(1, hdr, frame, 1'b0, id);
      end
      wait_tx(n_frames);
      wait_rx(n_frames);
      vdev_marker(devices[0], 4);
      private_functions[0].shutdown();
      if (private_functions[0].state != VF_DISABLED)
        `uvm_error("VDEV_DIFF", "S4 私有 Function 停机失败")
      vdev_marker(devices[0], 255);
      phase.drop_objection(this);
    endtask
  endclass
  ```
  说明：
  - `private_ops[0]` 是通用 `virtio_atomic_ops`（C/D 之后），后端为寄存器级 `dpu_priv_config_backend`；S1 走 FSM `full_init`，即 D5 后端的 `discover`/`reset`/`configure_queue`/`enable_queue`。
  - 若 `full_init` 已预填 RX 使 `rx_refill(0, n_frames)` 报环满，去掉这行补充（预填的 buffer 足够收回回环帧），在 triage 中记一笔。
  - S4 用 `private_functions[0].shutdown()` 对应 Linux 的 `ip link down` + `rmmod`；D Notes 列出的 VIP 后端刻意不做的驱动步骤（#9、#11–15、#18、#19、#22、#23、#26、#30、#32、#34–38）只出现在 Linux 轨迹，在 Step 4 逐条写白名单。

- [ ] **Step 3: 私有模式 Linux 轨迹、VIP 轨迹与对比**

  ```bash
  $S53 'cd ~/cosim_diff && ./build_cosim.sh && WALL_S=3600 ./run_cosim.sh priv scen 16'
  $S53 'cd ~/cosim_diff && echo "[]" > whitelist_priv.json && \
    ./vip_diff.sh vdev_diff_priv_test out/priv/scen/vip.jsonl +VDEV_N=16'
  $S53 'cd ~/cosim_diff && python3 -I tools/vdev_diff.py diff out/priv/scen/linux.jsonl out/priv/scen/vip.jsonl \
    --mode priv --rules rules_priv.json --whitelist whitelist_priv.json --report out/priv/scen/diff.md | tail -40'
  ```
  私有设备没有 feature 协商，`vdev_diff_priv_test` 不读 `+VDEV_DRV_FEATURES`。

- [ ] **Step 4: 逐条判定（同 F2 Step 5，编号 PRIV-nn，记入 `triage_priv.md`）**

  私有模式的补充规则：
  - 驱动与 dpu_common reg plan 不一致、或语义不明的地方，按驱动预期判定。
  - 模型和 VIP 都改成按驱动预期，并把这一点写进报告的“疑点清单”，同时更新 `vdev_dpu_priv.sv` 文件头。
  - VIP 修复提交信息为 `fix: <现象>（cosim 对比 PRIV-nn）`。
  - 循环直到 `VDEV_DIFF PASS mode=priv`。
  - 收尾：`git add -A && git commit -qm "test: 私有模式对比通过"`（在 53 `~/cosim_diff`）。

- [ ] **Step 5: 写 `docs/cosim-driver-diff-report.md`（virtio_sdd）**

  结构如下（中文，表格为主）：
  ```markdown
  # 真实驱动对比验证报告

  ## 1 概述
  目的；日期；VIP 分支与起止提交；设备模型提交；环境版本（QEMU 9.2.0 TCG、cosim-platform 59@6b99406
  + 本地补丁、guest 内核 6.8.0-107-generic + Alpine 3.20 用户态、dpu_snd1 icpu-kernel-driver f2c9cd6
  + 兼容补丁、VCS W-2024.09-SP1、dpu_common 4d73996）。

  ## 2 与设计的偏差
  | 设计 | 实际 | 原因 |
  （cosim-pcie-rc 路线 R 代替 cosim-pcie-pf；内建 virtio_net 用 sysfs bind/unbind 代替 modprobe/rmmod；
  ipv6.disable=1；S3 用 XPS 把发送固定到第 2 对；dpu_snd1 在本机 noble 工具链编译，Debian 回退不可行；
  review 类与白名单的引入）

  ## 3 结论
  | 模式 | 场景 | 结果 | 差异数（VIP 有误/模型有误/两者合规） |
  （std：S1–S4；priv：S1、S2、S4）

  ## 4 差异明细
  | ID | 场景 | 规则 | Linux 行为 | VIP 行为 | 判定 | 处理（提交 / 白名单理由） | 新增回归测试 |

  ## 5 私有驱动与 reg plan 疑点清单
  | 寄存器/流程 | 驱动源码位置 | reg plan 定义 | 不一致或不明之处 | 模型采用的语义 |
  另列私有偏序规则的驱动源码依据。

  ## 6 回归
  起点 40 个；新增测试列表；最终 STRICT_REGRESSION PASS tests=<N>。

  ## 附录 A 复跑说明（53 ~/cosim_diff）
  目录结构；依赖（/usr/local glib 2.66.8、~/virtio_priv_run/env.sh）；命令序列：
  SYNC → ./build_cosim.sh → ./run_cosim.sh std scen 16 → ./vip_diff.sh vdev_diff_std_test ... →
  python3 tools/vdev_diff.py diff ...（priv 同理）；镜像重新注入：./guest/inject.sh images/rootfs.ext4；
  QEMU 插件改动后：复制插件到 qemu/hw/net 并 ninja -C qemu/build qemu-system-x86_64；
  dpu_snd1.ko 重编：本机 apt download 头文件 + drv/patches。

  ## 附录 B 白名单全文
  whitelist_std.json 与 whitelist_priv.json 原文及每条理由。
  ```
  提交：
  ```bash
  git add docs/cosim-driver-diff-report.md
  git commit -m "docs: 真实驱动对比验证报告"
  ```

- [ ] **Step 6: 终回归**

  ```bash
  # SYNC 后
  sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
  ```
  期望：第一条 grep 无输出，末行为 `STRICT_REGRESSION PASS tests=<N>`。N 等于 40 加上 A–F 新增的测试数，与报告第 6 节一致。另外确认 `git status` 干净，且 `~/cosim_diff` 中的任何文件都没有进入 `virtio_sdd`：`git ls-files | grep -E "vdev_cosim|cosim_vdev_top|vdev_diff" ` 应为空，报告文件名不在此模式内。

---

## Notes for integrator (E/F)

**已对齐（E/F 原按假设 A1–A10 起草，现已按 D/C/A_B 的实际接口改写）：**

- `vdev_cosim_port`：改为实现 D 的三个纯虚任务 `dma_read(requester, addr, len, output bit [7:0] data[], output bit ok)`、`dma_write(requester, addr, bit [7:0] data[], output bit ok)`、`raise_msix(requester, addr, data)`；DPI 失败时 `ok=0` 并报 `uvm_error`。去掉了假设中的 `bind_port`、`ref byte unsigned data[$]` 和按向量号投递。
- TLP 分派：配置请求经 `device_by_bdf(COSIM_BDF)` 调零时间函数 `cfg_read(bit [11:0])`/`cfg_write(addr, data, be)`；MMIO 经 `device_by_addr(addr, bar, offset)` 调 `mmio_read/mmio_write(bar, off, size, …)`，按 `first_be` 拆成 1/2/4 字节的访问。去掉了假设中的 `mem_read/mem_write(..., hit)` task。
- 设备构造：`cosim_vdev_test` 先设参数（标准 `device_features/max_pairs/queue_max`，私有 `host_id=0`）和 `bdf=0x0018`，再调 `init()`，然后 `port.attach(dev)`。标准设备参数放在新文件 `vdev_diff_pkg`（E2 建立），与 VIP fixture 交给设备的值（2 对、256、`flow.device_features`）相同，VIP 测试在 end_of_elaboration 中核对。
- BAR 拓扑：标准设备是 BAR0/2/4（notify 在 BAR2），私有设备是 BAR0 32 MiB、BAR2、BAR4，都是 64 位。路线 R 的补丁按 sizing 注册全部 BAR。E2 冒烟的期望值已经按此改写。
- Marker：寄存器从“vendor cap +8”改为扩展配置空间 VSEC 的 0x108（0x100 处 DW0=`0x0001000B`、VSEC ID 0x5644）。guest 用 `setpci 108.L` 写入，VIP 用 `vdev_marker()` 调 `cfg_write(vdev_base::DEBUG_MARKER_OFF, …)`。D 没有 `emit_marker`。
- JSONL：记录器直接输出 D 的 `vdev_event::to_json()`，再在前面加 `seq`。`kind` 是枚举，字段名是 `from_status/to_status`、`bytes`、`has_hdr`。`vdev_diff.py` 把 `fn`（BDF）加入 `DROP_KEYS`，selftest 仍然通过。
- VIP 标准测试：fixture 没有 `vdev()`、`set_driver_features()`、`configure_mq()`。现在的做法是：
  - 设备事件接到 `flow.devices[0]`，marker 用 `flow.device()`。
  - 驱动特性写入 `f.drv_cfg.driver_features`。
  - S3 按 `do_configure_mq` 的顺序（A2）调用 `ops.ctrl_set_mq_pairs(2)`，接着 `setup_pair(1)`，最后 `ops.setup_msix(queue_count)`。
  - 帧用预填 `raw_data` 的 `packet_item`，因为 adapter 只接受 `packet_item`。
- VIP 私有测试：fixture 不能建私有 Function（A10 不成立），所以改为继承 D5 之后的 `dpu_priv_driver_flow_test`，用 Host 0 的 `devices[0]` 和 `private_ops[0]`。原 F3 的决策点已经消解。
- `rules_priv.json`：字段名改为 D 的 `host_id`、`soft_reset`、`af_declaration`、`mb_af_host_id`、`bdf`、`vtx_content.dwN`、`qid_map.*`。

**未能对齐（需决策）：** 路线 P 需要设备底座提供“MSI-X 由主机侧持有”开关和按向量号投递的端口接口，D 都没有。路线 R 失败时，计划改为停下汇报，不再自动切到 P。

**调研中发现的风险：**

1. **【阻塞，需用户确认】** 规范“只改一处让 `NUM_PFS=1` 用 `cosim-pcie-pf`”不可行，pf 不转发 0x40 以上的配置空间。计划改用路线 R（`cosim-pcie-rc` 多 BAR 补丁，约 80 行）。路线 P 需另改 D 的设备底座，只作为汇报后的备选，见 D-E1。
2. **Guest**：
   - Ubuntu 6.8.0-107 内核配 Alpine 3.20 用户态，没有 gcc 和 python。
   - virtio_net、virtio_pci 是内建的：S1/S4 用 sysfs bind/unbind 代替 modprobe/rmmod，启动期的绑定落在段 0。
   - 默认 rootfs 没有自动运行机制（openrc default 运行级为空），因此用 `init=/sbin/vdev-init`。
   - IPv6 的 DAD、RS 等自发报文会污染 `pkt` 集合，用 `ipv6.disable=1` 关掉。
   - 单 CPU 下 AF_PACKET 的发送队列由 XPS 决定，S3 必须改 `xps_cpus` 才能落到第 2 对。
3. **私有驱动**：
   - 53 无法针对 6.8 编译（gcc 9.4、glibc 2.31），改在本机 noble 编译。头文件包已确认可 `apt download`。
   - 规范的 Debian 回退不可行：镜像内核 6.1，没有 gcc 和头文件，guest 无网络。
   - 驱动已有 6.x 兼容宏（`class_create`、`netif_napi_add`、`pci_enable_pcie_error_reporting` 的 6.6 条件），预计补丁量小，但未实测。
   - 驱动默认 `af_mode=1`、`priv_ring=1`，probe 会走 AF 声明（BAR0 魔数 0x5555AAAA）和 mailbox。读 SR-IOV ext cap 时，若 cap 不存在，`pos=0`，会读到 0x14/0x16 的配置值，表现为 info 类的配置读。
   - 驱动 PCI ID 表只开放了 0x5013/0x5014/0x8689，0x5013 与规范一致。
4. **cosim 桥**：
   - `bridge_vcs_dma_*_sync` 每次上限 64 字节。
   - 原 rc 插件的 MMIO `max_access_size=8` 与 4 字节 TLP 不匹配，补丁改为 4。
   - SHM 路径的 DMA 写用 `cpu_physical_memory_write`；59 上 MSI-X 投递只在 TCP 路径（`pci_dma_write`）验证过，补丁统一转 BH + `pci_dma_write`。
   - QEMU 侧 MRd 没有超时，VCS 挂住时 QEMU 也会挂住，`run_cosim.sh` 用 `timeout` 兜底。
   - 若 SHM 路径出现 DMA completion 错位（`DMA read: cpl tag=... expected`），回退到 TCP（`transport=tcp`，127.0.0.1），bridge 两端都支持。
5. **VCS**：cosim-platform 的注释说，VCS Q-2020 在 class/package 作用域调用带 output 参数的 DPI 会崩溃。53 的 W-2024.09 未验证，E2 Step 6 给了 module 包装的回退办法。
6. **53 资源**：`/dev/shm` 已用 84%；`~/test_cosim` 是另一份 cosim，不要动。构建依赖都已就绪（glib 2.66.8 在 `/usr/local`，运行时需要 rpath，configure 已加）。
7. **59 副本**：cosim-platform 有 10 个文件未提交修改，按工作树复制，`cosim-platform.SOURCE` 记录了 `git status`。

**预计耗时：**
- E1 约 1 小时，其中 QEMU 构建 15–25 分钟，镜像拷贝约 5 分钟。
- E2 约 1–2 小时，含 1–3 轮 cosim 冒烟；每轮 VCS 编译 5–10 分钟，冒烟 5–15 分钟。
- E3 约 1–2 小时，私有驱动编译和兼容补丁的工作量未知。
- F1 约 1 小时。
- F2、F3：Linux 场景一轮约 15–30 分钟（TCG + VCS 同步，每个 MMIO 往返为毫秒级），VIP 对比测试编译加运行约 10 分钟。每条“VIP 有误”的修复至少再加一次 15–25 分钟的全回归。按 5–15 条差异估计，F2 加 F3 约 2–4 个工作日。
- 私有模式在 E3 Step 6 卡在未建模的 AF/mailbox 行为时，时间不可估，按决策点停下汇报。
