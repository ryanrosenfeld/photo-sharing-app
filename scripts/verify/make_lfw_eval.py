#!/usr/bin/env python3
"""Builds a REAL-photo evaluation set from LFW (Labeled Faces in the Wild, via the logasja/lfw Hugging Face dataset).
Not committed (real people's photos; research-use dataset) -- download into a scratch dir:

    scripts/verify/make_lfw_eval.py /tmp/lfw-eval            # ~470 small JPEGs
    OUT=verification-output/lfw scripts/verify/facematch-mac.sh /tmp/lfw-eval   # see facematch-mac.sh for args

70 identities with >=5 photos each; the first 3 photos of each identity play the friend's reference photos (the app asks
for 3-5), the rest are probes. Unlike the synthetic fixtures, same-person photos here differ in pose, light, expression and age."""
import collections, json, os, sys, urllib.request

out = sys.argv[1] if len(sys.argv) > 1 else "lfw-eval"
os.makedirs(out, exist_ok=True)
rows = []
for off in range(0, 3000, 100):
    url = f"https://datasets-server.huggingface.co/rows?dataset=logasja/lfw&config=default&split=train&offset={off}&length=100"
    rows += [(r["row"]["label"], r["row"]["image"]["src"]) for r in json.load(urllib.request.urlopen(url, timeout=60))["rows"]]
by = collections.defaultdict(list)
for label, src in rows:
    by[label].append(src)
manifest = []
for label in [l for l, v in by.items() if len(v) >= 5][:70]:
    for i, src in enumerate(by[label][:8]):
        fn = f"id{label}_{i + 1}.jpg"
        urllib.request.urlretrieve(src, os.path.join(out, fn))
        manifest.append({"identity": f"id{label}", "file": fn, "kind": "lfw", "role": "enroll" if i < 3 else "probe", "identities": [f"id{label}"]})
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
print(len(manifest), "photos ->", out)
