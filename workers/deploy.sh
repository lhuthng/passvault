#!/usr/bin/env bash
# NodeWarden deploy (Cloudflare Workers, KV storage mode - no payment card needed).
# Run from your laptop: ./deploy.sh   (CI: set CLOUDFLARE_API_TOKEN + JWT_SECRET env)
#
# Rules honored: CI/CD uses CLOUDFLARE_API_TOKEN (direct env value) - never a key path.
# Secrets live in .workers.env (chmod 600), never printed, never committed.

set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$KIT_DIR/nodewarden"
REPO_URL="https://github.com/shuaiplus/NodeWarden.git"
# Domain comes from .workers.env (set WORKERS_DOMAIN=vault.yourdomain.com there)
DOMAIN="${WORKERS_DOMAIN:?WORKERS_DOMAIN missing - add it to .workers.env (e.g. vault.yourdomain.com)}"
ENV_FILE="$KIT_DIR/.workers.env"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v git      >/dev/null || die "git required"
command -v node     >/dev/null || die "Node.js required (Node 18+): https://nodejs.org or sudo apt install nodejs npm"
command -v npm      >/dev/null || die "npm required"

# --- secrets -------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    cp "$KIT_DIR/.workers.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Created $ENV_FILE - filling JWT_SECRET"
    echo "JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')" >> "$ENV_FILE"
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${JWT_SECRET:?JWT_SECRET missing - openssl rand -base64 48, add to .workers.env}"
[[ ${#JWT_SECRET} -ge 32 ]] || die "JWT_SECRET must be >= 32 chars"
if [[ -n "${CI:-}" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    die "CI/CD must set CLOUDFLARE_API_TOKEN (direct value - never a path/file)"
fi

# --- repo ----------------------------------------------------------------------
if [[ ! -d "$REPO_DIR" ]]; then
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
else
    git -C "$REPO_DIR" pull --ff-only 2>/dev/null || echo "NOTE: upstream pull skipped (local changes?)"
fi
cd "$REPO_DIR"

echo "==> npm install"
npm install --no-fund --no-audit

# --- wrangler auth -------------------------------------------------------------
if ! npx wrangler whoami >/dev/null 2>&1; then
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        echo "==> using CLOUDFLARE_API_TOKEN from environment"
    else
        die "Not logged in to wrangler. Run once:  cd $REPO_DIR && npx wrangler login  (opens your browser)"
    fi
fi

# --- custom domain route (auto-attaches $DOMAIN to the Worker) ---
if ! grep -q "$DOMAIN" wrangler.kv.toml; then
    printf '\n# custom domain (zone must be on this Cloudflare account)\n[[routes]]\npattern = "%s"\ncustom_domain = true\n' "$DOMAIN" >> wrangler.kv.toml
    echo "==> added custom domain route: $DOMAIN"
fi

echo "==> deploy (KV mode)"
npm run deploy:kv

# --- JWT secret ----------------------------------------------------------------
echo "==> setting JWT_SECRET (runtime secret)"
if printf '%s' "$JWT_SECRET" | npx wrangler secret put JWT_SECRET; then
    echo "    JWT_SECRET set"
else
    echo "    NOTE: secret put failed on a fresh worker - run deploy again; it retries after the worker exists."
    npm run deploy:kv
    printf '%s' "$JWT_SECRET" | npx wrangler secret put JWT_SECRET
fi

echo
echo "Deployed. Verify:  curl -I https://$DOMAIN"
echo "Then open https://$DOMAIN in a browser and create your account (invite-code registration)."
