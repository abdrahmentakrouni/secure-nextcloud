#!/usr/bin/env bash
# Security audit for the secure-nextcloud stack.
#
# Usage:
#   bash scripts/audit.sh           # static checks (config files, certs, TLS settings)
#   bash scripts/audit.sh --live    # also verify the RUNNING stack via occ and HTTPS
#
# Exit codes: 0 = no failures, 1 = at least one FAIL (warnings do not fail).
# Note: -e is intentionally NOT set - we want to collect every result, not stop
# at the first problem.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

require_cmds grep openssl

PASS=0
FAIL=0
WARN=0

ok()   { log_ok "$*";   PASS=$((PASS + 1)); }
bad()  { log_err "$*";  FAIL=$((FAIL + 1)); }
warn() { log_warn "$*"; WARN=$((WARN + 1)); }

NC_DOMAIN="${NC_DOMAIN:-nextcloud.local}"
CERT_DIR="${CERT_DIR:-$REPO_ROOT/certs}"
COMPOSE_YML="$REPO_ROOT/docker-compose.yml"
NGINX_CONF="$REPO_ROOT/nginx/conf.d/nextcloud.conf"

section() { printf "\n"; log_info "--- $1 ---"; }

# Load .env if present (for NC_DOMAIN etc.) without failing when absent.
if [[ -f "$REPO_ROOT/.env" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    NC_DOMAIN="${NC_DOMAIN:-nextcloud.local}"
fi

# ---------------------------------------------------------------- static ---
section "Secrets and environment"

if [[ -f "$REPO_ROOT/.env" ]]; then
    ok ".env exists"
    env_perms="$(stat -c %a "$REPO_ROOT/.env" 2>/dev/null || echo unknown)"
    if [[ "$env_perms" == "600" ]]; then
        ok ".env permissions are 600"
    else
        bad ".env permissions are $env_perms (expected 600) - run: chmod 600 .env"
    fi
    if grep -vE '^\s*#' "$REPO_ROOT/.env" | grep -qi "ChangeMe"; then
        bad ".env still contains template passwords (ChangeMe)"
    else
        ok ".env has no template passwords left"
    fi
else
    warn ".env not found (static secrets checks skipped)"
fi

section "TLS certificates"

if [[ -s "$CERT_DIR/server.crt" && -s "$CERT_DIR/ca.crt" ]]; then
    ok "Certificate and CA present in $CERT_DIR"
    if openssl x509 -checkend 86400 -noout -in "$CERT_DIR/server.crt" >/dev/null 2>&1; then
        ok "Server certificate valid for more than 24h"
    else
        bad "Server certificate expired or expiring within 24h - run scripts/renew-certs.sh"
    fi
    if openssl x509 -in "$CERT_DIR/server.crt" -noout -ext subjectAltName 2>/dev/null \
            | grep -q "DNS:${NC_DOMAIN}"; then
        ok "Certificate SAN covers ${NC_DOMAIN}"
    else
        bad "Certificate SAN does not cover ${NC_DOMAIN}"
    fi
    key_perms="$(stat -c %a "$CERT_DIR/server.key" 2>/dev/null || echo unknown)"
    if [[ "$key_perms" == "600" ]]; then
        ok "Server key permissions are 600"
    else
        bad "Server key permissions are $key_perms (expected 600)"
    fi
else
    warn "No certificates in $CERT_DIR - run scripts/gen-certs.sh"
fi

section "Web server (nginx)"

if grep -q "TLSv1.3" "$NGINX_CONF"; then
    ok "TLS 1.3 enabled"
else
    bad "TLS 1.3 not enabled in nginx config"
fi
if grep -E "TLSv1\.0|TLSv1\.1" "$NGINX_CONF" >/dev/null; then
    bad "Legacy TLS 1.0/1.1 present in nginx config"
else
    ok "No legacy TLS 1.0/1.1 protocols"
fi
if grep -q "Strict-Transport-Security" "$NGINX_CONF"; then
    ok "HSTS header configured"
else
    bad "HSTS header missing from nginx config"
fi
if grep -q "limit_req_zone" "$NGINX_CONF"; then
    ok "Login rate limiting configured"
else
    bad "No rate limiting in nginx config"
fi
if grep -q "client_max_body_size" "$NGINX_CONF"; then
    ok "Upload size limit set"
else
    warn "client_max_body_size not set - nginx defaults to 1M and breaks uploads"
fi

section "Docker Compose surface"

db_ports="$(sed -n '/^  db:/,/^  [a-z]/p' "$COMPOSE_YML" | grep -c 'ports:' || true)"
redis_ports="$(sed -n '/^  redis:/,/^  [a-z]/p' "$COMPOSE_YML" | grep -c 'ports:' || true)"
if [[ "$db_ports" -eq 0 ]]; then
    ok "Database not published to the host (backend network only)"
else
    bad "Database publishes ports to the host"
fi
if [[ "$redis_ports" -eq 0 ]]; then
    ok "Redis not published to the host"
else
    bad "Redis publishes ports to the host"
fi

section "Repository hygiene"

if [[ -f "$REPO_ROOT/.gitignore" ]] && grep -q "^\.env$" "$REPO_ROOT/.gitignore" \
        && grep -q "^certs/" "$REPO_ROOT/.gitignore" && grep -q "^backups/" "$REPO_ROOT/.gitignore"; then
    ok ".gitignore excludes .env, certs/ and backups/"
else
    bad ".gitignore does not exclude secrets and data directories"
fi

# ------------------------------------------------------------------ live ---
if [[ "$LIVE" -eq 1 ]]; then
    require_cmds docker curl
    [[ -f "$REPO_ROOT/.env" ]] || die "--live needs .env"

    section "Running stack"

    if compose ps app 2>/dev/null | grep -q app; then
        ok "Nextcloud container is running"
    else
        bad "Nextcloud container is not running"
    fi

    if curl -skf -H "Host: ${NC_DOMAIN}" https://localhost/status.php 2>/dev/null \
            | grep -q '"installed":true'; then
        ok "Nextcloud answers over HTTPS and is installed"
    else
        bad "status.php not reachable over HTTPS or instance not installed"
    fi

    section "Nextcloud configuration (occ)"

    twofactor="$(occ config:system:get twofactor_enforced 2>/dev/null || echo unset)"
    if printf '%s' "$twofactor" | grep -qE '^(true|1)$'; then
        ok "Two-factor authentication enforced for all accounts"
    else
        bad "2FA not enforced (twofactor_enforced=$twofactor) - run scripts/enforce-2fa.sh"
    fi

    if app_enabled twofactor_totp 2>/dev/null; then
        ok "TOTP app enabled"
    else
        bad "TOTP app not enabled"
    fi

    if app_enabled password_policy 2>/dev/null; then
        ok "Password policy app enabled"
    else
        bad "Password policy app not enabled"
    fi

    if app_enabled admin_audit 2>/dev/null; then
        ok "Audit logging enabled"
    else
        bad "Audit logging (admin_audit) not enabled"
    fi

    proto="$(occ config:system:get overwriteprotocol 2>/dev/null || echo unset)"
    if [[ "$proto" == "https" ]]; then
        ok "HTTPS enforced on all generated URLs"
    else
        bad "overwriteprotocol is '$proto' (expected https)"
    fi

    expire="$(occ config:app:get core shareapi_enforce_expire_date 2>/dev/null || echo unset)"
    if [[ "$expire" == "yes" ]]; then
        ok "Share expiry enforced"
    else
        bad "Share expiry not enforced (got '$expire')"
    fi

    linkpw="$(occ config:app:get core shareapi_enforce_links_password 2>/dev/null || echo unset)"
    if [[ "$linkpw" == "yes" ]]; then
        ok "Passwords enforced on public link shares"
    else
        bad "Public link shares not password-protected (got '$linkpw')"
    fi

    region="$(occ config:system:get default_phone_region 2>/dev/null || echo unset)"
    if [[ "$region" != "unset" && -n "$region" ]]; then
        ok "Phone region set ($region)"
    else
        bad "default_phone_region not set"
    fi

    cache="$(occ config:system:get memcache.local 2>/dev/null || echo unset)"
    if printf '%s' "$cache" | grep -q "APCu"; then
        ok "Local memory cache in use (APCu)"
    else
        bad "memcache.local not set to APCu (got '$cache')"
    fi

    loglevel="$(occ config:system:get loglevel 2>/dev/null || echo unset)"
    if printf '%s' "$loglevel" | grep -qE '^(2|3)$'; then
        ok "Log level minimal (level $loglevel)"
    else
        warn "Log level is $loglevel (2 or 3 recommended)"
    fi

    section "Live HTTPS behaviour"

    if curl -skI -H "Host: ${NC_DOMAIN}" https://localhost/ 2>/dev/null \
            | grep -qi "strict-transport-security"; then
        ok "HSTS header sent by nginx"
    else
        bad "HSTS header missing from live responses"
    fi

    http_code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null || echo 000)"
    if [[ "$http_code" == "301" ]]; then
        ok "Plain HTTP redirects to HTTPS (301)"
    else
        bad "Plain HTTP did not redirect (got $http_code)"
    fi

    if echo | openssl s_client -connect localhost:443 -tls1_3 2>/dev/null \
            | grep -q "New, TLSv1.3"; then
        ok "TLS 1.3 handshake succeeds"
    else
        bad "TLS 1.3 handshake failed"
    fi

    # Belt and suspenders: if the CLIENT itself cannot do TLS 1.1 this check
    # passes trivially; the nginx config check above is the authoritative one.
    if echo | openssl s_client -connect localhost:443 -tls1_1 2>/dev/null \
            | grep -q "Server certificate"; then
        bad "Server still accepts TLS 1.1"
    else
        ok "TLS 1.1 rejected by the server"
    fi
fi

# --------------------------------------------------------------- summary ---
section "Summary"

printf "Result: %s passed, %s failed, %s warnings\n" "$PASS" "$FAIL" "$WARN"

if [[ "$FAIL" -gt 0 ]]; then
    log_err "Audit FAILED - fix the [FAIL] items above."
    exit 1
fi
log_ok "Audit PASSED (with $WARN warnings)."
exit 0
