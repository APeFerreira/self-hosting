# Pi-hole

This directory runs Pi-hole v6 in Docker Compose with Unbound as its only
upstream recursive resolver. The deployment is architecture-independent and is
intended for both home devices, including an Orange Pi, and ARM64 cloud hosts,
including Oracle Cloud Ampere instances.

## Deployment model

- Docker selects the native image automatically: `linux/arm/v7` on a 32-bit
  Orange Pi installation, `linux/arm64` on Oracle Ampere, or `linux/amd64` on
  an x86-64 host.
- Pi-hole uses bridge networking and joins the external `monitor-net` network
  created for Unbound.
- Pi-hole forwards DNS exclusively to `unbound#5335` by Docker service name.
- DNS and the web interfaces bind to IPv4 loopback by default. A deployment
  must explicitly select a LAN or VPN address to make them remotely reachable.
- Pi-hole data is stored in the Compose-managed `pihole-data` volume.
- The web password is read from a Docker secret and is not committed to Git or
  exposed as a Compose environment variable.

Unbound must be installed, running, and validated before Pi-hole. Follow the
[Unbound instructions](../unbound/README.md) first.

## Prerequisites

- Docker Engine with the Docker Compose plugin
- A working Unbound deployment from this repository
- The external Docker network `monitor-net`
- A static host address, or a stable DHCP reservation, for LAN deployments
- `dig` on the host for the tests below

Confirm that Unbound and its network exist:

```bash
docker compose --project-directory ../unbound ps
docker network inspect monitor-net >/dev/null
```

## Configure the web password

Generate the password once during installation. Do not generate a new password
on every container start, because doing so would unexpectedly change the login
whenever the container is recreated.

```bash
mkdir -p secrets
openssl rand -base64 32 > secrets/web_password
chmod 600 secrets/web_password
```

The `secrets/web_password` file is ignored by Git. Back it up in a secure
password manager. To rotate the password, replace the file and recreate the
container with `docker compose up -d --force-recreate`.

## Select reachable addresses with `.env`

### What `.env` does

The `.env` file is a local settings file read automatically by Docker Compose
when commands are run from this directory. You do not run it, source it, or
copy it into the container. Compose substitutes its values into the `${...}`
expressions in `docker-compose.yml` before creating the container.

Create your local copy with:

```bash
cp .env.example .env
```

The copied `.env` is ignored by Git. To see exactly what Compose will use after
substitution, run:

```bash
docker compose config
```

The variables have these meanings:

- `TZ` controls timestamps and scheduled tasks inside Pi-hole. `Etc/UTC` is a
  sensible VPS default; `America/Sao_Paulo` is an example local timezone.
- `PIHOLE_DNS_BIND_IP` is an IP address belonging to the VPS itself. Docker
  publishes TCP and UDP port 53 only on this address. It is not a container IP.
- `PIHOLE_WEB_BIND_IP` selects where the dashboard is published. Keeping it at
  `127.0.0.1` means the dashboard is reachable only from the VPS itself or
  through an SSH tunnel.
- `PIHOLE_WEB_HTTP_PORT` and `PIHOLE_WEB_HTTPS_PORT` are ports on the VPS. They
  map to Pi-hole's internal HTTP and HTTPS listeners.

Never put an address in the file merely because it appears in the Oracle Cloud
console. An OCI public IPv4 address is commonly implemented through NAT and may
not be assigned to an interface inside the VPS. Docker can bind only addresses
shown locally by:

```bash
ip -brief -4 address
```

Do not use `0.0.0.0` for this deployment. It would publish the service on every
IPv4 interface and make a later firewall or OCI rule mistake much more serious.

### Case 1: current SSH-only VPS, before WireGuard

While only SSH is open, keep all Pi-hole ports on loopback. Use this `.env`:

```dotenv
TZ=Etc/UTC
PIHOLE_DNS_BIND_IP=127.0.0.1
PIHOLE_WEB_BIND_IP=127.0.0.1
PIHOLE_WEB_HTTP_PORT=8080
PIHOLE_WEB_HTTPS_PORT=8443
```

This lets you install and test Pi-hole on the VPS without making DNS or the
dashboard reachable from other devices. Test DNS directly on the VPS with
`dig @127.0.0.1 example.com A`.

To open the dashboard from your computer, create an SSH tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 user@VPS_PUBLIC_IP
```

Keep that SSH session open, then browse to
`http://127.0.0.1:8080/admin/` on your computer. Port 8080 does not need to be
opened in OCI because it travels inside the existing SSH connection.

At this stage, other devices cannot use Pi-hole. That is intentional; they do
not yet have a private path to the VPS.

### Case 2: WireGuard is installed

Assume the WireGuard interface is named `wg0`, its VPS address is
`10.66.66.1/24`, and its public UDP listening port is `51820`. These are
examples; use the values from your WireGuard configuration.

Bring up WireGuard and confirm its local address before starting Pi-hole:

