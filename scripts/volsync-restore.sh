#!/usr/bin/env bash
#
# Restore an app's PVC from a VolSync/Kopia backup.
#
# Usage:
#   volsync-restore.sh <app> <type> <date|hash>
#   volsync-restore.sh <app> <type> --list-only
#
# Arguments:
#   app   - Application name (matches the ReplicationSource name)
#   type  - Backup type: "nfs" (local/fast) or "s3" (remote/slow)
#   date  - Target date in YYYY-MM-DD, YYYY-MM-DDTHH:MM:SS, or full ISO8601 format.
#           The script restores from the latest snapshot BEFORE this date.
#   hash  - A Kopia snapshot ID (hex string). Restores that exact snapshot.
#   --list-only - Just list available snapshots, don't restore
#

set -euo pipefail

APP="${1:?Usage: volsync-restore.sh <app> <nfs|s3> <date|hash|--list-only>}"
TYPE="${2:?Usage: volsync-restore.sh <app> <nfs|s3> <date|hash|--list-only>}"
DATE_OR_FLAG="${3:?Usage: volsync-restore.sh <app> <nfs|s3> <date|hash|--list-only>}"

LIST_ONLY=false
TARGET_DATE=""
TARGET_HASH=""

if [[ "${DATE_OR_FLAG}" == "--list-only" ]]; then
    LIST_ONLY=true
elif [[ "${DATE_OR_FLAG}" =~ ^[0-9a-f]{16,}$ ]]; then
    # Looks like a Kopia snapshot hash (hex string, 16+ chars)
    TARGET_HASH="${DATE_OR_FLAG}"
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

if [[ "${TYPE}" == "nfs" ]]; then
    # NFS/filesystem backend — connect using local path
    kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
        bash -c 'kopia repository connect filesystem --path=/repository --password="$KOPIA_PASSWORD" --override-hostname=volsync --override-username=root' 2>/dev/null || \
        die "Failed to connect to Kopia repository."
