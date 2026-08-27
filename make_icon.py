#!/usr/bin/env python3
"""生成 app 图标：一个哑铃 + 一格日历勾，画的就是这个 app 管的事
（私教课时：练什么 + 什么时候）。亮底深字，与 app 内亮色主题一致。
不用外部素材、不联网，重跑结果逐像素一致。"""
from PIL import Image, ImageDraw
import pathlib

S = 1024
BG   = (247, 247, 249)
BAR  = (28, 32, 44)
PLATE= (10, 122, 255)
GRID = (222, 224, 230)
OK   = (52, 199, 89)

img = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(img)

# 淡网格底（日历意象）
for i in range(1, 5):
    v = 150 + (S - 300) * i / 5
    d.line([(150, v), (S - 150, v)], fill=GRID, width=4)
    d.line([(v, 150), (v, S - 150)], fill=GRID, width=4)

# 哑铃：中杠 + 左右两组配重
cy = S * 0.46
d.rounded_rectangle([S*0.30, cy-26, S*0.70, cy+26], radius=26, fill=BAR)
for x in (S*0.20, S*0.74):
    d.rounded_rectangle([x, cy-110, x+60, cy+110], radius=26, fill=PLATE)
for x in (S*0.27, S*0.67):
    d.rounded_rectangle([x, cy-72, x+52, cy+72], radius=20, fill=BAR)

# 勾：这一节记上了
pts = [(S*0.34, S*0.72), (S*0.46, S*0.83), (S*0.70, S*0.60)]
d.line(pts, fill=OK, width=46, joint="curve")

out = pathlib.Path("Resources/Assets.xcassets/AppIcon.appiconset")
out.mkdir(parents=True, exist_ok=True)
img.save(out / "icon-1024.png")
(out / "Contents.json").write_text(
    '{"images":[{"filename":"icon-1024.png","idiom":"universal",'
    '"platform":"ios","size":"1024x1024"}],'
    '"info":{"author":"xcode","version":1}}\n'
)
(out.parent / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
print("✅ 图标已生成:", out / "icon-1024.png")
