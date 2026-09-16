#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把一次正式版本发布到 GitCode 的公开仓库（changelog + APK 分发）。

为什么用 GitCode 而不是私有开发仓库：
  开发仓库是私有的（代码与服务器地址不外泄），而更新分发必须公开可读。
  所以约定：公私两仓，版本号/tag 对齐；
    私有仓 = 开发主干，公开仓 = 只放 CHANGELOG 与 Release 附件（APK）。

目标仓库坐标不写死在本脚本里，全部来自环境变量（见下），
因此换仓库/换账号无需改代码。

用法：
    # 先设好坐标（换仓库只改这两行）
    export GITCODE_OWNER=<用户名或组织>
    export GITCODE_REPO=<仓库名>
    export GITCODE_TOKEN=<访问令牌>

    # 1) 只校验，不真发（推荐先跑这个）
    python tool/release_gitcode.py --version 1.0.0 --dry-run

    # 2) 正式发布：取 CHANGELOG 说明 + 上传 APK + 建 Release
    python tool/release_gitcode.py --version 1.0.0 --apk ../_release/contact_flutter_1.0.0_arm.apk

    # 3) 只上传附件（Release 已存在，例如补传）
    python tool/release_gitcode.py --version 1.0.0 --apk ... --skip-create

    # 4) 只产出 Release 正文，交给 CI 里的上传 action
    python tool/release_gitcode.py --version 1.0.0 --apk ... --emit-body body.md

环境变量：
    GITCODE_OWNER    必填，公开仓所属用户名/组织（如 newton-miku）
    GITCODE_REPO     必填，公开仓仓库名（如 contact_shiquan）
    GITCODE_TOKEN    必填（除 --dry-run / --emit-body），个人访问令牌，需仓库写权限
    GITCODE_API_BASE 可选，默认 https://api.gitcode.com/api/v5

App 端查询用的是【免鉴权】接口（实测可读）：
    GET $GITCODE_API_BASE/repos/$GITCODE_OWNER/$GITCODE_REPO/releases
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

API = os.environ.get("GITCODE_API_BASE", "https://api.gitcode.com/api/v5").rstrip("/")
TOKEN = os.environ.get("GITCODE_TOKEN", "").strip()


def require_env():
    """
    从环境变量取目标仓库坐标。

    刻意【不设默认值】：仓库地址属于部署信息，写死在脚本里就意味着
    换仓库/换账号必须先改代码。缺的时候直接报错并说明怎么设。
    """
    owner = os.environ.get("GITCODE_OWNER", "").strip()
    repo = os.environ.get("GITCODE_REPO", "").strip()
    missing = [n for n, v in (("GITCODE_OWNER", owner), ("GITCODE_REPO", repo)) if not v]
    if missing:
        print("错误：缺少环境变量 %s" % "、".join(missing), file=sys.stderr)
        print("  它们指向发布目标仓库，例如：", file=sys.stderr)
        print("    GITCODE_OWNER=<用户名或组织>  GITCODE_REPO=<仓库名>", file=sys.stderr)
        sys.exit(2)
    return owner, repo


def die(msg, code=1):
    print("错误：" + msg, file=sys.stderr)
    sys.exit(code)


def http(method, url, token=None, data=None, headers=None, raw=False, expect=(200, 201)):
    """最小 HTTP 封装。token 走 private-token 头（与 GitCode 文档一致）。"""
    body = None
    hdrs = dict(headers or {})
    if data is not None:
        if raw:
            body = data
        else:
            body = json.dumps(data).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
    if token:
        hdrs["private-token"] = token
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = resp.read()
            if resp.status not in expect:
                die("HTTP %d: %s" % (resp.status, payload[:400]))
            if raw:
                return payload
            return json.loads(payload.decode("utf-8")) if payload else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:600]
        die("HTTP %d %s\n%s\n%s" % (e.code, e.reason, url, detail))
    except urllib.error.URLError as e:
        die("网络错误：%s（%s）" % (e.reason, url))


