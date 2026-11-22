# PassVault Runbook

Self-hosted 1Password-style vault on a small (1 GB RAM) VPS,
served at `vault.yourdomain.com` behind Cloudflare, with encrypted daily
backups to Google Drive.

**Stack:** Vaultwarden (Rust Bitwarden server, ~50 MB RAM) + **Cloudflare Tunnel**
(outbound-only; no open ports, no certs) + rclone crypt → Google Drive + fail2ban.

**Client apps are the official Bitwarden apps** - macOS, Windows, Debian, and
the browser extension for Brave/Chromium (autofill, TOTP, passkeys, biometric
unlock). Nothing unofficial touches your devices.

> **Two deployment targets share this kit:**
> **A) This VM runbook** (Vaultwarden on a VPS, fallback target), or
> **B) the serverless Cloudflare Workers target** - `workers/README.md`
> (NodeWarden, free, no server; the current primary).

> Nothing personal is baked into this repo: domains, hosts, key paths, and
> secrets live only in git-ignored `.deploy.env` / `.env` / `.workers.env`.

---

## 0. Prepare & deploy

Deployment is **config-driven** (no interactive script). Connection settings
live in `.deploy.env` - local/CI only, never shipped to the server:

```
DEPLOY_HOST=<server IP>            # fill in
DEPLOY_USER=ubuntu
DEPLOY_DOMAIN=vault.yourdomain.com   # the vault hostname (must be your Cloudflare zone)
DEPLOY_SSH_KEY="$(cat ~/.ssh/<your-key>)"   # key CONTENT, never a path
```

Rule: **the key is always content, never a path.** Locally, `.deploy.env`
reads it with `DEPLOY_SSH_KEY="$(cat ~/.ssh/<your-key>)"`; in CI it comes
from the `SSH_PRIVATE_KEY` secret as `DEPLOY_SSH_KEY`.

```bash
chmod 600 .deploy.env              # it holds connection material
ssh -i <your-key-file> "$DEPLOY_USER@$DEPLOY_HOST" echo ok  # sanity check
./deploy.sh                        # installs Docker if missing, uploads the
                                   # kit to /opt/passvault, starts the stack
```

After the tunnel is configured (`tunnel-init.sh`), run `./deploy.sh` again to
start the full stack. Secrets overview: `SECRETS.md`.

## 1. Cloudflare setup (Tunnel - no certs, no firewall changes)

SSL/TLS is already **Full** - nothing more to configure in the dashboard.
The vault is reached through a **Cloudflare Tunnel** (outbound-only from the
VM), which removes Origin certificates, Origin Rules, open ingress ports, and
port conflicts on the host:

1. `./tunnel-init.sh` from the laptop - installs `cloudflared` on the server,
   prints a **login URL**: open it and click **Authorize** for
   `yourdomain.com` (one-time; the script waits and then finishes: creates
   the `passvault` tunnel, writes `cloudflared/config.yml` - ingress
   `vault.yourdomain.com` → `vaultwarden:80` - and repoints the `vault` DNS
   record to the tunnel via `--overwrite-dns`).
2. `./deploy.sh` → starts vaultwarden **and** the `cloudflared` container.
3. Verify: `curl -I https://vault.yourdomain.com/alive` → HTTP/2 200.

Notes:
- Real client IPs still reach fail2ban (`IP_HEADER=CF-Connecting-IP`; tunnels
  preserve it). WebSockets (live sync) work through tunnels.
