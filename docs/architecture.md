# Architecture

## Big picture

Everything runs inside one Virtual Machine (or any Linux host). The only
exposed surface is nginx on ports 80 and 443. The database and Redis live on
an internal Docker network (`internal: true`) that has **no route to the
outside world** - not even from the host's published ports.

```
                     +---------------------------- Virtual Machine ----------------------------+
                     |                                                                            |
 Clients             |   nginx :443          TLS 1.2/1.3 only - HSTS - login rate limiting        |
 (LAN/VPN) --HTTPS-->|      |                static file serving                                 |
                     |      |  FastCGI :9000                                                     |
                     |      v                                                                    |
                     |   Nextcloud 31 (PHP-FPM)  <-----  Redis :6379  (cache + file locking)     |
                     |      |                                                                    |
                     |      v                                                                    |
                     |   MariaDB 11.4  (backend network only - no published ports)               |
                     |                                                                            |
                     |   cron container  --  background jobs (file scans, cleanup, mail)          |
                     |                                                                            |
                     |   scripts/backup.sh  --  encrypted backup -> backups/ (off-site copy)      |
                     +----------------------------------------------------------------------------+
```

## Components

| Component        | Image              | Role                                            |
|------------------|--------------------|-------------------------------------------------|
| `nginx`          | nginx:1.27-alpine  | TLS termination, static files, rate limiting     |
| `app`            | nextcloud:31-fpm   | Nextcloud application (PHP-FPM)                  |
| `cron`           | nextcloud:31-fpm   | Background jobs via `/cron.sh`                   |
| `db`             | mariadb:11.4       | User data, shares, metadata                      |
| `redis`          | redis:7-alpine     | Memcache + distributed file locking              |

Volumes: `nextcloud` (application files), `nextcloud-data` (user files),
`db-data` (database). All three are captured by `scripts/backup.sh`.

## Data flows

**Login flow.** Browser opens HTTPS to nginx. The `/login` location applies a
per-IP rate limit (10/min, burst 5) before the request ever reaches PHP.
Nextcloud additionally throttles repeated failures per user/IP (built-in
brute-force protection) and the audit log records every attempt.

**File upload flow.** Client -> nginx (TLS terminated, size limit 10G) ->
PHP-FPM -> encrypted TLS connection to the DB is not needed (backend network
is already private) -> file stored on the `nextcloud-data` volume with
versioning and the audit entry written.

**Backup flow.** `backup.sh` streams a consistent `mariadb-dump` (single
transaction) and a tar of the web root, encrypts both with AES-256-CBC
(PBKDF2, 200k iterations) and writes a SHA-256 manifest. The resulting folder
is meant to be copied off the VM (rsync/external disk).

## Threat model (STRIDE, condensed)

| Threat                               | Vector                              | Mitigation                                                  |
|--------------------------------------|-------------------------------------|-------------------------------------------------------------|
| Spoofing                             | Credential theft, password spray    | Enforced TOTP 2FA, password policy, rate-limited login      |
| Tampering                            | MITM, forged files                  | TLS 1.2/1.3 + HSTS, internal network isolation, audit log   |
| Repudiation                          | Admin denies an action              | `admin_audit` writes an append-only audit log               |
| Information disclosure               | Leaked shares, eavesdropping        | Password-protected expiring links, no anonymous uploads, TLS everywhere |
| Denial of service                    | Login flooding, huge uploads        | nginx rate limits, body size caps, VM-level firewall (host) |
| Elevation of privilege               | Rogue app installation              | App store limited to admins; telemetry apps disabled        |

## Design decisions

**PHP-FPM + nginx instead of the bundled Apache image.** Separation of the
web server from the runtime is the standard production pattern: TLS and rate
limiting live in one place, the app container has no root ports, and static
files are served without touching PHP.

**No Nextcloud server-side encryption.** Nextcloud's built-in encryption
keeps the keys on the same server, which adds complexity without moving the
trust boundary. The honest controls are: TLS in transit, an encrypted VM disk
(LUKS) at rest, and GPG/AES-encrypted backups off-site. This is documented so
nobody mistakes the absence of the app for an oversight.

**MariaDB 11.4 LTS with READ-COMMITTED.** Required transaction isolation for
Nextcloud with binary logging enabled; keeps `mariadb-dump
--single-transaction` backups consistent without locking users out.

**Redis for locking.** File locking on the database does not scale and breaks
background jobs; Redis with a password on the internal network is the
reference setup.
