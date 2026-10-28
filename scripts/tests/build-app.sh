#!/bin/bash
# 在临时目录用假编译器/签名器/strip/nm 验证打包失败不会毁掉已有 App、release 去掉调试符号表并在签名后整包自检，不使用钥匙串。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voxpalm-build-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE="$TEST_DIR/project"
# 项目目录经符号链接访问，像仓库链接到外置盘上：打包脚本看到的路径和编译器记的真实路径不一样。
mkdir -p "$TEST_DIR/linked/project"
ln -s linked/project "$FIXTURE"
mkdir -p "$FIXTURE/scripts/lib" "$FIXTURE/App" "$FIXTURE/brand/icon" "$FIXTURE/brand/menubar" "$TEST_DIR/bin" "$TEST_DIR/products/whisper.framework" "$TEST_DIR/output/VoxPalm.app"
cp "$ROOT/scripts/build-app.sh" "$FIXTURE/scripts/"
cp "$ROOT/scripts/lib/local-paths.sh" "$FIXTURE/scripts/lib/"
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
printf 'codesign %s\n' "$*" >> "$TEST_DIR/tool-calls"
if [[ "${FAIL_SIGN:-0}" == 1 ]]; then exit 1; fi
if [[ "${FAIL_VERIFY:-0}" == 1 && "$1" == --verify ]]; then exit 1; fi
# UNREADABLE_AFTER_SIGN=1 模拟签完名后包里有读不了的文件。
if [[ "${UNREADABLE_AFTER_SIGN:-0}" == 1 && "$1" == --verify ]]; then chmod 000 "${!#}/Contents/Resources/THIRD-PARTY-NOTICES.md"; fi
SH
cat > "$TEST_DIR/bin/strip" <<'SH'
#!/bin/bash
# 和 codesign 记在同一份调用记录里；带 -S 时删掉假调试符号行，模拟去掉调试符号表。
# STRIP_KEEPS_SYMBOLS=1 模拟 strip 没生效。
printf 'strip %s\n' "$*" >> "$TEST_DIR/tool-calls"
file="${!#}"
test -f "$file" || exit 1
if [[ "${STRIP_KEEPS_SYMBOLS:-0}" == 1 ]]; then exit 0; fi
for argument in "$@"; do
  if [[ "$argument" == -S ]]; then
    printf '%s\n' "$(grep -v '^debug-symbol ' "$file")" > "$file"
  fi
done
SH
cat > "$TEST_DIR/bin/nm" <<'SH'
#!/bin/bash
# 把假调试符号行按 nm -pa 的格式列成调试符号条目，另外带一个普通符号。
printf 'nm %s\n' "$*" >> "$TEST_DIR/tool-calls"
file="${!#}"
test -f "$file" || exit 1
sed -n 's/^debug-symbol /0000000000000000 - 00 0000   OSO /p' "$file"
printf '0000000100000000 T _main\n'
SH
# 自检扫描出错的两种情形：FIND_FAILS=1 时 find 照常列文件但返回失败；GREP_FAILS=1 时读许可证文件的 grep 报错。
cat > "$TEST_DIR/bin/find" <<'SH'
#!/bin/bash
/usr/bin/find "$@" || exit
if [[ "${FIND_FAILS:-0}" == 1 ]]; then exit 1; fi
SH
cat > "$TEST_DIR/bin/grep" <<'SH'
#!/bin/bash
if [[ "${GREP_FAILS:-0}" == 1 && "${!#}" == */THIRD-PARTY-NOTICES.md ]]; then exit 2; fi
exec /usr/bin/grep "$@"
SH
chmod +x "$TEST_DIR/bin/swift" "$TEST_DIR/bin/codesign" "$TEST_DIR/bin/strip" "$TEST_DIR/bin/nm" "$TEST_DIR/bin/find" "$TEST_DIR/bin/grep"
export TEST_DIR
export PATH="$TEST_DIR/bin:$PATH"
export SIGN_IDENTITY=-
unset VOXPALM_PRIVATE_DIR
cd "$TEST_DIR"

