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

> [!NOTE]
> **Status:** Inactive (`replicas: 0`). Scaled down because no CI/CD pipelines are currently active.

### Architecture & Current State

1. **Custom `k8spod` Executor Deprecation**:
   - The initial configuration utilized an unmaintained personal fork (`git.erwanleboucher.dev/eleboucher/runner`) that added a custom `k8spod:` schema to spawn Kubernetes pods per job. That registry is defunct.
   - The official runner (`code.forgejo.org/forgejo/runner`) does not support the `k8spod:` schema; it expects standard `docker://<image>` or `host` schemas.
2. **Talos Linux DinD Verification**:
   - Docker-in-Docker (`docker:dind`) with privileged mode and the `overlay2` storage driver was verified fully functional on the cluster's Talos Linux nodes (kernel 6.18, cgroups v2).
3. **Re-enabling the Runner**:
   - To activate the runner when pipelines are needed:
     1. Generate a new runner registration token:
        ```bash
        kubectl --kubeconfig kubeconfig exec -n development deploy/forgejo -c forgejo -- \
          gitea --config /data/gitea/conf/app.ini --work-path /data actions generate-runner-token
        ```
     2. Update the `FORGEJO_RUNNER_TOKEN` field in Bitwarden (item: `forgejo`).
     3. Deploy the runner with a `docker:dind` sidecar and standard Docker labels (e.g. `ubuntu-latest:docker://node:20-bookworm` or `ghcr.io/catthehacker/ubuntu:act-latest`).
     4. Set `replicas: 1` in [`kubernetes/apps/development/forgejo/runner/helmrelease.yaml`](file:///home/laur/dev/talos/home-ops/kubernetes/apps/development/forgejo/runner/helmrelease.yaml).

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
