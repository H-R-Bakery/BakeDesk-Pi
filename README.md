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

Start the production stack with:

```bash
sudo /opt/bakedesk/deploy/deploy.sh
```

The deployment builds the PHP image from the sibling application checkout,
starts the stack, and runs pending Doctrine migrations. The PHP build context
is `/opt/bakedesk`; `deploy/docker/php/Dockerfile` copies only the application
checkout needed for the image. Persistent data is bind-mounted from
`/opt/bakedesk/data`.

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
direct IPP endpoint. A future CUPS queue can also be used through IPP, but
making a host CUPS listener reachable from containers requires an intentional
host listener/firewall change and is not enabled by this bootstrap.

Valkey is an in-memory Messenger queue transport. PostgreSQL is the durable
application store, and generated documents are stored in
`/opt/bakedesk/data/documents`. Mercure uses transient hub state in this
configuration, so no Mercure data directory is created.
