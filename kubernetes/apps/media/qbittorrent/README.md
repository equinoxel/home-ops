# qBittorrent

BitTorrent client routed through a [Gluetun](https://github.com/qdm12/gluetun) VPN tunnel, managed by [qui](https://github.com/autobrr/qui) (deployed separately in `../qui`).

## Architecture

The pod runs several containers orchestrated as a single unit:

| Container | Image | Role |
|---|---|---|
| **gluetun** | `ghcr.io/qdm12/gluetun` | VPN tunnel (WireGuard/OpenVPN) with kill-switch firewall. Runs as an init container with `restartPolicy: Always` so it stays up for the lifetime of the pod. |
| **socks5** | `mirror.gcr.io/serjs/go-socks5-proxy` | SOCKS5 proxy exposed on port 8388 through the VPN tunnel. Workaround until Gluetun supports SOCKS5 natively. |
| **app** | `ghcr.io/home-operations/qbittorrent` | The qBittorrent WebUI, listening on port 80. |
| **port-forward** | `ghcr.io/tholinka/gluetun-qb-port-sync` | Syncs the VPN provider's forwarded port into qBittorrent every 5 minutes via cron. |

All traffic from the app container exits through the Gluetun tunnel. The firewall only allows inbound connections on ports 80 (WebUI), 8388 (SOCKS proxy), and 9999 (health probes), and outbound traffic to the cluster pod/service CIDRs (`10.69.0.0/16`, `10.96.0.0/16`).

## Networking

- **WebUI** — exposed at `qb.tholinka.dev` via an HTTPRoute through the `envoy-internal` gateway.
- **SOCKS proxy** — available cluster-internally on the `qbittorrent-gluetun` service, port 8388.
- **DNS** — Gluetun uses CoreDNS (`10.96.0.10`) instead of the VPN provider's DNS.

## Storage

| Volume | Type | Mount |
|---|---|---|
| `config` | PVC (`2Gi`, managed by VolSync) | `/config` — qBittorrent state |
| `media` | NFS (`nas.servers.internal:/media`) | `/media/downloads/qbittorrent` |
| `tunnel` | HostPath (`/dev/net/tun`) | `/dev/net/tun` — TUN device for Gluetun |
| `gluetun-auth` | Secret (`qbittorrent-gluetun`) | Gluetun HTTP control server auth config |
| `config-file` | ConfigMap | `.qbt.toml` — points the qBittorrent CLI helper at localhost |

## Secrets

Three ExternalSecrets pull from the `gluetun` key in the Bitwarden ClusterSecretStore:

### `qbittorrent`

Consumed by the **app** and **port-forward** containers.

| Template Variable | Env / Usage |
|---|---|
| `GLUETUN_API_KEY` | `GLUETUN_CONTROL_SERVER_API_KEY` |
| `GLUETUN_QB_PORT_SYNC_PROXY` | Appended to `QBITTORRENT_WEBUI_PORT` path |

Also sets `QBITTORRENT_HOST: qui.media.svc.cluster.local` (hardcoded).

### `wireguard`

Consumed by the **gluetun** container.

| Template Variable | Env |
|---|---|
| `WIREGUARD_PRIVATE_KEY` | `WIREGUARD_PRIVATE_KEY` |
| `OPENVPN_USER` | `OPENVPN_USER` |
| `OPENVPN_PASSWORD` | `OPENVPN_PASSWORD` |
| `VPN_SERVICE_PROVIDER` | `VPN_SERVICE_PROVIDER` and `VPN_PORT_FORWARDING_PROVIDER` |
| `HEALTH_TARGET_ADDRESS` | `HEALTH_TARGET_ADDRESSES` |
| `SERVER_COUNTRIES` | `SERVER_COUNTRIES` |
| `SERVER_CITIES` | `SERVER_CITIES` |
| `GLUETUN_API_KEY` | `GLUETUN_CONTROL_SERVER_API_KEY` (for health checks) |

### `qbittorrent-gluetun`

Mounted as `auth.toml` into the Gluetun container. Defines an API key role (`gluetun-qb-port-sync`) that grants read access to `/v1/publicip/ip` and `/v1/portforward`.

## Health Checks

- **Gluetun** — liveness probe queries the control server's port-forward endpoint; fails if the forwarded port is `0`.
- **qBittorrent** — startup probe hits `/api/v2/app/version` (30 attempts, 10s apart).

## Dependencies

Deployed via Flux Kustomization with dependencies on:

- `keda` (observability) — NFS scaler component
- `storage-ready` (flux-system) — VolSync PVC
