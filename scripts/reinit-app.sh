#!/usr/bin/env bash
#
# Reinitialize a Flux-managed application.
#
# Suspends the Flux kustomization, deletes all resources it owns
# (pods, PVCs, PVs, jobs), resumes the kustomization, and reconciles.
# Useful when an app's local storage (openebs-hostpath) is lost after
# a node reimage and the app is stuck on stale PVCs.
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

# Also delete any pods still stuck (Terminating, etc.)
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
        # Remove finalizers first to avoid hanging
        kubectl patch pvc "${pvc}" -n "${NS}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete pvc "${pvc}" -n "${NS}" --wait=false 2>/dev/null || true
    done
fi

# Delete VolSync ReplicationSources that might be stuck
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

# Delete stale PVs that were bound to this app's PVCs
log "Cleaning up stale PVs..."
stale_pvs=$(kubectl get pv --no-headers -o custom-columns='NAME:.metadata.name,CLAIM:.spec.claimRef.name,NS:.spec.claimRef.namespace,STATUS:.status.phase' 2>/dev/null \
    | grep -i "${APP}" | grep "${NS}" | grep -E 'Released|Failed' | awk '{print $1}' || true)
if [[ -n "${stale_pvs}" ]]; then
    for pv in ${stale_pvs}; do
        log "  Deleting stale PV ${pv}..."
        kubectl delete pv "${pv}" 2>/dev/null || true
    done
fi

# Wait a moment for cleanup to propagate
log "Waiting for cleanup to settle..."
sleep 5

# ---------------------------------------------------------------------------
# Step 3: Resume and reconcile
# ---------------------------------------------------------------------------
log "Resuming Flux kustomization ${APP}..."
flux resume ks "${APP}" -n "${NS}"

log "Reconciling..."
flux reconcile ks "${APP}" -n "${NS}" --with-source

# ---------------------------------------------------------------------------
# Step 4: Wait for health
# ---------------------------------------------------------------------------
log "Waiting for pods to come up..."
for i in $(seq 1 30); do
    pods=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null | grep -i "${APP}" || true)
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
