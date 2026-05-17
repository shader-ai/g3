#!/bin/bash
# Generate SSL certificates for G3 proxy (TLS interception)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔐 Generating SSL certificates for G3 Proxy..."

# Generate CA private key (4096-bit RSA)
echo "📝 Generating CA private key..."
mkdir -p certs
openssl genrsa -out certs/ca.key 4096

# Generate CA certificate (valid for 10 years)
echo "📝 Generating CA certificate..."
openssl req -new -x509 -days 3650 -key certs/ca.key -out certs/ca.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=G3 Proxy CA"

# Set appropriate permissions
# Set appropriate permissions
chmod 600 certs/ca.key
chmod 644 certs/ca.crt

echo "✅ Certificates generated successfully!"
echo ""
echo "📁 Files created:"
echo "   - certs/ca.key (private key - keep secure!)"
echo "   - certs/ca.crt (certificate - distribute to clients)"
echo ""
echo "⚠️  IMPORTANT: Clients must import ca.crt into their trusted certificate store"
echo ""
echo "Installation instructions:"
echo ""
echo "Linux (Debian/Ubuntu):"
echo "  sudo cp ca.crt /usr/local/share/ca-certificates/g3-proxy-ca.crt"
echo "  sudo update-ca-certificates"
echo ""
echo "macOS:"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt"
echo ""
echo "Windows:"
echo "  Import ca.crt via certmgr.msc into 'Trusted Root Certification Authorities'"
echo ""
