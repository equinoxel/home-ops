# Anubis Component

[Anubis](https://github.com/TecharoHQ/anubis) is a proof-of-work bot protection reverse proxy. It sits in front of a web application and challenges visitors with a lightweight computational puzzle before forwarding traffic to the upstream service. Legitimate browsers solve the challenge transparently; automated scrapers and bots are blocked.

## What it does

- Presents a JavaScript proof-of-work challenge to incoming HTTP requests
- Forwards verified traffic to the configured `TARGET` backend
- Ships with built-in bot detection policies (Git clients, Docker clients, RSS readers, etc.)
- Exposes Prometheus metrics on a dedicated port
- Serves a `robots.txt` to discourage well-behaved crawlers

## Integration

This is a Kustomize **component**. Add it to any app's `Kustomization` that needs bot protection:

```yaml
# app.ks.yaml
spec:
  components:
    - ../../../../components/anubis
  postBuild:
    substitute:
      ANUBIS_TARGET: http://<app-service>.<namespace>.svc.cluster.local:<port>
      # Optional overrides:
      # ANUBIS_DIFFICULTY: "4"        # PoW difficulty (default: 4)
      # ANUBIS_MEM_LIMIT: "256Mi"     # Memory limit (default: 256Mi)
```

Then point your HTTPRoute (or Ingress) backend to the Anubis service instead of the app service directly:

```yaml
backendRefs:
  - name: <app>-anubis
    port: 8080
```

### Substitution variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP` | yes | — | Application name (used to name all resources) |
| `ANUBIS_TARGET` | yes | — | Full URL of the upstream service to proxy to |
| `ANUBIS_DIFFICULTY` | no | `4` | Proof-of-work difficulty (higher = harder challenge) |
| `ANUBIS_MEM_LIMIT` | no | `256Mi` | Container memory limit |

## Secrets

The component requires one Bitwarden secret item named **`anubis`** with the following field:

| Field | Description |
|-------|-------------|
| `ED25519_PRIVATE_KEY_HEX` | Hex-encoded Ed25519 private key used to sign challenge tokens |

The ExternalSecret creates a Kubernetes secret named `${APP}-anubis-key-secret` from this Bitwarden item.

### Generating the private key

```bash
openssl genpkey -algorithm ED25519 -outform DER | tail -c 32 | xxd -p -c 64
```

This produces a 64-character hex string. Store it in Bitwarden as the `ED25519_PRIVATE_KEY_HEX` field of the `anubis` item.

Alternatively, using Python:

```bash
python3 -c "from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey; print(Ed25519PrivateKey.generate().private_bytes_raw().hex())"
```

## Architecture

```
Internet → HTTPRoute → Anubis (:8080) → Target app
                         ↓
                    Metrics (:9090) → ServiceMonitor → Prometheus
```

## Files

| File | Purpose |
|------|---------|
| `helmrelease.yaml` | App-template HelmRelease defining the Anubis container, policy ConfigMap, and service |
| `externalsecret.yaml` | Pulls the Ed25519 signing key from Bitwarden |
| `ocirepository.yaml` | Points to the bjw-s app-template Helm chart |
| `kustomization.yaml` | Kustomize Component manifest |
