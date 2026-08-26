`ifndef DPU_REG_PLAN_TYPES_SV
`define DPU_REG_PLAN_TYPES_SV

typedef enum int unsigned {
    DPU_REG_OP_INVALID = 0,
    DPU_REG_OP_PCI_CFG_WRITE,
    DPU_REG_OP_MMIO_WRITE,
    DPU_REG_OP_READ_VERIFY,
    DPU_REG_OP_POLL_UNTIL,
    DPU_REG_OP_COMMIT,
    DPU_REG_OP_BARRIER
} dpu_reg_op_kind_e;

typedef enum int unsigned {
    DPU_REG_TARGET_INVALID = 0,
    DPU_REG_TARGET_NONE,
    DPU_REG_TARGET_PCI_CONFIG,
    DPU_REG_TARGET_AF_BAR0,
    DPU_REG_TARGET_FUNCTION_BAR
} dpu_reg_target_space_e;

typedef enum int unsigned {
    DPU_REG_SCOPE_INVALID = 0,
    DPU_REG_SCOPE_SINGLE,
    DPU_REG_SCOPE_PER_HOST,
    DPU_REG_SCOPE_PER_FUNCTION,
    DPU_REG_SCOPE_PER_SERVICE
} dpu_reg_target_scope_e;

typedef enum int unsigned {
    DPU_REG_PHASE_INVALID = 0,
    DPU_REG_PHASE_BOOTSTRAP,
    DPU_REG_PHASE_TABLE,
    DPU_REG_PHASE_COMMIT,
    DPU_REG_PHASE_ENABLE
} dpu_reg_phase_e;

typedef enum int unsigned {
    DPU_REG_OP_RESULT_NOT_RUN = 0,
    DPU_REG_OP_RESULT_SUCCEEDED,
    DPU_REG_OP_RESULT_FAILED
} dpu_reg_op_result_e;

typedef enum int unsigned {
    DPU_CFG_STATUS_NOT_EXECUTED = 0,
    DPU_CFG_STATUS_PLAN_INVALID,
    DPU_CFG_STATUS_PREFLIGHT_FAILED,
    DPU_CFG_STATUS_EXECUTION_FAILED,
    DPU_CFG_STATUS_SUCCEEDED
} dpu_cfg_status_e;

`endif // DPU_REG_PLAN_TYPES_SV
