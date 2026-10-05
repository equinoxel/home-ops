#!/usr/bin/env python3
"""Migrate documents from Paperless-ngx into Papra.

This script copies documents from a `Paperless-ngx <https://docs.paperless-ngx.com/>`_
instance into a `Papra <https://docs.papra.app/>`_ instance, preserving as much
organisational metadata as the two systems allow.

What it does
------------
1. Reads every tag from Paperless and recreates any missing tag in Papra
   (matched by name, case-insensitively).
2. Reads every Paperless *document type* and recreates it as a Papra **tag**
   (document types do not exist as a first-class concept in Papra, so they are
   folded into the tag namespace).
3. Reads every Paperless *correspondent* and recreates it as an option of a
   Papra **custom property** (a "custom category") named ``Recipient`` by
   default. Each uploaded document gets its correspondent set as that property.
4. Records the Paperless owner (user) of each document as a tag of the form
   ``paperless_<username>`` so ownership survives the migration until Papra
   grows a better model for it.
5. Deduplicates uploads. Papra rejects byte-identical uploads server-side with
   an HTTP 409 (it hashes content with SHA-256). To avoid re-downloading and
   re-uploading on every run, the script also keeps a local state file keyed by
   the SHA-256 of each Paperless document's original file. A document already
   present in that state (or rejected by Papra as a duplicate) is skipped and
   does **not** count against the per-run upload budget.
6. Uploads at most ``MAX_RECORDS`` not-yet-uploaded documents per run, so the
   migration can be run incrementally.
7. Shows a progress bar while uploading.
8. Uploads everything into the Papra organisation named ``Inbox`` by default.

Configuration
-------------
All settings are read from environment variables (optionally sourced from an
env file, ``scripts/.local-papra.env`` by default) and may be overridden with
command-line flags. Run with ``--help`` for the full list.

Dependencies
------------
Standard library only (``urllib``, ``hashlib``, ``json``, ``argparse``). No
``pip install`` required, so it runs with any Python 3.9+ interpreter.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import mimetypes
import os
import re
import socket
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator
from urllib import error as urllib_error
from urllib import request as urllib_request
from urllib.parse import unquote as urllib_unquote, urlencode, urljoin

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

#: Default path of the env file holding working variables.
DEFAULT_ENV_FILE = Path(__file__).resolve().parent / ".local-papra.env"

#: Default path of the JSON migration cache.
DEFAULT_CACHE_FILE = Path("/tmp/papra-migration-cache.json")

#: Default Papra organisation to upload into.
DEFAULT_ORGANIZATION = "Inbox"

#: Default name of the Papra custom property used to hold Paperless recipients.
DEFAULT_RECIPIENT_PROPERTY = "Recipient"

#: Default colour applied to tags created in Papra (hex, Papra requires it).
DEFAULT_TAG_COLOR = "#6b7280"

#: Prefix used when turning a Paperless user into a Papra tag.
USER_TAG_PREFIX = "paperless_"

#: HTTP status Papra returns when a byte-identical document already exists.
HTTP_CONFLICT = 409

#: Papra error code returned when an organisation hits its tag cap.
TAG_LIMIT_CODE = "tags.organization_limit_reached"

#: Network timeout (seconds) applied to every HTTP request.
HTTP_TIMEOUT = 120

#: Default number of retries for transient HTTP / network errors.
DEFAULT_RETRIES = 5


# --------------------------------------------------------------------------- #
# Small utilities
# --------------------------------------------------------------------------- #

def log(message: str) -> None:
    """Write a status line to stderr (keeps stdout clean for data)."""
    print(message, file=sys.stderr, flush=True)


def format_bytes(num_bytes: int | None) -> str:
    """Format a byte count into a human-readable string (B, KB, MB)."""
    if num_bytes is None:
        return "unknown size"
    if num_bytes < 1024:
        return f"{num_bytes} B"
    if num_bytes < 1024 * 1024:
        return f"{num_bytes / 1024:.1f} KB"
    return f"{num_bytes / (1024 * 1024):.1f} MB"


def load_env_file(path: Path) -> dict[str, str]:
    """Parse a ``KEY=VALUE`` env file into a dict.

    Lines that are blank or start with ``#`` are ignored. Surrounding quotes
    and whitespace around the value are stripped. Values are **not** exported
    into ``os.environ``; the caller decides precedence.
    """
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'").strip()
        if key:
            values[key] = value
    return values


class ProgressBar:
    """A minimal, dependency-free terminal progress bar.

    Renders to stderr so it does not pollute piped stdout. If stderr is not a
    TTY (e.g. output is redirected to a file), it degrades to periodic plain
    lines instead of carriage-return redraws.
    """

    def __init__(self, total: int, prefix: str = "Uploading", width: int = 32) -> None:
        self.total = max(total, 0)
        self.prefix = prefix
        self.width = width
        self.count = 0
        self._is_tty = sys.stderr.isatty()
        self._render()

    def update(self, step: int = 1, suffix: str = "") -> None:
        """Advance the bar by ``step`` and optionally show a trailing note."""
        self.count = min(self.count + step, self.total) if self.total else self.count + step
        self._render(suffix)

    def _render(self, suffix: str = "") -> None:
        total = self.total or 1
        filled = int(self.width * self.count / total)
        bar = "#" * filled + "-" * (self.width - filled)
        pct = int(100 * self.count / total)
        line = f"{self.prefix} [{bar}] {self.count}/{self.total} ({pct:3d}%) {suffix}"
        if self._is_tty:
            sys.stderr.write("\r" + line[:120].ljust(120))
        else:
            sys.stderr.write(line + "\n")
        sys.stderr.flush()

    def close(self) -> None:
        """Finish the bar with a trailing newline."""
        if self._is_tty:
            sys.stderr.write("\n")
        sys.stderr.flush()


def _write_form_fields(buf: io.BytesIO, boundary: str, fields: dict[str, str]) -> None:
    """Append simple (non-file) form fields to a multipart buffer."""
    for name, value in fields.items():
        buf.write(f"--{boundary}\r\n".encode("utf-8"))
        buf.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        buf.write(f"{value}\r\n".encode("utf-8"))


def build_multipart(fields: dict[str, str], file_field: str,
                    filename: str, file_bytes: bytes,
                    content_type: str) -> tuple[bytes, str]:
    """Encode a multipart/form-data body with one file part (stdlib only).

    Returns ``(body, content_type_header)``. Using a hand-rolled encoder keeps
    the script free of the ``requests`` dependency.
    """
    boundary = f"----paperless2papra{uuid.uuid4().hex}"
    buf = io.BytesIO()
    _write_form_fields(buf, boundary, fields)

    buf.write(f"--{boundary}\r\n".encode("utf-8"))
    buf.write(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
        .encode("utf-8")
    )
    buf.write(f"Content-Type: {content_type}\r\n\r\n".encode("utf-8"))
    buf.write(file_bytes)
    buf.write(b"\r\n")
    buf.write(f"--{boundary}--\r\n".encode("utf-8"))

    return buf.getvalue(), f"multipart/form-data; boundary={boundary}"


# --------------------------------------------------------------------------- #
# HTTP client
# --------------------------------------------------------------------------- #

@dataclass
class HttpResponse:
    """A tiny HTTP response wrapper."""

    status: int
    body: bytes
    headers: dict[str, str]

    def json(self) -> Any:
        """Decode the body as JSON, or return ``None`` when empty."""
        if not self.body:
            return None
        return json.loads(self.body.decode("utf-8"))


class HttpClient:
    """Thin ``urllib`` wrapper that adds auth, retries and JSON helpers."""

    def __init__(self, base_url: str, token: str, *,
                 auth_scheme: str = "Bearer", retries: int = DEFAULT_RETRIES) -> None:
        # Guarantee a single trailing slash so urljoin behaves predictably.
        self.base_url = base_url.rstrip("/") + "/"
        self.token = token
        # Papra uses "Bearer <token>"; Paperless-ngx uses "Token <token>".
        self.auth_scheme = auth_scheme
        self.retries = retries

    def _url(self, path: str) -> str:
        return urljoin(self.base_url, path.lstrip("/"))

    def request(self, method: str, path: str, *,
                query: dict[str, Any] | None = None,
                json_body: Any | None = None,
                data: bytes | None = None,
                content_type: str | None = None,
                allow_status: Iterable[int] = (),) -> HttpResponse:
        """Perform an HTTP request with bearer auth and bounded retries.

        ``allow_status`` lists non-2xx statuses that should be returned to the
        caller instead of raising (used for the expected 409 on duplicates).
        """
        url = self._url(path)
        if query:
            # Drop None values so optional params stay optional.
            clean = {k: v for k, v in query.items() if v is not None}
            if clean:
                delimiter = "&" if "?" in url else "?"
                url = f"{url}{delimiter}{urlencode(clean)}"

        body = data
        headers = {"Authorization": f"{self.auth_scheme} {self.token}"}
        if json_body is not None:
            body = json.dumps(json_body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif content_type:
            headers["Content-Type"] = content_type

        last_error: Exception | None = None
        for attempt in range(self.retries + 1):
            req = urllib_request.Request(url, data=body, headers=headers, method=method)
            try:
                with urllib_request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                    return HttpResponse(resp.status, resp.read(), dict(resp.headers))
            except urllib_error.HTTPError as exc:
                status = exc.code
                payload = exc.read()
                if status in allow_status:
                    return HttpResponse(status, payload, dict(exc.headers or {}))
                # Retry transient server / rate-limit errors (408, 429, 5xx); fail fast on client 4xx.
                is_retryable = status == 408 or status == 429 or (500 <= status < 600)
                if is_retryable and attempt < self.retries:
                    retry_count = attempt + 1
                    wait = min(2 ** retry_count, 60)
                    retry_after = exc.headers.get("Retry-After") if exc.headers else None
                    if retry_after and retry_after.strip().isdigit():
                        wait = max(wait, int(retry_after.strip()))
                    log(f"  HTTP {status} on {method} {path}; retrying ({retry_count}/{self.retries}) in {wait}s ...")
                    time.sleep(wait)
                    last_error = exc
                    continue
                detail = payload.decode("utf-8", "replace")[:500]
                raise RuntimeError(
                    f"HTTP {status} on {method} {url}: {detail}"
                ) from exc
            except (urllib_error.URLError, TimeoutError, ConnectionResetError, BrokenPipeError, socket.timeout) as exc:
                last_error = exc
                if attempt < self.retries:
                    retry_count = attempt + 1
                    wait = min(2 ** retry_count, 60)
                    reason = getattr(exc, "reason", str(exc))
                    log(f"  Network error on {method} {path} ({reason}); retrying ({retry_count}/{self.retries}) in {wait}s ...")
                    time.sleep(wait)
                    continue
                raise RuntimeError(f"Network error on {method} {url}: {exc}") from exc

        raise RuntimeError(f"Request failed after {self.retries} retries: {last_error}")

    def get_json(self, path: str, query: dict[str, Any] | None = None) -> Any:
        """GET and decode JSON."""
        return self.request("GET", path, query=query).json()

    def get_bytes(self, path: str, query: dict[str, Any] | None = None) -> bytes:
        """GET raw bytes (used to download document files)."""
        return self.request("GET", path, query=query).body


# --------------------------------------------------------------------------- #
# Paperless-ngx client
# --------------------------------------------------------------------------- #

@dataclass
class PaperlessDocument:
    """A subset of a Paperless document relevant to the migration."""

    id: int
    title: str
    original_file_name: str | None
    tag_ids: list[int]
    document_type_id: int | None
    correspondent_id: int | None
    owner_id: int | None
    created: str | None  # Paperless document date (ISO 8601), used as Papra documentDate.
    modified: str | None = None  # Paperless modification date (ISO 8601).
    archived_file_name: str | None = None


def extract_header_filename(content_disposition: str | None) -> str | None:
    """Extract filename from Content-Disposition header (RFC 5987 / 6266)."""
    if not content_disposition:
        return None
    # 1. Look for RFC 5987 / 6266 filename*=utf-8''... (case-insensitive)
    m = re.search(r"filename\*\s*=\s*(?:[uU][tT][fF]-8'')?([^;]+)", content_disposition)
    if m:
        raw = m.group(1).strip().strip("\"'")
        decoded = urllib_unquote(raw)
        if decoded:
            return decoded
    # 2. Look for regular filename="..."
    m = re.search(r'filename\s*=\s*"?([^";]+)"?', content_disposition)
    if m:
        raw = m.group(1).strip().strip("\"'")
        if raw.startswith("b'") and raw.endswith("'"):
            raw = raw[2:-1]
        if raw:
            return raw
    return None


def resolve_filename(
    doc: PaperlessDocument,
    header_filename: str | None = None,
    content_type: str | None = None,
) -> str:
    """Determine best filename for a document, strictly avoiding '.bin' fallbacks."""
    # 1. Prefer original_file_name if explicitly provided by Paperless
    if doc.original_file_name and doc.original_file_name.strip():
        name = doc.original_file_name.strip()
        if not name.lower().endswith(".bin"):
            return name

    # 2. Prefer header_filename from Content-Disposition if present
    if header_filename and header_filename.strip():
        name = header_filename.strip()
        if not name.lower().endswith(".bin"):
            return name

    # 3. Prefer archived_file_name if present
    if doc.archived_file_name and doc.archived_file_name.strip():
        name = doc.archived_file_name.strip()
        if not name.lower().endswith(".bin"):
            return name

    # 4. Infer extension from Content-Type or title
    title = (doc.title or f"document-{doc.id}").strip()
    if title.lower().endswith(".bin"):
        title = title[:-4].strip() or f"document-{doc.id}"

    # If title already has an extension (like .pdf, .jpg, etc.), use it
    suffix = Path(title).suffix.lower()
    if suffix and suffix != ".bin":
        return title

    ext = ""
    if content_type:
        mime = content_type.split(";")[0].strip().lower()
        ext = mimetypes.guess_extension(mime) or ""
        if ext == ".jpe":
            ext = ".jpg"

    if not ext or ext.lower() == ".bin":
        ext = ".pdf"

    return f"{title}{ext}"


class PaperlessClient:
    """Read-only access to the Paperless-ngx REST API."""

    def __init__(self, http: HttpClient) -> None:
        self.http = http

    def _paginate(self, path: str, query: dict[str, Any] | None = None) -> Iterator[dict[str, Any]]:
        """Yield every result across all pages of a list endpoint."""
        page = 1
        base_query = dict(query) if query else {}
        while True:
            params = {"page": page, "page_size": 100}
            params.update(base_query)
            data = self.http.get_json(path, query=params)
            results = data.get("results", []) if isinstance(data, dict) else []
            yield from results
            if not isinstance(data, dict) or not data.get("next"):
                return
            page += 1

    def id_name_map(self, resource: str, name_field: str = "name") -> dict[int, str]:
        """Build an ``{id: name}`` map for a simple Paperless resource."""
        mapping: dict[int, str] = {}
        for item in self._paginate(f"api/{resource}/"):
            mapping[item["id"]] = item.get(name_field) or f"{resource}-{item['id']}"
        return mapping

    def users(self) -> dict[int, str]:
        """Return ``{user_id: username}``.

        The Paperless ``/api/users/`` endpoint commonly requires elevated
        permissions. If the token's user cannot list users (HTTP 401/403), we
        degrade gracefully and return an empty map; callers then fall back to a
        ``paperless_user_<id>`` tag so ownership is still recorded.
        """
        try:
            return self.id_name_map("users", name_field="username")
        except RuntimeError as exc:
            if " 401" in str(exc) or " 403" in str(exc):
                log("  Note: cannot list Paperless users (permission denied); "
                    "owner tags will use numeric ids.")
                return {}
            raise

    def tags(self) -> dict[int, str]:
        """Return ``{tag_id: name}``."""
        return self.id_name_map("tags")

    def document_types(self) -> dict[int, str]:
        """Return ``{document_type_id: name}``."""
        return self.id_name_map("document_types")

    def correspondents(self) -> dict[int, str]:
        """Return ``{correspondent_id: name}``."""
        return self.id_name_map("correspondents")

    def documents(self) -> Iterator[PaperlessDocument]:
        """Yield every document (metadata only), oldest first for stable runs."""
        for item in self._paginate("api/documents/", query={"ordering": "added"}):
            yield PaperlessDocument(
                id=item["id"],
                title=item.get("title") or f"document-{item['id']}",
                original_file_name=item.get("original_file_name"),
                archived_file_name=item.get("archived_file_name"),
                tag_ids=item.get("tags") or [],
                document_type_id=item.get("document_type"),
                correspondent_id=item.get("correspondent"),
                owner_id=item.get("owner"),
                # Paperless exposes the document date as "created" (ISO 8601).
                created=item.get("created"),
                modified=item.get("modified"),
            )

    def download_original(self, document_id: int) -> tuple[bytes, str | None, str | None]:
        """Download the *original* file bytes for a document.

        ``original=true`` ensures we fetch the exact bytes Paperless ingested,
        which keeps the SHA-256 stable across runs.
        Returns ``(file_bytes, header_filename, content_type)``.
        """
        resp = self.http.request(
            "GET",
            f"api/documents/{document_id}/download/",
            query={"original": "true"},
        )
        lower_headers = {k.lower(): v for k, v in resp.headers.items()}
        disposition = lower_headers.get("content-disposition")
        content_type = lower_headers.get("content-type")
        header_filename = extract_header_filename(disposition)
        return resp.body, header_filename, content_type


# --------------------------------------------------------------------------- #
# Papra client
# --------------------------------------------------------------------------- #

class PapraClient:
    """Access to the Papra REST API, scoped to a single organisation."""

    def __init__(self, http: HttpClient) -> None:
        self.http = http
        self.organization_id: str | None = None

    # -- organisations ----------------------------------------------------- #

    def resolve_organization(self, name: str) -> str:
        """Find the organisation id by name and cache it on the client."""
        data = self.http.get_json("api/organizations")
        orgs = data.get("organizations", []) if isinstance(data, dict) else []
        for org in orgs:
            if org.get("name", "").strip().lower() == name.strip().lower():
                self.organization_id = org["id"]
                return org["id"]
        available = ", ".join(sorted(o.get("name", "?") for o in orgs)) or "(none)"
        raise RuntimeError(
            f"Papra organisation {name!r} not found. Available: {available}"
        )

    def _org_path(self, suffix: str) -> str:
        if not self.organization_id:
            raise RuntimeError("Organisation not resolved; call resolve_organization first.")
        return f"api/organizations/{self.organization_id}/{suffix.lstrip('/')}"

    # -- tags -------------------------------------------------------------- #

    def list_tags(self) -> dict[str, str]:
        """Return existing tags as ``{lowercased_name: tag_id}``."""
        data = self.http.get_json(self._org_path("tags"))
        tags = data.get("tags", []) if isinstance(data, dict) else []
        return {t["name"].strip().lower(): t["id"] for t in tags}

    def create_tag(self, name: str, color: str, description: str = "") -> str:
        """Create a tag and return its id.

        Despite the API reference listing form-data, the Papra server validates
        this endpoint against a JSON body, so we send JSON.
        """
        payload: dict[str, str] = {"name": name, "color": color}
        if description:
            payload["description"] = description
        resp = self.http.request(
            "POST", self._org_path("tags"), json_body=payload,
        )
        return resp.json()["tag"]["id"]

    def add_tag_to_document(self, document_id: str, tag_id: str) -> None:
        """Associate a tag with a document (idempotent enough for our use)."""
        self.http.request(
            "POST", self._org_path(f"documents/{document_id}/tags"),
            json_body={"tagId": tag_id},
            allow_status=(HTTP_CONFLICT,),
        )

    # -- custom properties (the "recipient category") --------------------- #

    def find_custom_property(self, name: str) -> dict[str, Any] | None:
        """Return the custom property definition matching ``name``, if any."""
        data = self.http.get_json(self._org_path("custom-properties"))
        defs = data.get("propertyDefinitions", []) if isinstance(data, dict) else []
        for definition in defs:
            if definition.get("name", "").strip().lower() == name.strip().lower():
                return definition
        return None

    def create_select_property(self, name: str, options: list[str]) -> dict[str, Any]:
        """Create a ``select`` custom property with the given options."""
        resp = self.http.request(
            "POST", self._org_path("custom-properties"),
            json_body={
                "name": name,
                "type": "select",
                "description": "Imported Paperless-ngx correspondents",
                "options": [{"name": opt} for opt in options],
            },
        )
        return resp.json()["propertyDefinition"]

    def update_property_options(self, property_id: str, name: str,
                                options: list[dict[str, Any]]) -> dict[str, Any]:
        """Replace/extend the options on an existing select property."""
        resp = self.http.request(
            "PUT", self._org_path(f"custom-properties/{property_id}"),
            json_body={"name": name, "options": options},
        )
        return resp.json()["propertyDefinition"]

    def set_document_property(self, document_id: str, property_id: str, value: str) -> None:
        """Set a custom property value (the select option id) on a document."""
        self.http.request(
            "PUT",
            self._org_path(f"documents/{document_id}/custom-properties/{property_id}"),
            json_body={"value": value},
        )

    # -- documents --------------------------------------------------------- #

    def set_document_date(self, document_id: str, iso_date: str) -> None:
        """Set a document's date via PATCH.

        Papra's upload endpoint ignores dates, so the Paperless ``created`` date
        is applied afterwards. The ``documentDate`` field accepts an ISO 8601
        string (the server coerces it to a Date).
        """
        self.http.request(
            "PATCH", self._org_path(f"documents/{document_id}"),
            json_body={"documentDate": iso_date},
        )

    def upload_document(self, filename: str, file_bytes: bytes) -> tuple[str | None, bool]:
        """Upload a document.

        Returns ``(document_id, created)``. ``created`` is ``False`` when Papra
        rejected the upload as a duplicate (HTTP 409), in which case
        ``document_id`` is ``None`` because the endpoint does not return the
        pre-existing document.
        """
        content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        body, header = build_multipart(
            fields={}, file_field="file", filename=filename,
            file_bytes=file_bytes, content_type=content_type,
        )
        try:
            resp = self.http.request(
                "POST", self._org_path("documents"),
                data=body, content_type=header,
                allow_status=(HTTP_CONFLICT,),
            )
        except RuntimeError as exc:
            if "Connection reset by peer" in str(exc) or "104" in str(exc):
                raise RuntimeError(
                    f"Connection reset by peer during upload of {filename!r} ({format_bytes(len(file_bytes))}). "
                    f"Papra likely rejected the file as too large (check DOCUMENT_STORAGE_MAX_UPLOAD_SIZE in Papra)."
                ) from exc
            raise
        if resp.status == HTTP_CONFLICT:
            return None, False
        return resp.json()["document"]["id"], True

    def iter_documents(self) -> Iterator[dict[str, Any]]:
        """Yield every (non-deleted) document in the organisation, paginated."""
        page_index = 0
        page_size = 100
        while True:
            data = self.http.get_json(
                self._org_path("documents"),
                query={"pageIndex": page_index, "pageSize": page_size},
            )
            docs = data.get("documents", []) if isinstance(data, dict) else []
            if not docs:
                return
            yield from docs
            if len(docs) < page_size:
                return
            page_index += 1

    def count_documents(self) -> int:
        """Return the total number of (non-deleted) documents in the org."""
        data = self.http.get_json(self._org_path("documents"),
                                  query={"pageIndex": 0, "pageSize": 1})
        if isinstance(data, dict) and "documentsCount" in data:
            return int(data["documentsCount"])
        return 0

    def delete_document(self, document_id: str) -> None:
        """Delete a document by id (Papra returns 204)."""
        self.http.request(
            "DELETE", self._org_path(f"documents/{document_id}"),
            allow_status=(404,),
        )


# --------------------------------------------------------------------------- #
# Local state (dedup across runs)
# --------------------------------------------------------------------------- #

@dataclass
class MigrationState:
    """Tracks which Paperless documents have already been handled.

    Keyed by the SHA-256 of the original file so that re-runs skip work even if
    Paperless document ids change. Persisted as JSON next to the env file.
    """

    path: Path
    uploaded: dict[str, dict[str, Any]] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> "MigrationState":
        if path.is_file():
            raw = json.loads(path.read_text(encoding="utf-8"))
            return cls(path=path, uploaded=raw.get("uploaded", {}))
        return cls(path=path)

    def is_uploaded(self, sha256: str) -> bool:
        return sha256 in self.uploaded

    def mark(self, sha256: str, paperless_id: int, papra_id: str | None) -> None:
        self.uploaded[sha256] = {
            "paperlessId": paperless_id,
            "papraDocumentId": papra_id,
            "at": int(time.time()),
        }

    def clear(self) -> None:
        """Forget all recorded uploads (used after a purge)."""
        self.uploaded.clear()

    def save(self) -> None:
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps({"uploaded": self.uploaded}, indent=2), encoding="utf-8")
        tmp.replace(self.path)


@dataclass
class MigrationCache:
    """Tracks cached Paperless document payloads, hashes and upload statuses.

    Avoids re-downloading files across migration runs by caching SHA-256 digests,
    file sizes, and Papra upload status keyed by Paperless document ID.
    Persisted at /tmp/papra-migration-cache.json by default.
    """

    path: Path
    documents: dict[str, dict[str, Any]] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> "MigrationCache":
        if path.is_file():
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
                docs = raw.get("documents", {}) if isinstance(raw, dict) else {}
                return cls(path=path, documents=docs)
            except Exception as exc:
                log(f"  Warning: failed to load cache from {path} ({exc}); starting fresh.")
                return cls(path=path)
        return cls(path=path)

    def seed_from_state(self, state: "MigrationState") -> int:
        """Import known uploaded documents from state into cache if not present."""
        added = 0
        for digest, item in state.uploaded.items():
            pid = item.get("paperlessId")
            if pid is not None:
                spid = str(pid)
                if spid not in self.documents:
                    self.documents[spid] = {
                        "paperless_id": int(pid),
                        "title": f"document-{pid}",
                        "file_name": None,
                        "file_size": None,
                        "sha256": digest,
                        "status": "uploaded" if item.get("papraDocumentId") else "duplicate",
                        "papra_id": item.get("papraDocumentId"),
                        "paperless_modified": None,
                        "cached_at": item.get("at", int(time.time())),
                    }
                    added += 1
        return added

    def get(self, doc_id: int) -> dict[str, Any] | None:
        return self.documents.get(str(doc_id))

    def put(self, doc_id: int, *,
            title: str,
            file_name: str | None,
            file_size: int | None,
            sha256: str,
            status: str,
            papra_id: str | None = None,
            paperless_modified: str | None = None) -> None:
        self.documents[str(doc_id)] = {
            "paperless_id": doc_id,
            "title": title,
            "file_name": file_name,
            "file_size": file_size,
            "sha256": sha256,
            "status": status,
            "papra_id": papra_id,
            "paperless_modified": paperless_modified,
            "cached_at": int(time.time()),
        }

    def update_status(self, doc_id: int, status: str, papra_id: str | None = None) -> None:
        key = str(doc_id)
        if key in self.documents:
            self.documents[key]["status"] = status
            if papra_id is not None:
                self.documents[key]["papra_id"] = papra_id
            self.documents[key]["cached_at"] = int(time.time())

    def reset_for_purge(self) -> None:
        """Reset all uploaded/duplicate statuses to pending after a purge."""
        for item in self.documents.values():
            if item.get("status") in ("uploaded", "duplicate"):
                item["status"] = "pending"
                item["papra_id"] = None
                item["cached_at"] = int(time.time())

    def save(self) -> None:
        tmp = self.path.with_suffix(self.path.suffix + f".tmp.{uuid.uuid4().hex[:6]}")
        payload = {
            "version": 1,
            "updated_at": int(time.time()),
            "documents": self.documents,
        }
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        tmp.replace(self.path)


# --------------------------------------------------------------------------- #
# Migration orchestration
# --------------------------------------------------------------------------- #

@dataclass
class Config:
    """Resolved runtime configuration."""

    papra_url: str
    papra_key: str
    paperless_url: str
    paperless_key: str
    max_records: int
    upload_delay: float
    retries: int
    organization: str
    recipient_property: str
    tag_color: str
    state_file: Path
    cache_file: Path
    report_file: Path
    dry_run: bool
    purge: bool
    assume_yes: bool
    no_cache: bool = False
    refresh_cache: bool = False


def sha256_bytes(data: bytes) -> str:
    """Return the hex SHA-256 of ``data`` (matches Papra's dedup hash)."""
    return hashlib.sha256(data).hexdigest()


def ensure_tags(papra: PapraClient, names: Iterable[str], color: str) -> dict[str, str]:
    """Ensure every name in ``names`` exists as a Papra tag.

    Returns ``{lowercased_name: tag_id}`` covering both pre-existing and newly
    created tags. If the organisation reaches its tag limit, the remaining tags
    are skipped with a single warning (documents still upload and keep whatever
    tags already exist).
    """
    existing = papra.list_tags()
    limit_hit = False
    created = 0
    for name in sorted({n for n in names if n}):
        key = name.strip().lower()
        if key in existing:
            continue
        if limit_hit:
            continue
        try:
            existing[key] = papra.create_tag(name, color)
            created += 1
        except RuntimeError as exc:
            if TAG_LIMIT_CODE in str(exc):
                limit_hit = True
                log(f"  Warning: Papra tag limit reached after creating {created} tag(s); "
                    "remaining tags will be skipped. Raise the org tag limit to import them all.")
                continue
            raise
    return existing


def ensure_recipient_property(papra: PapraClient, prop_name: str,
                              correspondents: Iterable[str]) -> tuple[str, dict[str, str]]:
    """Ensure the recipient custom property exists with all correspondents.

    Returns ``(property_id, {lowercased_option_name: option_id})``.
    """
    wanted = [c for c in correspondents if c]
    definition = papra.find_custom_property(prop_name)

    if definition is None:
        log(f"  Creating custom property {prop_name!r} with {len(wanted)} options")
        definition = papra.create_select_property(prop_name, wanted)
    else:
        # Add any options that are missing without dropping existing ones.
        current = definition.get("options", []) or []
        current_names = {o.get("name", "").strip().lower() for o in current}
        missing = [c for c in wanted if c.strip().lower() not in current_names]
        if missing:
            log(f"  Adding {len(missing)} new option(s) to {prop_name!r}")
            merged = [{"id": o["id"], "name": o["name"]} for o in current]
            merged += [{"name": c} for c in missing]
            definition = papra.update_property_options(
                definition["id"], definition.get("name", prop_name), merged,
            )

    option_map = {
        o.get("name", "").strip().lower(): o["id"]
        for o in (definition.get("options", []) or [])
    }
    return definition["id"], option_map


SIZE_BUCKETS = [
    "< 100 KB",
    "100 KB - 1 MB",
    "1 MB - 5 MB",
    "5 MB - 25 MB",
    "> 25 MB",
    "Unknown size",
]


def size_bucket(size_bytes: int | None) -> str:
    """Return standard size bucket label for a given byte count."""
    if size_bytes is None:
        return "Unknown size"
    if size_bytes < 100 * 1024:
        return "< 100 KB"
    if size_bytes < 1024 * 1024:
        return "100 KB - 1 MB"
    if size_bytes < 5 * 1024 * 1024:
        return "1 MB - 5 MB"
    if size_bytes < 25 * 1024 * 1024:
        return "5 MB - 25 MB"
    return "> 25 MB"


def extract_doc_tags(doc: PaperlessDocument, pl_tags: dict[int, str], pl_doc_types: dict[int, str]) -> list[str]:
    """Extract all classification tags (Paperless tags + document type) for reporting."""
    tags = [pl_tags[t] for t in doc.tag_ids if t in pl_tags]
    if doc.document_type_id in pl_doc_types:
        dt = pl_doc_types[doc.document_type_id]
        if dt not in tags:
            tags.append(dt)
    return tags


@dataclass
class ProcessedDoc:
    """Statistics entry for a document processed during the migration run."""

    id: int
    name: str
    filename: str
    extension: str
    size_bytes: int | None
    tags: list[str]
    status: str  # "uploaded", "skipped", "failed"


@dataclass
class FailedDocument:
    """Details of a document that failed during migration."""

    id: int
    name: str
    extension: str
    reason: str


def format_report_text(
    uploaded: int,
    skipped: int,
    failed_docs: list[FailedDocument],
    processed_docs: list[ProcessedDoc],
) -> str:
    """Format human-readable migration summary with breakdown statistics."""
    total = len(processed_docs) or (uploaded + skipped + len(failed_docs))

    # Extension breakdown
    by_ext: dict[str, int] = {}
    for d in processed_docs:
        ext_key = f".{d.extension}" if d.extension and d.extension != "none" else "(no extension)"
        by_ext[ext_key] = by_ext.get(ext_key, 0) + 1
    sorted_ext = sorted(by_ext.items(), key=lambda item: (-item[1], item[0]))

    # Size range breakdown
    by_size: dict[str, int] = {b: 0 for b in SIZE_BUCKETS}
    for d in processed_docs:
        b = size_bucket(d.size_bytes)
        by_size[b] = by_size.get(b, 0) + 1

    # Tag breakdown
    by_tag: dict[str, int] = {}
    for d in processed_docs:
        if not d.tags:
            by_tag["(untagged)"] = by_tag.get("(untagged)", 0) + 1
        else:
            for t in d.tags:
                by_tag[t] = by_tag.get(t, 0) + 1
    sorted_tags = sorted(by_tag.items(), key=lambda item: (-item[1], item[0]))

    lines: list[str] = []
    lines.append("=" * 70)
    lines.append("MIGRATION REPORT")
    lines.append("=" * 70)
    lines.append(f"  Updated / Uploaded:  {uploaded}")
    lines.append(f"  Skipped (duplicate): {skipped}")
    lines.append(f"  Failed:              {len(failed_docs)}")
    lines.append(f"  Total processed:     {total}")
    lines.append("")
    lines.append("-" * 70)
    lines.append("Statistics by Extension:")
    if sorted_ext:
        for ext, count in sorted_ext:
            lines.append(f"  {ext.ljust(20)} {count}")
    else:
        lines.append("  (none)")
    lines.append("")
    lines.append("-" * 70)
    lines.append("Statistics by Size Range:")
    for b in SIZE_BUCKETS:
        count = by_size.get(b, 0)
        if b != "Unknown size" or count > 0:
            lines.append(f"  {b.ljust(20)} {count}")
    lines.append("")
    lines.append("-" * 70)
    lines.append(f"Statistics by Tag ({len(by_tag)} unique):")
    if sorted_tags:
        for tag, count in sorted_tags:
            lines.append(f"  {tag.ljust(30)} {count}")
    else:
        lines.append("  (none)")
    lines.append("")
    lines.append("-" * 70)
    if failed_docs:
        lines.append(f"Failed Documents ({len(failed_docs)}):")
        for fdoc in failed_docs:
            lines.append(f"  * ID:        {fdoc.id}")
            lines.append(f"    Name:      {fdoc.name}")
            lines.append(f"    Extension: {fdoc.extension}")
            lines.append(f"    Reason:    {fdoc.reason}")
    else:
        lines.append("Failed Documents (0):")
        lines.append("  Status: All attempted documents processed successfully.")
    lines.append("=" * 70)
    return "\n".join(lines)


def format_report_json(
    uploaded: int,
    skipped: int,
    failed_docs: list[FailedDocument],
    processed_docs: list[ProcessedDoc],
) -> dict[str, Any]:
    """Format structured migration report as JSON dictionary."""
    total = len(processed_docs) or (uploaded + skipped + len(failed_docs))

    by_ext: dict[str, int] = {}
    for d in processed_docs:
        ext_key = d.extension if d.extension and d.extension != "none" else "unknown"
        by_ext[ext_key] = by_ext.get(ext_key, 0) + 1
    sorted_ext = dict(sorted(by_ext.items(), key=lambda item: (-item[1], item[0])))

    by_size: dict[str, int] = {b: 0 for b in SIZE_BUCKETS}
    for d in processed_docs:
        b = size_bucket(d.size_bytes)
        by_size[b] = by_size.get(b, 0) + 1
    if by_size.get("Unknown size") == 0:
        by_size.pop("Unknown size", None)

    by_tag: dict[str, int] = {}
    for d in processed_docs:
        if not d.tags:
            by_tag["(untagged)"] = by_tag.get("(untagged)", 0) + 1
        else:
            for t in d.tags:
                by_tag[t] = by_tag.get(t, 0) + 1
    sorted_tags = dict(sorted(by_tag.items(), key=lambda item: (-item[1], item[0])))

    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "summary": {
            "uploaded": uploaded,
            "skipped": skipped,
            "failed": len(failed_docs),
            "total": total,
        },
        "statistics": {
            "by_extension": sorted_ext,
            "by_size_range": by_size,
            "by_tag": sorted_tags,
        },
        "failed_documents": [
            {
                "id": fdoc.id,
                "name": fdoc.name,
                "extension": fdoc.extension,
                "reason": fdoc.reason,
            }
            for fdoc in failed_docs
        ],
    }


