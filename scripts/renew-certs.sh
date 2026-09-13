#!/usr/bin/env bash
# Replace the TLS server certificate with a fresh one (same local CA) and
# reload nginx if the stack is running. The root CA stays untouched, so
# clients that already trust it keep working without any reconfiguration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmds openssl

CERT_DIR="${CERT_DIR:-$REPO_ROOT/certs}"
NC_DOMAIN="${NC_DOMAIN:-nextcloud.local}"
export CERT_DIR NC_DOMAIN FORCE=1

[[ -s "$CERT_DIR/ca.key" ]] || die "No CA found in $CERT_DIR - run scripts/gen-certs.sh first"

log_info "Renewing server certificate for ${NC_DOMAIN}..."
bash "$SCRIPT_DIR/gen-certs.sh"

if compose ps --status running nginx 2>/dev/null | grep -q nginx; then
    compose exec -T nginx nginx -t -q
    compose exec -T nginx nginx -s reload
    log_ok "nginx reloaded with the new certificate"
else
    log_warn "Stack not running - certificate written, nginx will pick it up on next start"
fi

openssl x509 -enddate -noout -in "$CERT_DIR/server.crt"
