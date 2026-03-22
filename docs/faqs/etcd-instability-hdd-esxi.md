# etcd Instability on ESXi VMs with Rotational Disks

## The Problem

The cluster experiences periodic brief outages where all nodes show `NotReady` and
controllers (CNPG, openebs, volsync) crash with `leader election lost` or
`context deadline exceeded` errors against the API server.

### Symptoms

- Nodes intermittently show `NotReady` in `kubectl get nodes`
- Controllers crash-loop with errors like:
  ```
  Failed to update lock: Put "https://10.43.0.1:443/...": context deadline exceeded
  leader election lost
  ```
- openebs-localpv-provisioner CrashLoopBackOff
- CNPG operator restarting repeatedly
- Talos dmesg shows VIP migrating between nodes:
  ```
  etcd session closed
  removing shared IP ... ip: 10.0.0.155
  enabled shared IP ... ip: 10.0.0.155   # on a different node
  ```

### Root Cause

The cluster runs 3 control plane VMs on ESXi backed by **rotational (HDD) virtual
disks**. etcd is extremely sensitive to fsync latency — it uses fsync on every write
to guarantee durability. On rotational disks, fsync can take 10–50ms or more,
especially when other I/O-intensive workloads (Ceph OSD, observability) are running
on the same node and competing for disk access.

When etcd's fsync stalls long enough, it misses its internal heartbeat deadline,
causing:

1. etcd health check fails (`context deadline exceeded`)
2. The node holding the VIP (`10.0.0.155`) drops its etcd lease
3. The VIP migrates to another node via gratuitous ARP
4. During the ~30–60s ARP propagation window, `10.0.0.155:6443` is unreachable
5. All controllers using leader election lose their leases and crash-restart

The problem is compounded by `esxi-2cu-8g-01` running 52 pods (vs 15–17 on the
other nodes), including Ceph and observability workloads that generate heavy I/O.

---

## Solution

The fix has two parts: **immediate tuning** to make etcd more tolerant of latency
spikes, and **disk migration** to move VM system disks to SSD-backed storage.

### Part 1: etcd and Kernel Tuning

#### 1.1 Increase etcd heartbeat and election timeouts

In `talos/patches/controller/cluster.yaml`, increase the etcd heartbeat interval
and election timeout so transient I/O stalls don't immediately trigger a leader
election:

```yaml
cluster:
  etcd:
    extraArgs:
      heartbeat-interval: "500"   # default: 100ms
      election-timeout: "5000"    # default: 1000ms
      auto-compaction-retention: "1"
      auto-compaction-mode: periodic
      quota-backend-bytes: "8589934592"
```

- `heartbeat-interval: 500` — peers wait longer before suspecting a failure
- `election-timeout: 5000` — requires a sustained 5s outage before triggering
  VIP migration, absorbing transient I/O stalls
- `auto-compaction-retention: 1` — compacts the etcd DB hourly, keeping it small
  and reducing fsync pressure

#### 1.2 Reserve CPU and memory for system processes

In `talos/patches/global/machine-kubelet.yaml`, reserve resources so workload pods
cannot starve etcd and kubelet:

```yaml
machine:
  kubelet:
    extraConfig:
      kubeReserved:
        cpu: 500m
        memory: 500Mi
      systemReserved:
        cpu: 500m
        memory: 500Mi
      evictionHard:
        memory.available: 500Mi
```

#### 1.3 Tune dirty page writeback

In `talos/patches/global/machine-sysctls.yaml`, reduce dirty page buildup to
prevent I/O bursts that stall etcd fsyncs:

```yaml
machine:
  sysctls:
    vm.dirty_ratio: "15"
    vm.dirty_background_ratio: "5"
    vm.dirty_expire_centisecs: "1000"
    vm.dirty_writeback_centisecs: "500"
```

#### Apply the tuning changes

```sh
task talos:generate-config
task talos:apply-node IP=10.0.0.145 MODE=auto
task talos:apply-node IP=10.0.0.146 MODE=auto
task talos:apply-node IP=10.0.0.147 MODE=auto
```

---

### Part 2: Migrate VM System Disks to SSD

The ESXi host has a 915GB SSD datastore (`VMs-2`) that is currently unused by the
VMs. Moving each VM's `sda` (the OS/etcd disk) from the HDD datastore (`Surveil`)
to `VMs-2` eliminates the rotational disk latency for etcd entirely.

Each VM has two disks:
- `*.vmdk` — `sda`, the Talos OS disk containing etcd data → **migrate to SSD**
- `*_1.vmdk` — `sdb`, the Ceph OSD disk → leave on HDD (Ceph tolerates latency)

> **This requires cluster downtime.** Shut down all nodes gracefully before
> migrating.

#### Step 1: Verify free space on the SSD datastore

