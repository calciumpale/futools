<img src="Resources/AppIcon.png" width="96" alt="futools 的错层方块徽标">

# futools

futools 是一个 macOS 菜单栏应用。按全局快捷键打开命令面板，选中提示词并按 **Enter**，就能把内容填回 ChatGPT、Codex 或其他支持文本粘贴的应用。管理、搜索和填入已保存的提示词无需 API Key。

## 下载与安装

v1.3 支持 macOS 13 及以上版本，同一个安装包适用于 Apple 芯片和 Intel Mac。 [发布说明](https://github.com/calciumpale/futools/releases/tag/v1.3) · [下载 futools-v1.3-macOS-universal.zip](https://github.com/calciumpale/futools/releases/download/v1.3/futools-v1.3-macOS-universal.zip)

将校验文件和 ZIP 放在同一目录，运行 `shasum -a 256 -c futools-v1.3-macOS-universal.zip.sha256` 即可核对下载。 [SHA-256 校验文件](https://github.com/calciumpale/futools/releases/download/v1.3/futools-v1.3-macOS-universal.zip.sha256)

1. 解压 ZIP，把 `futools.app` 拖到 Finder 的「应用程序」中。
2. 双击打开 `futools`。首次启动会打开设置，以后也可从菜单栏的 futools 图标进入。
3. 要启用自动填入，在应用设置中点「打开系统设置」，然后在 macOS 的「系统设置 → 隐私与安全性 → 辅助功能」中开启 futools。授权前也能使用面板，按 **Enter** 会把提示词复制到剪贴板。

### 首次打开时的 macOS 提示

此版本使用临时签名（ad hoc），尚未通过 Apple 公证。如果 macOS 提示无法验证开发者，请先确认应用来自上面的 GitHub 发布页。尝试打开后，进入「系统设置 → 隐私与安全性」，在「安全性」区域点击「仍要打开」，再按系统提示确认。这个设置仅适用于当前应用。 [Apple：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)

## 命令面板

1. 将光标放在目标输入框里，按 **⌃⌥Space** 唤出面板。在顶部输入框键入关键词即可搜索，也可以直接写一段待优化的草稿。
2. 点击提示词或用 **↑ / ↓** 切换，右侧会显示所选提示词的完整正文。
3. 按 **Enter** 或点击「插入」，把选中的提示词填入原应用，由你决定何时发送。按 **Esc** 或再按一次全局快捷键可关闭面板。

在菜单栏的「管理提示词」中添加、修改或删除提示词。拖动列表每行右侧的把手即可排序，命令面板会同步这个顺序。搜索覆盖标题、分类和正文。

在「设置 → 全局快捷键」中分别录制命令面板和精简模式的快捷键，按下新的组合键即可保存，例如 **⌃⌥P**。录制时可按 **Esc** 取消。提示词和快捷键保存在本机 `~/Library/Application Support/Prompt Dock/library.json`。

如果原应用已切换、辅助功能权限不可用，或从已识别的终端应用选择了多行提示词，应用会复制文本。请回到目标输入框并按 **⌘V**。

自动填入使用系统剪贴板。若 macOS 允许应用读取剪贴板，填入后会尝试恢复原内容。否则剪贴板会保留这次选中的提示词。

如果系统的辅助功能开关已打开，应用内仍显示「待授权」，可以从辅助功能列表移除旧的应用条目，再用列表底部的「+」添加当前的 `futools.app`。之后退出并重新打开应用。

## 按住说话

启用辅助功能后，打开命令面板就可以直接按住触控板说话，指针可以留在原来的位置。松开后，转写文字会填到输入框的光标处。也可以按住面板上的麦克风。首次使用时，按 macOS 的提示允许麦克风和语音识别权限，再次按住即可开始录音。

转写使用 macOS 自带的语音识别。支持本机识别时，音频在设备上处理。需要联网识别时，音频会发送给 Apple 处理。 [Apple 语音识别文档](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

## 截图 OCR

截图识别需要在设置中配置自己的 DeepSeek API Key。 [配置方法](#提示词优化)

- 将截图复制到剪贴板，在命令面板的输入框按 **⌘V**，再点 **OCR**。点击后会清空输入框，左栏预览截图，右栏显示可编辑的识别结果。用底部按钮复制结果或填回原应用。
- 将截图拖到 macOS 菜单栏的 futools 图标。小框出现后，可松手放到图标或小框，自动识别。识别结果可以复制，也可以送到命令面板继续编辑。

开始识别时，截图会发送到 DeepSeek OCR API，沿用设置中的 DeepSeek API Key，并按识别页数计费。 [DeepSeek OCR 文档](https://api-docs.deepseek.com/guides/ocr/)

## 精简模式

先把光标放在 Codex 或其他应用的输入框里，再按 **⌃⌥⇧Space** 或从 futools 的菜单栏图标选择「精简模式」。精简面板会贴在目标输入框上方，左侧写草稿，右侧可按住麦克风说话或点击「优化提示词」。也可以按 **⌘↩** 优化。结果会直接填回原输入框，精简面板会留在原位。

精简面板或原输入框有焦点时，可以直接长按触控板说话，松开后文字会填到精简面板的草稿框。按 **Esc** 可取消录音并把焦点交还原应用。切到其他应用时，小框暂时隐藏，回来后会自动恢复。再次按精简模式快捷键可关闭。精简模式需要辅助功能权限。

在「设置 → 外观」中可选择跟随系统、日间或夜间。

## 提示词优化

提示词优化和截图 OCR 是可选功能，安装包不包含 API Key。

1. 在 DeepSeek 开放平台创建 API Key。 [DeepSeek API Keys](https://platform.deepseek.com/api_keys)
2. 打开 futools 的「设置」，在「DeepSeek API」里填写自己的 API Key，再点「保存密钥」。密钥保存在 macOS 钥匙串里。
3. 在同一个输入框搜索提示词，或写入、粘贴草稿。按 **⇧↩** 换行，点底部的「优化提示词」或按 **⌘↩** 提交优化。
4. 优化结果出现在面板右侧。结果出现后可继续编辑、填入原输入框，或存为新提示词。如果切换到已保存的提示词，点击右侧的「选用结果」可返回优化结果。

已预设 DeepSeek V4.1 Flash，模型 ID 为 `deepseek-flash`。点击「优化提示词」时，草稿会发送到 DeepSeek 官方 API，按 DeepSeek 的 API 用量计费。 [DeepSeek API 文档](https://api-docs.deepseek.com/api/create-chat-completion/) · [用量与价格](https://api-docs.deepseek.com/quick_start/pricing/)

## 本地构建

需要 macOS 13 或更新版本和 Swift 命令行工具。构建脚本生成当前 Mac 架构的本地签名应用。

```sh
./scripts/build-app.sh
open "dist/futools.app"
```

默认沿用 `dist` 中上一版的签名证书。首次构建时也可以通过 `PROMPT_DOCK_SIGNING_IDENTITY` 指定钥匙串里的签名身份。没有证书时会使用临时签名，每次更新后需要为新版本重新开启辅助功能权限。

运行发布打包脚本可生成供两种 Mac 架构使用的 `dist/futools-v1.3-macOS-universal.zip`。

```sh
./scripts/package-release.sh
```

使用 macOS 命令行工具中的 Swift 编译器验证提示词库。

```sh
./scripts/test-store.sh
```
