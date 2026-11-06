"""Gera os ícones do app (Android e iOS) a partir de um desenho simples.

Uso: python3 tool/make_icons.py
"""
import json
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AMBER = (0xFF, 0xB5, 0x47)
ORANGE = (0xFF, 0x7A, 0x3D)


def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(AMBER, ORANGE))
    return img


def glyph(draw, size, scale=1.0):
    c = size / 2
    w = size * 0.065 * scale
    r_dot = size * 0.08 * scale
    draw.ellipse([c - r_dot, c - r_dot, c + r_dot, c + r_dot], fill=(255, 255, 255, 255))
    sweep = math.degrees(1.15)
    for i, alpha in ((1, 255), (2, 184)):
        r = size * (0.13 + 0.115 * i) * scale
        outer = r + w / 2  # o traço do PIL cresce para dentro da caixa
        box = [c - outer, c - outer, c + outer, c + outer]
        color = (255, 255, 255, alpha)
        for start in (-sweep / 2, 180 - sweep / 2):
            draw.arc(box, start, start + sweep, fill=color, width=max(1, int(round(w))))
            # pontas arredondadas
            for ang in (start, start + sweep):
                a = math.radians(ang)
                x, y = c + r * math.cos(a), c + r * math.sin(a)
                rr = w / 2
                draw.ellipse([x - rr, y - rr, x + rr, y + rr], fill=color)


def render(size, rounded, ss=4):
    big = size * ss
    base = gradient(big).convert("RGBA")
    overlay = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    glyph(ImageDraw.Draw(overlay), big)
    img = Image.alpha_composite(base, overlay)
    if rounded:
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.28), fill=255)
        img.putalpha(mask)
    img = img.resize((size, size), Image.LANCZOS)
    return img


def android():
    sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for name, size in sizes.items():
        d = os.path.join(ROOT, "android/app/src/main/res", f"mipmap-{name}")
        os.makedirs(d, exist_ok=True)
        render(size, rounded=True).save(os.path.join(d, "ic_launcher.png"))
    # Ícone adaptativo (Android 8+): fundo em gradiente + desenho vetorial.
    res = os.path.join(ROOT, "android/app/src/main/res")
    os.makedirs(os.path.join(res, "mipmap-anydpi-v26"), exist_ok=True)
    with open(os.path.join(res, "mipmap-anydpi-v26", "ic_launcher.xml"), "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@drawable/ic_launcher_background" />\n'
            '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
            '    <monochrome android:drawable="@drawable/ic_launcher_foreground" />\n'
            '</adaptive-icon>\n'
        )
    with open(os.path.join(res, "drawable", "ic_launcher_background.xml"), "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n'
            '    <gradient android:angle="315" android:startColor="#FFFFB547" android:endColor="#FFFF7A3D" />\n'
            '</shape>\n'
        )
    # Desenho centrado na zona segura (66dp dos 108dp).
    vp, c = 108.0, 54.0
    unit = 66.0  # o desenho original ocupa "size"; aqui size = 66
    stroke = unit * 0.065
    dot = unit * 0.08
    sweep = 1.15
    paths = [
        f'    <path android:fillColor="#FFFFFFFF" android:pathData="M{c - dot:.2f},{c:.2f}a{dot:.2f},{dot:.2f} 0 1,0 {2 * dot:.2f},0a{dot:.2f},{dot:.2f} 0 1,0 {-2 * dot:.2f},0" />'
    ]
    for i, alpha in ((1, "FF"), (2, "B8")):
        r = unit * (0.13 + 0.115 * i)
        for start in (-sweep / 2, math.pi - sweep / 2):
            x1, y1 = c + r * math.cos(start), c + r * math.sin(start)
            x2, y2 = c + r * math.cos(start + sweep), c + r * math.sin(start + sweep)
            paths.append(
                f'    <path android:strokeColor="#{alpha}FFFFFF" android:strokeWidth="{stroke:.2f}" '
                f'android:strokeLineCap="round" android:fillColor="#00000000" '
                f'android:pathData="M{x1:.2f},{y1:.2f}A{r:.2f},{r:.2f} 0 0,1 {x2:.2f},{y2:.2f}" />'
            )
    with open(os.path.join(res, "drawable", "ic_launcher_foreground.xml"), "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:width="108dp" android:height="108dp"\n'
            f'    android:viewportWidth="{vp:.0f}" android:viewportHeight="{vp:.0f}">\n'
            + "\n".join(paths)
            + "\n</vector>\n"
        )


def ios(template_contents):
    d = os.path.join(ROOT, "ios/Runner/Assets.xcassets/AppIcon.appiconset")
    os.makedirs(d, exist_ok=True)
    with open(template_contents) as f:
        contents = json.load(f)
    for img in contents["images"]:
        pts = float(img["size"].split("x")[0])
        scale = int(img["scale"].replace("x", ""))
        px = int(round(pts * scale))
        render(px, rounded=False).convert("RGB").save(os.path.join(d, img["filename"]))
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


if __name__ == "__main__":
    import sys

    android()
    tpl = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        ROOT, "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json")
    ios(tpl)
    print("ok")
