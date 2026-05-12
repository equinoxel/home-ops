#!/usr/bin/env bash
#
# Restore an app's PVC from a VolSync/Kopia backup taken before a given date.
#
# Usage:
#   volsync-restore.sh <app> <type> <date>
#   volsync-restore.sh <app> <type> --list-only
#
# Arguments:
#   app   - Application name (matches the ReplicationSource name)
#   type  - Backup type: "nfs" (local/fast) or "s3" (remote/slow)
#   date  - Target date in YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS format
#           The script restores from the latest snapshot BEFORE this date.
#   --list-only - Just list available snapshots, don't restore
#

set -euo pipefail

APP="${1:?Usage: volsync-restore.sh <app> <nfs|s3> <date|--list-only>}"
TYPE="${2:?Usage: volsync-restore.sh <app> <nfs|s3> <date|--list-only>}"
DATE_OR_FLAG="${3:?Usage: volsync-restore.sh <app> <nfs|s3> <date|--list-only>}"

LIST_ONLY=false
if [[ "${DATE_OR_FLAG}" == "--list-only" ]]; then
    LIST_ONLY=true
    TARGET_DATE=""
else
    TARGET_DATE="${DATE_OR_FLAG}"
fi

log() { echo "$(date -u '+%H:%M:%S') [volsync-restore] $*"; }
warn() { echo "$(date -u '+%H:%M:%S') [volsync-restore] WARN: $*" >&2; }
die() { echo "$(date -u '+%H:%M:%S') [volsync-restore] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Determine namespace from Flux kustomization
# ---------------------------------------------------------------------------
NS=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
    -o jsonpath="{.items[?(@.metadata.name==\"${APP}\")].metadata.namespace}" 2>/dev/null || true)
if [[ -z "${NS}" ]]; then
    die "Flux kustomization '${APP}' not found. Cannot determine namespace."
fi
log "App=${APP} Namespace=${NS} Type=${TYPE}"

# ---------------------------------------------------------------------------
# Determine the secret and source name based on type
# ---------------------------------------------------------------------------
if [[ "${TYPE}" == "nfs" ]]; then
    SECRET_NAME="${APP}-volsync-secret"
    SOURCE_NAME="${APP}"
    DST_NAME="${APP}-dst"
elif [[ "${TYPE}" == "s3" ]]; then
    SECRET_NAME="${APP}-volsync-s3-secret"
    SOURCE_NAME="${APP}-s3"
    DST_NAME="${APP}-dst"
else
    die "TYPE must be 'nfs' or 's3', got '${TYPE}'"
fi

# ---------------------------------------------------------------------------
# Verify the secret exists
# ---------------------------------------------------------------------------
if ! kubectl get secret -n "${NS}" "${SECRET_NAME}" &>/dev/null; then
    die "Secret '${SECRET_NAME}' not found in namespace '${NS}'. Cannot access Kopia repository."
fi

# ---------------------------------------------------------------------------
# Launch a temporary Kopia pod to list/find snapshots
# ---------------------------------------------------------------------------
KOPIA_POD="volsync-restore-kopia-${APP}-$(date +%s)"
KOPIA_IMAGE="ghcr.io/home-operations/kopia:0.22.3"

log "Launching temporary Kopia pod to query snapshots..."

# Build volume/mount spec based on type
if [[ "${TYPE}" == "nfs" ]]; then
    VOLUMES_JSON='[
        {"name":"repo","nfs":{"server":"10.0.0.14","path":"/mnt/Main/backup/VolsyncKopia"}},
        {"name":"tmp","emptyDir":{}}
    ]'
    VOLUME_MOUNTS_JSON='[
        {"name":"repo","mountPath":"/repository"},
        {"name":"tmp","mountPath":"/tmp"}
    ]'
else
    VOLUMES_JSON='[{"name":"tmp","emptyDir":{}}]'
    VOLUME_MOUNTS_JSON='[{"name":"tmp","mountPath":"/tmp"}]'
fi

# Create the pod
kubectl run "${KOPIA_POD}" \
    --image="${KOPIA_IMAGE}" \
    --restart=Never \
    --namespace="${NS}" \
    --env="KOPIA_CHECK_FOR_UPDATES=false" \
    --overrides="{
        \"spec\":{
            \"containers\":[{
                \"name\":\"kopia\",
                \"image\":\"${KOPIA_IMAGE}\",
                \"command\":[\"sleep\",\"3600\"],
                \"envFrom\":[{\"secretRef\":{\"name\":\"${SECRET_NAME}\"}}],
                \"volumeMounts\":${VOLUME_MOUNTS_JSON}
            }],
            \"volumes\":${VOLUMES_JSON},
            \"securityContext\":{\"runAsUser\":65534,\"runAsGroup\":1000,\"fsGroup\":1000}
        }
    }" >/dev/null 2>&1

