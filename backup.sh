#!/usr/bin/env bash
# PassVault backup: consistent SQLite snapshot + attachments + config -> rclone
# crypt remote (Google Drive), then PRUNE with grandfather-father-son retention:
# keeps the newest backup of each day (KEEP_DAILY), each ISO week (KEEP_WEEKLY),
# each month (KEEP_MONTHLY) and deletes everything older that no bucket keeps.
# Applied to BOTH the remote and the local backups/ directory.
#
# SAFETY: refuses to run if the remote doesn't look like an rclone *crypt*
# remote, so the unencrypted vault can never land on cloud storage by accident.

set -euo pipefail

BASE="${BASE:-/opt/passvault}"
VAULT_DIR="${VAULT_DIR:-$BASE/data}"
BACKUP_DIR="${BACKUP_DIR:-$BASE/backups}"
REMOTE="${REMOTE:-gdrive-crypt:vaultwarden}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-3}"

if [[ ! "$REMOTE" == *crypt* ]]; then
    echo "ERROR: REMOTE='$REMOTE' does not look like a crypt remote." >&2
    echo "Set up an encrypted remote (see RUNBOOK §7) before enabling backups." >&2
    exit 1
fi

command -v sqlite3 >/dev/null || { echo "ERROR: sqlite3 not installed on host" >&2; exit 1; }
command -v rclone  >/dev/null || { echo "ERROR: rclone not installed on host" >&2;  exit 1; }
[[ -f "$VAULT_DIR/db.sqlite3" ]] || { echo "ERROR: $VAULT_DIR/db.sqlite3 not found" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Consistent online snapshot (never tar the live DB while Vaultwarden writes it).
sqlite3 "$VAULT_DIR/db.sqlite3" ".backup '$WORK/db.sqlite3'"

# 2. Config that a restore would need.
[[ -f "$BASE/.env" ]] && cp "$BASE/.env" "$WORK/env.txt" || true
if [[ -d "$BASE/cloudflared" ]]; then cp -r "$BASE/cloudflared" "$WORK/cloudflared"; fi

# 3. Pack.
ARCHIVE="$BACKUP_DIR/passvault-$STAMP.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" .
chmod 600 "$ARCHIVE"

# 4. Upload (encrypted by the crypt remote).
rclone copy "$ARCHIVE" "$REMOTE/"

# 5. Prune: grandfather-father-son over modification times.
#    Reads "mtime<TAB>path" newest-first on stdin, prints paths to delete.
prune_gfs() {
    local dc=0 wc=0 mc=0 keep d w m
    declare -A D W M
    while IFS=$'\t' read -r mtime path; do
        [[ -z "$path" ]] && continue
        d="${mtime:0:10}"
        m="${mtime:0:7}"
        w="$(date -u -d "${mtime:0:19}" +%G-%V 2>/dev/null || echo "$d")"
        keep=0
        if [[ -z "${D[$d]:-}" && $dc -lt $KEEP_DAILY ]];     then D[$d]=1; dc=$((dc+1)); keep=1; fi
        if [[ -z "${W[$w]:-}" && $wc -lt $KEEP_WEEKLY ]];    then W[$w]=1; wc=$((wc+1)); keep=1; fi
        if [[ -z "${M[$m]:-}" && $mc -lt $KEEP_MONTHLY ]];   then M[$m]=1; mc=$((mc+1)); keep=1; fi
        [[ $keep -eq 0 ]] && printf '%s\n' "$path"
    done
}

# Remote: list newest-first, compute deletions, delete exactly those.
rclone lsf "$REMOTE" --files-only --format tp --separator $'\t' 2>/dev/null \
    | sort -r | prune_gfs > "$WORK/remote-delete.txt" || true
if [[ -s "$WORK/remote-delete.txt" ]]; then
    rclone delete "$REMOTE" --files-from "$WORK/remote-delete.txt"
    echo "pruned $(wc -l < "$WORK/remote-delete.txt") old remote backup(s)"
fi

# Local: same policy.
find "$BACKUP_DIR" -maxdepth 1 -name 'passvault-*.tar.gz' \
    -printf '%TY-%Tm-%Td %TH:%TM:%TS\t%p\n' | sort -r | prune_gfs > "$WORK/local-delete.txt" || true
while IFS= read -r f; do rm -f "$f"; done < "$WORK/local-delete.txt"
[[ -s "$WORK/local-delete.txt" ]] && echo "pruned $(wc -l < "$WORK/local-delete.txt") old local backup(s)"

echo "[$(date '+%F %T')] backup OK -> $REMOTE ($(du -h "$ARCHIVE" | cut -f1))"
