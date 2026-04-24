#!/usr/bin/env bash
#
# Reinitialize a Flux-managed application with VolSync restore.
#
# Suspends the Flux kustomization, deletes all resources it owns,
# resumes the kustomization, triggers a VolSync restore from backup,
# waits for the restore to complete, then scales the app back up.
#
# Usage: reinit-app.sh <app-name> [namespace]
#
# If namespace is omitted, the script discovers it from the Flux kustomization.
#

set -euo pipefail

APP="${1:?Usage: reinit-app.sh <app-name> [namespace]}"
NS="${2:-}"

log() { echo "$(date -u '+%H:%M:%S') [reinit] $*"; }
warn() { echo "$(date -u '+%H:%M:%S') [reinit] WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Discover namespace if not provided
# ---------------------------------------------------------------------------
if [[ -z "${NS}" ]]; then
    NS=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
        -o jsonpath="{.items[?(@.metadata.name==\"${APP}\")].metadata.namespace}" 2>/dev/null)
    if [[ -z "${NS}" ]]; then
        echo "ERROR: Flux kustomization '${APP}' not found in any namespace." >&2
        echo "Available kustomizations:" >&2
        kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers \
            -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' >&2
        exit 1
    fi
fi

log "Reinitializing app=${APP} namespace=${NS}"

# ---------------------------------------------------------------------------
# Step 1: Suspend the Flux kustomization
# ---------------------------------------------------------------------------
log "Suspending Flux kustomization ${APP}..."
flux suspend ks "${APP}" -n "${NS}"

# ---------------------------------------------------------------------------
# Step 2: Delete owned resources
# ---------------------------------------------------------------------------

# Delete pods labeled with the app name (common label conventions)
log "Deleting pods..."
for label in "app.kubernetes.io/name=${APP}" "app=${APP}" "app.kubernetes.io/instance=${APP}"; do
    pods=$(kubectl get pods -n "${NS}" -l "${label}" --no-headers -o name 2>/dev/null || true)
    if [[ -n "${pods}" ]]; then
        log "  Found pods with label ${label}"
        kubectl delete pods -n "${NS}" -l "${label}" --force --grace-period=0 2>/dev/null || true
    fi
done

# Also delete any pods still stuck (Terminating, etc.) — including volsync movers
remaining=$(kubectl get pods -n "${NS}" --no-headers -o name 2>/dev/null | grep -i "${APP}" || true)
if [[ -n "${remaining}" ]]; then
    log "  Force-deleting remaining pods matching '${APP}'..."
    echo "${remaining}" | xargs -r kubectl delete -n "${NS}" --force --grace-period=0 2>/dev/null || true
fi

# Delete HelmReleases
hr=$(kubectl get helmrelease -n "${NS}" "${APP}" --no-headers -o name 2>/dev/null || true)
if [[ -n "${hr}" ]]; then
    log "Deleting HelmRelease ${APP}..."
    kubectl delete helmrelease -n "${NS}" "${APP}" --wait=false 2>/dev/null || true
fi

# Delete PVCs matching the app name
log "Deleting PVCs..."
pvcs=$(kubectl get pvc -n "${NS}" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep -i "${APP}" || true)
if [[ -n "${pvcs}" ]]; then
    for pvc in ${pvcs}; do
        log "  Deleting PVC ${pvc}..."
        kubectl patch pvc "${pvc}" -n "${NS}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete pvc "${pvc}" -n "${NS}" --wait=false 2>/dev/null || true
    done
fi

# Delete VolSync resources
log "Deleting VolSync resources..."
for kind in replicationsource replicationdestination; do
    resources=$(kubectl get "${kind}" -n "${NS}" --no-headers -o name 2>/dev/null | grep -i "${APP}" || true)
    if [[ -n "${resources}" ]]; then
        echo "${resources}" | while read -r res; do
            log "  Deleting ${res}..."
            kubectl delete "${res}" -n "${NS}" --wait=false 2>/dev/null || true
        done
    fi
done

# Delete stale PVs
log "Cleaning up stale PVs..."
stale_pvs=$(kubectl get pv --no-headers -o custom-columns='NAME:.metadata.name,CLAIM:.spec.claimRef.name,NS:.spec.claimRef.namespace,STATUS:.status.phase' 2>/dev/null \
    | grep -i "${APP}" | grep "${NS}" | grep -E 'Released|Failed' | awk '{print $1}' || true)
if [[ -n "${stale_pvs}" ]]; then
    for pv in ${stale_pvs}; do
        log "  Deleting stale PV ${pv}..."
        kubectl delete pv "${pv}" 2>/dev/null || true
    done
fi

log "Waiting for cleanup to settle..."
sleep 5

# ---------------------------------------------------------------------------
# Step 3: Resume and reconcile (creates PVC, ReplicationDestination, app)
# ---------------------------------------------------------------------------
log "Resuming Flux kustomization ${APP}..."
flux resume ks "${APP}" -n "${NS}"

log "Reconciling..."
flux reconcile ks "${APP}" -n "${NS}" --with-source

# ---------------------------------------------------------------------------
# Step 4: VolSync restore
# ---------------------------------------------------------------------------
DST="${APP}-dst"
has_volsync=$(kubectl get replicationdestination -n "${NS}" "${DST}" --no-headers -o name 2>/dev/null || true)

