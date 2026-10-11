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

Clone this repository onto the Pi at `/opt/bakedesk/deploy`, then run:

```bash
cd /opt/bakedesk/deploy
sudo ./setup.sh
```

`setup.sh` checks for Debian/Raspberry Pi OS ARM64, configures the host name,
installs and enables Avahi, installs Docker Engine from Docker’s official
Debian repository, installs host CUPS, prepares `/opt/bakedesk/data`, and
clones BakeDesk into `/opt/bakedesk/app` if that directory does not already
exist. It does not replace an existing application checkout.

Review `/opt/bakedesk/deploy/.env` after setup. Setup creates it from
`.env.example` with random local secrets when it is missing. It is ignored by
Git and must remain private.

Reboot the host after setup.

Start the production stack with:

```bash
sudo /opt/bakedesk/deploy/deploy.sh
```

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
Docker container, `bakedesk-label` is shared explicitly. Queue sharing is
limited by the helper’s CUPS listener and `/printers` ACL to localhost and the
Compose backend subnet; it does not enable unrestricted LAN access or remote
CUPS administration. The helper uses an exact 4×6 media option when the
installed driver exposes one, including `PageSize=w288h432` when provided by
the JD-668BT driver.

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
configuration that it previously created. The Compose backend network uses
the stable private subnet
`172.30.42.0/24`. The optional helper configures CUPS to listen on the Docker
host-gateway address and permits `/printers` access only from localhost and
that backend subnet. On Debian/Raspberry Pi OS with systemd socket activation,
the helper manages
`/etc/systemd/system/cups.socket.d/bakedesk.conf`, retaining the vendor
`/run/cups/cups.sock` while adding only the localhost and Docker host-gateway
TCP listeners. It explicitly accepts the `host.docker.internal` CUPS host name
through `ServerAlias`. The helper verifies the actual TCP listener and checks
the queue endpoint from a running BakeDesk PHP or worker container. CUPS
administration is left under the existing local administrative access rules,
and no LAN-wide CUPS administration is enabled.

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
lpstat -t
docker compose --project-directory /opt/bakedesk/deploy -f /opt/bakedesk/deploy/compose.yaml ps
```

Configure printers later in BakeDesk with IPP addresses such as the printer’s
direct IPP endpoint. Vendor-specific host printer provisioning is optional and
is kept out of `setup.sh` and the BakeDesk application.

Valkey is an in-memory Messenger queue transport. PostgreSQL is the durable
application store, and generated documents are stored in
`/opt/bakedesk/data/documents`. Mercure uses transient hub state in this
configuration, so no Mercure data directory is created.
