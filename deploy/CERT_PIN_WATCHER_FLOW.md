# cert_pin_watcher.py — Complete Flow

This document explains exactly how `cert_pin_watcher.py` works step by step, from startup to a bypass being live.

---

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        cert-pin-watcher                             │
│                                                                     │
│  docker logs -f g3proxy                                             │
│       │                                                             │
│       ▼                                                             │
│  ┌─────────────┐    Gate 1 fail     ┌──────────────┐               │
│  │  Every log  │ ─── no             │   DISCARD    │               │
│  │    line     │  InterceptionError─▶   (skip)     │               │
│  └──────┬──────┘                    └──────────────┘               │
│         │ Gate 1 pass                                               │
│         ▼                                                           │
│  ┌─────────────┐    Gate 2 fail     ┌──────────────┐               │
│  │  Check for  │ ─── ErrorCode(1) / │   DISCARD    │               │
│  │  cert-pin   │     EOF / generic ─▶   (skip)     │               │
│  │   signal    │     SslError       └──────────────┘               │
│  └──────┬──────┘                                                    │
│         │ Gate 2 pass                                               │
│         │ SSLV3_ALERT / ErrorCode(5) / CERTIFICATE_VERIFY_FAILED   │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │   Extract   │  hostname, user, error_type from log line          │
│  └──────┬──────┘                                                    │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │  Classify   │  root_domain() → classify_domain()                 │
│  │ source_type │  ai_agent / app / browser / unknown                │
│  └──────┬──────┘                                                    │
│         ▼                                                           │
│  ┌─────────────┐   already there?  ┌──────────────┐               │
│  │  Check YAML │ ──────────────── ▶│     SKIP     │               │
│  │ bypass list │                   └──────────────┘               │
│  └──────┬──────┘                                                    │
│         │ new hostname                                              │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │  Write YAML │  append to exact_match.bypass                      │
│  └──────┬──────┘                                                    │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │   SIGHUP    │  docker kill --signal HUP g3proxy                  │
│  │  g3proxy    │  (hot-reload, no restart, no dropped connections)  │
│  └──────┬──────┘                                                    │
│         ▼                                                           │
│  ┌─────────────┐                                                    │
│  │POST backend │  /api/v1/internal/proxy-bypass                     │
│  │  (async)    │  hostname, domain, error_type, user, source_type   │
│  └─────────────┘                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Full System Flow

```
Client Device (macOS)
      │
      │  HTTPS request to v.whatsapp.net:443
      ▼
┌─────────────────────────────────────┐
│           G3 Proxy (port 3128)      │
│                                     │
│  Check tls_inspect_policy           │
│         │                           │
│   ┌─────┴──────┐                    │
│   │            │                    │
│ In bypass   Not in bypass           │
│   │            │                    │
│   ▼            ▼                    │
│ Raw TCP    TLS Intercept            │
│ tunnel     (forged cert)            │
│ (blind)         │                   │
│            ┌────┴─────┐             │
│            │          │             │
│         accepts    rejects          │
│         G3 cert    G3 cert          │
│            │          │             │
│            ▼          ▼             │
│         Intercept  InterceptionError│
│         ok ✓       logged to stdout │
└─────────────────────────────────────┘
                        │
                        │  G3 stdout log line:
                        │  reason=InterceptionError
                        │  upstream=v.whatsapp.net:443
                        │  ErrorCode(5) / SSLV3_ALERT
                        ▼
┌─────────────────────────────────────┐
│       cert-pin-watcher              │
│                                     │
│  stream_logs() reads it             │
│  process_line() filters it          │
│       │                             │
│       ▼                             │
│  Extracts hostname + user           │
│  root_domain() → whatsapp.net       │
│  classify_domain() → "app"          │
│       │                             │
│       ▼                             │
│  add_to_bypass()                    │
│  ├── load g3proxy.yaml              │
│  ├── append v.whatsapp.net          │
│  └── save g3proxy.yaml              │
│       │                             │
│       ▼                             │
│  reload_g3proxy()                   │
│  └── SIGHUP → G3 hot-reloads       │
│       │                             │
│       ▼                             │
│  notify_backend()                   │
│  └── POST /api/v1/internal/...      │
└─────────────────────────────────────┘
                        │
           ┌────────────┴────────────┐
           ▼                         ▼
┌──────────────────┐      ┌──────────────────────┐
│    G3 Proxy      │      │   URAI Backend        │
│                  │      │                        │
│  exact_match     │      │  proxy_bypass_events   │
│  .bypass now     │      │  table: new row        │
│  has             │      │  hostname, source_type │
│  v.whatsapp.net  │      │  error_type, user,     │
│                  │      │  raw_log, bypassed_at  │
│  Next request    │      │          │             │
│  → raw TCP ✓     │      │          ▼             │
└──────────────────┘      │  Bypass Manager UI     │
                          │  shows new entry with  │
                          │  "App" amber badge     │
                          └──────────────────────┘
```

