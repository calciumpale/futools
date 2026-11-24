# Prompt Dock

Prompt Dock 是一个 macOS 菜单栏应用。它把常用提示词填入打开面板前正在使用的应用，适用于支持常规文本粘贴的网页和桌面输入框。

## 使用

1. 双击打开 `dist/Prompt Dock.app`。首次启动会打开设置。也可以从菜单栏的对话气泡图标进入设置。
2. 在设置里点击开启辅助功能权限，然后在 macOS 的「系统设置 → 隐私与安全性 → 辅助功能」中启用 Prompt Dock。面板也可以在未授权时使用，按 Enter 会把提示词复制到剪贴板。
3. 将光标放在 ChatGPT、Codex 或其他应用的输入框里，按 **⌃⌥Space** 唤出面板。在左上方输入关键词即可搜索提示词，也可以直接在这个输入框里写一段待优化的草稿。
4. 用 **↑ / ↓** 浏览搜索结果，按 **Enter** 把选中的提示词填入原应用。完成后可以在原应用中发送。按 **Esc** 或再按一次全局快捷键可关闭面板。

在菜单栏的「管理提示词」中添加、修改或删除提示词。拖动列表每行右侧的把手即可排序，命令面板会同步这个顺序。搜索覆盖标题、分类和正文。

在「设置」中点击「录制快捷键」，按下新的组合键即可保存，例如 **⌃⌥P**。录制时可按 **Esc** 取消。提示词和快捷键保存在本机 `~/Library/Application Support/Prompt Dock/library.json`。

如果原应用已切换、辅助功能权限不可用，或从已识别的终端应用选择了多行提示词，应用会复制文本。请回到目标输入框并按 **⌘V**。

自动填入使用系统剪贴板。若 macOS 允许应用读取剪贴板，填入后会尝试恢复原内容。否则剪贴板会保留这次选中的提示词。

如果系统的辅助功能开关已打开，应用内仍显示「待授权」，可以从辅助功能列表移除旧的 Prompt Dock，再用列表底部的「+」添加当前的 `dist/Prompt Dock.app`。之后退出并重新打开应用。

## 提示词优化

1. 在 DeepSeek 开放平台创建 API Key。 [DeepSeek API Keys](https://platform.deepseek.com/api_keys)
2. 打开 Prompt Dock 的「设置」，在「DeepSeek API」里填写自己的 API Key，再点「保存密钥」。密钥保存在 macOS 钥匙串里。
3. 在同一个输入框搜索提示词，或写入、粘贴草稿。按 **⇧↩** 换行，点底部的「优化提示词」或按 **⌘↩** 提交优化。
4. 面板右侧初始留空。结果出现后可继续编辑、填入原输入框，或存为新提示词。

已预设 DeepSeek V4.1 Flash，模型 ID 为 `deepseek-flash`。点击「优化提示词」时，草稿会发送到 DeepSeek 官方 API，按 DeepSeek 的 API 用量计费。 [DeepSeek API 文档](https://api-docs.deepseek.com/api/create-chat-completion/) · [用量与价格](https://api-docs.deepseek.com/quick_start/pricing/)

## 本地构建

需要 macOS 13 或更新版本和 Swift 命令行工具。构建脚本生成当前 Mac 架构的本地签名应用。

```sh
./scripts/build-app.sh
open "dist/Prompt Dock.app"
```

默认沿用 `dist` 中上一版的签名证书。首次构建时也可以通过 `PROMPT_DOCK_SIGNING_IDENTITY` 指定钥匙串里的签名身份。没有证书时会使用临时签名，每次更新后需要为新版本重新开启辅助功能权限。

使用 macOS 命令行工具中的 Swift 编译器验证提示词库。

```sh
./scripts/test-store.sh
```
