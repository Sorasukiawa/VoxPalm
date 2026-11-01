#!/bin/bash
# 照 REVIEW.md 的查法扫整包里的本机路径，每处一行，没查到就什么也不输出；没能查完返回非 0。
# 打包脚本签名后的自检和打包回归测试共用，手动查安装包也用它：bash scripts/lib/local-paths.sh VoxPalm.app [额外关键字...]
# 额外关键字是 /Users/ 和 .build 之外也要查的串（打包脚本传本仓库和私有仓库的完整路径，以及私有模块的「模块/」前缀）。
set -uo pipefail
if [[ $# -lt 1 || ! -d "$1" ]]; then
  echo "用法：$0 <App 目录> [额外关键字...]" >&2
  exit 2
fi
cd "$1" || exit 2
shift
PATTERNS=(-e /Users/ -e .build)
for extra in "$@"; do
  if [[ -n "$extra" ]]; then PATTERNS+=(-e "$extra"); fi
done
# 先用 nm -pa 看主程序的调试符号条目：发布包里应该一条都没有，条目里的路径不一定含上面的关键字。
# 通用版要带 -arch all，不然只看本机那一个架构。放在最前面输出，免得查到的路径太多时被打包脚本截掉。
for file in ./Contents/MacOS/*; do
  [[ -f "$file" ]] || continue
  if ! count="$(nm -pa -arch all "$file" | LC_ALL=C awk '/^[0-9a-f]+ - [0-9a-f][0-9a-f] [0-9a-f][0-9a-f][0-9a-f][0-9a-f] / { n++ } END { print n + 0 }')"; then
    printf 'nm 读不了：%s\n' "$file"; continue
  fi
  if (( count > 0 )); then printf '调试符号条目 %s 条：%s\n' "$count" "$file"; fi
done
# 再按字节找含这些关键字的可打印串：strip -S 去不掉写进程序的 #filePath、#file 和写死的路径，靠这一步查。
# 中文等非 ASCII 字节不当分隔符，不然含中文的路径会被切断、对不上额外关键字。
# whisper 框架里官方 CI 留下的 /Users/runner/ 不算，读不了的文件也算一处。
find . -type f -print0 | while IFS= read -r -d '' file; do
  if [[ ! -r "$file" ]]; then printf '读不了：%s\n' "$file"; continue; fi
  LC_ALL=C grep -a -F "${PATTERNS[@]}" -- "$file" | LC_ALL=C tr -c '[:print:]\200-\377' '\n' | LC_ALL=C grep -F "${PATTERNS[@]}" |
    { if [[ "$file" == */whisper.framework/* ]]; then grep -v -F /Users/runner/; else cat; fi; }
  if (( PIPESTATUS[0] > 1 )); then printf '读不了：%s\n' "$file"; fi
done || exit 1
