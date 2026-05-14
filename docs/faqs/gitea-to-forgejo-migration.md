# Migrating from Gitea to Forgejo (git.laurivan.com → giti.laurivan.com)

This runbook covers migrating all repositories, users, organizations, and metadata from an existing Gitea instance to a new Forgejo instance while preserving full commit history and offering the option to skip mirrored repositories.

## Prerequisites

- Access to both instances:
  - **Source**: `git.laurivan.com` (Gitea)
  - **Target**: `giti.laurivan.com` (Forgejo)
- Admin API tokens for both instances
- `curl`, `jq`, and `git` installed locally

## Step 1: Generate API Tokens

On the **source** (Gitea):
```bash
# Create via UI: Settings → Applications → Generate New Token (with all scopes)
# Or use existing admin credentials
export SOURCE_URL="https://git.laurivan.com"
export SOURCE_TOKEN="your-gitea-admin-token"
```

On the **target** (Forgejo):
```bash
export TARGET_URL="https://giti.laurivan.com"
export TARGET_TOKEN="your-forgejo-admin-token"
```

## Step 2: List All Repositories (Excluding Mirrors)

```bash
# Fetch all repos from source
curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
  "${SOURCE_URL}/api/v1/repos/search?limit=50&page=1" | \
  jq -r '.data[] | select(.mirror == false) | "\(.owner.login)/\(.name)"'
```

To include mirrors (for reference):
```bash
curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
  "${SOURCE_URL}/api/v1/repos/search?limit=50&page=1" | \
  jq -r '.data[] | "\(.owner.login)/\(.name) [mirror=\(.mirror)]"'
```

> **Note**: Paginate if you have more than 50 repos by incrementing `page`.

## Step 3: Migrate Users and Organizations

Forgejo's migration API can pull from Gitea directly. However, users need to exist first.

### Option A: Users authenticate via OIDC (recommended)

If both instances use Authentik/OIDC, users will be created on first login. No manual user migration needed — just ensure the same OIDC provider is configured on the target.

### Option B: Manually create users

```bash
# List users from source
curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
  "${SOURCE_URL}/api/v1/admin/users?limit=50" | \
  jq -r '.[] | "\(.login) \(.email)"'

# Create user on target (they'll reset password on first login)
curl -s -X POST -H "Authorization: token ${TARGET_TOKEN}" \
  -H "Content-Type: application/json" \
  "${TARGET_URL}/api/v1/admin/users" \
  -d '{
    "login": "username",
    "email": "user@example.com",
    "password": "temporary-password-change-me",
    "must_change_password": true
  }'
```

### Migrate Organizations

```bash
# List orgs from source
ORGS=$(curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
  "${SOURCE_URL}/api/v1/admin/orgs?limit=50" | jq -r '.[].username')

# Create each org on target
for org in $ORGS; do
  DESCRIPTION=$(curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
    "${SOURCE_URL}/api/v1/orgs/${org}" | jq -r '.description // ""')

  curl -s -X POST -H "Authorization: token ${TARGET_TOKEN}" \
    -H "Content-Type: application/json" \
    "${TARGET_URL}/api/v1/orgs" \
    -d "{\"username\": \"${org}\", \"description\": \"${DESCRIPTION}\", \"visibility\": \"private\"}"
done
```

## Step 4: Migrate Repositories (with full history)

### Option A: Use Forgejo's built-in migration API (recommended)

Forgejo can clone from Gitea directly, preserving all git history, issues, labels, milestones, releases, pull requests, and wiki.

