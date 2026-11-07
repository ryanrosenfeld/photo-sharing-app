#!/usr/bin/env python3
"""Offline decision-rule sweep on dumped embeddings (facematch-mac.sh <dir> --dump-embeddings), numpy only.
usage: rule_sweep.py <faces dir with manifest.json> <dump dir>
For every (probe photo, enrolled identity) computes the distance statistics a rule could use, then reports recall
(genuine accepted) vs false matches (impostor accepted) per rule, also with the reference set cut to 1 or 2 photos.
Enrollment uses the largest face of each reference photo (like the app); probes use every face (like the app)."""
import json, sys, itertools, numpy as np
man = json.load(open(sys.argv[1] + "/manifest.json")); d = sys.argv[2]
allv = json.load(open(d + "/embeddings.json")); alg = json.load(open(d + "/embeddings_aligned.json")); lar = json.load(open(d + "/embeddings_largest.json"))
PEN = 0.2
unit = lambda x: np.asarray(x, np.float64) / np.linalg.norm(x)
ids = sorted({m["identity"] for m in man})
refs = {i: [m["file"] for m in man if m["identity"] == i and m["role"] == "enroll" and m["file"] in lar] for i in ids}
def ref_aligned(f):  # the largest face's alignment flag: index in all-faces whose vector equals the largest
    for v, a in zip(allv[f], alg[f]):
        if np.allclose(v, lar[f], atol=1e-5): return a
    return False
probes = [m for m in man if m["role"] == "probe" and allv[m["file"]]]
def dists(probe, ident, refset):
    """sorted per-reference min-over-faces distances (with unaligned penalty), plus centroid distance."""
    per = []
    for r in refset:
        best = min(1 - unit(v) @ unit(lar[r]) + (0 if (a and ref_aligned(r)) else PEN) for v, a in zip(allv[probe["file"]], alg[probe["file"]]))
        per.append(best)
    return sorted(per)
def rules(n):
    R = {}
    for t in (.55, .58, .60, .62): R[f"min<{t}"] = lambda p, t=t: p[0] < t
    for lo, hi in ((.55, .60), (.55, .62), (.55, .65), (.50, .60)):
        R[f"min<{lo} or (>=2 refs<{hi})"] = lambda p, lo=lo, hi=hi: p[0] < lo or sum(x < hi for x in p) >= 2
    for t in (.58, .60, .62): R[f"mean of 2 best<{t}"] = lambda p, t=t: len(p) >= 2 and np.mean(p[:2]) < t or (len(p) < 2 and p[0] < .55)
    R["min<.55 or mean2best<.60"] = lambda p: p[0] < .55 or (len(p) >= 2 and np.mean(p[:2]) < .60)
    R["min<.55 or median<.62"] = lambda p: p[0] < .55 or (len(p) >= 2 and np.median(p) < .62)
    return R
for k in (3, 2, 1):
    rows = {}
    stat_g, stat_i = [], []
    for ident in ids:
        for refset in itertools.combinations(refs[ident], k) if k < 3 else [tuple(refs[ident])]:
            pass
    # build samples: genuine (probe of ident vs subset of ident refs); impostor (probe vs subset of other ident refs)
    samples = []
    for pr in probes:
        for ident in ids:
            for refset in (itertools.combinations(refs[ident], k) if k < len(refs[ident]) else [tuple(refs[ident])]):
                if len(refset) == 0: continue
                samples.append((ident in pr["identities"], dists(pr, ident, refset), pr["file"], ident))
    G = [s for s in samples if s[0]]; I = [s for s in samples if not s[0]]
    print(f"\n=== {k} reference photo(s): {len(G)} genuine trials, {len(I)} impostor trials ===")
    for name, fn in rules(k).items():
        miss = sum(not fn(s[1]) for s in G); fm = sum(fn(s[1]) for s in I)
        print(f"{name:34s} recall {len(G)-miss}/{len(G)} ({100*(len(G)-miss)/len(G):.1f}%)  misses {miss:3d}  false matches {fm}")
    # margin: closest impostor on the second-best statistic
    print("closest impostor: min", round(min(s[1][0] for s in I), 3), " mean2best", round(min(np.mean(s[1][:2]) for s in I if len(s[1]) > 1), 3) if k > 1 else "")
    if k == 3:
        print("remaining-miss detail (file, ident, per-ref distances):")
        for s in G:
            if s[1][0] >= .55: print("  ", s[2], s[3], [round(x, 3) for x in s[1]])

# --- margins for the consensus statistic (3 refs): how close does the closest impostor get to each acceptance bound?
S = []
for pr in probes:
    for ident in ids:
        S.append((ident in pr["identities"], dists(pr, ident, tuple(refs[ident]))))
Gs = [s for _, s in [(g, s) for g, s in S if g]]; Is = [s for g, s in S if not g]
print("\nimpostor margins (3 refs): closest impostor best=%.3f  2nd-best=%.3f ; impostor trials with best<0.70: %d, 2nd-best<0.70: %d, 2nd-best<0.65: %d" % (
    min(s[0] for s in Is), min(s[1] for s in Is), sum(s[0] < .70 for s in Is), sum(s[1] < .70 for s in Is), sum(s[1] < .65 for s in Is)))
print("genuine 2nd-best p95 %.3f max %.3f" % (np.percentile([s[1] for s in Gs], 95), max(s[1] for s in Gs)))
