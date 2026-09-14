#!/usr/bin/env bash
# Restore a backup created by scripts/backup.sh (files + database).
#
# Usage:
#   BACKUP_PASSPHRASE='...' bash scripts/restore.sh backups/<stamp> [--yes]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmds docker openssl

[[ -f "$REPO_ROOT/.env" ]] || die "No .env found - copy .env.example to .env first"
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"

BACKUP="${1:-}"
CONFIRM="${2:-}"
[[ -n "$BACKUP" ]] || die "Usage: BACKUP_PASSPHRASE=... bash scripts/restore.sh backups/<stamp> [--yes]"
[[ -d "$BACKUP" ]] || die "Backup directory not found: $BACKUP"

if [[ "$CONFIRM" != "--yes" ]]; then
    read -r -p "This will OVERWRITE the current Nextcloud files and database. Continue? [y/N] " ans
    [[ "$ans" == "y" ]] || die "Aborted"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

dec() {
    # $1 source (.gz or .gz.enc)  $2 destination
    if [[ -f "${1}.enc" ]]; then
        [[ -n "${BACKUP_PASSPHRASE:-}" ]] || die "Backup is encrypted - set BACKUP_PASSPHRASE"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "${1}.enc" -out "$2"
    elif [[ -f "$1" ]]; then
        cp "$1" "$2"
    else
        die "Missing backup file: $1"
    fi
}

log_info "Decrypting backup set..."
dec "$BACKUP/database.sql.gz" "$TMP/database.sql.gz"
dec "$BACKUP/nextcloud.tar.gz" "$TMP/nextcloud.tar.gz"

log_info "Stopping web, app and cron containers..."
compose stop nginx app cron

log_info "Restoring files..."
compose exec -T app sh -c 'find /var/www/html -mindepth 1 -maxdepth 1 -exec rm -rf {} +'
compose exec -T app tar xzf - -C /var/www/html < "$TMP/nextcloud.tar.gz"

log_info "Restoring database..."
# shellcheck disable=SC2016  # intentional: variables expand inside the container
gunzip -c "$TMP/database.sql.gz" \
    | compose exec -T db sh -c 'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'

log_info "Starting stack..."
compose up -d
wait_for_nextcloud 300

log_ok "Restore complete. Verify logins, shares and file counts before going back to users."
