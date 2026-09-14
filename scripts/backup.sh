#!/usr/bin/env bash
# Encrypted full backup: database dump + file archive + checksums.
#
# Usage:
#   BACKUP_PASSPHRASE='...' bash scripts/backup.sh
#   (without a passphrase the backup is stored UNENCRYPTED with a warning)
#
# Schedule it daily from the host: see docs/runbook.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmds docker openssl

[[ -f "$REPO_ROOT/.env" ]] || die "No .env found - copy .env.example to .env first"
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"

BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
TARGET="$BACKUP_DIR/$STAMP"

mkdir -p "$TARGET"

DB_DUMP="$TARGET/database.sql.gz"
HTML_TAR="$TARGET/nextcloud.tar.gz"

log_info "Backing up database..."
# shellcheck disable=SC2016  # intentional: variables expand inside the container
compose exec -T db sh -c 'mariadb-dump --single-transaction -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' \
    | gzip > "$DB_DUMP"
[[ -s "$DB_DUMP" ]] || die "Database dump is empty - aborting"

log_info "Archiving Nextcloud files (config, apps, data)..."
compose exec -T app tar czf - -C /var/www/html . > "$HTML_TAR"
[[ -s "$HTML_TAR" ]] || die "File archive is empty - aborting"

if [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
    log_info "Encrypting backup (AES-256-CBC, PBKDF2, 200k iterations)..."
    for f in "$DB_DUMP" "$HTML_TAR"; do
        openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
            -in "$f" -out "${f}.enc"
        rm -f "$f"
    done
else
    log_warn "BACKUP_PASSPHRASE not set - backup stored UNENCRYPTED"
fi

(cd "$TARGET" && sha256sum ./*) > "$TARGET/SHA256SUMS"

# Retention: delete backup sets older than the configured window.
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' \
    -mtime "+$RETENTION_DAYS" -exec rm -rf {} +

log_ok "Backup complete: $TARGET ($(du -sh "$TARGET" | cut -f1))"
