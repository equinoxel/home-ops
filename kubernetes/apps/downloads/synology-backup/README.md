# synology-backup

Automated periodic backup application that mirrors cluster backups and TrueNAS filesystem shares to an external Synology NAS over NFS and S3.

Runs daily at **04:00 AM** as a Kubernetes `CronJob` using [rclone](https://rclone.org/).

---

## What It Does

1. **VolSync S3 Backups Sync**: Connects to the TrueNAS RustFS S3 API and mirrors the `volsync-kopia` bucket (which holds all Kopia snapshots for cluster PVCs) directly to `/destination/volsync-kopia` on the Synology NAS.
2. **Database S3 Backups Sync (Optional)**: If configured, syncs database backup buckets (such as `database` used by CNPG PostgreSQL and MariaDB) to `/destination/database`.
3. **TrueNAS Filesystem / Photos Sync**: Mounts the TrueNAS photos share over NFS (read-only) and mirrors all photos/media to `/destination/photos` on the Synology NAS.
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

## Secrets Setup (Bitwarden)

All sensitive information—including the Synology NAS address, TrueNAS address, mount paths, and S3 credentials—is managed through [External Secrets Operator](https://external-secrets.io/) via the `bitwarden` ClusterSecretStore.

Create an item in your Bitwarden vault named:
```text
synology_backup
```

### Placeholder JSON for Bitwarden

Paste the following JSON (with your actual network IPs, paths, and keys) into the item notes or custom fields:

```json
{
  "SYNOLOGY_NFS_SERVER": "192.168.1.100",
  "SYNOLOGY_NFS_PATH": "/volume1/backup",
  "TRUENAS_NFS_SERVER": "192.168.1.50",
  "TRUENAS_PHOTOS_NFS_PATH": "/mnt/Main/shares/photo",
  "AWS_S3_ENDPOINT": "http://192.168.1.50:30292",
  "AWS_ACCESS_KEY_ID": "replace-with-rustfs-access-key",
  "AWS_SECRET_ACCESS_KEY": "replace-with-rustfs-secret-key",
  "VOLSYNC_S3_BUCKET": "volsync-kopia",
  "DATABASE_S3_BUCKET": "database"
}
```

### Parameter Reference

| Key | Description | Example (Anonymized) |
|---|---|---|
| `SYNOLOGY_NFS_SERVER` | IP address or hostname of the Synology NAS | `192.168.1.100` |
| `SYNOLOGY_NFS_PATH` | NFS export path on the Synology NAS | `/volume1/backup` |
| `TRUENAS_NFS_SERVER` | IP address or hostname of the TrueNAS server | `192.168.1.50` |
| `TRUENAS_PHOTOS_NFS_PATH` | NFS export path for photos on TrueNAS | `/mnt/Main/shares/photo` |
| `AWS_S3_ENDPOINT` | TrueNAS RustFS S3 endpoint URL | `http://192.168.1.50:30292` |
| `AWS_ACCESS_KEY_ID` | RustFS S3 access key | `your-access-key` |
| `AWS_SECRET_ACCESS_KEY` | RustFS S3 secret key | `your-secret-key` |
| `VOLSYNC_S3_BUCKET` | VolSync S3 bucket name | `volsync-kopia` |
| `DATABASE_S3_BUCKET` | *(Optional)* Database backup bucket name | `database` |

---

## How to Enable and Deploy

This application is currently **staged and suspended** so you can review the manifests and configure Bitwarden and Synology first.

Once you have verified the configuration:

1. **Enable the application in Flux**:
   In `kubernetes/apps/downloads/kustomization.yaml`, uncomment the resource:
   ```yaml
   resources:
     # ...
     - ./synology-backup
   ```

2. **Unsuspend the Kustomization**:
   In `kubernetes/apps/downloads/synology-backup/app.ks.yaml`, change:
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
