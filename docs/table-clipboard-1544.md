# 表格粘贴与双格式复制（#1544）

## 验收入口

1. 表格上方「复制表格」菜单，以及选区的「复制所选区域」菜单，均提供「复制为 Markdown」与「复制为表格」。前者是聊天源码，后者是 TSV，并在剪贴板中标注表格类型，方便电子表格分列。
2. 输入框普通粘贴：Markdown 表格保留源码；单张标准 HTML 表格、带明确 TSV 类型的剪贴板转为 Markdown。发送后的用户消息使用原生表格显示。
3. 纯制表符文本不自动转换。需要时点输入框「＋ → 粘贴为表格」；识别失败显示提示，不改原稿。
4. 在已有正文中粘贴表格，保留光标前后内容，在表格边界补空行；已选中的文字被正常替换。

## 实现边界

全部使用 Swift、SwiftUI、AppKit / UIKit。HTML 只本地提取文字单元格，不使用 WebView、不执行脚本、不加载资源。用户消息内的图片语法与 Mermaid 代码保留为文字/代码，不因新增表格渲染触发远程加载。

HTML 混合正文、多张表格、合并单元格和非文本单元格不强行转换，保留原有粘贴路径；电子表格另有明确 TSV 数据时可使用它。选区复制为 Markdown 时第一行成为表头。复制保留可见文字，不复制原有字体和颜色。

## 验证

- macOS：`TableClipboardTests`、`TableSelectionTests`、`StreamReplayTests` 共 9 项通过。覆盖 Markdown/TSV 往返、竖线/反斜杠/换行、引用 TSV、HTML 实体、复杂 HTML 回退、无外侧竖线的 Markdown、代码围栏不误转换，以及原生用户气泡截图。
- iPhone 模拟器：`TablePasteTests` 通过，实际 `ComposerUITextView.paste` 替换选区、保留前后正文，并确认普通 TSV 不被自动转换。
- 用户气泡截图：`/tmp/paseo-user-table-1544.png`，390 点宽度；表格列与复制菜单可见。
- 独立 Mac 回放窗口实操通过：两种复制菜单及系统剪贴板内容、Markdown 粘贴回输入框、HTML table 自动转 Markdown、普通制表符保持原样、「＋ → 粘贴为表格」替换选区、⌘Z 撤销恢复。没有向真实会话发送测试消息。

Mac 相关测试可沿用 `docs/native-experience-1539-1543.md` 的 xcodebuild 参数，加上上述三个 `-only-testing:PaseoTests/<Suite>`。手机使用 `PaseoMobile` scheme，限定 `-only-testing:PaseoMobileTests/TablePasteTests`。
