# 掌声 VoxPalm 菜单栏 App

## 编译和运行

需要 macOS 14 以上和 Xcode。

```bash
scripts/build-app.sh
open build/VoxPalm.app
```

`scripts/build-app.sh` 会编译、打包成 `build/VoxPalm.app` 并签名：钥匙串里有 Developer ID 或 Apple Development 证书就用它（重新编译后系统权限不会失效），没有就临时签名（每次重新编译后要重新授权）。`CONFIG=debug` 打调试版；`OUTPUT_DIR=<目录>` 打到别的目录，不动 `build/` 里正在用的那份；`UNIVERSAL=1` 打 Apple 芯片和 Intel 通用版（发布包用）。

新包会先在输出目录的临时文件夹里完成打包和签名校验，全部成功才替换原有 App；失败时保留旧包。相对 `OUTPUT_DIR` 按运行命令时的目录解释，`UNIVERSAL=0` 只编译当前架构，`SWIFT_JOBS` 控制编译并发（默认 2）。打包脚本的隔离回归检查：`bash scripts/tests/build-app.sh`（使用假编译器和签名器，不访问钥匙串）。

第一次编译时 SwiftPM 会从 GitHub 下载 whisper.cpp 官方预编译的 xcframework（约 66 MB，版本和校验和写在 `Packages/VoxPalmCore/Package.swift`）。打包脚本把其中 macOS 的框架放进 `VoxPalm.app/Contents/Frameworks` 并一起签名，许可证放进 `Contents/Resources/THIRD-PARTY-NOTICES.md`。

## 第一次用

第一次打开会弹出引导：打开 3 个权限 → 选控制设备和收音设备 → 按一下设备上的键设成说话键并当场试一句。之后都在菜单栏图标里改；引导可以从「设置 → 关于」再走一遍。

1. 设置 → 权限：「输入监控」「辅助功能」「麦克风」。点「开启」会打开系统设置对应的页面，旁边浮出掌声的图标，把它拖进列表就行（和 Codex、Claude 一样）；麦克风是系统直接弹框问。打开后自动打勾，掌声会自动重新开始监听。
2. 设置 → 设备：选控制设备（遥控器、翻页笔，或者「系统媒体键」「键盘按键」）和收音设备。
3. 设置 → 按键：上面是设备示意图。点图上的键，再按一下设备上的同一个键把它们对上（系统媒体键、DJI 这类已知设备不用对），然后设它的单击、双击、长按。示意图是照产品图和说明书逐个部件量出来画的（小米蓝牙遥控器 2、Siri Remote、DJI Mic 2 / Mini 按真实布局，其他是通用外形），设备在侧面的键会把侧面展开画在旁边；品牌标志画在实物印标志的位置：官方版画真的标志图形（第三方标志放在私有仓库 `marks/`，不进本仓库），开源版用普通字体印品牌名。也可以点「套用『AI 编程』预设」：上下键直接切 Claude / Codex 的上一个、下一个对话；确认键长按按住说话、单击回车发送。
4. 设置 → 语音：选「内置转写」（macOS 26 以上用系统转写，更老的系统用 whisper.cpp）或「外部输入法」。用 whisper.cpp 的话，第一次要在「whisper.cpp」卡片里点「下载」下一个语音模型，不用自己装命令行工具。

外部输入法的麦克风和语音键需要在两边配成一致：微信、豆包自己的麦克风选「自动检测」；组合键可在掌声里选「自定义快捷键」并录制。各输入工具已验证和待验证的范围见[外部输入法配置与验证状态](../docs/外部输入法.md)。

whisper.cpp 的模型：

| 名字 | 文件 | 大小 | 说明 |
|---|---|---|---|
| 小 | `ggml-small-q5_1.bin` | 190 MB | 体积最小；Intel 芯片的 Mac 默认用它 |
| 均衡 | `ggml-large-v3-turbo-q5_0.bin` | 574 MB | Apple 芯片的 Mac 默认用它 |
| 更准 | `ggml-large-v3-turbo-q8_0.bin` | 874 MB | large-v3-turbo 的 8 位量化版本，体积更大 |

名称沿用界面选项；三档的实际速度和准确率还没有完成同一组语料的对比实测，不能只根据名称判断效果。

