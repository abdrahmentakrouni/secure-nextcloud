# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - 2026-09-15

### Added

- Docker Compose stack: Nextcloud 31 (FPM), nginx 1.27, MariaDB 11.4, Redis 7, cron
- Local TLS PKI: root CA + SAN server certificate generator, renewal script
- nginx reverse proxy: TLS 1.2/1.3 only, HSTS, login rate limiting, internal paths blocked
- Security baseline hardening: HTTPS enforcement, audit log, password policy, strict sharing rules, telemetry off
- Enforced TOTP two-factor authentication with backup codes for all accounts
- IAM bootstrap: five role groups, demo users with quotas, app restrictions, offboarding helper
- Encrypted backups (AES-256-CBC, PBKDF2) with SHA-256 manifests and retention, plus restore script
- Security audit script with live verification mode (20+ controls, non-zero exit on failure)
- One-command deployment via scripts/setup.sh
- CI: ShellCheck 0.9, yamllint, compose validation, certificate tests, full-stack smoke test
- Documentation: architecture + threat model, GDPR control mapping, IAM matrix, operations runbook
