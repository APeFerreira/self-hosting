# Pi-Hole

## Instructions

### Pull image

```bash
docker pull --platform linux/arm/v7 pihole/pihole:latest
```

### Start container

```bash
docker compose up -d --build
```

## Web interface

Access the Pi-hole web interface by navigating to `http://<your_pi-hole_ip>/admin` in your web browser.

## Settings

Under `Interface settings`, select `Respond only on interface eth0`