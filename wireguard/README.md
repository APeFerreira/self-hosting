# WireGuard

## Local network server

For a server on your local network, follow Pi-hole's
[WireGuard server guide](https://docs.pi-hole.net/guides/vpn/wireguard/server/).

## Oracle Cloud server

For an Oracle Cloud VM, follow the provisioning and network steps in the
[Pi-hole and WireGuard on Oracle Cloud guide](https://github.com/anbuchelva/Pi-hole-and-Wireguard-on-Oracle-Cloud-always-free-tier).
When the guide reaches its software setup, use the local
[`oracle_setup.sh`](./oracle_setup.sh) instead of the guide's `setup.sh`. This
version supports Ubuntu and Debian and does not install Pi-hole, so use it only
when Pi-hole is already installed.

The script must run as root from root's home directory. It installs WireGuard,
changes firewall and IP-forwarding settings, creates
`/etc/wireguard/wg0.conf` by default, starts the corresponding `wg-quick`
service, and writes a client profile containing private key material under
`/root`. Review it before running it:

```bash
sudo -i
cp /path/to/oracle_setup.sh /root/
chmod +x /root/oracle_setup.sh
./oracle_setup.sh
```

Also allow inbound UDP traffic to the selected WireGuard port (port `51515` by
default) in the VM's Oracle Cloud security list or network security group.

Do not install or configure WireGuard separately before using this script. Once
the server has been created, run the script again to add another client.

## Split tunnel vs. full tunnel

Generated client profiles use a split tunnel by default:

```ini
AllowedIPs = 10.66.66.0/24, fd42:42:42::/64
```

Only traffic for the WireGuard networks—including requests to the configured
Pi-hole DNS addresses—uses the VPN. Other Internet traffic uses the client's
normal connection.

For a full tunnel, create a separate copy of the client profile and change the peer setting to:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

This requires forwarding and NAT on the server, which `oracle_setup.sh`
configures. If the server does not have working IPv6 egress, use only
`0.0.0.0/0`; be aware that the client's native IPv6 traffic will then bypass the
VPN unless IPv6 is disabled on the client. See Pi-hole's
[full-tunnel guide](https://docs.pi-hole.net/guides/vpn/wireguard/route-everything/)
for the routing details.

## Friendly client names (optional)

Add client addresses to `/etc/hosts` if you want Pi-hole's dashboard to display
names instead of IP addresses:

```text
10.66.66.2    linux-dell-pc
fd42:42:42::2 linux-dell-pc
10.66.66.3    android-phone
fd42:42:42::3 android-phone
10.66.66.4    android-tv
fd42:42:42::4 android-tv
```
