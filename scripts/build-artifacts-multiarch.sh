#!/usr/bin/env bash
# Build g3proxy and g3fcgen for Linux (EC2: amd64 and arm64/Graviton).
# Run from g3 repo root: ./scripts/build-artifacts-multiarch.sh
# Output: artifacts/amd64/g3proxy, artifacts/amd64/g3fcgen, artifacts/arm64/g3proxy, artifacts/arm64/g3fcgen

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G3_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$G3_ROOT"

if [ ! -f deploy/Dockerfile ] || [ ! -f deploy/g3fcgen.Dockerfile ]; then
  echo "ERROR: Run from g3 repo root (directory containing deploy/Dockerfile)." >&2
  exit 1
fi

echo "Building multi-arch artifacts for Linux (EC2 amd64 + arm64) in $G3_ROOT"
mkdir -p artifacts/amd64 artifacts/arm64

# Ensure buildx builder exists
docker buildx create --use 2>/dev/null || true

extract_binary() {
  local image=$1
  local src=$2
  local dest=$3
  local id
  id=$(docker create "$image")
  docker cp "$id:$src" "$dest"
  docker rm "$id" >/dev/null
  chmod +x "$dest"
}

# --- g3proxy: linux/amd64 and linux/arm64 ---
echo "[1/4] Building g3proxy for linux/amd64..."
docker buildx build \
  --platform linux/amd64 \
  --target builder \
  --tag g3proxy-builder:amd64 \
  --file deploy/Dockerfile \
  --load \
  .
extract_binary g3proxy-builder:amd64 /out/g3proxy artifacts/amd64/g3proxy
echo "      -> artifacts/amd64/g3proxy"

echo "[2/4] Building g3proxy for linux/arm64..."
docker buildx build \
  --platform linux/arm64 \
  --target builder \
  --tag g3proxy-builder:arm64 \
  --file deploy/Dockerfile \
  --load \
  .
extract_binary g3proxy-builder:arm64 /out/g3proxy artifacts/arm64/g3proxy
echo "      -> artifacts/arm64/g3proxy"

# --- g3fcgen: linux/amd64 and linux/arm64 ---
echo "[3/4] Building g3fcgen for linux/amd64..."
docker buildx build \
  --platform linux/amd64 \
  --target builder \
  --tag g3fcgen-builder:amd64 \
  --file deploy/g3fcgen.Dockerfile \
  --load \
  .
extract_binary g3fcgen-builder:amd64 /out/g3fcgen artifacts/amd64/g3fcgen
echo "      -> artifacts/amd64/g3fcgen"

echo "[4/4] Building g3fcgen for linux/arm64..."
docker buildx build \
  --platform linux/arm64 \
  --target builder \
  --tag g3fcgen-builder:arm64 \
  --file deploy/g3fcgen.Dockerfile \
  --load \
  .
extract_binary g3fcgen-builder:arm64 /out/g3fcgen artifacts/arm64/g3fcgen
echo "      -> artifacts/arm64/g3fcgen"

echo ""
echo "Done. Multi-arch Linux artifacts:"
echo "  artifacts/amd64/g3proxy  artifacts/amd64/g3fcgen"
echo "  artifacts/arm64/g3proxy  artifacts/arm64/g3fcgen"
echo "Commit these and run the Build G3 Proxy & G3FCGen workflow to push images."
