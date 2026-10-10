#!/usr/bin/env python3
"""目录：文档输出层 docs/code_walkthrough。

职责：复用 technical-manual-docx 生成器，把已核对的 Markdown 生成为 Word；
主要依赖：标准库与调用者指定的技能生成器，不依赖 Virtio 仿真运行环境。
所有权和生命周期：本进程只拥有新文档输出，借用生成器模块，不修改技能源码或 Virtio 代码。
"""

from __future__ import annotations

import argparse
import functools
import importlib.util
from pathlib import Path
from xml.etree import ElementTree as ET


# 统一 OOXML 命名空间；以下适配只修正文档表现，不改变源码教学内容或书签目标。
WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
W = "{" + WORD_NS + "}"
ET.register_namespace("w", WORD_NS)


# 功能：使用本地排版已验证的 Noto Sans CJK SC 字体，并将样式属性按 Word 规范排序；不探测字体安装。
# 输入输出及副作用：original 是原 XML 生成函数；转发参数并返回替换字体后的 bytes，不修改原技能文件。
# 失败边界：original 须返回有效 UTF-8 XML，否则解析抛异常；仅在样式同时含 pPr/rPr 时重排，不替换等宽字体名称。
def xml_with_installed_fonts(original, *args, **kwargs):
    xml = original(*args, **kwargs)
    xml = xml.replace(b"Microsoft YaHei", b"Noto Sans CJK SC").replace(
        b"Aptos", b"Noto Sans CJK SC"
    )
    root = ET.fromstring(xml)
    for style in root.findall(W + "style"):
        ppr = style.find(W + "pPr")
        rpr = style.find(W + "rPr")
        if ppr is not None and rpr is not None:
            style.remove(ppr)
            style.insert(list(style).index(rpr), ppr)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


# 功能：把两级目录缓存设置为紧凑行距，减少长标题导致的分页浪费；页数由正文标题数量决定。
# 输入输出及副作用：original 接收 headings/层级并生成真实 TOC 字段；仅调整返回 paragraph 的字体和行距。
# 失败边界：要求 original 返回含 pPr 的 paragraph，否则抛异常；移除 keepLines 允许跨页，保留字段、链接和条目。
def compact_toc(original, *args, **kwargs):
    paragraph = original(*args, **kwargs)
    ppr = paragraph.find(W + "pPr")
    keep = ppr.find(W + "keepLines")
    if keep is not None:
        ppr.remove(keep)
    ET.SubElement(ppr, W + "spacing", {
        W + "before": "0", W + "after": "0",
        W + "line": "260", W + "lineRule": "exact",
    })
    for size in paragraph.iter(W + "sz"):
        size.set(W + "val", "20")
    for size in paragraph.iter(W + "szCs"):
        size.set(W + "val", "20")
    return paragraph


