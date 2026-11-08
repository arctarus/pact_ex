#!/usr/bin/env bash
# Installs the Pact protobuf plugin under
# ${PACT_PLUGIN_DIR:-$HOME/.pact/plugins}/protobuf-$VERSION.
# Does nothing when it is already installed. Every download is checked against
# a SHA-256 pinned in this file before anything is installed. They match the
# digests GitHub reports for the v-0.8.1 release assets. Pinning them protects
# against release files that change after the fact, which a `.sha256` file
# published next to the binary would not. Update all five with every plugin
# version.
set -euo pipefail

VERSION=0.8.1
DIR="${PACT_PLUGIN_DIR:-$HOME/.pact/plugins}/protobuf-$VERSION"
MANIFEST_SHA256=ef99f043a98942018046800e7a3f1d344365bcddd406200b26130a3fb4ad91c4
BINARY_SHA256_LINUX_X86_64=d0fc6b3d99b17995ed5bf024f03f51790f332741c7acf745b97619dd4ee43fe0
BINARY_SHA256_LINUX_AARCH64=c9387916e75e8815dc56d3b47fbb05d6de9fd757abce853f90a240bc5ae1b896
BINARY_SHA256_MACOS_X86_64=5af6b4a35f058f358f9fe9da34dcf2d60337bc80dd58f3bdebae2dab672d32d1
BINARY_SHA256_MACOS_AARCH64=de8197cb7e6f5d79e7a8850fb54b3bf42913ac1537f9a64adfcd5e69785f3fd3
BASE_URL="https://github.com/pactflow/pact-protobuf-plugin/releases/download/v-$VERSION"

if [ -f "$DIR/pact-plugin.json" ]; then
  echo "protobuf plugin $VERSION is already installed in $DIR"
  exit 0
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

manifest="pact-plugin.json"
binary="pact-protobuf-plugin-$os-$arch.gz"

verify() {
  local file="$1" expected="$2" actual
  actual="$(sha256 "$file")"

  if [ "$actual" != "$expected" ]; then
    echo "SHA-256 mismatch for $(basename "$file")" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

curl -fsSL -o "$tmp/$manifest" "$BASE_URL/$manifest"
verify "$tmp/$manifest" "$MANIFEST_SHA256"

curl -fsSL -o "$tmp/$binary" "$BASE_URL/$binary"
case "$os-$arch" in
  linux-x86_64) binary_sha256=$BINARY_SHA256_LINUX_X86_64 ;;
  linux-aarch64) binary_sha256=$BINARY_SHA256_LINUX_AARCH64 ;;
  macos-x86_64) binary_sha256=$BINARY_SHA256_MACOS_X86_64 ;;
  macos-aarch64) binary_sha256=$BINARY_SHA256_MACOS_AARCH64 ;;
esac
verify "$tmp/$binary" "$binary_sha256"

# The early exit above and `PactEx.Plugin.installed?/2` both look for
# pact-plugin.json, so it goes in last. An interrupted run then leaves no
# install that looks complete.
gunzip -c "$tmp/$binary" >"$tmp/pact-protobuf-plugin"
chmod +x "$tmp/pact-protobuf-plugin"

mkdir -p "$DIR"
mv "$tmp/pact-protobuf-plugin" "$DIR/pact-protobuf-plugin"
mv "$tmp/$manifest" "$DIR/pact-plugin.json"

echo "installed protobuf plugin $VERSION in $DIR"
