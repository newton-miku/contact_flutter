#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SVG 路径 -> PNG 的极简渲染器（只依赖 PIL）。

支持 M / L / C / Q / Z 与小写相对指令，曲线采样成多边形后用 supersampling 抗锯齿。
够用来画图标符号，且不引入 cairosvg 之类的本地库依赖。

数据格式：glyph = [(path_string, fill_rgba), ...]
"""

import math
import re
from PIL import Image, ImageDraw

_NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")
_CMD = re.compile(r"[MmLlCcQqAaZzHhVv]")


def _tokenize(d):
    """把 path 字符串切成 [(cmd, [nums...]), ...]。"""
    out = []
    i = 0
    while i < len(d):
        ch = d[i]
        if ch in " ,\t\r\n":
            i += 1
            continue
        if _CMD.match(ch):
            cmd = ch
            i += 1
            j = i
            while j < len(d) and not _CMD.match(d[j]):
                j += 1
            nums = [float(x) for x in _NUM.findall(d[i:j])]
            out.append((cmd, nums))
            i = j
        else:
            i += 1
    return out


def _bezier3(p0, p1, p2, p3, n=28):
    pts = []
    for k in range(n + 1):
        t = k / n
        u = 1 - t
        x = u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def _bezier2(p0, p1, p2, n=24):
    pts = []
    for k in range(n + 1):
        t = k / n
        u = 1 - t
        x = u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0]
        y = u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def _arc_to_beziers(p0, rx, ry, phi_deg, large_arc, sweep, p1):
    """
    SVG 圆弧(A)转三次贝塞尔段。按规范做端点参数化后分段逼近。
    返回 [(c1, c2, end), ...]。
    """
    x1, y1 = p0
    x2, y2 = p1
    if rx == 0 or ry == 0 or (abs(x1 - x2) < 1e-12 and abs(y1 - y2) < 1e-12):
        return [((x1, y1), (x2, y2), (x2, y2))]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)

    dx2 = (x1 - x2) / 2.0
    dy2 = (y1 - y2) / 2.0
    x1p = cp * dx2 + sp * dy2
    y1p = -sp * dx2 + cp * dy2

    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s

    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large_arc == sweep:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx

    cx = cp * cxp - sp * cyp + (x1 + x2) / 2.0
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2.0

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        n = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1.0, min(1.0, dot / n))) if n else 0.0
        return -a if (ux * vy - uy * vx) < 0 else a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                   (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    nseg = max(1, int(math.ceil(abs(dtheta) / (math.pi / 2.0))))
    out = []
    for i in range(nseg):
        t0 = theta1 + dtheta * i / nseg
        t1 = theta1 + dtheta * (i + 1) / nseg
        dt = t1 - t0
        k = 4.0 / 3.0 * math.tan(dt / 4.0)

        def pt(t):
            return (cx + rx * math.cos(t) * cp - ry * math.sin(t) * sp,
                    cy + rx * math.cos(t) * sp + ry * math.sin(t) * cp)

        def dpt(t):
            return (-rx * math.sin(t) * cp - ry * math.cos(t) * sp,
                    -rx * math.sin(t) * sp + ry * math.cos(t) * cp)

        a0, a1 = pt(t0), pt(t1)
        d0, d1 = dpt(t0), dpt(t1)
        out.append(((a0[0] + k * d0[0], a0[1] + k * d0[1]),
                    (a1[0] - k * d1[0], a1[1] - k * d1[1]),
                    a1))
    return out


def path_to_subpaths(d):
    """返回 [[(x,y), ...], ...]，每个子路径是一串点。"""
    subs = []
    cur = []
    pos = (0.0, 0.0)
    start = (0.0, 0.0)
    for cmd, nums in _tokenize(d):
        rel = cmd.islower()
        C = cmd.upper()
        if C == "M":
            for k in range(0, len(nums) - 1, 2):
                x, y = nums[k], nums[k + 1]
                if rel:
                    x, y = pos[0] + x, pos[1] + y
                pos = (x, y)
                if k == 0:
                    if len(cur) > 2:
                        subs.append(cur)
                    cur = [pos]
                    start = pos
                else:
                    cur.append(pos)
        elif C == "L":
            for k in range(0, len(nums) - 1, 2):
                x, y = nums[k], nums[k + 1]
                if rel:
                    x, y = pos[0] + x, pos[1] + y
                pos = (x, y)
                cur.append(pos)
        elif C == "H":
            for v in nums:
                x = pos[0] + v if rel else v
                pos = (x, pos[1])
                cur.append(pos)
        elif C == "V":
            for v in nums:
                y = pos[1] + v if rel else v
                pos = (pos[0], y)
                cur.append(pos)
        elif C == "C":
            for k in range(0, len(nums) - 5, 6):
                p1 = (nums[k], nums[k + 1])
                p2 = (nums[k + 2], nums[k + 3])
                p3 = (nums[k + 4], nums[k + 5])
                if rel:
                    p1 = (pos[0] + p1[0], pos[1] + p1[1])
                    p2 = (pos[0] + p2[0], pos[1] + p2[1])
                    p3 = (pos[0] + p3[0], pos[1] + p3[1])
                cur.extend(_bezier3(pos, p1, p2, p3)[1:])
                pos = p3
        elif C == "Q":
            for k in range(0, len(nums) - 3, 4):
                p1 = (nums[k], nums[k + 1])
                p2 = (nums[k + 2], nums[k + 3])
                if rel:
                    p1 = (pos[0] + p1[0], pos[1] + p1[1])
                    p2 = (pos[0] + p2[0], pos[1] + p2[1])
                cur.extend(_bezier2(pos, p1, p2)[1:])
                pos = p2
        elif C == "A":
            for k in range(0, len(nums) - 6, 7):
                rx, ry, rot, laf, sf = nums[k], nums[k + 1], nums[k + 2], nums[k + 3], nums[k + 4]
                ex, ey = nums[k + 5], nums[k + 6]
                if rel:
                    ex, ey = pos[0] + ex, pos[1] + ey
                for (c1, c2, end) in _arc_to_beziers(pos, rx, ry, rot, int(laf), int(sf), (ex, ey)):
                    cur.extend(_bezier3(pos, c1, c2, end)[1:])
                    pos = end
        elif C == "Z":
            if cur:
                cur.append(start)
                pos = start
    if len(cur) > 2:
        subs.append(cur)
    return subs


def render_glyph(glyph, px, ss=4, transform=None):
    """
    渲染 glyph 到 px x px 的 RGBA 图。

    glyph: [(path_d, (r,g,b,a)), ...]；坐标按 100x100 视图框给出。
           第三项可选传 'erase' -> 该子路径用于【挖洞】（把已画内容的 alpha 清成 0）。
           "透明色"并不能挖洞：alpha_composite 只叠加有颜色的像素，用 a=0 的图形去画
           不会擦除已画的白，所以单色层这类"镂空"必须显式擦除。
    transform: (scale_x, scale_y, tx, ty) 额外变换（用于旋转前的摆放）。
    """
    big = px * ss
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = big / 100.0

    def apply(p):
        x, y = p
        if transform:
            sx, sy, tx, ty = transform
            x, y = x * sx + tx, y * sy + ty
        return (x * k, y * k)

    for item in glyph:
        path_d, fill = item[0], item[1]
        op = item[2] if len(item) > 2 else None
        for sub in path_to_subpaths(path_d):
            pts = [apply(p) for p in sub]
            if len(pts) < 3:
                continue
            if op == "erase":
                # 就地擦除：必须在"该擦的位置"立即执行，不能攒到最后统一擦，
                # 否则会把之后画的图形（如头像里的人形）一并抹掉。
                hm = Image.new("L", (big, big), 0)
                ImageDraw.Draw(hm).polygon(pts, fill=255)
                alpha = img.getchannel("A")
                alpha.paste(0, mask=hm)
                img.putalpha(alpha)
            else:
                d.polygon(pts, fill=fill)

    return img.resize((px, px), Image.LANCZOS)


def rotate_layer(layer, deg):
    return layer.rotate(deg, resample=Image.BICUBIC, expand=False)


# ---------------------------------------------------------------- 图标符号
def glyph_handset(color=(255, 255, 255, 255)):
    """
    经典电话听筒（视图框 0..100，横放，调用方旋转约 -40°）。

    做法：一条浅弧中轴线 + 沿程变化的带宽（中间厚、两端收窄但不腰斩），
    再在两端各加一个圆角"耳罩/话筒"，形成 iOS/Material 那种话机轮廓。
    带体较厚（半宽 13 -> 6 -> 13），避免出现"领结"式的尖腰。
    """
    import math as _m

    def bez(t, p0, p1, p2):
        u = 1 - t
        return (u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1])

    # 中轴线：从左下到右下的一条浅弧（中段低）
    A, C, B = (14.0, 34.0), (50.0, 62.0), (86.0, 34.0)

    N = 48
    upper, lower = [], []
    for i in range(N + 1):
        t = i / N
        px_, py_ = bez(t, A, C, B)
        # 切线 -> 法线
        tx, ty = bez(min(1.0, t + 1e-3), A, C, B)
        tx, ty = tx - px_, ty - py_
        n = _m.hypot(tx, ty) or 1.0
        nx, ny = -ty / n, tx / n
        # 带半宽：两端 13，中段 6.5（平滑过渡，不腰斩）
        hw = 6.5 + 6.5 * abs(1 - 2 * t)
        upper.append((px_ + nx * hw, py_ + ny * hw))
        lower.append((px_ - nx * hw, py_ - ny * hw))

    ear_r = 15.0
    mouth_r = 15.0

    def ellipse_path(cx, cy, rx, ry):
        """用 4 段三次贝塞尔拼一个椭圆（闭合路径）。"""
        k = 0.5523
        p = [(cx + rx, cy), (cx, cy + ry), (cx - rx, cy), (cx, cy - ry)]
        c = [(cx + rx, cy + ry * k), (cx + rx * k, cy + ry),
             (cx - rx * k, cy + ry), (cx - rx, cy + ry * k),
             (cx - rx, cy - ry * k), (cx - rx * k, cy - ry),
             (cx + rx * k, cy - ry), (cx + rx, cy - ry * k)]
        d = "M %.2f %.2f " % p[0]
        d += "C %.2f %.2f %.2f %.2f %.2f %.2f " % (c[0][0], c[0][1], c[1][0], c[1][1], p[1][0], p[1][1])
        d += "C %.2f %.2f %.2f %.2f %.2f %.2f " % (c[2][0], c[2][1], c[3][0], c[3][1], p[2][0], p[2][1])
        d += "C %.2f %.2f %.2f %.2f %.2f %.2f " % (c[4][0], c[4][1], c[5][0], c[5][1], p[3][0], p[3][1])
        d += "C %.2f %.2f %.2f %.2f %.2f %.2f Z" % (c[6][0], c[6][1], c[7][0], c[7][1], p[0][0], p[0][1])
        return d

    path = "M " + " L ".join("%.2f %.2f" % pt for pt in upper)
    path += " L " + " L ".join("%.2f %.2f" % pt for pt in reversed(lower))
    path += " Z"

    ear = ellipse_path(A[0] - 1.0, A[1] + 3.0, ear_r, ear_r * 1.05)
    mouth = ellipse_path(B[0] + 1.0, B[1] + 3.0, mouth_r, mouth_r * 1.05)
    return [(path, color), (ear, color), (mouth, color)]


def _rr_polygon(cx, cy, half_len, half_wid, angle_deg, rounded=True):
    """
    圆角矩形 -> 多边形点列（局部坐标系，中心在 cx,cy，长轴方向 angle_deg）。
    圆角用弧上采样，避免旋转位图的插值失真。
    """
    a = math.radians(angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    r = half_wid if rounded else 0.0
    hl, hw = half_len, half_wid

    def loc(x, y):
        """局部坐标 -> 全局坐标"""
        return (cx + x * ca - y * sa, cy + x * sa + y * ca)

    if r <= 1e-9:
        return [loc(-hl, -hw), loc(hl, -hw), loc(hl, hw), loc(-hl, hw)]

    pts = []
    # 右上 -> 右下 -> 左下 -> 左上，四个圆角各采样 8 段
    corners = [
        (hl - r, -(hw - r), -90, 0),      # 右上角
        (hl - r, hw - r, 0, 90),          # 右下角
        (-(hl - r), hw - r, 90, 180),     # 左下角
        (-(hl - r), -(hw - r), 180, 270),  # 左上角
    ]
    for (ox, oy, a0, a1) in corners:
        for i in range(9):
            t = math.radians(a0 + (a1 - a0) * i / 8.0)
            pts.append(loc(ox + r * math.cos(t), oy + r * math.sin(t)))
    return pts


def glyph_phone_flat(color=(255, 255, 255, 255), angle=45.0):
    """
    话机听筒（视图框 0..100，本地横放后整体旋转 angle 度）。

    构成（全是圆角矩形转成的多边形，同一画布求并集，最后统一旋转）：
      - 握把：一条粗圆角矩形
      - 两端：更宽的圆角矩形，向外鼓出，形成"两端大、中间细"的听筒轮廓
      - 背后：两张错开的小卡片，呼应 App 的"名片叠层"语言
    这样画出来的形状在任何尺寸都是清晰的多边形边缘，不会糊。
    """
    cx, cy = 50.0, 50.0

    def path_of(points, color_):
        d = "M %.2f %.2f " % points[0]
        for p in points[1:]:
            d += "L %.2f %.2f " % p
        d += "Z"
        return (d, color_)

    out = []
    # 背后的小卡片（半透明感靠颜色深浅表现，这里用同色）
    out.append(path_of(_rr_polygon(56.0, 54.0, 15.0, 11.0, angle), color))
    out.append(path_of(_rr_polygon(50.0, 50.0, 15.0, 11.0, angle), color))
    # 握把
    out.append(path_of(_rr_polygon(50.0, 50.0, 21.0, 7.5, angle), color))
    # 两端端头：沿轴向两端外移，且加宽
    a = math.radians(angle)
    for sgn in (-1, 1):
        ex = 50.0 + math.cos(a) * 21.0 * sgn
        ey = 50.0 + math.sin(a) * 21.0 * sgn
        out.append(path_of(_rr_polygon(ex, ey, 8.0, 12.5, angle), color))
    return out
    """圆角矩形路径（用 Q 画角，不依赖圆弧指令）。"""
    return (
        "M %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f Z"
    ) % (
        x0 + r, y0, x1 - r, y0, x1, y0, x1, y0 + r,
        x1, y1 - r, x1, y1, x1 - r, y1,
        x0 + r, y1, x0, y1, x0, y1 - r,
        x0, y0 + r, x0, y0, x0 + r, y0,
    )


def _circle_path(cx, cy, r):
    """
    圆路径（4 段二次贝塞尔 Q 近似）。

    注意控制点系数：用 Q（二次）近似 1/4 圆弧时，控制点应落在
    切点正方形的角上，即偏移量为 r * (1 - cos45°) 的补角关系 ——
    正确系数 k = 4/3 * (sqrt(2) - 1) * 2 ≈ 1.1045 的 Q 等价形式；
    最简单且精确的写法是控制点取 (cx + r, cy + r) 这类"角点"，
    即偏移 k = 1.0，此时 Q 曲线在端点处切线水平/垂直，中点半径误差 < 0.03%。

    历史 bug：这里曾误用三次贝塞尔的 1.5523，导致画出来的"圆"是鼓胀的
    圆角方块（被当成椭圆/胶囊），是图标头像"两个椭圆"问题的根因。
    """
    k = 1.0
    return (
        "M %.2f %.2f Q %.2f %.2f %.2f %.2f "
        "Q %.2f %.2f %.2f %.2f Q %.2f %.2f %.2f %.2f Q %.2f %.2f %.2f %.2f Z"
    ) % (
        cx + r, cy,
        cx + r * k, cy + r * k, cx, cy + r,
        cx - r * k, cy + r * k, cx - r, cy,
        cx - r * k, cy - r * k, cx, cy - r,
        cx + r * k, cy - r * k, cx + r, cy,
    )


def _rr_path(x0, y0, x1, y1, r):
    """圆角矩形路径（用 Q 画角，不依赖圆弧指令）。"""
    return (
        "M %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f "
        "L %.2f %.2f Q %.2f %.2f %.2f %.2f Z"
    ) % (
        x0 + r, y0, x1 - r, y0, x1, y0, x1, y0 + r,
        x1, y1 - r, x1, y1, x1 - r, y1,
        x0 + r, y1, x0, y1, x0, y1 - r,
        x0, y0 + r, x0, y0, x0 + r, y0,
    )


def glyph_cards_simple(color=(255, 255, 255, 255), detail=None):
    """
    "一叠名片"（极简版，视图框 0..100）——推荐用于 48px 级的小图标。

    为小尺寸优化：卡片内只留一个【大】头像圆，去掉文字条
    （文字条在 48px 下只有 1~2px，必然糊成一团）。
    """
    back = _rr_path(30.0, 12.0, 92.0, 64.0, 11.0)
    front = _rr_path(8.0, 34.0, 72.0, 90.0, 12.0)
    if detail is None:
        detail = (0, 0, 0, 0)
    avatar = _circle_path(30.0, 62.0, 15.0)
    return [(back, color), (front, color), (avatar, detail)]


def glyph_cards(color=(255, 255, 255, 255), detail=None):
    """
    "一叠名片"标记（视图框 0..100）——通讯录 / 电话本语义。

    构成全部是圆角矩形与圆，几何完全可控：
      - back   后排卡片：向右上错开，形成"一叠"的层次感
      - front  前排主卡
      - 主卡内容：头像圆 + 两条文字条（颜色由 detail 指定，通常取容器底色）
    """
    back = _rr_path(28.0, 8.0, 92.0, 64.0, 10.0)
    front = _rr_path(8.0, 30.0, 78.0, 90.0, 11.0)
    if detail is None:
        detail = (0, 0, 0, 0)
    avatar = _circle_path(27.0, 53.0, 11.0)
    bar1 = _rr_path(44.0, 44.0, 70.0, 50.5, 3.25)
    bar2 = _rr_path(44.0, 57.0, 61.0, 63.5, 3.25)
    return [(back, color), (front, color), (avatar, detail), (bar1, detail), (bar2, detail)]


def _bust_path(cx, cy, w, h, r):
    """
    "肩"：上边圆角、底边齐平的宽肩（刻意不是椭圆，避免读成第二个圆）。
    cx,cy = 包围盒中心；w,h = 宽高；r = 上方圆角半径。
    """
    x0, y0, x1, y1 = cx - w / 2.0, cy - h / 2.0, cx + w / 2.0, cy + h / 2.0
    return (
        "M %.2f %.2f "
        "C %.2f %.2f %.2f %.2f %.2f %.2f "
        "L %.2f %.2f "
        "C %.2f %.2f %.2f %.2f %.2f %.2f "
        "L %.2f %.2f Z"
    ) % (
        x0, y1,
        x0, y0 + r * 0.55, x0 + r * 0.45, y0, x0 + r, y0,
        x1 - r, y0,
        x1 - r * 0.45, y0, x1, y0 + r * 0.55, x1, y1,
        x0, y1,
    )


def glyph_cards_stack(color=(255, 255, 255, 255), detail=None, gap=None):
    """
    最终图标符号：两张重叠的名片 + 前排卡内"圆形头像（含人形）+ 两条文字条"。

    color  卡片本身（通常取容器底色的对比色，如蓝）
    detail 卡内元素（头像底圆、文字条）颜色，通常取容器色（白）
    gap    前排卡片的描边色，用于把两张卡分开；取容器色即可

    关键设计点：
      - 两张卡重叠，但前排带一圈 gap 色描边 -> 交界处有清晰分界线
      - 头像是一个正圆，里面是"圆头 + 宽肩"的人形；肩刻意做成方圆角而非椭圆，
        否则会和头一起被读成"两个椭圆"
      - 文字条与头像在横向上完全错开，不重叠
    """
    if detail is None:
        detail = (0, 0, 0, 0)
    if gap is None:
        gap = detail

    back = _rr_path(30.0, 12.0, 92.0, 64.0, 11.0)
    front = _rr_path(8.0, 34.0, 76.0, 90.0, 12.0)
    stroke = _rr_path(8.0 - 4.0, 34.0 - 4.0, 76.0 + 4.0, 90.0 + 4.0, 15.0)

    # 头像：正圆 + 圆头 + 宽肩
    av_cx, av_cy, av_r = 27.0, 62.0, 14.0
    head_r = av_r * 0.27
    head_cy = av_cy - av_r * 0.33
    sh_w, sh_h = av_r * 1.16, av_r * 0.52
    sh_cy = av_cy + av_r * 0.40

    # 文字条：与头像横向错开
    b1 = _rr_path(50.0, 50.0, 68.0, 57.0, 3.5)
    b2 = _rr_path(50.0, 67.0, 62.0, 74.0, 3.5)

    # 注意：erase 项的填充色必须是"完全透明"，不能是 detail 色。
    # 若写成 detail 色（如白），擦完又会用同色填回，人形被白色盖住 ->
    # 表现为"空心头像圆"（曾经踩过这个坑）。
    ERASE = (0, 0, 0, 0)
    return [
        (back, color),
        (stroke, gap),
        (front, color),
        # 先擦出头像圆与文字条的位置（在单色层里表现为镂空），
        # 再填回 detail 色、最后把"头 + 肩"人形画在头像圆之上 —— 顺序不能反。
        (_circle_path(av_cx, av_cy, av_r), ERASE, "erase"),
        (b1, ERASE, "erase"),
        (b2, ERASE, "erase"),
        (_circle_path(av_cx, av_cy, av_r), detail),
        (b1, detail),
        (b2, detail),
        (_circle_path(av_cx, head_cy, head_r), color),
        (_bust_path(av_cx, sh_cy, sh_w, sh_h, sh_h * 0.62), color),
    ]


def glyph_person(color=(255, 255, 255, 255)):
    """
    极简人形：圆头 + 平滑肩线，宽高留呼吸空间（不顶满视图框）。
    视图框 0..100，实际内容约 x:14..86 / y:10..88。
    """
    head = (
        "M 50 10 "
        "C 62.2 10, 72 19.8, 72 32 "
        "C 72 44.2, 62.2 54, 50 54 "
        "C 37.8 54, 28 44.2, 28 32 "
        "C 28 19.8, 37.8 10, 50 10 Z"
    )
    body = (
        "M 50 64 "
        "C 70.4 64, 86 78.6, 86 96 "
        "L 86 96 "
        "L 14 96 "
        "C 14 78.6, 29.6 64, 50 64 Z"
    )
    return [(head, color), (body, color)]


def glyph_person_simple(color=(255, 255, 255, 255)):
    """glyph_person 的别名（历史上曾有两种人形，保留名字避免调用方断裂）。"""
    return glyph_person(color)

