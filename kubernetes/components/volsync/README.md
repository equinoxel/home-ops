# volsync component

Kustomize component that provisions [VolSync](https://volsync.readthedocs.io/) backup resources for an application's PVC.

## Requirements

- [VolSync](https://volsync.readthedocs.io/) operator installed in the cluster
- [External Secrets](https://external-secrets.io/) operator with a `ClusterSecretStore` named `bitwarden`
- Two secrets in Bitwarden:
  - `volsync_template` — used by the `local` backend (filesystem/Kopia), must contain `KOPIA_PASSWORD`
  - `volsync_s3_template` — used by the `remote` backend (S3/Kopia), must contain `KOPIA_PASSWORD`, `AWS_S3_ENDPOINT`, `REPOSITORY_TEMPLATE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

## What it creates

| Resource | Description |
|---|---|
| `PersistentVolumeClaim/${APP}` | App PVC, restored from `ReplicationDestination` on first apply |
| `ReplicationSource/${APP}` | Local Kopia backup every 2 hours to a filesystem repository |
| `ReplicationSource/${APP}-s3` | Remote Kopia backup daily at 00:30 to S3 |
| `ReplicationDestination/${APP}-dst` | One-shot restore trigger (SSA: IfNotPresent) |
| `ExternalSecret/${APP}-volsync` | Pulls local repo credentials from Bitwarden |
| `ExternalSecret/${APP}-volsync-s3` | Pulls S3 credentials from Bitwarden |

## Usage

Add the component to a Flux `Kustomization` via `components` and set `APP` at minimum via `postBuild.substitute`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
  namespace: default
spec:
  path: ./kubernetes/apps/default/myapp/app
  # ...
  postBuild:
    substitute:
      APP: myapp
      VOLSYNC_CAPACITY: 10Gi        # default: 5Gi
  components:
    - ../../../../components/volsync
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `APP` | **required** | App name, used to name all resources |
| `VOLSYNC_CAPACITY` | `5Gi` | PVC and destination capacity |
| `VOLSYNC_STORAGECLASS` | `ceph-block` | StorageClass for PVC and snapshots |
| `VOLSYNC_SNAPSHOTCLASS` | `csi-ceph-blockpool` | VolumeSnapshotClass |
| `VOLSYNC_ACCESSMODES` | `ReadWriteOnce` | PVC access mode |
| `VOLSYNC_SNAP_ACCESSMODES` | `ReadWriteOnce` | Snapshot access mode |
| `VOLSYNC_CACHE_ACCESSMODES` | `ReadWriteOnce` | Cache PVC access mode |
| `VOLSYNC_CACHE_CAPACITY` | `5Gi` | Cache PVC size |
| `VOLSYNC_CACHE_STORAGECLASS` | `ceph-block` | Cache PVC StorageClass |
| `VOLSYNC_PUID` | `1000` | UID for the mover pod |
| `VOLSYNC_PGID` | `1000` | GID for the mover pod |
| `VOLSYNC_GROUP_CHANGE_POLICY` | `Always` | fsGroupChangePolicy for the mover pod |

## Restore

The `ReplicationDestination` uses `ssa: IfNotPresent`, so it is only created once and won't overwrite an existing restore. To trigger a new restore, delete the `ReplicationDestination` and the PVC, then re-apply:

```sh
kubectl -n <namespace> delete replicationdestination <app>-dst
kubectl -n <namespace> delete pvc <app>
flux reconcile ks <ks-name> --with-source
```

For the full step-by-step restore procedure including scaling, monitoring, and troubleshooting, see [docs/volsync-restore-runbook.md](../../docs/volsync-restore-runbook.md).
