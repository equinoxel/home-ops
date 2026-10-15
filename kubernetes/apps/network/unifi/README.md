# UniFi OS Server

Ubiquiti's modern self-hosted **UniFi OS Server** platform deployed in Kubernetes to manage UniFi network hardware (switches, access points, and gateways) with support for modern UniFi OS features (Site Magic SD-WAN, UniFi Identity, InnerSpace, and multi-site organization).

## Overview

- **Namespace**: `network`
- **Image**: `ghcr.io/lemker/unifi-os-server:v1.7.0` (UniFi OS Server 5.1.42)
- **Web UI URL**: `https://unifi.laurivan.com` (proxied via `envoy-internal`)
- **Device Inform & STUN IP**: `192.168.2.161` (`${SVC_UNIFI_STUN_IP}`) via Cilium LoadBalancer
- **Storage**: 10Gi PVC backed by VolSync replication

## Architecture & Container Runtime

UniFi OS Server runs upstream systemd inside the container to manage its internal microservices (`unifi-core`, `ulp-go`, `unifi` Java controller, PostgreSQL, MongoDB, RabbitMQ, and internal Nginx).

Because systemd runs as PID 1:
- The container requires `securityContext.privileged: true`.
- Tmpfs volumes (`emptyDir` with `medium: Memory`) are mounted at `/run`, `/run/lock`, `/tmp`, and `/var/lib/journal`.
- Persistent state is isolated into distinct subPaths on the single `unifi` PVC:
  - `/persistent`: Persistent UniFi OS files
  - `/data`: Platform data and UUID
  - `/var/log`: Application and system logs
  - `/srv`: System runtime files
  - `/var/lib/unifi`: UniFi Network controller data and configs
  - `/var/lib/mongodb`: Embedded MongoDB database
  - `/etc/rabbitmq/ssl`: RabbitMQ TLS certificates

## Networking & Ports

### 1. Ingress / Web UI (`envoy-internal`)
- Envoy Gateway terminates public TLS (`*.laurivan.com`) and routes directly to the container's HTTP port `80`, ensuring native WebSocket upgrade support.
- Access URL: `https://unifi.laurivan.com`

### 2. Device Communication (LoadBalancer `192.168.2.161`)
Exposed via Cilium LoadBalancer IPAM at `192.168.2.161` (`${SVC_UNIFI_STUN_IP}`):
- `8080/tcp`: Device inform (APs, switches, and gateways report here)
- `3478/udp`: STUN service
- `10003/udp`: UniFi OS AP discovery
- `10001/udp`: Legacy AP discovery
- `5514/udp`: Remote syslog
- `6789/tcp`: Mobile speed test

### 3. Health Checks
Health checks utilize the internal HTTP health endpoint:
- `httpGet: /api/ping` on port `80` (startup, liveness, and readiness probes).

## Device Adoption / Inform URL

When adopting UniFi devices via SSH, point them to:
```bash
set-inform http://192.168.2.161:8080/inform
# or using DNS:
set-inform http://unifi-stun.laurivan.com:8080/inform
```
