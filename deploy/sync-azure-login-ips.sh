#!/usr/bin/env bash
# sync-azure-login-ips.sh — fetch Microsoft's published AzureActiveDirectory
# service-tag IP ranges and load them into the nftables azure_login_v4 set.
#
# Data source: https://www.microsoft.com/en-us/download/details.aspx?id=56519
# Microsoft publishes a new JSON file each week; schedule this script accordingly
# (e.g. via systemd-timer or cron weekly, next to peer-sync).
#
# Run as root after nftables-tproxy.sh has created the urai_tproxy table.
set -euo pipefail

DOWNLOAD_URL="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_$(date +%Y%m%d).json"
FALLBACK_URL="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public.json"
TMPFILE=$(mktemp /tmp/azure-service-tags-XXXXXX.json)
trap 'rm -f "$TMPFILE"' EXIT

# Try dated filename first; fall back to the undated permalink.
if ! curl -fsSL "$DOWNLOAD_URL" -o "$TMPFILE" 2>/dev/null; then
    echo "Dated file not available yet, trying permalink..." >&2
    curl -fsSL "$FALLBACK_URL" -o "$TMPFILE"
fi

# Extract AzureActiveDirectory IPv4 prefixes.
PREFIXES=$(python3 - "$TMPFILE" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for entry in data.get("values", []):
    if entry.get("id") == "AzureActiveDirectory":
        for prefix in entry.get("properties", {}).get("addressPrefixes", []):
            if ":" not in prefix:   # skip IPv6
                print(prefix)
        break
PYEOF
)

if [ -z "$PREFIXES" ]; then
    echo "ERROR: no AzureActiveDirectory IPv4 prefixes found in service-tags JSON" >&2
    exit 1
fi

# Flush and reload the set atomically.
{
    echo "flush set inet urai_tproxy azure_login_v4"
    echo "table inet urai_tproxy {"
    echo "  set azure_login_v4 {"
    echo "    type ipv4_addr"
    echo "    flags interval"
    echo "    elements = {"
    echo "$PREFIXES" | sed 's/$/,/' | head -c -2   # trailing comma stripped from last
    echo ""
    echo "    }"
    echo "  }"
    echo "}"
} | nft -f -

COUNT=$(echo "$PREFIXES" | wc -l)
echo "azure_login_v4 updated: $COUNT IPv4 prefixes loaded."
