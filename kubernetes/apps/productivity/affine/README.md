# AFFiNE & AFFiNE MCP Server

Self-hosted knowledge base and workspace combining documents, whiteboards, and multimodal AI capabilities, accessible at [https://affine.laurivan.com](https://affine.laurivan.com).

Also includes a companion **Model Context Protocol (MCP)** server at [https://affine-mcp.laurivan.com](https://affine-mcp.laurivan.com) to allow AI agents (Claude Desktop, Cursor, Antigravity) to query and manage workspaces and documents over MCP.

---

## Architecture

```mermaid
graph LR
    subgraph External
        User[User / Browser]
        AIAgent[AI Agent / Claude / Cursor]
    end

    subgraph "Cluster (productivity namespace)"
        subgraph "AFFiNE App"
            Migration["InitContainer: migration<br/>(self-host-predeploy.js)"]
            Affine["AFFiNE Server<br/>(:3010)"]
            AffinePVC["PVC: affine<br/>(5Gi, OpenEBS hostpath)"]
        end

        subgraph "AFFiNE MCP"
            MCP["AFFiNE MCP Server<br/>(:3000, HTTP transport)"]
        end
    end

    subgraph "Cluster Shared Services"
        CNPG["CloudNativePG (PostgreSQL)<br/>postgres-cluster-rw.database.svc"]
        Dragonfly["Dragonfly (Redis)<br/>via dfguard sidecar tunnel"]
        VolSync["VolSync<br/>(backup to S3/Kopia)"]
        Envoy["Envoy Gateway<br/>(envoy-internal)"]
    end

    subgraph "External Providers"
        Authentik["Authentik OIDC<br/>auth.laurivan.com"]
        Bitwarden["Bitwarden Secrets Manager<br/>(BWS)"]
    end

    User -->|HTTPS| Envoy -->|proxy :3010| Affine
    AIAgent -->|HTTPS Bearer Token| Envoy -->|proxy :3000| MCP
    MCP -->|HTTP internal :3010| Affine

    Affine -->|mTLS :5432| CNPG
    Affine -->|localhost:6379 tunnel| Dragonfly
    Affine --> AffinePVC
    Affine -->|OIDC / OAuth| Authentik

    VolSync -.->|backup| AffinePVC
    Bitwarden -.->|ExternalSecret| Affine
    Bitwarden -.->|ExternalSecret| MCP
```

---

## Components

| Component | Image | Purpose |
|:---|:---|:---|
| **AFFiNE Server** | `ghcr.io/toeverything/affine:stable` | Primary collaborative workspace application (docs, whiteboards, tables) |
| **AFFiNE MCP Server** | `ghcr.io/dawncr0w/affine-mcp-server:latest` | Model Context Protocol adapter enabling AI assistants to interact with AFFiNE via HTTP |
| **PostgreSQL** | CloudNativePG (`postgres-cluster`) | Relational database backend with vector extensions (`vchord`, `vector`) |
| **Dragonfly** | Dragonfly (`dfguard` tunnel) | Redis-compatible distributed cache and session store |
| **VolSync** | VolSync (`openebs-hostpath`) | Continuous volume snapshots and offsite backups |

---

## Endpoints

| Service | Protocol | Hostname | Gateway | Port | Auth Mode |
|:---|:---|:---|:---|:---|:---|
| **AFFiNE Web UI & API** | HTTPS | `affine.laurivan.com` | envoy-internal | 443 -> 3010 | Authentik OIDC / Email login |
| **AFFiNE MCP Server** | HTTPS | `affine-mcp.laurivan.com` | envoy-internal | 443 -> 3000 | Bearer token (`AFFINE_MCP_HTTP_TOKEN`) |

---

## Authentication & Authentik SSO (OIDC)

AFFiNE integrates with **Authentik** via OpenID Connect (OIDC).

* **Issuer URL:** `https://auth.laurivan.com/application/o/affine/`
* **Redirect URI:** `https://affine.laurivan.com/oauth/callback`
* **Scopes:** `openid profile email`

### Authentik Setup Instructions

1. Log into your Authentik Admin interface at [https://auth.laurivan.com](https://auth.laurivan.com).
2. Go to **Applications -> Providers** and click **Create**:
   * **Type:** `OAuth2/OpenID Provider`
   * **Name:** `AFFiNE`
   * **Client type:** `Confidential`
   * **Client ID:** *(Copy to Bitwarden `AFFINE_OIDC_CLIENT_ID`)*
   * **Client Secret:** *(Copy to Bitwarden `AFFINE_OIDC_CLIENT_SECRET`)*
   * **Redirect URIs:** `https://affine.laurivan.com/oauth/callback`
   * **Signing Key:** Select your Authentik signing certificate
   * **Scopes:** Ensure `openid`, `profile`, and `email` are selected
   * **Subject mode:** `Based on the User's Email` (or username)
3. Go to **Applications -> Applications** and click **Create**:
   * **Name:** `AFFiNE`
   * **Slug:** `affine`
   * **Provider:** Select the `AFFiNE` provider created in the previous step
   * **Launch URL:** `https://affine.laurivan.com`

---

## Secrets Management (Bitwarden)

Secrets are synchronized directly from **Bitwarden Secrets Manager (BWS)** using the External Secrets Operator (`ClusterSecretStore: bitwarden`).

### 1. Item: `affine`

Create a secret in Bitwarden named **`affine`** containing the following JSON payload:

```json
{
  "AFFINE_ADMIN_EMAIL": "laur@laurivan.com",
  "AFFINE_ADMIN_PASSWORD": "<generate-secure-admin-password>",
  "AFFINE_SERVER_EXTERNAL_URL": "https://affine.laurivan.com",
  "AFFINE_OIDC_CLIENT_ID": "<client-id-from-authentik>",
  "AFFINE_OIDC_CLIENT_SECRET": "<client-secret-from-authentik>",
  "AFFINE_OIDC_ISSUER": "https://auth.laurivan.com/application/o/affine/"
}
```

*The ExternalSecret automatically compiles this data into `/root/.affine/config/config.json` inside the container.*

### 2. Item: `affine-mcp`

Create a second secret in Bitwarden named **`affine-mcp`** containing the following JSON payload:

```json
{
  "AFFINE_EMAIL": "laur@laurivan.com",
  "AFFINE_PASSWORD": "<password-matching-affine-account>",
  "AFFINE_MCP_HTTP_TOKEN": "<generate-a-strong-secret-token-for-mcp-clients>"
}
```

---

## Connecting AI Clients to AFFiNE MCP

To configure Claude Desktop, Cursor, Antigravity, or other MCP clients to interact with your AFFiNE server:

```json
{
  "mcpServers": {
    "affine": {
      "url": "https://affine-mcp.laurivan.com/mcp",
      "headers": {
        "Authorization": "Bearer <YOUR_AFFINE_MCP_HTTP_TOKEN>"
      }
    }
  }
}
```

---

## Flux Kustomizations

| Name | Path | Depends On |
|:---|:---|:---|
| `affine` | `./kubernetes/apps/productivity/affine/app` | `postgres-cluster`, `dragonfly-cluster`, `volsync` |
| `affine-mcp` | `./kubernetes/apps/productivity/affine/mcp` | `affine` |
