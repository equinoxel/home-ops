# Cilium L2 Announcements Not Working Across Subnets

## Problem

LoadBalancer services with IPs in `10.0.0.0/24` are unreachable when the pods backing them run on worker nodes in `10.0.50.0/24`.

Cilium L2 announcements work by sending ARP replies for the LoadBalancer IP from the node running the service's backing pods. ARP is a Layer 2 protocol — it only works within the same broadcast domain (subnet). A node on `10.0.50.0/24` cannot ARP for an IP in `10.0.0.0/24` because they are on different VLANs.

In this cluster:
- Control plane nodes (`esxi-2cu-8g-*`) are on `10.0.0.0/24` with `NoSchedule` taints
- Worker nodes (`blade-*`) are on `10.0.50.0/24`
- LoadBalancer IPs (envoy-external, envoy-internal, k8s-gateway) are in `10.0.0.0/24`

Since no workload pods run on the control plane nodes, no node on `10.0.0.0/24` can announce the LB IPs via ARP.

## Solution

Add tolerations for the `node-role.kubernetes.io/control-plane` taint to the specific services that need LB IPs on `10.0.0.0/24`. This allows only those pods to schedule on control plane nodes while all other workloads remain on workers.

### Envoy Gateway

In `kubernetes/apps/network/envoy-gateway/app/envoy.yaml`, the `EnvoyProxy` resource gets tolerations and a node affinity preference:

```yaml
envoyDeployment:
  pod:
    tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
    affinity:
      nodeAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: Exists
```

### k8s-gateway

In `kubernetes/apps/network/k8s-gateway/app/helmrelease.yaml`, the same tolerations and affinity are added as Helm values.

### Why `preferred` and not `required`?

Using `preferredDuringSchedulingIgnoredDuringExecution` means the scheduler will try to place pods on control plane nodes (where L2 announcements work) but can fall back to worker nodes if control plane nodes are unavailable. This keeps the services resilient.

### Alternative Approaches

1. Move LB IPs to `10.0.50.0/24` — simpler but requires updating all DNS records
2. Use BGP instead of L2 announcements — works across subnets but requires router configuration
3. Put all nodes on the same subnet — eliminates the problem entirely
