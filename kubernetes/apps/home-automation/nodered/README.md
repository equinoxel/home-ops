# Node-RED

[Node-RED](https://nodered.org/) — low-code programming for event-driven applications, wiring together hardware devices, APIs, and online services.

## Architecture

Single-container deployment using the `app-template` Helm chart with projects feature enabled.

| Container | Image | Role |
|---|---|---|
| **app** | `docker.io/nodered/node-red` | Node-RED flow editor and runtime listening on port 1880 |

## Networking

- **WebUI & API** — exposed at `https://nodered.laurivan.com` via an HTTPRoute on the internal Envoy Gateway (`envoy-internal` in `network-system`).

## Authentication

Internal access only via the internal gateway; projects mode enabled for flow and credential management.

## Storage

| Volume | Type | Mount |
|---|---|---|
| `data` | PVC (`2Gi`, managed by VolSync) | `/data` — Node-RED flows, configuration, and project repositories |

## Health Checks

- **Startup** — TCP socket check on port 1880 (30 retries, 5s interval, 10s initial delay).
- **Liveness / Readiness** — `GET /` on port 1880 (30s interval, 5s timeout).

## Dependencies

Deployed via Flux Kustomization with dependencies on:

- `storage-ready` (flux-system) — VolSync PVC and storage infrastructure
