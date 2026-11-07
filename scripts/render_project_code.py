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
    "integration/project/project_bar_registry.sv",
    "integration/project/project_dut_config.sv",
    "integration/project/project_vio_config.sv",
    "integration/project/project_pcie_rc_driver.sv",
    "integration/project/project_env_cfg.sv",
    "integration/project/project_dut_config_seq.sv",
    "integration/project/project_env.sv",
    "integration/project/project_base_test.sv",
)
OUTPUT = ROOT / "docs/project_env_full_code.md"


def render():
    """逐字节读源码并列出哈希/包含顺序；不推断缺失平台布局或硬件行为。"""
    parts = ["""# 项目外部配置完整源码

本文件由 `python3 scripts/render_project_code.py` 自动生成，禁止手工修改代码块。
运行 `python3 scripts/render_project_code.py --check` 检查是否与最终源码一致。
最短接入顺序、平台 hook/布局和 Intel bind 见 [README](../integration/project/README.md)。

保留一个 env、一个 cfg；辅助 typed/registry/driver 文件是必要依赖，不可只复制两个类。
下列 `.sv` 文件由 `project_env_pkg.sv` 按其 include 顺序包含，不得重复单独编译。
按需替换项目类名前缀时，同步更新 extern 定义的类限定名。

外部 package 顺序由 `filelists/project_integration.f` → `filelists/aip_integration.f`
→ `filelists/dpu_common.f` / `filelists/virtio_net.f` 明确声明：AIP (`src/sv`布局)、
DPU、net_packet、host_mem、PCIe TL、VIO、AIP glue、Intel interface/adapter，再到本包。
依赖版本与 package SHA-256 见 [验证记录](vio_external_configuration_validation.md)。
生产 VIO filelist 不包含本目录；模型测试需另外添加 `filelists/project_tests.f`。

public table hooks 默认失败；没有配置平台输入的示例不是可直接运行的真实 DUT test。
base_test 显式启动一个配置 seq，共用 env_cfg 中的资源完成写表、使能、验证和确认。
ring 在写队列表前准备；不自动执行 Virtio capability 发现、协商或复位。

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
