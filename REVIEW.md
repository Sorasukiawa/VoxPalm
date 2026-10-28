# 掌声评审须知

本仓库公开，源码、文档和提交历史任何人都能看。评审前先读 `AGENTS.md`；评审只读，不启动 App、不申请权限、不连接设备。

## 出事是什么样

- 最怕发出去的东西带了不该公开的内容：安装包里留着本机源码路径、用户名或私有仓库的目录和文件名（`#filePath` 写进程序、release 没去调试符号表都出过，默认的 `strings` 查不出符号表里的路径），或者闭源适配、逆向细节、别人的 GPL 代码进了本仓库（见 `AGENTS.md`「开源边界」）；以及随安装包签名发出去的二进制被换掉。
- 其次是替用户按错键：掌声往前台 App 发按键、按住修饰键、贴字、按回车，误触发会把半句话发进别人正在用的聊天窗口，修饰键没松开会让整台 Mac 打字错乱；以及用户没打开时开着麦、内置转写的录音离开本机或落盘、导出的报告能认出具体设备，下载的模型没校验就加载。

## 高风险路径

改到下面任何一处，合入 main 前都要独立评审：
- `scripts/build-app.sh`、`scripts/tests/build-app.sh`、`scripts/check.sh`、`App/VoxPalm.entitlements`、`App/Info.plist`、`Packages/VoxPalmCore/Package.swift`：打包、release 去调试符号表、签名、权限说明和 Bundle ID；whisper 预编译框架的版本和校验和（会被打进安装包并签名）；合入前检查和 CI 跑的就是 `check.sh`。
- `App/Package.swift`、`App/Sources/VoxPalm/PrivateModules.swift`、`App/Sources/VoxPalm/UIPreview.swift`：私有模块只在 `VOXPALM_PRIVATE` 下链接；调试预览里有 `#filePath`，只能编进调试版。
- `Packages/VoxPalmCore/Sources/VoxPalmEngine/` 中的 `KeyPoster.swift`、`TextInserter.swift`、`TextTarget.swift`、`AppCommands.swift`、`Action.swift`、`ButtonEngine.swift`，以及 `Packages/VoxPalmCore/Sources/VoxPalmVoice/InputMethodBridge.swift`、`Packages/VoxPalmCore/Sources/VoxPalmDevices/SystemEventMonitor.swift`：模拟按键、按住修饰键、贴字、切对话和回车发送；系统级键盘监听能看到所有按键，过滤时会吞键。
- `Packages/VoxPalmCore/Sources/VoxPalmVoice/` 中的 `VoiceSession.swift`、`AudioCapture.swift`、`MicRouting.swift`、`Transcribers.swift`，以及 `App/Sources/VoxPalm/DevicePicker.swift`：什么时候开麦、预热、用哪支麦、交给哪个转写引擎；选麦界面量音量时也会开麦。
- `Packages/VoxPalmCore/Sources/VoxPalmVoice/Whisper.swift`、`WhisperDownload.swift`、`App/Sources/VoxPalm/WhisperModels.swift`：模型下载地址、写死的哈希和校验流程。
- `Packages/VoxPalmCore/Sources/VoxPalmDevices/Redaction.swift`、`HIDMonitor.swift`、`tools/probe/Sources/ProbeKit/ProbeReport.swift`、`tools/probe/Sources/ProbeKit/ProbeRecorder.swift`、`tools/probe/Sources/voxpalm-probe/ProbeCLI.swift`：设备身份怎么存、探针报告怎么脱敏。
- `App/Sources/VoxPalm/AppConfig.swift`、`App/Sources/VoxPalm/Permissions.swift`：设置读坏时不覆盖、只在明确导入时备份替换；重置麦克风授权。
- `.github/**`：公开仓库的 CI，谁都能发 PR 触发。
- `LICENSE`、`THIRD-PARTY-NOTICES.md`、`BRAND-LICENSE.md`、`docs/开源范围与许可.md`、`AGENTS.md`、`CLAUDE.md`、`REVIEW.md`：许可、开源范围和 AI 会话的规则；改 `REVIEW.md` 能缩小评审范围。

## 重点看什么

