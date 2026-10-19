# 掌声 VoxPalm 菜单栏 App

## 编译和运行

需要 macOS 14 以上和 Xcode。

```bash
scripts/build-app.sh
open build/VoxPalm.app
```

`scripts/build-app.sh` 会编译、打包成 `build/VoxPalm.app` 并签名：钥匙串里有 Developer ID 或 Apple Development 证书就用它（重新编译后系统权限不会失效），没有就临时签名（每次重新编译后要重新授权）。`CONFIG=debug` 打调试版。

## 第一次用

1. 点菜单栏的掌声图标 → 设置 → 权限，依次打开「输入监控」「辅助功能」「麦克风」。系统设置里打开「掌声」的开关后，掌声会自动重新开始监听。
2. 设置 → 设备：选控制设备（遥控器、翻页笔，或者「系统媒体键」「键盘按键」）和收音设备。
3. 设置 → 按键：上面是设备示意图。点图上的键，再按一下设备上的同一个键把它们对上（系统媒体键、DJI 这类已知设备不用对），然后设它的单击、双击、长按。示意图是照产品图和说明书逐个部件量出来画的（小米蓝牙遥控器 2、Siri Remote、DJI Mic 2 / Mini 按真实布局，其他是通用外形），设备在侧面的键会把侧面展开画在旁边；品牌标志画在实物印标志的位置：官方版画真的标志图形（第三方标志放在私有仓库 `marks/`，不进本仓库），开源版用普通字体印品牌名。也可以点「套用『AI 编程』预设」：上下键直接切 Claude / Codex 的上一个、下一个对话；确认键长按按住说话、单击回车发送。
4. 设置 → 语音：选「内置转写」（macOS 26 以上用系统转写，更老的系统用 whisper.cpp）或「外部输入法」。

## 代码结构

| 位置 | 内容 |
|---|---|
| `Packages/VoxPalmCore` · `VoxPalmDevices` | 读设备：HID、系统媒体键和键盘事件、「正在播放」命令、CoreAudio 设备和录音测量。设备探针也用它 |
| `Packages/VoxPalmCore` · `VoxPalmEngine` | 按键 → 动作：控制设备来源、单击 / 双击 / 长按识别、键位方案、模拟按键和贴文字 |
| `Packages/VoxPalmCore` · `VoxPalmVoice` | 语音会话：直接从选中的麦录音（预录防吞字）、系统转写（SpeechAnalyzer）和 whisper.cpp、外部输入法桥接 |
| `App/` | 菜单栏界面、设置、权限引导、配置存取（`~/Library/Application Support/VoxPalm/config.json`） |
| `tools/probe/` | 设备探针 |

核心库的单元测试：

```bash
cd Packages/VoxPalmCore && swift test
```

## 闭源模块

开源版不带任何闭源代码，完整可用。官方版本编译时设 `VOXPALM_PRIVATE_DIR` 指向私有仓库，会额外链接 DJI 适配和第三方品牌标志（以后还有 Pro 包），并定义编译条件 `VOXPALM_PRIVATE`；接入点在 `App/Sources/VoxPalm/PrivateModules.swift`。官方版编译在 `App/.build-private`，和开源版的 `App/.build` 分开。

## 调试开关

| 环境变量 | 作用 |
|---|---|
| `VOXPALM_CONFIG` | 用别的配置文件，不碰真正的设置 |
| `VOXPALM_DEBUG_AUDIO_FILE` | 用这个音频文件代替麦克风 |
| `VOXPALM_DEBUG_TRANSCRIPT_FILE` | 转写结果写进这个文件，不贴到前台 App（要求回车发送的那次结尾带 ⏎） |

画设备示意图（不开窗口，画完就退出）：`build/VoxPalm.app/Contents/MacOS/VoxPalm --render-diagrams <目录>`，每种示意图套上「AI 编程」预设，浅色、深色各一张 PNG；另外每种设备单独画一张 `art-<id>.png`（只有设备本体、高 600 点），用来和产品图并排对比。

日志：`log stream --predicate 'subsystem == "com.sorasukiawa.VoxPalm"' --info`。日志里只记按键和动作，不记转写出的文字。
