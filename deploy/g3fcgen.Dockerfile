# Build g3fcgen from the local g3 repo (build context = g3 repo root).

# ---------------------------------------------------------------------------
# Stage 1: Build from local source
# ---------------------------------------------------------------------------
FROM rust:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libclang-dev \
    cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/g3

# Copy dependency files first for better layer caching
# This allows Docker to cache the dependency download/compile step
COPY Cargo.toml Cargo.lock ./
COPY lib ./lib
COPY g3fcgen/Cargo.toml ./g3fcgen/

# Copy the rest of the source code
COPY . .

# Build g3fcgen
# Cache target for fast rebuilds; copy binary to /out so it's in the image
RUN mkdir -p /out
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/src/g3/target \
    cargo build --profile release-lto \
    --no-default-features --features vendored-openssl \
    -p g3fcgen \
    && cp /usr/src/g3/target/release-lto/g3fcgen /out/g3fcgen

# ---------------------------------------------------------------------------
# Stage 2: Runtime image (config/certs mounted at runtime)
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/g3fcgen /usr/local/bin/g3fcgen
RUN chmod +x /usr/local/bin/g3fcgen

RUN mkdir -p /etc/g3fcgen /var/log/g3fcgen

ENTRYPOINT ["/usr/local/bin/g3fcgen"]
CMD ["-c", "/etc/g3fcgen/g3fcgen.yaml"]
