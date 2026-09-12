# Unbound

This directory runs an Unbound recursive DNS resolver in Docker Compose.

The current deployment:

- uses `alpinelinux/unbound:latest`;
- listens on TCP and UDP port `5335` inside the container;
- publishes TCP and UDP port `5335` on every host interface;
- mounts `./unbound.conf` at `/etc/unbound/unbound.conf`;
- connects the container to the pre-existing external Docker network
  `monitor-net`; and
- allows DNS clients whose source address is within `172.16.0.0/12` or
  `127.0.0.0/8`.

The configuration does not currently allow clients from common
`192.168.0.0/16` or `10.0.0.0/8` LANs, even though the published port can be
reached through the host's network interfaces.

## Prerequisites

- Docker Engine with the Docker Compose plugin
- A pre-existing `monitor-net` Docker network
- `dig` on the host for the examples below

Create the external network once, if it does not already exist:

```bash
docker network inspect monitor-net >/dev/null 2>&1 || \
  docker network create monitor-net
```

## Validate the configuration

Validate the mounted Unbound configuration before starting the long-running
service:

```bash
docker compose run --rm --entrypoint unbound-checkconf \
  unbound /etc/unbound/unbound.conf
```

This checks syntax only. It does not prove that recursion, DNSSEC validation,
network access, or TCP fallback works.

## Start the service

Run these commands from this directory:

```bash
docker compose up -d
docker compose ps
docker compose logs --tail=100 unbound
```

After the service is running, the configuration can also be checked with:

```bash
docker compose exec unbound unbound-checkconf
```

## Addressing the resolver

### From the Docker host

The Compose file publishes Unbound on host port `5335`, so use:

```text
127.0.0.1:5335
```

There is no need to discover a Docker bridge address.

### From another container on `monitor-net`

Use Docker's stable service name and the container port:

```text
unbound:5335
```

Do not store the container's IP address. Docker may assign a different address
whenever the container is recreated. This access also assumes that
`monitor-net` uses an address inside the allowed `172.16.0.0/12` range.

#### Inspect the container's Docker IP

The current container IP can still be useful for temporary diagnostics, such
as checking reachability or confirming which subnet Docker assigned to
`monitor-net`:

```bash
docker inspect -f \
  '{{with index .NetworkSettings.Networks "monitor-net"}}{{.IPAddress}}{{end}}' \
  unbound
```

To display the address assigned on every network attached to the container:

```bash
docker inspect -f \
  '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}: {{$network.IPAddress}}{{println}}{{end}}' \
  unbound
```

This address can be used for short-lived tests from a host or container that
has a route to `monitor-net`. It should not be saved in Pi-hole, application
configuration, or scripts: use `unbound:5335` between containers on
`monitor-net`, because that name remains stable when the Unbound container is
recreated with a different IP.

### From a LAN client

Direct LAN use is not enabled by the current Unbound ACL. In particular, a
client whose source address is `192.168.x.x` or `10.x.x.x` will normally be
refused.

Also note that Unbound is published on port `5335`, not the standard DNS port
`53`. A command such as the following tests whatever is listening on port 53
(for example Pi-hole), not this Unbound service:

```powershell
nslookup example.com 192.168.15.182
```

Do not enable direct LAN access merely for testing. First choose the intended
network boundary and then update the published host address, firewall, and
Unbound ACL together.

## Functional tests

Run these from the Docker host.

Test a normal UDP query:

```bash
dig @127.0.0.1 -p 5335 example.com A
```

Test TCP explicitly:

```bash
dig @127.0.0.1 -p 5335 example.com A +tcp
```

A successful basic query normally has `status: NOERROR`, but that status alone
does not demonstrate DNSSEC validation.

Once a DNSSEC trust anchor has been configured, test a valid signed domain and
a deliberately broken signed domain:

```bash
dig @127.0.0.1 -p 5335 cloudflare.com A +dnssec
dig @127.0.0.1 -p 5335 dnssec-failed.org A +dnssec
```

The valid response should contain the `ad` flag. The deliberately broken domain
should return `SERVFAIL`. These expectations do not apply reliably until the
trust-anchor problem below has been fixed.

Avoid using `ANY` queries as a health check. Their behavior is deliberately
restricted by many DNS implementations and they do not provide a stronger
resolver test than a normal `A`, `AAAA`, or `SOA` query.

