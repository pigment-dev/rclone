#!/usr/bin/env python3
"""Builds every PigmentDev rClone logo file from one set of numbers.

Run from anywhere:  python3 brand/tools/build_brand.py
Needs: python3 with fonttools + uharfbuzz (pip3 install fonttools uharfbuzz).
Fonts are read from brand/fonts (Red Hat, OFL) and converted to paths,
so the SVGs render the same everywhere without any font installed.
"""
import math, os
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
import uharfbuzz as hb

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BRAND = os.path.join(ROOT, "brand")
FONTS = os.path.join(BRAND, "fonts")

INK, PAPER, ORANGE, STAGE = "#0B0B0B", "#F3F4F5", "#EB5E28", "#191919"

# ---------------------------------------------------------------- the mark
# 100-unit grid. A ring (centre CX,CY radius R) drawn with stroke SW.
# Arrow 1: stem from the foot up the ring's left side, over the top, ends at A1 deg.
# Arrow 2: a short arc on the lower right (B0..B1 deg) chasing back to the stem.
# Angles are degrees clockwise from 12 o'clock.
CX, CY, R, SW = 60, 41, 30, 13
FOOT = 92
A1 = 48
B0, B1 = 120, 172
HW, HL, BEND = 23, 20, 10  # arrowhead width, length, inward bend (deg)


def pt(r, a, cx=CX, cy=CY):
    t = math.radians(a)
    return (cx + r * math.sin(t), cy - r * math.cos(t))


def f(p):
    return f"{p[0]:.2f} {p[1]:.2f}"


def head(a):
    t = math.radians(a)
    b = pt(R, a - 0.3)
    T = (math.cos(t), math.sin(t))
    N = (math.sin(t), -math.cos(t))
    tb = math.tan(math.radians(BEND))
    tip = (b[0] + T[0] * HL - N[0] * HL * tb, b[1] + T[1] * HL - N[1] * HL * tb)
    o = (b[0] + N[0] * HW / 2, b[1] + N[1] * HW / 2)
    i = (b[0] - N[0] * HW / 2, b[1] - N[1] * HW / 2)
    return f"M{f(o)}L{f(tip)}L{f(i)}Z"


def body_paths():
    sx = CX - R
    p1 = pt(R, A1)
    a = f"M{sx} {FOOT}V{CY}A{R} {R} 0 0 1 {f(p1)}"
    q0, q1 = pt(R, B0), pt(R, B1)
    b = f"M{f(q0)}A{R} {R} 0 0 1 {f(q1)}"
    return a, b


def mark_group(body, accent, small=False):
    a, b = body_paths()
    g = [f'<path d="{a}" fill="none" stroke="{body}" stroke-width="{SW}"/>',
         f'<path d="{head(A1)}" fill="{accent}"/>']
    if not small:
        g += [f'<path d="{b}" fill="none" stroke="{body}" stroke-width="{SW}"/>',
              f'<path d="{head(B1)}" fill="{accent}"/>']
    return "".join(g)


# Visual bounds of the mark on the 100 grid (measured once from a render).
MB = (23.5, 4.5, 93.0, 92.0)  # x0, y0, x1, y1


def svg(w, h, vb, inner, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="{vb}" '
            f'role="img" aria-label="{title}"><title>{title}</title>{inner}</svg>\n')


# ---------------------------------------------------------------- text to paths
_cache = {}


def font(name, wght):
    key = (name, wght)
    if key not in _cache:
        path = os.path.join(FONTS, f"{name}.ttf")
        tt = TTFont(path)
        inst = instantiateVariableFont(tt, {"wght": wght})
        blob = hb.Blob.from_file_path(path)
        face = hb.Face(blob)
        hbf = hb.Font(face)
        hbf.set_variations({"wght": wght})
        _cache[key] = (inst, hbf, tt["head"].unitsPerEm)
    return _cache[key]


def text_path(s, name, wght, size, x, y, tracking=0.0):
    """Return (list of (char, d)), advance width in px. Baseline at y."""
    inst, hbf, upm = font(name, wght)
    buf = hb.Buffer()
    buf.add_str(s)
    buf.guess_segment_properties()
    hb.shape(hbf, buf, {"kern": True, "liga": True})
    gs = inst.getGlyphSet()
    order = inst.getGlyphOrder()
    scale = size / upm
    out = []
    pen_x = 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        gname = order[info.codepoint]
        sp = SVGPathPen(gs)
        tp = TransformPen(sp, (scale, 0, 0, -scale, x + (pen_x + pos.x_offset) * scale, y - pos.y_offset * scale))
        gs[gname].draw(tp)
        out.append((s[info.cluster], sp.getCommands()))
        pen_x += pos.x_advance + tracking * upm
    return out, pen_x * scale


