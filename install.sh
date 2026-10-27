#!/usr/bin/env bash
# =============================================================================
# LiteForum — Ultra-Secure One-Shot Installer
# Single-command usage:
#   curl -fsSL https:/get.erendev.xyz/install.sh | sudo bash -s -- \
#        --domain forum.example.com --email you@example.com --lang tr --admin admin@example.com
# =============================================================================
set -Eeuo pipefail
umask 027

# ------------------------------- Arguments -----------------------------------
DOMAIN=""
ADMIN_EMAIL=""
EMAIL=""
LANG_CODE="tr"           # tr | en  (ErenDev OAuth is ONLY shown when tr)
DRY_RUN=0
SKIP_TLS=0
NO_FIREWALL=0
APP_DIR="/var/www/liteforum"
DATA_DIR="/var/lib/liteforum"
LOG_DIR="/var/log/liteforum"
SVC_USER="liteforum"
PHP_VER=""
INSTALL_LOG="/var/log/liteforum-install.log"

log()   { printf "\e[36m[%s]\e[0m %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$INSTALL_LOG"; }
ok()    { printf "\e[32m[OK]\e[0m  %s\n" "$*" | tee -a "$INSTALL_LOG"; }
warn()  { printf "\e[33m[WARN]\e[0m %s\n" "$*" | tee -a "$INSTALL_LOG"; }
die()   { printf "\e[31m[FATAL]\e[0m %s\n" "$*" | tee -a "$INSTALL_LOG"; exit 1; }

usage() {
  cat <<EOT
LiteForum Installer
  --domain <fqdn>       Domain (TLS is provisioned automatically via Let's Encrypt)
  --email <mail>        Contact email for Let's Encrypt + admin
  --admin <mail>        Admin account email (password is auto-generated)
  --lang <tr|en>        Installation language (tr → ErenDev OAuth is shown)
  --skip-tls            Skip TLS (HTTP only, HSTS disabled)
  --no-firewall         Skip UFW setup
  --dry-run             Print the plan only
  -h|--help
EOT
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)      DOMAIN="$2"; shift 2;;
    --email)       EMAIL="$2"; shift 2;;
    --admin)       ADMIN_EMAIL="$2"; shift 2;;
    --lang)        LANG_CODE="$2"; shift 2;;
    --skip-tls)    SKIP_TLS=1; shift;;
    --no-firewall) NO_FIREWALL=1; shift;;
    --dry-run)     DRY_RUN=1; shift;;
    -h|--help)     usage;;
    *) die "Unknown arg: $1";;
  esac
done

[[ "$LANG_CODE" == "tr" || "$LANG_CODE" == "en" ]] || die "--lang must be tr|en"
[[ $EUID -eq 0 ]] || die "root required (use sudo)."
[[ -n "$DOMAIN" ]] || die "--domain is required (needed for TLS)."
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
EMAIL="${EMAIL:-$ADMIN_EMAIL}"

log "LiteForum installer starting — domain=$DOMAIN lang=$LANG_CODE admin=$ADMIN_EMAIL dry-run=$DRY_RUN"
[[ $DRY_RUN -eq 1 ]] && { echo "DRY-RUN: no system changes will be made."; }

# ------------------------------- OS detection --------------------------------
detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  . /etc/os-release
  case "$ID" in
    ubuntu|debian) ;;
    *) die "Only Ubuntu/Debian are supported. Found: $ID";;
  esac
  ARCH="$(dpkg --print-architecture)"
  [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || die "Unsupported architecture: $ARCH"
  ok "OS=$PRETTY_NAME ARCH=$ARCH"
}

# ------------------------------- Packages ------------------------------------
install_packages() {
  log "Installing packages (apt)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get upgrade -y -qq
  # Pick the newest available PHP FPM
  PHP_VER="$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' | sort -V | tail -1 | awk -F- '{print $1}')"
  [[ -n "$PHP_VER" ]] || PHP_VER="php8.2"
  log "PHP version selected: $PHP_VER"
  apt-get install -y -qq --no-install-recommends \
    nginx "$PHP_VER-fpm" "$PHP_VER-cli" "$PHP_VER-sqlite3" "$PHP_VER-curl" \
    "$PHP_VER-mbstring" "$PHP_VER-xml" "$PHP_VER-intl" "$PHP_VER-opcache" \
    "$PHP_VER-bcmath" "$PHP_VER-gd" \
    sqlite3 curl ca-certificates openssl \
    ufw fail2ban unattended-upgrades apt-listchanges \
    certbot python3-certbot-nginx \
    logrotate rsync jq \
    libnginx-mod-http-headers-more-filter \
    libnginx-mod-http-limit-req 2>>"$INSTALL_LOG" || true
  ok "Packages installed"
}

# ------------------------------- Service user --------------------------------
create_user() {
  if ! id "$SVC_USER" &>/dev/null; then
    useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin \
            --user-group "$SVC_USER"
    ok "System user created: $SVC_USER"
  else
    ok "User already exists: $SVC_USER"
  fi
  usermod -aG www-data "$SVC_USER" || true
}