def version_code(version):
    """
    版本名 -> versionCode（"版本号的换算"）。

    Android 要求 versionCode 是单调递增的整数，而发布入口是 tag，所以这里
    由版本名确定性换算，无需手工维护、也不会两处不一致。

    规则（保持短小，沿用项目原有约定）：
        MAJOR×10000 + MINOR×100 + PATCH
        1.0.0 -> 10000    1.0.1 -> 10001    1.1.0 -> 10100    2.0.0 -> 20000

    约束：MINOR 与 PATCH 需 < 100（各占两位），否则会进位串位——
      例如 1.100.0 会算出 20000，与 2.0.0 撞车。正常发版到不了这个量级。
    """
    parts = []
    for seg in version.split("."):
        seg = re.sub(r"\D", "", seg) or "0"
        parts.append(int(seg))
    while len(parts) < 3:
        parts.append(0)
    major, minor, patch = parts[0], parts[1], parts[2]
    for label, val in (("MINOR", minor), ("PATCH", patch)):
        if val >= 100:
            die("版本号 %s 的 %s 段为 %d（>=100）。\n"
                "该位占两位，>=100 会进位串位（1.100.0 与 2.0.0 会算出同一个数），"
                "请控制在 0-99 内。" % (version, label, val))
    return major * 10000 + minor * 100 + patch


def require_version_arg(raw):
    """
    取并校验版本名。

    版本名【必须】由调用方显式传入（CI 里来自 tag，经 tool/derive_version.sh 换算）。
    刻意不提供"读 pubspec"的回退：pubspec 里是开发期占位值（0.0.0），
    拿它发版会把一个假版本推给用户，而且这种错最不显眼——
    包能装、更新说明也正常，只是所有平台的版本号都是错的。
    """
    version = (raw or "").strip().lstrip("vV")
    if not version:
        die("缺少 --version（版本名，如 1.0.0）。\n"
            "  CI 里由 tag 推导：bash tool/derive_version.sh v1.0.0 --github-env\n"
            "  本地手动跑时请显式传入，例如：--version 1.0.1")
    if not re.match(r"^\d+\.\d+\.\d+$", version):
        die("版本名必须是 X.Y.Z 形式（来自 tag，如 v1.0.0），当前为：%s" % version)
    return version


def extract_version_block(version):
    """
    从 CHANGELOG.md 取该版本的说明块；没有则返回 None（由调用方回退到自动生成）。

    标题格式：## [1.0.0] - 2026-09-15
    不再要求写 Version-Code——versionCode 由版本名换算，写进 Release 正文。

    关键：搜索前必须先剥掉围栏代码块。文首格式说明里就有一个示例标题
    （被 ``` 包着），不剥离的话正则会先命中它，取出来只有三个反引号——
    这个坑已经踩过一次。
    """
    p = os.path.join(ROOT, "CHANGELOG.md")
    if not os.path.exists(p):
        return None
    text = open(p, encoding="utf-8").read()
    text = re.sub(r"^```.*?^```\s*$", "", text, flags=re.M | re.S)
    # 同时剥掉 HTML 注释（维护者说明里也有示例标题）
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)

    pat = re.compile(r"^##\s*\[%s\][^\n]*\n(.*?)(?=^##\s|\Z)" % re.escape(version),
                     re.M | re.S)
    m = pat.search(text)
    if not m:
        return None
    notes = m.group(1).strip()
    # 顺手兼容旧写法：若块内写了 Version-Code，去掉（现在是换算出来的）
    notes = re.sub(r"^Version-Code:\s*\d+\s*$\n?", "", notes, flags=re.M).strip()
    return notes or None


def build_release_body(version, code, notes):
    """Release 正文 = 版本信息行 + 更新说明；App 从这里核对 versionCode。"""
    return "Version: %s\nVersion-Code: %d\n\n%s" % (version, code, notes)


