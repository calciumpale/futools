# Prompt Dock

Prompt Dock 是一个 macOS 菜单栏应用。它把常用提示词填入打开面板前正在使用的应用，适用于支持常规文本粘贴的网页和桌面输入框。

## 使用

1. 双击打开 `dist/Prompt Dock.app`。首次启动会打开设置。也可以从菜单栏的对话气泡图标进入设置。
2. 在设置里点击开启辅助功能权限，然后在 macOS 的「系统设置 → 隐私与安全性 → 辅助功能」中启用 Prompt Dock。面板也可以在未授权时使用，按 Enter 会把提示词复制到剪贴板。
3. 将光标放在 ChatGPT、Codex 或其他应用的输入框里，按 **⌃⌥Space** 唤出面板。在左上方输入关键词即可搜索提示词，也可以直接在这个输入框里写一段待优化的草稿。
4. 点击提示词或用 **↑ / ↓** 切换，右侧会显示所选提示词的完整正文。按 **Enter** 把选中的提示词填入原应用。按 **Esc** 或再按一次全局快捷键可关闭面板。

在菜单栏的「管理提示词」中添加、修改或删除提示词。拖动列表每行右侧的把手即可排序，命令面板会同步这个顺序。搜索覆盖标题、分类和正文。

在「设置 → 全局快捷键」中分别录制命令面板和精简模式的快捷键，按下新的组合键即可保存，例如 **⌃⌥P**。录制时可按 **Esc** 取消。提示词和快捷键保存在本机 `~/Library/Application Support/Prompt Dock/library.json`。

如果原应用已切换、辅助功能权限不可用，或从已识别的终端应用选择了多行提示词，应用会复制文本。请回到目标输入框并按 **⌘V**。

自动填入使用系统剪贴板。若 macOS 允许应用读取剪贴板，填入后会尝试恢复原内容。否则剪贴板会保留这次选中的提示词。

如果系统的辅助功能开关已打开，应用内仍显示「待授权」，可以从辅助功能列表移除旧的 Prompt Dock，再用列表底部的「+」添加当前的 `dist/Prompt Dock.app`。之后退出并重新打开应用。

## 按住说话

启用辅助功能后，打开命令面板就可以直接按住触控板说话，指针可以留在原来的位置。松开后，转写文字会填到输入框的光标处。也可以按住面板上的麦克风。首次使用时，按 macOS 的提示允许麦克风和语音识别权限，再次按住即可开始录音。

转写使用 macOS 自带的语音识别。支持本机识别时，音频在设备上处理。需要联网识别时，音频会发送给 Apple 处理。 [Apple 语音识别文档](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

## 截图 OCR

- 将截图复制到剪贴板，在命令面板的输入框按 **⌘V**，再点 **OCR**。识别出的文字会填到输入框的光标处。
- 将截图拖到 macOS 菜单栏的 Prompt Dock 图标。小框出现后，可松手放到图标或小框，自动识别。识别结果可以复制，也可以送到命令面板继续编辑。

开始识别时，截图会发送到 DeepSeek OCR API，沿用设置中的 DeepSeek API Key，并按识别页数计费。 [DeepSeek OCR 文档](https://api-docs.deepseek.com/guides/ocr/)

## 精简模式

先把光标放在 Codex 或其他应用的输入框里，再按 **⌃⌥⇧Space** 或从 Prompt Dock 菜单栏选择「精简模式」。小框会和目标输入区域左右对齐，贴在它的正上方并留出窄缝。输入草稿后点击「优化提示词」或按 **⌘↩**，结果会直接填回原输入框，小框继续吸附。

精简面板或原输入框有焦点时，可以直接长按触控板说话，松开后文字会填到精简面板的草稿框。按 **Esc** 可取消录音并把焦点交还原应用。切到其他应用时，小框暂时隐藏，回来后会自动恢复。再次按精简模式快捷键可关闭。精简模式需要辅助功能权限。

在「设置 → 外观」中可选择跟随系统、日间或夜间。

## 提示词优化

1. 在 DeepSeek 开放平台创建 API Key。 [DeepSeek API Keys](https://platform.deepseek.com/api_keys)
2. 打开 Prompt Dock 的「设置」，在「DeepSeek API」里填写自己的 API Key，再点「保存密钥」。密钥保存在 macOS 钥匙串里。
3. 在同一个输入框搜索提示词，或写入、粘贴草稿。按 **⇧↩** 换行，点底部的「优化提示词」或按 **⌘↩** 提交优化。
4. 优化结果出现在面板右侧。结果出现后可继续编辑、填入原输入框，或存为新提示词。如果切换到已保存的提示词，点击右侧的「选用结果」可返回优化结果。

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
