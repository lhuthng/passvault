#!/usr/bin/env bash
# PassVault recovery - run ON YOUR LAPTOP from the kit directory.
# One-shot server rescue after trouble (disk full, OOM, botched upgrade):
#   1. stop any crash-looping containers from this compose project
#   2. add swap if the host has none (small VMs thrash without it)
#   3. install sqlite3/rclone/fail2ban/unattended-upgrades + fail2ban jail
#   4. apply key-only sshd hardening (validated, rolled back on error)
#   5. stage backup systemd units (not enabled until rclone crypt works)
#   6. run deploy.sh (vaultwarden only until the tunnel is configured)
# Idempotent: safe to run repeatedly. Never reboots, never touches services
# outside this kit's containers.

set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$KIT_DIR/.deploy.env" ]] || { echo "ERROR: .deploy.env missing" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source "$KIT_DIR/.deploy.env"; set +a
: "${DEPLOY_HOST:?DEPLOY_HOST not set}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"

TMP_KEY=""
cleanup() { [[ -n "$TMP_KEY" ]] && { shred -u "$TMP_KEY" 2>/dev/null || rm -f "$TMP_KEY"; } || true; }
trap cleanup EXIT

if [[ -z "${DEPLOY_SSH_KEY:-}" ]]; then
    echo "ERROR: DEPLOY_SSH_KEY not set - put your private key content in .deploy.env" >&2
    exit 1
fi
[[ "$DEPLOY_SSH_KEY" == *"PRIVATE KEY"* ]] || { echo "ERROR: DEPLOY_SSH_KEY does not look like a private key" >&2; exit 1; }
TMP_KEY="$(mktemp "${TMPDIR:-/tmp}/pvkey.XXXXXX")"; chmod 600 "$TMP_KEY"
printf '%s\n' "$DEPLOY_SSH_KEY" > "$TMP_KEY"; KEY="$TMP_KEY"

ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=25 \
    "$DEPLOY_USER@$DEPLOY_HOST" "DEPLOY_USER='$DEPLOY_USER'" 'bash -s' <<'REMOTE'
set -u
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "State on arrival"
free -m | head -2
uptime

say "1. Stop crash-looping kit containers (vaultwarden/tunnel only)"
sudo docker compose -f /opt/passvault/docker-compose.yml ps 2>/dev/null || true
sudo docker update --restart=no cloudflared >/dev/null 2>&1 || true
sudo docker stop cloudflared >/dev/null 2>&1 && echo "  tunnel stopped" || echo "  tunnel already stopped"
sudo docker ps --format '{{.Names}}: {{.Status}}'

say "2. Swap (1 GB) if the host has none"
if sudo swapon --show | grep -q .; then
    echo "  swap already present:"; sudo swapon --show
else
    sudo fallocate -l 1G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    echo "  /swapfile enabled + persisted in /etc/fstab"
fi
free -m | awk 'NR==2 {printf "  mem used/free: %s/%s MB, swap: %s MB\n", $3, $4, $5}'

say "3. Packages"
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 rclone fail2ban unattended-upgrades >/dev/null 2>&1
echo "  sqlite3, rclone, fail2ban, unattended-upgrades installed"
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 && echo "  unattended security upgrades enabled"

say "4. fail2ban"
sudo cp /opt/passvault/fail2ban/vaultwarden.conf /etc/fail2ban/filter.d/
sudo cp /opt/passvault/fail2ban/vaultwarden.local  /etc/fail2ban/jail.d/
sudo systemctl enable --now fail2ban >/dev/null 2>&1
sudo systemctl restart fail2ban
sleep 2
sudo fail2ban-client status 2>&1 | head -3 || echo "  (check journalctl -u fail2ban if jails are missing)"

say "5. sshd hardening (key-only)"
sudo install -m 644 /opt/passvault/sshd/99-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf
if sudo sshd -t; then
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd
    echo "  applied + reloaded (sshd -t passed)"
else
    sudo rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    echo "  ROLLED BACK: sshd -t failed"
fi

say "6. Backup unit rendered (NOT enabled until rclone crypt is configured)"
sed -e "s/__USER__/$DEPLOY_USER/g" /opt/passvault/systemd/passvault-backup.service \
    | sudo tee /etc/systemd/system/passvault-backup.service >/dev/null
sudo cp /opt/passvault/systemd/passvault-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
mkdir -p "$HOME/.config/rclone"
echo "  unit in place; the timer enables on the next deploy once rclone works"

say "Final state"
free -m | head -2
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
REMOTE

echo
echo "Recovery done. Now: ./deploy.sh   (full stack once the tunnel is configured)"
