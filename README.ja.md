<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/wordmark/VoxPalm-lockup-dark.png">
  <img src="brand/wordmark/VoxPalm-lockup-light.png" alt="VoxPalm" width="400">
</picture>

### 押したまま話して、離せば文字に

リモコンやワイヤレスマイクを、Mac の音声入力ボタンに

[![ライセンス GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-D85A30)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-2B2840?logo=apple&logoColor=white)](#ソースからビルド)
[![Swift 6](https://img.shields.io/badge/Swift-6-FF7A4D?logo=swift&logoColor=white)](Packages/VoxPalmCore)
![ステータス：開発中](https://img.shields.io/badge/%E3%82%B9%E3%83%86%E3%83%BC%E3%82%BF%E3%82%B9-%E9%96%8B%E7%99%BA%E4%B8%AD-5E5A6E)

[简体中文](README.md) · [繁體中文](README.zh-TW.md) · [English](README.en.md) · **日本語**

</div>

> [!NOTE]
> 開発中です。[公開ベータ版](https://github.com/Sorasukiawa/VoxPalm/releases)をダウンロードして試せます。まだ Apple の公証を受けていないため、初回は「システム設定 › プライバシーとセキュリティ」で「このまま開く」をクリックしてください（手順はリリースノートを参照）。[ソースからビルド](#ソースからビルド)することもできます。アプリの画面は今のところ簡体字中国語のみです。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-keys-dark.png">
    <img src="docs/screenshots/settings-keys-light.png" alt="設定 › キー：デバイスの図のボタンをクリックして、1 回押し・2 回押し・長押しの動作を設定" width="760">
  </picture>
</p>

## できること

**VoxPalm**（掌声）は macOS のメニューバーアプリです。手に持ったリモコンや、服に付けたワイヤレスマイクのボタンを押したまま話し、離すとカーソルの位置に文字が入ります。ボタンごとに 1 回押し・2 回押し・長押しの動作も設定でき、チャットの切り替え、ショートカットキー、録音・編集ソフトの操作に使えます。

- **音声でコーディング**：椅子にもたれたまま、Claude Code や Codex などの AI コーディングツールに話しかけて指示できます。リモコンの上下キーでチャットを切り替え、決定ボタンの長押しで話し、1 回押しで送信します。
- **ふだんの文字入力**：豆包（Doubao）、WeChat 入力法、Typeless、Handy などの入力ツールと連携でき、内蔵のオンデバイス文字起こしも使えます。
- **録音と編集**：録音・編集ソフトで録音の開始と停止、再生、マーカーの追加ができます。

## 特長

- **操作用と収音用を別々に選べる**：たとえばリモコンで操作し、プロ用マイクで収音できます。
- **2 通りの文字入力**：内蔵の文字起こしはこの Mac 上で音声を文字にし、音声をアップロードしません（macOS 26 以降はシステムの文字起こし、それより古いシステムでは whisper.cpp）。いつも使っている IME に任せることもでき、その場合は VoxPalm が IME の音声入力キーを代わりに押します。
- **最初の一言を取りこぼさない**：ボタンを押した瞬間から録音を始め、長押しになった時点で有効になり、短く押しただけなら自動で破棄します。
- **入れるべき場所にだけ貼る**：ボタンを押したときにカーソルがあった入力欄にだけ貼り付け、パスワード欄には貼りません。貼れないときはクリップボードに入れ、小さな表示で ⌘V を押すよう知らせます。
- **ひとつのボタンにいくつもの役割**：各ボタンの 1 回押し・2 回押し・長押しに、押して話す、ショートカットキー、定型文、メディアキー、アプリを開く、を割り当てられます。
- **図を見ながらボタンを設定**：設定画面にデバイスの図が描かれていて、実機のボタンを押すと図の同じボタンが光ります。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/panel-dark.png">
    <img src="docs/screenshots/panel-light.png" alt="メニューバーのパネル：話すボタン、操作と収音のデバイス、最近入力した文字" width="293">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-voice-dark.png">
    <img src="docs/screenshots/settings-voice-light.png" alt="設定 › 音声：内蔵の文字起こしか外部 IME、最初の一言の取りこぼし防止" width="467">
  </picture>
</p>
<p align="center"><sub>左：メニューバーのアイコンから開くパネル　　右：設定 › 音声</sub></p>

## 対応デバイス

ボタンを Mac で読み取れるかどうかはデバイスごとに実機で確かめており、すべてのボタンが使えるとは決めつけていません。

| デバイス | 状態 | コード |
|---|---|---|
| DJI Mic 2 | 実機確認済み（送信機を Bluetooth で Mac に直接接続、ファームウェア 04.02.01.13）：録音ボタン、リンクボタン、電源ボタンの 1 回押し。ボタンと収音は同時に使えます。2 回押しはできません。送信機のマイクが無音になったときは、自動で Mac のマイクに切り替えて録音します | クローズドソースのモジュール、無料版で利用可 |
| DJI Mic Mini | 未確認 | クローズドソースのモジュール、無料版で利用可 |
| Xiaomi Bluetooth リモコン 2 / 2 Pro | 予定 | オープンソース |
| Apple Siri Remote | 機種識別、機種別の図、ボタン学習を実装済み。実機検証は未完了。スワイプと内蔵マイクは未対応 | オープンソース |
| DualSense（DS5） | USB・Bluetooth のボタン対応を実装済み。実機検証は未完了 | オープンソース |
| DualSense Edge（DSE） | USB で 23 ボタンの入力、方向キーの 8 方向とニュートラルへの復帰を実機確認済み。背面ボタンはデフォルトプロファイルで個別に読み取り可能。Bluetooth、接続の安定性、アプリの一連の動作は引き続き検証が必要 | オープンソース |
| プレゼンター、フットペダルなどの汎用ボタンデバイス | 予定 | オープンソース |
| iPhone / iPad / Apple Watch（VoxPalm モバイル版：トラックパッド + 押して話す） | 予定 | オープンソース |

これらの新しい対応は現在ソースコードのみで、beta.2 の配布パッケージには含まれません。範囲・設定・実機確認の手順は[リモコンとコントローラー](docs/设备兼容/遥控器与手柄.md)（簡体字中国語）を参照してください。

お手持ちのデバイスが表にない場合は、[デバイスプローブ](tools/probe/README.md)（中国語）でボタンと収音を調べ、レポートを issue に投稿してください。[コントリビュート](#コントリビュート)も参照してください。

## ソースからビルド

macOS 14 以降と完全版の Xcode が必要です（現在は Xcode 27 で確認しています）。リポジトリのルートで実行します。

```bash
git clone https://github.com/Sorasukiawa/VoxPalm.git
cd VoxPalm
env -u VOXPALM_PRIVATE_DIR bash scripts/build-app.sh
open build/VoxPalm.app
```

初回起動時にガイドが表示されます。「入力監視」「アクセシビリティ」「マイク」の 3 つの権限をオンにし、操作用と収音用のデバイスを選び、デバイスのボタンを押して話すボタンに設定したら、その場で一言試せます。

コアライブラリとデバイスプローブのテストは、それぞれ次のコマンドで実行します。

```bash
swift test --package-path Packages/VoxPalmCore
swift test --package-path tools/probe
```

テストが通ることはコード内のテストケースの範囲しか保証しません。デバイスの互換性は、上の表にある実機での確認結果を基準にしています。詳しい説明とコード構成は [App/README.md](App/README.md)（中国語）にあります。

## ロードマップ

| バージョン | 内容 |
|---|---|
| 0.1 ベータ | Mac のコア：ボタン → 動作、押して話す、マイクの切り替えとプリロール、外部 IME との連携、内蔵の文字起こし。DJI Mic 2 / Mini、汎用ボタンデバイス。Siri Remote のボタンと DualSense / Edge 対応を前倒し |
| 0.2 ベータ | モバイル版：iPhone / iPad のトラックパッド + 押して話す、Apple Watch の話すボタン |
| 0.3 ベータ | Xiaomi Bluetooth リモコン 2、Siri Remote のタッチ面。Pro 機能：複数のキー設定、アプリごとの切り替え、録音・編集ソフト用アクションパック、文字起こしの強化 |
| 1.0 正式版 | iOS 版の App Store 配信、Pro の販売開始、公式サイト |

## 無料版と Pro

無料版は期間も回数も無制限で、デバイス 1 セットで「ボタン → 話す → 文字入力」のすべてを使えます。対応デバイスも版による違いはありません。Pro は買い切りで、複数デバイス、複数の利用シーン、録音・編集のワークフロー向けです。詳しくは [docs/免费版与Pro.md](docs/免费版与Pro.md)（中国語）をご覧ください。

## コントリビュート

いちばん助かるのはデバイスの実機確認です。[デバイスプローブ](tools/probe/README.md)で `voxpalm-probe wizard` を実行し、生成されたレポートを issue に添付してください。採用されたレポートには Pro ライセンスを差し上げます。

コードを提出するにはコントリビューター・ライセンス契約（CLA）への署名が必要です。その手続きが整うまで、外部からのコードはマージしていません。詳しくは [CONTRIBUTING.md](CONTRIBUTING.md)（中国語）をご覧ください。

## オープンソースとライセンス

- このリポジトリには、macOS アプリ本体、ボタンと音声のエンジン、デバイス対応の枠組み、デバイスプローブのソースコードが含まれ、[GPL-3.0-only](LICENSE) で公開しています。非公開のモジュールがなくてもビルドできます。
- DJI などの新しいデバイス向けの対応モジュールと Pro 機能は別に管理しているクローズドソースで、このリポジトリには含まれません。
- 名前、ロゴ、アイコン、宣伝用素材は独自のブランド素材です。[BRAND-LICENSE.md](BRAND-LICENSE.md)（中国語）をご覧ください。

詳しい区分は [docs/开源范围与许可.md](docs/开源范围与许可.md)（中国語）にあります。
