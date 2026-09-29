# papra

[Papra](https://papra.app/) is a minimalist document management and archiving platform. This deployment runs the single-container `rootless` image with a SQLite database on a VolSync-backed PVC, reachable at `https://papra.laurivan.com` through the internal Envoy gateway.

## Layout

| File | Purpose |
|---|---|
| `app.ks.yaml` | Flux Kustomization, pulls in the `volsync` component and sets `VOLSYNC_CAPACITY` |
| `app/helmrelease.yaml` | bjw-s `app-template` HelmRelease (container, service, route, persistence) |
| `app/externalsecret.yaml` | Pulls `AUTH_SECRET` and Authentik OIDC credentials from Bitwarden, and assembles the `AUTH_PROVIDERS_CUSTOMS` SSO config, into the `papra` secret |
| `app/kustomization.yaml` | Bundles the ExternalSecret and HelmRelease |

## Storage

Papra keeps its SQLite database and uploaded documents under `/app/app-data` (`db/` and `documents/`). The `volsync` component provisions a PVC named `papra` and backs it up on the standard local and S3 Kopia schedules. `VOLSYNC_CAPACITY` is set to `20Gi`; raise it in `app.ks.yaml` if the document archive grows.

## Secret

Papra reads three values from Bitwarden through the `bitwarden` `ClusterSecretStore`: the auth secret and the Authentik OIDC client credentials. Create one Bitwarden item named `papra` (matching the `dataFrom.extract.key` in `externalsecret.yaml`) carrying these fields.

Generate `AUTH_SECRET` with `openssl rand -hex 48` (at least 32 characters). Get `PAPRA_OIDC_CLIENT_ID` and `PAPRA_OIDC_CLIENT_SECRET` from the Authentik provider you create in the SSO section below. Drop this JSON into the Bitwarden item's field set:

```json
{
  "AUTH_SECRET": "<openssl rand -hex 48>",
  "PAPRA_OIDC_CLIENT_ID": "<authentik client id>",
  "PAPRA_OIDC_CLIENT_SECRET": "<authentik client secret>"
}
```

The ExternalSecret assembles these into the `papra` Kubernetes secret, including the `AUTH_PROVIDERS_CUSTOMS` JSON that wires up the Authentik login button. Rotating any value: update it in Bitwarden, let the ExternalSecret refresh, and the stakater reloader annotation restarts the pod so the new value takes effect.

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
