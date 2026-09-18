#!/usr/bin/env bash
# 打 Linux 桌面包（.deb），产物落到 ../_release/。
#
# ⚠️ 本脚本属于 linux-uos 分支：专为 UOS Desktop 20 / glibc 2.28 维护。
#    只支持 Flutter 3.10.x —— 更新的引擎要求 glibc ≥ 2.31，在 UOS 20 上装不起来。
#    脚本会自己校验版本，不满足直接拒绝（编出装不上的包比不编更糟）。
#
# 目标环境：UOS / Deepin / 麒麟 等 Debian 系国产系统，arm64 与 amd64 均可。
#
# 重要：Flutter 的 Linux 桌面版【不支持从 Windows 交叉编译到 arm64】。
#       必须在 Linux 上原生构建；给 UOS arm64 出包有两种可行做法：
#         a) 直接在 UOS arm64 机器上构建（最简单，推荐）
#         b) 在开发机上用 arm64 容器/虚拟机原生构建（qemu 也能跑，但慢）
#       脚本会自动检测宿主架构，与 --arch 不一致时直接报错，不会产出错误架构的包。
#
# 用法：
#   API_BASE_URL=https://你的服务器 bash tool/build_deb.sh
#   API_BASE_URL=https://你的服务器 bash tool/build_deb.sh --arch arm64
#   bash tool/build_deb.sh --arch arm64 --skip-build    # 复用已有 build/linux 产物，只重新打包
#   TAG=v1.0.1 API_BASE_URL=https://... bash tool/build_deb.sh
#       指定 tag 时版本号由它推导（与 CI 用同一个换算脚本），
#       不指定则回退 pubspec.yaml 里的 version（开发期占位值）。
set -euo pipefail

cd "$(dirname "$0")/.."   # 仓库根目录（contact_flutter/）

# ---------------- 参数 ----------------
ARCH=""                  # 留空 = 用宿主架构
SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch=*)     ARCH="${1#--arch=}" ;;
    --arch)       ARCH="${2:-}"; shift ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（可用：--arch <arm64|amd64>、--skip-build）" >&2; exit 2 ;;
  esac
  shift
done

# ---------------- 基础检查 ----------------
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "错误：Flutter Linux 桌面版只能在 Linux 上构建（当前：$(uname -s)）。" >&2
  echo "      Windows/macOS 无法交叉编译出 Linux 包，请用 UOS 机器或 WSL2/Linux 容器。" >&2
  exit 1
fi
command -v flutter >/dev/null 2>&1 || { echo "错误：找不到 flutter，请先装 Flutter SDK 并加入 PATH。" >&2; exit 1; }

# Flutter 版本闸门。
#
# 为什么卡死在 3.10.x：Flutter 的 Linux 桌面引擎是预编译的，它链的 glibc
# 决定产物能跑在什么系统上。3.10.x 之后引擎要求 glibc ≥ 2.31，
# 而 UOS Desktop 20 是 Debian 10 底子、glibc 只有 2.28
# → 编出来的包能装上但起不来（或被依赖检查直接拒）。
#
# 这里主动拦一道：与其编出一个装不上的 deb，不如当场说清楚。
FLUTTER_VER="$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
case "${FLUTTER_VER:-}" in
  3.10.*) echo "==> Flutter $FLUTTER_VER（符合 UOS 20 的 glibc 2.28 要求）" ;;
  *)
    echo "错误：本分支只支持 Flutter 3.10.x，当前是 ${FLUTTER_VER:-未知}。" >&2
    echo "      UOS Desktop 20 的 glibc 是 2.28；更新的 Flutter 引擎要求 glibc ≥ 2.31，" >&2
    echo "      产物在 UOS 上装不起来，所以这里直接拒绝。" >&2
    echo "      装 3.10.6：" >&2
    echo "        curl -LO https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_3.10.6-stable.tar.xz" >&2
    echo "        tar xf flutter_linux_3.10.6-stable.tar.xz -C ~/ && export PATH=\"\$HOME/flutter/bin:\$PATH\"" >&2
    echo "      确认：flutter --version 应显示 3.10.6" >&2
    exit 1 ;;
esac

