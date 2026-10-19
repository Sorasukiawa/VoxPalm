# 生成图标、分层和菜单栏图标的 SVG 源文件。
# 图形：● 按钮 → 声波 → 一行行文字和光标，讲「按住说话，松手出字」。
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

DEFS = """<defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2B2840"/><stop offset="1" stop-color="#17151F"/></linearGradient>
    <linearGradient id="hot" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF8A5C"/><stop offset="1" stop-color="#D85A30"/></linearGradient>
  </defs>"""

def pill(x, y, w, h, fill):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{min(w, h) / 2}" fill="{fill}"/>'

def mark(small=False):
    if small:
        # 16/32 像素用的简化版：按钮 + 一根声波 + 两行字，线条加粗，去掉光标
        dx = 24
        button = (250 + dx, 512, 86)
        bars = [(372 + dx, 420, 88)]
        lines = [(440, 500 + dx, 812 + dx, 88), (584, 500 + dx, 712 + dx, 88)]
        cursor = ""
    else:
        button = (262, 512, 70)
        bars = [(356, 400, 56), (440, 260, 56)]
        lines = [(420, 532, 820, 56), (512, 532, 770, 56), (604, 532, 668, 56)]
        cursor = pill(692, 566, 24, 76, "#FF7A4D")
    bx, by, br = button
    parts = [
        # 按钮带一点厚度，看起来是能按下去的
        f'<circle cx="{bx}" cy="{by + br * 0.16:.1f}" r="{br}" fill="#A93F1C"/>',
        f'<circle cx="{bx}" cy="{by}" r="{br}" fill="url(#hot)"/>',
    ]
    parts += [pill(x, 512 - h / 2, w, h, "url(#hot)") for x, h, w in bars]
    parts += [pill(x0, cy - h / 2, x1 - x0, h, "#FFF3EA") for cy, x0, x1, h in lines]
    if cursor:
        parts.append(cursor)
    return "<g>\n    " + "\n    ".join(parts) + "\n  </g>"

def svg(body, size=1024, title="掌声 VoxPalm"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">\n  <title>{title}</title>\n  {body}\n</svg>\n'

sq = squircle()
# 深色图标在深色 Dock 上容易和背景糊在一起，加一圈很淡的内描边
rim = f'<path d="{squircle(a=409)}" fill="none" stroke="#6B6590" stroke-opacity="0.45" stroke-width="6"/>'
open(f"{OUT}/icon/VoxPalm-icon.svg", "w").write(svg(f'{DEFS}\n  <path d="{sq}" fill="url(#bg)"/>\n  {rim}\n  {mark()}'))
open(f"{OUT}/icon/VoxPalm-icon-small.svg", "w").write(svg(f'{DEFS}\n  <path d="{sq}" fill="url(#bg)"/>\n  {rim}\n  {mark(small=True)}', title="掌声 VoxPalm（16/32 像素简化版）"))
open(f"{OUT}/icon/layers/background.svg", "w").write(svg(f'{DEFS}\n  <rect width="1024" height="1024" fill="url(#bg)"/>', title="掌声 VoxPalm 背景层"))
open(f"{OUT}/icon/layers/foreground.svg", "w").write(svg(f'{DEFS}\n  {mark()}', title="掌声 VoxPalm 前景层"))

# 菜单栏模板图标：36 网格（@2x），按 18pt 显示；黑色 + 透明，系统自动适配深浅色
mb = "\n  ".join([
    '<circle cx="8" cy="18" r="4.6" fill="#000"/>',
    pill(15.5, 9, 4, 18, "#000"),
    pill(23, 12, 10, 4, "#000"),
    pill(23, 20, 7, 4, "#000"),
])
open(f"{OUT}/menubar/MenuBarIconTemplate.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 36 36">\n  <title>掌声 VoxPalm 菜单栏图标</title>\n  {mb}\n</svg>\n')
print("done")
