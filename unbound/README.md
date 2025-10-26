# Unbound


## Instructions

### Create network (if not created yet)

```bash
docker network create monitor-net
```

### Start container

```bash
docker compose up -d
```


### Check if config file is ok

```bash
docker exec unbound unbound-checkconf
```

### Discover the container's IP

This IP is used when pinging from inside other containers.

```bash
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' unbound
```

## Test

You should look for `status: NOERROR` if successful.


### On container

```bash
dig google.com ANY @127.0.0.1 -p 5335
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
dig google.com ANY @172.17.0.1 -p 5335
```

### On Windows

First find the Pi's IP and then

```bash
nslookup youtube.com 192.168.15.182

```

