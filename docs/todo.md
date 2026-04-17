# Reliability Improvements

Action items identified from operational issues encountered during setup and day-to-day management of the cluster.

---

## VolSync Restore Runbook

**Purpose:** There is currently no documented procedure for restoring data from a VolSync backup into a fresh PVC. When a PVC is deleted or created empty, the path from "no data" to "data restored" is unclear and error-prone.

- [x] Write a step-by-step runbook for triggering a manual VolSync restore with `copyMethod: Direct` and `openebs-hostpath`
- [x] Include instructions for deleting a broken PVC, recreating it via Flux, and triggering the ReplicationDestination
- [x] Document how to verify the restore completed successfully (check `latestImage`, pod logs, data integrity)
- [x] Store the runbook in `docs/` and link it from the VolSync component README

---

## VolSync Backup Monitoring

**Purpose:** If VolSync ReplicationSource backups silently fail, the issue won't surface until a restore is needed — at which point the backup may be stale or missing entirely.

- [x] Add a Prometheus alert on `volsync_replication_source_last_sync_time` being older than a defined threshold (e.g., 6 hours for 2-hourly backups)
- [x] Add a Prometheus alert on `volsync_replication_source_last_sync_status` indicating failure
- [x] Verify that VolSync metrics are being scraped (check ServiceMonitor or PodMonitor configuration)
- [ ] Add a Grafana dashboard panel for VolSync backup status across all apps

---

## VolSync PVC Immutability Protection

**Purpose:** Kubernetes treats PVC `dataSource`/`dataSourceRef` fields as immutable after creation. When Flux tries to reconcile a PVC that was created with a `dataSourceRef` (or without one), any mismatch causes a dry-run failure that blocks the entire Kustomization.

- [x] Remove `dataSourceRef` from the VolSync PVC component (`kubernetes/components/volsync/pvc.yaml`)
- [x] Add `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` annotation to the VolSync PVC component
- [ ] Delete and recreate any existing PVCs that still have the old `dataSourceRef` baked in (pgadmin, navidrome, etc.)
- [ ] Verify all VolSync-managed PVCs are in `Bound` state after the fix

---

## NFS Mount Reliability

**Purpose:** NFS mount failures at pod startup are silent and cause pods to hang indefinitely in `ContainerCreating` state. This is especially problematic for media apps that depend on NAS shares.

- [ ] Verify `nfs-common` (or equivalent) is included in Talos system extensions
- [ ] Add `mountOptions` to NFS volumes for faster failure detection:
  - `soft` — return errors instead of hanging on NFS timeout
  - `timeo=30` — 3-second timeout
  - `retrans=3` — retry 3 times before failing
- [ ] Test pod startup behavior when the NAS (`10.0.0.14`) is unreachable
- [ ] Consider adding a liveness probe or startup probe that validates NFS mount availability

---

## Flux Dependency Management

**Purpose:** Apps that depend on ExternalSecrets will fail with `CreateContainerConfigError` if the secret store (Bitwarden Connect / 1Password Connect) isn't ready when the ExternalSecret tries to sync. Making these dependencies explicit prevents race conditions during cluster bootstrap or reconciliation.

- [ ] Audit all Flux Kustomizations that use ExternalSecrets and ensure they have `dependsOn` referencing the secret store operator
- [ ] Add `dependsOn` for homepage pointing to the Bitwarden/1Password Connect Kustomization
- [ ] Add Flux `healthChecks` to critical app Kustomizations to catch deployment failures early
- [ ] Test the full bootstrap sequence from a clean cluster to verify dependency ordering

---

## ExternalSecret Hygiene

**Purpose:** The homepage ExternalSecret has many commented-out fields. If a service integration is uncommented but the corresponding `dataFrom` extract is forgotten (or the Bitwarden item doesn't have the expected field), the secret will be incomplete and the pod will fail.

- [ ] Audit all ExternalSecrets for consistency between `template.data` fields and `dataFrom` extracts
- [ ] Remove commented-out fields that are not planned for near-term use to reduce confusion
- [ ] Add comments to remaining commented fields indicating which Bitwarden item and field they expect
- [ ] Consider splitting large ExternalSecrets (like homepage) into per-service secrets to isolate failures

---

## Init Container Resource Requests

**Purpose:** Init containers without resource requests can cause scheduling issues on a resource-constrained homelab. The scheduler may not account for their resource needs, leading to unexpected evictions or OOM kills.

- [ ] Add `resources.requests` to the busybox init container in the subsonic HelmRelease
- [ ] Audit all other init containers across the cluster for missing resource requests
- [ ] Set reasonable defaults (e.g., `cpu: 10m`, `memory: 32Mi` for simple shell init containers)

---

## Image Digest Pinning

**Purpose:** Container image tags can be mutated (e.g., `latest`, or even semver tags being re-pushed). Pinning to digests ensures reproducible deployments and prevents unexpected breakage from upstream changes.

- [ ] Add image digest to `ghcr.io/sentriz/gonic:v0.20.1` in the subsonic HelmRelease
- [ ] Add image digest to `docker.io/busybox:latest` in the subsonic init container (or pin to a specific tag + digest)
- [ ] Audit all HelmReleases for images missing digest pins
- [ ] Consider using Renovate to automatically update digests when new versions are released

---

## Pod Disruption Budgets

**Purpose:** Stateful apps (pgadmin, navidrome, gonic) with a single replica will experience downtime during voluntary disruptions like node drains or upgrades. PodDisruptionBudgets prevent accidental eviction during maintenance.

- [ ] Add `PodDisruptionBudget` resources for pgadmin, navidrome, and subsonic (gonic)
- [ ] Set `minAvailable: 1` or `maxUnavailable: 0` for single-replica stateful apps
- [ ] Test node drain behavior with PDBs in place

---

## Periodic Restore Testing

**Purpose:** Backups that have never been restored are assumptions, not guarantees. Periodic restore testing validates the entire backup-restore pipeline end to end.

- [ ] Schedule a quarterly restore test to a throwaway namespace
- [ ] Document the test procedure: create namespace, trigger ReplicationDestination, verify data, clean up
- [ ] Track restore test results (date, app, success/failure, notes)
- [ ] Consider automating the test with a CronJob or Flux RunnerJob
