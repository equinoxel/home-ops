# synology-backup

Automated periodic backup application that mirrors cluster backups and TrueNAS filesystem shares to an external Synology NAS over NFS and S3.

Runs daily at **04:00 AM** as a Kubernetes `CronJob` using [rclone](https://rclone.org/).

---

## What It Does

1. **Multi-Bucket S3 Sync (Auto-Discovery)**: Connects to the TrueNAS RustFS S3 API and automatically discovers all existing buckets (e.g. `volsync-kopia`, `database`, `documents`, and future buckets like `home-assistant`), syncing each into `/destination/<bucket-name>` on the Synology NAS.
   - If a bucket is not yet created on RustFS (e.g. before Home Assistant S3 backup is configured), it safely logs an info message and skips it without failing the job.
2. **TrueNAS Filesystem / Photos Sync**: Mounts the TrueNAS photos share over NFS (read-only) and mirrors all photos/media to `/destination/photos` on the Synology NAS.
   - **Accidental Deletion Protection**: Uses rclone's `--backup-dir` flag so any files modified or deleted on the source are archived to a dated directory (`/destination/photos-deleted/YYYY-MM-DD/`) instead of being permanently removed from the backup.

---

## Synology NAS Setup Steps

Before enabling this application, prepare the shared folder and NFS permissions on your Synology NAS:

1. **Create Destination Shared Folder**
   - Open **DSM** > **Control Panel** > **Shared Folder** > **Create**.
   - Name: `backup` (or your preferred name, matching `SYNOLOGY_NFS_PATH`).
   - Configure volume and encryption as desired.

2. **Enable NFS Service**
   - Go to **Control Panel** > **File Services** > **NFS**.
   - Check **Enable NFS service**.
   - Set **Maximum NFS protocol** to **NFSv4.1** or **NFSv4.2**.
   - Click **Apply**.

3. **Configure NFS Permissions**
   - In **Control Panel** > **Shared Folder**, select your backup folder and click **Edit**.
   - Switch to the **NFS Permissions** tab and click **Create**:
     - **Hostname or IP**: Enter the subnet of your Kubernetes nodes (e.g., `192.168.x.0/24`).
     - **Privilege**: `Read/Write`.
     - **Squash**: `No mapping` (or `Map all users to admin` if you prefer Synology admin ownership).
     - **Security**: `sys`.
     - Check **"Enable asynchronous"**.
     - Check **"Allow connections from non-privileged ports (ports higher than 1024)"**.
     - Check **"Allow users to access mounted subfolders"**.
   - Click **Save**.

---

## Secrets Setup (No Duplication)

This app **reuses existing secrets already defined in your cluster and Bitwarden** rather than duplicating them:

* **S3 / RustFS Credentials**: Pulled directly from the existing **`volsync_s3_template`** item in Bitwarden (`AWS_S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
* **TrueNAS Server Address**: Pulled directly from the existing **`cluster-settings`** ConfigMap (`SVC_TRUENAS_IP`).

### What You Need in Bitwarden

You only need a single lightweight item in Bitwarden containing the Synology-specific details:

**Item Name:**
```text
synology
```

**JSON Payload (Placeholder):**
```json
{
  "SYNOLOGY_NFS_SERVER": "192.168.1.100",
  "SYNOLOGY_NFS_PATH": "/volume1/backup"
}
```

*(Optional: you can add `"BACKUP_S3_BUCKETS": "volsync-kopia,database,home-assistant"` if you want to restrict backups to specific buckets instead of the default auto-discovery).*

### Parameter Reference

| Key | Source | Description | Example (Anonymized) |
|---|---|---|---|
| `SYNOLOGY_NFS_SERVER` | Bitwarden (`synology`) | IP address or hostname of the Synology NAS | `192.168.1.100` |
| `SYNOLOGY_NFS_PATH` | Bitwarden (`synology`) | NFS export path on the Synology NAS | `/volume1/backup` |
| `AWS_S3_ENDPOINT` | Bitwarden (`volsync_s3_template`) | Existing TrueNAS RustFS S3 endpoint | `http://192.168.1.50:30292` |
| `AWS_ACCESS_KEY_ID` | Bitwarden (`volsync_s3_template`) | Existing RustFS S3 access key | `srwXFvRMtJq1iAiWRHvr` |
| `AWS_SECRET_ACCESS_KEY` | Bitwarden (`volsync_s3_template`) | Existing RustFS S3 secret key | `...` |
| `SVC_TRUENAS_IP` | ConfigMap (`cluster-settings`) | Existing TrueNAS IP address | `192.168.1.50` |
| `TRUENAS_PHOTOS_NFS_PATH` | Helm default | TrueNAS NFS photos export path | `/mnt/Main/shares/photo` |
| `BACKUP_S3_BUCKETS` | Config / Secret | List of buckets (defaults to `auto`) | `auto` |

---

## How to Enable and Deploy

This application is currently **staged and suspended** so you can review the manifests and configure Bitwarden and Synology first.

Once you have verified the configuration:

1. **Enable the application in Flux**:
   In [`kubernetes/apps/downloads/kustomization.yaml`](file:///home/laur/dev/talos/home-ops/kubernetes/apps/downloads/kustomization.yaml), uncomment the resource:
   ```yaml
   resources:
     # ...
     - ./synology-backup
   ```

2. **Unsuspend the Kustomization**:
   In [`kubernetes/apps/downloads/synology-backup/app.ks.yaml`](file:///home/laur/dev/talos/home-ops/kubernetes/apps/downloads/synology-backup/app.ks.yaml), change:
   ```yaml
   suspend: false
   ```

3. **Reconcile Flux**:
   ```bash
   flux reconcile ks downloads --with-source
   ```

---

## Testing & Operational Verification

### Trigger an On-Demand Backup Run

You don't need to wait until 04:00 AM to test the backup. Trigger an immediate one-off job from the CronJob:

```bash
kubectl create job --from=cronjob/synology-backup synology-backup-manual -n downloads
```

### Watch the Progress & Logs

```bash
kubectl logs -f -n downloads job/synology-backup-manual
```

### Check Job History & Status

```bash
kubectl get cronjob,job -n downloads -l app.kubernetes.io/name=synology-backup
```
