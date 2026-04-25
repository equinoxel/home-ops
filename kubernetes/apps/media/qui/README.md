# qui

[qui](https://github.com/autobrr/qui) — a web UI for managing qBittorrent instances. Authenticates via OIDC through Authentik.

## Architecture

Single-container deployment using the `app-template` Helm chart.

| Container | Image | Role |
|---|---|---|
| **app** | `ghcr.io/autobrr/qui` | Web UI listening on port 80 |

## Networking

- **WebUI** — exposed at `qui.laurivan.com` via an HTTPRoute through the `envoy-internal` gateway.

## Authentication

OIDC is enabled and configured against the Authentik provider:

| Setting | Value |
|---|---|
| Issuer | `https://auth.laurivan.com/application/o/qui/` |
| Callback URL | `https://qui.laurivan.com/api/auth/oidc/callback` |
| Built-in login | Disabled |

The OIDC client ID and secret are pulled from the external secret (see below).

### Authentik Setup

1. **Create an OAuth2/OpenID Provider**
   - Go to **Admin → Providers → Create** and select **OAuth2/OpenID Provider**.
   - Name: `qui`
   - Authorization flow: use your default implicit/explicit consent flow.
   - Client ID / Client Secret: copy these into the Bitwarden `qui` item as `QUI_OIDC_CLIENT_ID` and `QUI_OIDC_CLIENT_SECRET`.
   - Redirect URIs: `https://qui.tholinka.dev/api/auth/oidc/callback`
   - Scopes: `openid`, `profile`, `email`.
   - Signing Key: select your self-signed or managed certificate.

2. **Create an Application**
   - Go to **Admin → Applications → Create**.
   - Name: `qui`
   - Slug: `qui` (this determines the issuer path — `https://auth.tholinka.dev/application/o/qui/`).
   - Provider: select the `qui` provider created above.
   - Launch URL: `https://qui.tholinka.dev`

3. **Assign Access**
   - Under the application's **Policy / Group Bindings**, bind the groups or users that should have access.

4. **Store Secrets in Bitwarden**
   - In the `qui` Bitwarden item, set:
     - `QUI_SESSION_SECRET` — a random string (e.g. `openssl rand -hex 32`).
     - `QUI_OIDC_CLIENT_ID` — the Client ID from step 1.
     - `QUI_OIDC_CLIENT_SECRET` — the Client Secret from step 1.

## Storage

| Volume | Type | Mount |
|---|---|---|
| `config` | PVC (`2Gi`, managed by VolSync) | `/` (default) — qui state |
| `media` | NFS (`nas.servers.internal:/media`) | `/media` |

## Secrets

One ExternalSecret pulls from the `qui` key in the Bitwarden ClusterSecretStore:

| Template Variable | Env |
|---|---|
| `QUI_SESSION_SECRET` | `QUI__SESSION_SECRET` |
| `QUI_OIDC_CLIENT_ID` | `QUI__OIDC_CLIENT_ID` |
| `QUI_OIDC_CLIENT_SECRET` | `QUI__OIDC_CLIENT_SECRET` |

## Health Checks

- **Liveness / Readiness** — `GET /health` on port 80.

## Dependencies

Deployed via Flux Kustomization with dependencies on:

- `keda` (observability) — NFS scaler component
- `storage-ready` (flux-system) — VolSync PVC
- `authentik` (security) — OIDC provider must be available at startup
