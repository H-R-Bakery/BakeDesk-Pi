# BakeDesk-Pi

BakeDesk-Pi is the Raspberry Pi deployment companion for
[BakeDesk](https://github.com/H-R-Bakery/BakeDesk). It provides the ARM64 host
bootstrap, production Docker image, Compose services, Nginx configuration,
host CUPS installation, and operational scripts. The BakeDesk application
remains in its own checkout.

The supported V1 endpoint is:

```text
http://bakedesk.local
```

The Pi host is named `bakedesk`; Avahi publishes that name as `bakedesk.local`.
V1 is HTTP-only and intended for the bakery LAN.

## First installation

On a fresh Pi, clone this repository at `/opt/bakedesk/deploy`, then run:

```bash
sudo mkdir -p /opt/bakedesk
sudo git clone https://github.com/H-R-Bakery/BakeDesk-Pi.git /opt/bakedesk/deploy
cd /opt/bakedesk/deploy
sudo ./setup.sh
```

`setup.sh` checks for Debian/Raspberry Pi OS ARM64, configures the host name,
installs and enables Avahi, installs Docker Engine from Docker’s official
Debian repository, installs and starts ZeroTier on the host, installs host
CUPS, prepares `/opt/bakedesk/data`, and clones BakeDesk into
`/opt/bakedesk/app` if that directory does not already exist. It does not
replace an existing application checkout and does not join a ZeroTier network.

Review `/opt/bakedesk/deploy/.env` after setup. Setup creates it from
`.env.example` with random local secrets when it is missing. It is ignored by
Git and must remain private. Set the production ZeroTier network manually:

```env
ZEROTIER_NETWORK_ID=<network-id>
```

`deploy.sh` reads and validates that value, joins the configured network when
necessary, and verifies membership before building or restarting BakeDesk.
Run it with:

```bash
sudo /opt/bakedesk/deploy/deploy.sh
```

A newly joined private member may require authorization in ZeroTier Central.
The deployment reports that state and continues once the host service is
working and the network membership is present.

Reboot the host after setup.

The deployment builds the PHP image from the sibling application checkout,
starts the stack, and runs pending Doctrine migrations. The PHP build context
is `/opt/bakedesk`; `deploy/docker/php/Dockerfile` copies only the application
checkout needed for the image. Persistent data is bind-mounted from
`/opt/bakedesk/data`.

## Optional JADENS label printer setup

The generic deployment remains printer-vendor-neutral. The optional
`setup-jadens.sh` helper provisions a locally connected JADENS JD-668BT printer
through host CUPS:

```bash
sudo ./setup-jadens.sh
```

Run this after `deploy.sh` has started the Compose stack; the helper requires a
running PHP or worker container to verify HTTP access to the CUPS queue.

It installs and verifies JADENS Linux Driver `3.3.6.506`, discovers the
JADENS model and device URI from CUPS, and creates or updates the predictable
queue `bakedesk-label`. The original vendor download URL for this exact
driver is:

```text
https://cdn.shopify.com/s/files/1/0574/8742/5675/files/jadens-printer-driver_linux_3.3.6.506.deb?v=1779691150
```

The Debian package metadata contains no license, copyright notice, or explicit
redistribution permission.

On Debian 13/Raspberry Pi OS trixie, the bundled JADENS filter also requires
the distribution package `libcupsimage2t64`. The helper installs this runtime
dependency and runs `ldd` on the installed filter, failing with the unresolved
libraries if any are still missing.

The resulting URI to enter in BakeDesk is:

```text
ipp://host.docker.internal:631/printers/bakedesk-label
```

Enter it in `BakeDesk → Admin → Printers`. Because BakeDesk connects from a
Docker container, the helper sets `printer-is-shared=true` directly on
`bakedesk-label`. Queue sharing is limited by the helper’s CUPS listener and
`/printers` ACL to localhost and the Compose backend subnet; it does not enable
unrestricted LAN access or remote CUPS administration. The helper uses an
exact 4×6 media option when the installed driver exposes one, including
`PageSize=w288h432` when provided by the JD-668BT driver.

The default run does not submit a physical print job. An explicit diagnostic
job can be submitted with:

```bash
sudo ./setup-jadens.sh --test
```

Inspect the queue with:

```bash
lpstat -t
lpoptions -p bakedesk-label -l
```

To remove and recreate the queue while troubleshooting:

```bash
sudo lpadmin -x bakedesk-label
sudo ./setup-jadens.sh
```

The helper is intended to be rerunnable. It updates the existing queue and
reapplies its marked CUPS access block without rejecting the listener and ACL
configuration that it previously created. If an earlier failed helper run
left the known broad `Port 631` line behind, the helper removes it only when
the legacy managed-state marker is absent and the pre-change backup proves
that it was the sole non-managed configuration difference. Other broad or
administrator-defined listeners still stop setup for review. The Compose
backend network uses the stable private subnet
`172.30.42.0/24`. The optional helper configures CUPS to listen on the Docker
host-gateway address and permits `/printers` access only from localhost and
that backend subnet. On Debian/Raspberry Pi OS with systemd socket activation,
the helper manages
`/etc/systemd/system/cups.socket.d/bakedesk.conf`, retaining the vendor
`/run/cups/cups.sock` while adding only the localhost and Docker host-gateway
TCP listeners. It explicitly accepts the `host.docker.internal` CUPS host name
through `ServerAlias`. The helper verifies the actual TCP listeners, the
inherited `/run/cups/cups.sock`, and the queue endpoint from a running BakeDesk
PHP or worker container. It also sends a non-printing IPP `Validate-Job`
request through that container to verify remote print authorization without
creating a job. CUPS administration is left under the existing local
administrative access rules, and no LAN-wide CUPS administration is enabled.

After setup, the final end-to-end check is `BakeDesk → Admin → Printers → Test
Label`. This exercises the production path through the PHP/worker container,
host CUPS, the JADENS driver, and the USB printer.

## Updates and checks

```bash
sudo /opt/bakedesk/deploy/update.sh
/opt/bakedesk/deploy/scripts/status.sh
```

The update helper fast-forwards the application checkout when it has a normal
upstream branch, rebuilds the image, restarts changed services, and runs
migrations. It refuses to overwrite local Git changes.

Useful host checks include:

```bash
systemctl status avahi-daemon
systemctl status docker
systemctl status cups
systemctl status zerotier-one
sudo zerotier-cli info
sudo zerotier-cli listnetworks
lpstat -t
docker compose --project-directory /opt/bakedesk/deploy -f /opt/bakedesk/deploy/compose.yaml ps
```

To remove an obsolete ZeroTier membership explicitly, use:

```bash
sudo zerotier-cli leave <network-id>
```

Deployment leaves existing ZeroTier networks alone, including networks that
were joined before or after the value in `.env` changes. `update.sh` calls
`deploy.sh`, so application updates repeat the same membership verification
without duplicating the ZeroTier logic.

Configure printers later in BakeDesk with IPP addresses such as the printer’s
direct IPP endpoint. Vendor-specific host printer provisioning is optional and
is kept out of `setup.sh` and the BakeDesk application.

Valkey is an in-memory Messenger queue transport. PostgreSQL is the durable
application store, and generated documents are stored in
`/opt/bakedesk/data/documents`. Mercure uses transient hub state in this
configuration, so no Mercure data directory is created.

## Backup configuration

Backups are owned by BakeDesk-Pi and contain a PostgreSQL logical dump, the
documents directory, the private deployment `.env`, and non-secret manifest
and SHA-256 checksum metadata. They do not contain raw PostgreSQL data files,
Valkey or Mercure state, Docker images, either Git checkout, or `public_assets`.
The archive payload layout is:

```text
manifest.txt
checksums.sha256
database.dump
deploy.env
documents/
```

The committed defaults are:

```env
BAKEDESK_BACKUP_ENABLED=1
BAKEDESK_BACKUP_SCHEDULE="Sun *-*-* 02:00:00 America/Indiana/Indianapolis"
BAKEDESK_BACKUP_RETENTION_DAYS=90
BAKEDESK_BACKUP_DIRECTORY=/opt/bakedesk/backups
```

`BAKEDESK_BACKUP_SCHEDULE` is a native systemd `OnCalendar=` expression. Test
an expression before changing `.env` with:

```bash
systemd-analyze calendar 'Sun *-*-* 02:00:00 America/Indiana/Indianapolis'
systemd-analyze calendar '*-*-* 02:00:00 America/Indiana/Indianapolis'
```

Examples include:

```text
daily:             *-*-* 02:00:00 America/Indiana/Indianapolis
weekly Sunday:     Sun *-*-* 02:00:00 America/Indiana/Indianapolis
Monday and Thursday: Mon,Thu *-*-* 02:00:00 America/Indiana/Indianapolis
```

The backup directory is created root-owned with mode `0700`; archive files
are mode `0600`. A same-SD-card backup protects against accidental deletion or
operator mistakes but does not protect against SD-card failure. Set
`BAKEDESK_BACKUP_DIRECTORY` to an appropriately mounted external or
network-backed filesystem when that protection is required. This project does
not configure NFS, SMB, or cloud storage.

## Cleanup configuration

BakeDesk owns reference-aware cleanup of application data. BakeDesk-Pi only
schedules and invokes the command:

```env
BAKEDESK_CLEANUP_ENABLED=1
BAKEDESK_CLEANUP_SCHEDULE="*-*-* 03:00:00 America/Indiana/Indianapolis"
BAKEDESK_PRINT_JOB_RETENTION_DAYS=90
BAKEDESK_ORDER_RETENTION_DAYS=730
```

Documents follow the application’s reference-aware cleanup rules rather than
an independent host age setting.

## Manual backup and restore

Run a backup manually with:

```bash
sudo ./backup.sh
```

Archives live in `BAKEDESK_BACKUP_DIRECTORY` and use names such as
`bakedesk-2026-10-11_020000.tar.gz`. After a successful backup, only completed
archives matching this tool’s naming format and older than
`BAKEDESK_BACKUP_RETENTION_DAYS` are removed. Other files in that directory
are left alone.

Restore is always manual and replaces the current BakeDesk database,
documents, and deployment configuration. It validates the archive structure,
manifest, checksums, and database credentials before changing production data,
then requires typing `RESTORE` interactively:

```bash
sudo ./restore.sh /path/to/bakedesk-2026-10-11_020000.tar.gz
```

For a deliberate non-interactive restore, use `--yes`; this is destructive:

```bash
sudo ./restore.sh --yes /path/to/bakedesk-2026-10-11_020000.tar.gz
```

The restore stops Nginx, PHP, and the print worker, keeps PostgreSQL running,
resets the configured PostgreSQL role password to the restored `.env`, drops
and recreates the configured database, restores `database.dump` with
`pg_restore`, swaps the documents tree, and runs `deploy.sh`. That deployment
applies current Doctrine migrations, reconciles timers, starts the services,
and reports Compose and PostgreSQL health. The old `.env` and documents tree
are held temporarily while the operation completes. Valkey, Mercure, and CUPS
host state are not restored from the archive; the Pi’s ZeroTier identity is
also host state and remains local to that Pi.

## Timer operations

`deploy.sh` validates both calendar expressions with `systemd-analyze calendar`
before writing managed units under `/etc/systemd/system`. It then runs
`systemctl daemon-reload` and enables or disables the timers according to the
two `BAKEDESK_*_ENABLED` flags. Both timers use `Persistent=true`; an enabled
timer can run after the Pi returns from downtime. Editing `.env` followed by
`sudo ./deploy.sh` applies schedule changes without rerunning `setup.sh`.

Useful commands are:

```bash
systemctl status bakedesk-backup.timer
systemctl status bakedesk-cleanup.timer
systemctl list-timers 'bakedesk-*'
sudo systemctl start bakedesk-backup.service
sudo systemctl start bakedesk-cleanup.service
journalctl -u bakedesk-backup.service
journalctl -u bakedesk-cleanup.service
```

Preview application cleanup without changing data:

```bash
sudo ./cleanup.sh --dry-run
```

This calls the deployed container’s `php bin/console bakedesk:cleanup
--dry-run`; cleanup rules are not duplicated in shell or SQL.

## Disaster recovery

On a fresh Pi:

1. Install and clone BakeDesk-Pi under `/opt/bakedesk/deploy`.
2. Run `sudo ./setup.sh`.
3. Make the backup archive available to the Pi.
4. Run `sudo ./restore.sh /path/to/archive.tar.gz` and confirm with `RESTORE`,
   or use the deliberate `--yes` option for a non-interactive operation.
5. The restore flow invokes `deploy.sh`, which builds the current application,
   runs current migrations, reconciles timers, and verifies the services.
6. Authorize or check ZeroTier membership as needed.
7. Re-run the optional `setup-jadens.sh` host printer setup if that printer is
   used by this installation.

The backup contains the deployment `.env`, so it includes BakeDesk secrets and
the configured ZeroTier network ID. It does not contain the Pi’s ZeroTier
identity, CUPS or JADENS host configuration, Docker images, or either Git
checkout. Do not place backup archives in either repository.
