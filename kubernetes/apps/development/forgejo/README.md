# Forgejo

Self-hosted Git forge running at [https://giti.laurivan.com](https://giti.laurivan.com).

## Architecture

```mermaid
graph LR
    subgraph External
        User[User / Browser]
        SSH[SSH Client]
    end

    subgraph "Cluster (dev namespace)"
        subgraph "Forgejo App"
            Anubis["Anubis<br/>(bot protection)"]
            Forgejo["Forgejo<br/>(chart default image)"]
            Dragonfly["Dragonfly<br/>(Redis-compatible cache)"]
            PVC["PVC: forgejo<br/>(10Gi, OpenEBS hostpath)"]
        end

        subgraph "Forgejo Runner"
            Runner["forgejo-runner<br/>(StatefulSet)"]
            WorkerPods["CI Worker Pods<br/>(ephemeral)"]
        end
    end

    subgraph "External Services"
        Authentik["Authentik<br/>auth.laurivan.com"]
        Bitwarden["Bitwarden<br/>(secrets)"]
        VolSync["VolSync<br/>(backup)"]
    end

    User -->|HTTPS| Anubis -->|proxy| Forgejo
    SSH -->|TCP :22| Forgejo
    Forgejo --> Dragonfly
    Forgejo --> PVC
    Forgejo -->|OIDC| Authentik
    Runner -->|HTTP| Forgejo
    Runner -->|spawns| WorkerPods
    Bitwarden -.->|ExternalSecret| Forgejo
    VolSync -.->|backup| PVC
```

## Components

| Component | Purpose |
|-----------|---------|
| **Forgejo** | Git forge (web UI, API, SSH) |
| **Anubis** | Bot/scraper protection proxy in front of Forgejo HTTP |
| **Dragonfly** | Redis-compatible in-memory store for cache, sessions, and queues |
| **Forgejo Runner** | CI/CD runner (Kubernetes executor, spawns job pods in `dev` namespace) |
| **VolSync** | PVC backup (10Gi OpenEBS hostpath volume) |

## Endpoints

| Protocol | Hostname | Gateway | Port |
|----------|----------|---------|------|
| HTTPS | `giti.laurivan.com` | envoy-external | 443 |
| SSH | `giti.laurivan.com` | envoy-external (TCPRoute) | 22 |

## Authentication

Forgejo uses **Authentik** as its sole authentication provider via OpenID Connect. Internal sign-in and registration are disabled.

- **Provider**: OpenID Connect
- **Discovery URL**: `https://auth.laurivan.com/application/o/forgejo/.well-known/openid-configuration`
- **Admin group claim**: `forgejo_admins`
- **Scopes**: `openid email profile groups`

### Authentik Setup

1. In Authentik, create an **OAuth2/OpenID Provider** named `forgejo`
2. Set the redirect URI to `https://giti.laurivan.com/user/oauth2/authentik/callback`
3. Create an **Application** with slug `forgejo` linked to the provider
4. Assign users/groups — members of the `forgejo_admins` group get admin privileges in Forgejo
5. Copy the Client ID and Client Secret into Bitwarden (see below)

## Secrets

All secrets are stored in a single **Bitwarden item** named `forgejo` and synced via ExternalSecret (ClusterSecretStore: `bitwarden`).

### Required Bitwarden Fields

| Field | Usage | How to Obtain |
|-------|-------|---------------|
| `FORGEJO_SIGNING_PRIVATE_KEY` | SSH signing key (ed25519 private) for commit signing | `ssh-keygen -t ed25519 -f signing -N ""` → contents of `signing` |
| `FORGEJO_SIGNING_PUBLIC_KEY` | SSH signing key (ed25519 public) | Contents of `signing.pub` from above |
| `FORGEJO_OIDC_CLIENT_ID` | Authentik OAuth2 Client ID | From Authentik provider settings |
| `FORGEJO_OIDC_CLIENT_SECRET` | Authentik OAuth2 Client Secret | From Authentik provider settings |
| `FORGEJO_RUNNER_TOKEN` | Registration token for the CI runner | Forgejo Admin → Actions → Runners → Create new runner |

### Generated Kubernetes Secrets

| Secret Name | Used By | Keys |
|-------------|---------|------|
| `forgejo` | Forgejo app (signing keys) | `signing_private_key`, `signing_public_key` |
| `forgejo-oidc` | Forgejo app (OAuth) | `key`, `secret` |
| `forgejo-runner-secret` | Forgejo runner | `token` |

## Storage

- **PVC**: `forgejo` (10Gi, OpenEBS hostpath)
- **Backup**: VolSync (configured via component)
- **Contents**: Git repositories, LFS objects, app data

## CI/CD Runner

The CI/CD runner is deployed as a StatefulSet (`replicas: 1`) using the official Forgejo runner (`code.forgejo.org/forgejo/runner`) and a Docker-in-Docker (`docker:dind`) sidecar.

### Architecture

- **Runner Daemon:** Official `forgejo-runner` running rootless (`runAsUser: 1000`), polling the Forgejo instance and communicating with the DinD sidecar over `tcp://127.0.0.1:2375`.
- **Docker-in-Docker Sidecar:** Privileged `docker:dind` container managing the container lifecycle and executing job containers using the `overlayfs` driver on Talos Linux.
- **Shared Storage:** Ephemeral `/data` volume mounted to both runner and DinD sidecar so job workspaces are visible to the Docker daemon for bind mounts.

### Runner Labels

| Label | Execution Type | Container Image |
|-------|----------------|-----------------|
| `ubuntu-latest` | docker | `node:20-bookworm` |
| `ubuntu-24.04` | docker | `node:20-bookworm` |
| `default` | docker | `node:20-bookworm` |
| `docker` | docker | `node:20-bookworm` |
| `dind` | docker | `docker:dind` |

### Runner Resources

- DinD container: 100m CPU request, 256Mi memory request (4Gi memory limit)
- Runner daemon: 5m CPU request, 64Mi memory request (512Mi memory limit)
- Runner capacity: 2 concurrent jobs

## Dependencies

- `bitwarden` ClusterSecretStore — secret management
- `envoy-external` Gateway — ingress (HTTP + SSH)
- `authentik` — identity provider

## Flux Kustomizations

| Name | Path | Depends On |
|------|------|------------|
| `forgejo` | `./kubernetes/apps/development/forgejo/app` | — |
| `forgejo-runner` | `./kubernetes/apps/development/forgejo/runner` | — |

Both deploy to the `dev` namespace.
