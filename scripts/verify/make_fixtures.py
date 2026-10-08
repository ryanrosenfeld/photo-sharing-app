#!/usr/bin/env python3
"""Build face fixtures from AI-generated source portraits (PhotoShareTests/Fixtures/sources).

Sources: 4 synthetic (non-real-person) portraits from the SFHQ "Synthetic Faces High Quality"
dataset (bitmind/SyntheticFacesHQ on Hugging Face, preview rows 12/24/48/84 of 100).
"Same person" photos are augmented variants (pose, zoom, lighting, mirror, blur, JPEG) of the
one source, so this checks pipeline integrity / regressions, not real-world recognition accuracy.

Special probes (alice only) regression-test past bugs: EXIF-rotated pixel data and a very large
(4032x3024) photo with a small off-centre face (downsample / crop-scale).
"""
import json, random
from pathlib import Path
from PIL import Image, ImageEnhance, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parents[2] / "PhotoShareTests/Fixtures"
SRC, OUT = ROOT / "sources", ROOT / "faces"
NAMES = ["alice", "bob", "carol", "dan"]

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

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*"): f.unlink()
    manifest = []
    for name in NAMES:
        base = Image.open(SRC / f"{name}.jpg").convert("RGB")
        for i in range(4):
            fn = f"{name}_{i + 1}.jpg"
            variant(base, i, random.Random(f"{name}{i}")).save(OUT / fn, quality=88)
            manifest.append({"identity": name, "file": fn, "kind": "normal"})
    base = Image.open(SRC / "alice.jpg").convert("RGB")
    # EXIF orientation 6: stored pixels rotated CCW, tag says "rotate CW to display".
    stored = base.rotate(90, expand=True)
    exif = Image.Exif(); exif[0x0112] = 6
    stored.save(OUT / "alice_5_exif_rotated.jpg", quality=88, exif=exif)
    manifest.append({"identity": "alice", "file": "alice_5_exif_rotated.jpg", "kind": "exif_rotated"})
    # Large 4032x3024 camera-style frame, face ~800px, off-centre, smooth background.
    W, H = 4032, 3024
    bg = base.resize((64, 64)).filter(ImageFilter.GaussianBlur(4)).resize((W, H), Image.BICUBIC)
    bg.paste(base.resize((900, 900), Image.LANCZOS), (2300, 700))
    bg.save(OUT / "alice_6_large.jpg", quality=80)
    manifest.append({"identity": "alice", "file": "alice_6_large.jpg", "kind": "large"})
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(manifest)} fixtures to {OUT}")

main()
