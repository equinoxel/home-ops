# Victoria Metrics

## Overview

Victoria Metrics is the primary metrics storage and monitoring stack for this cluster. It is deployed via the [victoria-metrics-k8s-stack](https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-metrics-k8s-stack) Helm chart (v0.78.0), which bundles multiple components into a single deployment.

Victoria Metrics provides a Prometheus-compatible time-series database with better performance and lower resource usage than Prometheus itself.

## Architecture

```mermaid
graph TD
    subgraph Sources
        SM[ServiceMonitors / PodMonitors]
    end

    subgraph Victoria Metrics Stack
        VMA[VMAgent<br/>collector]
        VMS[VMSingle<br/>storage & query<br/>200Gi / 400d retention]
        VMAL[VMAlert<br/>rule evaluation]
        VMAM[VMAlertmanager<br/>notifications]
        VMAUTH[VMAuth<br/>unified query proxy]
    end

    subgraph Notifications
        PO[Pushover]
        HB[Healthchecks.io<br/>heartbeat]
    end

    subgraph Visualization
        GF[Grafana]
        VL[Victoria Logs]
    end

    SM --> VMA
    VMA --> VMS
    VMS --> VMAL
    VMAL --> VMAM
    VMAM --> PO
    VMAM --> HB
    VMS --> VMAUTH
    VL --> VMAUTH
    VMAUTH --> GF
```

### Components

| Component | Purpose | Endpoint |
|-----------|---------|----------|
| **VMSingle** | Single-node time-series database | `metrics.tholinka.dev` |
| **VMAgent** | Scrapes metrics from targets and remote-writes to VMSingle | Internal |
| **VMAlert** | Evaluates alerting/recording rules | `alerts.tholinka.dev` |
| **VMAlertmanager** | Routes and sends alert notifications | `alertmanager.tholinka.dev` |
| **VMAuth** | Authentication proxy and unified query router | Internal (port 8427) |
| **VM Operator** | Manages VM CRDs and reconciles resources | Internal |

### VMAuth Routing

VMAuth acts as a unified query endpoint that routes requests:
- `/api/v1/query.*` and `/api/v1/label/.*` → VMSingle (metrics)
- `/select/logsql/.*` → Victoria Logs (logs)

This allows Grafana to use a single datasource for both metrics and logs.

## Configuration

### Helm Chart

- **Chart:** `victoria-metrics-k8s-stack` v0.78.0
- **Source:** `oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack`
- **Image registry:** `quay.io`

### Storage

- **VMSingle:** 200Gi on `ceph-block`, retention 400 days
- **VMAlertmanager:** 1Gi on `ceph-block`

### Scrape Targets

In addition to in-cluster ServiceMonitors/PodMonitors, external targets are scraped via ScrapeConfig:

| Target | Endpoint | Metrics Path |
|--------|----------|--------------|
| NAS node-exporter | `nas.servers.internal:9100` | `/metrics` |
| NAS smartctl | `nas.servers.internal:9633` | `/metrics` |

### Alerting

Alerts are routed via VMAlertmanager:
- **Pushover** — primary notification channel for all firing alerts
- **Heartbeat** — Watchdog alert sent to healthchecks.io every 5 minutes
- **Blackhole** — suppresses `InfoInhibitor` alerts

Inhibition rules suppress warning-level alerts when a critical alert with the same name and namespace is firing.

### Custom Alert Rules

| Rule Group | Alert | Description |
|------------|-------|-------------|
| dockerhub | DockerhubRateLimitRisk | >100 containers pulling from Docker Hub |
| oom | OomKilled | Container OOMKilled ≥1 time in 10 minutes |
| btrfs | BtrfsDeviceErrorsDetected | BTRFS device errors detected |
| btrfs | BtrfsDeviceAlmostFull | BTRFS device <1% free space |

### Grafana Dashboards

Dashboards are provisioned via GrafanaDashboard CRDs using the Grafana Operator:
- Kubernetes API Server, CoreDNS, Global, Namespaces, Nodes, Pods, Volumes, PVC
- etcd Storage
- Node Exporter Full

### Ext-Auth (Authentik)

Three SecurityPolicies protect the web UIs via authentik:
- `vmsingle-victoria-metrics` (metrics UI)
- `vmalert-victoria-metrics` (alerts UI)
- `vmalertmanager-victoria-metrics` (alertmanager UI)

## Secrets

Secrets are managed via ExternalSecrets pulling from the `bitwarden` ClusterSecretStore.

### `vmalertmanager` Secret

Created from Bitwarden items `pushover` and `alertmanager`.

| Key | Description | Default/Example |
|-----|-------------|-----------------|
| `ALERTMANAGER_PUSHOVER_TOKEN` | Pushover application API token for alertmanager notifications | `axxxxxxxxxxxxxxxxxxxxxxxxxxxxx` (30-char alphanumeric) |
| `PUSHOVER_USER_KEY` | Pushover user/group key to receive notifications | `uxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` (30-char alphanumeric) |
| `HEALTHCHECKS_IO_HEARTBEAT_URL` | Healthchecks.io ping URL for Watchdog heartbeat | `https://hc-ping.com/<uuid>` |

## Dependencies

- `storage-ready` (flux-system) — ensures Ceph storage and VolSync CRDs are available
- Prometheus Operator CRDs — for ServiceMonitor, PodMonitor, ScrapeConfig resources
- Grafana Operator — for dashboard provisioning
