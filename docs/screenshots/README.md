# 首页截图

README 首页用的界面截图，深浅色各一张，README 里用 `<picture>` 跟着 GitHub 的深浅色切换。

都是 App 的 `--render-live` 在屏幕外的真窗口里截的（不抢前台）。设置 `VOXPALM_CONFIG` 指向独立测试配置以启用演示内容；预览只在内存里改状态，不保存配置、不启用控制设备或预热麦克风：

```bash
VOXPALM_CONFIG=/tmp/voxpalm-shots/config.json build/VoxPalm.app/Contents/MacOS/VoxPalm --render-live /tmp/voxpalm-shots
```

| 文件 | 取自 | 处理 |
|---|---|---|
| `settings-keys-*.png` | `live-settings-keys-*.png` | 缩到 1440 像素宽 |
| `settings-voice-*.png` | `live-settings-voice-*.png` | 缩到 1440 像素宽 |
| `panel-*.png` | `live-panel-*.png` | 原样 |

缩图可以用 `sips --resampleWidth 1440 <原图> --out <新图>`。界面大改后重新截一遍，文件名不变，几种语言的 README 都不用改。截图只用不带厂商品牌的设备（比如系统媒体键），免得让人误以为某款设备已经支持。
