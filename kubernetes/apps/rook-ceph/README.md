# Rook-Ceph — Disabled

## Problem

Rook-Ceph requires either a dedicated raw block device or a StorageClass that supports `volumeMode: Block` for OSD PVCs. In the current single-node worker setup (blade-01), the only available disk is the system NVMe which hosts the Talos EPHEMERAL partition. The available StorageClass (`openebs-hostpath`) only supports `volumeMode: Filesystem`, which is incompatible with Rook's `storageClassDeviceSets`.

Additionally, the `directories` storage option (which would have allowed using a subdirectory on the EPHEMERAL partition) was removed from the CephCluster CRD in Rook v1.3+.

## Decision

Rook-Ceph is disabled. All applications that previously used the `ceph-block` StorageClass have been migrated to `openebs-hostpath`.

## Affected Applications

The following files were updated to replace `ceph-block` with `openebs-hostpath`:

- `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` — Alertmanager and Prometheus storage
- `kubernetes/apps/observability/grafana/instance/grafana.yaml` — Grafana persistent storage
- `kubernetes/components/volsync/pvc.yaml` — Default PVC StorageClass
- `kubernetes/components/volsync/local/replicationsource.yaml` — Local backup cache and storage
- `kubernetes/components/volsync/local/replicationdestination.yaml` — Local restore storage
- `kubernetes/components/volsync/remote/replicationsource.yaml` — Remote backup cache and storage

## Re-enabling Ceph

To re-enable Rook-Ceph in the future, you would need one of:

1. A dedicated raw block device on a worker node
2. A StorageClass that supports `volumeMode: Block` (e.g., OpenEBS LVM)
3. A loopback device created via Talos machine config

Then uncomment `./rook-ceph` in `kubernetes/apps/rook-ceph/kustomization.yaml` and revert the StorageClass references.
