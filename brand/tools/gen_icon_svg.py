# 生成图标、分层和菜单栏图标的 SVG 源文件。
# 用法：python3 brand/tools/gen_icon_svg.py brand
import math, os, sys
OUT = sys.argv[1]
os.makedirs(f"{OUT}/icon/layers", exist_ok=True); os.makedirs(f"{OUT}/menubar", exist_ok=True)

def squircle(cx=512, cy=512, a=412, n=5.0, steps=240):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{cx + a * math.copysign(abs(c) ** (2 / n), c):.1f} {cy + a * math.copysign(abs(s) ** (2 / n), s):.1f}")
    return "M" + " L".join(pts) + " Z"

def arc(cx, cy, r, deg):
    a = math.radians(deg)
    x, y1, y2 = cx + r * math.cos(a), cy - r * math.sin(a), cy + r * math.sin(a)
    return f"M{x:.1f} {y1:.1f} A{r} {r} 0 0 1 {x:.1f} {y2:.1f}"

DEFS = """<defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E66B3F"/><stop offset="1" stop-color="#C94F28"/></linearGradient>
    <linearGradient id="body" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFFBF8"/><stop offset="1" stop-color="#F6E5DA"/></linearGradient>
  </defs>"""

def mark(small=False):
    if small:
        # 16/32 像素用的简化版：一道声波、更粗的线、去掉指示灯
        x, y, w, h, bx, by, br = 318, 325, 230, 440, 433, 455, 66
        arcs = [(235, 42, 76)]
        dot = ""
    else:
        x, y, w, h, bx, by, br = 313, 321, 200, 430, 413, 444, 56
        arcs = [(185, 40, 44), (275, 40, 44)]
        dot = f'<circle cx="{bx}" cy="{y + h - 115}" r="20" fill="#F0997B"/>'
    waves = "\n    ".join(f'<path d="{arc(bx, by, r, d)}" fill="none" stroke="#FFF7F2" stroke-width="{sw}" stroke-linecap="round"/>' for r, d, sw in arcs)
    return f"""<g>
    <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{w / 2}" fill="url(#body)"/>
    <circle cx="{bx}" cy="{by}" r="{br}" fill="#D85A30"/>
    {dot}
    {waves}
  </g>"""

def svg(body, size=1024, title="掌声 VoxPalm"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">\n  <title>{title}</title>\n  {body}\n</svg>\n'

sq = squircle()
open(f"{OUT}/icon/VoxPalm-icon.svg", "w").write(svg(f'{DEFS}\n  <path d="{sq}" fill="url(#bg)"/>\n  {mark()}'))
open(f"{OUT}/icon/VoxPalm-icon-small.svg", "w").write(svg(f'{DEFS}\n  <path d="{sq}" fill="url(#bg)"/>\n  {mark(small=True)}', title="掌声 VoxPalm（16/32 像素简化版）"))
open(f"{OUT}/icon/layers/background.svg", "w").write(svg(f'{DEFS}\n  <rect width="1024" height="1024" fill="url(#bg)"/>', title="掌声 VoxPalm 背景层"))
open(f"{OUT}/icon/layers/foreground.svg", "w").write(svg(f'{DEFS}\n  {mark()}', title="掌声 VoxPalm 前景层"))

# 菜单栏模板图标：36 网格（@2x），按 18pt 显示；黑色 + 透明，系统自动适配深浅色
cap = "M11.5 6 A5.5 5.5 0 0 1 17 11.5 V26.5 A5.5 5.5 0 0 1 6 26.5 V11.5 A5.5 5.5 0 0 1 11.5 6 Z"
hole = "M11.5 10.3 A3.2 3.2 0 1 0 11.5 16.7 A3.2 3.2 0 1 0 11.5 10.3 Z"
mb = f"""<path d="{cap} {hole}" fill="#000" fill-rule="evenodd"/>
  <path d="{arc(11.5, 13.5, 11, 40)}" fill="none" stroke="#000" stroke-width="2.8" stroke-linecap="round"/>
  <path d="{arc(11.5, 13.5, 17, 40)}" fill="none" stroke="#000" stroke-width="2.8" stroke-linecap="round"/>"""
open(f"{OUT}/menubar/MenuBarIconTemplate.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 36 36">\n  <title>掌声 VoxPalm 菜单栏图标</title>\n  {mb}\n</svg>\n')
print("done")
