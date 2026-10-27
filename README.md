# LiteForum

A lightweight, modern, open-source forum — vanilla PHP + SQLite (WAL) + Nginx + PHP-FPM + Tailwind.

Runs comfortably on the cheapest $3 VPS. No framework. No Composer. No Docker required. One command and it's live.

[Live demo](https://demo.erendev.xyz) · [Install](#quick-start) · [Features](#features) · [ErenDev OAuth](#erendev-oauth--turkish-only) · [Contributing](#contributing)

![license](https://img.shields.io/badge/license-MIT-22c55e)
![php](https://img.shields.io/badge/php-8.2%2B-777bb4)
![sqlite](https://img.shields.io/badge/sqlite-3.35%2B-003b57)

---

## Why LiteForum?

Most self-hosted forums were designed for a world where RAM was free and `composer install` was a normal step. LiteForum takes the opposite road:

- **512 MB RAM VPS, zero swap.** PHP-FPM `ondemand` pool, OPcache preloaded, no long-running workers. The default install idles under 40 MB RSS.
- **Vanilla PHP 8.2, no framework.** Every file is readable top-to-bottom. `grep` is your documentation. No `vendor/` folder to audit.
- **SQLite in WAL mode.** `journal_mode=WAL`, `busy_timeout=5000`, `synchronous=NORMAL`, `foreign_keys=ON`. Handles concurrent reads and single-writer workloads without the Postgres tax.
- **One-command install.** `curl | bash` provisions Nginx, PHP-FPM, TLS, UFW, Fail2ban, backups, and a hardened sysctl profile — no Docker, no Kubernetes, no YAML.
- **Multilingual by design.** Turkish, English, French, German, Spanish, and Arabic (RTL), with a UI language switcher. i18n is a flat PHP array per language — adding a seventh language is a 40-line file.
- **Sane defaults, not a config dump.** Secure session cookies, CSRF, Argon2id, CSP, HSTS, rate-limit zones, encrypted backups — all pre-wired.

LiteForum is not trying to be Flarum. It's trying to be **the forum you can audit in an afternoon, deploy in a minute, and forget about for a year.**

---

## Screenshots

Dark theme, indigo accents, glass panels, dotted background — the same visual language as the ErenDev documentation site.

| Home | Login (Turkish UI) | Login (any other UI language) |
|:---:|:---:|:---:|
| ![Home](docs/screenshots/home.png) | ![Login TR](docs/screenshots/login-tr.png) | ![Login EN](docs/screenshots/login-en.png) |
| Category list, glass card | ErenDev button visible | ErenDev button **absent** |

| Topic view | New topic | Admin |
|:---:|:---:|:---:|
| ![Topic](docs/screenshots/topic.png) | ![New topic](docs/screenshots/new-topic.png) | ![Admin](docs/screenshots/admin.png) |

> Placeholder paths — replace `docs/screenshots/*.png` with real captures using `bg-slate-950`, `indigo-500/600` accents, and `bg-slate-900/60 backdrop-blur border border-slate-800 rounded-2xl shadow-2xl` panels.

---

## Live demo

**https://demo.erendev.xyz**

- Reset nightly at 03:00 UTC.
- Installed with `--lang tr`, so the ErenDev OAuth button **is** rendered there while the UI is Turkish. Switch the language dropdown to English and it disappears instantly — that's the point.
- Admin demo account: `admin@demo.erendev.xyz` / `demo-admin-2026` (rotated weekly).

---

## ErenDev OAuth — Turkish only

LiteForum integrates with the [ErenDev Identity Provider](https://oauth2.erendev.xyz) via the OAuth2 Authorization Code flow. **The button is visible only in the Turkish UI, and only on forums installed with Turkish as the default language. Every other language — including English — hides it completely.**

> **The ErenDev login button is rendered only when BOTH conditions hold:**
>
> 1. The forum was installed with `--lang tr` (OAuth credentials exist in `config.php`).
> 2. The visitor's current UI language is Turkish.
>
> **If either condition fails — including the case where the forum was installed in Turkish but the visitor switched the UI to English, French, German, Spanish, or Arabic — the button is not present in the served HTML at all.** It is not hidden with `display: none`, not removed by JavaScript, and not stripped by CSS. The `<img>` tag is simply never written to the response.

### The rule

| Install language | Current UI language | ErenDev button | OAuth callback endpoint |
|:---:|:---:|:---:|:---:|
| `tr` | `tr` | ✅ **Shown** | ✅ Active |
| `tr` | `en` | ❌ Not emitted | ❌ `404 Not Found` |
| `tr` | `fr` / `de` / `es` / `ar` | ❌ Not emitted | ❌ `404 Not Found` |
| `en` | any | ❌ Not emitted | ❌ `404 Not Found` |
| `fr` / `de` / `es` / `ar` | any | ❌ Not emitted | ❌ `404 Not Found` |

### Why "hidden" means *not emitted*

On any non-Turkish view, the ErenDev button **is not present in the served HTML at all.** Verify with:

```bash
# On a Turkish UI, this returns the button:
curl -s https://forum.example.com/login.php -b "LF_SESSION=<tr-session>" | grep -i erendev

# On any other UI language, this returns nothing:
curl -s https://forum.example.com/login.php -b "LF_SESSION=<en-session>" | grep -i erendev
