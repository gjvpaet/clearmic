#!/bin/bash
# Fetches DeepFilterNet at a pinned commit and builds its static library.
set -euo pipefail
cd "$(dirname "$0")/.."
REV=7b14b895fe7fc42cab72b4a4c1e49c982bd6404b
MODEL=vendor/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz
command -v cargo >/dev/null || { echo "cargo missing: run 'brew install rust'" >&2; exit 1; }
mkdir -p vendor/lib
[ -d vendor/DeepFilterNet ] || git clone https://github.com/Rikorose/DeepFilterNet vendor/DeepFilterNet
git -C vendor/DeepFilterNet checkout -q "$REV"
# A tiny file here means git stored a Git LFS pointer instead of the model.
[ "$(stat -f%z "$MODEL")" -gt 100000 ] || { echo "$MODEL is not a real model file (Git LFS pointer?)" >&2; exit 1; }
# LTO off: thin LTO leaves LLVM bitcode in the .a, newer than Xcode's linker can read.
CARGO_PROFILE_RELEASE_LTO=off cargo build --release --manifest-path vendor/DeepFilterNet/libDF/Cargo.toml --no-default-features --features capi
cp "$(find vendor/DeepFilterNet -name libdf.a -path '*release*' | head -1)" vendor/lib/libdf.a
echo "built vendor/lib/libdf.a"
