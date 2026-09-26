# network-aliases

A tiny Kustomize component that ships a **`cluster-settings` ConfigMap** holding
the static LoadBalancer / VIP addresses used across the cluster as named
variables. The goal is to have a single source of truth for these IPs so that:

- app manifests reference `${SVC_*}` instead of hardcoding an address, and
- the same list can be mirrored into a **Pi-hole / AdGuard Home** config as DNS
  host records.

Nothing here is secret, so it lives in a plain `ConfigMap` (contrast with the
`sops` component's `cluster-secrets` `Secret`).

## Aliases

| Variable | IP | Suggested hostname | Backing service |
|----------|----|--------------------|-----------------|
| `SVC_KUBE_APISERVER_IP`      | `192.168.2.155` | `kube.laurivan.com`          | Kubernetes API VIP (Talos) |
| `SVC_K8S_GATEWAY_IP`         | `192.168.2.156` | `k8s-gateway.laurivan.com`   | k8s-gateway (internal DNS) |
| `SVC_ENVOY_INTERNAL_IP`      | `192.168.2.157` | `internal.laurivan.com`, `*.laurivan.com` | Envoy internal gateway |
| `SVC_ENVOY_EXTERNAL_IP`      | `192.168.2.158` | `external.laurivan.com`      | Envoy external gateway |
| `SVC_ENVOY_INTERNAL_ROOT_IP` | `192.168.2.159` | `laurivan.com` (apex)        | Envoy internal root gateway |
| `SVC_GO2RTC_IP`              | `192.168.2.157` | `go2rtc-streams.laurivan.com` | go2rtc (shares .157 w/ envoy-internal, distinct ports) |
| `SVC_VERNEMQ_IP`             | `192.168.2.154` | `mqtt.laurivan.com`          | VerneMQ MQTT |
| `SVC_UNIFI_STUN_IP`          | `192.168.2.41`  | `unifi-stun.laurivan.com`    | UniFi STUN |

> `192.168.2.157` is intentionally shared by the Envoy internal gateway and
> go2rtc. Cilium LB-IPAM allows two services to share an IP when their ports do
> not collide.

## Usage

1. Add the component to the target namespace's `kustomization.yaml`:

   ```yaml
   components:
     - ../../components/network-aliases
   ```

2. Reference the ConfigMap from the app's Flux `Kustomization` (`ks.yaml`):

   ```yaml
   spec:
     postBuild:
       substituteFrom:
         - name: cluster-secrets   # existing
           kind: Secret
         - name: cluster-settings  # this component
           kind: ConfigMap
   ```

3. Use the variable in a manifest:

   ```yaml
   annotations:
     lbipam.cilium.io/ips: "${SVC_ENVOY_INTERNAL_IP}"
   ```

## Pi-hole / AdGuard Home

Mirror the table above into your DNS config. For Pi-hole `dnsmasq`
`host-record` syntax:

```
host-record=kube.laurivan.com,192.168.2.155
host-record=k8s-gateway.laurivan.com,192.168.2.156
host-record=internal.laurivan.com,192.168.2.157
host-record=external.laurivan.com,192.168.2.158
host-record=laurivan.com,192.168.2.159
host-record=go2rtc-streams.laurivan.com,192.168.2.157
host-record=mqtt.laurivan.com,192.168.2.154
host-record=unifi-stun.laurivan.com,192.168.2.41
```

For AdGuard Home, the equivalent "DNS rewrites" are `hostname -> IP` pairs.
