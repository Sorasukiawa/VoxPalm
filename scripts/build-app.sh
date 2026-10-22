#!/bin/bash
# 编译并打包掌声 VoxPalm.app，输出到 build/VoxPalm.app。
# 用法：scripts/build-app.sh            （release）
#      CONFIG=debug scripts/build-app.sh
#      VOXPALM_PRIVATE_DIR=../VoxPalm-private scripts/build-app.sh   （官方版：带上私有仓库的 DJI 适配）
#      OUTPUT_DIR=/tmp/voxpalm-test scripts/build-app.sh            （打到别的目录，不动 build/ 里正在用的那份）
#      UNIVERSAL=1 scripts/build-app.sh                             （发布包：Apple 芯片和 Intel 通用版）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
# 官方版和开源版用不同的编译目录，免得互相残留模块。
SCRATCH="$ROOT/App/.build"
if [[ -n "${VOXPALM_PRIVATE_DIR:-}" ]]; then
  export VOXPALM_PRIVATE_DIR="$(cd "$VOXPALM_PRIVATE_DIR" && pwd)"
  SCRATCH="$ROOT/App/.build-private"
fi

ARCH_FLAGS=()
if [[ -n "${UNIVERSAL:-}" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

cd "$ROOT/App"
# 数组为空时这样写，老版本 bash 在 set -u 下才不报错
swift build -c "$CONFIG" --scratch-path "$SCRATCH" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="${OUTPUT_DIR:-$ROOT/build}/VoxPalm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/VoxPalm" "$APP/Contents/MacOS/VoxPalm"
# 发布包去掉调试用的符号表：里面记着编译时源码和中间文件的完整路径（本机用户名、目录，连私有模块的文件名都有），
# 用 strings 查不出来。只去调试符号，崩溃报告里照样有函数名。签名在后面重新做。
if [[ "$CONFIG" == "release" ]]; then
  strip -S -no_code_signature_warning "$APP/Contents/MacOS/VoxPalm"
fi
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
