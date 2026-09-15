# Operations runbook

Day-2 operations for the secure-nextcloud stack. Everything here assumes the
stack was deployed with `sudo bash scripts/setup.sh`.

## Daily: backups

Schedule from the host crontab (`crontab -e`), not inside a container - if
the VM reboots, cron must still find Docker:

```cron
# Daily encrypted backup at 02:30
30 2 * * * cd /opt/secure-nextcloud && BACKUP_PASSPHRASE='CHANGE-ME' bash scripts/backup.sh >> /var/log/nc-backup.log 2>&1
```

Copy the resulting `backups/<stamp>/` folder off the VM (rsync to another
machine or an external disk). An encrypted backup that never leaves the
server protects against ransomware of the *data*, not of the *machine*.

**Verify weekly:** the audit script catches expired certificates and config
drift:

```bash
sudo bash scripts/audit.sh --live
```

## Monthly: restore drill (Art. 32 requires tested recovery)

A backup that was never restored is a hope, not a backup. Once a month, on a
scratch VM or a spare port mapping:

```bash
BACKUP_PASSPHRASE='...' bash scripts/restore.sh backups/<stamp> --yes
bash scripts/audit.sh --live
# then: log in as a test user, open files, check the audit log
```

Keep a note of the last successful drill date - that is what an auditor asks
for first.

## Certificate renewal

The local CA signs certificates for 825 days; renew any time without touching
clients (the CA stays the same):

```bash
sudo bash scripts/renew-certs.sh     # regenerates + reloads nginx
```

For a **public** deployment, switch to Let's Encrypt instead: point real DNS
at the VM, keep the `/.well-known/acme-challenge/` location (already in the
nginx config), run certbot with the webroot plugin, and replace the
certificate paths in `nginx/conf.d/nextcloud.conf`.

## Updating the stack

```bash
cd /opt/secure-nextcloud
BACKUP_PASSPHRASE='...' bash scripts/backup.sh        # backup FIRST
docker compose pull
docker compose up -d
docker compose exec -u www-data app php occ upgrade
sudo bash scripts/audit.sh --live                     # verify nothing broke
```

Read the Nextcloud release notes before jumping more than one major version.

## Incident response

**Suspicious logins / brute force.** nginx rate-limits `/login` and
Nextcloud throttles repeated failures, but check the logs:

```bash
grep -i "login failed\|bruteforce" data/nextcloud.log | tail -50
docker compose exec -u www-data app php occ security:bruteforce:reset <ip>
```

Suspected credential compromise: `iam.sh --offboard <user>` immediately, then
rotate the password and re-enable.

**Suspected data breach (GDPR Art. 33).** The clock is 72 hours from
awareness to notifying the supervisory authority. In order:

1. Contain - offboard accounts, block the source IP on the host firewall,
   `docker compose stop nginx` if the attack is active.
2. Preserve - copy `data/nextcloud.log` and `data/audit.log` aside before
   they rotate.
3. Assess - what was shared, to whom, and was personal data exposed.
4. Notify - DPO and authority; document every decision with a timestamp.

**Ransomware / corrupted data.** Do not wipe anything. Stop the stack
(`docker compose stop`), snapshot the VM disk for forensics, restore the last
clean backup set on a fresh VM, and only then return to service.

## Where the evidence lives

| Artefact            | Location                              |
|---------------------|---------------------------------------|
| Application log     | `nextcloud-data/nextcloud.log`        |
| Audit log           | `nextcloud-data/audit.log`            |
| nginx access/error  | `docker compose logs nginx`           |
| Backup manifests    | `backups/<stamp>/SHA256SUMS`          |
| CI history          | GitHub Actions runs for this repo     |

## Health checks

```bash
docker compose ps                            # all five containers Up
curl -sk https://localhost/status.php -H 'Host: nextcloud.local'
sudo bash scripts/audit.sh --live            # full control pass
```

If `status.php` stalls, check disk space first (`df -h`) - Nextcloud stops
behaving when the data volume is full; then `docker compose logs app`.