1. 开源边界：闭源设备适配、Pro 功能、逆向资料、定价和调研不进本仓库，代码注释和提交说明里也不写逆向细节；不复制别人的 GPL 代码；外部贡献在 CLA 就位前不合并（`AGENTS.md`）。不带私有仓库也要能编译和测试（`scripts/check.sh` 会 `unset VOXPALM_PRIVATE_DIR`），私有代码只通过 `PrivateModules.swift` 里的 `#if VOXPALM_PRIVATE` 接入。
2. 安装包不带本机信息：release 必须 `strip -S`（`scripts/build-app.sh`）；新出现的 `#filePath`、`#file`、绝对路径和用户名只能在 `#if DEBUG` 里（参照 `UIPreview.swift`）。改打包的提交要说明怎么查过整包：对每个 Mach-O 用 `grep -a -c` 或 `strings -a`，再用 `nm -pa` 看调试符号条目，`/Users/`、私有仓库目录名、`.build` 都应为 0 处，whisper 框架里官方 CI 的 `/Users/runner/` 除外。换 whisper 框架版本或校验和要写明来源。
3. 不误发按键：回车先满足贴字的条件，输入框读得到字时必须非空（读不到字的不拦，`TextTarget.swift` 的 `DeliveryRule.sendReturn`），只在用户配置了发送时才按；切对话只对 Claude、Codex 前台生效（`AppCommands.swift`）；按住的修饰键（`InputMethodBridge.swift` 的按住模式）在松手、取消、出错、换设备的路径上都要松开，按下和松开在 `VoiceSession.swift` 里配对。
4. 麦克风和隐私：默认只在按下说话键后开麦；预热（`keepMicWarm`）必须默认关、由用户手动打开，保留的声音最多 3 秒（`AppConfig.swift` 校验）、只在内存；选麦界面量音量离开就停（`DevicePicker.swift`）。明确选定的手柄麦（`MicRouting.isControllerInput`）断开时禁止录音、不能回退，其他麦按 `MicRouting` 的规则回退到默认输入或避开会被静音的麦。内置转写只能用本机引擎（`Transcribers.swift`）；外部输入法模式下掌声自己不转写，交给用户选的输入法处理；录音和转写只有调试环境变量 `VOXPALM_DEBUG_AUDIO_FILE`、`VOXPALM_DEBUG_TRANSCRIPT_FILE` 才读写文件（`VoiceSession.swift`），不进日志。`HIDMonitor.swift` 不存原始序列号，但它的设备摘要不加盐、能穷举还原出蓝牙地址，只能在本机用；探针报告默认脱敏、蓝牙地址只留厂商段、设备摘要用一次性密钥重算（`ProbeReport.swift`、`Redaction.swift`），`--no-redact` 只给本人排查；「导出设置」写出的文件不能带设备摘要和完整蓝牙地址（`AppConfig.sharable`）；探针默认会记下录制期间打的字（`ProbeRecorder.swift`），脱敏不处理这部分，分享报告的提示和文档要讲清。重置麦克风授权只能带本 App 的 Bundle ID（`Permissions.swift`），否则会重置所有 App。
5. 下载的模型校验通过才用：下载源只走 HTTPS，先比大小再比 SHA-256，对不上就丢弃（`WhisperDownload.swift`）；哈希写死在 `Whisper.swift`，下载地址指向会变的 `resolve/main` 和第三方镜像，完整性全靠这些哈希，不能为了能用而跳过或放宽。
6. CI 保持 `contents: read`、`persist-credentials: false`，第三方 action 固定到提交 SHA；公开仓库的工作流不引入 Secret 或签名证书。
7. 设备能力写实：文档和 README 分清「已实测」「待验证」，没实测的不写成能用（`AGENTS.md`「设备能力」）；改 README 时四个语言版本一起改。
8. 测试跟着改：动到上面的逻辑要有对应的单元测试或 `scripts/tests/` 用例，删测试、放宽断言、从 `check.sh` 里删检查都算问题。

## 不用管

- 品牌导出的 PNG 和 `brand/` 素材只看是不是用 `brand/tools/` 脚本生成的；`design/` 不评。`docs/screenshots/` 只看有没有真实设备名、转写内容或用户名。
- `tools/probe/` 是开发用的设备探针，不进安装包，只看非法参数仍在开麦前失败（`scripts/check.sh`）和导出脱敏（见第 4 条）。
- 界面样式、动效和措辞从轻，除非会误导用户以为设备已支持或会替用户发出消息。

## 输出要求

- 每条发现写 `file:line` 和证据（代码、测试或复现步骤），推测要标明；不提纯风格或命名偏好。
- 每条标一个级别：重要（会造成上面的出事情形，或违反上面任一条）、小问题（最多 3 条）、原有问题（这次改动之前就有的 bug）。
- 总结第一句写重要发现有几条；一条都没有就直说「没有要改的」。