# 平台目录残留检查。
#
# 本分支没有 android/ios/macos/windows 工程。但如果你之前在 main 上工作过，
# 切分支时这些目录里【未跟踪】的残留（gradlew、签名配置、ephemeral/ 等）会留在磁盘上，
# 于是目录还在、里面的工程文件却没了。
#
# 这会让 Flutter 3.10 走进一条很坑的路径：它的 isUsingGradle 只看
# `android/build.gradle`（不认 .kts），判定"没用 Gradle"后转去读
# `android/AndroidManifest.xml`——文件不存在 → 判成 v1 Android 嵌入 →
# pub get 直接失败并报「请把 App 迁移到 v2 嵌入」，和真实原因毫无关系。
#
# 与其让人去猜那句话，不如在这里直接说清楚。
RESIDUE=""
for d in android ios macos windows; do
  [[ -d "$d" ]] && RESIDUE="${RESIDUE} ${d}"
done
if [[ -n "$RESIDUE" ]]; then
  echo "错误：检测到残留的平台目录：${RESIDUE}" >&2
  echo "      本分支只需要 linux/。Flutter 3.10 见到 android/ 却找不到 build.gradle 时，" >&2
  echo "      会误判成 v1 Android 嵌入，pub get 会报一句和真因无关的" >&2
  echo "      「requires your app to be migrated to the Android embedding v2」。" >&2
  echo "      处理：rm -rf android ios macos windows" >&2
  echo "      ⚠️ android/key.properties 与 android/release.jks 是未跟踪文件，删前请自行备份。" >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64) HOST_DEB_ARCH="arm64" ;;
  x86_64|amd64)  HOST_DEB_ARCH="amd64" ;;
  *) echo "错误：不支持的宿主架构 $HOST_ARCH。" >&2; exit 1 ;;
esac

if [[ -z "$ARCH" ]]; then
  ARCH="$HOST_DEB_ARCH"
elif [[ "$ARCH" == "aarch64" ]]; then
  ARCH="arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
  ARCH="amd64"
fi

if [[ "$ARCH" != "$HOST_DEB_ARCH" ]]; then
  cat >&2 <<EOF
错误：请求的目标架构 ($ARCH) 与宿主架构 ($HOST_DEB_ARCH) 不一致。

Flutter Linux 桌面版是原生编译，不支持从 $HOST_DEB_ARCH 交叉编译到 $ARCH。
请改用以下任一方式：
  1. 直接在目标架构的机器上运行本脚本（UOS $ARCH 机器上是原生的）；
  2. 在开发机上跑 $ARCH 的容器/虚拟机（如 docker run --platform linux/$ARCH ...）后在其中构建；
  3. 交叉编译需要自备 $ARCH 的 GTK3 开发库与工具链，并把 CMAKE_SYSROOT 指过去，本脚本不负责这层。
EOF
  exit 1
fi

# ---------------- GTK3 开发依赖 ----------------
if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
  echo "==> 缺少 GTK3 开发库，尝试安装（需要 sudo，或请手动装）"
  if command -v apt-get >/dev/null 2>&1; then
    # UOS/Debian 系包名：libgtk-3-dev（部分国产系统旧源里叫 libgtk-3-dev 之外的名字，故两个都试）
    sudo apt-get update -qq || true
    sudo apt-get install -y libgtk-3-dev pkg-config cmake ninja-build clang || {
      echo "自动安装失败，请手动安装：libgtk-3-dev pkg-config cmake ninja-build clang" >&2; exit 1; }
  else
    echo "未找到 apt-get，请手动安装 GTK3 开发库（gtk+-3.0.pc）后重试。" >&2
    exit 1
  fi
fi
pkg-config --exists gtk+-3.0 || { echo "错误：gtk+-3.0 仍不可用。" >&2; exit 1; }

# ---------------- 版本与元信息 ----------------
API_BASE_URL="${API_BASE_URL:-}"
if [[ -z "$API_BASE_URL" && "$SKIP_BUILD" == "0" ]]; then
  echo "缺少 API_BASE_URL，例如：API_BASE_URL=https://你的服务器 bash tool/build_deb.sh" >&2
  exit 1
fi

# 版本号必须来自 tag，且与 Android / Windows 同源。
#
# 绝不回退到 pubspec 里的开发期占位值（那是 0.0.0）：
# 桌面端的 PackageInfo 读的是 bundle 里 flutter_assets/version.json，
# 由构建时的 --build-name/--build-number 决定；不注入就会固定成占位值，
# 用户装了新版仍被提示"发现新版本"，而且同一个版本在不同平台会对不上。
if [[ -z "${TAG:-}" ]]; then
  echo "错误：必须指定 TAG，例如" >&2
  echo "  TAG=v1.0.1 API_BASE_URL=https://你的服务器 bash tool/build_deb.sh --arch arm64" >&2
  echo "（版本换算由 tool/derive_version.sh 统一完成，与 CI 完全一致）" >&2
  exit 1