else
    # S3 backend — parse KOPIA_REPOSITORY URI the same way VolSync does:
    #   KOPIA_REPOSITORY=s3://bucket@host:port/prefix  or  s3://bucket/prefix
    # VolSync extracts:
    #   bucket = first segment matching [a-z0-9][a-z0-9.-]+[a-z0-9] after s3://
    #   prefix = everything after the first / following the non-slash segment (s3://[^/]+/PREFIX)
    #   endpoint = from AWS_S3_ENDPOINT env var (stripped of http(s)://)
    kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
        bash -c '
            # Extract bucket: VolSync uses regex ^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])
            if [[ "${KOPIA_REPOSITORY}" =~ ^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9]) ]]; then
                BUCKET="${BASH_REMATCH[1]}"
            else
                echo "ERROR: Cannot parse bucket from KOPIA_REPOSITORY" >&2
                exit 1
            fi

            # Extract prefix: VolSync uses regex s3://[^/]+/(.+)
            PREFIX=""
            if [[ "${KOPIA_REPOSITORY}" =~ s3://[^/]+/(.+) ]]; then
                PREFIX="${BASH_REMATCH[1]}"
                # Ensure trailing slash (VolSync does this)
                [[ "${PREFIX}" =~ /$ ]] || PREFIX="${PREFIX}/"
            fi

            # Strip protocol from endpoint
            ENDPOINT="${AWS_S3_ENDPOINT#http://}"
            ENDPOINT="${ENDPOINT#https://}"

            # Determine TLS setting
            DISABLE_TLS_FLAG=""
            if [[ "${AWS_S3_DISABLE_TLS}" == "true" ]]; then
                DISABLE_TLS_FLAG="--disable-tls"
            fi

            CMD=(kopia repository connect s3
                --bucket="$BUCKET"
                --endpoint="$ENDPOINT"
                --access-key="$AWS_ACCESS_KEY_ID"
                --secret-access-key="$AWS_SECRET_ACCESS_KEY"
                --password="$KOPIA_PASSWORD"
                --override-hostname=volsync
                --override-username=root)

            [[ -n "$PREFIX" ]] && CMD+=(--prefix="$PREFIX")
            [[ -n "$DISABLE_TLS_FLAG" ]] && CMD+=($DISABLE_TLS_FLAG)

            "${CMD[@]}"
        ' 2>/dev/null || \
        die "Failed to connect to Kopia repository."
fi

log "Listing snapshots for source '${SOURCE_NAME}'..."
SNAPSHOTS=$(kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
    kopia snapshot list --all --json 2>/dev/null || true)

if [[ -z "${SNAPSHOTS}" || "${SNAPSHOTS}" == "null" || "${SNAPSHOTS}" == "[]" ]]; then
    die "No snapshots found in the repository."
fi

# Filter snapshots for this app's source using jq (python3 not available in kopia image)
APP_SNAPSHOTS=$(echo "${SNAPSHOTS}" | \
    jq -r --arg source "${SOURCE_NAME}" --arg app "${APP}" '
        def human_size:
            if . >= 1073741824 then "\(. / 1073741824 * 10 | floor / 10) GB"
            elif . >= 1048576 then "\(. / 1048576 * 10 | floor / 10) MB"
            elif . >= 1024 then "\(. / 1024 * 10 | floor / 10) KB"
            else "\(.) B"
            end;
        [.[] | select(
            (.source.host | contains($source)) or
            (.source.host | contains($app)) or
            (.source.userName | contains($source)) or
            (.source.userName | contains($app))
        )] | sort_by(.startTime) | reverse | .[] |
        "\(.startTime)  \(.id)  \((.rootEntry.summ.size // 0) | human_size)  \(.source.host):\(.source.path)"
    ' 2>/dev/null || true)

if [[ -z "${APP_SNAPSHOTS}" ]]; then
    # Fallback: just list all snapshots
    log "Could not filter by app name. Listing all snapshots:"
    kubectl exec -n "${NS}" "${KOPIA_POD}" -- kopia snapshot list --all 2>/dev/null || true
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
# Find the target snapshot (by date or by hash)
# ---------------------------------------------------------------------------
if [[ -n "${TARGET_HASH}" ]]; then
    # Verify the hash exists in the snapshot list
    SELECTED_SNAPSHOT=$(echo "${APP_SNAPSHOTS}" | awk -v hash="${TARGET_HASH}" '$2 == hash { print $2; exit }' || true)
    if [[ -z "${SELECTED_SNAPSHOT}" ]]; then
        die "Snapshot hash '${TARGET_HASH}' not found. Available snapshots listed above."
    fi
    # Get the timestamp of the selected snapshot for the restoreAsOf field
    TARGET_DATE=$(echo "${APP_SNAPSHOTS}" | awk -v hash="${TARGET_HASH}" '$2 == hash { print $1; exit }')
    log "Selected snapshot by hash: ${SELECTED_SNAPSHOT} (${TARGET_DATE})"
else
    # Normalize date to ISO format for comparison
    if [[ "${TARGET_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        TARGET_DATE="${TARGET_DATE}T23:59:59"
    fi

    SELECTED_SNAPSHOT=$(echo "${APP_SNAPSHOTS}" | \
        awk -v target="${TARGET_DATE}" '{
            if ($1 <= target) { print $2; exit }
        }' || true)

    if [[ -z "${SELECTED_SNAPSHOT}" ]]; then
        die "No snapshot found before ${TARGET_DATE}. Available snapshots listed above."
    fi
    log "Selected snapshot: ${SELECTED_SNAPSHOT} (latest before ${TARGET_DATE})"
fi

# ---------------------------------------------------------------------------
# Perform the restore
# ---------------------------------------------------------------------------
log "Starting restore process..."

# Step 1: Suspend HelmRelease, save replica counts, and scale down
log "Suspending HelmRelease and scaling down app..."
flux suspend hr "${APP}" -n "${NS}" 2>/dev/null || true

# Save replica counts to a temp file before scaling down
REPLICAS_FILE=$(mktemp)
for kind in deployment statefulset; do
    while IFS= read -r res; do
        [[ -z "${res}" ]] && continue
        replicas=$(kubectl get "${res}" -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        echo "${res}=${replicas}" >> "${REPLICAS_FILE}"
        log "  Scaling down ${res} (was ${replicas} replicas)..."
        kubectl scale "${res}" -n "${NS}" --replicas=0 2>/dev/null || true
    done <<< "$(kubectl get "${kind}" -n "${NS}" --no-headers -o name 2>/dev/null | grep -i "${APP}" || true)"
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

# Step 3: Ensure PVC exists (don't delete it — we'll restore directly into it)
log "Verifying PVC exists..."
pvc_exists=$(kubectl get pvc -n "${NS}" "${APP}" --no-headers 2>/dev/null || true)
if [[ -z "${pvc_exists}" ]]; then
    log "PVC not found, reconciling Flux to recreate it..."
    flux reconcile ks "${APP}" -n "${NS}" --with-source 2>/dev/null || true
    sleep 10
    for i in $(seq 1 20); do
        pvc_exists=$(kubectl get pvc -n "${NS}" "${APP}" --no-headers 2>/dev/null || true)
        if [[ -n "${pvc_exists}" ]]; then
            break
        fi
        sleep 5
    done
    if [[ -z "${pvc_exists}" ]]; then
        die "PVC '${APP}' could not be created."
    fi
fi

# Step 5: Restore directly using Kopia (bypasses VolSync's restoreAsOf limitations)
log "Restoring snapshot ${SELECTED_SNAPSHOT} directly via Kopia..."

# The Kopia pod is still running from the snapshot listing phase.
# Mount the target PVC into a new pod and restore directly.
RESTORE_POD="volsync-direct-restore-${APP}-$(date +%s)"

# Build volume/mount spec — includes the app PVC as the restore target
if [[ "${TYPE}" == "nfs" ]]; then
    RESTORE_VOLUMES_JSON='[
        {"name":"repo","nfs":{"server":"10.0.0.14","path":"/mnt/Main/backup/VolsyncKopia"}},
        {"name":"data","persistentVolumeClaim":{"claimName":"'"${APP}"'"}},
        {"name":"tmp","emptyDir":{}}
    ]'
    RESTORE_MOUNTS_JSON='[
        {"name":"repo","mountPath":"/repository"},
        {"name":"data","mountPath":"/restore-target"},
        {"name":"tmp","mountPath":"/tmp"}
    ]'
else
    RESTORE_VOLUMES_JSON='[
        {"name":"data","persistentVolumeClaim":{"claimName":"'"${APP}"'"}},
        {"name":"tmp","emptyDir":{}}
    ]'
    RESTORE_MOUNTS_JSON='[
        {"name":"data","mountPath":"/restore-target"},
        {"name":"tmp","mountPath":"/tmp"}
    ]'
fi

# Clean up old kopia pod (we'll create a new one with PVC access)
kubectl delete pod "${KOPIA_POD}" -n "${NS}" --force --grace-period=0 2>/dev/null || true
sleep 3

# Create a restore pod with PVC mounted
kubectl run "${RESTORE_POD}" \
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
                \"volumeMounts\":${RESTORE_MOUNTS_JSON}
            }],
            \"volumes\":${RESTORE_VOLUMES_JSON},
            \"securityContext\":{\"runAsUser\":0,\"runAsGroup\":0,\"fsGroup\":0}
        }
    }" >/dev/null 2>&1

