#!/usr/bin/env bash
# 把发布签名（release.jks + key.properties）打包成「一个文件」，用于：
#   1) 填入仓库唯一的签名 Secret：SIGNING_BUNDLE_BASE64
#   2) 离线备份（该文件即密钥的全部，务必妥善保存）
#
# 用法：
#   bash tool/pack_signing.sh                 # 默认输出到 ../_private/contact_flutter-signing.bundle
#   bash tool/pack_signing.sh /path/out.bundle
#
# 文件格式：base64( tar.gz( release.jks, key.properties ) )——纯文本，可直接复制粘贴。
set -euo pipefail

cd "$(dirname "$0")/.."   # 仓库根目录（contact_flutter/）
OUT="${1:-../_private/contact_flutter-signing.bundle}"

if [[ ! -f android/release.jks ]]; then
  echo "缺少 android/release.jks（发布密钥库）" >&2
  exit 1
fi
if [[ ! -f android/key.properties ]]; then
  echo "缺少 android/key.properties（签名配置）" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
tar -czf - -C android release.jks key.properties | base64 -w0 > "$OUT"

echo "已生成：$OUT  ($(wc -c < "$OUT") 字节)"
echo
echo "接下来：仓库 → Settings → Secrets and variables → Actions → Secrets → New repository secret"
echo "  名称：SIGNING_BUNDLE_BASE64"
echo "  值  ：上面这个文件的全文本（cat \"$OUT\" 复制）"
