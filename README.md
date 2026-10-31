# LiteForum

A lightweight, modern, open-source forum — vanilla PHP + SQLite (WAL) + Nginx + PHP-FPM.

Runs comfortably on the cheapest $3 VPS. No framework. No Composer. No Docker required. One command and it's live.

[Live demo](https://demo.erendev.xyz) · [Install](#quick-start) · [Features](#features) · [ErenDev OAuth](#erendev-oauth--turkish-ui-only) · [Contributing](#contributing)

![license](https://img.shields.io/badge/license-MIT-22c55e)
![php](https://img.shields.io/badge/php-8.2%2B-777bb4)
![sqlite](https://img.shields.io/badge/sqlite-3.35%2B-003b57)

---

## What it is

LiteForum is a self-hosted forum engine. Categories hold topics, topics hold posts, posts accept reactions. Users register with an email address and a password, or — on Turkish-UI installs — with ErenDev OAuth. Moderators can pin, lock, and delete. Admins can manage categories, users, and site settings from a single page. Every action is written to an audit log.

It is not a clone of Flarum or phpBB. It is a small, auditable forum that you can deploy in a minute on hardware you already have.

---

## Why LiteForum

- **512 MB RAM VPS, zero swap.** PHP-FPM `ondemand` pool, OPcache preloaded, no long-running workers. Idles under 40 MB RSS.
- **Vanilla PHP 8.2.** No framework, no `vendor/` folder. Every file is readable top-to-bottom.
- **SQLite with WAL.** `journal_mode=WAL`, `busy_timeout=5000`, `synchronous=NORMAL`, `foreign_keys=ON`. Concurrent reads alongside a single writer.
- **One-command install.** `curl | bash` provisions Nginx, PHP-FPM, TLS, UFW, Fail2ban, cron backups, and kernel hardening. No Docker, no Kubernetes, no YAML.
- **Cloudflare tunnel, with or without a domain.** `--cf-token` gives you a stable domain behind Cloudflare with no certbot and no open inbound ports. `--cloudflared` gives a temporary address with no domain at all.
- **Six languages out of the box.** Turkish, English, French, German, Spanish, Arabic (RTL). A dropdown in the header switches the UI instantly. Adding a seventh language is a 40-line file.
- **ErenDev OAuth, scoped to Turkish.** The button appears only when both the install language and the current UI language are Turkish. In every other combination it is not written to the served HTML at all.
- **Sane security defaults.** CSRF on every form, Argon2id passwords, secure session cookies, CSP, HSTS, rate limits, audit log — all pre-wired.

---

## Screenshots

| Home | Category | Topic |
|:---:|:---:|:---:|
| ![Home](docs/screenshots/home.png) | ![Category](docs/screenshots/category.png) | ![Topic](docs/screenshots/topic.png) |
| Stats, categories, recent topics | Topic list with pinned/locked badges | Posts, reactions, moderation bar |

| Login (Turkish UI) | Login (any other UI) | Admin |
|:---:|:---:|:---:|
| ![Login TR](docs/screenshots/login-tr.png) | ![Login EN](docs/screenshots/login-en.png) | ![Admin](docs/screenshots/admin.png) |
| ErenDev button visible | ErenDev button absent | Settings, categories, users, audit |

Dark theme, indigo accents, glass panels, dotted background. Light and high-contrast themes are available per user in Settings.

> Placeholder paths. Replace `docs/screenshots/*.png` with real captures.

---

## Demo

**https://demo.erendev.xyz**

- Installed with `--lang tr`, so the ErenDev OAuth button **is** shown when the UI is Turkish. Switch the language dropdown to English and the button disappears on the next page load.
- Reset nightly at 03:00 UTC.
- Admin demo: `info@erendev.xyz` / `demo-admin-2026` (rotated weekly).

---

## ErenDev OAuth — Turkish UI only

LiteForum integrates with the [ErenDev Identity Provider](https://oauth2.erendev.xyz) via the OAuth2 Authorization Code flow.

**The button is rendered only when BOTH conditions are true:**

1. The forum was installed with `--lang tr` (OAuth credentials exist in `config.php`).
2. The visitor's current UI language is Turkish.

If either condition fails, the button is **not present in the served HTML at all**. No CSS hiding, no JavaScript removal. The `<img>` is simply never written to the response.

### Behavior matrix

| Install lang | Current UI lang | Button | Callback endpoint |
|:---:|:---:|:---:|:---:|
| `tr` | `tr` | ✅ Shown | ✅ Active |
| `tr` | `en` | ❌ Not emitted | ❌ 404 |
| `tr` | `fr` / `de` / `es` / `ar` | ❌ Not emitted | ❌ 404 |
| `en` | any | ❌ Not emitted | ❌ 404 |
| `fr` / `de` / `es` / `ar` | any | ❌ Not emitted | ❌ 404 |

### How it is enforced

The button in `views/login.php` and `views/register.php`:

```php
$showErenDev = (($config['default_lang'] ?? '') === 'tr')
            && (($_SESSION['ui_lang'] ?? '') === 'tr');
if ($showErenDev):
?>
  <a href="<?= e($oauth_url) ?>">
    <img src="https://oauth2.erendev.xyz/erendev-login-button.svg"
         alt="ErenDev ile Giriş Yap" class="h-12">
  </a>
<?php endif; ?>
```

The callback endpoint (`public/oauth/erendev/callback.php`):

```php
if (($config['default_lang'] ?? '') !== 'tr') { http_response_code(404); exit; }
if (($_SESSION['ui_lang'] ?? '') !== 'tr')     { http_response_code(404); exit; }
```

Verify yourself on an EN install:

```bash
curl -s https://forum.example.com/login.php | grep -i erendev
# (empty output)
```

### Adding the button to your own site

The official SVG is public:

```html
<a href="https://oauth2.erendev.xyz/oauth/authorize?client_id=YOUR_CLIENT_ID&redirect_uri=YOUR_CALLBACK&response_type=code&scope=profile%20email&state=RANDOM">
  <img src="https://oauth2.erendev.xyz/erendev-login-button.svg"
       alt="ErenDev ile Giriş Yap" class="h-12">
</a>
```

Full OAuth2 + PKCE + OIDC docs: [oauth2.erendev.xyz/developer/docs](https://oauth2.erendev.xyz/developer/docs).

---

## Features

### Forum

- **Categories → Topics → Posts**, with per-topic view counts and pinned/locked flags.
- **Reactions** on every post: 👍 ❤️ 🔥 😂 😮. One per user per emoji, toggleable.
- **Full-text search** across post bodies using SQLite FTS5, ranked with `bm25()`, with `snippet()` highlighting. Filter by category and author.
- **Notifications** for mentions (`@username`), replies to watched topics, and reactions to your posts. Per-user toggles for each type. Unread badge in the header.
- **Markdown-lite** in posts: `**bold**`, `*italic*`, `` `code` ``, `[link](url)`, `> quote`, `@mention`. HTML is escaped before formatting.
- **User profiles** at `/user.php?u=username` with bio, avatar color, recent topics and posts.
- **Activity feed** (`/activity.php`) and **stats page** (`/stats.php`) with online counter and top users.

### Accounts

- **Email + password registration** with Argon2id hashing.
- **Password change** from `/settings.php`.
- **Password reset via email** at `/forgot-password.php` (one-hour tokens, single use).
- **Ban enforcement** — banned users cannot log in; active sessions are terminated on next request.
- **ErenDev OAuth** — Turkish-UI installs only, per the rule above.

### Moderation

- **Pin / unpin** topics (visible to moderators and admins).
- **Lock / unlock** topics (blocks new replies).
- **Delete posts** (soft delete — shows `[deleted]`, keeps thread structure).
- **Delete topics** (admins only, cascades to posts).
- **Ban / unban users** (admins only, with reason).

### Admin (`/admin.php`)

- **Site settings** — name and tagline editable; reflected in header, title, and footer immediately.
- **Category management** — add, edit, delete. Each category has names and descriptions in all six languages, an emoji icon, and a position.
- **User management** — bulk role changes (`member` / `moderator` / `admin`), ban status visible.
- **Audit log** — last 50 actions with actor, action, target, IP, and timestamp.

### Personalization

- **Three themes** per user: `dark`, `light`, `high-contrast`.
- **Five accent colors**: `indigo`, `emerald`, `rose`, `amber`, `sky`.
- **Avatar color** per user, applied to the generated initial-avatar.

### Security defaults

- **CSRF tokens** on every state-changing form, verified with `hash_equals`.
- **Argon2id** for password hashing.
- **Session hardening** — `httponly`, `secure`, `SameSite=Strict`, `use_strict_mode`, `sid_length=48`.
- **Content-Security-Policy** — no `unsafe-inline` for scripts, `frame-ancestors 'none'`.
- **HSTS** with `includeSubDomains`.
- **PHP-FPM sandbox** — `open_basedir`, `disable_functions` (no `exec`, `shell_exec`, `system`), `display_errors=off`, `expose_php=off`.
- **Kernel hardening** — `dmesg_restrict`, `kptr_restrict=2`, protected hardlinks/symlinks.
- **Rate limits** on login, registration, posting, reactions, and password resets.
- **Fail2ban** jails for sshd and nginx-http-auth.
- **Daily encrypted backups** (AES-256-CBC via `openssl enc -pbkdf2`), 14-day retention.

---

## Quick start

### Requirements

- Ubuntu 22.04 / 24.04 or Debian 12 (x86_64 or arm64)
- **Either** a domain pointing at the server's public IP (Let's Encrypt), **or** a domain managed by Cloudflare (`--cf-token`), **or** no domain at all (`--cloudflared`)
- 512 MB RAM minimum, 1 GB recommended
- Root access
- **Ports 80 and 443 open** (Let's Encrypt mode only) — in your provider's firewall *and* in the OS (`ufw`, `iptables`). Oracle Cloud, AWS Lightsail, and similar providers have a separate cloud-side firewall that must be configured too, or Let's Encrypt validation will fail. Not needed with either Cloudflare tunnel mode, since the tunnel only makes outbound connections.

### Three steps

**1. Install.** Pick one of the three modes below.

Turkish forum with a domain (ErenDev button available):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --email  you@example.com \
  --admin  admin@example.com \
  --lang   tr
```

English forum with a domain (ErenDev button never rendered):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --email  you@example.com \
  --admin  admin@example.com \
  --lang   en
```

Domain behind Cloudflare, login link (easiest, no dashboard steps):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --cf-login \
  --admin  admin@example.com \
  --lang   tr
```

The installer prints a Cloudflare login link. Open it, choose your zone, and the rest is automatic: tunnel creation, DNS record, and the systemd service.

Domain behind Cloudflare, token-based named tunnel (no certbot, stable address):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --cf-token <TUNNEL_TOKEN> \
  --admin   admin@example.com \
  --lang    tr
```

Before running it, see [Cloudflare named tunnel setup](#cloudflare-named-tunnel-setup).

No domain, Cloudflare quick tunnel (temporary `trycloudflare.com` address):

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --cloudflared \
  --admin  admin@example.com \
  --lang   en
```

**2. Read the generated credentials:**

```bash
sudo cat /root/liteforum-credentials.txt
```

**3. Open the site.** With a domain:

```
https://forum.example.com
```

With `--cf-login` or `--cf-token`, the URL is `https://forum.example.com`. With `--cloudflared`, the random `trycloudflare.com` address is printed at the end of the install and written to the credentials file under `URL`.

TLS is provisioned by Let's Encrypt in plain domain mode. The certificate renews automatically via `certbot.timer`. In both Cloudflare modes, TLS is handled by Cloudflare and certbot is not used.

If Let's Encrypt fails (closed port, DNS issue, rate limit), the installer continues with HTTP-only and prints a message telling you to re-run `certbot` later. The forum still works.

### Installer flags

| Flag | Default | Description |
|---|---|---|
| `--domain <fqdn>` | *required* unless `--cloudflared` | Domain for the site. Used for the Let's Encrypt certificate, or as the public hostname with `--cf-token` |
| `--cf-login` | off | Create a named tunnel through a Cloudflare login link. Creates the tunnel and DNS record automatically. TLS is terminated by Cloudflare, certbot is skipped. Requires `--domain`. Cannot be combined with `--cf-token` |
| `--cf-token <token>` | off | Run a Cloudflare named tunnel for `--domain`. TLS is terminated by Cloudflare, certbot is skipped. Requires `--domain` |
| `--cloudflared` | off | Expose the forum through a Cloudflare quick tunnel with a random address. Cannot be combined with `--domain` or `--cf-token` |
| `--email <mail>` | `admin@<domain>` | Let's Encrypt contact + admin email |
| `--admin <mail>` | `admin@<domain>` | Admin account email |
| `--lang <tr\|en>` | `tr` | Install language — controls whether ErenDev OAuth credentials exist |
| `--skip-tls` | off | HTTP only, no certbot; HSTS disabled |
| `--no-firewall` | off | Skip UFW setup |
| `--dry-run` | off | Print plan, make no changes |

When `--cloudflared` is used without `--domain`, the admin email defaults to `admin@localhost`, so pass `--admin` if you want a real address. With `--cf-token`, it defaults to `admin@<domain>`.

### Cloudflare tunnel modes

Both modes run `cloudflared` as a systemd service, `liteforum-cloudflared`, and send traffic from Cloudflare to `http://127.0.0.1:80`. Nginx serves HTTP only, and Cloudflare handles HTTPS for visitors. No open inbound ports are needed.

#### Cloudflare named tunnel setup

Do this once in the Cloudflare dashboard, before running the installer:

1. Make sure your domain is on Cloudflare (added as a zone, nameservers pointed to Cloudflare).
2. Open **Zero Trust → Networks → Tunnels → Create a tunnel**, choose **Cloudflared**, and give it a name.
3. On the install screen, copy the token from the command shown (the value after `--token`). This is `<TUNNEL_TOKEN>`.
4. Under **Public Hostname**, add:
   - Subdomain and domain: `forum.example.com`
   - Service type: `HTTP`
   - URL: `localhost:80`

   This also creates the DNS record for you.
5. Run the installer with `--domain forum.example.com --cf-token <TUNNEL_TOKEN>`.

The installer:

- installs `cloudflared` from the official GitHub release,
- stores the token in `/etc/liteforum/cloudflared.env` (mode 0600), not in the credentials file,
- starts the service and waits for it to report a registered connection,
- sets `base_url` in `config.php` to `https://forum.example.com`.

Public Hostname routing lives in the Cloudflare dashboard, not on the server. If you change the domain or port, update it there.

#### Quick tunnel (no domain)

With `--cloudflared`, the installer reads the random `https://<name>.trycloudflare.com` address from the service log and writes it into `config.php` as `base_url` and as the OAuth `redirect_uri`.

- **The URL changes whenever the tunnel restarts.** Quick tunnels are temporary. Use the named tunnel mode for a stable address.
- **ErenDev OAuth is unreliable in this mode.** The provider has to accept the redirect URI, and the address changes. Expect the Turkish login button to fail after a restart.
- To see the current address: `sudo journalctl -u liteforum-cloudflared | grep trycloudflare`.

#### Things to check in both tunnel modes

- **Rate limits.** Requests through the tunnel arrive from `127.0.0.1`, so IP-based rate limits may treat all visitors as one. The application should read the `CF-Connecting-IP` header when it is behind Cloudflare. Check this before going live.
- **HSTS.** The origin serves HTTP, so the installer does not send HSTS. Enable it under Cloudflare → SSL/TLS → Edge Certificates if you want it.

### What the installer touches

```
/var/www/liteforum/              # Application (root-owned, 0755)
/var/lib/liteforum/              # SQLite DB, sessions, tmp, backups (liteforum-owned, 0700)
/var/log/liteforum/              # Nginx + PHP logs (root:adm, 0750)
/etc/nginx/sites-available/liteforum
/etc/php/<ver>/fpm/pool.d/liteforum.conf
/etc/fail2ban/jail.d/liteforum.local
/etc/sysctl.d/99-liteforum.conf
/etc/cron.d/liteforum-backup
/etc/liteforum/backup.pass       # 0600 backup encryption key
/etc/systemd/system/liteforum-cloudflared.service   # only with --cloudflared or --cf-token
/etc/liteforum/cloudflared.env   # 0600 tunnel token, only with --cf-token
/usr/bin/cloudflared                                # only with --cloudflared or --cf-token
/root/liteforum-credentials.txt  # 0600 admin + OAuth creds
```

### Upgrading

```bash
cd /var/www/liteforum
sudo -u liteforum git pull
sudo sqlite3 /var/lib/liteforum/liteforum.db < migrations/$(ls migrations | tail -1)
sudo systemctl reload php*-fpm nginx
```

### Backing up

The installer schedules a daily encrypted backup at 03:45 UTC. To back up manually:

```bash
sudo -u liteforum sqlite3 /var/lib/liteforum/liteforum.db "PRAGMA wal_checkpoint(TRUNCATE);"
sudo tar czf - /var/lib/liteforum | sudo openssl enc -aes-256-cbc -pbkdf2 -salt \
  -pass file:/etc/liteforum/backup.pass \
  > /var/lib/liteforum/backups/manual-$(date +%F).tar.gz.enc
```

To restore:

```bash
sudo openssl enc -d -aes-256-cbc -pbkdf2 \
  -in /var/lib/liteforum/backups/lf-YYYY-MM-DD.tar.gz.enc \
  -pass file:/etc/liteforum/backup.pass \
  | sudo tar xzf - -C /
sudo chown -R liteforum:liteforum /var/lib/liteforum
sudo systemctl reload php*-fpm nginx
```

### Uninstalling

```bash
sudo systemctl disable --now nginx php*-fpm fail2ban
sudo systemctl disable --now liteforum-cloudflared 2>/dev/null
sudo rm -f /etc/systemd/system/liteforum-cloudflared.service /etc/liteforum/cloudflared.env
sudo rm -f /etc/nginx/sites-enabled/liteforum /etc/nginx/sites-available/liteforum
sudo rm -rf /var/www/liteforum /var/lib/liteforum /var/log/liteforum /etc/liteforum
sudo rm -f /root/liteforum-credentials.txt
sudo userdel liteforum 2>/dev/null
```

---

## Technology stack

| Layer | Choice | Why |
|---|---|---|
| Web server | **Nginx** (TLS 1.2/1.3, HTTP/2, `limit_req`) | Fast, small, well-understood |
| PHP runtime | **PHP 8.2+ FPM**, `ondemand` pool, OPcache | No workers unless traffic needs them |
| Framework | **None — vanilla PHP** | Auditable; no `vendor/` |
| Database | **SQLite 3.35+**, WAL, `busy_timeout=5000` | Single-file, zero ops |
| Full-text search | **FTS5** with `bm25()` and `snippet()` | Built into SQLite |
| Styling | Hand-written CSS with CSS variables | No build step, no Node runtime |
| Sessions | PHP native, file-backed, `SameSite=Strict` | Secure by default |
| Passwords | **Argon2id** via `password_hash` | Modern KDF |
| OAuth | **OAuth2 Authorization Code** (ErenDev IdP) | Optional, Turkish UI only |
| TLS | **Let's Encrypt** via Certbot, or **Cloudflare** tunnel termination | Free, automatic |
| Firewall | **UFW** + **Fail2ban** | Belt and suspenders |
| Backups | `sqlite3 checkpoint` + `tar` + `openssl enc` | Portable, encrypted |

Footprint on a fresh install with 3 categories, 10 topics, 100 posts: **~12 MB on disk**, **~38 MB RSS idle**.

---

## Multilingual UI

Translation files live in `lang/`:

```
lang/
├── tr.php   # Turkish
├── en.php   # English
├── fr.php   # French
├── de.php   # German
├── es.php   # Spanish
└── ar.php   # Arabic (RTL)
```

Each file returns a flat `[key => string]` array. Missing keys fall back to English, then to the key name.

```php
// lang/tr.php
<?php return [
  'forum'         => 'Forum',
  'login'         => 'Giriş Yap',
  'erendev_login' => 'ErenDev ile Giriş Yap',
  // ...
];
```

Usage in views:

```php
<?= e(t('login')) ?>
```

The `<html>` element receives `dir="rtl"` when Arabic is selected.

### Adding a language

1. Copy `lang/en.php` to `lang/<code>.php` and translate the values.
2. Add the code to `config['available_langs']` in `config/config.php`.
3. Add the code to the whitelist in `public/lang.php` (already reads from config — no change needed).
4. Add the code to the `<select>` in `views/layout.php` (already iterates `available_langs` — no change needed).
5. For category names/descriptions, add a `name_<code>` / `description_<code>` column via migration, or leave it empty to fall back to English.

No build step, no cache purge. Reload the page.

---

## Contributing

Contributions are welcome. LiteForum's small codebase makes it a good first project.

### Getting set up

```bash
git clone https://github.com/liteforum/liteforum.git
cd liteforum

# Dry-run to see the plan (no changes)
sudo bash install.sh --dry-run --domain localhost --lang tr

# Dry-run of the tunnel variants
sudo bash install.sh --dry-run --cloudflared --lang tr
sudo bash install.sh --dry-run --domain localhost --cf-token TEST --lang tr

# Or run locally without install
php -S 127.0.0.1:8080 -t public
```

### Guidelines

- **Keep it vanilla.** No Composer packages, no PHP frameworks, no Node on the runtime path. If you need a helper, write 20 lines of PHP.
- **Every state-changing form needs `csrf_field()` and `csrf_verify()`.** PRs missing CSRF will be closed.
- **Escape output with `e()`.** No exceptions.
- **New SQL goes through PDO prepared statements.** No string interpolation.
- **The ErenDev gate is sacred.** Any change touching `views/login.php`, `views/register.php`, or `public/oauth/erendev/callback.php` must preserve the double check (`default_lang === 'tr'` **AND** `ui_lang === 'tr'`). PRs that weaken it are rejected.
- **Commit messages**: imperative, present tense, ≤ 72 chars first line. e.g. `Add FTS5 snippet highlighting to search results`.

### Good first issues

Five self-contained tasks for new contributors:

1. **Add a language file** — Portuguese, Italian, Russian, or Japanese. Follow [Adding a language](#adding-a-language). ~40 lines.
2. **Translate missing UI strings** — audit `lang/tr.php` against `lang/en.php` and close the gap. Check for hardcoded strings in `views/*.php`.
3. **Theme preview thumbnails** — the settings page shows a `<select>` today. Add small swatch previews for each theme and accent color using the CSS variables from `app/theme.php`.
4. **ErenDev button variant** — add a compact icon-only variant (`h-10`) for the header, and document its HTML snippet in the `#erendev-oauth--turkish-ui-only` section. Must respect the double gate.
5. **Notification digest email** — the `users.notify_digest` flag is stored but no cron job reads it. Add a `bin/digest.php` that batches unread notifications per user and sends a summary via `mail()`, plus a `cron.d` entry.

Each is a single PR. Mention `good first issue` in the issue title and ping `@liteforum/core` for review.

### Reporting bugs

Open an issue with:

- LiteForum commit (`git rev-parse --short HEAD`)
- PHP version (`php -v`)
- Install command used
- Output of `sudo journalctl -u php*-fpm -u nginx --since "10 min ago"`
- For Cloudflare tunnel installs, output of `sudo journalctl -u liteforum-cloudflared --since "10 min ago"`

For security issues, email `security@liteforum.dev` instead of opening a public issue. We aim to respond within 72 hours.

---

## FAQ

**Is SQLite really enough for a forum?**
For a forum with under a few hundred concurrent readers, yes. WAL gives concurrent reads alongside a single writer, and `busy_timeout=5000` handles brief lock contention during posting. Past a few thousand concurrent readers, revisit.

**Can I use PostgreSQL instead?**
Not today. The code is SQLite-specific (`FTS5`, `PRAGMA` calls). An adapter is on the long-term list but not scheduled.

**Why not Flarum?**
Flarum is great. It's also ~150 MB of `vendor/`, needs Composer, MySQL, and a queue worker. LiteForum is ~12 MB and needs nothing.

**Can I enable ErenDev OAuth on an English forum?**
Not through a setting. The OAuth credentials are only written to `config.php` when `--lang tr` is passed at install time. To get the button on an existing English forum, reinstall with `--lang tr`. This is a deliberate design choice — see [ErenDev OAuth — Turkish UI only](#erendev-oauth--turkish-ui-only).

**Does the UI language switcher let a non-Turkish user see the ErenDev button?**
No. The button is rendered only when **both** the install language is Turkish **and** the current UI language is Turkish. Switching the dropdown to English, French, German, Spanish, or Arabic removes the `<img>` from the served HTML on the next page load.

**What happens if someone hits `/oauth/erendev/callback.php` while on a non-Turkish UI?**
The callback returns `404 Not Found`. The endpoint is guarded by the same double check as the button.

**Do I need a domain?**
Not with `--cloudflared`, which gives a temporary `trycloudflare.com` address that changes on restart. For a permanent address, use `--domain` with either `--cf-token` (Cloudflare tunnel, no certbot) or no tunnel flag (Let's Encrypt).

**Do I need to open ports 80 and 443 with a Cloudflare tunnel?**
No. The tunnel only makes outbound connections to Cloudflare.

**How do I change the site name?**
Log in as admin, go to `/admin.php`. The "Site Settings" card at the top has name and tagline fields. Saving updates the header, page titles, and footer immediately.

**How do I make someone a moderator?**
On `/admin.php` → Users table, enter their user ID in the "bulk role" field, select `moderator`, submit. Moderators can pin, lock, and delete posts. Only admins can delete topics and ban users.

**Is there an API?**
Not yet. The PHP routes are simple enough to call directly if you need something bespoke — see `public/*.php`.

**License?**
MIT. Fork it, ship it, sell it, whatever. A link back is appreciated but not required.

---

## License

MIT License

Copyright (c) 2026 LiteForum contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

**Demo:** https://demo.erendev.xyz · **Install:** https://get.erendev.xyz/install.sh · **OAuth docs:** https://oauth2.erendev.xyz
