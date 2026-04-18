# VolSync Cache PVC Node Mismatch Runbook

Step-by-step procedure for fixing VolSync mover pods stuck in `Pending` due to cache PVCs bound to a different node than the data PVC.

## Overview

This cluster uses `openebs-hostpath` storage, which creates PersistentVolumes with node affinity — each PV is local to a specific node. VolSync mover pods need to mount both the **data PVC** and a **cache PVC** simultaneously. If these PVCs are bound to different nodes, the mover pod cannot schedule because a pod can only run on one node.

**Symptoms:**
- VolSync mover pods stuck in `Pending` for extended periods
- `volsync_volume_out_of_sync` alert fires for the affected app
- `ReplicationSource` status shows `Synchronization in-progress` but `lastSyncTime` is stale or missing
- Scheduler events show: `0/N nodes are available: X node(s) didn't match PersistentVolume's node affinity`

**Root cause:** The cache PVC was provisioned on a different node than the data PVC. This can happen when:
- A node was drained or unavailable when the cache PVC was first created
- The data PVC was migrated to a different node (e.g., during a restore)
- The cache PVC was created before the data PVC was bound

**Impact:** Backup data on the NFS repository is safe. Cache PVCs only hold Kopia deduplication cache, which is rebuilt automatically. Deleting them causes no data loss.

## Prerequisites

- `kubectl` access to the cluster
- The affected app's VolSync `ReplicationSource` exists

## Variables

| Placeholder | Example | Description |
|---|---|---|
| `<app>` | `pgadmin` | Application name (matches `APP` in postBuild) |
| `<namespace>` | `database` | Kubernetes namespace |

## Step 1: Confirm the diagnosis

Verify the mover pods are stuck in `Pending`:

```bash
kubectl get pods -n <namespace> | grep volsync-src-<app>
```

Check the scheduler events on one of the stuck pods:

```bash
kubectl describe pod -n <namespace> <stuck-pod-name> | tail -10
```

Look for messages like:
- `didn't match PersistentVolume's node affinity`
- `didn't match Pod's node affinity/selector`

## Step 2: Identify the node mismatch

Find which node the data PVC is on:

```bash
DATA_PV=$(kubectl get pvc -n <namespace> <app> -o jsonpath='{.spec.volumeName}')
kubectl get pv "$DATA_PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}'
```

Find which node(s) the cache PVCs are on:

```bash
for pvc in $(kubectl get pvc -n <namespace> -o name | grep volsync-src-<app>.*cache); do
  PV=$(kubectl get -n <namespace> "$pvc" -o jsonpath='{.spec.volumeName}')
  NODE=$(kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
  echo "$pvc -> $NODE"
done
```

If the cache PVCs are on a different node than the data PVC, proceed with the fix.

## Step 3: Delete the stuck mover pods

Delete the pending mover pods so the cache PVCs are released:

```bash
kubectl delete pods -n <namespace> -l volsync.backube/replicationsource=<app>
```

If the label selector doesn't match, delete them by name:

```bash
kubectl get pods -n <namespace> | grep volsync-src-<app>
kubectl delete pod -n <namespace> <pod-name-1> <pod-name-2>
```

## Step 4: Delete the misplaced cache PVCs

Delete all cache PVCs for the affected ReplicationSource(s):

```bash
kubectl delete pvc -n <namespace> volsync-src-<app>-cache
kubectl delete pvc -n <namespace> volsync-src-<app>-s3-cache  # if using remote (S3) replication
```

Verify they are gone:

```bash
kubectl get pvc -n <namespace> | grep volsync-src-<app>
```

## Step 5: Wait for VolSync to recreate

VolSync will automatically create new mover pods and cache PVCs on the next sync trigger. The cache PVCs will be provisioned on the correct node because the mover pod's `nodeSelector` constrains scheduling to the data PVC's node.

Watch for the new pods:

```bash
kubectl get pods -n <namespace> -w | grep volsync-src-<app>
```

If you don't want to wait for the next scheduled sync (cron: `0 */2 * * *`), you can trigger a manual sync by patching the trigger:

```bash
kubectl patch replicationsource -n <namespace> <app> \
  --type merge -p '{"spec":{"trigger":{"manual":"sync-'"$(date +%s)"'"}}}'
```

## Step 6: Verify the fix

Confirm the new cache PVCs are on the correct node:

```bash
for pvc in $(kubectl get pvc -n <namespace> -o name | grep volsync-src-<app>.*cache); do
  PV=$(kubectl get -n <namespace> "$pvc" -o jsonpath='{.spec.volumeName}')
  NODE=$(kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
  echo "$pvc -> $NODE"
done
```

All cache PVCs should now be on the same node as the data PVC.

Confirm the mover pods complete successfully:

```bash
# Watch for completion (pods will disappear when done)
kubectl get pods -n <namespace> -w | grep volsync-src-<app>

# Check the ReplicationSource status
kubectl get replicationsource -n <namespace> <app>
```

The `LAST SYNC` timestamp should update to the current time and the status should show `Waiting for next scheduled synchronization`.

Confirm the `volsync_volume_out_of_sync` alert resolves (may take up to 5 minutes):

```bash
kubectl exec -n observability -c prometheus svc/kube-prometheus-stack-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=volsync_volume_out_of_sync{obj_name="<app>"}' 2>/dev/null
```

The value should be `0` (in sync).

## Troubleshooting

### Cache PVC stays Pending after recreation

```bash
kubectl describe pvc -n <namespace> volsync-src-<app>-cache
```

Common causes:
- **Node is full** — The target node may not have enough disk space for the cache. Check with `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary | jq '.node.fs'`.
- **openebs-hostpath provisioner not running** — Check `kubectl get pods -n openebs`.

### Mover pod runs but sync fails

```bash
kubectl logs -n <namespace> -l volsync.backube/replicationsource=<app>
```

Common causes:
- **Kopia cache corruption** — The new empty cache is fine; Kopia rebuilds it. But if the repository itself is corrupted, check the NFS share.
- **NFS connectivity** — Verify the NFS server is reachable from the node: `kubectl run nfs-test --rm -it --image=busybox -- ping -c3 10.0.0.14`.

### Problem recurs after node drain or maintenance

If this happens repeatedly, consider pinning the cache `storageClassName` to a shared storage class (e.g., NFS) instead of `openebs-hostpath`. This would require overriding `VOLSYNC_CACHE_STORAGECLASS` in the Kustomization's `postBuild.substitute`:

```yaml
postBuild:
  substitute:
    APP: <app>
    VOLSYNC_CAPACITY: 2Gi
    VOLSYNC_CACHE_STORAGECLASS: nfs-client  # shared storage for cache
```
