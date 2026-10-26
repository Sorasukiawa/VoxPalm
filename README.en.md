<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/wordmark/VoxPalm-lockup-dark.png">
  <img src="brand/wordmark/VoxPalm-lockup-light.png" alt="VoxPalm" width="400">
</picture>

### Hold to talk, release to type

Turn remotes and wireless mics into a voice button for your Mac

[![License GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-D85A30)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-2B2840?logo=apple&logoColor=white)](#build-from-source)
[![Swift 6](https://img.shields.io/badge/Swift-6-FF7A4D?logo=swift&logoColor=white)](Packages/VoxPalmCore)
![Status: work in progress](https://img.shields.io/badge/status-work%20in%20progress-5E5A6E)

[简体中文](README.md) · [繁體中文](README.zh-TW.md) · **English** · [日本語](README.ja.md)

</div>

> [!NOTE]
> VoxPalm is under development. You can download the [public beta](https://github.com/Sorasukiawa/VoxPalm/releases) to try it: it is not notarized by Apple yet, so the first time you open it you need to click "Open Anyway" in System Settings › Privacy & Security (see the release notes). You can also [build it from source](#build-from-source). The app's interface is currently in Simplified Chinese only.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-keys-dark.png">
    <img src="docs/screenshots/settings-keys-light.png" alt="Settings › Keys: click a button on the device diagram to set its single press, double press and long press" width="760">
  </picture>
</p>

## What it does

**VoxPalm** (掌声) is a macOS menu bar app. Hold a button on a remote in your hand, or on a wireless mic clipped to your shirt, and speak; let go, and the text appears wherever your cursor is. Every button can also have its own single press, double press and long press, to switch chats, send shortcuts, or control recording and editing apps.

- **Voice coding**: lean back and talk to AI coding tools like Claude Code and Codex. Up and down on the remote switch chats; long-press the center button to talk, single-press it to send.
- **Everyday typing**: works with input tools such as Doubao, WeChat Input, Typeless and Handy, or use the built-in on-device transcription.
- **Recording and editing**: start and stop recording, play back and drop markers in recording and editing apps.

## Highlights

- **Control and audio are chosen separately**: for example, operate with a remote and record with a professional microphone.
- **Two ways to get text**: built-in transcription turns speech into text on your Mac and never uploads audio (Apple's speech framework on macOS 26 and later, whisper.cpp on older systems). Or hand off to the input method you already use, and VoxPalm holds its voice key for you.
- **The first word is never cut off**: recording starts the instant you press, counts only once it becomes a long press, and short taps are discarded.
- **Text lands only where it should**: it is pasted only into the text field that had the cursor when you pressed, never into a password field. If it can't be pasted, it goes to the clipboard and a small overlay tells you to press ⌘V.
- **One button, many jobs**: single press, double press and long press can each be push-to-talk, a keyboard shortcut, a text snippet, a media key, or opening an app.
- **Set up buttons on a diagram**: Settings draws your device, and pressing a button on the real thing lights it up on the diagram.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/panel-dark.png">
    <img src="docs/screenshots/panel-light.png" alt="Menu bar panel: talk button, control and audio devices, recent text" width="293">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-voice-dark.png">
    <img src="docs/screenshots/settings-voice-light.png" alt="Settings › Voice: built-in transcription or an external input method, and first-word protection" width="467">
  </picture>
</p>
<p align="center"><sub>Left: the panel that opens from the menu bar icon &nbsp;&nbsp; Right: Settings › Voice</sub></p>

## Devices

Whether a device's buttons can be read by the Mac is tested on each device; we never assume every button works.

| Device | Status | Code |
|---|---|---|
| DJI Mic 2 | Tested (transmitter connected directly to the Mac over Bluetooth, firmware 04.02.01.13): single press on the record, link and power buttons, and buttons and audio work at the same time. Double press isn't possible; when its mic goes silent, recording automatically falls back to the Mac's microphone | Closed-source module, included in the free version |
| DJI Mic Mini | Not yet tested | Closed-source module, included in the free version |
| Xiaomi Bluetooth Remote 2 / 2 Pro | Planned | Open source |
| Apple Siri Remote | Model detection, diagrams and button learning implemented; hardware verification pending. Touch gestures and the built-in microphone are not implemented | Open source |
| DualSense (DS5) | USB/Bluetooth button support implemented; hardware verification pending | Open source |
| DualSense Edge (DSE) | All 23 buttons, eight D-pad directions and neutral tested over USB/Bluetooth; independent back buttons in the default profile. R1 with the built-in controller mic over USB, Chinese transcription and pasting into a chat input tested. Bluetooth can use the Mac mic; wireless controller audio remains experimental. Disconnect cancellation and long-term stability still need verification | Open source |
| Presenters, foot pedals and other generic button devices | Planned | Open source |
| iPhone / iPad / Apple Watch (VoxPalm mobile: trackpad + hold to talk) | Planned | Open source |

These new integrations are currently source-only and are not in the beta.2 download. See [remote and controller support](docs/设备兼容/遥控器与手柄.md) (Simplified Chinese) for scope, setup and hardware checks.

Your device isn't listed? Test its buttons and audio with the [device probe](tools/probe/README.md) (Chinese) and post the report in an issue; see [Contributing](#contributing).

## Build from source

Requires macOS 14 or later and the full Xcode (currently verified with Xcode 27). Run from the repository root:

```bash
git clone https://github.com/Sorasukiawa/VoxPalm.git
cd VoxPalm
env -u VOXPALM_PRIVATE_DIR bash scripts/build-app.sh
open build/VoxPalm.app
```

On first launch a short setup guide walks you through granting three permissions (Input Monitoring, Accessibility and Microphone), choosing your control and audio devices, and pressing a button on your device to make it the talk button, then trying it out.

To run the tests for the core library and the device probe:

```bash
swift test --package-path Packages/VoxPalmCore
swift test --package-path tools/probe
```

Passing tests only cover the cases in the code; device compatibility is defined by the per-device test records in the table above. More details and the code layout are in [App/README.md](App/README.md) (Chinese).

## Roadmap

| Version | Scope |
|---|---|
| 0.1 beta | Mac core: button → action, hold to talk, mic switching and pre-roll, external input method bridge, built-in transcription; DJI Mic 2 / Mini and generic button devices; Siri Remote buttons and DualSense / Edge support brought forward |
| 0.2 beta | Mobile: iPhone / iPad trackpad + hold to talk, Apple Watch talk button |
| 0.3 beta | Xiaomi Bluetooth Remote 2 and Siri Remote touch surface; Pro features: multiple key maps, per-app switching, action packs for recording and editing apps, transcription enhancements |
| 1.0 | App Store release on iOS, Pro on sale, website |

## Free and Pro

The free version has no time or usage limits: one set of devices is all you need for the full button → speak → text flow, and every supported device works in it. Pro is a one-time purchase aimed at multiple devices, multiple scenarios and recording and editing workflows. Details: [docs/免费版与Pro.md](docs/免费版与Pro.md) (Chinese).

## Contributing

The most helpful thing right now is device testing: run `voxpalm-probe wizard` with the [device probe](tools/probe/README.md) and attach the generated report to an issue. Accepted test reports earn a Pro license.

Code contributions require signing a Contributor License Agreement (CLA). Until that process is in place, external code isn't being merged. See [CONTRIBUTING.md](CONTRIBUTING.md) (Chinese).

## Open source and licensing

- This repository contains the source of the macOS app, the button and voice engines, the device adapter framework and the device probe, open source under [GPL-3.0-only](LICENSE). It builds without any private modules.
- Adapter modules for DJI and other new devices, and Pro features, are maintained separately as closed source and are not in this repository.
- The name, logo, icons and promotional artwork are proprietary brand assets; see [BRAND-LICENSE.md](BRAND-LICENSE.md) (Chinese).

The full breakdown is in [docs/开源范围与许可.md](docs/开源范围与许可.md) (Chinese).
