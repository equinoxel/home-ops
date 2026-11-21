# Jellyfin

[Jellyfin](https://jellyfin.org/) is a free and open-source media streaming server designed to organize and stream video, audio, and photos to client devices.

## Architecture

- **Namespace**: `media`
- **Controller**: Single replica Deployment managed via `app-template` Helm chart
- **Port**: `8096` (HTTP)
- **Ingress Route**: Exposed on the internal Envoy Gateway (`envoy-internal`) at [https://jelly.laurivan.com](https://jelly.laurivan.com)
- **Homepage Integration**: Automatically discovered under the `Media` group via Gateway API `HTTPRoute` annotations

## Storage & NFS Mounts

- **Config (`/config`)**: PersistentVolumeClaim `jellyfin` (20Gi) backed by OpenEBS LocalPV with automated VolSync local and remote (S3) Kopia snapshot backups.
- **Cache (`/cache`)**: Transient `emptyDir` for transcode buffering and temporary cache.
- **Media (`/media`)**: NFS share mounted from TrueNAS:
  - Host: `192.168.2.44`
  - Share path: `/mnt/Main/shares/video`
  - Target container path: `/media`
- **Music (`/music`)**: NFS share mounted from TrueNAS:
  - Host: `192.168.2.44`
  - Share path: `/mnt/Main/shares/audio/music`
  - Target container path: `/music` (read-only)

## Authentication

Jellyfin uses **native user management**.
- No external OAuth/SSO (e.g. Authentik forward-auth) is enforced on `jelly.laurivan.com`, allowing official Jellyfin apps (web, iOS, Android, TV clients) to authenticate directly against the server.
- Upon first launch, navigate to [https://jelly.laurivan.com](https://jelly.laurivan.com) and follow the initial startup setup wizard to create the primary administrator account and configure media libraries.

## Backup & Recovery

Config persistence is protected by VolSync:
- Local snapshot backup schedule: `0 */2 * * *` (every 2 hours)
- Remote S3 backup schedule: `30 0 * * *` (daily)
- Secrets are auto-provisioned via ExternalSecrets from Bitwarden (`volsync_template` and `volsync_s3_template`).