def write_and_print_report(
    uploaded: int,
    skipped: int,
    failed_docs: list[FailedDocument],
    processed_docs: list[ProcessedDoc],
    report_file: Path,
) -> None:
    """Print the migration report to stderr and save both TXT and JSON versions."""
    text_report = format_report_text(uploaded, skipped, failed_docs, processed_docs)
    json_report = format_report_json(uploaded, skipped, failed_docs, processed_docs)

    log("\n" + text_report)

    try:
        report_file.parent.mkdir(parents=True, exist_ok=True)
        report_file.write_text(text_report + "\n", encoding="utf-8")
        log(f"Report saved to: {report_file}")
    except Exception as exc:
        log(f"Warning: could not write text report to {report_file}: {exc}")

    json_file = report_file.with_suffix(".json")
    try:
        json_file.write_text(json.dumps(json_report, indent=2) + "\n", encoding="utf-8")
        log(f"JSON report saved to: {json_file}")
    except Exception as exc:
        log(f"Warning: could not write JSON report to {json_file}: {exc}")


def resolve_config(args: argparse.Namespace) -> Config:
    """Merge env file, process env and CLI flags into a Config.

    Precedence (highest first): CLI flag > process environment > env file.
    """
    env_file = Path(args.env_file).expanduser()
    file_env = load_env_file(env_file)

    def pick(cli_value: str | None, key: str, default: str | None = None) -> str | None:
        if cli_value is not None:
            return cli_value
        if os.environ.get(key):
            return os.environ[key]
        if file_env.get(key):
            return file_env[key]
        return default

    papra_url = pick(args.papra_url, "PAPRA_URL")
    papra_key = pick(args.papra_key, "PAPRA_KEY")
    paperless_url = pick(args.paperless_url, "PAPERLESS_URL")
    paperless_key = pick(args.paperless_key, "PAPERLESS_KEY")
    max_raw = pick(str(args.max_records) if args.max_records is not None else None,
                   "MAX_RECORDS", "10")
    organization = pick(args.organization, "PAPRA_ORGANIZATION", DEFAULT_ORGANIZATION)
    recipient_property = pick(args.recipient_property, "PAPRA_RECIPIENT_PROPERTY",
                              DEFAULT_RECIPIENT_PROPERTY)
    tag_color = pick(args.tag_color, "PAPRA_TAG_COLOR", DEFAULT_TAG_COLOR)
    delay_raw = pick(str(args.upload_delay) if args.upload_delay is not None else None,
                     "UPLOAD_DELAY_SECONDS", "2")
    retries_raw = pick(str(args.retries) if args.retries is not None else None,
                       "HTTP_RETRIES", str(DEFAULT_RETRIES))
    state_raw = pick(args.state_file, "MIGRATION_STATE_FILE",
                     str(env_file.with_name("paperless-to-papra.state.json")))
    cache_raw = pick(args.cache_file, "MIGRATION_CACHE_FILE",
                     str(DEFAULT_CACHE_FILE))
    report_raw = pick(args.report_file, "MIGRATION_REPORT_FILE",
                      str(Path(cache_raw).with_name("papra-migration-report.txt")))

    # A purge only talks to Papra, so Paperless credentials are not required.
    required = {"PAPRA_URL": papra_url, "PAPRA_KEY": papra_key}
    if not args.purge_org:
        required["PAPERLESS_URL"] = paperless_url
        required["PAPERLESS_KEY"] = paperless_key
    missing = [name for name, value in required.items() if not value]
    if missing:
        raise SystemExit(
            f"Missing required configuration: {', '.join(missing)}.\n"
            f"Set them in {env_file}, the environment, or via CLI flags."
        )

    try:
        max_records = int(str(max_raw).strip())
    except ValueError:
        raise SystemExit(f"MAX_RECORDS must be an integer, got {max_raw!r}")

    try:
        upload_delay = float(str(delay_raw).strip())
    except ValueError:
        raise SystemExit(f"UPLOAD_DELAY_SECONDS must be a number, got {delay_raw!r}")

    try:
        retries = int(str(retries_raw).strip())
    except ValueError:
        raise SystemExit(f"HTTP_RETRIES must be an integer, got {retries_raw!r}")

    return Config(
        papra_url=papra_url,
        papra_key=papra_key,
        paperless_url=paperless_url,
        paperless_key=paperless_key,
        max_records=max_records,
        upload_delay=upload_delay,
        retries=retries,
        organization=organization,
        recipient_property=recipient_property,
        tag_color=tag_color,
        state_file=Path(state_raw).expanduser(),
        cache_file=Path(cache_raw).expanduser(),
        report_file=Path(report_raw).expanduser(),
        dry_run=args.dry_run,
        purge=args.purge_org,
        assume_yes=args.yes,
        no_cache=args.no_cache,
        refresh_cache=args.refresh_cache,
    )


