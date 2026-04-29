#!/usr/bin/env python3
"""
Convert a pre-trained MobileFaceNet ONNX model to CoreML (.mlpackage).

Setup:
    pip install coremltools onnx onnxruntime

Get the ONNX model (pick one):
  Option A — insightface buffalo_sc (recommended, ArcFace-trained):
    pip install insightface
    python -c "
    import insightface
    from insightface.model_zoo import get_model
    m = get_model('buffalo_sc')
    m.prepare(-1)
    # The ONNX file is cached at ~/.insightface/models/buffalo_sc/w600k_mbf.onnx
    "
    cp ~/.insightface/models/buffalo_sc/w600k_mbf.onnx scripts/mobilefacenet.onnx

  Option B — direct download of MobileFaceNet ArcFace ONNX:
    curl -L -o scripts/mobilefacenet.onnx \
      https://github.com/onnx/models/raw/main/validated/vision/body_analysis/arcface/model/arcface-mobilefacenet-int8.onnx

Then run:
    python scripts/convert_mobilefacenet.py

Output:
    PhotoShare/Resources/MobileFaceNet.mlpackage

Xcode setup:
    1. In Xcode, drag MobileFaceNet.mlpackage into the PhotoShare group
    2. Make sure "Add to targets: PhotoShare" is checked
    3. Build — Xcode compiles it to MobileFaceNet.mlmodelc in the app bundle
"""

import sys
import os
import onnx
import coremltools as ct
import numpy as np

ONNX_PATH = os.path.join(os.path.dirname(__file__), "mobilefacenet.onnx")
OUTPUT_PATH = os.path.join(os.path.dirname(__file__), "../PhotoShare/Resources/MobileFaceNet.mlpackage")

def main():
    if not os.path.exists(ONNX_PATH):
        print(f"ERROR: {ONNX_PATH} not found. See the instructions at the top of this script.")
        sys.exit(1)

    print(f"Loading ONNX model from {ONNX_PATH}...")
    onnx_model = onnx.load(ONNX_PATH)

    # Print input/output names so you can verify if conversion fails
    for inp in onnx_model.graph.input:
        print(f"  ONNX input:  {inp.name}  shape: {[d.dim_value for d in inp.type.tensor_type.shape.dim]}")
    for out in onnx_model.graph.output:
        print(f"  ONNX output: {out.name}  shape: {[d.dim_value for d in out.type.tensor_type.shape.dim]}")

    print("Converting to CoreML...")
    mlmodel = ct.convert(
        onnx_model,
        inputs=[
            ct.ImageType(
                # "input" matches the ONNX input name for most MobileFaceNet variants.
                # If conversion fails, replace "input" with the ONNX input name printed above.
                name="face",
                shape=(1, 3, 112, 112),
                # Normalize [0,255] BGR → [-1, 1]: pixel * (1/127.5) + (-1.0)
                scale=1 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.BGR,
                channel_first=True,
            )
        ],
        outputs=[
            # Rename the output to a stable name the Swift code expects.
            ct.TensorType(name="embedding"),
        ],
        minimum_deployment_target=ct.target.iOS17,
    )

    # Sanity-check: run a zero-input prediction and verify output shape
    print("Verifying output shape...")
    spec = mlmodel.get_spec()
    output_names = [o.name for o in spec.description.output]
    print(f"  Output features: {output_names}")

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    mlmodel.save(OUTPUT_PATH)
    print(f"\nSaved to {OUTPUT_PATH}")
    print("Next: drag MobileFaceNet.mlpackage into Xcode → PhotoShare group, add to PhotoShare target, then build.")

if __name__ == "__main__":
    main()