if [[ -n "${has_volsync}" ]]; then
    log "VolSync ReplicationDestination found — triggering restore..."

    # Scale down the app so it doesn't mount the PVC during restore
    log "Scaling down app to free PVC for restore..."
    hr_exists=$(kubectl get helmrelease -n "${NS}" "${APP}" --no-headers -o name 2>/dev/null || true)
    if [[ -n "${hr_exists}" ]]; then
        # Suspend the HelmRelease so Flux doesn't fight us
        flux suspend hr "${APP}" -n "${NS}" 2>/dev/null || true
    fi

    # Scale down deployments/statefulsets matching the app
    for kind in deployment statefulset; do
        resources=$(kubectl get "${kind}" -n "${NS}" --no-headers -o name 2>/dev/null | grep -i "${APP}" || true)
        if [[ -n "${resources}" ]]; then
            echo "${resources}" | while read -r res; do
                log "  Scaling down ${res}..."
                kubectl scale "${res}" -n "${NS}" --replicas=0 2>/dev/null || true
            done
        fi
    done

    # Wait for app pods to terminate
    log "Waiting for app pods to terminate..."
    for i in $(seq 1 30); do
        app_pods=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null \
            | grep -i "${APP}" | grep -v volsync | grep -v dst || true)
        if [[ -z "${app_pods}" ]]; then
            log "  App pods terminated."
            break
        fi
        log "  Still waiting... (attempt ${i}/30)"
        sleep 5
    done

    # Trigger the restore with a unique manual trigger value
    TRIGGER="restore-$(date +%s)"
    log "Patching ReplicationDestination trigger to '${TRIGGER}'..."
    kubectl patch replicationdestination "${DST}" -n "${NS}" \
        --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"${TRIGGER}\"}}}"

    # Wait for the restore to complete
    log "Waiting for VolSync restore to complete..."
    for i in $(seq 1 60); do
        # Check for mover pod
        mover=$(kubectl get pods -n "${NS}" -l "volsync.backube/replicationdestination=${DST}" \
            --no-headers -o custom-columns='NAME:.metadata.name,STATUS:.status.phase' 2>/dev/null || true)

        # Check lastSyncTime on the destination
        last_sync=$(kubectl get replicationdestination "${DST}" -n "${NS}" \
            -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || true)

        if [[ -n "${last_sync}" ]]; then
            log "  Restore complete! lastSyncTime=${last_sync}"
            break
        fi

        if [[ -n "${mover}" ]]; then
            log "  Restore in progress: ${mover} (attempt ${i}/60)"
        else
            log "  Waiting for restore mover pod... (attempt ${i}/60)"
        fi
        sleep 10
    done

    # Check if restore actually succeeded
    last_sync=$(kubectl get replicationdestination "${DST}" -n "${NS}" \
        -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || true)
    if [[ -z "${last_sync}" ]]; then
        warn "Restore may not have completed. Check manually:"
        warn "  kubectl get replicationdestination ${DST} -n ${NS}"
        warn "  kubectl logs -n ${NS} -l volsync.backube/replicationdestination=${DST}"
    fi

    # Scale the app back up
    log "Scaling app back up..."
    if [[ -n "${hr_exists}" ]]; then
        flux resume hr "${APP}" -n "${NS}" 2>/dev/null || true
    fi
    for kind in deployment statefulset; do
        resources=$(kubectl get "${kind}" -n "${NS}" --no-headers -o name 2>/dev/null | grep -i "${APP}" || true)
        if [[ -n "${resources}" ]]; then
            echo "${resources}" | while read -r res; do
                log "  Scaling up ${res}..."
                kubectl scale "${res}" -n "${NS}" --replicas=1 2>/dev/null || true
            done
        fi
    done
else
    log "No VolSync ReplicationDestination found — skipping restore."
    log "App will start with an empty PVC."
fi

# ---------------------------------------------------------------------------
# Step 5: Force-sync ExternalSecrets for the app
# ---------------------------------------------------------------------------
log "Checking for ExternalSecrets to force-sync..."
ext_secrets=$(kubectl get externalsecret -n "${NS}" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep -i "${APP}" || true)
if [[ -n "${ext_secrets}" ]]; then
    for es in ${ext_secrets}; do
        log "  Force-syncing ExternalSecret ${es}..."
        kubectl annotate externalsecret "${es}" -n "${NS}" force-sync="$(date +%s)" --overwrite 2>/dev/null || true
    done
    log "Waiting for ExternalSecrets to sync..."
    sleep 5
else
    log "No ExternalSecrets found for ${APP} in ${NS}."
fi

# ---------------------------------------------------------------------------
# Step 6: Wait for health
# ---------------------------------------------------------------------------
log "Waiting for pods to come up..."
for i in $(seq 1 30); do
    pods=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null | grep -i "${APP}" | grep -v volsync || true)
    if [[ -n "${pods}" ]]; then
        running=$(echo "${pods}" | grep -c 'Running' || true)
        total=$(echo "${pods}" | wc -l)
        log "  Pods: ${running}/${total} running (attempt ${i}/30)"
        if [[ "${running}" -eq "${total}" && "${total}" -gt 0 ]]; then
            log "All pods running."
            break
        fi
    else
        log "  No pods found yet (attempt ${i}/30)"
    fi
    sleep 10
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log "=== Reinit complete for ${APP} in ${NS} ==="
kubectl get pods -n "${NS}" --no-headers 2>/dev/null | grep -i "${APP}" || log "No pods found for ${APP}"
echo ""
kubectl get pvc -n "${NS}" --no-headers 2>/dev/null | grep -i "${APP}" || log "No PVCs found for ${APP}"
