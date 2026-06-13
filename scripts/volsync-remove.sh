#!/usr/bin/env bash
#
# Remove VolSync/Kopia snapshots AFTER a given timestamp from both NFS and S3.
#
# Usage:
#   volsync-remove.sh <app> <timestamp>
#   volsync-remove.sh <app> <timestamp> --dry-run
#
# Arguments:
#   app       - Application name (matches the ReplicationSource name)
#   timestamp - Cutoff in YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS format.
#               Snapshots strictly AFTER this timestamp will be removed.
#   --dry-run - List what would be removed without actually deleting
#
# The script removes matching snapshots from BOTH NFS and S3 repositories.
#

set -euo pipefail

APP="${1:?Usage: volsync-remove.sh <app> <timestamp> [--dry-run]}"
TIMESTAMP="${2:?Usage: volsync-remove.sh <app> <timestamp> [--dry-run]}"
DRY_RUN="${3:-}"

if [[ "${DRY_RUN}" == "--dry-run" ]]; then
    DRY_RUN=true
else
    DRY_RUN=false
fi

log() { echo "$(date -u '+%H:%M:%S') [volsync-remove] $*"; }
warn() { echo "$(date -u '+%H:%M:%S') [volsync-remove] WARN: $*" >&2; }
die() { echo "$(date -u '+%H:%M:%S') [volsync-remove] ERROR: $*" >&2; exit 1; }

# Normalize timestamp for comparison
if [[ "${TIMESTAMP}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    CUTOFF="${TIMESTAMP}T23:59:59"
else
    CUTOFF="${TIMESTAMP}"
fi

# ---------------------------------------------------------------------------
# Determine namespace from Flux kustomization
# ---------------------------------------------------------------------------
NS=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
    -o jsonpath="{.items[?(@.metadata.name==\"${APP}\")].metadata.namespace}" 2>/dev/null || true)
if [[ -z "${NS}" ]]; then
    die "Flux kustomization '${APP}' not found. Cannot determine namespace."
fi
log "App=${APP} Namespace=${NS} Cutoff=${CUTOFF} (snapshots AFTER this will be removed)"

KOPIA_IMAGE="ghcr.io/home-operations/kopia:0.22.3"
KOPIA_POD="volsync-remove-kopia-${APP}-$(date +%s)"

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup_kopia_pod() {
    kubectl delete pod "${KOPIA_POD}" -n "${NS}" --force --grace-period=0 2>/dev/null || true
}
trap cleanup_kopia_pod EXIT

# ---------------------------------------------------------------------------
# Helper: launch kopia pod for a given type (nfs or s3)
# ---------------------------------------------------------------------------
launch_kopia_pod() {
    local type="$1"
    local secret_name

    if [[ "${type}" == "nfs" ]]; then
        secret_name="${APP}-volsync-secret"
    else
        secret_name="${APP}-volsync-s3-secret"
    fi

    # Check if the secret exists
    if ! kubectl get secret -n "${NS}" "${secret_name}" &>/dev/null; then
        warn "Secret '${secret_name}' not found in namespace '${NS}'. Skipping ${type}."
        return 1
    fi

    # Build volume/mount spec
    local volumes_json volume_mounts_json
    if [[ "${type}" == "nfs" ]]; then
        volumes_json='[
            {"name":"repo","nfs":{"server":"10.0.0.14","path":"/mnt/Main/backup/VolsyncKopia"}},
            {"name":"tmp","emptyDir":{}}
        ]'
        volume_mounts_json='[
            {"name":"repo","mountPath":"/repository"},
            {"name":"tmp","mountPath":"/tmp"}
        ]'
    else
        volumes_json='[{"name":"tmp","emptyDir":{}}]'
        volume_mounts_json='[{"name":"tmp","mountPath":"/tmp"}]'
    fi

    # Delete any existing pod
    kubectl delete pod "${KOPIA_POD}" -n "${NS}" --force --grace-period=0 2>/dev/null || true
    sleep 2

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
                    \"envFrom\":[{\"secretRef\":{\"name\":\"${secret_name}\"}}],
                    \"volumeMounts\":${volume_mounts_json}
                }],
                \"volumes\":${volumes_json},
                \"securityContext\":{\"runAsUser\":65534,\"runAsGroup\":1000,\"fsGroup\":1000}
            }
        }" >/dev/null 2>&1

    # Wait for pod to be ready
    for i in $(seq 1 30); do
        phase=$(kubectl get pod "${KOPIA_POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "${phase}" == "Running" ]]; then
            return 0
        elif [[ "${phase}" == "Failed" || "${phase}" == "Error" ]]; then
            kubectl logs "${KOPIA_POD}" -n "${NS}" 2>/dev/null || true
            kubectl delete pod "${KOPIA_POD}" -n "${NS}" --force 2>/dev/null || true
            warn "Kopia pod failed to start for ${type}."
            return 1
        fi
        sleep 2
    done
    warn "Kopia pod timed out for ${type}."
    return 1
}