def purge_organization(papra: PapraClient, state: MigrationState,
                       cache: MigrationCache, config: Config) -> int:
    """Delete every document in the target organisation.

    This is destructive and irreversible-ish: Papra moves deleted documents to
    the trash, from which its own retention task eventually hard-deletes them.
    After purging, the local dedup state is cleared so a later migration run
    re-uploads from scratch.
    """
    total = papra.count_documents()
    if total == 0:
        log(f"Organisation {config.organization!r} already has no documents.")
        if state.uploaded:
            state.clear()
            state.save()
        if not config.no_cache:
            cache.reset_for_purge()
            cache.save()
        return 0

    log(f"About to DELETE all {total} document(s) in Papra organisation "
        f"{config.organization!r} (id {papra.organization_id}).")

    if config.dry_run:
        log("[dry-run] No documents were deleted.")
        return 0

    if not config.assume_yes:
        # Require an explicit, typed confirmation for a destructive bulk delete.
        prompt = (f"Type the organisation name {config.organization!r} to confirm "
                  f"deletion of {total} document(s): ")
        try:
            answer = input(prompt).strip()
        except EOFError:
            answer = ""
        if answer != config.organization:
            log("Confirmation did not match; aborting. Nothing was deleted.")
            return 1

    # Collect ids first so pagination is not disturbed by concurrent deletes.
    doc_ids = [d["id"] for d in papra.iter_documents()]
    bar = ProgressBar(total=len(doc_ids), prefix="Deleting")
    deleted = failed = 0
    try:
        for doc_id in doc_ids:
            try:
                papra.delete_document(doc_id)
                deleted += 1
                bar.update(suffix=f"ok {doc_id}")
            except Exception as exc:  # noqa: BLE001 - report and continue
                failed += 1
                bar.update(suffix=f"FAIL {doc_id}")
                log(f"\n  Failed to delete {doc_id}: {exc}")
    finally:
        bar.close()

    # Deleted documents can no longer collide on content, so forget the state.
    state.clear()
    state.save()
    if not config.no_cache:
        cache.reset_for_purge()
        cache.save()

    log(f"Purge done. deleted={deleted} failed={failed}")
    return 1 if failed else 0


