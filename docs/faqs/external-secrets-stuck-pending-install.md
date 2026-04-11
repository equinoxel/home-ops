# External Secrets Stuck in `pending-install` After `helm uninstall`

## Problem

After running `helm uninstall external-secrets -n security`, the subsequent Flux-managed reinstall gets stuck in `pending-install`. The `external-secrets-cert-controller` pod fails its readiness probe (HTTP 500) because `helm uninstall` removed the core CRDs (e.g. `externalsecrets.external-secrets.io`). The cert-controller needs these CRDs to inject conversion webhooks, but the CRDs are supposed to be installed by the same helm release — creating a chicken-and-egg deadlock.

Logs will show:

```
"msg":"failed to inject conversion webhook","error":"CustomResourceDefinition.apiextensions.k8s.io \"externalsecrets.external-secrets.io\" not found"
```

## Resolution

1. Suspend the Flux HelmRelease to stop retries:
   ```bash
   flux suspend helmrelease external-secrets -n security
   ```

2. Uninstall the stuck helm release:
   ```bash
   helm uninstall external-secrets -n security
   ```

3. Manually apply the CRDs for the matching chart version (replace `v2.0.1` with your version):
   ```bash
   kubectl apply --server-side -f https://raw.githubusercontent.com/external-secrets/external-secrets/v2.0.1/deploy/crds/bundle.yaml
   ```

4. Resume the Flux HelmRelease:
   ```bash
   flux resume helmrelease external-secrets -n security
   ```

5. Force reconciliation:
   ```bash
   flux reconcile helmrelease external-secrets -n security
   ```

6. Verify all pods are ready:
   ```bash
   kubectl get pods -n security
   ```
