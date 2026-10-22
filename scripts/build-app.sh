#!/bin/bash
# 编译并打包掌声 VoxPalm.app，输出到 build/VoxPalm.app。
# 用法：scripts/build-app.sh            （release）
#      CONFIG=debug scripts/build-app.sh
#      VOXPALM_PRIVATE_DIR=../VoxPalm-private scripts/build-app.sh   （官方版：带上私有仓库的 DJI 适配）
#      OUTPUT_DIR=/tmp/voxpalm-test scripts/build-app.sh            （打到别的目录，不动 build/ 里正在用的那份）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
# 官方版和开源版用不同的编译目录，免得互相残留模块。
SCRATCH="$ROOT/App/.build"
if [[ -n "${VOXPALM_PRIVATE_DIR:-}" ]]; then
  export VOXPALM_PRIVATE_DIR="$(cd "$VOXPALM_PRIVATE_DIR" && pwd)"
  SCRATCH="$ROOT/App/.build-private"
fi

cd "$ROOT/App"
swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

APP="${OUTPUT_DIR:-$ROOT/build}/VoxPalm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/VoxPalm" "$APP/Contents/MacOS/VoxPalm"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
# whisper.cpp（MIT）的预编译框架：老系统的内置转写用。ditto 保留框架里的符号链接。许可证随 App 带上。
ditto "$BIN_DIR/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
# 品牌素材从 brand/ 取，不在 App 目录里放副本。
cp "$ROOT/brand/icon/VoxPalm.icns" "$APP/Contents/Resources/"
cp "$ROOT/brand/menubar/MenuBarIconTemplate.png" "$ROOT/brand/menubar/MenuBarIconTemplate@2x.png" "$APP/Contents/Resources/"

# 签名：有 Developer ID 或 Apple Development 证书就用它，这样重新编译后系统权限不会失效；没有就临时签名。
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
# 先签里面的框架再签 App：强化运行时只肯加载同一个签名的框架。
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --options runtime --entitlements "$ROOT/App/VoxPalm.entitlements" --sign "${IDENTITY:--}" "$APP"
echo "已打包：${APP}（签名：${IDENTITY:-临时签名}）"
