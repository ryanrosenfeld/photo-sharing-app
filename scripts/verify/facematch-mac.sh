#!/bin/bash
# Face-match evaluation on the Mac (real Vision landmarks, no Simulator, ~10 s).
# Usage: scripts/verify/facematch-mac.sh [faces dir (default: the committed fixtures)] [--min-recall N] [--dump-embeddings]
set -euo pipefail
FACES=PhotoShareTests/Fixtures/faces
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then FACES=$1; shift; fi
cd "$(dirname "$0")/../.."
OUT=${OUT:-verification-output/facematch-mac}
mkdir -p "$OUT/build"
rm -rf "$OUT/MobileFaceNet.mlmodelc"
xcrun coremlcompiler compile PhotoShare/Resources/MobileFaceNet.mlpackage "$OUT" >/dev/null
# the generated MobileFaceNet.swift model class is not needed: FaceDetector drives MLModel directly
swiftc -O -swift-version 5 ${SWIFT_FLAGS:-} -o "$OUT/build/facematch-mac" \
  PhotoShare/FaceMatch/FaceDetector.swift PhotoShareTests/FaceMatchEvaluation.swift scripts/verify/facematch-mac/main.swift
FACEMATCH_MODEL_PATH="$PWD/$OUT/MobileFaceNet.mlmodelc" "$OUT/build/facematch-mac" "$FACES" "$OUT" "$@"