# Update trap to also clean up restore pod
trap "kubectl delete pod '${KOPIA_POD}' -n '${NS}' --force --grace-period=0 2>/dev/null || true; kubectl delete pod '${RESTORE_POD}' -n '${NS}' --force --grace-period=0 2>/dev/null || true" EXIT

# Wait for restore pod to be ready
log "Waiting for restore pod to start..."
for i in $(seq 1 60); do
    phase=$(kubectl get pod "${RESTORE_POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "Running" ]]; then
        break
    elif [[ "${phase}" == "Failed" || "${phase}" == "Error" ]]; then
        kubectl logs "${RESTORE_POD}" -n "${NS}" 2>/dev/null || true
        die "Restore pod failed to start."
    fi
    sleep 3
done

# Connect to the repository from the restore pod
log "Connecting to Kopia repository from restore pod..."
if [[ "${TYPE}" == "nfs" ]]; then
    kubectl exec -n "${NS}" "${RESTORE_POD}" -- \
        bash -c 'kopia repository connect filesystem --path=/repository --password="$KOPIA_PASSWORD" --override-hostname=volsync --override-username=root' 2>/dev/null || \
        die "Failed to connect to Kopia repository from restore pod."
else
    kubectl exec -n "${NS}" "${RESTORE_POD}" -- \
        bash -c '
            if [[ "${KOPIA_REPOSITORY}" =~ ^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9]) ]]; then
                BUCKET="${BASH_REMATCH[1]}"
            else
                echo "ERROR: Cannot parse bucket from KOPIA_REPOSITORY" >&2
                exit 1
            fi
            PREFIX=""
            if [[ "${KOPIA_REPOSITORY}" =~ s3://[^/]+/(.+) ]]; then
                PREFIX="${BASH_REMATCH[1]}"
                [[ "${PREFIX}" =~ /$ ]] || PREFIX="${PREFIX}/"
            fi
            ENDPOINT="${AWS_S3_ENDPOINT#http://}"
            ENDPOINT="${ENDPOINT#https://}"
            DISABLE_TLS_FLAG=""
            if [[ "${AWS_S3_DISABLE_TLS}" == "true" ]]; then
                DISABLE_TLS_FLAG="--disable-tls"
            fi
            CMD=(kopia repository connect s3
                --bucket="$BUCKET"
                --endpoint="$ENDPOINT"
                --access-key="$AWS_ACCESS_KEY_ID"
                --secret-access-key="$AWS_SECRET_ACCESS_KEY"
                --password="$KOPIA_PASSWORD"
                --override-hostname=volsync
                --override-username=root)
            [[ -n "$PREFIX" ]] && CMD+=(--prefix="$PREFIX")
            [[ -n "$DISABLE_TLS_FLAG" ]] && CMD+=($DISABLE_TLS_FLAG)
            "${CMD[@]}"
        ' 2>/dev/null || \
        die "Failed to connect to Kopia repository from restore pod."
fi

# Clear the target directory before restoring
log "Clearing restore target..."
kubectl exec -n "${NS}" "${RESTORE_POD}" -- bash -c 'rm -rf /restore-target/* /restore-target/.[!.]* 2>/dev/null; true'

# Restore the specific snapshot by ID
log "Restoring snapshot ${SELECTED_SNAPSHOT} to /restore-target..."
kubectl exec -n "${NS}" "${RESTORE_POD}" -- \
    kopia snapshot restore "${SELECTED_SNAPSHOT}" /restore-target/ --overwrite-files --overwrite-directories --overwrite-symlinks 2>&1 | tail -5

# Verify restore
RESTORED_SIZE=$(kubectl exec -n "${NS}" "${RESTORE_POD}" -- du -sh /restore-target/ 2>/dev/null | awk '{print $1}')
log "Restored data size: ${RESTORED_SIZE}"

# Fix ownership (match VolSync's mover security context)
kubectl exec -n "${NS}" "${RESTORE_POD}" -- chown -R 1000:1000 /restore-target/ 2>/dev/null || true

# Cleanup restore pod
kubectl delete pod "${RESTORE_POD}" -n "${NS}" --force --grace-period=0 2>/dev/null || true

# Step 7: Restore backup schedules, resume app, and restore replica counts
log "Restoring backup schedules..."
kubectl patch replicationsource -n "${NS}" "${APP}" --type merge \
    -p '{"spec":{"trigger":{"schedule":"0 */2 * * *"}}}' 2>/dev/null || true
kubectl patch replicationsource -n "${NS}" "${APP}-s3" --type merge \
    -p '{"spec":{"trigger":{"schedule":"30 0 * * *"}}}' 2>/dev/null || true

log "Resuming HelmRelease..."
flux resume hr "${APP}" -n "${NS}" 2>/dev/null || true

# Restore saved replica counts
log "Restoring replica counts..."
if [[ -f "${REPLICAS_FILE}" ]]; then
    while IFS='=' read -r res replicas; do
        [[ -z "${res}" ]] && continue
        replicas="${replicas:-1}"
        log "  Scaling ${res} to ${replicas} replicas..."
        kubectl scale "${res}" -n "${NS}" --replicas="${replicas}" 2>/dev/null || true
    done < "${REPLICAS_FILE}"
    rm -f "${REPLICAS_FILE}"
fi

# Force Helm to reconcile (ensures chart defaults are re-applied)
flux reconcile hr "${APP}" -n "${NS}" 2>/dev/null || true

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