def cap_height(name, wght, size):
    inst, _, upm = font(name, wght)
    return inst["OS/2"].sCapHeight * size / upm


# ---------------------------------------------------------------- builders
def write(rel, data):
    p = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        fh.write(data)
    print("wrote", rel)


def mark_svg(body, accent, bg=None, small=False, title="PigmentDev rClone"):
    pad = 6
    x0, y0, x1, y1 = MB
    w, h = x1 - x0, y1 - y0
    side = max(w, h) + 2 * pad
    ox = x0 - (side - w) / 2
    oy = y0 - (side - h) / 2
    inner = ""
    if bg:
        inner += f'<rect x="{ox:.2f}" y="{oy:.2f}" width="{side:.2f}" height="{side:.2f}" fill="{bg}"/>'
    inner += mark_group(body, accent, small)
    return svg(256, 256, f"{ox:.2f} {oy:.2f} {side:.2f} {side:.2f}", inner, title)


def horizontal_svg(body, accent):
    size = 64
    ch = cap_height("RedHatDisplay", 900, size)  # ~45 px
    # mark: scale so its height = 1.62 x cap height, foot on baseline + descender feel
    x0, y0, x1, y1 = MB
    mh = ch * 1.75
    s = mh / (y1 - y0)
    base = 100.0  # baseline y
    my = base - ch / 2 - mh / 2 + ch * 0.0 - (ch * 0.0)
    my = base - ch - (mh - ch) * 0.35  # mark top
    mx = 0
    g = f'<g transform="translate({mx - x0 * s:.2f} {my - y0 * s:.2f}) scale({s:.4f})">{mark_group(body, accent)}</g>'
    tx = (x1 - x0) * s + size * 0.36
    p1, w1 = text_path("PigmentDev", "RedHatText", 500, size, tx, base, tracking=-0.01)
    gap = size * 0.24
    p2, w2 = text_path("rClone", "RedHatDisplay", 900, size, tx + w1 + gap, base, tracking=-0.02)
    paths = "".join(f'<path d="{d}" fill="{body}"/>' for _, d in p1 if d)
    for i, (c, d) in enumerate(p2):
        if d:
            paths += f'<path d="{d}" fill="{accent if i == 0 else body}"/>'
    total_w = tx + w1 + gap + w2 + 4
    top = my - 4
    bottom = max(my + mh, base + size * 0.24) + 4
    vb = f"-4 {top:.2f} {total_w + 4:.2f} {bottom - top:.2f}"
    W = total_w + 4
    H = bottom - top
    return svg(round(W * 2), round(H * 2), vb, g + paths, "PigmentDev rClone")


def squircle(x, y, size, n=5.0, steps=256):
    a = size / 2
    cx, cy = x + a, y + a
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s_ = math.cos(t), math.sin(t)
        px = cx + a * (abs(c) ** (2 / n)) * (1 if c >= 0 else -1)
        py = cy + a * (abs(s_) ** (2 / n)) * (1 if s_ >= 0 else -1)
        pts.append(f"{px:.2f} {py:.2f}")
    return "M" + "L".join(pts) + "Z"


def app_icon_svg():
    # macOS icon grid: 1024 canvas, 824 squircle body at 100,100
    body = squircle(100, 100, 824)
    x0, y0, x1, y1 = MB
    target = 560
    s = target / (y1 - y0)
    mw = (x1 - x0) * s
    ox = 512 - mw / 2 - x0 * s + 6
    oy = 512 - target / 2 - y0 * s
    g = f'<g transform="translate({ox:.2f} {oy:.2f}) scale({s:.4f})">{mark_group(PAPER, ORANGE)}</g>'
    inner = f'<path d="{body}" fill="{INK}"/>' + g
    return svg(1024, 1024, "0 0 1024 1024", inner, "PigmentDev rClone app icon")


