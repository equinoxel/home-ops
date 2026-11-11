# n8n

[n8n](https://n8n.io/) — extendable workflow automation tool for connecting apps and automating tasks.

## Architecture

Single-container deployment using the `app-template` Helm chart with SQLite embedded database.

| Container | Image | Role |
|---|---|---|
| **app** | `docker.io/n8nio/n8n` | n8n workflow engine and web UI listening on port 5678 |

## Networking

- **WebUI & Webhooks** — exposed at `https://n8n.laurivan.com` via an HTTPRoute on the internal Envoy Gateway (`envoy-internal` in `network-system`).
- Webhook URL configured to `https://n8n.laurivan.com/`.

## Authentication

n8n uses its native user management (owner registration and email/password authentication configured on first visit).

## Storage

| Volume | Type | Mount |
|---|---|---|
| `data` | PVC (`5Gi`, managed by VolSync) | `/home/node/.n8n` — SQLite database, configuration, and credentials |

## Health Checks

- **Startup** — `GET /healthz` on port 5678 (30 retries, 5s interval, 10s initial delay).
- **Liveness / Readiness** — `GET /healthz` on port 5678 (30s interval, 5s timeout).

## Dependencies

Deployed via Flux Kustomization with dependencies on:

- `storage-ready` (flux-system) — VolSync PVC and storage infrastructure