# ------------------------------- Directories ---------------------------------
create_dirs() {
  log "Preparing directories..."
  install -d -o root        -g root        -m 0755 "$APP_DIR"
  install -d -o root        -g root        -m 0755 "$APP_DIR/public"
  install -d -o root        -g root        -m 0755 "$APP_DIR/app"
  install -d -o root        -g root        -m 0755 "$APP_DIR/config"
  install -d -o root        -g root        -m 0755 "$APP_DIR/lang"
  install -d -o root        -g root        -m 0755 "$APP_DIR/views"
  install -d -o $SVC_USER   -g $SVC_USER   -m 0700 "$DATA_DIR"
  install -d -o $SVC_USER   -g $SVC_USER   -m 0700 "$DATA_DIR/sessions"
  install -d -o $SVC_USER   -g $SVC_USER   -m 0700 "$DATA_DIR/tmp"
  install -d -o $SVC_USER   -g $SVC_USER   -m 0700 "$DATA_DIR/backups"
  install -d -o root        -g adm         -m 0750 "$LOG_DIR"
}

# ------------------------------- Secrets -------------------------------------
gen_secrets() {
  log "Generating cryptographic secrets..."
  APP_KEY="$(openssl rand -hex 32)"
  ADMIN_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
  OAuth_CLIENT_ID="ed_app_$(openssl rand -hex 8)"
  OAuth_CLIENT_SECRET="eds_$(openssl rand -hex 24)"
  OAuth_STATE_KEY="$(openssl rand -hex 32)"
  ok "Secrets generated"
}

