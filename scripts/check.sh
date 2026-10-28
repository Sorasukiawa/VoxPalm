#!/bin/bash
# 开源仓库的日常检查；不启动 App、不申请权限、不连接控制设备。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset VOXPALM_PRIVATE_DIR
JOBS="${SWIFT_JOBS:-2}"
# bash -n 一次只查一个文件，后面的会被当成参数。
for script in scripts/build-app.sh scripts/lib/local-paths.sh scripts/tests/build-app.sh scripts/check.sh; do
  bash -n "$script"
done
plutil -lint App/Info.plist App/VoxPalm.entitlements
bash scripts/tests/build-app.sh
swift test --package-path Packages/VoxPalmCore --jobs "$JOBS"
swift test --package-path tools/probe --jobs "$JOBS"
swift test --package-path App --jobs "$JOBS"

# 无效命令必须在开麦/开始监听之前返回失败，不能崩溃、卡住或当成默认时长。
PROBE="$(swift build --package-path tools/probe --show-bin-path)/voxpalm-probe"
for command in audio watch; do
  for value in nan inf -1 0 invalid 1e15; do
    result=0
    "$PROBE" "$command" --seconds "$value" || result=$?
    if [[ "$result" != 1 ]]; then
      echo "探针 $command --seconds $value 应返回 1，实际是 $result" >&2
      exit 1
    fi
  done
  result=0
  "$PROBE" "$command" --seconds || result=$?
  test "$result" = 1
done
echo '开源版日常检查通过。真实设备与转写效果需要另外验收。'