# Wait for pod to be ready
log "Waiting for Kopia pod to start..."
for i in $(seq 1 30); do
    phase=$(kubectl get pod "${KOPIA_POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "Running" ]]; then
        break
    elif [[ "${phase}" == "Failed" || "${phase}" == "Error" ]]; then
        kubectl logs "${KOPIA_POD}" -n "${NS}" 2>/dev/null || true
        kubectl delete pod "${KOPIA_POD}" -n "${NS}" --force 2>/dev/null || true
        die "Kopia pod failed to start."
    fi
    sleep 2
done

# Cleanup function
cleanup_kopia_pod() {
    kubectl delete pod "${KOPIA_POD}" -n "${NS}" --force --grace-period=0 2>/dev/null || true
}
trap cleanup_kopia_pod EXIT

# ---------------------------------------------------------------------------
# Connect to the repository and list snapshots
# ---------------------------------------------------------------------------
log "Connecting to Kopia repository..."
kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
    kopia repository connect from-config --file=/tmp/repository.config 2>/dev/null || \
kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
    sh -c 'kopia repository connect $KOPIA_REPOSITORY --password="$KOPIA_PASSWORD" --override-hostname=volsync --override-username=root' 2>/dev/null || \
    die "Failed to connect to Kopia repository."

log "Listing snapshots for source '${SOURCE_NAME}'..."
SNAPSHOTS=$(kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
    kopia snapshot list --json 2>/dev/null || true)

if [[ -z "${SNAPSHOTS}" || "${SNAPSHOTS}" == "null" || "${SNAPSHOTS}" == "[]" ]]; then
    die "No snapshots found in the repository."
fi

# Filter snapshots for this app's source
# VolSync uses source name as the path identifier
APP_SNAPSHOTS=$(echo "${SNAPSHOTS}" | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
# Filter by source tag matching our app
results = []
for snap in data:
    source = snap.get('source', {})
    tags = snap.get('tags', {})
    # VolSync sets the source tag or uses the hostname
    hostname = source.get('host', '')
    username = source.get('userName', '')
    path = source.get('path', '')
    desc = snap.get('description', '')
    snap_id = snap.get('id', '')
    start_time = snap.get('startTime', '')
    # Match by hostname containing the app name or source name
    if '${SOURCE_NAME}' in hostname or '${APP}' in hostname or '${APP}' in path or '${APP}' in desc:
        results.append({'id': snap_id, 'time': start_time, 'host': hostname, 'path': path})
# Sort by time descending
results.sort(key=lambda x: x['time'], reverse=True)
for r in results:
    print(f\"{r['time']}  {r['id']}  {r['host']}:{r['path']}\")
" 2>/dev/null || true)

if [[ -z "${APP_SNAPSHOTS}" ]]; then
    # Fallback: just list all snapshots
    log "Could not filter by app name. Listing all snapshots:"
    kubectl exec -n "${NS}" "${KOPIA_POD}" -- kopia snapshot list 2>/dev/null || true
    die "No snapshots found matching '${APP}'. Check the output above."
fi

echo ""
echo "=== Available snapshots for ${APP} (${TYPE}) ==="
echo "${APP_SNAPSHOTS}"
echo ""

if [[ "${LIST_ONLY}" == "true" ]]; then
    log "List-only mode. Exiting."
    exit 0
fi

# ---------------------------------------------------------------------------
# Find the latest snapshot before TARGET_DATE
# ---------------------------------------------------------------------------
# Normalize date to ISO format for comparison
if [[ "${TARGET_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    TARGET_DATE="${TARGET_DATE}T23:59:59"
fi

SELECTED_SNAPSHOT=$(echo "${APP_SNAPSHOTS}" | \
    python3 -c "
import sys
target = '${TARGET_DATE}'
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 2:
        snap_time = parts[0]
        snap_id = parts[1]
        # Compare lexicographically (ISO dates sort correctly)
        if snap_time <= target:
            print(snap_id)
            break
" 2>/dev/null || true)

if [[ -z "${SELECTED_SNAPSHOT}" ]]; then
    die "No snapshot found before ${TARGET_DATE}. Available snapshots listed above."
fi

log "Selected snapshot: ${SELECTED_SNAPSHOT} (latest before ${TARGET_DATE})"

# ---------------------------------------------------------------------------
# Perform the restore
# ---------------------------------------------------------------------------
log "Starting restore process..."

# Step 1: Suspend HelmRelease and scale down
log "Suspending HelmRelease and scaling down app..."
flux suspend hr "${APP}" -n "${NS}" 2>/dev/null || true

for kind in deployment statefulset; do
    resources=$(kubectl get "${kind}" -n "${NS}" --no-headers -o name 2>/dev/null | grep -i "${APP}" || true)
    if [[ -n "${resources}" ]]; then
        echo "${resources}" | while read -r res; do
            log "  Scaling down ${res}..."
            kubectl scale "${res}" -n "${NS}" --replicas=0 2>/dev/null || true
        done
    fi
done

# Wait for pods to terminate
log "Waiting for app pods to terminate..."
for i in $(seq 1 30); do
    app_pods=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null \
        | grep -i "${APP}" | grep -v volsync | grep -v dst | grep -v "${KOPIA_POD}" || true)
    if [[ -z "${app_pods}" ]]; then
        break
    fi
    sleep 3
done

# Step 2: Suspend backup schedules
log "Suspending backup schedules..."
kubectl patch replicationsource -n "${NS}" "${APP}" --type merge \
    -p '{"spec":{"trigger":{"schedule":""}}}' 2>/dev/null || true
kubectl patch replicationsource -n "${NS}" "${APP}-s3" --type merge \
    -p '{"spec":{"trigger":{"schedule":""}}}' 2>/dev/null || true

# Step 3: Delete ReplicationDestination and PVC
log "Deleting ReplicationDestination and PVC..."
kubectl delete replicationdestination -n "${NS}" "${DST_NAME}" --wait=false 2>/dev/null || true
kubectl delete pvc -n "${NS}" "${APP}" --wait=false 2>/dev/null || true

# Wait for deletion
for i in $(seq 1 20); do
    pvc_exists=$(kubectl get pvc -n "${NS}" "${APP}" --no-headers 2>/dev/null || true)
    dst_exists=$(kubectl get replicationdestination -n "${NS}" "${DST_NAME}" --no-headers 2>/dev/null || true)
    if [[ -z "${pvc_exists}" && -z "${dst_exists}" ]]; then
        break
    fi
    sleep 3
done

# Step 4: Reconcile Flux to recreate PVC and ReplicationDestination
log "Reconciling Flux to recreate resources..."
flux reconcile ks "${APP}" -n "${NS}" --with-source 2>/dev/null || true
sleep 10

# Wait for PVC and ReplicationDestination to appear
for i in $(seq 1 20); do
    pvc_exists=$(kubectl get pvc -n "${NS}" "${APP}" --no-headers 2>/dev/null || true)
    dst_exists=$(kubectl get replicationdestination -n "${NS}" "${DST_NAME}" --no-headers 2>/dev/null || true)
    if [[ -n "${pvc_exists}" && -n "${dst_exists}" ]]; then
        break
    fi
    sleep 5
done

# Step 5: Trigger restore with the specific snapshot
TRIGGER="restore-${SELECTED_SNAPSHOT}-$(date +%s)"
log "Triggering restore from snapshot ${SELECTED_SNAPSHOT}..."
kubectl patch replicationdestination "${DST_NAME}" -n "${NS}" \
    --type merge \
    -p "{\"spec\":{\"trigger\":{\"manual\":\"${TRIGGER}\"},\"kopia\":{\"restoreAsOf\":\"${TARGET_DATE}\"}}}" 2>/dev/null || \
kubectl patch replicationdestination "${DST_NAME}" -n "${NS}" \
    --type merge \
    -p "{\"spec\":{\"trigger\":{\"manual\":\"${TRIGGER}\"}}}"

# Step 6: Wait for restore to complete
log "Waiting for restore to complete..."
for i in $(seq 1 60); do
    last_sync=$(kubectl get replicationdestination "${DST_NAME}" -n "${NS}" \
        -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || true)

    if [[ -n "${last_sync}" ]]; then
        duration=$(kubectl get replicationdestination "${DST_NAME}" -n "${NS}" \
            -o jsonpath='{.status.lastSyncDuration}' 2>/dev/null || true)
        log "Restore complete! lastSync=${last_sync} duration=${duration}"
        break
    fi

    mover=$(kubectl get pods -n "${NS}" -l "volsync.backube/replicationdestination=${DST_NAME}" \
        --no-headers -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' 2>/dev/null || true)
    if [[ -n "${mover}" ]]; then
        log "  Restore in progress: ${mover} (${i}/60)"
    else
        log "  Waiting for restore mover... (${i}/60)"
    fi
    sleep 10
done

# Step 7: Restore backup schedules and resume app
log "Restoring backup schedules..."
kubectl patch replicationsource -n "${NS}" "${APP}" --type merge \
    -p '{"spec":{"trigger":{"schedule":"0 */2 * * *"}}}' 2>/dev/null || true
kubectl patch replicationsource -n "${NS}" "${APP}-s3" --type merge \
    -p '{"spec":{"trigger":{"schedule":"30 0 * * *"}}}' 2>/dev/null || true

log "Resuming HelmRelease..."
flux resume hr "${APP}" -n "${NS}" 2>/dev/null || true

# Step 8: Wait for app to come back
log "Waiting for app to start..."
for i in $(seq 1 30); do
    pods=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null \
        | grep -i "${APP}" | grep -v volsync | grep -v "${KOPIA_POD}" || true)
    if [[ -n "${pods}" ]]; then
        running=$(echo "${pods}" | grep -c 'Running' || true)
        total=$(echo "${pods}" | wc -l)
        if [[ "${running}" -eq "${total}" && "${total}" -gt 0 ]]; then
            log "App is running."
            break
        fi
    fi
    sleep 5
done

echo ""
log "=== Restore complete for ${APP} (${TYPE}) ==="
log "Restored to: latest snapshot before ${TARGET_DATE}"
kubectl get pods -n "${NS}" --no-headers 2>/dev/null | grep -i "${APP}" | grep -v "${KOPIA_POD}" || true
echo ""
kubectl get pvc -n "${NS}" --no-headers 2>/dev/null | grep -i "${APP}" || true
