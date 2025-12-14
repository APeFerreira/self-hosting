# Pi-Hole

## Instructions

### Pull image

```bash
docker pull --platform linux/arm/v7 pihole/pihole:latest
```

### Start container

```bash
docker compose up -d
```


#### Problems

```
[+] Running 0/1
 ⠙ Container pihole  Starting                                                                                                                          0.2s
Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint pihole (ab2002f1fdd6d9a35797487b1d3815615dae1a6bdbc9b4b98e839bdffe4903ae): failed to bind host port for 0.0.0.0:53:172.19.0.2:53/tcp: address already in use
```

###### Possible solution (more specific)

Based on this [issue](https://discourse.pi-hole.net/t/update-what-to-do-if-port-53-is-already-in-use/52033), it seems that `systemd-resolved` is using port 53. In short, change the line in `/etc/systemd/resolved.conf` to:

```DNSStubListener=no
```

Then restart the service:

```bash
sudo systemctl restart systemd-resolved.service
```

###### Possible solution (too broad)

```bash
sudo systemctl disable --now systemd-resolved.service
sudo rm /etc/resolv.conf
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf
```

## Test

```bash
dig google.com ANY @127.0.0.1 -p 53
```


## Web interface

Access the Pi-hole web interface by navigating to `http://<your_pi-hole_ip>/admin` in your web browser.

## Settings

Under `Interface settings`, select `Respond only on interface eth0`