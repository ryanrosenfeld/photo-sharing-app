#!/usr/bin/env python3
"""Detection-vs-face-size stress set (NOT committed; ~25 MB): a 4032x3024 camera frame per (identity, head size), the
synthetic portrait pasted with a soft edge on a blurred background. Enrollment photos are copied from the committed fixtures.
Usage: make_scale_probes.py <out dir>; then: scripts/verify/facematch-mac.sh-style run with that dir (see docs/face-matching)."""
import json, random, shutil, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter
ROOT = Path(__file__).resolve().parents[2] / "PhotoShareTests/Fixtures"
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
names = ["alice", "bob", "carol", "dan", "erin", "frank", "grace", "heidi"]
HEAD = {"head50": 50, "head80": 80, "head120": 120, "head200": 200}   # px of Vision-style head box in the 4032 frame
man = []
for n in names:
    for i in (1, 2):
        shutil.copy(ROOT / f"faces/{n}_{i}.jpg", out / f"{n}_{i}.jpg")
        man.append({"identity": n, "file": f"{n}_{i}.jpg", "kind": "enroll", "role": "enroll", "identities": [n]})
for k, n in enumerate(names):
    base = Image.open(ROOT / f"sources/{n}.jpg").convert("RGB")
    other = Image.open(ROOT / f"sources/{names[(k + 3) % len(names)]}.jpg").convert("RGB")
    for kind, head in HEAD.items():
        rng = random.Random(f"{n}{kind}")
        W, H = 4032, 3024
        sw, sh = other.size   # face-free background: gradient between the other portrait's corner colours + soft texture
        tiny = Image.new("RGB", (2, 2)); tiny.putdata([other.getpixel(p) for p in [(8, 8), (sw - 9, 8), (8, sh - 9), (sw - 9, sh - 9)]])
        bg = tiny.resize((W, H), Image.BILINEAR)
        noise = Image.effect_noise((W // 32, H // 32), 40).resize((W, H), Image.BICUBIC).filter(ImageFilter.GaussianBlur(8))
        bg = ImageEnhance.Brightness(Image.blend(bg, Image.merge("RGB", (noise,) * 3), 0.12)).enhance(0.8)
        size = int(head / 0.65)          # Vision box ~0.65 of the portrait width
        f = base.resize((size, size), Image.LANCZOS)
        m = Image.new("L", (size, size), 0); ImageDraw.Draw(m).ellipse((size * .02, 0, size * .98, size), fill=255)
        bg.paste(f, (rng.randint(200, W - size - 200), rng.randint(200, H - size - 200)), m.filter(ImageFilter.GaussianBlur(size * .04)))
        fn = f"{n}_{kind}.jpg"; bg.save(out / fn, quality=85)
        man.append({"identity": n, "file": fn, "kind": kind, "role": "probe", "identities": [n]})
(out / "manifest.json").write_text(json.dumps(man, indent=1))
print(len(man), "entries ->", out)