- **WAF / Bot Fight Mode:** if you ever enable bot challenges, they break the
  Bitwarden apps (API clients can't solve JS challenges). Add a WAF **Skip
  rule** for URI Path in `( "/api" "/identity" "/notifications/hub" "/icons" )`
  first.
- Optional later: Zero Trust → Access on `/admin*` (admin is disabled while
  `ADMIN_TOKEN` is empty).

## 2. Provider firewall / networking

**Nothing to open.** The tunnel dials outbound
(TCP egress allowed by default); no ingress rules are needed. Existing host
services keep their existing exposure. (A leftover firewall rule from an old setup
is harmless; the tunnel does not need it.)

## 3. Server prep (Debian/Ubuntu VPS)

```bash
sudo apt update && sudo apt -y upgrade
curl -fsSL https://get.docker.com | sudo sh    # docker + compose plugin
sudo apt -y install sqlite3 rclone fail2ban
sudo usermod -aG docker "$USER"                # re-login afterwards
```

## 4. Deploy the kit

`./deploy.sh` (from §0) does all of this: creates `/opt/passvault`, installs
Docker if missing, rsyncs the kit up (excluding `backups/`, `data/`, and
`.deploy.env`), and runs `docker compose up -d`. On the server you only need:

```bash
cd /opt/passvault
cp .env.example .env        # DOMAIN is already https://vault.yourdomain.com
```

## 5. Configure

1. **Domain:** already set - `DOMAIN=https://vault.yourdomain.com` comes from
   `.env.example` when you copy it to `.env`.
2. **Admin token** (argon2, never a plain password):

```bash
docker run --rm -it vaultwarden/server:latest /vaultwarden hash
```

   Paste the `$argon2id$...` string into `.env` **single-quoted** (it contains
   `$`): `ADMIN_TOKEN='$argon2id$v=19$...'`. Leave it empty to disable
   `/admin` entirely - pair that with Cloudflare Access if you still want it.

3. **Signups:** `.env` ships with `SIGNUPS_ALLOWED=true` (open registration;
   each signup gets its own zero-knowledge keys). Add SMTP + `SIGNUPS_VERIFY=true` to stop throwaway
   signups, and see the hardening step in §9 for later.
4. **Tunnel:** run `./tunnel-init.sh` once (browser authorize → create → route
   DNS), then `./deploy.sh` starts the full stack.

## 6. Start and verify

```bash
docker compose up -d
docker compose logs -f          # wait for "Rocket has launched"; Ctrl-C
curl -I https://vault.yourdomain.com/alive     # expect HTTP/2 200
```

Browser: open https://vault.yourdomain.com → Create account → store your
master password somewhere safe offline (there is **no recovery** - zero
knowledge).

Then immediately: Settings → Security → Two-step Login → enable TOTP or
WebAuthn. (Vaultwarden unlocks all premium features for free, including
WebAuthn 2FA and attachments.)

## 7. Backups to Google Drive (encrypted)

The script refuses to run against a non-crypt remote by design.

1. **On your laptop** (has a browser, needed for Google OAuth):

```bash
rclone config            # n) new remote → name: gdrive → type: drive
                         # client_id/secret: blank (uses rclone's built-in)
                         # scope: 1 (drive) → auto-confirm → browser OAuth
rclone config create gdrive-crypt crypt remote=gdrive:vaultwarden
rclone config show gdrive gdrive-crypt   # copy these two sections
```

2. **On the server:** paste both sections into `~/.config/rclone/rclone.conf`
   (create the dir). The OAuth token lives in that file - back it up.

3. **First run + verify:**

```bash
cd /opt/passvault && ./backup.sh
rclone ls gdrive-crypt:vaultwarden       # you should see one .tar.gz
# download it on the laptop and confirm it's unreadable without the crypt key
```

4. **Schedule it:**

```bash
sudo cp systemd/passvault-backup.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now passvault-backup.timer
systemctl list-timers | grep passvault
```

5. **Crypt password:** store it offline (password manager's emergency sheet /
   printed). Without it the Google Drive copy is junk.

6. **Restore drill (do it once now, quarterly later):**

```bash
rclone copy gdrive-crypt:vaultwarden ./restore --max-depth 1
cd restore && tar xzf "$(ls -1t passvault-*.tar.gz | head -1)"
mkdir -p scratch && cp db.sqlite3 scratch/
docker run --rm -d -p 8080:80 -v "$PWD/scratch":/data vaultwarden/server:latest
# open http://localhost:8080 (or SSH tunnel) and log in; then clean up
```

## 8. fail2ban

```bash
sudo cp fail2ban/vaultwarden.conf /etc/fail2ban/filter.d/
sudo cp fail2ban/vaultwarden.local  /etc/fail2ban/jail.d/
# sanity-check the filter against a real log line:
sudo fail2ban-regex /opt/passvault/data/vw.log /etc/fail2ban/filter.d/vaultwarden.conf
sudo systemctl restart fail2ban
```

Because `IP_HEADER=CF-Connecting-IP` is set, bans hit the real client IP, not
Cloudflare's edge.

## 9. Hardening checklist (after onboarding people)

- [ ] `.env`: `SIGNUPS_ALLOWED=false` (admin-panel invites keep working)
- [ ] SMTP configured + `SIGNUPS_VERIFY=true`, or `SIGNUPS_DOMAINS_WHITELIST`
- [ ] `docker compose up -d` to apply
- [ ] Cloudflare Access on `/admin*` (or empty ADMIN_TOKEN to disable it)
- [ ] `unattended-upgrades` active: `sudo apt -y install unattended-upgrades`
- [ ] SSH: key-only via `sshd/99-hardening.conf`
      (`sudo cp sshd/99-hardening.conf /etc/ssh/sshd_config.d/ && sudo sshd -t && sudo systemctl reload ssh`),
      port 22 limited to your IP in the Security List
- [ ] Your account has 2FA enabled (§6)

## 10. Clients

| Platform | Install | Sign-in |
|---|---|---|
| macOS | `brew install --cask bitwarden` | gear icon → Self-hosted → `https://vault.yourdomain.com` |
| Windows | `winget install -e --id Bitwarden.Bitwarden` | same |
| Debian | `.deb` from bitwarden.com/download (or the official packages.bitwarden.com apt repo) | same |
| Brave / Chromium | Chrome Web Store → **Bitwarden Password Manager** (official extension) | same |

After installing the **desktop app**, enable biometrics:
1. Desktop app → Settings → *Enable browser integration* (extension talks to
   the app), plus Touch ID / Windows Hello unlock in the app itself.
2. Extension → Settings → unlock with biometrics.

**Passkeys:** extension → Settings → Passkeys section → enable saving and
using passkeys. Test the whole loop on [webauthn.io](https://webauthn.io):
create a passkey (extension stores it in the vault), sign out, sign back in
with the stored passkey.

**Autofill/TOTP:** works out of the box; enable extension autofill on page
load in its settings if you like prompts.

## 11. Updates

```bash
cd /opt/passvault && ./backup.sh        # always backup first
docker compose pull && docker compose up -d
docker image prune -f
```

Do it monthly; watch `docker compose logs vaultwarden` after upgrades.

## 12. Migration / portability

The whole state is `data/` (SQLite + attachments). To move servers:

```bash
./backup.sh                                   # on the old server
rclone copy gdrive-crypt:vaultwarden ./restore # on the new one, after §3-§5
# extract db.sqlite3 into the new data/ dir, docker compose up -d
```

Then edit the Cloudflare `A` record to the new IP. DNS propagates in seconds
on Cloudflare, and clients never notice - the URL never changes.

## 13. Files in this kit

```
docker-compose.yml   Vaultwarden + cloudflared tunnel, memory-capped for the 1 GB VM
tunnel-init.sh       one-time Cloudflare Tunnel bootstrap (login/create/route DNS)
cloudflared/         tunnel credentials + config.yml (created by tunnel-init.sh)
.env.example         Vaultwarden configuration template
backup.sh            SQLite snapshot + config → rclone crypt remote
systemd/             daily 04:00 backup timer (Persistent=true)
fail2ban/            filter + jail for Vaultwarden's log
sshd/                key-only SSH drop-in for the server
deploy.sh            non-interactive deploy: reads .deploy.env, uploads kit, starts stack
.deploy.env          deploy connection settings (host/user/domain/key content) - never uploaded
recover.sh           post-crash rescue (crash-loop stop, swap, packages, hardening, deploy)
workers/             TARGET B: NodeWarden on Cloudflare Workers (see workers/README.md)
SECRETS.md           who generates/holds which secret, and what never goes in .env
```
