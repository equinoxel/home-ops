# Grafana Stuck in ContainerCreating

## Problem

The Grafana pod is stuck in `ContainerCreating` or repeatedly restarting. Other apps that depend on the postgres cluster (authentik, immich, etc.) may also be unhealthy.

## Root Cause

Grafana (managed by the Grafana Operator) depends on the CNPG postgres cluster for its database. When the postgres cluster is down or in a `Failed` state, Grafana cannot start because:

- It cannot connect to its database backend
- Init containers or readiness probes that verify database connectivity will block

This is a **cascading failure** — the root cause is the postgres cluster, not Grafana itself.

## Diagnosis

```bash
# Check if Grafana is actually the problem or just a symptom
kubectl get cluster -n database
kubectl get pods -n database -l cnpg.io/cluster=postgres-cluster

# If postgres-cluster shows Failed/NotReady, that's the root cause
```

## Resolution

1. **Fix the postgres cluster first.** See [CNPG Cluster Recovery from S3](cnpg-cluster-recovery-from-s3.md) if the cluster data is lost, or investigate the specific postgres failure.

2. **Grafana will recover automatically.** Once the postgres cluster is healthy, the Grafana Operator will detect the change and the pod will start successfully. No manual intervention on Grafana is needed.

3. If Grafana doesn't recover within a few minutes after postgres is healthy, restart it:

   ```bash
   kubectl delete pod -n observability -l app.kubernetes.io/name=grafana
   ```

## General Rule

When multiple apps are unhealthy at the same time, check shared dependencies first:

- **postgres-cluster** — authentik, grafana, immich, paperless, atuin
- **openebs** — anything using `openebs-hostpath` PVCs
- **cert-manager** — anything needing TLS certificates
- **external-secrets** — anything using ExternalSecret resources
