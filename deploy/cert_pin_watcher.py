#!/usr/bin/env python3
"""
cert_pin_watcher.py — Auto-bypass sidecar for G3 proxy.

Streams g3proxy container logs, detects cert-pinning failures
(reason=InterceptionError + tls: client handshake failed), adds the
root domain to tls_inspect_policy.child_match.bypass so all subdomains
of the pinned app are covered, then sends SIGHUP to g3proxy to hot-reload.
"""

import json
import re
import subprocess
import sys
import time
import os
import logging
import urllib.request
import urllib.error
from pathlib import Path

import yaml

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [cert-pin-watcher] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

YAML_PATH = Path(os.environ.get("G3_CONFIG_PATH", "/config/g3proxy.yaml"))
CONTAINER_NAME = os.environ.get("G3_CONTAINER", "g3proxy")
BACKEND_URL = os.environ.get("BACKEND_URL", "http://backend:8000")

# Match the task-finished log line that carries reason + upstream.
RE_INTERCEPT_ERROR = re.compile(
    r"reason:\s*InterceptionError.*?upstream:\s*([\w.\-]+):(\d+)"
)
# Only bypass on genuine cert-pin/cert-rejection signals:
#   SSLV3_ALERT_CERTIFICATE_UNKNOWN — client explicitly rejected G3's forged cert (hard cert-pin)
#   ErrorCode(5)                    — TLS close_notify, client cleanly refused G3's cert (e.g. Apple/iCloud)
#   CERTIFICATE_VERIFY_FAILED       — upstream server rejected G3's cert (server-side pin)
#
# NOT bypassed (flaky connections, not cert-pins):
#   ErrorCode(1) / unexpected EOF   — abrupt TCP drop, could be network/timeout/retry, not a pin
#   SslError (generic)              — too broad, catches non-pin failures like handshake timeouts
RE_SSL_REJECTION = re.compile(
    r"SSLV3_ALERT_CERTIFICATE_UNKNOWN|CERTIFICATE_VERIFY_FAILED|ErrorCode\(5\)"
)
RE_USER = re.compile(r"\buser:\s*([\w.\-@]+)")
RE_ERROR_TYPE = re.compile(
    r"(SSLV3_ALERT_CERTIFICATE_UNKNOWN|CERTIFICATE_VERIFY_FAILED|ErrorCode\(5\))"
)


def load_yaml():
    with open(YAML_PATH) as f:
        return yaml.safe_load(f)


def save_yaml(data):
    with open(YAML_PATH, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)


def current_exact_bypass(data) -> list[str]:
    try:
        val = data["auditor"][0]["tls_inspect_policy"]["exact_match"]["bypass"]
        return val if val else []
    except (KeyError, IndexError, TypeError):
        return []


def current_child_bypass(data) -> list[str]:
    try:
        return data["auditor"][0]["tls_inspect_policy"]["child_match"]["bypass"]
    except (KeyError, IndexError, TypeError):
        return []


# AI agent domains — explicit list, must be exact (these are the critical ones to flag).
_AI_AGENT_DOMAINS: set[str] = {
    "anthropic.com", "claude.ai", "claude.com",
    "openai.com", "oaistatic.com", "chatgpt.com",
    "githubcopilot.com",
    "openrouter.ai",
    "x.ai",
    "cohere.com",
    "mistral.ai",
    "together.ai",
    "groq.com",
    "huggingface.co",
    "perplexity.ai",
    "deepmind.com",
}

# Keyword fragments matched against the root domain.
# Checked in order: app first, then browser. First match wins.
_APP_KEYWORDS: tuple[str, ...] = (
    "apple", "icloud", "mzstatic", "cdn-apple",            # Apple
    "microsoft", "microsoftonline", "msftstatic",           # Microsoft identity/infra
    "visualstudio", "vsassets", "vscode",                   # VS Code
    "sharepoint", "sharepointonline",                       # SharePoint
    "slack", "slackb",                                      # Slack
    "zoom",                                                 # Zoom
    "dropbox",                                              # Dropbox
    "github",                                               # GitHub (desktop app)
    "exp-tas",                                              # VS Code experimentation
    "whatsapp", "whatsapp.net",                             # WhatsApp
    "telegram", "t.me",                                     # Telegram
    "signal",                                               # Signal
)

_BROWSER_KEYWORDS: tuple[str, ...] = (
    "google", "googleapis", "gstatic", "googleusercontent",  # Google
    "youtube", "ytimg", "ggpht",                             # YouTube
    "bing", "msn", "live",                                   # Microsoft browser/consumer
    "cloudflare",                                            # Cloudflare
    "akamai", "akamaized", "akamaitechnologies",             # Akamai CDN
    "twitter", "t.co", "ads-twitter",                        # Twitter
    "facebook", "fbcdn", "facebook.net",                     # Facebook
    "linkedin", "licdn",                                     # LinkedIn
    "doubleclick", "googletagmanager",                       # Ads/analytics
    "hcaptcha", "recaptcha",                                 # Captcha
    "cloudflareinsights",                                    # Browser analytics
    "tiktok",                                                # TikTok
    "instagram",                                             # Instagram
    "reddit",                                                # Reddit
    "amazon", "amazonaws",                                   # AWS/Amazon browser
    "demdex", "omtrdc",                                      # Adobe analytics
    "scorecardresearch",                                     # Nielsen analytics
    "onetrust", "cookielaw",                                 # Cookie consent
)