# 功能：规范段落直属换行以保留代码块整段分页语义，并应用字体、封面、首章/附录分页和首页设置；附录 A 加宽文件路径列。
# 输入输出及副作用：转发 meta/blocks/relationships，返回 (document XML bytes, 原 toc)；按原顺序把直属 br 包入新 run，保留段落样式、keepLines、字段与书签。
# 失败边界：只修正 paragraph 直属 br，已有 run 内换行不变；要求有效 XML、body/sectPr及目标表 tcW/上下边距，缺失会抛异常。
def document_for_code_teaching(original, *args, **kwargs):
    xml, toc = original(*args, **kwargs)
    xml = xml.replace(
        "本手册用于集成、调试和交付。".encode(),
        "阅读主线：对象创建 → 资源建立 → 业务启动 → 结果检查".encode(),
        1,
    )
    root = ET.fromstring(xml)
    # Word 换行必须属于 run；生成器的代码块若把 br 直接放在 paragraph 下，
    # Writer 可能修复成多个段落，导致原 Code/keepLines 不能约束整个代码块。
    # 这里只在原 child 索引处包一层 run，既不拆段，也不移动文字或分页属性。
    for paragraph in root.iter(W + "p"):
        # 显式布尔值避免不同导入器对空 OnOff 元素采取不同默认值。
        for property_name in ("keepNext", "keepLines"):
            property_node = paragraph.find(W + "pPr/" + W + property_name)
            if property_node is not None:
                property_node.set(W + "val", "1")
        for index, child in enumerate(list(paragraph)):
            if child.tag == W + "br":
                paragraph.remove(child)
                run = ET.Element(W + "r")
                run.append(child)
                paragraph.insert(index, run)
    for run in root.iter(W + "r"):
        rpr = run.find(W + "rPr")
        if rpr is None:
            rpr = ET.Element(W + "rPr")
            run.insert(0, rpr)
        if rpr.find(W + "rFonts") is None:
            ET.SubElement(rpr, W + "rFonts", {
                W + "ascii": "Noto Sans CJK SC",
                W + "hAnsi": "Noto Sans CJK SC",
                W + "eastAsia": "Noto Sans CJK SC",
            })
    first_chapter = True
    for paragraph in root.findall(".//" + W + "p"):
        ppr = paragraph.find(W + "pPr")
        style_node = ppr.find(W + "pStyle") if ppr is not None else None
        if style_node is None:
            continue
        style = style_node.get(W + "val")
        if style in ("Title", "Subtitle"):
            size, color = (64, "17365D") if style == "Title" else (28, "0F6B78")
            ET.SubElement(ppr, W + "spacing", {
                W + "before": "1440" if style == "Title" else "0",
                W + "after": "300", W + "line": "280", W + "lineRule": "auto",
            })
            for rpr in paragraph.findall(".//" + W + "rPr"):
                ET.SubElement(rpr, W + "sz", {W + "val": str(size)})
                ET.SubElement(rpr, W + "szCs", {W + "val": str(size)})
                ET.SubElement(rpr, W + "color", {W + "val": color})
                if style == "Title":
                    ET.SubElement(rpr, W + "b")
        elif style == "Heading1":
            text = "".join(paragraph.itertext())
            if first_chapter or text.startswith("附录"):
                ET.SubElement(ppr, W + "pageBreakBefore")
                run = ET.Element(W + "r")
                ET.SubElement(run, W + "br", {W + "type": "page"})
                paragraph.insert(1, run)
            first_chapter = False
    section = root.find(W + "body/" + W + "sectPr")
    ET.SubElement(section, W + "titlePg")
    in_function_appendix = False
    for block in root.find(W + "body"):
        if block.tag == W + "p":
            style_node = block.find(W + "pPr/" + W + "pStyle")
            if style_node is not None and style_node.get(W + "val") == "Heading1":
                in_function_appendix = "".join(block.itertext()).startswith("附录 A")
        if block.tag != W + "tbl" or not in_function_appendix:
            continue
        grid = block.find(W + "tblGrid")
        if grid is None or len(grid) != 3:
            continue
        widths = (1800, 4500, 2700)
        for column, width in zip(grid, widths):
            column.set(W + "w", str(width))
        for row in block.findall(W + "tr"):
            for cell, width in zip(row.findall(W + "tc"), widths):
                cell.find(W + "tcPr/" + W + "tcW").set(W + "w", str(width))
        for edge in ("top", "bottom"):
            block.find(W + "tblPr/" + W + "tblCellMar/" + W + edge).set(W + "w", "60")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True), toc


# 功能：将通用英文页脚标签换成与本文对应的简短中文名称。
# 输入输出及副作用：original 返回 footer XML；保留自动 PAGE 字段，只替换固定标签一次。
# 失败边界：不重排页号或修改页码起点；原标签缺失时原 XML 保持不变。
def teaching_footer(original, *args, **kwargs):
    return original(*args, **kwargs).replace(
        b"Technical Manual  ", "源码导读  ".encode(), 1
    )