## Known problems and risks

Severity meanings:

- **Critical**: likely compromise, data loss, or complete service failure;
- **High**: defeats an important security or reliability property;
- **Medium**: meaningful operational, security, or maintenance risk; and
- **Low**: hardening, clarity, or maintainability issue with limited immediate
  impact.

### High: no DNSSEC trust anchor is configured

`unbound.conf` enables `harden-dnssec-stripped`, but it does not declare a
`trust-anchor-file`, `auto-trust-anchor-file`, or inline trust anchor. The
Compose bind mount replaces the image's complete `/etc/unbound/unbound.conf`,
so packaged configuration cannot be assumed to remain active.

`harden-dnssec-stripped` is not a substitute for a trust anchor. Until an anchor
is configured and the valid/broken-domain tests above pass, this service must
not be described as a DNSSEC-validating resolver.

Possible fixes are to reference the trust-anchor file supplied by the pinned
image, after verifying its path, or to initialize and persist a writable
`auto-trust-anchor-file` with `unbound-anchor`.

### High: the network exposure and access policy do not match

The short Compose port mappings (`5335:5335`) publish DNS on all host
interfaces, while the Unbound ACL allows only loopback and the broad Docker
range `172.16.0.0/12`. This creates two problems:

- the host exposes a DNS port on interfaces where clients will usually be
  refused; and
- the intended consumers and trust boundary are not explicit.

Choose and document one model: host/Pi-hole-only access bound to
`127.0.0.1:5335`, container-only access through `monitor-net`, or deliberate
LAN access bound to a specific LAN address and protected by an exact ACL and
firewall policy.

### High: `edns-buffer-size: 1472` is fragmentation-prone

An EDNS payload size of 1472 assumes a clean 1500-byte IPv4 path. It is too
large for many tunneled, PPPoE, VPN, and IPv6 paths and can cause intermittent
failures, especially for larger DNSSEC responses. The modern conservative
value is `1232`.

### Medium: IPv6 is enabled and preferred without a matching listener policy

The configuration sets `do-ip6: yes` and `prefer-ip6: yes`, although its own
comment says IPv6 should only be enabled when native connectivity exists. It
only declares `interface: 0.0.0.0`; there is no IPv6 listening interface or
IPv6 client ACL.

If the host does not have verified native IPv6 connectivity, preferring IPv6
can introduce delays or failures. If IPv6 clients should be served, the
listener, published ports, and ACLs all need an explicit IPv6 design.

### Medium: the image is not reproducibly pinned

`alpinelinux/unbound:latest` can resolve to a different image on a future pull.
That can change the Alpine or Unbound version and its packaged paths or defaults
without any change in this repository. Pin a reviewed version or digest and use
a controlled dependency-update process.

### Medium: there is no DNS health check

`restart: unless-stopped` only helps when the process exits. It cannot detect a
running Unbound process that is unable to answer or recurse. Add a health check
that performs an actual DNS query, or configure `unbound-control` and test the
daemon through it. A syntax-only health check is insufficient.

### Medium: the Docker ACL is broad and depends on an implicit subnet

Allowing all of `172.16.0.0/12` is broader than allowing only `monitor-net`, yet
the Compose file does not define or verify the external network's subnet. If
Docker creates `monitor-net` in another private range, legitimate container
queries will fail. Define a dedicated network with a known subnet and allow
that exact subnet.

### Low: the configuration mount is writable

The container only needs to read `unbound.conf`, but the bind mount is not
marked read-only. Add `:ro` after confirming that the image does not try to
modify this file.

### Low: two IPv4-mapped IPv6 comments are reversed

Near the end of `unbound.conf`, `::ffff:c0a8:0/112` is labeled as
`169.254.0.0/16`, but `c0a8` represents `192.168`. Conversely,
`::ffff:a9fe:0/112` represents `169.254`, not `192.168`. Both ranges are still
listed, so the immediate behavior is not lost, but the comments are misleading.

### Low: `monitor-net` creates unnecessary deployment coupling

Compose cannot start this service until somebody creates the external network.
The name also suggests monitoring rather than DNS infrastructure. A dedicated
DNS network, or a Compose-managed network when cross-project access is not
required, would make ownership and purpose clearer.