def classify_domain(domain: str) -> str:
    if domain in _AI_AGENT_DOMAINS:
        return "ai_agent"
    for kw in _APP_KEYWORDS:
        if kw in domain:
            return "app"
    for kw in _BROWSER_KEYWORDS:
        if kw in domain:
            return "browser"
    return "unknown"


MULTI_PART_TLDS = {"co.uk", "co.in", "co.jp", "co.au", "co.nz", "co.za", "com.au", "com.br"}

def root_domain(hostname: str) -> str:
    """Extract registrable root domain, handling common multi-part TLDs."""
    parts = hostname.rstrip(".").split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in MULTI_PART_TLDS:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:]) if len(parts) >= 2 else hostname


def add_to_bypass(hostname: str, user: str = "unknown", error_type: str = "SslError") -> bool:
    """
    Add the exact hostname to exact_match bypass.
    Only the specific hostname that cert-pinned is bypassed — other subdomains
    of the same root domain remain intercepted.
    Returns True if yaml was changed.
    """
    data = load_yaml()
    exact_bypass = current_exact_bypass(data)

    if hostname in exact_bypass:
        log.info("hostname %s already in exact_match bypass", hostname)
        return False

    exact_bypass.append(hostname)
    policy = data["auditor"][0]["tls_inspect_policy"]
    if "exact_match" not in policy or policy["exact_match"] is None:
        policy["exact_match"] = {}
    policy["exact_match"]["bypass"] = exact_bypass
    save_yaml(data)
    log.info(
        "added %s to exact_match bypass (%d exact entries) | triggered_by=%s error=%s",
        hostname, len(exact_bypass), user, error_type,
    )
    return True


def notify_backend(hostname: str, domain: str, error_type: str, triggered_by: str, source_type: str = "unknown", raw_log: str = ""):
    """POST bypass event to backend internal endpoint."""
    payload = json.dumps({
        "hostname": hostname,
        "domain": domain,
        "error_type": error_type,
        "triggered_by": triggered_by,
        "source_type": source_type,
        "raw_log": raw_log.strip(),
    }).encode()
    url = f"{BACKEND_URL}/api/v1/internal/proxy-bypass"
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            log.info("backend notified: %s %s", resp.status, domain)
    except urllib.error.URLError as e:
        log.warning("backend notify failed for %s: %s", domain, e)


def reload_g3proxy():
    """Send SIGHUP to the g3proxy container (triggers full config hot-reload)."""
    result = subprocess.run(
        ["docker", "kill", "--signal", "HUP", CONTAINER_NAME],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        log.info("sent SIGHUP to %s — config reloading", CONTAINER_NAME)
    else:
        log.error("SIGHUP failed: %s", result.stderr.strip())


def stream_logs():
    """Yield log lines from the g3proxy container indefinitely."""
    while True:
        try:
            proc = subprocess.Popen(
                ["docker", "logs", "-f", "--tail", "0", CONTAINER_NAME],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            for line in proc.stdout:
                yield line
            exit_code = proc.wait()
            if exit_code != 0:
                log.warning("docker logs exited with code %d — retrying in 5s", exit_code)
                time.sleep(5)
        except Exception as e:
            log.error("log stream error: %s — retrying in 5s", e)
            time.sleep(5)


def process_line(line: str):
    if "InterceptionError" not in line:
        return
    if not RE_SSL_REJECTION.search(line):
        return

    m = RE_INTERCEPT_ERROR.search(line)
    if not m:
        return

    hostname = m.group(1)

    user_m = RE_USER.search(line)
    user = user_m.group(1) if user_m else "unknown"

    err_m = RE_ERROR_TYPE.search(line)
    error_type = err_m.group(1) if err_m else "SslError"

    log.info("cert-pin detected: %s | user=%s error=%s", hostname, user, error_type)

    domain = root_domain(hostname)
    source_type = classify_domain(domain)
    changed = add_to_bypass(hostname, user=user, error_type=error_type)
    if changed:
        reload_g3proxy()
        notify_backend(hostname=hostname, domain=domain, error_type=error_type, triggered_by=user, source_type=source_type, raw_log=line)


def main():
    log.info("starting — watching %s logs, config at %s", CONTAINER_NAME, YAML_PATH)

    if not YAML_PATH.exists():
        log.error("config file not found: %s", YAML_PATH)
        sys.exit(1)

    data = load_yaml()
    log.info(
        "current bypass: %d exact entries, %d child entries",
        len(current_exact_bypass(data)),
        len(current_child_bypass(data)),
    )

    for line in stream_logs():
        process_line(line)


if __name__ == "__main__":
    main()
