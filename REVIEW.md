# 掌声评审须知

本仓库公开，源码、文档和提交历史任何人都能看。评审前先读 `AGENTS.md`；评审只读，不启动 App、不申请权限、不连接设备。

## 出事是什么样

- 最怕发出去的东西带了不该公开的内容：安装包里留着本机源码路径、用户名或私有仓库的目录和文件名（`#filePath` 写进程序、release 没去调试符号表都出过，只用 `strings` 查不出符号表里的路径），或者闭源适配、逆向细节、别人的 GPL 代码进了本仓库（见 `AGENTS.md`「开源边界」）。
- 其次是替用户按错键：掌声往前台 App 发按键、贴字、按回车，误触发会把半句话发进别人正在用的聊天窗口；以及没按键时开着麦、录音或转写落盘，下载的模型没校验就加载。

## 高风险路径

改到下面任何一处，合入 main 前都要独立评审：
- `scripts/build-app.sh`、`scripts/tests/build-app.sh`、`App/VoxPalm.entitlements`、`App/Info.plist`：打包、release 去调试符号表、签名、带上 whisper 框架和第三方许可、权限说明和 Bundle ID。
- `App/Package.swift`、`App/Sources/VoxPalm/PrivateModules.swift`、`App/Sources/VoxPalm/UIPreview.swift`：私有模块只在 `VOXPALM_PRIVATE` 下链接；调试预览里有 `#filePath`，只能编进调试版。
- `Packages/VoxPalmCore/Sources/VoxPalmEngine/KeyPoster.swift`、`TextInserter.swift`、`TextTarget.swift`、`AppCommands.swift`、`Action.swift`、`ButtonEngine.swift`：模拟按键、贴字、切对话和回车发送。
- `Packages/VoxPalmCore/Sources/VoxPalmVoice/VoiceSession.swift`、`AudioCapture.swift`、`MicRouting.swift`：什么时候开麦、预录多久、用哪支麦（选定的麦断开时不能偷换成别的麦）、录音和转写去哪。
- `Packages/VoxPalmCore/Sources/VoxPalmVoice/Whisper.swift`、`WhisperDownload.swift`、`App/Sources/VoxPalm/WhisperModels.swift`：模型下载源和 SHA-256 校验。
- `Packages/VoxPalmCore/Sources/VoxPalmDevices/Redaction.swift`、`App/Sources/VoxPalm/AppConfig.swift`：导出报告脱敏，设置读坏时不覆盖、只在明确导入时备份替换。
- `.github/workflows/*.yml`：公开仓库的 CI，谁都能发 PR 触发。
- `LICENSE`、`THIRD-PARTY-NOTICES.md`、`BRAND-LICENSE.md`、`docs/开源范围与许可.md`、`AGENTS.md`、`CLAUDE.md`、`REVIEW.md`：许可、开源范围和 AI 会话的规则；改 `REVIEW.md` 能缩小评审范围。

## 重点看什么

1. 开源边界：闭源设备适配、Pro 功能、逆向资料、定价和调研不进本仓库，代码注释和提交说明里也不写逆向细节；不复制别人的 GPL 代码；外部贡献在 CLA 就位前不合并（`AGENTS.md`）。不带私有仓库也要能编译和测试（`scripts/check.sh` 会 `unset VOXPALM_PRIVATE_DIR`），私有代码只通过 `PrivateModules.swift` 里的 `#if VOXPALM_PRIVATE` 接入。
2. 安装包不带本机信息：release 必须 `strip -S`（`scripts/build-app.sh`）；新出现的 `#filePath`、`#file`、绝对路径和用户名只能在 `#if DEBUG` 里（参照 `UIPreview.swift`）。改打包的提交要说明怎么查过整包：`/Users/`、私有仓库目录名、`.build` 都应为 0 处，whisper 框架里官方 CI 的 `/Users/runner/` 除外。
3. 不误发按键：回车只在用户配置了发送、且确认光标在有字的输入框里时才按（`Action.swift` 的 `sendReturn`）；切对话只对 Claude、Codex 前台生效；按键在任何出错、取消、换设备的路径上都要成对松开，不留按住的修饰键（`KeyPoster.swift`）。
4. 麦克风和隐私：只在按下说话键后开麦预录，松手或取消就停；录音和转写只在内存里，只有调试环境变量 `VOXPALM_DEBUG_AUDIO_FILE`、`VOXPALM_DEBUG_TRANSCRIPT_FILE` 才读写文件（`VoiceSession.swift`），不进日志；导出报告蓝牙地址只留厂商段、不导出序列号（`Redaction.swift`）。
5. 下载的模型校验通过才用：下载源只走 HTTPS，SHA-256 对不上就丢弃（`WhisperDownload.swift`），不能为了能用而跳过校验或换成不固定的地址。
6. CI 保持 `contents: read`、`persist-credentials: false`，第三方 action 固定到提交 SHA；公开仓库的工作流不引入 Secret 或签名证书。
7. 设备能力写实：文档和 README 分清「已实测」「待验证」，没实测的不写成能用（`AGENTS.md`「设备能力」）；改 README 时四个语言版本一起改。
8. 测试跟着改：动到上面的逻辑要有对应的单元测试或 `scripts/tests/` 用例，删测试、放宽断言都算问题。

## 不用管

- 品牌导出的 PNG 和 `brand/` 素材只看是不是用 `brand/tools/` 脚本生成的；`design/`、`docs/screenshots/` 不评。
- `tools/probe/` 是开发用的设备探针，不进安装包，只看非法参数仍在开麦前失败（`scripts/check.sh`）。
- 界面样式、动效和措辞从轻，除非会误导用户以为设备已支持或会替用户发出消息。

## 输出要求

- 每条发现写 `file:line` 和证据（代码、测试或复现步骤），推测要标明；不提纯风格或命名偏好。
- 每条标一个级别：重要（会造成上面的出事情形，或违反上面任一条）、小问题（最多 3 条）、原有问题（这次改动之前就有的 bug）。
- 总结第一句写重要发现有几条；一条都没有就直说「没有要改的」。
