#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成应用图标（通讯录 App）——候选方案。

设计语言参照国内主流 App（支付宝/微信/抖音/B站/钉钉）的共性：
  - 一个高辨识度主符号，符号内部不放细节
  - 1~2 个大色块 + 干净渐变，纯矢量扁平
  - 48px 下符号依然清晰

符号用 tool/svgpath.py 里的极简 SVG 路径渲染器绘制。

用法：
    python tool/make_logo.py                  # 出候选对比图 logo/icon_candidates.png
    python tool/make_logo.py --preview E      # 出某方案的详细预览
    python tool/make_logo.py --apply E        # 选定方案，输出全套图标资源
"""

import os
import sys
from PIL import Image, ImageDraw

from svgpath import (render_glyph, rotate_layer, glyph_person, glyph_person_simple,
                     glyph_handset, glyph_cards, glyph_cards_simple, glyph_phone_flat,
                     glyph_cards_stack)

S = 1024
CORNER_RATIO = 0.235

G_TOP = (37, 99, 235)
G_BOTTOM = (29, 78, 216)
ACCENT = (37, 99, 235)
WHITE = (255, 255, 255, 255)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
LOGO_DIR = os.path.join(ROOT, "logo")
# 其它平台的图标目录
WIN_RES = os.path.join(ROOT, "windows", "runner", "resources")
WEB_DIR = os.path.join(ROOT, "web")
WEB_ICONS = os.path.join(WEB_DIR, "icons")
IOS_ICONS = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
MACOS_ICONS = os.path.join(ROOT, "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset")


# ---------------- 通用 ----------------
def gradient_diag(size, c0, c1):
    """对角线性渐变（左上 -> 右下）。"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    denom = max(1, (size - 1) * 2.0)
    for y in range(size):
        for x in range(size):
            t = (x + y) / denom
            px[x, y] = tuple(int(round(c0[i] + (c1[i] - c0[i]) * t)) for i in range(3))
    return img


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def circle_mask(size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse([0, 0, size - 1, size - 1], fill=255)
    return m


def base_canvas(size, bg=True):
    """按默认蓝生成圆角渐变底（保留给单符号方案用）。"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if bg:
        g = gradient_diag(size, G_TOP, G_BOTTOM).convert("RGBA")
        g.putalpha(rounded_mask(size, int(size * CORNER_RATIO)))
        img = Image.alpha_composite(img, g)
    return img


_BBOX_CACHE = {}


def measure_glyph(glyph):
    """测出 glyph 内容的包围盒（单位：视图框 0..100）。带缓存，避免重复渲染。"""
    key = repr(glyph)
    if key in _BBOX_CACHE:
        return _BBOX_CACHE[key]
    layer = render_glyph(glyph, 200, ss=1)
    bb = layer.getchannel("A").getbbox()
    if not bb:
        res = (0.0, 0.0, 100.0, 100.0)
    else:
        res = (bb[0] * 0.5, bb[1] * 0.5, bb[2] * 0.5, bb[3] * 0.5)
    _BBOX_CACHE[key] = res
    return res


def place_glyph_centered(img, glyph, target, center=None):
    """
    把 glyph 的【内容】缩放并居中到 target 像素（按第一维取尺寸）。

    实现要点：先测内容包围盒，再按"目标像素 / 内容占比"反推出需要多大的渲染画布，
    最后【在该尺寸上直接渲染】——不做大图缩小，避免缩放导致的模糊。
    """
    if center is None:
        center = (img.width / 2.0, img.height / 2.0)
    x0, y0, x1, y1 = measure_glyph(glyph)
    gw, gh = max(1e-6, x1 - x0), max(1e-6, y1 - y0)
    layer_px = max(8, int(round(target / max(gw, gh) * 100.0)))
    layer = render_glyph(glyph, layer_px, ss=4)
    cx = (x0 + (x1 - x0) / 2.0) * layer_px / 100.0
    cy = (y0 + (y1 - y0) / 2.0) * layer_px / 100.0
    img.alpha_composite(layer, (int(round(center[0] - cx)), int(round(center[1] - cy))))


def place_mark(img, glyph_fn, target, center, angle=0.0, color=WHITE):
    """
    把 glyph 的【内容】缩放并居中到 target 像素。
    按内容包围盒换算，避免因视图框内的留白导致符号偏小。
    glyph_fn 是"颜色 -> glyph"的构造函数，便于换色。
    """
    glyph = glyph_fn(color)
    x0, y0, x1, y1 = measure_glyph(glyph)
    gw, gh = max(1e-6, x1 - x0), max(1e-6, y1 - y0)
    layer_px = max(8, int(round(target / max(gw, gh) * 100.0)))
    layer = render_glyph(glyph, layer_px, ss=4)
    if angle:
        layer = rotate_layer(layer, angle)
    cb = (x0 * layer_px / 100.0, y0 * layer_px / 100.0,
          x1 * layer_px / 100.0, y1 * layer_px / 100.0)
    cw, ch = cb[2] - cb[0], cb[3] - cb[1]
    ox = int(round(center[0] - (cb[0] + cw / 2.0)))
    oy = int(round(center[1] - (cb[1] + ch / 2.0)))
    img.alpha_composite(layer, (ox, oy))


def probe(img, points, tag):
    """像素断言：打印若干坐标的颜色，确认符号真的画上去了、且在预期位置。"""
    pxm = img.convert("RGBA").load()
    parts = []
    for (x, y) in points:
        parts.append("(%d,%d)=%s" % (x, y, pxm[int(x), int(y)]))
    print("  [probe %s] %s" % (tag, "  ".join(parts)))


# ---------------- 配色 ----------------
# 同色系渐变 + 白色容器 + 同色系符号，保证整体协调。
PALETTES = {
    "A": dict(top=(37, 99, 235), bottom=(29, 78, 216), container=None, mark=(255, 255, 255)),
    "B": dict(top=(37, 99, 235), bottom=(29, 78, 216), container=(255, 255, 255), mark=(37, 99, 235)),
    "C": dict(top=(14, 116, 144), bottom=(13, 148, 136), container=(255, 255, 255), mark=(13, 148, 136)),
    "D": dict(top=(30, 64, 175), bottom=(37, 99, 235), container=None, mark=(255, 255, 255)),
    "E": dict(top=(37, 99, 235), bottom=(29, 78, 216), container=(255, 255, 255), mark=(37, 99, 235)),
    # F：无外层渐变，白色方块自己就是外形
    "F": dict(top=(255, 255, 255), bottom=(255, 255, 255), container=(255, 255, 255), mark=(37, 99, 235)),
}

# 画布比例参数（已按"图标适当放大"调整：0.665->0.720、0.46->0.54）
CARD = 0.720
PERSON_ON_FLAT = 0.62
CARDS_IN_CARD = 0.54
CARDS_IN_CARD_FG = 0.54
CARDS_IN_CARD_F = 0.70     # F：白底占满画布，卡片可以更大
PERSON_IN_CARD = 0.5


def _canvas(size, pal, bg=True):
    """按配色生成底（圆角渐变）。"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if bg:
        g = gradient_diag(size, pal["top"], pal["bottom"]).convert("RGBA")
        g.putalpha(rounded_mask(size, int(size * CORNER_RATIO)))
        img = Image.alpha_composite(img, g)
    return img


def _container(img, size, pal):
    """画白色圆角方块容器，返回容器内可用边长。"""
    if pal["container"] is None:
        return size
    cs = size * CARD
    x0 = (size - cs) / 2.0
    ImageDraw.Draw(img).rounded_rectangle(
        [x0, x0, x0 + cs, x0 + cs], radius=cs * 0.295, fill=pal["container"] + (255,))
    return cs


def design_A(size=S, bg=True):
    """A：蓝渐变底 + 白色人形（扁平单符号，最克制）。"""
    pal = PALETTES["A"]
    img = _canvas(size, pal, bg)
    place_glyph_centered(img, glyph_person(pal["mark"] + (255,)), size * PERSON_ON_FLAT)
    probe(img, [(size * 0.5, size * 0.28), (size * 0.5, size * 0.78)], "A")
    return img


def design_B(size=S, bg=True):
    """
    B：蓝渐变底 + 白色圆角方块容器 + 容器内蓝色人形。

    小尺寸下最清晰：人形与容器是"不同形状语言"，缩到 48px 也不会互相糊住。
    """
    pal = PALETTES["B"]
    img = _canvas(size, pal, bg)
    _container(img, size, pal)
    place_glyph_centered(img, glyph_person(pal["mark"] + (255,)), size * PERSON_IN_CARD)
    probe(img, [(size * 0.15, size * 0.5), (size * 0.5, size * 0.34)], "B")
    return img


def design_C(size=S, bg=True):
    """C：青绿渐变底 + 白容器 + 青色名片叠层（配色协调的另一支）。"""
    pal = PALETTES["C"]
    img = _canvas(size, pal, bg)
    _container(img, size, pal)
    glyph = glyph_cards(pal["mark"] + (255,), detail=pal["container"] + (255,))
    place_glyph_centered(img, glyph, size * CARDS_IN_CARD)
    probe(img, [(size * 0.15, size * 0.5), (size * 0.5, size * 0.44)], "C")
    return img


def design_D(size=S, bg=True):
    """D：深蓝→蓝渐变底 + 白色名片叠层（无容器，符号满版）。"""
    pal = PALETTES["D"]
    img = _canvas(size, pal, bg)
    glyph = glyph_cards(pal["mark"] + (255,), detail=pal["top"] + (255,))
    place_glyph_centered(img, glyph, size * 0.62)
    probe(img, [(size * 0.5, size * 0.5)], "D")
    return img


def design_F(size=S, bg=True):
    """
    F（最终方案）：没有外层蓝色渐变，白色圆角方块直接占满整个画布。

    白色方块本身就是 logo 的外形（对外只留白底 + 蓝色两张名片），
    卡片相应放大，整体更"实"、在深色壁纸上更醒目。
    """
    pal = PALETTES["F"]
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # 白色方块满画布，只有外侧圆角
    d.rounded_rectangle([0, 0, size - 1, size - 1],
                        radius=size * CORNER_RATIO, fill=pal["container"] + (255,))
    glyph = glyph_cards_stack(pal["mark"] + (255,),
                              detail=pal["container"] + (255,),
                              gap=pal["container"] + (255,))
    place_glyph_centered(img, glyph, size * CARDS_IN_CARD_F)
    probe(img, [(size * 0.5, size * 0.5), (size * 0.5, size * 0.06)], "F")
    return img


def design_E(size=S, bg=True):
    """
    E：渐变底 + 白容器 + 蓝色"两张名片"（保留作对照）。

    卡片重叠，但前排带底色描边 -> 交界处有清晰分界线，能看出是两张卡；
    前排卡内是圆形头像（正圆头 + 宽肩人形）与两条文字条，横向错开不重叠。
    """
    pal = PALETTES["E"]
    img = _canvas(size, pal, bg)
    _container(img, size, pal)
    glyph = glyph_cards_stack(pal["mark"] + (255,),
                              detail=pal["container"] + (255,),
                              gap=pal["container"] + (255,))
    place_glyph_centered(img, glyph, size * CARDS_IN_CARD)
    probe(img, [(size * 0.5, size * 0.40), (size * 0.31, size * 0.52),
                (size * 0.5, size * 0.78)], "E")
    return img


DESIGNS = {"A": design_A, "B": design_B, "C": design_C, "D": design_D,
           "E": design_E, "F": design_F}
LABELS = {
    "A": ("A  person, flat", "no container, most minimal"),
    "B": ("B  person in card", "CLEAREST at 48px"),
    "C": ("C  cards, teal", "same layout, teal palette"),
    "D": ("D  cards, flat", "no container, full-bleed"),
    "E": ("E  cards in card", "business-card stack (with blue bg)"),
    "F": ("F  cards on white", "RECOMMENDED: white fills the icon"),
}


def _at_size(key, px):
    """按最终像素尺寸重新渲染某个方案（不是缩放位图）——检验小尺寸清晰度的唯一正确方式。"""
    return DESIGNS[key](size=px * 4).resize((px, px), Image.LANCZOS)


def make_candidates_preview():
    """三列布局，可容纳 5 个方案（A..E）；小尺寸按真实像素渲染。"""
    keys = ["A", "B", "C", "D", "E"]
    cols, tile = 3, 560
    rows = (len(keys) + cols - 1) // cols
    W = 28 * 2 + cols * tile
    H = 76 + rows * 320
    pv = Image.new("RGB", (W, H), (18, 20, 26))
    d = ImageDraw.Draw(pv)
    d.text((28, 16), "icon candidates  --  python tool/make_logo.py --apply <A|B|C|D|E>",
           fill=(230, 234, 242))
    d.text((28, 36), "small sizes are rendered AT target px (not downscaled), so what you see is what ships",
           fill=(140, 148, 166))

    for i, key in enumerate(keys):
        cx = 28 + (i % cols) * tile
        cy = 76 + (i // cols) * 320
        img = DESIGNS[key]()
        big = img.resize((160, 160), Image.LANCZOS)
        pv.paste(big, (cx, cy), big)
        d.text((cx + 172, cy + 10), LABELS[key][0], fill=(238, 242, 250))
        d.text((cx + 172, cy + 30), LABELS[key][1], fill=(148, 156, 174))
        sx = cx + 172
        for px in (48, 72, 96):
            s = _at_size(key, px)
            pv.paste(s, (sx, cy + 58), s)
            sx += px + 14
        d.text((cx + 172, cy + 166), "48 / 72 / 96 px  (rendered at size)", fill=(140, 148, 166))
        m = _at_size(key, 96).copy()
        m.putalpha(circle_mask(96))
        pv.paste(m, (cx + 172, cy + 190), m)
        d.text((cx + 278, cy + 252), "circle", fill=(140, 148, 166))
        b = _at_size(key, 96).copy()
        b.putalpha(rounded_mask(96, 22))
        pv.paste(b, (cx + 286, cy + 190), b)
        d.text((cx + 388, cy + 252), "squircle", fill=(140, 148, 166))
    return pv


def make_preview_single(key):
    """单方案详细预览：圆角 / 圆形遮罩 / squircle / 48-96px。"""
    img = DESIGNS[key]()
    pv = Image.new("RGB", (1180, 470), (18, 20, 26))
    d = ImageDraw.Draw(pv)
    d.text((28, 14), "icon %s  %s" % (key, LABELS[key][0]), fill=(232, 236, 244))

    big = img.resize((250, 250), Image.LANCZOS)
    pv.paste(big, (28, 100), big)
    d.text((28, 364), "rounded (legacy)", fill=(158, 166, 184))

    a = img.resize((250, 250), Image.LANCZOS).copy()
    a.putalpha(circle_mask(250))
    pv.paste(a, (308, 100), a)
    d.text((308, 364), "circle mask", fill=(158, 166, 184))

    b = img.resize((250, 250), Image.LANCZOS).copy()
    b.putalpha(rounded_mask(250, 58))
    pv.paste(b, (588, 100), b)
    d.text((588, 364), "squircle mask", fill=(158, 166, 184))

    x = 880
    for px in (48, 72, 96):
        s = _at_size(key, px)
        pv.paste(s, (x, 180), s)
        d.text((x - 2, 364), "%dpx" % px, fill=(158, 166, 184))
        x += px + 22
    return pv


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print("  %-58s %s" % (os.path.relpath(path, ROOT), "%dx%d" % img.size))


# ---------------- 自适应图标三层 ----------------
# 自适应图标画布 108dp，内容必须落在中间 72dp 的安全区内（2/3）。
SAFE_SCALE = 0.62


def render_adaptive_foreground(size=S, pal=None):
    """
    自适应前景：透明底，整个图形缩到中间安全区（2/3）。
    做法是先按满画布渲染一份 E，再整体缩放居中——避免各层比例参数互相打架。
    """
    pal = pal or PALETTES["E"]
    full = design_F(size=size, bg=False)
    inner = int(size * SAFE_SCALE)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - inner) // 2
    out.alpha_composite(full.resize((inner, inner), Image.LANCZOS), (off, off))
    return out


def render_adaptive_background(size=S, pal=None):
    """自适应背景：满幅渐变（不切圆角，遮罩由启动器负责）。"""
    pal = pal or PALETTES["E"]
    return gradient_diag(size, pal["top"], pal["bottom"]).convert("RGBA")


def render_monochrome(size=S, pal=None):
    """
    Android 13+ 主题图标单色层：只有白色 + 透明镂空，系统会用它做整体着色。

    关键：不能把详细元素都设成白色，否则卡片内部全白、细节丢失。
    正确做法是让 detail（头像底圆、文字条）保持透明 -> 形成镂空，
    而 mark（卡片、人形的头与肩）保持白色 -> 读作"白卡上的镂空头像与文字条"。
    """
    mono_pal = dict(top=(255, 255, 255), bottom=(255, 255, 255),
                    container=(255, 255, 255), mark=(255, 255, 255))
    full = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    _container(full, size, mono_pal)
    glyph = glyph_cards_stack((255, 255, 255, 255),   # mark：卡片与人形 = 白
                              detail=(0, 0, 0, 0),      # detail：头像底圆、文字条 = 镂空
                              gap=(0, 0, 0, 0))         # gap：卡间描边 = 镂空分界
    place_glyph_centered(full, glyph, size * CARDS_IN_CARD)
    inner = int(size * SAFE_SCALE)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - inner) // 2
    out.alpha_composite(full.resize((inner, inner), Image.LANCZOS), (off, off))
    return out


