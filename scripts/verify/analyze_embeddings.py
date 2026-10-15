#!/usr/bin/env python3
"""Offline metric comparison on dumped embeddings: analyze_embeddings.py <faces dir with manifest.json> <embeddings.json>
Scores (probe photo, enrolled identity) pairs; genuine = identity is in the photo. Reports AUC/EER and TPR at fixed FPR
for raw Euclidean, cosine, and centroid variants (min over faces in the photo, like the app)."""
import json, sys, numpy as np
man = json.load(open(sys.argv[1] + "/manifest.json")); emb = json.load(open(sys.argv[2]))
ids = sorted({m["identity"] for m in man})
def unit(x): x = np.asarray(x, dtype=np.float64); return x / np.linalg.norm(x, axis=-1, keepdims=True)
enr = {i: np.array([emb[m["file"]][0] for m in man if m["identity"] == i and m["role"] == "enroll" and emb[m["file"]]]) for i in ids}
probes = [(m, np.array(emb[m["file"]])) for m in man if m["role"] == "probe" and emb[m["file"]]]
def score(fn):
    g, im = [], []
    for m, faces in probes:
        for i in ids:
            if len(enr[i]) == 0: continue
            d = fn(faces, enr[i]); (g if i in m["identities"] else im).append(d)
    return np.array(g), np.array(im)
def pair_min(metric):
    return lambda F, E: min(metric(f, e) for f in F for e in E)
euc = lambda a, b: np.linalg.norm(a - b)
cos = lambda a, b: 1 - float(unit(a) @ unit(b))
def centroid(metric):
    return lambda F, E: min(metric(f, unit(E).mean(0)) for f in F)
variants = {
  "euclid raw (shipping)": pair_min(euc), "euclid on unit vectors": pair_min(lambda a, b: np.linalg.norm(unit(a) - unit(b))),
  "cosine distance": pair_min(cos), "cosine vs centroid of enrolled": centroid(cos),
}
for name, fn in variants.items():
    g, im = score(fn)
    # AUC = P(genuine < impostor)
    auc = 1 - np.searchsorted(np.sort(im), g, side="left").sum() / (len(g) * len(im))
    srt = np.sort(im)
    out = []
    for fpr in (0, 1e-4, 1e-3, 1e-2):
        t = srt[int(fpr * len(srt))] if fpr > 0 else srt[0]       # threshold below which fpr of impostors fall
        out.append(f"TPR@FPR={fpr:g}: {np.mean(g < t):.3f} (t<{t:.3f})")
    print(f"{name:34s} AUC {auc:.4f}   genuine p50 {np.median(g):.3f} impostor p50 {np.median(im):.3f}   " + "  ".join(out))
