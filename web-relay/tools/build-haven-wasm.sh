#!/bin/sh
# Builds Haven (../haven-go) for js/wasm into public/haven.wasm, and copies the matching Go runtime shim
# to src/haven/wasm_exec.js. Both are build outputs (gitignored); rerun after any haven-go change.
# HAVEN_WASM_PKG: the haven-go package with the wasm entry point (default ".").
set -eu
cd "$(dirname "$0")/.."
out="$PWD"
pkg="${HAVEN_WASM_PKG:-.}"
(cd ../haven-go && GOOS=js GOARCH=wasm go build -trimpath -ldflags="-s -w" -o "$out/public/haven.wasm" "$pkg")
root="$(go env GOROOT)"
shim="$root/lib/wasm/wasm_exec.js"
[ -f "$shim" ] || shim="$root/misc/wasm/wasm_exec.js"
cp "$shim" src/haven/wasm_exec.js
ls -l public/haven.wasm
