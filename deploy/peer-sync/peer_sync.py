#!/usr/bin/env python3
"""
Peer-sync daemon for the Urai gateway.

Polls GET /tunnel/peers every PEER_SYNC_INTERVAL seconds, then uses
`wg syncconf` to reconcile WireGuard peers — adding new ones, removing gone
ones. On peer removal, also flushes conntrack flows for the old inner IP so
existing connections are cut immediately (design §6/§9).

Required env:
  URAI_BROKER_URL      — e.g. https://urai.example.com/api/v1
  URAI_GATEWAY_TOKEN   — bearer token for GET /tunnel/peers
  WG_INTERFACE         — WireGuard interface name (default: wg0)
  PEER_SYNC_INTERVAL   — poll interval in seconds (default: 5)
"""
import json
import logging
import os
import subprocess
import sys
import tempfile
import time

import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [peer-sync] %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)

BROKER_URL = os.environ["URAI_BROKER_URL"].rstrip("/")
GATEWAY_TOKEN = os.environ["URAI_GATEWAY_TOKEN"]
WG_IFACE = os.environ.get("WG_INTERFACE", "wg0")
INTERVAL = int(os.environ.get("PEER_SYNC_INTERVAL", "5"))


def fetch_peers() -> list[dict]:
    resp = requests.get(
        f"{BROKER_URL}/tunnel/peers",
        headers={"Authorization": f"Bearer {GATEWAY_TOKEN}"},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def wg_private_key() -> str:
    """Read the current WireGuard private key from the running interface."""
    return subprocess.check_output(
        ["wg", "show", WG_IFACE, "private-key"], text=True
    ).strip()


def syncconf(peers: list[dict]) -> None:
    """Replace all WireGuard peers atomically via `wg syncconf`."""
    privkey = wg_private_key()

    lines = [f"[Interface]", f"PrivateKey = {privkey}", ""]
    for peer in peers:
        lines += [
            "[Peer]",
            f"PublicKey = {peer['public_key']}",
            f"AllowedIPs = {peer['allowed_ips']}",
            "",
        ]

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".conf", delete=False
    ) as f:
        f.write("\n".join(lines))
        fname = f.name

    try:
        subprocess.run(["wg", "syncconf", WG_IFACE, fname], check=True)
    finally:
        os.unlink(fname)


def flush_conntrack(inner_ips: list[str]) -> None:
    """Delete conntrack entries for removed inner IPs so flows are cut instantly."""
    for ip in inner_ips:
        try:
            subprocess.run(
                ["conntrack", "-D", "-s", ip],
                check=False,
                capture_output=True,
            )
        except FileNotFoundError:
            log.debug("conntrack not available; skipping flow flush for %s", ip)


def main() -> None:
    log.info(
        "starting: broker=%s iface=%s interval=%ds", BROKER_URL, WG_IFACE, INTERVAL
    )
    prev_peers: dict[str, dict] = {}

    while True:
        try:
            peers = fetch_peers()
            current: dict[str, dict] = {p["public_key"]: p for p in peers}

            syncconf(peers)

            removed_ips = [
                p["allowed_ips"].split("/")[0]
                for pk, p in prev_peers.items()
                if pk not in current
            ]
            if removed_ips:
                log.info("removed peers, flushing conntrack for: %s", removed_ips)
                flush_conntrack(removed_ips)

            added = set(current) - set(prev_peers)
            if added:
                log.info("added %d new peer(s)", len(added))

            prev_peers = current

        except requests.HTTPError as exc:
            log.warning("broker HTTP error: %s", exc)
        except Exception as exc:
            log.error("sync error: %s", exc)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
