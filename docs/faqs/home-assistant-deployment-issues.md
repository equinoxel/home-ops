# Home Assistant Deployment Issues

## Table of Contents

- [Missing ipv6 Secret Blocks Flux Reconciliation](#missing-ipv6-secret-blocks-flux-reconciliation)
- [Multus Macvlan Link Not Found](#multus-macvlan-link-not-found)
- [Macvlan Cannot Assign Requested Address (Bond Down)](#macvlan-cannot-assign-requested-address-bond-down)
- [Macvlan Cannot Assign Requested Address (Multicast MAC)](#macvlan-cannot-assign-requested-address-multicast-mac)
- [Macvlan Route Network Unreachable](#macvlan-route-network-unreachable)
- [ExternalSecret SecretSyncedError](#externalsecret-secretsyncederror)
- [Failed to Create SubPath Directory](#failed-to-create-subpath-directory)
- [Mount MS_RDONLY Operation Not Permitted (User Namespaces)](#mount-ms_rdonly-operation-not-permitted-user-namespaces)
- [400 Bad Request Behind Reverse Proxy](#400-bad-request-behind-reverse-proxy)

---

## Missing ipv6 Secret Blocks Flux Reconciliation

**Symptom:** Flux Kustomization for home-assistant stays `Ready: False` with error:
```
substitute from 'Secret/ipv6' error: secrets "ipv6" not found
```

**Cause:** The `postBuild.substituteFrom` references a Secret `ipv6` with `optional: false`, but the ExternalSecret that creates it is commented out in `kubernetes/components/common/kustomization.yaml`.

**Resolution:** Set `optional: true` in `app.ks.yaml`:
```yaml
substituteFrom:
  - kind: Secret
    name: ipv6
    optional: true
```

---

## Multus Macvlan Link Not Found

**Symptom:** Pod stuck in `ContainerCreating` with:
```
plugin type="macvlan" failed (add): Link not found
```

**Cause:** The `iot` NetworkAttachmentDefinition uses `master: "bond0.20"` but the node doesn't have a `bond0.20` VLAN interface configured in Talos.

**Resolution:** Add a VLANConfig for VLAN 20 to the node's Talos config:
```yaml
apiVersion: v1alpha1
kind: VLANConfig
name: bond0.20
vlanID: 20
parent: bond0
mtu: 9000
```

---

## Macvlan Cannot Assign Requested Address (Bond Down)

**Symptom:** Pod stuck in `ContainerCreating` with:
```
plugin type="macvlan" failed (add): failed to create macvlan: cannot assign requested address
```

**Cause:** The `bond0` interface and its VLANs show `lowerLayerDown` because the underlying NIC (`net0`/`ens34`) is disconnected at the ESXi hypervisor level.

**Resolution:** In ESXi VM settings, ensure the second network adapter is:
- Connected and set to "Connect at power on"
- Attached to a port group that trunks the required VLANs
- Has Promiscuous Mode, Forged Transmits, and MAC Address Changes set to Accept

---

## Macvlan Cannot Assign Requested Address (Multicast MAC)

**Symptom:** Same error as above, but `bond0` is up.

**Cause:** The MAC address in the multus annotation has the multicast bit set (LSB of first octet = 1). Linux rejects multicast MACs for macvlan interfaces.

**Resolution:** Use a valid unicast locally-administered MAC. The first octet must have LSB = 0 and second bit = 1. Example: `02:xx:xx:xx:xx:xx` or `76:xx:xx:xx:xx:xx`.

---

## Macvlan Route Network Unreachable

**Symptom:** Pod stuck in `ContainerCreating` with:
```
failed to add route '{0.0.0.0} via 10.0.30.1 dev net1': network is unreachable
```

**Cause:** The `iot` NetworkAttachmentDefinition has a gateway (`10.0.30.1`) that doesn't match the assigned subnet (`10.0.20.0/24`). The gateway must be reachable from the pod's IP.

**Resolution:** Fix the gateway in `kubernetes/apps/network/multus/networks/iot.yaml` to match the subnet:
```json
"routes": [
  { "dst": "0.0.0.0/0", "gw": "10.0.20.1" }
]
```

---

## ExternalSecret SecretSyncedError

**Symptom:** ExternalSecret shows `SecretSyncedError` with:
```
map has no entry for key "HASS_GOOGLE_PROJECT_ID"
```

**Cause:** The ExternalSecret template references keys that don't exist in the Bitwarden item (`home_assistant`).

**Resolution:** Either add the missing fields to the Bitwarden item, or remove the unused keys from `externalsecret.yaml`.

---

## Failed to Create SubPath Directory

**Symptom:** Pod fails with:
```
failed to create subPath directory for volumeMount "config-venv" of container "code-server"
```

**Cause:** The PVC is freshly provisioned and the subPath directory (`ha-venv`) doesn't exist yet. The kubelet creates subPath dirs before fsGroup is applied, so it can fail on empty volumes.

**Resolution:** Manually create the directory with correct ownership:
```bash
kubectl run debug-pvc --rm -i --restart=Never --image=busybox \
  --overrides='{"spec":{"nodeName":"<node>","containers":[{"name":"debug","image":"busybox","command":["sh","-c","mkdir -p /data/ha-venv && chown 1000:1000 /data/ha-venv"],"volumeMounts":[{"name":"vol","mountPath":"/data"}]}],"volumes":[{"name":"vol","persistentVolumeClaim":{"claimName":"home-assistant-cache"}}]}}' \
  -n home-automation
```

---

## Mount MS_RDONLY Operation Not Permitted (User Namespaces)

**Symptom:** Container fails to start with:
```
cannot clear locked flags MS_RDONLY: mount dst=/config: operation not permitted
```

**Cause:** `hostUsers: false` enables user namespaces, which prevents the container from remounting bind-mounts to clear the read-only flag. This is a kernel limitation with user namespaces and local-volume/hostpath PVs.

**Resolution:** Remove `hostUsers: false` from `defaultPodOptions` in the HelmRelease. The pod still runs as non-root (UID 1000) via the security context.

---

## 400 Bad Request Behind Reverse Proxy

**Symptom:** HA returns `400 Bad Request` when accessed through Envoy Gateway.

**Cause:** Home Assistant doesn't trust the reverse proxy IP. Without `http.trusted_proxies` configured, HA rejects forwarded requests.

**Resolution:** Add the HTTP config to `/config/configuration.yaml`:
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.42.0.0/16
    - 10.43.0.0/16
```

The `10.42.0.0/16` covers the pod network (Envoy), `10.43.0.0/16` covers the service network.