def _write_adaptive_xml():
    xml_dir = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(xml_dir, exist_ok=True)
    body = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
"""
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        p = os.path.join(xml_dir, name)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        print("  %-58s" % os.path.relpath(p, ROOT))


def flatten_to_white(img, bg=(255, 255, 255)):
    """
    把带透明的图压到白底并转 RGB。
    iOS 的 App Store 图标不允许有 alpha 通道，必须走这一步。
    """
    canvas = Image.new("RGBA", img.size, bg + (255,))
    canvas.alpha_composite(img.convert("RGBA"))
    return canvas.convert("RGB")


def _render_at(px):
    """按目标像素渲染 F 方案（不是缩放位图，保证小尺寸清晰）。"""
    return DESIGNS["F"](size=px * 4).resize((px, px), Image.LANCZOS)


def apply_windows(key):
    """
    Windows：.exe 图标只能是 ICO（PE 资源格式写死），PIL 可直接写多尺寸 ICO。
    同时给一份 256 PNG 备用（商店/文档场景）。
    """
    print("== Windows ==")
    ico = os.path.join(WIN_RES, "app_icon.ico")
    os.makedirs(WIN_RES, exist_ok=True)
    base = DESIGNS[key](size=1024)
    base.save(ico, format="ICO",
              sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
                     (128, 128), (256, 256)])
    print("  %-58s %s" % (os.path.relpath(ico, ROOT), "ico 16..256"))
    save(DESIGNS[key](size=1024).resize((256, 256), Image.LANCZOS),
         os.path.join(LOGO_DIR, "app_icon_256.png"))


def apply_web(key):
    """Web：favicon + PWA 图标（含 maskable，遮罩安全区留白更多）。"""
    print("== Web ==")
    save(_render_at(32), os.path.join(WEB_DIR, "favicon.png"))
    save(_render_at(192), os.path.join(WEB_ICONS, "Icon-192.png"))
    save(_render_at(512), os.path.join(WEB_ICONS, "Icon-512.png"))
    # maskable：系统会按圆形/方形裁切，所以把图形缩到 80% 留出安全区
    for px, name in ((192, "Icon-maskable-192.png"), (512, "Icon-maskable-512.png")):
        canvas = Image.new("RGBA", (px, px), (255, 255, 255, 255))
        inner = int(px * 0.80)
        art = _render_at(inner)
        off = (px - inner) // 2
        canvas.alpha_composite(art, (off, off))
        save(canvas, os.path.join(WEB_ICONS, name))


def apply_linux(key):
    """
    Linux 桌面：Flutter 的 linux runner 不直接吃图标。

    实际取图路径：
      - deb 打包（tool/build_deb.sh）从 android 的 mipmap-xxxhdpi 取
      - 其它分发方式可直接用 logo/app_icon_256.png（下面 Windows 那步已产出）
    所以这里不重复产出一份同内容的 PNG——原先的 app_icon_linux_256.png
    与 app_icon_256.png 逐字节相同，属于冗余。
    """
    print("== Linux ==\n  图标复用 logo/app_icon_256.png（不重复产出）")


def apply_ios(key):
    """
    iOS：按 AppIcon.appiconset/Contents.json 里登记的文件名逐个生成。

    注意：App Store 明确拒绝带 alpha 通道的图标
    （"Invalid App Store Icon ... can't be transparent nor contain an alpha channel"），
    所以必须把圆角外的透明区域压到白色底、再转成 RGB 输出。
    """
    print("== iOS（不透明，去 alpha）==")
    sizes = {
        "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, px in sorted(sizes.items()):
        save(flatten_to_white(_render_at(px)), os.path.join(IOS_ICONS, name))


def apply_macos(key):
    """macOS：按 AppIcon.appiconset/Contents.json 里登记的文件名生成。"""
    print("== macOS ==")
    sizes = {
        "app_icon_16.png": 16, "app_icon_32.png": 32, "app_icon_64.png": 64,
        "app_icon_128.png": 128, "app_icon_256.png": 256,
        "app_icon_512.png": 512, "app_icon_1024.png": 1024,
    }
    for name, px in sorted(sizes.items(), key=lambda kv: kv[1]):
        save(_render_at(px), os.path.join(MACOS_ICONS, name))


def apply_design(key):
    """把选定方案落到所有平台资源与主图。"""
    os.makedirs(LOGO_DIR, exist_ok=True)

    print("== 主图 ==")
    save(DESIGNS[key](), os.path.join(LOGO_DIR, "app_icon_1024.png"))
    save(render_adaptive_foreground(), os.path.join(LOGO_DIR, "adaptive_foreground_1024.png"))
    save(render_adaptive_background(), os.path.join(LOGO_DIR, "adaptive_background_1024.png"))
    save(render_monochrome(), os.path.join(LOGO_DIR, "adaptive_monochrome_1024.png"))

    print("== Android 传统图标（按目标像素渲染） ==")
    for folder, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                       ("xxhdpi", 144), ("xxxhdpi", 192)):
        save(_render_at(px), os.path.join(RES, "mipmap-" + folder, "ic_launcher.png"))

    print("== Android 自适应图标（108dp 画布，1x/1.5x/2x/3x/4x） ==")
    for folder, mult in (("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0),
                         ("xxhdpi", 3.0), ("xxxhdpi", 4.0)):
        px = int(108 * mult)
        save(render_adaptive_foreground(S).resize((px, px), Image.LANCZOS),
             os.path.join(RES, "mipmap-" + folder, "ic_launcher_foreground.png"))
        save(render_adaptive_background(S).resize((px, px), Image.LANCZOS),
             os.path.join(RES, "mipmap-" + folder, "ic_launcher_background.png"))
        save(render_monochrome(S).resize((px, px), Image.LANCZOS),
             os.path.join(RES, "mipmap-" + folder, "ic_launcher_monochrome.png"))

    print("== 自适应图标 XML ==")
    _write_adaptive_xml()

    apply_windows(key)
    apply_web(key)
    apply_linux(key)
    apply_ios(key)
    apply_macos(key)

    print("== 预览 ==")
    save(make_preview_single(key), os.path.join(LOGO_DIR, "ic_launcher_preview.png"))
    print("\n完成。Android 清单里的 icon/roundIcon 已指向 @mipmap/ic_launcher(_round)；")
    print("      Windows 用 windows/runner/resources/app_icon.ico（RC 已引用，无需改）。")


def main():
    if "--preview" in sys.argv:
        i = sys.argv.index("--preview")
        key = sys.argv[i + 1].upper() if i + 1 < len(sys.argv) else ""
        if key not in DESIGNS:
            print("用法：python tool/make_logo.py --preview <A|B|C|D|E>", file=sys.stderr)
            sys.exit(2)
        os.makedirs(LOGO_DIR, exist_ok=True)
        save(make_preview_single(key), os.path.join(LOGO_DIR, "ic_launcher_preview.png"))
        return
    if "--apply" in sys.argv:
        i = sys.argv.index("--apply")
        key = sys.argv[i + 1].upper() if i + 1 < len(sys.argv) else ""
        if key not in DESIGNS:
            print("用法：python tool/make_logo.py --apply <A|B|C|D|E>", file=sys.stderr)
            sys.exit(2)
        apply_design(key)
        return
    os.makedirs(LOGO_DIR, exist_ok=True)
    save(make_candidates_preview(), os.path.join(LOGO_DIR, "icon_candidates.png"))
    print("\n选定后：python tool/make_logo.py --apply E")


if __name__ == "__main__":
    main()
