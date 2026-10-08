# WireGuard

WireGuard provides the private network used by remote devices to reach Pi-hole
and other services without exposing those services directly to the Internet.
The examples use:

- WireGuard interface: `wg0`
- VPN IPv4 subnet: `10.66.66.0/24`
- VPN server address: `10.66.66.1`
- WireGuard UDP port: `51515`

The installer intentionally fixes the interface and IPv4 network to these
values so server and client addresses cannot collide. IPv6 is not configured.

## Installer status and backup

[`oracle_setup.sh`](./oracle_setup.sh) is the reviewed installer. The legacy
pre-review version is preserved as the non-executable
[`oracle_setup.original.sh`](./oracle_setup.original.sh). The backup contains
private-key generation logic but no generated keys or credentials.

The active installer:

- supports current Ubuntu and Debian hosts;
- defaults to IPv4-only split tunnels;
- uses a fixed `10.66.66.1/24` server address and safely allocates clients;
- shows a dry-run summary and requires typed confirmation before mutations;
- writes the initial server configuration through an atomic staging directory;
- installs idempotent iptables rules and removes duplicate legacy copies;
- applies peer changes live with `wg syncconf`, without restarting `wg0`;
- creates named clients and supports listing and revocation;
- backs up the server configuration before every peer change; and
- rolls back generated configuration when installation or peer application
  fails.

The installer deliberately trusts authenticated WireGuard peers to access host
services through `wg0`. It enables IPv4 forwarding and NAT so full-tunnel
clients can reach the Internet. It refuses to run when UFW or firewalld is
active because mixing persistent firewall managers would make rule ownership
ambiguous.

Treat the script as a privileged installer: it installs packages, generates
private keys, writes under `/etc/wireguard`, enables IPv4 forwarding, modifies
iptables, and enables a system service. It is for a fresh installation and
refuses to overwrite a non-empty `/etc/wireguard` directory.

## Recommended installation path

### Oracle Cloud VPS

Copy the installer to root's home directory and inspect a dry run:

```bash
sudo -i
cp /path/to/self-hosting/wireguard/oracle_setup.sh /root/
chmod 700 /root/oracle_setup.sh
./oracle_setup.sh install --dry-run
```

The dry run asks for three values:

1. **Public endpoint:** the Internet-facing address that phones and laptops use
   to contact WireGuard. For an OCI VPS, enter the **public IPv4 address** shown
   on the instance page in Oracle Cloud, for example `203.0.113.10`. You may
   instead enter a DNS hostname such as `vpn.example.com`, but that name must
   resolve to the OCI public address. This public address often does not appear
   in `ip addr` inside the VPS because OCI maps it to the instance through NAT.
2. **Public network interface:** the Linux interface inside the VPS that carries
   its default IPv4 route, commonly a name such as `enp0s3`. This is an
   interface name—not an IP address and not the OCI public address. The script
   detects it and presents it as the default. Confirm it with:

   ```bash
   ip -4 route show default
   ```

   In output such as `default via 10.0.0.1 dev enp0s3`, enter `enp0s3`. The
   installer uses this interface for the UDP firewall rule and for NAT when
   full-tunnel clients access the Internet.
3. **WireGuard UDP port:** the public and local UDP listening port, defaulting
   to `51515`. The same destination port must be allowed in the OCI ingress
   rule.

For example, an OCI installation might use:

```text
Public endpoint:          203.0.113.10
Public network interface: enp0s3
WireGuard UDP port:       51515
```

It displays all host changes without installing packages or writing files. If
the summary is correct, install while keeping the existing SSH session open:

```bash
./oracle_setup.sh install
```

Type `INSTALL` only after reviewing the final summary. The script installs the
server but does not create a client automatically.

Create named split- or full-tunnel clients afterward:

```bash
./oracle_setup.sh add-client phone split --dry-run
./oracle_setup.sh add-client phone split
./oracle_setup.sh add-client laptop full
./oracle_setup.sh list-clients
```

Profiles are stored in `/root/wireguard-clients`. Server configuration backups
are stored in `/etc/wireguard/backups`. Revoke a lost or retired profile with:

```bash
./oracle_setup.sh revoke-client phone --dry-run
./oracle_setup.sh revoke-client phone
```

The final command requires typing `REVOKE` and removes both the live peer and
the VPS's local copy of the client profile.

### Orange Pi or another home server

