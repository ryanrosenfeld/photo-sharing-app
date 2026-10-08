#!/usr/bin/env python3
"""Generate procedural cartoon face fixtures (no real people, no downloads).

Each identity is a fixed parameter set (skin, face shape, eye spacing, nose, mouth, hair);
each photo of an identity adds pose/lighting/background jitter. Output: JPEGs plus manifest.json.

These are a *pipeline-integrity* fixture (detect -> crop -> embed -> distance), not an accuracy
benchmark: cartoon faces are out-of-distribution for MobileFaceNet. Swap in generated photoreal
faces by dropping files + manifest entries into the same folder (see README.md there).
"""
import json, random, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "PhotoShareTests/Fixtures/faces")
IDENTITIES = ["alice", "bob", "carol", "dan"]
PHOTOS_PER = 4
S = 640

def params(name):
    r = random.Random(name)
    return dict(
        skin=tuple(r.randint(a, b) for a, b in [(150, 245), (100, 200), (70, 170)]),
        hair=tuple(r.randint(10, 160) for _ in range(3)),
        eye=tuple(r.randint(20, 120) for _ in range(3)),
        fw=r.uniform(0.62, 0.80), fh=r.uniform(0.74, 0.92),
        eye_sep=r.uniform(0.2, 0.32), eye_r=r.uniform(0.05, 0.08), eye_y=r.uniform(-0.12, -0.03),
        nose_len=r.uniform(0.07, 0.15), nose_w=r.uniform(0.04, 0.09),
        mouth_w=r.uniform(0.12, 0.26), mouth_y=r.uniform(0.15, 0.24), smile=r.uniform(-0.03, 0.07),
        brow=r.uniform(0.02, 0.06), hair_style=r.choice(["short", "long", "bald"]),
    )

def draw_face(p, rng):
    img = Image.new("RGB", (S, S), tuple(rng.randint(150, 235) for _ in range(3)))
    d = ImageDraw.Draw(img)
    cx, cy = S / 2, S / 2
    fw, fh = p["fw"] * S * 0.62, p["fh"] * S * 0.62
    if p["hair_style"] != "bald":
        hh = fh * (1.12 if p["hair_style"] == "short" else 1.3)
        d.ellipse([cx - fw * 0.58, cy - hh * 0.62, cx + fw * 0.58, cy + hh * (0.2 if p["hair_style"] == "short" else 0.75)], fill=p["hair"])
    d.ellipse([cx - fw / 2, cy - fh / 2, cx + fw / 2, cy + fh / 2], fill=p["skin"])
    ex = p["eye_sep"] * fw; ey = cy + p["eye_y"] * fh; er = p["eye_r"] * fw
    for sx in (-1, 1):
        x = cx + sx * ex
        d.ellipse([x - er * 1.5, ey - er, x + er * 1.5, ey + er], fill=(245, 245, 245))
        d.ellipse([x - er, ey - er, x + er, ey + er], fill=p["eye"])
        d.ellipse([x - er * .4, ey - er * .4, x + er * .4, ey + er * .4], fill=(10, 10, 10))
        by = ey - er * 1.9
        d.line([x - er * 1.6, by + p["brow"] * fh * .3, x + er * 1.6, by - p["brow"] * fh * .3 * sx], fill=p["hair"], width=int(S * .012))
    ny = ey + p["nose_len"] * fh * 2.4
    nw = p["nose_w"] * fw * 1.4
    d.line([cx, ey + er * 1.2, cx - nw * .4, ny], fill=tuple(int(c * .7) for c in p["skin"]), width=int(S * .01))
    d.ellipse([cx - nw, ny - nw * .3, cx + nw, ny + nw * .5], outline=tuple(int(c * .65) for c in p["skin"]), width=int(S * .01))
    my = cy + p["mouth_y"] * fh * 1.6; mw = p["mouth_w"] * fw * 1.5; sm = p["smile"] * fh * 2
    d.line([cx - mw, my, cx, my + sm, cx + mw, my], fill=(150, 50, 60), width=int(S * .016), joint="curve")
    return img

def make_photo(name, p, i):
    rng = random.Random(f"{name}-{i}")
    img = draw_face(p, rng)
    img = img.rotate(rng.uniform(-8, 8), resample=Image.BICUBIC, fillcolor=img.getpixel((2, 2)))
    z = rng.uniform(0.9, 1.1)
    c = int(S * z)
    img = img.resize((c, c), Image.BICUBIC)
    canvas = Image.new("RGB", (S, S), img.getpixel((2, 2)))
    canvas.paste(img, ((S - c) // 2 + rng.randint(-25, 25), (S - c) // 2 + rng.randint(-25, 25)))
    canvas = ImageEnhance.Brightness(canvas).enhance(rng.uniform(0.8, 1.15))
    return canvas.filter(ImageFilter.GaussianBlur(rng.uniform(0, 0.8)))

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name in IDENTITIES:
        p = params(name)
        for i in range(PHOTOS_PER):
            f = f"{name}_{i + 1}.jpg"
            make_photo(name, p, i).save(OUT / f, quality=90)
            manifest.append({"identity": name, "file": f})
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(manifest)} photos to {OUT}")

main()
