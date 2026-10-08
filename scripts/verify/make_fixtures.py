#!/usr/bin/env python3
"""Build face fixtures from AI-generated source portraits (PhotoShareTests/Fixtures/sources).

Sources: 4 synthetic (non-real-person) portraits from the SFHQ "Synthetic Faces High Quality"
dataset (bitmind/SyntheticFacesHQ on Hugging Face, preview rows 12/24/48/84 of 100).
"Same person" photos are augmented variants (pose, zoom, lighting, mirror, blur, JPEG) of the
one source, so this checks pipeline integrity / regressions, not real-world recognition accuracy.

Wide-shot probes (every identity) put the face small inside a larger scene with a soft-edged paste on a blurred,
tinted background taken from another portrait; group probes hold two enrolled identities. Everything is still synthetic
compositing of one source image per identity, so it measures detector/alignment robustness to scale, roll, light and
JPEG, NOT cross-photo identity variation (age, expression, real pose changes).

Special probes (alice only) regression-test past bugs: EXIF-rotated pixel data and a very large
(4032x3024) photo with a small off-centre face (downsample / crop-scale).
"""
import json, random
from pathlib import Path
from PIL import Image, ImageEnhance, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parents[2] / "PhotoShareTests/Fixtures"
SRC, OUT = ROOT / "sources", ROOT / "faces"
NAMES = ["alice", "bob", "carol", "dan", "erin", "frank", "grace", "heidi", "ivan", "judy", "ken", "lena", "mia", "nick", "olga", "pete"]

def variant(img, i, rng):
    """i=0 original; others progressively different 'photos' of the same person."""
    S = 512
    im = img.copy()
    if i == 1:   # slight turn + zoom in
        im = im.rotate(rng.uniform(5, 9), resample=Image.BICUBIC, expand=False).resize((int(S * 1.15),) * 2)
        o = (im.width - S) // 2; im = im.crop((o, o, o + S, o + S))
        im = ImageEnhance.Brightness(im).enhance(0.88)
    elif i == 2:  # mirrored, warmer, softer
        im = ImageOps.mirror(im); im = ImageEnhance.Color(im).enhance(1.25).filter(ImageFilter.GaussianBlur(0.9))
    elif i == 3:  # farther away: face small inside a wider scene
        small = im.resize((int(S * .6),) * 2, Image.LANCZOS)
        bg = im.resize((S, S)).filter(ImageFilter.GaussianBlur(25))
        bg.paste(small, (rng.randint(60, 140), rng.randint(60, 140))); im = ImageEnhance.Contrast(bg).enhance(1.1)
    return im

def scene(w, h, bg_src, rng):
    """Blurred, darkened/tinted background built from a (different) portrait: plausible bokeh, no hard edges."""
    c = rng.randint(0, 150)
    bg = bg_src.crop((c, c, c + 360, c + 360)).resize((w, w), Image.BICUBIC).crop((0, 0, w, h))
    bg = bg.filter(ImageFilter.GaussianBlur(18))
    return ImageEnhance.Brightness(bg).enhance(rng.uniform(0.6, 0.95))

def paste_face(bg, face, size, xy):
    """Soft elliptical-feathered paste so the composite has no rectangle edge."""
    f = face.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(mask).ellipse((size * .02, size * .0, size * .98, size * 1.0), fill=255)
    bg.paste(f, xy, mask.filter(ImageFilter.GaussianBlur(size * .04)))

def extra_probes(name, base, others, rng):
    """(kind, identities-in-photo, image) probes appended per identity."""
    out = []
    o1, o2 = others
    W, H = 800, 600
    # wide: head ~19% of frame width
    im = scene(W, H, o1[1], rng); paste_face(im, base, 240, (rng.randint(60, W - 300), rng.randint(60, H - 300)))
    out.append(("wide", [name], im))
    # tiny: head ~12% of frame width
    im = scene(W, H, o2[1], rng); paste_face(im, base, 150, (rng.randint(60, W - 210), rng.randint(60, H - 210)))
    out.append(("tiny", [name], im))
    # group: two enrolled identities side by side
    im = scene(W, H, o1[1], rng)
    paste_face(im, base, 250, (rng.randint(60, 140), rng.randint(120, 260)))
    paste_face(im, o2[1], 290, (rng.randint(420, 480), rng.randint(100, 220)))
    out.append(("group", [name, o2[0]], im))
    # roll + dim + noise + heavy JPEG
    im = base.rotate(rng.choice([-1, 1]) * rng.uniform(18, 26), resample=Image.BICUBIC, fillcolor=(40, 40, 40))
    im = ImageEnhance.Brightness(im).enhance(0.7)
    px = im.load()
    for _ in range(9000):
        x, y = rng.randrange(512), rng.randrange(512); v = rng.randint(-35, 35)
        r, g, b = px[x, y]; px[x, y] = (max(0, min(255, r + v)), max(0, min(255, g + v)), max(0, min(255, b + v)))
    out.append(("roll_dim_noise", [name], im))
    return out

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*"): f.unlink()
    manifest = []
    for name in NAMES:
        base = Image.open(SRC / f"{name}.jpg").convert("RGB")
        for i in range(4):
            fn = f"{name}_{i + 1}.jpg"
            variant(base, i, random.Random(f"{name}{i}")).save(OUT / fn, quality=88)
            manifest.append({"identity": name, "file": fn, "kind": "normal", "role": "enroll" if i < 2 else "probe", "identities": [name]})
    base = Image.open(SRC / "alice.jpg").convert("RGB")
    # EXIF orientation 6: stored pixels rotated CCW, tag says "rotate CW to display".
    stored = base.rotate(90, expand=True)
    exif = Image.Exif(); exif[0x0112] = 6
    stored.save(OUT / "alice_5_exif_rotated.jpg", quality=88, exif=exif)
    manifest.append({"identity": "alice", "file": "alice_5_exif_rotated.jpg", "kind": "exif_rotated", "role": "probe", "identities": ["alice"]})
    # Large 4032x3024 camera-style frame, face ~800px, off-centre, smooth background.
    W, H = 4032, 3024
    bg = base.resize((64, 64)).filter(ImageFilter.GaussianBlur(4)).resize((W, H), Image.BICUBIC)
    bg.paste(base.resize((900, 900), Image.LANCZOS), (2300, 700))
    bg.save(OUT / "alice_6_large.jpg", quality=80)
    manifest.append({"identity": "alice", "file": "alice_6_large.jpg", "kind": "large", "role": "probe", "identities": ["alice"]})
    bases = {n: Image.open(SRC / f"{n}.jpg").convert("RGB") for n in NAMES}
    for k, name in enumerate(NAMES):
        rng = random.Random(f"extra{name}")
        others = [(NAMES[(k + 3) % len(NAMES)], None), (NAMES[(k + 7) % len(NAMES)], None)]
        others = [(n, bases[n]) for n, _ in others]
        for j, (kind, ids, im) in enumerate(extra_probes(name, bases[name], others, rng)):
            fn = f"{name}_{7 + j}_{kind}.jpg"
            im.save(OUT / fn, quality=70 if kind == "roll_dim_noise" else 85)
            manifest.append({"identity": name, "file": fn, "kind": kind, "role": "probe", "identities": ids})
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(manifest)} fixtures to {OUT}")

main()