fi
while IFS='=' read -r _k _v; do
  case "$_k" in
    TAG) TAG="$_v" ;;
    APP_VER) APP_VER="$_v" ;;
    APP_CODE) APP_CODE="$_v" ;;
  esac
done < <(bash tool/derive_version.sh "$TAG" --github-env)
APP_VERSION="$APP_VER"
VERSION_ARGS=(--build-name="$APP_VER" --build-number="$APP_CODE")
BUILD_TIME="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
SHA_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

BUNDLE_DIR="build/linux/$HOST_ARCH/release/bundle"
OUT_DIR="../_release"
PKG_NAME="contact_flutter"
# deb 版本用版本名即可（Debian 的版本比较能正确处理 1.0.1 < 1.0.2）
DEB_NAME="${PKG_NAME}_${APP_VERSION}_${ARCH}.deb"
STAGE="build/deb-stage"

echo "==> 目标架构：$ARCH（宿主 $HOST_ARCH）"
echo "==> 版本：$APP_VERSION（versionCode $APP_CODE）   提交：$SHA_SHORT"

# ---------------- 1. 构建 ----------------
if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "==> 跳过构建，复用 $BUNDLE_DIR"
  [[ -d "$BUNDLE_DIR" ]] || { echo "错误：$BUNDLE_DIR 不存在，不能 --skip-build。" >&2; exit 1; }
else
  echo "==> flutter build linux --release"
  flutter build linux --release \
    "${VERSION_ARGS[@]}" \
    --dart-define=API_BASE_URL="$API_BASE_URL" \
    --dart-define=APP_VERSION="$SHA_SHORT" \
    --dart-define=BUILD_TIME="$BUILD_TIME"
fi

[[ -x "$BUNDLE_DIR/$PKG_NAME" ]] || { echo "错误：未找到 $BUNDLE_DIR/$PKG_NAME" >&2; exit 1; }

# ---------------- 2. 组织 deb 目录树 ----------------
echo "==> 组装包目录 $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/opt/$PKG_NAME" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/256x256/apps"

# 2.1 应用本体：bundle 内容进 /opt/<pkg>/
cp -a "$BUNDLE_DIR/." "$STAGE/opt/$PKG_NAME/"

# 2.2 可执行文件改名，原二进制加 .bin；用启动包装脚本占住这个名字
mv "$STAGE/opt/$PKG_NAME/$PKG_NAME" "$STAGE/opt/$PKG_NAME/$PKG_NAME.bin"
install -m 0755 "packaging/linux/$PKG_NAME.launcher" "$STAGE/opt/$PKG_NAME/$PKG_NAME"

# 2.3 桌面入口
install -m 0644 "packaging/linux/$PKG_NAME.desktop" \
  "$STAGE/usr/share/applications/$PKG_NAME.desktop"

# 2.4 图标：优先用仓库里最大的 launcher 图（Android xxxhdpi 那版）
ICON_SRC=""
for c in android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png \
         android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png \
         android/app/src/main/res/mipmap-xhdpi/ic_launcher.png; do
  [[ -f "$c" ]] && { ICON_SRC="$c"; break; }
done
if [[ -n "$ICON_SRC" ]]; then
  install -m 0644 "$ICON_SRC" "$STAGE/usr/share/icons/hicolor/256x256/apps/$PKG_NAME.png"
  echo "    图标来源：$ICON_SRC"
else
  echo "    警告：没找到图标 png，桌面条目可能显示为空白图标。"
fi

# 2.5 DEBIAN 元数据
SIZE_KB="$(du -sk "$STAGE" | cut -f1)"
sed -e "s/@VERSION@/$APP_VERSION/g" \
    -e "s/@ARCH@/$ARCH/g" \
    -e "s/@SIZE@/$SIZE_KB/g" \
    "packaging/linux/control.in" > "$STAGE/DEBIAN/control"
install -m 0755 packaging/linux/postinst "$STAGE/DEBIAN/postinst"
install -m 0755 packaging/linux/prerm    "$STAGE/DEBIAN/prerm"

# ---------------- 3. 产出 deb ----------------
mkdir -p "$OUT_DIR"
( cd "$STAGE" && find . -type f -print0 | xargs -0 md5sum > DEBIAN/md5sums )

echo "==> dpkg-deb --build"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT_DIR/$DEB_NAME"

echo
echo "==> 完成：$OUT_DIR/$DEB_NAME"
dpkg-deb --info "$OUT_DIR/$DEB_NAME" | sed -n '1,12p'
echo
echo "安装（在目标机器上）："
echo "  sudo dpkg -i $DEB_NAME   ||  sudo apt-get -f install"
echo "卸载：sudo dpkg -r contact-flutter"
