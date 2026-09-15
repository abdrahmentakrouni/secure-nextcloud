# Identity & Access Management (IAM)

## Role model

Five groups cover the classic company structure. The principle: **an employee
sees only what belongs to their role** - the HR folder is not visible to
developers, clients see only what is explicitly shared with them.

| Group        | Purpose                        | Files quota | Public links | Internal apps (e.g. Calendar) | Typical members          |
|--------------|--------------------------------|-------------|--------------|-------------------------------|--------------------------|
| `it-admins`  | Platform administration        | 10 GB       | yes          | yes                           | IT staff                 |
| `management` | Leadership, board documents    | 10 GB       | yes          | yes                           | Directors                |
| `hr`         | Contracts, payroll, reviews    | 5 GB        | yes          | yes                           | HR team                  |
| `employees`  | Day-to-day work                | 5 GB        | yes          | yes                           | Staff                    |
| `clients`    | External, project-scoped       | 1 GB        | yes*         | **no**                        | Client contacts          |

\* every public link is **password-protected and expires within 7 days**
(enforced instance-wide by `scripts/harden.sh`, not left to user discipline).

## How enforcement works

| Layer    | Mechanism                                                       | Where            |
|----------|-----------------------------------------------------------------|------------------|
| Groups   | `occ group:add` - roles map 1:1 to Nextcloud groups             | `scripts/iam.sh` |
| Quotas   | `occ user:setting <uid> files quota <size>` per user            | `scripts/iam.sh` |
| App gate | Calendar restricted to internal groups via `config:app:set`     | `scripts/iam.sh` |
| Sharing  | Expiry + password enforced globally, anonymous uploads disabled | `scripts/harden.sh` |
| 2FA      | TOTP enforced for every account, backup codes enabled           | `scripts/enforce-2fa.sh` |
| Login    | nginx rate limit (10/min/IP) + built-in throttling              | `nginx/conf.d/nextcloud.conf` |

The `clients` group is the external boundary: members can browse shared
folders and upload through expiring requests, but internal applications and
group-wide shares stay out of reach.

## User lifecycle

**Onboarding.**

```bash
# interactive (prompts for a password):
docker compose exec -u www-data app php occ user:add --display-name="Jane Doe" -g employees jane.doe
# scripted (password from environment, never a CLI argument):
docker compose exec -u www-data -e OC_PASS='Aa1!xxxxxxxxxxxx' app php occ user:add --display-name="Jane Doe" -g employees jane.doe
docker compose exec -u www-data app php occ user:setting jane.doe files quota '5 GB'
```

The user then logs in once and is forced to enroll their TOTP app and save
backup codes - enforcement is instance-wide, so nobody can skip it.

**Offboarding.**

```bash
bash scripts/iam.sh --offboard jane.doe
```

Disables the account immediately (sessions and app passwords revoked), keeps
the files, and prints the `files:transfer-ownership` command to hand active
shares to a colleague. Delete the account later once handover is confirmed:
`occ user:delete jane.doe`.

**Quarterly access review (runbook item).**

```bash
docker compose exec -u www-data app php occ group:list
docker compose exec -u www-data app php occ user:list
docker compose exec -u www-data app php occ twofactorauth:state
```

Cross-check group membership against HR reality; remove anyone who changed
roles, and confirm every account shows 2FA configured.

## Why groups instead of per-user settings

People move between roles; user settings rot. With the role model, a move is
one `occ group:adduser`/`group:removeuser` pair and every permission follows
the group definition above. Auditors can read the table, engineers can diff
the script - the policy lives in version control, not in someone's memory.
