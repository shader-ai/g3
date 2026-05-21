# Build g3fcgen from source with cargo-chef for dependency layer caching.
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
    && rm -rf /var/lib/apt/lists/*

COPY --from=planner /usr/src/g3/recipe.json recipe.json
RUN cargo chef cook --profile release-lto \
    --no-default-features --features vendored-openssl \
    -p g3fcgen --recipe-path recipe.json

COPY . .
RUN mkdir -p /out \
    && cargo build --profile release-lto \
    --no-default-features --features vendored-openssl \
    -p g3fcgen \
    && cp target/release-lto/g3fcgen /out/g3fcgen

# Runtime image
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/g3fcgen /usr/local/bin/g3fcgen
RUN chmod +x /usr/local/bin/g3fcgen \
    && mkdir -p /etc/g3fcgen /var/log/g3fcgen

ENTRYPOINT ["/usr/local/bin/g3fcgen"]
CMD ["-c", "/etc/g3fcgen/g3fcgen.yaml"]
