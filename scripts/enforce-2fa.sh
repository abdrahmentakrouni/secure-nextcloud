#!/usr/bin/env bash
# Enforce TOTP two-factor authentication for EVERY account.
# Users enroll on their next login (TOTP app + one-time backup codes).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmds docker

[[ -f "$REPO_ROOT/.env" ]] || die "No .env found - copy .env.example to .env first"
compose ps app | grep -q app || die "Stack is not running - start it first (scripts/setup.sh)"

log_info "Enforcing two-factor authentication (TOTP)..."

if ! app_enabled twofactor_totp; then
    if occ app:list | grep -q -- "twofactor_totp"; then
        occ app:enable twofactor_totp
    else
        log_info "TOTP app not shipped with this build - installing from the app store..."
        occ app:install twofactor_totp
    fi
fi

if ! app_enabled twofactor_backupcodes; then
    occ app:enable twofactor_backupcodes
fi

# Empty enforced-groups list = every account, no exceptions.
occ config:system:set twofactor_enforced --type boolean --value true
occ config:system:set twofactor_enforced_groups --type json --value '[]'
occ config:system:set twofactor_enforced_excluded_groups --type json --value '[]'

log_ok "2FA is now enforced for ALL accounts (TOTP + backup codes)."
log_info "Each user is prompted to enroll on their next login."
