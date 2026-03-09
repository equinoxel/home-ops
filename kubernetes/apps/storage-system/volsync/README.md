# volsync

Installs the [VolSync](https://volsync.readthedocs.io/) operator and its supporting infrastructure: a Kopia UI for browsing repositories, and scheduled maintenance jobs.

## Components

### `app` (volsync operator)

Deploys the VolSync HelmRelease using the [perfectra1n fork](https://github.com/perfectra1n/volsync) which adds NFS mover support.

Two `MutatingAdmissionPolicy` resources are applied to all VolSync mover jobs:

- `volsync-mover-jitter` — adds a 0–30s random sleep init container to `volsync-src-*` jobs to spread backup load
- `volsync-mover-nfs` — mounts `nas.servers.internal:/backups/VolsyncKopia` at `/repository` on any mover job that doesn't already have a `repository` volume (used by the `local` backend)

Depends on: `keda`

### `kopia` (repository browser)

Deploys two [Kopia](https://kopia.io/) server instances for browsing backup repositories:

| Instance | Repository | URL | Replicas |
|---|---|---|---|
| `kopia` | NFS (`nas.servers.internal:/backups/VolsyncKopia`) | `kopia.laurivan.com` | 1 |
| `kopia-s3` | S3 (credentials from Bitwarden) | `kopia-s3.laurivan.com` | 0 (scale up manually) |

Both are exposed via the `envoy-internal` gateway with ext-auth.

Secrets pulled from Bitwarden:
- `volsync_template` → `kopia` secret (`KOPIA_PASSWORD`)
- `volsync_s3_template` + `kopia_s3` → `kopia-s3` secret (`KOPIA_PASSWORD`, S3 `repository.config`)

### `maintenance`

Runs `KopiaMaintenance` jobs on a schedule to compact and garbage-collect both repositories:

| Resource | Repository | Schedule |
|---|---|---|
| `nfs` | NFS filesystem | `30 3,15 * * *` (twice daily) |
| `s3` | S3 | `30 3 * * */2` (every 2 days) |

A `MutatingAdmissionPolicy` (`kopia-maintenance-nfs`) patches NFS maintenance jobs to mount the NFS share and allow `runAsUser: 0` (required for NFS access).

Secrets pulled from Bitwarden:
- `volsync_template` → `volsync-nfs-maintenance-secret`
- `volsync_s3_template` → `volsync-s3-maintenance-secret`

## Bitwarden secrets required

### `volsync_template`

Used by: NFS `ReplicationSource`/`ReplicationDestination`, `kopia` UI, NFS maintenance.

```json
{
  "KOPIA_PASSWORD": "<strong-passphrase>"
}
```

### `volsync_s3_template`

Used by: S3 `ReplicationSource`, `kopia-s3` UI, S3 maintenance.

`REPOSITORY_TEMPLATE` is the Kopia S3 repository URI passed as `KOPIA_REPOSITORY` to mover pods.

```json
{
  "KOPIA_PASSWORD": "<strong-passphrase>",
  "AWS_S3_ENDPOINT": "http://10.0.0.14:30186",
  "REPOSITORY_TEMPLATE": "s3://volsync@10.0.0.14:30188/<bucket-name>",
  "AWS_ACCESS_KEY_ID": "<garage-access-key-id>",
  "AWS_SECRET_ACCESS_KEY": "<garage-secret-access-key>"
}
```

### `kopia_s3`

Used by: `kopia-s3` UI only (builds the `repository.config` file).

```json
{
  "KOPIA_PASSWORD": "<strong-passphrase>",
  "BUCKET": "<bucket-name>",
  "S3_ENDPOINT": "http://10.0.0.14:30188",
  "AWS_ACCESS_KEY_ID": "<garage-access-key-id>",
  "AWS_SECRET_ACCESS_KEY": "<garage-secret-access-key>"
}
```
