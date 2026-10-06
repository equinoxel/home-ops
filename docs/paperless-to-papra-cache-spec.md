# Specification: Paperless-to-Papra Migration Cache

**Status:** Proposed  
**Document:** `docs/paperless-to-papra-cache-spec.md`  
**Target Script:** [`scripts/paperless-to-papra.py`](../scripts/paperless-to-papra.py)  
**Default Cache Path:** `/tmp/papra-migration-cache.json`

---

## 1. Problem Statement & Motivation

The Paperless-ngx instance contains **5,141 documents**. The Paperless REST API list endpoint (`/api/documents/`) provides document metadata (ID, title, original file name, created/modified timestamps, tags, correspondent, document type), but **does not expose a SHA-256 checksum** of the document payload.

Papra performs server-side deduplication using the document's SHA-256 digest (returning HTTP 409 Conflict if identical content exists). Currently, to evaluate whether a Paperless document is already uploaded or pending, [`paperless-to-papra.py`](../scripts/paperless-to-papra.py):
1. Paginates through Paperless document metadata.
2. **Downloads the full original document file over HTTP** for every single document:
   ```python
   file_bytes = paperless.download_original(doc.id)
   digest = sha256_bytes(file_bytes)
   ```
3. Checks if `digest` exists in [`paperless-to-papra.state.json`](../scripts/paperless-to-papra.state.json).

### The Bottleneck
When running with incremental batching (e.g. `--max-records 10` or `500`):
- To process documents 100 to 200, the script must download all preceding 100 documents first simply to compute their SHA-256 and confirm they are in `state.json`.
- When reaching document 3,000, the script would download 3,000 files (many gigabytes over HTTP) before finding new documents to upload.
- This creates massive network overhead, slows migrations to a crawl, and places unnecessary load on the Paperless-ngx instance.

---

## 2. Proposed Solution: Document Cache

Introduce a persistent JSON cache located at `/tmp/papra-migration-cache.json` (configurable via CLI flag and environment variable).

The cache indexes Paperless documents by `paperless_id`, storing their metadata, calculated SHA-256 digest, file size, Papra document ID, and status (`uploaded`, `duplicate`, `pending`, `failed`).

```mermaid
flowchart TD
    Start([Iterate doc in paperless.documents()]) --> CheckCache{doc.id in Cache?}
    
    CheckCache -- Yes: Hit --> InspectStatus{Cache status == 'uploaded' or 'duplicate'?}
    InspectStatus -- Yes --> SkipDownload[Skip Download! Mark as already uploaded]
    InspectStatus -- No --> DownloadNeeded[Download file bytes for upload]
    
    CheckCache -- No: Miss --> DownloadFile[Download original file from Paperless]
    DownloadFile --> CalcHash[Calculate SHA-256 digest]
    CalcHash --> CheckState{Hash in Papra / State?}
    
    CheckState -- Yes --> CacheUploaded[Update Cache: status = 'uploaded']
    CheckState -- No --> QueuePending[Queue in pending batch (do NOT cache yet)]
    QueuePending --> UploadPapra[Upload to Papra + apply tags/properties/date]
    UploadPapra -- Success (201) --> CacheSuccess[Cache: status = 'uploaded', papra_id = ID]
    UploadPapra -- Conflict (409) --> CacheDup[Cache: status = 'duplicate']
    UploadPapra -- Error --> CacheFail[Do not cache! Record failed]
    
    SkipDownload --> NextDoc[Next Document]
    CacheUploaded --> NextDoc
    CacheSuccess --> NextDoc
    CacheDup --> NextDoc
    CacheFail --> NextDoc
```

---

## 3. Cache Storage & Schema

### 3.1 File Location
- **Default Path:** `/tmp/papra-migration-cache.json`
- **CLI Flag:** `--cache-file PATH`
- **Environment Variable:** `MIGRATION_CACHE_FILE`
- **Precedence:** CLI flag > `MIGRATION_CACHE_FILE` > Default `/tmp/papra-migration-cache.json`

### 3.2 JSON Schema (`v1`)
```json
{
  "version": 1,
  "updated_at": "2026-10-04T21:00:00Z",
  "documents": {
    "1": {
      "paperless_id": 1,
      "title": "Scanned_20201013-1742",
      "file_name": "Scanned_20201013-1742.pdf",
      "file_size": 2516582,
      "sha256": "2bf3cfc18f133488424213123891238912389123891238912389123891238912",
      "status": "uploaded",
      "papra_id": "01923e4b-7c12-7000-8000-000000000001",
      "paperless_modified": "2021-07-16T10:00:00Z",
      "cached_at": 1728075600
    },
    "2": {
      "paperless_id": 2,
      "title": "IVAN_LAUR_111730",
      "file_name": "IVAN_LAUR_111730.pdf",
      "file_size": 16357785,
      "sha256": "39a5489d7764...",
      "status": "uploaded",
      "papra_id": "01923e4b-7c12-7000-8000-000000000002",
      "paperless_modified": "2018-09-20T14:32:00Z",
      "cached_at": 1728075605
    }
  }
}
```