def run(config: Config) -> int:
    """Execute the migration (or a purge). Returns a process exit code."""
    papra = PapraClient(
        HttpClient(config.papra_url, config.papra_key, auth_scheme="Bearer", retries=config.retries))
    state = MigrationState.load(config.state_file)
    cache = MigrationCache.load(config.cache_file)

    if not config.no_cache and state.uploaded:
        seeded = cache.seed_from_state(state)
        if seeded > 0:
            log(f"Seeded cache with {seeded} pre-existing document(s) from state file.")
            cache.save()

    log(f"Resolving Papra organisation {config.organization!r} ...")
    papra.resolve_organization(config.organization)

    if config.purge:
        return purge_organization(papra, state, cache, config)

    paperless = PaperlessClient(
        HttpClient(config.paperless_url, config.paperless_key, auth_scheme="Token", retries=config.retries))

    log("Reading Paperless metadata (tags, document types, correspondents, users) ...")
    pl_tags = paperless.tags()
    pl_doc_types = paperless.document_types()
    pl_correspondents = paperless.correspondents()
    pl_users = paperless.users()

    def owner_tag_name(owner_id: int | None) -> str | None:
        """Map a Paperless owner id to its ``paperless_<...>`` tag name.

        Uses the username when it is known; otherwise falls back to the numeric
        id (e.g. when listing users is not permitted for this token).
        """
        if owner_id is None:
            return None
        if owner_id in pl_users:
            return f"{USER_TAG_PREFIX}{pl_users[owner_id]}"
        return f"{USER_TAG_PREFIX}user_{owner_id}"

    # Tags come from three Paperless sources: real tags, document types, and
    # one synthetic "paperless_<user>" tag per owner.
    tag_names: set[str] = set(pl_tags.values())
    tag_names.update(pl_doc_types.values())
    tag_names.update(
        name for name in (owner_tag_name(uid) for uid in pl_users) if name
    )

    if config.dry_run:
        log("[dry-run] Would ensure tags: " + ", ".join(sorted(tag_names)))
        log(f"[dry-run] Would ensure recipient property {config.recipient_property!r} "
            f"with options: " + ", ".join(sorted(pl_correspondents.values())))
    else:
        log("Ensuring tags exist in Papra ...")
    tag_id_by_name = ({} if config.dry_run
                      else ensure_tags(papra, tag_names, config.tag_color))

    if config.dry_run:
        recipient_prop_id, recipient_option_by_name = "", {}
    else:
        log("Ensuring recipient custom property exists in Papra ...")
        try:
            recipient_prop_id, recipient_option_by_name = ensure_recipient_property(
                papra, config.recipient_property, pl_correspondents.values(),
            )
        except RuntimeError as exc:
            # Don't let a custom-property limit or error block document uploads.
            log(f"  Warning: could not fully set up recipient property: {exc}")
            recipient_prop_id, recipient_option_by_name = "", {}

    # Select the next batch of not-yet-uploaded documents.
    log("Scanning Paperless documents for pending uploads ...")
    pending: list[tuple[PaperlessDocument, bytes, str, str]] = []
    failed_docs: list[FailedDocument] = []
    processed_docs: list[ProcessedDoc] = []
    scanned = 0
    for doc in paperless.documents():
        scanned += 1
        tags = extract_doc_tags(doc, pl_tags, pl_doc_types)
        filename = resolve_filename(doc)
        desc = f"#{doc.id} {doc.title!r}"
        if filename != doc.title:
            desc += f" ({filename})"
        if doc.created:
            date_str = doc.created.split("T")[0] if "T" in doc.created else doc.created
            desc += f" [{date_str}]"
        log(f"  [{scanned}] Scanning {desc} ...")

        cached_entry = None if (config.no_cache or config.refresh_cache) else cache.get(doc.id)

        # Check if modified timestamp in Paperless is newer than cached_at
        if cached_entry and doc.modified and cached_entry.get("paperless_modified"):
            if doc.modified > cached_entry["paperless_modified"]:
                log(f"       -> document modified in Paperless ({doc.modified} > {cached_entry['paperless_modified']}); refreshing cache")
                cached_entry = None

        if cached_entry and cached_entry.get("status") in ("uploaded", "duplicate"):
            cached_fn = cached_entry.get("file_name")
            if not cached_fn or cached_fn.lower().endswith(".bin"):
                cached_entry["file_name"] = filename
                cached_entry["title"] = doc.title
                if doc.modified:
                    cached_entry["paperless_modified"] = doc.modified
                if not config.no_cache:
                    cache.save()
            else:
                filename = cached_fn
            size_str = format_bytes(cached_entry.get("file_size"))
            digest = cached_entry.get("sha256", "")
            log(f"       -> [cache hit] {size_str}, sha256={digest[:12]}… (already uploaded, skipping)")
            ext = Path(filename).suffix.lower().lstrip(".") or "pdf"
            processed_docs.append(ProcessedDoc(
                id=doc.id,
                name=doc.title,
                filename=filename,
                extension=ext,
                size_bytes=cached_entry.get("file_size"),
                tags=tags,
                status="skipped",
            ))
            continue

        try:
            file_bytes, header_fn, content_type = paperless.download_original(doc.id)
            filename = resolve_filename(doc, header_filename=header_fn, content_type=content_type)
        except Exception as exc:
            ext = Path(filename).suffix.lower().lstrip(".") or "pdf"
            failed_docs.append(FailedDocument(
                id=doc.id,
                name=doc.title,
                extension=ext,
                reason=f"Download failed: {exc}",
            ))
            processed_docs.append(ProcessedDoc(
                id=doc.id,
                name=doc.title,
                filename=filename,
                extension=ext,
                size_bytes=None,
                tags=tags,
                status="failed",
            ))
            if not config.no_cache:
                cache.update_status(doc.id, status="failed")
                cache.save()
            log(f"       -> download failed: {exc}, skipping")
            continue

        digest = sha256_bytes(file_bytes)
        size_str = format_bytes(len(file_bytes))
        ext = Path(filename).suffix.lower().lstrip(".") or "pdf"

        if state.is_uploaded(digest):
            if not config.no_cache:
                cache.put(
                    doc.id,
                    title=doc.title,
                    file_name=filename,
                    file_size=len(file_bytes),
                    sha256=digest,
                    status="uploaded",
                    paperless_modified=doc.modified,
                )
                cache.save()
            processed_docs.append(ProcessedDoc(
                id=doc.id,
                name=doc.title,
                filename=filename,
                extension=ext,
                size_bytes=len(file_bytes),
                tags=tags,
                status="skipped",
            ))
            log(f"       -> downloaded {size_str}, sha256={digest[:12]}… (already uploaded, skipping)")
            continue

        if not config.no_cache:
            cache.put(
                doc.id,
                title=doc.title,
                file_name=filename,
                file_size=len(file_bytes),
                sha256=digest,
                status="pending",
                paperless_modified=doc.modified,
            )
            cache.save()

        pending.append((doc, file_bytes, digest, filename))
        log(f"       -> downloaded {size_str}, sha256={digest[:12]}… (pending upload {len(pending)}/{config.max_records})")
        if len(pending) >= config.max_records:
            log(f"  Reached limit of {config.max_records} pending document(s); stopping scan.")
            break

    if not pending:
        if scanned == 0:
            log("No documents found in Paperless.")
        elif not failed_docs:
            log(f"Nothing to do: scanned {scanned} document(s), all already uploaded.")
        write_and_print_report(
            uploaded=sum(1 for d in processed_docs if d.status == "uploaded"),
            skipped=sum(1 for d in processed_docs if d.status == "skipped"),
            failed_docs=failed_docs,
            processed_docs=processed_docs,
            report_file=config.report_file,
        )
        return 1 if failed_docs else 0

    log(f"Scanned {scanned} document(s); uploading up to {len(pending)} new one(s).")

    if config.dry_run:
        for doc, file_bytes, digest, filename in pending:
            log(f"[dry-run] Would upload #{doc.id} {doc.title!r} ({filename}, sha256={digest[:12]}…)")
            tags = extract_doc_tags(doc, pl_tags, pl_doc_types)
            ext = Path(filename).suffix.lower().lstrip(".") or "pdf"
            processed_docs.append(ProcessedDoc(
                id=doc.id,
                name=doc.title,
                filename=filename,
                extension=ext,
                size_bytes=len(file_bytes),
                tags=tags,
                status="uploaded",
            ))
        write_and_print_report(
            uploaded=sum(1 for d in processed_docs if d.status == "uploaded"),
            skipped=sum(1 for d in processed_docs if d.status == "skipped"),
            failed_docs=failed_docs,
            processed_docs=processed_docs,
            report_file=config.report_file,
        )
        return 1 if failed_docs else 0

    def tag_id_for(name: str) -> str | None:
        """Return a Papra tag id for ``name``, creating the tag on demand.

        Owner tags for unknown users are only discovered while scanning
        documents, so this lazily creates any tag not seen during the initial
        ensure pass.
        """
        key = name.strip().lower()
        tid = tag_id_by_name.get(key)
        if tid is None:
            try:
                tid = papra.create_tag(name, config.tag_color)
            except RuntimeError as exc:
                if TAG_LIMIT_CODE in str(exc):
                    return None  # Tag cap reached; skip this one tag.
                raise
            tag_id_by_name[key] = tid
        return tid

    bar = ProgressBar(total=len(pending))
    try:
        for doc, file_bytes, digest, filename in pending:
            tags = extract_doc_tags(doc, pl_tags, pl_doc_types)
            ext = Path(filename).suffix.lower().lstrip(".") or "pdf"
            try:
                papra_id, created = papra.upload_document(filename, file_bytes)

                if not created:
                    # Papra already had identical content; record so we skip it
                    # next time without re-downloading.
                    state.mark(digest, doc.id, papra_id)
                    if not config.no_cache:
                        cache.update_status(doc.id, status="duplicate", papra_id=None)
                    processed_docs.append(ProcessedDoc(
                        id=doc.id,
                        name=doc.title,
                        filename=filename,
                        extension=ext,
                        size_bytes=len(file_bytes),
                        tags=tags,
                        status="skipped",
                    ))
                    bar.update(suffix=f"skip #{doc.id} (duplicate)")
                    continue

                # Apply tags: Paperless tags + document type + owner tag.
                tag_targets: list[str] = [pl_tags[t] for t in doc.tag_ids if t in pl_tags]
                if doc.document_type_id in pl_doc_types:
                    tag_targets.append(pl_doc_types[doc.document_type_id])
                owner_tag = owner_tag_name(doc.owner_id)
                if owner_tag:
                    tag_targets.append(owner_tag)

                for name in tag_targets:
                    tid = tag_id_for(name)
                    if tid:
                        papra.add_tag_to_document(papra_id, tid)

                # Set the recipient (correspondent) custom property.
                if recipient_prop_id and doc.correspondent_id in pl_correspondents:
                    recipient_name = pl_correspondents[doc.correspondent_id]
                    option_id = recipient_option_by_name.get(recipient_name.strip().lower())
                    if option_id:
                        papra.set_document_property(papra_id, recipient_prop_id, option_id)

                # Carry over the Paperless document date (Papra ignores it on
                # upload, so it is set explicitly here).
                if doc.created:
                    papra.set_document_date(papra_id, doc.created)

                state.mark(digest, doc.id, papra_id)
                if not config.no_cache:
                    cache.update_status(doc.id, status="uploaded", papra_id=papra_id)
                processed_docs.append(ProcessedDoc(
                    id=doc.id,
                    name=doc.title,
                    filename=filename,
                    extension=ext,
                    size_bytes=len(file_bytes),
                    tags=tags,
                    status="uploaded",
                ))
                bar.update(suffix=f"ok #{doc.id}")
            except Exception as exc:  # noqa: BLE001 - report and continue the batch
                ext = Path(filename).suffix.lower().lstrip(".") or "pdf"
                failed_docs.append(FailedDocument(
                    id=doc.id,
                    name=doc.title,
                    extension=ext,
                    reason=str(exc),
                ))
                processed_docs.append(ProcessedDoc(
                    id=doc.id,
                    name=doc.title,
                    filename=filename,
                    extension=ext,
                    size_bytes=len(file_bytes),
                    tags=tags,
                    status="failed",
                ))
                if not config.no_cache:
                    cache.update_status(doc.id, status="failed")
                bar.update(suffix=f"FAIL #{doc.id}")
                log(f"\n  Failed on Paperless #{doc.id} ({doc.title!r}): {exc}")
            finally:
                # Persist after every document so an interruption loses nothing.
                state.save()
                if not config.no_cache:
                    cache.save()

            # Throttle so Papra's in-process content extraction / auto-tagging
            # does not pile up and spike memory (a tight memory limit can
            # otherwise OOM-kill the server during bulk imports).
            if config.upload_delay > 0:
                time.sleep(config.upload_delay)
    finally:
        bar.close()
        state.save()
        if not config.no_cache:
            cache.save()

    write_and_print_report(
        uploaded=sum(1 for d in processed_docs if d.status == "uploaded"),
        skipped=sum(1 for d in processed_docs if d.status == "skipped"),
        failed_docs=failed_docs,
        processed_docs=processed_docs,
        report_file=config.report_file,
    )
    return 1 if failed_docs else 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    """Construct the argument parser with detailed help."""
    parser = argparse.ArgumentParser(
        prog="paperless-to-papra.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Migrate documents from Paperless-ngx into Papra.\n\n"
            "Configuration is read from an env file (default: scripts/.local-papra.env),\n"
            "overridden by environment variables, overridden by the CLI flags below.\n\n"
            "Behaviour:\n"
            "  * Paperless tags and document types become Papra tags.\n"
            "  * Paperless correspondents become options of a Papra custom property\n"
            "    (a 'custom category', default name 'Recipient').\n"
            "  * The Paperless owner is stored as a tag 'paperless_<username>'.\n"
            "  * Duplicate content is detected via SHA-256 (both a local state file\n"
            "    and Papra's own server-side 409 rejection), so re-runs are safe.\n"
            "  * At most MAX_RECORDS new documents are uploaded per run.\n"
            "  * Everything is uploaded into the 'Inbox' organisation by default."
        ),
        epilog=(
            "Environment variables:\n"
            "  PAPRA_URL                 Base URL of the Papra instance (required)\n"
            "  PAPRA_KEY                 Papra API key / bearer token (required)\n"
            "  PAPERLESS_URL             Base URL of the Paperless-ngx instance (required)\n"
            "  PAPERLESS_KEY             Paperless-ngx API token (required)\n"
            "  MAX_RECORDS               Max new documents to upload per run (default: 10)\n"
            "  UPLOAD_DELAY_SECONDS      Pause between uploads to throttle Papra (default: 2)\n"
            "  HTTP_RETRIES              Times to retry transient HTTP/network errors (default: 5)\n"
            "  PAPRA_ORGANIZATION        Target organisation name (default: Inbox)\n"
            "  PAPRA_RECIPIENT_PROPERTY  Custom property name for recipients (default: Recipient)\n"
            "  PAPRA_TAG_COLOR           Hex colour for created tags (default: #6b7280)\n"
            "  MIGRATION_STATE_FILE      Path to the local dedup state JSON\n"
            "  MIGRATION_CACHE_FILE      Path to the local migration cache JSON\n"
            "  MIGRATION_REPORT_FILE     Path to write the migration report\n\n"
            "Examples:\n"
            "  ./paperless-to-papra.py\n"
            "  ./paperless-to-papra.py --max-records 50\n"
            "  ./paperless-to-papra.py --dry-run\n"
            "  ./paperless-to-papra.py --env-file /tmp/papra.env --organization Inbox\n"
            "  ./paperless-to-papra.py --purge-org --organization Inbox        # delete all docs (prompts)\n"
            "  ./paperless-to-papra.py --purge-org --organization Inbox --yes  # delete all docs (no prompt)\n"
        ),
    )
    parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE),
                        help=f"Path to the env file (default: {DEFAULT_ENV_FILE}).")
    parser.add_argument("--papra-url", help="Override PAPRA_URL.")
    parser.add_argument("--papra-key", help="Override PAPRA_KEY.")
    parser.add_argument("--paperless-url", help="Override PAPERLESS_URL.")
    parser.add_argument("--paperless-key", help="Override PAPERLESS_KEY.")
    parser.add_argument("--max-records", type=int,
                        help="Override MAX_RECORDS (max new uploads this run).")
    parser.add_argument("--upload-delay", type=float,
                        help="Override UPLOAD_DELAY_SECONDS (pause between uploads; "
                             "throttles Papra to avoid OOM, default 2).")
    parser.add_argument("--retries", type=int,
                        help=f"Override HTTP_RETRIES (times to retry transient errors with progressive times, default {DEFAULT_RETRIES}).")
    parser.add_argument("--organization",
                        help="Override PAPRA_ORGANIZATION (target org name).")
    parser.add_argument("--recipient-property",
                        help="Override PAPRA_RECIPIENT_PROPERTY (custom category name).")
    parser.add_argument("--tag-color",
                        help="Override PAPRA_TAG_COLOR (hex colour for created tags).")
    parser.add_argument("--state-file",
                        help="Override MIGRATION_STATE_FILE (local dedup state path).")
    parser.add_argument("--cache-file",
                        help=f"Path to the JSON migration cache (default: {DEFAULT_CACHE_FILE}).")
    parser.add_argument("--report-file",
                        help="Path to write the migration report (default: papra-migration-report.txt "
                             "in the cache directory).")
    parser.add_argument("--refresh-cache", action="store_true",
                        help="Force re-downloading files and recalculating hashes, updating the cache.")
    parser.add_argument("--no-cache", action="store_true",
                        help="Bypass cache lookup and caching entirely.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Report what would happen without creating, uploading or deleting anything.")
    parser.add_argument("--purge-org", action="store_true",
                        help="DESTRUCTIVE: delete ALL documents in the target organisation "
                             "(instead of migrating), then clear the local dedup state. "
                             "Requires typing the org name to confirm, or --yes.")
    parser.add_argument("--yes", action="store_true",
                        help="Skip the interactive confirmation prompt for --purge-org.")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    args = build_parser().parse_args(argv)
    config = resolve_config(args)
    try:
        return run(config)
    except KeyboardInterrupt:
        log("\nInterrupted. Progress has been saved; re-run to continue.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