def sync_public_readme(owner, repo, version, token):
    """
    把完整 CHANGELOG 同步到公开仓的 README.md（作为可浏览的版本历史）。

    处理要点：
      - CHANGELOG 开头的维护者说明写在 HTML 注释里，这里必须剥掉，
        否则公开 README 上会出现"标题格式必须严格写成"这类内部提示
      - 用 Contents API 写入；已存在则带上 sha 覆盖
      - 失败只告警不中断——Release 已经发出去了，README 同步失败不该算发布失败
    """
    changelog_path = os.path.join(ROOT, "CHANGELOG.md")
    changelog = open(changelog_path, encoding="utf-8").read()
    # 剥掉 HTML 注释（维护者说明）与 Markdown 引用块（旧的写法兼容）
    body_md = re.sub(r"<!--.*?-->", "", changelog, flags=re.S)
    body_md = re.sub(r"^\s*>\s?.*$(\n|$)", "", body_md, flags=re.M)
    body_md = body_md.strip()

    header = (
        "# %s\n\n"
        "本仓库是 **contact_flutter（通讯录 / 来电名片）的公开分发与版本历史仓库**。\n\n"
        "- 源码开发仓为私有仓库，不对外公开\n"
        "- 每个正式版本的安装包发布在本仓的 [Releases](https://gitcode.com/%s/%s/releases)\n"
        "- 下面的版本历史由发布脚本自动生成，请勿手工编辑\n\n"
        "---\n\n"
        "## 版本历史\n\n" % (repo, owner, repo)
    )
    content = header + body_md + "\n"

    api = "%s/repos/%s/%s/contents/README.md" % (API, owner, repo)
    sha = None
    try:
        cur = http("GET", api, token=token)
        if isinstance(cur, dict):
            sha = cur.get("sha")
    except SystemExit:
        sha = None  # 首次创建时 404，忽略

    payload = {
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
        "message": "docs: 同步版本历史到 %s" % version,
    }
    if sha:
        payload["sha"] = sha
    try:
        http("PUT", api, token=token, data=payload, expect=(200, 201))
        print("  公开仓 README 已同步（%d 字）" % len(content))
    except SystemExit:
        print("  警告：公开仓 README 同步失败（不影响 Release 发布）")


def verify_apk_version(apk_path, want_name, want_code):
    """
    校验 APK 内部真实的 versionName/versionCode 与 tag 推导值一致。

    为什么要这一步：构建参数传对了，不代表【真正上传的那个 APK】里是对的——
    Flutter 的构建缓存（build/、.dart_tool/、android/local.properties）可能留着
    上一次的版本号，曾观察到 local.properties 里缓存着旧 versionCode 的情况。
    发出去的包版本号错了，用户端"检查更新"就会一直误判，且很难查。

    用 Android SDK 的 aapt2 读包内清单；找不到 aapt2 时只告警不阻断
    （不因为环境缺工具就让发布无法进行）。
    """
    aapt2 = _find_aapt2()
    if not aapt2:
        print("  警告：找不到 aapt2，跳过 APK 版本校验")
        print("        （建议设置 ANDROID_HOME 或把 build-tools 放到 SDK 下）")
        return
    try:
        out = subprocess.run([aapt2, "dump", "badging", apk_path],
                             capture_output=True, timeout=120)
        text = out.stdout.decode("utf-8", "replace")
    except Exception as e:
        print("  警告：aapt2 执行失败（%s），跳过 APK 版本校验" % e)
        return

    m = re.search(r"versionCode='(\d+)'", text)
    n = re.search(r"versionName='([^']*)'", text)
    if not m or not n:
        print("  警告：aapt2 输出里读不到版本信息，跳过校验")
        return
    apk_code, apk_name = int(m.group(1)), n.group(1)
    print("  APK 内实际：versionName=%s versionCode=%d" % (apk_name, apk_code))
    if apk_name != want_name or apk_code != want_code:
        die("APK 里的版本与 tag 推导值不一致！\n"
            "  期望（tag v%s）: versionName=%s versionCode=%d\n"
            "  APK 里实际     : versionName=%s versionCode=%d\n"
            "多半是构建缓存残留（android/local.properties、build/）留着上一次的版本号，\n"
            "请先清理再重新构建：\n"
            "  flutter clean && flutter pub get && flutter build apk --release "
            "--build-name=<版本名> --build-number=<versionCode> ..."
            % (want_name, want_name, want_code, apk_name, apk_code))
    print("  与 tag 推导值一致 ✅")


