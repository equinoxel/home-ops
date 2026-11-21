# WatchState

[WatchState](https://github.com/arabcoders/watchstate) is a self-hosted sync tool designed to synchronize play progress and watch state across media backends (Plex, Jellyfin, and Emby) without relying on third-party cloud services.

## Architecture

- **Namespace**: `media`
- **Controller**: Single-replica Deployment managed via the `app-template` Helm chart
- **Port**: `8080` (HTTP)
- **Ingress Route**: Exposed on the internal Envoy Gateway (`envoy-internal` in `network-system`) at [https://watchstate.laurivan.com](https://watchstate.laurivan.com)
- **Homepage Integration**: Automatically discovered under the `Media` group via Gateway API `HTTPRoute` annotations (`gethomepage.dev/enabled: "true"`, `gethomepage.dev/icon: watchstate.png`)

## Storage & Persistence

- **Config (`/config`)**: PersistentVolumeClaim `watchstate` (5Gi) backed by OpenEBS LocalPV (`openebs-hostpath`). Stores the SQLite database, configuration files, backend tokens, and logs.
- **VolSync Integration**: Automated local snapshots (`0 */2 * * *`) and remote S3 backups (`30 0 * * *`) with Kopia repository secrets auto-extracted from Bitwarden.
- **Temporary Storage (`/tmp`)**: Mounted as `emptyDir`.

## Initial Setup & First Access

1. Open [https://watchstate.laurivan.com](https://watchstate.laurivan.com) in your browser.
2. On first launch, follow the on-screen prompt to create the initial admin user credentials.

## Configuring Plex & Jellyfin Sync

WatchState syncs play state and progress between your media servers:

1. **Add Jellyfin**:
   - Navigate to **Backends** > **Add Backend**.
   - Select **Jellyfin**.
   - Enter your internal Jellyfin endpoint (e.g. `http://jellyfin.media.svc.cluster.local:8096` or `https://jelly.laurivan.com`) and generate/provide an API key from Jellyfin's Dashboard.
   - Map the corresponding user account.
2. **Add Plex**:
   - Navigate to **Backends** > **Add Backend**.
   - Select **Plex**.
   - Provide the Plex server URL and authentication token (X-Plex-Token).
   - Map the corresponding user account.
3. **Configure Sync Direction**:
   - Under **Backends**, toggle **Import** (pulls watch state from the backend into WatchState) and **Export** (pushes watch state from WatchState to the backend) according to your desired flow (e.g. two-way sync with both enabled).
4. **Enable Scheduled Sync or Webhooks**:
   - Under **Tasks**, enable the scheduled `Import` and `Export` tasks for automated periodic synchronization.
   - Optionally configure webhook notifications from Plex/Jellyfin for instant real-time synchronization.

## Backup & Recovery

Persistence is protected by VolSync:
- Local snapshot backup schedule: `0 */2 * * *` (every 2 hours)
- Remote S3 backup schedule: `30 0 * * *` (daily)
- Secrets are auto-provisioned via ExternalSecrets from Bitwarden (`volsync_template` and `volsync_s3_template`).
