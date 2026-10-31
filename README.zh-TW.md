<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/wordmark/VoxPalm-lockup-dark.png">
  <img src="brand/wordmark/VoxPalm-lockup-light.png" alt="掌聲 VoxPalm" width="400">
</picture>

### 按住說話，鬆手出字

把遙控器和無線麥克風，變成 Mac 的語音按鈕

[![授權 GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-D85A30)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-2B2840?logo=apple&logoColor=white)](#從原始碼編譯)
[![Swift 6](https://img.shields.io/badge/Swift-6-FF7A4D?logo=swift&logoColor=white)](Packages/VoxPalmCore)
![狀態：開發中](https://img.shields.io/badge/%E7%8B%80%E6%85%8B-%E9%96%8B%E7%99%BC%E4%B8%AD-5E5A6E)

[简体中文](README.md) · **繁體中文** · [English](README.en.md) · [日本語](README.ja.md)

</div>

> [!NOTE]
> 開發中。可以下載[公開測試版](https://github.com/Sorasukiawa/VoxPalm/releases)先試用：還沒有經過 Apple 公證，第一次打開要在「系統設定 › 隱私權與安全性」裡點「強制打開」，步驟見發布說明。也可以[從原始碼編譯](#從原始碼編譯)。App 介面目前只有簡體中文。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-keys-dark.png">
    <img src="docs/screenshots/settings-keys-light.png" alt="設定 › 按鍵：點裝置示意圖上的鍵，設定它的單擊、雙擊、長按" width="760">
  </picture>
</p>

## 它做什麼

手裡拿著遙控器，或衣服上夾著無線麥克風，按住鍵說話，鬆手後文字就出現在游標所在的地方。每個鍵還能設定單擊、雙擊、長按，用來切換對話、按快速鍵、控制錄音和剪輯軟體。

- **語音寫程式**：靠在椅子上按住說話，對 Claude Code、Codex 這類 AI 程式設計工具下指令；遙控器上下鍵切換對話，確認鍵長按說話、單擊送出。
- **辦公輸入**：串接豆包、微信、Typeless、Handy 等輸入工具，也可以用內建的本機轉錄。
- **錄音剪輯**：在錄音和剪輯軟體裡開始、停止錄音，播放，打標記。

## 特色

- **控制和收音分開選**：例如用遙控器操作，用專業麥克風收音。
- **兩種出字方式**：內建轉錄在這台 Mac 上把話轉成文字，聲音不上傳（macOS 26 以上用系統轉錄，較舊的系統用 whisper.cpp）；也可以交給你常用的輸入法，掌聲替你按住它的語音鍵。
- **不吃掉第一個字**：按下鍵的那一刻就開始錄，長按成立才算數，短按自動捨棄。
- **只貼到對的地方**：只貼進按鍵時游標所在的那個輸入框，密碼欄位不貼；貼不進去就放進剪貼簿，浮動視窗提示按 ⌘V。
- **一個鍵多種用法**：每個鍵的單擊、雙擊、長按，都能設成按住說話、快速鍵、一段文字、媒體鍵、開啟 App。
- **照著示意圖設定按鍵**：設定裡畫著裝置的示意圖，按一下實體裝置上的鍵，圖上對應的鍵就會亮起。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/panel-dark.png">
    <img src="docs/screenshots/panel-light.png" alt="選單列面板：說話鍵、控制和收音裝置、最近出字" width="293">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-voice-dark.png">
    <img src="docs/screenshots/settings-voice-light.png" alt="設定 › 語音：內建轉錄或外部輸入法，防止吃字" width="467">
  </picture>
</p>
<p align="center"><sub>左：點選單列圖示彈出的面板　　右：設定 › 語音</sub></p>

## 裝置

每款裝置的按鍵能不能被 Mac 讀到，都要逐台實測，不預設所有按鍵都能用。

| 裝置 | 狀態 | 程式碼 |
|---|---|---|
| DJI Mic 2 | 已實測（發射器藍牙直連 Mac，韌體 04.02.01.13）：錄製鍵、連接鍵、電源鍵單擊，按鍵和收音可以同時用；無法雙擊，它的麥克風沒聲音時錄音自動改用 Mac 麥克風 | 閉源模組，免費版可用 |
| DJI Mic Mini | 待實測 | 閉源模組，免費版可用 |
| 小米藍牙遙控器 2 / 2 Pro | 規劃中 | 開源 |
| Apple Siri Remote | 已加入型號辨識、對應外形與按鍵學習，實機待驗證；滑動觸控、內建麥克風尚未接入 | 開源 |
| DualSense（DS5） | 已加入 USB/藍牙按鍵適配；實機待驗證 | 開源 |
| DualSense Edge（DSE） | USB/藍牙 23 鍵、八方向及回中已實測，預設設定檔的背鍵可獨立讀取；USB 內建麥克風搭配 R1，中文轉寫、聊天框貼字、說話中拔線取消及同一連接埠重新連線恢復已實測；藍牙可搭配 Mac 麥克風，手柄藍牙收音仍在實驗；藍牙斷線取消及長時間穩定性待驗收 | 開源 |
| 簡報筆、腳踏板等通用按鍵裝置 | 規劃中 | 開源 |
| iPhone / iPad / Apple Watch（掌聲手機版：觸控板 + 按住說話） | 規劃中 | 開源 |

公開測試版 3（`v0.1.0-beta.3`）包含上述按鍵適配和手柄 USB 收音入口；USB 手柄麥在「收音設備」中單獨選擇，斷開後不會自動改用 Mac 麥。手柄本身的藍牙收音不包含在下載包中；DS5 和 Siri Remote 仍待實機驗證。範圍、使用方式與驗收清單見[遙控器與手柄](docs/设备兼容/遥控器与手柄.md)。

手上的裝置不在表裡？可以用[裝置探針](tools/probe/README.md)（簡體中文）測一下它的按鍵和收音，把報告發到 issue，見[參與貢獻](#參與貢獻)。

## 從原始碼編譯

需要 macOS 14 以上和完整的 Xcode（目前以 Xcode 27 驗證過）。在儲存庫根目錄執行：

```bash
git clone https://github.com/Sorasukiawa/VoxPalm.git
cd VoxPalm
env -u VOXPALM_PRIVATE_DIR bash scripts/build-app.sh
open build/VoxPalm.app
```

第一次開啟會有引導：開啟「輸入監控」「輔助使用」「麥克風」三個權限 → 選擇控制裝置和收音裝置 → 按一下裝置上的鍵設成說話鍵，當場試一句。

核心函式庫和裝置探針的測試分別執行：

```bash
swift test --package-path Packages/VoxPalmCore
swift test --package-path tools/probe
```

測試通過只涵蓋程式碼裡的案例；裝置相容性以上面表格裡逐台實測的紀錄為準。更多說明和程式碼結構見 [App/README.md](App/README.md)（簡體中文）。

## 路線圖

| 版本 | 內容 |
|---|---|
| 0.1 測試版 | Mac 端核心：按鍵 → 動作、按住說話、切換麥克風和預錄、外部輸入法橋接、內建轉錄；DJI Mic 2 / Mini、通用按鍵裝置；提前加入 Siri Remote 按鍵和 DualSense / Edge 適配 |
| 0.2 測試版 | 手機版：iPhone / iPad 觸控板 + 按住說話，Apple Watch 說話鍵 |
| 0.3 測試版 | 小米藍牙遙控器 2、Siri Remote 觸控面；Pro 功能：多套按鍵配置、依 App 切換、錄音剪輯動作包、轉錄強化 |
| 1.0 正式版 | iOS 上架、Pro 開賣、官網 |

## 免費版和 Pro

免費版不限時間、不限次數，一套裝置就能完整用上「按鍵 → 說話 → 出字」，支援的裝置也不分版本。Pro 是一次買斷，主要給多裝置、多情境和錄音剪輯工作流程。詳見 [docs/免费版与Pro.md](docs/免费版与Pro.md)（簡體中文）。

## 參與貢獻

現在最需要的是裝置實測：用[裝置探針](tools/probe/README.md)跑一遍 `voxpalm-probe wizard`，把產生的報告附在 issue 裡。被採用的實測報告會送 Pro 授權。

提交程式碼前需要簽署貢獻者授權協議（CLA），流程就緒前暫不合併外部程式碼。詳見 [CONTRIBUTING.md](CONTRIBUTING.md)（簡體中文）。

## 開源與授權

- 本儲存庫提供 macOS 主程式、按鍵與語音引擎、裝置適配框架和裝置探針的原始碼，以 [GPL-3.0-only](LICENSE) 開源，不帶私有模組也能建置。
- DJI 等新裝置的適配模組、Pro 功能另外維護，是閉源的，不在本儲存庫。
- 名字、Logo、圖示和宣傳素材是專有品牌素材，見 [BRAND-LICENSE.md](BRAND-LICENSE.md)（簡體中文）。

完整的劃分見 [docs/开源范围与许可.md](docs/开源范围与许可.md)（簡體中文）。
