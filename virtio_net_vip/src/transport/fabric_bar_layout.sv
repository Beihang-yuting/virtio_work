`ifndef FABRIC_BAR_LAYOUT_SV
`define FABRIC_BAR_LAYOUT_SV

// ============================================================================
// fabric_bar_layout
//
// 目录层次：src/transport；Fabric function 的 BAR 角色布局，由冻结 snapshot 的
// dpu_bar_pair_lease_t 构造且构造后不可变。DUT profile 的角色契约（哪一对偶数 BAR
// 承载 device-memory / mailbox / MSI-X）只在 slot_contract 中定义一次；bar accessor
// 的访问守卫与发现策略的 capability 窗口校验都查询本对象，不再写死 BAR 号。
// 本对象不持有 BAR 基址/大小的运行副本（仍由 bar accessor 的 bar_base/bar_size 保存）。
// ============================================================================

class fabric_bar_layout extends uvm_object;
    `uvm_object_utils(fabric_bar_layout)

    // 契约规定的 64-bit BAR 对数；slot 序号即错误信息中的 "pair slot"。
    localparam int unsigned PAIR_COUNT = 3;

    // 按 slot 存放的已校验租约。
    protected dpu_bar_pair_lease_t leases[PAIR_COUNT];

    // 空布局；只能经 build() 得到有效实例。
    function new(string name = "fabric_bar_layout");
        super.new(name);
    endfunction

    // 唯一的 BAR 角色契约表：slot → (偶数 BAR, 角色)。
    static function void slot_contract(int unsigned slot,
                                       output int unsigned even_bar_id,
                                       output dpu_bar_role_e role);
        case (slot)
            0: begin
                even_bar_id = 0;
                role = DPU_BAR_DEVICE_MEMORY;
            end
            1: begin
                even_bar_id = 2;
                role = DPU_BAR_MAILBOX;
            end
            default: begin
                even_bar_id = 4;
                role = DPU_BAR_MSIX;
            end
        endcase
    endfunction

    // 校验整组租约：恰好三对、每对符合契约、无重复、无缺失。全部通过才返回新布局；
    // 失败时 layout=null，why 为带上下文的诊断（文本与 HEAD 的 bar accessor 一致）。
    static function bit build(dpu_bar_pair_lease_t bars[$],
                              output fabric_bar_layout layout,
                              output string why);
        bit lease_seen[PAIR_COUNT];
        fabric_bar_layout candidate;

        layout = null;
        why = "";
        if (bars.size() != PAIR_COUNT) begin
            why = $sformatf(
                "Fabric BAR lease set must contain exactly three unique pairs; got %0d",
                bars.size());
            return 0;
        end
        candidate = new("fabric_bar_layout");
        foreach (bars[index]) begin
            int found_slot;

            found_slot = -1;
            for (int unsigned slot = 0; slot < PAIR_COUNT; slot++) begin
                int unsigned even_bar_id;
                dpu_bar_role_e role;

                slot_contract(slot, even_bar_id, role);
                if ((bars[index].even_bar_id == even_bar_id) &&
                    (bars[index].role == role))
                    found_slot = slot;
            end
            if (found_slot < 0) begin
                why = $sformatf(
                    "Fabric BAR lease %0d has invalid role %0d for even BAR%0d; expected BAR0=device-memory, BAR2=mailbox, or BAR4=MSI-X",
                    index, bars[index].role, bars[index].even_bar_id);
                return 0;
            end
            if (lease_seen[found_slot]) begin
                why = $sformatf(
                    "Fabric BAR lease %0d duplicates the required BAR%0d role %0d pair",
                    index, bars[index].even_bar_id, bars[index].role);
                return 0;
            end
            lease_seen[found_slot] = 1;
            candidate.leases[found_slot] = bars[index];
        end
        for (int unsigned lease_slot = 0; lease_slot < PAIR_COUNT; lease_slot++) begin
            if (!lease_seen[lease_slot]) begin
                why = $sformatf(
                    "Fabric BAR lease set is missing required pair slot %0d",
                    lease_slot);
                return 0;
            end
        end
        layout = candidate;
        return 1;
    endfunction

    // 承载指定角色的偶数 BAR 号；build 已保证三种角色齐全，找不到时返回不存在的 6。
    function int unsigned even_bar_for(dpu_bar_role_e role);
        foreach (leases[slot]) begin
            if (leases[slot].role == role)
                return leases[slot].even_bar_id;
        end
        return 6;
    endfunction

    // 查询任一 BAR（含 64-bit 对的高半部分）所属角色；不属于任何租约时返回 0。
    function bit role_of(int unsigned bar_id, output dpu_bar_role_e role);
        role = DPU_BAR_DEVICE_MEMORY;
        foreach (leases[slot]) begin
            if ((bar_id == leases[slot].even_bar_id) ||
                (bar_id == leases[slot].even_bar_id + 1)) begin
                role = leases[slot].role;
                return 1;
            end
        end
        return 0;
    endfunction

    // bar_id 是否属于指定角色的租约。
    function bit has_role(int unsigned bar_id, dpu_bar_role_e role);
        dpu_bar_role_e actual;

        return role_of(bar_id, actual) && (actual == role);
    endfunction
endclass

`endif // FABRIC_BAR_LAYOUT_SV
