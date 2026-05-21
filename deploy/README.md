# G3 Proxy — Build & Deploy

Builds **g3proxy** and **g3fcgen** from source using Docker. No pre-built binaries are committed to the repo — everything compiles inside Docker via a multi-stage Rust build with [cargo-chef](https://github.com/LukeMathWalker/cargo-chef) for dependency caching.

---

## Prerequisites

- Docker 20.10+ (BuildKit enabled by default)
- Docker Compose v2 (`docker compose`)
- This directory lives inside the g3 repo root at `g3/deploy/`

---

## Local run

### Option A — deploy script (recommended)

```bash
cd g3/deploy

# 1. Configure auth and ICAP
vi deploy.env

# 2. Build and start
./deploy.sh
```

`deploy.sh` handles: cert generation → auth setup → `docker compose build` → `docker compose up -d`.

### Option B — manual

```bash
cd g3/deploy
docker compose build
docker compose up -d
```

### Test

```bash
curl -x http://USER:PASS@localhost:3128 https://www.google.com
```

Install `certs/ca.crt` on the client if you need TLS inspection to work end-to-end.

---

## Configuration (`deploy.env`)

| Variable | Default | Description |
|---|---|---|
| `AUTH_MODE` | `users_file` | `users_file` or `single_user` |
| `USERS_FILE` | `config/users.yaml` | Path to hashed-token user list (when `AUTH_MODE=users_file`) |
| `PROXY_USER` | — | Username (when `AUTH_MODE=single_user`) |
| `PROXY_PASS` | — | Password (when `AUTH_MODE=single_user`) |
| `ICAP_IP` | `host.docker.internal` | ICAP server IP (use `host.docker.internal` when ICAP runs on the same host as Docker) |
| `ICAP_PORT` | `1344` | ICAP server port |

---

## Build times

Builds use **cargo-chef**: dependencies compile once into a cached Docker layer. Only application code recompiles on subsequent builds.

| | First build | After (code change only) |
|---|---|---|
| Local (Apple Silicon / Graviton) | ~20–30 min | ~3–5 min |
| CI (`ubuntu-24.04-arm` runner) | ~20–30 min | ~5–10 min |

> The first build is slow because it compiles vendored BoringSSL, QUIC, and all Rust crates from scratch. After that, the dependency layer is cached — locally by Docker's BuildKit layer cache, in CI by ECR (`buildcache` tag).

---

## CI build (`build-g3-proxy.yml`)

The GitHub Actions workflow builds on a native **`ubuntu-24.04-arm`** (Graviton) runner — no QEMU emulation — and pushes `linux/arm64` images to ECR.

| Step | Detail |
|---|---|
| Runner | `ubuntu-24.04-arm` (native ARM64, matches EC2 target) |
| Platform | `linux/arm64` only |
| Cache | ECR registry cache (`buildcache` tag, `mode=max`) |
| Images pushed | `gfox/urai-g3proxy`, `gfox/urai-g3fcgen` — tagged with commit SHA and `latest` |

Trigger: `workflow_dispatch` (manual). Tie it to a push trigger on `g3/**` paths when ready for automation.

---

## Directory structure

```
deploy/
├── deploy.sh                # Build + run (reads deploy.env)
├── deploy.env               # Auth and ICAP config (edit before running)
├── docker-compose.yml       # Local compose (build context = g3 repo root)
├── Dockerfile               # g3proxy — multi-stage Rust build with cargo-chef
├── g3fcgen.Dockerfile       # g3fcgen — multi-stage Rust build with cargo-chef
├── generate-certs.sh        # Generates self-signed CA for TLS inspection
├── config/
│   ├── g3proxy.yaml         # g3proxy runtime config
│   ├── g3fcgen.yaml         # g3fcgen runtime config
│   └── users.yaml           # Hashed proxy user tokens
├── certs/                   # ca.crt, ca.key (generated, not committed)
└── logs/                    # Container log output (mounted at runtime)
```

---

## Useful commands

```bash
cd g3/deploy

docker compose logs -f           # tail logs for all services
docker compose ps                # container status
docker compose restart g3proxy   # restart one service
docker compose down              # stop and remove containers
docker compose build --no-cache  # force full rebuild (skips all layer cache)
```

---

## Troubleshooting

**Sites return 400 or fail with TLS inspection enabled**
The ICAP `reqmod` service is likely modifying requests in a way the origin rejects. Temporarily disable `icap_reqmod_service` in `config/g3proxy.yaml` to confirm, then fix the ICAP server to return `204` or pass the request through unchanged. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**First build fails with OOM**
`release-lto` (Link Time Optimization) is memory-intensive. Increase Docker's memory limit to at least 4 GB in Docker Desktop settings.

**`docker compose build` uses wrong architecture**
Builds target the host architecture by default. On Intel Mac you get `amd64`; on Apple Silicon or Graviton you get `arm64`. The EC2 target is `aarch64` (arm64) — build on Apple Silicon or in CI for a matching image.