def _find_aapt2():
    """在 ANDROID_HOME / ANDROID_SDK_ROOT / 常见路径下找 aapt2，取版本号最大的一个。"""
    roots = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
             os.path.expanduser("~/AppData/Local/Android/Sdk"), "/usr/lib/android-sdk"]
    cands = []
    for r in roots:
        if not r:
            continue
        bt = os.path.join(r, "build-tools")
        if not os.path.isdir(bt):
            continue
        for d in os.listdir(bt):
            exe = os.path.join(bt, d, "aapt2.exe" if os.name == "nt" else "aapt2")
            if os.path.exists(exe):
                cands.append((d, exe))
    if not cands:
        return None
    cands.sort(key=lambda kv: [int(x) if x.isdigit() else 0 for x in kv[0].split(".")])
    return cands[-1][1]


def upload_attachment(owner, repo, tag, fname, payload, attempts=3):
    """
    上传附件，失败自动重试。

    接口返回的结构是 {"url": <签名URL>, "headers": {x-obs-*...}}，
    **签名校验依赖那些 x-obs-* 头，一个都不能少**：
    曾经错把整个响应当 headers 遍历（而不是 info["headers"]），
    结果只发出去一个 Content-Length，服务端一律 401。

    失败重试会【重新申请】上传地址：旧签名有效期很短。
    """
    last_err = None
    for i in range(1, attempts + 1):
        info = http("GET",
                    "%s/repos/%s/%s/releases/%s/upload_url?file_name=%s"
                    % (API, owner, repo, urllib.parse.quote(tag, safe=""),
                       urllib.parse.quote(fname, safe="")),
                    token=TOKEN)
        hdrs = dict(info.get("headers") or {})
        hdrs["Content-Length"] = str(len(payload))
        missing = [k for k in ("x-obs-acl", "x-obs-callback", "x-obs-meta-project-id")
                   if k not in hdrs]
        if missing:
            die("上传地址返回的 headers 缺少 %s（服务端结构可能变了）" % missing)
        try:
            http("PUT", info["url"], data=payload, headers=hdrs, raw=True,
                 expect=(200, 201, 203, 204))
            return
        except SystemExit as e:
            last_err = e
            if i < attempts:
                wait = 2 * i
                print("  第 %d 次上传失败，%d 秒后重试（重新申请上传地址）..." % (i, wait))
                time.sleep(wait)
    die("附件上传连续 %d 次失败：%s" % (attempts, last_err))


