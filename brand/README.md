# 掌声 VoxPalm 品牌素材

图形含义：从左到右是 ● 按钮 → 声波 → 一行行文字和光标，讲的就是「按住说话，松手出字」。● 也是通用的「录音」符号。

本目录里的名字、Logo、图标、文字标志和宣传封面是专有品牌素材，不属于 GPL 开源范围，使用条件见 [BRAND-LICENSE.md](../BRAND-LICENSE.md)。`tools/` 里的生成脚本按 GPL-3.0-only 开源。

## 文件

| 文件 | 用途 |
|---|---|
| `icon/VoxPalm-icon.svg` | App 图标源文件，1024 画布，已带 macOS 圆角外形和留白 |
| `icon/VoxPalm-icon-small.svg` | 16、32 像素用的简化版：按钮 + 一根声波 + 两行字，线条更粗，去掉光标 |
| `icon/layers/background.svg`、`icon/layers/foreground.svg` | 背景层和前景层，不带圆角外形，留给 Icon Composer 做分层图标用 |
| `icon/VoxPalm.icns` | 直接放进 App 的图标文件 |
| `icon/VoxPalm-icon-1024.png` | 官网、README 用的大图 |
| `menubar/MenuBarIconTemplate.svg`、`.png`、`@2x.png` | 菜单栏图标，黑色加透明的模板图，系统会自动适配深浅色 |
| `wordmark/VoxPalm-lockup-light/dark` | 图标加「掌声 VoxPalm」横排组合，分浅色背景和深色背景两版，SVG 和 PNG 各一份 |
| `wordmark/VoxPalm-wordmark-light/dark` | 只有文字的版本 |
| `cover/VoxPalm-cover-1280x640.png` | 横版封面：GitHub 社交预览、官网、推特 |
| `cover/VoxPalm-cover-1242x1660.png` | 竖版封面：小红书 |
| `preview.png` | 图标在浅色和深色背景、各尺寸、菜单栏的预览 |

## 颜色

| 用途 | 色值 |
|---|---|
| 图标背景渐变（上 → 下） | `#2B2840` → `#17151F` |
| 按钮、声波渐变（上 → 下） | `#FF8A5C` → `#D85A30` |
| 按钮厚度 | `#A93F1C` |
| 文字线条 | `#FFF3EA` |
| 光标、强调色 | `#FF7A4D`、`#D85A30` |
| 封面底色 | `#FFF7F2` |
| 正文深色 | `#1F1D2B` |
| 正文浅色 | `#5E5A6E` |

## 字体

| 用在哪 | 字体 | 许可 |
|---|---|---|
| 文字标志、封面、宣传图（中英文） | 思源黑体 Source Han Sans CN：「掌声」用 Heavy，「VoxPalm」和标题用 Bold，正文用 Regular / Medium | SIL OFL 1.1，可以免费商用，也可以用在 Logo 上 |
| App 界面 | 系统字体（苹方、SF） | 系统自带，用在 App 界面里没问题 |

文字标志的 SVG 已经把文字转成了路径，别的电脑没装思源黑体也能正常显示。苹方和 SF 字体的许可里没有明确允许用在 Logo 上，所以 Logo 和宣传图不用它们。

## 宣传文案

- 主标语：按住说话，松手出字
- 副标语：把遥控器和无线麦，变成 Mac 的语音按钮
- 场景：语音编程 · 办公输入 · 录音剪辑

## 重新生成

改颜色或造型时改 `tools/` 里的脚本，再按顺序运行：

```bash
python3 brand/tools/gen_icon_svg.py brand
swift brand/tools/export_icons.swift brand
iconutil -c icns brand/icon/VoxPalm.iconset -o brand/icon/VoxPalm.icns
swift brand/tools/make_wordmark.swift brand
swift brand/tools/make_covers.swift brand
```

文字标志和封面要求本机装有思源黑体 Source Han Sans CN。

## 使用说明

- 菜单栏图标在代码里加载后要设成模板图（`image.isTemplate = true`），否则深色模式下会是黑的。
- 封面和介绍里的设备只写类别（遥控器、无线麦），不写品牌名、不用厂商的产品图，避免商标问题和「已经支持」的误解。