---

## Source Type Classification Flow

```
hostname: api-safari-aaps1a.smoot.apple.com
                │
                ▼
        root_domain()
                │
                ▼
         apple.com
                │
                ▼
    ┌───────────────────────┐
    │  in _AI_AGENT_DOMAINS?│ ──── No
    └───────────┬───────────┘
                │ No
                ▼
    ┌───────────────────────┐
    │  keyword in           │
    │  _APP_KEYWORDS?       │
    │  "apple" in apple.com?│ ──── Yes ──▶  source_type = "app" 🟡
    └───────────────────────┘

─────────────────────────────────────────────────────

hostname: api.githubcopilot.com
                │
                ▼
        root_domain()
                │
                ▼
      githubcopilot.com
                │
                ▼
    ┌───────────────────────┐
    │  in _AI_AGENT_DOMAINS?│
    │  "githubcopilot.com"  │ ──── Yes ──▶  source_type = "ai_agent" 🔴
    └───────────────────────┘

─────────────────────────────────────────────────────

hostname: www.youtube.com
                │
                ▼
        root_domain()
                │
                ▼
         youtube.com
                │
                ▼
    ┌───────────────────────┐
    │  in _AI_AGENT_DOMAINS?│ ──── No
    └───────────┬───────────┘
                ▼
    ┌───────────────────────┐
    │  keyword in           │
    │  _APP_KEYWORDS?       │ ──── No
    └───────────┬───────────┘
                ▼
    ┌───────────────────────┐
    │  keyword in           │
    │  _BROWSER_KEYWORDS?   │
    │  "youtube" in         │
    │  youtube.com?         │ ──── Yes ──▶  source_type = "browser" 🔵
    └───────────────────────┘

─────────────────────────────────────────────────────

hostname: o33249.ingest.us.sentry.io
                │
                ▼
        root_domain()
                │
                ▼
          sentry.io
                │
                ▼
    ┌───────────────────────┐
    │  in _AI_AGENT_DOMAINS?│ ──── No
    └───────────┬───────────┘
                ▼
    ┌───────────────────────┐
    │  _APP_KEYWORDS?       │ ──── No
    └───────────┬───────────┘
                ▼
    ┌───────────────────────┐
    │  _BROWSER_KEYWORDS?   │ ──── No
    └───────────┬───────────┘
                ▼
                        source_type = "unknown" ⬜  (human review)
```

---

## Deduplication Flow

```
Detection #1 — v.whatsapp.net (first time)
        │
        ▼
  load yaml → exact_bypass = []
        │
  "v.whatsapp.net" in [] ?  ── No
        │
        ▼
  append → save → SIGHUP → notify backend
  log: "added v.whatsapp.net to exact_match bypass (1 exact entries)"

─────────────────────────────────────────────────────

Detection #2 — v.whatsapp.net (app retried before reload finished)
        │
        ▼
  load yaml → exact_bypass = ["v.whatsapp.net"]
        │
  "v.whatsapp.net" in list ?  ── Yes
        │
        ▼
  return False → nothing happens
  log: "hostname v.whatsapp.net already in exact_match bypass"
```

---

## 1. Startup

```
docker compose up -d cert-pin-watcher
```

