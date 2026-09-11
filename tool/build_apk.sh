#!/usr/bin/env bash
# 打 Android 发布包，产物直接落到 ../_release/。
#
# ABI 拆分（与 CI 一致）：
#   默认      → 只打 arm（armeabi-v7a + arm64-v8a），文件名带包名后缀，如
#               _release/contact_flutter_demo.apk
#   --x86     → 额外再打一个只含 x86_64 的包（模拟器用），文件名加 _x86_64 后缀：
#               _release/contact_flutter_demo_x86_64.apk
#
# 用法：
#   API_BASE_URL=https://你的服务器 bash tool/build_apk.sh
#   API_BASE_URL=https://你的服务器 APP_ID_SUFFIX=_demo bash tool/build_apk.sh --x86
set -euo pipefail

cd "$(dirname "$0")/.."   # 仓库根目录（contact_flutter/）

WITH_X86=0
for arg in "$@"; do
  case "$arg" in
    --x86) WITH_X86=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（可用：--x86）" >&2; exit 2 ;;
  esac
done

if [[ -z "${API_BASE_URL:-}" ]]; then
  echo "缺少 API_BASE_URL，例如：API_BASE_URL=https://你的服务器 bash tool/build_apk.sh" >&2
  exit 1
fi
if [[ ! -f android/key.properties ]]; then
  echo "缺少 android/key.properties（发布签名），release 打包会被 Gradle 拒绝。" >&2
  exit 1
fi

APP_VERSION=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
BUILD_TIME=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
OUT_DIR="../_release"
APK="build/app/outputs/flutter-apk/app-release.apk"
# 发布线后缀（只影响文件名，包名后缀由 Gradle 读 APP_ID_SUFFIX 决定）
NAME="contact_flutter${APP_ID_SUFFIX:-}"

mkdir -p "$OUT_DIR"

# 参数：$1 = --target-platform 的值，$2 = 文件名后缀（默认包为空）
build_apk() {
  echo "==> flutter build apk --target-platform $1"
  flutter build apk --release \
    --target-platform "$1" \
    --dart-define=API_BASE_URL="$API_BASE_URL" \
    --dart-define=APP_VERSION="$APP_VERSION" \
    --dart-define=BUILD_TIME="$BUILD_TIME"

  local dst="$OUT_DIR/${NAME}$2.apk"
  cp "$APK" "$dst"
  local abis
  abis=$(unzip -l "$dst" | grep -o 'lib/[^/]*' | sed 's|lib/||' | sort -u | tr '\n' ' ')
  echo "==> $dst  $(du -h "$dst" | cut -f1)  含 ABI: ${abis:-无}"
}

build_apk "android-arm,android-arm64" ""
if [[ "$WITH_X86" == "1" ]]; then
  build_apk "android-x64" "_x86_64"
fi

echo
echo "完成。安装到手机：adb install -r $OUT_DIR/${NAME}.apk"
