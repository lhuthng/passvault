# NodeWarden on Cloudflare Workers - Runbook

**Target B (serverless).** Bitwarden-compatible vault running entirely on
Cloudflare Workers + D1 (+ KV for attachments) - free tier, no payment card,
no VM, no certs, no firewall. Same official Bitwarden clients everywhere.

Source project: https://github.com/shuaiplus/nodewarden (LGPL-3.0)
> ⚠️ Maturity note: young community project (self-described "for learning and
> discussion purposes"), no security audit. Mitigate: strong master password,
> all three backup layers below, watch upstream updates. The VM kit
> (`../RUNBOOK.md`) remains the fallback target.

**What disappears vs the VM target:** cloud firewall ingress rules, iptables, origin
certificates, port conflicts, memory babysitting. The Worker
attaches `vault.yourdomain.com` directly (your zone is already on Cloudflare).

## 0. Prerequisites (laptop)

- Node.js 18+ and npm, git, rclone (for off-site backup)
- Cloudflare account holding the `yourdomain.com` zone
- One-time: `cd nodewarden && npx wrangler login` (browser OAuth - deploy.sh
  tells you when)

## 1. Deploy

```bash
cd workers
./deploy.sh
```

First run: clones NodeWarden, installs deps, generates `JWT_SECRET` into
`.workers.env` (mode 600), adds the custom-domain route, deploys **KV mode**
(`npm run deploy:kv` - D1 schema auto-initializes on first request), and sets
the JWT secret. Re-runs: pulls upstream, redeploys, idempotent.

Verify: `curl -I https://vault.yourdomain.com` → 200/redirect from the Worker.

## 2. Accounts (invite-code, not open signup)

Registration is **invite-code based** - a deliberate upgrade over the VM kit's
open signups. Open the web vault, create your account first, then generate
invite codes for other people from the vault UI (see the project wiki,
nodewarden.app, if the UI moves). Each account still gets its own
zero-knowledge key material.

Optional after onboarding: set `HIDE_WEB_VAULT=1` (Workers → Settings →
Variables) to 404 the web UI while keeping the client API alive - remove the
variable to bring it back.

## 3. Clients (identical to the VM target)

| Platform | Install | Sign-in server URL |
|---|---|---|
| macOS | `brew install --cask bitwarden` | `https://vault.yourdomain.com` |
| Windows | `winget install -e --id Bitwarden.Bitwarden` | same |
| Debian | bitwarden.com/download (.deb) | same |
| Brave / Chromium | official "Bitwarden Password Manager" extension | same |

- Biometric unlock (Touch ID / Windows Hello): desktop app → enable browser
  integration; extension → unlock with biometrics.
- **Passkeys:** enable in the extension; NodeWarden also supports **passkey
  login for the vault itself** plus TOTP/YubiKey/2FA recovery codes. Test the
  loop on webauthn.io.
- ⚠️ The project lists the **macOS desktop client as "not fully verified"** -
  prefer the browser extension on macOS until you've verified your flows.

## 4. Backups - three layers

1. **Built-in Backup Center** (web vault): scheduled incremental backups to
   WebDAV or S3.
2. **This kit:** `./backup-workers.sh` → `wrangler d1 export` → rclone crypt →
   Google Drive (refuses non-crypt remotes; 30-day retention). Vault items are
   end-to-end encrypted; the dump still contains account metadata - keep it
   crypt-only.
3. **Client-side:** monthly encrypted export (File → Export vault) stored
   offline.

Quarterly restore drill: import the SQL into a **scratch D1 database** and
point a throwaway Worker at it.

## 5. CI/CD

Same rule as always - direct values, never paths:

- CI secrets: `CLOUDFLARE_API_TOKEN` (Workers-edit template token) and
  `JWT_SECRET`; run `workers/deploy.sh` with `CI=true`.
- Wrangler is token-native, so no SSH-key dance exists at all.

## 6. Housekeeping

- Updates: re-run `./deploy.sh` (pulls upstream `--ff-only`, redeploys).
- Data survives redeploys/restarts (D1 + KV are durable); wiping users/invite
  codes requires deleting the D1 database + KV namespace - don't do that by
  accident.
- No organizations/collections/roles - per-person vaults only (matches your
  use case).
- The old VM: reboot it and keep it for your other services; the
  vault containers can stay stopped - the whole `/opt/passvault` there is now
  the dormant fallback target.
