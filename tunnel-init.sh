#!/usr/bin/env bash
# One-time Cloudflare Tunnel bootstrap for the PassVault VM target.
# Run ON YOUR LAPTOP from the kit directory. Idempotent - safe to re-run.
#
#   1. installs cloudflared on the server (binary, no repo changes)
#   2. starts `cloudflared tunnel login` and prints the URL - open it and
#      click Authorize for your zone (script waits for you)
#   3. creates the `passvault` tunnel, writes cloudflared/config.yml
#      (ingress: vault.yourdomain.com -> vaultwarden:80) + credentials
#   4. repoints DNS: vault.yourdomain.com -> tunnel (--overwrite-dns)
#
# Then run ./deploy.sh to start the full stack.

set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_NAME="passvault"

[[ -f "$KIT_DIR/.deploy.env" ]] || { echo "ERROR: .deploy.env missing" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source "$KIT_DIR/.deploy.env"; set +a
: "${DEPLOY_HOST:?DEPLOY_HOST not set}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DOMAIN="${DEPLOY_DOMAIN:?set DEPLOY_DOMAIN=vault.yourdomain.com in .deploy.env}"

# Key content only (never a path): .deploy.env uses DEPLOY_SSH_KEY="$(cat ~/.ssh/<key>)"
if [[ -z "${DEPLOY_SSH_KEY:-}" ]]; then
    echo "ERROR: DEPLOY_SSH_KEY not set - put your private key content in .deploy.env, e.g. DEPLOY_SSH_KEY=\"\$(cat ~/.ssh/id_ed25519)\"" >&2
    exit 1
fi
[[ "$DEPLOY_SSH_KEY" == *"PRIVATE KEY"* ]] || { echo "ERROR: DEPLOY_SSH_KEY does not look like a private key" >&2; exit 1; }
TMP_KEY="$(mktemp "${TMPDIR:-/tmp}/pvkey.XXXXXX")"; chmod 600 "$TMP_KEY"
printf '%s\n' "$DEPLOY_SSH_KEY" > "$TMP_KEY"; KEY="$TMP_KEY"

ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=25 \
    "$DEPLOY_USER@$DEPLOY_HOST" DOMAIN="$DOMAIN" TUNNEL_NAME="$TUNNEL_NAME" 'bash -s' <<'REMOTE'
set -euo pipefail
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

CF=/usr/local/bin/cloudflared

say "1. cloudflared binary"
if [ ! -x "$CF" ]; then
    echo "  downloading latest release..."
    sudo curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o "$CF"
    sudo chmod +x "$CF"
fi
echo "  $($CF --version 2>/dev/null | head -1)"

say "2. Account login (browser authorize)"
if [ -f "$HOME/.cloudflared/cert.pem" ]; then
    echo "  already authorized (cert.pem present)"
else
    if ! pgrep -f "cloudflared tunnel login" >/dev/null 2>&1; then
        nohup "$CF" tunnel login >/tmp/cf-login.log 2>&1 &
        sleep 5
    fi
    URL=$(grep -o 'https://dash.cloudflare.com/argotunnel[^[:space:]]*' /tmp/cf-login.log 2>/dev/null | head -1 || true)
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ OPEN THIS URL IN YOUR BROWSER AND CLICK AUTHORIZE           │"
    echo "  │ (authorize the $DOMAIN zone)                                │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo "  ${URL:-<url not captured - cat /tmp/cf-login.log on the server>}"
    echo "  waiting for authorization (up to 5 min; re-run if it times out)..."
    for i in $(seq 1 60); do
        [ -f "$HOME/.cloudflared/cert.pem" ] && break
        sleep 5
    done
    [ -f "$HOME/.cloudflared/cert.pem" ] || { echo "  NOT authorized yet - click the URL, then re-run tunnel-init.sh"; exit 2; }
    echo "  authorized ✓"
fi

say "3. Tunnel '$TUNNEL_NAME'"
TID=$("$CF" tunnel list -o json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(next((t['id'] for t in d if t.get('name') == '$TUNNEL_NAME'), ''))
except Exception:
    print('')
")
if [ -z "$TID" ]; then
    "$CF" tunnel create "$TUNNEL_NAME"
    TID=$("$CF" tunnel list -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next(t['id'] for t in d if t.get('name') == '$TUNNEL_NAME'))
")
fi
echo "  tunnel id: $TID"

say "4. Config + credentials -> /opt/passvault/cloudflared/"
mkdir -p /opt/passvault/cloudflared
cp "$HOME/.cloudflared/$TID.json" /opt/passvault/cloudflared/
cat > /opt/passvault/cloudflared/config.yml <<EOF
tunnel: $TID
credentials-file: /etc/cloudflared/$TID.json
ingress:
  - hostname: $DOMAIN
    service: http://vaultwarden:80
  - service: http_status:404
EOF
chmod 600 /opt/passvault/cloudflared/$TID.json /opt/passvault/cloudflared/config.yml
# The tunnel container runs as this uid/gid so it can read the 600 files.
if ! grep -q '^PUID=' /opt/passvault/.env 2>/dev/null; then
    printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> /opt/passvault/.env
    echo "  PUID/PGID ($(id -u):$(id -g)) written to server .env for compose"
fi
echo "  config.yml + credentials in place (mode 600)"

say "5. DNS: $DOMAIN -> tunnel"
"$CF" tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$DOMAIN"
echo "  vault record now a proxied CNAME to the tunnel (previous A record replaced)"

say "DONE - now run: ./deploy.sh  (starts vaultwarden + cloudflared)"
REMOTE
