# Unbound

## TODO

- [ ] Check config file

## Instructions

### Pull image

```bash
docker pull alpinelinux/unbound:latest-armv7
```

### Start container

```bash
docker run --name=my_unbound \
--detach=true \
--publish=5353:5353/tcp \
--publish=5353:5353/udp \
--restart=unless-stopped \
alpinelinux/unbound:latest-armv7
```

### Enter the container

```bash
docker exec -it my_unbound /bin/sh
```

### Install nano

```bash
apk update && apk add bind-tools nano
```

### Paste my config into `/etc/unbound/unbound.conf`


### Check if config file is ok

```bash
unbound-checkconf
```

### Restart the container

```bash
docker restart my_unbound
```

## Test

You should look for `status: NOERROR` if successful.

### On container

```bash
dig google.com ANY @127.0.0.1 -p 5353
```

### On host

#### Discover IP

Run

```bash
ip addr | grep docker
```

And look for something like `inet 172.17.0.1/16`


#### Test

```bash
dig google.com ANY @172.17.0.1 -p 5353
```

### On Windows

First find the Pi's IP and then

```bash
nslookup youtube.com 192.168.15.182
```