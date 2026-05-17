# G3 Proxy deploy (local repo)

Build and run **g3proxy** and **g3fcgen** from your cloned g3 repo (no GitHub pull).

## Prerequisites

- Docker and Docker Compose
- This directory lives inside the [g3](https://github.com/bytedance/g3) repo (e.g. `g3/deploy/`)

## Quick start

```bash
cd deploy

# 1. Configure (required)
cp deploy.env deploy.env.local   # optional: keep a local copy
# Edit deploy.env: AUTH_MODE, USERS_FILE or PROXY_USER/PROXY_PASS, ICAP_IP, ICAP_PORT

# 2. Build and run (builds from parent g3 repo)
./deploy.sh
```

## How it works

- **Build context** is the parent of `deploy/` (the g3 repo root). Images are built from the local source with `Dockerfile` and `g3fcgen.Dockerfile` in `deploy/`.
- **Config and certs** live in `deploy/config/` and `deploy/certs/` and are mounted at runtime (no config baked into images).
- **deploy.sh** reads `deploy.env`, generates certs if needed, updates ICAP URL in `config/g3proxy.yaml`, then runs `docker compose build` and `docker compose up -d` from `deploy/`.

## Manual build and run

```bash
cd deploy
docker compose build
docker compose up -d
```

## Structure

```
deploy/
├── deploy.sh           # Build and deploy (uses deploy.env)
├── deploy.env          # AUTH_MODE, USERS_FILE, ICAP_IP, ICAP_PORT
├── Dockerfile          # g3proxy (context = parent = g3 repo)
├── g3fcgen.Dockerfile  # g3fcgen (context = parent)
├── docker-compose.yml  # context: .. ; run from deploy/
├── config/
│   ├── g3proxy.yaml
│   ├── users.yaml
│   └── g3fcgen.yaml
├── certs/              # ca.crt, ca.key (generate-certs.sh)
└── logs/
```

## Useful commands

```bash
cd deploy
docker compose logs -f
docker compose ps
docker compose restart
docker compose down
```

Test proxy (after installing `certs/ca.crt` on the client):

```bash
curl -x http://USER:PASS@localhost:3128 https://www.google.com
```

## Troubleshooting (ICAP + inspection)

If YouTube, ChatGPT, or similar sites return 400 or don’t work when using inspection and ICAP auditing, see **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**. In short: the origin is rejecting the request; the usual cause is the **ICAP reqmod** service modifying the request. Temporarily disable `icap_reqmod_service` in `config/g3proxy.yaml` to confirm, then fix the ICAP server to return 204 or the unchanged request.
