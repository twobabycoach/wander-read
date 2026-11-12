# 漫读 WanderRead

漫读是一款原生 macOS 稍后阅读应用。先收下想读的内容，每次只看一小批候选，选中感兴趣的一篇再开始读。收藏、推荐、笔记和中文 PDF 识别都在本机运行。

## 从收录到阅读

- **收下材料**。添加网页链接和本地文件，也可从 Obsidian 仓库或 Zotero 个人库收录。
- **在少量候选里挑一篇**。每批最多三篇，可预览、换一批或返回上一批。研究策略可设置主题范围、指标与优先级。
- **专注阅读**。应用内打开 PDF、Markdown、纯文本、HTML 和 RTF。PDF 支持按章节折叠、识别中文目录、回原页、划线和扫描页 OCR。网页交给浏览器打开。
- **留下出处**。摘录和批注可带着原文位置写入 Obsidian。阅读时可按需查找相关文献，合上应用后还能接续阅读。

## 构建与运行

需要 Apple Silicon、macOS 13 或更新版本，以及 Xcode 命令行工具（Swift 5.8 或更新版本）。应用使用 SwiftUI、AppKit、PDFKit 和 Vision。

```sh
git clone https://github.com/twobabycoach/wander-read.git
cd wander-read
bash scripts/build.sh
open dist/漫读.app
```

构建脚本生成可在本机运行的应用包。首次运行是空资料库。通过「收下一篇」或拖入文件收录，按 **⌘R** 换一批，按 **⇧⌘F** 切换专注阅读。

```sh
bash scripts/test.sh
```

## 数据与联动

漫读将资料库保存到 `~/Library/Application Support/WanderRead/library.json`。可在「偏好与数据」导出和恢复 JSON。PDF 批注与生成的目录保存在资料库中，原文件继续作为阅读与摘录的出处。

发送笔记到 Obsidian 时可选收件文件夹和模板。源码也包含与研贴的本地通信接口，完整研贴联动需要另行安装兼容的研贴和 Obsidian 接收组件。

## 致谢与许可

候选推荐与优先级设计受 ebAobS 的「漫游式渐进阅读」启发。漫读的原生应用与推荐实现以 Swift 编写。可查看[算法说明](Design/ALGORITHM.md)、[上游对应关系](References/PRIORITY-PARITY.md)和[推荐与队列核对](References/ROAMING-AUDIT.md)。[上游项目](https://github.com/ebAobS/roaming-mode-incremental-reading)

本仓库中的漫读代码与配套文档采用 [MIT License](LICENSE)。
