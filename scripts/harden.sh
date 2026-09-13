#!/usr/bin/env bash
# Apply the Nextcloud security baseline:
#   - HTTPS-only URLs and sane trusted domains
#   - strict sharing policy (password + expiry on links, no anonymous uploads)
#   - audit logging, password policy, telemetry off
# Idempotent: safe to run again at any time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmds docker

[[ -f "$REPO_ROOT/.env" ]] || die "No .env found - copy .env.example to .env first"
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
: "${NC_DOMAIN:?NC_DOMAIN missing in .env}"

compose ps app | grep -q app || die "Stack is not running - start it first (scripts/setup.sh)"

log_info "Applying Nextcloud security baseline for ${NC_DOMAIN}..."

# --- Core system configuration -------------------------------------------
occ config:system:set default_phone_region --value="${NC_PHONE_REGION:-TN}"
occ config:system:set maintenance_window_start --type integer --value 2
occ config:system:set loglevel --type integer --value 2

# Every generated URL must be HTTPS.
occ config:system:set overwrite.cli.url --value="https://${NC_DOMAIN}"
occ config:system:set overwriteprotocol --value https
occ config:system:set overwritehost --value "$NC_DOMAIN"

# Trusted domains: what the container image seeded + ours.
occ config:system:set trusted_domains 1 --value="localhost"
occ config:system:set trusted_domains 2 --value="$NC_DOMAIN"

# Local in-memory cache (Redis is already wired by the container image).
occ config:system:set memcache.local --value='\OC\Memcache\APCu'

# --- Audit trail (who did what - GDPR traceability) -----------------------
occ app:enable admin_audit
occ config:system:set logfile_audit --value="/var/www/html/data/audit.log"

# --- Password policy -------------------------------------------------------
occ app:enable password_policy
occ config:app:set password_policy minLength --value 12
occ config:app:set password_policy enforceUpperLowerCase --value 1
occ config:app:set password_policy enforceNumericCharacters --value 1
occ config:app:set password_policy enforceSpecialCharacters --value 1
occ config:app:set password_policy expirationDays --value 90

# --- Sharing: links allowed but locked down --------------------------------
occ config:app:set core shareapi_allow_links --value=yes
occ config:app:set core shareapi_enforce_links_password --value=yes
occ config:app:set core shareapi_default_expire_date --value=yes
occ config:app:set core shareapi_enforce_expire_date --value=yes
occ config:app:set core shareapi_default_expire_units --value days
# Default 7 days; tolerated to be absent on some Nextcloud builds.
occ config:app:set core shareapi_default_expire_date_value --value 7 \
    || log_warn "shareapi_default_expire_date_value not supported - skipping"
occ config:app:set core shareapi_allow_public_upload --value=no
occ config:app:set core shareapi_allow_group_shares --value=yes

# --- Shrink the attack surface ---------------------------------------------
if app_enabled federation; then
    occ app:disable federation
    log_ok "Server-to-server federation disabled"
fi
if app_enabled support; then
    occ app:disable support
    log_ok "Support/telemetry app disabled"
fi
if app_enabled survey_client; then
    occ app:disable survey_client
    log_ok "Usage survey client disabled"
fi

log_ok "Security baseline applied."
