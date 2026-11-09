#!/usr/bin/env python3
"""scripts：从实际项目源码生成可复制文档，避免维护第二份实现。

仅依赖 Python 标准库；仓库拥有源码和输出，脚本不改源码、不编译依赖。
--check 只比较期望内容，文档缺失或漂移时非零退出；默认覆盖生成文档。
"""
from argparse import ArgumentParser
from hashlib import sha256
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "filelists/project_integration.f",
    "integration/project/project_env_pkg.sv",
    "integration/project/project_env_cfg.sv",
    "integration/project/project_env.sv",
    "integration/project/project_base_test.sv",
    "integration/project/project_single_queue_config_seq.sv",
)
OUTPUT = ROOT / "docs/project_env_full_code.md"


def render():
    """逐字节读源码并列出哈希/包含顺序；不推断缺失平台布局或硬件行为。"""
    parts = ["""# 项目 env / env_cfg 完整参考代码

本文件由 `python3 scripts/render_project_code.py` 从实际源码生成；使用 `--check` 检查一致性。
接入流程、参数和 Intel bind 见 [README](../integration/project/README.md)。

用户自己的 env_cfg 直接组合 `dpu_env_cfg`、`virtio_net_env_config`、`pcie_tl_env_config`，
不需要继承参考 cfg。env 直接创建三个组件，借用平台已有 VIF 和每 Host 的唯一 memory manager。
参考 `project_*` 只承担组装；公共实现通过 package 复用，不复制到用户 env。

| 编译入口 | 提供的能力 |
| --- | --- |
| `$DPU_COMMON_ROOT/filelists/dpu_common.f` | 资源、BAR、表类型与 `dpu_env_cfg` |
| `$DPU_COMMON_ROOT/filelists/dpu_pcie.f` | `dpu_cfg_seq`、`dpu_bar_reg_seq`、PCIe 路由 |
| `integration/dpu/virtio_dpu_pkg.sv` | `vio_dpu_cfg_seq`、`vio_pcie_rc_driver` |
| `integration/project/project_env_pkg.sv` | 本文的 env/cfg/base_test 与单队列示例 |

顺序为 AIP → DPU/host_mem/net_packet/PCIe TL → VIO/AIP → Intel → DPU PCIe 集成 → VIO DPU 集成 → 用户包。
同一个 package 只编译一次。参考 project 不加入生产核心 filelist/package。

配置 seq 从实际 PCIe sequencer 的 `dpu_cfg` 键获取公共配置；VIO env 以 `vio_env_hN` 发布。
`vio_dpu_cfg_seq` 先执行 AF 声明和状态读，再配置 BDF/所选 MSI-X、准备实际 ring、
写 Notify/QSCH/VTX/VRX，最后确认 VIO。每批 VIO/RDMA Notify 表成功后，
每个管理 BAR 写一次 `+0x80044 = 1`。空批次不写，失败停止；不增加 bank 切换或使能读回。
原有每100次完整 DWORD 写后的 AF 状态读保持不变。

Tcl 名称仍为 `dut_config`、`reg_acc`、`load_params`；其中 reg_acc 注册 `dpu_bar_reg_seq`，
addr 为 Host0/PF0 BAR0 内偏移。load_params 用 AIP 命令宏注册一次，顶层统一刷新允许字段。
完整快照恢复说明和边界见 README，源码变更后需重新编译并保存快照。

"""]
    for relative in SOURCES:
        data = (ROOT / relative).read_bytes()
        language = "systemverilog" if relative.endswith(".sv") else "text"
        parts.append(f"## `{relative}`\n\nSHA-256: `{sha256(data).hexdigest()}`\n\n```{language}\n")
        parts.append(data.decode("utf-8"))
        if not data.endswith(b"\n"):
            parts.append("\n")
        parts.append("```\n\n")
    return "".join(parts).rstrip() + "\n"


def main():
    """生成或只读比对最终文档；错误经进程退出码向维护者传递。"""
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    content = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != content:
            print("project_env_full_code.md is stale; run scripts/render_project_code.py", file=sys.stderr)
            return 1
        print(f"project source export matches all {len(SOURCES)} source files")
        return 0
    OUTPUT.write_text(content, encoding="utf-8")
    print(f"generated {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
