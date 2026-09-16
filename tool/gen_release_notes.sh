#!/usr/bin/env bash
# 依据提交历史自动生成 Release 说明（按 conventional commit 前缀分组为中文小节）。
#
# 在 Actions 的 release 作业里调用（需要完整历史 + 全部 tag）：
#   - uses: actions/checkout@v7
#     with:
#       fetch-depth: 0   # 探测"上一个 tag"与跨 tag 比对提交都要完整历史
#   - run: bash tool/gen_release_notes.sh > release_notes.md
#
# 手动测试：GITHUB_REF_NAME=v1.0.0 bash tool/gen_release_notes.sh
#
# 分组规则（提交标题格式 `type(scope): 标题`）：
#   feat→新功能  fix→问题修复  perf→性能优化  build/ci→构建与 CI  docs→文档
#   其余（refactor/style/test/chore、无前缀）→其他变更
#   条目渲染为 "- **scope**：标题"，无 scope 时只留标题。
# 区间：上一个 tag（按创建时间、排除当前 tag）..当前提交；无上一个 tag 则取全部历史。
set -euo pipefail

TAG="${GITHUB_REF_NAME:?GITHUB_REF_NAME 未设置}"

# 上一个 tag：当前提交可达的 tag 按创建时间倒序，排除当前 tag 后取第一个。
# 首个 tag 时 PREV 为空 → 用全部历史。
PREV=$(git tag --sort=-creatordate --merged HEAD | grep -Fxv -- "$TAG" | head -1 || true)

if [[ -n "$PREV" ]]; then
  RANGE="$PREV..HEAD"
else
  RANGE="HEAD"
fi
COUNT=$(git rev-list --count --no-merges "$RANGE")

declare -A SECTS=()
while IFS= read -r subject; do
  [[ -z "$subject" ]] && continue
  # 兼容 `feat!:` / `feat(ui)!:` 的感叹号形式（breaking change 标记）
  if [[ "$subject" =~ ^([A-Za-z]+)(\(([^\)]*)\))?(!)?:\ (.*)$ ]]; then
    type="${BASH_REMATCH[1]}"
    scope="${BASH_REMATCH[3]}"
    rest="${BASH_REMATCH[5]}"
  else
    type=""; scope=""; rest="$subject"
  fi
  case "$type" in
    feat)     sec="✨ 新功能" ;;
    fix)      sec="🐛 问题修复" ;;
    perf)     sec="⚡ 性能优化" ;;
    build|ci) sec="🔧 构建与 CI" ;;
    docs)     sec="📄 文档" ;;
    *)        sec="📦 其他变更" ;;
  esac
  if [[ -n "$scope" ]]; then
    SECTS["$sec"]+="- **${scope}**：${rest}"$'\n'
  else
    SECTS["$sec"]+="- ${rest}"$'\n'
  fi
done < <(git log --no-merges --format=%s "$RANGE")

BODY=""
for sec in "✨ 新功能" "🐛 问题修复" "⚡ 性能优化" "🔧 构建与 CI" "📄 文档" "📦 其他变更"; do
  items="${SECTS["$sec"]:-}"
  [[ -n "$items" ]] || continue
  BODY+="### ${sec}"$'\n'"${items}"$'\n'
done

if [[ "$COUNT" -eq 0 ]]; then
  BODY="本次发布无新提交。"$'\n'
fi

{
  if [[ -n "$PREV" ]]; then
    echo "自 \`${PREV}\` 以来 ${COUNT} 个提交："
  else
    echo "首个发布，共 ${COUNT} 个提交："
  fi
  echo
  echo "$BODY"
}
# 这里刻意【不】输出 "完整变更列表：<GitHub 对比链接>"。
# 说明会被发布到 GitCode 公开仓，而那个链接指向私有仓：
#   1) 对外是 404，点了没用
#   2) 等于把私有仓的 owner/repo 公开出去，正是"公私两仓"要避免的
# 所以任何情况下都不要往这些说明里拼仓库地址。