def main():
    ap = argparse.ArgumentParser(
        description="发布到 GitCode 公开仓（版本历史 + Android/Windows 分发）",
        epilog="版本名必须由 --version 显式给出（CI 里来自 tag），versionCode 由版本名换算，"
               "pubspec 只是开发期占位值、不会被读取。")
    ap.add_argument("--version", required=False,
                    help="版本名，如 1.0.0（必填；CI 里由 tag 经 derive_version.sh 推导）")
    ap.add_argument("--apk", action="append",
                    help="要上传/校验的 APK 路径；可重复指定（默认包与 x86_64 包各一个）")
    ap.add_argument("--verify-only", action="store_true",
                    help="只校验包内版本号，不调用任何写接口、也不需要仓库坐标与 token\n"
                         "（CI 里构建完成后复核用）")
    ap.add_argument("--notes-file", help="更新说明文件（CI 里用自动生成的中文说明）")
    ap.add_argument("--dry-run", action="store_true", help="只校验，不调用写接口")
    ap.add_argument("--skip-create", action="store_true", help="Release 已存在，只上传附件")
    ap.add_argument("--check-token", action="store_true", help="只验证 token 是否有效")
    ap.add_argument("--emit-body",
                    help="只把 Release 正文写到该文件，不调用任何写接口。\n"
                         "供 CI 用 Zxilly/upload-gitcode-release 这类 action 建 Release 时使用")
    args = ap.parse_args()

    # --apk 现在是可重复的；统一成列表，后面按列表处理
    apks = list(args.apk or [])

    if args.check_token:
        if not TOKEN:
            die("缺少 GITCODE_TOKEN")
        me = http("GET", "%s/user" % API, token=TOKEN)
        print("token 有效，账号：%s" % (me.get("login") or me.get("name") or "?"))
        print("API 基址：%s" % API)
        return

    # 纯校验：不碰网络也不写任何东西，所以放在 require_env 之前，
    # 构建作业里就能用它复核"真正要上传的那个包"的版本号。
    if args.verify_only:
        version = require_version_arg(args.version)
        if not apks:
            die("--verify-only 需要至少一个 --apk")
        code = version_code(version)
        print("== 校验包内版本号（%s → versionCode %d）==" % (version, code))
        for p in apks:
            if not os.path.exists(p):
                die("APK 不存在：%s" % p)
            print("  %s（%.1f MB）" % (p, os.path.getsize(p) / 1024.0 / 1024.0))
            verify_apk_version(p, version, code)
        print("\n校验通过，未调用任何写接口。")
        return

    # 目标仓库坐标来自环境变量（脚本里不写死 owner/repo）
    owner, repo = require_env()

    # 版本必须显式给出（CI 里由 tag 传入）。
    # 刻意【不】回退读 pubspec：那里的值是开发期占位（0.0.0），
    # 悄悄拿它发版会把一个假版本推给用户，而且是所有平台里最不显眼的那种错。
    version = require_version_arg(args.version)

    code = version_code(version)
    tag = "v%s" % version
    print("== 目标 ==")
    print("  仓库   : %s/%s" % (owner, repo))
    print("  API    : %s" % API)
    print("  版本   : %s" % version)
    print("  tag    : %s" % tag)
    print("  versionCode : %d（由版本名换算）" % code)

    # 说明来源：--notes-file（CI 用自动生成的中文说明）> CHANGELOG 对应块
    notes = None
    if args.notes_file:
        if not os.path.exists(args.notes_file):
            die("说明文件不存在：%s" % args.notes_file)
        notes = open(args.notes_file, encoding="utf-8").read().strip() or None
        if notes:
            print("== 更新说明：来自 %s（%d 字）==" % (args.notes_file, len(notes)))
    if not notes:
        notes = extract_version_block(version)
        if notes:
            print("== 更新说明：来自 CHANGELOG.md 的 [%s] 块（%d 字）==" % (version, len(notes)))
    if not notes:
        notes = "本次发布未单独撰写更新说明。"
        print("== 更新说明：CHANGELOG.md 里没有 [%s] 块，使用占位说明 ==" % version)
        print("   （想写详细说明：在 CHANGELOG.md 加 '## [%s] - YYYY-MM-DD' 段落即可）" % version)

    body = build_release_body(version, code, notes)
    for line in body.splitlines()[:8]:
        print("  " + line)
    if len(body.splitlines()) > 8:
        print("  ...（略）")

    # CI 用法：只产出正文交给自己建 Release 的 action（如 Zxilly/upload-gitcode-release），
    # 本脚本就不再自己调写接口。
    if args.emit_body:
        with open(args.emit_body, "w", encoding="utf-8", newline="\n") as f:
            f.write(body + "\n")
        print("\n== 已写出 Release 正文：%s（%d 字）==" % (args.emit_body, len(body)))
        if apks:
            # 仍然校验包内版本号：包与正文不符是最难查的问题
            print("  校验包内版本号：")
            for p in apks:
                if not os.path.exists(p):
                    die("APK 不存在：%s" % p)
                verify_apk_version(p, version, code)
        print("（未调用任何写接口，可交给上传 action 使用）")
        return

    if apks:
        for p in apks:
            if not os.path.exists(p):
                die("APK 不存在：%s" % p)
            print("== APK ==\n  %s（%.1f MB）" % (p, os.path.getsize(p) / 1024.0 / 1024.0))
        # 校验"真正要上传的那些包"里的版本号，而不是只看 pubspec
        print("  校验包内版本号：")
        for p in apks:
            verify_apk_version(p, version, code)
    elif not args.dry_run:
        print("提示：未指定 --apk，只创建 Release 不带附件")

    if not TOKEN and not args.dry_run:
        die("缺少 GITCODE_TOKEN 环境变量（GitCode → 设置 → 访问令牌，需仓库写权限）")

    if args.dry_run:
        print("\n[dry-run] 校验通过，未调用任何写接口。")
        print("正式执行：GITCODE_TOKEN=xxx python tool/release_gitcode.py --apk <apk>")
        return

    # 1) 创建 Release
    if not args.skip_create:
        print("\n== 创建 Release ==")
        try:
            rel = http("POST", "%s/repos/%s/%s/releases" % (API, owner, repo), token=TOKEN,
                       data={"tag_name": tag, "name": tag, "body": body, "prerelease": False})
            print("  已创建：%s" % (rel.get("html_url") or rel.get("url") or tag))
        except SystemExit:
            # Release 已存在（例如补传附件时重跑）不该让整个流程失败，
            # 但要提醒：正文里的 changelog 不会自动更新，需要显式重建 Release。
            print("  警告：创建失败（多半是该 tag 的 Release 已存在）")
            print("        继续尝试上传附件；如需更新说明，先删掉该 tag 再重发：")
            print("        python tool/delete_gitcode_release.py %s" % tag)
    else:
        print("\n== 跳过创建（--skip-create）==")

    # 2) 上传附件
    for p in apks:
        fname = os.path.basename(p)
        # 附件名不能含 "+"：它在 URL 查询里代表空格，会让签名/路由对不上
        # （实测：名字带 + 的文件即使上传成功，匿名下载也是 404）。
        if "+" in fname:
            die("附件名不能含 '+'（在 URL 里会被当成空格，导致下载 404）：%s\n"
                "请改名，例如 contact_flutter_v1.0.0.apk" % fname)
        print("\n== 上传附件 %s ==" % fname)
        with open(p, "rb") as f:
            payload = f.read()
        print("  上传中（%.1f MB）..." % (len(payload) / 1024.0 / 1024.0))
        upload_attachment(owner, repo, tag, fname, payload)
        print("  上传完成")

    # 3) 同步公开仓 README（版本历史）
    print("\n== 同步公开仓 README（版本历史）==")
    sync_public_readme(owner, repo, version, TOKEN)

    # 4) 复核：列出 release，确认可读
    print("\n== 复核（免鉴权接口，App 就用这个）==")
    rels = http("GET", "%s/repos/%s/%s/releases" % (API, owner, repo))
    for r in (rels or [])[:3]:
        assets = ", ".join(a.get("name", "?") for a in (r.get("assets") or []))
        has_code = "Version-Code:" in (r.get("body") or "")
        print("  %-12s 附件: %-28s versionCode 行: %s"
              % (r.get("tag_name"), assets or "无", "有" if has_code else "缺"))
    print("\n完成。App 端查询地址：%s/repos/%s/%s/releases" % (API, owner, repo))
    print("公开仓页面：https://gitcode.com/%s/%s" % (owner, repo))


if __name__ == "__main__":
    main()