Each `sda` is ~69GB, so you need ~210GB free:

```sh
ssh root@<esxi-host> "df -h /vmfs/volumes/VMs-2"
```

#### Step 2: Create destination directories

```sh
ssh root@<esxi-host> "mkdir -p \
  /vmfs/volumes/VMs-2/esxi-01-2cu-8g \
  /vmfs/volumes/VMs-2/esxi-2cu-8g-02 \
  /vmfs/volumes/VMs-2/esxi-2cu-8g-03"
```

#### Step 3: Shut down the cluster gracefully

```sh
export TALOSCONFIG="talos/clusterconfig/talosconfig"
talosctl -n 10.0.0.146 shutdown
talosctl -n 10.0.0.147 shutdown
talosctl -n 10.0.0.145 shutdown
```

Wait for all VMs to power off before proceeding.

#### Step 4: Clone sda to the SSD datastore

Run each clone sequentially — this takes several minutes per disk:

```sh
ssh root@<esxi-host> "vmkfstools -i \
  /vmfs/volumes/Surveil/esxi-01-2cu-8g/esxi-01-2cu-8g.vmdk \
  /vmfs/volumes/VMs-2/esxi-01-2cu-8g/esxi-01-2cu-8g.vmdk -d thin"

ssh root@<esxi-host> "vmkfstools -i \
  /vmfs/volumes/Surveil/esxi-2cu-8g-02/esxi-2cu-8g-02.vmdk \
  /vmfs/volumes/VMs-2/esxi-2cu-8g-02/esxi-2cu-8g-02.vmdk -d thin"

ssh root@<esxi-host> "vmkfstools -i \
  /vmfs/volumes/Surveil/esxi-2cu-8g-03/esxi-2cu-8g-03.vmdk \
  /vmfs/volumes/VMs-2/esxi-2cu-8g-03/esxi-2cu-8g-03.vmdk -d thin"
```

#### Step 5: Update each VMX to point sda at the new SSD disk

```sh
ssh root@<esxi-host> "sed -i \
  's|/vmfs/volumes/Surveil/esxi-01-2cu-8g/esxi-01-2cu-8g.vmdk|/vmfs/volumes/VMs-2/esxi-01-2cu-8g/esxi-01-2cu-8g.vmdk|' \
  /vmfs/volumes/Surveil/esxi-01-2cu-8g/esxi-01-2cu-8g.vmx"

ssh root@<esxi-host> "sed -i \
  's|/vmfs/volumes/Surveil/esxi-2cu-8g-02/esxi-2cu-8g-02.vmdk|/vmfs/volumes/VMs-2/esxi-2cu-8g-02/esxi-2cu-8g-02.vmdk|' \
  /vmfs/volumes/Surveil/esxi-2cu-8g-02/esxi-2cu-8g-02.vmx"

ssh root@<esxi-host> "sed -i \
  's|/vmfs/volumes/Surveil/esxi-2cu-8g-03/esxi-2cu-8g-03.vmdk|/vmfs/volumes/VMs-2/esxi-2cu-8g-03/esxi-2cu-8g-03.vmdk|' \
  /vmfs/volumes/Surveil/esxi-2cu-8g-03/esxi-2cu-8g-03.vmx"
```

#### Step 6: Reload VMX and power on

```sh
# Get VM IDs
ssh root@<esxi-host> "vim-cmd vmsvc/getallvms"

# For each VM ID:
ssh root@<esxi-host> "vim-cmd vmsvc/reload <ID> && vim-cmd vmsvc/power.on <ID>"
```

Power on one node at a time and wait for it to reach `Ready` before starting the
next, to avoid etcd quorum issues during startup.

#### Step 7: Verify cluster health

```sh
export TALOSCONFIG="talos/clusterconfig/talosconfig"
talosctl -n 10.0.0.145 etcd status
kubectl get nodes
flux get ks -A
```

#### Step 8: Clean up old HDD disks

Once the cluster is stable for a few days, remove the old vmdk files from `Surveil`
to reclaim HDD space:

```sh
ssh root@<esxi-host> "vmkfstools -U /vmfs/volumes/Surveil/esxi-01-2cu-8g/esxi-01-2cu-8g.vmdk"
ssh root@<esxi-host> "vmkfstools -U /vmfs/volumes/Surveil/esxi-2cu-8g-02/esxi-2cu-8g-02.vmdk"
ssh root@<esxi-host> "vmkfstools -U /vmfs/volumes/Surveil/esxi-2cu-8g-03/esxi-2cu-8g-03.vmdk"
```

---

## Expected Outcome

After applying Part 1 (tuning), transient I/O stalls of up to ~4.5s will no longer
trigger a VIP migration. After Part 2 (SSD migration), etcd fsync latency drops
from 10–50ms to <1ms, eliminating the root cause entirely.
