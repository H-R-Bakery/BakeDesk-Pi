# BakeDesk-Pi deployment rules

BakeDesk-Pi is the Raspberry Pi deployment and runtime infrastructure for the
separate [BakeDesk application](https://github.com/H-R-Bakery/BakeDesk). It
owns host bootstrap, Docker Compose orchestration, Nginx, the production PHP
image, CUPS installation, persistent runtime directories, and deployment
helpers. BakeDesk owns the Symfony application, business rules, migrations,
labels, reports, and application tests.

## Target host

- The supported target is a modern 64-bit Raspberry Pi OS Lite or Debian
  ARM64 host.
- The host name is `bakedesk`.
- Avahi on the host owns `bakedesk.local`; Avahi must not run in Docker.
- V1 is HTTP-only and LAN-only. Nginx publishes the application on host port
  80 at `http://bakedesk.local`.
- CUPS runs on the host. BakeDesk uses configured IPP addresses for printers;
  this repository does not assume a printer vendor, model, USB ID, IP address,
  or queue name.

## Compose architecture

Nginx, PHP-FPM, the Symfony Messenger print worker, PostgreSQL, Valkey,
Mercure, and Gotenberg run as separate Docker Compose services. PHP and the
worker use the same production BakeDesk image and differ by command. CUPS is
the only printing infrastructure installed directly on the host.

PostgreSQL, Valkey, Gotenberg, and the internal PHP-FPM port are private
Compose services and must not be exposed to the LAN unnecessarily. The
application containers must not use Docker `privileged` mode or host network
mode. Nginx is the only LAN-facing application service.

Valkey is a Messenger queue transport, not the source of truth. It is
configured without an extra persistence volume. BakeDesk’s durable application
state is in PostgreSQL and documents are in the host documents directory.
Mercure is configured for transient real-time updates and has no persistent
volume under this configuration.

## Host layout

The expected layout is:

```text
/opt/bakedesk/
├── app/       # checkout of H-R-Bakery/BakeDesk
├── deploy/    # checkout of H-R-Bakery/BakeDesk-Pi
└── data/
    ├── documents/
    └── postgres/
```

The PHP image build context is `/opt/bakedesk`. The Dockerfile is owned by
this repository at `deploy/docker/php/Dockerfile`, while application files are
copied from the sibling `app/` checkout during the build. The application is
never copied permanently into this repository.

Persistent data stays outside both Git checkouts. Directories are created with
restricted ownership and permissions; they must not be made world-writable.

## Operating rules

- Keep the BakeDesk application portable. Do not add Pi host or Docker
  infrastructure to the BakeDesk repository to solve a deployment concern.
- Keep setup, deployment, and update operations safe and idempotent where
  practical. Never use destructive Git resets or overwrite an existing app
  checkout.
- Use production Symfony settings in PHP and worker containers. Do not install
  Xdebug or development Composer dependencies in the production image.
- Do not add Kubernetes, Swarm, Traefik, Apache, Redis, RabbitMQ, another
  reverse proxy, backup/restore tooling, reboot controls, or the future
  `/menu/{id}` feature here.
- Do not add vendor-specific printer configuration. Configure printers later
  through BakeDesk using IPP. Useful host checks are `systemctl status cups`
  and `lpstat -t`.
- Do not broaden CUPS listening or firewall access unless a deliberate future
  CUPS queue integration requires it.
- The deployment environment file contains secrets and is ignored by Git. Keep
  it readable only by the deployment operator and the root-owned deployment
  process as appropriate.