For a home server, follow Pi-hole's
[WireGuard server guide](https://docs.pi-hole.net/guides/vpn/wireguard/server/).
Give the Orange Pi a static LAN address or DHCP reservation before configuring
router port forwarding. The repository installer can also work on a fresh
Ubuntu- or Debian-based Orange Pi, but it uses the same trusted-peer and direct
iptables policy described above; inspect its dry run before choosing it over a
manual setup.

## Opening the WireGuard port

WireGuard needs one inbound **UDP** port: the server's `ListenPort`. With this
repository's default, that is UDP `51515`. It does not require a TCP rule.

Opening the WireGuard port does not mean opening Pi-hole itself. Keep public
TCP/UDP 53 and Pi-hole web ports closed. VPN clients reach those services
through the encrypted WireGuard interface.

### Oracle Cloud VPS

OCI and the operating system are separate firewall layers. The same UDP port
must be allowed through OCI and through any active guest firewall.

#### 1. Add the OCI ingress rule

In the Oracle Cloud console:

1. Open the instance and identify its VNIC and subnet.
2. Open the network security group attached to the VNIC, or the security list
   attached to its subnet.
3. Add a **stateful ingress** rule with:

   | Field | Value |
   | --- | --- |
   | Source type | CIDR |
   | Source CIDR | `0.0.0.0/0`, or a narrower known client range |
   | IP protocol | UDP |
   | Source port | All |
   | Destination port | `51515` |
   | Description | WireGuard |

Mobile clients frequently change public IP addresses, so restricting the
source CIDR may be impractical. The WireGuard cryptographic handshake still
authenticates peers, but exposing only the single required UDP port keeps the
network surface small.

Do not add OCI ingress rules for DNS port 53 or Pi-hole ports 8080/8443. After
WireGuard is connected, those services are reached through `10.66.66.1`.

#### 2. Check the VPS firewall

The repository installer creates an idempotent direct iptables rule whenever
`wg0` starts and removes it when `wg0` stops. Verify the managed rules with:

```bash
sudo iptables -S INPUT
sudo iptables -S FORWARD
sudo iptables -t nat -S POSTROUTING
```

Do not add a duplicate UFW or firewalld rule. The installer refuses to proceed
when either manager is active. If you deliberately choose a manual setup using
UFW instead of this installer, its equivalent port rule is:

```bash
sudo ufw allow 51515/udp comment 'WireGuard'
```

#### 3. Verify the listener and handshake

After starting WireGuard:

```bash
sudo systemctl status wg-quick@wg0
sudo ss -lunp | grep ':51515'
sudo wg show
```

A UDP port scan cannot reliably prove that WireGuard works because WireGuard
does not respond to unauthenticated packets. The meaningful test is connecting
a configured client from an external network and checking that `wg show`
reports a recent handshake and increasing transfer counters.

### Orange Pi behind a home router

The Orange Pi normally has a private address and the router owns the public
address. Opening the host firewall alone is therefore insufficient; the router
must forward the UDP port to the Pi.

Assuming the Orange Pi is `192.168.1.10`:

1. Give `192.168.1.10` a DHCP reservation or configure a static address.
2. In the router's port-forwarding/NAT page, create this rule:

   | Field | Value |
   | --- | --- |
   | Protocol | UDP |
   | External/WAN port | `51515` |
   | Internal address | `192.168.1.10` |
   | Internal port | `51515` |

3. For a manual setup managed by UFW, allow the same host port:

   ```bash
   sudo ufw allow 51515/udp comment 'WireGuard'
   ```

   Do not add this UFW rule when using `oracle_setup.sh`; that installer
   requires UFW to be inactive and owns its direct iptables rules.

4. Put the router's public IP address or a dynamic-DNS hostname in each
   client's `Endpoint`, followed by `:51515`.

Do not use the router's DMZ-host feature and do not forward TCP 51515. If the
home has two routers performing NAT, the port must be forwarded through both,
or one device must be placed in bridge/passthrough mode.

Port forwarding will not work through carrier-grade NAT (CGNAT) unless the ISP
provides a public address or inbound-port service. A practical alternative is
to use the Oracle VPS as the publicly reachable WireGuard hub and let the
Orange Pi connect outward to it.

Some routers do not support NAT loopback. Test a home-hosted VPN from mobile
data or another external network, not from the same Wi-Fi network.

## Connect Pi-hole after WireGuard starts

Pi-hole should publish DNS on the WireGuard server address, not on the VPS
public address. Once `wg0` owns `10.66.66.1`, set this in `pihole/.env`:

```dotenv
PIHOLE_DNS_BIND_IP=10.66.66.1
PIHOLE_WEB_BIND_IP=127.0.0.1
```

Then recreate Pi-hole:

```bash
cd ../pihole
docker compose up -d
```

WireGuard must be up before Docker binds Pi-hole to `10.66.66.1`. Configure
clients to use `DNS = 10.66.66.1`; the Pi-hole README contains the complete
split- and full-tunnel examples.

## Split tunnel versus full tunnel

A split-tunnel client routes only the private VPN networks:

```ini
AllowedIPs = 10.66.66.0/24
```

This is sufficient for Pi-hole and other services addressed through the VPN.
The client's ordinary Internet traffic continues to use its local connection.

A full-tunnel IPv4 client routes all IPv4 traffic through the VPS or home
server:

```ini
AllowedIPs = 0.0.0.0/0
```

Full tunnel also requires IP forwarding, forwarding firewall rules, and NAT on
the server; the installer configures those IPv4 requirements. It does not
configure IPv6. Do not add `::/0` to these generated profiles. A client with
native IPv6 can still send IPv6 traffic outside an IPv4-only full tunnel, so
disable IPv6 on that client if the policy requires all traffic to traverse the
VPN.

## Add friendly client names

Add client addresses to the server's `/etc/hosts` if Pi-hole should display
names instead of VPN addresses:

```text
10.66.66.2 linux-laptop
10.66.66.3 android-phone
10.66.66.4 tablet
```

## Protect client profiles

Every generated client configuration and QR code contains a private key. Treat
it like a password:

- transfer it only through a trusted channel;
- store it with restrictive permissions;
- never commit it to this repository; and
- remove the corresponding peer from the server if a device or profile is
  lost.
