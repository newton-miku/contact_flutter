#!/usr/bin/env bash
# 由 tag 推导版本名与 versionCode —— 发布链路的唯一换算入口。
#
# 约定（发版只需推一个 tag，pubspec 的 version 退化为开发期占位值）：
#   tag          v1.0.0
#   versionName  1.0.0
#   versionCode  MAJOR*10000 + MINOR*100 + PATCH = 10000
# 约束：MINOR / PATCH 必须 < 100（各占两位），否则会进位串位。
#
# 与 Dart 端 lib/services/app_update.dart 的 _versionCodeOf 必须保持一致；
# 两处都改了才算改完。
#
# 用法：
#   bash tool/derive_version.sh v1.0.0                     # 给人看
#   bash tool/derive_version.sh v1.0.0 --github-env        # 输出 GITHUB_ENV 格式
#   bash tool/derive_version.sh v1.0.0 --github-env >> "$GITHUB_ENV"
# 不给 tag 时按 GITHUB_REF_TYPE / GITHUB_REF / GITHUB_REF_NAME 推断（CI 里够用）。
set -euo pipefail

die() {
    echo "错误：$*" >&2
    exit 1
}

TAG=""
MODE="print"
for arg in "$@"; do
    case "$arg" in
        --github-env) MODE="github-env" ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            die "未知参数：$arg（可用：--github-env）"
            ;;
        *)
            [ -z "$TAG" ] || die "只接受一个 tag 参数，收到两个：$TAG / $arg"
            TAG="$arg"
            ;;
    esac
done

# 未显式给 tag 时从 CI 环境推断
if [ -z "$TAG" ]; then
    if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
        TAG="$GITHUB_REF_NAME"
    elif [ -n "${GITHUB_REF:-}" ]; then
        TAG="${GITHUB_REF#refs/tags/}"
    else
        TAG="${GITHUB_REF_NAME:-}"
    fi
fi

[ -n "$TAG" ] || die "没拿到 tag。请显式传入，例如：bash tool/derive_version.sh v1.0.0"

case "$TAG" in
    v*) ;;
    *) die "tag 必须以 v 开头（如 v1.0.0），当前为：$TAG" ;;
esac

VER="${TAG#v}"
if ! printf '%s' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "tag 必须是 vX.Y.Z 形式（如 v1.0.0），当前为：$TAG"
fi

MAJOR="${VER%%.*}"
REST="${VER#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

for seg in "$MINOR" "$PATCH"; do
    if [ "$seg" -gt 99 ]; then
        die "MINOR/PATCH 必须 < 100（versionCode 各占两位），$VER 里的 $seg 超了。
  版本号规则：versionCode = MAJOR*10000 + MINOR*100 + PATCH
  想发大版本请进位到 MAJOR，例如 $((MAJOR + 1)).0.0"
    fi
done

CODE=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))

if [ "$MODE" = "github-env" ]; then
    # 写进 $GITHUB_ENV 后，后续步骤可直接用 $TAG / $APP_VER / $APP_CODE
    echo "TAG=$TAG"
    echo "APP_VER=$VER"
    echo "APP_CODE=$CODE"
else
    echo "tag         : $TAG"
    echo "versionName : $VER"
    echo "versionCode : $CODE"
fi
