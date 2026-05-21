# Build g3proxy from source with cargo-chef for dependency layer caching.
# Build context must be the g3 repo root.

FROM rust:bookworm AS chef
RUN cargo install cargo-chef --locked
WORKDIR /usr/src/g3

# Planner: capture dependency graph without compiling anything
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Builder: compile deps (cached layer), then compile source
FROM chef AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    libclang-dev \
    cmake \
    capnproto \
    && rm -rf /var/lib/apt/lists/*

COPY --from=planner /usr/src/g3/recipe.json recipe.json
RUN cargo chef cook --profile release-lto \
    --no-default-features --features vendored-boringssl,rustls-ring,quic,vendored-c-ares \
    -p g3proxy --recipe-path recipe.json

COPY . .
RUN mkdir -p /out \
    && cargo build --profile release-lto \
    --no-default-features --features vendored-boringssl,rustls-ring,quic,vendored-c-ares \
    -p g3proxy \
    && cp target/release-lto/g3proxy /out/g3proxy

# Runtime image
FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/g3proxy /usr/local/bin/g3proxy
RUN chmod +x /usr/local/bin/g3proxy \
    && mkdir -p /etc/g3proxy /var/log/g3proxy

EXPOSE 3128

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3128 || exit 1

CMD ["/usr/local/bin/g3proxy", "-vv", "-c", "/etc/g3proxy/g3proxy.yaml"]