```bash
sudo wg show
ip -4 address show dev wg0
```

If the output shows `10.66.66.1/24`, use:

```dotenv
TZ=Etc/UTC
PIHOLE_DNS_BIND_IP=10.66.66.1
PIHOLE_WEB_BIND_IP=127.0.0.1
PIHOLE_WEB_HTTP_PORT=8080
PIHOLE_WEB_HTTPS_PORT=8443
```

This is the recommended layout: WireGuard clients can reach DNS at
`10.66.66.1:53`, while the dashboard remains accessible only through the SSH
tunnel described above. If you also want the dashboard available directly over
WireGuard, change only this line:

```dotenv
PIHOLE_WEB_BIND_IP=10.66.66.1
```

You could then browse to `http://10.66.66.1:8080/admin/` while connected to the
VPN. The password remains required in either layout.

Configure each WireGuard client to use the VPS WireGuard address as DNS:

```ini
[Interface]
DNS = 10.66.66.1
```

For a full-tunnel client, `AllowedIPs = 0.0.0.0/0` already routes that DNS
address through WireGuard. For a split-tunnel client, its `AllowedIPs` must
include either the WireGuard subnet, for example `10.66.66.0/24`, or at least
the DNS server address `10.66.66.1/32`. Otherwise the client will try to reach
the DNS address outside the tunnel.

The only new public OCI ingress rule needed for this design is the chosen
WireGuard UDP port, such as UDP 51820. Do not open public ingress for TCP/UDP
53 or web ports 8080 and 8443.

Because Docker cannot bind to `10.66.66.1` before `wg0` exists, WireGuard must
be up before Pi-hole is created or restarted. If startup fails with `cannot
assign requested address`, start `wg0` and run `docker compose up -d` again.

### Home or Orange Pi alternative

On a home LAN without WireGuard, set `PIHOLE_DNS_BIND_IP` to the host's static
LAN address or DHCP reservation, such as `192.168.1.10`. The dashboard may stay
on `127.0.0.1` or use the same trusted LAN address. Do not hard-code an
interface name such as `eth0`; this bridge-mode deployment needs an IP address,
and interface names vary between systems.

## Start Pi-hole

### Existing installations

The previous Compose file used the host path `~/projects/pihole/etc-pihole`.
This version uses the portable `pihole-data` named volume and does not delete
that old directory, but it also does not import it automatically. Export a
Pi-hole Teleporter backup from the existing instance before switching, then
restore it through the new web interface. For a new installation, no migration
is needed.

From this directory:

```bash
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 pihole
```

Wait until `docker compose ps` reports the container as healthy.

## Test DNS and Unbound integration

From the Docker host, test Pi-hole through the configured bind address. With
the default loopback setting:

```bash
dig @127.0.0.1 example.com A
dig @127.0.0.1 pi.hole A
```

Confirm the configured upstream from inside the container:

```bash
docker compose exec pihole pihole-FTL --config dns.upstreams
```

The output should contain `unbound#5335`. Also inspect both services while
performing a query:

```bash
docker compose logs --tail=100 pihole
docker compose --project-directory ../unbound logs --tail=100 unbound
```

Avoid `ANY` queries as health checks. A normal `A`, `AAAA`, or `SOA` query is a
more predictable functional test.

## Web interface

With the default bindings, use one of:

```text
http://127.0.0.1:8080/admin/
https://127.0.0.1:8443/admin/
```

For remote administration over SSH:

```bash
ssh -L 8080:127.0.0.1:8080 user@server
```

Then open `http://127.0.0.1:8080/admin/` locally. Pi-hole generates a
self-signed certificate for its HTTPS listener, so browsers will not trust it
until the certificate is explicitly accepted or replaced.

## Port 53 conflicts

Check the actual listener before changing host DNS services:

```bash
sudo ss -lntup '( sport = :53 )'
```

On systems using `systemd-resolved`, do not blindly delete `/etc/resolv.conf` or
point it at Pi-hole before Pi-hole is healthy. The correct change depends on
the distribution's resolver configuration. Preserve a working external
resolver during installation and document a rollback before disabling the
stub listener.

Because this deployment binds only the address configured by
`PIHOLE_DNS_BIND_IP`, it can coexist with a resolver bound exclusively to a
different local address. If both services require the same address and port,
resolve that conflict before starting Pi-hole.

## DHCP

This deployment provides DNS only. It deliberately omits `NET_ADMIN` and does
not expose DHCP ports. Running Pi-hole as a DHCP server requires a separate,
home-network-specific design such as host or macvlan networking. DHCP is not
appropriate for the Oracle VPS deployment.

## Updates and backups

The Compose file uses a date-based Pi-hole release instead of `latest` so that
updates are deliberate. Review the Pi-hole release notes, update the tag, pull,
and recreate the service.

Back up the `pihole-data` volume and the password secret before upgrades. Do
not remove the volume with `docker compose down -v` unless permanent deletion
of Pi-hole configuration and history is intended.
