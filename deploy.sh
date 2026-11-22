#!/usr/bin/env bash
# PassVault deploy - non-interactive. Reads .deploy.env:
#
#   DEPLOY_HOST    server IP or hostname
#   DEPLOY_USER    SSH user (default: ubuntu)
#   DEPLOY_DOMAIN  vault hostname (for the final hint)
#   DEPLOY_SSH_KEY private key CONTENT - never a path. Locally:
#                  DEPLOY_SSH_KEY="$(cat ~/.ssh/id_ed25519)"
#                  In CI: inject the content from the SSH_PRIVATE_KEY secret.
#
# .deploy.env is NEVER copied to the server.

set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$KIT_DIR/.deploy.env" ]] || die ".deploy.env missing - see RUNBOOK §0 for the template"

# shellcheck disable=SC1091
set -a; source "$KIT_DIR/.deploy.env"; set +a
: "${DEPLOY_HOST:?DEPLOY_HOST not set in .deploy.env}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"

TMP_KEY=""
cleanup() {
    if [[ -n "$TMP_KEY" ]]; then
        shred -u "$TMP_KEY" 2>/dev/null || rm -f "$TMP_KEY"
    fi
}
trap cleanup EXIT

if [[ -n "${DEPLOY_SSH_KEY:-}" ]]; then
    TMP_KEY="$(mktemp "${TMPDIR:-/tmp}/pvkey.XXXXXX")"
    chmod 600 "$TMP_KEY"
    printf '%s\n' "$DEPLOY_SSH_KEY" > "$TMP_KEY"    # private keys must end with a newline
    KEY="$TMP_KEY"
else
    die "DEPLOY_SSH_KEY not set - put your private key content in .deploy.env, e.g. DEPLOY_SSH_KEY=\"\$(cat ~/.ssh/id_ed25519)\""
fi
[[ "$DEPLOY_SSH_KEY" == *"PRIVATE KEY"* ]] || die "DEPLOY_SSH_KEY does not look like a private key (expecting -----BEGIN ... PRIVATE KEY-----)"

SSH_CMD="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15"

say "Connectivity check"
$SSH_CMD "$DEPLOY_USER@$DEPLOY_HOST" 'echo "  connected: $(uname -srm)"'

say "Server prep (Docker + compose plugin if missing)"
$SSH_CMD "$DEPLOY_USER@$DEPLOY_HOST" 'bash -s' <<'PREP'
set -e
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sudo sh
fi
if ! docker compose version >/dev/null 2>&1; then
    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    sudo curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
         -o /usr/local/lib/docker/cli-plugins/docker-compose
    sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    echo "  installed docker compose plugin"
fi
echo "  $(docker --version) / compose $(docker compose version --short)"
PREP

say "Upload kit"
$SSH_CMD "$DEPLOY_USER@$DEPLOY_HOST" 'sudo mkdir -p /opt/passvault && sudo chown "$(id -u)":"$(id -g)" /opt/passvault'
# NOTE: .env, data/, cloudflared/ and backups/ are server-side state and are
# NEVER overwritten or deleted by deploys - so CI/CD cannot touch credentials.
rsync -av --exclude backups/ --exclude data/ --exclude .deploy.env \
      --exclude workers/ --exclude .env --exclude cloudflared/ \
      --exclude .git/ --exclude .github/ --exclude .workers.env \
      -e "$SSH_CMD" \
      "$KIT_DIR/" "$DEPLOY_USER@$DEPLOY_HOST:/opt/passvault/"

say "Start stack"
# Full stack only after ./tunnel-init.sh configured the tunnel; until then vaultwarden alone.
$SSH_CMD "$DEPLOY_USER@$DEPLOY_HOST" "DEPLOY_USER='$DEPLOY_USER'" 'bash -s' <<'UP'
set -e
cd /opt/passvault
[[ -f .env ]] || { echo ".env missing on the server - create it first (RUNBOOK §5)"; exit 1; }
if [[ -s cloudflared/config.yml ]] && ls cloudflared/*.json >/dev/null 2>&1; then
    sudo docker compose up -d --remove-orphans
else
    echo "  tunnel not configured yet - starting vaultwarden only (run ./tunnel-init.sh, then deploy again)"
    sudo docker compose up -d --no-deps vaultwarden 2>/dev/null || sudo docker compose up -d vaultwarden
    sudo docker compose stop tunnel 2>/dev/null || true
fi
sudo docker compose ps

# Backup unit: rendered for THIS deploy user (no hardcoded usernames anywhere)
sed -e "s/__USER__/$DEPLOY_USER/g" systemd/passvault-backup.service \
    | sudo tee /etc/systemd/system/passvault-backup.service >/dev/null
sudo cp systemd/passvault-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
if [[ -f "$HOME/.config/rclone/rclone.conf" ]]; then
    sudo systemctl enable --now passvault-backup.timer 2>/dev/null || true
    echo "  backup timer installed + enabled (rclone configured)"
else
    echo "  backup unit installed; timer auto-enables once rclone is configured (RUNBOOK §7)"
fi
UP

say "Done"
echo "  Next: create your account at https://${DEPLOY_DOMAIN:-<your-vault-domain>}, enable 2FA (§6),"
echo "  then backups (§7) and hardening (§9). If the tunnel isn't set up yet: ./tunnel-init.sh"