The watcher container starts, loads env vars, and reads the current `g3proxy.yaml`:

```python
YAML_PATH   = G3_CONFIG_PATH  # /config/g3proxy.yaml (inside container)
CONTAINER   = G3_CONTAINER    # g3proxy
BACKEND_URL = BACKEND_URL     # http://host.docker.internal:8000
```

On startup it logs how many hostnames are already in the bypass list:

```
starting — watching g3proxy logs, config at /config/g3proxy.yaml
current bypass: 0 exact entries, 0 child entries
```

---

## 2. Log Streaming

```python
def stream_logs():
    proc = subprocess.Popen(
        ["docker", "logs", "-f", "--tail", "0", "g3proxy"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    for line in proc.stdout:
        yield line
```

- Uses `docker logs -f --tail 0` — streams only NEW lines from g3proxy, nothing historical
- If docker crashes or exits, the function retries every 5 seconds automatically
- Every line yielded goes into `process_line()`

---

## 3. Line Filtering — Two-Gate Check

```python
def process_line(line: str):
    # Gate 1 — must mention InterceptionError
    if "InterceptionError" not in line:
        return

    # Gate 2 — must contain a genuine cert-pin error
    if not RE_SSL_REJECTION.search(line):
        return
```

**Gate 1** — drops ~99% of lines (only task-finished lines with `InterceptionError` pass)

**Gate 2** — strict cert-pin filter:

| Passes Gate 2 | Blocked by Gate 2 |
|---|---|
| `SSLV3_ALERT_CERTIFICATE_UNKNOWN` | `ErrorCode(1)` — abrupt TCP drop |
| `ErrorCode(5)` — TLS close_notify | `unexpected EOF` — network blip |
| `CERTIFICATE_VERIFY_FAILED` | Generic `SslError` |

Only lines that pass **both gates** continue to processing.

---

## 4. Extraction

```python
RE_INTERCEPT_ERROR = re.compile(
    r"reason:\s*InterceptionError.*?upstream:\s*([\w.\-]+):(\d+)"
)
RE_USER      = re.compile(r"\buser:\s*([\w.\-@]+)")
RE_ERROR_TYPE = re.compile(
    r"(SSLV3_ALERT_CERTIFICATE_UNKNOWN|CERTIFICATE_VERIFY_FAILED|ErrorCode\(5\))"
)

m        = RE_INTERCEPT_ERROR.search(line)
hostname = m.group(1)          # e.g. v.whatsapp.net
user     = RE_USER → group(1)  # e.g. rohan.rn  (or "unknown")
error    = RE_ERROR_TYPE → g1  # e.g. ErrorCode(5)
```

From a single G3 log line, three values are extracted:
- **hostname** — the exact upstream that cert-pinned
- **user** — the LDAP username from the G3 task (who triggered it)
- **error_type** — which specific cert-pin signal fired

---

## 5. Root Domain + Source Type Classification

```python
domain      = root_domain(hostname)       # v.whatsapp.net → whatsapp.net
source_type = classify_domain(domain)     # "app"
```

**`root_domain()`** strips subdomains down to the registrable root, handling multi-part TLDs (`co.uk`, `com.au` etc.):

```
v.whatsapp.net              → whatsapp.net
api-safari-aaps1a.smoot.apple.com → apple.com
o33249.ingest.us.sentry.io  → sentry.io
```

**`classify_domain()`** runs three checks in order:

```
1. Is root domain in _AI_AGENT_DOMAINS set?   → "ai_agent"
2. Does any _APP_KEYWORDS keyword appear?     → "app"
3. Does any _BROWSER_KEYWORDS keyword appear? → "browser"
4. Nothing matched                            → "unknown"
```

Examples:
```
githubcopilot.com  → exact match in AI set      → ai_agent
whatsapp.net       → "whatsapp" in APP_KEYWORDS  → app
youtube.com        → "youtube" in BROWSER_KEYWORDS → browser
sentry.io          → no match                    → unknown
```

---

## 6. YAML Patch — Add to exact_match.bypass

