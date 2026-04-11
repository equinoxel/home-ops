# Kubelet Stuck in `Initialized` After Moving Node to a Different Subnet

## Problem

After moving `blade-01` from `10.0.0.0/24` to `10.0.50.0/24`, the node gets stuck in Talos "booting" stage. Kubelet never transitions from `Initialized` to `Running`, and the node shows `NotReady` in Kubernetes. All workload pods remain `Pending` since blade-01 is the only worker node (control plane nodes have `NoSchedule` taints).

Talos dmesg shows:

```
no suitable node IP found, please make sure .machine.kubelet.nodeIP filters and pod/service subnets are set up correctly
```

The root cause is `machine.kubelet.nodeIP.validSubnets` in `talos/patches/global/machine-kubelet.yaml` — it only listed `10.0.0.0/24`, so kubelet couldn't find a matching IP on the new subnet and refused to start.

## Resolution

1. Add the new subnet to `validSubnets` in `talos/patches/global/machine-kubelet.yaml`:
   ```yaml
   machine:
     kubelet:
       nodeIP:
         validSubnets:
           - 10.0.0.0/24
           - 10.0.50.0/24
   ```

2. Apply the patch live to the affected node (no reboot required):
   ```bash
   talosctl -n 10.0.50.10 patch machineconfig --patch 'machine:
     kubelet:
       nodeIP:
         validSubnets:
           - 10.0.0.0/24
           - 10.0.50.0/24'
   ```

3. Verify kubelet started:
   ```bash
   talosctl -n 10.0.50.10 service
   # kubelet should show Running / OK
   ```

4. Verify the node is Ready:
   ```bash
   kubectl get nodes
   ```

## Related Changes

When moving a node to a different subnet, also update:

- `talos/talconfig.yaml` — node `ipAddress` field
- `talos/patches/global/machine-kubelet.yaml` — `nodeIP.validSubnets`
- Cilium routing config — `autoDirectNodeRoutes` only works within a single L2 network (see `cilium-bpf-verifier-bug.md` or cluster networking docs)
