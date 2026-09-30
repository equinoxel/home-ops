# papra

[Papra](https://papra.app/) is a minimalist document management and archiving platform. This deployment runs the single-container `rootless` image, stores documents in RustFS (S3) and the SQLite database on a VolSync-backed PVC, and is reachable at `https://papra.laurivan.com` through the internal Envoy gateway.

## Layout

| File | Purpose |
|---|---|
| `app.ks.yaml` | Flux Kustomization, pulls in the `volsync` component and sets `VOLSYNC_CAPACITY` |
| `app/helmrelease.yaml` | bjw-s `app-template` HelmRelease (container, service, route, persistence) |
| `app/externalsecret.yaml` | Pulls `AUTH_SECRET`, Authentik OIDC credentials, RustFS S3 credentials, and Ollama settings from Bitwarden, and assembles the `AUTH_PROVIDERS_CUSTOMS` SSO config, into the `papra` secret |
| `app/kustomization.yaml` | Bundles the ExternalSecret and HelmRelease |

## Storage

Documents go to RustFS over the S3 driver (`DOCUMENT_STORAGE_DRIVER: s3`); only the SQLite database stays on disk under `/app/app-data/db`. The `volsync` component provisions a PVC named `papra` for that database and backs it up on the standard local and S3 Kopia schedules. Because documents no longer sit on the PVC, `VOLSYNC_CAPACITY` is `5Gi`.

S3 settings live in `app/helmrelease.yaml` (driver, region `auto`, and `DOCUMENT_STORAGE_S3_FORCE_PATH_STYLE: "true"`, which RustFS requires) and `app/externalsecret.yaml` (endpoint, bucket, credentials). The bucket is `papra`. Credentials and endpoint are the shared RustFS values reused from the Bitwarden `cloudnative_pg` item, the same ones Postgres and MariaDB back up with.

Prerequisite: the `papra` bucket must exist in RustFS before Papra starts writing. Papra's S3 driver does not create it. Create it once with `mc`, using the shared RustFS credentials:

```bash
mc alias set rustfs http://192.168.2.44:30292 <access-key> <secret-key>
mc mb --ignore-existing rustfs/papra
```

Backups are now split: the SQLite database is covered by VolSync on the PVC, and document blobs live in the RustFS `papra` bucket (back that bucket up on the RustFS side if you want document redundancy).

## Secret

Papra reads several values from Bitwarden through the `bitwarden` `ClusterSecretStore`. Two Bitwarden items are involved:

- `papra` (matching `dataFrom.extract.key` in `externalsecret.yaml`): the auth secret, the Authentik OIDC client credentials, and the Ollama fields.
- `cloudnative_pg` (already present, reused): the shared RustFS S3 access key, secret key, and endpoint.

Generate `AUTH_SECRET` with `openssl rand -hex 48` (at least 32 characters). Get `PAPRA_OIDC_CLIENT_ID` and `PAPRA_OIDC_CLIENT_SECRET` from the Authentik provider you create in the SSO section below. The Ollama fields are placeholders until you enable AI (see the AI section). Drop this JSON into the `papra` item's field set:

```json
{
  "AUTH_SECRET": "<openssl rand -hex 48>",
  "PAPRA_OIDC_CLIENT_ID": "<authentik client id>",
  "PAPRA_OIDC_CLIENT_SECRET": "<authentik client secret>",
  "OLLAMA_API_KEY": "ollama",
  "OLLAMA_BASE_URL": "http://<ollama-host>:11434/v1"
}
```

The ExternalSecret assembles these into the `papra` Kubernetes secret, including the `AUTH_PROVIDERS_CUSTOMS` JSON that wires up the Authentik login button and the S3 credentials. Rotating any value: update it in Bitwarden, let the ExternalSecret refresh, and the stakater reloader annotation restarts the pod so the new value takes effect.

## SSO via Authentik

Papra's OAuth support is [better-auth generic OAuth](https://www.better-auth.com/docs/plugins/generic-oauth). It reads the `AUTH_PROVIDERS_CUSTOMS` env var, a JSON array of providers. This repo builds that array in `app/externalsecret.yaml`: the non-secret parts (provider id `authentik`, display name, discovery URL, scopes) are pinned in the manifest, and only the client id and secret come from Bitwarden.

### Create the Authentik provider and application

In the Authentik admin UI at `https://auth.laurivan.com`:

1. Create an OAuth2/OpenID Provider:
   - Authorization flow: your default explicit-consent (or implicit) flow.
   - Client type: `Confidential`.
   - Redirect URI (strict match): `https://papra.laurivan.com/api/auth/oauth2/callback/authentik`
   - Signing key: your default certificate.
   - Copy the generated Client ID and Client Secret.
2. Create an Application:
   - Slug: `papra` (this must match the slug in the discovery URL below).
   - Provider: the provider from step 1.
3. Confirm the discovery URL resolves: `https://auth.laurivan.com/application/o/papra/.well-known/openid-configuration`

The `:providerId` segment of Papra's callback path is `authentik` because that is the `providerId` set in `AUTH_PROVIDERS_CUSTOMS`. The Authentik application slug is `papra`, which is what appears in the discovery URL. Keep both as-is or change them together in `app/externalsecret.yaml`.

### Provider config (for reference)

The ExternalSecret template produces this `AUTH_PROVIDERS_CUSTOMS` value once Bitwarden fills the placeholders:

```json
[
  {
    "providerId": "authentik",
    "providerName": "Authentik",
    "providerIconUrl": "https://api.iconify.design/simple-icons:authentik.svg",
    "type": "oidc",
    "discoveryUrl": "https://auth.laurivan.com/application/o/papra/.well-known/openid-configuration",
    "clientId": "<from Bitwarden PAPRA_OIDC_CLIENT_ID>",
    "clientSecret": "<from Bitwarden PAPRA_OIDC_CLIENT_SECRET>",
    "scopes": ["openid", "profile", "email"]
  }
]
```

After the secret and application exist, reconcile and the Papra sign-in page shows an "Authentik" button.

## Registration

Password signup is disabled by default (`AUTH_IS_REGISTRATION_ENABLED: "false"`), so SSO is the intended login path. The first user to sign in through Authentik gets no special role automatically; promote them to admin from within Papra (or set `AUTH_FIRST_USER_AS_ADMIN` in `app/helmrelease.yaml` before the first login). To allow local password accounts instead, flip `AUTH_IS_REGISTRATION_ENABLED` to `"true"`, register, then set it back to `"false"` and reconcile.

## AI (Ollama)

Papra can auto-tag and analyze documents with an LLM through its [OpenAI-compatible adapters](https://docs.papra.app/guides/llm-configuration). Ollama is a built-in adapter. This is wired up but disabled, since there is no Ollama endpoint in the cluster yet.

What is already set in `app/helmrelease.yaml`:

- `AI_IS_ENABLED: "false"` (master switch, off).
- `AUTO_TAGGING_ENABLED: "true"` (the auto-tag feature; still gated by the master switch).
- `AI_DEFAULT_MODEL: ollama://qwen3:8b` (model nomenclature is `<adapter>://<model>`).

The Ollama connection settings come from the `papra` secret via `app/externalsecret.yaml`:

- `OLLAMA_API_KEY`: Ollama ignores auth, so the literal `ollama` is a fine placeholder.
- `OLLAMA_BASE_URL`: must point at the Ollama endpoint and keep the `/v1` suffix, e.g. `http://ollama.<namespace>.svc.cluster.local:11434/v1`.

To turn it on once an Ollama instance exists:

1. Set `OLLAMA_BASE_URL` (and pull the model, e.g. `ollama pull qwen3:8b`) in the `papra` Bitwarden item.
2. Flip `AI_IS_ENABLED` to `"true"` in `app/helmrelease.yaml`.
3. Adjust `AI_DEFAULT_MODEL` if you run a different model. Per-feature overrides exist too (`AUTO_TAGGING_MODEL` takes precedence over `AI_DEFAULT_MODEL`).
4. Reconcile. Auto-tagging also has to be enabled per organization in Papra's settings.