# 和打包脚本的自检用同一个扫描：整包按字节找本机路径，再用 nm -pa 看主程序的调试符号条目，每处一行。
local_paths() {
  bash "$ROOT/scripts/lib/local-paths.sh" "$1"
}
# release 必须先对包里的主程序去调试符号表再签名，否则安装包会带出本机路径和私有仓库的文件名。
assert_release_stripped() {
  local first leaks
  first="$(head -1 "$TEST_DIR/tool-calls")"
  if ! grep -q -E -- '^strip (.* )?-S .*/VoxPalm\.app/Contents/MacOS/VoxPalm$' <<< "$first"; then
    echo "$1：release 打包没有在签名前对主程序调用 strip -S" >&2; exit 1
  fi
  # 打包脚本要在验签之后对整包自检；nm 是自检里看主程序调试符号条目的那一步，通用版要看所有架构。
  if ! sed -n '/^codesign --verify /,$p' "$TEST_DIR/tool-calls" | grep -q -E -- '^nm -pa -arch all .*/Contents/MacOS/VoxPalm$'; then
    echo "$1：release 打包没有在签名后对整包做本机路径自检" >&2; exit 1
  fi
  leaks="$(local_paths output/VoxPalm.app)"
  if [[ -n "$leaks" ]]; then
    printf '%s：release 包里还有本机路径：\n%s\n' "$1" "$leaks" >&2; exit 1
  fi
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
: > "$TEST_DIR/tool-calls"
UNIVERSAL=0 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/success.log" 2>&1
assert_release_stripped 单架构临时签名
test "$(grep -c -- '--options 0' "$TEST_DIR/codesign-arguments")" = 2
test "$(cat output/VoxPalm.app/Contents/MacOS/VoxPalm)" = 'new executable'
test ! -e output/VoxPalm.app/keep
test -f output/VoxPalm.app/Contents/Frameworks/whisper.framework/whisper
test ! -d "$FIXTURE/App/output"
if grep -q -- '--arch' "$TEST_DIR/swift-arguments"; then
  echo 'UNIVERSAL=0 不应编译通用版' >&2; exit 1
fi
# 调试版保留符号表、不调用 strip，本来就带路径，不做自检；顺带确认整包扫描真能查出一处路径和一处调试符号条目。
: > "$TEST_DIR/tool-calls"
CONFIG=debug OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/debug.log" 2>&1
if grep -q -e '^strip ' -e '^nm ' "$TEST_DIR/tool-calls"; then
  echo 'debug 打包不应调用 strip，也不做本机路径自检' >&2; exit 1
fi
test "$(local_paths output/VoxPalm.app | wc -l | tr -d ' ')" = 2
: > "$TEST_DIR/tool-calls"
UNIVERSAL=1 OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/universal.log" 2>&1
grep -q -- '--arch arm64 --arch x86_64' "$TEST_DIR/swift-arguments"
assert_release_stripped 通用版
: > "$TEST_DIR/codesign-arguments"
: > "$TEST_DIR/tool-calls"
SIGN_IDENTITY=fixture-identity OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/certificate.log" 2>&1
test "$(grep -c -- '--options runtime' "$TEST_DIR/codesign-arguments")" = 2
assert_release_stripped 证书签名
# 官方发布包：带私有目录、通用版、证书签名。
mkdir -p "$TEST_DIR/private"
: > "$TEST_DIR/tool-calls"
VOXPALM_PRIVATE_DIR="$TEST_DIR/private" UNIVERSAL=1 SIGN_IDENTITY=fixture-identity OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/official.log" 2>&1
assert_release_stripped 官方发布组合
# strip -S 去不掉写进程序的路径（#filePath、#file、写死的路径），strip 没生效时调试符号条目里的路径也不一定含 /Users/。
# 签名后的整包自检要拦下这些，打包失败并保留旧包。
expect_leak_rejected() {
  local name="$1" expected="$2"
  shift 2
  if env "$@" OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/leak.log" 2>&1; then
    echo "$name：包里有本机路径还打包成功了" >&2; exit 1
  fi
  if ! grep -q -F -- "$expected" "$TEST_DIR/leak.log"; then
    echo "$name：自检没有报出 $expected" >&2; cat "$TEST_DIR/leak.log" >&2; exit 1
  fi
  test "$(cat output/VoxPalm.app/Contents/MacOS/VoxPalm)" = 'new executable'
}
printf 'leaky executable\n/Users/fixture/VoxPalm/App/Sources/VoxPalm/AppConfig.swift\n' > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected 源码路径 /Users/fixture/VoxPalm/App/Sources/VoxPalm/AppConfig.swift UNIVERSAL=0
printf 'leaky executable\n/private/var/ci/VoxPalm/App/.build-private/release/VoxPalm.build/AppConfig.swift.o\n' > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected 官方版编译目录 /App/.build-private/ VOXPALM_PRIVATE_DIR="$TEST_DIR/private" UNIVERSAL=1 SIGN_IDENTITY=fixture-identity
printf 'leaky executable\ndebug-symbol /Volumes/Work/VoxPalm/App/Sources/VoxPalm/AppConfig.swift\n' > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected 调试符号条目 '调试符号条目 1 条' STRIP_KEEPS_SYMBOLS=1
# whisper 框架以外，官方 CI 的 /Users/runner/ 也算本机路径（CI 上的仓库就在那下面）。
printf 'leaky executable\n/Users/runner/work/VoxPalm/VoxPalm/App/Sources/VoxPalm/AppConfig.swift\n' > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected CI路径 /Users/runner/work/VoxPalm/VoxPalm/App/Sources/VoxPalm/AppConfig.swift UNIVERSAL=1
# 仓库和私有仓库不在 /Users/ 下时（这里的临时目录就不在），自检也要按它们的完整路径查：
# 走符号链接的路径和解析后的真实路径（临时目录的 /var 就是符号链接）都要查，目录名带中文也要查得到。
repository="$(cd "$FIXTURE" && pwd)/App/Sources/VoxPalm/AppConfig.swift"
printf 'leaky executable\n%s\n' "$repository" > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected 仓库路径 "$repository" UNIVERSAL=0
repository="$(cd "$FIXTURE" && pwd -P)/App/Sources/VoxPalm/AppConfig.swift"
printf 'leaky executable\n%s\n' "$repository" > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected 仓库真实路径 "$repository" UNIVERSAL=0
mkdir -p "$TEST_DIR/外置盘/private"
private_source="$(cd "$TEST_DIR/外置盘/private" && pwd)/Sources/Adapter.swift"
printf 'leaky executable\n%s\n' "$private_source" > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected 私有仓库路径 "$private_source" VOXPALM_PRIVATE_DIR="$TEST_DIR/外置盘/private"
# 读不了的文件、扫描出错都当成查到；没能查完也要失败并保留旧包。
printf 'leaky executable\n' > "$TEST_DIR/products/VoxPalm"
expect_leak_rejected 读不了的文件 '读不了：./Contents/Resources/THIRD-PARTY-NOTICES.md' UNREADABLE_AFTER_SIGN=1
expect_leak_rejected 扫描出错 '读不了：./Contents/Resources/THIRD-PARTY-NOTICES.md' GREP_FAILS=1
expect_leak_rejected 没能查完 '自检没能查完' FIND_FAILS=1
if UNIVERSAL=invalid OUTPUT_DIR=output bash "$FIXTURE/scripts/build-app.sh" > "$TEST_DIR/invalid.log" 2>&1; then
  echo '无效的 UNIVERSAL 应返回失败' >&2; exit 1
fi
test -z "$(find output -name '.voxpalm-build.*' -print)"
echo '打包回归通过：失败保留旧包、成功替换、相对路径、release 去调试符号且整包无本机路径、签名后自检拦下本机路径并保留旧包、通用版开关、临时与证书签名选项、临时文件清理。'
