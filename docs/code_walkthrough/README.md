# Virtio 源码教学手册

本目录保存固定提交 `e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c` 的中文源码导读。内容沿正式 MODEL 测试入口追踪对象创建、资源建立、业务启动和结果检查；文档生成不运行仿真，也不修改 SystemVerilog 或外部依赖。

阅读入口：[Word 手册](virtio_env_walkthrough.docx) · [PDF 预览](virtio_env_walkthrough.pdf)。Word 保留可编辑正文、真实两级目录字段和源码链接；PDF 用于直接检查分页与版式。

`virtio_env_walkthrough.md` 保存封面元数据、目录设置和导读入口。后续正文严格按以下顺序拼接：

1. `chapters/01_env_objects.md`：环境成员、UVM phase、Function 子对象与绑定。
2. `chapters/02_resources_init.md`：快照、资源、队列和初始化。
3. `chapters/03_business_flow.md`：正式业务调用链。
4. `chapters/04_lifecycle_reference.md`：生命周期、错误边界与函数参考。

`render_manual.py` 借用调用者提供的 technical-manual-docx 生成器，保留主文件元数据，把四个章节解析后的 blocks 顺序追加，应用本地字体、封面、目录和页脚排版。任何必需输入缺失都报错退出，不输出内容不完整的手册。脚本只写指定 DOCX，不改技能文件。其排版适配复用已有 RDMA 手册 wrapper，并将用途和默认路径调整为本目录。

适配层还补齐正文到样式、编号、设置、字体表和主题的内部关系及主题内容类型，并规范代码块换行。这样 Word/LibreOffice 才能使用真实段落样式，保留标题跟随正文、短代码块不跨页和列表编号；不靠手工空行模拟分页。

```bash
python3 docs/code_walkthrough/render_manual.py \
  --generator /absolute/path/to/build_docx.py
```

`--generator` 必填，须指向实际技能生成脚本。默认输入和输出分别为本目录的 `virtio_env_walkthrough.md`、`virtio_env_walkthrough.docx`；可用 `--input`、`--output` 覆盖。章节文件始终从本脚本相邻的 `chapters/` 读取。输出路径已经存在时，生成器会按其写入行为处理，调用者应选择预期目标。

发布前应核对源码行号、固定 SHA 链接和跨章节主线一致性，再用 DOCX 验证器检查结构，并渲染检查目录、表格和分页。只生成文档不能替代仿真验证；本手册不宣称依赖检查或测试通过。

本版交付检查：DOCX 验证器通过，0 警告；PDF 为 A4、49 页。80 个目录书签与内部链接、110 个固定基线源码链接均已核对；已抽查封面、两页目录、对象树、代码块、长表格和末页。仅完成文档静态与排版验证，未运行 VCS。