### 3.3 Field Definitions
| Field | Type | Description |
|---|---|---|
| `paperless_id` | integer | Paperless document ID (unique primary key) |
| `title` | string | Document title in Paperless |
| `file_name` | string | Original filename (or fallback `<title>.bin`) |
| `file_size` | integer | Size of the original file in bytes |
| `sha256` | string | Hex SHA-256 digest of the downloaded file payload |
| `status` | string | `uploaded` (present in Papra), `duplicate` (rejected with 409), `pending` (cached metadata, not yet uploaded), `failed` (failed during upload) |
| `papra_id` | string \| null | Papra document UUID if available |
| `paperless_modified` | string \| null | The `modified` ISO timestamp from Paperless |
| `cached_at` | integer | Epoch timestamp of when this entry was created/updated |

---

## 4. Interaction with Existing `MigrationState`

Currently, `paperless-to-papra.state.json` stores:
```json
{
  "uploaded": {
    "<sha256>": {
      "paperlessId": 1,
      "papraDocumentId": "...",
      "at": 1728075600
    }
  }
}
```

### Dual-Layer Operation & Auto-Seeding
1. **Cold-Start Auto-Seeding**: When `/tmp/papra-migration-cache.json` does not exist or is empty, the cache loader can automatically import known records from `paperless-to-papra.state.json`. Since `state.json` already contains 106 uploaded items, those 106 items will not need to be re-downloaded even on a fresh `/tmp` cache start!
2. **Dual Sync**:
   - `MigrationState` tracks SHA-256 -> Papra document mapping.
   - `MigrationCache` tracks Paperless ID -> Document details + Status.
   - When an upload completes, both `MigrationCache` and `MigrationState` are updated and atomically saved.

---

## 5. Workflow & Scanning Logic

### Phase 1: Scanning Loop
For each document yielded by `paperless.documents()`:
1. **Cache Lookup**: Check if `doc.id` is present in cache.
2. **Cache Hit & Already Uploaded (`status in ("uploaded", "duplicate")`)**:
   - Check cache invalidation (optional: if `doc.modified != entry.paperless_modified`, treat as modified).
   - If valid: Log cache hit with zero network download:
     ```text
     [1] Scanning #1 'Scanned_20201013-1742' [2021-07-16] ...
          -> [cache hit] 2.4 MB, sha256=2bf3cfc18f13… (already uploaded, skipping)
     ```
   - Advance to next document without issuing any HTTP download request!
3. **Cache Miss or Not Uploaded (`status not in ("uploaded", "duplicate")`)**:
   - Download the file bytes via `paperless.download_original(doc.id)`.
   - Calculate SHA-256 digest and file size.
   - Check if `state.is_uploaded(digest)`.
   - If already uploaded:
     - Update cache: `status = "uploaded"`, `sha256 = digest`, `file_size = ...`.
     - Log status and skip.
   - If not uploaded:
     - Append `(doc, file_bytes, digest, filename)` to in-memory `pending` queue.
     - **Do NOT populate cache here!** The record has not been uploaded or processed yet.
     - Log download and queue status.
   - If `len(pending) >= config.max_records`: stop scan.

### Phase 2: Upload Phase
For each item in `pending`:
1. Upload file to Papra (`papra.upload_document(filename, file_bytes)`).
2. If HTTP 409 Conflict (duplicate):
   - Mark `state.mark(digest, doc.id, None)`.
   - Update cache: `cache.put(doc.id, ..., status="duplicate")`.
3. If HTTP 201 Created:
   - Apply Paperless tags and document type as Papra tags.
   - Set recipient custom property.
   - Set document date.
   - **Only after all processing succeeds**:
     - Mark `state.mark(digest, doc.id, papra_id)`.
     - Update cache: `cache.put(doc.id, ..., status="uploaded", papra_id=papra_id)`.
4. If Exception / failure:
   - Record in `failed_docs`.
   - **Do NOT populate cache!** Remove any existing entry via `cache.remove(doc.id)` so failures are retried cleanly on subsequent runs.
5. Save state and cache atomically to disk.

---

## 6. Purge & Invalidation Handling

When `--purge-org` is invoked:
- All documents in the target Papra organisation are deleted.
- Existing `state.clear()` clears the SHA-256 dedup records.
- For the cache: all entries with `status in ("uploaded", "duplicate")` are reset to `status = "pending"` (or cleared), preserving their cached `sha256`, `file_name`, and `file_size` so the subsequent migration run does not need to re-download 5,000 files to recalculate hashes.

---

## 7. Configuration & CLI Flags

| CLI Flag | Env Variable | Default | Description |
|---|---|---|---|
| `--cache-file PATH` | `MIGRATION_CACHE_FILE` | `/tmp/papra-migration-cache.json` | Path to JSON cache file |
| `--refresh-cache` | `REFRESH_CACHE` | `false` | Force re-downloading files and recalculating hashes |
| `--reset-cache` | `RESET_CACHE` | `false` | Reset / clear the JSON migration cache (and state) before running |
| `--reset-cache-only` | - | `false` | Clear the cache (and state) and exit immediately |
| `--no-cache` | `NO_CACHE` | `false` | Bypass cache lookup and caching entirely |

---

## 8. Validated Design Decisions

1. **Cache Seeding from Existing State:**
   - **Decision:** Pre-populate the cache from the existing `paperless-to-papra.state.json` on cold start so that the ~106 documents already migrated do not require re-downloading.
2. **Handling Modified Documents:**
   - **Decision:** Automatically re-download and recalculate the SHA-256 hash if the Paperless document's `modified` timestamp is newer than `cached_at`.
3. **Purge Behavior:**
   - **Decision:** When `--purge-org` is executed, reset document status to `pending` in the cache while preserving file names, sizes, and SHA-256 hashes to prevent re-downloading all documents during subsequent migrations.
