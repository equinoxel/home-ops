# BookOrbit

[BookOrbit](https://bookorbit.app/) is a self-hosted digital library and book manager for EPUB, PDF, comics, and audiobooks. It features smart shelves, metadata management, Kobo/KOReader sync, OPDS support, and a built-in reader.

- **Upstream docs**: https://bookorbit.app/installation.html
- **Source**: https://github.com/bookorbit/bookorbit

## Architecture

```mermaid
graph TD
    subgraph media namespace
        HR[HelmRelease<br/>bookorbit]
        SVC[Service<br/>:3000]
        DEP[Deployment<br/>bookorbit]
        PVC[PVC<br/>bookorbit<br/>1Gi openebs-hostpath]
        ES[ExternalSecret<br/>bookorbit]
        SEC[Secret<br/>bookorbit]
        CERT[Certificate<br/>postgres-bookorbit-cert]
        DBSEC[Secret<br/>bookorbit-postgres]
        SP[SecurityPolicy<br/>bookorbit]
    end

    subgraph network namespace
        GW[Gateway<br/>envoy-internal]
    end

    subgraph security namespace
        AK[Authentik<br/>embedded-outpost]
    end

    subgraph database namespace
        DB[(PostgreSQL<br/>postgres-cluster)]
        DBKS[Kustomization<br/>bookorbit-db]
        DBOBJ[Database CR<br/>postgres-bookorbit]
    end

    subgraph NFS
        NFS_BOOKS[192.168.2.44<br/>/mnt/Main/shares/books]
    end

    subgraph external
        BW[Bitwarden<br/>ClusterSecretStore]
    end

    HR --> DEP
    HR --> SVC
    HR --> ROUTE[HTTPRoute<br/>bookorbit.laurivan.com]
    ROUTE --> GW
    SP --> ROUTE
    SP --> AK
    DEP --> PVC
    DEP --> NFS_BOOKS
    DEP --> CERT
    DEP --> DBSEC
    DEP --> SEC
    ES --> BW
    ES --> SEC
    DBKS --> DBOBJ
    DBOBJ --> DB
    CERT --> DB
    DBSEC -.->|connection URL| DEP
```

## Secrets

### Bitwarden item: `bookorbit`

Create a Bitwarden item named `bookorbit` with the following fields:

| Field | Description | Generation |
|-------|-------------|------------|
| `JWT_SECRET` | Secret for signing login tokens | `openssl rand -hex 32` |
| `SETUP_BOOTSTRAP_TOKEN` | One-time token for initial admin setup | `openssl rand -hex 16` |

### Auto-generated secrets

| Secret | Source | Purpose |
|--------|--------|---------|
| `bookorbit-postgres` | CNPG component | PostgreSQL connection URL with mTLS params |
| `postgres-bookorbit-cert` | cert-manager | TLS client certificate for PostgreSQL auth |

## Kubernetes Parameters

### Endpoints

| Parameter | Value |
|-----------|-------|
| Internal URL | `https://bookorbit.laurivan.com` |
| Gateway | `envoy-internal` (namespace: `network`) |
| Service port | `3000` |

### Resources

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 50m | — |
| Memory | 256Mi | 2Gi |

### Storage

| Volume | Type | Path | Size |
|--------|------|------|------|
| `data` | PVC (openebs-hostpath) | `/data` | 1Gi |
| `books` | NFS (`192.168.2.44`) | `/books` | `/mnt/Main/shares/books` |
| `postgres-certs` | Secret | `/var/run/secrets/postgresql` | — |

### Database

| Parameter | Value |
|-----------|-------|
| Cluster | `postgres-cluster` (namespace: `database`) |
| Database name | `bookorbit` |
| Owner | `bookorbit` |
| Extensions | `uuid-ossp`, `pg_trgm`, `vector` (pgvector) |
| Auth | mTLS via cert-manager |

### Environment Variables

| Variable | Value | Source |
|----------|-------|--------|
| `APP_URL` | `https://bookorbit.laurivan.com` | helmrelease |
| `APP_PORT` | `3000` | helmrelease |
| `DATABASE_URL` | `postgresql://bookorbit@...` | `bookorbit-postgres` secret |
| `JWT_SECRET` | — | `bookorbit` secret (Bitwarden) |
| `SETUP_BOOTSTRAP_TOKEN` | — | `bookorbit` secret (Bitwarden) |
| `PUID` / `PGID` | `1000` | helmrelease |

## Enabling

1. Create the Bitwarden item `bookorbit` with the fields above
2. Create an **Authentik Proxy Provider** for BookOrbit:
   - Name: `bookorbit`
   - External host: `https://bookorbit.laurivan.com`
   - Mode: Forward auth (single application)
3. Create an **Authentik Application** linked to the provider
4. Uncomment `#- ./bookorbit` in [`kubernetes/apps/media/kustomization.yaml`](../kustomization.yaml)
5. Commit and push — Flux will create the database, certificate, and deploy the app
6. After first login, configure OIDC/SSO in BookOrbit UI (Settings > OIDC / SSO):
   - Issuer: `https://auth.laurivan.com/application/o/bookorbit/`
   - Client ID / Secret: from the Authentik provider

## References

- [`app.ks.yaml`](./app.ks.yaml) — Flux Kustomization with CNPG and VolSync components
- [`app/helmrelease.yaml`](./app/helmrelease.yaml) — App deployment via app-template chart
- [`app/externalsecret.yaml`](./app/externalsecret.yaml) — Bitwarden secret sync
- [`../../components/cnpg/app`](../../components/cnpg/app) — CNPG database component
- [`../../components/ext-auth`](../../components/ext-auth) — Authentik external auth SecurityPolicy
- [`../../components/volsync`](../../components/volsync) — VolSync backup component
