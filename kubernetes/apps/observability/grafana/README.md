# Grafana

Grafana is deployed using the [grafana-operator](https://github.com/grafana/grafana-operator) pattern, where the operator manages the Grafana instance, datasources, and dashboards declaratively via Custom Resources.

## Architecture

```mermaid
graph TD
    subgraph "Flux Kustomizations"
        KS_APP["grafana (app.ks.yaml)<br/>Deploys grafana-operator HelmRelease"]
        KS_INSTANCE["grafana-instance (instance.ks.yaml)<br/>Deploys Grafana CR + datasources"]
        KS_DASHBOARDS["grafana-dashboards (dashboards.ks.yaml)<br/>Deploys GrafanaDashboard CRs"]
    end

    KS_APP --> KS_INSTANCE
    KS_INSTANCE -->|dependsOn| KS_APP
    KS_INSTANCE -->|dependsOn| OPENEBS["openebs<br/>(storage-system)"]

    subgraph "observability namespace"
        OPERATOR["grafana-operator<br/>(Deployment)"]
        GRAFANA_CR["Grafana CR<br/>(grafana.integreatly.org)"]
        GRAFANA_POD["grafana-deployment<br/>(managed by operator)"]
        DS_PROM["GrafanaDatasource<br/>prometheus → vmauth"]
        DS_AM["GrafanaDatasource<br/>alertmanager → vmalertmanager"]
        DASHBOARDS["GrafanaDashboard CRs<br/>(kube-prometheus-stack, cilium, etc.)"]
        PVC["grafana-pvc<br/>10Gi openebs-hostpath"]
    end

    OPERATOR -->|reconciles| GRAFANA_CR
    GRAFANA_CR -->|creates| GRAFANA_POD
    GRAFANA_POD --> PVC
    OPERATOR -->|syncs| DS_PROM
    OPERATOR -->|syncs| DS_AM
    OPERATOR -->|syncs| DASHBOARDS

    subgraph "External Dependencies"
        AUTHENTIK["authentik<br/>(security namespace)"]
        VMAUTH["vmauth-victoria-metrics<br/>:8427"]
        VMALERT["vmalertmanager<br/>:9093"]
        BITWARDEN["Bitwarden<br/>(ClusterSecretStore)"]
        ENVOY["envoy-internal<br/>(network namespace)"]
    end

    GRAFANA_POD -->|OAuth login| AUTHENTIK
    DS_PROM -->|queries| VMAUTH
    DS_AM -->|queries| VMALERT
    GRAFANA_POD -->|secrets from| BITWARDEN
    GRAFANA_POD -->|exposed via| ENVOY
```

## Directory Structure

```
grafana/
├── app/                    # grafana-operator HelmRelease
│   ├── helmrelease.yaml    # Operator deployment
│   ├── ocirepository.yaml  # Chart source
│   └── grafanadashboard.yaml  # Operator-specific dashboards
├── instance/               # Grafana instance configuration
│   ├── grafana.yaml        # Grafana CR (the actual Grafana server)
│   ├── externalsecret.yaml # OAuth + admin credentials from Bitwarden
│   ├── grafanadatasource.yaml  # Prometheus + Alertmanager datasources
│   └── servicemonitor.yaml # Metrics scraping
├── dashboards/             # GrafanaDashboard CRs
│   ├── kube-prometheus-stack.yaml
│   ├── cilium.yaml
│   └── ...
├── app.ks.yaml             # Flux Kustomization for operator
├── instance.ks.yaml        # Flux Kustomization for instance (depends on app + openebs)
├── dashboards.ks.yaml      # Flux Kustomization for dashboards
└── kustomization.yaml      # Top-level kustomize resources
```

## Authentication via Authentik

Grafana uses Authentik as its OAuth/OIDC provider. Users do not log in with local credentials — authentication is handled entirely by Authentik.

### How It Works

```mermaid
sequenceDiagram
    participant User
    participant Grafana
    participant Authentik

    User->>Grafana: Access grafana.laurivan.com
    Grafana->>Authentik: Redirect to auth.laurivan.com/application/o/authorize/
    Authentik->>User: Login page (or SSO if already authenticated)
    User->>Authentik: Authenticate
    Authentik->>Grafana: Redirect back with OAuth token
    Grafana->>Authentik: Exchange token at /application/o/token/
    Grafana->>Authentik: Fetch user info from /application/o/userinfo/
    Grafana->>User: Logged in with role based on group membership
```

### Configuration

The OAuth configuration is defined in the `Grafana` CR (`instance/grafana.yaml`):

| Setting | Value |
|---------|-------|
| Provider | `generic_oauth` (OpenID Connect) |
| Auto-login | Enabled (`oauth_auto_login: true`) |
| Scopes | `openid email profile groups` |
| Auth URL | `https://auth.laurivan.com/application/o/authorize/` |
| Token URL | `https://auth.laurivan.com/application/o/token/` |
| UserInfo URL | `https://auth.laurivan.com/application/o/userinfo/` |
| Signout redirect | `https://auth.laurivan.com/application/o/grafana/end-session/` |

### Role Mapping

Grafana roles are assigned based on Authentik group membership:

| Authentik Group | Grafana Role |
|-----------------|--------------|
| `Grafana Admins` | Admin |
| `Grafana Editors` | Editor |
| *(any other)* | Viewer |

This is configured via `role_attribute_path`:
```
contains(groups[*], 'Grafana Admins') && 'Admin' || contains(groups[*], 'Grafana Editors') && 'Editor' || 'Viewer'
```

### Anonymous Access

Anonymous access is enabled for read-only viewing (Viewer role, Main Org). This allows dashboards to be viewed without authentication.

### Secrets

OAuth credentials are stored in Bitwarden and injected via ExternalSecret:

- `GF_AUTH_GENERIC_OAUTH_CLIENT_ID` — Authentik application client ID
- `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` — Authentik application client secret
- `GF_SECURITY_ADMIN_PASSWORD` — Local admin fallback password

## Dependencies

| Dependency | Namespace | Purpose |
|------------|-----------|---------|
| **grafana-operator** | observability | Manages the Grafana instance lifecycle |
| **openebs** | storage-system | Provides `openebs-hostpath` StorageClass for Grafana PVC |
| **authentik** | security | OAuth/OIDC authentication provider |
| **victoria-metrics** | observability | Metrics datasource (via vmauth proxy) |
| **vmalertmanager** | observability | Alertmanager datasource |
| **external-secrets** | security | Syncs OAuth credentials from Bitwarden |
| **envoy-internal** | network | Gateway for `grafana.laurivan.com` HTTPRoute |
| **cert-manager** | cert-manager | TLS certificates for the HTTPRoute |

## Datasources

Datasources are managed declaratively via `GrafanaDatasource` CRs:

- **prometheus** (default) — Points to `vmauth-victoria-metrics:8427` which proxies to VMSingle
- **alertmanager** — Points to `vmalertmanager-victoria-metrics:9093`

## Dashboards

Dashboards are managed via `GrafanaDashboard` CRs that reference upstream Grafana.com dashboard IDs or inline JSON. They are automatically synced by the grafana-operator. Individual apps can also ship their own `GrafanaDashboard` CRs (e.g., authentik, CNPG, cilium).

All dashboards use `instanceSelector.matchLabels: grafana.internal/instance: grafana` to target this Grafana instance.

## Accessing Grafana

- **URL**: https://grafana.laurivan.com
- **Login**: Automatic via Authentik SSO (or anonymous Viewer access)
- **Admin**: Members of the `Grafana Admins` group in Authentik
