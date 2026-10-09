# Self-hosting

A collection of Docker Compose services and operating notes for a self-hosted
environment. The configurations support small home devices such as an Orange
Pi Zero as well as ARM64 cloud hosts such as Oracle Cloud Ampere instances.

## Installation order

Install the DNS stack in this order:

1. [Unbound](./unbound/README.md) must be installed, started, and validated
   first. It provides recursive resolution and DNSSEC validation.
2. [Pi-hole](./pihole/README.md) is installed next. It provides filtering and
   forwards DNS exclusively to Unbound through the shared `monitor-net` Docker
   network.

Do not start Pi-hole until Unbound passes its documented UDP, TCP, and DNSSEC
tests. Each service README contains its prerequisites, deployment commands,
security boundaries, and functional tests.

## Deployment targets

### Home network or Orange Pi

Docker automatically selects the image matching the host architecture,
including 32-bit ARM where supported. Give the DNS host a static LAN address or
DHCP reservation, and expose DNS only on the intended LAN address. Pi-hole's
web interface can remain on loopback or be exposed only to a trusted LAN.

### Oracle Cloud Ampere VPS

Ampere hosts use ARM64 images selected automatically by Docker. Prefer access
through a private VPN such as WireGuard, keep administrative interfaces on
loopback or the VPN address, and retain restrictive Oracle Cloud and host
firewall rules. Do not expose a public recursive DNS service.

## Secrets and local configuration

Service-specific `.env` files and generated secrets are intentionally excluded
from Git. Start from each service's checked-in example configuration, generate
credentials once during installation, and keep secure backups outside this
repository.

## TODO

- [ ] Create a full tunnel profile, so that I can update the Wireguard's [README.md](./wireguard/README.md).
- [ ] Add Oracle setup guide
- [ ] Check IPv6 exposure: Your VPS's sshd was listening on both 0.0.0.0:443 and [::]:443. Your IPv4 /32 restrictions do not automatically protect IPv6. Check whether Oracle assigned a public IPv6 address and whether any IPv6 ingress/firewall rules permit port 443.
- [ ] Your persistent firewall's exact contents were never independently verified: We know both WireGuard and SSH survived the reboot. That's the important functional test. However, the complete saved rules.v4 contents were not pasted into the conversation. Keep a secure backup of your actual SSH, WireGuard and firewall configuration files if you want a reproducible disaster-recovery setup.