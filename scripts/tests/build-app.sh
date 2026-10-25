#!/bin/bash
# 在临时目录用假编译器/签名器验证打包失败不会毁掉已有 App，不使用钥匙串。
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
printf 'new executable' > "$TEST_DIR/products/VoxPalm"
printf 'framework' > "$TEST_DIR/products/whisper.framework/whisper"
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
exit 0
SH
chmod +x "$TEST_DIR/bin/swift" "$TEST_DIR/bin/codesign" "$TEST_DIR/bin/strip"
export TEST_DIR
export PATH="$TEST_DIR/bin:$PATH"
export SIGN_IDENTITY=-
unset VOXPALM_PRIVATE_DIR
cd "$TEST_DIR"

if FAIL_SIGN=1 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/sign.log" 2>&1; then
  echo '签名失败应返回失败' >&2; exit 1
fi
test "$(cat output/VoxPalm.app/keep)" = 'old executable'
if FAIL_VERIFY=1 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/verify.log" 2>&1; then
  echo '验签失败应返回失败' >&2; exit 1
fi
test "$(cat output/VoxPalm.app/keep)" = 'old executable'
: > "$TEST_DIR/codesign-arguments"
UNIVERSAL=0 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/success.log" 2>&1
test "$(grep -c -- '--options 0' "$TEST_DIR/codesign-arguments")" = 2
test "$(cat output/VoxPalm.app/Contents/MacOS/VoxPalm)" = 'new executable'
test ! -e output/VoxPalm.app/keep
test -f output/VoxPalm.app/Contents/Frameworks/whisper.framework/whisper
test ! -d "$FIXTURE/App/output"
if grep -q -- '--arch' "$TEST_DIR/swift-arguments"; then
  echo 'UNIVERSAL=0 不应编译通用版' >&2; exit 1
fi
UNIVERSAL=1 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/universal.log" 2>&1
grep -q -- '--arch arm64 --arch x86_64' "$TEST_DIR/swift-arguments"
: > "$TEST_DIR/codesign-arguments"
SIGN_IDENTITY=fixture-identity OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/certificate.log" 2>&1
test "$(grep -c -- '--options runtime' "$TEST_DIR/codesign-arguments")" = 2
if UNIVERSAL=invalid OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/invalid.log" 2>&1; then
  echo '无效的 UNIVERSAL 应返回失败' >&2; exit 1
fi
test -z "$(find output -name '.voxpalm-build.*' -print)"
echo '打包回归通过：失败保留旧包、成功替换、相对路径、通用版开关、临时与证书签名选项、临时文件清理。'
