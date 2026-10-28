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
# 相对输出目录按调用脚本时的位置解释，不受下面 cd App 影响。
OUTPUT="${OUTPUT_DIR:-$ROOT/build}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
# 官方版和开源版用不同的编译目录，免得互相残留模块。
SCRATCH="$ROOT/App/.build"
if [[ -n "${VOXPALM_PRIVATE_DIR:-}" ]]; then
  export VOXPALM_PRIVATE_DIR="$(cd "$VOXPALM_PRIVATE_DIR" && pwd)"
  SCRATCH="$ROOT/App/.build-private"
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
elif [[ -n "${UNIVERSAL:-}" && "$UNIVERSAL" != "0" ]]; then
  echo "UNIVERSAL 只能设为 0 或 1" >&2
  exit 1
fi

cd "$ROOT/App"
# 数组为空时这样写，老版本 bash 在 set -u 下才不报错
swift build -c "$CONFIG" --jobs "${SWIFT_JOBS:-2}" --scratch-path "$SCRATCH" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

DESTINATION="$OUTPUT/VoxPalm.app"
# 先在同一磁盘打完包、验过签名，再替换旧包；编译、拷贝或签名失败都保留旧包。
STAGING="$(mktemp -d "$OUTPUT/.voxpalm-build.XXXXXX")"
APP="$STAGING/VoxPalm.app"
PREVIOUS="$STAGING/previous.app"
cleanup() {
  if [[ -e "$PREVIOUS" && ! -e "$DESTINATION" ]]; then
    if ! mv "$PREVIOUS" "$DESTINATION"; then
      echo "恢复旧包失败，旧包保留在：$PREVIOUS" >&2
      return
    fi
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
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
# 正式证书启用强化运行时；临时签名没有 Team ID，启用后会在加载 whisper 时被库验证拦下。
SIGN_OPTIONS=runtime
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  SIGN_OPTIONS=0
fi
# 先签里面的框架再签 App，显式覆盖编译产物可能保留的旧签名选项。
codesign --force --options "$SIGN_OPTIONS" --sign "${IDENTITY:--}" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --options "$SIGN_OPTIONS" --entitlements "$ROOT/App/VoxPalm.entitlements" --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
# 发布包签完名再整包查一遍本机路径：strip -S 去不掉写进程序的 #filePath、#file 和写死的路径，查到就失败、保留旧包。
# 官方版也查（私有编译目录 .build-private 也含 .build）；仓库和私有仓库不在 /Users/ 下也按完整路径查，
# 经符号链接的再查一遍解析后的真实路径，编译器记的是那个。调试版本来就带路径，不查。
if [[ "$CONFIG" == "release" ]]; then
  EXTRA_PATHS=("$ROOT" "$(cd "$ROOT" && pwd -P)")
  if [[ -n "${VOXPALM_PRIVATE_DIR:-}" ]]; then
    EXTRA_PATHS+=("$VOXPALM_PRIVATE_DIR" "$(cd "$VOXPALM_PRIVATE_DIR" && pwd -P)")
  fi
  if ! LEAKS="$(bash "$ROOT/scripts/lib/local-paths.sh" "$APP" "${EXTRA_PATHS[@]}")"; then
    echo "整包本机路径自检没能查完，保留旧包。已查到的：" >&2
    head -20 <<< "$LEAKS" >&2
    exit 1
  fi
  if [[ -n "$LEAKS" ]]; then
    printf '发布包里查到 %s 处本机路径，保留旧包。写进程序的路径只能放在 #if DEBUG 里：\n' "$(grep -c '' <<< "$LEAKS")" >&2
    head -20 <<< "$LEAKS" >&2
    exit 1
  fi
fi
if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$PREVIOUS"
fi
mv "$APP" "$DESTINATION"
echo "已打包：${DESTINATION}（签名：${IDENTITY:-临时签名}）"
