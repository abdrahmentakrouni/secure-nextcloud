# Secure Nextcloud Infrastructure

[![CI](https://github.com/abdrahmentakrouni/secure-nextcloud/actions/workflows/ci.yml/badge.svg)](https://github.com/abdrahmentakrouni/secure-nextcloud/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/abdrahmentakrouni/secure-nextcloud)](https://github.com/abdrahmentakrouni/secure-nextcloud/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Nextcloud](https://img.shields.io/badge/Nextcloud-31-informational)
![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-2496ED)
![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)

A **private cloud, hardened**. GDPR-aligned Nextcloud on your own VM: TLS 1.3
everywhere, two-factor authentication forced on every account, role-based
access for five company groups, encrypted backups with a tested restore path.
One command deploys the whole thing; CI boots it and proves the controls on
every push.

> **Why this exists.** European companies lose client trust - and face GDPR
> fines up to 4% of global revenue - when confidential files leak. Files on a
> consumer cloud sit on someone else's servers, often without 2FA, with
> links that never expire. This project builds the alternative: a private
> cloud where the company keeps the keys and the defaults are the safe ones.

## What it protects against

| Threat (business view)            | Control in this stack                                       | GDPR        |
|-----------------------------------|-------------------------------------------------------------|-------------|
| Files intercepted in transit      | TLS 1.2/1.3 only, HSTS, HTTPS forced app-side               | Art. 32     |
| Stolen or weak credentials        | **Enforced** TOTP 2FA + backup codes, rate-limited login    | Art. 32     |
| Over-sharing, ex-employee access  | RBAC groups, quotas, expiring password-protected links      | Art. 5, 25  |
| Ransomware / disk failure         | AES-256 encrypted backups + documented restore drill        | Art. 32(1)(c) |
| Silent harvesting                 | Telemetry/federation apps disabled                          | Art. 25     |
| "Who did what?"                   | Append-only audit log (`admin_audit`)                       | Art. 5(2)   |

Full mapping with articles: [docs/gdpr-compliance.md](docs/gdpr-compliance.md)

## Architecture

```
                    +--------------------------- Virtual Machine ---------------------------+
                    |                                                                       |
 Clients            |  nginx :443        TLS 1.2/1.3 - HSTS - login rate limiting           |
 (LAN/VPN) --HTTPS->|     |             static files                                        |
                    |     | FastCGI :9000                                                   |
                    |     v                                                                 |
                    |  Nextcloud 31 (FPM) <-----  Redis (cache + file locking)              |
                    |     |                                                                 |
                    |     v                                                                 |
                    |  MariaDB 11.4   (internal network - no published ports)               |
                    |                                                                       |
                    |  cron container (background jobs)      backup.sh -> encrypted off-site|
                    +-----------------------------------------------------------------------+
```

The database and Redis live on an **internal Docker network** with no route
to the outside. Only nginx faces the network. Details and the threat model:
[docs/architecture.md](docs/architecture.md)

## Quickstart

```bash
git clone https://github.com/abdrahmentakrouni/secure-nextcloud.git
cd secure-nextcloud
cp .env.example .env && nano .env          # change EVERY password
sudo bash scripts/setup.sh                 # certs -> stack -> hardening -> 2FA -> IAM -> audit
```

For a local VM, point the domain at it first: `echo "<VM-IP> nextcloud.local" | sudo tee -a /etc/hosts`, then trust `certs/ca.crt` on your client devices (setup prints the exact commands for Linux and Windows when it finishes).

## What `setup.sh` actually does

1. **Generates a private PKI** - local root CA + a server certificate for
   your domain (`scripts/gen-certs.sh`, SAN includes the domain, keys 0600)
2. **Boots the stack** - Nextcloud 31 FPM, nginx 1.27, MariaDB 11.4, Redis 7,
   cron - and waits for the install to complete
3. **Hardens Nextcloud** (`scripts/harden.sh`) - HTTPS-only URLs, audit log,
   password policy (12+, all character classes, 90-day expiry), links
   password-protected and capped at 7 days, anonymous uploads disabled,
   telemetry and federation off
4. **Enforces 2FA** (`scripts/enforce-2fa.sh`) - TOTP for *every* account,
   backup codes enabled; users enroll on next login
5. **Sets up IAM** (`scripts/iam.sh`) - groups (`it-admins`, `management`,
   `hr`, `employees`, `clients`), demo users with quotas, internal apps
   hidden from external users
6. **Audits itself** (`scripts/audit.sh --live`) - 20+ controls verified
   against the running instance; non-zero exit on any failure

## Verification, not promises

Every push runs the same pipeline in CI:

- ShellCheck 0.9 + yamllint on all scripts and YAML
- `docker compose config` validation
- Certificate tooling tested with `openssl verify`
- **Full-stack smoke test**: the real stack boots in the runner, the
  hardening/2FA/IAM scripts run against it, the audit must pass, login must
  serve over HTTPS with HSTS, HTTP must redirect with 301

```text
[ OK ] TLS 1.3 enabled
[ OK ] HSTS header sent by nginx
[ OK ] Two-factor authentication enforced for all accounts
[ OK ] Share expiry enforced
[ OK ] Audit logging enabled
[ OK ] Database not published to the host (backend network only)
Result: 21 passed, 0 failed, 1 warnings
```

## Operations in one page

| Task                    | Command                                        |
|-------------------------|------------------------------------------------|
| Deploy                  | `sudo bash scripts/setup.sh`                   |
| Daily audit             | `bash scripts/audit.sh --live`                 |
| Encrypted backup        | `BACKUP_PASSPHRASE=... bash scripts/backup.sh` |
| Restore                 | `BACKUP_PASSPHRASE=... bash scripts/restore.sh backups/<stamp>` |
| Renew certificate       | `sudo bash scripts/renew-certs.sh`             |
| Offboard a user         | `bash scripts/iam.sh --offboard <user>`        |

Runbooks, incident response (including the GDPR 72-hour path) and update
procedures: [docs/runbook.md](docs/runbook.md)

## Documentation

| Document                                      | Contents                                       |
|-----------------------------------------------|------------------------------------------------|
| [docs/architecture.md](docs/architecture.md)  | Components, data flows, STRIDE threat model    |
| [docs/gdpr-compliance.md](docs/gdpr-compliance.md) | Control-to-article mapping, records of processing |
| [docs/iam-matrix.md](docs/iam-matrix.md)      | Role model, onboarding, offboarding, reviews   |
| [docs/runbook.md](docs/runbook.md)            | Backups, restore drills, updates, incidents    |

## Disclaimer

Built for learning and portfolio demonstration. Change every password in
`.env`, read the docs before production use, and have compliance reviewed by
a human who is allowed to give legal advice.
