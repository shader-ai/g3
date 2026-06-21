#!/bin/bash
# G3 Proxy deploy: build from local g3 repo and run.
# Run from deploy/:  ./deploy.sh
# Requires deploy.env in deploy/.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_ENV="${SCRIPT_DIR}/deploy.env"

if [ ! -f "$DEPLOY_ENV" ]; then
    echo "❌ deploy.env not found. Create deploy.env in deploy/ (see deploy.env.example or README)."
    exit 1
fi

echo "📋 Loading configuration from deploy.env..."
set -a
source "$DEPLOY_ENV"
set +a
ICAP_IP=${ICAP_IP:-192.168.23.6}
ICAP_PORT=${ICAP_PORT:-1344}

echo "🚀 G3 Proxy deploy (local repo)"
echo "================================"
echo ""

if [[ $EUID -eq 0 ]]; then
    echo "⚠️  Don't run as root. Use a regular user with sudo."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed."
    exit 1
fi

if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose --version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "❌ Docker Compose is not installed."
    exit 1
fi

echo "📁 Using deploy dir: $SCRIPT_DIR"
mkdir -p "$SCRIPT_DIR/config" "$SCRIPT_DIR/certs" "$SCRIPT_DIR/logs"

# Certificates
if [ ! -f "$SCRIPT_DIR/certs/ca.crt" ] || [ ! -f "$SCRIPT_DIR/certs/ca.key" ]; then
    echo "🔐 Generating SSL certificates..."
    if [ -f "$SCRIPT_DIR/certs/generate-certs.sh" ]; then
        (cd "$SCRIPT_DIR/certs" && chmod +x generate-certs.sh && ./generate-certs.sh)
    elif [ -f "$SCRIPT_DIR/generate-certs.sh" ]; then
        (cd "$SCRIPT_DIR" && chmod +x generate-certs.sh && ./generate-certs.sh)
    else
        echo "❌ No generate-certs.sh found in deploy/certs or deploy/"
        exit 1
    fi
else
    echo "✅ SSL certificates already exist"
fi

echo ""

# ICAP
echo "   ICAP server: ${ICAP_IP}:${ICAP_PORT}"

G3PROXY_YAML="$SCRIPT_DIR/config/g3proxy.yaml"
if [ -f "$G3PROXY_YAML" ]; then
    if sed --version &>/dev/null; then
        sed -i "s|icap://192.168.23.6:1344/|icap://${ICAP_IP}:${ICAP_PORT}/|g" "$G3PROXY_YAML"
        sed -i "s|icap://host.docker.internal:1344/|icap://${ICAP_IP}:${ICAP_PORT}/|g" "$G3PROXY_YAML"
    else
        sed -i '' "s|icap://192.168.23.6:1344/|icap://${ICAP_IP}:${ICAP_PORT}/|g" "$G3PROXY_YAML"
        sed -i '' "s|icap://host.docker.internal:1344/|icap://${ICAP_IP}:${ICAP_PORT}/|g" "$G3PROXY_YAML"
    fi
    echo "✅ ICAP configuration updated"
fi
echo ""

# Build and run (context = parent of deploy = g3 repo)
echo "🏗️  Building images (from local g3 repo)..."
cd "$SCRIPT_DIR"
$COMPOSE_CMD build

echo ""
echo "🚀 Starting containers..."
$COMPOSE_CMD up -d

echo ""
sleep 5
if $COMPOSE_CMD ps | grep -q "running"; then
    echo "✅ G3 Proxy is running!"
    echo ""
    $COMPOSE_CMD ps
    echo ""
    echo "📝 Logs:    cd deploy && $COMPOSE_CMD logs -f"
    echo "🔑 WG key:  docker exec wireguard wg show wg0 public-key"
    echo "📡 Peers:   docker exec wireguard wg show wg0"
    echo "🔐 CA cert: $SCRIPT_DIR/certs/ca.crt  (trust on client: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt)"
    echo ""
    echo "Next: run gateway-net.sh inside the wireguard netns to install TPROXY + masquerade rules:"
    echo "  sudo docker exec wireguard bash /config/gateway-net.sh"
else
    echo "❌ Container failed to start. Check logs:"
    $COMPOSE_CMD logs
    exit 1
fi
