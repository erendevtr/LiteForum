# LiteForum

A lightweight, open-source forum: vanilla PHP 8.2, SQLite (WAL), Nginx, PHP-FPM. No framework, no Composer, no Docker. One installer script brings up a working site on a small VPS.

[Live demo](https://demo.erendev.xyz) · [Install](#quick-start) · [Security](#security) · [ErenDev OAuth](#erendev-oauth--turkish-ui-only) · [Contributing](#contributing)

![license](https://img.shields.io/badge/license-MIT-22c55e)
![php](https://img.shields.io/badge/php-8.2%2B-777bb4)
![sqlite](https://img.shields.io/badge/sqlite-3.35%2B-003b57)

---

## What it is

LiteForum is a self-hosted forum engine. Categories contain topics, topics contain posts, and posts accept reactions and image attachments. Users register with email and password, or through ErenDev OAuth on Turkish-UI installs. Moderators can pin, lock, and delete posts. Admins manage categories, roles, users, the optional AI assistant, Turnstile, and site settings from a single tabbed admin panel. Admin and moderation actions are written to an audit log.

It is intentionally small. The whole application is plain PHP you can read top to bottom.

---

## Why LiteForum

- **Small footprint.** PHP-FPM runs in `ondemand` mode with OPcache. The app is designed for a 512 MB VPS with no swap.
- **No build step.** No `vendor/` directory, no Node on the runtime path, hand-written CSS.
- **SQLite with WAL.** `journal_mode=WAL`, `busy_timeout=5000`, `synchronous=NORMAL`, `foreign_keys=ON`.
- **One-command install.** The installer provisions Nginx, PHP-FPM, TLS (Let's Encrypt or Cloudflare), UFW, Fail2ban, encrypted nightly backups, and basic kernel hardening.
- **Three ways to get a URL.** A domain with Let's Encrypt, a domain behind a Cloudflare tunnel (no open inbound ports), or a temporary `trycloudflare.com` address with no domain at all.
- **Six UI languages.** Turkish, English, French, German, Spanish, and Arabic (RTL). Switching is instant from the header. Turkish and English are complete; the others fall back to English for untranslated strings.
- **Optional AI assistant.** Anthropic or OpenAI can post replies to topics, processed by a worker that runs every minute. Disabled by default.
- **ErenDev OAuth, Turkish UI only.** See [the gate](#erendev-oauth--turkish-ui-only).

---

## Demo

**https://demo.erendev.xyz**

---

## Quick start

### Requirements

- Ubuntu 22.04 / 24.04 or Debian 12 (x86_64 or arm64)
- Root access
- 512 MB RAM minimum, 1 GB recommended
- One of:
  - a domain pointing at the server's public IP (Let's Encrypt), with **ports 80 and 443 open** in both the OS firewall and your provider's cloud firewall (Oracle Cloud, AWS Lightsail, and similar have a separate one);
  - a domain on Cloudflare (`--cf-login` or `--cf-token`), which needs **no inbound ports**;
  - no domain (`--cloudflared`), also with no inbound ports.

### Install

Pick one of the following.

Turkish forum with a domain (Let's Encrypt):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --email  you@example.com \
  --admin  admin@example.com \
  --lang   tr
```

English forum with a domain (ErenDev button is never rendered):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --email  you@example.com \
  --admin  admin@example.com \
  --lang   en
```

Cloudflare, login-link flow (creates the tunnel and DNS record for you):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --cf-login \
  --admin  admin@example.com \
  --lang   tr
```

The installer prints a Cloudflare login URL. Open it, choose your zone, and the rest is automatic.

Cloudflare, token-based named tunnel (stable address, no certbot):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --cf-token <TUNNEL_TOKEN> \
  --admin   admin@example.com \
  --lang    tr
```

See [Cloudflare named tunnel setup](#cloudflare-named-tunnel-setup) first. The token will end up in your shell history. Clear it afterwards with `history -d $(history 1 | awk '{print $1}')` or by editing `~/.bash_history`.

No domain, temporary address:

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --cloudflared \
  --admin  admin@localhost \
  --lang   en
```

### Read the credentials

```bash
sudo cat /root/liteforum-credentials.txt
```

The file is mode `0600`. It contains the admin password, the app key, the OAuth client values, and the public URL. Store the admin password somewhere safe and delete the file once you have.

### Installer flags

| Flag | Default | Description |
|---|---|---|
| `--domain <fqdn>` | required unless `--cloudflared` | Public hostname. Used for Let's Encrypt, or as the tunnel hostname with `--cf-token` / `--cf-login` |
| `--cf-login` | off | Named tunnel created through a Cloudflare login link. Requires `--domain`. Cannot be combined with `--cf-token` |
| `--cf-token <token>` | off | Run a named tunnel with an existing token. Requires `--domain` |
| `--cloudflared` | off | Quick tunnel with a random `trycloudflare.com` address. Cannot be combined with `--domain`, `--cf-token`, or `--cf-login` |
| `--email <mail>` | `admin@<domain>` | Let's Encrypt contact address |
| `--admin <mail>` | `admin@<domain>` | Admin account email. With `--cloudflared` the domain is `localhost`, so the default is `admin@localhost` |
| `--lang <tr\|en>` | `tr` | Install language. `tr` writes ErenDev OAuth credentials to `config.php`; `en` does not |
| `--skip-tls` | off | HTTP only, no certbot. HSTS is not sent |
| `--port <n>` | `80` | HTTP port Nginx listens on. Requires `--skip-tls` or a tunnel mode |
| `--no-firewall` | off | Skip UFW setup |
| `--dry-run` | off | Validate arguments and print the plan. Makes no changes |

All domain and email arguments are validated before anything is written. Values containing quotes, spaces, or shell metacharacters are rejected.

### Cloudflare named tunnel setup

Do this once in the Cloudflare dashboard before running the installer:

1. Add your domain to Cloudflare (nameservers pointed at Cloudflare).
2. Open **Zero Trust → Networks → Tunnels → Create a tunnel**, choose **Cloudflared**, and give it a name.
3. Copy the token from the install command shown (the value after `--token`).
4. Under **Public Hostname**, add `forum.example.com`, service type `HTTP`, URL `localhost:80`. This also creates the DNS record.
5. Run the installer with `--domain forum.example.com --cf-token <TUNNEL_TOKEN>`.

The installer stores the token in `/etc/liteforum/cloudflared.env` (mode `0600`) and waits for a registered connection. Routing lives in the Cloudflare dashboard, not on the server. If you change the domain or port, update it there.

### Tunnel modes: what to know

- **Named tunnels** and `--cf-login` terminate TLS at Cloudflare. Nginx serves plain HTTP on `127.0.0.1` only, and UFW does not open 80 or 443.
- **Quick tunnels** get a new address every time the tunnel restarts. Find the current one with `sudo journalctl -u liteforum-cloudflared | grep trycloudflare`. ErenDev OAuth generally fails after a restart because the redirect URI changes, so use a named tunnel if you need the Turkish login button.
- **Client IPs.** Behind a tunnel, the app reads `CF-Connecting-IP`, but only when the request arrives from the local loopback address. Requests that reach the origin from anywhere else are rate-limited by their real socket address, so a client cannot spoof the header.
- **HSTS** is not sent by the origin in tunnel modes. Enable it in Cloudflare under SSL/TLS → Edge Certificates if you want it.

### Verify and go live

With a domain, the site is at `https://forum.example.com`. The installer checks each main page over local HTTP after startup and warns about any that fail. Check `/var/log/liteforum/error.log` for details.

Let's Encrypt is requested with the webroot method (`certbot certonly --webroot`), so Nginx's configuration does not need to be rewritten by certbot. If issuance fails (closed port, DNS not propagated, rate limit), the installer continues with HTTP and warns you. Once DNS and ports are correct, re-run `sudo certbot certonly --webroot -w /var/www/liteforum/public -d <domain>` and then re-run the installer or reload Nginx with the HTTPS configuration. Session cookies are set without the `Secure` flag while the site is on plain HTTP, which is expected.

---

## What the installer touches

```
/var/www/liteforum/                                  application (root-owned, 0755)
/var/lib/liteforum/                                  SQLite DB, sessions, tmp, uploads, backups (liteforum, 0700)
/var/log/liteforum/                                  Nginx, PHP, AI worker, and backup logs (liteforum:adm, 0750)
/etc/nginx/sites-available/liteforum
/etc/nginx/liteforum-common.conf                     shared security headers and locations
/etc/nginx/liteforum-fcgi.conf                       PHP-FPM handler settings
/etc/nginx/conf.d/liteforum-zones.conf               login rate-limit zone
/etc/php/<ver>/fpm/pool.d/liteforum.conf
/etc/fail2ban/jail.d/liteforum.local
/etc/sysctl.d/99-liteforum.conf
/etc/cron.d/liteforum-backup
/etc/cron.d/liteforum-ai                             AI worker, every minute
/usr/local/sbin/liteforum-backup                     nightly backup script (root, 0700)
/etc/liteforum/backup.pass                           backup encryption key (root, 0600)
/etc/systemd/system/liteforum-cloudflared.service    tunnel modes only
/etc/liteforum/cloudflared.env                       named tunnel token (root, 0600)
/etc/cloudflared/                                    --cf-login tunnel config and credentials
/usr/bin/cloudflared                                 tunnel modes only
/root/liteforum-credentials.txt                      admin password and app secrets (root, 0600)
```

The installer does not change SSH configuration. Disable password logins yourself if you want that hardening. UFW opens the SSH port it detects, not a hard-coded 22.

---

## Security

### Defaults

- **CSRF tokens** on every state-changing form, verified with `hash_equals`.
- **Password hashing** with `password_hash()` using PHP's default algorithm. Hashes are upgraded by PHP as the default changes.
- **Sessions:** `httponly`, `SameSite=Strict`, `use_strict_mode`, `use_only_cookies`, and the `Secure` flag whenever the configured base URL is HTTPS. The session ID is regenerated on login.
- **Content-Security-Policy:** `script-src 'self'`, so no inline scripts and no inline event handlers. `connect-src` and `frame-src` allow Cloudflare Turnstile only when it is enabled. `frame-ancestors 'none'`, `object-src 'none'`, and `base-uri 'self'`. `style-src` still allows `'unsafe-inline'` because views use inline `style` attributes.
- **Output escaping:** all user content is HTML-escaped before Markdown-lite formatting is applied. Search snippets and admin-supplied labels are escaped the same way.
- **Uploads:** images only (jpg, png, gif, webp), 5 MB limit. The MIME type is checked with `finfo` and the file must parse as an image. Files are stored under random names outside the web root and served through `media.php` with `nosniff`.
- **Secrets at rest:** the AI API key and Turnstile secret are encrypted with AES-256-GCM using a key derived from `app_key`.
- **Redirects:** post-login and post-reaction redirects accept only local paths.
- **Password reset:** one-hour, single-use tokens, stored as SHA-256 hashes. Responses do not reveal whether an address is registered.
- **ErenDev OAuth:** the account is matched only by the provider's subject ID. Local accounts are never linked by email, and the provider must report a verified email.
- **Bans** are enforced on every request, and roles are reloaded from the database on every request, so demotions take effect immediately.
- **PHP-FPM sandbox:** `open_basedir`, `disable_functions` (`exec`, `shell_exec`, `system`, `proc_open`, `popen`, and related), `display_errors=off`, `expose_php=off`.
- **Rate limits** on login, registration, posting, reactions, and password resets, all stored in SQLite.
- **Audit log** for moderation, admin, and settings actions, with actor, IP, and timestamp.
- **Fail2ban** jails for sshd, nginx HTTP auth, and nginx `limit_req` events from the LiteForum error log.
- **UFW** allows only SSH, plus HTTP and HTTPS in Let's Encrypt mode.
- **Kernel:** `dmesg_restrict`, `kptr_restrict=2`, protected hardlinks and symlinks, SYN cookies.
- **Backups:** daily at 03:45 UTC, consistent snapshot via `sqlite3 .backup`, AES-256-CBC with PBKDF2, 14-day retention.

### Changes in this revision

- Installer arguments are validated before being written into nginx, PHP, and SQL.
- The installer refuses to run over an existing database instead of silently leaving it in place.
- Password hashing uses `password_hash()` with PHP's default algorithm, so it works on any PHP 8.2 build.
- Let's Encrypt uses the webroot method. The HTTP-only fallback warns instead of leaving a half-configured site.
- Nginx shared rules moved into one include file, and Turnstile is allowed in the CSP only when used.
- The UFW SSH rule follows the port sshd actually listens on.
- Admin panel moved to tabs. Admin labels and messages go through the translation layer.
- Secrets for the AI assistant and Turnstile are encrypted at rest.
- Image uploads are validated by content, not extension.

### Known limitations

- The `cloudflared` binary is downloaded from the latest GitHub release without a checksum check. Pin and verify it yourself if your threat model requires that.
- ErenDev OAuth uses the Authorization Code flow with `state`. PKCE is not implemented yet.
- Re-running the installer on an existing site is refused when a database is present. It is not an upgrade path. See [Upgrading](#upgrading).
- Backups are encrypted with a key stored on the same server. Copy backup files off the server to protect against losing the machine.
- Login is rate-limited per IP only, not per account.
- AI-generated replies are visible to all users. Review the provider and system prompt before enabling the assistant on a public forum.
- The `'unsafe-inline'` style allowance in the CSP remains until views move their inline styles into the stylesheet.

---

## ErenDev OAuth — Turkish UI only

LiteForum integrates with the [ErenDev Identity Provider](https://oauth2.erendev.xyz) using the OAuth2 Authorization Code flow.

The button appears only when **both** of these are true:

1. The forum was installed with `--lang tr`, so OAuth credentials exist in `config.php`.
2. The visitor's current UI language is Turkish.

If either check fails, the button is not written to the HTML. The callback endpoint also returns 404 under the same conditions.

| Install lang | UI lang | Button | Callback |
|:---:|:---:|:---:|:---:|
| `tr` | `tr` | shown | active |
| `tr` | any other | not emitted | 404 |
| `en`, `fr`, `de`, `es`, `ar` | any | not emitted | 404 |

The check in `views/login.php` and `views/register.php`:

```php
$showErenDev = (($config['default_lang'] ?? '') === 'tr')
            && (($_SESSION['ui_lang'] ?? '') === 'tr');
```

The callback repeats both checks before doing anything else.

Verify on an English install:

```bash
curl -s https://forum.example.com/login.php | grep -i erendev
# (no output)
```

Accounts created through ErenDev get a random local password, so they can only sign in through the provider. Accounts whose email already exists locally are not linked automatically. The login is refused with a message instead.

---

## Features

### Forum

- Categories, topics, and posts, with view counts and pinned or locked flags.
- Category tags. Admins define the tags allowed in each category. Authors pick up to five when starting a topic, and the category page filters by tag.
- Image attachments on topics and replies.
- Reactions on posts: 👍 ❤️ 🔥 😂 😮. One per user per emoji, toggleable.
- Full-text search across post bodies with SQLite FTS5, ranked by `bm25()`, with highlighted snippets. Filter by category and author.
- Notifications for `@mentions`, replies in watched topics, and reactions to your posts. Each type can be turned off in Settings. Unread count in the header.
- Markdown-lite in posts: `**bold**`, `*italic*`, `` `code` ``, `[link](https://…)`, `> quote`, and `@mention`.
- Profiles at `/user.php?u=<username>`, an activity feed, and a stats page with an online counter.
- Optional AI assistant. When enabled, it can reply to new topics and replies from a dedicated account. Replies are generated by a worker that runs every minute, using Anthropic or OpenAI.

### Accounts

- Email and password registration, protected by Cloudflare Turnstile when enabled.
- Password change and profile settings (bio, theme, accent, avatar colour, notification preferences) from Settings.
- Password reset by email, one-hour single-use links.
- Bans: banned users cannot sign in, and active sessions end on their next request.
- ErenDev OAuth on Turkish-UI installs.

### Moderation (moderators and admins)

- Pin and unpin topics.
- Lock and unlock topics. Locked topics accept no replies.
- Soft-delete posts. They show as `[deleted]` and the thread structure stays intact.

### Admin-only

- Delete topics.
- Ban and unban users.
- Site name and tagline, reflected in the header, page titles, and footer.
- Category management: add, edit, and delete, with names and descriptions in all six languages, an emoji icon, and a sort position.
- Category tags, managed per category.
- Role management for `member`, `moderator`, and `admin`, plus custom roles with a colour and a power level. Power level 50 and above grants moderator permissions. Custom roles cannot grant admin.
- Verified-account badges on user profiles and posts.
- Turnstile configuration: site key, encrypted secret, and enable switch.
- AI assistant configuration: provider, model, encrypted API key, and enable switch.
- Audit log of the last 100 actions.

The admin panel is at `/admin.php` and is split into tabs: General, AI assistant, Turnstile, Users & roles, Categories, and Audit log.

### Personalization

- Themes: `dark`, `light`, `high-contrast`.
- Accents: `indigo`, `emerald`, `rose`, `amber`, `sky`.
- Avatar colour for the generated initial avatar.

---

## Operations

### Upgrading

There is no in-place upgrade path yet. The installer refuses to run when a database already exists, so it cannot overwrite a live site by accident. To update code safely:

1. Take a manual backup (below).
2. Copy your changed files into `/var/www/liteforum/` by hand, keeping `config/config.php` as it is.
3. Apply any SQL changes to `/var/lib/liteforum/liteforum.db` with `sqlite3`.
4. Reload services: `sudo systemctl reload php*-fpm nginx`.

To reinstall from scratch, stop the services, move `/var/lib/liteforum/` out of the way, and run the installer again. This regenerates all secrets and invalidates existing sessions and OAuth configuration.

### Backups

The installer schedules a backup at 03:45 UTC every day. The script lives at `/usr/local/sbin/liteforum-backup`, writes encrypted archives to `/var/lib/liteforum/backups/`, and deletes archives older than 14 days. Logs go to `/var/log/liteforum/backup.log`.

Backups cover the database only. Uploaded images in `/var/lib/liteforum/uploads/` are not included in the current script. If you rely on uploads, add that directory to the archive step.

To take a manual backup:

```bash
sudo /usr/local/sbin/liteforum-backup
```

To restore an archive:

```bash
sudo systemctl stop php*-fpm nginx
sudo mkdir -p /tmp/lf-restore
sudo openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass file:/etc/liteforum/backup.pass \
  -in /var/lib/liteforum/backups/lf-YYYY-MM-DD-HHMM.tar.gz.enc \
  | sudo tar xzf - -C /tmp/lf-restore
sudo rm -f /var/lib/liteforum/liteforum.db-wal /var/lib/liteforum/liteforum.db-shm
sudo install -o liteforum -g liteforum -m 0600 /tmp/lf-restore/liteforum.db /var/lib/liteforum/liteforum.db
sudo rm -rf /tmp/lf-restore
sudo systemctl start php*-fpm nginx
```

Copy the archives and `/etc/liteforum/backup.pass` off the server. An archive is useless without the key, and an archive kept only on the same disk does not protect you from disk failure.

### Logs

- Nginx and PHP errors: `/var/log/liteforum/error.log`, `/var/log/liteforum/php-error.log`
- Access log: `/var/log/liteforum/access.log`
- AI worker: `/var/log/liteforum/ai-worker.log`
- Installer log: `/var/log/liteforum-install.log`
- Tunnel: `sudo journalctl -u liteforum-cloudflared`

### Uninstalling

```bash
sudo systemctl disable --now nginx php*-fpm fail2ban
sudo systemctl disable --now liteforum-cloudflared 2>/dev/null
sudo rm -f /etc/systemd/system/liteforum-cloudflared.service /etc/liteforum/cloudflared.env
sudo rm -rf /etc/cloudflared
sudo rm -f /etc/nginx/sites-enabled/liteforum /etc/nginx/sites-available/liteforum
sudo rm -f /etc/nginx/liteforum-common.conf /etc/nginx/liteforum-fcgi.conf /etc/nginx/conf.d/liteforum-zones.conf
sudo rm -f /etc/cron.d/liteforum-backup /etc/cron.d/liteforum-ai /usr/local/sbin/liteforum-backup
sudo rm -rf /var/www/liteforum /var/lib/liteforum /var/log/liteforum /etc/liteforum
sudo rm -f /root/liteforum-credentials.txt
sudo userdel liteforum 2>/dev/null
```

---

## Technology stack

| Layer | Choice |
|---|---|
| Web server | Nginx, TLS 1.2 / 1.3, HTTP/2, `limit_req` |
| PHP | PHP 8.2+ FPM, `ondemand` pool, OPcache |
| Framework | None. Vanilla PHP. |
| Database | SQLite 3.35+, WAL, `busy_timeout=5000` |
| Search | FTS5 with `bm25()` and `snippet()` |
| Styling | Hand-written CSS with variables. No build step |
| Passwords | `password_hash()` / `password_verify()` |
| Encryption at rest | AES-256-GCM for stored API keys and secrets |
| OAuth | OAuth2 Authorization Code, ErenDev IdP. Turkish UI only |
| Bot protection | Cloudflare Turnstile (optional) |
| AI assistant | Anthropic or OpenAI HTTP APIs via cURL (optional) |
| TLS | Let's Encrypt (Certbot, webroot) or Cloudflare tunnel termination |
| Firewall | UFW and Fail2ban |
| Backups | `sqlite3 .backup`, `tar`, `openssl enc` |

---

## Multilingual UI

Translations live in `lang/` as flat `[key => string]` arrays. `en.php` is the complete base. Other files only need to override the keys they translate. Missing keys fall back to English, then to the key name.

```
lang/
├── en.php   English (complete base)
├── tr.php   Turkish (complete)
├── fr.php   French (partial, falls back to English)
├── de.php   German (partial, falls back to English)
├── es.php   Spanish (partial, falls back to English)
└── ar.php   Arabic (partial, RTL)
```

### Adding a language

1. Create `lang/<code>.php` and return an array with the keys you want to translate. Start from `lang/en.php` to see every key.
2. Add the code to `available_langs` in `config/config.php`.
3. For category names and descriptions, fill the matching `name_<code>` and `description_<code>` columns in the admin panel. Empty values fall back to English.

Reload the page. No build step.

---

## Contributing

The codebase is small and deliberately simple. Keep these rules in mind:

- **Stay vanilla.** No Composer packages, no PHP framework, and no Node at runtime.
- **Every state-changing form needs `csrf_field()` and `csrf_verify()`.**
- **Escape all output with `e()`.** This includes search snippets, admin labels, and anything from the database.
- **Use PDO prepared statements** for all SQL. No string interpolation.
- **Translate every user-facing string with `t()`.** Hard-coded text in views breaks the language switcher.
- **No inline JavaScript or inline event handlers.** The CSP forbids them. Use `data-*` attributes and `public/assets/app.js`.
- **Keep the ErenDev gate intact.** Changes to `views/login.php`, `views/register.php`, or `public/oauth/erendev/callback.php` must keep both checks (`default_lang === 'tr'` and `ui_lang === 'tr'`).
- **Commit messages:** imperative, present tense, 72 characters or fewer on the first line.

### Running locally

```bash
git clone https://github.com/liteforum/liteforum.git
cd liteforum

# Show the install plan without changing anything
sudo bash install.sh --dry-run --domain localhost --lang tr
sudo bash install.sh --dry-run --cloudflared --lang tr

# Check the installer syntax
bash -n install.sh

# Or run the app without installing
php -S 127.0.0.1:8080 -t public
```

### Good first issues

1. **Complete a language file.** Fill in `fr.php`, `de.php`, `es.php`, or `ar.php`. See [Adding a language](#adding-a-language).
2. **Translation audit.** Find hard-coded strings in `views/*.php` and move them into `lang/en.php`.
3. **Theme swatches.** The settings page shows a plain `<select>` for themes and accents. Add small colour previews using the variables in `app/theme.php`.
4. **Compact ErenDev button.** An icon-only variant for the header, documented in the ErenDev section. It must keep the double gate.
5. **Notification digest.** `users.notify_digest` is stored but nothing reads it. Add `bin/digest.php` that batches unread notifications per user and sends a summary, plus a cron entry.
6. **Upload backups.** Include `/var/lib/liteforum/uploads/` in `liteforum-backup`.

Open an issue titled with `good first issue` and mention `@liteforum/core` for review.

### Reporting bugs

Include:

- LiteForum commit (`git rev-parse --short HEAD`)
- PHP version (`php -v`)
- The install command you used (with secrets removed)
- `sudo journalctl -u php*-fpm -u nginx --since "10 min ago"`
- For tunnel installs, `sudo journalctl -u liteforum-cloudflared --since "10 min ago"`
- For AI problems, the last lines of `/var/log/liteforum/ai-worker.log` and the `error` column of the `ai_jobs` table (no API keys)

**For security issues, do not open a public issue.** Email `security@liteforum.dev`. We aim to reply within 72 hours.

---

## FAQ

**Is SQLite enough for a forum?**
For a forum with a few hundred concurrent readers, yes. WAL allows concurrent reads alongside a single writer. Past a few thousand concurrent readers, revisit the choice.

**Can I use PostgreSQL or MySQL?**
Not yet. FTS5 and several PRAGMA calls are SQLite-specific. An adapter is on the long-term list.

**Why not Flarum?**
Flarum is a good project with a larger feature set. It needs Composer, a database server, and a queue worker. LiteForum needs none of those.

**Can I enable ErenDev OAuth on an English forum later?**
No. The OAuth credentials are only generated when the install uses `--lang tr`. Reinstalling is the only route, and it regenerates secrets. See [Upgrading](#upgrading).

**Does the language switcher hide the ErenDev button for non-Turkish users?**
Yes. The button is emitted only when the install language and the current UI language are both Turkish. Switching the dropdown to any other language removes it on the next page load.

**What does `/oauth/erendev/callback.php` return on a non-Turkish UI?**
404. It applies the same two checks as the button.

**Do I need a domain?**
No. `--cloudflared` gives a temporary address that changes on restart. For a permanent address, use `--domain` with `--cf-login` or `--cf-token` (no open ports needed) or without a tunnel flag (Let's Encrypt).

**Do I need to open ports 80 and 443 with a Cloudflare tunnel?**
No. The tunnel makes only outbound connections. The installer does not open those ports in tunnel modes.

**How do I turn on the AI assistant?**
Sign in as admin, open `/admin.php?tab=ai`, choose a provider, optionally set a model, paste an API key, and tick Enabled. Replies are produced by a worker that runs every minute, so expect a short delay. The key is stored encrypted.

**Can I require a bot check on registration?**
Yes. Create a Turnstile widget in Cloudflare, then enter the site key and secret in `/admin.php?tab=turnstile` and enable it. If it is enabled without a secret, login and registration are blocked until you add one.

**How do I change the site name?**
Sign in as admin and open `/admin.php`. The General tab has name and tagline fields. Saving updates the header, titles, and footer immediately.

**How do I make someone a moderator?**
On `/admin.php?tab=users`, enter the username in the role assignment form, choose a role, and submit. Or use the bulk role form with the user IDs. Moderators can pin, lock, and delete posts. Only admins can delete topics and ban users.

**Is there an API?**
No. The routes are plain PHP files under `public/`, so you can call them directly if you need something custom.

---

## License

MIT License. Copyright (c) 2026 LiteForum contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

**Demo:** https://demo.erendev.xyz · **Install script:** https://get.erendev.xyz/install.sh · **OAuth docs:** https://oauth2.erendev.xyz
