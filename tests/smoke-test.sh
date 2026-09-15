#!/usr/bin/env bash
# CI smoke test - verifies the FULL security pipeline against a running stack.
# The workflow boots the stack first; this script does the rest:
#   wait -> harden -> 2FA -> IAM -> audit -> end-to-end HTTPS assertions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=../scripts/lib.sh
source "$SCRIPT_DIR/../scripts/lib.sh"

require_cmds docker curl openssl

[[ -f "$REPO_ROOT/.env" ]] || die ".env missing - the workflow must create it first"
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"

# On any error, dump container logs for the CI artifact.
trap 'compose logs --tail 100 > "$REPO_ROOT/compose-logs.txt" 2>&1 || true' ERR

wait_for_nextcloud 600

bash "$REPO_ROOT/scripts/harden.sh"
bash "$REPO_ROOT/scripts/enforce-2fa.sh"
bash "$REPO_ROOT/scripts/iam.sh" --demo

bash "$REPO_ROOT/scripts/audit.sh" --live || {
    log_err "Security audit reported failures"
    exit 1
}

log_info "End-to-end assertions..."

code="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${NC_DOMAIN}" https://localhost/login)"
[[ "$code" == "200" ]] || { log_err "Login page returned HTTP $code"; exit 1; }
log_ok "Login page loads over HTTPS (200)"

curl -skI -H "Host: ${NC_DOMAIN}" https://localhost/ \
    | grep -qi "strict-transport-security" \
    || { log_err "HSTS header missing"; exit 1; }
log_ok "HSTS header present"

code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/)"
[[ "$code" == "301" ]] || { log_err "HTTP did not redirect to HTTPS (got $code)"; exit 1; }
log_ok "Plain HTTP redirects to HTTPS (301)"

occ user:info alice.martin >/dev/null 2>&1 \
    || { log_err "Demo user alice.martin was not created"; exit 1; }
log_ok "IAM demo user exists"

occ config:system:get twofactor_enforced 2>/dev/null | grep -qE '^(true|1)$' \
    || { log_err "2FA is not enforced after enforce-2fa.sh"; exit 1; }
log_ok "2FA enforcement verified"

log_ok "Smoke test PASSED"
