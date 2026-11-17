#!/bin/bash
# Fetches DeepFilterNet at a pinned commit and builds the combined native
# library (DeepFilterNet + WebRTC echo canceller): vendor/lib/libclearnative.a
set -euo pipefail
cd "$(dirname "$0")/.."
REV=7b14b895fe7fc42cab72b4a4c1e49c982bd6404b
MODEL=vendor/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz
for tool in cargo meson ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "$tool missing: run 'brew install rust meson ninja pkg-config'" >&2; exit 1; }
done
mkdir -p vendor/lib
[ -d vendor/DeepFilterNet/.git ] || git clone https://github.com/Rikorose/DeepFilterNet vendor/DeepFilterNet
git -C vendor/DeepFilterNet checkout -q "$REV"
# A tiny file here means git stored a Git LFS pointer instead of the model.
[ "$(stat -f%z "$MODEL")" -gt 100000 ] || { echo "$MODEL is not a real model file (Git LFS pointer?)" >&2; exit 1; }
# Our own crate's release profile has no LTO, so Apple's linker can read the result.
cargo build --release --manifest-path native/Cargo.toml --target-dir vendor/native-target
cp vendor/native-target/release/libclearnative.a vendor/lib/libclearnative.a
rm -f vendor/lib/libdf.a
echo "built vendor/lib/libclearnative.a"
