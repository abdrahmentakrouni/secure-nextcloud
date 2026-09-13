#!/usr/bin/env bash
# Generate a local Certificate Authority and a TLS server certificate for the
# Nextcloud domain. Self-signed on purpose: this stack runs on a private LAN/VM.
# For a public deployment use Let's Encrypt instead (see docs/runbook.md).
#
# Usage:  bash scripts/gen-certs.sh            (skips if a certificate exists)
#         FORCE=1 bash scripts/gen-certs.sh    (replace existing certificate)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CERT_DIR="${CERT_DIR:-$REPO_ROOT/certs}"
NC_DOMAIN="${NC_DOMAIN:-nextcloud.local}"
CERT_DAYS="${CERT_DAYS:-825}"
CA_DAYS="${CA_DAYS:-3650}"
KEY_BITS="${KEY_BITS:-3072}"

require_cmds openssl

CA_KEY="$CERT_DIR/ca.key"
CA_CRT="$CERT_DIR/ca.crt"
SRV_KEY="$CERT_DIR/server.key"
SRV_CRT="$CERT_DIR/server.crt"

if [[ -s "$SRV_CRT" && "${FORCE:-0}" != "1" ]]; then
    log_warn "Certificate already exists at $SRV_CRT (use FORCE=1 or scripts/renew-certs.sh)"
    exit 0
fi

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

log_info "Generating local root CA (${CA_DAYS} days)..."
openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -subj "/C=TN/O=Private Cloud/CN=Private Cloud Root CA" \
    -out "$CA_CRT"

log_info "Generating server key (${KEY_BITS} bits)..."
openssl genrsa -out "$SRV_KEY" "$KEY_BITS" 2>/dev/null

log_info "Signing certificate for ${NC_DOMAIN} (${CERT_DAYS} days)..."
EXT_FILE="$(mktemp)"
trap 'rm -f "$EXT_FILE"' EXIT
{
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=serverAuth"
    echo "subjectAltName=DNS:${NC_DOMAIN},IP:127.0.0.1"
} > "$EXT_FILE"

openssl req -new -key "$SRV_KEY" \
    -subj "/C=TN/O=Private Cloud/CN=${NC_DOMAIN}" \
    -out "$CERT_DIR/server.csr"
openssl x509 -req -in "$CERT_DIR/server.csr" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -days "$CERT_DAYS" -sha256 -extfile "$EXT_FILE" \
    -out "$SRV_CRT" 2>/dev/null
rm -f "$EXT_FILE" "$CERT_DIR/server.csr" "$CERT_DIR/ca.srl"
trap - EXIT

chmod 600 "$CA_KEY" "$SRV_KEY"
chmod 644 "$CA_CRT" "$SRV_CRT"

# Self-test: the server certificate must chain back to our CA.
if ! openssl verify -CAfile "$CA_CRT" "$SRV_CRT" >/dev/null; then
    die "Generated certificate failed chain verification"
fi

log_ok "TLS material ready in $CERT_DIR"
log_info "Trust ${CA_CRT} on client devices, then https://${NC_DOMAIN} works without warnings"
