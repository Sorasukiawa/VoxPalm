#!/bin/bash
# 在临时目录用假编译器/签名器/strip 验证打包失败不会毁掉已有 App、release 去掉调试符号表，不使用钥匙串。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voxpalm-build-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE="$TEST_DIR/project"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/App" "$FIXTURE/brand/icon" "$FIXTURE/brand/menubar" "$TEST_DIR/bin" "$TEST_DIR/products/whisper.framework" "$TEST_DIR/output/VoxPalm.app"
cp "$ROOT/scripts/build-app.sh" "$FIXTURE/scripts/"
for file in App/Info.plist App/VoxPalm.entitlements THIRD-PARTY-NOTICES.md brand/icon/VoxPalm.icns brand/menubar/MenuBarIconTemplate.png brand/menubar/MenuBarIconTemplate@2x.png; do
  touch "$FIXTURE/$file"
done
# 假编译产物带一行调试符号里的本机路径；whisper 框架里只有官方 CI 的 /Users/runner/ 路径。
printf 'new executable\ndebug-symbol /Users/fixture/VoxPalm/App/.build/release/VoxPalm.build/AppConfig.swift.o\n' > "$TEST_DIR/products/VoxPalm"
printf 'framework\n/Users/runner/work/whisper.cpp/build-apple/whisper.build/ggml.c.o\n' > "$TEST_DIR/products/whisper.framework/whisper"
printf 'old executable' > "$TEST_DIR/output/VoxPalm.app/keep"
cat > "$TEST_DIR/bin/swift" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_DIR/swift-arguments"
if [[ "$*" == *--show-bin-path* ]]; then
  printf '%s\n' "$TEST_DIR/products"
fi
SH
cat > "$TEST_DIR/bin/codesign" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_DIR/codesign-arguments"
if [[ "${FAIL_SIGN:-0}" == 1 ]]; then exit 1; fi
if [[ "${FAIL_VERIFY:-0}" == 1 && "$1" == --verify ]]; then exit 1; fi
SH
cat > "$TEST_DIR/bin/strip" <<'SH'
#!/bin/bash
# 记下参数；带 -S 时删掉假调试符号行，模拟去掉调试符号表。
printf '%s\n' "$*" >> "$TEST_DIR/strip-arguments"
file="${!#}"
test -f "$file" || exit 1
for argument in "$@"; do
  if [[ "$argument" == -S ]]; then
    printf '%s\n' "$(grep -v '^debug-symbol ' "$file")" > "$file"
  fi
done
SH
chmod +x "$TEST_DIR/bin/swift" "$TEST_DIR/bin/codesign" "$TEST_DIR/bin/strip"
export TEST_DIR
export PATH="$TEST_DIR/bin:$PATH"
export SIGN_IDENTITY=-
unset VOXPALM_PRIVATE_DIR
cd "$TEST_DIR"

# 照 REVIEW.md 的查法扫整包：按字节找含 /Users/ 或 .build 的可打印串，每处一行；
# whisper 框架里官方 CI 留下的 /Users/runner/ 不算。真安装包也能这样查。
local_paths() {
  local file
  find "$1" -type f -print0 | while IFS= read -r -d '' file; do
    LC_ALL=C grep -a -F -e /Users/ -e .build "$file" | LC_ALL=C tr -c '[:print:]' '\n' | LC_ALL=C grep -F -e /Users/ -e .build |
      { if [[ "$file" == */whisper.framework/* ]]; then grep -v -F /Users/runner/; else cat; fi; } || true
  done
}

if FAIL_SIGN=1 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/sign.log" 2>&1; then
  echo '签名失败应返回失败' >&2; exit 1
fi
test "$(cat output/VoxPalm.app/keep)" = 'old executable'
if FAIL_VERIFY=1 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/verify.log" 2>&1; then
  echo '验签失败应返回失败' >&2; exit 1
fi
test "$(cat output/VoxPalm.app/keep)" = 'old executable'
: > "$TEST_DIR/codesign-arguments"
: > "$TEST_DIR/strip-arguments"
UNIVERSAL=0 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/success.log" 2>&1
# release 必须对包里的主程序去调试符号表，否则安装包会带出本机路径和私有仓库的文件名。
if ! grep -q -E -- '(^| )-S .*/VoxPalm\.app/Contents/MacOS/VoxPalm$' "$TEST_DIR/strip-arguments"; then
  echo 'release 打包没有对主程序调用 strip -S' >&2; exit 1
fi
leaks="$(local_paths output/VoxPalm.app)"
if [[ -n "$leaks" ]]; then
  printf 'release 包里还有本机路径：\n%s\n' "$leaks" >&2; exit 1
fi
test "$(grep -c -- '--options 0' "$TEST_DIR/codesign-arguments")" = 2
test "$(cat output/VoxPalm.app/Contents/MacOS/VoxPalm)" = 'new executable'
test ! -e output/VoxPalm.app/keep
test -f output/VoxPalm.app/Contents/Frameworks/whisper.framework/whisper
test ! -d "$FIXTURE/App/output"
if grep -q -- '--arch' "$TEST_DIR/swift-arguments"; then
  echo 'UNIVERSAL=0 不应编译通用版' >&2; exit 1
fi
# 调试版保留符号表、不调用 strip；顺带确认上面的整包扫描真能查出路径。
: > "$TEST_DIR/strip-arguments"
CONFIG=debug OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/debug.log" 2>&1
if [[ -s "$TEST_DIR/strip-arguments" ]]; then
  echo 'debug 打包不应调用 strip' >&2; exit 1
fi
test "$(local_paths output/VoxPalm.app | wc -l | tr -d ' ')" = 1
UNIVERSAL=1 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/universal.log" 2>&1
grep -q -- '--arch arm64 --arch x86_64' "$TEST_DIR/swift-arguments"
: > "$TEST_DIR/codesign-arguments"
SIGN_IDENTITY=fixture-identity OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/certificate.log" 2>&1
test "$(grep -c -- '--options runtime' "$TEST_DIR/codesign-arguments")" = 2
if UNIVERSAL=invalid OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/invalid.log" 2>&1; then
  echo '无效的 UNIVERSAL 应返回失败' >&2; exit 1
fi
test -z "$(find output -name '.voxpalm-build.*' -print)"
echo '打包回归通过：失败保留旧包、成功替换、相对路径、release 去调试符号且整包无本机路径、通用版开关、临时与证书签名选项、临时文件清理。'
