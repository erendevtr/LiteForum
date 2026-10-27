```markdown
<div align="center">

# LiteForum

**A lightweight, modern, open-source forum — vanilla PHP + SQLite (WAL) + Nginx + PHP-FPM + Tailwind.**

Runs comfortably on the cheapest $3 VPS. No framework. No Composer. No Docker required.
One command and it's live.

[![Live demo](https://img.shields.io/badge/live_demo-demo.erendev.xyz-6366f1?style=flat-square)](https://demo.erendev.xyz)
[![Install](https://img.shields.io/badge/install-get.erendev.xyz%2Finstall.sh-4f46e5?style=flat-square)](https://get.erendev.xyz/install.sh)
[![License](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)](LICENSE)
[![PHP](https://img.shields.io/badge/php-8.2%2B-777bb4?style=flat-square)](https://www.php.net/)
[![SQLite](https://img.shields.io/badge/sqlite-3.35%2B-003b57?style=flat-square)](https://sqlite.org/)

[Demo](https://demo.erendev.xyz) · [Install](#quick-start) · [Features](#features) · [ErenDev OAuth](#erendev-oauth--language-locked-by-design) · [Roadmap](#roadmap)

</div>

---

## Why LiteForum?

Most self-hosted forums were designed for a world where RAM was free and a `composer install` was a normal step. LiteForum takes the opposite road:

- **512 MB RAM VPS, zero swap.** PHP-FPM `ondemand` pool, OPcache preloaded, no long-running workers. The default install idles under 40 MB RSS.
- **Vanilla PHP 8.2, no framework.** Every file is readable top-to-bottom. `grep` is your documentation. No `vendor/` folder to audit.
- **SQLite in WAL mode.** `journal_mode=WAL`, `busy_timeout=5000`, `synchronous=NORMAL`, `foreign_keys=ON`. Handles concurrent reads and single-writer workloads without the Postgres tax.
- **One-command install.** `curl | bash` provisions Nginx, PHP-FPM, TLS, UFW, Fail2ban, backups, and a hardened sysctl profile — no Docker, no Kubernetes, no YAML.
- **Truly bilingual, out of the box.** Turkish and English, with a UI language switcher in the header. i18n is a flat PHP array per language — adding a third language is a 40-line file (see [Adding a language](#adding-a-language)).
- **Sane defaults, not a config dump.** Secure session cookies, CSRF, Argon2id, CSP, HSTS, rate-limit zones, Argon2id-hashed admin, encrypted off-box-ready backups — all pre-wired.

LiteForum is not trying to be Flarum. It's trying to be **the forum you can audit in an afternoon, deploy in a minute, and forget about for a year.**

---

## Screenshots

> Dark theme, indigo accents, glass panels, dotted background — matches the ErenDev documentation site look and feel.

| Home | Login (TR install) | Login (EN install) |
|:---:|:---:|:---:|
| ![Home](docs/screenshots/home.png) | ![Login TR](docs/screenshots/login-tr.png) | ![Login EN](docs/screenshots/login-en.png) |
| Category list, glass card | ErenDev button visible | ErenDev button **absent** |

| Topic view | New topic | Admin |
|:---:|:---:|:---:|
| ![Topic](docs/screenshots/topic.png) | ![New topic](docs/screenshots/new-topic.png) | ![Admin](docs/screenshots/admin.png) |

> Placeholder paths — replace `docs/screenshots/*.png` with real captures using `bg-slate-950`, `indigo-500/600` accents, and `bg-slate-900/60 backdrop-blur border border-slate-800 rounded-2xl shadow-2xl` panels.

---

## Live demo

**[https://demo.erendev.xyz](https://demo.erendev.xyz)**

- Reset nightly at 03:00 UTC.
- The demo is installed with `--lang tr`, so the ErenDev OAuth button **is** rendered there. That's the point.
- Admin demo account: `admin@demo.erendev.xyz` / `demo-admin-2026` (rotated weekly).

---

## ErenDev OAuth — language-locked by design

LiteForum integrates with the [ErenDev Identity Provider](https://oauth2.erendev.xyz) via OAuth2 Authorization Code flow. **The button's visibility is not a setting. It is decided once, at install time, by the installation language.**

> **ErenDev OAuth login is only available when the forum is installed with Turkish as the default language. If installed in English, the ErenDev login button is completely hidden across the entire forum.**

### The rule

| Install language (`--lang`) | Login screen | Register screen | Anywhere a login is required | OAuth callback endpoint |
|---|---|---|---|---|
| **`tr`** (Turkish) | ✅ Button shown | ✅ Button shown | ✅ Button shown | ✅ Active |
| **`en`** (English) | ❌ Never rendered | ❌ Never rendered | ❌ Never rendered | ❌ `404 Not Found` |

### Why "hidden" means *not emitted*

On an English install, the ErenDev button **is not present in the served HTML at all.** It is not hidden with `display: none`, not removed by JavaScript, and not stripped by CSS.

```bash
# On an EN install, this returns nothing:
curl -s https://forum.example.com/login.php | grep -i erendev
```

The button markup lives inside a server-side conditional that is evaluated before a single byte of HTML is produced:

```php
<?php if (($config['default_lang'] ?? '') === 'tr'): ?>
  <a href="<?= e($oauth_url) ?>">
    <img src="https://oauth2.erendev.xyz/erendev-login-button.svg"
         alt="ErenDev ile Giriş Yap" class="h-12">
  </a>
<?php endif; ?>
```

The OAuth callback endpoint is guarded with the same check:

```php
// public/oauth/erendev/callback.php
if (($config['default_lang'] ?? '') !== 'tr') {
    http_response_code(404);
    exit('Not found.');
}
```

Even the OAuth client_id / client_secret are physically absent from an EN install's `config.php`, so a leaked secret can't be abused to re-enable it.

### Does the UI language switcher affect it?

**No.** LiteForum ships with a user-facing TR/EN switcher in the header. It changes UI strings only. **ErenDev OAuth visibility is bound to the *install* language**, which is written into `config.php` at install time and cannot be changed from the UI.

| Install lang | User switches UI → TR | User switches UI → EN |
|:---:|:---:|:---:|
| `tr` | Button shown | Button **still shown** |
| `en` | Button **still absent** | Button absent |

If you want ErenDev OAuth, reinstall with `--lang tr`. That's the only way.

### Adding the button to your own site

The official SVG is public. If you are building something else and want the same button:

```html
<a href="https://oauth2.erendev.xyz/oauth/authorize?client_id=YOUR_CLIENT_ID&redirect_uri=YOUR_CALLBACK&response_type=code&scope=profile%20email&state=RANDOM">
  <img src="https://oauth2.erendev.xyz/erendev-login-button.svg"
       alt="ErenDev ile Giriş Yap" class="h-12">
</a>
```

Full OAuth2 + PKCE + OIDC documentation: [oauth2.erendev.xyz/developer/docs](https://oauth2.erendev.xyz/developer/docs).

---

## Features

### Core
- **Categories → Topics → Posts** hierarchy with FTS5 full-text search across post bodies.
- **User registration and login** — Argon2id password hashing, secure session regeneration on login, `SameSite=Strict` cookies.
- **Role management** — `member`, `moderator`, `admin`. Admin panel at `/admin.php`.
- **Pagination** — cursor-based for topics, offset-based for admin listings.
- **Spam protection** — per-IP rate limits on login (10/min), registration (5/hr), and posting (6/min), plus a honeypot field on the register form. Nginx `limit_req` provides a second layer.

### Security defaults (all on, no config needed)
- **CSRF tokens** on every state-changing form, verified with `hash_equals`.
- **Content-Security-Policy** — no `unsafe-inline` for scripts, `frame-ancestors 'none'`, `form-action` allow-lists ErenDev's OAuth domain on TR installs only.
- **Strict-Transport-Security** with `includeSubDomains; preload`.
- **Session hardening** — `httponly`, `secure`, `SameSite=Strict`, `use_strict_mode`, `sid_length=48`.
- **PHP-FPM sandboxing** — `open_basedir`, `disable_functions` (no `exec`, `shell_exec`, `system`), `display_errors=off`, `expose_php=off`.
- **Kernel hardening** — `dmesg_restrict`, `kptr_restrict=2`, `ptrace_scope=2`, `unprivileged_bpf_disabled=1`, protected hardlinks/symlinks/fifos.
- **Fail2ban jails** for sshd, nginx-http-auth, and nginx-req-limit.
- **Daily encrypted backups** (AES-256-CBC via `openssl enc -pbkdf2`) with 14-day retention and WAL checkpoint at 03:30 UTC.

### Installer
- **Single command.** Provisions everything from a blank Ubuntu 22.04/24.04 or Debian 12 host.
- **Idempotent on re-run** for the SQLite step — existing databases are never touched.
- **`--dry-run`** prints the full plan without making changes.
- **`--skip-tls`** for offline/air-gapped setups.
- **`--no-firewall`** if you manage the firewall externally.
- **Auto-generated credentials** written to `/root/liteforum-credentials.txt` at `0600`.

### Look and feel
- Dark theme (`bg-slate-950`), indigo accents (`indigo-500/600`, `text-indigo-400`), glass panels (`bg-slate-900/60 backdrop-blur border border-slate-800 rounded-2xl shadow-2xl`), blurred indigo glow (`bg-indigo-600/20 blur-[120px]`), radial-gradient dot pattern — the same visual language as the ErenDev documentation site.
- Tailwind build output is committed; no Node runtime on the server.

---

## Quick start

### Requirements

- Ubuntu 22.04 / 24.04 or Debian 12 (x86_64 or arm64)
- A domain pointing at the server's public IP (needed for Let's Encrypt)
- 512 MB RAM minimum, 1 GB recommended
- Root access (the installer manages Nginx, PHP-FPM, UFW, Fail2ban, sysctl)

### Three steps

**1. Install — Turkish forum (ErenDev OAuth button visible):**

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --email  you@example.com \
  --admin  admin@example.com \
  --lang   tr
```

**1b. Install — English forum (ErenDev OAuth button never rendered):**

```bash
curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
  --domain forum.example.com \
  --email  you@example.com \
  --admin  admin@example.com \
  --lang   en
```

**2. Grab your admin credentials:**

```bash
sudo cat /root/liteforum-credentials.txt
```

**3. Open the site:**

```
https://forum.example.com
```

TLS is provisioned by Let's Encrypt. The cert auto-renews via `certbot.timer`.

### Installer flags

| Flag | Default | Description |
|---|---|---|
| `--domain <fqdn>` | *required* | Domain for the site and TLS cert |
| `--email <mail>` | `admin@<domain>` | Let's Encrypt contact + admin email |
| `--admin <mail>` | `admin@<domain>` | Admin account email |
| `--lang <tr\|en>` | `tr` | Install language — controls ErenDev OAuth visibility |
| `--skip-tls` | off | HTTP only; HSTS disabled |
| `--no-firewall` | off | Skip UFW setup |
| `--dry-run` | off | Print plan, make no changes |

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
/root/liteforum-credentials.txt  # 0600 admin + OAuth creds
```

### Upgrading

```bash
cd /var/www/liteforum
sudo -u liteforum git pull
sudo sqlite3 /var/lib/liteforum/liteforum.db < migrations/$(ls migrations | tail -1)
sudo systemctl reload php*-fpm nginx
```

The installer prints the exact PHP version it selected during initial install — look for `PHP version selected:` in `/var/log/liteforum-install.log`.

### Uninstall

```bash
sudo systemctl disable --now nginx php*-fpm fail2ban
sudo rm -f /etc/nginx/sites-enabled/liteforum
sudo rm -rf /var/www/liteforum /var/lib/liteforum /var/log/liteforum /etc/liteforum
sudo rm -f /root/liteforum-credentials.txt
```

---

## Technology stack

| Layer | Choice | Why |
|---|---|---|
| Web server | **Nginx** (TLS 1.2/1.3, HTTP/2, `limit_req` zones) | Fast, small, well-understood |
| PHP runtime | **PHP 8.2+ FPM**, `ondemand` pool, OPcache preloaded | No workers unless traffic needs them |
| Framework | **None — vanilla PHP** | Auditable; no `vendor/` |
| Database | **SQLite 3.35+**, WAL mode, `busy_timeout=5000` | Single-file, zero ops |
| Full-text search | **FTS5** virtual table (trigger-maintained) | Built into SQLite |
| Styling | **Tailwind CSS**, prebuilt and committed | No Node on the server |
| Sessions | PHP native, file-backed, `SameSite=Strict` | Secure by default |
| Auth (email) | **Argon2id** via `password_hash` | Modern KDF |
| Auth (OAuth) | **OAuth2 Authorization Code** (ErenDev IdP) | Optional, TR-only |
| TLS | **Let's Encrypt** via Certbot, auto-renew | Free, automatic |
| Firewall | **UFW** + **Fail2ban** | Belt and suspenders |
| Backups | **sqlite3 checkpoint** + `tar` + `openssl enc` | Portable, encrypted |

Rough footprint on a fresh install with 3 categories, 10 topics, 100 posts: **~12 MB on disk**, **~38 MB RSS idle**. Yes, really.

---

## Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │                 Nginx (443)                 │
                         │  TLS 1.3 · HSTS · CSP · limit_req zones     │
                         └──────────────────┬──────────────────────────┘
                                            │ unix socket
                         ┌──────────────────▼──────────────────────────┐
                         │         PHP-FPM (ondemand pool)             │
                         │  open_basedir · disable_functions · OPcache │
                         └──────────────────┬──────────────────────────┘
                                            │
         ┌──────────────────────────────────┼──────────────────────────────────┐
         │                                  │                                  │
 ┌───────▼────────┐               ┌─────────▼─────────┐              ┌─────────▼─────────┐
 │  public/*.php  │               │      app/*.php    │              │    views/*.php    │
 │  (routes)      │ ─────────────►│  (bootstrap, db,  │─────────────►│  (layout, forms)  │
 │                │               │   auth, csrf,     │              │                   │
 │                │               │   i18n, helpers)  │              │                   │
 └───────┬────────┘               └─────────┬─────────┘              └───────────────────┘
         │                                  │
         │                                  │ PDO
         │                       ┌──────────▼──────────┐
         │                       │  SQLite (WAL)       │
         │                       │  liteforum.db       │
         │                       │  + FTS5 index       │
         │                       └─────────────────────┘
         │
         │ HTTP (only when default_lang === 'tr')
         │
 ┌───────▼─────────────────────────────────────────────────────────────────────┐
 │                    ErenDev Identity Provider (OAuth2)                       │
 │   authorize → token → userinfo → local session                              │
 │   Note: unreachable on EN installs — OAuth code path does not exist.        │
 └─────────────────────────────────────────────────────────────────────────────┘
```

---

## Bilingual UI

### Files

```
lang/
├── tr.php   # Turkish strings
└── en.php   # English strings
```

Each file returns a flat `[key => string]` array. Missing keys fall back to the key name itself.

```php
// lang/tr.php
<?php return [
  'forum'      => 'Forum',
  'login'      => 'Giriş Yap',
  'erendev_login' => 'ErenDev ile Giriş Yap',
  // ...
];
```

Usage in views:

```php
<?= e(t('login')) ?>
```

### The UI language switcher

A `<select>` in the header submits to `POST /lang.php`, which stores `$_SESSION['ui_lang']` and reinitializes i18n. It changes UI strings only — **never** ErenDev button visibility. See [ErenDev OAuth — language-locked by design](#erendev-oauth--language-locked-by-design).

### Adding a language

1. Copy `lang/en.php` to `lang/de.php` and translate the values.
2. Add the code to the whitelist in `app/i18n.php`:
   ```php
   $code = in_array($code, ['tr', 'en', 'de'], true) ? $code : 'en';
   ```
3. Add an `<option value="de">` to the switcher in `views/layout.php`.
4. Add the code to the whitelist in `public/lang.php`.
5. For categories, seed `name_de` (or leave blank to fall back to `name_en`).

That's it. No build step, no compile, no cache purge.

---

## Contributing

Contributions are welcome. LiteForum's small codebase makes it a good first project for anyone who's been meaning to contribute to OSS.

### Getting set up

```bash
git clone https://github.com/liteforum/liteforum.git
cd liteforum

# Local dev — no TLS, no firewall, ports 8080
sudo bash install.sh --dry-run --domain localhost --lang tr

# Or manually: PHP 8.2+ and SQLite are enough
php -S 127.0.0.1:8080 -t public
```

### Guidelines

- **Keep it vanilla.** No Composer packages, no PHP frameworks, no Node on the runtime path. If you need a helper, write 20 lines of PHP.
- **Every state-changing form needs `csrf_field()` and `csrf_verify()`.** PRs missing CSRF will be closed without review.
- **Escape output with `e()`.** No exceptions.
- **New SQL goes through PDO prepared statements.** No string interpolation.
- **Language files are append-only per key.** Don't rename existing keys — the fallback chain will break for partial translations.
- **Commit messages**: imperative mood, present tense, ≤ 72 chars on the first line. e.g. `Add FTS5 snippet highlighting to search results`.
- **Tests**: not required for cosmetic PRs, but new logic in `app/` should come with a small `tests/` script that can be run with `php tests/run.php`.

### Good first issues

If you want to help but aren't sure where to start, here are five self-contained tasks:

1. **Add a language file** — `lang/fr.php`, `lang/de.php`, `lang/es.php`, `lang/ar.php` (RTL is a bonus). Follow [Adding a language](#adding-a-language). ~40 lines.
2. **Translate missing UI strings** — audit `lang/tr.php` against `lang/en.php` and close the gap. Check for hardcoded strings in `views/*.php` while you're in there.
3. **Add a dark/light theme toggle** — the CSS is already in `views/layout.php`; wire a `data-theme` attribute to a Tailwind-compatible light palette and a `POST /theme.php` endpoint. Persist in `$_SESSION['theme']`.
4. **ErenDev button variant** — the SVG lives at `https://oauth2.erendev.xyz/erendev-login-button.svg`. Add a compact variant (icon-only, `h-10`) for the header, and document its HTML snippet in the `#button` section of the README. Must still respect the `default_lang === 'tr'` gate.
5. **Spam protection: time-based form check** — reject registration if the form is submitted in under 2 seconds (measure via a signed `form_ts` field). Add the check to `public/register.php`, the corresponding hidden input to `views/register.php`, and a test in `tests/`.

Each of these is a single PR. Mention `good first issue` in the issue title and ping `@liteforum/core` for a review within 48 hours.

### Reporting bugs

Open an issue with:
- LiteForum version (`git rev-parse --short HEAD`)
- PHP version (`php -v`)
- Install command used
- Output of `sudo journalctl -u php*-fpm -u nginx --since "10 min ago"`

For security issues, **do not open a public issue.** Email `security@liteforum.dev` with a description and reproduction steps. We aim to respond within 72 hours.

---

## Roadmap

### v1.0 — shipped
- [x] Category → topic → post core
- [x] Registration, login, logout (email + Argon2id)
- [x] Role management (member / moderator / admin)
- [x] FTS5 full-text search
- [x] Pagination
- [x] Spam protection (rate limits + honeypot)
- [x] Turkish and English UI, install-time language selection
- [x] **ErenDev OAuth — visible on TR installs, never rendered on EN installs**
- [x] One-command installer (Nginx, PHP-FPM, TLS, UFW, Fail2ban, backups, sysctl hardening)
- [x] Dark glass/indigo theme matching the ErenDev documentation site

### v1.1 — planned
- [ ] **In-app notifications** — mention detection, reply-watch, batched digest email
- [ ] **Search improvements** — snippet highlighting, category filter, FTS5 `bm25()` ranking, author filter
- [ ] **Theme options** — light mode, high-contrast mode, per-user accent color
- [ ] **More languages** — French, German, Spanish, Arabic (RTL)
- [ ] **Better admin UI** — bulk user actions, audit log viewer, category reordering

### v2.0 — exploring
- [ ] **Plugin system** — event-based hooks (`forum.post.before_save`, `forum.user.after_login`, etc.) loaded from `plugins/` without touching core files. Sandbox constraints TBD.
- [ ] **Optional MySQL/Postgres adapter** — for installs that outgrow SQLite. Default remains SQLite.
- [ ] **Email verification + password reset** — opt-in, requires SMTP config
- [ ] **Webhooks + RSS feeds** — per-category and per-topic
- [ ] **Official Docker image** — for those who really want it. Vanilla installer remains the primary path.

Vote on roadmap items in [Discussions](https://github.com/liteforum/liteforum/discussions).

---

## FAQ

**Is SQLite really enough for a forum?**
For a forum with under a few hundred concurrent readers, yes — comfortably. WAL gives you concurrent reads alongside a single writer, and `busy_timeout=5000` handles the brief lock contention you'll see during posting. Past a few thousand concurrent readers, revisit.

**Can I use PostgreSQL instead?**
Not yet — v2.0 is exploring an adapter. Today's code is SQLite-specific (FTS5, `PRAGMA` calls).

**Why not Flarum?**
Flarum is great. It's also ~150 MB of `vendor/`, needs Composer, MySQL, and a queue worker. LiteForum is ~12 MB and needs nothing.

**Can I enable ErenDev OAuth on an English forum?**
Not through a setting. The OAuth client credentials are only written to `config.php` when `--lang tr` is passed at install time. To get the button on an existing English forum, reinstall with `--lang tr`. This is a deliberate design choice — see [ErenDev OAuth — language-locked by design](#erendev-oauth--language-locked-by-design).

**Does the UI language switcher let an English user see the ErenDev button?**
No. The switcher changes strings only. ErenDev button visibility is bound to `default_lang` in `config.php`, which is written once at install time and cannot be changed from the UI.

**How do I back up?**
The installer sets up a daily `cron.d` job at 03:45 UTC that checkpoints the WAL and pipes `tar czf - /var/lib/liteforum` through `openssl enc -aes-256-cbc -pbkdf2`. Backups go to `/var/lib/liteforum/backups/` and roll off after 14 days. The passphrase is at `/etc/liteforum/backup.pass` (0600).

**How do I restore?**
```bash
openssl enc -d -aes-256-cbc -pbkdf2 -in /var/lib/liteforum/backups/lf-YYYY-MM-DD.tar.gz.enc \
  -pass file:/etc/liteforum/backup.pass | sudo tar xzf - -C /
sudo chown -R liteforum:liteforum /var/lib/liteforum
sudo systemctl reload php*-fpm nginx
```

**Is there an API?**
Not yet. The PHP routes are simple enough to call directly if you need something bespoke — see `public/*.php`.

**License?**
MIT. Fork it, ship it, sell it, whatever. A link back is appreciated but not required.

---

## License

```
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
```

---

<div align="center">

**[⬆ back to top](#liteforum)**

Made with vanilla PHP, one SQLite file, and a strong opinion about `composer install`.

[demo.erendev.xyz](https://demo.erendev.xyz) · [get.erendev.xyz/install.sh](https://get.erendev.xyz/install.sh) · [oauth2.erendev.xyz](https://oauth2.erendev.xyz)

</div>
```