def menubar_svg(state="idle"):
    # 18x18 pt template. Mark fits in a 16 pt box, centred. Pure black + alpha only.
    x0, y0, x1, y1 = MB
    box = 16.0
    s = box / (y1 - y0)
    mw = (x1 - x0) * s
    ox = 9 - mw / 2 - x0 * s
    oy = 1 - y0 * s
    m = f'<g transform="translate({ox:.3f} {oy:.3f}) scale({s:.5f})">{mark_group("#000", "#000")}</g>'
    if state == "idle":
        inner = m
    else:
        # knock a hole in the bottom-right corner, then draw the badge in it
        inner = ('<defs><mask id="k" maskUnits="userSpaceOnUse" x="0" y="0" width="18" height="18">'
                 '<rect width="18" height="18" fill="#fff"/><circle cx="14" cy="14" r="5" fill="#000"/></mask></defs>'
                 f'<g mask="url(#k)">{m}</g>')
        if state == "attention":
            inner += '<circle cx="14" cy="14" r="3.4" fill="#000"/>'
        else:  # paused
            inner += '<rect x="11.6" y="10.8" width="1.8" height="6.4" rx=".5" fill="#000"/><rect x="14.6" y="10.8" width="1.8" height="6.4" rx=".5" fill="#000"/>'
    return svg(18, 18, "0 0 18 18", inner, f"PigmentDev rClone menu bar {state}")


def favicon_svg():
    # transparent mark that follows the browser theme
    x0, y0, x1, y1 = MB
    pad = 2
    side = max(x1 - x0, y1 - y0) + 2 * pad
    ox = x0 - (side - (x1 - x0)) / 2
    oy = y0 - pad
    a, b = body_paths()
    inner = ('<style>.b{stroke:#0B0B0B}@media (prefers-color-scheme:dark){.b{stroke:#F3F4F5}}</style>'
             f'<path class="b" d="{a}" fill="none" stroke-width="{SW}"/><path d="{head(A1)}" fill="{ORANGE}"/>'
             f'<path class="b" d="{b}" fill="none" stroke-width="{SW}"/><path d="{head(B1)}" fill="{ORANGE}"/>')
    return svg(32, 32, f"{ox:.2f} {oy:.2f} {side:.2f} {side:.2f}", inner, "PigmentDev rClone")


def touch_icon_svg():
    x0, y0, x1, y1 = MB
    target = 108
    s = target / (y1 - y0)
    mw = (x1 - x0) * s
    ox = 90 - mw / 2 - x0 * s + 1
    oy = 90 - target / 2 - y0 * s
    g = f'<g transform="translate({ox:.2f} {oy:.2f}) scale({s:.4f})">{mark_group(PAPER, ORANGE)}</g>'
    return svg(180, 180, "0 0 180 180", f'<rect width="180" height="180" fill="{INK}"/>' + g, "PigmentDev rClone")


def icon_composer_layers():
    """Two 1024 layers for mac/Resources/AppIcon.icon: body (paper) and arrowheads (orange)."""
    x0, y0, x1, y1 = MB
    target = 560
    sc = target / (y1 - y0)
    mw = (x1 - x0) * sc
    ox = 512 - mw / 2 - x0 * sc + 6
    oy = 512 - target / 2 - y0 * sc
    a, b = body_paths()
    tr = f'transform="translate({ox:.2f} {oy:.2f}) scale({sc:.4f})"'
    body = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><g {tr} fill="none" stroke="{PAPER}" stroke-width="{SW}">'
            f'<path d="{a}"/><path d="{b}"/></g></svg>\n')
    heads = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><g {tr} fill="{ORANGE}">'
             f'<path d="{head(A1)}"/><path d="{head(B1)}"/></g></svg>\n')
    return body, heads


ICON_JSON = """{
  "fill" : {
    "solid" : "srgb:0.04314,0.04314,0.04314,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        { "glass" : true, "image-name" : "arrowheads.svg", "name" : "arrowheads" },
        { "glass" : true, "image-name" : "body.svg", "name" : "body" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.3 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
"""


if __name__ == "__main__":
    _b, _h = icon_composer_layers()
    write("mac/Resources/AppIcon.icon/Assets/body.svg", _b)
    write("mac/Resources/AppIcon.icon/Assets/arrowheads.svg", _h)
    write("mac/Resources/AppIcon.icon/icon.json", ICON_JSON)
    write("brand/favicon.svg", favicon_svg())
    write("brand/apple-touch-icon.svg", touch_icon_svg())
    write("brand/logo-mark.svg", mark_svg(INK, ORANGE))
    write("brand/logo-mark-dark.svg", mark_svg(PAPER, ORANGE))
    write("brand/logo-mono.svg", mark_svg("currentColor", "currentColor"))
    write("brand/logo-mark-small.svg", mark_svg(INK, ORANGE, small=True))
    write("brand/logo-horizontal.svg", horizontal_svg(INK, ORANGE))
    write("brand/logo-horizontal-dark.svg", horizontal_svg(PAPER, ORANGE))
    write("brand/app-icon.svg", app_icon_svg())
    write("brand/menubar-template.svg", menubar_svg("idle"))
    write("brand/menubar-template-attention.svg", menubar_svg("attention"))
    write("brand/menubar-template-paused.svg", menubar_svg("paused"))