# 功能：补充正文到生成器已有样式、编号、设置、字体表及主题部件的 OPC 关系，使 Writer 使用实际样式和列表。
# 输入输出及副作用：original 接收外部链接列表；返回补齐内部关系的 XML bytes，保留原链接、ID和目标。
# 失败边界：要求有效关系 XML和本生成器的五个已确认部件；已有类型幂等保留，新增 ID 避开已有 ID，不访问网络或修改技能源码。
def document_relationships_with_parts(original, *args, **kwargs):
    root = ET.fromstring(original(*args, **kwargs))
    relation_ns = "http://schemas.openxmlformats.org/package/2006/relationships"
    type_base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    used_ids = {node.get("Id") for node in root}
    for kind, target in (
        ("styles", "styles.xml"),
        ("numbering", "numbering.xml"),
        ("settings", "settings.xml"),
        ("fontTable", "fontTable.xml"),
        ("theme", "theme/theme1.xml"),
    ):
        relation_type = type_base + kind
        if any(node.get("Type") == relation_type for node in root):
            continue
        relation_id = "rIdManual" + kind
        while relation_id in used_ids:
            relation_id += "_"
        ET.SubElement(root, "{" + relation_ns + "}Relationship", {
            "Id": relation_id, "Type": relation_type, "Target": target,
        })
        used_ids.add(relation_id)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


# 功能：为生成器已写入的主题部件补正确内容类型，与正文新增 theme 关系对应。
# 输入输出及副作用：original 无业务参数，返回 Content_Types XML bytes；仅补 theme1.xml override，原有类型不变。
# 失败边界：要求有效内容类型 XML；已有目标 override 时幂等保留，不建立新主题文件或改写主题内容。
def content_types_with_theme(original, *args, **kwargs):
    root = ET.fromstring(original(*args, **kwargs))
    content_ns = "http://schemas.openxmlformats.org/package/2006/content-types"
    if not any(node.get("PartName") == "/word/theme/theme1.xml" for node in root):
        ET.SubElement(root, "{" + content_ns + "}Override", {
            "PartName": "/word/theme/theme1.xml",
            "ContentType": "application/vnd.openxmlformats-officedocument.theme+xml",
        })
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


# 功能：加载调用方指定的本地生成器，按固定顺序追加四个章节，只用主文件 meta 驱动封面与目录并生成 DOCX。
# 输入输出及副作用：--generator 必填，--input/--output 指定主 Markdown 与 DOCX；章节从脚本相邻 chapters 读取，不运行仿真或下载脚本。
# 失败边界：生成器或任一 Markdown 缺失时提前退出；模块/API、解析和写入错误向外传播，XML结构须满足各适配函数前提。
def main() -> int:
    parser = argparse.ArgumentParser(description="Render the Virtio ENV code walkthrough")
    parser.add_argument("--generator", required=True, type=Path)
    parser.add_argument("--input", type=Path, default=Path(__file__).with_name("virtio_env_walkthrough.md"))
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("virtio_env_walkthrough.docx"))
    args = parser.parse_args()
    chapter_paths = [
        Path(__file__).parent / "chapters" / name
        for name in (
            "01_env_objects.md",
            "02_resources_init.md",
            "03_business_flow.md",
            "04_lifecycle_reference.md",
        )
    ]
    # 先验证全部输入存在，再加载生成器；章节配置不覆盖主文件的目录和封面元数据。
    for source in [args.generator, args.input, *chapter_paths]:
        if not source.is_file():
            parser.error(f"Required manual input is missing: {source}")
    spec = importlib.util.spec_from_file_location("manual_skill_builder", args.generator)
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot load the supplied manual generator")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    for name in ("_styles_xml", "_theme_xml", "_font_table_xml"):
        setattr(builder, name, functools.partial(xml_with_installed_fonts, getattr(builder, name)))
    builder._toc_paragraph = functools.partial(compact_toc, builder._toc_paragraph)
    builder._document_xml = functools.partial(document_for_code_teaching, builder._document_xml)
    builder._footer_xml = functools.partial(teaching_footer, builder._footer_xml)
    builder._document_rels_xml = functools.partial(
        document_relationships_with_parts, builder._document_rels_xml
    )
    builder._content_types_xml = functools.partial(content_types_with_theme, builder._content_types_xml)
    meta, blocks = builder.parse_markdown(args.input)
    for chapter_path in chapter_paths:
        _, chapter_blocks = builder.parse_markdown(chapter_path)
        blocks.extend(chapter_blocks)
    builder.build_docx(meta, blocks, args.output)
    print(f"Generated {args.output.name}: {len(blocks)} content blocks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
