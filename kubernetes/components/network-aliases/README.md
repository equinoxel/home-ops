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

## Retiring `cluster-settings`

This component exists as an interim source of truth **only because there is no
dynamic DNS provider yet**. Its main job is to let you hand-mirror the IP table
above into Pi-hole / AdGuard Home.

Once **Pi-hole or AdGuard Home is installed alongside `external-dns`**, DNS
records are created automatically from the
`external-dns.alpha.kubernetes.io/hostname` annotations already present on the
gateways and LoadBalancer services. The manual host-record mirroring is no
longer needed, and the `${SVC_*}` substitution can be replaced with inline
values. At that point, do the following to remove this component:

1. **Confirm external-dns is publishing records.** Install Pi-hole / AdGuard
   Home, then enable `pihole-external-dns` (add `./pihole/ks.yaml` and
   `./pihole-external-dns/ks.yaml` to `kubernetes/apps/network/kustomization.yaml`).
   Verify with `dig <hostname> @<pihole-ip>` that records resolve without any
   manual entries.

2. **Remove the manual DNS host-records** from Pi-hole / AdGuard Home (the
   `host-record` / DNS-rewrite entries listed above). They are now managed by
   external-dns and would otherwise conflict.

3. **Inline the LB IPs.** For each service still reading a `${SVC_*}` value
   (`lbipam.cilium.io/ips`), replace the variable with the literal IP in the
   manifest. Grep for the remaining consumers first:

   ```bash
   grep -rl 'cluster-settings' kubernetes/
   grep -rn 'SVC_' kubernetes/
   ```

4. **Drop the ConfigMap from each Flux `Kustomization`.** Remove the
   `- name: cluster-settings` / `kind: ConfigMap` entry from every `ks.yaml`
   `postBuild.substituteFrom` block that references it.

5. **Remove the component.** Delete the
   `- ../../components/network-aliases` line from the namespace
   `kustomization.yaml` files, then delete this `network-aliases` directory.

6. **Reconcile and verify.** Run `flux reconcile` (or let Flux sync) and confirm
   every affected app comes up healthy with DNS resolving via external-dns.