# ---------------------------------------------------------------------------
# Helper: connect to kopia repository
# ---------------------------------------------------------------------------
connect_kopia() {
    local type="$1"

    if [[ "${type}" == "nfs" ]]; then
        kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
            bash -c 'kopia repository connect filesystem --path=/repository --password="$KOPIA_PASSWORD" --override-hostname=volsync --override-username=root' 2>/dev/null
    else
        kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
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
            ' 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Helper: list and remove snapshots after cutoff
# ---------------------------------------------------------------------------
process_snapshots() {
    local type="$1"
    local source_name

    if [[ "${type}" == "nfs" ]]; then
        source_name="${APP}"
    else
        source_name="${APP}-s3"
    fi

    log "Listing snapshots for ${APP} (${type})..."
    local snapshots
    snapshots=$(kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
        kopia snapshot list --all --json 2>/dev/null || true)

    if [[ -z "${snapshots}" || "${snapshots}" == "null" || "${snapshots}" == "[]" ]]; then
        warn "No snapshots found in ${type} repository."
        return 0
    fi

    # Find snapshot IDs that are strictly AFTER the cutoff
    local to_remove
    to_remove=$(echo "${snapshots}" | jq -r --arg cutoff "${CUTOFF}" --arg source "${source_name}" --arg app "${APP}" '
        [.[] | select(
            ((.source.host | contains($source)) or
             (.source.host | contains($app)) or
             (.source.userName | contains($source)) or
             (.source.userName | contains($app)))
            and (.startTime > $cutoff)
        )] | sort_by(.startTime) | .[] |
        "\(.startTime)  \(.id)  \(.source.host):\(.source.path)"
    ' 2>/dev/null || true)

    if [[ -z "${to_remove}" ]]; then
        log "No snapshots found after ${CUTOFF} in ${type} repository."
        return 0
    fi

    local count
    count=$(echo "${to_remove}" | wc -l)

    echo ""
    echo "=== Snapshots to REMOVE from ${type} (${count} total) ==="
    echo "${to_remove}"
    echo ""

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would remove ${count} snapshot(s) from ${type}. No changes made."
        return 0
    fi

    # Extract just the IDs and delete them
    local ids
    ids=$(echo "${to_remove}" | awk '{print $2}')

    local removed=0
    local failed=0
    while IFS= read -r snap_id; do
        if kubectl exec -n "${NS}" "${KOPIA_POD}" -- \
            kopia snapshot delete "${snap_id}" --delete 2>/dev/null; then
            ((removed++))
        else
            warn "Failed to delete snapshot ${snap_id}"
            ((failed++))
        fi
    done <<< "${ids}"

    log "Removed ${removed} snapshot(s) from ${type}. Failed: ${failed}."
}

# ---------------------------------------------------------------------------
# Main: process both NFS and S3
# ---------------------------------------------------------------------------
TOTAL_ERRORS=0

for TYPE in nfs s3; do
    log "--- Processing ${TYPE} backend ---"

    if ! launch_kopia_pod "${TYPE}"; then
        warn "Skipping ${TYPE} (could not launch pod)."
        ((TOTAL_ERRORS++))
        continue
    fi

    if ! connect_kopia "${TYPE}"; then
        warn "Failed to connect to ${TYPE} repository. Skipping."
        ((TOTAL_ERRORS++))
        continue
    fi

    process_snapshots "${TYPE}"

    # Disconnect and clean up pod for next iteration
    kubectl exec -n "${NS}" "${KOPIA_POD}" -- kopia repository disconnect 2>/dev/null || true
    kubectl delete pod "${KOPIA_POD}" -n "${NS}" --force --grace-period=0 2>/dev/null || true
    sleep 2
done

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
    log "=== DRY-RUN complete. No snapshots were deleted. ==="
else
    log "=== Removal complete for ${APP} (both NFS and S3) ==="
fi

if [[ ${TOTAL_ERRORS} -gt 0 ]]; then
    warn "${TOTAL_ERRORS} backend(s) had errors. Check output above."
    exit 1
fi
