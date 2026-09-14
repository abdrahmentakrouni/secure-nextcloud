#!/usr/bin/env bash
# Identity & Access Management bootstrap: department groups, optional demo
# users with quotas, and app restrictions for external users.
#
# Usage:
#   bash scripts/iam.sh                 # create the group structure only
#   bash scripts/iam.sh --demo          # groups + demo users (passwords printed once)
#   bash scripts/iam.sh --offboard USER # disable an account, keep data for handover
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmds docker openssl

[[ -f "$REPO_ROOT/.env" ]] || die "No .env found - copy .env.example to .env first"
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"

compose ps app | grep -q app || die "Stack is not running - start it first (scripts/setup.sh)"

# Note: do NOT name this variable GROUPS - that is a special read-only bash
# array (the user's supplementary group IDs) and assignments are ignored.
NC_GROUPS=("it-admins" "management" "hr" "employees" "clients")

ensure_group() {
    occ group:list --output=json | grep -q -- "\"$1\"" || occ group:add "$1"
}

user_exists() {
    occ user:info "$1" >/dev/null 2>&1
}

create_user() {
    # $1 uid  $2 display name  $3 group  $4 quota  $5 password
    if user_exists "$1"; then
        log_warn "User $1 already exists - skipping creation"
    else
        occ_env OC_PASS "$5" user:add --password-from-env \
            --display-name="$2" -g "$3" "$1" >/dev/null
        log_ok "Created $1 ($3)"
    fi
    occ user:setting "$1" files quota "$4"
}

strong_random_password() {
    # Guaranteed to satisfy the password policy: upper, lower, digit, symbol.
    printf 'Aa1!%s' "$(openssl rand -hex 12)"
}

setup_groups() {
    local g
    for g in "${NC_GROUPS[@]}"; do
        ensure_group "$g"
    done
    log_ok "Group structure in place: ${NC_GROUPS[*]}"
}

create_demo_users() {
    local pw="${DEMO_USERS_PASSWORD:-$(strong_random_password)}"
    if [[ -z "${DEMO_USERS_PASSWORD:-}" ]]; then
        log_info "Demo password (printed once, change it on first login): $pw"
    fi
    create_user "alice.martin"  "Alice Martin"  "management" "10 GB" "$pw"
    create_user "karim.benali"  "Karim Benali"  "hr"         "5 GB"  "$pw"
    create_user "sofia.rossi"   "Sofia Rossi"   "employees"  "5 GB"  "$pw"
    create_user "marc.dupont"   "Marc Dupont"   "clients"    "1 GB"  "$pw"

    # Internal tools stay invisible to external clients: enable the Calendar
    # app (shipped with Nextcloud, off by default) and restrict it to staff.
    if ! app_enabled calendar; then
        occ app:enable calendar
    fi
    occ config:app:set calendar enabled \
        --value='["it-admins","management","hr","employees"]'
    log_ok "Calendar restricted to internal staff"
}

offboard_user() {
    local uid="${1:-}"
    [[ -n "$uid" ]] || die "Usage: bash scripts/iam.sh --offboard <username>"
    user_exists "$uid" || die "User not found: $uid"
    occ user:disable "$uid"
    log_ok "Disabled $uid (data kept for handover - see docs/iam-matrix.md)"
    log_info "To move their files: docker compose exec -u www-data app php occ files:transfer-ownership <new-user> $uid"
}

case "${1:-}" in
    --demo)
        setup_groups
        create_demo_users
        ;;
    --offboard)
        offboard_user "${2:-}"
        ;;
    "")
        setup_groups
        ;;
    *)
        die "Usage: bash scripts/iam.sh [--demo] [--offboard USER]"
        ;;
esac
