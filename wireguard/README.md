# WireGuard

WireGuard provides the private network used by remote devices to reach Pi-hole
and other services without exposing those services directly to the Internet.
The examples use:

- WireGuard interface: `wg0`
- VPN IPv4 subnet: `10.66.66.0/24`
- VPN server address: `10.66.66.1`
- VPN IPv6 subnet: `fd42:42:42::/64`
- WireGuard UDP port: `51515`

Replace these examples consistently if different values are selected during
installation.

## Installer status and backup

[`oracle_setup.sh`](./oracle_setup.sh) is the current legacy installer. The
pre-review version has also been preserved as the non-executable
[`oracle_setup.original.sh`](./oracle_setup.original.sh). The backup contains
private-key generation logic but no generated keys or credentials.

The `update-wireguard` branch contains a major rewrite of the installer. It
passes Bash syntax validation and improves several areas:

- strict error handling and root-only file permissions;
- modern Ubuntu and Debian package installation;
- validation of user-provided settings;
- `/32` and `/128` client interface addresses;
- stateful return-traffic firewall rules;
- `PersistentKeepalive = 25` for clients behind NAT; and
- safer handling and messaging for client profile secrets.

It has not been promoted to the active script because the review found these
remaining concerns:

1. It always generates IPv6 routes and an IPv6 DNS server even when the VPS has
   no working IPv6 path. The current Pi-hole Compose deployment publishes DNS
   only on an IPv4 address, so the generated IPv6 DNS address would not answer.
2. It permits a custom WireGuard server IPv4 address but allocates clients from
   `.2` through `.254` without excluding the server address. A server address
   other than the default `.1` can therefore collide with a client.
3. Its firewall helper uses fail-fast execution across IPv4 and IPv6 commands.
   An unsupported IPv6 operation can leave some IPv4 rules installed while
   causing `wg-quick` startup to fail. Repeated partial starts can also create
   duplicate rules.
4. Client creation writes the profile and appends the server peer before
   restarting WireGuard. A failed restart leaves a partially committed client
   that requires manual cleanup.

Treat both scripts as privileged installers: they install packages, generate
private keys, write under `/etc/wireguard`, enable IP forwarding, modify
iptables/ip6tables, and enable a system service. Review the active script and
back up `/etc/wireguard` before running it on an existing server.

## Recommended installation path

### Oracle Cloud VPS

Use the provisioning and network concepts from the
[Pi-hole and WireGuard on Oracle Cloud guide](https://github.com/anbuchelva/Pi-hole-and-Wireguard-on-Oracle-Cloud-always-free-tier),
but do not run an Internet-downloaded setup script blindly. Pi-hole is already
managed by Docker in this repository and should not be installed again by a
WireGuard installer.

Until the candidate installer concerns above are fixed, prefer a reviewed
manual WireGuard setup or the official distribution packages and configuration
steps. Preserve SSH access and an existing root session while changing
firewall rules so a mistake does not lock you out of the VPS.

### Orange Pi or another home server

For a home server, follow Pi-hole's
[WireGuard server guide](https://docs.pi-hole.net/guides/vpn/wireguard/server/).
Give the Orange Pi a static LAN address or DHCP reservation before configuring
router port forwarding.

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

The reviewed installer candidate creates a direct iptables rule when `wg0`
starts. If the server uses UFW instead, the equivalent explicit rule is:

```bash
sudo ufw allow 51515/udp comment 'WireGuard'
sudo ufw status verbose
```

Do not mix several persistent firewall managers without understanding their
rule ordering. Check current rules before adding another rule:

```bash
sudo iptables -S INPUT
sudo ip6tables -S INPUT
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

3. If the Orange Pi runs UFW, allow the same host port:

   ```bash
   sudo ufw allow 51515/udp comment 'WireGuard'
   ```

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
the server. Add `::/0` only after verifying end-to-end IPv6 routing and DNS;
otherwise IPv6 can fail or bypass the intended tunnel policy.

## Add friendly client names

Add client addresses to the server's `/etc/hosts` if Pi-hole should display
names instead of VPN addresses:

```text
10.66.66.2 linux-laptop
10.66.66.3 android-phone
10.66.66.4 tablet
```

IPv6 names should be added only if IPv6 is enabled and working throughout the
WireGuard and Pi-hole deployment.

## Protect client profiles

Every generated client configuration and QR code contains a private key. Treat
it like a password:

- transfer it only through a trusted channel;
- store it with restrictive permissions;
- never commit it to this repository; and
- remove the corresponding peer from the server if a device or profile is
  lost.
