# GDPR alignment

This project is engineered around the pain that keeps European companies away
from consumer cloud tools: **client data leaking**. Under the GDPR a personal
data breach is not just an incident - it is a reportable event (Art. 33, 72
hours) that can cost up to 4% of global annual turnover (Art. 83). The
controls below are mapped to the regulation so a reviewer can see *why* each
piece exists.

> This is an engineering document, not legal advice. A production deployment
> needs its own DPIA and a DPO review.

## Control-to-article mapping

| # | Risk (business language)        | Control in this stack                                          | GDPR basis            |
|---|---------------------------------|----------------------------------------------------------------|-----------------------|
| 1 | Files intercepted in transit    | TLS 1.2/1.3 only, HSTS, private CA, HTTPS enforced app-side    | Art. 32(1)(a)         |
| 2 | Account takeover / stolen login | Enforced TOTP 2FA + backup codes, rate-limited login           | Art. 32(1)(b)         |
| 3 | Over-shared data, ex-employee   | RBAC groups, quotas, enforced share expiry + link passwords    | Art. 5(1)(f), 25      |
| 4 | Ransomware / disk loss          | Daily encrypted backups (AES-256 + PBKDF2), tested restore     | Art. 32(1)(c)         |
| 5 | Silent harvesting by the vendor | Telemetry apps (support, survey_client) disabled               | Art. 25               |
| 6 | "Who did what?" unanswerable    | `admin_audit` append-only audit log                            | Art. 5(2)             |
| 7 | Weak or reused passwords        | Policy: 12+ chars, mixed case, digits, symbols, 90-day expiry  | Art. 32(1)(b)         |
| 8 | Data on a server nobody audits  | Self-hosted, CI-tested setup, checksums, runbook procedures    | Art. 25, 32           |

## Article 32 in practice

Article 32 asks for "a risk-appropriate level of security", and names
pseudonymisation and encryption, confidentiality, integrity, availability and
resilience, plus the ability to **restore** after an incident. How this
project answers each:

- **Encryption** - TLS 1.3 in transit; at rest the VM disk should be LUKS
  encrypted (one checkbox in the virtualization layer), and backups are
  always AES-256 encrypted before leaving the machine.
- **Availability and resilience** - Redis + APCu caching, cron jobs, and a
  documented backup/restore cycle (`backup.sh` / `restore.sh`) that must be
  drilled, not just scheduled (see `docs/runbook.md`).
- **Confidentiality** - internal Docker network with no published database
  ports; only nginx faces the network; login rate limiting; 2FA everywhere.
- **Restoration testing** - the restore script is part of the repo and the
  runbook includes a quarterly restore drill checklist.

## Records of processing (starter)

| Question                 | Answer for this deployment                       |
|--------------------------|--------------------------------------------------|
| Data processed           | File names, file contents, user accounts, logs   |
| Categories of subjects   | Employees, management, external clients          |
| Retention                | Share links expire <= 7 days; backups rotate 30 days |
| Access                   | RBAC groups (it-admins, management, hr, employees, clients) |
| Sub-processors           | None (self-hosted); hosting provider if colocated |
| Breach detection         | Audit log + `nextcloud.log` review (runbook)     |
| Breach notification path | DPO -> supervisory authority within 72h          |

## Data protection by design (Art. 25)

The defaults chosen in `scripts/harden.sh` are the privacy-protective ones
out of the box: public uploads disabled, links require passwords and expire,
telemetry off, federation off, minimal log level. Making the *default* the
*safe* option is exactly what Art. 25 asks for - protection without relying
on users to configure anything.

## Offboarding and data minimisation

`scripts/iam.sh --offboard <user>` disables the account in one command while
keeping files for handover (`occ files:transfer-ownership` is printed). No
orphan accounts with valid passwords linger after someone leaves - the classic
audit finding.
