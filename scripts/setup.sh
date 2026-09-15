#!/usr/bin/env bash
# One-command deployment:
#   certificates -> stack -> install wait -> hardening -> 2FA -> IAM -> audit
#
# Usage:  sudo bash scripts/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmds docker openssl curl

log_info "=== secure-nextcloud setup ==="

if [[ "$(id -u)" -ne 0 ]]; then
    log_warn "Not running as root - if docker fails with permission errors, re-run with sudo"
fi

# 1. Environment ------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/.env" ]]; then
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
    chmod 600 "$REPO_ROOT/.env"
    log_warn "Created .env from the template - the template passwords are PUBLIC."
    log_warn "Edit .env and change every password before putting this into production."
    sleep 5
fi
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
: "${NC_DOMAIN:?NC_DOMAIN missing in .env}"

# 2. TLS certificates ---------------------------------------------------------
CERT_DIR="${CERT_DIR:-$REPO_ROOT/certs}"
if [[ ! -s "$CERT_DIR/server.crt" ]]; then
    bash "$SCRIPT_DIR/gen-certs.sh"
else
    log_ok "TLS certificates already present"
fi

# 3. Stack --------------------------------------------------------------------
log_info "Starting the stack (first run installs Nextcloud, 1-3 minutes)..."
compose up -d --wait

# 4. Wait for the application -------------------------------------------------
wait_for_nextcloud 420

# 5. Security pipeline --------------------------------------------------------
bash "$SCRIPT_DIR/harden.sh"
bash "$SCRIPT_DIR/enforce-2fa.sh"
bash "$SCRIPT_DIR/iam.sh" --demo

# 6. Verify -------------------------------------------------------------------
if bash "$SCRIPT_DIR/audit.sh" --live; then
    log_ok "Security audit passed."
else
    log_warn "Security audit reported failures - review the output above."
fi

cat <<EOF

=== Deployment finished ===

  URL:          https://${NC_DOMAIN}
  Admin:        ${NEXTCLOUD_ADMIN_USER:-cloudadmin}
  Certificates: $CERT_DIR (trust ca.crt on client devices)

  Next steps:
    1. Trust the local CA on every client device:
         Linux:   cp certs/ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
         Windows: double-click ca.crt -> install into "Trusted Root Certification Authorities"
    2. Point the domain at the VM:  <VM-IP> ${NC_DOMAIN}   (in /etc/hosts or local DNS)
    3. Log in, enroll your TOTP second factor (it is enforced).
    4. Schedule daily backups: see docs/runbook.md

EOF
