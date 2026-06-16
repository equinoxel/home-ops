#!/usr/bin/env bash
#
# Trigger an on-demand VolSync backup for an application.
#
# Usage:
#   volsync-backup.sh <app> <type>
#
# Arguments:
#   app   - Application name (matches the ReplicationSource name)
#   type  - "nfs" (local), "s3" (remote), or "both"
#

set -euo pipefail

APP="${1:?Usage: volsync-backup.sh <app> <nfs|s3|both>}"
TYPE="${2:?Usage: volsync-backup.sh <app> <nfs|s3|both>}"

log() { echo "$(date -u '+%H:%M:%S') [volsync-backup] $*"; }
warn() { echo "$(date -u '+%H:%M:%S') [volsync-backup] WARN: $*" >&2; }
die() { echo "$(date -u '+%H:%M:%S') [volsync-backup] ERROR: $*" >&2; exit 1; }

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
# Trigger backup by annotating the ReplicationSource
# ---------------------------------------------------------------------------
trigger_backup() {
    local rs_name="$1"

    if ! kubectl get replicationsource -n "${NS}" "${rs_name}" &>/dev/null; then
        warn "ReplicationSource '${rs_name}' not found in namespace '${NS}'. Skipping."
        return 1
    fi

    log "Triggering backup for ReplicationSource '${rs_name}'..."
    kubectl annotate replicationsource -n "${NS}" "${rs_name}" \
        volsync.backube/trigger="$(date -u +%Y%m%d%H%M%S)" --overwrite

    log "Waiting for backup to complete (ReplicationSource '${rs_name}')..."
    kubectl wait replicationsource -n "${NS}" "${rs_name}" \
        --for=condition=Synchronizing=False \
        --timeout=300s

    log "Backup complete for '${rs_name}'."
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
FAILED=0

if [[ "${TYPE}" == "nfs" || "${TYPE}" == "both" ]]; then
    trigger_backup "${APP}" || FAILED=$((FAILED + 1))
fi

if [[ "${TYPE}" == "s3" || "${TYPE}" == "both" ]]; then
    trigger_backup "${APP}-s3" || FAILED=$((FAILED + 1))
fi

if [[ "${FAILED}" -gt 0 ]]; then
    die "${FAILED} backup(s) failed."
fi

log "All requested backups completed successfully."
