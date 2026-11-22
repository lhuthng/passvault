#!/usr/bin/env bash
# NodeWarden backup: D1 export -> rclone crypt remote (Google Drive).
# Same safety rule as the VM kit: refuses non-crypt remotes, so the raw SQL
# (contains email/user data, not vault secrets - items are E2E-encrypted)
# never lands on Google unencrypted.
#
# Layered backups, best practice = all three:
#   1. this script (server-side D1 dump)
#   2. NodeWarden's built-in Backup Center (WebDAV/S3 scheduled incremental)
#   3. client-side encrypted export (File -> Export vault) kept offline

set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$KIT_DIR/nodewarden"
OUT_DIR="${OUT_DIR:-$KIT_DIR/backups}"
REMOTE="${REMOTE:-gdrive-crypt:vaultwarden-workers}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

[[ "$REMOTE" == *crypt* ]] || { echo "ERROR: REMOTE='$REMOTE' is not a crypt remote - refusing." >&2; exit 1; }
command -v rclone >/dev/null || { echo "ERROR: rclone required" >&2; exit 1; }
[[ -d "$REPO_DIR" ]] || { echo "ERROR: $REPO_DIR missing - run deploy.sh first" >&2; exit 1; }

# D1 database name from the KV wrangler config
DB_NAME="$(grep -A6 'd1_databases' "$REPO_DIR/wrangler.kv.toml" 2>/dev/null \
    | grep 'database_name' | head -1 | sed 's/.*= *"\([^"]*\)".*/\1/' || true)"
: "${D1_NAME:=$DB_NAME}"
: "${D1_NAME:?D1 database name not found - set D1_NAME env or check wrangler.kv.toml}"

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="$OUT_DIR/nodewarden-d1-$STAMP.sql"

cd "$REPO_DIR"
echo "==> exporting D1 '$D1_NAME'"
npx wrangler d1 export "$D1_NAME" --remote --output "$OUT"
chmod 600 "$OUT"

echo "==> uploading to $REMOTE"
rclone copy "$OUT" "$REMOTE/"
rclone delete "$REMOTE" --min-age "${RETENTION_DAYS}d"
ls -1t "$OUT_DIR"/nodewarden-d1-*.sql 2>/dev/null | tail -n +8 | xargs -r rm -f

echo "[$(date '+%F %T')] backup OK -> $REMOTE ($(du -h "$OUT" | cut -f1))"
echo "Restore drill: npx wrangler d1 import '$D1_NAME' --remote --file=<sql>  (into a scratch DB)"
