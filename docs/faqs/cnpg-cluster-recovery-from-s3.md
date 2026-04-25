# CNPG Cluster Recovery from S3 Backup

## Problem

The `postgres-cluster` Flux Kustomization is stuck with a `Failed` health check. The CNPG Cluster reports `ClusterIsNotReady` and the condition `ConsistentSystemID` shows "No instances are present in the cluster to report a system ID."

The pod is stuck in `Init:0/2` with a `FailedMount` event:

```
MountVolume.NewMounter initialization failed for volume "pvc-...":
  path "/var/mnt/local-hostpath/pvc-..." does not exist
```

The PVC may be stuck in `Terminating` state, bound to a PV whose backing path on the node was deleted or lost (common with `openebs-hostpath` when a node is rebuilt or storage is wiped).

## Root Cause

The `openebs-hostpath` PV stores data at a local path on the node. If that path is removed (node rebuild, disk failure, manual cleanup), the PV becomes unmountable. The PVC may get stuck in `Terminating` due to its finalizer, and CNPG cannot start the postgres instance.

## Resolution

### 1. Clear the stuck PVC (if still Terminating)

```bash
kubectl patch pvc postgres-cluster-1 -n database \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

If the PVC is already gone, skip this step.

### 2. Delete the existing pod (if stuck)

```bash
kubectl delete pod postgres-cluster-1 -n database
```

### 3. Switch bootstrap to recovery mode

In `kubernetes/apps/database/cnpg/cluster/cluster.yaml`, change the bootstrap section:

```yaml
  bootstrap:
    # To reinitialize from scratch, switch back to initdb mode:
    # initdb:
    #   database: app
    #   owner: app
    recovery:
      source: source
```

The `externalClusters` section already defines the `source` pointing to the barman-cloud S3 backup.

### 4. Delete the CNPG Cluster resource

Bootstrap only runs on initial creation — changing the field on an existing Cluster has no effect. You must delete and let Flux recreate it:

```bash
kubectl delete cluster postgres-cluster -n database
```

### 5. Commit, push, and reconcile

```bash
git add kubernetes/apps/database/cnpg/cluster/cluster.yaml
git commit -m "fix(cnpg): switch bootstrap to s3 recovery mode"
git push

flux reconcile source git flux-system
flux reconcile kustomization postgres-cluster -n database
```

### 6. Monitor recovery

```bash
# Watch the recovery job and pod
kubectl get pods -n database -l cnpg.io/cluster=postgres-cluster -w

# Check cluster status
kubectl get cluster -n database
```

The recovery job (`postgres-cluster-1-full-recovery-*`) will download the base backup from S3 and replay WAL segments. Once complete, the primary pod starts and the cluster transitions to `Cluster in healthy state`.

### 7. Switch bootstrap back to initdb

After recovery succeeds, revert the bootstrap to `initdb` so future Flux reconciliations don't accidentally trigger another recovery:

```yaml
  bootstrap:
    # To restore from backup, switch to recovery mode:
    # recovery:
    #   source: source
    initdb:
      database: app
      owner: app
```

Commit and push:

```bash
git add kubernetes/apps/database/cnpg/cluster/cluster.yaml
git commit -m "fix(cnpg): switch bootstrap back to initdb after successful recovery"
git push
```

## Verification

```bash
# Cluster healthy
kubectl get cluster -n database
# NAME               INSTANCES   READY   STATUS                     PRIMARY
# postgres-cluster   1           1       Cluster in healthy state   postgres-cluster-1

# Flux Kustomization reconciled
kubectl get kustomization postgres-cluster -n database
# READY   True

# Downstream apps (authentik, grafana, immich, etc.) should recover automatically
```

## Prerequisites

- The `barman-cloud` plugin must be installed and the `ObjectStore` resource configured
- The S3 credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) must be present in the `cluster-cnpg-secret`
- Continuous archiving must have been working before the failure (`ContinuousArchiving: True`)
