# Build g3proxy from the local g3 repo (build context = g3 repo root).
# Run: docker compose -f deploy/docker-compose.yml build (from repo root)
#   or: cd deploy && docker compose build

# ---------------------------------------------------------------------------
# Stage 1: Build from local source
# ---------------------------------------------------------------------------
FROM rust:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libclang-dev \
    cmake \
    capnproto \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/g3

# Copy dependency files first for better layer caching
# This allows Docker to cache the dependency download/compile step
COPY Cargo.toml Cargo.lock ./
COPY lib ./lib
COPY g3proxy/Cargo.toml ./g3proxy/

# Copy the rest of the source code
COPY . .

# Build g3proxy (same features as upstream image)
# Cache target for fast rebuilds; copy binary to /out so it's in the image
RUN mkdir -p /out
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/src/g3/target \
    cargo build --profile release-lto \
    --no-default-features --features vendored-boringssl,rustls-ring,quic,vendored-c-ares \
    -p g3proxy \
    && cp /usr/src/g3/target/release-lto/g3proxy /out/g3proxy

# ---------------------------------------------------------------------------
# Stage 2: Runtime image (config/certs mounted at runtime)
# ---------------------------------------------------------------------------
FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/g3proxy /usr/local/bin/g3proxy
RUN chmod +x /usr/local/bin/g3proxy

RUN mkdir -p /etc/g3proxy /var/log/g3proxy

EXPOSE 3128

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3128 || exit 1

CMD ["/usr/local/bin/g3proxy", "-vv", "-c", "/etc/g3proxy/g3proxy.yaml"]
