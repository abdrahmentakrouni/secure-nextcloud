#!/usr/bin/env bash
# Shared helpers for all secure-nextcloud scripts.
# shellcheck shell=bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_ok()   { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_err()  { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; }

die() { log_err "$*"; exit 1; }

require_cmds() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
    done
}

# Resolve the repo root from the calling script's location (scripts live in scripts/).
if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    REPO_ROOT="$(dirname "$SCRIPT_DIR")"
fi

COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/docker-compose.yml}"

compose() {
    docker compose -f "$COMPOSE_FILE" "$@"
}

# Run an occ command inside the app container as the web user.
occ() {
    compose exec -T -u www-data app php occ "$@"
}

# Run occ with an extra environment variable (e.g. OC_PASS for user creation).
occ_env() {
    local var_name="$1" var_value="$2"
    shift 2
    compose exec -T -u www-data -e "${var_name}=${var_value}" app php occ "$@"
}

# Check whether an app is enabled (not just installed).
app_enabled() {
    occ app:list | awk '/Enabled:/{f=1;next} /Disabled:/{f=0} f' | grep -q -- "- ${1}:"
}

# Wait for the Nextcloud API to answer over HTTPS through nginx.
wait_for_nextcloud() {
    local timeout="${1:-300}" waited=0
    log_info "Waiting for Nextcloud to become ready (timeout ${timeout}s)..."
    until curl -skf -H "Host: ${NC_DOMAIN:-nextcloud.local}" \
            https://localhost/status.php >/dev/null 2>&1; do
        sleep 5
        waited=$((waited + 5))
        if (( waited >= timeout )); then
            compose logs --tail=50 app nginx 2>/dev/null || true
            die "Nextcloud did not become ready within ${timeout}s"
        fi
    done
    log_ok "Nextcloud is up"
}