```python
def add_to_bypass(hostname, user, error_type) -> bool:
    data = load_yaml()
    exact_bypass = current_exact_bypass(data)

    if hostname in exact_bypass:
        return False          # already there, skip

    exact_bypass.append(hostname)
    policy["exact_match"]["bypass"] = exact_bypass
    save_yaml(data)
    return True               # yaml changed
```

- Loads `g3proxy.yaml` fresh on every call (reads current state)
- Deduplicates — if the hostname is already in the list, returns `False` and nothing else happens
- Appends the **exact hostname** (not root domain) to `exact_match.bypass`
- Writes yaml back to disk

**Why exact_match and not child_match?**

`child_match` would bypass the root domain + ALL subdomains. This means if `cdn.openai.com` cert-pins, `api.openai.com` would also get bypassed — URAI would lose visibility on the AI API. `exact_match` only bypasses the specific pinned endpoint.

---

## 7. G3 Hot-Reload via SIGHUP

```python
def reload_g3proxy():
    subprocess.run(
        ["docker", "kill", "--signal", "HUP", "g3proxy"]
    )
```

- Sends `SIGHUP` to the g3proxy container
- G3 responds to SIGHUP by re-reading `g3proxy.yaml` in-place — no restart, no dropped connections
- The new `exact_match.bypass` entry is live within milliseconds
- Next connection attempt from the cert-pinned app will be routed as a raw TCP tunnel

---

## 8. Backend Notification

```python
def notify_backend(hostname, domain, error_type, triggered_by, source_type, raw_log):
    payload = {
        "hostname":     hostname,      # v.whatsapp.net
        "domain":       domain,        # whatsapp.net
        "error_type":   error_type,    # ErrorCode(5)
        "triggered_by": triggered_by,  # rohan.rn
        "source_type":  source_type,   # app
        "raw_log":      raw_log,       # full G3 log line
    }
    POST → {BACKEND_URL}/api/v1/internal/proxy-bypass
```

- Fire-and-forget with 5s timeout
- The `/api/v1/internal/` path is whitelisted in security middleware (no JWT required)
- Backend saves to `proxy_bypass_events` table → visible in Bypass Manager UI
- If backend is unreachable, watcher logs a warning and continues — bypass is already live in yaml

---

## 9. Deduplication Logic

```
First detection of v.whatsapp.net:
  → not in yaml → add → reload → notify backend → log: "added v.whatsapp.net"

Second detection of v.whatsapp.net (app retried before reload):
  → already in yaml → return False → no reload, no backend call → log: "already in bypass"
```

Only the **first** detection per hostname triggers the yaml write + SIGHUP + backend POST.

---

## 10. End-to-End Timeline

```
T+0ms    App makes HTTPS request through G3
T+0ms    G3 attempts TLS intercept, presents forged cert
T+5ms    App rejects cert → sends ErrorCode(5) / SSLV3_ALERT
T+10ms   G3 logs: reason=InterceptionError upstream=v.whatsapp.net:443
T+50ms   cert-pin-watcher reads log line from docker logs stream
T+51ms   Gate 1 pass: "InterceptionError" found
T+51ms   Gate 2 pass: "ErrorCode(5)" found
T+52ms   Extracts: hostname=v.whatsapp.net user=rohan.rn error=ErrorCode(5)
T+52ms   root_domain → whatsapp.net → classify → "app"
T+53ms   Loads g3proxy.yaml, appends v.whatsapp.net, saves yaml
T+54ms   docker kill --signal HUP g3proxy
T+60ms   G3 hot-reloads config — bypass list now includes v.whatsapp.net
T+65ms   POST /api/v1/internal/proxy-bypass → backend saves event → UI shows badge
T+∞      App retries → G3 sees hostname in exact_match.bypass → raw TCP tunnel → app works ✓
```

---

## Files

| File | Role |
|---|---|
| `deploy/cert_pin_watcher.py` | The watcher script |
| `deploy/sidecar.Dockerfile` | Docker image — Python 3.11 slim + PyYAML |
| `deploy/docker-compose.yml` | `cert-pin-watcher` service definition |
| `deploy/config/g3proxy.yaml` | Live config — watcher writes `exact_match.bypass` here |