```bash
#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="https://git.laurivan.com"
SOURCE_TOKEN="your-gitea-token"
TARGET_URL="https://giti.laurivan.com"
TARGET_TOKEN="your-forgejo-token"
SKIP_MIRRORS=true
# Set to a space-separated list of orgs/users to migrate, or "" for all
ONLY_OWNERS="org1 org2 org3"

# Get all repos (paginated)
page=1
while true; do
  repos=$(curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
    "${SOURCE_URL}/api/v1/repos/search?limit=50&page=${page}")

  count=$(echo "$repos" | jq '.data | length')
  [ "$count" -eq 0 ] && break

  echo "$repos" | jq -c '.data[]' | while read -r repo; do
    is_mirror=$(echo "$repo" | jq -r '.mirror')
    owner=$(echo "$repo" | jq -r '.owner.login')
    name=$(echo "$repo" | jq -r '.name')
    clone_url=$(echo "$repo" | jq -r '.clone_url')
    private=$(echo "$repo" | jq -r '.private')
    description=$(echo "$repo" | jq -r '.description // ""')
    has_wiki=$(echo "$repo" | jq -r '.has_wiki')

    # Skip mirrors if configured
    if [ "$SKIP_MIRRORS" = "true" ] && [ "$is_mirror" = "true" ]; then
      echo "SKIP (mirror): ${owner}/${name}"
      continue
    fi

    # Skip repos not matching ONLY_OWNERS if set
    if [ -n "$ONLY_OWNERS" ]; then
      if ! echo "$ONLY_OWNERS" | grep -qw "$owner"; then
        echo "SKIP (owner filter): ${owner}/${name}"
        continue
      fi
    fi

    echo "MIGRATING: ${owner}/${name}..."

    # Use Forgejo migration API (service type 3 = Gitea)
    curl -s -X POST -H "Authorization: token ${TARGET_TOKEN}" \
      -H "Content-Type: application/json" \
      "${TARGET_URL}/api/v1/repos/migrate" \
      -d "{
        \"clone_addr\": \"${clone_url}\",
        \"auth_token\": \"${SOURCE_TOKEN}\",
        \"repo_name\": \"${name}\",
        \"repo_owner\": \"${owner}\",
        \"service\": \"gitea\",
        \"mirror\": false,
        \"private\": ${private},
        \"description\": $(echo "$description" | jq -Rs .),
        \"wiki\": ${has_wiki},
        \"issues\": true,
        \"labels\": true,
        \"milestones\": true,
        \"pull_requests\": true,
        \"releases\": true
      }"

    echo " ✓ Done: ${owner}/${name}"
    sleep 1  # Rate limiting
  done

  page=$((page + 1))
done
```

### Option B: Manual git clone + push (if API migration fails)

For repos where the API migration doesn't work:

```bash
REPO="owner/repo-name"
git clone --mirror "https://${SOURCE_TOKEN}@git.laurivan.com/${REPO}.git" /tmp/repo-mirror
cd /tmp/repo-mirror
git remote set-url origin "https://${TARGET_TOKEN}@giti.laurivan.com/${REPO}.git"
git push --mirror
cd ..
rm -rf /tmp/repo-mirror
```

> **Note**: `--mirror` preserves all branches, tags, and refs (full history).

## Step 5: Verify Migration

```bash
# Compare repo counts
SOURCE_COUNT=$(curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
  "${SOURCE_URL}/api/v1/repos/search?limit=1" | jq '.data | length')

TARGET_COUNT=$(curl -s -H "Authorization: token ${TARGET_TOKEN}" \
  "${TARGET_URL}/api/v1/repos/search?limit=1" | jq '.data | length')

echo "Source repos: ${SOURCE_COUNT}, Target repos: ${TARGET_COUNT}"

# Spot-check a repo's commit count
REPO="owner/repo-name"
SOURCE_COMMITS=$(curl -s -H "Authorization: token ${SOURCE_TOKEN}" \
  "${SOURCE_URL}/api/v1/repos/${REPO}/commits?limit=1" \
  -o /dev/null -w '%{http_code}')
echo "Source ${REPO} accessible: ${SOURCE_COMMITS}"
```

## Step 6: Post-Migration Tasks

1. **Update webhook URLs** — Any CI/CD webhooks pointing to the old instance need updating
2. **Update git remotes locally** — For each local clone:
   ```bash
   git remote set-url origin https://giti.laurivan.com/owner/repo.git
   ```
3. **Update Forgejo Actions runners** — Point runners at the new instance
4. **DNS cutover** (optional) — If you want `git.laurivan.com` to point to Forgejo, update the HTTPRoute hostname and Authentik redirect URI
5. **Decommission old instance** — Once verified, shut down the old Gitea

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `repo_owner` doesn't exist on target | Create the user/org first (Step 3) |
| 409 Conflict on migrate | Repo already exists on target, delete or rename first |
| Large repos timeout | Use Option B (manual git clone --mirror) |
| LFS objects missing | Add `"lfs": true` to the migration payload |
| Wiki not migrated | Ensure `has_wiki` is true and wiki has content |

## Notes

- The Forgejo migration API (`/api/v1/repos/migrate`) with `"service": "gitea"` handles Gitea-specific metadata natively
- All commit SHAs, branch names, and tags are preserved (it's a full git clone under the hood)
- Issues/PRs get new IDs on the target but retain their original content and timestamps
- If using SSH keys for push access, ensure they're configured on the target instance
