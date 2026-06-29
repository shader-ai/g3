#!/usr/bin/env bash
# gateway-net.sh — idempotent netns setup for the WireGuard gateway.
#
# Run INSIDE the wireguard container's network namespace:
#   sudo docker exec wireguard bash /config/gateway-net.sh
#
# deploy.sh instructs the operator to run this after `docker compose up -d`.
# Pass URAI_BROKER_URL so control-plane IPs are added to the bypass set:
#   URAI_BROKER_URL=https://backend-host/api/v1 docker exec -e URAI_BROKER_URL wireguard bash /config/gateway-net.sh
#
# What this does (all in the wg netns where g3proxy listens on :3129):
#   A1 — build the urai_tproxy nftables table (TPROXY mangle + azure_login_v4 bypass set)
#   A2 — add TPROXY policy routing: fwmark 1 → table 100 → local 0.0.0.0/0 dev lo
#   A3 — add masquerade for WireGuard inner subnet (non-TCP egress: UDP/DNS/ICMP)
#        populate azure_login_v4 via sync-azure-login-ips.sh
#        add broker/backend IPs to azure_login_v4 (control-plane bypass)
#
# Idempotent: safe to re-run after reboot or peer changes.
set -euo pipefail

WG_INNER_CIDR="${WG_INNER_CIDR:-10.66.0.0/16}"
WG_IFACE="${WG_IFACE:-wg0}"
TPROXY_PORT="${TPROXY_PORT:-3129}"
FWMARK="${FWMARK:-1}"
ROUTE_TABLE="${ROUTE_TABLE:-100}"

# ── A1: nftables table ────────────────────────────────────────────────────────
nft -f - <<NFTEOF
table inet urai_tproxy
delete table inet urai_tproxy

table inet urai_tproxy {
    # Entra auth IPs + backend broker IPs — populated below.
    # IPs in this set bypass TPROXY so TLS is not bumped (real cert seen by agent).
    set azure_login_v4 {
        type ipv4_addr
        flags interval
    }

    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # Bypass Entra auth traffic and backend broker so they are not intercepted.
        ip daddr @azure_login_v4 return

        # All TCP from WireGuard inner subnet → TPROXY to g3proxy (no auth).
        ip saddr ${WG_INNER_CIDR} meta l4proto tcp tproxy ip to 127.0.0.1:${TPROXY_PORT} meta mark set ${FWMARK}
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # Masquerade non-TPROXY traffic from the WireGuard inner subnet.
        # TCP is caught by TPROXY before postrouting; g3proxy handles its own outbound.
        # This carries UDP (DNS to 1.1.1.1), ICMP, and other non-TCP egress.
        ip saddr ${WG_INNER_CIDR} masquerade
    }
}
NFTEOF

echo "urai_tproxy table installed."

# ── A2: TPROXY policy routing ─────────────────────────────────────────────────
# Marked packets (fwmark=FWMARK) are routed via table ROUTE_TABLE so the kernel
# delivers them locally to g3proxy (on :TPROXY_PORT) instead of forwarding them.
if ! ip rule show | grep -q "lookup ${ROUTE_TABLE}"; then
    ip rule add fwmark "${FWMARK}" lookup "${ROUTE_TABLE}"
    echo "ip rule: fwmark ${FWMARK} → table ${ROUTE_TABLE} added."
else
    echo "ip rule: fwmark ${FWMARK} → table ${ROUTE_TABLE} already present."
fi

# Use `ip route replace` (idempotent): adds if missing, no-ops if present, never
# errors — so a re-run is safe under `set -e`. (`ip route show` prints this route
# as "local default", so a grep for "local 0.0.0.0/0" never matches and a plain
# `add` would abort the script with "File exists" on every re-run.)
ip route replace local 0.0.0.0/0 dev lo table "${ROUTE_TABLE}"
echo "ip route: local 0.0.0.0/0 dev lo table ${ROUTE_TABLE} ensured."

# CRITICAL: a unicast route for the WG inner subnet in the SAME table.
# The fwmark also taints the kernel's reverse-path source validation: on local
# input, fib_validate_source() re-looks-up the *client source* WITH the mark,
# which lands in this table. With only `local 0.0.0.0/0 dev lo` present, that
# reverse lookup returns RTN_LOCAL → EINVAL, so the kernel drops every TPROXY'd
# TCP SYN as "martian source" (ICMP/UDP are unaffected as they aren't marked).
# A unicast route for the inner subnet makes the reverse lookup resolve via the
# WG interface so source validation passes and the SYN reaches g3proxy.
ip route replace "${WG_INNER_CIDR}" dev "${WG_IFACE}" table "${ROUTE_TABLE}"
echo "ip route: ${WG_INNER_CIDR} dev ${WG_IFACE} table ${ROUTE_TABLE} ensured."

# ── A3a: Entra bypass via sync-azure-login-ips.sh ────────────────────────────
# gateway-net.sh and sync-azure-login-ips.sh are volume-mounted at /config.
SYNC_SCRIPT="/config/sync-azure-login-ips.sh"
if [ -f "$SYNC_SCRIPT" ]; then
    bash "$SYNC_SCRIPT" || echo "sync-azure-login-ips.sh failed (non-fatal; Entra bypass set empty until retried)."
else
    echo "WARNING: sync-azure-login-ips.sh not found at $SYNC_SCRIPT — Entra bypass empty."
    echo "  Copy sync-azure-login-ips.sh to the wg config volume and re-run gateway-net.sh."
fi

# ── A3b: broker bypass ────────────────────────────────────────────────────────
# Add the backend broker's IP(s) to azure_login_v4 so lease-renew calls under
# the kill-switch are not TPROXY-intercepted, TLS-bumped, or logged as AI requests.
if [ -n "${URAI_BROKER_URL:-}" ]; then
    BROKER_HOST=$(echo "$URAI_BROKER_URL" | sed -E 's|https?://([^/:]+).*|\1|')
    if [ -n "$BROKER_HOST" ]; then
        BROKER_IPS=$(getent hosts "$BROKER_HOST" 2>/dev/null | awk '{print $1}' | grep -v ':' || true)
        if [ -n "$BROKER_IPS" ]; then
            for ip in $BROKER_IPS; do
                nft add element inet urai_tproxy azure_login_v4 "{ $ip }" 2>/dev/null || true
                echo "azure_login_v4: added broker IP $ip (${BROKER_HOST})."
            done
        else
            echo "WARNING: could not resolve broker host ${BROKER_HOST} — broker bypass not applied."
        fi
    fi
else
    echo "INFO: URAI_BROKER_URL not set; broker bypass not configured."
    echo "  Re-run with: URAI_BROKER_URL=https://... docker exec -e URAI_BROKER_URL wireguard bash /config/gateway-net.sh"
fi

echo ""
echo "gateway-net.sh complete. Verify with:"
echo "  nft list ruleset"
echo "  ip rule show && ip route show table ${ROUTE_TABLE}"
