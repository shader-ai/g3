#!/usr/bin/env bash
# nftables-tproxy.sh — install the urai_tproxy nftables ruleset on the gateway host.
#
# Creates a TPROXY chain that redirects WireGuard inner traffic to g3proxy
# (127.0.0.1:3129) while exempting Microsoft Entra auth IPs from TLS inspection.
# g3 has no per-SNI no-bump path; the Entra carve-out must happen here at L4.
#
# Run as root. Idempotent — flushes and recreates the table on each run.
# Run sync-azure-login-ips.sh after this to populate the azure_login_v4 set.
set -euo pipefail

nft -f - <<'NFTEOF'
# Flush and recreate so the script is idempotent.
table inet urai_tproxy
delete table inet urai_tproxy

table inet urai_tproxy {
    # Named set — populated by sync-azure-login-ips.sh (cron/systemd-timer).
    set azure_login_v4 {
        type ipv4_addr
        flags interval
    }

    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # Entra auth traffic (login.microsoftonline.com, etc.) routes direct —
        # no TLS bump, real certificate seen by the agent.
        ip daddr @azure_login_v4 return

        # All other TCP from WireGuard inner addresses → g3proxy TPROXY.
        meta l4proto tcp tproxy to 127.0.0.1:3129 meta mark set 1
    }
}
NFTEOF

echo "urai_tproxy table installed."
echo "Run sync-azure-login-ips.sh to populate azure_login_v4."