模型不随 App 打包，从 whisper.cpp 官方的 Hugging Face 仓库（`ggerganov/whisper.cpp`）下载，连不上时自动换国内镜像 `hf-mirror.com`；下完按写死的大小和 SHA-256 核对，对上了才用。存在 `~/Library/Application Support/VoxPalm/Models`（不进时间机器备份），设置里可以删。下到一半断了，点「重试」从断点接着下（只在这次运行里记得断点）。也可以在模型菜单里选「自己的模型文件」，用任意 ggml 格式的 whisper 模型。

用起来（2026-10-22 在 Apple 芯片的 Mac 上量的「均衡」）：按下说话键就开始读模型，读一次 0.8 秒左右，读进来的模型留在内存里 5 分钟；一段 6 秒的话松手后 1.2 秒出字。每台 Mac 第一次读模型要现编显卡程序，多等 9 秒左右（之后系统记住了），所以下载完会马上在后台读一遍。

出字和回车的规矩：按下说话键那一刻记下前台 App 和光标所在的输入框，转写完先看一眼——还是那个输入框、能打字、不是密码框才贴；不然字留在剪贴板里，浮窗提示按 ⌘V 并写明原因。「发送（回车）」和「说完自动按回车发送」同样只在光标停在有字的输入框里时才按，密码框绝不贴、不按。系统「终端」的输入区也算能打字的输入框。

## 界面

Siri Remote、DualSense（DS5）和 DualSense Edge（DSE）的源码适配已加入，尚未包含在 beta.2 下载包。DSE 的 USB/蓝牙 23 键、八方向及回中已通过真机验证；USB 内置麦克风，以及蓝牙按键配 Mac 麦克风的 R1 说话、转写和贴字也已实测。手柄蓝牙收音仍在实验，DS5 和 Siri Remote 的真机验收尚未完成。手柄在「游戏手柄」分类选择，Siri Remote 仍需按图逐键学习；手柄「AI 编程」预设用 R1 长按说话、叉键发送。滑动触摸和摇杆移动未接入；共享监听时游戏和系统也可能收到原按键。详见[遥控器与手柄](../docs/设备兼容/遥控器与手柄.md)。

设计稿在 `design/`（`VoxPalm-UI.html`），界面用 macOS 原生控件，品牌只用在三处：珊瑚色强调、菜单栏图标的状态、说话浮窗。

- 菜单栏图标：平时是黑白模板图标；预录、正在听、转写中有动画；暂停监听变淡；缺权限或设备没连上时右下角带橙点。
- 点图标弹出面板：说话键和「按住试一下」、控制 / 收音 / 出字三行状态、最近一次出字、监听开关。
- 说话浮窗：屏幕下方正中，不抢焦点、不挡鼠标；显示正在听（音量跳动）、转写中、已输入几个字、按得太短、没听到声音等。外部输入法模式下不出，输入法有自己在听的界面（微信输入法的语音条也在屏幕下方正中）。
- 设置窗口：设备、按键、语音、权限、Pro、关于六页。
- 授权小窗：贴在系统设置窗口下面、跟着它走，只在系统设置在前台时出现；权限打开后打勾、自己收起。
- 样式（2026-10-19 按本人反馈「有点简陋、像古早 Mac」改）：系统设置风格的彩色图标块、卡片、自己画的珊瑚色主按钮和中性次要按钮（系统按钮在窗口不在前台时会变灰）、引导页底部透一点珊瑚色的光；共用部件在 `Components.swift`。

## 代码结构

| 位置 | 内容 |
|---|---|
| `Packages/VoxPalmCore` · `VoxPalmDevices` | 读设备：HID、系统媒体键和键盘事件、「正在播放」命令、CoreAudio 设备和录音测量。设备探针也用它 |
| `Packages/VoxPalmCore` · `VoxPalmEngine` | 按键 → 动作：控制设备来源、单击 / 双击 / 长按识别、键位方案、模拟按键和贴文字 |
| `Packages/VoxPalmCore` · `VoxPalmVoice` | 语音会话：直接从选中的麦录音（预录防吞字）、系统转写（SpeechAnalyzer）和 whisper.cpp（链接官方预编译库，模型清单和下载在 `Whisper.swift`、`WhisperDownload.swift`）、外部输入法桥接 |
| `App/` | 菜单栏界面、设置、权限引导、配置存取（`~/Library/Application Support/VoxPalm/config.json`） |
| `tools/probe/` | 设备探针 |

