#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
复核 GitCode 公开仓的 Release 是否真能被【免鉴权】使用。

这一步存在的意义：App 端的"检查更新"与用户下载安装包走的都是匿名路径，
发布脚本自己跑成功 ≠ 别人能读到、能下到。所以发布后必须复验：

  1) /releases 匿名可读、能解析出版本名与 Version-Code
  2) 各平台产物（Android 默认包 / x86_64 包 / Windows zip）匿名能真正下载到
     （只取头部 64 字节验证；type=source 的源码归档不算产物）
  3) 本次发布的 tag（环境变量 TAG）里三类产物是否齐全
  4) 提醒哪些附件名带 '+'（会导致下载 404，必须改名）

退出码：0 = 可被匿名使用；1 = 有问题（App 端会表现为"没有正式版本"或下载失败）
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def require_env():
    """
    从环境变量取目标仓库坐标（脚本里不写死 owner/repo）。
    缺失时直接报错并说明怎么设，避免静默连到错误的仓库。
    """
    owner = os.environ.get("GITCODE_OWNER", "").strip()
    repo = os.environ.get("GITCODE_REPO", "").strip()
    missing = [n for n, v in (("GITCODE_OWNER", owner), ("GITCODE_REPO", repo)) if not v]
    if missing:
        print("错误：缺少环境变量 %s" % "、".join(missing), file=sys.stderr)
        print("  例如：GITCODE_OWNER=<用户名或组织> GITCODE_REPO=<仓库名>", file=sys.stderr)
        sys.exit(2)
    return owner, repo


API = os.environ.get("GITCODE_API_BASE", "https://api.gitcode.com/api/v5").rstrip("/")


def anonymous_get(url, extra_headers=None, timeout=30):
    headers = {"User-Agent": "contact_flutter-release-check"}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, headers=headers)
    return urllib.request.urlopen(req, timeout=timeout)


def main():
    owner, repo = require_env()
    url = "%s/repos/%s/%s/releases" % (API, owner, repo)
    try:
        with anonymous_get(url) as r:
            rels = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("复核失败：HTTP %d %s" % (e.code, e.read().decode("utf-8", "replace")[:200]))
        return 1
    except Exception as e:
        print("复核失败：%s: %s" % (type(e).__name__, e))
        return 1

    if not isinstance(rels, list) or not rels:
        print("⚠ /releases 匿名可读，但列表为空：App 会显示「远端还没有正式版本记录」")
        return 1

    print("匿名可读 Release 数：%d" % len(rels))
    problems = []

    # 只对"本次刚发布的那个 tag"做完整性要求：历史版本（例如只有 APK 的 v1.0.0）
    # 不该让复核永远失败。CI 里由发布作业把 TAG 传进来。
    expect_tag = os.environ.get("TAG", "").strip()
    if expect_tag:
        print("本次发布的 tag：%s（对它做完整性校验）" % expect_tag)

    for rel in rels[:5]:
        tag = rel.get("tag_name")
        body = rel.get("body") or ""
        cm = re.search(r"^Version-Code:\s*(\d+)\s*$", body, re.M)
        notes_len = len(re.sub(r"^Version.*\n", "", body, flags=re.M).strip())
        print()
        print("  %-12s 版本说明 %4d 字   Version-Code: %s"
              % (tag, notes_len, cm.group(1) if cm else "缺（App 只能按版本名比较）"))
        if not cm:
            problems.append("%s 正文缺少 Version-Code 行" % tag)

        assets = rel.get("assets") or []
        # type=source 是平台自动附的源码归档，不是产物。App 端也会排除它们
        # （其中还有个与 tag 同名的 .zip），所以这里同样不能拿它当"有包"。
        attach = [a for a in assets if str(a.get("type")) != "source"]
        sources = [a for a in assets if str(a.get("type")) == "source"]
        print("    附件 %d 个：产物 %d 个，源码归档 %d 个"
              % (len(assets), len(attach), len(sources)))

        kinds = {"默认包(arm+arm64)": [], "x86_64(模拟器)": [], "Windows(zip)": []}
        for a in attach:
            low = str(a.get("name", "")).lower()
            if low.endswith(".apk"):
                key = "x86_64(模拟器)" if "x86_64" in low else "默认包(arm+arm64)"
                kinds[key].append(a)
            elif low.endswith(".zip"):
                kinds["Windows(zip)"].append(a)

        strict = bool(expect_tag) and tag == expect_tag
        if expect_tag and not strict:
            for label, items in kinds.items():
                if items:
                    print("      %-18s %s"
                          % (label, ", ".join(str(a.get("name")) for a in items)))
            continue

        for label, items in kinds.items():
            if not items:
                print("      %-18s 【缺】" % label)
                if strict:
                    problems.append("%s 缺少 %s" % (tag, label))
                continue
            for a in items:
                name = str(a.get("name"))
                if "+" in name:
                    problems.append("%s 的附件名含 '+'（下载会 404）：%s" % (tag, name))
                    print("      %-18s %s 名字含 '+' -> 匿名下载会 404" % (label, name))
                    continue
                u = a.get("browser_download_url")
                try:
                    with anonymous_get(u, {"Range": "bytes=0-63"}) as r:
                        data = r.read()
                    ok = len(data) > 0
                    print("      %-18s %-42s HTTP %d，取到 %3d 字节 %s"
                          % (label, name, r.status, len(data), "OK" if ok else "空响应"))
                    if not ok:
                        problems.append("%s 的 %s 匿名下载返回空" % (tag, name))
                except urllib.error.HTTPError as e:
                    problems.append("%s 的 %s 匿名下载失败 HTTP %d" % (tag, name, e.code))
                    print("      %-18s %-42s 匿名下载 HTTP %d %s"
                          % (label, name, e.code, e.reason))
                except Exception as e:
                    problems.append("%s 的 %s 匿名下载异常 %s" % (tag, name, e))
                    print("      %-18s %-42s 匿名下载异常 %s" % (label, name, e))

    print()
    if problems:
        print("发现 %d 个问题：" % len(problems))
        for p in problems:
            print("  - " + p)
        return 1
    print("✅ 匿名可读且可下载，App 端能正常判断更新")
    if expect_tag:
        print("   %s 的三类产物齐全（Android 默认包 / x86_64 / Windows zip）" % expect_tag)
    else:
        print("   提示：设置环境变量 TAG 可对指定版本做产物完整性校验")
    print("   仓库页面：https://gitcode.com/%s/%s/releases" % (owner, repo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