# ------------------------------- SQLite init ---------------------------------
init_sqlite() {
  log "Initializing SQLite database (WAL, busy_timeout)..."
  DB="$DATA_DIR/liteforum.db"
  [[ -f "$DB" ]] && { warn "DB already exists, leaving it untouched."; return; }
  sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
PRAGMA temp_store=MEMORY;
PRAGMA mmap_size=134217728;
PRAGMA journal_size_limit=67108864;

CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member','moderator','admin')),
  erendev_sub TEXT UNIQUE,
  created_at INTEGER NOT NULL,
  last_login_at INTEGER
);
CREATE TABLE IF NOT EXISTS categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL UNIQUE,
  name_tr TEXT NOT NULL,
  name_en TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS topics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id),
  title TEXT NOT NULL,
  slug TEXT NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  is_locked INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS posts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id),
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_topics_cat ON topics(category_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_topic ON posts(topic_id, created_at ASC);
CREATE TABLE IF NOT EXISTS rate_limits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bucket TEXT NOT NULL,
  ip TEXT NOT NULL,
  ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rate ON rate_limits(bucket, ip, ts);
CREATE TABLE IF NOT EXISTS oauth_states (
  state TEXT PRIMARY KEY,
  code_verifier TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts USING fts5(
  title, body, content='posts', content_rowid='id'
);
CREATE TRIGGER IF NOT EXISTS posts_ai AFTER INSERT ON posts BEGIN
  INSERT INTO posts_fts(rowid,title,body) VALUES (new.id,'',new.body);
END;
CREATE TRIGGER IF NOT EXISTS posts_au AFTER UPDATE ON posts BEGIN
  INSERT INTO posts_fts(posts_fts,rowid,title,body) VALUES('delete',old.id,'',old.body);
  INSERT INTO posts_fts(rowid,title,body) VALUES (new.id,'',new.body);
END;
SQL
  chown "$SVC_USER:$SVC_USER" "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true
  chmod 0600 "$DB" 2>/dev/null || true
  ok "SQLite ready: $DB"
}

# ------------------------------- config.php ----------------------------------
write_env() {
  log "Writing config.php (0600, readable only by the service owner)..."
  ENV="$APP_DIR/config/config.php"
  cat > "$ENV" <<PHP
<?php
return [
    'app_name'          => 'LiteForum',
    'default_lang'      => '$LANG_CODE',   // 'tr' → ErenDev OAuth is rendered; 'en' → never rendered
    'app_key'           => '$APP_KEY',
    'db_path'           => '$DATA_DIR/liteforum.db',
    'base_url'          => 'https://$DOMAIN',
    'session_name'      => 'LF_SESSION',
    'session_lifetime'  => 7200,
    'erendev' => [
        'client_id'     => '$OAuth_CLIENT_ID',
        'client_secret' => '$OAuth_CLIENT_SECRET',
        'authorize_url' => 'https://oauth2.erendev.xyz/oauth/authorize',
        'token_url'     => 'https://oauth2.erendev.xyz/oauth/token',
        'userinfo_url'  => 'https://oauth2.erendev.xyz/oauth/userinfo',
        'redirect_uri'  => 'https://$DOMAIN/oauth/erendev/callback.php',
        'scope'         => 'profile email',
        'button_svg'    => 'https://oauth2.erendev.xyz/erendev-login-button.svg',
    ],
    'rate_limit' => [
        'login_per_10min' => 8,
        'post_per_min'    => 6,
        'register_per_hr' => 5,
    ],
    'admin_email' => '$ADMIN_EMAIL',
];
PHP
  chown "$SVC_USER:$SVC_USER" "$ENV"
  chmod 0640 "$ENV"
  ok "config.php written (0640)"
}

# ------------------------------- i18n ----------------------------------------
write_i18n() {
  log "Writing translation files (tr, en)..."
  cat > "$APP_DIR/lang/tr.php" <<'PHP'
<?php return [
  'forum'              => 'Forum',
  'login'              => 'Giriş Yap',
  'register'           => 'Kayıt Ol',
  'logout'             => 'Çıkış Yap',
  'username'           => 'Kullanıcı adı',
  'email'              => 'E-posta',
  'password'           => 'Şifre',
  'categories'         => 'Kategoriler',
  'topics'             => 'Konular',
  'posts'              => 'Mesajlar',
  'new_topic'          => 'Yeni Konu',
  'reply'              => 'Yanıtla',
  'search'             => 'Ara...',
  'submit'             => 'Gönder',
  'erendev_login'      => 'ErenDev ile Giriş Yap',
  'too_many_attempts'  => 'Çok fazla deneme, lütfen sonra tekrar deneyin.',
  'missing_info'       => 'Eksik bilgi.',
  'bad_credentials'    => 'E-posta veya şifre hatalı.',
  'bot_detected'       => 'Bot tespit edildi.',
  'register_limit'     => 'Bu IP için kayıt limiti aşıldı.',
  'bad_username'       => 'Kullanıcı adı 3–32 karakter olmalı; harf, rakam, _ veya - kullanın.',
  'bad_email'          => 'Geçerli bir e-posta girin.',
  'weak_password'      => 'Şifre en az 10 karakter olmalı.',
  'already_exists'     => 'Bu kullanıcı adı veya e-posta zaten kayıtlı.',
];
PHP
  cat > "$APP_DIR/lang/en.php" <<'PHP'
<?php return [
  'forum'              => 'Forum',
  'login'              => 'Log in',
  'register'           => 'Sign up',
  'logout'             => 'Log out',
  'username'           => 'Username',
  'email'              => 'Email',
  'password'           => 'Password',
  'categories'         => 'Categories',
  'topics'             => 'Topics',
  'posts'              => 'Posts',
  'new_topic'          => 'New topic',
  'reply'              => 'Reply',
  'search'             => 'Search...',
  'submit'             => 'Submit',
  'erendev_login'      => 'Sign in with ErenDev',
  'too_many_attempts'  => 'Too many attempts, please try again later.',
  'missing_info'       => 'Missing information.',
  'bad_credentials'    => 'Incorrect email or password.',
  'bot_detected'       => 'Bot detected.',
  'register_limit'     => 'Registration limit exceeded for this IP.',
  'bad_username'       => 'Username must be 3–32 chars: letters, digits, _ or -.',
  'bad_email'          => 'Please enter a valid email address.',
  'weak_password'      => 'Password must be at least 10 characters.',
  'already_exists'     => 'This username or email is already registered.',
];
PHP
  chown -R root:root "$APP_DIR/lang"
  chmod 0644 "$APP_DIR/lang"/*.php
}

# ------------------------------- Core app ------------------------------------
write_app() {
  log "Writing PHP application (vanilla PHP, no framework)..."
  chown -R root:root "$APP_DIR/app" "$APP_DIR/views"
  chmod 0755 "$APP_DIR/app" "$APP_DIR/views"

  cat > "$APP_DIR/app/bootstrap.php" <<'PHP'
<?php
declare(strict_types=1);
define('LF_ROOT', dirname(__DIR__));
$config = require LF_ROOT . '/config/config.php';
require LF_ROOT . '/app/db.php';
require LF_ROOT . '/app/csrf.php';
require LF_ROOT . '/app/auth.php';
require LF_ROOT . '/app/i18n.php';
require LF_ROOT . '/app/helpers.php';

// Secure session
session_name($config['session_name']);
session_set_cookie_params([
  'lifetime' => 0,
  'path'     => '/',
  'secure'   => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on',
  'httponly' => true,
  'samesite' => 'Strict',
]);
session_start();
i18n_init($config['default_lang'] ?? 'tr');
csrf_init($config['app_key']);
$db = db_init($config['db_path']);
PHP

  cat > "$APP_DIR/app/db.php" <<'PHP'
<?php
declare(strict_types=1);
function db_init(string $path): PDO {
  static $pdo = null;
  if ($pdo) return $pdo;
  $pdo = new PDO('sqlite:' . $path, null, null, [
    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES   => false,
  ]);
  $pdo->exec('PRAGMA journal_mode=WAL;');
  $pdo->exec('PRAGMA busy_timeout=5000;');
  $pdo->exec('PRAGMA synchronous=NORMAL;');
  $pdo->exec('PRAGMA foreign_keys=ON;');
  $pdo->exec('PRAGMA temp_store=MEMORY;');
  return $pdo;
}
PHP

  cat > "$APP_DIR/app/helpers.php" <<'PHP'
<?php
declare(strict_types=1);
function e(?string $s): string { return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function csp_nonce(): string {
  static $n = null;
  if ($n === null) $n = base64_encode(random_bytes(16));
  return $n;
}
function redirect(string $to): never { header('Location: ' . $to, true, 302); exit; }
function rate_limit(PDO $db, string $bucket, string $ip, int $max, int $windowSec): bool {
  $now = time();
  $db->prepare('DELETE FROM rate_limits WHERE ts < ?')->execute([$now - $windowSec]);
  $st = $db->prepare('SELECT COUNT(*) FROM rate_limits WHERE bucket=? AND ip=? AND ts>=?');
  $st->execute([$bucket, $ip, $now - $windowSec]);
  if ((int)$st->fetchColumn() >= $max) return false;
  $db->prepare('INSERT INTO rate_limits(bucket,ip,ts) VALUES(?,?,?)')->execute([$bucket, $ip, $now]);
  return true;
}
function client_ip(): string {
  return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
}
PHP

  cat > "$APP_DIR/app/csrf.php" <<'PHP'
<?php
declare(strict_types=1);
function csrf_init(string $key): void {
  if (empty($_SESSION['csrf_token'])) $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
  if (empty($_SESSION['csrf_key']))   $_SESSION['csrf_key']   = $key;
}
function csrf_token(): string { return $_SESSION['csrf_token']; }
function csrf_field(): string {
  return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">';
}
function csrf_verify(): void {
  $t = $_POST['_csrf'] ?? '';
  if (!is_string($t) || !hash_equals($_SESSION['csrf_token'] ?? '', $t)) {
    http_response_code(419); exit('Invalid CSRF token.');
  }
}
PHP

  cat > "$APP_DIR/app/auth.php" <<'PHP'
<?php
declare(strict_types=1);
function auth_user(): ?array {
  return $_SESSION['user'] ?? null;
}
function auth_require(): array {
  $u = auth_user();
  if (!$u) redirect('/login.php');
  return $u;
}
function auth_login(array $user): void {
  session_regenerate_id(true);
  $_SESSION['user'] = [
    'id' => (int)$user['id'],
    'username' => $user['username'],
    'role' => $user['role'],
  ];
  $GLOBALS['db']->prepare('UPDATE users SET last_login_at=? WHERE id=?')
                ->execute([time(), (int)$user['id']]);
}
function auth_logout(): void {
  $_SESSION = [];
  if (ini_get('session.use_cookies')) {
    $p = session_get_cookie_params();
    setcookie(session_name(), '', time()-42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
  }
  session_destroy();
}
function password_hash_safe(string $p): string {
  return password_hash($p, PASSWORD_ARGON2ID);
}
function password_verify_safe(string $p, string $h): bool {
  return password_verify($p, $h);
}
PHP

  cat > "$APP_DIR/app/i18n.php" <<'PHP'
<?php
declare(strict_types=1);
$GLOBALS['__lang'] = [];
function i18n_init(string $code): void {
  $code = in_array($code, ['tr','en'], true) ? $code : 'en';
  $path = LF_ROOT . '/lang/' . $code . '.php';
  $GLOBALS['__lang'] = is_file($path) ? require $path : [];
}
function t(string $key): string {
  return $GLOBALS['__lang'][$key] ?? $key;
}
PHP
  chown -R root:root "$APP_DIR/app"
  chmod -R 0755 "$APP_DIR/app"
}

# ------------------------------- Views ---------------------------------------
write_views() {
  log "Writing views..."

  cat > "$APP_DIR/views/layout.php" <<'PHP'
<?php /* @var string $content @var string $title */ ?>
<!doctype html>
<html lang="<?= e($GLOBALS['__lang_code'] ?? 'tr') ?>" class="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<title><?= e($title ?? 'LiteForum') ?> · LiteForum</title>
<style nonce="<?= e(csp_nonce()) ?>">
  :root { color-scheme: dark; }
  body { background:#020617; color:#cbd5e1; font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; margin:0; }
  .bg-pattern { background-image: radial-gradient(#1e293b 1px, transparent 1px); background-size: 32px 32px; }
  .glass { background: rgba(15,23,42,.6); backdrop-filter: blur(8px); border:1px solid #1e293b; border-radius: 1rem; box-shadow: 0 25px 50px -12px rgba(0,0,0,.6); }
  .glow { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }
  .glow::before { content:""; position:absolute; top:-120px; left:50%; transform:translateX(-50%); width:800px; height:400px; background: rgba(79,70,229,.2); filter: blur(120px); border-radius: 999px; }
  a { color:#818cf8; text-decoration:none; } a:hover { text-decoration:underline; }
  .container { max-width: 1100px; margin: 0 auto; padding: 2rem 1.25rem; position: relative; z-index: 1; }
  header.nav { position: sticky; top:0; z-index:10; border-bottom:1px solid rgba(30,41,59,.8); background: rgba(2,6,23,.8); backdrop-filter: blur(8px); }
  header.nav .inner { max-width:1100px; margin:0 auto; padding: 1rem 1.25rem; display:flex; justify-content:space-between; align-items:center; }
  .logo { display:flex; gap:.5rem; align-items:center; color:#fff; font-weight:600; }
  .logo .mark { width:32px; height:32px; border-radius:.5rem; background:#6366f1; display:flex; align-items:center; justify-content:center; font-weight:700; }
  input, textarea, select { background:#0f172a; color:#e2e8f0; border:1px solid #1e293b; border-radius:.5rem; padding:.55rem .75rem; width:100%; box-sizing:border-box; font:inherit; }
  button, .btn { background:#6366f1; color:#fff; border:0; border-radius:.5rem; padding:.6rem 1rem; cursor:pointer; font-weight:600; }
  button:hover, .btn:hover { background:#4f46e5; text-decoration:none; }
  .btn-ghost { background:transparent; border:1px solid #334155; color:#cbd5e1; }
  .muted { color:#94a3b8; }
  .card { padding: 1.5rem; }
  .flex { display:flex; gap:.75rem; align-items:center; }
  .grid { display:grid; gap:1rem; }
  table { width:100%; border-collapse: collapse; }
  th, td { text-align:left; padding:.75rem 1rem; border-bottom:1px solid #1e293b; }
  code { background:#0f172a; padding:1px 6px; border-radius:4px; color:#a5b4fc; font-size: .9em; }
</style>
</head>
<body class="bg-pattern" style="position:relative; min-height:100vh;">
<div class="glow"></div>
<header class="nav">
  <div class="inner">
    <a class="logo" href="/"><span class="mark">L</span><span>LiteForum</span></a>
    <nav class="flex">
      <?php if ($u = auth_user()): ?>
        <span class="muted">@<?= e($u['username']) ?></span>
        <?php if ($u['role'] === 'admin'): ?><a href="/admin.php">Admin</a><?php endif; ?>
        <form method="post" action="/logout.php" style="margin:0"><?= csrf_field() ?><button class="btn-ghost" type="submit"><?= e(t('logout')) ?></button></form>
      <?php else: ?>
        <a href="/login.php"><?= e(t('login')) ?></a>
        <a href="/register.php"><?= e(t('register')) ?></a>
      <?php endif; ?>
    </nav>
  </div>
</header>
<main class="container">
<?= $content ?>
</main>
<footer class="container muted" style="font-size:.8rem; padding-bottom:3rem">
  LiteForum · <a href="https://github.com/liteforum/liteforum">GitHub</a> · MIT
</footer>
</body>
</html>
PHP

  cat > "$APP_DIR/views/home.php" <<'PHP'
<?php /* @var array $cats */ ?>
<div class="glass card">
  <h1 style="margin:0 0 1rem;color:#fff"><?= e(t('forum')) ?></h1>
  <table>
    <thead><tr><th><?= e(t('categories')) ?></th><th><?= e(t('topics')) ?></th></tr></thead>
    <tbody>
    <?php foreach ($cats as $c): ?>
      <tr>
        <td><a href="/category.php?slug=<?= e($c['slug']) ?>"><?= e($c['name_' . $GLOBALS['__lang_code']] ?? $c['name_tr']) ?></a></td>
        <td class="muted"><?= (int)$c['n'] ?></td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table>
</div>
PHP

  cat > "$APP_DIR/views/login.php" <<'PHP'
<?php /* @var string $error */ $config = $GLOBALS['__config']; ?>
<div class="glass card" style="max-width:420px;margin:2rem auto">
  <h1 style="margin:0 0 1rem;color:#fff"><?= e(t('login')) ?></h1>
  <?php if (!empty($error)): ?><p style="color:#fca5a5"><?= e($error) ?></p><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="email" type="email" required placeholder="<?= e(t('email')) ?>" autocomplete="username">
    <input name="password" type="password" required placeholder="<?= e(t('password')) ?>" autocomplete="current-password">
    <button type="submit"><?= e(t('login')) ?></button>
  </form>

  <?php
  /* =========================================================================
     ERENDEV OAUTH — RENDERED ONLY WHEN THE INSTALL LANGUAGE IS 'tr'.
     On an 'en' installation this block is NEVER emitted to the HTML
     (not hidden with CSS — simply not printed). Even if the end user
     changes their UI language, default_lang is fixed at install time,
     so the button stays hidden everywhere.
     ========================================================================= */
  if (($config['default_lang'] ?? '') === 'tr'):
    $rd = rawurlencode($config['erendev']['redirect_uri']);
    $cid = rawurlencode($config['erendev']['client_id']);
    $scope = rawurlencode($config['erendev']['scope']);
    $state = bin2hex(random_bytes(24));
    $_SESSION['erendev_state'] = $state;
    $url = $config['erendev']['authorize_url']
         . '?client_id=' . $cid
         . '&redirect_uri=' . $rd
         . '&response_type=code'
         . '&scope=' . $scope
         . '&state=' . rawurlencode($state);
  ?>
  <div style="margin-top:1.25rem; padding-top:1.25rem; border-top:1px solid #1e293b">
    <a href="<?= e($url) ?>">
      <img src="<?= e($config['erendev']['button_svg']) ?>"
           alt="ErenDev ile Giriş Yap" width="240" height="48" style="height:48px">
    </a>
  </div>
  <?php endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/register.php" <<'PHP'
<?php /* @var string $error */ $config = $GLOBALS['__config']; ?>
<div class="glass card" style="max-width:420px;margin:2rem auto">
  <h1 style="margin:0 0 1rem;color:#fff"><?= e(t('register')) ?></h1>
  <?php if (!empty($error)): ?><p style="color:#fca5a5"><?= e($error) ?></p><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="username" required minlength="3" maxlength="32" pattern="[A-Za-z0-9_\-]{3,32}" placeholder="<?= e(t('username')) ?>">
    <input name="email" type="email" required placeholder="<?= e(t('email')) ?>" autocomplete="email">
    <input name="password" type="password" required minlength="10" placeholder="<?= e(t('password')) ?>" autocomplete="new-password">
    <input name="hp" type="text" tabindex="-1" autocomplete="off" style="display:none" aria-hidden="true">
    <button type="submit"><?= e(t('register')) ?></button>
  </form>
  <?php if (($config['default_lang'] ?? '') === 'tr'): ?>
    <div style="margin-top:1.25rem; padding-top:1.25rem; border-top:1px solid #1e293b">
      <a href="/login.php"><img src="<?= e($config['erendev']['button_svg']) ?>" alt="ErenDev ile Giriş Yap" style="height:48px"></a>
    </div>
  <?php endif; ?>
</div>
PHP
  chown -R root:root "$APP_DIR/views"
  chmod -R 0755 "$APP_DIR/views"
}

# ------------------------------- Public routes -------------------------------
write_public() {
  log "Writing public PHP routes..."
  chown -R root:root "$APP_DIR/public"

  cat > "$APP_DIR/public/index.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$GLOBALS['__config'] = $config;
$GLOBALS['__lang_code'] = in_array($_SESSION['lang'] ?? '', ['tr','en'], true)
    ? $_SESSION['lang'] : $config['default_lang'];

$cats = $db->query(
  "SELECT c.*, (SELECT COUNT(*) FROM topics t WHERE t.category_id=c.id) AS n
   FROM categories c ORDER BY position, id"
)->fetchAll();

$title = t('forum');
ob_start();
require LF_ROOT . '/views/home.php';
$content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/login.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$GLOBALS['__config'] = $config;
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  if (!rate_limit($db, 'login', client_ip(), $config['rate_limit']['login_per_10min'], 600)) {
    http_response_code(429); $error = t('too_many_attempts');
  } else {
    $email = filter_var($_POST['email'] ?? '', FILTER_VALIDATE_EMAIL);
    $pass  = (string)($_POST['password'] ?? '');
    if (!$email || $pass === '') { $error = t('missing_info'); }
    else {
      $st = $db->prepare('SELECT * FROM users WHERE email = ?');
      $st->execute([$email]);
      $u = $st->fetch();
      if ($u && password_verify_safe($pass, $u['password_hash'])) {
        auth_login($u);
        redirect('/');
      }
      $error = t('bad_credentials');
    }
  }
}
ob_start(); require LF_ROOT . '/views/login.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/register.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$GLOBALS['__config'] = $config;
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  if (!empty($_POST['hp'])) { http_response_code(400); exit(t('bot_detected')); }
  if (!rate_limit($db, 'register', client_ip(), $config['rate_limit']['register_per_hr'], 3600)) {
    http_response_code(429); $error = t('register_limit');
  } else {
    $u  = trim((string)($_POST['username'] ?? ''));
    $em = filter_var($_POST['email'] ?? '', FILTER_VALIDATE_EMAIL);
    $p  = (string)($_POST['password'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_\-]{3,32}$/', $u)) $error = t('bad_username');
    elseif (!$em) $error = t('bad_email');
    elseif (strlen($p) < 10) $error = t('weak_password');
    else {
      try {
        $st = $db->prepare('INSERT INTO users(username,email,password_hash,created_at) VALUES(?,?,?,?)');
        $st->execute([$u, $em, password_hash_safe($p), time()]);
        $row = $db->prepare('SELECT * FROM users WHERE id=?');
        $row->execute([$db->lastInsertId()]);
        auth_login($row->fetch());
        redirect('/');
      } catch (PDOException $e) {
        $error = t('already_exists');
      }
    }
  }
}
ob_start(); require LF_ROOT . '/views/register.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/logout.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); exit; }
csrf_verify();
auth_logout();
redirect('/');
PHP

  # OAuth callback
  mkdir -p "$APP_DIR/public/oauth/erendev"
  cat > "$APP_DIR/public/oauth/erendev/callback.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$config = require LF_ROOT . '/config/config.php';

// Language rule: on an EN install, this endpoint does not exist at all
if (($config['default_lang'] ?? '') !== 'tr') {
  http_response_code(404); exit('Not found.');
}

$state = (string)($_GET['state'] ?? '');
$code  = (string)($_GET['code'] ?? '');
if (!$state || !hash_equals($_SESSION['erendev_state'] ?? '', $state)) {
  http_response_code(400); exit('Invalid state.');
}
unset($_SESSION['erendev_state']);
if (!$code) { http_response_code(400); exit('Missing code.'); }

$ch = curl_init($config['erendev']['token_url']);
curl_setopt_array($ch, [
  CURLOPT_POST => true,
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_TIMEOUT => 15,
  CURLOPT_SSL_VERIFYPEER => true,
  CURLOPT_SSL_VERIFYHOST => 2,
  CURLOPT_POSTFIELDS => http_build_query([
    'grant_type'    => 'authorization_code',
    'code'          => $code,
    'redirect_uri'  => $config['erendev']['redirect_uri'],
    'client_id'     => $config['erendev']['client_id'],
    'client_secret' => $config['erendev']['client_secret'],
  ]),
]);
$resp = curl_exec($ch);
if (curl_errno($ch)) { http_response_code(502); exit('Token exchange failed.'); }
$tok = json_decode((string)$resp, true);
if (empty($tok['access_token'])) { http_response_code(502); exit('No access token.'); }

$ch2 = curl_init($config['erendev']['userinfo_url']);
curl_setopt_array($ch2, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_TIMEOUT => 10,
  CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . $tok['access_token']],
  CURLOPT_SSL_VERIFYPEER => true,
]);
$u = json_decode((string)curl_exec($ch2), true);
if (empty($u['sub']) || empty($u['email'])) { http_response_code(502); exit('Bad userinfo.'); }

$sub = (string)$u['sub'];
$email = (string)$u['email'];
$username = $u['preferred_username'] ?? ('ed_' . substr(hash('sha256', $sub), 0, 10));

$st = $db->prepare('SELECT * FROM users WHERE erendev_sub = ? OR email = ?');
$st->execute([$sub, $email]);
$user = $st->fetch();
if (!$user) {
  $db->prepare('INSERT INTO users(username,email,password_hash,erendev_sub,created_at) VALUES(?,?,?,?,?)')
     ->execute([$username, $email, password_hash_safe(bin2hex(random_bytes(24))), $sub, time()]);
  $st = $db->prepare('SELECT * FROM users WHERE id=?');
  $st->execute([$db->lastInsertId()]);
  $user = $st->fetch();
} else {
  $db->prepare('UPDATE users SET erendev_sub=? WHERE id=?')->execute([$sub, $user['id']]);
}
auth_login($user);
redirect('/');
PHP

  chown -R root:root "$APP_DIR/public"
  find "$APP_DIR/public" -type d -exec chmod 0755 {} \;
  find "$APP_DIR/public" -type f -exec chmod 0644 {} \;
}

# ------------------------------- Nginx ---------------------------------------
write_nginx() {
  log "Configuring Nginx (hardened)..."
  SOCK="/run/php/${PHP_VER}-fpm-liteforum.sock"
  cat > "/etc/nginx/sites-available/liteforum" <<NGINX
# Rate-limit zones
limit_req_zone \$binary_remote_addr zone=lf_login:10m rate=10r/m;
limit_req_zone \$binary_remote_addr zone=lf_general:10m rate=30r/s;

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    root $APP_DIR/public;
    index index.php;
    server_tokens off;
    charset utf-8;
    client_max_body_size 10m;
    client_body_timeout 15s;
    client_header_timeout 15s;
    send_timeout 20s;
    keepalive_timeout 30s;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), interest-cohort=()" always;
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Resource-Policy "same-origin" always;
    add_header Content-Security-Policy "default-src 'self'; img-src 'self' https://oauth2.erendev.xyz data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://oauth2.erendev.xyz; connect-src 'self'" always;

    location = /install.php {
        # Loopback only
        allow 127.0.0.1;
        allow ::1;
        deny all;
        fastcgi_pass unix:$SOCK;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_hide_header X-Powered-By;
    }

    location = /login.php {
        limit_req zone=lf_login burst=5 nodelay;
        fastcgi_pass unix:$SOCK;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$SOCK;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 30s;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ /\.(?!well-known) { deny all; }
    location ~* \.(env|log|sqlite|db|sql|bak|ini|conf|md|git)$ { deny all; }
    location ~ /(config|app|lang|views|storage)/ { deny all; }

    access_log $LOG_DIR/access.log;
    error_log  $LOG_DIR/error.log warn;
}
NGINX
  if [[ $SKIP_TLS -eq 1 ]]; then
    sed -i 's/return 301 https:\/\/\$host\$request_uri;//' /etc/nginx/sites-available/liteforum
    sed -i 's/listen 443 ssl http2;/listen 80;/' /etc/nginx/sites-available/liteforum
    sed -i '/ssl_/d' /etc/nginx/sites-available/liteforum
    sed -i '/Strict-Transport-Security/d' /etc/nginx/sites-available/liteforum
  fi
  ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
  rm -f /etc/nginx/sites-enabled/default
  chown root:root /etc/nginx/sites-available/liteforum
  chmod 0644 /etc/nginx/sites-available/liteforum
  ok "Nginx configured"
}

# ------------------------------- PHP-FPM -------------------------------------
write_phpfpm() {
  log "Hardening PHP-FPM pool..."
  POOL="/etc/php/${PHP_VER#php}/fpm/pool.d/liteforum.conf"
  cat > "$POOL" <<FPM
[liteforum]
user = $SVC_USER
group = $SVC_USER
listen = /run/php/${PHP_VER}-fpm-liteforum.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
pm.max_requests = 500

request_terminate_timeout = 30s
request_slowlog_timeout = 5s
slowlog = $LOG_DIR/php-slow.log

php_admin_value[error_log] = $LOG_DIR/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_flag[expose_php] = off
php_admin_flag[allow_url_include] = off
php_admin_flag[allow_url_fopen] = off

php_admin_value[open_basedir] = $APP_DIR:$DATA_DIR:/tmp
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,pcntl_exec,show_source,phpinfo
php_admin_value[upload_tmp_dir] = $DATA_DIR/tmp
php_admin_value[session.save_path] = $DATA_DIR/sessions
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
php_admin_value[session.cookie_samesite] = "Strict"
php_admin_value[session.use_strict_mode] = 1
php_admin_value[session.use_only_cookies] = 1
php_admin_value[session.sid_length] = 48
php_admin_value[session.sid_bits_per_character] = 6

php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 64
php_admin_value[opcache.validate_timestamps] = 0
php_admin_value[opcache.interned_strings_buffer] = 8
php_admin_value[opcache.max_accelerated_files] = 4000
FPM
  chown root:root "$POOL"
  chmod 0644 "$POOL"
  ok "PHP-FPM pool written"
}

# ------------------------------- Firewall ------------------------------------
setup_ufw() {
  [[ $NO_FIREWALL -eq 1 ]] && { warn "UFW skipped"; return; }
  log "Configuring UFW..."
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
  ok "UFW enabled"
}

# ------------------------------- Fail2ban ------------------------------------
setup_fail2ban() {
  log "Configuring Fail2ban..."
  cat > /etc/fail2ban/jail.d/liteforum.local <<'F2B'
[sshd]
enabled = true
maxretry = 4
findtime = 10m
bantime = 1h

[nginx-http-auth]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-req-limit]
enabled = true
filter = nginx-req-limit
action = iptables-multiport[name=ReqLimit, port="http,https", protocol=tcp]
logpath = /var/log/liteforum/error.log
findtime = 10m
bantime = 1h
maxretry = 10
F2B
  cat > /etc/fail2ban/filter.d/nginx-req-limit.conf <<'FLT'
[Definition]
failregex = limiting requests, excess:.* by zone .*, client: <HOST>
ignoreregex =
FLT
  systemctl enable --now fail2ban
  ok "Fail2ban enabled"
}

# ------------------------------- Kernel hardening ----------------------------
setup_sysctl() {
  log "Kernel hardening (sysctl)..."
  cat > /etc/sysctl.d/99-liteforum.conf <<'SYS'
# Kernel hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 2
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.use_tempaddr = 2
SYS
  sysctl --system >/dev/null
  ok "Sysctl applied"
}

# ------------------------------- Backups -------------------------------------
setup_backup() {
  log "Setting up daily automated backups..."
  cat > /etc/cron.d/liteforum-backup <<CRON
# LiteForum daily backup + WAL checkpoint
30 3 * * * $SVC_USER sqlite3 $DATA_DIR/liteforum.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
45 3 * * * root tar czf - $DATA_DIR | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:/etc/liteforum/backup.pass > $DATA_DIR/backups/lf-\$(date +\\%F).tar.gz.enc 2>/dev/null && find $DATA_DIR/backups -name 'lf-*.tar.gz.enc' -mtime +14 -delete
CRON
  install -d -o root -g root -m 0700 /etc/liteforum
  openssl rand -base64 32 > /etc/liteforum/backup.pass
  chmod 0600 /etc/liteforum/backup.pass
  ok "Backups scheduled (14-day retention)"
}

# ------------------------------- TLS -----------------------------------------
setup_tls() {
  [[ $SKIP_TLS -eq 1 ]] && { warn "TLS skipped"; return; }
  log "Obtaining Let's Encrypt TLS certificate ($DOMAIN)..."
  # Temporary HTTP config for the ACME challenge
  cat > /etc/nginx/sites-available/liteforum.http <<HTTP
server { listen 80; server_name $DOMAIN; root $APP_DIR/public;
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 301 https://\$host\$request_uri; }
}
HTTP
  ln -sf /etc/nginx/sites-available/liteforum.http /etc/nginx/sites-enabled/liteforum.http
  rm -f /etc/nginx/sites-enabled/liteforum
  nginx -t && systemctl reload nginx
  certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect || die "Certbot failed"
  rm -f /etc/nginx/sites-enabled/liteforum.http
  ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
  nginx -t && systemctl reload nginx
  systemctl enable --now certbot.timer 2>/dev/null || true
  ok "TLS done"
}

# ------------------------------- Seed data -----------------------------------
seed_data() {
  log "Seeding sample categories + admin user..."
  DB="$DATA_DIR/liteforum.db"
  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO categories(slug,name_tr,name_en,position) VALUES
 ('genel','Genel','General',10),
 ('duyurular','Duyurular','Announcements',20),
 ('destek','Destek','Support',30);
SQL
  HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_ARGON2ID);' "$ADMIN_PASS")"
  sqlite3 "$DB" <<SQL
INSERT INTO users(username,email,password_hash,role,created_at)
VALUES('admin','$ADMIN_EMAIL','$HASH','admin',strftime('%s','now'))
ON CONFLICT(email) DO UPDATE SET role='admin';
SQL
  chown "$SVC_USER:$SVC_USER" "$DB"* 2>/dev/null || true
  chmod 0600 "$DB"* 2>/dev/null || true
  ok "Seed complete"
}

# ------------------------------- Services ------------------------------------
start_services() {
  log "Starting services..."
  nginx -t || die "Nginx config is invalid"
  systemctl enable --now "$PHP_VER-fpm"
  systemctl enable --now nginx
  systemctl restart "$PHP_VER-fpm"
  systemctl restart nginx
  systemctl enable --now unattended-upgrades
  ok "Services are up"
}

# ------------------------------- Dry-run exit --------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  cat <<EOF
DRY-RUN plan:
  Domain : $DOMAIN
  Lang   : $LANG_CODE  (ErenDev OAuth rendered: $([[ $LANG_CODE == tr ]] && echo YES || echo NO))
  Admin  : $ADMIN_EMAIL
  AppDir : $APP_DIR
  DataDir: $DATA_DIR
  PHP    : $PHP_VER
  TLS    : $([[ $SKIP_TLS -eq 1 ]] && echo skip || echo yes)
EOF
  exit 0
fi

# ------------------------------- Orchestration -------------------------------
detect_os
install_packages
create_user
create_dirs
gen_secrets
init_sqlite
write_env
write_i18n
write_app
write_views
write_public
write_nginx
write_phpfpm
setup_ufw
setup_fail2ban
setup_sysctl
setup_backup
seed_data
setup_tls
start_services

# ------------------------------- Summary -------------------------------------
CRED_FILE="/root/liteforum-credentials.txt"
cat > "$CRED_FILE" <<EOF
LiteForum — Installation Summary ($(date -Is))
===============================================
URL              : https://$DOMAIN
Install language : $LANG_CODE
ErenDev OAuth    : $([[ $LANG_CODE == tr ]] && echo "VISIBLE (login + register + all auth entry points)" || echo "HIDDEN (never rendered)")
Admin email      : $ADMIN_EMAIL
Admin password   : $ADMIN_PASS
App key          : $APP_KEY
OAuth client_id  : $OAuth_CLIENT_ID
OAuth secret     : $OAuth_CLIENT_SECRET
DB               : $DATA_DIR/liteforum.db
Logs             : $LOG_DIR
Backup passphrase: /etc/liteforum/backup.pass
Backups          : $DATA_DIR/backups
EOF
chmod 0600 "$CRED_FILE"

log "Installation finished."
echo
echo "============================================================"
echo " LiteForum is ready → https://$DOMAIN"
echo " Install language: $LANG_CODE"
if [[ "$LANG_CODE" == "tr" ]]; then
  echo " ErenDev OAuth: VISIBLE (button rendered on login and register screens)"
else
  echo " ErenDev OAuth: HIDDEN (EN install — button is never rendered anywhere)"
fi
echo " Admin login: $ADMIN_EMAIL"
echo " Admin pass : $ADMIN_PASS   → $CRED_FILE"
echo "============================================================"
