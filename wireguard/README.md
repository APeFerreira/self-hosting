## Local network server

If setting up a local network server, follow Pi-hole's [documentation](https://docs.pi-hole.net/guides/vpn/wireguard/server/) for installing Wireguard.

## Cloud server

If setting up a cloud server, follow this [guide](https://github.com/anbuchelva/Pi-hole-and-Wireguard-on-Oracle-Cloud-always-free-tier) for installing Wireguard in an Oracle VM. Comment the lines related to Pi-hole installation if it's already installed. The commented script can be found [here](./oracle_setup.sh).

**DO NOT INSTALL WIREGUARD BY YOURSELF IF USING THE SCRIPT FROM THE GUIDE**

## Full vs. Split tunnel

The default configuration (which is the recommended configuration) for all VPN profiles is Split Tunnel. If you wish to route all your traffic through the VPN (Full Tunnel), edit the **Allowed IPs** on your Client Profile on your device to read `0.0.0.0/0, ::/0`. -> IN FACT IT'S MORE COMPLEX THAN THIS

## Update Host Names (Optional Step)

edit `/etc/hosts/` file to update the client names, if you wish to see the client names instead of the ip address of client devices.

`sudo nano /etc/hosts` would open the hosts file in edit mode.

Add clients like given below:

```
10.66.66.2      linux-dell-pc
fd42:42:42::2   linux-dell-pc
10.66.66.3      android-phone
fd42:42:42::3   android-phone
10.66.66.4      android-tv
fd42:42:42::4   android-tv
```
