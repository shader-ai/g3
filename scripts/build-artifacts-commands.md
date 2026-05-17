# Commands to build g3 artifacts locally with Docker and extract them

Run from the **g3 repo root** (directory that contains `deploy/` and `lib/`).

## When to rebuild

- **Deployment uses `platform: linux/amd64`** (e.g. EC2 Graviton / aarch64): artifacts must be **linux/amd64**. If you built on an ARM Mac, the default commands below produce **arm64** binaries — use the **Build for linux/amd64** section instead and rebuild once.
- **Same-arch deployment**: the default commands (current platform) are fine.

## One-time setup

```bash
cd /path/to/urai/g3
mkdir -p artifacts
```

## 1. Build g3proxy and extract binary

```bash
# Build only the builder stage (current platform)
docker build \
  --target builder \
  --tag g3proxy-builder:local \
  --file deploy/Dockerfile \
  .

# Extract binary from builder image
CONTAINER_ID=$(docker create g3proxy-builder:local)
docker cp "$CONTAINER_ID:/out/g3proxy" artifacts/g3proxy
docker rm "$CONTAINER_ID"
chmod +x artifacts/g3proxy
```

## 2. Build g3fcgen and extract binary

```bash
# Build only the builder stage (current platform)
docker build \
  --target builder \
  --tag g3fcgen-builder:local \
  --file deploy/g3fcgen.Dockerfile \
  .

# Extract binary from builder image
CONTAINER_ID=$(docker create g3fcgen-builder:local)
docker cp "$CONTAINER_ID:/out/g3fcgen" artifacts/g3fcgen
docker rm "$CONTAINER_ID"
chmod +x artifacts/g3fcgen
```

## Build multi-arch (for CI: artifacts/amd64 and artifacts/arm64)

CI expects **artifacts/amd64/** and **artifacts/arm64/** so it can build and push multi-arch images. Run from **g3** repo root.

```bash
mkdir -p artifacts/amd64 artifacts/arm64
docker buildx create --use 2>/dev/null || true

# g3proxy (amd64)
docker buildx build \
  --platform linux/amd64 \
  --target builder \
  --tag g3proxy-builder:amd64 \
  --file deploy/Dockerfile \
  --load \
  .
CONTAINER_ID=$(docker create g3proxy-builder:amd64)
docker cp "$CONTAINER_ID:/out/g3proxy" artifacts/amd64/g3proxy
docker rm "$CONTAINER_ID"
chmod +x artifacts/amd64/g3proxy

# g3proxy (arm64)
docker buildx build \
  --platform linux/arm64 \
  --target builder \
  --tag g3proxy-builder:arm64 \
  --file deploy/Dockerfile \
  --load \
  .
CONTAINER_ID=$(docker create g3proxy-builder:arm64)
docker cp "$CONTAINER_ID:/out/g3proxy" artifacts/arm64/g3proxy
docker rm "$CONTAINER_ID"
chmod +x artifacts/arm64/g3proxy

# g3fcgen (amd64)
docker buildx build \
  --platform linux/amd64 \
  --target builder \
  --tag g3fcgen-builder:amd64 \
  --file deploy/g3fcgen.Dockerfile \
  --load \
  .
CONTAINER_ID=$(docker create g3fcgen-builder:amd64)
docker cp "$CONTAINER_ID:/out/g3fcgen" artifacts/amd64/g3fcgen
docker rm "$CONTAINER_ID"
chmod +x artifacts/amd64/g3fcgen

# g3fcgen (arm64)
docker buildx build \
  --platform linux/arm64 \
  --target builder \
  --tag g3fcgen-builder:arm64 \
  --file deploy/g3fcgen.Dockerfile \
  --load \
  .
CONTAINER_ID=$(docker create g3fcgen-builder:arm64)
docker cp "$CONTAINER_ID:/out/g3fcgen" artifacts/arm64/g3fcgen
docker rm "$CONTAINER_ID"
chmod +x artifacts/arm64/g3fcgen
```

Then commit `artifacts/amd64/` and `artifacts/arm64/` and run the **Build G3 Proxy & G3FCGen** workflow; it will push multi-arch images.

**Or run the script** (from g3 repo root):

```bash
./scripts/build-artifacts-multiarch.sh
```

## Build for linux/amd64 only (single-arch, legacy layout)

Use this if you only need amd64 and use the old layout `artifacts/g3proxy` and `artifacts/g3fcgen`. Run from **g3** repo root.

```bash
mkdir -p artifacts
docker buildx create --use 2>/dev/null || true

# g3proxy (amd64)
docker buildx build \
  --platform linux/amd64 \
  --target builder \
  --tag g3proxy-builder:amd64 \
  --file deploy/Dockerfile \
  --load \
  .
CONTAINER_ID=$(docker create g3proxy-builder:amd64)
docker cp "$CONTAINER_ID:/out/g3proxy" artifacts/g3proxy
docker rm "$CONTAINER_ID"
chmod +x artifacts/g3proxy

# g3fcgen (amd64)
docker buildx build \
  --platform linux/amd64 \
  --target builder \
  --tag g3fcgen-builder:amd64 \
  --file deploy/g3fcgen.Dockerfile \
  --load \
  .
CONTAINER_ID=$(docker create g3fcgen-builder:amd64)
docker cp "$CONTAINER_ID:/out/g3fcgen" artifacts/g3fcgen
docker rm "$CONTAINER_ID"
chmod +x artifacts/g3fcgen
```

## Result

- **Multi-arch (CI)**: `artifacts/amd64/g3proxy`, `artifacts/amd64/g3fcgen`, `artifacts/arm64/g3proxy`, `artifacts/arm64/g3fcgen`
- **Single-arch (legacy)**: `artifacts/g3proxy`, `artifacts/g3fcgen` (current platform or amd64 from section above)

## Optional: use the script instead (current platform only)

```bash
./scripts/build-artifacts-local.sh
```

Override output directory:

```bash
ARTIFACTS_DIR=/tmp/g3-out ./scripts/build-artifacts-local.sh
```