核心库的单元测试：

```bash
cd Packages/VoxPalmCore && swift test
```

在仓库根目录运行 `bash scripts/check.sh`，可依次检查打包脚本、核心库、探针、App 配置存储和探针参数。默认使用 2 个编译任务，`SWIFT_JOBS` 可调整；脚本强制使用开源构建，不启动正常 App 或接管真实设备。GitHub Actions 使用同一入口，另做临时签名的通用版打包；自动检查通过不等于完成设备和系统版本兼容性验收。

已验证的工具链（2026-10-24，`de5bfb3`，两边 `bash scripts/check.sh` 都通过，核心库 89、探针 8、App 11 项测试）：

| 环境 | Xcode | Swift |
|---|---|---|
| GitHub Actions `macos-26`（镜像 `macos-26-arm64` 20261013.0424.1） | 26.6（17F113） | 6.3.3 |
| 本机 macOS 27 | 27.1（27A9275） | 6.4 |

云端通用版打包时链接器会对 `whisper.framework` 报 `ignoring unexpected dylib file` 警告，不影响打包和验签。本机复现云端检查：

```bash
SWIFT_JOBS=2 bash scripts/check.sh
SIGN_IDENTITY=- UNIVERSAL=1 OUTPUT_DIR="$TMPDIR/voxpalm-package" bash scripts/build-app.sh
```

配置导入会先在配置目录生成 `config-backup-<标识>.json`，成功后可在「关于」页找到备份。读不出原配置时会保留它，界面显示保存问题，本次修改暂不自动写回；可先导出本次设置，再导入有效配置恢复保存。退出前会立即保存尚在等待写入的改动，写入失败时提供返回检查的选择。

导出的设置文件不含设备身份：已适配设备的序列号摘要、设备标识里的蓝牙地址换成 `<redacted>`，选的蓝牙麦改回跟随系统默认输入。导入后按型号和连接方式认回当前连着的设备，同型号恰好一台时自动选上，否则等设备连上再认或手动选一次；本机的 `config.json` 不受影响。

另有一个用真模型的 whisper.cpp 测试，平时跳过；设 `VOXPALM_TEST_WHISPER_MODEL=<ggml 模型文件>` 才跑（用 `say -v Tingting` 合成一句中文再转回来）。

## 闭源模块

开源版不带任何闭源代码，完整可用。官方版本编译时设 `VOXPALM_PRIVATE_DIR` 指向私有仓库，会额外链接 DJI 适配和第三方品牌标志（以后还有 Pro 包），并定义编译条件 `VOXPALM_PRIVATE`；接入点在 `App/Sources/VoxPalm/PrivateModules.swift`。官方版编译在 `App/.build-private`，和开源版的 `App/.build` 分开。

## 调试开关

| 环境变量 | 作用 |
|---|---|
| `VOXPALM_CONFIG` | 用别的配置文件，不碰真正的设置；下载的 whisper.cpp 模型也跟着放到这个配置文件旁边的 `Models` |
| `VOXPALM_DEBUG_AUDIO_FILE` | 用这个音频文件代替麦克风 |
| `VOXPALM_DEBUG_TRANSCRIPT_FILE` | 转写结果写进这个文件，不贴到前台 App（要求回车发送的那次结尾带 ⏎）；日志里写出字目标检查的结果（「会贴到某 App」或「不贴」和原因） |

画界面截图（画完就退出）：`build/VoxPalm.app/Contents/MacOS/VoxPalm --render-ui <目录>`，菜单栏图标各状态、面板、说话浮窗各状态、设置各页、引导各步、授权小窗，浅色深色各一张；`--render-live <目录>` 改用屏幕外的真窗口截引导、面板、设置几页和授权小窗（看得到玻璃效果和真按钮样式，不抢前台）。配合 `VOXPALM_CONFIG` 用测试配置画。

画设备示意图（不开窗口，画完就退出）：`build/VoxPalm.app/Contents/MacOS/VoxPalm --render-diagrams <目录>`，每种示意图套上「AI 编程」预设，浅色、深色各一张 PNG；另外每种设备单独画一张 `art-<id>.png`（只有设备本体、高 600 点），用来和产品图并排对比。

日志：`log stream --predicate 'subsystem == "com.sorasukiawa.VoxPalm"' --info`。日志里只记按键和动作，不记转写出的文字。
