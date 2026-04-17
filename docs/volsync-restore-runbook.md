# VolSync Restore Runbook

Step-by-step procedure for restoring application data from a VolSync Kopia backup into a fresh PVC.

## Overview

This cluster uses VolSync with Kopia and `copyMethod: Direct` on `openebs-hostpath` storage. The restore flow is:

1. Scale down the application so nothing is using the PVC
2. Delete the existing PVC (if any) and the ReplicationDestination
3. Let Flux recreate both resources
4. Trigger the ReplicationDestination to perform the restore
5. Wait for the restore to complete
6. Scale the application back up

> **Important:** The PVC component uses `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`, meaning Flux will only create the PVC if it doesn't already exist. The ReplicationDestination uses the same policy via a label. This is why both must be deleted before Flux can recreate them.

## Prerequisites

- `kubectl` access to the cluster
- `flux` CLI installed
- The VolSync secret (`<app>-volsync-secret`) must exist and be valid
- The Kopia repository must contain at least one snapshot

## Variables

Throughout this runbook, replace these placeholders:

| Placeholder | Example | Description |
|---|---|---|
| `<app>` | `pgadmin` | Application name (matches `APP` in postBuild) |
| `<namespace>` | `database` | Kubernetes namespace |
| `<ks-name>` | `pgadmin` | Flux Kustomization name |

## Step 1: Verify backup exists

Before restoring, confirm there are snapshots available:

```bash
# Check the ReplicationSource last sync time
kubectl get replicationsource -n <namespace> <app>

# Check the secret exists
kubectl get secret -n <namespace> <app>-volsync-secret
```

The ReplicationSource should show a recent `LAST SYNC` timestamp. If it shows `<none>`, no backup has ever completed and there is nothing to restore from.

## Step 2: Scale down the application

The PVC must not be in use during the restore. Scale down the app:

```bash
# For HelmRelease-managed apps, suspend and scale
flux suspend hr -n <namespace> <app>
kubectl scale -n <namespace> deployment/<app> --replicas=0

# Wait for pods to terminate
kubectl wait -n <namespace> pod -l app.kubernetes.io/name=<app> --for=delete --timeout=60s
```

Also suspend any VolSync ReplicationSources that reference the PVC:

```bash
kubectl patch replicationsource -n <namespace> <app> --type merge -p '{"spec":{"trigger":{"schedule":""}}}'
kubectl patch replicationsource -n <namespace> <app>-s3 --type merge -p '{"spec":{"trigger":{"schedule":""}}}'
```

## Step 3: Delete the PVC and ReplicationDestination

Both resources have `ssa: IfNotPresent`, so they must be deleted for Flux to recreate them:

```bash
# Delete the ReplicationDestination first
kubectl delete replicationdestination -n <namespace> <app>-dst

# Delete the PVC
kubectl delete pvc -n <namespace> <app>

# Verify both are gone
kubectl get pvc,replicationdestination -n <namespace> | grep <app>
```

## Step 4: Recreate resources via Flux

Force Flux to reconcile, which will recreate the PVC and ReplicationDestination:

```bash
flux reconcile ks <ks-name> --with-source
```

Verify the PVC is created and bound:

```bash
kubectl get pvc -n <namespace> <app>
```

The PVC should show `Bound` status. If it stays `Pending`, check:
- The StorageClass exists: `kubectl get sc openebs-hostpath`
- The openebs provisioner is running: `kubectl get pods -n openebs`

Verify the ReplicationDestination is recreated:

```bash
kubectl get replicationdestination -n <namespace> <app>-dst
```

## Step 5: Trigger the restore

The ReplicationDestination is created with `trigger.manual: restore-once`. To trigger a new restore, patch the manual trigger to a new unique value:

```bash
kubectl patch replicationdestination -n <namespace> <app>-dst \
  --type merge \
  -p '{"spec":{"trigger":{"manual":"restore-'"$(date +%s)"'"}}}'
```

## Step 6: Monitor the restore

Watch the ReplicationDestination status:

```bash
# Watch for completion
kubectl get replicationdestination -n <namespace> <app>-dst -w

# Check mover pod logs
kubectl logs -n <namespace> -l volsync.backube/replicationdestination=<app>-dst -f
```

The restore is complete when:
- `LAST SYNC` shows a timestamp
- `DURATION` shows the elapsed time
- The mover pod completes and is cleaned up

If the restore fails, check:
- Mover pod logs for Kopia errors
- Secret `<app>-volsync-secret` has correct `KOPIA_PASSWORD`
- The Kopia repository is accessible and not corrupted

## Step 7: Resume the application

Re-enable the ReplicationSources and resume the app:

```bash
# Restore backup schedules
kubectl patch replicationsource -n <namespace> <app> --type merge -p '{"spec":{"trigger":{"schedule":"0 */2 * * *"}}}'
kubectl patch replicationsource -n <namespace> <app>-s3 --type merge -p '{"spec":{"trigger":{"schedule":"30 0 * * *"}}}'

# Resume the HelmRelease
flux resume hr -n <namespace> <app>

# Verify the app is running
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
```

## Step 8: Verify data integrity

Once the app is running, verify the restored data:

- Log into the application and check that data is present
- Check application logs for errors: `kubectl logs -n <namespace> -l app.kubernetes.io/name=<app>`
- Verify the ReplicationSource runs a successful backup after restore

## Troubleshooting

### PVC stays Pending

```bash
kubectl describe pvc -n <namespace> <app>
```

Common causes:
- **`datasource not handled by provisioner`** — The PVC still has a `dataSourceRef`. Delete it and let Flux recreate it.
- **`waiting for first consumer`** — Normal with `WaitForFirstConsumer` binding mode. The PVC will bind when a pod mounts it.
- **No available nodes** — openebs-hostpath provisions on the node where the pod is scheduled. Check node availability.

### ReplicationDestination shows no LAST SYNC after trigger

```bash
kubectl describe replicationdestination -n <namespace> <app>-dst
kubectl get pods -n <namespace> -l volsync.backube/replicationdestination=<app>-dst
```

Common causes:
- **Mover pod stuck in Pending** — Check for resource constraints or PVC issues.
- **Kopia password mismatch** — The `KOPIA_PASSWORD` in the secret must match the one used when the backup was created.
- **Empty repository** — No snapshots exist to restore from.

### Application shows empty data after restore

- Verify the restore actually completed (Step 6)
- Check that the app's data path matches the PVC mount path
- Check file ownership matches the app's UID/GID (compare `VOLSYNC_PUID`/`VOLSYNC_PGID` with the app's `securityContext`)
